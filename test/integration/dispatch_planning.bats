#!/usr/bin/env bats
load '../helpers/load'

setup() {
    poller_fixture_init
    poller_source
}

# Worktree ephemeral dir dispatch_planning uses for PROJ-1: dirname(REPO_ROOT)/<prefix>PROJ-1.
wt_dir() { printf '%s/%s%s' "$(dirname "$POLLER_REPO")" "$PLAN_WORKTREE_PREFIX" "$1"; }

@test "dispatch_planning: ai_run_planning failure does not abort the poll (regression: bug #1 dead-code rc check)" {
    export FAKE_AI_RUN_PLANNING_RC=1
    run dispatch_planning "PROJ-1"
    assert_success   # dispatch_planning itself returns 0 — the caller's poll loop must not abort
    assert_output --partial "AI planning FAILED"
    [ "$(call_count ai_run_planning)" -eq 1 ]
}

@test "dispatch_planning: ai_run_planning failure removes the ephemeral worktree" {
    export FAKE_AI_RUN_PLANNING_RC=1
    dispatch_planning "PROJ-1"
    [ ! -d "$(wt_dir PROJ-1)" ]
}

@test "dispatch_planning: ai_run_planning failure leaves the in-flight marker for stale-reclaim" {
    export FAKE_AI_RUN_PLANNING_RC=1
    dispatch_planning "PROJ-1"
    [ -f "$INFLIGHT_DIR/PROJ-1" ]
}

@test "dispatch_planning: clean decision, tracker_transition fails once — posts one escalation comment (plus the always-posted plan summary)" {
    export FAKE_AI_RUN_PLANNING_DECISION="$(fixture_path fixtures/decisions/)clean.json"
    tracker_transition() { printf 'tracker_transition %s\n' "$*" >> "$CALL_LOG"; return 1; }
    dispatch_planning "PROJ-1"
    [ "$(call_count tracker_add_comment)" -eq 2 ]   # summary comment + one escalation comment
    [ "$(grep -c 'Plan Review\* failed' "$CALL_LOG")" -eq 1 ]
    grep -q "tracker_transition PROJ-1 plan-review" "$CALL_LOG"
}

@test "dispatch_planning: clean decision, tracker_transition fails — in-flight marker is untouched (not cleared)" {
    export FAKE_AI_RUN_PLANNING_DECISION="$(fixture_path fixtures/decisions/)clean.json"
    tracker_transition() { return 1; }
    dispatch_planning "PROJ-1"
    [ -f "$INFLIGHT_DIR/PROJ-1" ]
}

@test "dispatch_planning: clean decision, tracker_transition fails — a second dispatch for the same key/spec does not re-invoke ai_run_planning" {
    export FAKE_AI_RUN_PLANNING_DECISION="$(fixture_path fixtures/decisions/)clean.json"
    tracker_transition() { return 1; }
    dispatch_planning "PROJ-1"
    [ "$(call_count ai_run_planning)" -eq 1 ]

    run dispatch_planning "PROJ-1"
    assert_success
    assert_output --partial "already reported, not re-running"
    [ "$(call_count ai_run_planning)" -eq 1 ]
}

@test "dispatch_planning: escalation clears once tracker_transition succeeds and the AI spec changed (human re-queue path)" {
    export FAKE_AI_RUN_PLANNING_DECISION="$(fixture_path fixtures/decisions/)clean.json"
    tracker_transition() { return 1; }
    dispatch_planning "PROJ-1"
    [ "$(call_count ai_run_planning)" -eq 1 ]

    # Same escalation marker as above blocks a same-spec retry — simulate the documented recovery
    # path (a human changes the ticket's ai-plan-<profile> label) via a ticket fixture carrying a
    # different profile label, which resolves to a different spec and re-arms the dispatch.
    tracker_get_issue() {
        jq '.fields.labels = ["ai-plan-alt"]' "$(fixture_json ticket-clean)"
    }
    export AI_PROFILE_alt="fake:alt-model"   # different resolved spec string than the default "fake"
    tracker_transition() { printf 'tracker_transition %s\n' "$*" >> "$CALL_LOG"; return 0; }

    run dispatch_planning "PROJ-1"
    assert_success
    [ "$(call_count ai_run_planning)" -eq 2 ]
    grep -q "tracker_transition PROJ-1 plan-review" "$CALL_LOG"
    [ ! -f "$INFLIGHT_DIR/PROJ-1" ]   # inflight_clear ran on the successful transition
}

@test "dispatch_planning: questions decision transitions to needs-author-input and clears in-flight" {
    export FAKE_AI_RUN_PLANNING_DECISION="$(fixture_path fixtures/decisions/)questions.json"
    dispatch_planning "PROJ-1"
    grep -q "tracker_transition PROJ-1 needs-author-input" "$CALL_LOG"
    [ ! -f "$INFLIGHT_DIR/PROJ-1" ]
}

@test "dispatch_planning: skip decision clears in-flight without transitioning" {
    export FAKE_AI_RUN_PLANNING_DECISION="$(fixture_path fixtures/decisions/)skip.json"
    run dispatch_planning "PROJ-1"
    assert_output --partial "planning skipped"
    [ "$(call_count tracker_transition)" -eq 0 ]
    [ ! -f "$INFLIGHT_DIR/PROJ-1" ]
}

@test "dispatch_planning: DRY_RUN never dispatches, never marks in-flight" {
    export DRY_RUN=1
    run dispatch_planning "PROJ-1"
    assert_output --partial "[dry-run] would plan"
    [ "$(call_count ai_run_planning)" -eq 0 ]
    [ ! -f "$INFLIGHT_DIR/PROJ-1" ]
}

@test "dispatch_planning: AI provider env-check failure escalates once and never marks in-flight" {
    export FAKE_AI_LOAD_ENV_RC=1
    run dispatch_planning "PROJ-1"
    assert_output --partial "failed its environment check"
    [ "$(call_count tracker_add_comment)" -eq 1 ]
    [ ! -f "$INFLIGHT_DIR/PROJ-1" ]

    # A second call with the same failing provider must not re-comment.
    run dispatch_planning "PROJ-1"
    [ "$(call_count tracker_add_comment)" -eq 1 ]
}

@test "warn_unassigned_pipeline_tickets: logs a warning per ticket when the adapter defines tracker_search_unassigned" {
    tracker_search_unassigned() { printf 'PROJ-9\n'; }
    run warn_unassigned_pipeline_tickets
    assert_success
    assert_output --partial "PROJ-9 is in the pipeline"
    assert_output --partial "unassigned-pipeline check: 1 ticket(s) need an assignee"
}

@test "warn_unassigned_pipeline_tickets: silently a no-op when the adapter (e.g. jira.sh) doesn't define tracker_search_unassigned" {
    unset -f tracker_search_unassigned 2>/dev/null
    run warn_unassigned_pipeline_tickets
    assert_success
    refute_output --partial "unassigned"
}

@test "warn_unassigned_pipeline_tickets: succeeds (does not abort the poll) when zero unassigned tickets are found (regression: bug #11)" {
    # The common case — most polls find nothing unassigned. `[ "$count" -gt 0 ] && log ...` as the
    # function's LAST statement used to return the (failing) test's exit status here, which under
    # `set -e` silently aborted the whole poll before it ever reached `log "poll complete"` — see
    # intake-poll.sh's main block, which calls this as a bare statement.
    tracker_search_unassigned() { :; }
    run warn_unassigned_pipeline_tickets
    assert_success
    refute_output --partial "unassigned-pipeline check"
}
