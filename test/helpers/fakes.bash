# Shared fixture/fake helpers for the ai-intake-harness bats suite.
#
# Seam split (see .ai/plans/active/2026-08-21-test-suite-plan.md, Layer 2): jira_api is the
# chokepoint for jira.sh/jira-tags.sh's authenticated REST calls EXCEPT jira_search_jql, which
# builds its own curl call directly — overriding jira_api alone does not fake search. Tests that
# exercise tracker_search must also fake jira_search_jql (or stub curl on PATH).

# fixture_json NAME — path to test/fixtures/jira/NAME (NAME may omit .json).
fixture_json() {
    local name="$1"
    case "$name" in *.json) ;; *) name="${name}.json" ;; esac
    printf '%s/fixtures/jira/%s' "$TEST_ROOT" "$name"
}

# fixture_path RELATIVE_PATH — a path under test/ (stable — unlike $REPO_ROOT, which
# poller_source's `source intake-poll.sh` reassigns to the fixture repo).
fixture_path() {
    printf '%s/%s' "$TEST_ROOT" "$1"
}

# ----- intake-poll.sh source-isolation fixture -----------------------------------------------
# intake-poll.sh (see intake-poll.sh:114-124) always derives REPO_ROOT from its own on-disk
# location's git toplevel, and unconditionally sources lib/intake-config.sh (which would otherwise
# source the REAL tracker/project/ai adapters and, via tracker_load_env, make a live Jira call) —
# so a test can't just source the repo's real intake-poll.sh in place. Instead: copy it into a
# throwaway git repo under BATS_TEST_TMPDIR (isolates REPO_ROOT/STATE_DIR from the real repo's
# .intake/ state), pre-set _INTAKE_CONFIG_LOADED=1 so the real adapter-loading block is skipped
# entirely, and define every tracker_*/ai_* contract function as an in-shell fake BEFORE sourcing.
#
# A real git repo (not just a directory) is required because dispatch_planning itself shells out to
# `git -C "$REPO_ROOT" worktree add ... main` for the ephemeral planning worktree — that's real
# repo mechanics this suite deliberately exercises, not something to fake.
#
# load_ai_provider (intake-poll.sh) re-sources lib/ai/<provider>.sh fresh on every dispatch, so the
# fake AI adapter must be a real file on disk (a plain function pre-defined before sourcing would
# just get overwritten the first time a dispatch resolves a provider) — see lib/ai/fake.sh below.
poller_fixture_init() {
    POLLER_REPO="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$POLLER_REPO"
    git init -q "$POLLER_REPO"
    git -C "$POLLER_REPO" checkout -q -b main 2>/dev/null || git -C "$POLLER_REPO" symbolic-ref HEAD refs/heads/main
    git -C "$POLLER_REPO" -c user.email=test@test.local -c user.name=test commit -q --allow-empty -m init

    cp "$REPO_ROOT/intake-poll.sh" "$POLLER_REPO/intake-poll.sh"
    mkdir -p "$POLLER_REPO/lib/ai"
    cp "$TEST_HELPERS_DIR/fake-ai-adapter.sh" "$POLLER_REPO/lib/ai/fake.sh"
    # Not sourced (guarded by _INTAKE_CONFIG_LOADED=1 below) — just needs to exist, since `.` fails
    # outright on a missing file regardless of what a guard inside it would have done.
    cp "$REPO_ROOT/lib/intake-config.sh" "$POLLER_REPO/lib/intake-config.sh"

    CALL_LOG="$BATS_TEST_TMPDIR/calls.log"
    : > "$CALL_LOG"
    export CALL_LOG

    export _INTAKE_CONFIG_LOADED=1
    export TRACKER_PROJECT_KEY=PROJ
    export PLAN_WORKTREE_PREFIX=.intake-plan-
    export AI_PROVIDER=fake
    export AI_PLANNING_MODEL=""
    export AI_IMPLEMENTATION_MODEL=""
    export JIRA_AI_COMMENT_FOOTER='----
fake AI footer'
    export JIRA_INTAKE_EMAIL="test@test.local"

    # Default fakes — override individual ones in a test AFTER `poller_source`, bash resolves the
    # most-recently-defined function at call time.
    tracker_load_env() { return 0; }
    tracker_search() { :; }
    tracker_get_issue() { cat "$(fixture_json ticket-clean)"; }
    tracker_add_comment() { printf 'tracker_add_comment %s\n' "$*" >> "$CALL_LOG"; return 0; }
    tracker_transition() { printf 'tracker_transition %s\n' "$*" >> "$CALL_LOG"; return 0; }
    tracker_abstract_state() { printf 'ready-for-planning'; }
    tracker_ticket_regex() { printf 'PROJ-[0-9]+'; }
}

# poller_source — sources the isolated intake-poll.sh copy. Call after poller_fixture_init and
# after overriding any of the default fakes above.
poller_source() {
    # shellcheck source=/dev/null
    source "$POLLER_REPO/intake-poll.sh"
}

# call_count FUNC_NAME — how many times FUNC_NAME appears in $CALL_LOG.
call_count() {
    grep -c "^$1 " "$CALL_LOG" 2>/dev/null || true
}
