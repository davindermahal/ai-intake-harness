#!/bin/bash
# Shared helpers for worktree provisioning scripts (worktree-new.sh, worktree-go.sh,
# worktree-remove.sh). Source this file; do not execute it directly.
#
#   . "$(dirname "$0")/lib/worktree-common.sh"
#
# Functions are prefixed wt_ and operate via explicit arguments. This file holds only GENERIC
# orchestration (git worktree lifecycle, port allocation, env files, container start/stop,
# database create/clone/drop, terminal launch) — nothing stack-specific. Name derivation,
# dependency install, schema/fixture provisioning, asset build, tests, and smoke-verify are the
# `project_*` contract, implemented per target project in scripts/lib/project/<adapter>.sh
# (e.g., symfony-docker.sh for a Symfony project). Callers source both this file and the configured project adapter.

# Guard against double-sourcing
[ -n "${_WORKTREE_COMMON_LOADED:-}" ] && return 0
_WORKTREE_COMMON_LOADED=1

# Read a KEY=value from a .env-style file without sourcing it (values may contain
# bash-unsafe characters). Usage: wt_env_get <file> <KEY>
wt_env_get() {
    grep -E "^${2}=" "$1" | head -1 | cut -d'=' -f2-
}

# Echo the first free host port at or after $1 (skips ports already published by
# a running container). Usage: port=$(wt_free_port 8082)
wt_free_port() {
    local port="$1"
    while docker ps --format '{{.Ports}}' | grep -q ":${port}->"; do
        port=$((port + 1))
    done
    printf '%s' "$port"
}

# Create the git worktree: check out an existing branch, or create a new one from HEAD.
# Usage: wt_create_worktree <branch> <worktree-dir>
wt_create_worktree() {
    local branch="$1" dir="$2"
    if git show-ref --verify --quiet "refs/heads/${branch}"; then
        git worktree add "$dir" "$branch"
    else
        git worktree add -b "$branch" "$dir"
    fi
}

# Copy .env into the worktree (a symlink won't work — Docker can't follow symlinks
# pointing outside the bind-mounted dir) and write per-worktree .env.local overrides.
# Usage: wt_write_env <repo-root> <worktree-dir> <app-port> <xdebug-port> <db-name>
wt_write_env() {
    local repo_root="$1" dir="$2" port="$3" xdebug="$4" db="$5"
    cp "${repo_root}/.env" "${dir}/.env"
    cat > "${dir}/.env.local" <<EOF
APP_PORT=${port}
XDEBUG_PORT=${xdebug}
POSTGRES_DB=${db}
EOF
}

# Pre-create bind-mounted dirs as the current user so Docker doesn't create them as root.
# Usage: wt_precreate_dirs <worktree-dir>
wt_precreate_dirs() {
    mkdir -p "$1/vendor" "$1/var"
}

# Drop and (re)create an empty database via host psql, with the same guards wt_drop_db has so we
# can never drop the source DB: refuses unless <db> matches ${PROJECT_DB_PREFIX}_* AND differs
# from <source-db>. Identifiers are passed through psql's -v :"name" substitution (not string-
# interpolated) so a <db-name> containing a quote can't break out of the SQL.
# Usage: wt_create_empty_db <db-name> <pg-user> <pg-password> <source-db>
wt_create_empty_db() {
    local db="$1" user="$2" pass="$3" source_db="$4"
    local prefix="${PROJECT_DB_PREFIX:-myapp}"
    case "$db" in
        "${prefix}"_*) ;;
        *) echo "   refusing to create '${db}' — not a '${prefix}_*' worktree database" >&2; return 1 ;;
    esac
    if [ "$db" = "$source_db" ]; then
        echo "   refusing to create '${db}' — it is the source database" >&2; return 1
    fi
    PGPASSWORD="$pass" psql -h localhost -U "$user" -d postgres -v db="$db" \
        -c 'DROP DATABASE IF EXISTS :"db"' \
        -c 'CREATE DATABASE :"db"' > /dev/null
}

# Clone a source database into a target via pg_dump | pg_restore (host side).
# The target must already exist (use wt_create_empty_db first).
# Usage: wt_clone_db <source-db> <target-db> <pg-user> <pg-password>
wt_clone_db() {
    local src="$1" dst="$2" user="$3" pass="$4"
    PGPASSWORD="$pass" pg_dump -h localhost -U "$user" -d "$src" -F c \
        | PGPASSWORD="$pass" pg_restore -h localhost -U "$user" -d "$dst" --no-owner 2>/dev/null
    return 0
}

# Start the worktree's app container using the MAIN worktree's compose files
# (always current) but resolving relative volume paths from the worktree dir.
# Usage: wt_start_container <repo-root> <worktree-dir> <project-name>
wt_start_container() {
    local repo_root="$1" dir="$2" project="$3"
    docker compose \
        --env-file "${repo_root}/.env" \
        --env-file "${dir}/.env.local" \
        -f "${repo_root}/compose.yaml" \
        -f "${repo_root}/compose.override.yaml" \
        --project-directory "${dir}" \
        -p "${project}" \
        up -d
}

# Wait up to 30s for the container to accept exec. Usage: wt_wait_container <container>
wt_wait_container() {
    local container="$1" i
    for i in $(seq 1 30); do
        docker exec "$container" true 2>/dev/null && return 0
        sleep 1
    done
    echo "Warning: ${container} may not be fully ready, continuing anyway..."
    return 0
}

