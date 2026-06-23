# Agent Team

**A background "agent team" for Claude Code that gets work done on your subscription without burning through your 5-hour usage limit.**

Create GitHub Issues for what you want done. A fixed cron "heartbeat" runs worker agents one at a time on a stagger — so something is almost always progressing, but never all at once. A verifier (*karen*) checks that work marked done actually works, posting its verdict as an issue comment and closing the issue on pass.

---

## Why this exists

Heavy sub-agent use in Claude Code can burn your rolling 5-hour usage window in one sitting and lock you out for hours. Agent Team spreads bounded work across that window at a sustainable rate, so you stay under the cap and always have capacity for interactive work.

The principle throughout is **token frugality + steady pacing**: cheap models for bulk work, expensive reasoning gated, and never more than one agent running at once.

## How it works

- Tasks live as **GitHub Issues** labelled `agent-todo`. You create the issues; the dispatcher claims them.
- A single **cron heartbeat** runs `dispatcher.sh` every ~10 minutes. It never changes.
- Each tick does **at most one thing** — karen verification first if pending, otherwise one worker run. Never concurrent.
- All policy lives in **`schedule.json`** (no LLM touches crontab).
- **Labels carry state**:

```
agent-todo    → queued, not yet claimed
agent-doing   → dispatcher claimed it (prevents double-dispatch)
agent-review  → worker done; awaiting karen verification
agent-done    → karen passed; issue closed
```

```
You ─ create GitHub Issues ─▶ label: agent-todo
                                      │
cron ─ every 10m ─▶ dispatcher ───────┤ claims oldest agent-todo → agent-doing
                         │            │ runs worker → posts summary comment → agent-review
                         │            │ runs karen  → posts verdict comment
                         │            │   PASSED → agent-done, issue closed
                         └────────────┘   FAILED → agent-todo, worker retries
                    logs/usage.jsonl  (cost per run)
                    state/STATUS.md   (rolling 5h spend meter)
```

## Roles

| Role | Runs | Model | Job |
|------|------|-------|-----|
| **Worker** | scheduled, staggered | Haiku | Execute one issue's task; write summary to `state/worker_output.txt`. |
| **Karen** | scheduled, gated | Sonnet | Independently verify finished work; write verdict to `state/verdict.txt`; never edits source. |

---

## Requirements

- **Claude Code** with a Pro or Max subscription (runs on your subscription, not the API)
- **jq** (`brew install jq`)
- **GitHub CLI (`gh`)** — required (`brew install gh`, then `gh auth login`)
- **macOS or Linux** — portable bash 3.2, no GNU-only tools

## Install

This repo is a Claude Code plugin marketplace whose one plugin bundles the `agent-team` skill. Pick one path:

### As a Claude Code plugin (recommended)
In Claude Code:
```
/plugin marketplace add frason/CS-agent-team
/plugin install agent-team@cs-agent-team
```
Then, in the project you want worked on, ask Claude to **"set up the agent team."** The skill scaffolds the directories, copies the scripts, and installs the `worker`/`karen` agents into `.claude/agents/`. Update later with `/plugin marketplace update cs-agent-team`.

### As a bare skill
Copy the skill folder — `skills/agent-team/` → `~/.claude/skills/agent-team/` (personal) or `<project>/.claude/skills/agent-team/`. Then ask Claude to "set up the agent team" as above.

