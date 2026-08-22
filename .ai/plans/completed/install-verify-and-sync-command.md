# Plan: `install.sh --verify` — audit an already-installed consumer repo and scaffold new config

**Status**: completed
**Branch**: feature/gemini-adapter-live-verification-fixes (implemented in place, not on a new branch)
**Created**: 2026-08-21
**Updated**: 2026-08-21

## Implementation notes (2026-08-21)

Implemented per this plan, all 16 steps. Two real bugs surfaced during live testing that the plan
text didn't anticipate, both fixed:

1. **SIGPIPE + `pipefail` race**: `_known_ai_providers | grep -qxF "$x"` (and the same pattern for
   `_known_trackers`) intermittently reported a false MISSING even for a value that matched. `grep
   -q` exits the instant it finds a match, SIGPIPEs the still-writing producer, and `pipefail`
   then reports that SIGPIPE as the pipeline's own failure — a well-known bash gotcha. Fixed by
   capturing the producer's output to a variable first (`printf '%s\n' "$(_known_ai_providers)" |
   grep ...`), which writes as one atomic buffered write well under the pipe capacity, sidestepping
   the race.
2. **`jira_common_load_env` is fatal, not just non-zero, on a totally-missing `.env.local`**: it
   uses `${JIRA_SITE_URL:?msg}`, and bash's documented behavior for that construct in a
   non-interactive shell is to `exit` the whole script outright — bypassing `if`-guards, `||`,
   everything — the moment `.env.local`/`.env` don't exist at all. This would have taken down the
   entire `--verify` run at the tracker-adapter check on a totally fresh consumer repo. Fixed by
   running `jira_common_load_env` and `jira_project_statuses` together in one subshell, capturing
   only the resulting status list as ordinary stdout — the fatal path now only kills the subshell.

Also deviated from the plan's literal step 8 wording in one place: instead of a narrow
`_project_adapter_name` helper, added a more general `_intake_config_value KEY [DEFAULT]` helper
(used for every single-key read across the new verify checks, not just `PROJECT_ADAPTER`) and
refactored `_scaffold_gemini_permission_profile` to use it. `_known_trackers` also excludes
`jira-common.sh`/`jira-cookie.sh` (shared plumbing, not selectable `TRACKER` adapters) — the plan's
literal wording ("same over lib/tracker/*.sh") would have wrongly flagged a correctly-configured
`TRACKER=jira`/`jira-tags` install as unrecognized.

Verified: `bash -n` + `shellcheck -x` clean on `install.sh` and `lib/tracker/jira-common.sh`; full
scratch-fake-consumer-repo pass covering every scenario in step 16 (missing config, jira-tags
without `TRACKER_APP_TAG`, `--fix` alone without `--verify`, gemini missing/present permission
profile + project-adapter function, Makefile missing a target, idempotent re-`--fix`, tail summary
not affecting the normal flow's own exit code); **and, going beyond scratch-repo faking, the live
native-status sub-check was verified for real** against this repo's own self-hosted Jira project
(`DAV`, read-only `GET /rest/api/2/project/DAV/statuses`) — confirmed `[OK]` for the real
`jira-tags` config, and confirmed a correctly-detected `[MISSING]` when temporarily switching a
scratch copy of `.ai/intake.config` to `TRACKER=jira` against that same real project (which
doesn't have jira.sh's seven hardcoded status names, since this project is actually driven via
jira-tags's two-native-status mirror) — `.ai/intake.config` was restored byte-for-byte afterward
(diffed to confirm) and is gitignored regardless, so no risk to this repo's own dogfooding setup.

## Goal

A consumer repo vendors this harness via `git subtree` and runs `install.sh` once, up front.
Every later harness change that adds a new config key, a new required project-adapter contract
function, or a new scaffolded file (like the `.gemini/settings.json` +
`project_gemini_permission_profile` scaffolding just added for `AI_PROVIDER=gemini`) has no way to
reach that consumer repo except "re-read the README/commit history and manually notice what's
new." Give `install.sh` a **non-destructive audit mode** that a consumer can run any time (ideally
right after `git subtree pull`) to see, in one pass: what's configured, what's missing, what's
stale, and — for the subset that's safely automatable — have it scaffolded on the spot.

## Scope

**In scope:**
- A new `install.sh --verify` flag: read-only audit of everything the harness currently expects
  in the consumer repo, printed as a categorized report (OK / MISSING / WARN), non-zero exit if
  anything needs attention.
- A new `install.sh --verify --fix` combination: after the audit, apply only the fixes that are
  genuinely safe and additive (create a net-new file the harness fully owns the template for;
  never edit an existing hand-maintained file's content).
- Folding a lightweight version of the same audit into the *end* of a normal (no-flags)
  `install.sh` run too, so first-time installs get the same "here's your config health" summary
  for free.
- Refactoring the `scripts/intake-cron.sh` scaffold (currently inlined in the main flow) into a
  reusable function, so `--verify --fix` and the normal flow share one template instead of two.
- A **live check that the abstract-state → Jira-status mapping actually matches the target
  project's real workflow**, for both Jira-flavored tracker adapters: `TRACKER=jira-tags`'s
  configurable `TRACKER_NATIVE_STATUS_IN_PROGRESS`/`TRACKER_NATIVE_STATUS_CODE_REVIEW` mirror
  targets (`lib/tracker/jira-tags.sh`'s `jira_tags_native_status`), and plain `TRACKER=jira`'s
  seven hardcoded status names (`lib/tracker/jira.sh`'s `tracker_transition`). Today a mismatch
  here is invisible until the poller actually attempts that one specific transition at runtime —
  jira-tags degrades silently (label updated, native-status mirror just logs a warning to stderr
  and leaves the board status alone), plain jira.sh fails that one transition outright — either
  way, undiscovered until it happens to a real ticket, buried in the poll log. This was flagged
  directly by the user as missing from the original draft of this plan.
- README documentation for the new flag(s) and when to reach for them.

**Out of scope:**
- Detecting *which* harness version/commit a consumer repo is on. `git subtree add --squash`
  flattens the vendored directory's history into the consumer's own commit graph — there's no
  `.git` inside `ai-intake-harness/` to introspect, and no version file exists today. Don't invent
  one just for this; the audit's checklist itself is the signal, not a version diff.
- Editing the *content* of any existing file (`.env.local`, `.ai/intake.config`,
  `scripts/intake-cron.sh`, the consumer's `Makefile`, any `.claude/settings.*.json` or
  `.gemini/settings.json` that already exists). Fix mode only ever creates files that don't exist
  yet.
- Touching the live crontab under `--fix`. Always report-only, pointing at the existing
  `--install-cron` flag — installing a cron entry is a system-state change the user should invoke
  explicitly, same reasoning `--install-cron` already exists as its own opt-in flag rather than
  happening automatically.
- Adding a new hard dependency (python/jq/node) purely for strict JSON validation of
  `.gemini/settings.json` — best-effort only, skipped if nothing suitable is on PATH.

## Key decisions

1. **Extend `install.sh`, don't write a new script.** `--verify`/`--fix` reuse `REPO_ROOT`
   resolution, `ENV_LOCAL`/`INTAKE_CONFIG`/`CRON_WRAPPER`/`GEMINI_SETTINGS` path vars, and the
   existing `jira-common.sh` sourcing. A standalone script would duplicate all of that.
2. **`--fix` is additive-only, never edit-in-place.** It may create: `.gemini/settings.json` (via
   the existing `_scaffold_gemini_permission_profile`), append
   `project_gemini_permission_profile` to a project adapter file that exists but lacks it (same
   function), and create `scripts/intake-cron.sh` from the template if it's wholly absent (via the
   new `_scaffold_cron_wrapper`, factored out of the main flow). It never rewrites a file that
   already exists with different content than the template, and never touches the crontab itself
   or the consumer's `Makefile`.
3. **Adapter names are discovered, not hardcoded.** Valid `AI_PROVIDER`/`TRACKER` values are read
   by listing `lib/ai/*.sh` / `lib/tracker/*.sh` in the harness directory, so a newly added
   adapter is picked up with no verify-script edit. The **project-adapter contract function
   names** (`project_derive_names`, `project_install_deps`, `project_provision_fresh`,
   `project_build`, `project_test`, `project_verify`, `project_permission_profile`, plus
   `project_gemini_permission_profile` when `AI_PROVIDER=gemini`) have no directory to discover
   from and stay a hardcoded list, matching README.md's "Project adapter" contract section and
   `.ai/system.md` — a known duplication to keep in sync if that contract ever grows (call this
   out with a comment in the code pointing at both docs).
4. **Exit code reflects audit health, not just "did the script crash."** `install.sh --verify`
   exits `1` if anything is MISSING or WARN, `0` if everything checked out — makes it usable as a
   scriptable pre-flight/health check (e.g. a Makefile target, or a manual habit after `git
   subtree pull`), not just a human-read report. The normal no-flags flow's own exit code is
   unchanged by folding the audit summary into its tail (still governed by the existing Jira
   connectivity test), so nothing that already calls `install.sh` today breaks.
5. **Report grouping mirrors the README's own section order** (Jira auth → `.ai/intake.config` →
   AI provider → tracker adapter → project adapter contract → permission profiles →
   `scripts/intake-cron.sh` → crontab → Makefile targets) so the report reads like a checklist
   against the Quickstart steps, in order.
6. **One check is deliberately allowed to hit the network: the native-status mapping.** Every
   other category check in `_run_verify` is local-only by design (decision/step-7's own original
   reasoning: "duplicating `--test-only` would slow down every `--verify` run with a network
   call"). The state→status mapping check is the one exception — it is genuinely impossible to
   verify without asking Jira what statuses the project's workflow actually has
   (`GET /rest/api/2/project/{key}/statuses`), and it's exactly the class of bug (a board column
   renamed, or a status typo'd in `.ai/intake.config`) that's otherwise invisible until a real
   ticket hits it. Gate it behind a best-effort `jira_common_load_env` call: if Jira isn't
   reachable (offline, no `.env.local` yet, bad creds), skip this one sub-check with a note
   pointing at `--test-only`, rather than failing the whole `--verify` run over it.

## Files to change

- `install.sh` — add `--verify`/`--fix` flag parsing; new `_run_verify` function plus one helper
  check function per category (see Implementation order); factor the existing inline
  `scripts/intake-cron.sh` heredoc into `_scaffold_cron_wrapper`; call a report-only `_run_verify`
  at the tail of the normal (no-flags) flow; update the top-of-file "Does N things" doc comment.
- `lib/tracker/jira-common.sh` — new `jira_project_statuses PROJECT_KEY` helper (one REST call,
  shared by both Jira-flavored adapters' verify checks — see step 7).
- `README.md` — new subsection (after step 7, before "Adapter contracts") documenting
  `install.sh --verify` / `--verify --fix`: what it checks, what `--fix` will and won't touch, and
  "run this after `git subtree pull`."

## Implementation order

1. **Factor the cron wrapper scaffold into a function.**
   In `install.sh`, extract the existing inline block that creates `$CRON_WRAPPER` (currently
   inside the `if [ "$TEST_ONLY" -eq 0 ]` branch — the `mkdir -p "$REPO_ROOT/scripts"` +
   `cat > "$CRON_WRAPPER" <<EOF ... EOF` + `chmod +x` + follow-up echo lines) into a new function
   `_scaffold_cron_wrapper`, placed next to `_scaffold_gemini_permission_profile`. Replace the
   inline block's call site with `if [ -f "$CRON_WRAPPER" ]; then echo "... leaving it alone."; else
   _scaffold_cron_wrapper; fi`, preserving the exact template content and echoed instructions
   byte-for-byte.
   **Acceptance check**: `bash -n install.sh` passes; re-run the existing scratch-repo smoke test
   from the prior gemini-scaffolding work (fresh fake consumer repo, `install.sh < /dev/null`) and
   confirm `scripts/intake-cron.sh` is created with identical content to before this refactor
   (`diff` against a copy saved before the change).

2. **Add discovery helpers.**
   Add two small functions: `_known_ai_providers` (echoes `$(basename -s .sh
   "$SCRIPT_DIR"/lib/ai/*.sh)`, one per line) and `_known_trackers` (same over
   `$SCRIPT_DIR/lib/tracker/*.sh`). These replace hand-maintained lists anywhere the verify report
   needs to validate `AI_PROVIDER`/`TRACKER` values.
   **Acceptance check**: `_known_ai_providers` run standalone (`bash -c '. install.sh...'`  or a
   quick inline test) lists exactly `claude gemini codex antigravity local-llm` against this
   repo's current `lib/ai/`.

3. **Write `_run_verify`, the report engine.**
   Add a function `_run_verify` that:
   - Declares `local issues=0` and a small helper `_v_ok`/`_v_missing`/`_v_warn` (each takes a
     message, prints it prefixed `[OK]`/`[MISSING]`/`[WARN]`, and `_v_missing`/`_v_warn` increment
     `issues`).
   - Runs each category check below in README order, calling the `_v_*` helpers.
   - Ends by printing a one-line summary (`"N checks, N issue(s)."`) and `return`s `issues` (bash
     functions cap return values at 255, but this repo's checklist is well under that — fine as
     an exit-code proxy).
   **Acceptance check**: with no other logic yet (empty checks), calling `_run_verify` prints just
   the summary line and returns 0.

4. **Category check: `.env.local`/`.env`.**
   Inside `_run_verify`: if neither `$ENV_LOCAL` nor `$REPO_ROOT/.env` exists, `_v_missing "No
   .env.local — run install.sh to create one (README step 2)."`. Else if `$ENV_LOCAL` still
   matches the placeholder check already used elsewhere in this file
   (`grep -q '^JIRA_SITE_URL=https://your-site.atlassian.net$'`), `_v_warn "$ENV_LOCAL still has
   placeholder values."`. Else `_v_ok "$ENV_LOCAL configured."`.
   **Acceptance check**: point `REPO_ROOT` at a scratch repo with no `.env.local` → see `[MISSING]`
   line; copy in the placeholder `.env.local.dist` → see `[WARN]`; fill in a real `JIRA_SITE_URL`
   → see `[OK]`.

5. **Category check: `.ai/intake.config` presence + known-key report.**
   If `$INTAKE_CONFIG` doesn't exist, `_v_missing` with a pointer to README step 3. Otherwise, for
   each key in the same list `lib/intake-config.sh` documents (`TRACKER TRACKER_PROJECT_KEY
   TRACKER_APP_TAG TRACKER_GATE_COMMENTS PROJECT_ADAPTER PROJECT_DB_PREFIX PLAN_WORKTREE_PREFIX
   AI_PROVIDER AI_PLANNING_MODEL AI_IMPLEMENTATION_MODEL AI_LOCAL_LLM_BASE_URL AI_LOCAL_LLM_MODEL
   AI_LOCAL_LLM_TIMEOUT`), check whether it appears uncommented in the file
   (`grep -qE "^${key}="`) and print one combined `_v_ok "<n> of <total> intake.config keys set
   (defaults apply to the rest)."` line rather than one line per key (keeps the report short —
   the point is surfacing *drift*, not reprinting the whole file). Then: if
   `TRACKER=jira-tags` is set but `TRACKER_APP_TAG` is absent/blank, `_v_missing "TRACKER=jira-tags
   requires TRACKER_APP_TAG (README step 3)."`.
   **Acceptance check**: scratch repo with a minimal `intake.config` (`TRACKER=jira-tags` only, no
   `TRACKER_APP_TAG`) → see the missing-app-tag `[MISSING]` line.

6. **Category check: AI provider.**
   Read `AI_PROVIDER` out of `$INTAKE_CONFIG` (default `claude`, matching
   `lib/intake-config.sh`'s own default). If it's not in `_known_ai_providers`'s output,
   `_v_missing "AI_PROVIDER='$x' doesn't match any lib/ai/*.sh adapter."`. Else call
   `_validate_ai_provider "$x"` (existing function) — but audit mode shouldn't print its
   "OK — ... looks ready" / warning lines through the raw function as-is if they don't fit the
   `[OK]`/`[WARN]` prefix convention; wrap its return value instead:
   `if _validate_ai_provider "$x" >/tmp/... 2>&1; then _v_ok "..."; else _v_warn "..."; fi` — or,
   simpler and avoiding a temp file, add a boolean-returning sibling `_ai_provider_ready "$x"`
   that both `_validate_ai_provider` (prints its own messages, used by the interactive wizard) and
   `_run_verify` (wants a clean OK/WARN line) can call. Prefer the sibling-function approach: less
   duplicated logic than parsing captured output.
   **Acceptance check**: scratch repo, `AI_PROVIDER=bogus` → `[MISSING]`; `AI_PROVIDER=gemini` with
   no `GEMINI_API_KEY` set → `[WARN]`; `AI_PROVIDER=claude` on a machine with `claude` on PATH and
   valid auth → `[OK]`.

7. **Category check: tracker adapter, plus the live native-status mapping check.**
   First, the cheap local part, same shape as step 6: `TRACKER` (default `jira`) must be in
   `_known_trackers`'s output; `_v_missing` if not, `_v_ok` otherwise.

   Then, only when `TRACKER` is `jira` or `jira-tags` (the two adapters that map abstract states
   onto literal Jira status names — a hypothetical `github`/custom adapter has no equivalent
   concept), run the live sub-check the user specifically asked this plan to cover: **does the
   configured/hardcoded status-name mapping actually match real statuses in this Jira project's
   workflow?**
   - Add `jira_project_statuses PROJECT_KEY` to `lib/tracker/jira-common.sh`:
     ```bash
     jira_project_statuses() {
         jira_api GET "/rest/api/2/project/$1/statuses" | jq -r '.[].statuses[].name' | sort -u
     }
     ```
     (`GET /rest/api/2/project/{key}/statuses` returns every status configured across the
     project's issue types — the same shape `jira_api` already speaks elsewhere in this file.)
   - In `_run_verify`, attempt `jira_common_load_env "$REPO_ROOT"` (suppress its own stdout/stderr
     noise — it's chatty on success, e.g. eager credential verification). If it fails, `_v_warn
     "Skipping the Jira status-mapping check — Jira isn't reachable yet (see install.sh
     --test-only)."` and stop this sub-check here; don't let a network/auth failure block the rest
     of `_run_verify`.
   - If reachable, call `real_statuses="$(jira_project_statuses "$TRACKER_PROJECT_KEY")"`.
     - **`TRACKER=jira`**: check each of the seven literal names `tracker_transition` in
       `lib/tracker/jira.sh` hardcodes — `Ready for Planning`, `Needs Author Input`,
       `Plan Review`, `Ready for Implementation`, `In Progress`, `Ready for Verification`, `Done`
       — appears in `$real_statuses`. Collect any that don't and `_v_missing "This Jira project's
       workflow has no status(es) named: <list>. lib/tracker/jira.sh's abstract→status mapping is
       fixed (not configurable) — either rename the corresponding status(es) in Jira's workflow
       configuration, or this project can't fully drive the pipeline via TRACKER=jira."` if any
       are absent, else `_v_ok "All jira.sh abstract-state status names exist in this project's
       workflow."`.
     - **`TRACKER=jira-tags`**: check `TRACKER_NATIVE_STATUS_IN_PROGRESS` (default `In Progress`)
       and `TRACKER_NATIVE_STATUS_CODE_REVIEW` (default `Code Review`) — read from
       `$INTAKE_CONFIG` the same way other keys are, falling back to the adapter's own defaults —
       both appear in `$real_statuses`. `_v_missing "TRACKER_NATIVE_STATUS_IN_PROGRESS='<x>' /
       TRACKER_NATIVE_STATUS_CODE_REVIEW='<y>' — <name> doesn't match any status in this Jira
       project's workflow; the state:* label will still update correctly (that's the real source
       of truth), but the board's native status column won't mirror it. Fix the
       TRACKER_NATIVE_STATUS_* value(s) in .ai/intake.config to match this project's actual board
       column name(s)."` naming whichever of the two is/are wrong, else `_v_ok "Both
       TRACKER_NATIVE_STATUS_* values exist in this project's workflow."`.
   - This check only confirms the status names **exist somewhere in the project's workflow** —
     not that every specific transition edge (e.g. "In Progress" specifically reachable from
     wherever a given ticket currently sits) is reachable, since that's per-issue-type and
     per-current-status. That finer-grained reachability is what `jira_tags_set_state`'s own
     runtime warning (and `tracker_transition_to_status`'s "no transition to 'X' available"
     error) already catches live, non-fatally, ticket by ticket — good enough as a backstop for
     that narrower case; re-verifying full graph reachability statically here isn't worth the
     complexity this plan would need to add.
   **Acceptance check**: `TRACKER=bogus` → `[MISSING]` (local check, no network hit). `TRACKER=jira`
   or `jira-tags` with no reachable Jira (e.g. placeholder `.env.local`) → the local check still
   runs, and the live sub-check prints its skip `[WARN]` pointing at `--test-only` rather than
   erroring the whole run. Against a real (or realistically faked, see step 16) Jira project:
   `TRACKER_NATIVE_STATUS_IN_PROGRESS=Nonexistent Column` → `[MISSING]` naming it; reverting it to
   a real column name → `[OK]`. Same for `TRACKER=jira` against a project missing one of the seven
   hardcoded status names.

8. **Category check: project adapter contract.**
   Resolve `adapter="$(sed -n 's/^PROJECT_ADAPTER=\([^ \t#]*\).*/\1/p' "$INTAKE_CONFIG" | head -1)";
   adapter="${adapter:-symfony-docker}"` (same extraction already written for
   `_scaffold_gemini_permission_profile` — factor this one-liner into a small
   `_project_adapter_name` helper both call, instead of duplicating the `sed`). Resolve
   `adapter_file="$REPO_ROOT/scripts/lib/project/$adapter.sh"` (respecting a `PROJECT_ADAPTER_PATH`
   override the same way, if set in `$INTAKE_CONFIG`). If missing, `_v_missing "$adapter_file
   doesn't exist yet (README step 4)."` and skip the rest of this check. Otherwise, for each
   required function name in `project_derive_names project_install_deps project_provision_fresh
   project_build project_test project_verify project_permission_profile`, grep for it being
   defined (tolerate both `name()` and `function name` — pattern:
   `grep -qE "(^|[[:space:]])(function[[:space:]]+)?${fn}[[:space:]]*\(\)"`); collect any missing
   names and `_v_missing "adapter_file is missing: <space-separated list>"` if any, else `_v_ok`.
   If the resolved `AI_PROVIDER` is `gemini`, additionally check for
   `project_gemini_permission_profile` the same way, `_v_missing` (not `_v_warn` — per
   `lib/ai/gemini.sh`, its absence makes implementation refuse to launch outright) if absent.
   **Acceptance check**: scratch repo with an adapter file missing `project_test` → see it named
   in the `[MISSING]` line; add a stub `project_test() { :; }` → check clears.

