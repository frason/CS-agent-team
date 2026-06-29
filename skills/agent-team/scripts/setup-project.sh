#!/usr/bin/env bash
#
# setup-project.sh — Create a GitHub Projects v2 board for the agent team.
#
# Run once from the project root after setup-labels.sh:
#   bash scripts/setup-project.sh
#
# What it does:
#   1. Creates a GitHub Projects v2 board owned by the repo's owner.
#   2. Adds a Priority custom field (single-select: urgent / high / normal / low).
#   3. Saves the project number to schedule.json (github.project_number).
#
# After this runs, the lead will automatically add new issues to the project board.
# View the board: gh project view <number> --owner <owner> --web

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found"; exit 1; }
command -v gh >/dev/null 2>&1  || { echo "ERROR: gh CLI not found"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: gh not authenticated — run 'gh auth login'"; exit 1; }
[ -f "$ROOT/schedule.json" ]   || { echo "ERROR: schedule.json not found"; exit 1; }

REPO=$(jq -r '.github.repo // ""' "$ROOT/schedule.json")
[ -n "$REPO" ] || { echo "ERROR: github.repo not set in schedule.json"; exit 1; }

OWNER=$(echo "$REPO" | cut -d'/' -f1)
REPONAME=$(echo "$REPO" | cut -d'/' -f2)
TITLE="Agent Team — $REPONAME"

echo "Owner:   $OWNER"
echo "Repo:    $REPO"
echo "Board:   $TITLE"
echo

# Check if a project with this name already exists.
existing=$(gh project list --owner "$OWNER" --format json \
  --jq ".projects[] | select(.title == \"$TITLE\") | .number" 2>/dev/null | head -1 || true)

if [ -n "${existing:-}" ]; then
  echo "Project '$TITLE' already exists as #$existing — skipping creation."
  PROJECT_NUM="$existing"
else
  echo "Creating project..."
  PROJECT_NUM=$(gh project create --owner "$OWNER" --title "$TITLE" --format json \
    --jq '.number' 2>/dev/null)
  echo "✓  project #$PROJECT_NUM created"

  # Add a Priority single-select field.
  gh project field-create "$PROJECT_NUM" --owner "$OWNER" \
    --name "Priority" --data-type "SINGLE_SELECT" \
    --single-select-options "urgent,high,normal,low" >/dev/null 2>&1 \
    && echo "✓  Priority field added" \
    || echo "·  Could not add Priority field — add it manually in the GitHub UI"
fi

# Save project number to schedule.json.
tmp=$(mktemp)
jq --argjson n "$PROJECT_NUM" '.github.project_number = $n' \
  "$ROOT/schedule.json" > "$tmp" && mv "$tmp" "$ROOT/schedule.json"
echo "✓  project_number $PROJECT_NUM saved to schedule.json"

echo
echo "Board URL: https://github.com/users/$OWNER/projects/$PROJECT_NUM"
echo "(For org repos: https://github.com/orgs/$OWNER/projects/$PROJECT_NUM)"
echo
echo "Next steps:"
echo "  • Open the board URL above and customise columns/views if desired."
echo "  • The lead will now add new issues to this project automatically."
echo "  • Run 'bash scripts/dispatcher.sh --force-lead' to trigger the lead now."
