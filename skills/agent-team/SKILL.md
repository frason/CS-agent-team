---
name: agent-team
description: Set up and operate a background "agent team" for Claude Code — a cron heartbeat dispatches worker agents one at a time against tasks tracked as GitHub Issues, and a verifier (karen) audits each finished task before closing it. Paces token use to fit a Claude subscription's rolling 5-hour limit. Use this skill whenever the client wants to delegate coding or side-project work to background agents, run staggered subagents with cron, set up an orchestrator/worker/verifier team, keep working through long sessions without hitting the 5-hour usage limit, or bootstrap, configure, or adjust this kind of delegated agent system — even if they don't name it explicitly.
---

# Agent Team

A background delegation system for Claude Code. Work is tracked as **GitHub Issues**. A cron
**heartbeat** runs worker agents one at a time on a stagger. A **verifier** (karen) audits each
finished task and closes the issue on pass. Everything runs on the client's Claude
**subscription** (no API billing), and the design keeps token use low and paced so a long
session never burns the rolling 5-hour limit all at once.

## The roles

| Role   | Runs | Model | Job |
|--------|------|-------|-----|
| Worker | unattended, staggered | haiku | Executes the task from one GitHub Issue; writes a summary to `state/worker_output.txt`. |
| Karen  | unattended, gated | sonnet | Independently verifies that the worker's output actually meets the requirements; writes verdict to `state/verdict.txt`; never edits source. |

## How it works

- **Tasks are GitHub Issues** labelled `agent-todo`. You create the issues; the dispatcher claims them.
- **One fixed cron heartbeat** runs `scripts/dispatcher.sh` every 10 minutes. It never changes.
- **All policy lives in `schedule.json`** (no LLM touches crontab).
- **Each tick does at most ONE thing** — karen verification first if any `agent-review` issue exists,
  otherwise one worker run. Never concurrent.
- **Labels carry state** (atomic swap prevents double-dispatch):
  ```
  agent-todo    → queued, not yet claimed
  agent-doing   → dispatcher claimed it (in-flight)
  agent-review  → worker done; awaiting karen
  agent-done    → karen passed; issue closed
  ```
- **FAILED karen verdict cycles the issue back** to `agent-todo` with a comment explaining
  what needs to be fixed, so the worker retries on the next eligible tick.

```
You ─ create GitHub Issues ─▶ (label: agent-todo)
                                      │
cron ─every 10m─▶ dispatcher.sh ─────┤ claims oldest agent-todo → agent-doing
                       │             │ runs worker → posts summary comment → agent-review
                       │             │ runs karen  → posts verdict comment
                       │             │   PASSED → agent-done, closes issue
                       └─────────────┘   FAILED → agent-todo, worker retries
                  logs/usage.jsonl (cost per run)
                  state/STATUS.md  (rolling budget meter)
```

## Setting it up

Run these steps in the client's project (or a dedicated control directory).
Confirm the target directory with the client first.

1. **Install dependencies**:
   - `brew install jq`
   - `brew install gh` then `gh auth login`

2. **Copy the bundled files** from this skill into the project (or run `scripts/setup.sh`):
   - `scripts/dispatcher.sh`    → `scripts/dispatcher.sh`   (`chmod +x`)
   - `scripts/budget_check.sh`  → `scripts/budget_check.sh` (`chmod +x`)
   - `scripts/setup-labels.sh`  → `scripts/setup-labels.sh` (`chmod +x`)
   - `scripts/setup.sh`         → `scripts/setup.sh`        (`chmod +x`)
   - `assets/schedule.json`     → `schedule.json`
   - `assets/STATUS.md`         → `state/STATUS.md`
   - `assets/settings.json`     → `.claude/settings.json`
   - `assets/env.example`       → `.env.example`
   - `assets/agents/worker.md`  → `.claude/agents/worker.md`
   - `assets/agents/karen.md`   → `.claude/agents/karen.md`

3. **Set the GitHub repo** in `schedule.json`:
   ```json
   "github": { "repo": "owner/repo" }
   ```

4. **Create the GitHub labels** (run once):
   ```bash
   bash scripts/setup-labels.sh
   ```
   This creates `agent-todo`, `agent-doing`, `agent-review`, and `agent-done` on the repo.

5. **Authenticate cron to the subscription** (not API):
   ```bash
   claude setup-token
   ```
   Copy `.env.example` to `.env`, paste the token into `CLAUDE_CODE_OAUTH_TOKEN`, and set
   `PATH` to where `claude`, `jq`, and `gh` live (`which claude; which jq; which gh`).

6. **Add the heartbeat to cron** (`crontab -e`) with absolute paths:
   ```
   */10 * * * * /ABS/PATH/scripts/dispatcher.sh >> /ABS/PATH/logs/dispatcher.log 2>&1
   ```

