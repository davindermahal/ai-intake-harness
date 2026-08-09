# Lessons Learned

Problems encountered, mistakes, improvements, and interesting discoveries. These are drawn from the
code's own comments (which candidly document several hard-won fixes) and from the design's stated
open questions. Where a lesson is only partially documented, it is flagged with a TODO.

## Problems encountered & their fixes

### A detached worker's death must be recoverable
Implementation workers run detached, and a detached process can die silently or hang. Early on there
was no recovery — a stalled ticket would sit stuck indefinitely. This drove the **watchdog** pass: it
sweeps in-progress tickets, restarts a dead/hung worker in place up to a retry budget, and escalates
to a human once retries are exhausted. A subtle refinement: reaping dead worker slots used to happen
only while draining a non-empty implementation queue, so a hung worker wasn't even *killed* until new
ready work appeared. The watchdog now reaps unconditionally on every sweep.

### Transient slot files can't prove dispatch history
The running-slot files (one per live worker) are deleted as soon as a slot is reaped — so they can't
later prove the harness ever dispatched a ticket. That mattered because the watchdog must **not** act
on a ticket a human dragged to "in progress" by hand. The fix was a separate **durable attempts
record** that outlives slot reaping: no record ⇒ human-moved ⇒ leave it alone; a record ⇒ harness-
dispatched ⇒ eligible for restart/escalation.

### Restarting a worker that already reported a blocker just repeats it
Naively restarting any dead worker would re-run work that had already deliberately stopped with a real
blocker. The footer stamped on every AI comment doubles as a fingerprint: if an AI comment was posted
*after* the last launch, the watchdog treats it as "already reported back" and escalates instead of
restarting.

### A fresh worker looks "dead" while it's still provisioning
Right after launch, a worker hasn't recorded liveness yet, so a watchdog checking too soon would
misread it as dead and restart it. A **grace period** protects the provisioning window before the
watchdog will act on a ticket.

### The plan must live on the feature branch, not main
Plans are authored inside an ephemeral worktree of the ticket's feature branch and committed **there**,
never on main. This keeps a plan attached to exactly the branch that implements it and keeps main
clean. Because the plan is committed locally and never pushed, a tracker link to it would 404 — so on a
clean plan the poller inlines the **full plan text** into the review comment, read from the worktree
*before* the worktree is removed.

### Re-runs (bounces) must restore an archived plan and re-approve it
A successful run can archive the plan from "active" to "completed". On a re-dispatch (e.g. a
verification bounce), the worker reads the "active" location, so the tooling moves the plan back and
re-flips its status to "ready" before relaunching. An existing worktree auto-resumes in place rather
than erroring, so a re-dispatch never aborts on the leftover first-run worktree.

### The planning worker needs access to state outside its worktree
The ticket context file and the decision file live in the runtime state directory in the *main*
checkout, outside the planning worktree. A worker sandboxed strictly to its worktree couldn't read the
ticket or write its decision — so the launch explicitly grants access to that state directory.
Otherwise the poller sees "no decision file" and leaves the ticket stuck in-flight.

### Environment-file parsing edge cases
Credential/config values may contain characters that are unsafe to `source`, and env files may use
CRLF line endings or omit a trailing newline on the last line. The env readers deliberately extract
values without sourcing, strip carriage returns, and still process a final unterminated line — small
robustness fixes that avoid silent misconfiguration.

### A scheme-less tracker host silently breaks
A tracker URL without an `https://` scheme hits plain HTTP and gets redirected to an HTML error page,
which then fails to parse as JSON in confusing ways. The adapter now normalizes a scheme-less host by
prepending `https://`.

### Logs must go to stderr, not stdout
Helper functions echo results on stdout that callers capture (e.g. a live worker count). Any log line
on stdout would corrupt those captures, so all logging goes to stderr; the cron line merges both into
the log file, so nothing is lost.

## Lessons from the consumer integration

These surfaced while operating the harness in its first consumer project and are recorded in project
memory; they are integration lessons more than harness-code bugs:

- **Moving the script tree breaks host-only glue.** When the scripts were relocated into the
  `ai-intake-harness/` directory, things that referenced the old paths — a gitignored host-only cron
  wrapper, and the workers' final comment/transition step — broke until updated. Lesson: after any
  relocation or rename, verify the whole path end-to-end (a status/health command helps), because some
  glue is intentionally outside version control.
- **A worktree can accidentally resolve to the shared main database.** A per-worktree app container was
  observed resolving its database connection to the shared main database. The fix was recreating the
  container, not changing code — a reminder that per-worktree isolation depends on the container
  actually picking up the per-worktree environment overrides.

> TODO: The two integration lessons above are summarized from the consumer project's memory notes; the
> precise reproduction and root cause live in that project's history, not in this harness's source.

## Improvements made over time

- Extracted the single-project automation into a generic core plus adapters, so the same engine drives
  a different tracker/stack/AI without touching the poller or prompts.
- Introduced the AI-provider seam with the default agent preserved bit-for-bit, plus per-ticket
  provider selection by a tracker label.
- Added the watchdog, the durable attempts record, unconditional slot reaping, and the grace period —
  together turning silent stalls into self-healing-with-escalation.
- Added guards so a per-worktree database drop can only ever touch a correctly-prefixed worktree
  database and never the shared source database.

## Interesting discoveries

- **The same agent invocation works unmodified against a local model.** Because the agent sends its
  traffic to a configurable base URL, pointing it at a small local translation proxy lets the *identical*
  invocation drive a locally-hosted model instead of a paid API — no change to the invocation shape.
- **One comment footer serves two purposes.** The marker that distinguishes AI comments from human ones
  also became the watchdog's reliable "the worker already reported back" signal, avoiding a second
  mechanism.

## Known open questions / caveats

- The **local-LLM provider's** full agentic behavior was not verified end-to-end from a host that can
  actually reach the local model; the design flags a possible fallback to a planning-only, non-agentic
  mode if tool-use translation proves unreliable for a given local model.
- The **OpenAI provider is a stub** that fails loudly; its real integration was deferred to a follow-up.
- A **GitHub Issues tracker adapter** is anticipated but not yet built.
