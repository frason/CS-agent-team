#!/usr/bin/env bash
#
# gh_sync.sh — deterministic bridge between GitHub (the human edge) and the local blackboard.
#
# Called by dispatcher.sh at lead windows when github.enabled is true. It uses only the `gh`
# CLI and file ops — NO model, no tokens. It moves the *human-facing* messages; agent-to-agent
# coordination stays in local files, and PR creation is left to the lead (it writes the summary).
#
#   Inbound : labeled open issues          -> lead-inbox/gh-issue-N.md
#             new client comments on those  -> lead-inbox/answer-N-*.md
#   Outbound: questions/*.md (with issue:N) -> a comment on issue N, then moved to questions/posted/
#
# Resilient by design: any missing tool / auth / network issue just logs and exits 0, so it can
# never break a dispatcher tick.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"; cd "$ROOT"
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }

SCHEDULE="$ROOT/schedule.json"
INBOX="$ROOT/lead-inbox"
Q="$ROOT/questions"
ST="$ROOT/state"
ACT="$ROOT/logs/activity.log"
mkdir -p "$INBOX" "$Q/posted" "$ST" "$ROOT/logs"

TS()  { date +%Y-%m-%dT%H:%M:%S; }
log() { echo "$(TS) gh-sync: $*" >> "$ACT"; }

command -v jq >/dev/null 2>&1 || { log "jq missing; skip"; exit 0; }
[ "$(jq -r '.github.enabled // false' "$SCHEDULE")" = "true" ] || exit 0
command -v gh >/dev/null 2>&1 || { log "gh not installed; skip"; exit 0; }
gh auth status >/dev/null 2>&1 || { log "gh not authenticated; skip"; exit 0; }

REPO=$(jq -r '.github.repo // ""' "$SCHEDULE")
LABEL=$(jq -r '.github.inbox_label // "agent-team"' "$SCHEDULE")
[ -n "$REPO" ] || { log "github.repo not set; skip"; exit 0; }
GHR=(--repo "$REPO")

SEEN="$ST/gh_seen_issues.txt"; touch "$SEEN"
LASTSYNC="$ST/gh_last_sync"
LAST=$(cat "$LASTSYNC" 2>/dev/null || echo "1970-01-01T00:00:00Z")
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# 1) Inbound — new labeled open issues become lead-inbox items (the lead decomposes them).
gh issue list "${GHR[@]}" --label "$LABEL" --state open --json number,title \
   --jq '.[] | "\(.number)\t\(.title)"' 2>/dev/null | while IFS=$'\t' read -r num title; do
  [ -z "${num:-}" ] && continue
  grep -qx "$num" "$SEEN" && continue
  body=$(gh issue view "$num" "${GHR[@]}" --json body --jq '.body' 2>/dev/null || echo "")
  { echo "issue: $num"; echo "# GitHub issue #$num: $title"; echo; echo "$body"; } \
      > "$INBOX/gh-issue-$num.md"
  echo "$num" >> "$SEEN"
  log "pulled issue #$num -> lead-inbox"
done || true

# 2) Outbound — post any unposted question that names an issue, then archive it.
for qf in "$Q"/*.md; do
  [ -e "$qf" ] || continue
  iss=$(grep -i '^issue:' "$qf" | head -1 | sed 's/.*:[[:space:]]*//' | tr -d '[:space:]' 2>/dev/null || true)
  [ -z "${iss:-}" ] && continue
  if gh issue comment "$iss" "${GHR[@]}" --body-file "$qf" >/dev/null 2>&1; then
    mv "$qf" "$Q/posted/" && log "posted question -> issue #$iss"
  else
    log "failed to post question to issue #$iss"
  fi
done

# 3) Inbound — new comments since last sync on tracked issues become "answer:" items.
while IFS= read -r num; do
  [ -z "${num:-}" ] && continue
  new=$(gh issue view "$num" "${GHR[@]}" --json comments --jq '.comments' 2>/dev/null \
        | jq -r --arg last "$LAST" \
            '[.[] | select(.createdAt > $last) | "From \(.author.login) at \(.createdAt):\n\(.body)\n---"] | join("\n")' \
            2>/dev/null || true)
  if [ -n "${new:-}" ] && [ "$new" != "null" ]; then
    out="$INBOX/answer-$num-$(date +%s).md"
    { echo "issue: $num"; echo "# answer: new comment(s) on issue #$num"; echo; echo "$new"; } > "$out"
    log "pulled new comment(s) on issue #$num -> lead-inbox"
  fi
done < "$SEEN"

echo "$NOW" > "$LASTSYNC"
exit 0
