#!/usr/bin/env bash
#
# dispatcher.sh — fixed cron "heartbeat" for the PM / lead / worker agent team.
#
# Add ONE line to your crontab (use absolute paths):
#   */10 * * * * /ABS/PATH/<project>/scripts/dispatcher.sh >> /ABS/PATH/<project>/logs/dispatcher.log 2>&1
#
# The heartbeat never changes. All policy lives in schedule.json, which the PM edits.
# Each tick runs AT MOST ONE thing: a lead pass (only in its windows, only if the
# lead-inbox has work, and only if the lead isn't paused) OR one worker lane
# (round-robin, cooldown-aware, skipping paused lanes). Never both, never two at once.
#
# Portable across macOS (bash 3.2, no flock, BSD date/grep) and Linux.

set -euo pipefail

# ---- locate project root (this script lives in <root>/scripts) ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

# ---- load environment for cron (PATH + subscription OAuth token) ----
# cron runs with a minimal environment, so put PATH and CLAUDE_CODE_OAUTH_TOKEN
# in <root>/.env (see env.example). This keeps you on your subscription, not API.
if [ -f "$ROOT/.env" ]; then set -a; . "$ROOT/.env"; set +a; fi

SCHEDULE="$ROOT/schedule.json"
STATUS="$ROOT/state/STATUS.md"
LANES_STATE="$ROOT/state/lanes.json"
USAGE="$ROOT/logs/usage.jsonl"
ACTIVITY="$ROOT/logs/activity.log"
TODO="$ROOT/queue/todo"
DOING="$ROOT/queue/doing"
DONE="$ROOT/queue/done"
INBOX="$ROOT/lead-inbox"
QUESTIONS="$ROOT/questions"
REVIEW="$ROOT/queue/review"
BACKLOG="$ROOT/queue/backlog"
LOCKDIR="$ROOT/.dispatcher.lock.d"

mkdir -p "$ROOT/state" "$ROOT/logs" "$ROOT/artifacts" "$TODO" "$DOING" "$DONE" "$REVIEW" "$BACKLOG" \
         "$INBOX/done" "$QUESTIONS/answered"
[ -f "$LANES_STATE" ] || echo '{}' > "$LANES_STATE"

TS()  { date +%Y-%m-%dT%H:%M:%S; }
log() { echo "$(TS) $*" >> "$ACTIVITY"; echo "$(TS) $*"; }

command -v jq     >/dev/null 2>&1 || { echo "$(TS) ERROR: jq not found in PATH"; exit 1; }
command -v claude >/dev/null 2>&1 || { echo "$(TS) ERROR: claude CLI not in PATH (set PATH in .env)"; exit 1; }

# ---- single-flight lock (portable: atomic mkdir; auto-clears stale locks >25m) ----
if [ -d "$LOCKDIR" ] && [ -n "$(find "$LOCKDIR" -maxdepth 0 -mmin +25 2>/dev/null)" ]; then
  rmdir "$LOCKDIR" 2>/dev/null || true
fi
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  echo "$(TS) previous tick still running; skipping"; exit 0
fi
trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT INT TERM

