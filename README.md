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
- **Tracker adapter** (`lib/tracker/<name>.sh`) — implementation for a specific issue tracker (Jira Cloud, GitHub Issues, etc.). Exports: `tracker_load_env`, `tracker_search`, `tracker_get_issue`, `tracker_add_comment`, `tracker_transition`, `tracker_ticket_regex`, `tracker_abstract_state`.
- **Project adapter** (`scripts/lib/project/<name>.sh` in your consumer repo) — implementation for your stack (Symfony+Docker, Rails, Node, etc.). Exports: `project_derive_names`, `project_install_deps`, `project_provision_fresh`, `project_migrate`, `project_build`, `project_test`, `project_verify`, `project_permission_profile`.

---

## Quickstart: Adding the harness to a new project

### 1. Vendor the harness via git subtree

From your repo root:
```bash
git subtree add --prefix=ai-intake-harness https://github.com/davindermahal/ai-intake-harness.git main --squash
```

### 2. Set up Jira credentials

Run the install helper from your repo root:
```bash
ai-intake-harness/install.sh
```
At a real terminal, it interactively walks you through both `.env.local` (gitignored — Jira site
URL, then either an API token or, if you don't have one, an on-the-spot offer to set up the
browser-cookie3 venv fallback) and `.ai/intake.config` (step 3 below — tracker, project key, app
tag), then scaffolds the `scripts/intake-cron.sh` wrapper from step 6's template (gitignored — you
still need to fill in `ANTHROPIC_API_KEY`), prints the crontab entry with your repo's actual path
baked in (or installs it directly with `--install-cron`), and tests that the harness can reach
Jira with whatever you just entered. Piped/scripted/CI runs (no TTY attached) skip the prompts and
fall back to copying `.env.local.dist` and printing what to fill in instead — safe to automate:
```bash
ai-intake-harness/install.sh < /dev/null
# ... fill in .env.local (JIRA_SITE_URL, JIRA_INTAKE_EMAIL, JIRA_INTAKE_API_TOKEN) and
#     .ai/intake.config (step 3) by hand ...
ai-intake-harness/install.sh --test-only
```

**No API token available** (e.g. blocked by org policy)? Leave `JIRA_INTAKE_EMAIL`/
`JIRA_INTAKE_API_TOKEN` blank in `.env.local` instead — the harness falls back to authenticating
with a browser session cookie. This is the **only** thing in the harness that needs Python; if
you're using the API token, skip this whole section, nothing here applies to you.

