#!/usr/bin/env bash
#
# setup-labels.sh — one-time workspace initialization for the GitHub Issues-backed agent team.
#
# Run this once from your project root before starting the dispatcher:
#   bash scripts/setup-labels.sh
#
# What it does:
#   1. Creates local state/ and logs/ directories.
#   2. Creates (or updates) the four agent-team GitHub labels on the configured repo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }

# ---- preflight ----
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found"; exit 1; }
command -v gh  >/dev/null 2>&1 || { echo "ERROR: gh CLI not found — install from https://cli.github.com"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: gh not authenticated — run 'gh auth login'"; exit 1; }
[ -f "$ROOT/schedule.json" ]   || { echo "ERROR: schedule.json not found at $ROOT/schedule.json"; exit 1; }

REPO=$(jq -r '.github.repo // ""' "$ROOT/schedule.json")
[ -n "$REPO" ] || {
  echo "ERROR: github.repo is not set in schedule.json."
  echo "       Edit schedule.json and set: \"github\": { \"repo\": \"owner/repo\" }"
  exit 1
}

echo "Workspace: $ROOT"
echo "Repo:      $REPO"
echo

# ---- 1. local directories ----
mkdir -p "$ROOT/state" "$ROOT/logs" "$ROOT/lead-inbox/done"
echo "✓  state/, logs/, and lead-inbox/done/ directories ready"

# ---- 2. GitHub labels ----
# Colors: Orange, Blue, Yellow, Green, Grey (GitHub hex, no leading #)
create_label() {  # $1=name  $2=hex-color  $3=description
  local name="$1" color="$2" desc="$3"
  if gh label create "$name" --repo "$REPO" \
       --color "$color" --description "$desc" --force >/dev/null 2>&1; then
    printf "✓  label '%-15s' created/updated\n" "$name"
  else
    printf "⚠  label '%-15s' could not be created — check manually on GitHub\n" "$name"
  fi
}

create_label "agent-todo"     "E4692A" "Work queued and waiting for the dispatcher"
create_label "agent-doing"    "1D76DB" "Dispatcher claimed this issue (in-flight)"
create_label "agent-review"   "F5C518" "Worker done; awaiting karen verification"
create_label "agent-done"     "0E8A16" "Karen passed; issue closed"
create_label "agent-backlog"  "AAAAAA" "Sequenced task waiting on dependencies"
create_label "agent-triage"   "BFD4F2" "User-entered issue awaiting lead triage"
create_label "agent-question" "8B5CF6" "Lead needs client input before proceeding"

echo
echo "All done. Next steps:"
echo
echo "  1. Verify schedule.json has github.repo set to \"$REPO\""
echo "  2. Authenticate cron to your Claude subscription:"
echo "       claude setup-token"
echo "       cp assets/env.example .env  # then paste token + PATH"
echo "  3. Install the cron heartbeat (crontab -e):"
echo "       */10 * * * * $ROOT/scripts/dispatcher.sh >> $ROOT/logs/dispatcher.log 2>&1"
echo "  4. Drop a goal file into lead-inbox/ to kick off the lead, or create a GitHub Issue"
echo "     in $REPO with the 'agent-todo' label for manual task entry."
echo "     Test the lead right now:   $ROOT/scripts/dispatcher.sh --force-lead"
echo "     Test a worker right now:   $ROOT/scripts/dispatcher.sh --force-worker"
