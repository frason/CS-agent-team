#!/usr/bin/env bash
#
# dispatcher.sh — GitHub Issues-backed cron heartbeat for the agent team.
#
# Task state is managed via GitHub Issue labels:
#   agent-todo    → queued, not yet claimed
#   agent-doing   → dispatcher claimed it (prevents double-dispatch)
#   agent-review  → worker done; awaiting karen verification
#   agent-done    → karen passed; issue closed
#   agent-backlog → sequenced task waiting on dependencies (created by lead)
#
# Add ONE line to your crontab (absolute paths required):
#   */10 * * * * /ABS/PATH/scripts/dispatcher.sh >> /ABS/PATH/logs/dispatcher.log 2>&1
#
# Each tick does AT MOST ONE thing (priority order):
#   1. LEAD pass  — at lead_windows minutes or --force-lead
#   2. KAREN pass — oldest agent-review issue (always before new work)
#   3. WORKER run — oldest agent-todo issue
#
# Manual override flags (bypass active_hours + soft budget; still respect paused):
#   dispatcher.sh --force-lead                  run the lead agent right now
#   dispatcher.sh --force-worker               run on the oldest agent-todo issue
#   dispatcher.sh --force-worker <issue-num>   run on a specific issue
#
# Portable across macOS (bash 3.2, BSD date/grep) and Linux.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

# load cron environment (PATH + CLAUDE_CODE_OAUTH_TOKEN / GH_TOKEN)
if [ -f "$ROOT/.env" ]; then set -a; . "$ROOT/.env"; set +a; fi

# ---- parse manual force flags ----
force_lead=false
force_issue=""
while [ $# -gt 0 ]; do
  case "$1" in
    --force-lead)
      force_lead=true; shift ;;
    --force-worker)
      if [ -n "${2:-}" ] && printf '%s' "${2:-}" | grep -qE '^[0-9]+$'; then
        force_issue="$2"; shift 2
      else
        force_issue="next"; shift
      fi ;;
    *)
      echo "$(date +%Y-%m-%dT%H:%M:%S) unknown flag: $1"
      echo "usage: dispatcher.sh [--force-lead] [--force-worker [<issue-number>]]"
      exit 1 ;;
  esac
done

# ---- paths ----
SCHEDULE="$ROOT/schedule.json"
STATE="$ROOT/state"
USAGE="$ROOT/logs/usage.jsonl"
ACTIVITY="$ROOT/logs/activity.log"
LOCKDIR="$ROOT/.dispatcher.lock.d"
INBOX="$ROOT/lead-inbox"

mkdir -p "$STATE" "$ROOT/logs" "$INBOX/done"

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
gh api user --jq '.login' >/dev/null 2>&1 \
  || { log "ERROR: gh not authenticated — run 'gh auth login' or set GH_TOKEN in .env"; exit 1; }

# ---- read policy ----
[ -f "$SCHEDULE" ] || { log "ERROR: schedule.json not found at $SCHEDULE"; exit 1; }
[ "$(jq -r '.paused // false' "$SCHEDULE")" = "true" ] && { log "globally paused — nothing to do"; exit 0; }

REPO=$(jq -r '.github.repo // ""' "$SCHEDULE")
[ -n "$REPO" ] || { log "ERROR: github.repo not set in schedule.json"; exit 1; }

