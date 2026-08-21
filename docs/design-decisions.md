# Design Decisions

Each entry records *why* a decision was made, what alternatives were weighed, and the trade-offs.
Reasoning is drawn from the source and its accompanying design notes; where the rationale is not fully
documented in the code, that is flagged with a TODO rather than guessed.

---

## 1. Three layers, replaceable adapters (generic core + tracker/project/AI seams)

**Decision.** Keep a generic core engine that knows nothing about the tracker, stack, or AI backend,
and push all specifics behind fixed-contract adapter files selected by one config file.

**Why.** The system began as automation for a single project on a single tracker. To reuse it
elsewhere, the tracker-specific and stack-specific knowledge had to be separable so the core, the
poller, and the prompts never change when the target changes.

**Alternatives considered.**
- A per-project fork of the whole automation. Rejected: divergent copies are unmaintainable.
- Configuration flags inside a monolithic script. Rejected: conditionals for every tracker/stack
  bloat the core and still leak specifics into it.

**Trade-offs.** Adapters add indirection and a contract to learn, and each new stack still requires
writing a real adapter (not just config). In exchange, the core stays small and stable and new
targets are additive.

---

## 2. Full-REST tracker access with an API token (no interactive-OAuth / agent-tool dependency)

**Decision.** The poller performs **all** tracker I/O — search, read, comment, transition — directly
over the tracker's REST API with a single API-token account. The dispatched AI workers do no tracker
calls at all.

**Why.** The workflow must run unattended (from cron, on a build host). An interactive OAuth flow or
an agent's tracker tool would require a human-in-the-loop session and machine-specific auth, defeating
automation.

**Alternatives considered.**
- Having the AI worker talk to the tracker through an agent/MCP tool. Rejected: reintroduces an
  interactive auth dependency and scatters tracker access across many callers.

**Trade-offs.** Under a single-account model every automated comment attributes to the same tracker
user, so a footer marker is needed to distinguish AI comments from human ones. In exchange, there is
exactly one tracker chokepoint, it works headlessly on any machine, and the AI workers stay sandboxed
away from the tracker.

---

## 3. The plan file as the seam between planning and implementation

**Decision.** A single structured plan document, committed on the ticket's feature branch, is the only
artifact connecting the planning phase to the implementation phase. It is versioned from creation,
refined on re-pickup, and never rewritten from scratch. Its status field drives the workflow.

**Why.** A durable, reviewable, git-versioned artifact gives the human approval gate something
concrete to read and approve, keeps the plan attached to the exact branch it describes, and lets the
implementation phase pick up precisely what was approved.

**Alternatives considered.**
- Passing plan content ephemerally between phases. Rejected: nothing durable to review or approve.
- Writing plans on the main branch. Rejected: plans belong with their feature branch and must not
  clutter or precede work on main.

**Trade-offs.** Requires a plan-status convention and discipline to refine-not-regenerate. In
exchange, review, approval, and implementation all key off one auditable file.

---

## 4. Human approval gate that automation cannot cross

**Decision.** The transition that approves a reviewed plan for implementation is reserved for a
person. The automation is built so it can never perform it — the tracker adapter does not even map
that transition, and workers cannot self-approve.

**Why.** Structural and irreversible decisions deserve human judgment. Fully autonomous "ticket in,
merge out" removes the checkpoint where a person should weigh in.

**Alternatives considered.** Fully autonomous end-to-end automation. Rejected on principle: no
approval checkpoint.

**Trade-offs.** Throughput is gated on a human being available to approve. That is the intended
safety property, not a bug.

---

## 5. Hard automation boundary — build and verify only

**Decision.** Unattended workers may build, test, and verify, but must never push to a shared remote,
merge, or deploy. This is enforced by a curated permission profile (allow build/test/verify + local
git; deny push, deploy, ssh, and reading secrets), not merely by instruction.

**Why.** Isolate risk. The worst an automated run can do is leave an un-pushed branch for a human to
review; it can never affect shared or production state.

**Alternatives considered.** Trusting prompt instructions alone to keep workers in bounds. Rejected:
instructions are not a security boundary; a permission sandbox is.

**Trade-offs.** A human must always do the final push/merge/deploy. Intended.

The Gemini provider (see DAV-2) approximates this boundary with coarser tools —
`--sandbox` + `--approval-mode yolo` + a tool-category `coreTools`/`excludeTools` settings file,
rather than Claude's per-command allow/deny. This gap is explicit and author-accepted, not
accidental; `lib/ai/gemini.sh` refuses to launch at all rather than run unrestricted when no
settings file is configured.

---

## 6. Isolation via per-ticket worktree + container + fresh database

**Decision.** Each implementation ticket gets its own git worktree, its own app container on its own
port, and its own database freshly built from committed migrations plus fixtures.

**Why.** Concurrent tickets must not collide, and building the schema from committed migrations also
continuously tests that the migration chain applies cleanly. A fresh seed avoids depending on
another environment's data.

