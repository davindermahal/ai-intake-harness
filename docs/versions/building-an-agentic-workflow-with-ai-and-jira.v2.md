# Building an Agentic Workflow with AI and JIRA

I filed the ticket from my phone. Sitting waiting in the cafe for my lunch to arrive. I
wrote a clear description, added two acceptance notes, and dragged the card into the right column in
the JIRA app.

Then I forgot about it.

By the time I had eaten my lunch, a plan was waiting for me. I read it, approved it, and went to
home. A while later, a finished branch was waiting too — built, tested, ready to review. I never
opened a terminal to get any of it started.

That is the workflow I want to walk through. Not "AI writes code" — that part is table stakes now.
The interesting part is the *system* around it. How an agent decides what to work on. How you stay in
control of the decisions that matter. And why isolation — the least glamorous piece — is the thing
that makes it safe enough to leave running while you make tea.

I'll give you the mental model first, then enough of the implementation to build your own.

## Why this matters

If you've pointed an AI agent at real work, you've hit the same walls I did.

**Manual dispatch doesn't scale.** Someone has to notice a ticket is ready. Gather its context.
Launch the agent. Babysit it. Do that across a whole backlog and the human *is* the bottleneck.

**There's no safe boundary.** Let an agent act on a shared branch, a shared database, or with
permission to deploy, and you're one bad run from a real mess. Work needs to happen somewhere
isolated — and stop short of anything you can't undo.

**There's no approval checkpoint.** "Ticket in, merge out" sounds efficient. It also deletes the one
moment where a person should look up and say "wait, not like that."

**Everything ends up welded together.** Ad-hoc automation hardcodes one tracker, one stack, one AI
backend. None of it survives to the next project.

Solve these and the payoff isn't just speed. It's being able to queue work from anywhere — your
phone, a meeting, the couch — and trust that it lands as a reviewable branch, never a surprise in
production.

## The mental model

Hold one idea in your head before anything else:

> **You drive the pipeline by changing a ticket's status. A background poller notices, and acts.**

That's almost the whole interface. No scripts to run. No other tool to open. You move a card from one
column to the next, and the automation responds to where it lands. Some moves are made by the
machine. The ones that matter — above all, approving a plan — are made by you.

The work runs in a straight line, with gates:

> **ticket → plan → (you approve) → isolated worktree → build/verify → report back**

Nothing merges. Nothing deploys. The worst an automated run can do is leave you a branch to look at.
That one property is the entire safety model.

### It's a conversation, not a command

The most valuable habit here is writing a good ticket. The agent knows only what the ticket tells
it. So be specific: the goal, the constraints, what "done" actually looks like. Vague ticket, vague
plan. Every time.

But you don't have to get it perfect. If the ticket is unclear, the planning agent doesn't guess — it
comes back with questions. You answer in a comment, move the card back, and it folds your answers
into the plan and tries again. That back-and-forth isn't friction. It's the point. Treat the ticket
as the opening line of a dialog: give it your best detail, and let the agent pull the rest out of you
before a single line of code exists.

### The workflow, and who moves each arrow

Here's the state machine, marked with who performs each move. The status names are the concrete JIRA
ones; the same abstract states map onto any tracker.

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

Read it as a conversation. You put a card in **Ready for Planning**. The agent comes back with
questions (**Needs Author Input**) or a clean plan (**Plan Review**). When the plan is good, *you*
move it to **Ready for Implementation** — the one gate the automation is built never to cross. From
there it implements, verifies, and lands in **Ready for Verification**, where you review and merge.

The machine performs exactly four of these transitions. Approving a plan is not one of them.

And this is what makes the phone part real. Every move on *your* side is just dragging a card. You
can plan, answer questions, and approve from anywhere. The provisioning and building happen back at
your desk, without you.

## The core concepts

A handful of ideas do most of the work. Learn these and the rest follows.

### The poller

The **poller** is the core background script. It runs on a schedule — cron, every couple of minutes,
guarded so only one copy runs at a time. Each run makes up to three passes:

- **Planning pass** — for every ticket waiting to be planned, launch a planning agent.
- **Implementation pass** — for every approved ticket, provision an isolated worktree and launch an
  implementation worker. Up to a limit.
- **Watchdog pass** — sweep the in-progress tickets and recover any worker that died quietly or hung.