### Scripted (fastest)
From inside `skills/agent-team/`, run the interactive installer:
```bash
./scripts/setup.sh
```
It scaffolds directories, copies asset templates (without clobbering anything you've customized), checks dependencies, seeds `.env`, creates the GitHub labels, and offers to append the cron heartbeat. Re-running is safe.

### Manual
The skill files live under `skills/agent-team/`. Run these from that folder:

1. Scaffold runtime dirs:
   ```bash
   mkdir -p scripts state logs .claude/agents
   ```
2. Copy files into place: `scripts/*` → `scripts/`; `assets/schedule.json` → project root; `assets/STATUS.md` → `state/`; `assets/settings.json` → `.claude/settings.json`; `assets/agents/worker.md` and `assets/agents/karen.md` → `.claude/agents/`.
3. `chmod +x scripts/*.sh`
4. Set `github.repo` in `schedule.json` (e.g. `"repo": "owner/repo"`), then run `scripts/setup-labels.sh` to create the four labels on GitHub.
5. Authenticate cron to your subscription: `claude setup-token`, copy `assets/env.example` → `.env`, paste the token into `CLAUDE_CODE_OAUTH_TOKEN`, and set `PATH`.
6. Add the heartbeat to cron (`crontab -e`), with absolute paths:
   ```
   */10 * * * * /ABS/PATH/scripts/dispatcher.sh >> /ABS/PATH/logs/dispatcher.log 2>&1
   ```
7. Test once by hand: `./scripts/dispatcher.sh --force-worker`, then check `logs/dispatcher.log`.

## Using it

- **Queue work** — create a GitHub Issue on the configured repo and add the `agent-todo` label.
- **Check status** — watch issue labels and comments on GitHub. The dispatcher posts the worker summary and karen's verdict as comments before advancing the label.
- **Force a run now** — `scripts/dispatcher.sh --force-worker` (or `--force-worker <N>` for a specific issue). Bypasses `active_hours` and the soft budget throttle.
- **Pause everything** — set `"paused": true` in `schedule.json`.
- **Watch spend** — `state/STATUS.md` shows a live 5h spend bar when `telemetry.show_rolling_budget_in_status` is true.

---

## Configuration (`schedule.json`)

| Field | Meaning |
|------|---------|
| `paused` | `true` halts all runs immediately. |
| `worker_model` | Model for workers (default `haiku`). Accepts tier aliases (`haiku`, `sonnet`, `opus`, `fable`) or pinned model IDs (e.g. `claude-haiku-4-5-20251001`). Current tiers: Haiku 4.5 / Sonnet 4.6 / Opus 4.8 / Fable 5. |
| `karen_model` | Model for the verifier (default `sonnet`). |
| `max_turns` | Hard cap on agentic turns per run. |
| `soft_budget_usd_per_5h` | Self-throttle: skip ticks once trailing-5h spend hits this. `0` disables. |
| `telemetry.show_rolling_budget_in_status` | `true` writes a live 5h-spend meter to `state/STATUS.md` each tick (token-free). |
| `active_hours` | Only run between `start` and `end` (24-hour clock). |
| `github.repo` | Required. GitHub repo as `owner/repo`. |
| `github.base_branch` | Branch agents must never push to directly (default `main`). |
| `github.work_branch` | Branch for committing verified work before opening PRs (default `agents/work`). |

## Repo layout

```
CS-agent-team/
├── .claude-plugin/
│   ├── marketplace.json          # marketplace catalog
│   └── plugin.json               # plugin manifest
├── README.md
├── .gitignore
└── skills/
    └── agent-team/
        ├── SKILL.md              # how Claude installs & operates the system
        ├── scripts/
        │   ├── dispatcher.sh     # cron heartbeat (GitHub Issues-backed)
        │   ├── budget_check.sh   # writes 5h spend meter to state/STATUS.md
        │   ├── setup-labels.sh   # one-time: create GitHub labels + state/ dir
        │   └── setup.sh          # interactive installer
        └── assets/
            ├── schedule.json     # policy template
            ├── settings.json     # permission allowlist
            ├── env.example       # cron auth template
            ├── STATUS.md         # status-board template
            └── agents/
                ├── worker.md
                └── karen.md
```

## Limitations & honest caveats

- **It's a tortoise.** Progress is steady but slow by design — don't use it for anything you need in the next hour.
- **Weekly cap.** Staggering paces the 5-hour window; if you approach your subscription's weekly ceiling, only smaller/fewer tasks help.
- **Cheap models make mistakes.** That's why karen verifies and why you review before merging. Keep it on version-controlled, reversible work — never prod, secrets, or deploys.
- **Headless permissions.** Background runs auto-deny prompts; `.claude/settings.json` pre-allows safe tools and runs in `acceptEdits`. Widen the allowlist for your project's commands if a worker stalls.

## License

No license yet — add one (e.g. MIT) before sharing publicly.
