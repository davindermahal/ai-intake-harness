#!/usr/bin/env bats
load '../helpers/load'

# Layer 5: install.sh --verify/--fix, run as a real subprocess (not sourced — see the plan's
# rationale) against a throwaway "consumer repo" fixture. No fixture ever carries real Jira
# credentials, so the tracker category's live status-mapping check fails fast on the missing
# JIRA_SITE_URL and degrades to a [WARN] "Jira isn't reachable yet" rather than attempting any
# network call — see jira_common_load_env's `${JIRA_SITE_URL:?...}` guard.

CONTRACT_FNS="project_derive_names project_install_deps project_provision_fresh project_migrate project_build project_test project_verify project_permission_profile"

# make_fixture_repo DIR — a minimal consumer-repo fixture with every project_* contract function
# defined as a one-line stub. Callers remove functions from $DIR/scripts/lib/project/fake-stack.sh
# to test the [MISSING] path.
make_fixture_repo() {
    local dir="$1"
    mkdir -p "$dir/.ai" "$dir/scripts/lib/project"
    cat > "$dir/.ai/intake.config" <<'EOF'
TRACKER=jira
TRACKER_PROJECT_KEY=PROJ
PROJECT_ADAPTER=fake-stack
AI_PROVIDER=claude
EOF
    {
        local fn
        for fn in $CONTRACT_FNS; do
            printf '%s() { :; }\n' "$fn"
        done
    } > "$dir/scripts/lib/project/fake-stack.sh"
}

@test "install.sh --verify: reports [MISSING] for a fixture adapter missing project_migrate (regression: doc/#3 fix)" {
    local dir="$BATS_TEST_TMPDIR/consumer"
    make_fixture_repo "$dir"
    sed -i '/^project_migrate/d' "$dir/scripts/lib/project/fake-stack.sh"

    run bash "$REPO_ROOT/install.sh" --verify "$dir"
    assert_failure   # non-zero exit — issues found
    assert_output --partial "[MISSING]"
    assert_output --partial "project_migrate"
}

@test "install.sh --verify: a complete fixture adapter reports every contract function present" {
    local dir="$BATS_TEST_TMPDIR/consumer"
    make_fixture_repo "$dir"

    run bash "$REPO_ROOT/install.sh" --verify "$dir"
    assert_output --partial "defines every required contract function"
    refute_output --partial "is missing:"
}

@test "install.sh --verify: no .ai/intake.config at all is reported [MISSING] and skips the dependent checks" {
    local dir="$BATS_TEST_TMPDIR/consumer"
    mkdir -p "$dir"
    run bash "$REPO_ROOT/install.sh" --verify "$dir"
    assert_failure
    assert_output --partial "[MISSING]"
    assert_output --partial "No .ai/intake.config"
    assert_output --partial "skipping the remaining checks"
}

@test "install.sh --verify --fix: scaffolds the missing scripts/intake-cron.sh (net-new file)" {
    local dir="$BATS_TEST_TMPDIR/consumer"
    make_fixture_repo "$dir"
    [ ! -f "$dir/scripts/intake-cron.sh" ]

    # --fix only ever resolves a SUBSET of findings (gemini profile, cron wrapper) — remaining
    # findings (no .env.local, no permission profile, no crontab entry) are still reported and the
    # exit code is still their count, so this run legitimately exits non-zero even on success.
    run bash "$REPO_ROOT/install.sh" --verify --fix "$dir"
    [ -f "$dir/scripts/intake-cron.sh" ]
    assert_output --partial "Created $dir/scripts/intake-cron.sh from template"
    assert_output --partial "[OK]      $dir/scripts/intake-cron.sh exists and points at $dir."
}

@test "install.sh --verify --fix: never touches an existing file's mtime or content (net-new only)" {
    local dir="$BATS_TEST_TMPDIR/consumer"
    make_fixture_repo "$dir"
    local before_content before_mtime
    before_content="$(cat "$dir/.ai/intake.config")"
    before_mtime="$(stat -c %Y "$dir/.ai/intake.config")"
    sleep 1

    run bash "$REPO_ROOT/install.sh" --verify --fix "$dir"

    [ "$(cat "$dir/.ai/intake.config")" = "$before_content" ]
    [ "$(stat -c %Y "$dir/.ai/intake.config")" = "$before_mtime" ]
}

@test "install.sh --verify: the Jira live status-mapping check degrades to a [WARN] instead of hitting the network (no fixture ever carries real credentials)" {
    local dir="$BATS_TEST_TMPDIR/consumer"
    make_fixture_repo "$dir"

    run bash "$REPO_ROOT/install.sh" --verify "$dir"
    assert_output --partial "Skipping the Jira status-mapping check"
    assert_output --partial "isn't reachable yet"
}
