#!/usr/bin/env bash
#
# dispatcher.sh — GitHub Issues-backed cron heartbeat for the worker / karen agent team.
#
# Task state is managed via GitHub Issue labels:
#   agent-todo    → queued, not yet claimed
#   agent-doing   → dispatcher claimed it (prevents double-dispatch)
#   agent-review  → worker done; awaiting karen verification
#   agent-done    → karen passed; issue closed
#
# Add ONE line to your crontab (absolute paths required):
#   */10 * * * * /ABS/PATH/<project>/scripts/dispatcher.sh >> /ABS/PATH/<project>/logs/dispatcher.log 2>&1
#
# Each tick does AT MOST ONE thing:
#   1. Run karen on the oldest agent-review issue  (always checked first)
#   2. OR run a worker on the oldest agent-todo issue
#
# Manual override flags (bypass active_hours + soft budget; still respect paused):
#   dispatcher.sh --force-worker               run on the oldest agent-todo issue right now
#   dispatcher.sh --force-worker <issue-num>   run on a specific issue right now
#
# Portable across macOS (bash 3.2, BSD date/grep) and Linux.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

# load cron environment (PATH + CLAUDE_CODE_OAUTH_TOKEN / GH_TOKEN)
if [ -f "$ROOT/.env" ]; then set -a; . "$ROOT/.env"; set +a; fi

# ---- parse manual force flags ----
force_issue=""   # empty = normal flow | "next" = oldest todo | "<N>" = specific issue
while [ $# -gt 0 ]; do
  case "$1" in
    --force-worker)
      if [ -n "${2:-}" ] && printf '%s' "${2:-}" | grep -qE '^[0-9]+$'; then
        force_issue="$2"; shift 2
      else
        force_issue="next"; shift
      fi ;;
    *)
      echo "$(date +%Y-%m-%dT%H:%M:%S) unknown flag: $1"
      echo "usage: dispatcher.sh [--force-worker [<issue-number>]]"
      exit 1 ;;
  esac
done

# ---- paths ----
SCHEDULE="$ROOT/schedule.json"
STATE="$ROOT/state"
USAGE="$ROOT/logs/usage.jsonl"
ACTIVITY="$ROOT/logs/activity.log"
LOCKDIR="$ROOT/.dispatcher.lock.d"

mkdir -p "$STATE" "$ROOT/logs"

TS()  { date +%Y-%m-%dT%H:%M:%S; }
log() { echo "$(TS) $*" | tee -a "$ACTIVITY"; }

# ---- preflight: required tools ----
command -v jq     >/dev/null 2>&1 || { log "ERROR: jq not found in PATH";                exit 1; }
command -v gh     >/dev/null 2>&1 || { log "ERROR: gh CLI not found in PATH";             exit 1; }
command -v claude >/dev/null 2>&1 || { log "ERROR: claude CLI not in PATH (set in .env)"; exit 1; }

# ---- preflight: git repository with a github.com remote ----
git rev-parse --git-dir >/dev/null 2>&1 \
  || { log "ERROR: must be run inside a git repository"; exit 1; }
origin_url=$(git remote get-url origin 2>/dev/null || true)
case "$origin_url" in
  *github.com*) : ;;
  *) log "ERROR: remote 'origin' must point to github.com (found: '${origin_url:-none}')"; exit 1 ;;
esac
gh auth status >/dev/null 2>&1 \
  || { log "ERROR: gh not authenticated — run 'gh auth login' or set GH_TOKEN in .env"; exit 1; }

# ---- read policy ----
[ -f "$SCHEDULE" ] || { log "ERROR: schedule.json not found at $SCHEDULE"; exit 1; }
[ "$(jq -r '.paused // false' "$SCHEDULE")" = "true" ] && { log "globally paused — nothing to do"; exit 0; }

REPO=$(jq -r '.github.repo // ""' "$SCHEDULE")
[ -n "$REPO" ] || { log "ERROR: github.repo not set in schedule.json"; exit 1; }

