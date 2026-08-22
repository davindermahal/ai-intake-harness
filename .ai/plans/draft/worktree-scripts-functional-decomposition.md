# Plan (deferred): decompose worktree-go.sh / worktree-new.sh into testable, shared functions

**Status**: draft (deliberately deferred — see "Why deferred" below; not scheduled)
**Created**: 2026-08-21
**Updated**: 2026-08-21
**Related**: `.ai/plans/active/2026-08-21-test-suite-plan.md` (Layer 4b treats these two scripts as
black-box-only until this refactor lands; this document is that refactor's home so the analysis
isn't lost)

## Why deferred, and why this is its own document

The test-suite plan's priority is broad *test* coverage across the existing codebase, not
restructuring production scripts. `worktree-go.sh` and `worktree-new.sh` provision real
infrastructure (git worktrees, Docker containers, real Postgres databases) and `worktree-go.sh`'s
`HEADLESS=1` path is exactly what the poller invokes unattended in production
(`intake-poll.sh`'s `launch_implementation_worker`, via `make worktree-go`). A restructuring of
that code for testability's sake alone deserves its own scoped review rather than riding along
inside "add tests" — different blast radius, different reviewers' attention, different rollback
story. This document exists so the extraction boundaries, the real behavioral differences already
found between the two scripts, and the risk analysis are captured now (while freshly researched)
for whoever picks this up.

**Do this only after** the test-suite plan's Layer 4b (black-box subprocess tests against the
*current*, unrefactored scripts) exists and passes — those tests become the characterization/safety
net this refactor needs, given there is no other coverage of this code today.

## Current state (both files read in full, 2026-08-21)

- **`worktree-go.sh`**: 278 lines, **zero functions defined** — 100% top-level imperative code
  under `set -e`. Handles: `PROFILE=` resolution (lines 58-72), credential/name/port derivation
  (84-101), an existing-worktree guard that behaves differently under `HEADLESS` (112-124), a
  provision-fresh branch (`RESUME != 1`, 126-177: git worktree, env write, DB create+optional-
  clone, precreate dirs, container start+wait+verify, install deps, `SEED`-mode-dependent
  schema/migrate step, asset build) vs. a resume branch (178-194: just ensure the container's
  running), then a launch branch three ways (`HEADLESS` detached worker / interactive terminal +
  Claude / terminal only, 196-264), then a summary banner (266-277).
- **`worktree-new.sh`**: 108 lines, **zero functions defined** — same shape, much smaller: no
  `PROFILE`/`RESUME`/`HEADLESS`/interactive-launch machinery at all. Always: git worktree, env
  write, DB create+clone (unconditional — this script has no `SEED` concept, it's always "clone"),
  precreate dirs, container start+wait+verify, install deps, migrate (never `project_provision_fresh`
  — this script never does a fresh-schema build), then its own summary banner.
- Both source `lib/worktree-common.sh` (already function-based) and `lib/intake-config.sh` for the
  `wt_*`/`project_*`/`ai_*` primitives, then inline everything above at the top level.

### Real duplication found (not hypothetical — read side by side)
`worktree-new.sh`'s steps 1-7 (create worktree → write env → create+clone DB → precreate dirs →
start container → wait+verify → install deps) are **near-byte-identical** to the corresponding
slice of `worktree-go.sh`'s non-`RESUME` branch. The credential/name/port derivation block
(`worktree-go.sh:84-101` vs `worktree-new.sh:25-42`) is essentially line-for-line the same code
in both files today. This is a real maintenance cost independent of testing: the bug-audit fix that
added a 4th `<source-db>` argument to `wt_create_empty_db` had to be hand-applied at both call
sites (`worktree-go.sh:137`, `worktree-new.sh:67`) because nothing shares that call — a shared
function would have made that a single-line, single-review-point diff instead of two.

### Real behavioral differences found (must NOT be merged away during extraction)
- `wt_fix_var_perms` is called in `worktree-go.sh` (line 155) but **not** in `worktree-new.sh` —
  confirm whether this is deliberate before unifying the container-wait step, don't just add or
  drop the call to make the two scripts match.
- The asset-build step (`project_build`, `worktree-go.sh:177`) only exists in `worktree-go.sh`'s
  `SEED=fresh` path — `worktree-new.sh` never builds assets. Preserve this; don't add it to the
  shared path "for consistency."
- `worktree-new.sh` always hard-errors on an existing worktree dir (line 52-55); `worktree-go.sh`
  only does that when NOT `HEADLESS` (auto-`RESUME`s under `HEADLESS`, line 112-124). These are
  genuinely different UX contracts for the two entrypoints, not an oversight — keep them separate,
  parameterize rather than unify.

## Proposed extraction boundaries

Target: move shared step-logic into `lib/worktree-common.sh` (which already holds the `wt_*`
primitives these scripts call), leaving both entrypoint scripts as thin orchestrators that call
into the same shared functions with different flags/branches — **not** merging the two scripts
into one, since their flag surfaces and UX genuinely differ.

| New function | Extracted from | Shared by both scripts? |
|---|---|---|
| `wt_resolve_profile_override BRANCH_VAR...` | `worktree-go.sh:58-72` (`PROFILE=` → `PROVIDER`/`MODEL`) | No — `worktree-go.sh` only |
| `wt_derive_context REPO_ROOT BRANCH PORT_ARG` | `worktree-go.sh:84-101` / `worktree-new.sh:25-42` | **Yes — identical today** |
| `wt_provision_worktree REPO_ROOT BRANCH WORKTREE_DIR PORT XDEBUG_PORT DB_NAME SEED_MODE ...` | `worktree-go.sh:127-150` steps 1-5 / `worktree-new.sh:57-78` steps 1-5 | Yes, parameterized by `SEED_MODE` (`fresh`\|`clone`\|`none`) — `worktree-new.sh` always passes `clone` |
| `wt_wait_and_verify_container APP_CONTAINER ... [--fix-perms]` | `worktree-go.sh:152-159` / `worktree-new.sh:80-86` | Yes, with the `wt_fix_var_perms` call gated by an explicit flag (preserving the difference noted above, not merging it away) |
| `wt_install_and_provision APP_CONTAINER ... SEED_MODE` | `worktree-go.sh:161-177` / `worktree-new.sh:88-92` | Yes, parameterized by `SEED_MODE` — only calls `project_build` when the caller says so (`worktree-go.sh`'s `fresh` path) |
| `wt_resume_existing_worktree APP_CONTAINER ...` | `worktree-go.sh:178-194` | No — `worktree-go.sh` only (`worktree-new.sh` has no resume concept) |
| `wt_launch_headless_worker TICKET WORKTREE_DIR REPO_ROOT BRANCH APP_CONTAINER ...` | `worktree-go.sh:196-244` | No — `worktree-go.sh` only, but **highest test-value target** despite no duplication partner: this is the plan-status-flip + log/pidfile/metafile bookkeeping + `ai_run_implementation` launch that the poller's production `HEADLESS=1` dispatch exercises every time, and nothing today unit-tests it in isolation (Layer 3 of the test-suite plan fakes `ai_run_implementation` at the `intake-poll.sh` level, but the flip-plan-to-ready / restore-from-completed / metafile-writing logic itself is currently untested even there) |
| `wt_launch_interactive_terminal WORKTREE_DIR TICKET BRANCH CLAUDE` | `worktree-go.sh:246-264` | No — `worktree-go.sh` only. Lowest test priority (a human is present when this runs) but cheap to extract alongside the rest for consistency |
| `wt_print_go_summary` / `wt_print_new_summary` | `worktree-go.sh:266-277` / `worktree-new.sh:94-107` | No — genuinely different fields/hints; extract as two small distinct functions (or leave inline — banners are the lowest-risk, most cosmetic part of either script) |

All of these follow the same pattern `project_derive_names` already establishes in this codebase:
set caller-visible globals (`WORKTREE_DIR`, `DB_NAME`, `PORT`, etc.) rather than `local`-scoping
everything and forcing awkward multi-value returns — consistent with existing style, not a new
convention.

## Extraction methodology (behavior-preserving, staged — do not skip steps)

1. **Prerequisite**: Layer 4b black-box bats tests exist and pass against the *current* scripts
   (stub `docker`/`git`/`psql`/`pg_dump`/`pg_restore`/`composer`/`claude` on `PATH`, assert on exit
   code + final banner + resulting `.env.local`). These are the safety net — there is no other
   coverage of this code today.
2. Extract **one function at a time**, in the order listed above (top of the table first — start
   with `wt_resolve_profile_override`, the most self-contained, lowest-risk slice). After each
   extraction: re-run the Layer 4b suite, and re-run `bash -n` + `shellcheck`.
3. **No logic changes during extraction.** Every `echo`, every guard condition, every step order,
   every error message stays byte-for-byte identical to what it replaces. If a real improvement is
   spotted along the way (e.g., "should `worktree-new.sh` also call `wt_fix_var_perms`?"), note it
   and defer it to a follow-up change *after* the extraction is proven behavior-preserving —
   don't fix and refactor in the same diff.
4. Once a function is shared by both scripts, update **both** call sites in the same commit (this
   is the whole point — no more hand-duplicated fixes like the `wt_create_empty_db` one from the
   bug audit).
5. After all extractions land, revisit Layer 4b: some of those black-box tests can be
   **upgraded** to call the new shared functions directly (faster, more precise failure
   attribution) instead of running the whole script as a subprocess — but keep at least one
   full-script black-box test per entrypoint as an end-to-end sanity check.

## Risk assessment

- **Blast radius**: `worktree-go.sh HEADLESS=1` is on the critical path of the poller's
  unattended implementation dispatch — a regression here doesn't just break a developer's local
  `make worktree-go`, it silently breaks the automated ticket-to-implementation pipeline in
  production. Any change to this file (refactor or otherwise) should get the same care as the
  bug-audit fixes: `bash -n` + `shellcheck` clean, plus a real dry-run/manual verification before
  merge, not just "tests pass."
- **No existing coverage**: unlike `intake-poll.sh` (which had 35 functions and clear seams to
  fake), these two scripts have never been tested at all — the refactor is inherently higher-risk
  than the bug-audit's targeted fixes were, purely because there's no existing behavior baseline
  except reading the code carefully (which is what this document's "real differences found"
  section above is trying to capture before it's forgotten).
- **Real infra side effects**: any integration test exercising these scripts for real (not fully
  stubbed) creates actual git worktrees / Docker containers / Postgres databases — never point
  such a test at a real consumer repo's main database; always use disposable fixture repos.

## Suggested sequencing (once picked up)
1. Land Layer 4b black-box tests (from the test-suite plan) against the current scripts.
2. Extract `wt_resolve_profile_override` and `wt_derive_context` (self-contained, `wt_derive_context`
   has the highest immediate dedup payoff).
3. Extract `wt_provision_worktree` + `wt_wait_and_verify_container` + `wt_install_and_provision`
   (the shared provisioning core — the biggest, riskiest slice, do it as its own reviewed change).
4. Extract the `worktree-go.sh`-only pieces (`wt_resume_existing_worktree`,
   `wt_launch_headless_worker`, `wt_launch_interactive_terminal`) — no duplication payoff, but
   unlocks direct unit testing of the headless-launch bookkeeping specifically.
5. Decide on the two summary-banner functions (or leave inline).
6. Upgrade the subset of Layer 4b tests that make sense to call the new functions directly.

## Open design questions for whoever picks this up
- Should `worktree-new.sh` become "call the same shared functions `worktree-go.sh` uses, with
  `SEED_MODE=clone` and no headless/interactive branch," or should it stay a fully independent
  entrypoint that merely happens to share `lib/worktree-common.sh` helpers? (This document assumes
  the former for the shared middle steps, but doesn't assume the two scripts should look identical
  end-to-end.)
- Is the `wt_fix_var_perms` gap between the two scripts (present in `worktree-go.sh`, absent in
  `worktree-new.sh`) intentional, or a pre-existing bug worth its own fix? Investigate before
  building a shared function that has to accommodate it either way.
- Do the two summary banners get extracted at all, or is that not worth the churn given they're
  the least risky, most cosmetic part of either script?
