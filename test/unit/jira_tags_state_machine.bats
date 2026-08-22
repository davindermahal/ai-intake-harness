#!/usr/bin/env bats
load '../helpers/load'

# jira_tags_legal_move is a pure state-transition table (lib/tracker/jira-tags.sh:99) — enumerate
# every (from, to) pair over the full abstract-state vocabulary and assert legal/illegal
# exhaustively. This is also where the human-approval-gate boundary lives for TRACKER=jira-tags: a
# dedicated test below asserts `ready-for-implementation` is never a legal TARGET of either this
# table or jira.sh's own transition map, turning the bug audit's manual verification into a
# permanent regression guard.

setup() {
    export TRACKER_PROJECT_KEY="PROJ"
    source "$REPO_ROOT/lib/tracker/jira-tags.sh"
}

# The exact edge set documented in jira_tags_legal_move's case statement.
LEGAL_MOVES=(
    "ready-for-planning:needs-author-input"
    "ready-for-planning:plan-review"
    "needs-author-input:ready-for-planning"
    "plan-review:ready-for-implementation"
    "ready-for-implementation:in-progress"
    "in-progress:ready-for-verification"
    "in-progress:ready-for-implementation"
    "ready-for-verification:ready-for-implementation"
    "ready-for-verification:done"
)

ALL_STATES=(ready-for-planning needs-author-input plan-review ready-for-implementation in-progress ready-for-verification done)

@test "jira_tags_legal_move: every documented legal move succeeds" {
    for move in "${LEGAL_MOVES[@]}"; do
        run jira_tags_legal_move "${move%%:*}" "${move##*:}"
        [ "$status" -eq 0 ] || fail "expected $move to be legal, got status $status"
    done
}

@test "jira_tags_legal_move: exhaustively rejects every (from,to) pair not on the documented list" {
    local from to move known
    for from in "${ALL_STATES[@]}"; do
        for to in "${ALL_STATES[@]}"; do
            move="$from:$to"
            known=0
            for legal in "${LEGAL_MOVES[@]}"; do
                [ "$legal" = "$move" ] && known=1 && break
            done
            if [ "$known" -eq 0 ]; then
                run jira_tags_legal_move "$from" "$to"
                [ "$status" -ne 0 ] || fail "expected $move to be illegal, but jira_tags_legal_move accepted it"
            fi
        done
    done
}

@test "jira_tags_legal_move: same-state no-op moves are illegal" {
    local s
    for s in "${ALL_STATES[@]}"; do
        run jira_tags_legal_move "$s" "$s"
        [ "$status" -ne 0 ] || fail "expected $s:$s (no-op) to be illegal"
    done
}

@test "jira-tags.sh: tracker_transition never accepts ready-for-implementation as an abstract state (human approval gate)" {
    # jira_tags_legal_move DOES allow plan-review/ready-for-verification -> ready-for-implementation
    # as edges (a human's own approval action) — the real boundary is that the AUTOMATION's entry
    # point, tracker_transition, has no case for it at all, so no poller code path can ever drive
    # that specific move itself.
    run tracker_transition "PROJ-1" ready-for-implementation
    assert_failure
    assert_output --partial "unknown abstract state"
}

@test "jira.sh: tracker_transition also never accepts ready-for-implementation as an abstract state" {
    source "$REPO_ROOT/lib/tracker/jira.sh"
    run tracker_transition "PROJ-1" ready-for-implementation
    assert_failure
    assert_output --partial "unknown abstract state"
}
