#!/usr/bin/env bats
load '../helpers/load'

# Layer 2: turns install.sh's own --verify function-existence check into a reusable assertion
# pattern, and mocks the Jira I/O boundary. See fakes.bash's header comment on the jira_api /
# jira_search_jql seam split: jira_search_jql builds its own curl call, so tracker_search tests
# fake it directly rather than relying on a jira_api override.

TRACKER_CONTRACT_FNS="tracker_load_env tracker_search tracker_get_issue tracker_add_comment tracker_transition tracker_ticket_regex tracker_abstract_state"
AI_CONTRACT_FNS="ai_load_env ai_run_planning ai_run_implementation"

assert_contract_defined() {
    local fn
    for fn in "$@"; do
        declare -f "$fn" >/dev/null || fail "contract function '$fn' is not defined"
    done
}

@test "jira.sh defines the full tracker_* contract" {
    export TRACKER_PROJECT_KEY=PROJ
    source "$REPO_ROOT/lib/tracker/jira.sh"
    assert_contract_defined $TRACKER_CONTRACT_FNS
}

@test "jira-tags.sh defines the full tracker_* contract" {
    export TRACKER_PROJECT_KEY=PROJ TRACKER_APP_TAG=app:test
    source "$REPO_ROOT/lib/tracker/jira-tags.sh"
    assert_contract_defined $TRACKER_CONTRACT_FNS
}

@test "every lib/ai/*.sh adapter defines the full ai_* contract" {
    local f name
    for f in "$REPO_ROOT"/lib/ai/*.sh; do
        name="$(basename "$f" .sh)"
        run bash -c "source '$f' && declare -f ai_load_env ai_run_planning ai_run_implementation >/dev/null"
        [ "$status" -eq 0 ] || fail "lib/ai/$name.sh is missing one or more of: $AI_CONTRACT_FNS"
    done
}

# ----- jira_api / jira_search_jql mocking -------------------------------------------------

@test "jira.sh: tracker_get_issue returns the fake jira_api's canned fixture" {
    export TRACKER_PROJECT_KEY=PROJ
    source "$REPO_ROOT/lib/tracker/jira.sh"
    jira_api() { cat "$(fixture_json ticket-clean)"; }
    run tracker_get_issue "PROJ-1"
    assert_success
    run bash -c "echo '$output' | jq -r '.fields.summary'"
    assert_output "Add retry logic to the payment webhook"
}

@test "jira.sh: tracker_abstract_state maps every real jira.sh status name to the correct abstract state" {
    export TRACKER_PROJECT_KEY=PROJ
    source "$REPO_ROOT/lib/tracker/jira.sh"
    local ctx="$BATS_TEST_TMPDIR/ctx.json"
    declare -A expect=(
        ["Ready for Planning"]=ready-for-planning
        ["Needs Author Input"]=needs-author-input
        ["Plan Review"]=plan-review
        ["Ready for Implementation"]=ready-for-implementation
        ["In Progress"]=in-progress
        ["Ready for Verification"]=ready-for-verification
        ["Done"]=done
        ["Backlog"]=""
    )
    local native_status
    for native_status in "${!expect[@]}"; do
        jq -n --arg s "$native_status" '{fields:{status:{name:$s}}}' > "$ctx"
        run tracker_abstract_state "$ctx"
        assert_success
        assert_output "${expect[$native_status]}"
    done
}

@test "jira_search_jql: pages via nextPageToken and returns keys from every page (regression: bug #6)" {
    export TRACKER_PROJECT_KEY=PROJ JIRA_SITE_URL=https://fake.example
    source "$REPO_ROOT/lib/tracker/jira.sh"
    local calls_log="$BATS_TEST_TMPDIR/curl_calls.log"
    : > "$calls_log"
    # jira_search_jql calls the `curl` BINARY directly (not through jira_api) — a same-shell
    # function override intercepts it fine, since bash resolves a function before PATH lookup.
    curl() {
        printf '%s\n' "$*" >> "$calls_log"
        if [[ "$*" == *"nextPageToken=tok123"* ]]; then
            printf '{"issues":[{"key":"PROJ-3"}],"nextPageToken":""}'
        else
            printf '{"issues":[{"key":"PROJ-1"},{"key":"PROJ-2"}],"nextPageToken":"tok123"}'
        fi
    }
    run jira_search_jql "project = PROJ"
    assert_success
    assert_line "PROJ-1"
    assert_line "PROJ-2"
    assert_line "PROJ-3"
    [ "$(wc -l < "$calls_log")" -eq 2 ]
    grep -q "nextPageToken=tok123" "$calls_log"
}

@test "jira-tags.sh: tracker_search scopes JQL to the app tag and assignee=currentUser()" {
    export TRACKER_PROJECT_KEY=PROJ TRACKER_APP_TAG="app:my-app"
    source "$REPO_ROOT/lib/tracker/jira-tags.sh"
    local captured=""
    jira_search_jql() { captured="$1"; }
    tracker_search implementation
    [[ "$captured" == *'labels = "app:my-app"'* ]]
    [[ "$captured" == *'labels = "state:ready-for-implementation"'* ]]
    [[ "$captured" == *'assignee = currentUser()'* ]]
}