now_epoch=$(date +%s)
minute=$(( 10#$(date +%M) ))   # force base-10 so "08"/"09" don't read as octal
hour=$((   10#$(date +%H) ))

# ---- read policy from schedule.json ----
[ "$(jq -r '.paused // false' "$SCHEDULE")" = "true" ] && { log "globally paused — nothing to do"; exit 0; }

ah_start=$(jq -r '.active_hours.start // 0'  "$SCHEDULE")
ah_end=$(  jq -r '.active_hours.end   // 24' "$SCHEDULE")
if (( hour < ah_start || hour >= ah_end )); then
  echo "$(TS) outside active hours (${ah_start}-${ah_end}); skipping"; exit 0
fi

cooldown=$(    jq -r '.lane_cooldown_min      // 30'       "$SCHEDULE")
worker_model=$(jq -r '.worker_model           // "haiku"'  "$SCHEDULE")
lead_model=$(  jq -r '.lead_model             // "sonnet"' "$SCHEDULE")
lead_paused=$( jq -r '.lead_paused            // false'    "$SCHEDULE")
karen_model=$( jq -r '.karen_model            // "sonnet"' "$SCHEDULE")
require_verify=$(jq -r '.require_verification  // false'   "$SCHEDULE")
gh_enabled=$(  jq -r '.github.enabled         // false'    "$SCHEDULE")
max_turns=$(   jq -r '.max_turns              // 25'       "$SCHEDULE")
soft_budget=$( jq -r '.soft_budget_usd_per_5h // 0'        "$SCHEDULE")
auto_accept=$( jq -r '.auto_accept_low_risk   // false'    "$SCHEDULE")
pd_enabled=$(  jq -r '.pre_dispatch.enabled   // false'    "$SCHEDULE")
pd_timeout=$(  jq -r '.pre_dispatch.timeout_sec // 10'     "$SCHEDULE")
pd_maxbytes=$( jq -r '.pre_dispatch.max_bytes // 4096'     "$SCHEDULE")

# ---- soft self-throttle: heuristic cap on spend in the trailing 5h window ----
# A proxy for your subscription's rolling 5-hour limit. Set to 0 to disable.
if [ -f "$USAGE" ] && [ "$soft_budget" != "0" ]; then
  cutoff=$(( now_epoch - 5*3600 ))
  spent=$(jq -s --argjson c "$cutoff" '[ .[] | select(.ts >= $c) | .cost ] | add // 0' "$USAGE" 2>/dev/null || echo 0)
  if [ "$(jq -n --argjson s "$spent" --argjson b "$soft_budget" '$s >= $b')" = "true" ]; then
    log "throttled: \$$spent in last 5h >= soft budget \$$soft_budget"; exit 0
  fi
fi

# ---- helper: run a claude agent headless, log cost + a snippet of its result ----
run_agent() {  # $1 = agent name, $2 = model, $3 = prompt file
  local agent="$1" model="$2" pf="$3" out cost result_text
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
  # surface the agent's summary / any blocker so the lead + PM can see it
  result_text=$(echo "$out" | jq -r '.result // .text // ""' 2>/dev/null | tr '\n' ' ' | cut -c1-240 || true)
  [ -n "$result_text" ] && log "  > $agent: $result_text"
  return 0
}

# ---- portable timeout wrapper (coreutils `timeout`/`gtimeout` if present, else none) ----
run_limited() {  # $1 = seconds, rest = command + args
  local s="$1"; shift
  if   command -v timeout  >/dev/null 2>&1; then timeout  "$s" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$s" "$@"
  else "$@"; fi
}

# ---- speculative pre-dispatch: run a task's read-only `pre_dispatch_cmd:` and inject its ----
# ---- output into the task file, so the worker boots with targeted context (token-free). ----
# Safety: this executes an LLM-authored shell string unattended, so it is opt-in and tightly
# constrained — no shell metacharacters, leading command must be on a read-only allowlist,
# bounded by a timeout and an output cap. It NEVER runs anything that can mutate state.
pre_dispatch() {  # $1 = claimed task file
  local f="$1" cmd first second out
  cmd=$(grep -i '^pre_dispatch_cmd:' "$f" | head -1 | sed 's/^[^:]*:[[:space:]]*//' || true)
  [ -z "$cmd" ] && return 0
  # Reject anything that could chain, redirect, substitute, or span lines.
  case "$cmd" in
    *';'*|*'|'*|*'&'*|*'>'*|*'<'*|*'`'*|*'$('*|*'${'*|*$'\n'*)
      log "  pre-dispatch: rejected (shell metacharacters): $cmd"; return 0 ;;
  esac
  first=$(printf '%s' "$cmd"  | awk '{print $1}')
  second=$(printf '%s' "$cmd" | awk '{print $2}')
  case "$first" in
    grep|rg|find|ls|tree|cat|head|wc) : ;;
    sed) [ "$second" = "-n" ] || { log "  pre-dispatch: sed allowed only with -n: $cmd"; return 0; } ;;
    git) case "$second" in ls-files|grep) : ;; *) log "  pre-dispatch: git allowed only for ls-files/grep: $cmd"; return 0 ;; esac ;;
    *)   log "  pre-dispatch: '$first' not in read-only allowlist: $cmd"; return 0 ;;
  esac
  # No metacharacters remain, so unquoted word-splitting is safe (globs expand against ROOT).
  out=$(run_limited "$pd_timeout" $cmd 2>/dev/null | head -c "$pd_maxbytes" || true)
  if [ -n "$out" ]; then
    { echo; echo "## Pre-dispatch context (\`$cmd\`)"; echo '```'; printf '%s\n' "$out"; echo '```'; } >> "$f"
    log "  pre-dispatch: injected $(printf '%s' "$out" | wc -c | tr -d ' ') bytes from: $cmd"
  fi
}

