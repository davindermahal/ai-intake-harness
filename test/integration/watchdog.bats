#!/usr/bin/env bats
load '../helpers/load'

setup() {
    poller_fixture_init
    poller_source
    export JIRA_WATCHDOG_GRACE_SECONDS=1   # tests use "past grace" launched timestamps well beyond this
}

past() { date -d "-$1 seconds" +%s; }   # an epoch $1 seconds in the past

@test "watchdog_check: no attempts record — not harness-dispatched, ignored entirely (case D)" {
    run watchdog_check "PROJ-1"
    assert_output --partial "not harness-dispatched, ignoring"
    [ "$(call_count tracker_add_comment)" -eq 0 ]
}

@test "watchdog_check: within the grace period — skipped even with a dead PID" {
    export JIRA_WATCHDOG_GRACE_SECONDS=900
    attempts_reset "PROJ-1"
    run watchdog_check "PROJ-1"
    assert_output --partial "within grace period"
    [ "$(call_count tracker_add_comment)" -eq 0 ]
}

@test "watchdog_check: worker PID alive — healthy, skip" {
    attempts_reset "PROJ-1"
    printf 'attempts=1\nlaunched=%s\n' "$(past 1000)" > "$(attempts_file PROJ-1)"
    mkdir -p "$RUNNING_DIR"
    echo $$ > "$RUNNING_DIR/PROJ-1.pid"   # this test process — guaranteed alive
    run watchdog_check "PROJ-1"
    assert_output --partial "alive — healthy, skip"
    [ "$(call_count tracker_add_comment)" -eq 0 ]
}

@test "watchdog_check: dead PID, no AI-footer comment (case A) — restarts via launch_implementation_worker" {
    printf 'attempts=1\nlaunched=%s\n' "$(past 1000)" > "$(attempts_file PROJ-1)"
    git -C "$POLLER_REPO" branch "feature/PROJ-1-x" >/dev/null
    tracker_get_issue() { cat "$(fixture_json ticket-clean)"; }   # no comments -> no AI footer
    local stub_bin="$BATS_TEST_TMPDIR/stubbin"; mkdir -p "$stub_bin"
    cat > "$stub_bin/make" <<EOF
#!/bin/bash
mkdir -p "$RUNNING_DIR"
echo \$\$ > "$RUNNING_DIR/PROJ-1.pid"
exit 0
EOF
    chmod +x "$stub_bin/make"
    PATH="$stub_bin:$PATH" run watchdog_check "PROJ-1"
    assert_success
    read -r attempts _ < <(attempts_get "PROJ-1")
    [ "$attempts" -eq 2 ]
    grep -q "relaunching the stalled implementation worker" "$CALL_LOG"
}

@test "watchdog_check: dead PID, an AI-footer comment posted after launch (case C) — escalates, does not restart" {
    printf 'attempts=1\nlaunched=%s\n' "$(past 100000)" > "$(attempts_file PROJ-1)"
    export JIRA_AI_COMMENT_FOOTER='----
🤖 _Posted by Claude (JIRA intake automation)_'
    # Comment `created` timestamp built relative to "now" (well after `launched`, -100000s ago) —
    # NOT the static fixtures/jira/ticket-with-ai-comment.json, whose baked-in date is only "after
    # launch" by coincidence on the day it was written and silently goes stale (and this test with
    # it) as real time passes past that fixed date.
    local case_c_fixture="$BATS_TEST_TMPDIR/case-c.json"
    jq --arg fp "$JIRA_AI_COMMENT_FOOTER" --arg created "$(date -u -d '-100 seconds' '+%Y-%m-%dT%H:%M:%S.000+0000')" \
        -n '{fields:{comment:{comments:[{created:$created, body:("resolved locally\n\n" + $fp)}]}}}' > "$case_c_fixture"
    tracker_get_issue() { cat "$case_c_fixture"; }
    run watchdog_check "PROJ-1"
    assert_success
    assert_output --partial "case C"
    attempts_escalated "PROJ-1"
    grep -q "already reported back" "$CALL_LOG"
}

