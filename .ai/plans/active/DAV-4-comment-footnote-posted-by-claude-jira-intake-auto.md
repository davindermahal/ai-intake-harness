# Plan: DAV-4 Comment footnote 🤖 Posted by Claude (JIRA intake automation)

**Status**: completed
**Branch**: feature/DAV-4-comment-footnote-posted-by-claude-jira-intake-auto
**Created**: 2026-08-24
**Updated**: 2026-08-24

## Implementation notes (headless worker, 2026-08-24)

Implemented per this plan: `ai_display_name` added to all five `lib/ai/<name>.sh` adapters
(`Claude`/`Gemini`/`Codex`/`Antigravity`/`Local LLM`); `lib/tracker/jira-common.sh`'s static
`JIRA_AI_COMMENT_FOOTER` footer replaced with a `jira_common_ai_footer` function that asks the
currently-sourced adapter's `ai_display_name` (falling back to the generic `AI`); the stale
`intake-poll.sh` comment fixed; `README.md` / `.ai/system.md` contract docs updated; new
`test/unit/ai_display_name.bats` covering all five adapters plus the fallback/dynamic footer.

**Deviation from plan, disclosed:** step 6 said to delete `JIRA_AI_COMMENT_FOOTER` entirely.
Doing so verbatim would have broken `intake-poll.sh`'s watchdog (`watchdog_stalled_comment_after`,
~line 670), which reads that exact global as a fingerprint substring to detect any AI-posted
comment on a ticket — a real cross-file dependency the plan's "nothing else in this file reads it"
reasoning didn't account for (true of `jira-common.sh` itself, not of `intake-poll.sh`, which
inherits the variable via the same sourcing chain). Fix: kept `JIRA_AI_COMMENT_FOOTER` defined, but
narrowed its value to just the provider-independent constant suffix (`(JIRA intake automation)_`),
which `jira_common_ai_footer` now appends after the dynamic provider name and which still appears
in every generated footer regardless of provider — so the watchdog's fingerprint match keeps
working unmodified, and `test/helpers/fakes.bash` / `test/integration/watchdog.bats` (which set
their own fixture value for this same variable name) needed no changes, exactly as the plan
predicted for the tests, just not for the reason it gave.

**Deviation from plan, disclosed:** step 11 (`make lint && make test`) could only run partially.
This build executed under this repo's own locked-down implementation-worker permission profile
(`.claude/settings.ai-harness-dev.json`: only `shellcheck`, `bash -n`, `git status/diff/add/commit/
log`, `./tracker-comment.sh` allowed — no `make`, no `bats`, no generic `bash -c`/`find -exec`).
Ran the lint target's actual checks directly instead — `shellcheck -S warning` and `bash -n` on
every changed `.sh` file — both clean. Could not invoke `test/bats-core/bin/bats`, so the full
suite (including the new `ai_display_name.bats`) is unexecuted by this worker; verified its logic
by manual trace against `jira_common_ai_footer`'s implementation instead. Please run `make test`
locally/in CI before merging. (Same permission-profile limitation previously disclosed in
`.ai/plans/completed/DAV-2-using-a-different-ai-agent.md`.)

## Goal

Every AI-posted Jira comment ends with a footer that hardcodes `🤖 _Posted by Claude (JIRA
intake automation)_` regardless of which `AI_PROVIDER` actually ran the ticket. Make the footer
name the provider that actually ran (Claude, Gemini, Codex, Antigravity, or a local LLM), not a
literal string.

## Scope

**In:**
- Add an optional `ai_display_name` function to the `ai_*` adapter contract, implemented by all
  five built-in adapters (`lib/ai/claude.sh`, `gemini.sh`, `codex.sh`, `antigravity.sh`,
  `local-llm.sh`).
- Make the single AI-comment footer chokepoint (`lib/tracker/jira-common.sh`) build the footer
  text dynamically from whichever adapter is currently sourced, instead of a hardcoded string.
- Update the two docs that enumerate the `ai_*` contract (`README.md`, `.ai/system.md`) and one
  stale in-code comment that names the old static variable.
- Add a unit test covering the new function and the footer's fallback behavior.

