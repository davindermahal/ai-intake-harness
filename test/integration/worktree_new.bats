#!/usr/bin/env bats
load '../helpers/load'

# Layer 4b (worktree-new.sh only — see the plan's Decisions section on why worktree-go.sh/
# worktree-new.sh get black-box-only coverage, no functional decomposition in this plan). Runs the
# REAL worktree-new.sh as a subprocess against a throwaway git repo, with every external binary
# (docker/psql/pg_dump/pg_restore/composer) stubbed on PATH and a fixture project adapter — asserts
# on exit code, stdout, and the resulting .env.local.

setup() {
    CONSUMER="$BATS_TEST_TMPDIR/consumer"
    mkdir -p "$CONSUMER"
    git init -q "$CONSUMER"
    git -C "$CONSUMER" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    git -C "$CONSUMER" branch -q -m main 2>/dev/null || true

    cat > "$CONSUMER/.env" <<'EOF'
POSTGRES_USER=appuser
POSTGRES_PASSWORD=secret
POSTGRES_DB=myapp_main
EOF

    mkdir -p "$CONSUMER/.ai" "$CONSUMER/scripts/lib/project"
    cat > "$CONSUMER/.ai/intake.config" <<'EOF'
TRACKER=jira
TRACKER_PROJECT_KEY=PROJ
PROJECT_ADAPTER=fake-stack
AI_PROVIDER=claude
EOF

    STUB_LOG="$BATS_TEST_TMPDIR/calls.log"
    : > "$STUB_LOG"
    cat > "$CONSUMER/scripts/lib/project/fake-stack.sh" <<'PROJEOF'
project_derive_names() {
    local branch="$1" repo_root="$2"
    SLUG="$(printf '%s' "$branch" | tr '[:upper:]/' '[:lower:]-')"
    DB_SUFFIX="$SLUG"
    DB_NAME="myapp_${DB_SUFFIX}"
    PROJECT_NAME="myapp_${SLUG}"
    APP_CONTAINER="myapp_${SLUG}_app"
    TICKET="$(printf '%s' "$branch" | grep -oE 'PROJ-[0-9]+' | head -1)"
    WORKTREE_DIR="$(dirname "$repo_root")/wt-${SLUG}"
}
project_install_deps() { echo "project_install_deps $*" >> "$STUB_LOG"; }
project_provision_fresh() { echo "project_provision_fresh $*" >> "$STUB_LOG"; }
project_migrate() { echo "project_migrate $*" >> "$STUB_LOG"; }
project_build() { echo "project_build $*" >> "$STUB_LOG"; }
project_test() { echo "project_test $*" >> "$STUB_LOG"; }
project_verify() { echo "project_verify $*" >> "$STUB_LOG"; }
project_permission_profile() { echo "project_permission_profile $*" >> "$STUB_LOG"; }
PROJEOF
    export STUB_LOG

    STUB_BIN="$BATS_TEST_TMPDIR/stubbin"
    mkdir -p "$STUB_BIN"
    for bin in psql pg_dump pg_restore composer; do
        cat > "$STUB_BIN/$bin" <<EOF
#!/bin/bash
printf '$bin %s\n' "\$*" >> "$STUB_LOG"
exit 0
EOF
        chmod +x "$STUB_BIN/$bin"
    done
    # docker needs one special case: wt_verify_container_db execs `printenv POSTGRES_DB` inside
    # the (nonexistent, stubbed) container and aborts on a mismatch — echo back
    # $EXPECTED_POSTGRES_DB (each test sets it to match the branch's derived DB_NAME) so that guard
    # passes without a real container.
    cat > "$STUB_BIN/docker" <<EOF
#!/bin/bash
printf 'docker %s\n' "\$*" >> "$STUB_LOG"
case "\$*" in *"printenv POSTGRES_DB"*) printf '%s' "\${EXPECTED_POSTGRES_DB:-}" ;; esac
exit 0
EOF
    chmod +x "$STUB_BIN/docker"
    export PATH="$STUB_BIN:$PATH"
}

# slug_of BRANCH — mirrors the fixture project adapter's own derivation, so a test can predict
# DB_NAME/WORKTREE_DIR and prime EXPECTED_POSTGRES_DB for the docker stub above.
slug_of() { printf '%s' "$1" | tr '[:upper:]/' '[:lower:]-'; }

@test "worktree-new.sh: happy path creates the worktree, writes .env.local, and reports success" {
    local branch="feature/PROJ-9-test-branch" slug; slug="$(slug_of "$branch")"
    export EXPECTED_POSTGRES_DB="myapp_${slug}"
    (cd "$CONSUMER" && bash "$REPO_ROOT/worktree-new.sh" "$branch" 8090) > "$BATS_TEST_TMPDIR/out.log" 2>&1
    local rc=$?
    local wtdir="$BATS_TEST_TMPDIR/wt-${slug}"
    [ "$rc" -eq 0 ]
    [ -d "$wtdir" ]
    [ -f "$wtdir/.env.local" ]
    grep -q "^APP_PORT=8090$" "$wtdir/.env.local"
    grep -q "^POSTGRES_DB=myapp_${slug}$" "$wtdir/.env.local"
    grep -q "Worktree ready" "$BATS_TEST_TMPDIR/out.log"
}

@test "worktree-new.sh: refuses to run when the target worktree dir already exists" {
    local wtdir="$BATS_TEST_TMPDIR/wt-feature-proj-9-dup"
    mkdir -p "$wtdir"
    run bash -c "cd '$CONSUMER' && bash '$REPO_ROOT/worktree-new.sh' 'feature/PROJ-9-dup' 8090"
    assert_failure
    assert_output --partial "already exists"
}

@test "worktree-new.sh: clones the source database via wt_create_empty_db + pg_dump|pg_restore" {
    local branch="feature/PROJ-9-clonedb" slug; slug="$(slug_of "$branch")"
    export EXPECTED_POSTGRES_DB="myapp_${slug}"
    (cd "$CONSUMER" && bash "$REPO_ROOT/worktree-new.sh" "$branch" 8091) > /dev/null 2>&1
    grep -q "psql .*-v db=myapp_${slug}" "$STUB_LOG"
    grep -q "^pg_dump " "$STUB_LOG"
    grep -q "^pg_restore " "$STUB_LOG"
}

@test "worktree-new.sh: runs project_install_deps then project_migrate (SEED=clone path, no fixtures)" {
    local branch="feature/PROJ-9-deps" slug; slug="$(slug_of "$branch")"
    export EXPECTED_POSTGRES_DB="myapp_${slug}"
    (cd "$CONSUMER" && bash "$REPO_ROOT/worktree-new.sh" "$branch" 8092) > /dev/null 2>&1
    grep -q "^project_install_deps " "$STUB_LOG"
    grep -q "^project_migrate " "$STUB_LOG"
    ! grep -q "^project_provision_fresh " "$STUB_LOG"   # worktree-new.sh never seeds fresh fixtures
}
