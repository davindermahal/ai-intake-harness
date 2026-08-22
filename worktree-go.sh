#!/bin/bash
# Spin up a fully-provisioned worktree and launch Claude on it.
#
# From the main worktree, this:
#   1. creates a git worktree for <branch> (sibling dir, slashes flattened to dashes)
#   2. starts a unique app container for it (own port, correct volume mount)
#   3. builds a FRESH database — schema from committed migrations (tests the migration
#      chain), then loads fixtures (seeds the dev admin users + sample data)
#   4. opens a new terminal window cd'd into the worktree
#   5. launches Claude there, pointed at .ai/prompts/worktree-bootstrap.md, which finds
#      the ticket's plan and (if it is marked ready) implements it after one confirmation
#
# Usage: bash ai-intake-harness/worktree-go.sh <branch-name> [port]
#
# Env overrides:
#   SEED=fresh|clone|none   DB seeding mode          (default: fresh)
#   CLAUDE=1|0              launch Claude in the terminal (default: 1)
#   TERMINAL=1|0           open a new terminal window    (default: 1)
#   HEADLESS=1             unattended JIRA-intake mode: no terminal; provision, copy the
#                          ticket's ready plan into the worktree, then launch a DETACHED
#                          headless Claude worker (.ai/prompts/worktree-bootstrap-auto.md)
#                          under .claude/settings.jira-intake.json that implements + builds +
#                          verifies and posts results to the ticket. Implies TERMINAL=0.
#                          (default: 0)
#   RESUME=1               HEADLESS-only: RE-USE an existing worktree instead of erroring on it.
#                          Skips create/seed/provision and just relaunches the headless worker in
#                          place (branch, DB, and committed plan already there). This is what makes
#                          a "Ready for Verification -> Ready for Implementation" bounce re-run: the
#                          poller sets RESUME=1 when the worktree already exists. Under HEADLESS an
#                          existing worktree auto-resumes even without the flag; the interactive
#                          (non-HEADLESS) guard still hard-errors on an existing dir. (default: 0)
#   PROVIDER=claude|codex|antigravity|local-llm|gemini   override AI_PROVIDER for this implementation run only
#   MODEL=...              override AI_IMPLEMENTATION_MODEL (--model) for this run only
#   PROFILE=<name>         resolve an AI_PROFILE_<name>="provider:model" entry from
#                          .ai/intake.config into PROVIDER+MODEL for this run (explicit
#                          PROVIDER=/MODEL= still win over the profile's parts)
set -e

BRANCH="$1"
PORT_ARG="$2"
SEED="${SEED:-fresh}"
CLAUDE="${CLAUDE:-1}"
TERMINAL="${TERMINAL:-1}"
HEADLESS="${HEADLESS:-0}"
RESUME="${RESUME:-0}"
PROVIDER="${PROVIDER:-}"
MODEL="${MODEL:-}"
PROFILE="${PROFILE:-}"
[ "$HEADLESS" = "1" ] && TERMINAL=0

if [ -z "$BRANCH" ]; then
    echo "Usage: $0 <branch-name> [port]"
    exit 1
fi

REPO_ROOT="$(pwd)"

# PROFILE= resolves a named AI_PROFILE_<name>="provider:model" entry from .ai/intake.config into
# the PROVIDER/MODEL overrides (hyphens in the name map to '_' in the variable). Resolved in a
# subshell so none of the config file's other assignments leak into this environment before
# lib/intake-config.sh applies its documented env-over-config precedence.
if [ -n "$PROFILE" ]; then
    _profile_var="AI_PROFILE_${PROFILE//-/_}"
    _profile_spec="$( [ -f "${REPO_ROOT}/.ai/intake.config" ] && . "${REPO_ROOT}/.ai/intake.config" 2>/dev/null; eval "printf '%s' \"\${${_profile_var}:-}\"" )"
    if [ -z "$_profile_spec" ]; then
        echo "Error: unknown AI profile '${PROFILE}' (no ${_profile_var} in .ai/intake.config)"
        exit 1
    fi
    [ -n "$PROVIDER" ] || PROVIDER="${_profile_spec%%:*}"
    case "$_profile_spec" in *:*) [ -n "$MODEL" ] || MODEL="${_profile_spec#*:}" ;; esac
    echo "AI profile: ${PROFILE} -> provider ${PROVIDER}, model ${MODEL:-<provider default>}"
