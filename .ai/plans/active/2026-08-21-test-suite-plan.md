# Plan: A bats-core test suite for the ai-intake-harness bash codebase

**Status**: active
**Branch**: (none yet — planning only)
**Created**: 2026-08-21
**Updated**: 2026-08-21

## Goal

Design and stand up a real automated test suite for this repo's ~20 bash scripts (currently zero
tests — only `bash -n` + `shellcheck` static checks, run manually). **Priority is broad coverage
across the whole service** — every layer below (adapters, poller, worktree lifecycle, `install.sh`)
is in scope and none is optional; sequencing is by dependency and practicality (foundational pieces
first), not by "cover the riskiest area and stop." The areas where the 2026-08-21 bug audit
(`.ai/plans/completed/2026-08-21-bugs.md`) found live bugs — the poller state machine and the
worktree DB guards — get concrete regression tests as part of that broad coverage (called out
inline below), not special-cased ahead of the rest.

## Decisions (resolved 2026-08-21)

- **CI target**: both. `make test`/`make lint` run locally, and the same targets run in GitHub
  Actions on every push/PR — see "CI wiring" below for the concrete workflow.
- **Priority**: broad coverage across the whole service (see Goal above) — every layer in this
  plan is in scope, not just the bug-audit areas.
- **Main-guard refactor**: approved. Small, mechanical structural changes (like the
  `intake-poll.sh`/`install.sh` main-guards below) are in scope for this plan.
- **Large refactor**: the `worktree-go.sh`/`worktree-new.sh` functional decomposition (turning
  their ~0-function, 100%-top-level bodies into shared, directly-testable functions) is explicitly
  **deferred**, not part of this plan. It's fully designed and documented separately at
  `.ai/plans/draft/worktree-scripts-functional-decomposition.md` so the analysis isn't lost —
  pick it up later. Until then, these two scripts get Layer 4b's black-box subprocess coverage
  only (see below), which also doubles as the characterization-test safety net that refactor will
  need whenever it's picked up.

## Codebase shape (why this matters for test design)

Two different shapes exist in this repo, and they need different testing strategies:

1. **Sourced function libraries** — `lib/intake-config.sh`, `lib/worktree-common.sh`,
   `lib/tracker/*.sh`, `lib/ai/*.sh`. Pure function definitions, no unconditional top-level
   execution. **Already directly testable today** — `source` the file, call a function, assert.
2. **Executed root scripts** — `intake-poll.sh`, `install.sh`, `worktree-go.sh`, `worktree-new.sh`,
   `worktree-remove.sh`, `tracker-comment.sh`, `tracker-transition.sh`, `local-llm-spike.sh`,
   `scripts/intake-cron.sh`. Mixed: some (`intake-poll.sh`: 35 functions, `install.sh`: 13,
   `worktree-remove.sh`: 5) hold most of their logic in functions but still run unconditional
   top-level code at the bottom (confirmed: `intake-poll.sh`'s last ~15 lines are a bare
   `case "$POLL_MODE" in ... esac` with no `main`/`BASH_SOURCE` guard — `source`-ing it today to
   unit-test one function would trigger a real poll run). Two scripts
   (`worktree-go.sh`, `worktree-new.sh`) have **zero functions at all** — 100% top-level
   imperative code. This directly shapes the phasing below.

The adapter-seam architecture is a major asset here: `tracker_*`/`project_*`/`ai_*` are plain shell
functions called by name from `intake-poll.sh`/`worktree-go.sh`. Bash resolves the most recently
defined function at call time, so a test can `source` the real adapter, then redefine
`tracker_get_issue`/`tracker_transition`/`ai_run_planning`/etc. with fixture-driven fakes — no
dependency-injection framework, no `LD_PRELOAD` tricks, just function overrides. This is the single
biggest lever available and the plan leans on it heavily (Layer 2/3 below).