now_epoch=$(date +%s)
hour=$(( 10#$(date +%H) ))
minute=$(( 10#$(date +%M) ))
max_turns=$(     jq -r '.max_turns               // 25'      "$SCHEDULE")
worker_model=$(  jq -r '.worker_model            // "haiku"' "$SCHEDULE")
karen_model=$(   jq -r '.karen_model             // "sonnet"' "$SCHEDULE")
lead_model=$(    jq -r '.lead_model              // "sonnet"' "$SCHEDULE")
lead_max_turns=$(jq -r '.lead_max_turns          // 50'      "$SCHEDULE")
lead_paused=$(   jq -r '.lead_paused             // false'   "$SCHEDULE")
soft_budget=$(   jq -r '.soft_budget_usd_per_5h  // 0'       "$SCHEDULE")

# ---- refresh the rolling-budget summary in STATUS.md (token-free, gated) ----
# Runs before the throttle check so throttled ticks still update the meter.
if [ "$(jq -r '.telemetry.show_rolling_budget_in_status // false' "$SCHEDULE")" = "true" ]; then
  bash "$SCRIPT_DIR/budget_check.sh" || true
fi

# ---- active_hours (skipped for any --force flag) ----
if [ -z "$force_issue" ] && [ "$force_lead" != "true" ]; then
  ah_start=$(jq -r '.active_hours.start // 0'  "$SCHEDULE")
  ah_end=$(  jq -r '.active_hours.end   // 24' "$SCHEDULE")
  if (( hour < ah_start || hour >= ah_end )); then
    echo "$(TS) outside active hours (${ah_start}–${ah_end}); skipping"; exit 0
  fi
fi

# ---- soft budget throttle (skipped for any --force flag) ----
if [ -f "$USAGE" ] && [ "$soft_budget" != "0" ] && [ -z "$force_issue" ] && [ "$force_lead" != "true" ]; then
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
# Usage: run_agent <agent> <model> <prompt-file> [<max-turns>]
# Feeds the prompt via stdin (not -p arg): task files starting with YAML "---" frontmatter
# would be parsed by claude as an unknown CLI option ("error: unknown option '---'").
run_agent() {
  local agent="$1" model="$2" pf="$3" mt="${4:-$max_turns}" out rc cost subtype
  out=$(claude -p \
          --agent "$agent" \
          --model "$model" \
          --max-turns "$mt" \
          --output-format json < "$pf" 2>>"$ROOT/logs/dispatcher.log") && rc=0 || rc=$?

  if echo "$out" | jq -e . >/dev/null 2>&1; then
    cost=$(echo "$out" | jq -r '.total_cost_usd // 0')
    echo "$out" | jq -c --arg a "$agent" --argjson ts "$now_epoch" \
        '{ts:$ts, agent:$a, cost:(.total_cost_usd // 0), usage:(.usage // {})}' >> "$USAGE"
    subtype=$(echo "$out" | jq -r '.subtype // ""')
  else
    cost=0; subtype=""
  fi

  if [ "$rc" -ne 0 ]; then
    # A turn-budget cutoff exits non-zero but the agent's writes already landed.
    if [ "$subtype" = "error_max_turns" ]; then
      log "ran $agent ($model) cost=\$$cost — hit max-turns; treating as complete"
      return 0
    fi
    log "ERROR: claude run failed for agent=$agent rc=$rc (see logs/dispatcher.log)"
    return 1
  fi

  log "ran $agent ($model) cost=\$$cost"
  return 0
}

# ---- helper: promote backlog issues whose declared dependencies are all closed ----
# Dependencies are declared in the issue body as a line: "depends_on: #12, #15"
# This is deterministic (no tokens) and runs before the lead on every lead-window tick.
promote_backlog() {
  local issues num body deps all_closed dep dep_state
  issues=$(gh issue list --repo "$REPO" --label "agent-backlog" --state open \
    --json number,body 2>/dev/null || true)
  [ -z "${issues:-}" ] || [ "$issues" = "[]" ] && return 0

  while IFS= read -r iss; do
    num=$(printf '%s' "$iss" | jq -r '.number')
    body=$(printf '%s' "$iss" | jq -r '.body // ""')
    deps=$(printf '%s' "$body" | grep -iE '^depends_on:' | head -1 \
           | sed 's/[^:]*:[[:space:]]*//' | grep -oE '[0-9]+' || true)

    if [ -z "${deps:-}" ]; then
      gh issue edit "$num" --repo "$REPO" \
        --remove-label "agent-backlog" --add-label "agent-todo" >/dev/null 2>&1 || true
      log "  promoted backlog #$num → agent-todo (no dependencies declared)"
      continue
    fi

    all_closed=true
    for dep in $deps; do
      dep_state=$(gh issue view "$dep" --repo "$REPO" --json state \
        --jq '.state' 2>/dev/null || echo "OPEN")
      [ "$dep_state" = "CLOSED" ] || { all_closed=false; break; }
    done

    if [ "$all_closed" = "true" ]; then
      gh issue edit "$num" --repo "$REPO" \
        --remove-label "agent-backlog" --add-label "agent-todo" >/dev/null 2>&1 || true
      log "  promoted backlog #$num → agent-todo (all dependencies closed)"
    fi
  done < <(printf '%s' "$issues" | jq -c '.[]' 2>/dev/null)
}

# ============================================================
# LEAD PASS — at configured lead_windows minute values or --force-lead.
# Always exits after this block so lead and karen/worker never share a tick.
# ============================================================
is_lead_window=$(jq -r --argjson m "$minute" \
  '(.lead_windows // [0]) | index($m) != null' "$SCHEDULE")

if [ "$is_lead_window" = "true" ] || [ "$force_lead" = "true" ]; then

  if [ "$lead_paused" = "true" ]; then
    log "lead paused (lead_paused: true) — skipping lead pass"
    exit 0
  fi

  # Promote backlog issues with satisfied dependencies (token-free).
  promote_backlog

  # Collect inbox items that will be fed to the lead.
  fed_items=()
  for f in "$INBOX"/*.md; do
    [ -e "$f" ] || continue
    fed_items+=("$f")
  done
  inbox_count=${#fed_items[@]}

  # Count remaining backlog issues (after promotion above).
  backlog_count=$(gh issue list --repo "$REPO" --label "agent-backlog" --state open \
    --json number --jq 'length' 2>/dev/null || echo 0)

  # Fetch open client questions and count answered ones (have comments).
  question_json=$(gh issue list --repo "$REPO" --label "agent-question" --state open \
    --json number,title,body,comments 2>/dev/null || echo "[]")
  question_answered_count=$(printf '%s' "$question_json" \
    | jq '[.[] | select((.comments | length) > 0)] | length' 2>/dev/null || echo 0)
  question_total=$(printf '%s' "$question_json" | jq 'length' 2>/dev/null || echo 0)

  if [ "$inbox_count" -eq 0 ] && [ "${backlog_count:-0}" -eq 0 ] \
     && [ "${question_answered_count:-0}" -eq 0 ] && [ "$force_lead" != "true" ]; then
    log "lead window: nothing to do (empty inbox, no backlog, no answered questions)"
    exit 0
  fi

  log "LEAD PASS inbox=${inbox_count} backlog=${backlog_count:-0} questions=${question_total:-0}(${question_answered_count:-0} answered)"

  # Fetch current board state for the lead prompt.
  todo_list=$(gh issue list --repo "$REPO" --label "agent-todo" --state open \
    --json number,title --jq '[.[] | "  #\(.number) \(.title)"] | join("\n")' 2>/dev/null \
    || echo "  (none)")
  doing_list=$(gh issue list --repo "$REPO" --label "agent-doing" --state open \
    --json number,title --jq '[.[] | "  #\(.number) \(.title)"] | join("\n")' 2>/dev/null \
    || echo "  (none)")
  review_list=$(gh issue list --repo "$REPO" --label "agent-review" --state open \
    --json number,title --jq '[.[] | "  #\(.number) \(.title)"] | join("\n")' 2>/dev/null \
    || echo "  (none)")
  backlog_list=$(gh issue list --repo "$REPO" --label "agent-backlog" --state open \
    --json number,title --jq '[.[] | "  #\(.number) \(.title)"] | join("\n")' 2>/dev/null \
    || echo "  (none)")

  tmp=$(mktemp)
  {
    printf 'This is your scheduled lead planning pass. Repo: %s\n\n' "$REPO"
    printf '## GitHub Issues board\n\n'
    printf 'agent-todo (ready for workers):\n%s\n\n'              "$todo_list"
    printf 'agent-doing (in flight):\n%s\n\n'                     "$doing_list"
    printf 'agent-review (awaiting karen verification):\n%s\n\n'  "$review_list"
    printf 'agent-backlog (waiting on dependencies):\n%s\n\n'     "$backlog_list"

    # Include client questions with their comments so the lead can process answers.
    if [ "${question_total:-0}" -gt 0 ]; then
      printf '## Client questions (agent-question issues)\n\n'
      printf '%s' "$question_json" | jq -r '.[] |
        "### #\(.number) \(.title)\n\n" +
        "Question body:\n\(.body // "(no body)")\n\n" +
        if ((.comments // []) | length) > 0 then
          "Client response(s):\n" +
          ([.comments[] | "- \(.author.login): \(.body)"] | join("\n")) + "\n"
        else
          "(awaiting client response — do not block other work on this)\n"
        end + "\n"' 2>/dev/null || true
    fi

    if [ "$inbox_count" -gt 0 ]; then
      printf '## Inbox (%d item(s))\n\n' "$inbox_count"
      for f in "${fed_items[@]+"${fed_items[@]}"}"; do
        printf '### %s\n\n' "$(basename "$f")"
        cat "$f"
        printf '\n\n'
      done
    else
      printf '## Inbox\n\n(empty — check board state, backlog, and questions above)\n\n'
    fi
  } > "$tmp"

  run_agent lead "$lead_model" "$tmp" "$lead_max_turns" || true
  rm -f "$tmp"

  # Archive inbox items that were fed to the lead on this pass.
  for f in "${fed_items[@]+"${fed_items[@]}"}"; do
    [ -e "$f" ] && mv "$f" "$INBOX/done/" 2>/dev/null || true
  done

  exit 0
fi

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
You are karen, the verifier. Audit the repository for the work claimed in GitHub issue #${iss_num}.

Issue title: ${iss_title}
Issue description:
${iss_body}

Instructions:
1. Establish what was CLAIMED — read the issue body, any referenced artifacts, and task files.
2. Establish what ACTUALLY EXISTS — read source files; run build/tests where possible to prove
   function rather than assume it. Use read-only commands only; do NOT edit source.
3. For each item, decide: PASS (works), FAIL (broken/missing — cite exact evidence), or
   OVER-ENGINEERED (exceeds requirement).
4. Write your complete verdict to state/verdict.txt.
   - The VERY FIRST LINE must be exactly the word PASSED or FAILED (nothing else on that line).
   - Leave a blank line, then list bulleted findings (one per item with evidence).
   - End with a "## Gaps to close" section listing any required remediation (FAIL items only).
5. Return a 2–3 line log summary: counts, overall verdict, and the most critical gap.
PROMPT

  run_agent karen "$karen_model" "$tmp" || true
  rm -f "$tmp"

  # Guard: if karen produced no verdict, cycle back rather than hanging on agent-review.
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

  # Post the verdict as an issue comment regardless of outcome.
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
  # --force-worker <N>: target a specific issue by number
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
  # Normal tick or --force-worker (next): pick the oldest open agent-todo issue.
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

# Atomic label swap — prevents a concurrent tick from claiming the same issue.
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

# keep the activity log bounded
if [ -f "$ACTIVITY" ] && [ "$(wc -l < "$ACTIVITY" | tr -d ' ')" -gt 500 ]; then
  tail -n 500 "$ACTIVITY" > "$ACTIVITY.tmp" && mv "$ACTIVITY.tmp" "$ACTIVITY"
fi