fi

# Map the user-facing PROVIDER=/MODEL= override names onto the AI_* names intake-config.sh reads,
# before it sources them — mirrors SEED/CLAUDE/TERMINAL, which are likewise this script's own
# override names distinct from what they configure.
[ -n "$PROVIDER" ] && export AI_PROVIDER="$PROVIDER"
[ -n "$MODEL" ] && export AI_IMPLEMENTATION_MODEL="$MODEL"
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

# Ports
if [ -n "$PORT_ARG" ]; then
    PORT="$PORT_ARG"
else
    PORT=$(wt_free_port 8082)
fi
XDEBUG_PORT=$(wt_free_port 9004)

echo "Branch:    ${BRANCH}"
echo "Directory: ${WORKTREE_DIR}"
echo "Port:      ${PORT}"
echo "Xdebug:    ${XDEBUG_PORT}"
echo "Database:  ${DB_NAME} (seed mode: ${SEED})"
echo "Container: ${APP_CONTAINER}"
echo "Ticket:    ${TICKET:-<none detected>}"
echo ""

# Existing worktree dir: interactive runs hard-error (as before); headless runs RESUME into it
# (re-run in place for a Ready-for-Verification -> Ready-for-Implementation bounce). The poller
# sets RESUME=1, but under HEADLESS we also auto-detect an existing dir so a re-dispatch never
# aborts on the leftover first-run worktree.
if [ -d "${WORKTREE_DIR}" ]; then
    if [ "$HEADLESS" = "1" ]; then
        RESUME=1
        echo "==> ${WORKTREE_DIR} already exists — RESUME (headless): reusing worktree, container, and DB."
    else
        echo "Error: ${WORKTREE_DIR} already exists."
        exit 1
    fi
fi

if [ "$RESUME" != "1" ]; then
    # 1. git worktree
    echo "==> Creating git worktree..."
    wt_create_worktree "$BRANCH" "$WORKTREE_DIR"

    # 2. env files
    echo "==> Writing .env / .env.local..."
    wt_write_env "$REPO_ROOT" "$WORKTREE_DIR" "$PORT" "$XDEBUG_PORT" "$DB_NAME"

    # 3. database — create empty before the container boots so Symfony can connect
    echo "==> Creating database ${DB_NAME}..."
    wt_create_empty_db "$DB_NAME" "$POSTGRES_USER" "$POSTGRES_PASSWORD" "$SOURCE_DB"
    if [ "$SEED" = "clone" ]; then
        echo "==> Cloning ${SOURCE_DB} → ${DB_NAME}..."
        wt_clone_db "$SOURCE_DB" "$DB_NAME" "$POSTGRES_USER" "$POSTGRES_PASSWORD"
    fi

    # 4. bind-mount dirs
    wt_precreate_dirs "$WORKTREE_DIR"

    # 5. start container (reuses the project image built by the project adapter; mounts this worktree)
    echo "==> Starting app container ${APP_CONTAINER}..."
    export USER_ID GROUP_ID APP_CONTAINER APP_PORT="$PORT" XDEBUG_PORT POSTGRES_DB="$DB_NAME"
    COMPOSER_HOME="$(composer config --global home 2>/dev/null || echo "${HOME}/.composer")"
    export COMPOSER_HOME
    wt_start_container "$REPO_ROOT" "$WORKTREE_DIR" "$PROJECT_NAME"

    # 6. wait
    echo "==> Waiting for ${APP_CONTAINER}..."
    wt_wait_container "$APP_CONTAINER"
    wt_fix_var_perms "$APP_CONTAINER"

    # 6b. guard: abort before touching the DB if the container resolved to the wrong database
    echo "==> Verifying container database..."
    wt_verify_container_db "$APP_CONTAINER" "$USER_ID" "$GROUP_ID" "$DB_NAME" || exit 1

    # 7. PHP + JS deps + bundle assets
    echo "==> Installing dependencies (composer, assets:install, npm)..."
    project_install_deps "$APP_CONTAINER" "$USER_ID" "$GROUP_ID" "$WORKTREE_DIR"

    # 8. schema + seed
    if [ "$SEED" = "fresh" ]; then
        echo "==> Building schema from committed migrations, loading fixtures..."
        project_provision_fresh "$APP_CONTAINER" "$USER_ID" "$GROUP_ID" "$REPO_ROOT" "$DB_NAME" "$POSTGRES_USER" "$POSTGRES_PASSWORD"
    else
        # clone / none: just apply any pending migrations on top
        echo "==> Applying pending migrations..."
        project_migrate "$APP_CONTAINER" "$USER_ID" "$GROUP_ID"
    fi

    # 9. one-time asset build (so the app renders without `make watch`)
    echo "==> Building assets..."
    project_build "$WORKTREE_DIR"
