---
name: agent-team
description: Set up and operate a background "agent team" for Claude Code — a lead decomposes goals into GitHub Issues, worker agents execute them one at a time on a stagger, and a verifier (karen) audits each finished task before closing it. Paces token use to fit a Claude subscription's rolling 5-hour limit. Use this skill whenever the client wants to delegate coding or side-project work to background agents, run staggered subagents with cron, set up a lead/worker/verifier team, keep working through long sessions without hitting the 5-hour usage limit, or bootstrap, configure, or adjust this kind of delegated agent system — even if they don't name it explicitly.
---

# Agent Team

A background delegation system for Claude Code. Drop a goal into `lead-inbox/` — a **lead**
decomposes it into GitHub Issues, **worker** agents execute them one at a time on a stagger,
and **karen** (the verifier) audits each finished task and closes the issue on pass. Everything
runs on the client's Claude **subscription** (no API billing), and the design keeps token use
low and paced so a long session never burns the rolling 5-hour limit all at once.

## The roles

| Role   | Runs | Model | Job |
|--------|------|-------|-----|
| PM     | interactive (client opens it) | haiku | First-time setup, status reporting, scheduling, relaying lead questions. The only role the client talks to directly. |
| Lead   | scheduled, `lead_windows` | sonnet | Drains `lead-inbox/`, decomposes goals into GitHub Issues, manages sequencing via `depends_on`. |
| Worker | scheduled, staggered | haiku | Executes one `agent-todo` issue; writes summary to `state/worker_output_<issue-number>.txt`. |
| Karen  | scheduled, gated | sonnet | Independently verifies finished work; writes verdict to `state/verdict.txt`; never edits source. |

## How it works

- **Tasks are GitHub Issues** with label-based state. The lead creates them from goals; workers claim them.
- **One fixed cron heartbeat** runs `scripts/dispatcher.sh` every 10 minutes. It never changes.
- **All policy lives in `schedule.json`** (no LLM touches crontab).
- **Each tick does at most ONE thing** (priority: lead → karen → worker). Never concurrent.
- **Labels carry state** (atomic swap prevents double-dispatch):
  ```
  agent-todo     → queued, not yet claimed
  agent-doing    → dispatcher claimed it (in-flight)
  agent-review   → worker done; awaiting karen
  agent-done     → karen passed; issue closed
  agent-backlog  → sequenced task waiting on dependencies (created by lead)
  agent-triage   → user-entered issue awaiting lead triage (priority/timing)
  agent-question → lead needs client input; client answers by commenting
  agent-blocked  → exceeded max_worker_attempts; needs manual or lead intervention
  ```
- **Backlog promotion**: the dispatcher checks `depends_on:` in every `agent-backlog` issue each
  lead-window tick and relabels to `agent-todo` once all referenced issues are CLOSED.
- **Client triage**: when you create a GitHub Issue directly, the dispatcher detects it
  (missing `<!-- agent-planned -->` marker) and triggers the lead immediately. For issues with
  a `### Priority` form field the lead sequences them right away; for plain-text issues the
  lead asks priority/timing questions and relabels to `agent-triage` until you respond.
- **Issue Form**: `.github/ISSUE_TEMPLATE/task.yml` pre-fills priority, timing, and
  dependencies at creation time — eliminates the triage question round-trip.
- **GitHub Projects v2**: optional board (`scripts/setup-project.sh`) aggregates issues from
  all repos into one view. The lead adds issues to the board automatically when configured.
- **Global budget**: `~/.claude/agent-team-budget.json` caps spend across all projects on
  this machine and reserves a configurable amount for PM interactions (`pm_reserve_usd`).
- **Client questions go through GitHub**: the lead creates `agent-question` issues. The client
  answers by commenting; the lead reads comments on its next pass and closes the issue.
- **FAILED karen verdict** cycles the issue back to `agent-todo` with a comment explaining
  what needs fixing, so the worker retries on the next eligible tick.
- **A karen crash is different from a FAILED verdict**: if karen exits non-zero or writes
  no `state/verdict.txt` (a CLI/subscription outage), the issue stays in `agent-review` and
  karen retries next cycle — it does NOT bounce to `agent-todo` or touch the worker's
  `max_worker_attempts` count. Only a real FAILED verdict sends work back to the worker.

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

**Easiest path (Claude Code):** After copying the skill files (step 2 below), open the PM
agent and say "set up the agent team". It detects what's missing and walks through token,
GitHub, labels, and cron interactively — no terminal editing required.

Alternatively, run the steps manually:

1. **Install dependencies** (if not already present):
   ```bash
   brew install jq gh
   gh auth login
   ```

