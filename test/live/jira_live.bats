#!/usr/bin/env bats
load '../helpers/load'

# Layer 6 — opt-in smoke tests against REAL Jira / a real local LM Studio instance, using this
# repo's own .env.local / .ai/intake.config. Deliberately NOT part of `make test` / test/unit
# /test/integration (no fixtures, no mocking) — gated behind RUN_LIVE_TESTS=1 and run via
# `make test-live`, as a manual/scheduled check rather than a merge gate. See the plan's Layer 6.

setup() {
    if [ "${RUN_LIVE_TESTS:-0}" != "1" ]; then
        skip "RUN_LIVE_TESTS=1 not set — run via 'make test-live'"
    fi
}

@test "install.sh --test-only: reaches Jira with this repo's real .env.local credentials" {
    run bash "$REPO_ROOT/install.sh" --test-only "$REPO_ROOT"
    assert_success
}

@test "install.sh --verify: the live Jira status-mapping check passes against the real configured project" {
    run bash "$REPO_ROOT/install.sh" --verify "$REPO_ROOT"
    refute_output --partial "Skipping the Jira status-mapping check"
}

@test "install.sh --test-cookie: the browser-cookie auth fallback works, if configured" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "no python3 on PATH — cookie auth fallback isn't set up on this host"
    fi
    run bash "$REPO_ROOT/install.sh" --test-cookie "$REPO_ROOT"
    assert_success
}

@test "local-llm-spike.sh: a local LM Studio instance is reachable and diagnostics pass" {
    run bash "$REPO_ROOT/local-llm-spike.sh"
    assert_success
}
