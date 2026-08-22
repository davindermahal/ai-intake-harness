# Architecture

High-level only. This describes the major components, their responsibilities, how data moves between
them, and which external systems are involved. It deliberately omits internal algorithms and
stack-specific logic.

## Design in one sentence

A background **poller** watches abstract ticket queues on an issue tracker, and for each matched
ticket dispatches an AI worker for the appropriate phase (planning or implementation), isolating each
unit of work in its own git worktree and staying within a build-and-verify-only boundary.

## The three layers and two adapter seams

The system is organized as one generic core plus two replaceable adapter seams (with a third seam
anticipated for AI providers).

```
            ┌─────────────────────────────────────────────┐
            │   CORE ENGINE  (the poller)                  │
            │   generic — no tracker/stack/AI knowledge    │
            │   - poll loop over abstract queues           │
            │   - in-flight set + concurrency cap          │
            │   - plan-file convention as the seam         │
            │   - dispatch: planning vs. implementation    │
            │   - watchdog over in-progress work           │
            └──────┬───────────────┬───────────────┬───────┘
                   │               │               │
          ┌────────▼──┐   ┌────────▼───────┐  ┌────▼──────────┐
          │ TRACKER   │   │ PROJECT        │  │ AI PROVIDER   │
          │ ADAPTER   │   │ ADAPTER        │  │ ADAPTER       │
          │ (in repo) │   │ (consumer repo)│  │ (in repo)     │
          └───────────┘   └────────────────┘  └───────────────┘
```

- **Core engine** — polls abstract queues, tracks which tickets are in flight, caps concurrency,
  dispatches workers, and sweeps in-progress work for stalls. It knows *nothing* about which tracker,
  which stack, or which AI backend it is driving; all of that is resolved from one config file.
- **Tracker adapter** — implements a fixed contract for one issue tracker (search a queue, read an
  issue, comment, transition, and supply a ticket-id pattern). A built-in adapter targets a hosted
  Jira instance over REST. Swapping trackers means writing a new adapter file, not editing the engine.
- **Project adapter** — lives in the *consumer* repository and implements a fixed contract for one
  tech stack (derive names, install dependencies, provision a fresh database, build, test, verify,
  and name a permission profile). This is where all stack-specific knowledge lives.
- **AI provider adapter** — implements a fixed contract (environment check, run planning, run
  implementation). The default drives the Claude Code CLI. Additional providers can be selected by
  configuration or, per-ticket, by a tracker label.

A single small **config loader** turns the config selections into concrete adapter files to source,
so every other script stays adapter-agnostic.

## Major components

### 1. The poller (core engine)

A long-running-per-invocation script, typically fired by cron on a short interval and guarded so only
one instance runs at a time. On each run it processes up to three passes:

- **Planning pass** — for each ticket in the abstract *planning* queue, dispatch an AI planning
  worker.
- **Implementation pass** — for each ticket in the abstract *implementation* queue, trigger an
  isolated worktree provision + a detached implementation worker, subject to a concurrency cap.
- **Watchdog pass** — sweep tickets already *in progress*; detect a worker that died silently or hung
  and either restart it in place (up to a retry budget) or escalate with a comment.

The poller performs **all** tracker I/O itself. The AI workers it dispatches never talk to the
tracker directly.

### 2. The planning worker (AI)

A headless AI run, invoked inside an ephemeral git worktree of the ticket's feature branch. It reads
the ticket from a context file the poller wrote, authors or refines a structured **plan file**, and
writes a **decision** telling the poller how to route the ticket (open questions vs. clean vs. skip).
It writes files and emits a decision — it does not touch the tracker or run git; the poller commits
the plan and acts on the decision.

### 3. The implementation trigger + worker

Implementation is triggered as plain automation: locate the ticket's feature branch (which carries
the approved plan), provision a fully-isolated worktree — its own app container, its own port, and a
**freshly-seeded database built from committed migrations** — flip the committed plan to an
"approved/ready" state, and launch a **detached** headless implementation worker. That worker
implements the approved plan, builds, runs tests, verifies against the running app, and posts its own
result summary back to the ticket. It stops at the automation boundary: no push, no merge, no deploy.

### 4. The worktree lifecycle tooling