now_epoch=$(date +%s)
hour=$(( 10#$(date +%H) ))
max_turns=$(   jq -r '.max_turns              // 25'       "$SCHEDULE")
worker_model=$(jq -r '.worker_model           // "haiku"'  "$SCHEDULE")
karen_model=$( jq -r '.karen_model            // "sonnet"' "$SCHEDULE")
soft_budget=$( jq -r '.soft_budget_usd_per_5h // 0'        "$SCHEDULE")

# ---- active_hours (skipped for --force-worker) ----
if [ -z "$force_issue" ]; then
  ah_start=$(jq -r '.active_hours.start // 0'  "$SCHEDULE")
  ah_end=$(  jq -r '.active_hours.end   // 24' "$SCHEDULE")
  if (( hour < ah_start || hour >= ah_end )); then
    echo "$(TS) outside active hours (${ah_start}–${ah_end}); skipping"; exit 0
  fi
fi

# ---- soft budget throttle (skipped for --force-worker) ----
if [ -f "$USAGE" ] && [ "$soft_budget" != "0" ] && [ -z "$force_issue" ]; then
  cutoff=$(( now_epoch - 5*3600 ))
  spent=$(jq -s --argjson c "$cutoff" \
    '[.[] | select(.ts >= $c) | .cost] | add // 0' "$USAGE" 2>/dev/null || echo 0)
  if [ "$(jq -n --argjson s "$spent" --argjson b "$soft_budget" '$s >= $b')" = "true" ]; then
    log "throttled: \$$spent in last 5h >= soft budget \$$soft_budget"; exit 0
  fi
fi

# ---- single-flight lock (atomic mkdir; auto-clears stale locks >25m) ----
if [ -d "$LOCKDIR" ] && [ -n "$(find "$LOCKDIR" -maxdepth 0 -mmin +25 2>/dev/null)" ]; then
  rmdir "$LOCKDIR" 2>/dev/null || true
fi
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  echo "$(TS) previous tick still running; skipping"; exit 0
fi
trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT INT TERM

# ---- helper: run a claude agent headless, log cost ----
run_agent() {  # $1=agent $2=model $3=prompt-file
  local agent="$1" model="$2" pf="$3" out cost
  if ! out=$(claude -p "$(cat "$pf")" \
               --agent "$agent" \
               --model "$model" \
               --max-turns "$max_turns" \
               --output-format json 2>>"$ROOT/logs/dispatcher.log"); then
    log "ERROR: claude run failed for agent=$agent (see logs/dispatcher.log)"
    return 1
  fi
  cost=$(echo "$out" | jq -r '.total_cost_usd // 0')
  echo "$out" | jq -c --arg a "$agent" --argjson ts "$now_epoch" \
      '{ts:$ts, agent:$a, cost:(.total_cost_usd // 0), usage:(.usage // {})}' >> "$USAGE"
  log "ran $agent ($model) cost=\$$cost"
  return 0
}

# ============================================================
# RULE 1 — Priority: karen verification always runs before new work.
# ============================================================
review_json=$(gh issue list --repo "$REPO" --label "agent-review" --state open \
  --json number,title,body --jq 'sort_by(.number) | first // empty' 2>/dev/null || true)

if [ -n "${review_json:-}" ]; then
  iss_num=$(  echo "$review_json" | jq -r '.number')
  iss_title=$(echo "$review_json" | jq -r '.title')
  iss_body=$( echo "$review_json" | jq -r '.body // ""')
  log "VERIFY issue #$iss_num: $iss_title"

  verdict_file="$STATE/verdict.txt"
  rm -f "$verdict_file"

  tmp=$(mktemp)
  cat > "$tmp" <<PROMPT
You are karen, the verifier. Audit the repository for issue #${iss_num}: "${iss_title}".

Issue description:
${iss_body}

Instructions:
1. Establish what was CLAIMED — read relevant task files, artifacts, and the issue body.
2. Establish what ACTUALLY EXISTS — read source files; where possible, run build/tests to
   prove function rather than assume it. Use read-only commands only; do NOT edit source.
3. For each item, decide: PASS (works), FAIL (broken/missing — give exact evidence), or
   OVER-ENGINEERED (exceeds the requirement).
4. Write your complete verdict to state/verdict.txt.
   - The VERY FIRST LINE must be exactly the word PASSED or FAILED (nothing else on that line).
   - Leave a blank line, then list bulleted findings (one per item with evidence).
   - End with a "## Gaps to close" section for any remediation steps (FAIL items only).
5. Return a 2–3 line summary for the log: counts, verdict, and the most critical gap.
PROMPT

  run_agent karen "$karen_model" "$tmp" || true
  rm -f "$tmp"

  # guard: if karen produced no verdict, cycle back rather than hanging
  if [ ! -f "$verdict_file" ]; then
    log "  karen did not write verdict.txt — cycling #$iss_num back to agent-todo"
    gh issue comment "$iss_num" --repo "$REPO" \
      --body "⚠️ **Verifier did not produce a verdict.** Cycling back to \`agent-todo\` for retry." \
      >/dev/null 2>&1 || true
    gh issue edit "$iss_num" --repo "$REPO" \
      --remove-label "agent-review" --add-label "agent-todo" >/dev/null 2>&1 || true
    exit 0
  fi

  verdict_text=$(cat "$verdict_file")
  first_word=$(head -1 "$verdict_file" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')

  gh issue comment "$iss_num" --repo "$REPO" \
    --body "## Karen's Verdict

\`\`\`
${verdict_text}
\`\`\`" >/dev/null 2>&1 || true

  # ---- RULE 2: route on PASSED / FAILED ----
  if [ "$first_word" = "PASSED" ]; then
    gh issue edit  "$iss_num" --repo "$REPO" \
      --remove-label "agent-review" --add-label "agent-done" >/dev/null 2>&1 || true
    gh issue close "$iss_num" --repo "$REPO" >/dev/null 2>&1 || true
    log "  issue #$iss_num PASSED — labelled agent-done, closed"
  else
    gh issue edit "$iss_num" --repo "$REPO" \
      --remove-label "agent-review" --add-label "agent-todo" >/dev/null 2>&1 || true
    log "  issue #$iss_num FAILED — labelled agent-todo for rework"
  fi
  exit 0
fi

# ============================================================
# RULE 3 — Worker: claim and execute the oldest agent-todo issue.
# ============================================================
if [ -n "$force_issue" ] && [ "$force_issue" != "next" ]; then
  # --force-worker <N>: specific issue by number
  todo_json=$(gh issue view "$force_issue" --repo "$REPO" \
    --json number,title,body,labels 2>/dev/null || true)
  if [ -z "${todo_json:-}" ]; then
    log "--force-worker: issue #$force_issue not found in $REPO"; exit 1
  fi
  has_label=$(echo "$todo_json" | jq -r '[.labels[].name] | index("agent-todo") != null')
  if [ "$has_label" != "true" ]; then
    log "--force-worker: issue #$force_issue does not have the agent-todo label"; exit 1
  fi
else
  # normal tick or --force-worker (next): oldest open agent-todo
  todo_json=$(gh issue list --repo "$REPO" --label "agent-todo" --state open \
    --json number,title,body --jq 'sort_by(.number) | first // empty' 2>/dev/null || true)
fi

if [ -z "${todo_json:-}" ]; then
  echo "$(TS) nothing to do (no agent-review or agent-todo issues open)"; exit 0
fi

iss_num=$(  echo "$todo_json" | jq -r '.number')
iss_title=$(echo "$todo_json" | jq -r '.title')
iss_body=$( echo "$todo_json" | jq -r '.body // ""')
log "WORK issue #$iss_num: $iss_title"

# Atomic label swap — prevents a concurrent tick from claiming the same issue
gh issue edit "$iss_num" --repo "$REPO" \
  --remove-label "agent-todo" --add-label "agent-doing" >/dev/null 2>&1 || true

output_file="$STATE/worker_output.txt"
rm -f "$output_file"

tmp=$(mktemp)
cat > "$tmp" <<PROMPT
You are a worker on a background agent team. Complete the task described in GitHub issue #${iss_num}.

Title: ${iss_title}

Description:
${iss_body}

Instructions:
1. Read only the files you actually need — do not explore the entire repository.
2. Do the work described. Stay strictly in scope; do not expand requirements.
3. When finished, write a concise technical markdown summary to state/worker_output.txt.
   Include: what you did, which files were changed or created, any caveats or follow-up items.
   Keep it under 40 lines — this will be posted as a GitHub issue comment.
4. If the task is ambiguous or blocked, write what you found to state/worker_output.txt,
   state the blocker clearly, and stop — do not guess or broaden scope.

Your summary will be posted to the issue and then independently verified by karen.
PROMPT

run_agent worker "$worker_model" "$tmp" || true
rm -f "$tmp"

if [ -f "$output_file" ]; then
  summary=$(cat "$output_file")
else
  summary="_Worker completed issue #${iss_num} but did not write state/worker_output.txt._"
fi

gh issue comment "$iss_num" --repo "$REPO" \
  --body "## Worker Summary

${summary}" >/dev/null 2>&1 || true

gh issue edit "$iss_num" --repo "$REPO" \
  --remove-label "agent-doing" --add-label "agent-review" >/dev/null 2>&1 || true
log "  issue #$iss_num complete — moved to agent-review"

# keep activity log bounded
if [ -f "$ACTIVITY" ] && [ "$(wc -l < "$ACTIVITY" | tr -d ' ')" -gt 500 ]; then
  tail -n 500 "$ACTIVITY" > "$ACTIVITY.tmp" && mv "$ACTIVITY.tmp" "$ACTIVITY"
fi
