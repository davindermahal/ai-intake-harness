#!/bin/bash
# Set up a new git worktree ready to work from immediately.
# Creates the branch, writes .env.local, clones the main DB, starts Docker, installs deps.
#
# This is the "clone main DB, no auto-launch" path. For a fresh-seeded DB plus an
# auto-opened terminal running Claude, use ai-intake-harness/worktree-go.sh (make worktree-go).
#
# Usage: bash ai-intake-harness/worktree-new.sh <branch-name> [port]
set -e

BRANCH="$1"
PORT_ARG="$2"

if [ -z "$BRANCH" ]; then
    echo "Usage: $0 <branch-name> [port]"
    exit 1
fi

REPO_ROOT="$(pwd)"
# shellcheck source=ai-intake-harness/lib/worktree-common.sh
. "$(dirname "$0")/lib/worktree-common.sh"
# shellcheck source=ai-intake-harness/lib/intake-config.sh
. "$(dirname "$0")/lib/intake-config.sh" "$REPO_ROOT"

USER_ID=$(id -u)
GROUP_ID=$(id -g)

# Credentials (extracted without sourcing — values may contain bash-unsafe chars)
POSTGRES_PASSWORD=$(wt_env_get "${REPO_ROOT}/.env" POSTGRES_PASSWORD)
POSTGRES_USER=$(wt_env_get "${REPO_ROOT}/.env" POSTGRES_USER)
SOURCE_DB=$(wt_env_get "${REPO_ROOT}/.env" POSTGRES_DB)

# Derive SLUG / DB_NAME / PROJECT_NAME / APP_CONTAINER / TICKET / WORKTREE_DIR
project_derive_names "$BRANCH" "$REPO_ROOT"

# Ports — only meaningful for a project that has a container publishing them (wt_free_port shells
# out to `docker ps` to avoid a collision, so skip it entirely for a no-container project).
PORT=""
XDEBUG_PORT=""
if [ -n "$APP_CONTAINER" ]; then
    if [ -n "$PORT_ARG" ]; then
        PORT="$PORT_ARG"
    else
        PORT=$(wt_free_port 8082)
    fi
    XDEBUG_PORT=$(wt_free_port 9004)
fi

echo "Branch:    ${BRANCH}"
echo "Directory: ${WORKTREE_DIR}"
echo "Port:      ${PORT:-(none)}"
echo "Xdebug:    ${XDEBUG_PORT:-(none)}"
echo "Database:  ${DB_NAME:-(none)} (cloned from ${SOURCE_DB})"
echo "Container: ${APP_CONTAINER:-(none)}"
echo ""

if [ -d "${WORKTREE_DIR}" ]; then
    echo "Error: ${WORKTREE_DIR} already exists."
    exit 1
fi

# 1. git worktree
echo "==> Creating git worktree..."
wt_create_worktree "$BRANCH" "$WORKTREE_DIR"

# 2-6b. env files + database + container — entirely opt-in (APP_CONTAINER=="" opts out, see
# lib/worktree-common.sh's header comment). Same gate as worktree-go.sh — no .env/.env.local copy
# either (there may be no repo-root .env at all for a no-container project).
export USER_ID GROUP_ID APP_CONTAINER APP_PORT="$PORT" XDEBUG_PORT POSTGRES_DB="$DB_NAME"
if [ -n "$APP_CONTAINER" ]; then
    echo "==> Writing .env / .env.local..."
    wt_write_env "$REPO_ROOT" "$WORKTREE_DIR" "$PORT" "$XDEBUG_PORT" "$DB_NAME"

    echo "==> Cloning database ${SOURCE_DB} → ${DB_NAME}..."
    wt_create_empty_db "$DB_NAME" "$POSTGRES_USER" "$POSTGRES_PASSWORD" "$SOURCE_DB"
    wt_clone_db "$SOURCE_DB" "$DB_NAME" "$POSTGRES_USER" "$POSTGRES_PASSWORD"
    echo "Database ready."

    wt_precreate_dirs "$WORKTREE_DIR"

    echo "==> Starting app container..."
    COMPOSER_HOME="$(composer config --global home 2>/dev/null || echo "${HOME}/.composer")"
    export COMPOSER_HOME
    wt_start_container "$REPO_ROOT" "$WORKTREE_DIR" "$PROJECT_NAME"

    echo "==> Waiting for ${APP_CONTAINER}..."
    wt_wait_container "$APP_CONTAINER"

    echo "==> Verifying container database..."
    wt_verify_container_db "$APP_CONTAINER" "$USER_ID" "$GROUP_ID" "$DB_NAME" || exit 1
else
    echo "==> No container for this project (APP_CONTAINER empty) — skipping database/container provisioning."
fi

# 7. deps + migrations
echo "==> Installing dependencies..."
project_install_deps "$APP_CONTAINER" "$USER_ID" "$GROUP_ID" "$WORKTREE_DIR"
echo "==> Running migrations..."
project_migrate "$APP_CONTAINER" "$USER_ID" "$GROUP_ID"

echo ""
echo "================================================================"
echo "  Worktree ready: ${BRANCH}"
if [ -n "$APP_CONTAINER" ]; then
    BS_PORT=$((PORT + 1000))
    echo "  App:            http://localhost:${PORT}"
    echo "  BrowserSync:    http://localhost:${BS_PORT}  (auto-reload)"
    echo "  Xdebug port:    ${XDEBUG_PORT}"
fi
echo "  Database:       ${DB_NAME:-(none)}"
echo "  Container:      ${APP_CONTAINER:-(none)}"
echo ""
echo "  Next:"
echo "    cd ${WORKTREE_DIR}"
if [ -n "$APP_CONTAINER" ]; then
    echo "    make watch   # webpack + BrowserSync on :${BS_PORT}"
fi
echo "================================================================"