2. **Copy the bundled files** into the project (or run `scripts/setup.sh`):
   - `scripts/dispatcher.sh`        → `scripts/dispatcher.sh`   (`chmod +x`)
   - `scripts/budget_check.sh`      → `scripts/budget_check.sh` (`chmod +x`)
   - `scripts/setup-labels.sh`      → `scripts/setup-labels.sh` (`chmod +x`)
   - `scripts/setup-project.sh`     → `scripts/setup-project.sh` (`chmod +x`)
   - `scripts/setup.sh`             → `scripts/setup.sh`        (`chmod +x`)
   - `assets/schedule.json`         → `schedule.json`
   - `assets/STATUS.md`             → `state/STATUS.md`
   - `assets/settings.json`         → `.claude/settings.json`
   - `assets/env.example`           → `.env.example`
   - `assets/agents/pm.md`          → `.claude/agents/pm.md`
   - `assets/agents/lead.md`        → `.claude/agents/lead.md`
   - `assets/agents/worker.md`      → `.claude/agents/worker.md`
   - `assets/agents/karen.md`       → `.claude/agents/karen.md`
   - `assets/.github/ISSUE_TEMPLATE/task.yml` → `.github/ISSUE_TEMPLATE/task.yml`

3. **Set the GitHub repo** in `schedule.json`:
   ```json
   "github": { "repo": "owner/repo" }
   ```

4. **Create the GitHub labels** (run once):
   ```bash
   bash scripts/setup-labels.sh
   ```
   Creates all 8 labels on the repo and scaffolds `lead-inbox/done/`.

   Optionally create a GitHub Projects v2 board for cross-repo visibility:
   ```bash
   bash scripts/setup-project.sh
   ```

5. **Authenticate cron to the subscription**:
   ```bash
   claude setup-token   # follow the prompts; copy the token it prints
   ```
   Copy `.env.example` to `.env`, paste `CLAUDE_CODE_OAUTH_TOKEN=<token>`, and set
   `PATH` to where `claude`, `jq`, and `gh` live (`which claude; which jq; which gh`).

