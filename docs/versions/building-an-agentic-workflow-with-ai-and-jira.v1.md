# Building an Agentic Workflow with AI and JIRA

I filed a ticket from my phone on the walk back from lunch. I wrote a clear description, added a
couple of acceptance notes, and moved it to the right column in the JIRA app. By the time I sat back
down at my computer, there was a plan waiting for me to approve — and a while after I approved it, a
finished branch waiting for me to review. I never opened a terminal to get the work started.

That is the workflow I want to walk through here. Not "AI writes code" — that part is table stakes
now — but the *system* around it: how an AI coding agent decides what to work on, how you stay in
control of the decisions that matter, and why isolation is the unglamorous piece that makes the whole
thing safe enough to leave running. My goal is that you come away with the mental model first, and
then enough of the implementation to build your own version.

## Why this matters

If you have pointed an AI agent at real work, you have probably hit the same friction I did.

- **Manual dispatch doesn't scale.** Someone has to notice a ticket is ready, gather its context,
  launch an agent, and babysit it. Do that across a whole backlog and the human *is* the bottleneck.
- **There's no safe boundary by default.** Letting an agent act on a shared branch, a shared
  database, or with permission to push and deploy is asking for trouble. Work needs to happen
  somewhere isolated and stop short of anything you can't undo.
- **There's no natural approval checkpoint.** "Ticket in, merge out" removes the one moment where a
  person should weigh in on a structural decision.
- **Everything ends up tightly coupled.** Ad-hoc automation hardcodes one tracker, one tech stack,
  and one AI backend, so none of it survives to the next project.

The payoff of solving these is not just speed. It is being able to *queue work from anywhere* — your
phone, a meeting, the couch — and trust that it will land as a reviewable branch rather than a
surprise in production.

## The mental model

Hold one idea in your head before any of the components:

> **You drive the pipeline by changing a ticket's status. A background poller notices and acts.**

That's almost the whole interface. You don't run scripts or click buttons in some other tool. You
move a ticket from one column to the next, and the automation responds to where it lands. Some
transitions are done by the automation; the ones that matter — above all, approving a plan for
implementation — are done by you.

The shape of the work is a straight line with gates in it:

> **ticket → plan → (human approval) → isolated worktree → build/verify → report back**

Nothing merges or deploys on its own. The worst an automated run can do is leave you a branch to look
at. That single property is the entire safety model.

### It's a conversation, not a command

The most important habit to build is writing a good ticket. The agent only knows what the ticket
tells it, so **be specific in the description** — the goal, the constraints, what "done" looks like.

But you don't have to get it perfect. If the ticket is ambiguous, the planning agent doesn't guess —
it comes back with **questions**. You answer in a comment, move the ticket back, and it folds your
answers into the plan and tries again. That back-and-forth is a feature. Treat the ticket as the
start of a dialog: give it your best detail up front, and let the agent pull the rest out of you
before any code gets written.

### The workflow, and who moves each arrow

Here is the state machine, annotated with who performs each transition. The status names are the
concrete JIRA names; the same abstract states can map onto another tracker's vocabulary.

```
 (you)        (you)             (poller)            (you, in a comment)
Backlog → Selected → Ready for Planning → Needs Author Input ⇄ Ready for Planning
                            │                                        ▲
                            │ (poller, clean plan)                   │ (you: answer + move back)
                            ▼
                      Plan Review ── (YOU: approval gate) ──▶ Ready for Implementation
                                                                     │ (poller)
                                                                     ▼
                                                                In Progress
                                                        (worker: on success)│
                                                                     ▼
                                        Ready for Verification ──▶ (YOU: review diff + merge) ──▶ Done
```

Read it as a conversation. You put a ticket in **Ready for Planning**. The agent either comes back
with questions (**Needs Author Input**) or a clean plan (**Plan Review**). When the plan is good,
*you* move it to **Ready for Implementation** — the one gate the automation is built never to cross.
From there the agent implements, verifies, and lands the ticket in **Ready for Verification**, where
you review the diff and merge. The automation performs only four of these transitions; approving a
plan is not one of them.

This is what makes the phone workflow real: every one of *your* moves is just dragging a card in the
JIRA mobile app. You can plan, answer questions, and approve from anywhere, and let the machine do
the provisioning and building back at your desk.

## The core concepts

A handful of ideas do most of the work. Understand these and you can reason about the whole system.

### The poller

The **poller** is the core background script. It runs on a schedule — typically cron, every couple of
minutes, guarded so only one instance runs at a time. On each run it makes up to three passes over
the tracker:

- **Planning pass** — for each ticket waiting to be planned, dispatch an AI planning worker.
- **Implementation pass** — for each approved ticket, provision an isolated worktree and launch an
  implementation worker (subject to a limit on how many run at once).
- **Watchdog pass** — sweep tickets currently in progress and recover any worker that died silently
  or hung.

