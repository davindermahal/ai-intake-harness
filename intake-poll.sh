#!/bin/bash
# Intake poller — generic core engine, driving the ticket -> plan -> approval -> worktree ->
# build/verify -> report state machine behind the tracker_*/project_*/ai_* adapter seams.
#
# Runs the two abstract pickup queues against the configured tracker and dispatches per matched
# ticket, then sweeps a third pass over tickets already being worked:
#   - Planning queue       ("Ready for Planning")       -> headless Claude on
#         ai-intake-harness/prompts/intake-planning.md  (authors/refines the plan, emits a decision JSON)
#   - Implementation queue ("Ready for Implementation") -> pure-bash trigger:
#         flip plan to ready, run `make worktree-go HEADLESS=1` (which launches a detached
#         headless Claude worker, .ai/prompts/worktree-bootstrap-auto.md, that implements +
#         builds + verifies and posts its own results to the ticket).
#   - Watchdog pass ("In Progress")                     -> pure-bash sweep:
#         detects a stalled implementation worker (dead PID, no report back) and restarts it
#         through the same worktree-go path (RESUME), up to JIRA_MAX_ATTEMPTS; escalates with a
#         ticket comment instead of restarting once retries are exhausted or the worker already
#         reported a blocker. See "Watchdog" below.
#
# FULL-REST design (no MCP on the headless path): this script performs ALL tracker I/O —
# search, read, comment, transition — through the configured tracker adapter (Jira today,
# ai-intake-harness/lib/tracker/jira.sh, full-REST with a personal API token). The AI runs never
# talk to the tracker directly. This removes the interactive OAuth (MCP) dependency so the
# workflow runs unattended. See .ai/docs/jira-intake-setup.md (Part A2) and .ai/docs/JIRA-WORKFLOW.md.
#
# Tracker + project + AI selection comes from .ai/intake.config (TRACKER, TRACKER_PROJECT_KEY,
# PROJECT_ADAPTER, PROJECT_DB_PREFIX, AI_PROVIDER, AI_PROFILE_*, ...), loaded via
# ai-intake-harness/lib/intake-config.sh — edit that file to point this poller at a different
# tracker, target project, or AI backend; nothing in this script hardcodes any of them. The AI
# provider AND model can also be selected per-ticket, per-phase, via Jira labels:
# ai-plan-<profile> (planning) / ai-impl-<profile> (implementation), where <profile> names an
# AI_PROFILE_<name>="provider:model" entry in .ai/intake.config; the legacy ai-provider-<name>
# label still works (both phases, provider only). See resolve_ai_profile below and
# ai-intake-harness/lib/ai/<name>.sh for the ai_* adapter contract.
#
# Planning worker <-> poller protocol (per ticket):
#   - poller writes the ticket JSON to   .intake/context/<KEY>.json
#   - the AI writes its decision JSON to  .intake/decision/<KEY>.json
#       {"action":"questions"|"clean"|"skip", "comment":"<always present>", "plan_file":"..."}
#   - poller posts `comment` to the ticket (ALWAYS) and transitions it accordingly.
#
# Automation boundary: build + verify only. Nothing is pushed to a shared remote, merged to
# main, or deployed automatically — a human reviews the branch diff and merges.
#
# A flock guarantees a single instance; a durable in-flight set under .intake/inflight/
# prevents re-picking a ticket an earlier (possibly crashed) run is still working.
#
# Watchdog (In Progress sweep): every implementation launch (initial dispatch or a watchdog
# restart) writes a durable record to .intake/attempts/<KEY> (attempts=N, launched=<epoch>) — the
# running-slot files are deleted once a dead slot is reaped, so they can't prove later that the
# harness dispatched a ticket. The watchdog only ever acts on tickets that have this record: no
# record means a human dragged the ticket to In Progress manually, and it's left alone. For every
# other In Progress ticket with a record, past a grace period (JIRA_WATCHDOG_GRACE_SECONDS) it
# checks the recorded PID: alive -> healthy, skip. Dead/missing -> checks whether an AI-footer
# comment was posted after the last launch (the worker finished and deliberately left a
# blocker/failure report) -> escalate, don't restart. Otherwise -> restart via the same
# worktree-go RESUME path used for a Ready for Verification -> Ready for Implementation bounce,
# up to JIRA_MAX_ATTEMPTS total launches (default 3 = initial + 2 restarts). At the cap, or on the
# reported-blocker case, it posts a one-shot escalation comment and drops a
# .intake/attempts/<KEY>.escalated marker so it never repeats the comment on later polls — the
# ticket stays In Progress (the workflow's "AI stuck" signal); move it back to Ready for
# Implementation to clear the escalation and re-queue.
#
# Auth (single-account model) — set in .env.local (gitignored):
#   JIRA_SITE_URL=https://your-site.atlassian.net
#   JIRA_INTAKE_EMAIL=you@your-domain
#   JIRA_INTAKE_API_TOKEN=...            # id.atlassian.com -> Security -> API tokens
#
# Usage:
#   bash ai-intake-harness/intake-poll.sh [--mode planning|implementation|watchdog|both] [--dry-run]
#
# Env overrides:
#   POLL_MODE=both|planning|implementation|watchdog   which pass(es) to run   (default: both)
#   DRY_RUN=1                                list matches, do not dispatch  (default: 0)
#   CLAUDE_BIN=claude                        claude CLI binary (all real ai_* adapters use it) (default: claude)
#   CLAUDE_FLAGS="--permission-mode acceptEdits"   flags for headless runs
#   CLAUDE_TIMEOUT=900                       seconds before a claude planning run is killed
#   AI_PROVIDER=claude|openai|local-llm      which ai_* adapter drives dispatches (default: claude)
#   AI_PLANNING_MODEL=...                    --model for planning runs (default: empty = CLI default)
#   AI_IMPLEMENTATION_MODEL=...              --model for implementation runs (default: empty = CLI default)
#   AI_LOCAL_LLM_TIMEOUT=3600                planning kill timeout when the resolved provider is
#                                             local-llm (local models are slower; Claude keeps
#                                             CLAUDE_TIMEOUT)
#   INFLIGHT_STALE_SECONDS=1800              re-pick a stuck in-flight ticket after this
#   JIRA_MAX_WORKTREES=2                     max implementation workers running at once
#   JIRA_RUN_STALE_SECONDS=14400             kill+reclaim a hung worker's slot after this
#   JIRA_MAX_ATTEMPTS=3                      watchdog: total launches per stall episode before
#                                             escalating instead of restarting (initial + N-1 retries)
#   JIRA_WATCHDOG_GRACE_SECONDS=900          watchdog: ignore an In Progress ticket until this long
#                                             after its last launch (protects the provisioning window)
#
# The tracker's project key is set in .ai/intake.config (TRACKER_PROJECT_KEY), not an env var.
#
# Crontab (poll every 2 minutes, never overlap, log to file):
#   */2 * * * * cd /path/to/project && /usr/bin/flock -n .intake/poll.lock \
#       bash ai-intake-harness/intake-poll.sh >> .intake/poll.log 2>&1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# ----- config / env -------------------------------------------------------------------
POLL_MODE="${POLL_MODE:-both}"
DRY_RUN="${DRY_RUN:-0}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CLAUDE_FLAGS="${CLAUDE_FLAGS:---permission-mode acceptEdits}"
CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-900}"
INFLIGHT_STALE_SECONDS="${INFLIGHT_STALE_SECONDS:-1800}"
JIRA_MAX_WORKTREES="${JIRA_MAX_WORKTREES:-2}"      # max simultaneous implementation workers
JIRA_RUN_STALE_SECONDS="${JIRA_RUN_STALE_SECONDS:-14400}"  # reclaim a hung worker after ~4h
JIRA_MAX_ATTEMPTS="${JIRA_MAX_ATTEMPTS:-3}"                # watchdog: initial launch + N-1 restarts
JIRA_WATCHDOG_GRACE_SECONDS="${JIRA_WATCHDOG_GRACE_SECONDS:-900}"  # watchdog: ignore a fresh launch this long

