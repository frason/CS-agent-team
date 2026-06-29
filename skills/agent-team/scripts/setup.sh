#!/usr/bin/env bash
#
# setup.sh — interactive one-shot installer for the agent team.
#
# Automates the setup checklist from the README: scaffolds the runtime tree,
# copies the asset templates into place, checks dependencies (jq, gh, claude),
# seeds .env, creates the required GitHub labels, and offers to install the cron
# heartbeat.
#
# Safe to re-run: it never clobbers an existing schedule.json / .env / agent file,
# and it won't add a second crontab entry if the dispatcher is already scheduled.
#
# Run from the skill directory:  ./scripts/setup.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"; cd "$ROOT"
ASSETS="$ROOT/assets"

say() { printf '%s\n' "$*"; }
ask() {  # $1 = prompt, $2 = default (y|n); returns 0 for yes
  local p="$1" d="${2:-y}" a
  printf '%s [%s] ' "$p" "$d"
  read -r a || a=""
  case "${a:-$d}" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

say "== Agent Team setup =="
say "Project root: $ROOT"
say

# 1) Runtime directory tree.
mkdir -p "$ROOT/state" "$ROOT/logs" "$ROOT/.claude/agents" "$ROOT/lead-inbox/done"
say "✓ runtime directories (state/, logs/, lead-inbox/done/, .claude/agents/)"

# 2) Copy asset templates into place — never clobber a customized file.
copy_once() {  # $1 = src, $2 = dest
  [ -f "$1" ] || { say "  ! missing template: $1"; return; }
  if [ -e "$2" ]; then say "  · kept existing $(basename "$2")"; return; fi
  mkdir -p "$(dirname "$2")"; cp "$1" "$2"; say "  + $(basename "$2")"
}
if [ -d "$ASSETS" ]; then
  copy_once "$ASSETS/schedule.json" "$ROOT/schedule.json"
  copy_once "$ASSETS/SPEC.md"       "$ROOT/SPEC.md"
  copy_once "$ASSETS/STATUS.md"     "$ROOT/state/STATUS.md"
  copy_once "$ASSETS/settings.json" "$ROOT/.claude/settings.json"
  if [ -d "$ASSETS/agents" ]; then
    for a in "$ASSETS/agents"/*.md; do
      [ -e "$a" ] || continue
      copy_once "$a" "$ROOT/.claude/agents/$(basename "$a")"
    done
  fi
  # Copy GitHub Issue Form template (enables structured task submission from the GitHub UI).
  if [ -d "$ASSETS/.github/ISSUE_TEMPLATE" ]; then
    mkdir -p "$ROOT/.github/ISSUE_TEMPLATE"
    for t in "$ASSETS/.github/ISSUE_TEMPLATE"/*; do
      [ -e "$t" ] || continue
      copy_once "$t" "$ROOT/.github/ISSUE_TEMPLATE/$(basename "$t")"
    done
  fi
else
  say "  ! assets/ not found next to scripts/ — skipping template copy"
fi

# 3) Make the scripts executable.
chmod +x "$SCRIPT_DIR"/*.sh 2>/dev/null || true
say "✓ scripts executable"
say

# 4) Dependencies.
missing_deps=false

if command -v jq >/dev/null 2>&1; then
  say "✓ jq: $(command -v jq)"
else
  missing_deps=true
  say "✗ jq not found."
  if command -v brew >/dev/null 2>&1 && ask "Install jq with Homebrew now?" y; then
    brew install jq && say "✓ jq installed"
  else
    say "  Install jq manually (e.g. 'brew install jq'), then re-run."
  fi
fi

if command -v gh >/dev/null 2>&1; then
  say "✓ gh: $(command -v gh)"
  if gh auth status >/dev/null 2>&1; then
    say "✓ gh authenticated"
  else
    say "✗ gh is installed but not authenticated."
    say "  Run 'gh auth login', then re-run this script."
    missing_deps=true
  fi
else
  missing_deps=true
  say "✗ gh CLI not found. Install from https://cli.github.com, then re-run."
fi

CLAUDE_BIN="$(command -v claude || true)"
if [ -n "$CLAUDE_BIN" ]; then
  say "✓ claude: $CLAUDE_BIN"
else
  say "✗ claude CLI not found in PATH. Install it, then re-run."
  missing_deps=true
fi
say

# 5) .env — PATH + OAuth token so cron (a bare environment) can find claude/gh.
if [ -f "$ROOT/.env" ]; then
  say "· kept existing .env"
else
  [ -f "$ASSETS/env.example" ] && cp "$ASSETS/env.example" "$ROOT/.env"
  printf 'PATH=%s\n' "$PATH" >> "$ROOT/.env"
  say "+ wrote .env (PATH seeded for cron)"
  if [ -n "$CLAUDE_BIN" ] && ask "Run 'claude setup-token' now to authenticate cron to your subscription?" y; then
    tok="$("$CLAUDE_BIN" setup-token 2>/dev/null | tail -1 || true)"
    if [ -n "$tok" ]; then
      printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$tok" >> "$ROOT/.env"
      say "+ token written to .env"
    else
      say "  ! couldn't capture a token automatically — paste it into"
      say "    CLAUDE_CODE_OAUTH_TOKEN in $ROOT/.env by hand."
    fi
  fi
fi
say

# 6) GitHub repository configuration.
REPO=$(jq -r '.github.repo // ""' "$ROOT/schedule.json" 2>/dev/null || true)
if [ -z "$REPO" ]; then
  say "⚠ github.repo is not set in schedule.json."
  say "  Edit schedule.json and set: \"github\": { \"repo\": \"owner/repo\" }"
  say "  Then re-run this script (or run scripts/setup-labels.sh directly)."
  say
else
  say "GitHub repo: $REPO"
  if [ "$missing_deps" = "false" ] && ask "Create/update the agent-team labels on $REPO now?" y; then
    bash "$SCRIPT_DIR/setup-labels.sh"
  else
    say "  Skipped. Run 'bash scripts/setup-labels.sh' after setting github.repo."
  fi
  say
  if [ "$missing_deps" = "false" ] && ask "Create a GitHub Projects v2 board for cross-repo visibility? (optional)" n; then
    bash "$SCRIPT_DIR/setup-project.sh"
  else
    say "  Skipped. Run 'bash scripts/setup-project.sh' later if you want a project board."
  fi
  say
fi

# 7) Cron heartbeat line — show it, append idempotently on request.
CRON_LINE="*/10 * * * * $SCRIPT_DIR/dispatcher.sh >> $ROOT/logs/dispatcher.log 2>&1"
say "Cron heartbeat line:"
say "  $CRON_LINE"
if crontab -l 2>/dev/null | grep -Fq "$SCRIPT_DIR/dispatcher.sh"; then
  say "· dispatcher already in your crontab — leaving it untouched"
elif ask "Append this line to your crontab now?" n; then
  ( crontab -l 2>/dev/null; echo "$CRON_LINE" ) | crontab - \
    && say "✓ crontab updated"
else
  say "  Skipped. Add it later with 'crontab -e'."
  say "  (macOS: cron needs Full Disk Access to run from this directory —"
  say "   System Settings → Privacy & Security → Full Disk Access → add /usr/sbin/cron.)"
fi
say
say "Done. Test one tick by hand:"
say "  Lead pass:   $SCRIPT_DIR/dispatcher.sh --force-lead"
say "  Worker pass: $SCRIPT_DIR/dispatcher.sh --force-worker"
