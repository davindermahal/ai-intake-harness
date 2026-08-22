# Plan: DAV-2 Using a different AI agent

**Status**: completed
**Branch**: feature/DAV-2-using-a-different-ai-agent
**Created**: 2026-08-20
**Updated**: 2026-08-20

## Implementation notes (headless worker, 2026-08-20)

Implemented per this plan: `lib/ai/gemini.sh` (new adapter, all three `ai_*` contract functions),
`intake-poll.sh` `GEMINI_*` defaults, README "AI provider adapter" section +
`project_gemini_permission_profile` docs + Gemini quickstart example + stale bullet fix,
`docs/design-decisions.md` #5/#11 updates, `docs/lessons-learned.md` open-questions bullet.
Verified: `bash -n` on both changed scripts, `shellcheck lib/ai/gemini.sh` (only the same SC2086
info-level word-splitting notices `lib/ai/claude.sh` already has on the identical pattern), static
confirmation that `ai_load_env`/`ai_run_planning`/`ai_run_implementation` are defined, and every
grep-based acceptance check in Implementation order steps 2/4/5/6.

**Deviation from plan, disclosed:** step 1 (live `gemini --help` verification) could not run — this
build executed under this repo's own locked-down implementation-worker permission profile
(`.claude/settings.ai-harness-dev.json`: only `shellcheck`, `bash -n`, `git status/diff/add/commit/
log`, `./tracker-comment.sh`, `./tracker-transition.sh` allowed; no general shell, no npm install, no
`command -v gemini`). Flag names/shapes (`-p`, `-m`/`--model`, `--include-directories`, `--sandbox`,
`--approval-mode`, `--settings`) remain the plan's documented assumptions, called out in
`lib/ai/gemini.sh`'s own header comment — re-verify against a live install before relying on this
adapter for a real Gemini-backed run.

## Goal

Add a real, working **Gemini** AI provider adapter (`lib/ai/gemini.sh`) implementing the harness's
full `ai_*` contract — `ai_load_env`, `ai_run_planning`, **and `ai_run_implementation`** — so a
consumer without Claude access (e.g. a work environment that only has Gemini) can run **both**
the planning and implementation phases with Google's Gemini CLI instead of Claude Code CLI.

> **Updated 2026-08-20**: an earlier pass of this plan scoped `ai_run_implementation` as a loud
> stub pending author confirmation (see resolved question under Open Questions below). The author
> replied "attempt full implementation-phase now," explicitly accepting a coarser-grained
> automation-boundary mechanism than Claude's as a documented known limitation rather than a hard
> stop. This revision designs and builds that real implementation-phase support.

