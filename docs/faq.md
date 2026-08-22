# FAQ

Questions a future reader is likely to ask, with concise answers.

### What does this harness actually do?
It watches an issue tracker and, for each ticket in the right state, dispatches an AI coding agent to
either **plan** the ticket or **implement** an already-approved plan — isolating the work in its own
git worktree, building and verifying it, and reporting back to the ticket. A human approves the plan
in between and does the final merge.

### Does it merge or deploy code automatically?
No. There is a hard automation boundary: unattended workers may build, test, and verify only. They
never push to a shared remote, merge, or deploy. A human reviews the branch and merges. This is
enforced by a restricted permission profile, not just by instruction.

### Can the automation approve its own plans?
No. Approving a reviewed plan for implementation is a human-only transition. The system is built so it
cannot perform that step — the tracker adapter doesn't even map it.

### Which issue trackers are supported?
There is a built-in adapter for a hosted Jira instance (over REST, authenticated with an API token
or, if you can't get one issued, a browser session cookie fallback — see the next question). Other
trackers (e.g. GitHub Issues) can be supported by writing a new tracker adapter implementing the
same contract; a GitHub adapter is anticipated but not yet built.

### Do I need to install Python for the Jira adapter?
No, not by default. The Jira adapter normally authenticates with an API token over plain REST — no
Python involved. Python (plus `pip install browser_cookie3`) is only needed if you use the
**browser-cookie fallback**, for accounts that can't get an API token issued: it extracts a fresh
session cookie from your local Chrome/Firefox login on every run instead of using a token. See
`README.md` "Set up Jira credentials" for setup and `ai-intake-harness/install.sh --test-cookie` for
how to verify that path specifically.

### Which AI backends does it support?
Claude Code (the default), Gemini CLI, OpenAI's Codex CLI, and Google's Antigravity CLI are all
fully-working providers, each with its own automation-boundary flags (see `docs/design-decisions.md`
#5). There is also an experimental local-LLM provider (routes the Claude CLI through a local proxy
at a locally-hosted model's native Anthropic-compatible endpoint) — unverified end-to-end, see
`docs/lessons-learned.md`. No stub remains in the seam. The provider (and model) can be overridden
per-ticket via a tracker label, or per-profile via `.ai/intake.config`.

### How do I add it to my own project?
Vendor the harness into your repo, add one config file selecting the tracker and naming your project
adapter, write a project adapter for your stack (dependency install, fresh provision, build, test,
verify, permission profile), wire a few commands into your build tooling, set up the cron poller, and
create a restricted permission profile for unattended workers. The project README walks through each
step and documents the adapter contracts.

### What is a "project adapter" and why do I have to write one?
It's the module that teaches the generic core how to work with *your* stack — how to install
dependencies, create a fresh database, build, run tests, and verify the app is healthy. Because every
stack differs, this can't be generic; it lives in your repo and implements a fixed set of functions.

### How does the poller run, and can two run at once?
It's meant to run on a schedule (e.g. via cron every couple of minutes). A lock guarantees only one
instance runs at a time, so overlapping cron ticks don't collide.

### How many tickets can it implement simultaneously?
Implementation is concurrency-capped (a small configurable default). Each live worker holds a "slot";
once the cap is reached, additional ready tickets wait for a slot to free on a later poll.

### What happens if an AI worker crashes or hangs?
A watchdog pass detects it (via process liveness plus a durable dispatch record), and either restarts
it in place — up to a bounded retry budget — or, once retries are exhausted or the worker already
reported a real blocker, posts a one-time escalation comment and leaves the ticket in its stuck state
as a signal for a human.

### Will the watchdog interfere with a ticket I moved by hand?
No. It only acts on tickets it can prove the harness dispatched (they carry a durable attempts record).
A ticket a human moved into the in-progress state has no such record and is left alone.

### Where do plans live? Can I read one before approving?
Each plan is a structured file committed on the ticket's feature branch. Because it's committed locally
and not pushed, a clean plan's full text is inlined into the review comment on the ticket so you can
read and approve it without a checkout; a local command prints the same file.

### Why does the poller talk to the tracker instead of the AI agent?
So the whole workflow can run unattended. Using the tracker's REST API with a token (or, for accounts
that can't get one, a browser session cookie) avoids any interactive OAuth login or agent-side
tracker tool, and concentrates all tracker access in one place. The AI workers never touch the
tracker directly; they post results through helper scripts that use the same single chokepoint.

### How can I tell an AI-written comment from a human one?
Every comment the automation posts carries a small footer marker. Because it's applied at the single
comment chokepoint, it can't be bypassed.

### Does each ticket really get its own database? Isn't that wasteful?
Yes, each implementation ticket gets a freshly-seeded database built from committed migrations. It
costs provisioning time, but it keeps concurrent work fully isolated and continuously proves the
migration chain applies cleanly. A "clone an existing database" mode is also available.

### What's in the runtime state directory, and is it committed?
It holds all transient coordination files — ticket context, decisions, in-flight markers, running-slot
process ids, attempt records, logs, and the poll lock. It lives at the repo root and is gitignored.

### It picked up a ticket and then seemed to do nothing — why?
Common causes: the ticket had no feature branch / committed plan to implement (it must go through
planning first); the configured AI provider failed its environment check; or a worker wrote no decision
file and the ticket was left in-flight for a later retry. The poller log and the per-ticket logs in the
runtime state directory explain which.

### Can I run implementation interactively instead of headless?
Yes. The worktree tooling can open a terminal and launch the agent interactively (with a confirm-first
step), which is the attended path. Planning always runs headless.

### Is the local-LLM path production-ready?
Treat it as experimental. Its full agentic behavior wasn't verified end-to-end from a host that can
reach the local model, and the design flags a possible fallback to a planning-only mode if tool-use
translation proves unreliable for a given model.
