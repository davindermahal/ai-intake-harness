#!/usr/bin/env bats
load '../helpers/load'

# Stubs psql/docker/pg_dump/pg_restore on PATH, logging each invocation's argv (plus psql's -c/-v
# args) to $STUB_LOG instead of executing anything real. Layer 4a — lib/worktree-common.sh has no
# unconditional top-level code, so it's directly sourceable with no main-guard needed.

setup() {
    STUB_BIN="$BATS_TEST_TMPDIR/stubbin"
    STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
    mkdir -p "$STUB_BIN"
    : > "$STUB_LOG"

    # One argv per line (plus a "---" call separator) — not "$*" joined into one string — so a
    # test can assert exactly which TOKEN a value landed in (proving a malicious db name stayed
    # confined to its own -v argument and never got spliced into a -c SQL string).
    cat > "$STUB_BIN/psql" <<'EOF'
#!/bin/bash
for a in "$@"; do printf '%s\n' "$a" >> "$STUB_LOG"; done
printf -- '---\n' >> "$STUB_LOG"
exit "${STUB_PSQL_RC:-0}"
EOF
    cat > "$STUB_BIN/docker" <<'EOF'
#!/bin/bash
printf 'docker %s\n' "$*" >> "$STUB_LOG"
if [ "$1" = "ps" ]; then printf '%s\n' "${STUB_DOCKER_PS_OUTPUT:-}"; fi
exit 0
EOF
    chmod +x "$STUB_BIN/psql" "$STUB_BIN/docker"
    export STUB_LOG PATH="$STUB_BIN:$PATH"

    export PROJECT_DB_PREFIX="myapp"
    source "$REPO_ROOT/lib/worktree-common.sh"
}

# ----- wt_create_empty_db (regression: bug #4 guards, bug #8 SQL injection) --------------------

@test "wt_create_empty_db: refuses a db name that doesn't match \${PROJECT_DB_PREFIX}_*" {
    run wt_create_empty_db "other_db" "u" "p" "myapp_main"
    assert_failure
    assert_output --partial "refusing to create"
    [ ! -s "$STUB_LOG" ]   # psql never invoked
}

@test "wt_create_empty_db: refuses when db == source_db" {
    run wt_create_empty_db "myapp_main" "u" "p" "myapp_main"
    assert_failure
    assert_output --partial "refusing to create"
    [ ! -s "$STUB_LOG" ]
}

# c_arg_after FLAG — the argv token immediately following the last occurrence of FLAG in the log.
c_arg_after() { awk -v f="$1" '$0==f{found=1; next} found{print; exit}' "$STUB_LOG"; }

@test "wt_create_empty_db: a legal call passes the db name through -v db=, not string interpolation" {
    run wt_create_empty_db "myapp_feature1" "u" "p" "myapp_main"
    assert_success
    [ "$(c_arg_after "-v")" = "db=myapp_feature1" ]
    [ "$(c_arg_after "-c")" = 'DROP DATABASE IF EXISTS :"db"' ]   # first -c token
    grep -qxF 'CREATE DATABASE :"db"' "$STUB_LOG"                  # second -c token — the -v value never leaks into either
}

@test "wt_create_empty_db: a db name containing a quote is passed through inert, not broken out of the SQL (regression: bug #8)" {
    local evil='myapp_x'"'"';DROP TABLE users;--'
    run wt_create_empty_db "$evil" "u" "p" "myapp_main"
    assert_success
    # The -v value carries the raw payload as ONE opaque argv token (proof it's inert)...
    [ "$(c_arg_after "-v")" = "db=$evil" ]
    # ...while both -c SQL tokens are still the fixed literal :"db" strings, untouched.
    grep -qxF 'DROP DATABASE IF EXISTS :"db"' "$STUB_LOG"
    grep -qxF 'CREATE DATABASE :"db"' "$STUB_LOG"
    ! grep -qxF "DROP TABLE users" "$STUB_LOG"   # never its own standalone argv token
}

# ----- wt_drop_db (same two guards, plus ordering) ----------------------------------------------

@test "wt_drop_db: refuses a db name that doesn't match \${PROJECT_DB_PREFIX}_*" {
    run wt_drop_db "other_db" "u" "p" "myapp_main"
    assert_failure
    assert_output --partial "refusing to drop"
    [ ! -s "$STUB_LOG" ]
}

@test "wt_drop_db: refuses when db == source_db" {
    run wt_drop_db "myapp_main" "u" "p" "myapp_main"
    assert_failure
    assert_output --partial "refusing to drop"
    [ ! -s "$STUB_LOG" ]
}

@test "wt_drop_db: returns 1 (not found) when the existence check finds nothing, without attempting the drop" {
    # wt_drop_db's existence probe uses `psql -tAc` and expects "1" on stdout for an existing db;
    # our stub prints nothing, so it reports "does not exist" and returns before the terminate/drop.
    run wt_drop_db "myapp_feature1" "u" "p" "myapp_main"
    assert_failure
    [ "$(c_arg_after "-v")" = "db=myapp_feature1" ]
    ! grep -q "DROP DATABASE" "$STUB_LOG"
}

@test "wt_drop_db: terminates backends before dropping, in the same invocation" {
    cat > "$STUB_BIN/psql" <<'EOF'
#!/bin/bash
for a in "$@"; do printf '%s\n' "$a" >> "$STUB_LOG"; done
printf -- '---\n' >> "$STUB_LOG"
case "$*" in *-tAc*) echo 1 ;; esac
exit 0
EOF
    chmod +x "$STUB_BIN/psql"
    run wt_drop_db "myapp_feature1" "u" "p" "myapp_main"
    assert_success
    # Two psql invocations happen (existence probe, then terminate+drop) — scope the ordering check
    # to the LAST one (the last "-v" flag onward) so the probe's own -tAc call can't confuse it.
    local v_line term_line drop_line
    v_line="$(grep -n '^-v$' "$STUB_LOG" | tail -1 | cut -d: -f1)"
    term_line="$(awk -v s="$v_line" 'NR>s && /pg_terminate_backend/{print NR; exit}' "$STUB_LOG")"
    drop_line="$(awk -v s="$v_line" 'NR>s && /^DROP DATABASE/{print NR; exit}' "$STUB_LOG")"
    [ -n "$term_line" ] && [ -n "$drop_line" ] && [ "$term_line" -lt "$drop_line" ]
}

# ----- wt_free_port --------------------------------------------------------------------------

@test "wt_free_port: returns the requested port when nothing is published on it" {
    export STUB_DOCKER_PS_OUTPUT=""
    run wt_free_port 8082
    assert_success
    assert_output "8082"
}

@test "wt_free_port: skips past ports already published, returns the first truly-free one" {
    export STUB_DOCKER_PS_OUTPUT="0.0.0.0:8082->80/tcp
0.0.0.0:8083->80/tcp"
    run wt_free_port 8082
    assert_success
    assert_output "8084"
}
