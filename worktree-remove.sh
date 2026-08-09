#!/bin/bash
# Reclaim a FINISHED implementation worktree's resources (the teardown counterpart of
# worktree-go.sh / worktree-new.sh). For a given feature branch it removes:
#   - the git worktree directory (sibling dir)
#   - the app container + the per-worktree compose network
#   - the per-worktree database in the shared PostgreSQL instance
#   - the (merged) feature branch                         (unless KEEP_BRANCH=1)
#
# <branch> accepts three forms:
#   1. an exact, existing branch (feature/TICKET-75-page-creation-and-organization)
#   2. JIRA shorthand — feature/<TICKET> or bare <TICKET> (feature/TICKET-75, TICKET-75) — resolved
#      against the real feature/<TICKET>-* branch (same glob intake-poll.sh uses). Zero or more
#      than one match is a hard error — it never falls through to derive-and-report-success on
#      an unresolved name.
#   3. anything else is refused: only feature/* branches are removable.
#
# Safe by default — a worktree is removable only when ALL hold:
#   1. the branch is feature/* (never main / the primary worktree)
#   2. it is NOT currently running — no live worker slot under .intake/running/<KEY>.pid
#      (the concurrency-cap PID files; a live `kill -0` means an implementation worker is active)
#   3. it is MERGED into local `main`                     (override for a single branch with FORCE=1)
# The database drop is additionally guarded (wt_drop_db) so the source DB (PROJECT_DB_PREFIX) is never
# dropped. The final summary reflects what was actually found/removed per resource — it never
# reports success for a resource that was never present to begin with. See
# .ai/plans/completed/worktree-remove.md.
#
# Merged-ness keys off the BUILD HOST's local `main`, so a PR merged via the Bitbucket/GitHub web
# UI — which only updates the remote — would otherwise look "unmerged" here. To close that gap,
# the script auto-syncs local `main` to `origin/main` before checking (see sync_main): it only ever
# fast-forwards (never rewrites history), and only when this worktree is currently on `main` with a
# clean working tree and no divergence from origin/main. If any of those don't hold, it skips the
# sync and leaves the existing manual-pull behavior in place. Disable with AUTO_SYNC=0.
#
# Usage:
#   bash ai-intake-harness/worktree-remove.sh <branch>     # remove one worktree by branch name
#   bash ai-intake-harness/worktree-remove.sh --merged     # sweep every merged feature/* worktree
#
# Env / flags:
#   DRY_RUN=1       list what would be removed; change nothing        (default 0)
#   KEEP_BRANCH=1   keep the git branch (default: delete if merged)   (default 0)
#   FORCE=1         single-branch: remove even if not merged (-D)     (default 0)
#   KEEP_DB=1       keep the database                                 (default 0)
#   AUTO_SYNC=0     don't fast-forward local main to origin/main first (default 1)
set -euo pipefail

DRY_RUN="${DRY_RUN:-0}"
KEEP_BRANCH="${KEEP_BRANCH:-0}"
FORCE="${FORCE:-0}"
KEEP_DB="${KEEP_DB:-0}"
AUTO_SYNC="${AUTO_SYNC:-1}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=ai-intake-harness/lib/worktree-common.sh
. "$(dirname "$0")/lib/worktree-common.sh"
# shellcheck source=ai-intake-harness/lib/intake-config.sh
. "$(dirname "$0")/lib/intake-config.sh" "$REPO_ROOT"

RUNNING_DIR="${REPO_ROOT}/.intake/running"

# Credentials + the source DB name (never drop this one).
POSTGRES_USER=$(wt_env_get "${REPO_ROOT}/.env" POSTGRES_USER)
POSTGRES_PASSWORD=$(wt_env_get "${REPO_ROOT}/.env" POSTGRES_PASSWORD)
SOURCE_DB=$(wt_env_get "${REPO_ROOT}/.env" POSTGRES_DB)

log()  { echo "[worktree-remove] $*" >&2; }