One rule outranks the rest: **the poller does all tracker communication itself.** The agents it
launches never touch JIRA. Keep tracker access in one place, and the whole thing can run with nobody
watching.

### Plan first, implement second — with a human in the middle

Work happens in two phases, split by an artifact you can actually read.

In the **planning phase**, an agent reads the ticket and writes a structured **plan file**: goal,
scope, the files it expects to touch, key decisions, order of work, open questions. No application
code yet.

That plan file is the **seam** between the phases. It's committed on the ticket's feature branch,
versioned from the start, and *refined* on each pass — never regenerated from scratch.

In the **implementation phase** — which starts only after you approve — an agent makes the changes,
builds, tests, verifies, and reports back.

The plan file exists so your approval has something concrete to approve. You're not rubber-stamping a
vibe. You're reading a specific document the implementation will then follow.

### Isolation is what makes this safe

This is the concept I'd most want you to keep, because it's the easiest to underrate. **Every
implementation ticket gets its own git worktree. Its own app container, on its own port. Its own
freshly-seeded database.**

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

Why the trouble, instead of one shared environment?

- **Concurrent tickets never collide.** Two agents work at once and can't corrupt each other's
  branch, container, or data.
- **Building the database from committed migrations proves the migration chain applies cleanly** —
  every single run. A free integration test.
- **A fresh seed means the work never leans on some other environment's leftover data.**

I learned the flip side the hard way. A per-worktree container quietly resolved its database
connection to the shared main database. One worktree, reaching into the wrong data. Isolation only
holds if each worktree actually picks up its own environment — and when it doesn't, it fails in
exactly the way it was built to prevent. This isn't a nice-to-have. It's the ground the whole thing
stands on.

### The automation boundary

One hard rule. Unattended workers may build and verify. They may never push, merge, or deploy. A
human reviews the branch and merges. Full stop.

What matters is *how* that's enforced. Not a polite line in a prompt — instructions aren't a security
boundary. The workers run under a restricted permission profile: build, test, verify, and local git
allowed; pushing, deploying, and reading secrets denied. The boundary is structural. The worst a
runaway run can do is leave an un-pushed branch on the host.

## How it works under the hood

Now the implementation, deep enough to build your own. Here's one ticket's journey.

1. **You move a ticket to Ready for Planning.** On its next run the poller reads it from JIRA, writes
   the context to a file, and launches a planning agent inside a short-lived worktree of the feature
   branch.
2. **The agent writes a plan file and a small decision** — questions, clean, or skip. It writes files
   and emits that decision. It does not touch JIRA. It does not run git.
3. **The poller commits the plan, posts a comment, and moves the ticket** — to *Needs Author Input*
   (with the questions) or *Plan Review* (with the full plan text inlined, so you can read and
   approve straight from the JIRA app, no checkout needed).
4. **You approve** by moving it to Ready for Implementation. Your gate.
5. **The poller provisions an isolated worktree and launches a detached worker,** then moves the
   ticket to In Progress. Only so many workers run at once; the rest wait for a free slot.
6. **The worker implements the plan, builds, tests, verifies,** posts its results, and — on success —
   moves the ticket to Ready for Verification. On failure it says what broke and *leaves* the ticket
   in In Progress. So "still In Progress" reliably means "not done."
7. **You review the diff and merge.** The machine never does this.

### Coordination is just files