# ---- promote backlog tasks whose dependencies are all complete (deterministic, no LLM) ----
# A backlog task with "depends_on: [id, ...]" moves to todo/ once every listed id appears as
# a completed task in done/. Tasks with no deps promote immediately. This is pure file-check
# bookkeeping — it runs every tick, costs nothing, and never starts an agent itself.
if [ -d "$BACKLOG" ]; then
  done_ids=$(grep -rhiE '^id:' "$DONE" --include='*.md' 2>/dev/null | sed 's/^[^:]*:[[:space:]]*//' | tr -d '[:space:]' | sort -u || true)
  for bt in "$BACKLOG"/*.md; do
    [ -e "$bt" ] || continue
    deps=$(grep -i '^depends_on:' "$bt" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '[]' | tr ',' ' ' || true)
    blocked=false
    for d in $deps; do
      d=$(echo "$d" | tr -d '[:space:]'); [ -z "$d" ] && continue
      echo "$done_ids" | grep -qx "$d" || { blocked=true; break; }
    done
    if [ "$blocked" = "false" ]; then
      mv "$bt" "$TODO/" && log "promoted $(basename "$bt") (dependencies satisfied)"
    fi
  done
fi

# ============================================================
#  Decide the ONE thing to do this tick
# ============================================================

# 1) Lead — runs in its windows (not paused) if the inbox has work OR tasks await verification.
is_window=$(jq -r --argjson m "$minute" '((.lead_windows // [0,30]) | index($m)) != null' "$SCHEDULE")

# GitHub edge: at lead windows, sync issues/comments in and questions out (deterministic, gated, token-free)
if [ "$gh_enabled" = "true" ] && [ "$is_window" = "true" ]; then
  bash "$SCRIPT_DIR/gh_sync.sh" || log "gh-sync failed (see logs/dispatcher.log)"
fi

inbox_count=$(find "$INBOX" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
review_count=$(find "$REVIEW" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')

if [ "$is_window" = "true" ] && [ "$lead_paused" != "true" ] && { [ "$inbox_count" -gt 0 ] || [ "$review_count" -gt 0 ]; }; then
  tmp=$(mktemp)
  {
    echo "You are the lead. Handle the work below."
    echo
    echo "INBOX ($inbox_count item(s)): New requests -> break each into small, well-scoped"
    echo "task files in queue/todo/ (use the task template). Items titled 'answer:' are the"
    echo "client's answers to your questions -> use them to unblock tasks. A 'verify request'"
    echo "item -> queue a karen verification task (agent: karen, model: sonnet) in the verify"
    echo "lane for the work named. Move each handled item to lead-inbox/done/."
    echo
    echo "REVIEW ($review_count task(s) in queue/review/ awaiting verification — only used when"
    echo "require_verification is on): for each not yet judged by karen, queue a karen verify"
    echo "task. When karen's verdict is PASS, move the task file to queue/done/. When it is FAIL,"
    echo "create a small fix task in queue/todo/ and move the reviewed file to queue/done/."
    echo
    echo "Also read karen's verdicts in artifacts/ (verify-*.md) and recent worker summaries in"
    echo "logs/activity.log; for any FAIL or blocker, create honest fix tasks (match requirements"
    echo "exactly, no over-engineering). If something needs the client to decide, write a question"
    echo "into questions/ rather than guessing. Finally, update state/STATUS.md (claimed vs verified)."
    echo
    for f in "$INBOX"/*.md; do
      [ -e "$f" ] || continue
      echo "----- inbox item: $(basename "$f") -----"
      cat "$f"; echo
    done
  } > "$tmp"
  log "lead pass: inbox=$inbox_count review=$review_count"
  run_agent lead "$lead_model" "$tmp" || true
  rm -f "$tmp"
  exit 0
fi

# 2) Otherwise — run the next eligible worker lane.
#    Choose the lane that (a) isn't paused, (b) has a pending task, (c) is past its
#    cooldown, and (d) has waited the longest (oldest last-run). One lane per tick.
best_lane=""; best_task=""; best_last="$now_epoch"
while IFS= read -r lane; do
  [ -z "$lane" ] && continue
  is_paused_lane=$(jq -r --arg l "$lane" '((.paused_lanes // []) | index($l)) != null' "$SCHEDULE")
  [ "$is_paused_lane" = "true" ] && continue
  task=$(grep -rilE "^lane:[[:space:]]*${lane}[[:space:]]*$" --include='*.md' "$TODO" 2>/dev/null | sort | head -1 || true)
  [ -z "$task" ] && continue
  last=$(jq -r --arg l "$lane" '.[$l] // 0' "$LANES_STATE")
  (( now_epoch - last < cooldown * 60 )) && continue
  if (( last <= best_last )); then best_last="$last"; best_lane="$lane"; best_task="$task"; fi
done < <(jq -r '.lanes[]' "$SCHEDULE")

if [ -z "$best_lane" ]; then
  echo "$(TS) nothing eligible (idle, paused, or all lanes cooling down)"; exit 0
fi

# claim the task so a later tick can't grab it too
claimed="$DOING/$(basename "$best_task")"
mv "$best_task" "$claimed"

# speculative pre-dispatch: inject targeted context before the worker boots (token-free, gated)
[ "$pd_enabled" = "true" ] && pre_dispatch "$claimed"

# which agent runs this task (default "worker"; verify tasks set "agent: karen")
task_agent=$(grep -i '^agent:' "$claimed" | head -1 | sed 's/.*:[[:space:]]*//' | tr -d '[:space:]' || true)
[ -z "$task_agent" ] && task_agent="worker"

