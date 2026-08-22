#!/usr/bin/env bats
load '../helpers/load'

# Layer 4b (worktree-go.sh, HEADLESS=1 path only — the path intake-poll.sh's
# dispatch_implementation actually drives in production; the interactive/CLAUDE=1/TERMINAL=1 path
# opens a real terminal window and isn't meaningfully testable headlessly, so it's out of scope
# here — see the plan's Decisions on worktree-go.sh/worktree-new.sh being black-box-only).
#
# Exercises the REAL lib/ai/local-llm.sh adapter's env-check (no fake AI adapter needed): with no
# LM Studio listening on AI_LOCAL_LLM_BASE_URL, ai_load_env fails fast and deterministically, which
# is exactly the "AI provider not ready" guard this test protects — worktree-go.sh must abort
# cleanly before ever writing a running-slot PID file.

setup() {
    CONSUMER="$BATS_TEST_TMPDIR/consumer"
    mkdir -p "$CONSUMER"
    git init -q "$CONSUMER"
    git -C "$CONSUMER" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

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
AI_LOCAL_LLM_BASE_URL=http://127.0.0.1:1
EOF
    cat > "$CONSUMER/scripts/lib/project/fake-stack.sh" <<'PROJEOF'
project_derive_names() {
    local branch="$1" repo_root="$2"
    SLUG="$(printf '%s' "$branch" | tr '[:upper:]/' '[:lower:]-')"
    DB_SUFFIX="$SLUG"; DB_NAME="myapp_${DB_SUFFIX}"; PROJECT_NAME="myapp_${SLUG}"
    APP_CONTAINER="myapp_${SLUG}_app"
    TICKET="$(printf '%s' "$branch" | grep -oE 'PROJ-[0-9]+' | head -1)"
    WORKTREE_DIR="$(dirname "$repo_root")/wt-${SLUG}"
}
project_install_deps() { :; }
project_provision_fresh() { :; }
project_migrate() { :; }
project_build() { :; }
PROJEOF

    STUB_BIN="$BATS_TEST_TMPDIR/stubbin"
    mkdir -p "$STUB_BIN"
    for bin in psql pg_dump pg_restore composer; do
        cat > "$STUB_BIN/$bin" <<'EOF'
#!/bin/bash
exit 0
EOF
        chmod +x "$STUB_BIN/$bin"
    done
    cat > "$STUB_BIN/docker" <<'EOF'
#!/bin/bash
case "$*" in *"printenv POSTGRES_DB"*) printf '%s' "${EXPECTED_POSTGRES_DB:-}" ;; esac
exit 0
EOF
    chmod +x "$STUB_BIN/docker"
    export PATH="$STUB_BIN:$PATH"
}

@test "worktree-go.sh HEADLESS: an AI provider that fails its env check aborts cleanly with no running-slot PID file" {
    local branch="feature/PROJ-9-headless" slug="feature-proj-9-headless"
    export EXPECTED_POSTGRES_DB="myapp_${slug}"
    run bash -c "cd '$CONSUMER' && HEADLESS=1 PROVIDER=local-llm TERMINAL=0 bash '$REPO_ROOT/worktree-go.sh' '$branch' 8095"
    assert_failure
    assert_output --partial "failed its environment check"
    assert_output --partial "Not launching"
    [ ! -f "$CONSUMER/.intake/running/PROJ-9-headless.pid" ]
}
