# ai-intake-harness

A tracker- and project-agnostic **ticket → plan → approval → worktree → build/verify → report**
intake harness for AI coding agents (Claude Code, with extensibility for Gemini/OpenAI/local LLMs).

Drive your issue tracker to automatically dispatch AI-powered planning and implementation into
git feature branches, with human approval gates in between.

---

## What it does

```
   you                AI                 you            AI               AI
 ┌──────┐   ┌────────────────────┐   ┌────────┐   ┌──────────────┐   ┌──────────┐
 │ write│──▶│   PLANNING         │──▶│ review │──▶│ IMPLEMENT    │──▶│   done   │
 │ticket│   │ ticket → plan file │   │  plan  │   │ worktree-go  │   │          │
 └──────┘   └────────────────────┘   └────────┘   └──────────────┘   └──────────┘
                     ▲   │
            answer   │   │ questions
                     └───┘
```

**Planning** (poller → headless AI worker):
1. Ticket enters `Ready for Planning` status.
2. Poller creates an ephemeral git worktree of the ticket's feature branch.
3. Headless Claude worker reads the ticket, authors a structured plan (`.ai/plans/active/TICKET-slug.md`).
4. If the plan has open questions, transitions the ticket back to the author. Otherwise, transitions to `Plan Review` where a human approves it.

**Implementation** (poller → `make worktree-go`):
1. Ticket enters `Ready for Implementation` (human approval).
2. Poller dispatches `make worktree-go HEADLESS=1` in a detached background worker.
3. Worker provisions a fresh worktree + database, implements the approved plan, runs build + test + verify.
4. Posts results back to the ticket and transitions to `Done` (or `Ready for Verification` if issues found).

**The state machine** (nine abstract states):
```
Backlog → Selected → Ready for Planning → Needs Author Input ⇄ Ready for Planning
→ Plan Review → Ready for Implementation → In Progress → Ready for Verification → Done
```

---

## How it's organized: Three layers, two adapter seams

```
                 ┌─────────────────────────────────────────┐
                 │   CORE ENGINE  (intake-poll.sh)          │
                 │   generic — no tracker/stack knowledge   │
                 │   - poll loop over abstract queues       │
                 │   - in-flight set, running-slot cap      │
                 │   - plan-file convention                 │
                 │   - dispatch: planning vs. implementation│
                 └──────────────┬─────────────┬─────────────┘
                                │             │
                    ┌───────────▼──┐     ┌────▼────────────┐
                    │ TRACKER      │     │ PROJECT ADAPTER  │
                    │ ADAPTER      │     │ (per target repo)│
                    │ lib/tracker/ │     │ scripts/lib/     │
                    │ *.sh         │     │ project/*.sh     │
                    └──────────────┘     └──────────────────┘
```

- **Core engine** (`intake-poll.sh`) — polls abstract queues, manages state transitions, dispatches workers. No knowledge of which tracker or which project.
- **Tracker adapter** (`lib/tracker/<name>.sh`) — implementation for a specific issue tracker (Jira Cloud, GitHub Issues, etc.). Exports: `tracker_load_env`, `tracker_search`, `tracker_get_issue`, `tracker_add_comment`, `tracker_transition`, `tracker_ticket_regex`.
- **Project adapter** (`scripts/lib/project/<name>.sh` in your consumer repo) — implementation for your stack (Symfony+Docker, Rails, Node, etc.). Exports: `project_derive_names`, `project_install_deps`, `project_provision_fresh`, `project_build`, `project_test`, `project_verify`, `project_permission_profile`.

---

## Quickstart: Adding the harness to a new project

### 1. Vendor the harness via git subtree

From your repo root:
```bash
git subtree add --prefix=ai-intake-harness https://github.com/davindermahal/ai-intake-harness.git main --squash
```

### 2. Create `.ai/intake.config` in your repo

Selects which tracker and project adapter to use:
```bash
TRACKER=jira                    # or github, or your custom tracker adapter
TRACKER_PROJECT_KEY=MYPROJ      # your tracker's project identifier
PROJECT_ADAPTER=my-stack        # selects scripts/lib/project/my-stack.sh in YOUR repo
PROJECT_DB_PREFIX=mydb          # database name prefix for worktrees (e.g., mydb_feature_1_...)
```

### 3. Write a project adapter for your stack

Create `scripts/lib/project/my-stack.sh`. It must export these functions:

**`project_derive_names <branch> <repo-root>`**
Sets: `SLUG`, `DB_SUFFIX`, `DB_NAME`, `PROJECT_NAME`, `APP_CONTAINER`, `TICKET`, `WORKTREE_DIR`

**`project_install_deps <worktree-dir>`**
Install your project's dependencies (npm install, composer install, etc.).

**`project_provision_fresh <container> <uid> <gid>`**
Create a fresh database schema + fixtures. Called once when a new worktree is provisioned.

**`project_build <worktree-dir>`**
Build/compile your project (webpack dev, Next.js build, etc.).

**`project_test <container>`**
Run your test suite. Return 0 on success.

**`project_verify <port>`**
Smoke test / health check. Your app should be running on `http://localhost:<port>`.
Return 0 if OK.