The poller and its detached workers talk through **files in a gitignored directory at the repo
root** — the ticket context, the plan decision, markers for what's in flight, records of which
workers are alive, retry history, logs. A short-lived poll process and a long-running background
worker need to hand off work with no shared service between them. Files are simple. Inspectable. They
survive restarts. (I'll spare you the exact names and formats — the shape is the point.)

### The watchdog recovers silent failures

Detached workers die quietly sometimes. Or hang. The watchdog — the poller's third pass — sweeps the
in-progress tickets and either restarts a dead worker in place, up to a bounded retry budget, or
escalates with a single comment once the retries run out. Two details keep it from becoming a
nuisance:

- **It only touches tickets it can prove *it* dispatched.** A durable per-ticket record marks
  harness-launched work. A ticket you dragged into "in progress" by hand has no such record. The
  watchdog leaves it alone.
- **It won't re-run a worker that already reported a real blocker.** Every automated comment carries
  a small footer marker. If the agent commented *after* its last launch, the watchdog reads that as
  "already reported back" and escalates instead of repeating the failure.

### Staying reusable: adapters, not forks

The core engine — poll loop, concurrency limit, plan-file convention, watchdog — knows nothing about
*which* tracker, *which* stack, or *which* AI backend it drives. All of that lives behind three kinds
of small, replaceable **adapters**:

| Adapter | Knows about | Example |
|---|---|---|
| **Tracker adapter** | one issue tracker | search a queue, read a ticket, comment, transition (JIRA over REST) |
| **Project adapter** | one tech stack | install dependencies, provision a fresh database, build, test, verify |
| **AI provider adapter** | one AI backend | run planning, run implementation |

New tracker, stack, or model? Write a new adapter. Don't touch the engine. The project adapter lives
in the *consumer's* own repo, because that's where all the stack-specific knowledge belongs. One more
detail worth naming: the poller talks to JIRA over its REST API with a token — deliberately not
through an interactive login or an agent-side tracker tool. That's what lets the whole workflow run
from cron with nobody home.

## Trade-offs, honestly

No design is free. These are the costs I took on purpose.

| Choice | What you gain | What it costs |
|---|---|---|
| Human approval gate | A real checkpoint on structural decisions | Throughput waits on a human to approve |
| Build-and-verify-only boundary | Automation can't touch shared or production state | Someone always does the final push and merge |
| Per-ticket worktree + container + fresh DB | Clean isolation; migrations exercised every run | Provisioning is slower; a fresh seed omits environment assets like uploaded images |
| File-based coordination | Simple, inspectable, no extra service | Needs careful handling of stale state; single-host, not distributed |
| Concurrency cap | The host doesn't get swamped | Ready tickets can wait for a slot |
| Adapters instead of a fork | The core stays small; new targets are additive | Each new stack means writing a real adapter, not flipping a flag |

Two of these deserve plain talk. The approval gate *is* a throughput limit — that's the point, not a
bug. And the isolation that makes concurrent work safe is also the fiddliest thing to operate. When
it breaks, it breaks in the exact way it was meant to prevent.

There's a maturity caveat too, and I'd rather say it than bury it. One AI provider works end-to-end.
A second is stubbed. An optional path to a locally-hosted model exists but hasn't been verified end
to end. The architecture is ready for many providers; not all of them are finished. And I've only run
this against my own project so far. It's *designed* to be reusable — but that reuse hasn't met a
second codebase yet. Take "it's generic" as intent I still have to prove, not a claim I've verified.

## Summary

The core idea is small. **Let people express intent by moving tickets. Let a background poller turn
that intent into AI-planned, AI-implemented work. Keep humans on the two levers that matter —
approving the plan, and merging the result.** Everything else exists to do that safely:

- A **poller** owns all tracker communication. The agents never touch JIRA.
- A **plan file** is the reviewable seam — so your approval is concrete, and a specific ticket (or a
  quick round of questions) is what makes the plan worth approving.
- **Isolation** — a separate worktree, container, and fresh database per ticket — is what turns
  concurrent, unattended work from reckless into safe.
- A structural **automation boundary** and a **watchdog** keep it trustworthy with nobody watching.

## Where to take this next

If this resonates, don't start with "adopt my harness." Start with your own workflow. Ask: which
decisions genuinely need a human, and which are manual only because nobody automated them yet? Draw
your version of that state machine. Mark every arrow with who should move it. The arrows you won't
hand to an agent are your approval gates. The rest are candidates.

Then get isolation right *before* you get clever with the AI. An agent that can only touch a
throwaway worktree and a throwaway database is one you can leave running. An agent with a path to
shared state is one you have to babysit — which puts you right back where you started.

Here's where I'm taking it from here:

- **Make the AI backend a deliberate choice** — pick the provider and model, a hosted API like OpenAI
  or Anthropic or a locally-run model, per project or even per ticket, instead of defaulting to
  whatever got wired in first.
- **Publish the harness to GitHub** so it can be picked up and reused, not left to sit in my repo.
- **Prove the reuse.** Drop it into a second project, a different stack, and find what the adapter
  seams don't yet cover. A design is only as generic as the second real use that tests it.

That's the plan, anyway. For now, the loop that matters already runs: I file a ticket from my phone,
walk away, and come back to work that's ready to review. Coffee still warm.