while [ $# -gt 0 ]; do
    case "$1" in
        --mode) POLL_MODE="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) sed -n '2,88p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

STATE_DIR="$REPO_ROOT/.intake"
INFLIGHT_DIR="$STATE_DIR/inflight"
CONTEXT_DIR="$STATE_DIR/context"
DECISION_DIR="$STATE_DIR/decision"
RUNNING_DIR="$STATE_DIR/running"
ATTEMPTS_DIR="$STATE_DIR/attempts"
mkdir -p "$INFLIGHT_DIR" "$CONTEXT_DIR" "$DECISION_DIR" "$RUNNING_DIR" "$ATTEMPTS_DIR"

# Logs go to stderr so they never pollute a `$(...)` capture of a helper's stdout
# (e.g. live="$(running_count)"). The cron line merges 2>&1 into poll.log, so nothing is lost.
log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# ----- tracker + project + AI adapters (config-selected) -------------------------------
# Provides: tracker_load_env, tracker_search, tracker_get_issue, tracker_add_comment,
# tracker_transition, tracker_ticket_regex (plus the project_* contract, unused here but loaded
# for anything downstream this process launches, and the ai_* contract for the env/config-default
# AI_PROVIDER — resolve_ai_profile/load_ai_provider below reload it per-ticket when a Jira label
# overrides it). Selection comes from .ai/intake.config.
# shellcheck source=ai-intake-harness/lib/intake-config.sh
. "$SCRIPT_DIR/lib/intake-config.sh" "$REPO_ROOT"
tracker_load_env "$REPO_ROOT" || die "could not load tracker credentials/tools"