**Out:**
- No change to *how* a provider gets selected/resolved (`resolve_ai_profile`,
  `load_ai_provider`, the `AI_PROVIDER` export in `worktree-go.sh`) — that plumbing already
  correctly threads the resolved provider through to comment-posting time for both phases (see
  Key decisions). This plan only makes the footer *use* it.
- No change to `lib/tracker/jira.sh` / `jira-tags.sh` — both already delegate to
  `jira_common_add_comment`, the one chokepoint being changed.
- No change to Jira wiki markup / comment format beyond the provider name substitution.

## Files to change

- `lib/ai/claude.sh` — add `ai_display_name` → `Claude`.
- `lib/ai/gemini.sh` — add `ai_display_name` → `Gemini`.
- `lib/ai/codex.sh` — add `ai_display_name` → `Codex`.
- `lib/ai/antigravity.sh` — add `ai_display_name` → `Antigravity`.
- `lib/ai/local-llm.sh` — override `ai_display_name` → `Local LLM` (it sources `claude.sh`, which
  would otherwise leak `Claude` through).
- `lib/tracker/jira-common.sh` — replace the static `JIRA_AI_COMMENT_FOOTER` var with a
  `jira_common_ai_footer` function that calls `ai_display_name` if defined.
- `intake-poll.sh` — fix one comment that names the now-removed variable.
- `README.md` — document `ai_display_name` in the "AI provider adapter" contract list.
- `.ai/system.md` — same, in the one-line AI provider adapter contract summary.
- `test/unit/ai_display_name.bats` (new) — unit coverage.

## Key decisions

1. **New contract function, not a data/env plumbing change.** The resolved-provider tracking
   already works: `dispatch_planning` calls `load_ai_provider "$provider"` (which re-sources
   `lib/ai/${provider}.sh`, redefining its `ai_*` functions) immediately before running planning,
   and nothing re-sources a different adapter before `post_comment` runs later in the same
   function — so whichever adapter is sourced at that point is genuinely the one that ran. For
   implementation, `worktree-go.sh:77` already does `export AI_PROVIDER="$PROVIDER"` before
   `lib/intake-config.sh` sources the matching `lib/ai/${AI_PROVIDER}.sh`, and that export is
   inherited by the detached worker process that later calls `tracker-comment.sh`. So the fix is
   purely "make the footer ask the currently-sourced adapter its name" — no new variable needs to
   be threaded through `intake-poll.sh`.
2. **Footer asks via an optional contract function (`command -v ai_display_name`), not a required
   one.** `lib/tracker/jira-common.sh` has no existing dependency on the `ai_*` layer. Making
   `ai_display_name` required would create a hard cross-layer coupling and break anything that
   sources `jira-common.sh` standalone (e.g. a unit test, or a future tracker adapter reuse).
   Mirrors the existing optional-hook pattern `lib/ai/gemini.sh` already uses for
   `project_gemini_permission_profile` (`command -v ... && ...`). Falls back to the literal `AI`
   when undefined.
3. **`local-llm.sh` gets a static `Local LLM` name, not the resolved model id.** Building the real
   footer via `_ai_local_llm_resolve_model` would require a live LM Studio call just to post a
   comment, and could fail/hang comment-posting if LM Studio is briefly unreachable. `Local LLM`
   is enough to answer the ticket's actual question (is it hardcoded to "Claude"?) — confirm this
   default at review (non-blocking, see Open Questions).

## Implementation order

1. **`lib/ai/claude.sh`** — after the existing `ai_load_env()`/`ai_run_planning()`/
   `ai_run_implementation()` block at the bottom of the file, add:
   ```bash
   _ai_claude_display_name_impl() { printf '%s' 'Claude'; }
   ai_display_name() { _ai_claude_display_name_impl "$@"; }
   ```
   Acceptance: `bash -n lib/ai/claude.sh` exits 0, and
   `bash -c 'source lib/ai/claude.sh; ai_display_name'` prints `Claude`.

