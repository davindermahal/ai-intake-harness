# Workflow & Triggers — How to Drive the Flow

This is the operator's runbook: **what you do to trigger each stage, what fires in response, and how
to observe or intervene.** Read `architecture.md` for the component picture; this doc is about the
buttons you actually press.

## The one thing to understand first

**You drive the pipeline by changing a ticket's status in the tracker.** There is (almost) nothing
else to click. A background **poller** runs on a schedule, notices tickets sitting in the statuses it
watches, and acts on them. Two of the transitions are performed *by the automation*; the rest — most
importantly the approval to implement — are performed *by you*.

Everything below uses the concrete Jira status names from the built-in tracker adapter. A different
tracker adapter maps the same abstract states onto its own status names.

## The state machine, annotated with who moves each arrow

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

- **Statuses the poller *watches* (queues):** `Ready for Planning`, `Ready for Implementation`,
  `In Progress` (watchdog).
- **Transitions the poller *performs*:** → `Needs Author Input`, → `Plan Review`, → `In Progress`,
  → `Ready for Verification`.
- **Transitions only *you* may perform:** everything else — and in particular
  **`Plan Review → Ready for Implementation`, the approval gate the automation will never cross.**

---

## Stage-by-stage: how to trigger each part

### 0. Get a ticket into the pipeline
- **You do:** create the ticket, then move it to **`Ready for Planning`**. (The `Backlog → Selected`
  steps are pre-pipeline and up to you; the harness only starts paying attention at *Ready for
  Planning*.)
- **Optional — pick the AI backend for this ticket, per phase:** add profile labels
  `ai-plan-<profile>` (who authors the plan) and/or `ai-impl-<profile>` (who implements it), where
  `<profile>` names an `AI_PROFILE_<name>="provider:model"` entry in `.ai/intake.config` — e.g.
  `ai-plan-opus` + `ai-impl-qwen` = Claude plans, the local Qwen implements. The legacy
  single-label form `ai-provider-claude` | `ai-provider-openai` | `ai-provider-local-llm` still
  works (both phases, provider only). With no label the configured default (`AI_PROVIDER` in
  `.ai/intake.config`, normally `claude`) is used.

### 1. Planning — trigger: status = `Ready for Planning`
- **What fires:** on its next run the poller picks the ticket off the planning queue, creates an
  ephemeral worktree of its feature branch, and runs a headless AI planning worker that authors/refines
  `.ai/plans/active/<KEY>-<slug>.md`.
- **Automation response — one of two routes:**
  - **Open questions →** poller commits the draft plan on the feature branch, posts a comment listing
    the questions, and moves the ticket to **`Needs Author Input`**.
  - **Clean plan →** poller commits the plan, posts a comment with the **full plan text inlined**, and
    moves the ticket to **`Plan Review`**.
- **You observe with:** `make intake-plan KEY=<KEY>` (prints the plan file) and the ticket comment.

### 2. Answering questions — trigger: comment + move back to `Ready for Planning`
- **You do:** answer the questions **in a ticket comment**, then move the ticket **back to
  `Ready for Planning`**.
- **What fires:** the poller re-plans, but **refines** the existing plan (folding your answers in and
  accumulating the Q&A) rather than regenerating it. It routes to `Needs Author Input` again or to
  `Plan Review` as before. This loop can repeat.

### 3. Approve the plan — trigger: `Plan Review → Ready for Implementation`  ← the human gate
- **You do:** read the plan (from the inlined comment, or `make intake-plan KEY=<KEY>`), and when
  satisfied move the ticket to **`Ready for Implementation`**.
- **This is the one transition the automation cannot make for you.** Nothing gets built until a person
  makes this move.

### 4. Implementation — trigger: status = `Ready for Implementation`
- **What fires:** the poller finds the ticket's `feature/<KEY>-*` branch (which carries the approved,
  committed plan), provisions a fully-isolated worktree — its own app container, port, and a
  **freshly-seeded database from committed migrations** — flips the committed plan to `ready`, and
  launches a **detached** headless implementation worker. It then posts a "launched" comment and moves
  the ticket to **`In Progress`**.
- **Concurrency:** only a capped number of workers run at once (`JIRA_MAX_WORKTREES`, default 2). Extra
  ready tickets wait for a slot to free on a later poll — no action needed from you.