**`project_permission_profile`**
Echo the path to a `.claude/settings.*.json` file (permission allowlist for unattended workers).
Example: `.claude/settings.my-stack.json`.

For a worked example of a Symfony/Docker project adapter implementing this contract, see `scripts/lib/project/symfony-docker.sh` in the harness's original consumer project (private, not yet public).

### 4. Wire up the Makefile

Add these targets to your `Makefile`:

```makefile
worktree-go:
	@test -n "$(BRANCH)" || (echo "Usage: make worktree-go BRANCH=<branch> [PORT=<port>]" && exit 1)
	@SEED=$(SEED) CLAUDE=$(CLAUDE) TERMINAL=$(TERMINAL) bash ai-intake-harness/worktree-go.sh "$(BRANCH)" "$(PORT)"

worktree-new:
	@test -n "$(BRANCH)" || (echo "Usage: make worktree-new BRANCH=<branch> [PORT=<port>]" && exit 1)
	@bash ai-intake-harness/worktree-new.sh "$(BRANCH)" "$(PORT)"

worktree-remove:
	@test -n "$(BRANCH)$(MERGED)" || (echo "Usage: make worktree-remove BRANCH=<branch> | MERGED=1 [DRY_RUN=1]" && exit 1)
	@DRY_RUN=$(DRY_RUN) KEEP_BRANCH=$(KEEP_BRANCH) FORCE=$(FORCE) KEEP_DB=$(KEEP_DB) AUTO_SYNC=$(if $(AUTO_SYNC),$(AUTO_SYNC),1) \
	  bash ai-intake-harness/worktree-remove.sh $(if $(MERGED),--merged,"$(BRANCH)")

intake-poll-log:
	@tail -n $(or $(LINES),200) .intake/poll.log

intake-plan:
	@test -n "$(KEY)" || (echo "Usage: make intake-plan KEY=<TICKET-NN>" && exit 1)
	@f=$$(ls .ai/plans/active/$(KEY)-*.md .ai/plans/completed/$(KEY)-*.md 2>/dev/null | head -1); \
	 if [ -n "$$f" ]; then echo "==> $$f"; echo; cat "$$f"; else echo "No plan for $(KEY)" >&2; exit 1; fi
```

> The poller itself takes only `--mode planning|implementation|watchdog|both` and `--dry-run` —
> status/log helpers are consumer-side Makefile recipes over the `.intake/` state dir; the
> `intake-*` targets above are a minimal set, worth extending with your own dashboard/status
> script over the same `.intake/` files as your usage grows.

### 5. Set up the cron poller

Create a small wrapper script for cron — the harness does **not** ship one, because the wrapper
holds host-specific credentials (Claude auth) and paths. Keep it out of git (gitignore whatever
you name it, e.g. `scripts/intake-cron.sh`):

```bash
# intake-cron.sh (consumer-created, gitignored; chmod +x)
export HOME=/home/<you>
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"   # claude + make + jq + docker
export ANTHROPIC_API_KEY="$(cat "$HOME/.secrets/anthropic_key")"   # or CLAUDE_CODE_OAUTH_TOKEN
cd /path/to/repo
exec /usr/bin/flock -n .intake/poll.lock bash ai-intake-harness/intake-poll.sh
```

Then add a crontab entry (e.g., every 2 minutes):
```bash
*/2 * * * * /path/to/repo/scripts/intake-cron.sh >> /path/to/repo/.intake/poll.log 2>&1
```

(The `flock` in the wrapper guarantees concurrent runs don't collide. Because the wrapper is
host-only and gitignored, renaming harness scripts never updates it — re-check it after renames.)

### 6. Create a curated permission profile

Write `.claude/settings.<adapter-name>.json` with an allow/deny list for unattended workers.
Restrict to build/test/verify tools; deny anything destructive.

Example (for a Node/Docker setup):
```json
{
  "permissions": {
    "defaultMode": "default",
    "allow": [
      "Read", "Edit", "Write", "Glob", "Grep",
      "Bash(docker exec:*)",
      "Bash(npm:*)",
      "Bash(git add:*)",
      "Bash(git commit:*)",
      "Bash(curl -s http://localhost:*)"
    ],
    "deny": [
      "Bash(git push:*)",
      "Bash(make deploy:*)",
      "Read(.env)"
    ]
  }
}
```

For Gemini (`AI_PROVIDER=gemini`), write `.gemini/settings.<adapter-name>.json` instead, using
Gemini's `coreTools`/`excludeTools` schema to restrict tool categories (e.g. exclude
`run_shell_command` entirely, or scope `coreTools` to only the specific tools your build/verify
flow needs). Gemini's model is coarser than Claude's per-command allow/deny — there's no
equivalent of denying `Bash(git push:*)` specifically while allowing other shell commands; you're
choosing whole tool categories on or off.

---

## Adapter contracts

### Tracker adapter: `lib/tracker/<name>.sh`

Implement these shell functions:

- **`tracker_load_env <repo-root>`** — load/validate tracker credentials from `.env` or elsewhere. Exit with error if missing.
- **`tracker_search <queue>`** — echo ticket keys, one per line. Queues: `planning` (tickets ready for planning), `implementation` (tickets ready for implementation).
- **`tracker_get_issue <key>`** — echo JSON: `{summary, status, description, comments}` (bodies as plain text).
- **`tracker_add_comment <key> <text>`** — post a comment to the ticket. Text may span lines.
- **`tracker_transition <key> <state>`** — transition the ticket to an abstract state. States: `needs-author-input`, `plan-review`, `ready-for-implementation`, `in-progress`, `ready-for-verification`, `done`.
- **`tracker_ticket_regex`** — echo a regex pattern to extract ticket keys from branch names (e.g., `PROJ-[0-9]+` for Jira).

**Built-in adapter:** `lib/tracker/jira.sh` — Jira Cloud REST, single API-token account.

### Project adapter: `scripts/lib/project/<name>.sh`

Implement these shell functions (documented above):
- `project_derive_names <branch> <repo-root>`
- `project_install_deps <worktree-dir>`
- `project_provision_fresh <container> <uid> <gid>`
- `project_build <worktree-dir>`
- `project_test <container>`
- `project_verify <port>`
- `project_permission_profile`
- `project_gemini_permission_profile` *(optional — only required to select `AI_PROVIDER=gemini`
  for the implementation phase)*. Echoes the path to a Gemini-schema (`coreTools`/`excludeTools`)
  settings file — see "AI provider adapter" below.

### AI provider adapter: `lib/ai/<name>.sh`

Implement these shell functions:

- **`ai_load_env`** — validate the CLI/credentials this provider needs are present. Fail loudly
  (non-zero exit, message to stderr) rather than deferring to a confusing failure mid-run.
- **`ai_run_planning <key> <branch> <ctx-file> <decision-file> <worktree-dir>`** — run the
  planning routine headlessly inside the given worktree.
- **`ai_run_implementation <logfile> <pidfile>`** — launch a DETACHED headless implementation
  worker, writing its PID to `<pidfile>`.

**Built-in adapters:** `lib/ai/claude.sh` (Claude Code CLI, default, fully working — both
phases; automation boundary via a curated per-command allow/deny `--settings` profile, see
`project_permission_profile`) · `lib/ai/gemini.sh` (Gemini CLI, fully working — both phases;
automation boundary via `--sandbox` + `--approval-mode yolo` + a tool-*category*-level
`coreTools`/`excludeTools` settings file, see `project_gemini_permission_profile` — coarser-grained
than Claude's, an accepted trade-off, see `docs/design-decisions.md` #5) · `lib/ai/local-llm.sh`
(routes the claude CLI at a local model server — experimental) · `lib/ai/openai.sh` (stub, fails
loudly).

Selection: `AI_PROVIDER` in `.ai/intake.config` (default `claude`), overridable per-ticket via a
tracker label — see `intake-poll.sh`'s `resolve_ai_profile`.

---

## Runtime state (gitignored)

**`.intake/`** at the repo root holds:
- `poll.lock` — flock guard (single-instance poller)
- `poll.log` — cron output
- `context/<KEY>.json` — ticket data for planning workers
- `decision/<KEY>.json` — worker decisions (plan file path + routing)
- `inflight/<KEY>` — dedup marker files
- `running/<KEY>.pid` — implementation-worker slots (concurrency cap)
- `logs/<KEY>-*.log` — per-ticket worker logs

---

## Architecture notes

- **No MCP calls, full REST.** Tracker adapters use REST (no Atlassian MCP dependency; works on any machine).
- **Headless + attended.** Planning always runs headless (non-interactive). Implementation can run attended (`make worktree-go` in a terminal, which launches Claude interactively) or headless (for CI/cron automation).
- **Plan file as the seam.** A plan (`.ai/plans/active/TICKET-slug.md`) is committed on the ticket's feature branch. Versioned from creation, never rewritten. Plan status (`draft`/`ready`/`active`/`completed`) drives the workflow.
- **Permission sandbox.** Unattended workers run under a curated `.claude/settings` profile, deny-listing destructive operations (push, deploy, secret reads).
- **Concurrency-capped implementation.** Environment variable `JIRA_MAX_WORKTREES` (default 2) limits simultaneous implementation workers; extras wait for a slot to free.

---

## Future directions (non-goals for v1)

- **Fine-grained Gemini permissions.** `lib/ai/gemini.sh` covers both phases, but its
  implementation-phase automation boundary is tool-*category*-level (`coreTools`/`excludeTools`),
  coarser than Claude's per-command allow/deny — porting Claude's exact granularity to Gemini
  would require the Gemini CLI to grow an equivalent mechanism first. `lib/ai/openai.sh` remains a
  stub entirely.
- **GitHub Issues tracker adapter.** Deferred until a second real tracker consumer exists to design against; not yet built.

---

## References

This harness was extracted from a private Jira-driven Symfony/Docker project, where it was
generalized behind the `tracker_*`/`project_*` adapter seams described above so it could be
dropped into other projects. That project remains the harness's first real-world consumer, but
isn't public.