2. **`lib/ai/gemini.sh`** — same pattern, appended after its existing `ai_load_env()` block:
   ```bash
   _ai_gemini_display_name_impl() { printf '%s' 'Gemini'; }
   ai_display_name() { _ai_gemini_display_name_impl "$@"; }
   ```
   Acceptance: `bash -c 'source lib/ai/gemini.sh; ai_display_name'` prints `Gemini`.

3. **`lib/ai/codex.sh`** — same pattern:
   ```bash
   _ai_codex_display_name_impl() { printf '%s' 'Codex'; }
   ai_display_name() { _ai_codex_display_name_impl "$@"; }
   ```
   Acceptance: `bash -c 'source lib/ai/codex.sh; ai_display_name'` prints `Codex`.

4. **`lib/ai/antigravity.sh`** — same pattern:
   ```bash
   _ai_antigravity_display_name_impl() { printf '%s' 'Antigravity'; }
   ai_display_name() { _ai_antigravity_display_name_impl "$@"; }
   ```
   Acceptance: `bash -c 'source lib/ai/antigravity.sh; ai_display_name'` prints `Antigravity`.

5. **`lib/ai/local-llm.sh`** — it already does `. ".../claude.sh"` near the top (line 37), which
   will now define `ai_display_name` as `Claude`. Append an override alongside its own
   `ai_load_env()`/`ai_run_planning()`/`ai_run_implementation()` reassignment block at the bottom:
   ```bash
   _ai_local_llm_display_name_impl() { printf '%s' 'Local LLM'; }
   ai_display_name() { _ai_local_llm_display_name_impl "$@"; }
   ```
   Acceptance: `bash -c 'source lib/ai/local-llm.sh; ai_display_name'` prints `Local LLM` (not
   `Claude`).

6. **`lib/tracker/jira-common.sh`** — replace the static footer (current lines ~206-214,
   `JIRA_AI_COMMENT_FOOTER='----\n🤖 _Posted by Claude (JIRA intake automation)_'`) with a
   function, and update `jira_common_add_comment` (current lines ~217-221) to call it:
   ```bash
   # jira_common_ai_footer — echoes the AI-comment footer, naming whichever provider actually ran
   # (lib/ai/<name>.sh's optional ai_display_name contract function — sourced by the time any
   # comment posts, see lib/intake-config.sh / dispatch_planning's load_ai_provider). Falls back to
   # the generic "AI" when no adapter is sourced (e.g. this file loaded standalone in a test).
   # Stamped on EVERY comment posted through jira_common_add_comment — see that function's header
   # for why this stays the one un-bypassable chokepoint.
   jira_common_ai_footer() {
       local name="AI"
       command -v ai_display_name >/dev/null 2>&1 && name="$(ai_display_name)"
       printf -- '----\n🤖 _Posted by %s (JIRA intake automation)_' "$name"
   }

   # jira_common_add_comment KEY TEXT — post a plain-text/wiki comment. Returns non-zero on a reported error.
   jira_common_add_comment() {
       local key="$1" text="$2" body resp
       text="$text

   $(jira_common_ai_footer)"
       body="$(jq -n --arg b "$text" '{body:$b}')"
       resp="$(jira_api POST "/rest/api/2/issue/$key/comment" "$body")" || return 1
       ...
   ```
   Keep the rest of `jira_common_add_comment` (the error-handling block after `resp=...`)
   unchanged. Delete the old `JIRA_AI_COMMENT_FOOTER` variable entirely — nothing else in this
   file reads it.
   Acceptance: `bash -n lib/tracker/jira-common.sh` exits 0; `grep -n JIRA_AI_COMMENT_FOOTER
   lib/tracker/jira-common.sh` returns nothing; `grep -n 'jira_common_ai_footer' lib/tracker/jira-common.sh`
   shows the new function and its use inside `jira_common_add_comment`.

7. **`intake-poll.sh`** — around line 538, the comment `# for the summary text above plus
   JIRA_AI_COMMENT_FOOTER added by tracker_add_comment.` names the variable just removed. Reword
   it to `# for the summary text above plus the AI-comment footer added by tracker_add_comment.`
   (same line, no other change — this is doc-only, the code on that line and below is untouched).
   Acceptance: `grep -n JIRA_AI_COMMENT_FOOTER intake-poll.sh` returns nothing.