- **You observe with:** `make intake-logs KEY=<KEY>` (tails that worker's implement/build/verify log).

### 5. Verification & merge — trigger: worker finishes → `Ready for Verification`
- **What fires (success):** the worker posts its build/verify results to the ticket and moves it to
  **`Ready for Verification`**.
- **What fires (failure/blocker):** the worker posts what went wrong and **leaves the ticket in
  `In Progress`** — so "still In Progress" reliably means "not finished".
- **You do:** review the branch diff and **merge it yourself. The automation never pushes, merges, or
  deploys** — that boundary is the whole safety model. Merging (and closing to `Done`) is your move.

---

## Re-running and recovery

- **Re-run an implementation** (e.g. after a verification bounce): move the ticket **back to
  `Ready for Implementation`**. The poller resumes *in the existing worktree* (branch, DB, and plan
  already there) and relaunches the worker. Moving it back also **resets the watchdog's retry budget**
  and clears any escalation.
- **Stuck ticket ("AI stuck" signal):** if a worker dies silently or hangs, the **watchdog** (the
  poller's `In Progress` sweep) restarts it in place up to `JIRA_MAX_ATTEMPTS` (default 3). When that's
  exhausted — or the worker already reported a real blocker — it posts a one-time escalation comment
  and **leaves the ticket in `In Progress`**. To re-queue after you've addressed it, move it back to
  `Ready for Implementation`.
- **The watchdog leaves human-moved tickets alone.** It only ever acts on tickets it can prove *it*
  dispatched, so a ticket you dragged to `In Progress` by hand is never touched.

---

## What actually runs the poller

The poller is fired by **cron** (never overlapping — a `flock` guards a single instance), typically
every 2 minutes, via a small host-only wrapper that `cd`s into the repo and calls the poller. Canonical
crontab shape (see the consumer's `JIRA-WORKFLOW.md` for the exact installed line):

```cron
*/2 * * * * cd /path/to/repo && /usr/bin/flock -n .intake/poll.lock \
    bash ai-intake-harness/intake-poll.sh >> .intake/poll.log 2>&1
```

> **Note:** the wrapper the crontab points at is commonly host-only / gitignored, so a rename or move
> of the scripts won't update it automatically. After any such change, confirm the poller still runs
> with `make intake-status`.

---

## Manual / operator commands (observe, force, bypass)

You rarely need these — moving the ticket is the intended interface — but they're the escape hatches.

### Observe
| Command | What it shows |
|---|---|
| `make intake-status` | Health dashboard: is the poller scheduled/running, queue counts, live workers. No KEY needed. |
| `make intake-plan KEY=TICKET-70` | Prints the plan file (active/, then completed/). |
| `make intake-logs KEY=TICKET-70 [LINES=200]` | Tails that ticket's latest implementation-worker log. |
| `make intake-poll-log [LINES=200]` | Tails the poller log (dispatch/commit/transition across all tickets). |

*(The `jira-plan` / `jira-logs` / `jira-poll-log` / `jira-status` aliases are the same commands under
their older names.)*

### Force a poll now (don't wait for cron)
```bash
bash ai-intake-harness/intake-poll.sh                 # run all passes once
bash ai-intake-harness/intake-poll.sh --mode planning       # just the planning pass
bash ai-intake-harness/intake-poll.sh --mode implementation # just implementation
bash ai-intake-harness/intake-poll.sh --mode watchdog       # just the In Progress sweep
bash ai-intake-harness/intake-poll.sh --dry-run             # show what it *would* dispatch, do nothing
```

### Drive a worktree directly (bypass the tracker)
```bash
# Attended: provision a worktree + open a terminal + launch the agent interactively
make worktree-go BRANCH=feature/TICKET-23-do-the-thing

# Headless (what the poller runs under the hood); RESUME reuses an existing worktree
make worktree-go BRANCH=feature/TICKET-23-do-the-thing HEADLESS=1 [RESUME=1]

# Override the AI backend / model for this run only (PROFILE resolves an
# AI_PROFILE_<name>="provider:model" entry from .ai/intake.config)
make worktree-go BRANCH=feature/TICKET-23-... PROVIDER=local-llm MODEL=<model>
make worktree-go BRANCH=feature/TICKET-23-... PROFILE=qwen
```

### Post a comment or transition by hand (same REST chokepoint the automation uses)
```bash
ai-intake-harness/tracker-comment.sh    TICKET-70 "note text"        # or: ... TICKET-70 -   (body from stdin)
ai-intake-harness/tracker-transition.sh TICKET-70 "Ready for Verification"
```
`tracker-transition.sh` resolves by target status name and only succeeds if that transition is legal
from the ticket's current status — so it can't be used to sneak past the `Plan Review → Ready for
Implementation` gate from an unrelated state.

---

## Cheat sheet: status → what happens

| You set status to… | Who picks it up | Result |
|---|---|---|
| `Ready for Planning` | poller (planning pass) | plan authored → `Needs Author Input` **or** `Plan Review` |
| `Needs Author Input` | *you* | answer in a comment, move back to `Ready for Planning` to re-plan |
| `Plan Review` | *you* (approval gate) | move to `Ready for Implementation` when the plan is good |
| `Ready for Implementation` | poller (implementation pass) | worktree provisioned, worker launched → `In Progress` |
| `In Progress` | worker + watchdog | success → `Ready for Verification`; failure/stall → stays `In Progress` (+ escalation) |
| `Ready for Verification` | *you* | review the branch diff and merge; nothing is pushed/merged automatically |

## Boundaries to remember
- The automation performs only four transitions (`Needs Author Input`, `Plan Review`, `In Progress`,
  `Ready for Verification`) and **never** `Plan Review → Ready for Implementation`.
- Unattended workers **build and verify only** — never push, merge, or deploy.
- The AI workers never talk to the tracker directly; all comments/transitions go through the poller and
  the helper CLIs (one REST chokepoint, and every automated comment carries an AI footer).
