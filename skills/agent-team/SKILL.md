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
| Lead   | scheduled, `lead_windows` | sonnet | Drains `lead-inbox/`, decomposes goals into GitHub Issues, manages sequencing via `depends_on`. |
| Worker | scheduled, staggered | haiku | Executes one `agent-todo` issue; writes summary to `state/worker_output.txt`. |
| Karen  | scheduled, gated | sonnet | Independently verifies finished work; writes verdict to `state/verdict.txt`; never edits source. |

## How it works

- **Tasks are GitHub Issues** with label-based state. The lead creates them from goals; workers claim them.
- **One fixed cron heartbeat** runs `scripts/dispatcher.sh` every 10 minutes. It never changes.
- **All policy lives in `schedule.json`** (no LLM touches crontab).
- **Each tick does at most ONE thing** (priority: lead → karen → worker). Never concurrent.
- **Labels carry state** (atomic swap prevents double-dispatch):
  ```
  agent-todo    → queued, not yet claimed
  agent-doing   → dispatcher claimed it (in-flight)
  agent-review  → worker done; awaiting karen
  agent-done    → karen passed; issue closed
  agent-backlog → sequenced task waiting on dependencies (created by lead)
  ```
- **Backlog promotion**: the dispatcher checks `depends_on:` in every `agent-backlog` issue each
  lead-window tick and relabels to `agent-todo` once all referenced issues are CLOSED.
- **FAILED karen verdict** cycles the issue back to `agent-todo` with a comment explaining
  what needs fixing, so the worker retries on the next eligible tick.

```
drop file ─▶ lead-inbox/          You ─ create GitHub Issues ─▶ (agent-todo)
                │                                                      │
cron ─10m─▶ dispatcher ───────────────────────────────────────────────┤
                │                                                      │
         [lead_window]                                                 │
                │ promotes backlog → todo                              │
                │ runs lead ──────────────────────────────▶ creates/updates GitHub Issues
                │   reads inbox + board state                          │
                │   archives lead-inbox/ items                         │
                │                                                      │
         [all other ticks]                                             │
                ├── agent-review exists? ── karen ──────────────────▶ PASSED → agent-done, close
                │                                                      FAILED → agent-todo, retry
                └── agent-todo exists? ── worker ──────────────────▶ summary comment → agent-review
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
   This creates `agent-todo`, `agent-doing`, `agent-review`, `agent-done`, and `agent-backlog`
   on the repo, and scaffolds `lead-inbox/done/`.

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
   ./scripts/dispatcher.sh --force-lead    # test the lead pass
   ./scripts/dispatcher.sh --force-worker  # test a worker run
   ```
   Then check `logs/dispatcher.log` and `logs/usage.jsonl`.

Tell the client the two things most likely to trip them up: cron runs with a bare environment
(hence `.env` for PATH + token), and headless runs auto-deny permission prompts (hence
`.claude/settings.json` + `acceptEdits` — widen the allow list to their project's commands
if a worker stalls).

## Operating it (what to tell the client)

- **Delegate a goal** — drop a `.md` file into `lead-inbox/`. The lead will pick it up on the
  next `lead_windows` tick, break it into GitHub Issues, and start sequencing work automatically.
- **Queue a task manually** — create a GitHub Issue and add the `agent-todo` label. The
  dispatcher claims it on the next non-lead tick.
- **Check status** — watch issue labels and comments on GitHub. The dispatcher posts the worker
  summary and karen's verdict as comments before changing labels.
- **Rolling budget** — `state/STATUS.md` shows a 5h rolling spend bar when
  `telemetry.show_rolling_budget_in_status` is true.
- **Force a run now** — `scripts/dispatcher.sh --force-lead` (lead) or `--force-worker` /
  `--force-worker <N>` (worker). All force flags bypass `active_hours` and the soft budget
  throttle; they still respect `paused`.
- **Pause lead only** — set `"lead_paused": true` in `schedule.json`.
- **Pause everything** — set `"paused": true` in `schedule.json`.
- **Adjust lead schedule** — set `lead_windows` to a list of minute values (e.g. `[0, 30]`
  runs the lead at :00 and :30 of every hour; `[0]` is the default — top of the hour).
- **Adjust active hours** — set `active_hours.start` / `.end` (24h clock).
- **Cap spend** — set `soft_budget_usd_per_5h` to skip ticks once the 5h trailing window
  hits the limit. `0` disables.

## schedule.json reference

| Field | Meaning |
|-------|---------|
| `paused` | `true` halts all runs immediately. |
| `worker_model` | Model for workers (default `haiku`). |
| `karen_model` | Model for the verifier (default `sonnet` — needs reasoning). |
| `lead_model` | Model for the lead (default `sonnet`). |
| `max_turns` | Hard cap on agentic turns for worker/karen runs. |
| `lead_max_turns` | Hard cap on agentic turns for lead runs (default `50`). |
| `lead_paused` | `true` skips the lead pass without halting workers/karen. |
| `lead_windows` | List of minute values when the lead runs (default `[0]` — top of every hour). E.g. `[0, 30]` runs at :00 and :30. |
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

- `scripts/dispatcher.sh`   — cron heartbeat (lead → karen → worker priority, bash 3.2).
- `scripts/budget_check.sh` — token-free rolling-budget meter for `state/STATUS.md`.
- `scripts/setup-labels.sh` — one-time init: creates directories and all 5 GitHub labels.
- `scripts/setup.sh`        — interactive installer (wraps all setup steps).
- `assets/schedule.json`    — policy template (edit the deployed copy).
- `assets/STATUS.md`        — status board template.
- `assets/settings.json`    — permission allowlist for `.claude/settings.json`.
- `assets/env.example`      — cron environment template.
- `assets/agents/lead.md`   — lead agent definition (planning + GitHub Issue creation).
- `assets/agents/worker.md` — worker agent definition.
- `assets/agents/karen.md`  — karen (verifier) agent definition.