@test "watchdog_check: unparseable comment timestamp is treated as unknown, not silently as case A (regression: bug #9)" {
    printf 'attempts=1\nlaunched=%s\n' "$(past 100000)" > "$(attempts_file PROJ-1)"
    export JIRA_AI_COMMENT_FOOTER='----
🤖 _Posted by Claude (JIRA intake automation)_'
    # NOTE: named bad_ts_fixture, not "ctx" — watchdog_stalled_comment_after has its own `local
    # ctx=...` of the same name, which would otherwise shadow this one for the duration of its
    # call to the tracker_get_issue fake below (bash locals are visible down the call stack).
    local bad_ts_fixture="$BATS_TEST_TMPDIR/bad-ts.json"
    jq --arg fp2 "$JIRA_AI_COMMENT_FOOTER" -n \
        '{fields:{comment:{comments:[{created:"not-a-date", body:("garbage\n\n" + $fp2)}]}}}' > "$bad_ts_fixture"
    tracker_get_issue() { cat "$bad_ts_fixture"; }
    git -C "$POLLER_REPO" branch "feature/PROJ-1-x" >/dev/null
    local stub_bin="$BATS_TEST_TMPDIR/stubbin"; mkdir -p "$stub_bin"
    cat > "$stub_bin/make" <<EOF
#!/bin/bash
mkdir -p "$RUNNING_DIR"
echo \$\$ > "$RUNNING_DIR/PROJ-1.pid"
exit 0
EOF
    chmod +x "$stub_bin/make"
    PATH="$stub_bin:$PATH" run watchdog_check "PROJ-1"
    assert_output --partial "couldn't parse comment timestamp"
    assert_output --partial "treating as unknown, not as case A"
    # An unparseable timestamp must not silently satisfy case A's restart path with a phantom
    # "after launch" comment — it's neither confirmed unstalled-and-alive nor confirmed
    # case-C-reported, so this run still restarts (the safe default), but only after warning loudly.
}

@test "watchdog_check: attempts exhausted — escalates once, does not restart" {
    printf 'attempts=%s\nlaunched=%s\n' "$JIRA_MAX_ATTEMPTS" "$(past 100000)" > "$(attempts_file PROJ-1)"
    tracker_get_issue() { cat "$(fixture_json ticket-clean)"; }
    run watchdog_check "PROJ-1"
    assert_output --partial "attempts exhausted"
    attempts_escalated "PROJ-1"
    [ "$(call_count ai_run_implementation)" -eq 0 ]
}

@test "watchdog_check: already escalated — skipped on a later poll (no repeat comment)" {
    printf 'attempts=1\nlaunched=%s\n' "$(past 100000)" > "$(attempts_file PROJ-1)"
    attempts_mark_escalated "PROJ-1"
    run watchdog_check "PROJ-1"
    assert_output --partial "already escalated"
    [ "$(call_count tracker_add_comment)" -eq 0 ]
}

@test "watchdog_check: no feature branch to restart from — escalates" {
    printf 'attempts=1\nlaunched=%s\n' "$(past 100000)" > "$(attempts_file PROJ-1)"
    tracker_get_issue() { cat "$(fixture_json ticket-clean)"; }
    run watchdog_check "PROJ-1"
    assert_output --partial "no feature/PROJ-1-* branch found"
    grep -q "no feature branch could be found" "$CALL_LOG"
}

@test "watchdog_check: at JIRA_MAX_WORKTREES capacity — defers restart to a later poll" {
    printf 'attempts=1\nlaunched=%s\n' "$(past 100000)" > "$(attempts_file PROJ-1)"
    tracker_get_issue() { cat "$(fixture_json ticket-clean)"; }
    git -C "$POLLER_REPO" branch "feature/PROJ-1-x" >/dev/null
    mkdir -p "$RUNNING_DIR"
    export JIRA_MAX_WORKTREES=1
    echo 999999 > "$RUNNING_DIR/OTHER-1.pid"   # a dead PID still counts until reaped...
    # running_count reaps dead slots first, so use a genuinely-alive PID to hold the slot.
    echo $$ > "$RUNNING_DIR/OTHER-1.pid"
    run watchdog_check "PROJ-1"
    assert_output --partial "at capacity"
    [ "$(call_count ai_run_implementation)" -eq 0 ]
}