# ----- in-flight set ------------------------------------------------------------------
inflight_active() {  # 0 = currently in-flight (skip), 1 = free to process
    local key="$1"; local marker="$INFLIGHT_DIR/$key" age now mtime
    [ -f "$marker" ] || return 1
    now="$(date +%s)"; mtime="$(stat -c %Y "$marker" 2>/dev/null || echo 0)"
    age=$(( now - mtime ))
    if [ "$age" -ge "$INFLIGHT_STALE_SECONDS" ]; then
        log "in-flight marker for $key is stale (${age}s) — reclaiming"
        rm -f "$marker"; return 1
    fi
    return 0
}
inflight_mark()  { date +%s > "$INFLIGHT_DIR/$1"; }
inflight_clear() { rm -f "$INFLIGHT_DIR/$1"; }

# ----- running-slot set (implementation concurrency cap) ------------------------------
# A detached implementation worker occupies a slot from launch (worktree-go HEADLESS writes its
# PID to $RUNNING_DIR/<KEY>.pid) until its process exits. reap_running() frees slots whose worker
# has died (or hung past JIRA_RUN_STALE_SECONDS); running_count() reports how many remain live.
# The implementation dispatch loop stops once the live count reaches JIRA_MAX_WORKTREES, leaving the
# remaining "Ready for Implementation" tickets for a later poll to pick up as slots free.
reap_running() {
    local f key pid now mtime age
    now="$(date +%s)"
    for f in "$RUNNING_DIR"/*.pid; do
        [ -e "$f" ] || continue
        key="$(basename "$f" .pid)"
        pid="$(cat "$f" 2>/dev/null || true)"
        if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
            log "  slot freed for $key (worker pid ${pid:-?} exited)"
            rm -f "$f" "$RUNNING_DIR/$key.meta"
            continue
        fi
        mtime="$(stat -c %Y "$f" 2>/dev/null || echo "$now")"; age=$(( now - mtime ))
        if [ "$age" -ge "$JIRA_RUN_STALE_SECONDS" ]; then
            log "  slot for $key is stale (${age}s, pid $pid) — killing worker and reclaiming"
            kill "$pid" 2>/dev/null || true
            rm -f "$f" "$RUNNING_DIR/$key.meta"
        fi
    done
}
running_count() {
    reap_running
    local n=0 f
    for f in "$RUNNING_DIR"/*.pid; do [ -e "$f" ] && n=$((n+1)); done
    echo "$n"
}

# local_llm_worker_live — true if any live implementation-worker slot was launched with the
# local-llm provider (running-slot .meta files carry a provider= line, written by worktree-go).
# LM Studio is a single shared inference server, so at most one local-llm worker may run at a
# time regardless of JIRA_MAX_WORKTREES.
local_llm_worker_live() {
    reap_running
    local m
    for m in "$RUNNING_DIR"/*.meta; do
        [ -e "$m" ] || continue
        grep -qx 'provider=local-llm' "$m" 2>/dev/null && return 0
    done
    return 1
}

# ----- attempts record (watchdog dispatch history, survives a reaped running-slot) -----------
# One file per ticket, .intake/attempts/<KEY>: `attempts=<N>` (total launches this stall episode,
# starting at 1) and `launched=<epoch>` (of the most recent launch). A ticket with no record was
# never dispatched by the harness (a human dragged it to In Progress) and the watchdog leaves it
# alone. `.intake/attempts/<KEY>.escalated` marks a stall episode already reported so the watchdog
# doesn't repeat the comment on every later poll.
attempts_file() { printf '%s/%s' "$ATTEMPTS_DIR" "$1"; }
attempts_exists() { [ -f "$(attempts_file "$1")" ]; }
attempts_escalated() { [ -f "$(attempts_file "$1").escalated" ]; }
attempts_mark_escalated() { touch "$(attempts_file "$1").escalated"; }

# attempts_get KEY — echoes "<attempts> <launched-epoch>" (defaults "0 0" if no record).
attempts_get() {
    local key="$1" f attempts=0 launched=0
    f="$(attempts_file "$key")"
    if [ -f "$f" ]; then
        attempts="$(sed -n 's/^attempts=//p' "$f")"; [ -n "$attempts" ] || attempts=0
        launched="$(sed -n 's/^launched=//p' "$f")"; [ -n "$launched" ] || launched=0
    fi
    printf '%s %s\n' "$attempts" "$launched"
}

# attempts_reset KEY — fresh dispatch from Ready for Implementation: new stall episode, attempt 1.
attempts_reset() {
    printf 'attempts=1\nlaunched=%s\n' "$(date +%s)" > "$(attempts_file "$1")"
    rm -f "$(attempts_file "$1").escalated"
}

# attempts_bump KEY — watchdog restart: same episode, one more attempt, launch clock reset.
attempts_bump() {
    local key="$1" attempts launched
    read -r attempts launched < <(attempts_get "$key")
    printf 'attempts=%s\nlaunched=%s\n' "$((attempts + 1))" "$(date +%s)" > "$(attempts_file "$key")"
}

# ----- dispatch-failure one-shot escalation ----------------------------------------------------
# The watchdog's .escalated marker pattern applied to the dispatch failure paths, which used to
# re-post the SAME ticket comment on every 2-minute poll until a human intervened. One marker per
# (ticket, phase) under $ATTEMPTS_DIR; its content is the resolved AI spec, so changing the
# ticket's labels/profile (a human "nudge") re-arms the comment while the same failing
# configuration stays silent. The marker clears on the next successful dispatch of that phase
# (e.g. the provider's env check passes again).
dispatch_marker() { printf '%s/%s.%s-dispatch-escalated' "$ATTEMPTS_DIR" "$1" "$2"; }
dispatch_escalate_once() {
    local key="$1" phase="$2" spec="$3" message="$4" marker
    marker="$(dispatch_marker "$key" "$phase")"
    if [ -f "$marker" ] && [ "$(cat "$marker" 2>/dev/null)" = "$spec" ]; then
        log "  $key: $phase dispatch still failing (AI spec '$spec') — already reported, not re-commenting"
        return 0
    fi
    tracker_add_comment "$key" "$message"
    printf '%s' "$spec" > "$marker"
}
dispatch_escalation_clear() { rm -f "$(dispatch_marker "$1" "$2")"; }

# ----- branch helpers -----------------------------------------------------------------
# kebab-case slug from a ticket summary (<=50 chars).
slugify() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-50 | sed -E 's/-+$//'
}

# Existing feature/<KEY>-* branch, or empty.
existing_branch() {
    git -C "$REPO_ROOT" for-each-ref --format='%(refname:short)' "refs/heads/feature/$1-*" | head -1
}

# Branch for a ticket: reuse an existing feature/<KEY>-* branch, else feature/<KEY>-<slug>.
resolve_branch() {
    local key="$1" summary="$2" b slug
    b="$(existing_branch "$key")"; [ -n "$b" ] && { printf '%s' "$b"; return; }
    slug="$(slugify "$summary")"
    printf 'feature/%s-%s' "$key" "${slug:-ticket}"
}

# ----- AI profile resolution (per-ticket + per-phase label > env/config default) -------
# resolve_ai_profile CTX_FILE PHASE — echoes a "provider" or "provider:model" spec for THIS
# ticket's PHASE (planning|implementation). Precedence per phase:
#   1. phase label  ai-plan-<profile> / ai-impl-<profile> — <profile> names an
#      AI_PROFILE_<name>="provider:model" entry in .ai/intake.config (hyphens in the label map
#      to '_' in the variable name); a bare provider name (lib/ai/<name>.sh exists) doubles as a
#      model-less profile. An unknown profile name is passed through as a provider spec so the
#      dispatch fails loudly (one-shot escalation) instead of silently falling back.
#   2. legacy ai-provider-<name> label (both phases, provider only — kept working for compatibility)
#   3. env/config default: $AI_PROVIDER plus the phase's AI_PLANNING_MODEL/AI_IMPLEMENTATION_MODEL
# The model part is everything after the FIRST colon (model ids may themselves contain ':').
resolve_ai_profile() {
    local ctx="$1" phase="$2" prefix label name var spec default_model
    case "$phase" in
        planning)       prefix="ai-plan-"; default_model="${AI_PLANNING_MODEL:-}" ;;
        implementation) prefix="ai-impl-"; default_model="${AI_IMPLEMENTATION_MODEL:-}" ;;
        *) log "resolve_ai_profile: unknown phase '$phase'"; return 1 ;;
    esac
    label="$(jq -r --arg p "$prefix" '.fields.labels[]? | select(startswith($p))' "$ctx" | head -1)"
    if [ -n "$label" ]; then
        name="${label#"$prefix"}"
        var="AI_PROFILE_${name//-/_}"
        spec="${!var:-}"
        if [ -n "$spec" ]; then
            printf '%s' "$spec"
        elif [ -f "$SCRIPT_DIR/lib/ai/${name}.sh" ]; then
            printf '%s' "$name"
        else
            log "  unknown AI profile '$name' (no $var in .ai/intake.config, no lib/ai/${name}.sh) — passing through so the dispatch fails visibly"
            printf '%s' "$name"
        fi
        return 0
    fi
    label="$(jq -r '.fields.labels[]? | select(test("^ai-provider-"))' "$ctx" | head -1)"
    if [ -n "$label" ]; then
        printf '%s' "${label#ai-provider-}"
        return 0
    fi
    if [ -n "$default_model" ]; then
        printf '%s:%s' "$AI_PROVIDER" "$default_model"
    else
        printf '%s' "$AI_PROVIDER"
    fi
}

# spec_provider/spec_model SPEC — split a "provider[:model]" spec on the first colon.
spec_provider() { printf '%s' "${1%%:*}"; }
spec_model()    { case "$1" in *:*) printf '%s' "${1#*:}" ;; *) printf '' ;; esac; }

# load_ai_provider NAME — (re)source ai/<name>.sh, which (re)defines ai_load_env/ai_run_planning/
# ai_run_implementation, then runs ai_load_env. Called fresh before every dispatch (not cached) so
# a ticket-by-ticket label can select a different provider than the previous dispatch within the
# same long-lived poller process.
load_ai_provider() {
    local name="$1"
    local f="$SCRIPT_DIR/lib/ai/${name}.sh"
    if [ ! -f "$f" ]; then
        log "  unknown AI provider '$name' (no lib/ai/${name}.sh)"; return 1
    fi
    # shellcheck source=/dev/null
    . "$f"
    ai_load_env
}

# ----- dispatch -----------------------------------------------------------------------
dispatch_planning() {
    local key="$1"; local ctx="$CONTEXT_DIR/$key.json" dec="$DECISION_DIR/$key.json"
    local summary branch wt action comment spec provider model saved_model saved_timeout rc
    tracker_get_issue "$key" > "$ctx"
    summary="$(jq -r '.fields.summary // ""' "$ctx")"
    spec="$(resolve_ai_profile "$ctx" planning)"
    provider="$(spec_provider "$spec")"
    model="$(spec_model "$spec")"
    branch="$(resolve_branch "$key" "$summary")"
    wt="$(dirname "$REPO_ROOT")/${PLAN_WORKTREE_PREFIX}$key"
    rm -f "$dec"
    log "dispatch $key -> planning (branch $branch, AI: $spec)"
    if [ "$DRY_RUN" = "1" ]; then log "  [dry-run] would plan $key on $branch (AI $spec) in an ephemeral worktree"; return 0; fi

    if ! load_ai_provider "$provider"; then
        log "  $key: AI provider '$provider' failed its environment check — leaving for a later poll"
        dispatch_escalate_once "$key" planning "$spec" "Cannot start planning for $key: the configured AI provider '$provider' (resolved from '$spec') failed its environment check (see the poller log on the build host). Left the ticket as-is; fix the provider config/label and it will be retried automatically. This message is posted once per failing configuration."
        return 0
    fi
    dispatch_escalation_clear "$key" planning

    inflight_mark "$key"

    # Ephemeral worktree of the feature branch (checkout only — no container). Plans are authored
    # and committed HERE so they live on the feature branch.
    git -C "$REPO_ROOT" worktree remove --force "$wt" 2>/dev/null || true; rm -rf "$wt"
    if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
        git -C "$REPO_ROOT" worktree add --quiet "$wt" "$branch" || { log "  $key: worktree add (existing branch) failed"; return 0; }
    else
        git -C "$REPO_ROOT" worktree add --quiet -b "$branch" "$wt" main || { log "  $key: worktree add (new branch) failed"; return 0; }
    fi

    # Per-dispatch model + timeout: the profile-resolved model rides the existing
    # AI_PLANNING_MODEL global (save/restored — not subshelled, because the exit status and the
    # bookkeeping around the run live in this process), and local models get the longer
    # AI_LOCAL_LLM_TIMEOUT instead of the Claude-tuned CLAUDE_TIMEOUT.
    saved_model="$AI_PLANNING_MODEL"; saved_timeout="$CLAUDE_TIMEOUT"
    [ -n "$model" ] && AI_PLANNING_MODEL="$model"
    [ "$provider" = "local-llm" ] && CLAUDE_TIMEOUT="$AI_LOCAL_LLM_TIMEOUT"
    ai_run_planning "$key" "$branch" "$ctx" "$dec" "$wt"; rc=$?
    AI_PLANNING_MODEL="$saved_model"; CLAUDE_TIMEOUT="$saved_timeout"
    if [ "$rc" -ne 0 ]; then
        log "  $key: AI planning FAILED — removing worktree, leaving marker for stale-reclaim"
        git -C "$REPO_ROOT" worktree remove --force "$wt" 2>/dev/null || true; return 0
    fi
    if [ ! -f "$dec" ]; then
        log "  $key: no decision file — removing worktree, leaving in-flight"
        git -C "$REPO_ROOT" worktree remove --force "$wt" 2>/dev/null || true; return 0
    fi

    action="$(jq -r '.action // "error"' "$dec")"
    comment="$(jq -r '.comment // ""' "$dec")"
    plan_file="$(jq -r '.plan_file // ""' "$dec")"

    # Commit the plan on the feature branch (only if Claude actually wrote/changed it).
    if [ -n "$(git -C "$wt" status --porcelain .ai/plans/active/ 2>/dev/null)" ]; then
        git -C "$wt" add .ai/plans/active/ >/dev/null 2>&1 || true
        git -C "$wt" -c user.name="JIRA intake" -c user.email="$JIRA_INTAKE_EMAIL" \
            commit --quiet -m "$key planning ($action): update plan" >/dev/null 2>&1 || true
        log "  $key: committed plan on $branch"
    fi

    # On a clean plan, append the FULL plan contents inline beneath the summary so the author can
    # read/approve it without a checkout (the plan is committed on the feature branch locally and
    # never pushed, so a Bitbucket link would 404). Must read it BEFORE removing the worktree.
    # `make jira-plan KEY=$key` prints the same file locally. Jira wiki: {code}…{code} = code block.
    if [ "$action" = "clean" ] && [ -n "$plan_file" ]; then
        local plan_path="$plan_file"
        case "$plan_path" in /*) ;; *) plan_path="$wt/$plan_path" ;; esac
        if [ -f "$plan_path" ]; then
            comment="$comment

----
*Full plan* (\`$plan_file\`) — also available locally via \`make jira-plan KEY=$key\`:

{code}
$(cat "$plan_path")
{code}"
        else
            log "  $key: plan_file '$plan_file' not found — posting summary without inline plan"
        fi
    fi

    git -C "$REPO_ROOT" worktree remove --force "$wt" 2>/dev/null || true

    [ -n "$comment" ] && tracker_add_comment "$key" "$comment"   # always post the summary
    case "$action" in
        questions) tracker_transition "$key" needs-author-input && inflight_clear "$key" ;;
        clean)     tracker_transition "$key" plan-review        && inflight_clear "$key" ;;
        skip)      log "  $key: planning skipped" ; inflight_clear "$key" ;;
        *)         log "  $key: unrecognized planning action '$action' — leaving in-flight" ;;
    esac
}

# worktree_dir_for_branch BRANCH — the sibling dir worktree-go derives from a branch name
# ('/' -> '-', lowercased). Used to detect a leftover worktree from a prior run so both the fresh
# dispatch and the watchdog restart can decide whether to pass RESUME=1.
worktree_dir_for_branch() {
    local slug; slug="$(printf '%s' "$1" | tr '/' '-' | tr '[:upper:]' '[:lower:]')"
    printf '%s/%s' "$(dirname "$REPO_ROOT")" "$slug"
}

# launch_implementation_worker KEY BRANCH PROVIDER MODEL — run `make worktree-go HEADLESS=1`
# (RESUME=1 auto-detected from a leftover worktree dir), logging to .intake/logs/. Prints the
# logfile path to stdout and returns worktree-go's exit status. Shared by a fresh dispatch
# (dispatch_implementation) and a watchdog restart (process_watchdog) — same launch, different
# caller-side bookkeeping (attempts_reset vs. attempts_bump, launch comment vs. restart comment).
# MODEL may be empty (= the provider/CLI default); a profile-resolved model rides worktree-go's
# existing MODEL= override into AI_IMPLEMENTATION_MODEL.
launch_implementation_worker() {
    local key="$1" branch="$2" provider="$3" model="${4:-}" wtdir resume=0 logfile
    wtdir="$(worktree_dir_for_branch "$branch")"
    if [ -d "$wtdir" ]; then
        resume=1
        log "  $key: existing worktree $wtdir — will RESUME in place"
    fi
    mkdir -p "$STATE_DIR/logs"
    logfile="$STATE_DIR/logs/$key-worktree-$(date +%Y%m%d-%H%M%S).log"
    log "  $key: launching worktree-go (HEADLESS, RESUME=$resume, PROVIDER=$provider, MODEL=${model:-<default>}) on branch $branch; log $logfile"
    echo "$logfile"
    HEADLESS=1 RESUME="$resume" PROVIDER="$provider" MODEL="$model" make -C "$REPO_ROOT" worktree-go BRANCH="$branch" >"$logfile" 2>&1
}

# Implementation trigger is pure bash: find the ticket's feature branch (created during planning,
# with the plan committed on it) and launch `make worktree-go HEADLESS=1`, which checks out that
# branch, flips the committed plan to ready, and runs a detached headless worker
# (.ai/prompts/worktree-bootstrap-auto.md) that implements + builds + verifies and posts results
# to the ticket. Nothing is pushed/merged/deployed — the human merges.
dispatch_implementation() {
    local key="$1"; local ctx="$CONTEXT_DIR/$key.json" branch logfile spec provider model
    log "dispatch $key -> implementation (bash trigger)"
    tracker_get_issue "$key" > "$ctx"
    spec="$(resolve_ai_profile "$ctx" implementation)"
    provider="$(spec_provider "$spec")"
    model="$(spec_model "$spec")"

    branch="$(existing_branch "$key")"
    if [ -z "$branch" ]; then
        log "  $key: no feature/$key-* branch — no committed plan to implement"
        dispatch_escalate_once "$key" implementation "$spec" "Cannot implement $key: no feature branch / committed plan found. It must go through planning first (Ready for Planning). This message is posted once."
        return 0
    fi

    # LM Studio is one shared inference server — never launch a second local-llm implementation
    # worker while one is live. Defer exactly like the JIRA_MAX_WORKTREES capacity
    # check: the ticket stays queued and a later poll picks it up when the slot frees.
    if [ "$provider" = "local-llm" ] && local_llm_worker_live; then
        log "  $key: a local-llm implementation worker is already live — deferring (one LM Studio)"
        return 0
    fi

    if [ "$DRY_RUN" = "1" ]; then log "  [dry-run] would run: HEADLESS=1 PROVIDER=$provider MODEL=$model make worktree-go BRANCH=$branch (RESUME auto-detected)"; return 0; fi

    inflight_mark "$key"
    # A fresh dispatch from Ready for Implementation is always a NEW stall episode (even if it
    # resumes a leftover worktree from a prior bounce) — reset the watchdog's attempts record so a
    # human re-queuing always gets the full retry budget and clears any stale escalation.
    if logfile="$(launch_implementation_worker "$key" "$branch" "$provider" "$model")"; then
        attempts_reset "$key"
        dispatch_escalation_clear "$key" implementation
        tracker_add_comment "$key" "Implementation launched on branch \`$branch\` via make worktree-go (headless, AI: $spec). A worker is implementing the committed plan, building, and verifying; it will post results here. Nothing is pushed, merged, or deployed automatically — review the branch and merge when ready."
        tracker_transition "$key" in-progress && inflight_clear "$key"
    else
        log "  $key: worktree-go FAILED (see $logfile)"
        dispatch_escalate_once "$key" implementation "$spec" "Implementation trigger FAILED for $key during worktree provisioning. See the poller log $logfile on the build host. Left in Ready for Implementation; it will be retried on later polls (this message is posted once per failing configuration)."
        inflight_clear "$key"
    fi
}

# ----- watchdog (In Progress sweep) -----------------------------------------------------------
# watchdog_stalled_comment_after KEY LAUNCHED_EPOCH — true if the ticket already has an AI-footer
# comment created after LAUNCHED_EPOCH (case C: the worker finished and deliberately left the
# ticket In Progress with a blocker/failure report — restarting would likely just repeat it).
# Reuses jira.sh's own JIRA_AI_COMMENT_FOOTER (sourced into this process by intake-config.sh) as
# the fingerprint rather than adding a new tracker_* contract function for one adapter.
watchdog_stalled_comment_after() {
    # Two `local`s: $key must be assigned before it can expand in $ctx (SC2318 — in a single
    # `local`, the expansion would see the CALLER's key, which only works here by accident).
    local key="$1" launched="$2" created c_epoch found=0
    local ctx="$CONTEXT_DIR/$key.json"
    tracker_get_issue "$key" > "$ctx"
    while IFS= read -r created; do
        [ -n "$created" ] || continue
        c_epoch="$(date -d "$created" +%s 2>/dev/null || echo 0)"
        if [ "$c_epoch" -gt "$launched" ]; then found=1; break; fi
    done < <(jq -r --arg fp "$JIRA_AI_COMMENT_FOOTER" \
        '.fields.comment.comments[]? | select((.body // "") | contains($fp)) | .created' "$ctx")
    [ "$found" = "1" ]
}

# watchdog_escalate KEY MESSAGE — post a one-shot "needs a human" comment and mark the episode so
# the watchdog never repeats it on a later poll. Leaves the ticket In Progress (that status is
# already the workflow's "AI stuck" signal); moving it back to Ready for Implementation both
# re-queues it and (via dispatch_implementation's attempts_reset) clears the escalation.
watchdog_escalate() {
    local key="$1" message="$2"
    tracker_add_comment "$key" "Watchdog: $key $message"
    attempts_mark_escalated "$key"
}

# watchdog_check KEY — apply the stall taxonomy (see intake-poll.sh header) to one In Progress
# ticket. Only acts on tickets carrying an attempts record (case D: no record -> a human moved it
# to In Progress by hand -> ignore entirely).
watchdog_check() {
    local key="$1" attempts launched now age pid pidfile branch logfile next ctx spec provider model

    if ! attempts_exists "$key"; then
        log "  $key: no attempts record — not harness-dispatched, ignoring"
        return 0
    fi
    if attempts_escalated "$key"; then
        log "  $key: already escalated — skipping (move to Ready for Implementation to re-queue)"
        return 0
    fi

    read -r attempts launched < <(attempts_get "$key")
    now="$(date +%s)"; age=$((now - launched))
    if [ "$age" -lt "$JIRA_WATCHDOG_GRACE_SECONDS" ]; then
        log "  $key: within grace period (${age}s < ${JIRA_WATCHDOG_GRACE_SECONDS}s) — skip"
        return 0
    fi

    pidfile="$RUNNING_DIR/$key.pid"
    if [ -f "$pidfile" ]; then
        pid="$(cat "$pidfile" 2>/dev/null || true)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            log "  $key: worker pid $pid alive — healthy, skip"
            return 0
        fi
    fi

    # PID dead/missing past the grace period: case A (silent death) or C (reported blocker).
    if watchdog_stalled_comment_after "$key" "$launched"; then
        log "  $key: an AI-footer comment was posted after the last launch (case C) — escalating"
        watchdog_escalate "$key" "already reported back (a blocker/failure comment posted after its last launch) — automatic restart would likely repeat the same failure. Move back to *Ready for Implementation* to re-queue after addressing it."
        return 0
    fi

    if [ "$attempts" -ge "$JIRA_MAX_ATTEMPTS" ]; then
        log "  $key: attempts exhausted ($attempts/$JIRA_MAX_ATTEMPTS) — escalating"
        watchdog_escalate "$key" "stalled with no response ($attempts/$JIRA_MAX_ATTEMPTS attempts) and automatic retries are exhausted. Move back to *Ready for Implementation* to re-queue."
        return 0
    fi

    branch="$(existing_branch "$key")"
    if [ -z "$branch" ]; then
        log "  $key: no feature/$key-* branch found — cannot restart"
        watchdog_escalate "$key" "stalled, but no feature branch could be found to restart from. Needs manual investigation."
        return 0
    fi

    next=$((attempts + 1))
    if [ "$(running_count)" -ge "$JIRA_MAX_WORKTREES" ]; then
        log "  $key: at capacity ($JIRA_MAX_WORKTREES running) — deferring restart to a later poll"
        return 0
    fi
    if [ "$DRY_RUN" = "1" ]; then
        log "  [dry-run] would restart $key (attempt $next/$JIRA_MAX_ATTEMPTS)"
        return 0
    fi

    ctx="$CONTEXT_DIR/$key.json"
    tracker_get_issue "$key" > "$ctx"
    spec="$(resolve_ai_profile "$ctx" implementation)"
    provider="$(spec_provider "$spec")"
    model="$(spec_model "$spec")"

    # Same one-LM-Studio constraint as a fresh dispatch: don't restart a local-llm worker while
    # another local-llm worker is live — a later watchdog pass retries once the slot frees.
    if [ "$provider" = "local-llm" ] && local_llm_worker_live; then
        log "  $key: a local-llm implementation worker is already live — deferring restart"
        return 0
    fi

    if logfile="$(launch_implementation_worker "$key" "$branch" "$provider" "$model")"; then
        attempts_bump "$key"
        tracker_add_comment "$key" "Watchdog: relaunching the stalled implementation worker on branch \`$branch\` (attempt $next/$JIRA_MAX_ATTEMPTS) — the previous worker did not respond. It resumes in the existing worktree and will post results here when done."
    else
        log "  $key: restart FAILED (see $logfile)"
        watchdog_escalate "$key" "a restart attempt failed during worktree provisioning (see poller log $logfile on the build host)."
    fi
}

# process_watchdog — sweep every In Progress ticket. Reaps dead/hung worker slots unconditionally
# first (today reaping only happens while draining a non-empty implementation queue, so a hung
# worker otherwise isn't even killed until new Ready for Implementation work shows up).
process_watchdog() {
    local key count=0
    log "polling watchdog (In Progress)"
    reap_running
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        count=$((count+1))
        watchdog_check "$key"
    done < <(tracker_search in-progress)
    log "watchdog: $count ticket(s) checked"
}

process_queue() {
    local label="$1" queue="$2" handler="$3" gated="${4:-0}" key count=0 live
    log "polling $label queue"
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        if inflight_active "$key"; then log "  skip $key (in-flight)"; continue; fi
        # Concurrency cap (implementation only): stop dispatching once JIRA_MAX_WORKTREES workers
        # are already running. Remaining ready tickets stay queued for a later poll.
        if [ "$gated" = "1" ]; then
            live="$(running_count)"
            if [ "$live" -ge "$JIRA_MAX_WORKTREES" ]; then
                log "  $label at capacity ($live/$JIRA_MAX_WORKTREES running) — deferring $key and remaining ready tickets"
                break
            fi
        fi
        count=$((count+1))
        "$handler" "$key"
    done < <(tracker_search "$queue")
    log "$label: $count ticket(s) dispatched"
}

# ----- main ---------------------------------------------------------------------------
case "$POLL_MODE" in
    planning)       process_queue "planning"       planning       dispatch_planning ;;
    implementation) process_queue "implementation" implementation dispatch_implementation 1 ;;
    watchdog)       process_watchdog ;;
    both)
        process_queue "planning"       planning       dispatch_planning
        process_queue "implementation" implementation dispatch_implementation 1
        process_watchdog
        ;;
    *) die "invalid POLL_MODE: $POLL_MODE (planning|implementation|watchdog|both)" ;;
esac

log "poll complete"