One rule matters more than the rest: **the poller does all tracker communication itself.** The AI
workers it launches never talk to JIRA directly. That keeps tracker access in one place and lets the
whole thing run unattended.

### Plan first, implement second — with a human in between

Work happens in two distinct phases, separated by an artifact you can read.

- In the **planning phase**, an agent reads the ticket and writes a structured **plan file**: the
  goal, the scope, the files it expects to touch, the key decisions, the order of work, and any open
  questions. No application code is written yet.
- The plan file is the **seam** between the phases. It is committed on the ticket's feature branch,
  versioned from the start, and *refined* on each pass rather than regenerated from scratch.
- In the **implementation phase** — which starts only after you approve the plan — an agent makes the
  actual changes, builds, tests, verifies, and reports back.

The plan file exists so your approval has something concrete to approve. You are not rubber-stamping a
vibe; you are reading a specific document the implementation will then follow.

### Isolation is what makes this safe

This is the concept I'd most want you to take away, because it's easy to underrate. **Every
implementation ticket gets its own git worktree, its own application container on its own port, and
its own freshly-seeded database.**

```
        ┌──────────────────────── one host ────────────────────────┐
        │                                                           │
        │   worktree: feature/TICKET-23      worktree: feature/TICKET-31
        │   ┌───────────────────────┐        ┌───────────────────────┐
        │   │ app container :PORT_A │        │ app container :PORT_B │
        │   │ database TICKET_23     │        │ database TICKET_31     │
        │   │ (fresh from migrations)│        │ (fresh from migrations)│
        │   └───────────────────────┘        └───────────────────────┘
        │            ▲                                   ▲            │
        │            └────────── never share state ─────┘            │
        └───────────────────────────────────────────────────────────┘
```

Why go to this trouble instead of sharing one environment?

- **Concurrent tickets never collide.** Two agents can work at once and cannot corrupt each other's
  branch, container, or data.
- **Building the database from committed migrations continuously proves the migration chain applies
  cleanly** — a free integration test on every run.
- **A fresh seed means the work doesn't depend on some other environment's leftover data.**

I learned the flip side the hard way: a per-worktree container that accidentally resolved its
database connection to the shared main database. Isolation only holds if each worktree actually picks
up its own environment; when it doesn't, you get exactly the cross-contamination the design was meant
to prevent. Isolation isn't a nice-to-have here — it's the property the whole approach rests on.

### The automation boundary

There is a hard rule: unattended workers may **build and verify, but never push, merge, or deploy.**
A human reviews the branch and merges.

The important part is *how* it's enforced. Not with a polite instruction in a prompt — instructions
aren't a security boundary. Unattended workers run under a restricted permission profile that allows
build, test, verify, and local git, and denies pushing, deploying, and reading secrets. The boundary
is structural. The worst case of a runaway run is an un-pushed branch sitting on the host.

## How it works under the hood

Now the implementation, at the level you'd need to build your own. Here is one ticket's journey.

1. **You move a ticket to Ready for Planning.** On its next run the poller reads the ticket from
   JIRA, writes the ticket's context to a file, and launches a planning agent inside a short-lived
   ("ephemeral") worktree of the feature branch.
2. **The agent writes a plan file and a small decision** telling the poller how to route the ticket:
   it has questions, the plan is clean, or skip. The agent writes files and emits that decision — it
   does *not* touch JIRA or run git itself.
3. **The poller commits the plan on the feature branch, posts a comment, and moves the ticket** — to
   *Needs Author Input* (with the questions) or *Plan Review* (with the full plan text inlined, so
   you can read and approve it from the JIRA app without checking anything out).
4. **You approve** by moving the ticket to Ready for Implementation. This is your gate.
5. **The poller provisions an isolated worktree and launches a detached implementation worker,** then
   moves the ticket to In Progress. Only a capped number of workers run at once; extras wait for a
   free slot on a later poll.
6. **The worker implements the approved plan, builds, tests, and verifies,** posts its results back
   to the ticket, and — on success — moves it to Ready for Verification. On failure it says what went
   wrong and *leaves* the ticket in In Progress, so "still In Progress" reliably means "not finished."
7. **You review the branch diff and merge.** The automation never does this step.

### Coordination is just files

