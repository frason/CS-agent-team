# Agent Team

**A background "agent team" for Claude Code that gets work done on your subscription without burning through your 5-hour usage limit.**

You talk to a cheap project-manager agent. A fixed cron "heartbeat" drips work to worker agents one at a time on a stagger — so something is almost always progressing, but never all at once. A *lead* turns your goals into small tasks, and a verifier (*karen*) checks that work marked **done** actually works. It runs from a blank repo all the way to reviewed pull requests, entirely on your Claude subscription — no API billing.

---

## Why this exists

Heavy sub-agent use in Claude Code can burn your rolling 5-hour usage window in one sitting and lock you out for hours. Agent Team spreads bounded work across that window at a sustainable rate, so you stay under the cap and keep a lightweight agent available to talk to the whole time.

The principle throughout is **token frugality + steady pacing**: cheap models for bulk work, expensive reasoning gated and amortized, tiny file-based messages, and never more than one agent running at once.

## How it works

- A single **cron heartbeat** runs `dispatcher.sh` every ~10 minutes. It never changes.
- Each tick does **at most one thing** — one worker *or* one planning pass, never concurrent — so spend is paced, not bursted.
- All policy lives in **`schedule.json`**, edited by the PM agent (never the crontab).
- Coordination is **file-based** — a local "blackboard" of `queue/`, `lead-inbox/`, `questions/`, `artifacts/`, and `STATUS.md`. Agents exchange short files, not bloated context.
- **Cheap models** (Haiku) do the bulk; **stronger models** (Sonnet) handle planning and verification only where judgment is needed.

```
You ── chat ──▶ PM ──┬─▶ queue/        ← workers pull tasks
                     ├─▶ lead-inbox/   ← lead plans goals
                     └─◀ questions/    ← lead's questions (PM relays)

cron ─ every 10m ─▶ dispatcher ─▶ one worker  OR  one lead pass
                                   ├─▶ artifacts/        (full output)
                                   ├─▶ logs/usage.jsonl  (cost per run)
                                   └─▶ pull request       (verified work, for your review)
```

## Roles

| Role | Runs | Model | Job |
|------|------|-------|-----|
| **You (client)** | — | — | Set goals; talk only to the PM. |
| **PM** | interactive | Haiku | Capture intent, report honest status, relay questions, edit the schedule, facilitate. |
| **Lead** | scheduled | Sonnet | Build a spec, size the team, decompose goals into small tasks, open PRs. |
| **Worker** | scheduled, staggered | Haiku | Do one small task; write output to an artifact, return a short summary. |
| **Karen** | scheduled, gated | Sonnet | Independently verify that *claimed-done* work is real; never edits source. |

---

## Requirements

- **Claude Code** with a Pro or Max subscription (runs on your subscription, not the API)
- **jq**
- **macOS or Linux** — the scripts are portable to bash 3.2 and avoid GNU-only tools (`flock`, `date -Is`, etc.)
- *(optional)* **GitHub CLI (`gh`)** for the GitHub integration

## Install

This repo is a Claude Code plugin marketplace whose one plugin bundles the `agent-team` skill. Pick one path:

### As a Claude Code plugin (recommended)
In Claude Code:
```
/plugin marketplace add frason/CS-agent-team
/plugin install agent-team@cs-agent-team
```
Then, in the project you want worked on, ask Claude to **"set up the agent team."** The skill scaffolds the directories, copies the scripts, and installs the `pm` / `lead` / `worker` / `karen` agents into `.claude/agents/`. Update later with `/plugin marketplace update cs-agent-team`.

### As a bare skill
Copy the skill folder into your skills directory — `skills/agent-team/` → `~/.claude/skills/agent-team/` (personal) or `<project>/.claude/skills/agent-team/`. (Or install the packaged `agent-team.skill`.) Then ask Claude to "set up the agent team" as above.

### Manual
The skill files live under `skills/agent-team/`. Run these from that folder.
1. Scaffold the runtime dirs in your project:
   ```bash
   mkdir -p scripts state logs artifacts \
            queue/todo queue/doing queue/done queue/review queue/backlog \
            lead-inbox/done questions/answered .claude/agents
   ```
