#!/usr/bin/env bats
load '../helpers/load'

setup() {
    poller_fixture_init
    poller_source
}

@test "slugify: lowercases and hyphenates" {
    run slugify "Add Retry Logic To Webhook"
    assert_success
    assert_output "add-retry-logic-to-webhook"
}

@test "slugify: strips punctuation runs to single hyphens" {
    run slugify "Fix: the \$500 bug!! (urgent)"
    assert_success
    assert_output "fix-the-500-bug-urgent"
}

@test "slugify: strips leading/trailing punctuation" {
    run slugify "--- already hyphenated ---"
    assert_success
    assert_output "already-hyphenated"
}

@test "slugify: truncates to 50 chars and re-trims a trailing hyphen" {
    local long="This is a very long ticket summary that goes on and on and on"
    run slugify "$long"
    assert_success
    [ "${#output}" -le 50 ]
    case "$output" in *-) fail "trailing hyphen after truncation: $output" ;; esac
}

@test "slugify: empty string yields empty slug" {
    run slugify ""
    assert_success
    assert_output ""
}

@test "slugify: all-punctuation summary yields empty slug (resolve_branch falls back to 'ticket')" {
    run slugify "!!! ??? ---"
    assert_success
    assert_output ""
}

@test "slugify: unicode input survives lowercasing (sed's [^a-z0-9] is locale-aware, not ascii-only)" {
    run slugify "Café résumé fix"
    assert_success
    assert_output "café-résumé-fix"
}

@test "resolve_branch: falls back to 'ticket' suffix when the summary slugifies to empty" {
    run resolve_branch "PROJ-9" "!!!"
    assert_success
    assert_output "feature/PROJ-9-ticket"
}

@test "resolve_branch: reuses an existing feature/<KEY>-* branch instead of re-slugifying" {
    git -C "$POLLER_REPO" branch "feature/PROJ-9-old-slug" >/dev/null
    run resolve_branch "PROJ-9" "A brand new summary"
    assert_success
    assert_output "feature/PROJ-9-old-slug"
}
