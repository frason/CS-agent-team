# SPEC — <project name>

_Living spec. The PM seeds it at kickoff from the `/plan` intake; the lead refines it during
discovery and marks slices "settled" before build tasks are queued. karen verifies work
against this document._

## Status
- Phase: discovery <!-- discovery | build | verify -->
- Settled slices: (none yet)
- Open: see `questions/`

## Overview
<one or two sentences: what we're building and for whom>

## Users & jobs
- Primary user: <who>
- The one job: <the single most important thing it must do>
- MVP = done enough to use when: <smallest usable version>

## Scope & non-goals
- In scope (v1): <bullets>
- Explicitly NOT doing (v1): <bullets>   ← karen flags anything built beyond this as over-engineering

## Main flow (happy path)
1. <step>
2. <step>
3. <step>

## Stack & integrations
- Runs as: <CLI | web app | service | …>
- Language/framework: <or "lead's choice">
- Integrates with: <APIs / services / data store / none>
- Auth/users: <yes/no + how>

## Acceptance & quality bar
- A feature is "done" when: <tests pass / demo flow / acceptance criteria>
- Quality bar: <coverage / performance / security / compliance, if any>

## Guardrails
- Agents must never: <secrets / prod / deploys / money / external sends / …>
- Decisions that come back to the client: <list>

## Build order & dependencies
<the lead fills this in: phases, and which tasks must precede which (becomes id/depends_on)>