7. **Test once by hand** before trusting cron:
   ```bash
   ./scripts/dispatcher.sh --force-worker
   ```
   Then check `logs/dispatcher.log` and `logs/usage.jsonl`.

Tell the client the two things most likely to trip them up: cron runs with a bare environment
(hence `.env` for PATH + token), and headless runs auto-deny permission prompts (hence
`.claude/settings.json` + `acceptEdits` — widen the allow list to their project's commands
if a worker stalls).

## Operating it (what to tell the client)

- **Queue work** — create a GitHub Issue on the configured repo and add the `agent-todo` label.
  The dispatcher picks it up on the next tick (or immediately with `--force-worker`).
- **Check status** — watch the issue labels and comments on GitHub. The dispatcher posts the
  worker's summary and karen's verdict as comments before changing labels.
- **Rolling budget** — `state/STATUS.md` shows a 5h rolling spend bar (updated every tick) when
  `telemetry.show_rolling_budget_in_status` is true.
- **Force a run now** — `scripts/dispatcher.sh --force-worker` (or `--force-worker <N>` for a
  specific issue). Bypasses `active_hours` and the soft budget throttle; still respects `paused`.
- **Pause everything** — set `"paused": true` in `schedule.json`.
- **Adjust hours** — set `active_hours.start` and `active_hours.end` (24h clock) in `schedule.json`.
- **Cap spend** — set `soft_budget_usd_per_5h` in `schedule.json` to skip ticks once the
  trailing 5-hour window hits the limit. `0` disables.

## schedule.json reference

| Field | Meaning |
|-------|---------|
| `paused` | `true` halts all runs immediately. |
| `worker_model` | Model for workers (default `haiku`). Accepts tier aliases (`haiku`, `sonnet`, `opus`, `fable`) or pinned model IDs. |
| `karen_model` | Model for the verifier (default `sonnet` — needs reasoning). |
| `max_turns` | Hard cap on agentic turns per run. |
| `soft_budget_usd_per_5h` | Heuristic self-throttle: skip ticks once trailing-5h spend hits this. `0` disables. |
| `telemetry.show_rolling_budget_in_status` | `true` updates `state/STATUS.md` with a spend bar on every tick. |
| `active_hours` | Only run between `start` and `end` (24-hour clock). |
| `github.repo` | Required. GitHub repo as `owner/repo`. |
| `github.base_branch` | The branch agents must never push to directly (default `main`). |
| `github.work_branch` | Branch for committing verified work before opening PRs (default `agents/work`). |

## Token-saving choices baked in

- Workers write summaries to `state/worker_output.txt` (≤40 lines) posted as comments;
  full output stays in the repo. This keeps agent contexts tiny — the biggest lever.
- Cheap models per role (Haiku workers, Sonnet verifier only where judgment matters).
- `maxTurns` + `effort: low` cap cost per worker run.
- `state/STATUS.md` stays short; history lives in `logs/`, so reads stay cheap.
- Staggering + `active_hours` + `soft_budget` pace the rolling 5-hour window instead of
  bursting into a lockout.
- Verification (karen, Sonnet) runs only when a task finishes — it's gated on the issue
  label state, not on a separate schedule, so it obeys the same ≤1-at-a-time pacing.

## Honest caveats

- **Weekly cap.** Pacing only smooths the 5-hour window. Near the weekly ceiling, the only
  fix is genuinely fewer/cheaper tasks — keep issues small and Haiku-only.
- **Headless permissions.** Background runs auto-deny prompts. `settings.json` pre-allows
  common safe tools and workers run in `acceptEdits`. If a worker stalls, widen the allow
  list. As a last resort in a sandboxed dir, add `--dangerously-skip-permissions` to the
  `claude` call in `dispatcher.sh` — understand the risk first.
- **Flag check.** If `dispatcher.log` shows an "unknown option" error, run `claude --help`
  and align the flags in `dispatcher.sh` with the installed version.

## Bundled files

- `scripts/dispatcher.sh`   — the cron heartbeat (GitHub Issues-backed, portable bash 3.2).
- `scripts/budget_check.sh` — token-free rolling-budget meter for `state/STATUS.md`.
- `scripts/setup-labels.sh` — one-time init: creates `state/`/`logs/` and GitHub labels.
- `scripts/setup.sh`        — interactive installer (wraps all setup steps).
- `assets/schedule.json`    — policy template (edit the deployed copy).
- `assets/STATUS.md`        — status board template.
- `assets/settings.json`    — permission allowlist for `.claude/settings.json`.
- `assets/env.example`      — cron environment template.
- `assets/agents/worker.md` — worker agent definition.
- `assets/agents/karen.md`  — karen (verifier) agent definition.
