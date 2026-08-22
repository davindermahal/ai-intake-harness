#!/usr/bin/env bats
load '../helpers/load'

setup() {
    poller_fixture_init
    poller_source
}

@test "spec_provider: plain provider, no model" {
    run spec_provider "claude"
    assert_success
    assert_output "claude"
}

@test "spec_provider: provider:model splits on first colon" {
    run spec_provider "claude:opus"
    assert_success
    assert_output "claude"
}

@test "spec_provider: leading colon (empty provider) yields empty string" {
    run spec_provider ":opus"
    assert_success
    assert_output ""
}

@test "spec_provider: empty spec yields empty string" {
    run spec_provider ""
    assert_success
    assert_output ""
}

@test "spec_model: plain provider has no model" {
    run spec_model "claude"
    assert_success
    assert_output ""
}

@test "spec_model: provider:model yields the model" {
    run spec_model "claude:opus"
    assert_success
    assert_output "opus"
}

@test "spec_model: model ids containing ':' keep everything after the FIRST colon" {
    run spec_model "claude:vendor:special-tag"
    assert_success
    assert_output "vendor:special-tag"
}

@test "spec_model: leading colon yields the part after it" {
    run spec_model ":opus"
    assert_success
    assert_output "opus"
}

@test "spec_model: empty spec yields empty string" {
    run spec_model ""
    assert_success
    assert_output ""
}

@test "attempts_file: pure path construction" {
    run attempts_file "PROJ-7"
    assert_success
    assert_output "$STATE_DIR/attempts/PROJ-7"
}

@test "dispatch_marker: pure path construction for a given phase" {
    run dispatch_marker "PROJ-7" "planning"
    assert_success
    assert_output "$STATE_DIR/attempts/PROJ-7.planning-dispatch-escalated"
}

@test "dispatch_marker: differs per phase for the same key" {
    local planning implementation
    planning="$(dispatch_marker "PROJ-7" "planning")"
    implementation="$(dispatch_marker "PROJ-7" "implementation")"
    [ "$planning" != "$implementation" ]
}
