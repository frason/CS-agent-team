# Agent Team

A background delegation system for Claude Code. Drop a goal into `lead-inbox/` or create
a GitHub Issue — a **lead** decomposes it, **workers** execute tasks one at a time, and
**karen** audits each finished task before closing it. Everything runs on your Claude
subscription via a 10-minute cron heartbeat.

---

## Roles

| Role | Runs | Model | Job |
|------|------|-------|-----|
| PM | Interactive (you open it) | Haiku | Setup wizard, status, scheduling, budget. The only role you talk to directly. |
| Lead | Scheduled (`lead_windows`) + on-demand triage | Sonnet | Drains `lead-inbox/`, plans goals into GitHub Issues, triages user-submitted tasks. |
| Worker | Scheduled, staggered | Haiku | Executes one `agent-todo` issue; writes summary to `state/worker_output.txt`. |
| Karen | Scheduled, gated on agent-review | Sonnet | Verifies finished work; writes verdict to `state/verdict.txt`; never edits source. |

---

## How it works

Tasks are **GitHub Issues** with label-based state. One cron heartbeat runs
`scripts/dispatcher.sh` every 10 minutes. Each tick does at most one thing:

```
drop goal ──▶ lead-inbox/     You ──▶ GitHub Issue (agent-todo)
                 │                            │
10min cron ──▶ dispatcher ───────────────────┤
                 │                            │
         [lead window or untriaged issues]    │
                 │  promote backlog → todo     │
                 │  triage user-entered issues │
                 │  run lead ─────────────────▶ creates/sequences GitHub Issues
                 │                            │
         [other ticks]                        │
                 ├─ agent-review? ── karen ──▶ PASSED → agent-done, closed
                 │                            FAILED → agent-todo, retry
                 └─ agent-todo? ─── worker ──▶ summary comment → agent-review
                                    (skips untriaged issues)
```

**Label state machine:**

| Label | Meaning |
|-------|---------|
| `agent-todo` | Queued. Worker will claim on the next eligible tick. |
| `agent-doing` | Claimed by the dispatcher (prevents double-dispatch). |
| `agent-review` | Worker done; karen will verify next. |
| `agent-done` | Karen passed; issue closed. |
| `agent-backlog` | Sequenced task waiting on `depends_on:` issues to close. |
| `agent-triage` | User-submitted issue awaiting lead priority/timing questions. |
| `agent-question` | Lead needs your input; answer by commenting on the issue. |
| `agent-blocked` | Exceeded retry limit. Needs manual attention or lead decomposition. |

---

## Setup

**Easiest:** copy the skill files into your project, open the PM agent, say "set up the agent team".

**Manual:**

```bash
# 1. Dependencies
brew install jq gh && gh auth login

# 2. Copy files (or run scripts/setup.sh which does all of this)
cp scripts/dispatcher.sh   YOUR_PROJECT/scripts/dispatcher.sh
cp scripts/budget_check.sh YOUR_PROJECT/scripts/budget_check.sh
cp scripts/setup-labels.sh YOUR_PROJECT/scripts/setup-labels.sh
cp scripts/setup-project.sh YOUR_PROJECT/scripts/setup-project.sh
cp assets/schedule.json    YOUR_PROJECT/schedule.json
cp assets/agents/*.md      YOUR_PROJECT/.claude/agents/
cp assets/.github/ISSUE_TEMPLATE/task.yml YOUR_PROJECT/.github/ISSUE_TEMPLATE/task.yml
chmod +x YOUR_PROJECT/scripts/*.sh

# 3. Set your repo in schedule.json
#    "github": { "repo": "owner/repo" }

# 4. Create GitHub labels (run once)
bash scripts/setup-labels.sh

# 5. Optional: create a GitHub Projects v2 board
bash scripts/setup-project.sh

# 6. Authenticate cron to your Claude subscription
claude setup-token
# paste result as CLAUDE_CODE_OAUTH_TOKEN in .env (copy from .env.example)

# 7. Install the cron heartbeat
DISP="$(pwd)/scripts/dispatcher.sh"
LOG="$(pwd)/logs/dispatcher.log"
( crontab -l 2>/dev/null | grep -Fv dispatcher.sh
  echo "*/10 * * * * $DISP >> $LOG 2>&1" ) | crontab -

# 8. Test by hand
./scripts/dispatcher.sh --force-lead
./scripts/dispatcher.sh --force-worker
```

---

## Operating

### Submitting work

**Drop a goal (recommended for new features):**
```bash
echo "Build a dark-mode toggle in the settings panel" > lead-inbox/$(date +%s)-dark-mode.md
```
The lead picks it up on the next lead-window tick, decomposes it, and creates GitHub Issues.

**Create an issue directly (for specific, well-scoped tasks):**

Use the **Agent Task** issue form on GitHub — it captures priority, timing, and dependencies
at creation time so the lead can sequence the issue immediately without follow-up questions.

