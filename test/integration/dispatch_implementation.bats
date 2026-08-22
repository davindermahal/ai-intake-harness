#!/usr/bin/env bats
load '../helpers/load'

setup() {
    poller_fixture_init
    poller_source
    # dispatch_implementation needs an existing feature/<KEY>-* branch (planning already ran).
    git -C "$POLLER_REPO" branch "feature/PROJ-1-add-retry-logic" >/dev/null
}

@test "dispatch_implementation: no feature branch — escalates once and never marks in-flight" {
    git -C "$POLLER_REPO" branch -D "feature/PROJ-1-add-retry-logic" >/dev/null
    run dispatch_implementation "PROJ-1"
    assert_output --partial "no committed plan to implement"
    [ "$(call_count tracker_add_comment)" -eq 1 ]
    [ ! -f "$INFLIGHT_DIR/PROJ-1" ]

    run dispatch_implementation "PROJ-1"
    [ "$(call_count tracker_add_comment)" -eq 1 ]   # not re-posted
}

@test "dispatch_implementation: a live worker already running for this key is never re-dispatched (regression: bug #2)" {
    mkdir -p "$RUNNING_DIR"
    echo $$ > "$RUNNING_DIR/PROJ-1.pid"   # this test process's own PID — guaranteed alive
    run dispatch_implementation "PROJ-1"
    assert_output --partial "already running for PROJ-1"
    [ "$(call_count ai_run_implementation)" -eq 0 ]
}

@test "dispatch_implementation: launch succeeds, tracker_transition fails — one escalation comment, marker untouched, running slot untouched" {
    tracker_transition() { printf 'tracker_transition %s\n' "$*" >> "$CALL_LOG"; return 1; }
    # launch_implementation_worker shells out to `make worktree-go` — faked via a stub make on
    # PATH so this test only exercises dispatch_implementation's own bookkeeping.
    local stub_bin="$BATS_TEST_TMPDIR/stubbin"
    mkdir -p "$stub_bin"
    # Unquoted heredoc: $RUNNING_DIR expands NOW, to a literal path baked into the stub — the real
    # `make` this replaces runs as a separate process and wouldn't inherit intake-poll.sh's
    # (unexported) shell variables otherwise.
    cat > "$stub_bin/make" <<EOF
#!/bin/bash
mkdir -p "$RUNNING_DIR"
echo \$\$ > "$RUNNING_DIR/PROJ-1.pid"
exit 0
EOF
    chmod +x "$stub_bin/make"
    PATH="$stub_bin:$PATH" run dispatch_implementation "PROJ-1"
    assert_success
    [ "$(call_count tracker_add_comment)" -eq 2 ]   # launch notice + the transition-failure escalation
    grep -q "follow-up status transition to \*In Progress\* failed" "$CALL_LOG"
    [ -f "$INFLIGHT_DIR/PROJ-1" ]                    # left alone, not stale-reclaimable immediately
    [ -f "$RUNNING_DIR/PROJ-1.pid" ]                 # running-slot PID file untouched
}

@test "dispatch_implementation: worktree-go launch failure escalates once and clears in-flight for retry" {
    local stub_bin="$BATS_TEST_TMPDIR/stubbin"
    mkdir -p "$stub_bin"
    cat > "$stub_bin/make" <<'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "$stub_bin/make"
    PATH="$stub_bin:$PATH" run dispatch_implementation "PROJ-1"
    assert_output --partial "worktree-go FAILED"
    [ "$(call_count tracker_add_comment)" -eq 1 ]
    [ ! -f "$INFLIGHT_DIR/PROJ-1" ]

    PATH="$stub_bin:$PATH" run dispatch_implementation "PROJ-1"
    [ "$(call_count tracker_add_comment)" -eq 1 ]   # not re-posted for the same failing config
}

@test "dispatch_implementation: DRY_RUN never launches, never marks in-flight" {
    export DRY_RUN=1
    run dispatch_implementation "PROJ-1"
    assert_output --partial "[dry-run] would run"
    [ "$(call_count ai_run_implementation)" -eq 0 ]
    [ ! -f "$INFLIGHT_DIR/PROJ-1" ]
}