Per-phase / per-ticket provider override ("planning by Claude, implementation by Gemini", "a tag to
override the default") is **already built** — `resolve_ai_profile` in `intake-poll.sh` already
supports `ai-plan-<profile>` / `ai-impl-<profile>` / `ai-provider-<name>` tracker labels and
`AI_PROFILE_<name>="provider:model"` entries in `.ai/intake.config` (see `docs/design-decisions.md`
#11, `intake-poll.sh:284-346`). This plan does not touch that mechanism — it only needs a real
`lib/ai/gemini.sh` for that mechanism to select. Once this lands, a consumer sets
`AI_PROFILE_gemini_plan="gemini"` (or attaches an `ai-plan-gemini`/`ai-impl-gemini` label to a
ticket, or sets `AI_PROVIDER=gemini` as the default) with zero further harness changes.

## Scope

**In:**
- `lib/ai/gemini.sh`: `ai_load_env`, `ai_run_planning`, and `ai_run_implementation` — all fully
  working, mirroring `lib/ai/claude.sh`'s shape and doc-comment conventions.
- `ai_run_implementation` launches a **detached** headless Gemini worker, matching `claude.sh`'s
  exact contract (`ai_run_implementation LOGFILE PIDFILE`, `nohup`+`exec`, worker PID written to
  `PIDFILE` so the poller's `kill -0` liveness check tracks the real process). Its automation
  boundary uses `--sandbox` (execution isolation) + `--approval-mode yolo` (required headless —
  there's no TTY to interactively approve actions) + a Gemini-native tool-restriction settings
  file, gated behind a new **optional** project-adapter contract function
  `project_gemini_permission_profile` (mirrors the existing `project_permission_profile`, but
  echoes a path to a Gemini-schema settings file — `coreTools`/`excludeTools` — instead of a
  Claude `settings.json` allow/deny list). If the consumer project hasn't implemented that
  function (or the file it points to doesn't exist), `ai_run_implementation` **refuses to launch**
  rather than running unrestricted — see Key decisions.
- New poller-level env vars `GEMINI_BIN` / `GEMINI_FLAGS` / `GEMINI_TIMEOUT`, defaulted in
  `intake-poll.sh` next to the existing `CLAUDE_BIN` / `CLAUDE_FLAGS` / `CLAUDE_TIMEOUT` block.
  (`HEADLESS_GEMINI_FLAGS` is supported the same implicit way `HEADLESS_CLAUDE_FLAGS` already is
  in `claude.sh` — an optional env override read via `${VAR:-}`, not separately documented/defaulted
  in `intake-poll.sh`'s globals block, matching the existing asymmetry.)
- README.md: add the missing "AI provider adapter" contract subsection (tracker/project adapters
  are documented; the `ai_*` contract currently isn't, anywhere in README) covering both phases for
  Gemini; document the new optional `project_gemini_permission_profile` function under the existing
  "Project adapter" contract subsection and the "Create a curated permission profile" quickstart
  step; fix the stale "Future directions" bullet that still claims the AI seam doesn't exist yet.
- `docs/design-decisions.md`: append to decision #5 (hard automation boundary) documenting that
  Gemini's boundary is coarser-grained than Claude's and why that's an accepted, explicit trade-off;
  update decision #11 (provider seam) now that Gemini is a second real, full (not stub) provider.
- `docs/lessons-learned.md`'s "Known open questions" list: update the Gemini caveat to reflect real
  implementation-phase support and the coarser boundary, alongside the existing OpenAI-stub /
  local-llm-unverified notes.

**Out:**
- **Fine-grained per-command allow/deny for Gemini matching Claude's exact granularity.** Not
  available in the Gemini CLI today (per Implementation order step 1's live verification) — tool
  *category*-level restriction (`coreTools`/`excludeTools`) is the accepted ceiling for this ticket,
  explicitly signed off on by the author (see Open Questions).
- Any change to `resolve_ai_profile` / the label / profile override mechanism — it already exists
  and already works generically for any provider named `lib/ai/<name>.sh`.
- Changing the default `AI_PROVIDER` (stays `claude`) — Gemini is opt-in, exactly like `local-llm`
  and `openai` are today. No behavior change for existing consumers.
- Vertex AI / service-account auth. Only the Gemini CLI's `GEMINI_API_KEY` (Google AI Studio key)
  path, matching `claude.sh`'s equivalent simplicity (no auth-method branching).
- A `local-llm.sh`-style verification "spike" script. Not warranted yet — nothing here points a
  paid/local model at an unverified proxy; it's the vendor's own CLI talking to the vendor's own
  API, the same trust level as `claude.sh`.
- Modifying `lib/ai/claude.sh`, `lib/ai/local-llm.sh`, or `lib/ai/openai.sh` — this ticket only adds
  a new adapter file alongside them.

## Files to change

- `lib/ai/gemini.sh` (new) — the adapter: `ai_load_env`, `ai_run_planning`, `ai_run_implementation`
  (real, detached headless worker — see Key decisions for the permission-boundary design).
- `intake-poll.sh` — add `GEMINI_BIN` / `GEMINI_FLAGS` / `GEMINI_TIMEOUT` defaults + header-comment
  doc lines, next to the existing `CLAUDE_*` block (~lines 74-108).
- `README.md` — new "AI provider adapter" contract subsection under "Adapter contracts" (both
  phases); new optional `project_gemini_permission_profile` documented under "Project adapter"
  contract (~line 217-226) and quickstart step 6 "Create a curated permission profile" (~line
  173-198, add a Gemini-equivalent example); fix the stale "Future directions" bullet (~line 255).
- `docs/design-decisions.md` — append an accepted-limitation note to decision #5's **Trade-offs**
  (~line 99) and a factual update to decision #11's **Trade-offs** (~line 201).
- `docs/lessons-learned.md` — update "Known open questions / caveats" (~line 108) to reflect real
  (not stub) Gemini implementation-phase support and its coarser boundary.

## Key decisions

- **Target CLI**: Google's official Gemini CLI (`npm install -g @google/gemini-cli`, binary
  `gemini`) — the direct analog to the Claude Code CLI (one-shot non-interactive prompt mode,
  agentic file/shell tool-use). This is an assumption, not a verified fact (no live CLI access
  during planning) — **Implementation order step 1 below verifies it against the real installed
  CLI's `--help` output before anything is wired up**, matching the "verify against the live tool,
  fail loud if wrong" philosophy `lib/ai/local-llm.sh` already established in this codebase. If the
  installed CLI's flags differ from what's assumed here, substitute the real flag names — the
  adapter's *structure* (mirroring `claude.sh`) does not change.
- **New adapter-specific globals, not reuse of `CLAUDE_*`**: unlike `local-llm.sh` (which drives the
  *same* `claude` binary, just pointed at a different server, so it legitimately reuses
  `CLAUDE_BIN`/`CLAUDE_FLAGS`/`CLAUDE_TIMEOUT`), `gemini.sh` drives a genuinely different binary. It
  gets its own `GEMINI_BIN`/`GEMINI_FLAGS`/`GEMINI_TIMEOUT`, following the same
  default-in-`intake-poll.sh` pattern as the `CLAUDE_*` trio.
- **No new model-selection variable**: reuse the existing generic `AI_PLANNING_MODEL` /
  `AI_IMPLEMENTATION_MODEL` (and the per-ticket profile mechanism). `local-llm.sh` needed its own
  `AI_LOCAL_LLM_MODEL` because it had to *discover* which model was loaded in LM Studio when none was
  specified; Gemini takes an explicit model name with no such ambiguity, so a plain `--model` flag
  fed by the existing generic vars is enough.
- **`ai_load_env` fails loudly if `GEMINI_API_KEY` is unset**: the Gemini CLI's interactive default
  is an OAuth browser login, which cannot run from an unattended cron dispatch. Checking for the key
  at selection time (not mid-run) matches `local-llm.sh`'s "probe and fail immediately" pattern
  rather than letting the poller hang or fail confusingly later.
- **Gemini's implementation-phase automation boundary is coarser than Claude's — accepted
  explicitly by the author.** Claude's boundary (design-decisions.md #5: build/test/verify only,
  never push/deploy/read secrets) is enforced via a curated *per-command* allow/deny list
  (`--settings <profile> --permission-mode default`). Gemini CLI has no equivalent per-command
  pattern-matching contract; the closest tools are `--sandbox` (isolates *where* commands run, via
  container/Seatbelt), `--approval-mode` (`default`/`auto_edit`/`yolo` — coarse, not per-command),
  and a project settings file's `coreTools`/`excludeTools` (restricts *which tool categories* are
  available at all, e.g. exclude `run_shell_command` entirely — not a curated allowlist of specific
  safe commands like Claude's). The design here combines all three: `--sandbox` for isolation,
  `--approval-mode yolo` (required — headless has no TTY to click approve), and a **required**
  project-supplied `coreTools`/`excludeTools` settings file as the real restriction layer.
- **Fail closed, not open, when no permission profile is configured.** Unlike `claude.sh` (which
  falls back to a safe `--permission-mode plan` read-only mode when no settings file is found),
  Gemini has no *verified* equivalent safe read-only headless mode (flagged for step-1
  verification — if one exists, prefer it as the fallback instead of hard-failing). Until verified,
  `ai_run_implementation` **refuses to launch at all** if `project_gemini_permission_profile` isn't
  implemented by the consumer's project adapter, rather than defaulting to unrestricted `yolo`. This
  is a stricter failure mode than Claude's on purpose — running unrestricted would be strictly worse
  than not running.
- **New optional project-adapter contract function**: `project_gemini_permission_profile` (echoes a
  path, relative to the worktree, to a `.gemini/settings.<adapter-name>.json`-style file — mirrors
  `project_permission_profile`'s existing convention exactly). Additive only: existing project
  adapters that don't implement it are unaffected (they simply can't select `AI_PROVIDER=gemini` for
  the implementation phase — planning-phase Gemini has no such requirement since it needs no shell
  access).

## Implementation order

1. **Verify the real Gemini CLI contract — planning AND implementation-phase flags.**
   Run:
   ```
   npm ls -g @google/gemini-cli || npm install -g @google/gemini-cli
   gemini --version
   gemini --help
   ```
   Confirm the help output has, for **planning**: a non-interactive one-shot prompt flag (assumed:
   `-p`/`--prompt`), a model-selection flag (assumed: `-m`/`--model`), and a flag to grant access to
   an extra directory outside the CLI's cwd (assumed: `--include-directories`, comma- or
   repeat-flag-separated — load-bearing: without it the worker can't reach
   `.intake/context/<KEY>.json` / `.intake/decision/<KEY>.json`, which live outside the worktree —
   see `lib/ai/claude.sh`'s `--add-dir "$STATE_DIR"` comment for why). For **implementation**,
   additionally confirm/determine:
   - A sandbox flag (assumed: `--sandbox`) and what backends it supports (Docker/Podman/Seatbelt) —
     note which are actually available on the machine that will run this.
   - An approval-mode flag (assumed: `--approval-mode`) and its values (assumed: `default` /
     `auto_edit` / `yolo`) — confirm `yolo` is the correct value for "no interactive prompts at
     all," and check whether any value provides a genuinely safe **read-only** headless mode (if
     so, use it as the no-profile-configured fallback instead of hard-failing — see Key decisions).
   - How a project-level settings file (assumed schema: `coreTools`/`excludeTools`) is supplied: an
     explicit CLI flag (assumed: `--settings <path>`) or auto-discovery only (e.g. a `.gemini/settings.json`
     the CLI reads from its cwd, with no path override). **This changes what
     `project_gemini_permission_profile`'s contract means** — if auto-discovery-only, the function's
     return value must resolve to exactly `.gemini/settings.json` under the worktree (not an
     arbitrary path), and step 2's flag construction drops `--settings` in favor of just ensuring the
     file exists at that fixed location before launch.
   If any assumed flag/behavior differs from the real CLI, use the real name/shape in step 2 instead
   — do not guess further, and do not silently drop a requirement.
   **Acceptance**: `gemini --help` printed successfully (exit 0) and you've written down the real
   flag names/values to use in step 2 for all of: prompt, model, extra-directory, sandbox,
   approval-mode, and settings-file discovery.

2. **Create `lib/ai/gemini.sh`.**
   New file, mirroring `lib/ai/claude.sh`'s structure and header-comment conventions. Contents
   (substitute any flag names step 1 found to differ from the assumptions below):
   ```bash
   #!/bin/bash
   # AI adapter: Gemini CLI — see .ai/intake.config for selection (AI_PROVIDER=gemini).
   #
   # Implements the ai_* contract: ai_load_env, ai_run_planning, ai_run_implementation. Targets
   # Google's official Gemini CLI (`npm install -g @google/gemini-cli`, binary `gemini`) — the
   # direct analog to the Claude Code CLI: a one-shot non-interactive prompt mode with agentic
   # tool-use (file read/write, shell). Flags below were verified against a live `gemini --help`
   # at authoring time (see DAV-2 plan step 1) — re-verify if the installed CLI's interface has
   # since changed.
   #
   # ai_run_implementation's automation boundary (design-decisions.md #5) is coarser-grained than
   # Claude's: Gemini CLI has no per-command allow/deny settings.json equivalent, only --sandbox
   # (execution isolation) + --approval-mode yolo (required headless — no TTY to interactively
   # approve) + a project settings file's coreTools/excludeTools (tool-*category* restriction, not
   # per-command patterns). This is an explicitly accepted gap (see DAV-2 plan's Key decisions) —
   # the consumer project supplies the restriction via the OPTIONAL
   # project_gemini_permission_profile contract function (mirrors project_permission_profile,
   # Gemini's schema instead of Claude's). If the consumer hasn't implemented it,
   # ai_run_implementation refuses to launch rather than running unrestricted.
   #
   # Not guarded against re-sourcing — see ai/claude.sh's header comment for why (a per-ticket
   # label can switch providers within one poller process).

   # ai_load_env — the gemini CLI must be on PATH, and headless auth must be configured (OAuth
   # login is interactive-only and cannot run from an unattended cron dispatch).
   _ai_gemini_load_env_impl() {
       command -v "${GEMINI_BIN:-gemini}" >/dev/null 2>&1 \
           || { echo "ai/gemini: '${GEMINI_BIN:-gemini}' not found on PATH" >&2; return 1; }
       [ -n "${GEMINI_API_KEY:-}" ] \
           || { echo "ai/gemini: GEMINI_API_KEY is not set — interactive OAuth login cannot run headless from the poller; set GEMINI_API_KEY (a Google AI Studio key) in the environment or .env" >&2; return 1; }
   }

   # ai_run_planning KEY BRANCH CTX DEC CWD — author/refine ticket $KEY's plan inside worktree $CWD.
   # Reads GEMINI_BIN / GEMINI_FLAGS / GEMINI_TIMEOUT / STATE_DIR (set by intake-poll.sh) and
   # AI_PLANNING_MODEL (from .ai/intake.config / env override / per-ticket profile) as globals —
   # matching lib/ai/claude.sh's existing convention.
   _ai_gemini_run_planning_impl() {
       local key="$1" branch="$2" ctx="$3" dec="$4" cwd="$5" prompt model_flag=""
       prompt="Ticket: $key  (phase: planning, branch: $branch)

   You are the headless JIRA intake planning worker for THIS ONE ticket ($key). Do NOT act on any
   other ticket. Do NOT call any Jira/Atlassian MCP tools and do NOT run git — the poller performs all
   tracker I/O over REST and commits your plan. Your job: author files and emit a decision.

   - Your working directory is a worktree of branch '$branch'. Author/refine the plan file here under
     .ai/plans/active/${key}-<slug>.md, and use exactly this branch in its **Branch**: line: $branch
   - The ticket data (summary, status, description, comments) is JSON at: $ctx
   - Follow the routine in: ai-intake-harness/prompts/intake-planning.md
   - When finished, write your decision JSON to: $dec

   Per project convention, the decision's 'comment' field MUST always contain a concise summary of
   what you did (it is posted back to the ticket for the record)."
       [ -n "${AI_PLANNING_MODEL:-}" ] && model_flag="--model $AI_PLANNING_MODEL"
       # $STATE_DIR lives outside this worktree ($REPO_ROOT/.intake in the MAIN checkout) — same
       # reason claude.sh grants --add-dir; without it the worker can't reach $ctx/$dec.
       ( cd "$cwd" && timeout "$GEMINI_TIMEOUT" "${GEMINI_BIN:-gemini}" -p "$prompt" --include-directories "$STATE_DIR" ${GEMINI_FLAGS:-} $model_flag )
   }

   # ai_run_implementation LOGFILE PIDFILE — launch the gemini CLI as a DETACHED headless worker
   # implementing $TICKET's approved plan in $WORKTREE_DIR. Mirrors claude.sh's
   # _ai_claude_run_implementation_impl contract exactly: writes the worker's PID to PIDFILE (the
   # poller's running-slot liveness check depends on this being the actual worker process, so the
   # launch stays a plain nohup+exec with no extra wrapper layer). Reads WORKTREE_DIR / TICKET /
   # GEMINI_BIN / HEADLESS_GEMINI_FLAGS as globals (set by worktree-go.sh).
   _ai_gemini_run_implementation_impl() {
       local logfile="$1" pidfile="$2" settings_rel settings_file perm_flags model_flag="" prompt

       if command -v project_gemini_permission_profile >/dev/null 2>&1; then
           settings_rel="$(project_gemini_permission_profile)"
           settings_file="${WORKTREE_DIR}/${settings_rel}"
       fi

       if [ -n "${settings_file:-}" ] && [ -f "$settings_file" ]; then
           # --sandbox isolates *where* commands run; --approval-mode yolo is required headless
           # (no TTY to interactively approve). Neither restricts *which* tools are available —
           # the settings file's coreTools/excludeTools is the real boundary here. See header.
           perm_flags="--sandbox --approval-mode yolo --settings $settings_file"
       else
           echo "ai/gemini: no Gemini permission profile found (expected project_gemini_permission_profile to echo a path under \$WORKTREE_DIR to a coreTools/excludeTools settings file) — refusing to launch unrestricted. Implement project_gemini_permission_profile in your project adapter (see README's Project adapter contract), or use AI_PROVIDER=claude for implementation." >&2
           return 1
       fi

       prompt="Headless JIRA-intake implementation for ticket ${TICKET:-<none>}. Read and follow .ai/prompts/worktree-bootstrap-auto.md exactly: implement the approved (ready) plan for this ticket, build, verify, and post a result summary to the ticket with ai-intake-harness/tracker-comment.sh. Do not push, merge, or deploy."
       [ -n "${AI_IMPLEMENTATION_MODEL:-}" ] && model_flag="--model $AI_IMPLEMENTATION_MODEL"

       ( cd "$WORKTREE_DIR" && nohup bash -c \
           "exec ${GEMINI_BIN:-gemini} -p \"\$1\" ${perm_flags} ${HEADLESS_GEMINI_FLAGS:-} ${model_flag}" _ "$prompt" \
           >"$logfile" 2>&1 & echo "$!" > "$pidfile" )
   }

   ai_load_env()           { _ai_gemini_load_env_impl "$@"; }
   ai_run_planning()       { _ai_gemini_run_planning_impl "$@"; }
   ai_run_implementation() { _ai_gemini_run_implementation_impl "$@"; }
   ```
   If step 1 found a different settings-discovery mechanism (auto-discovery only, no `--settings`
   flag), replace the `perm_flags` line with logic that copies/symlinks `$settings_file` to the
   fixed auto-discovered location under `$WORKTREE_DIR` instead of passing a flag.
   **Acceptance**: `bash -n lib/ai/gemini.sh` exits 0 (syntax valid). Then
   `shellcheck lib/ai/gemini.sh` — no new warnings beyond what `shellcheck lib/ai/claude.sh` already
   reports on the pattern this mirrors (compare the two outputs; don't chase pre-existing warnings
   inherited from the pattern).

3. **Smoke-test the adapter loads and defines the contract, without a live consumer repo.**
   This harness repo has no `.ai/intake.config` / consumer project attached, so
   `lib/intake-config.sh` can't be exercised end-to-end here — test `gemini.sh` standalone instead:
   ```
   ( GEMINI_BIN=gemini GEMINI_API_KEY=test-key . lib/ai/gemini.sh \
     && command -v ai_load_env >/dev/null && command -v ai_run_planning >/dev/null && command -v ai_run_implementation >/dev/null \
     && echo ADAPTER_OK )
   ```
   Then verify the fail-closed path (no `project_gemini_permission_profile` defined in this
   standalone context, matching a consumer that hasn't implemented it yet):
   ```
   ( GEMINI_BIN=gemini WORKTREE_DIR=/tmp TICKET=TEST-1 . lib/ai/gemini.sh \
     && ai_run_implementation /tmp/gemini-smoke.log /tmp/gemini-smoke.pid; echo "exit=$?" )
   ```
   (Requires the real `gemini` binary on PATH per step 1 — swap `GEMINI_BIN` to a `command -v`-able
   stub if it isn't installed on the machine running this check.)
   **Acceptance**: first command prints `ADAPTER_OK`; second prints the "no Gemini permission
   profile found" message to stderr and `exit=1`.

4. **Add `GEMINI_BIN` / `GEMINI_FLAGS` / `GEMINI_TIMEOUT` to `intake-poll.sh`.**
   In `intake-poll.sh`, find the header-comment block documenting `CLAUDE_BIN` / `CLAUDE_FLAGS` /
   `CLAUDE_TIMEOUT` (~lines 74-76) and the corresponding default assignments (~lines 106-108). Add
   analogous lines directly after each:
   ```
   #   GEMINI_BIN=gemini                        gemini CLI binary (ai/gemini.sh) (default: gemini)
   #   GEMINI_FLAGS=""                          flags for headless gemini planning runs
   #   GEMINI_TIMEOUT=900                       seconds before a gemini planning run is killed
   ```
   and:
   ```bash
   GEMINI_BIN="${GEMINI_BIN:-gemini}"
   GEMINI_FLAGS="${GEMINI_FLAGS:-}"
   GEMINI_TIMEOUT="${GEMINI_TIMEOUT:-900}"
   ```
   **Acceptance**: `bash -n intake-poll.sh` exits 0, and
   `grep -c 'GEMINI_BIN\|GEMINI_FLAGS\|GEMINI_TIMEOUT' intake-poll.sh` reports at least 6 (3 doc
   lines + 3 assignments).

5. **Document the `ai_*` adapter contract and the new project-adapter function in `README.md`; fix
   the stale "Future directions" bullet.**
   In `README.md`, under the existing "## Adapter contracts" section (~line 202), after the
   "### Project adapter" subsection (~line 217-226) and before the closing `---` (~line 228), add:
   ```markdown
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
   ```
   In the existing "### Project adapter" subsection (~line 217-226), add a line after
   `project_permission_profile`:
   ```markdown
   - `project_gemini_permission_profile` *(optional — only required to select `AI_PROVIDER=gemini`
     for the implementation phase)*. Echoes the path to a Gemini-schema (`coreTools`/`excludeTools`)
     settings file — see "AI provider adapter" below.
   ```
   In quickstart step 6 "Create a curated permission profile" (~line 173-198), add a short Gemini
   equivalent after the existing Claude example:
   ```markdown
   For Gemini (`AI_PROVIDER=gemini`), write `.gemini/settings.<adapter-name>.json` instead, using
   Gemini's `coreTools`/`excludeTools` schema to restrict tool categories (e.g. exclude
   `run_shell_command` entirely, or scope `coreTools` to only the specific tools your build/verify
   flow needs). Gemini's model is coarser than Claude's per-command allow/deny — there's no
   equivalent of denying `Bash(git push:*)` specifically while allowing other shell commands; you're
   choosing whole tool categories on or off.
   ```
   Then find the stale "Future directions" bullet (~line 255):
   `- **Multi-AI abstraction.** Today planning/implementation is hard-coded to \`claude\`... design
   pending a second real consumer.` — this is now factually wrong (the seam has existed since
   design decision #11, and this ticket adds a second real, full provider). Replace it with:
   ```markdown
   - **Fine-grained Gemini permissions.** `lib/ai/gemini.sh` covers both phases, but its
     implementation-phase automation boundary is tool-*category*-level (`coreTools`/`excludeTools`),
     coarser than Claude's per-command allow/deny — porting Claude's exact granularity to Gemini
     would require the Gemini CLI to grow an equivalent mechanism first. `lib/ai/openai.sh` remains a
     stub entirely.
   ```
   **Acceptance**: `grep -n "AI provider adapter" README.md` finds the new subsection;
   `grep -n "project_gemini_permission_profile" README.md` finds at least two matches (contract list
   + AI provider adapter section); `grep -n "design pending a second real consumer" README.md` finds
   nothing (the stale line is gone).

6. **Update `docs/design-decisions.md` decisions #5 and #11, and `docs/lessons-learned.md`'s open
   questions.**
   In `docs/design-decisions.md`, decision #5's **Trade-offs** paragraph (~line 99) currently reads
   "A human must always do the final push/merge/deploy. Intended." Append:
   ```
   The Gemini provider (see DAV-2) approximates this boundary with coarser tools —
   `--sandbox` + `--approval-mode yolo` + a tool-category `coreTools`/`excludeTools` settings file,
   rather than Claude's per-command allow/deny. This gap is explicit and author-accepted, not
   accidental; `lib/ai/gemini.sh` refuses to launch at all rather than run unrestricted when no
   settings file is configured.
   ```
   Decision #11's **Trade-offs** paragraph (~line 201) currently reads "A stubbed provider that only
   fails is dead weight until implemented, and the local-LLM path's full agentic behavior was not
   verified end-to-end...". Append one sentence:
   ```
   A second real provider (Gemini, both planning and implementation phases) has since landed — see
   DAV-2.
   ```
   In `docs/lessons-learned.md`, under "## Known open questions / caveats" (~line 108), add a bullet
   after the OpenAI-stub line:
   ```markdown
   - The **Gemini provider** supports both phases, but its implementation-phase automation boundary
     is tool-*category*-level (`--sandbox` + `--approval-mode yolo` + `coreTools`/`excludeTools`),
     coarser than Claude's per-command allow/deny (design decision #5) — an explicit, author-accepted
     trade-off, not a gap to silently work around. See `lib/ai/gemini.sh`'s header comment.
   ```
   **Acceptance**: both files still render as valid markdown (no broken list nesting) — visually
   confirm by re-reading the edited section.

## Boundaries

- **Do not** touch `resolve_ai_profile`, `load_ai_provider`, or any other part of `intake-poll.sh`'s
  per-ticket label/profile resolution — it already works generically for any `lib/ai/<name>.sh`.
- **Do not** modify `lib/ai/claude.sh`, `lib/ai/local-llm.sh`, or `lib/ai/openai.sh` — this ticket
  only adds a new adapter file alongside them.
- **Do not** attempt to give Gemini Claude-equivalent per-command allow/deny granularity — the
  Gemini CLI doesn't support it (per step 1's verification); tool-category-level restriction via
  `coreTools`/`excludeTools` is the accepted ceiling.
- **Do not** make `ai_run_implementation` fall back to running unrestricted (e.g. bare `yolo` with
  no settings file) when `project_gemini_permission_profile` is absent — fail closed, per Key
  decisions.
- **Do not** change the default `AI_PROVIDER` (stays `claude`) or any other existing default —
  Gemini is opt-in only.
- No application/project code in this repo to change — this repo is the harness itself, not a
  consumer project. (A real project adapter implementing `project_gemini_permission_profile` can
  only be written and tested against an actual consumer project — this ticket adds the contract and
  the harness-side consumer of it, not an example implementation.)

## Open Questions

**Resolved (was blocking):** *Scope of `ai_run_implementation` for Gemini.* The prior planning pass
routed this back to the author (loud stub, planning-only, vs. full implementation-phase support now,
accepting a coarser security boundary as a documented limitation). The author replied: **"attempt
full implementation-phase now."** This revision implements that — see Key decisions for the
resulting automation-boundary design (`--sandbox` + `--approval-mode yolo` + required
`coreTools`/`excludeTools` settings file, fail-closed if absent).

Non-blocking, confirm at review:
- Exact Gemini CLI flag names for planning (`-p`/`--prompt`, `-m`/`--model`,
  `--include-directories`) **and** for implementation (`--sandbox`, `--approval-mode` + its values,
  and whether project settings are passed via an explicit flag or auto-discovered only) are assumed
  from general knowledge of Google's Gemini CLI, not verified against a live install during
  planning — step 1 of Implementation order verifies and self-corrects before anything is wired up.
- Whether Gemini has any safe, verified read-only headless mode that could serve as a softer
  fallback than hard-failing when no permission profile is configured — step 1 checks; if none
  exists, the fail-closed design stands as specified.
- `GEMINI_API_KEY` (Google AI Studio key) is assumed as the only headless auth path; Vertex AI
  service-account auth is out of scope unless you need it.
- No real consumer project in this repo to end-to-end test `project_gemini_permission_profile`
  against — the contract and harness-side consumption are built and unit-smoke-tested (step 3), but
  full validation happens once a real consumer project implements the function.