External dependencies that any test strategy must account for: the Jira REST API (network + auth),
Docker, Postgres (`psql`/`pg_dump`/`pg_restore`), git worktrees, and five different AI CLIs
(`claude`, `gemini`, `codex`, `agy`, plus LM Studio's HTTP endpoint for `local-llm`), and
`python3`/`browser_cookie3` for the cookie-auth fallback. None of these can run in an ordinary CI
job without either mocking or a live, credentialed environment — see Layer 6.

## Framework choice: bats-core

- Ubuntu 24.04 (this machine's OS) ships `bats` 1.10.0 via apt, which **is** bats-core (the
  original `bats` project was absorbed into bats-core years ago) — `apt-get install bats` gets a
  real, current bats-core with no extra setup. For CI reproducibility independent of the base
  image's package version, vendor `bats-core`, `bats-support`, and `bats-assert` as git submodules
  pinned to tags instead (the standard bats project layout) — recommend starting with the apt
  package locally and switching to submodules once CI is wired up (sequencing step 10, below).
- No other language runtime is required — this keeps the dependency footprint honest for a bash
  project (no reaching for Python/Node test frameworks to test bash).
- Rejected alternative: shellspec (BDD-style, more built-in mocking) — more powerful but a bigger
  learning-curve/dependency ask for what's ultimately a small team; bats' "just bash + a `.bats`
  file that's mostly normal shell" fits this codebase's existing style better, and the
  function-override mocking trick above covers most of what shellspec's mocking would buy anyway.

## Proposed layout

```
test/
  unit/                    # Layer 1-2: pure functions + adapter contracts, no subprocess mocking needed
    slugify.bats
    spec_parsing.bats
    jira_tags_state_machine.bats
    tracker_contract.bats
  integration/             # Layer 3-5: poller state machine, worktree DB guards, install.sh
    dispatch_planning.bats
    dispatch_implementation.bats
    watchdog.bats
    worktree_common_db.bats
    install_verify.bats
  live/                    # Layer 6: opt-in, real Jira/LM Studio, gated by RUN_LIVE_TESTS=1
    jira_live.bats
  fixtures/
    jira/                  # canned tracker_get_issue JSON payloads
      ticket-clean.json
      ticket-with-ai-comment.json
      ticket-missing-fields.json
  helpers/
    fakes.bash             # reusable tracker_*/ai_*/project_* fake implementations + call-log helper
    bin/                   # stub docker/git/psql/pg_dump/pg_restore/composer/curl, PATH-prepended in setup()
    load.bash              # bats-support/bats-assert bootstrap
```

## Structural prerequisites (small, approved — do first, everything else depends on these)

1. **Add a main-guard to `intake-poll.sh`.** Wrap the existing bottom-of-file
   `case "$POLL_MODE" in ... esac` block in:
   ```sh
   if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
       case "$POLL_MODE" in
           ...
       esac
       log "poll complete"
   fi
   ```
   ~5-line diff, zero behavior change when run normally (`bash intake-poll.sh` still has
   `BASH_SOURCE[0] == $0`). Lets tests `source intake-poll.sh` and call `dispatch_planning`,
   `watchdog_check`, etc. directly without triggering a real poll. Low risk, but this file also
   runs unattended via cron in production — validate with a manual `bash -n` + one live dry-run
   after the change, same as any other edit to this file.
2. **Same treatment for `install.sh`** if Layer 5 sources it rather than always shelling out to it
   (see Layer 5 below — recommend NOT doing this one, see rationale there).
3. **`worktree-go.sh`/`worktree-new.sh` strategy**: since they have zero functions, there is no
   "source and call a function" option without a real refactor, and that refactor is explicitly
   **deferred** (see Decisions above) — full design saved at
   `.ai/plans/draft/worktree-scripts-functional-decomposition.md`. This plan uses **black-box
   subprocess testing only** for these two files (Layer 4b) — run the whole script with every
   external binary stubbed via a test-local `PATH`, assert on stdout and the resulting
   `.env.local`/files. These Layer 4b tests are written against the current, unrefactored scripts
   and will later serve as the characterization/safety-net tests for that deferred refactor.

## Test layers (bottom-up, roughly in the order to build them)

### Layer 0 — static analysis (already exists; formalize it)
`bash -n` + `shellcheck -S warning` over every `*.sh`, wired into a `make lint` target. Current
baseline (verified during the bug audit) is clean except 3 pre-existing style nits
(`worktree-go.sh:149`, `worktree-new.sh:77` — SC2155; `lib/worktree-common.sh:112` — SC2034). Fix
those three (trivial) so `make lint` can fail the build on ANY shellcheck warning going forward,
rather than needing a maintained ignore-list.

### Layer 1 — pure-function unit tests (no mocking, highest ROI per hour)
Concrete candidates found during research, all zero-side-effect string/path functions:
- `slugify` (`intake-poll.sh:353`) — table-driven: unicode input, >50-char summary (truncation),
  leading/trailing punctuation, empty string, a summary that's ALL punctuation (edge case: could
  slugify to an empty branch suffix).