8. **`README.md`** — in the "AI provider adapter: `lib/ai/<name>.sh`" section (~line 409-418),
   after the existing `ai_run_implementation` bullet, add:
   ```markdown
   - **`ai_display_name`** *(optional)* — echoes a short human-readable name for this provider
     (e.g. `Claude`, `Gemini`). Used only to name the AI in the footer `tracker_add_comment`
     stamps on every posted comment (`lib/tracker/jira-common.sh`); an adapter that omits it falls
     back to the generic `AI`.
   ```
   Acceptance: `grep -n 'ai_display_name' README.md` shows the new bullet.

9. **`.ai/system.md`** — in the "AI provider adapter" bullet (~line 27), append
   `` `ai_display_name` `` to the contract function list: change
   `Contract: \`ai_load_env\`, \`ai_run_planning\`, \`ai_run_implementation\`.` to
   `Contract: \`ai_load_env\`, \`ai_run_planning\`, \`ai_run_implementation\`, \`ai_display_name\`
   (optional).`
   Acceptance: `grep -n 'ai_display_name' .ai/system.md` shows the updated line.

10. **`test/unit/ai_display_name.bats`** (new file) — mirror the sourcing pattern used by
    `test/unit/tracker_ticket_regex.bats` (pure functions, no network, source the adapter file
    directly). Cover:
    - Each of the 5 adapters: `source lib/ai/<name>.sh` then assert `ai_display_name` prints the
      expected string (`Claude`, `Gemini`, `Codex`, `Antigravity`, `Local LLM`).
    - `lib/tracker/jira-common.sh` sourced standalone with no `ai_display_name` defined: assert
      `jira_common_ai_footer` contains `Posted by AI`.
    - `lib/tracker/jira-common.sh` sourced together with `lib/ai/gemini.sh` (i.e. `ai_display_name`
      defined and returning `Gemini`): assert `jira_common_ai_footer` contains
      `Posted by Gemini`.
    Each `@test` block sources fresh (bats runs each test in its own subshell/process, so
    function definitions from one `source` don't leak into the next test) — same isolation
    `tracker_ticket_regex.bats` already relies on.
    Acceptance: `test/bats-core/bin/bats test/unit/ai_display_name.bats` — all tests pass.

11. **Full suite** — after all edits: `make lint && make test`. Acceptance: both exit 0 (lint:
    shellcheck + `bash -n` clean on every changed `.sh` file; test: the full `test/unit` +
    `test/integration` bats suite, including the pre-existing suites that touch
    `dispatch_planning`/`dispatch_implementation`/`watchdog`, still passes unchanged — they fake
    `tracker_add_comment` directly and never exercise `jira_common_add_comment`, so they're not
    expected to need edits, but this step is the check that confirms it).

## Boundaries

- Don't touch `lib/tracker/jira.sh` or `lib/tracker/jira-tags.sh` — both already delegate to
  `jira_common_add_comment`; no adapter-specific footer logic exists there.
- Don't touch `resolve_ai_profile`, `load_ai_provider`, or the `AI_PROVIDER` export in
  `worktree-go.sh` (`intake-poll.sh`, `worktree-go.sh`) — that resolution/threading is already
  correct (see Key decisions #1); this plan only makes the footer consume it.
- Don't change the Jira wiki-markup shape of the footer (`----` rule + italic line) — only the
  provider name inside it.
- Don't add a live LM Studio call to `local-llm.sh`'s display name (see Key decisions #3).
- No changes to `test/helpers/fakes.bash` or `test/integration/watchdog.bats` — they set
  `JIRA_AI_COMMENT_FOOTER` as their own local fixture literal (`AI_PROVIDER=fake` in the poller
  test fixture never reaches `jira_common_add_comment`, which those tests fake out entirely), so
  they don't exercise the real footer function and don't need updating.

## Open Questions

None blocking. Confirm at review:
- `local-llm.sh`'s footer name `Local LLM` (Key decisions #3) — a static label rather than the
  resolved model id, to avoid a live network call at comment-posting time. Reasonable default;
  flag if you'd rather see the model id.