# model: explicit on the task, otherwise the default for that agent
task_model=$(grep -i '^model:' "$claimed" | head -1 | sed 's/.*:[[:space:]]*//' | tr -d '[:space:]' || true)
if [ -z "$task_model" ]; then
  case "$task_agent" in
    worker) task_model="$worker_model" ;;
    karen)  task_model="$karen_model" ;;
    *)      task_model="$lead_model" ;;
  esac
fi

log "run lane=$best_lane agent=$task_agent task=$(basename "$claimed")"
if run_agent "$task_agent" "$task_model" "$claimed"; then
  # finished worker output awaits verification when require_verification is on;
  # karen audits and everything else go straight to done.
  if [ "$require_verify" = "true" ] && [ "$task_agent" = "worker" ]; then
    # auto-accept: mechanical lane-based check — skip karen for provably read-only lanes
    # (docs). Risk field on the task is checked too, but lane membership is the real gate
    # so a mislabeled "risk: low" on functional code can't silently bypass verification.
    task_risk=$(grep -i '^risk:' "$claimed" | head -1 | sed 's/.*:[[:space:]]*//' | tr -d '[:space:]' || true)
    auto_accept_lanes=$(jq -r '(.auto_accept_low_risk_lanes // ["docs"]) | join(" ")' "$SCHEDULE")
    lane_is_safe=false
    for _l in $auto_accept_lanes; do
      [ "$_l" = "$best_lane" ] && { lane_is_safe=true; break; }
    done
    if [ "$auto_accept" = "true" ] && [ "$task_risk" = "low" ] && [ "$lane_is_safe" = "true" ]; then
      mv "$claimed" "$DONE/" && log "auto-accepted (risk=low, lane=$best_lane)"
    else
      mv "$claimed" "$REVIEW/"
    fi
  else
    mv "$claimed" "$DONE/"
  fi
else
  mv "$claimed" "$TODO/"   # put it back to retry next tick
fi

# stamp this lane's last-run time
jq --arg l "$best_lane" --argjson t "$now_epoch" '.[$l] = $t' "$LANES_STATE" > "$LANES_STATE.tmp" \
  && mv "$LANES_STATE.tmp" "$LANES_STATE"

# keep the activity log bounded
if [ -f "$ACTIVITY" ] && [ "$(wc -l < "$ACTIVITY" | tr -d ' ')" -gt 500 ]; then
  tail -n 500 "$ACTIVITY" > "$ACTIVITY.tmp" && mv "$ACTIVITY.tmp" "$ACTIVITY"
fi