2. Copy files into place: `scripts/*` → `scripts/`; `assets/schedule.json` and `assets/SPEC.md` → project root; `assets/STATUS.md` → `state/`; `assets/settings.json` → `.claude/settings.json`; `assets/agents/*` → `.claude/agents/`.
3. `chmod +x scripts/*.sh`

### Then, for either path
1. Install jq: `brew install jq`
2. Authenticate cron to your subscription: `claude setup-token`, then copy `assets/env.example` → `.env`, paste the token into `CLAUDE_CODE_OAUTH_TOKEN`, and set `PATH` (cron runs with a bare environment).
3. Add the heartbeat to cron (`crontab -e`), with absolute paths:
   ```
   */10 * * * * /ABS/PATH/scripts/dispatcher.sh >> /ABS/PATH/logs/dispatcher.log 2>&1
   ```
4. Test once by hand: `./scripts/dispatcher.sh`, then check `logs/dispatcher.log` and `logs/usage.jsonl`.

## Using it

Open the PM whenever you like: `claude --agent pm`.

- **Start a project** — on an empty repo the PM pushes you into `/plan` and runs a short kickoff intake, then writes `SPEC.md` and seeds the work.
- **Check status** — ask "what's going on?"; for quick pokes use `/btw` so they don't bloat the session. At most one agent runs at a time, by design.
- **Hand off work** — give the PM goals; it queues tasks or files them for the lead.
- **Adjust pacing** — "only work 9–5", "pause the refactor lane", "go faster this afternoon" → the PM edits `schedule.json`.
- **Answer questions** — the lead asks via the PM; your answers flow back asynchronously.
- **Work directly** — to pair with the lead or a worker, the PM pauses that agent so cron won't collide, hands you the `claude --agent …` command, and un-pauses after.
- **Watch spend** — `/usage` shows live 5-hour and weekly consumption.

## Greenfield → done (the lifecycle)

0. **Kickoff** — `/plan` intake (~10 questions: outcome, MVP, non-goals, stack, "done" criteria, guardrails, pace). The only synchronous moment.
1. **Discovery** — the lead drafts `SPEC.md` and raises unknowns into `questions/`; you answer async. Only settled slices become work.
2. **Scaffold** — an empty repo gets a minimal skeleton + test harness first, so there's something to verify against.
3. **Build** — the lead decomposes settled slices into tasks with dependencies; the dispatcher releases them as deps clear; Haiku workers run on the stagger.
4. **Verify** — karen audits against `SPEC.md`; the lead opens fix tasks; verified work becomes a PR.

---

## Configuration & preferences (`schedule.json`)

| Field | Meaning |
|------|---------|
| `paused` | `true` halts all runs immediately. |
| `lead_paused` | Stop lead passes (e.g. while you pair with the lead directly). |
| `paused_lanes` | Lanes to skip, e.g. `["refactor"]`. |
| `lanes` | Worker lanes (categories), sized by the lead from the plan. |
| `lane_cooldown_min` | A lane won't rerun until this many minutes pass — the main pacing knob. |
| `lead_windows` | Minutes-of-hour the lead may run, e.g. `[0, 30]`. |
| `worker_model` / `lead_model` / `karen_model` | Models per role. Accepts tier aliases (`haiku`, `sonnet`, `opus`, `fable`) that auto-track current releases, or pinned model IDs (e.g. `claude-haiku-4-5-20251001`). Current tiers: Haiku 4.5, Sonnet 4.6, Opus 4.8, Fable 5. A task's own `model:` field overrides the default for that task. |
| `max_turns` | Hard cap on agentic turns per run. |
| `require_verification` | `true` = every task must pass karen before `done/` (stricter, pricier). `false` (default) = verify in batches at milestones. |
| `soft_budget_usd_per_5h` | Self-throttle: skip ticks once trailing-5h spend hits this. `0` disables. |
| `auto_accept_low_risk` | `true` skips karen for tasks marked `risk: low` whose lane is in `auto_accept_low_risk_lanes` (default `["docs"]`). Classification is mechanical (lane membership), not self-reported by the LLM. |
| `auto_accept_low_risk_lanes` | Lanes eligible for auto-accept. Default `["docs"]`. Only read-only lanes that can't break running code should be listed here. |
| `pre_dispatch.enabled` | `true` runs a task's `pre_dispatch_cmd:` before the worker boots and injects the output as context. Off by default — see Pre-dispatch below. |
| `pre_dispatch.timeout_sec` | Max seconds the pre-dispatch command may run. Default `10`. |
| `pre_dispatch.max_bytes` | Max bytes of pre-dispatch output injected into the task. Default `4096`. |
| `active_hours` | Only run between `start` and `end` (24-hour clock). |
| `github.*` | Optional GitHub edge: `enabled`, `repo` (owner/name), `inbox_label`, `base_branch`, `work_branch`. |