6. **Add the heartbeat to cron** (non-interactive — no editor needed):
   ```bash
   DISP="$(pwd)/scripts/dispatcher.sh"
   LOG="$(pwd)/logs/dispatcher.log"
   ( crontab -l 2>/dev/null | grep -Fv dispatcher.sh
     echo "*/10 * * * * $DISP >> $LOG 2>&1" ) | crontab -
   crontab -l | grep dispatcher.sh   # confirm it's there
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

- **Delegate a goal** — drop a `.md` file into `lead-inbox/`. The lead picks it up on the
  next `lead_windows` tick, breaks it into GitHub Issues, and starts sequencing.
- **Queue a task manually** — create a GitHub Issue with the `agent-todo` label. Use the
  **Agent Task** issue form (`.github/ISSUE_TEMPLATE/task.yml`) to set priority/timing/deps
  at creation time. The lead triages it on its next pass; the dispatcher never lets a worker
  claim an untriaged issue.
- **Answer a triage question** — if the lead asks for priority/timing, comment on the
  `agent-triage` issue. The lead incorporates your answer on its next pass.
- **Answer a lead question** — comment on the `agent-question` issue directly; the lead reads
  it on its next pass and closes it.
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
- **Cap spend (per-project)** — set `soft_budget_usd_per_5h` in `schedule.json`. `0` disables.
- **Cap spend (all projects)** — edit `~/.claude/agent-team-budget.json`:
  `{"budget_usd_per_5h": 10, "pm_reserve_usd": 0.5, "entries": []}`. When remaining budget
  falls to `pm_reserve_usd`, all cron agents pause so the PM stays reachable. `budget = 0` disables.
- **Lead cost control** — a capable Lead model run frequently adds up (observed ~$3/pass
  for a strong model). Keep `lead_windows` sparse (e.g. `[0]` for hourly, not every 10 min)
  unless the project genuinely needs fast triage turnaround.

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
| `soft_budget_usd_per_5h` | Per-project self-throttle: skip ticks once trailing-5h spend hits this. `0` disables. |
| `max_worker_attempts` | How many times a worker may attempt an issue before it is moved to `agent-blocked`. Default `3`. |
| `worker_escalation_model` | Model to use for a worker retry once `worker_escalation_after` prior attempts exist. Empty string (default) disables escalation. |
| `worker_escalation_after` | Number of prior attempts (same cycle-detection count) before escalating to `worker_escalation_model`. Default `1`. |
| `telemetry.show_rolling_budget_in_status` | `true` updates `state/STATUS.md` with a spend bar on every tick. |
| `active_hours` | Only run between `start` and `end` (24-hour clock). |
| `github.repo` | Required. GitHub repo as `owner/repo`. |
| `github.base_branch` | The branch agents must never push to directly (default `main`). |
| `github.work_branch` | Branch for committing verified work before opening PRs (default `agents/work`). |
| `github.project_number` | GitHub Projects v2 board number. Set by `setup-project.sh`. Lead adds new issues to this board automatically when set. |

## Token-saving choices baked in

- Workers write summaries to a per-issue `state/worker_output_<issue-number>.txt` (≤40 lines)
  posted as comments; full output stays in the repo. This keeps agent contexts tiny — the
  biggest lever. Per-issue (not shared) so a worker on a newer issue can never overwrite the
  file karen is about to read for an older issue still stuck retrying verification.
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
- **schedule.json must be committed.** It's a tracked file in your project repo, not a
  local-only config. If you edit it and don't commit, any git operation that touches the
  tree (`git pull`, `git checkout <branch>`, a maintainer's `git reset --hard origin/main`)
  can silently discard your changes. Commit schedule.json edits like any other change:
  `git add schedule.json && git commit -m "adjust schedule"`. The dispatcher logs a
  warning if it detects uncommitted changes.
- **Headless permissions.** Background runs auto-deny prompts. `settings.json` pre-allows
  common safe tools and workers run in `acceptEdits`. If a worker stalls, widen the allow
  list. As a last resort in a sandboxed dir, add `--dangerously-skip-permissions` to the
  `claude` call in `dispatcher.sh` — understand the risk first. This applies to **platform
  build tools** too (e.g. `xcodebuild`, `xcodegen`, `xcrun` for iOS projects, or your
  stack's equivalent) — interactive approval in your own terminal session does NOT extend
  to cron-spawned headless runs. It also applies to **any MCP tool** the agents use: add
  the MCP tool name to `permissions.allow` the same way. Without this, agents burn every
  turn retrying a blocked command and still get logged as "complete" with zero real output
  — see the max-turns caveat below. (This includes any MCP tool used for karen's optional
  cross-model review — see karen.md.)
- **Max-turns exhaustion looks like success.** If an agent hits its turn limit mid-task,
  the dispatcher logs it as "treating as complete" and still advances the issue (worker →
  `agent-review`, karen still requires a verdict). This is BY DESIGN so a stuck agent
  doesn't loop forever, but it means "ran" in the log does not mean "did the work." The
  real signal to check is `logs/activity.log` for the line `MAX-TURNS-EXHAUSTED:` — if it
  co-occurs with `cost=$0` or no real artifact/summary written, the run produced nothing
  useful and needs a manual retry or a smaller task. Don't assume a logged run succeeded
  just because the dispatcher moved the issue forward.
- **A karen crash is not a FAILED verdict.** If karen crashes or exits without writing
  `state/verdict.txt` (e.g. a CLI/subscription outage — the same `$0`-cost signal used for
  worker outages), the issue stays in `agent-review` and karen retries next cycle. It does
  NOT bounce back to `agent-todo` — that would make the worker redo already-correct work
  and burn a `max_worker_attempts` retry for every karen infrastructure hiccup, unrelated
  to the actual code. Only a genuine FAILED verdict (karen ran successfully and found real
  problems) sends the issue back to the worker.
- **Don't run agents in parallel on one checkout.** The dispatcher itself is single-flight
  (the lock in `scripts/dispatcher.sh` guarantees one tick at a time) — this is not a risk
  from normal cron operation. It only bites if you bypass the dispatcher: e.g. hand-invoking
  multiple `claude --agent worker` sessions yourself, or running two checkouts of the same
  project against the same branch. Two agents editing the same files on the same working
  tree will stomp each other's changes. If you genuinely need parallel agent execution,
  give each agent its own `git worktree` (or an equivalent isolated checkout) rather than
  sharing one tree.
- **Silent throttling.** When the per-project soft budget (`soft_budget_usd_per_5h`) is hit,
  the dispatcher just logs `throttled: $X in last 5h >= per-project soft budget $Y` once
  per 10-minute tick and exits — there's no other signal. Don't assume a quiet project is
  idle-and-fine; check `logs/activity.log` for repeated `throttled:` lines, and
  `state/STATUS.md` for the rolling spend bar (when
  `telemetry.show_rolling_budget_in_status` is true) to see spend relative to the cap.
  If you expect work to be happening and see only `throttled:` lines, raise
  `soft_budget_usd_per_5h` or wait for the 5h window to roll over.
- **Flag check.** If `dispatcher.log` shows an "unknown option" error, run `claude --help`
  and align the flags in `dispatcher.sh` with the installed version.

To give karen an optional second-opinion model, register an MCP server for the project
(`claude mcp add <name> ...` — see `claude mcp --help`), then add its tool name to
`karen.md`'s `tools:` frontmatter and to `settings.json`'s `permissions.allow` list
(headless runs need it allowlisted the same as any other tool — see the Headless
permissions caveat above).

## Bundled files

- `scripts/dispatcher.sh`   — cron heartbeat (lead → karen → worker priority, bash 3.2).
- `scripts/budget_check.sh` — token-free rolling-budget meter for `state/STATUS.md`.
- `scripts/setup-labels.sh` — one-time init: creates directories and all 8 GitHub labels.
- `scripts/setup-project.sh` — optional: creates a GitHub Projects v2 board.
- `scripts/setup.sh`        — interactive installer (wraps all setup steps).
- `assets/schedule.json`    — policy template (edit the deployed copy).
- `assets/STATUS.md`        — status board template.
- `assets/settings.json`    — permission allowlist for `.claude/settings.json`.
- `assets/env.example`      — cron environment template.
- `assets/agents/pm.md`     — PM agent (client-facing: setup wizard, status, scheduling).
- `assets/agents/lead.md`   — lead agent (planning, triage, and GitHub Issue creation).
- `assets/agents/worker.md` — worker agent.
- `assets/agents/karen.md`  — karen (verifier) agent.
- `assets/.github/ISSUE_TEMPLATE/task.yml` — GitHub Issue Form (priority/timing/deps at creation).
