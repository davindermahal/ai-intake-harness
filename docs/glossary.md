# Glossary

Terms are written to be understandable by someone new to the project.

### Intake harness
The overall system: a set of scripts that watches an issue tracker and dispatches an AI coding agent
to plan and implement tickets, with human approval in between.

### Poller
The core background script. It runs on a schedule (typically via cron), checks the tracker's queues,
and dispatches the right kind of AI worker for each ticket. It does all communication with the
tracker; the AI workers never talk to the tracker themselves.

### Adapter
A small, replaceable module that teaches the generic core about one specific thing. There are three
kinds: **tracker adapters** (one per issue tracker), **project adapters** (one per tech stack), and
**AI provider adapters** (one per AI backend). Adding support for a new tracker/stack/AI means writing
a new adapter, not changing the core.

### Tracker adapter
The adapter that knows how to talk to a specific issue tracker — search a queue, read a ticket, post a
comment, change a ticket's status, and recognize ticket ids in branch names. A built-in adapter
targets a hosted Jira instance over REST.

### Project adapter
The adapter, living in the *consumer's* own repository, that knows how to work with a specific tech
stack — derive names, install dependencies, create a fresh database, build, run tests, verify the app
is healthy, and point to a permission profile. This is where all stack-specific knowledge lives.

### AI provider adapter
The adapter that knows how to invoke a specific AI backend for planning and implementation. The
default drives the Claude Code CLI. Others can be selected by configuration or per-ticket.

### Queue (abstract queue)
A named set of tickets the poller acts on, expressed generically rather than in one tracker's
vocabulary. The three queues are **planning** (tickets ready to be planned), **implementation**
(tickets approved and ready to be built), and **in-progress** (tickets currently being worked, swept
by the watchdog). Each tracker adapter translates these into its own query language.

### State machine / abstract states
The workflow expressed as tracker-neutral states (e.g. *Ready for Planning*, *Plan Review*, *Ready for
Implementation*, *In Progress*, *Ready for Verification*, *Done*). Each tracker adapter maps these onto
its own status names.

### Planning phase
The step where an AI worker reads a ticket and writes a structured **plan file** describing how to
implement it, then decides whether it needs to ask the author questions or the plan is clean. No
application code is written during planning.

### Implementation phase
The step where, after a human has approved the plan, an AI worker actually makes the code changes in
an isolated worktree, builds, tests, verifies, and reports back.

### Plan file
The single structured document that is the seam between planning and implementation. It captures goal,
scope, files to change, key decisions, implementation order, and open questions. It is committed onto
the ticket's feature branch and never rewritten from scratch — only refined.

### Plan status (draft / ready / active / completed)
A field in the plan file that drives the workflow. Planning always leaves a plan as **draft**; the
approval-to-implement step flips it to **ready**; it becomes **active** while being worked and
**completed** when done.

### Decision (decision file)
The small JSON document a planning worker writes to tell the poller how to route a ticket. It carries
an **action** (`questions`, `clean`, or `skip`), a **mandatory human-readable comment** the poller
posts to the ticket, and the plan-file path.

### Human approval gate
The one transition — approving a reviewed plan for implementation — that only a person may perform.
The automation is designed so it can never do this itself.

### Automation boundary
The hard rule that unattended automation may build and verify but must **never push, merge, or
deploy**. A human reviews the branch diff and merges.

### Worktree
A separate working directory checked out from a git branch. The harness gives each ticket its own
worktree so multiple pieces of work can proceed in isolation without colliding.

### Ephemeral worktree
A short-lived worktree used only during planning (checkout only, no running app). The poller creates
it, the planning worker authors the plan in it, the poller commits the plan, and the worktree is
removed.

### Fresh seed / provision
Building a worktree's database schema by running the project's committed migrations and then loading
sample/fixture data — as opposed to cloning an existing database. This also confirms the migration
chain applies cleanly.

### Headless / attended
**Headless** means the AI runs non-interactively (for cron/automation). **Attended** means a person
runs it in a terminal and interacts. Planning always runs headless; implementation can run either way.

### Detached worker
An implementation worker launched to keep running in the background after the launching process
returns, so the poller can move on. Its process id is recorded so the poller can check whether it is
still alive.

### Running slot
A record (a process-id file) that marks one live implementation worker. The poller counts these to
enforce a maximum number of simultaneous workers; extra ready tickets wait for a slot to free.

### Concurrency cap
The configurable limit on how many implementation workers may run at the same time.

### In-flight set / marker
Per-ticket markers the poller keeps so it does not re-pick a ticket that an earlier (possibly crashed)
run is still working on. Stale markers are automatically reclaimed after a timeout.

### Watchdog
The poller's third pass. It sweeps tickets that are *in progress* and, using durable dispatch records
plus process liveness, decides whether a worker is healthy, needs restarting, or the situation should
be escalated to a human with a comment.

### Attempts record
A durable per-ticket file recording how many times a stalled implementation has been launched and
when. It outlives the transient running-slot files, so the watchdog can enforce a retry budget and
know that a ticket was genuinely harness-dispatched (versus moved by a human).

### Escalation
When automatic retries are exhausted (or the worker already reported a blocker), the watchdog posts a
one-time "needs a human" comment and stops retrying, leaving the ticket in its stuck state as a signal.

### Runtime state directory
A gitignored directory at the repo root holding all transient coordination files: context, decisions,
in-flight markers, running slots, attempt records, logs, and locks. This file-based protocol lets the
poller and detached workers coordinate without a shared service.

### Permission profile
A curated allow/deny list under which an unattended worker runs, restricting it to build/test/verify
tooling and denying anything destructive (push, deploy, reading secrets). Named by the project
adapter.

### Full-REST design
The choice to have the poller do all tracker communication over the tracker's REST API with an API
token, rather than through an interactive/OAuth-based agent tool — so the workflow can run unattended
on any machine.

### AI-comment footer
A small marker appended to every tracker comment the automation posts, so an AI-written comment is
distinguishable from a human's. Because it is applied at the single comment chokepoint, it cannot be
bypassed.

### Local-LLM path
An optional provider configuration that redirects the AI agent's traffic through a small local
translation proxy to a locally-hosted model, so that path never uses a paid API.

### Consumer / consumer repository
The project that adopts the harness (typically by vendoring it in) and supplies a config file plus a
project adapter. The harness's first consumer is a Symfony + Docker web application.