# ----- process_watchdog / process_queue --------------------------------------------------------

@test "process_watchdog: sweeps every in-progress ticket returned by tracker_search" {
    tracker_search() { [ "$1" = "in-progress" ] && printf 'PROJ-1\nPROJ-2\n'; }
    run process_watchdog
    assert_output --partial "watchdog: 2 ticket(s) checked"
}

@test "process_queue: stops dispatching once JIRA_MAX_WORKTREES workers are already running, without aborting the poll" {
    export JIRA_MAX_WORKTREES=1
    mkdir -p "$RUNNING_DIR"
    echo $$ > "$RUNNING_DIR/OTHER-1.pid"
    tracker_search() { [ "$1" = "implementation" ] && printf 'PROJ-1\nPROJ-2\n'; }
    handled=""
    dispatch_implementation() { handled="$handled $1"; }
    run process_queue "implementation" implementation dispatch_implementation 1
    assert_success
    assert_output --partial "at capacity"
    assert_output --partial "implementation: 0 ticket(s) dispatched"
    [ -z "$handled" ]
}

@test "process_queue: an in-flight ticket is skipped, not re-dispatched" {
    inflight_mark "PROJ-1"
    tracker_search() { [ "$1" = "planning" ] && printf 'PROJ-1\n'; }
    dispatch_planning() { echo "SHOULD NOT BE CALLED" >&2; }
    run process_queue "planning" planning dispatch_planning
    assert_output --partial "skip PROJ-1 (in-flight)"
    refute_output --partial "SHOULD NOT BE CALLED"
}

# ----- in-flight staleness ----------------------------------------------------------------------

@test "inflight_active: a fresh marker blocks re-pickup" {
    inflight_mark "PROJ-1"
    run inflight_active "PROJ-1"
    assert_success
}

@test "inflight_active: a marker older than INFLIGHT_STALE_SECONDS is reclaimed as free" {
    export INFLIGHT_STALE_SECONDS=1
    inflight_mark "PROJ-1"
    touch -d "-10 seconds" "$INFLIGHT_DIR/PROJ-1"
    run inflight_active "PROJ-1"
    assert_failure
    [ ! -f "$INFLIGHT_DIR/PROJ-1" ]
}

# ----- reap_consume_implementation_result --------------------------------------------------------

@test "reap_consume_implementation_result: outcome=success transitions to ready-for-verification and clears the escalation marker" {
    git -C "$POLLER_REPO" branch "feature/PROJ-1-x" >/dev/null
    local wtdir; wtdir="$(worktree_dir_for_branch "feature/PROJ-1-x")"
    mkdir -p "$wtdir/.ai"
    echo '{"outcome":"success"}' > "$wtdir/.ai/impl-result.json"
    touch "$(dispatch_marker PROJ-1 implementation-transition)"
    run reap_consume_implementation_result "PROJ-1"
    assert_output --partial "deterministic post-implementation transition to ready-for-verification"
    grep -q "tracker_transition PROJ-1 ready-for-verification" "$CALL_LOG"
    [ ! -f "$(dispatch_marker PROJ-1 implementation-transition)" ]
    [ ! -f "$wtdir/.ai/impl-result.json" ]
}

@test "reap_consume_implementation_result: missing result file leaves the ticket for the watchdog (no transition attempted)" {
    git -C "$POLLER_REPO" branch "feature/PROJ-1-x" >/dev/null
    run reap_consume_implementation_result "PROJ-1"
    assert_output --partial "leaving for watchdog"
    [ "$(call_count tracker_transition)" -eq 0 ]
}

@test "reap_consume_implementation_result: outcome=blocked leaves the ticket for the watchdog (no transition attempted)" {
    git -C "$POLLER_REPO" branch "feature/PROJ-1-x" >/dev/null
    local wtdir; wtdir="$(worktree_dir_for_branch "feature/PROJ-1-x")"
    mkdir -p "$wtdir/.ai"
    echo '{"outcome":"blocked"}' > "$wtdir/.ai/impl-result.json"
    run reap_consume_implementation_result "PROJ-1"
    assert_output --partial "leaving for watchdog"
    [ "$(call_count tracker_transition)" -eq 0 ]
}