A set of scripts and shared helpers manage the git-worktree lifecycle generically: create/reuse a
worktree, allocate free host ports, write per-worktree environment overrides, create/clone/drop a
per-worktree database (with guards so it can never drop the shared source database), start/stop the
per-worktree app container, and — for attended use — open a terminal and launch the agent
interactively. Everything stack-specific is delegated to the project adapter.

### 5. Helper CLIs for workers

Small scripts let a worker post a comment or perform a status transition through the *same* tracker
adapter the poller uses — a single REST chokepoint. This is how a detached worker reports its results
without ever calling a tracker API directly or via any agent tool.

## The abstract state machine

The workflow is expressed in abstract states that each tracker adapter maps onto its own status
vocabulary:

```
Backlog → Selected → Ready for Planning → Needs Author Input ⇄ Ready for Planning
   → Plan Review → Ready for Implementation → In Progress → Ready for Verification → Done
```

- The planning queue picks up tickets in *Ready for Planning*.
- A planning worker with open questions routes back to *Needs Author Input*; the author answers and
  moves it back to *Ready for Planning*, and the loop accumulates the Q&A into the plan.
- A clean plan routes to *Plan Review* — the human approval gate.
- **A person** moves an approved ticket to *Ready for Implementation*. The automation never performs
  this transition.
- Implementation runs while the ticket is *In Progress*; a successful worker moves it to *Ready for
  Verification*, and a person reviews the branch and merges.

> For the operator's view of this state machine — exactly which transitions *you* make versus which
> the automation makes, and the commands to observe/force/bypass each stage — see
> `workflow-and-triggers.md`.

## Data flow

1. **Poller → context file.** For a matched ticket, the poller reads the issue from the tracker and
   writes a normalized JSON context file into a gitignored runtime state directory.
2. **Context file → planning worker.** The worker reads the ticket context, authors/refines the plan
   file in a worktree, and writes a **decision file** (an action + a mandatory human-readable comment
   + the plan path).
3. **Decision file → poller → tracker.** The poller commits the plan onto the feature branch, posts
   the decision's comment to the ticket (always), optionally inlines the full plan text into the
   comment for review, and performs the routing transition.
4. **Implementation trigger → worktree → detached worker.** The poller launches the worktree
   provisioning + worker, records the worker's process id in a "running slot" file for the
   concurrency cap and liveness checks, and posts a launch note.
5. **Worker → result file → poller → tracker.** When the worker finishes, it writes a deterministic
   result file (`.ai/impl-result.json`) into the worktree instead of transitioning the ticket
   itself. The **poller** reads that file on the next poll (reaping the worker's freed running-slot)
   and, only on a confirmed `success` outcome, transitions the ticket to the verification state —
   keeping the transition-authority boundary in one place (the poller, which already owns every
   other tracker write) rather than split across the worker process too.
6. **Watchdog.** On later polls, the watchdog reads durable per-ticket dispatch records plus process
   liveness to decide healthy / restart / escalate, and comments accordingly.

All inter-process handoffs are **files in a gitignored runtime state directory** at the repo root:
per-ticket context, per-ticket decisions, in-flight markers, running-slot process-id files, durable
dispatch-attempt records, and per-ticket logs. This file-based protocol is what lets the poller and a
detached worker coordinate without a shared service.

## External systems

- **Issue tracker (e.g. hosted Jira).** Accessed by the tracker adapter over REST using a single API
  token account. Deliberately **no interactive-OAuth / agent-tool dependency**, so the workflow runs
  unattended.
- **Git.** Feature branches and worktrees are the unit of isolation; the approved plan travels on the
  feature branch.
- **The AI coding agent (Claude Code CLI by default).** Invoked headless for planning and
  implementation.
- **The consumer project's runtime (e.g. Docker + PostgreSQL).** Provisioned per worktree by the
  project adapter. External container/database orchestration is stack-specific and lives entirely
  behind the project-adapter seam.
- **An optional local-LLM path.** One provider adapter can redirect the agent's traffic through a
  local translation proxy to a locally-hosted model instead of a paid API. (See `design-decisions.md`;
  details are summarized, not exposed.)

## What is intentionally not covered here

Internal algorithms (queue draining order, stall taxonomy, slot reaping, port allocation), the exact
adapter function contracts, and any stack-specific provisioning logic are implementation detail. The
adapter contracts are documented for integrators in the project README; the reasoning behind the
major choices is in `design-decisions.md`.