9. **Category check: permission profile file(s).**
   If `AI_PROVIDER=claude`: `ls "$REPO_ROOT"/.claude/settings.*.json` — `_v_warn` if none found
   ("unattended workers will run in Claude's default permission mode — see README step 7"), `_v_ok`
   otherwise (don't try to validate curated allow/deny contents — that's a judgment call, not a
   drift check). If `AI_PROVIDER=gemini`: check `$GEMINI_SETTINGS` exists — `_v_missing` if not
   (mention `--fix` will create a starter one). If it exists, best-effort JSON validity: only if
   `command -v jq` (or `python3 -c 'import json'`) is available, try parsing it and `_v_warn` on
   parse failure; otherwise skip validation silently (per the "no new hard dependency" boundary)
   and just `_v_ok "$GEMINI_SETTINGS exists."`.
   **Acceptance check**: `AI_PROVIDER=gemini`, no `.gemini/settings.json` → `[MISSING]`; run with
   `--fix` → file created, re-run `--verify` alone → `[OK]`; hand-corrupt the JSON, `jq` installed
   → `[WARN]`.

10. **Category check: `scripts/intake-cron.sh`.**
    `_v_missing` if `$CRON_WRAPPER` doesn't exist (mention `--fix` will scaffold it). If it exists,
    `grep -qF "cd $REPO_ROOT" "$CRON_WRAPPER"` — `_v_warn "cron wrapper's cd target doesn't match
    the current repo root — was this repo moved/renamed?"` if it doesn't match, `_v_ok` otherwise.
    Never inspect/report on its `ANTHROPIC_API_KEY`/`GEMINI_API_KEY` lines — those are
    intentionally host-specific and outside this audit's business.
    **Acceptance check**: rename the scratch repo's directory after a first `install.sh` run,
    re-run `--verify` from the new path → see the `cd` mismatch `[WARN]`.