**Alternatives considered.**
- Cloning an existing database instead of a fresh migrate+seed. Kept as an *option*, but fresh seed is
  the default because it also validates migrations and avoids importing stale/other-worktree data.
- Sharing one database across worktrees. Rejected: cross-worktree interference (a real failure the
  project has hit — see `lessons-learned.md`).

**Trade-offs.** Provisioning a fresh worktree is slower and heavier than reusing one, and a fresh seed
omits environment-specific assets (e.g. uploaded images). In exchange, isolation is clean and
migrations are exercised every time.

---

## 7. File-based coordination in a gitignored runtime state directory

**Decision.** The poller and detached workers coordinate purely through files in a gitignored state
directory: context, decisions, in-flight markers, running-slot process-id files, durable attempt
records, and logs. A lock guarantees a single poller instance.

**Why.** A detached background worker and a short-lived poll process need to hand off work without a
shared long-running service. Files are simple, inspectable, and survive process restarts.

**Alternatives considered.** A database or message queue for coordination. Rejected as heavyweight for
the scale and for a tool meant to drop into any repo.

**Trade-offs.** File-state needs careful staleness handling (reclaiming stale in-flight markers,
reaping dead slots) and is not distributed across machines. Accepted for a single-host poller.

---

## 8. Concurrency cap on implementation workers

**Decision.** Limit how many implementation workers run at once (configurable, small default). Extra
ready tickets wait for a slot to free on a later poll.

**Why.** Each worker provisions a container and a database and drives an AI agent — resource-intensive.
An unbounded fan-out would overwhelm the host.

**Trade-offs.** Ready tickets can wait. Acceptable; slots free as workers finish.

---

## 9. Watchdog with a retry budget and one-shot escalation

**Decision.** A third poller pass sweeps in-progress tickets, restarting a silently-dead or hung worker
in place up to a bounded number of attempts, and escalating with a single comment when the budget is
exhausted or the worker already reported a blocker. It acts only on tickets it can prove the harness
dispatched (via a durable attempts record), leaving human-moved tickets untouched.

**Why.** Detached workers can die silently; without a watchdog a ticket would sit stuck forever. But
blindly restarting a worker that already reported a real blocker just repeats the failure, and
restarting a ticket a human moved by hand would be wrong.

**Alternatives considered.** No watchdog (manual recovery only). Rejected: silent stalls are common
enough to automate recovery. Unlimited restarts. Rejected: risks loops on genuinely-stuck work.

**Trade-offs.** Requires a durable dispatch history that outlives the transient running-slot files,
plus a grace period so a still-provisioning worker is not mistaken for dead. Adds moderate complexity
to the poller in exchange for self-healing.

---

## 10. Distinguishing AI comments with an un-bypassable footer

**Decision.** Every tracker comment the automation posts gets a small footer marker, applied at the
single comment chokepoint used by both the poller and the worker helper CLIs.

**Why.** Under the single-account REST model, AI and human comments would otherwise be
indistinguishable. Placing the footer at the one chokepoint means it can never be forgotten or
bypassed — and it doubles as the watchdog's fingerprint for "the worker reported back."

**Trade-offs.** Slight noise on every comment. Worth it for provenance and for the watchdog signal.

---

## 11. Naming ahead of capability: `ai-intake-harness` with a stubbed provider seam

**Decision.** Introduce the AI-provider seam (environment check / run planning / run implementation)
with the Claude Code CLI as the only fully-working provider, plus a **stub** provider that fails
loudly and an **optional local-LLM** provider that routes the same agent invocation through a local
translation proxy. The provider can be overridden per-ticket by a tracker label; the model name stays
config-level.

**Why.** The seam is cheap to add and lets the whole pipeline be exercised end-to-end for multiple
providers, even before a second provider is fully built. The name anticipates multi-AI support.

**Alternatives considered.** Hardcoding the single agent until a second real provider exists. Rejected:
retrofitting a seam later is more disruptive than defining it up front behind a default that preserves
existing behavior.

**Trade-offs.** A stubbed provider that only fails is dead weight until implemented, and the local-LLM
path's full agentic behavior was not verified end-to-end from a host that can reach the local model
(flagged in-code). In exchange, the architecture is provider-ready and per-ticket selection works now.
A second real provider (Gemini, both planning and implementation phases) has since landed — see
DAV-2.

> TODO: The decision to make provider (but not model) label-overridable references a completed design
> note in the consumer repo; the full rationale for keeping the model config-only lives there and is
> summarized here rather than reproduced.

---

## 12. Vendoring into consumers via git subtree

**Decision.** Consumers vendor the harness into their repo (documented via git subtree) rather than
depending on it as an external package.

**Why.** The harness is shell scripts that must sit alongside the consumer's own project adapter,
config, and permission profiles, and run against the consumer's checkout. Vendoring keeps everything
in one repo and versioned together.

**Trade-offs.** Updates must be pulled in deliberately rather than resolved by a package manager.
Acceptable for a small, self-contained script tree.