- **Setup:** `pip install browser_cookie3` on the machine that runs cron, and stay logged into
  Jira in Chrome or Firefox there. Don't want it installed system-wide? Run
  `ai-intake-harness/install.sh --install-browser-cookie3` instead — it creates a venv at
  `~/.venvs/browser-cookie3` and installs the package there; the harness finds it automatically
  (falls back to that venv's python3 whenever the plain `python3` on PATH doesn't have the
  package — see `lib/tracker/jira-cookie.sh`'s `_jira_cookie_python`), no `PATH` changes needed.
  Safe to re-run.
- **How it works:** a fresh cookie is extracted straight from the browser's cookie store on every
  run (each poll cycle, each `tracker-comment.sh`/`tracker-transition.sh` invocation) — it's never
  written to disk or cached, so as long as you stay logged in, it keeps working with no further
  action from you. By default it tries every browser it can find and uses whichever has a working
  Jira session; to pin one specific browser instead, set `JIRA_COOKIE_BROWSER=chrome` (or
  `firefox`, `edge`, `brave`, ...) in `.ai/intake.config` (step 3) for normal runs, or as a one-off
  env var prefix (e.g. `JIRA_COOKIE_BROWSER=firefox ai-intake-harness/install.sh --test-cookie`)
  when testing — the connectivity check in `install.sh` doesn't read `.ai/intake.config`, even
  though the wizard in step 2 may have just created it.
- **Requires a real desktop login session** — it reads the OS keyring (GNOME Keyring/KWallet) to
  decrypt Chrome's cookie store, so this doesn't work on a headless box with no browser/desktop
  session on it. If your browser session itself ever fully expires, the harness fails loudly
  (rather than silently doing nothing) telling you to log into Jira in your browser again — there's
  no way for it to safely log back in on its own.
- **Test this path specifically** — even with a valid token already configured, to confirm the
  fallback actually works before you rely on it:
  ```bash
  ai-intake-harness/install.sh --test-cookie
  ```
  This forces cookie auth for that one check (ignoring any token in `.env.local`) and reports which
  account it connected as and which mode it used, e.g.
  `OK — connected to https://your-site.atlassian.net as Your Name (auth: cookie).`

See `.ai/plans/completed/jira-cookie-auth-fallback.md` for the full design and its trade-offs (in
short: this mode needs an actively logged-in desktop browser session, a real departure from "runs
unattended" — use the API token whenever you can get one).

### 3. Create `.ai/intake.config` in your repo

`install.sh` (step 2) already created this for you interactively if it was run at a terminal —
edit it if you need to change anything. Otherwise, create it yourself; it selects which tracker
and project adapter to use:
```bash
TRACKER=jira                    # or jira-tags, github, or your custom tracker adapter
TRACKER_PROJECT_KEY=MYPROJ      # your tracker's project identifier
# TRACKER_APP_TAG=app:my-app-name-1   # required only for TRACKER=jira-tags — see below
# TRACKER_GATE_COMMENTS=true          # TRACKER=jira-tags only; default false (comments ungated) — see below
# TRACKER_NATIVE_STATUS_IN_PROGRESS=In Development   # TRACKER=jira-tags only; this project's board
#                                      # column name for "actively being worked" (default "In Progress")
# TRACKER_NATIVE_STATUS_CODE_REVIEW=Code Review      # TRACKER=jira-tags only; this project's board
#                                      # column name for "ready for review" (default "Code Review")
# JIRA_COOKIE_BROWSER=chrome          # only relevant if you're using the cookie auth fallback
#                                      # (no API token — see step 2) and want to pin one browser;
#                                      # install.sh doesn't read this file, so pass it as an env
#                                      # var prefix instead when testing with --test-cookie
PROJECT_ADAPTER=my-stack        # selects scripts/lib/project/my-stack.sh in YOUR repo
PROJECT_DB_PREFIX=mydb          # database name prefix for worktrees (e.g., mydb_feature_1_...)
# PROJECT_ADAPTER_PATH=scripts/lib/project   # override where PROJECT_ADAPTER.sh is looked up;
#                                      # default is scripts/lib/project relative to your repo root
```

### 4. Write a project adapter for your stack

Create `scripts/lib/project/my-stack.sh`. It must export these functions:

**`project_derive_names <branch> <repo-root>`**
Sets: `SLUG`, `DB_SUFFIX`, `DB_NAME`, `PROJECT_NAME`, `APP_CONTAINER`, `TICKET`, `WORKTREE_DIR`

**`project_install_deps <container> <uid> <gid> <worktree-dir>`**
Install your project's dependencies (npm install, composer install, etc.) inside the running
container, as the given uid/gid so bind-mounted files stay owned by the host user.

**`project_provision_fresh <container> <uid> <gid> <repo-root> <db-name> <pg-user> <pg-password>`**
Create a fresh database schema + fixtures. Called once when a new worktree is provisioned with
`SEED=fresh` (worktree-go.sh's default).

**`project_migrate <container> <uid> <gid>`**
Run pending migrations only (no fixtures). Called instead of `project_provision_fresh` when a
worktree is provisioned with `SEED=clone` (clone the main DB) or `SEED=none` — both worktree-go.sh
and worktree-new.sh take this path. Required in practice even though nothing else in this section
enforces it; make sure `install.sh --verify`'s adapter-completeness check covers it too (see that
script's `required=` list).

**`project_build <worktree-dir>`**
Build/compile your project (webpack dev, Next.js build, etc.).

**`project_test <container>`** / **`project_verify <port>`**
Convention, not something the harness calls directly: build/test/verify actually happens inside
the AI worker's own agentic session (its prompt is expected to run your project's own
`make test`/`make verify` targets, or equivalent), not via a direct call from worktree-go.sh or
intake-poll.sh. Define these so your own Makefile/CI and the worker's prompt have a single
canonical entry point — `project_test` should run your test suite and return 0 on success;
`project_verify` should smoke-test/health-check the app at `http://localhost:<port>` and return 0
if OK.

**`project_permission_profile`**
Echo the path to a `.claude/settings.*.json` file (permission allowlist for unattended workers).
Example: `.claude/settings.my-stack.json`.

For a worked example of a Symfony/Docker project adapter implementing this contract, see `scripts/lib/project/symfony-docker.sh` in the harness's original consumer project (private, not yet public).

### 5. Wire up the Makefile

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

### 6. Set up the cron poller

`ai-intake-harness/install.sh` (step 2) already scaffolded `scripts/intake-cron.sh` for you from
the template below — the harness doesn't ship this file itself, because it holds host-specific
credentials (Claude auth) and paths, so it's gitignored and created locally on first run instead:

```bash
# intake-cron.sh (consumer-created, gitignored; chmod +x)
export HOME=/home/<you>
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"   # claude + make + jq + docker
export ANTHROPIC_API_KEY="$(cat "$HOME/.secrets/anthropic_key")"   # or CLAUDE_CODE_OAUTH_TOKEN
# export GEMINI_API_KEY="$(cat "$HOME/.secrets/gemini_key")"   # only if AI_PROVIDER=gemini
# --- or, instead of GEMINI_API_KEY, Vertex AI / Gemini Code Assist auth: ---
# export GOOGLE_CLOUD_PROJECT="your-project-id"        # or GOOGLE_CLOUD_PROJECT_ID
# export GOOGLE_CLOUD_LOCATION="us-central1"
cd /path/to/repo
exec /usr/bin/flock -n .intake/poll.lock bash ai-intake-harness/intake-poll.sh
```

Edit it to fix the `ANTHROPIC_API_KEY` line (or swap in `CLAUDE_CODE_OAUTH_TOKEN`); if
`AI_PROVIDER=gemini`, uncomment and fix **either** the `GEMINI_API_KEY` line (an AI Studio key) or
the `GOOGLE_CLOUD_PROJECT`/`GOOGLE_CLOUD_LOCATION` pair (Vertex AI / Gemini Code Assist — if you
already have Code Assist access via a Google Workspace/Cloud account and no separate AI Studio
key, this is the path you want; it still needs a credential behind it — ADC via
`gcloud auth application-default login`, `GOOGLE_APPLICATION_CREDENTIALS`, or `GOOGLE_API_KEY` —
`ai_load_env` only checks that the project/location vars are present, not that a credential is
live). Whichever you use, **it must be a real host environment variable set here** (or in your
interactive shell), never `.env`/`.env.local`: those two files are only ever read for `JIRA_*`
vars (`jira_common_load_env`), nothing else parses them, so any of these lines sitting in
`.env.local` would silently do nothing.
(Codex and Antigravity don't need an export here at all — both use a persisted CLI login instead
of an API-key env var, see "AI provider adapter" below.) Then add the crontab entry (e.g., every 2
minutes) — `install.sh` already printed this for you with your repo's actual path filled in, or
install it directly:
```bash
ai-intake-harness/install.sh --install-cron
# or add it yourself via 'crontab -e':
*/2 * * * * /path/to/repo/scripts/intake-cron.sh >> /path/to/repo/.intake/poll.log 2>&1
```
`--install-cron` is idempotent — safe to re-run, it skips if the entry's already there.

(The `flock` in the wrapper guarantees concurrent runs don't collide. Because the wrapper is
host-only and gitignored, renaming harness scripts never updates it — re-check it after renames.)

### 7. Create a curated permission profile

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

For Gemini (`AI_PROVIDER=gemini`), write `.gemini/settings.json` instead — that exact filename,
not an arbitrary adapter-named one: Gemini has no `--settings <path>` flag like Claude's, it only
ever auto-discovers a settings file at `<worktree>/.gemini/settings.json` (verified live against
gemini-cli 0.56.0). Use Gemini's `coreTools`/`excludeTools` schema to restrict tool categories
(e.g. exclude `run_shell_command` entirely, or scope `coreTools` to only the specific tools your
build/verify flow needs). Gemini's model is coarser than Claude's per-command allow/deny — there's
no equivalent of denying `Bash(git push:*)` specifically while allowing other shell commands;
you're choosing whole tool categories on or off.

`install.sh` automates the two mechanical parts of this for you whenever `.ai/intake.config`
resolves to `AI_PROVIDER=gemini` (checked near the end of its main flow, so this applies whether
you picked gemini in step 2's interactive wizard or hand-edited the config later and just re-ran
`install.sh`): it scaffolds a starter `.gemini/settings.json` (excluding `web_fetch` and
`google_web_search` — the two tools a code-implementation worker shouldn't need; tighten further
for your stack) if one doesn't exist yet, and appends the boilerplate
`project_gemini_permission_profile() { echo ".gemini/settings.json"; }` to your project adapter
file (`scripts/lib/project/$PROJECT_ADAPTER.sh`) if that file already exists and doesn't already
define it — this function is always the same one-liner regardless of stack, unlike
`project_permission_profile`, so it's safe to auto-append. If the project adapter file doesn't
exist yet (step 4 usually comes later), it prints the line to add once you write it. All of this
is idempotent — safe to re-run `install.sh` any time.

### 8. After updating the harness, verify your config

`git subtree pull --prefix=ai-intake-harness https://github.com/davindermahal/ai-intake-harness.git main --squash`
picks up whatever new config keys, contract functions, or scaffolded files a harness update added
— but nothing tells your consumer repo it needs them. Run:

```bash
ai-intake-harness/install.sh --verify
```

any time, especially right after a `subtree pull`, for a non-destructive audit: `.env.local`,
`.ai/intake.config`'s keys, the configured AI provider and tracker adapter — including, for
`TRACKER=jira`/`jira-tags`, a **live check** that the abstract-state → Jira-status mapping
(`lib/tracker/jira.sh`'s seven hardcoded status names, or `jira-tags.sh`'s configurable
`TRACKER_NATIVE_STATUS_IN_PROGRESS`/`TRACKER_NATIVE_STATUS_CODE_REVIEW`) actually matches real
statuses in the target project's workflow — the project adapter's contract-function completeness,
permission profile files, `scripts/intake-cron.sh`, the crontab entry, and Makefile targets. Each
line is `[OK]`/`[MISSING]`/`[WARN]`; the command exits non-zero if anything needs attention, so
it's scriptable (a Makefile target, a habit after every `subtree pull`), not just a human-read
report. (A plain `install.sh` run, with no flags, also prints this same audit at the very end as a
"Config health check" — that summary doesn't affect the run's own exit code, which stays governed
by the Jira connectivity test as before.)

Add `--fix` to have it scaffold the subset that's safely automatable:

```bash
ai-intake-harness/install.sh --verify --fix
```

`--fix` only ever creates **net-new** files it fully owns the template for — a starter
`.gemini/settings.json`, the boilerplate `project_gemini_permission_profile` function, or
`scripts/intake-cron.sh` if it's wholly absent. It never edits the content of a file that already
exists (that always stays report-only, pointing at the relevant step above), and never touches the
live crontab or your `Makefile` — install the crontab entry yourself via `--install-cron`, and add
Makefile targets by hand from step 5.

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
- **`tracker_abstract_state <ctx-file>`** — given an already-fetched `tracker_get_issue` JSON file, echo the ticket's abstract state name (same vocabulary as `tracker_transition`'s states, plus `ready-for-planning`), or `""` if it's outside the pipeline. Maps whatever this tracker's own status/label vocabulary is onto the abstract one, so tracker-agnostic worker prompts (e.g. `prompts/intake-planning.md`) never need to know which tracker is configured. No extra REST call — reads from the file the poller already wrote.

**Built-in adapters:**
- `lib/tracker/jira.sh` — Jira Cloud REST, single account, native Jira status field drives the workflow.
- `lib/tracker/jira-tags.sh` — Jira Cloud REST for one **shared project used by multiple repos**. Each repo/install is assigned a unique `TRACKER_APP_TAG` (e.g. `app:my-app-name-1`) that scopes every query to just that repo's tickets, and the workflow is driven by `state:<step>` labels instead of the status field (useful when the real status field is too coarse, or the board is locked down). Every query and state-changing write is additionally scoped to tickets assigned to the authenticated account, since the shared project may have multiple users. Comments are the one exception: they're ungated by default (`TRACKER_GATE_COMMENTS=false`) so a worker can always report back — even on a ticket reassigned out from under it mid-flight — set `TRACKER_GATE_COMMENTS=true` to gate them too. See `docs/workflow-and-triggers.md` ("Tag-based workflow") for the required `state:*` labels and who sets each one, and `.ai/plans/completed/jira-tags-tracker-adapter.md` for the full design.

Both adapters authenticate the same way, via shared `lib/tracker/jira-common.sh` plumbing: an API
token (`JIRA_INTAKE_EMAIL` + `JIRA_INTAKE_API_TOKEN`) if you have one, otherwise a browser session
cookie extracted fresh from the local machine on every run (`lib/tracker/jira-cookie.sh`, for
accounts that can't get a token issued) — see "Quickstart" step 2 and
`.ai/plans/completed/jira-cookie-auth-fallback.md`.

### Project adapter: `scripts/lib/project/<name>.sh`

Implement these shell functions (documented above):
- `project_derive_names <branch> <repo-root>`
- `project_install_deps <container> <uid> <gid> <worktree-dir>`
- `project_provision_fresh <container> <uid> <gid> <repo-root> <db-name> <pg-user> <pg-password>`
- `project_migrate <container> <uid> <gid>`
- `project_build <worktree-dir>`
- `project_test <container>`
- `project_verify <port>`
- `project_permission_profile`
- `project_gemini_permission_profile` *(optional — only required to select `AI_PROVIDER=gemini`
  for the implementation phase)*. Must echo exactly `.gemini/settings.json` — unlike Claude's
  arbitrary-named `--settings <path>`, Gemini has no flag to point at a settings file, it only
  ever auto-discovers that one fixed filename under the worktree root (verified live against
  gemini-cli 0.56.0). The file itself uses Gemini's `coreTools`/`excludeTools` schema — see "AI
  provider adapter" below. `AI_PROVIDER=codex` needs no equivalent function: its automation
  boundary is a fixed pair of CLI flags, not a project-supplied file.

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
automation boundary via `--sandbox` + `--approval-mode yolo` + `--skip-trust` (required alongside
`yolo` — without it, an untrusted worktree silently downgrades back to interactive approval and
hangs headless) + a tool-*category*-level `coreTools`/`excludeTools` settings file auto-discovered
at `.gemini/settings.json` (no CLI flag for this — see `project_gemini_permission_profile`) —
coarser-grained than Claude's, an accepted trade-off, see `docs/design-decisions.md` #5. Auth
needs `GEMINI_API_KEY` (AI Studio) as a real host environment variable, **or** both
`GOOGLE_CLOUD_PROJECT` (or `GOOGLE_CLOUD_PROJECT_ID`) and `GOOGLE_CLOUD_LOCATION` (Vertex AI /
Gemini Code Assist, backed by ADC/a service account/`GOOGLE_API_KEY`) — see "Quickstart" step 6;
`.env`/`.env.local` are not read for any of these) · `lib/ai/codex.sh`
(OpenAI's Codex CLI, fully working — both phases; automation boundary via `-s workspace-write -a
never`, fixed CLI flags rather than a project-supplied settings file, so no optional contract
function is needed — see `docs/design-decisions.md` #5. Auth is a persisted login, not an env var:
run `codex login` or `printenv OPENAI_API_KEY | codex login --with-api-key` once on the machine
running cron) · `lib/ai/antigravity.sh` (Google's Antigravity CLI — binary `agy`, not
`antigravity` — fully working, both phases; automation boundary via `--sandbox` +
`--dangerously-skip-permissions`, coarser than Codex's because `--sandbox`'s exact restrictions
aren't documented/verified the way Codex's sandbox was, treat as experimental until a real
implementation-phase run confirms its behavior — see `docs/design-decisions.md` #5. Auth is also a
persisted login, not an env var: run an interactive `agy` session once on the machine running cron
to sign in) · `lib/ai/local-llm.sh` (routes the claude CLI at a local model server —
experimental).

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
  would require the Gemini CLI to grow an equivalent mechanism first.
- **A generic local-LLM gateway.** `lib/ai/local-llm.sh` only works against a server exposing LM
  Studio's native Anthropic-compatible endpoint. `codex --help` shows `--oss`/`--local-provider
  <lmstudio|ollama>` flags suggesting Codex CLI has first-party local-model routing, which may make
  a broader (Ollama/vLLM/llama.cpp) local-LLM path easier to build on `lib/ai/codex.sh` than a new
  adapter — not designed or built yet, see `.ai/plans/completed/ai-provider-install-prompt.md`.
- **GitHub Issues tracker adapter.** Deferred until a second real tracker consumer exists to design against; not yet built.

---

## References

This harness was extracted from a private Jira-driven Symfony/Docker project, where it was
generalized behind the `tracker_*`/`project_*` adapter seams described above so it could be
dropped into other projects. That project remains the harness's first real-world consumer, but
isn't public.