- `spec_provider` / `spec_model` (`intake-poll.sh:417-418`) — `"claude"`, `"claude:opus"`,
  `":opus"`, `""` — assert the provider/model split behaves for every shape a Jira label or
  `AI_PROFILE_*` value could actually take.
- `attempts_file` / `dispatch_marker` (`intake-poll.sh:302,338`) — pure path-construction, assert
  exact output for a couple of keys/phases.
- `tracker_ticket_regex` (`lib/tracker/jira.sh:104`, `lib/tracker/jira-tags.sh:205`) — assert it
  matches real ticket keys and rejects near-misses (lowercase, no hyphen, trailing garbage) for
  both adapters.
- `jira_tags_legal_move` (`lib/tracker/jira-tags.sh:99`) — this is a pure state-transition table;
  enumerate every `(from, to)` pair and assert legal/illegal exhaustively. This is also where the
  human-approval-gate boundary is enforced for `TRACKER=jira-tags` — a dedicated test asserting
  `ready-for-implementation` is never a legal target of `jira_tags_legal_move` (or of `jira.sh`'s
  transition map) turns the manual verification done in the bug audit into a permanent regression
  guard.

### Layer 2 — adapter contract tests
- Turn `install.sh`'s existing `--verify` function-existence check into an assertion pattern
  reusable in tests: after `source`-ing `lib/tracker/jira.sh` and `lib/tracker/jira-tags.sh`,
  assert every documented `tracker_*` contract function is `declare -f`-defined; same for each
  `lib/ai/*.sh` adapter's `ai_load_env`/`ai_run_planning`/`ai_run_implementation`. Cheap, catches
  "adapter silently missing a required function" before `install.sh --verify` would in production.
- **Mocking the Jira I/O boundary**: `jira_api` (`lib/tracker/jira-common.sh:131`) is the single
  chokepoint for `jira.sh`/`jira-tags.sh`'s authenticated REST calls — override it in tests to
  return canned JSON from `test/fixtures/jira/*.json` instead of calling `curl`. Note
  `jira_search_jql` (`jira-common.sh:158`) builds its **own** `curl` call rather than going through
  `jira_api` — it needs a separate fake (or fake `curl` itself on `PATH` for tests that exercise
  search). Document this seam split explicitly in `test/helpers/fakes.bash` so the next person
  doesn't assume overriding `jira_api` alone is sufficient.
- With that fake in place: `tracker_search` returns the expected keys for a canned multi-page
  fixture (regression test for the pagination fix, bug #6 — assert a fixture with a
  `nextPageToken` on page 1 causes a second fake-`jira_search_jql`-level call and the combined
  output includes issues from both "pages"); `tracker_abstract_state` maps every real status name
  in the fixtures to the correct abstract state; `tracker_transition` calls the fake with the
  correct transition id resolved from a canned `/transitions` payload, and — the important
  negative test — **no fixture-driven call ever resolves to a `ready-for-implementation`
  transition**, for either adapter.