else
    # RESUME: worktree, DB, and committed plan already exist. Skip create/seed/provision; just make
    # sure the app container is running so the worker can build/verify against it. Recover the real
    # port from the worktree's .env.local (the fresh wt_free_port picks above are unused on resume).
    echo "==> RESUME: ensuring container ${APP_CONTAINER} is running..."
    if docker ps -a --format '{{.Names}}' | grep -qx "${APP_CONTAINER}"; then
        docker start "${APP_CONTAINER}" >/dev/null 2>&1 || true
        wt_wait_container "$APP_CONTAINER"
        wt_verify_container_db "$APP_CONTAINER" "$USER_ID" "$GROUP_ID" "$DB_NAME" || exit 1
    else
        echo "   WARNING: container ${APP_CONTAINER} not found — the worker's verify step may fail."
    fi
    if [ -f "${WORKTREE_DIR}/.env.local" ]; then
        PORT="$(wt_env_get "${WORKTREE_DIR}/.env.local" APP_PORT)"
        XDEBUG_PORT="$(wt_env_get "${WORKTREE_DIR}/.env.local" XDEBUG_PORT)"
    fi
fi

# 10. launch — headless (unattended intake) or interactive terminal
LAUNCHED_MSG="not launched (TERMINAL=0)"

if [ "$HEADLESS" = "1" ]; then
    # Unattended implementation worker. The plan is already committed on this branch (the intake
    # poller authored + committed it during planning). The human's move into Ready for
    # Implementation is the approval, so flip the committed plan draft -> ready in the worktree
    # before the worker runs (worktree-bootstrap-auto.md implements a `ready` plan).
    if [ -n "$TICKET" ]; then
        # On a RESUME/bounce re-run a prior SUCCESSFUL run may have archived the plan to
        # completed/. The worker reads active/, so bring it back first.
        for cp in "${WORKTREE_DIR}"/.ai/plans/completed/"${TICKET}"-*.md; do
            [ -f "$cp" ] || continue
            mkdir -p "${WORKTREE_DIR}/.ai/plans/active"
            mv "$cp" "${WORKTREE_DIR}/.ai/plans/active/"
            echo "==> Restored $(basename "$cp") completed/ -> active/ for re-run"
        done
        # The human's move into Ready for Implementation IS the approval, so set the plan's Status
        # to ready regardless of its current value (draft on a first run; active/completed on a
        # bounce). worktree-bootstrap-auto.md only implements a `ready` plan.
        for p in "${WORKTREE_DIR}"/.ai/plans/active/"${TICKET}"-*.md; do
            [ -f "$p" ] || continue
            sed -i -E 's/^(\*\*Status\*\*:).*/\1 ready/' "$p"
            sed -i -E "s/^(\*\*Updated\*\*:).*/\1 $(date +%Y-%m-%d)/" "$p"
            echo "==> Set plan $(basename "$p") Status -> ready in the worktree"
        done
    fi

    LOG_DIR="${REPO_ROOT}/.intake/logs"
    mkdir -p "$LOG_DIR"
    LOGFILE="${LOG_DIR}/${TICKET:-noticket}-impl-$(date +%Y%m%d-%H%M%S).log"
    # Running-slot files let the intake poller cap how many implementation workers run at once
    # (JIRA_MAX_WORKTREES): we record this worker's PID; the poller reaps the slot when it exits.
    RUNNING_DIR="${REPO_ROOT}/.intake/running"
    mkdir -p "$RUNNING_DIR"
    RUNNING_PIDFILE="${RUNNING_DIR}/${TICKET:-noticket}.pid"
    RUNNING_METAFILE="${RUNNING_DIR}/${TICKET:-noticket}.meta"
    echo "==> Launching DETACHED headless implementation worker (AI_PROVIDER=${AI_PROVIDER}); log: ${LOGFILE}"
    ai_load_env || { echo "   ERROR: AI provider '${AI_PROVIDER}' failed its environment check — see messages above. Not launching."; exit 1; }
    # The AI adapter (ai-intake-harness/lib/ai/${AI_PROVIDER}.sh, selected by lib/intake-config.sh)
    # owns the actual invocation shape and writes the worker's PID to RUNNING_PIDFILE — the
    # poller's `kill -0` liveness check depends on that PID being the real worker process.
    ai_run_implementation "$LOGFILE" "$RUNNING_PIDFILE"
    # provider= lets the poller's local_llm_worker_live() serialize local-llm workers (one shared
    # LM Studio); model= is informational for `make intake-status` style debugging.
    printf 'started=%s\nbranch=%s\nworktree=%s\ncontainer=%s\nlog=%s\nprovider=%s\nmodel=%s\n' \
        "$(date +%s)" "$BRANCH" "$WORKTREE_DIR" "$APP_CONTAINER" "$LOGFILE" \
        "${AI_PROVIDER}" "${AI_IMPLEMENTATION_MODEL:-}" > "$RUNNING_METAFILE"
    LAUNCHED_MSG="headless worker (detached, pid $(cat "$RUNNING_PIDFILE" 2>/dev/null || true)) — log ${LOGFILE}"