The poller and its detached workers coordinate through **files in a gitignored directory at the repo
root** — the ticket's context, the plan decision, markers for what's in flight, records of which
workers are alive, retry history, and logs. A short-lived poll process and a long-running background
worker need to hand off work without a shared service between them, and files are simple, inspectable,
and survive restarts. (I'll spare you the exact file names and formats; the shape is what matters.)

### The watchdog recovers silent failures

Detached workers can die quietly or hang. The watchdog — the poller's third pass — sweeps in-progress
tickets and either restarts a dead worker in place (up to a bounded retry budget) or escalates with a
single comment once retries run out. Two refinements keep it trustworthy rather than annoying:

- **It only acts on tickets it can prove *it* dispatched.** A durable per-ticket record marks
  harness-launched work; a ticket you dragged into "in progress" by hand has no such record, so the
  watchdog leaves it alone.
- **It won't blindly re-run a worker that already reported a real blocker.** Every automated comment
  carries a small footer marker. If the agent posted a comment *after* its last launch, the watchdog
  reads that as "already reported back" and escalates instead of repeating a failure.

### Staying reusable: adapters, not forks

The core engine — the poll loop, the concurrency limit, the plan-file convention, the watchdog —
knows nothing about *which* tracker, *which* tech stack, or *which* AI backend it drives. All of that
lives behind three kinds of small, replaceable **adapters**:

| Adapter | Knows about | Example |
|---|---|---|
| **Tracker adapter** | one issue tracker | search a queue, read a ticket, comment, transition (a JIRA adapter over REST) |
| **Project adapter** | one tech stack | install dependencies, provision a fresh database, build, test, verify |
| **AI provider adapter** | one AI backend | run planning, run implementation |

Supporting a new tracker, stack, or model means writing a new adapter, not editing the engine. The
project adapter lives in the *consumer's* own repository, because that is where all the stack-specific
knowledge belongs. One detail worth calling out: the poller talks to JIRA over its REST API with a
token, deliberately *not* through an interactive login or an agent-side tracker tool — that's what
lets the whole workflow run from cron with nobody watching.

## Trade-offs, honestly

No design is free. These are the costs I took on purpose.

| Choice | What you gain | What it costs |
|---|---|---|
| Human approval gate | A real checkpoint on structural decisions | Throughput waits on a human being available to approve |
| Build-and-verify-only boundary | Automation can never touch shared or production state | Someone must always do the final push and merge |
| Per-ticket worktree + container + fresh DB | Clean isolation; migrations exercised every run | Provisioning is slower and heavier; a fresh seed omits environment-specific assets like uploaded images |
| File-based coordination | Simple, inspectable, no extra service to run | Needs careful handling of stale state; single-host, not distributed |
| Concurrency cap | The host doesn't get overwhelmed | Ready tickets can wait for a free slot |
| Adapters instead of a fork | The core stays small; new targets are additive | Each new stack still means writing a real adapter, not flipping a flag |

A couple of these deserve to be stated plainly rather than dressed up. The approval gate *is* a
throughput limit — that's the point, not a bug. And the isolation that makes concurrent work safe is
also the fiddliest part to operate; when it breaks, it breaks in the way most likely to cause the
exact problem it was meant to prevent.

There's a maturity caveat too. One AI provider is fully working end-to-end; support for a second is
stubbed, and an optional path to a locally-hosted model exists but hasn't been verified end-to-end.
The architecture is ready for multiple providers; not all of them are finished. Just as importantly,
I've only run this against *my own* project so far — the harness is designed to be reusable, but that
reuse hasn't been tested on a second codebase yet. Take "it's generic" as a design intent I still
have to prove, not a claim I've verified.

## Summary

The useful idea is small: **let people express intent by moving tickets, let a background poller turn
that intent into AI-planned and AI-implemented work, and keep humans on the two levers that matter —
approving the plan and merging the result.** Everything else serves doing that safely:

- A **poller** watches the tracker and owns all tracker communication; the agents never talk to JIRA.
- A **plan file** is the reviewable seam between planning and implementation, so your approval is
  concrete — and a good, specific ticket (or a quick round of questions) is what makes that plan good.
- **Isolation** — a separate worktree, container, and fresh database per ticket — is what makes
  concurrent, unattended work safe rather than reckless.
- A structural **automation boundary** and a **watchdog** for silent failures keep the system
  trustworthy without someone watching it.

And because your side of the workflow is just moving cards, you really can queue the work from your
phone and come back to finished branches.

## Where to take this next

If any of this resonates, the exercise I'd suggest isn't "adopt my harness" — it's to look at your
own team's workflow and ask: *which decisions genuinely need a human, and which are just manual
because nobody automated them yet?* Draw your own version of that state machine and mark each arrow
with who should move it. The arrows you're unwilling to hand to an agent are your approval gates; the
rest are candidates for automation. Then get isolation right *before* you get fancy with the AI — an
agent that can only touch a throwaway worktree and database is one you can leave running; one with a
path to shared state is one you have to babysit.

Here's where I'm taking it from here:

- **Make the AI backend a deliberate choice.** Select the provider and model — a hosted API like
  OpenAI or Anthropic, or a locally-run model — per project or even per ticket, rather than defaulting
  to whatever was wired in first.
- **Publish the harness to GitHub** so it can be picked up and reused, rather than living only in my
  own repo.
- **Prove the reuse.** Drop it into a second project with a different stack and see what the adapter
  seams don't yet cover — because a design is only as generic as the second real use that tests it.