11. **Category check: crontab entry.**
    Skip entirely (no OK/MISSING/WARN line at all, not even a skip note — keep the report focused
    on hosts that actually use cron) if `command -v crontab` fails. Otherwise
    `crontab -l 2>/dev/null | grep -qF "$REPO_ROOT/scripts/intake-cron.sh"` — `_v_warn` pointing at
    `--install-cron` if absent, `_v_ok` if present.
    **Acceptance check**: on a machine with `crontab` and no existing entry → `[WARN]`; after
    `install.sh --install-cron` → `[OK]`.

12. **Category check: Makefile targets.**
    Skip entirely if `$REPO_ROOT/Makefile` doesn't exist (not every consumer uses `make` — silence
    here isn't a claim anything is wrong). Otherwise, for each of `worktree-go worktree-new
    worktree-remove intake-plan` (the targets README step 5 lists as required; `intake-poll-log` is
    convenience-only per its own doc comment, so leave it out of the required set), grep for
    `^<target>:` in the Makefile; `_v_warn "Makefile is missing target(s): <list> (README step 5)."`
    if any are absent, `_v_ok` otherwise.
    **Acceptance check**: scratch repo's Makefile missing `intake-plan:` → see it named in the
    `[WARN]` line.

13. **Wire up `--verify` and `--fix` flags.**
    In the arg-parsing loop, add `--verify) VERIFY=1 ;;` and `--fix) FIX=1 ;;` (both default `0`,
    declared alongside `TEST_ONLY`/`INSTALL_CRON`/etc). Immediately after the existing
    `--install-browser-cookie3`/`--install-cron` early-exit blocks, add:
    ```bash
    if [ "$VERIFY" -eq 1 ]; then
        _run_verify
        issues=$?
        if [ "$FIX" -eq 1 ]; then
            echo
            echo "==> Applying safe fixes ..."
            [ -f "$GEMINI_SETTINGS" ] || _scaffold_gemini_permission_profile   # also handles the
                                                                                 # project-adapter append
            [ -f "$CRON_WRAPPER" ] || _scaffold_cron_wrapper
            echo "==> Re-checking ..."
            echo
            _run_verify
            issues=$?
        fi
        exit "$issues"
    fi
    ```
    Note `_scaffold_gemini_permission_profile` should only actually run when `AI_PROVIDER=gemini`
    (it's already guarded at its call site in the main flow via the `grep -qE
    '^AI_PROVIDER=gemini...'` check — reuse that same guard here rather than calling it
    unconditionally). Also guard `--fix` with an early error if passed without `--verify`
    (`[ "$FIX" -eq 1 ] && [ "$VERIFY" -eq 0 ]` → `echo "FAILED: --fix requires --verify" >&2; exit
    1`), checked right after arg parsing, before `REPO_ROOT` resolution.
    **Acceptance check**: `install.sh --fix` alone (no `--verify`) exits 1 with the error message;
    `install.sh --verify` on a fully-configured scratch repo exits 0 and prints all `[OK]`;
    `install.sh --verify --fix` on a repo missing `.gemini/settings.json` (with `AI_PROVIDER=gemini`)
    creates it and the second `_run_verify` pass shows `[OK]` for that line.

14. **Fold a report-only summary into the normal (no-flags) flow.**
    At the very end of the `if [ "$TEST_ONLY" -eq 0 ]; then ... fi` block (after the crontab-entry
    print, before the closing `fi`), add:
    ```bash
    echo "==> Config health check:"
    _run_verify
    echo
    ```
    Do **not** let this `_run_verify` call's return value affect the script's own exit code — the
    script's exit status stays governed by the Jira connectivity test that follows, unchanged from
    today. (Bash's `set -e` would otherwise abort the script here if `_run_verify` returns
    non-zero via a MISSING/WARN count — guard the call as `_run_verify || true`.)
    **Acceptance check**: run `install.sh < /dev/null` end-to-end on a fresh scratch repo; confirm
    it still reaches the final Jira-connectivity section and exits with that section's own status,
    not `_run_verify`'s count.

15. **Update `install.sh`'s header doc comment and README.md.**
    Bump "Does six things" → "Does eight things" (the two new: the tail-of-normal-flow health
    check, and the standalone `--verify`/`--verify --fix` mode), describing both briefly. In
    README.md, add a subsection after step 7 ("Create a curated permission profile") titled
    "### 8. After updating the harness, verify your config" — one short paragraph: run
    `ai-intake-harness/install.sh --verify` any time, especially right after `git subtree pull
    --prefix=ai-intake-harness ... main --squash`, to see what's missing or stale; add
    `--fix` to have it scaffold what it safely can. List what `--fix` will and won't touch (mirror
    Key decision #2 above, briefly).
    **Acceptance check**: `grep -n "install.sh --verify" README.md` finds the new subsection;
    `grep -n "Does eight things" install.sh` confirms the header was updated.

16. **End-to-end smoke test across all four AI providers + both tracker adapters.**
    Using the same scratch fake-consumer-repo technique from the prior gemini-scaffolding work
    (`git init` a throwaway dir, copy this repo's contents into an `ai-intake-harness/`
    subdirectory, no real `.git` inside it): build a handful of `.ai/intake.config` variants
    (missing file entirely; `TRACKER=jira-tags` with and without `TRACKER_APP_TAG`;
    `AI_PROVIDER=gemini` with and without `.gemini/settings.json` and with/without a project
    adapter file defining `project_gemini_permission_profile`; a fully-correct config) and run
    `install.sh --verify` and `install.sh --verify --fix` against each, confirming the report and
    exit code match what steps 4–12's acceptance checks predict, and that `--fix` never modifies a
    file it didn't create from scratch (diff before/after on every existing file). For the live
    native-status sub-check specifically (step 7), a scratch repo has no real Jira behind it, so
    also exercise it directly against **this repo's own self-hosted Jira setup** (its real,
    gitignored `.env.local` + `.ai/intake.config` at the repo root already carry working
    credentials for its own dogfooding project — see `.gitignore`'s "Self-hosting" comment): run
    `ai-intake-harness/install.sh --verify .` from this repo's root (real REPO_ROOT, not a scratch
    copy) and confirm the status-mapping sub-check actually reaches Jira and reports `[OK]`
    against the real project's real statuses — `jira_project_statuses` is read-only (a single
    `GET`), so this is safe to run against the live self-hosted project with no risk of mutating a
    real ticket.
    **Acceptance check**: all variants produce the expected `[OK]`/`[MISSING]`/`[WARN]` lines and
    exit codes; `git diff` (or a pre/post file-hash comparison, since the scratch repo has no
    interesting git history) inside the scratch repo after `--fix` shows changes to newly-created
    files only.

## Boundaries

- Don't touch `lib/intake-config.sh`, `lib/ai/*.sh`, or either adapter's runtime *behavior* — this
  plan only adds an audit/scaffold layer on top of `install.sh`, no changes to how the poller or
  worktree scripts resolve config. The one deliberate exception is the new read-only
  `jira_project_statuses` helper added to `lib/tracker/jira-common.sh` (step 7) — additive only,
  no existing function in `jira.sh`/`jira-tags.sh`/`jira-common.sh` is modified.
- Don't edit the content of any file `--fix` finds already existing — MISSING/WARN items for
  those always stay report-only with a pointer to the relevant README step.
- Don't add a new dependency (python/jq/node) as a hard requirement — the `.gemini/settings.json`
  JSON-validity check degrades gracefully to "exists" when no JSON tool is available.
- Don't change the exit-code contract of a normal (no-flags) `install.sh` run — it must keep
  exiting based on the Jira connectivity test, same as before this plan.
- No real consumer project (a real tech-stack project adapter) exists in this repo to test the
  project-adapter-contract or permission-profile checks against — those are verified against
  scratch fake-consumer repos, same testing pattern the gemini-scaffolding work already
  established. The live native-status mapping check is the one exception: this repo's own
  self-hosted, gitignored `.env.local`/`.ai/intake.config` (real Jira credentials, used to drive
  this repo's own development — see `.gitignore`'s "Self-hosting" comment) give step 16 a real
  Jira project to verify that specific check against, read-only, with no scratch-repo faking
  needed.

## Open Questions

None blocking — the judgment calls above (additive-only `--fix`, crontab untouched even under
`--fix`, no version-detection, best-effort JSON validation) are resolved under Key decisions.
Flag it if you'd rather `--fix` also install the crontab entry automatically (Key decision #2) —
default here keeps that as a separate explicit opt-in (`--install-cron`), matching how that flag
already works today.