**Cadence tip:** four lanes on 10-minute ticks settle at ~40-minute spacing each. Want a true 30-minute cadence? Use three lanes, or tighten the cron to ~7-minute ticks.

## Pre-dispatch context injection (optional)

When `pre_dispatch.enabled` is `true`, the dispatcher runs a task's optional `pre_dispatch_cmd:` frontmatter field before booting the worker and appends the output to the task file as a `## Pre-dispatch context` block. This gives the worker targeted, up-to-date context (e.g. relevant file listing, grep results) without burning tokens in the worker's planning turn.

The lead sets `pre_dispatch_cmd:` on tasks where it helps. Example task frontmatter:

```
pre_dispatch_cmd: grep -rn "TODO" src/docs
risk: low
```

**Security:** the command string is author-controlled (the lead, an LLM) and runs unattended, so it is tightly sandboxed:
- Shell metacharacters (`;`, `|`, `&`, `>`, `<`, `` ` ``, `$(`, `${`, newlines) are rejected outright.
- The leading command must be on a read-only allowlist: `grep`, `rg`, `find`, `ls`, `tree`, `cat`, `head`, `wc`, `sed -n`, `git ls-files`, `git grep`.
- Output is capped at `pre_dispatch.max_bytes` and the command is killed after `pre_dispatch.timeout_sec`.
- Nothing that can mutate state is ever allowed.

Off by default. Enable with `pre_dispatch.enabled: true` in `schedule.json`.

## GitHub integration (optional)

Off by default. Set `github.enabled: true` and a `repo`, and GitHub becomes the human-facing edge while agent-to-agent coordination stays local:

- **Issues in** — open or label an issue with `inbox_label`; a deterministic, token-free sync (at lead windows) turns it into work.
- **Q&A** — the lead's questions post as issue comments; your replies are pulled back. Answer from anywhere, including the GitHub mobile app.
- **PRs out** — karen-verified work is committed to a work branch and opened as a PR for you to review and merge. Agents never push or merge `main`.

To enable: fill in the `github` block, authenticate `gh` for cron (`gh auth login` or `GH_TOKEN` in `.env`), and — important — **turn on branch protection for `main`**. That protection is the real guardrail; the agents are told to stay on the work branch, but branch protection enforces it.

## Repo layout

```
CS-agent-team/
├── .claude-plugin/
│   ├── marketplace.json          # marketplace catalog (lists the plugin)
│   └── plugin.json               # plugin manifest
├── README.md
├── .gitignore
├── agent-team.skill              # packaged bundle (zip)
└── skills/
    └── agent-team/
        ├── SKILL.md              # how Claude installs & operates the system
        ├── scripts/
        │   ├── dispatcher.sh     # cron heartbeat
        │   └── gh_sync.sh        # GitHub bridge (optional)
        └── assets/
            ├── schedule.json     # policy / preferences
            ├── settings.json     # permission allowlist
            ├── env.example       # cron auth template
            ├── SPEC.md           # living-spec template
            ├── STATUS.md         # status-board template
            └── agents/
                ├── pm.md
                ├── lead.md
                ├── worker.md
                └── karen.md
```

## Limitations & honest caveats

- **It's a tortoise.** Progress is steady but slow by design — don't use it for anything you need in the next hour.
- **Weekly cap.** Staggering paces the 5-hour window; if you approach your subscription's weekly ceiling, only smaller/fewer tasks help.
- **Cheap models make mistakes.** That's why karen verifies and why output goes through PRs you approve. Keep it on version-controlled, reversible work — never prod, secrets, or deploys.
- **Greenfield needs you early.** The project moves at the pace of your answers to spec questions.
- **Headless permissions.** Background runs auto-deny prompts; `.claude/settings.json` pre-allows safe tools and runs in `acceptEdits`. Widen the allowlist for your project's commands if a worker stalls.

## License

No license yet — add one (e.g. MIT) before sharing publicly.