Or from the CLI:
```bash
gh issue create --repo owner/repo --label "agent-todo" \
  --title "Add retry logic to the image upload" \
  --body "$(cat <<'EOF'
## Goal
Add exponential backoff retry (max 3 attempts) to uploadImage() in src/api/images.ts.

## Done when
- uploadImage retries on 5xx with 1s/2s/4s delays
- Existing tests pass; add one test for retry behaviour

<!-- agent-planned -->
EOF
)"
```

The `<!-- agent-planned -->` marker tells the dispatcher this issue is already scoped — it
goes straight to workers. Without the marker, the lead triages it first.

### Answering lead questions

The lead posts questions as GitHub Issues with the `agent-question` label. Comment on the
issue directly — the lead reads your comment on its next pass and closes it.

For triage questions (`agent-triage`), comment with priority/timing info; the lead
incorporates your answer and relabels the issue to `agent-todo`.

### Controlling pace

Edit `schedule.json` (or ask the PM):

| Want | Change |
|------|--------|
| Pause everything | `"paused": true` |
| Pause lead only | `"lead_paused": true` |
| Lead runs at :00 and :30 | `"lead_windows": [0, 30]` |
| Per-project spend cap | `"soft_budget_usd_per_5h": 5` |
| Only run 9–5 | `"active_hours": {"start": 9, "end": 17}` |
| Change retry limit | `"max_worker_attempts": 5` |

### Global budget (across all projects)

`~/.claude/agent-team-budget.json` caps total spend across all agent-team projects on this
machine and reserves headroom so the PM stays reachable:

```json
{
  "budget_usd_per_5h": 10,
  "pm_reserve_usd": 0.50,
  "entries": []
}
```

When `(total 5h spend) >= budget - pm_reserve`, all cron agents pause until the window
rolls over. `budget_usd_per_5h: 0` disables the global cap. The PM can view and update
this file; the dispatcher never blocks PM interactions, only cron agents.

### Force a run now

```bash
./scripts/dispatcher.sh --force-lead            # run the lead immediately
./scripts/dispatcher.sh --force-worker          # run on the oldest agent-todo issue
./scripts/dispatcher.sh --force-worker 42       # run on issue #42 specifically
```

Force flags bypass `active_hours` and both budget throttles. They still respect `paused`.

---

## GitHub Projects v2

`scripts/setup-project.sh` creates a Projects v2 board for the repo and saves the project
number to `schedule.json`. Once set, the lead adds every new issue to the board
automatically.

```bash
bash scripts/setup-project.sh
```

To view the board:
```bash
gh project view $(jq -r '.github.project_number' schedule.json) \
  --owner $(jq -r '.github.repo' schedule.json | cut -d/ -f1) --web
```

For a single view across **multiple repos**, add each project's issues to the same Projects
board (update `project_number` to the same value in each repo's `schedule.json`).

---

## schedule.json reference

| Field | Default | Meaning |
|-------|---------|---------|
| `paused` | `false` | Halt all runs immediately. |
| `worker_model` | `haiku` | Model for worker agents. |
| `karen_model` | `sonnet` | Model for the verifier. |
| `lead_model` | `sonnet` | Model for the lead. |
| `max_turns` | `25` | Hard cap on agentic turns for worker/karen. |
| `lead_max_turns` | `50` | Hard cap on agentic turns for lead. |
| `lead_paused` | `false` | Skip lead passes without halting workers/karen. |
| `lead_windows` | `[0]` | Minute values when the lead runs (top of hour). `[0,30]` = every 30 min. |
| `soft_budget_usd_per_5h` | `2` | Per-project self-throttle. `0` disables. |
| `telemetry.show_rolling_budget_in_status` | `true` | Updates `state/STATUS.md` with a spend bar. |
| `active_hours.start/end` | `0/24` | 24h clock window for cron runs. |
| `github.repo` | _(required)_ | `owner/repo` |
| `github.base_branch` | `main` | Branch agents never push to directly. |
| `github.work_branch` | `agents/work` | Branch for staging verified work before PRs. |
| `github.project_number` | _(optional)_ | Projects v2 board number. Set by `setup-project.sh`. |
| `max_worker_attempts` | `3` | Max worker attempts before moving issue to `agent-blocked`. |

---

## Caveats

- **Weekly cap.** Pacing smooths the 5-hour window but can't extend the weekly limit. Keep
  issues small and Haiku-only when approaching it.
- **Headless permissions.** Background runs auto-deny permission prompts. `settings.json`
  pre-allows common safe tools. If a worker stalls, widen the allowlist or add
  `--dangerously-skip-permissions` to the `claude` call in `dispatcher.sh`.
- **Token expiry.** OAuth tokens expire. If all agents fail with `rc=1`, run
  `claude setup-token` and update `.env`. The global budget check will pause agents rather
  than loop on repeated failures (which is what caused the token-burn incident).
- **cron environment.** cron runs with a bare PATH. `.env` must set `PATH` and
  `CLAUDE_CODE_OAUTH_TOKEN`. Copy from `.env.example` and verify with
  `env -i bash -c '. .env; claude --version'`.
