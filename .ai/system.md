# System

## What this project is

A shell-script harness that watches an issue tracker's queues and dispatches an AI coding agent
(Claude Code CLI by default) to plan and implement tickets, with human approval gates in between.
It is vendored into consumer repos (via git subtree) rather than run standalone. Source:
`docs/overview.md`.

The end-to-end flow: **ticket → plan → (human approval) → isolated worktree → build/verify →
report back**, driven by a background **poller** (`intake-poll.sh`) fired from cron.

## Three layers, three adapter seams

- **Core engine** (`intake-poll.sh`) — polls abstract queues, tracks in-flight tickets, caps
  concurrency, dispatches workers, sweeps in-progress work (watchdog). No tracker/stack/AI
  knowledge.
- **Tracker adapter** (`lib/tracker/<name>.sh`) — one per issue tracker. Built-in: `jira.sh`
  (Jira Cloud, full REST, single account — API token, or a browser session cookie fallback for
  accounts that can't get a token issued). Contract: `tracker_load_env`,
  `tracker_search`, `tracker_get_issue`, `tracker_add_comment`, `tracker_transition`,
  `tracker_ticket_regex`.
- **Project adapter** (`scripts/lib/project/<name>.sh`, lives in the *consumer* repo, not here) —
  one per tech stack. Contract: `project_derive_names`, `project_install_deps`,
  `project_provision_fresh`, `project_build`, `project_test`, `project_verify`,
  `project_permission_profile`.
- **AI provider adapter** (`lib/ai/<name>.sh`) — one per AI backend. Contract: `ai_load_env`,
  `ai_run_planning`, `ai_run_implementation`. Built-in: `claude.sh` (fully working, default),
  `local-llm.sh` (routes the claude CLI directly at LM Studio's native Anthropic-compatible
  endpoint — experimental, unverified end-to-end per `docs/lessons-learned.md`), `openai.sh`
  (stub, fails loudly).

`lib/intake-config.sh` is the single place that turns `.ai/intake.config` selections (in a
*consumer* repo) into which concrete adapter files get sourced.

## Core principles (from `docs/design-decisions.md`)

- **Human approval gates are load-bearing, not optional.** `Plan Review → Ready for
  Implementation` is a transition only a person may perform; the tracker adapter doesn't even map
  it for automation to use.
- **Hard automation boundary: build and verify only.** Unattended workers never push, merge, or
  deploy — enforced by a curated permission profile, not just instructions.
- **Isolation by default.** Every ticket gets its own git worktree, its own app container, and a
  freshly-seeded database (from committed migrations), so concurrent work never collides.
- **Adapters, not forks.** Reusing this on a new tracker/stack/AI backend means writing a small
  adapter file, not editing the core engine or prompts.
- **Full-REST tracker access**, no interactive OAuth or agent-tool dependency, so the poller runs
  unattended from cron on any machine. All tracker I/O is a single chokepoint (the poller +
  `tracker-comment.sh` / `tracker-transition.sh`, all going through the tracker adapter).

## Glossary

Full terminology is in `docs/glossary.md`. Load-bearing terms used throughout the code and docs:

- **Plan file** — the structured document (`.ai/plans/active/<KEY>-<slug>.md` *in the consumer
  repo*) that is the seam between planning and implementation. Committed on the ticket's feature
  branch, never rewritten from scratch, only refined. Status field: `draft` → `ready` → `active` →
  `completed`.
- **Decision file** — small JSON a planning worker writes to tell the poller how to route a
  ticket: action (`questions`/`clean`/`skip`) + mandatory comment + plan path.
- **Runtime state directory** — `.intake/` at a consumer repo's root (gitignored): poll lock/log,
  per-ticket context/decision/in-flight/running-slot/attempt-record files, per-ticket logs. This
  is how the poller and detached workers coordinate without a shared service.
- **Watchdog** — the poller's third pass; restarts a dead/hung implementation worker in place (up
  to a retry budget) or escalates with a one-time comment, using a durable attempts record to
  never touch a ticket a human moved by hand.
- **Detached worker** — an implementation worker launched to keep running after the launching
  process returns; its PID is tracked as a "running slot" for the concurrency cap.

## Non-goals (v1), from `README.md` "Future directions"

- **Multi-AI abstraction is only partially built.** The `ai_*` seam exists and `claude.sh` is
  fully working; `openai.sh` is a stub that fails loudly; `local-llm.sh` is experimental. Naming
  (`ai-intake-harness`) anticipates more providers, but a second real one hasn't driven further
  design yet.
- **No GitHub Issues tracker adapter yet** — deferred until a second real tracker consumer exists
  to design against. Only `jira.sh` exists today.