# Verify the container's baked-in POSTGRES_DB actually matches this worktree's own database
# name. compose.yaml interpolates POSTGRES_DB/DATABASE_URL from the shell/--env-file at
# container-creation time, and an already-exported shell POSTGRES_DB silently outranks any
# --env-file value (see .ai/docs/worktree-docker.md) — so the container can come up wired to a
# DIFFERENT database than the one this worktree created, most dangerously the shared main
# database. Call this before any migrate/fixture-load step; a mismatch aborts instead of letting
# that step purge whichever database the container actually points at.
# Usage: wt_verify_container_db <container> <uid> <gid> <expected-db>
wt_verify_container_db() {
    local container="$1" uid="$2" gid="$3" expected="$4" actual
    actual=$(docker exec -u "${uid}:${gid}" "$container" printenv POSTGRES_DB 2>/dev/null)
    if [ "$actual" != "$expected" ]; then
        {
            echo ""
            echo "!! ABORT: ${container} is wired to the wrong database — refusing to migrate/seed it."
            echo "!!   Expected POSTGRES_DB: ${expected}"
            echo "!!   Container's actual:  ${actual:-<empty/unreadable>}"
            echo "!!"
            echo "!!   Most likely cause: a shell-exported POSTGRES_DB (e.g. leaked from the main"
            echo "!!   worktree's 'make' invocation) beat the --env-file value when the container was"
            echo "!!   created — Compose lets an already-exported shell variable win over --env-file,"
            echo "!!   regardless of file order. See .ai/docs/worktree-docker.md."
            echo "!!"
            echo "!!   Fix: from inside this worktree's directory, run 'make down && make up' to"
            echo "!!   recreate the container with the correct env resolution, then re-run this."
            echo ""
        } >&2
        return 1
    fi
    return 0
}

# Fix ownership of the bind-mounted var/ dir (Docker may create it root-owned on first run).
# Usage: wt_fix_var_perms <container>
wt_fix_var_perms() {
    docker exec -u root "$1" chown -R hostuser:hostgroup /var/www/app/var 2>/dev/null || true
    return 0
}

# Remove a worktree's app container and its per-worktree compose network. Robust even when the
# worktree directory is already gone (so we don't depend on `docker compose down` finding its
# project dir): force-remove the container by name, then drop the "<project>_default" network.
# Network removal is always attempted and non-fatal either way. Returns 0 if a container matching
# <container> was found (and removal was attempted), 1 if none was found — callers use this to
# report an accurate outcome instead of assuming success. Usage: wt_remove_container <container> <project>
wt_remove_container() {
    local container="$1" project="$2"
    if docker ps -a --format '{{.Names}}' | grep -qx "$container"; then
        docker rm -f "$container" > /dev/null 2>&1 || true
        docker network rm "${project}_default" > /dev/null 2>&1 || true
        return 0
    fi
    docker network rm "${project}_default" > /dev/null 2>&1 || true
    return 1
}

# Drop a per-worktree database via host psql, with guards so we can never drop the source DB.
# Refuses unless <db> matches ${PROJECT_DB_PREFIX}_* AND differs from <source-db>. Terminates any
# open connections first, then drops it. Returns 0 if <db> existed and was dropped, 1 if it did
# not exist (or a guard refused) — callers use this to report an accurate outcome instead of
# assuming success. Identifiers/values are passed through psql's -v :"name"/:'name' substitution
# (not string-interpolated) so a <db-name> containing a quote can't break out of the SQL.
# Usage: wt_drop_db <db> <user> <pass> <source-db>
wt_drop_db() {
    local db="$1" user="$2" pass="$3" source_db="$4"
    local prefix="${PROJECT_DB_PREFIX:-myapp}"
    case "$db" in
        "${prefix}"_*) ;;
        *) echo "   refusing to drop '${db}' — not a '${prefix}_*' worktree database" >&2; return 1 ;;
    esac
    if [ "$db" = "$source_db" ]; then
        echo "   refusing to drop '${db}' — it is the source database" >&2; return 1
    fi
    local exists
    exists=$(PGPASSWORD="$pass" psql -h localhost -U "$user" -d postgres -tAc -v db="$db" \
        "SELECT 1 FROM pg_database WHERE datname = :'db'" 2>/dev/null)
    [ "$exists" = "1" ] || return 1
    PGPASSWORD="$pass" psql -h localhost -U "$user" -d postgres -v db="$db" \
        -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = :'db' AND pid <> pg_backend_pid()" \
        -c 'DROP DATABASE IF EXISTS :"db"' > /dev/null 2>&1
    return 0
}

# Open a new terminal window in <workdir> running <cmd>, leaving a shell open after.
# Tries gnome-terminal, konsole, x-terminal-emulator, xterm in that order.
# Returns non-zero if no terminal emulator is found. Usage: wt_open_terminal <workdir> <cmd>
wt_open_terminal() {
    local workdir="$1" cmd="$2"
    if command -v gnome-terminal >/dev/null 2>&1; then
        gnome-terminal --working-directory="$workdir" -- bash -lc "${cmd}; exec bash" >/dev/null 2>&1 &
    elif command -v konsole >/dev/null 2>&1; then
        konsole --workdir "$workdir" -e bash -lc "${cmd}; exec bash" >/dev/null 2>&1 &
    elif command -v x-terminal-emulator >/dev/null 2>&1; then
        x-terminal-emulator -e bash -lc "cd '${workdir}' && ${cmd}; exec bash" >/dev/null 2>&1 &
    elif command -v xterm >/dev/null 2>&1; then
        xterm -e bash -lc "cd '${workdir}' && ${cmd}; exec bash" >/dev/null 2>&1 &
    else
        return 1
    fi
    return 0
}
