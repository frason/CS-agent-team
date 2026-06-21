---
name: agent-team
description: Set up and operate a background "agent team" for Claude Code — a cheap project-manager (PM) agent the client talks to, a "lead" agent that plans the work, and worker agents that a fixed cron heartbeat runs one at a time on a stagger, so something is almost always running but never all at once. This paces token use to fit a Claude subscription's rolling 5-hour limit. Use this skill whenever the client wants to delegate coding or side-project work to background agents, run staggered or scheduled subagents with cron, set up a PM / lead / orchestrator / worker team, keep working through long sessions without hitting the 5-hour usage limit, or bootstrap, install, configure, or adjust this kind of delegated agent system — even if they don't name it explicitly.
---

# Agent Team

A background delegation system for Claude Code. The **client** talks only to a cheap **PM**
agent. A cron **heartbeat** drips work to **workers** one at a time on a stagger. A **lead**
turns the client's goals into small worker tasks. Everything runs on the client's Claude
**subscription** (no API billing), and the design keeps token use low and paced so a long
session doesn't burn the rolling 5-hour limit all at once.

## The roles

| Role   | Who/what | Runs | Model | Job |
|--------|----------|------|-------|-----|
| Client | the human | — | — | Sets goals; talks only to the PM. |
| PM     | `claude --agent pm` | interactive, when the client opens it | haiku | Captures intent, reports status, relays the lead's questions, edits the schedule, facilitates direct sessions. Never does heavy work. |
| Lead   | `--agent lead` | unattended, on schedule | sonnet | Sizes the team (which lanes, how many) from the plan and decomposes goals into small worker tasks; asks the client questions *through the PM*. |
| Worker | `--agent worker` | unattended, staggered | haiku | Executes one small task; writes full output to an artifact, returns a short summary. |
| Karen  | `--agent karen` (verify lane) | unattended, gated | sonnet | Independently verifies that *claimed-done* work is actually functional and matches requirements; writes a verdict, never edits source. |

## How it works