# 0 = a live implementation worker holds this ticket's slot (skip), 1 = free to remove.
worker_running() {
    local ticket="$1" pidfile pid
    [ -n "$ticket" ] || return 1
    pidfile="${RUNNING_DIR}/${ticket}.pid"
    [ -f "$pidfile" ] || return 1
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# 0 = merged into local main, 1 = not merged.
is_merged() {
    git branch --merged main --format='%(refname:short)' | grep -qx "$1"
}

# Fast-forward local `main` to `origin/main` so a PR merged via the web UI (which only updates the
# remote) doesn't read as "unmerged" here. Only ever fast-forwards, and only when it's unambiguously
# safe; otherwise it logs why it skipped and leaves merged-ness to whatever local main already has.
sync_main() {
    [ "$AUTO_SYNC" = "1" ] || return 0

    local current_branch
    current_branch="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [ "$current_branch" != "main" ]; then
        log "main sync: skipped — this worktree is on '$current_branch', not main"
        return 0
    fi

    if ! git -C "$REPO_ROOT" fetch origin main --quiet 2>/dev/null; then
        log "main sync: skipped — could not fetch origin/main (offline / no remote?)"
        return 0
    fi

    local local_sha remote_sha
    local_sha="$(git -C "$REPO_ROOT" rev-parse main)"
    remote_sha="$(git -C "$REPO_ROOT" rev-parse origin/main 2>/dev/null || true)"
    [ -n "$remote_sha" ] || return 0
    [ "$local_sha" = "$remote_sha" ] && return 0

    if ! git -C "$REPO_ROOT" merge-base --is-ancestor main origin/main; then
        log "main sync: skipped — local main has diverged from origin/main, resolve manually"
        return 0
    fi

    if [ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]; then
        log "main sync: skipped — local main has uncommitted changes, commit/stash first"
        return 0
    fi

    if [ "$DRY_RUN" = "1" ]; then
        log "main sync: [dry-run] local main is behind origin/main — would fast-forward"
        return 0
    fi

    git -C "$REPO_ROOT" merge --ff-only origin/main --quiet
    log "main sync: fast-forwarded local main ${local_sha:0:8} -> ${remote_sha:0:8}"
}

# Resolve user input into a real, existing local branch name. Prints the resolved branch name on
# stdout and returns 0 on success. Never falls through to name-derivation on an unresolved input —
# returns 1 with a logged error instead, so a wrong/ambiguous name can't silently no-op.
resolve_branch() {
    local input="$1" ticket matches match_count

    if git show-ref --verify --quiet "refs/heads/${input}"; then
        printf '%s' "$input"
        return 0
    fi

    ticket=$(printf '%s' "$input" | grep -oiE "${PROJECT_TICKET_REGEX:-TICKET-[0-9]+}" | head -1 | tr '[:lower:]' '[:upper:]')
    if [ -z "$ticket" ]; then
        log "refusing '$input' — not an existing branch and no ticket key found (only feature/* branches are removable)"
        return 1
    fi

    matches="$(git for-each-ref --format='%(refname:short)' "refs/heads/feature/${ticket}-*")"
    match_count="$(printf '%s\n' "$matches" | grep -c . || true)"

    if [ "$match_count" -eq 0 ]; then
        log "no feature/${ticket}-* branch found for '$input' — check 'git branch -a'"
        return 1
    fi
    if [ "$match_count" -gt 1 ]; then
        log "'$input' is ambiguous — multiple feature/${ticket}-* branches found, pass the exact one:"
        printf '%s\n' "$matches" | while IFS= read -r b; do log "    $b"; done
        return 1
    fi

    log "resolved '$input' -> '$matches'"
    printf '%s' "$matches"
    return 0
}

# Remove one branch's resources. Returns 0 if removed/skipped-by-guard-with-a-reason, 1 on
# resolution failure, refusal, or a run that touched nothing.
remove_branch() {
    local input="$1" branch

    branch="$(resolve_branch "$input")" || return 1

    if [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
        log "refusing to remove '$branch' — that is the primary worktree"; return 1
    fi
    case "$branch" in
        feature/*) ;;
        *) log "refusing to remove '$branch' — only feature/* branches are removable"; return 1 ;;
    esac

    # Derive SLUG / DB_NAME / PROJECT_NAME / APP_CONTAINER / TICKET / WORKTREE_DIR
    project_derive_names "$branch" "$REPO_ROOT"

    if worker_running "$TICKET"; then
        log "skip '$branch' — an implementation worker is still running (slot ${TICKET}.pid live)"; return 1
    fi

    if ! is_merged "$branch"; then
        if [ "$FORCE" = "1" ]; then
            log "'$branch' is NOT merged into main — proceeding anyway (FORCE=1)"
        else
            log "skip '$branch' — not merged into local main, even after syncing with origin/main (use FORCE=1 to override if this is expected)"; return 1
        fi
    fi

    if [ "$DRY_RUN" = "1" ]; then
        log "[dry-run] would remove '$branch':"
        log "    worktree : ${WORKTREE_DIR}"
        log "    container: ${APP_CONTAINER}  (network ${PROJECT_NAME}_default)"
        [ "$KEEP_DB" = "1" ]     && log "    database : (kept)" || log "    database : ${DB_NAME}"
        [ "$KEEP_BRANCH" = "1" ] && log "    branch   : (kept)" || log "    branch   : delete ${branch}"
        return 0
    fi

    local wt_note container_note db_note branch_note any_found=0

    # 1. git worktree
    if [ -d "$WORKTREE_DIR" ]; then
        git -C "$REPO_ROOT" worktree remove --force "$WORKTREE_DIR" > /dev/null 2>&1 \
            || rm -rf "$WORKTREE_DIR"
        wt_note="worktree: removed"
        any_found=1
    else
        wt_note="worktree: not found (already gone)"
    fi
    git -C "$REPO_ROOT" worktree prune > /dev/null 2>&1 || true

    # 2. container + network
    if wt_remove_container "$APP_CONTAINER" "$PROJECT_NAME"; then
        container_note="container: removed"
        any_found=1
    else
        container_note="container: not found (already gone)"
    fi

    # 3. database (guarded) — also the companion "<db>_test" database Doctrine's test env
    # creates (make test-ci), which otherwise outlives the worktree as an orphan.
    if [ "$KEEP_DB" = "1" ]; then
        db_note="database: kept"
    elif wt_drop_db "$DB_NAME" "$POSTGRES_USER" "$POSTGRES_PASSWORD" "$SOURCE_DB"; then
        db_note="database: dropped"
        if wt_drop_db "${DB_NAME}_test" "$POSTGRES_USER" "$POSTGRES_PASSWORD" "$SOURCE_DB"; then
            db_note="database: dropped (+ _test)"
        fi
        any_found=1
    else
        wt_drop_db "${DB_NAME}_test" "$POSTGRES_USER" "$POSTGRES_PASSWORD" "$SOURCE_DB" \
            && { db_note="database: not found, orphaned _test dropped"; any_found=1; } \
            || db_note="database: not found (already gone)"
    fi

    # 4. branch (only after its worktree is gone, or `git branch -d` refuses a checked-out branch)
    if git show-ref --verify --quiet "refs/heads/${branch}"; then
        any_found=1
        if [ "$KEEP_BRANCH" = "1" ]; then
            branch_note="branch: kept"
        elif [ "$FORCE" = "1" ]; then
            if git -C "$REPO_ROOT" branch -D "$branch" > /dev/null 2>&1; then
                branch_note="branch: removed"
            else
                branch_note="branch: kept (delete failed)"
            fi
        else
            if git -C "$REPO_ROOT" branch -d "$branch" > /dev/null 2>&1; then
                branch_note="branch: removed"
            else
                branch_note="branch: kept (git refused — not fully merged)"
            fi
        fi
    else
        branch_note="branch: not found (already gone)"
    fi

    if [ "$any_found" = "0" ]; then
        log "nothing to remove for '$branch' — no worktree, container, database, or branch matched"
        return 1
    fi

    log "removed '$branch' — ${wt_note}; ${container_note}; ${db_note}; ${branch_note}"
    return 0
}

# ----- main ---------------------------------------------------------------------------
if [ $# -lt 1 ]; then
    cat >&2 <<'USAGE'
Usage:
  bash ai-intake-harness/worktree-remove.sh <branch>     remove one worktree by branch name
  bash ai-intake-harness/worktree-remove.sh --merged     sweep every merged feature/* worktree

<branch> may be the exact branch, feature/<TICKET>, or bare <TICKET> — shorthand forms are
resolved against the real feature/<TICKET>-* branch.

Env / flags: DRY_RUN=1  KEEP_BRANCH=1  FORCE=1  KEEP_DB=1  AUTO_SYNC=0
USAGE
    exit 2
fi

sync_main

if [ "$1" = "--merged" ]; then
    log "sweeping merged feature/* worktrees (DRY_RUN=${DRY_RUN})"
    removed=0; skipped=0
    while IFS= read -r b; do
        [ -n "$b" ] || continue
        if remove_branch "$b"; then removed=$((removed+1)); else skipped=$((skipped+1)); fi
    done < <(git branch --merged main --format='%(refname:short)' | grep '^feature/' || true)
    log "sweep complete: ${removed} removed, ${skipped} skipped"
else
    remove_branch "$1"
fi