elif [ "$TERMINAL" != "0" ]; then
    if [ "$CLAUDE" != "0" ]; then
        if [ -n "$TICKET" ]; then
            PROMPT="Bootstrap this worktree for ticket ${TICKET}. Read and follow .ai/prompts/worktree-bootstrap.md."
        else
            PROMPT="Bootstrap this worktree. No ticket id was detected in the branch name '${BRANCH}'. Read and follow .ai/prompts/worktree-bootstrap.md."
        fi
        LAUNCH_CMD="claude $(printf '%q' "$PROMPT")"
        LAUNCHED_MSG="Claude (interactive, bootstrap routine)"
    else
        LAUNCH_CMD="echo 'Worktree ready. Run: claude'"
        LAUNCHED_MSG="terminal only (CLAUDE=0)"
    fi
    echo "==> Opening terminal..."
    if ! wt_open_terminal "$WORKTREE_DIR" "$LAUNCH_CMD"; then
        echo "   (no terminal emulator found — open one manually and run: cd ${WORKTREE_DIR})"
        LAUNCHED_MSG="no terminal emulator found"
    fi
fi

BS_PORT=$((PORT + 1000))
echo ""
echo "================================================================"
echo "  Worktree ready: ${BRANCH}"
echo "  App:            http://localhost:${PORT}"
echo "  BrowserSync:    http://localhost:${BS_PORT}  (run: make watch)"
echo "  Xdebug port:    ${XDEBUG_PORT}"
echo "  Database:       ${DB_NAME} (${SEED})"
echo "  Container:      ${APP_CONTAINER}"
echo "  Ticket:         ${TICKET:-<none detected>}"
echo "  Terminal:       ${LAUNCHED_MSG}"
echo "================================================================"