- **One fixed cron heartbeat** runs `scripts/dispatcher.sh` every 10 minutes. It never changes.
- **All policy lives in `schedule.json`**, which the PM edits. An LLM never touches crontab.
- **Each tick does at most ONE thing**: a lead pass (only in its windows, only if the
  lead-inbox has work, only if the lead isn't paused) **or** one worker lane. Never both.
- **Workers are paced by a per-lane cooldown.** Four lanes on 10-minute ticks settle at a
  ~40-minute cadence each — always something running, never simultaneously. (Three lanes
  gives a true 30-minute cadence; tighten ticks to ~7 min to keep 30 min with four.)
- **Coordination is file-based** (the "blackboard"): `STATUS.md`, `queue/` (incl. `review/`),
  `lead-inbox/`, `questions/`, `artifacts/`, `logs/`. Agents read/write files, not each
  other's context.
- **Verification is staggered too.** The verifier (karen) runs as one more lane, so it obeys
  the same ≤1-at-a-time pacing, cooldown, and budget throttle. The lead gates it to phase
  boundaries (it runs on Sonnet), keeping audits inside the 5-hour window.
- **Dependencies are deterministic and free.** Sequenced tasks sit in `queue/backlog/` with a
  `depends_on:` list; each tick the dispatcher promotes any whose dependencies are all in
  `done/` — a pure file check, no LLM, no extra agent runs, so ordering never breaks the pacing.

```
Client ─chat─▶ PM (haiku)
                  │ writes
                  ├─▶ queue/todo/    ← workers pull from here
                  ├─▶ lead-inbox/    ← lead plans from here (+ relayed answers)
                  └─◀ questions/     ← lead's questions for the client (PM relays)
cron ─every 10m─▶ dispatcher.sh ─▶ one worker OR one lead pass
                                     ├─▶ artifacts/      (full output)
                                     ├─▶ logs/usage.jsonl (cost per run)
                                     └─▶ logs/activity.log
```

## Greenfield (from scratch)
The system runs soup-to-nuts, not just on existing repos. For an empty project:
0. **Kickoff** — opening the PM on an empty repo triggers a `/plan` intake: ~10 core questions
   (outcome, MVP, non-goals, happy path, stack, integrations, "done" criteria, guardrails,
   pace). The PM writes the answers into SPEC.md and sets `schedule.json`.
1. **Discovery** — the lead refines SPEC.md and raises open questions into `questions/`; the
   client answers asynchronously via the PM. Only settled slices become build tasks. This
   front-loads the Sonnet reasoning, then amortizes it across cheap Haiku build work.
2. **Scaffold** — for an empty repo the lead queues a small scaffold task first (init,
   structure, a test harness) so there's something real to build on and for karen to verify.
3. **Build** — the lead decomposes settled slices into tasks with `depends_on`; the dispatcher
   promotes them as dependencies clear; Haiku workers run on the stagger.
4. **Verify** — karen audits against SPEC.md; the lead opens fix tasks; loop.

Everything past kickoff is the normal async, staggered, budget-throttled work — the project
moves at the pace of your answers to spec questions, and never breaks the 5-hour window.

## Setting it up

Run these steps in the client's project (or a dedicated control directory). Confirm the
target directory with the client first.

1. **Scaffold the working directories** in the project root:
   ```bash
   mkdir -p scripts state logs artifacts queue/todo queue/doing queue/done queue/review queue/backlog \
            lead-inbox/done questions/answered .claude/agents
   ```
2. **Copy the bundled files** from this skill into the project:
   - `scripts/dispatcher.sh`         → `scripts/dispatcher.sh`  (then `chmod +x`)
   - `scripts/gh_sync.sh`            → `scripts/gh_sync.sh`  (then `chmod +x`)
   - `assets/schedule.json`          → `schedule.json`
   - `assets/STATUS.md`              → `state/STATUS.md`
   - `assets/SPEC.md`                → `SPEC.md`  (template; the PM fills it at kickoff)
   - `assets/settings.json`          → `.claude/settings.json`  (merge if one exists)
   - `assets/env.example`            → `.env.example`
   - `assets/agents/pm.md`           → `.claude/agents/pm.md`
   - `assets/agents/lead.md`         → `.claude/agents/lead.md`
   - `assets/agents/worker.md`       → `.claude/agents/worker.md`
   - `assets/agents/karen.md`        → `.claude/agents/karen.md`
3. **Install jq** (the dispatcher needs it): `brew install jq`
4. **Authenticate cron to the subscription** (not API):
   ```bash
   claude setup-token
   ```
   Copy `.env.example` to `.env`, paste the token into `CLAUDE_CODE_OAUTH_TOKEN`, and set
   `PATH` to where `claude` and `jq` live (`which claude ; which jq`).
5. **Add the heartbeat to cron** (`crontab -e`) with absolute paths:
   ```
   */10 * * * * /ABS/PATH/scripts/dispatcher.sh >> /ABS/PATH/logs/dispatcher.log 2>&1
   ```
6. **Test once by hand** before trusting cron: `./scripts/dispatcher.sh`, then check
   `logs/dispatcher.log` and `logs/usage.jsonl`.

Tell the client the two things most likely to trip them up: cron runs with a bare
environment (hence `.env` for PATH + token), and headless runs auto-deny permission prompts
(hence `.claude/settings.json` + `acceptEdits` — widen the allow list to their project's
commands if a worker stalls).

## Operating it (what to tell the client)

Open the PM whenever you want to check in or hand off work: `claude --agent pm`.

- **Kick off a project with a plan.** For a new project, enter plan mode first with `/plan`
  (or Shift+Tab twice) and shape the plan with the PM before any work is queued. On
  approval, the PM seeds the lead-inbox and STATUS.md from the plan.
- **Check status.** Ask "what's going on?" — the PM reports from STATUS.md. For quick,
  ephemeral pokes (including "how many agents are running?"), use `/btw`: it sees the full
  context but the answer isn't added to history, so it won't bloat the session or inflate
  later turns. By design, at most one background agent runs at a time.
- **Hand off ideas.** The PM writes worker tasks to `queue/todo/` or planning requests to
  `lead-inbox/`. It never interrupts the lead — it only queues.
- **Adjust the schedule.** Tell the PM in plain words ("only work 9–5", "pause the refactor
  lane", "go faster this afternoon", "don't run the lead while I'm out") and it edits
  `schedule.json`.
- **Answer the lead's questions.** When the lead needs a decision, the PM surfaces it; your
  answer is relayed back into the lead-inbox for the lead's next run.
- **Check what's real.** Ask the PM "what's actually done?" — it reports claimed vs verified
  and won't overstate. Ask it to verify a phase and it queues the verifier (karen) via the
  lead; results arrive on the normal stagger.
- **Work directly, occasionally.** To pair with the lead or a worker hands-on, the PM pauses
  that agent (so cron won't run it at the same time), gives you the command
  (`claude --agent lead` / `claude --agent worker`), and un-pauses when you're done.

Check spend anytime with `/usage` (live 5-hour and weekly consumption + reset times).

## GitHub integration (optional edge)
Off by default. Set `github.enabled: true` and a `repo` in schedule.json and GitHub becomes the
human-facing edge, while all agent-to-agent coordination stays in local files:
- **Issues in** — open or label an issue with `inbox_label`; a deterministic sync (run at lead
  windows, token-free) drops it into `lead-inbox/` for the lead to plan.
- **Questions/answers** — the lead's questions post as issue comments; your replies are pulled
  back automatically, so you can answer from anywhere, including the GitHub mobile app.
- **PRs out** — karen-verified work is committed to a `work_branch` and opened as a PR for you
  to review and merge. The agents never push or merge `main`.
- **Stays local** — the queue, the dependency DAG, and inter-agent handoffs never touch the
  API, so the token budget and per-tick reliability are untouched.

To enable: set `github.enabled`, `repo`, and `inbox_label`; authenticate gh for cron
(`gh auth login`, or `GH_TOKEN` in `.env`); and — important — turn on **branch protection for
`main`** in the repo so an approved PR is the only path to merge. That protection is the real
guardrail; the agents are instructed to stay on the work branch, but branch protection enforces it.

## schedule.json reference

| Field | Meaning |
|-------|---------|
| `paused` | `true` halts all runs immediately. |
| `lead_paused` | `true` stops lead passes (e.g., while the client works with the lead directly). |
| `paused_lanes` | Lanes to skip, e.g. `["refactor"]` (e.g., while pairing with that worker). |
| `tick_minutes` | Documentation only — the real cadence is the crontab line. |
| `lanes` | The worker lanes (categories), sized by the **lead** from the plan. Tasks match by their `lane:` field. |
| `lane_cooldown_min` | A lane won't rerun until this many minutes have passed. |
| `lead_windows` | Minutes-of-hour when the lead may run, e.g. `[0, 30]`. |
| `worker_model` / `lead_model` | Default models (`haiku`, `sonnet`, `opus`, `fable`). A task's own `model:` overrides for workers. |
| `karen_model` | Model for the verifier (default `sonnet` — it must actually reason about code). |
| `require_verification` | `true` routes finished worker tasks to `queue/review/`; they reach `done/` only after karen passes them (stricter, pricier). Default `false` = verify in batches at phase ends. |
| `github.*` | Optional GitHub edge: `enabled`, `repo` (owner/name), `inbox_label` (issues with this label become work), `base_branch`, `work_branch`. Default off. |
| `max_turns` | Hard cap on agentic turns per run. |
| `soft_budget_usd_per_5h` | Heuristic self-throttle: skip ticks once trailing-5h spend hits this. `0` disables. |
| `active_hours` | Only run between `start` and `end` (24-hour clock). |

## Token-saving choices baked in

- Workers return summaries only; full output goes to `artifacts/`. This keeps the PM and
  lead contexts tiny — the biggest lever, since context is re-billed on every turn.
- Cheap models per role (Haiku workers + PM, Sonnet lead); bump only where judgment matters.
- `maxTurns` + `effort: low` cap cost per worker run.
- STATUS.md stays short; history lives in `logs/`, so PM reads stay cheap.
- Staggering + cooldown pace the rolling 5-hour window instead of bursting into a lockout.
- Verification (karen, Sonnet) is gated to phase boundaries, not run on every task, so the
  audit layer rides the same stagger and throttle without blowing the budget.

## Honest caveats

- **Weekly cap.** Pacing only smooths the 5-hour window. Near the weekly ceiling, the only
  fix is genuinely fewer/cheaper tasks — keep tasks small and Haiku-only.
- **Headless permissions.** Background runs auto-deny prompts. `settings.json` pre-allows
  common safe tools and workers run in `acceptEdits`. If a worker stalls, widen the allow
  list. As a last resort in a sandboxed dir, add `--dangerously-skip-permissions` to the
  `claude` call in `dispatcher.sh` — understand the risk first.
- **Flag check.** If `dispatcher.log` shows an "unknown option" error, run `claude --help`
  and align the flags in `dispatcher.sh` with the installed version.

## Bundled files

- `scripts/dispatcher.sh` — the cron heartbeat (portable bash; macOS 3.2 + Linux).
- `scripts/gh_sync.sh` — the deterministic GitHub bridge (issues/comments in, questions out).
- `assets/schedule.json` — policy template (the PM edits the deployed copy).
- `assets/SPEC.md` — the living-spec template the PM fills from the kickoff intake.
- `assets/STATUS.md` — the status board template.
- `assets/settings.json` — permission allowlist template for `.claude/settings.json`.
- `assets/env.example` — cron environment template.
- `assets/agents/{pm,lead,worker,karen}.md` — the four agent definitions to install into `.claude/agents/`.