### Layer 3 — poller state-machine tests (biggest layer; this is where the bugs lived)
Source `intake-poll.sh` (post main-guard) with `STATE_DIR` pointed at a bats temp dir
(`$BATS_TEST_TMPDIR`), and override `tracker_*`/`ai_*`/`project_*` with fixture-driven fakes from
`test/helpers/fakes.bash`. Each fake appends `func_name arg1 arg2 ...` to a call-log file so tests
can assert "called exactly once with these args" / "never called" without a real mock framework.
Concrete scenarios — each one is a direct regression test for a bug fixed in this session, plus the
adjacent cases:

- **`dispatch_planning`, `ai_run_planning` fails** (regression: bug #1, the `set -e` dead-code
  bug) — fake `ai_run_planning` returns 1; assert the *test itself* doesn't abort (proving `rc=$?`
  is actually reached), the ephemeral worktree is removed, and the in-flight marker is left for
  stale-reclaim.
- **`dispatch_planning`, clean decision, `tracker_transition` fails once** (regression: bug #3) —
  fake `tracker_transition` returns 1 on its first call; assert one escalation comment is posted
  (fake `tracker_add_comment`/`post_comment` called once), the in-flight marker is untouched, and a
  **second** `dispatch_planning` call for the same key/spec does **not** re-invoke
  `ai_run_planning` (assert the fake's call-log has exactly one entry) — this is the "silently
  retrying the whole billed phase forever" bug, made assertable.
  Companion test: fake `tracker_transition` succeeds on the *next* attempt after being scripted to
  fail once → assert the escalation marker is cleared and a subsequent call proceeds normally.
- **`dispatch_implementation`, a live worker already running** (regression: bug #2) — pre-seed
  `$RUNNING_DIR/<KEY>.pid` with this test process's own PID (guaranteed "alive" via `kill -0`);
  assert `launch_implementation_worker` (faked) is never called.
- **`dispatch_implementation`, launch succeeds but `tracker_transition` fails** (regression: bug
  #2's second half) — assert exactly one escalation comment, the in-flight marker is left alone
  (not stale-reclaimed immediately), and the running-slot PID file is untouched.
- **`reap_consume_implementation_result`** — `outcome=success` in the fixture result file →
  transitions to `ready-for-verification` and clears the `implementation-transition` escalation
  marker; missing/failed outcome → no transition attempted, left for the watchdog.
- **`watchdog_check`** — table of scenarios: attempts at cap → escalate once, don't restart; dead
  PID + no AI-footer comment → restart; dead PID + an AI-footer comment posted after launch →
  escalate (case C), don't restart; **a comment with an unparseable `created` timestamp**
  (regression: bug #9) → assert a warning is logged and it's treated as "unknown", not silently as
  case A.
- **`process_queue` concurrency cap** — fake `running_count` returns `JIRA_MAX_WORKTREES`; assert
  the handler is never invoked for the remaining queued tickets and the poll continues (doesn't
  abort the whole run).
- **`inflight_active`/staleness** — write an in-flight marker, `touch -d` it to a timestamp older
  than `INFLIGHT_STALE_SECONDS`; assert it's treated as free. Fresh marker → assert it blocks.

### Layer 4a — worktree DB-guard tests (`lib/worktree-common.sh`, directly sourceable, no main-guard needed)
Stub `psql`/`pg_dump`/`pg_restore`/`docker` as fake scripts on a test-local `PATH` prefix that log
their full invocation (argv, and for `psql`, the `-c`/`-v` args) to a file instead of executing
anything real.
- **`wt_create_empty_db`** (regression: bug #4) — refuses (non-zero, stub never invoked) when
  `db` doesn't match `${PROJECT_DB_PREFIX}_*`; refuses when `db == source_db`; on a legal call,
  assert the stub's logged invocation used `-v db=<name>` with the literal `:"db"`/`:'db'` tokens
  in the `-c` SQL text (regression: bug #8 — proves the SQL is parameterized, not
  string-interpolated; a stronger variant passes a syntactically-legal-but-quote-containing db name
  through and asserts the captured SQL text is unchanged/inert rather than containing a broken-out
  statement).
- **`wt_drop_db`** — same two guards, plus asserting the terminate-backends `-c` runs before the
  `DROP DATABASE` `-c` in the same invocation.
- **`wt_free_port`** — stub `docker ps --format '{{.Ports}}'` output with canned "already
  published" ports; assert the function returns the first truly-free port at or after the
  requested one.

### Layer 4b — worktree-go.sh / worktree-new.sh (deferred, black-box only)
Run the whole script as a subprocess with `docker`/`git`/`psql`/`pg_dump`/`pg_restore`/`composer`
(and, for the headless-launch path, a fake `claude`) stubbed on `PATH`; assert on exit code, the
final summary output, and the resulting `.env.local` contents. Lower priority — do this after
Layers 1-4a prove the fixture/stub approach works, since it's the most expensive layer to write
(most moving parts, least existing function-level seam to hook).

### Layer 5 — `install.sh --verify`/`--fix` tests
Build tiny throwaway "consumer repo" fixtures under a bats temp dir: a minimal `.env.local`,
`.ai/intake.config`, and a fake `scripts/lib/project/fake-stack.sh` with all-or-some of the
required contract functions defined. Run `install.sh --verify <fixture-dir>` **as a real
subprocess** (not sourced — `install.sh`'s interactive wizard code makes a main-guard refactor
higher-risk for the value it'd add here, and subprocess testing is sufficient since `--verify` is
already a clean, side-effect-scoped mode) and assert on the `[OK]`/`[MISSING]`/`[WARN]` lines and
exit code. Specific tests:
- A fixture adapter missing `project_migrate` produces `[MISSING] ... project_migrate` (regression
  test for the doc/#3 fix made this session — proves the newly-added required-function entry
  actually fires).
- `--fix` against a fixture with net-new files missing: assert the files it's documented to
  scaffold appear; assert an *existing* file's mtime and byte-for-byte content are unchanged by
  `--fix` (regression guard for the "net-new files only" contract stated in the script's own header
  comment).
- The live Jira status-mapping check inside `--verify` should be **skippable/mockable** in this
  layer (fixture-based tests must not hit real Jira) — either fake `jira_project_statuses` the same
  way Layer 2 fakes `jira_api`, or set `TRACKER=` to something that doesn't trigger the live check
  for the non-Jira-focused assertions, and cover the live check itself only in Layer 6.

### Layer 6 — live smoke tests (opt-in, gated, not part of default `make test`)
A small number of tests behind `RUN_LIVE_TESTS=1` that call `install.sh --test-only`,
`install.sh --verify` against the **real** configured Jira project (as manually verified during the
bug audit), `install.sh --test-cookie` if the cookie fallback is configured, and
`local-llm-spike.sh` against a real LM Studio instance if reachable. These need real
credentials/network, are inherently slower/flakier, and must stay out of the default CI path —
document them as a manual/scheduled check, not a merge gate.

## What this plan deliberately does NOT cover
- A full functional refactor of `worktree-go.sh`/`worktree-new.sh` into testable functions — see
  the dedicated `.ai/plans/draft/worktree-scripts-functional-decomposition.md` for that design;
  deliberately deferred out of this plan (see Decisions above).
- Spinning up real Docker containers / a real Postgres instance in CI for Layer 4 — the stub-binary
  approach avoids needing Docker-in-Docker; a later "real infra" integration tier is a possible
  follow-up but adds meaningfully more CI complexity and is lower ROI than the logic bugs Layer 3
  targets.
- Testing the AI CLIs' own output quality (`claude`/`gemini`/`codex`/`agy`) — only that the harness
  invokes them with the documented automation-boundary flags (already partly covered by the bug
  audit's adapter-library review; codifying those flag assertions as Layer 2-adjacent tests is a
  cheap add-on worth doing but is about the harness's own correctness, not the AI's).
- Consumer-repo project adapters (`scripts/lib/project/*.sh`) — those live outside this repo; the
  most this plan can do is test that `install.sh`'s contract-completeness check works correctly
  against a fixture adapter (Layer 5).

## Sequencing / rough effort (solo dev, focused work)
1. Structural prerequisite (main-guard in `intake-poll.sh`) — ~1 hour, low risk.
2. Bootstrap: install bats-core, scaffold `test/helpers/`, write the first fixtures — ~half day.
3. Layer 0 (formalize lint) + Layer 1 (pure-function units) — ~half day, quick wins.
4. Layer 2 (adapter contracts + the `jira_api`/`jira_search_jql` fake split) — ~1 day.
5. Layer 3 (poller state machine) — ~2-3 days; the biggest layer and the highest-value one, since
   it's where the bugs actually were.
6. Layer 4a (worktree DB guards) — ~1 day.
7. Layer 4b (worktree-go/worktree-new black-box) — ~1 day, do last among the integration layers.
8. Layer 5 (`install.sh --verify`/`--fix`) — ~1 day.
9. Layer 6 (live smoke, opt-in) — ~half day; mostly wiring existing `--test-only`/`--test-cookie`/
   `local-llm-spike.sh` into a gated `make test-live` target rather than writing new test logic.
10. CI wiring (see below) — ~half day.

Total: roughly 1.5-2 weeks of focused solo work. All ten steps are in scope — the ordering above is
by dependency and practicality (foundational/cheap pieces first), not a priority ranking to stop
early on; broad coverage across the whole service means Layers 4b, 5, and 6 are deliverables too,
not optional extras.

## CI wiring (both local and GitHub Actions — resolved)

This repo currently has no `.github/` directory at all — this plan adds one. Both targets run the
*same* underlying commands, so there's no drift between what a developer runs locally and what CI
checks:

**`Makefile` targets** (root, alongside the existing `worktree-go`/`intake-*` targets from
README.md's "Wire up the Makefile"):
```makefile
lint:
	shellcheck -S warning $$(find . -name '*.sh' -not -path './.git/*' -not -path './.intake/*')
	@for f in $$(find . -name '*.sh' -not -path './.git/*'); do bash -n "$$f" || exit 1; done

test:
	bats test/unit test/integration

test-live:
	RUN_LIVE_TESTS=1 bats test/live
```

**`.github/workflows/test.yml`** — two jobs, both on `push` and `pull_request`:
```yaml
name: test
on: [push, pull_request]
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: sudo apt-get update && sudo apt-get install -y shellcheck
      - run: make lint
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: sudo apt-get update && sudo apt-get install -y bats jq
      - run: make test
```
No `services:` block (no Docker-in-Docker, no real Postgres container) is needed for Layers 1-5 —
that's the point of the stub-binary approach in Layers 4a/4b/5: `docker`/`psql`/`pg_dump`/
`pg_restore` are faked on `PATH`, never actually invoked. This keeps the CI job fast and
credential-free. `make test-live` (Layer 6) is **not** part of this workflow — it needs real Jira
credentials and is inherently slower/flakier; if ever automated, it belongs in a separate,
manually- or schedule-triggered workflow with its secrets configured explicitly, kept out of the
PR-blocking path.

Given the CI target is confirmed as GitHub Actions, switch from the apt `bats` package to vendored
`bats-core`/`bats-support`/`bats-assert` git submodules pinned to tags (per the Framework Choice
section above) as part of sequencing step 10 below, so the exact same bats version runs locally and in CI
regardless of what a given Ubuntu image ships.

Recall `AGENT.md`'s human-approval-gate boundary: this harness's own CI must never be wired to
auto-merge or auto-transition tickets — this workflow is pure verification (lint + test) and
doesn't touch that boundary, but it's worth stating explicitly given how central that invariant is
to the project. Nothing in this workflow pushes, merges, or writes to the tracker.
