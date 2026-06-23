# Agent Team

**A background "agent team" for Claude Code that gets work done on your subscription without burning through your 5-hour usage limit.**

Drop a goal file into `lead-inbox/` and the system handles the rest: a **lead** decomposes goals into GitHub Issues, **workers** execute them one at a time on a stagger, and a **verifier** (*karen*) confirms each is actually done before closing it.

---

## Why this exists

Heavy sub-agent use in Claude Code can burn your rolling 5-hour usage window in one sitting and lock you out for hours. Agent Team spreads bounded work across that window at a sustainable rate, so you stay under the cap and always have capacity for interactive work.

The principle throughout is **token frugality + steady pacing**: cheap models for bulk work, expensive reasoning gated, and never more than one agent running at once.

## How it works

- All work lives as **GitHub Issues** with a label-based state machine. The lead creates them from your goals.
- A single **cron heartbeat** runs `dispatcher.sh` every 10 minutes. It never changes.
- Each tick does **at most one thing** in priority order: lead → karen → worker. Never concurrent.
- All policy lives in **`schedule.json`** (no LLM touches crontab).
- **Labels carry state**:

```
agent-todo    → queued, not yet claimed
agent-doing   → dispatcher claimed it (prevents double-dispatch)
agent-review  → worker done; awaiting karen
agent-done    → karen passed; issue closed
agent-backlog → waiting on dependencies (lead creates these for sequenced work)
```

```
drop file ─▶ lead-inbox/
                  │
cron ─ 10m ─▶ dispatcher
                  │
           [lead_windows]
                  │ promote agent-backlog → agent-todo (deterministic, no tokens)
                  │ run lead ─────────────────────────────▶ gh issue create (agent-todo / agent-backlog)
                  │   reads inbox + board, archives inbox             │
                  │                                                   ▼
           [other ticks]                                  labels carry all state
                  ├── agent-review? ── karen ── PASSED → agent-done, close issue
                  │                             FAILED → agent-todo, worker retries
                  └── agent-todo?  ── worker ── summary comment → agent-review
              logs/usage.jsonl  (cost per run)
              state/STATUS.md   (rolling 5h spend meter)
```

## Roles

| Role | Runs | Model | Job |
|------|------|-------|-----|
| **Lead** | scheduled, `lead_windows` | Sonnet | Drain `lead-inbox/`, decompose goals into GitHub Issues, manage sequencing via `depends_on`. |
| **Worker** | scheduled, staggered | Haiku | Execute one `agent-todo` issue; write summary to `state/worker_output.txt`. |
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

- **Delegate a goal** — drop a `.md` file into `lead-inbox/`. The lead picks it up on the next `lead_windows` tick and creates all the GitHub Issues.
- **Queue a task manually** — create a GitHub Issue and add the `agent-todo` label. The dispatcher claims it on the next non-lead tick.
- **Check status** — watch issue labels and comments on GitHub. The dispatcher posts worker summaries and karen's verdict as comments before changing labels.
- **Force a lead run** — `scripts/dispatcher.sh --force-lead`. Bypasses `active_hours` and the soft budget throttle.
- **Force a worker run** — `scripts/dispatcher.sh --force-worker` (or `--force-worker <N>` for a specific issue).
- **Pause lead only** — set `"lead_paused": true` in `schedule.json`.
- **Pause everything** — set `"paused": true` in `schedule.json`.
- **Watch spend** — `state/STATUS.md` shows a live 5h spend bar when `telemetry.show_rolling_budget_in_status` is true.

---

## Configuration (`schedule.json`)

| Field | Meaning |
|------|---------|
| `paused` | `true` halts all runs immediately. |
| `worker_model` | Model for workers (default `haiku`). Accepts tier aliases or pinned IDs. |
| `karen_model` | Model for the verifier (default `sonnet`). |
| `lead_model` | Model for the lead (default `sonnet`). |
| `max_turns` | Hard cap on agentic turns for worker/karen. |
| `lead_max_turns` | Hard cap on agentic turns for lead (default `50`). |
| `lead_paused` | `true` skips lead passes without halting workers or karen. |
| `lead_windows` | Minutes at which the lead runs (default `[0]` — top of every hour). `[0, 30]` runs at :00 and :30. |
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
        │   ├── dispatcher.sh     # cron heartbeat (lead → karen → worker priority)
        │   ├── budget_check.sh   # writes 5h spend meter to state/STATUS.md
        │   ├── setup-labels.sh   # one-time: create 5 GitHub labels + local dirs
        │   └── setup.sh          # interactive installer
        └── assets/
            ├── schedule.json     # policy template (includes lead_windows etc.)
            ├── settings.json     # permission allowlist
            ├── env.example       # cron auth template
            ├── STATUS.md         # status-board template
            └── agents/
                ├── lead.md       # lead: decomposes goals → GitHub Issues
                ├── worker.md
                └── karen.md

# Runtime directories (created by setup):
# lead-inbox/        ← drop goal .md files here; lead drains them
# lead-inbox/done/   ← processed inbox items archived here
# questions/         ← lead writes client questions here for the PM
# state/             ← STATUS.md, verdict.txt, worker_output.txt
# logs/              ← dispatcher.log, usage.jsonl, activity.log
```

## Limitations & honest caveats

- **It's a tortoise.** Progress is steady but slow by design — don't use it for anything you need in the next hour.
- **Weekly cap.** Staggering paces the 5-hour window; if you approach your subscription's weekly ceiling, only smaller/fewer tasks help.
- **Cheap models make mistakes.** That's why karen verifies and why you review before merging. Keep it on version-controlled, reversible work — never prod, secrets, or deploys.
- **Headless permissions.** Background runs auto-deny prompts; `.claude/settings.json` pre-allows safe tools and runs in `acceptEdits`. Widen the allowlist for your project's commands if a worker stalls.

## License

No license yet — add one (e.g. MIT) before sharing publicly.
