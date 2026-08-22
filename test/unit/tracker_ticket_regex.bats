#!/usr/bin/env bats
load '../helpers/load'

# tracker_ticket_regex is pure (no network) in both Jira-flavored adapters — source them directly.
# jira-common.sh (sourced by both) only defines functions at the top level, no side effects.

setup() {
    export TRACKER_PROJECT_KEY="PROJ"
}

@test "jira.sh: tracker_ticket_regex matches a real ticket key" {
    source "$REPO_ROOT/lib/tracker/jira.sh"
    local regex; regex="$(tracker_ticket_regex)"
    [[ "PROJ-123" =~ ^${regex}$ ]]
}

@test "jira.sh: tracker_ticket_regex rejects lowercase" {
    source "$REPO_ROOT/lib/tracker/jira.sh"
    local regex; regex="$(tracker_ticket_regex)"
    ! [[ "proj-123" =~ ^${regex}$ ]]
}

@test "jira.sh: tracker_ticket_regex rejects a key with no hyphen" {
    source "$REPO_ROOT/lib/tracker/jira.sh"
    local regex; regex="$(tracker_ticket_regex)"
    ! [[ "PROJ123" =~ ^${regex}$ ]]
}

@test "jira.sh: tracker_ticket_regex rejects trailing garbage" {
    source "$REPO_ROOT/lib/tracker/jira.sh"
    local regex; regex="$(tracker_ticket_regex)"
    ! [[ "PROJ-123x" =~ ^${regex}$ ]]
}

@test "jira-tags.sh: tracker_ticket_regex matches a real ticket key" {
    source "$REPO_ROOT/lib/tracker/jira-tags.sh"
    local regex; regex="$(tracker_ticket_regex)"
    [[ "PROJ-456" =~ ^${regex}$ ]]
}

@test "jira-tags.sh: tracker_ticket_regex rejects lowercase" {
    source "$REPO_ROOT/lib/tracker/jira-tags.sh"
    local regex; regex="$(tracker_ticket_regex)"
    ! [[ "proj-456" =~ ^${regex}$ ]]
}

@test "jira-tags.sh: tracker_ticket_regex rejects a key with no hyphen" {
    source "$REPO_ROOT/lib/tracker/jira-tags.sh"
    local regex; regex="$(tracker_ticket_regex)"
    ! [[ "PROJ456" =~ ^${regex}$ ]]
}
