#!/usr/bin/env bash
#
# setup.sh — interactive one-shot installer for the agent team.
#
# Automates the "Manual" checklist from the README: scaffolds the runtime tree,
# copies the asset templates into place, checks dependencies (jq, claude), seeds
# .env, and offers to append the cron heartbeat line.
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

# 1) Runtime directory tree (the same set the dispatcher creates on each tick).
mkdir -p "$ROOT/state" "$ROOT/logs" "$ROOT/artifacts" \
         "$ROOT/queue/todo" "$ROOT/queue/doing" "$ROOT/queue/done" \
         "$ROOT/queue/review" "$ROOT/queue/backlog" \
         "$ROOT/lead-inbox/done" "$ROOT/questions/answered" \
         "$ROOT/.claude/agents"
say "✓ runtime directories"

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
else
  say "  ! assets/ not found next to scripts/ — skipping template copy"
fi

# 3) Make the scripts executable.
chmod +x "$SCRIPT_DIR"/*.sh 2>/dev/null || true
say "✓ scripts executable"
say

# 4) Dependencies.
if command -v jq >/dev/null 2>&1; then
  say "✓ jq: $(command -v jq)"
else
  say "✗ jq not found."
  if command -v brew >/dev/null 2>&1 && ask "Install jq with Homebrew now?" y; then
    brew install jq && say "✓ jq installed"
  else
    say "  Install jq manually (e.g. 'brew install jq'), then re-run."
  fi
fi

CLAUDE_BIN="$(command -v claude || true)"
if [ -n "$CLAUDE_BIN" ]; then
  say "✓ claude: $CLAUDE_BIN"
else
  say "✗ claude CLI not found in PATH. Install it, then re-run."
fi
say

# 5) .env — PATH + OAuth token so cron (a bare environment) can run on your subscription.
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

# 6) Cron heartbeat line — show it, append idempotently on request.
mins=$(jq -r '.tick_minutes // 10' "$ROOT/schedule.json" 2>/dev/null || echo 10)
CRON_LINE="*/$mins * * * * $SCRIPT_DIR/dispatcher.sh >> $ROOT/logs/dispatcher.log 2>&1"
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
say "  $SCRIPT_DIR/dispatcher.sh"
