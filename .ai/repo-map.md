# Repo map

## Root scripts (executed directly, not sourced)

- **`intake-poll.sh`** — the core poller. Runs the planning pass, implementation pass, and
  watchdog pass over the configured tracker's abstract queues. `--mode planning|implementation|
  watchdog|both` and `--dry-run` flags. Meant to run under cron with a `flock` guard (single
  instance).
- **`worktree-go.sh`** — provisions a fully-isolated worktree (git worktree + app container +
  fresh-seeded database from committed migrations) and launches Claude on it, either attended
  (opens a terminal, one confirm-first step) or headless (`HEADLESS=1`, what the poller actually
  runs; `RESUME=1` reuses an existing worktree). This is what `make worktree-go` wraps.
- **`worktree-new.sh`** — lighter-weight worktree setup: creates the branch, writes
  `.env.local`, clones the *existing* main DB (vs. worktree-go's fresh seed), starts Docker,
  installs deps. No auto-launch of an agent.
- **`worktree-remove.sh`** — teardown counterpart to worktree-go/worktree-new. Removes the git
  worktree dir, app container + compose network, per-worktree database, and (if merged)
  the feature branch. Accepts an exact branch name, Jira-shorthand ticket key, or `--merged`.
- **`tracker-comment.sh`** — posts a comment to a ticket through the configured tracker adapter.
  Used by detached implementation workers to report results back (`KEY -` reads body from stdin);
  also usable by hand.
- **`tracker-transition.sh`** — transitions a ticket to a target status by name through the
  configured tracker adapter; only succeeds if the transition is legal from the ticket's current
  status (can't be used to sneak past the human approval gate).
- **`local-llm-spike.sh`** — standalone diagnostic script (not part of the runtime pipeline) that
  verifies the `local-llm` AI adapter's assumptions against a live LM Studio instance: server
  reachability, native `/v1/messages` endpoint presence, a real inference round-trip, tool-use
  emission, and optionally a full `claude -p` round-trip via `ANTHROPIC_BASE_URL`.

## `lib/` — sourced helper libraries

- **`lib/intake-config.sh`** — loads a consumer repo's `.ai/intake.config`, applies defaults, and
  sources the selected `tracker_*`/`project_*`/`ai_*` adapter files. The one place config
  selections become concrete adapter files; everything else stays adapter-agnostic.
- **`lib/worktree-common.sh`** — shared `wt_*`-prefixed helpers for worktree lifecycle: git
  worktree create/reuse, port allocation, env file writes, container start/stop, database
  create/clone/drop (with guards against ever dropping the shared source DB), terminal launch.
  Generic orchestration only — no stack-specific logic (that's the project adapter's job).
- **`lib/tracker/jira.sh`** — the built-in (and currently only) tracker adapter: Jira Cloud over
  REST with a single API-token account. Implements the full `tracker_*` contract.
- **`lib/ai/claude.sh`** — the default, fully-working AI provider adapter (Claude Code CLI).
  Extracted from what used to be inline poller/worktree-go logic; supports a model override via
  `AI_PLANNING_MODEL`/`AI_IMPLEMENTATION_MODEL`. Not guarded against re-sourcing, since a
  per-ticket tracker label can switch providers mid-poller-process.
- **`lib/ai/local-llm.sh`** — experimental AI provider adapter: points the claude CLI's
  `ANTHROPIC_BASE_URL` directly at LM Studio's native Anthropic-compatible endpoint so local
  models can drive the same agent invocation unmodified. Unverified end-to-end from a host that
  can reach a real local model (see `docs/lessons-learned.md`).
- **`lib/ai/openai.sh`** — stub AI provider adapter. Exercises the `ai_*` seam so
  `AI_PROVIDER=openai` / the `ai-provider-openai` label work end-to-end structurally, but fails
  loudly rather than doing anything real; real integration is deferred.

Note: **project adapters** (`scripts/lib/project/<name>.sh`, e.g. a Symfony/Docker adapter) are
not part of this repo — they live in each *consumer* repo that vendors this harness in, since
they encode stack-specific knowledge this harness deliberately doesn't have.

## `prompts/`

- **`prompts/intake-planning.md`** — the prompt driving the headless planning worker: read the
  ticket, author/refine the plan file, decide `questions`/`clean`/`skip` and write the decision
  JSON. Referenced directly by `intake-poll.sh`.

(The implementation-side prompts, e.g. `.ai/prompts/worktree-bootstrap.md` /
`worktree-bootstrap-auto.md` referenced in the root scripts' comments, live in the *consumer*
repo, not here.)

## `docs/`

Already comprehensive — read in full rather than re-summarized here beyond the pointers in
[`README.md`](README.md#read-order):

- `overview.md`, `architecture.md`, `workflow-and-triggers.md`, `design-decisions.md`,
  `glossary.md`, `faq.md`, `lessons-learned.md` — the core doc set, cross-referenced with each
  other.
- `permissions.yaml` — a PUBLIC/INTERNAL/CONFIDENTIAL/SECRET classification of extracted content,
  for downstream publishing decisions (not project code documentation per se).
- `article.md` — a working brief/outline for a blog post about this project.
- `building-an-agentic-workflow-with-ai-and-jira.md` and `versions/*.md` — the blog post itself
  and earlier drafts (v1, v2). Narrative/marketing content, not authoritative for how the code
  works — prefer the core doc set above for anything technical.

## Runtime state (not in this repo)

`.intake/` (poll lock/log, per-ticket context/decision/inflight/running/logs) and
`.ai/plans/active|completed/*.md` (plan files) are created at runtime **in the consumer repo**
that vendors this harness in — gitignored there, not part of this harness's own tree. See
`README.md` "Runtime state (gitignored)" at the repo root.

## This repo's own `.ai/`

Distinct from the consumer-repo `.ai/` described above: this directory is this harness project's
*own* AI-context layer (this file set) plus its own `plans/active/` and `plans/completed/` for
tracking development work on the harness itself.
