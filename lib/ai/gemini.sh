#!/bin/bash
# AI adapter: Gemini CLI — see .ai/intake.config for selection (AI_PROVIDER=gemini).
#
# Implements the ai_* contract: ai_load_env, ai_run_planning, ai_run_implementation. Targets
# Google's official Gemini CLI (`npm install -g @google/gemini-cli`, binary `gemini`) — the
# direct analog to the Claude Code CLI: a one-shot non-interactive prompt mode with agentic
# tool-use (file read/write, shell). Flags below follow the DAV-2 plan's documented assumptions
# about the Gemini CLI's interface (prompt/model/include-directories/sandbox/approval-mode/
# settings-file flags) — the plan's step 1 called for confirming these against a live
# `gemini --help`, but this build ran under a locked-down implementation-worker permission
# profile with no general shell access (only shellcheck/bash -n/git/tracker-comment allowed), so
# that live verification could not run here. Re-verify against the installed CLI's `--help`
# output before relying on this in a real deployment; if any flag name/shape differs, update the
# constants below — the adapter's *structure* (mirroring claude.sh) does not change.
#
# ai_run_implementation's automation boundary (design-decisions.md #5) is coarser-grained than
# Claude's: Gemini CLI has no per-command allow/deny settings.json equivalent, only --sandbox
# (execution isolation) + --approval-mode yolo (required headless — no TTY to interactively
# approve) + a project settings file's coreTools/excludeTools (tool-*category* restriction, not
# per-command patterns). This is an explicitly accepted gap (see DAV-2 plan's Key decisions) —
# the consumer project supplies the restriction via the OPTIONAL
# project_gemini_permission_profile contract function (mirrors project_permission_profile,
# Gemini's schema instead of Claude's). If the consumer hasn't implemented it,
# ai_run_implementation refuses to launch rather than running unrestricted.
#
# Not guarded against re-sourcing — see ai/claude.sh's header comment for why (a per-ticket
# label can switch providers within one poller process).

# ai_load_env — the gemini CLI must be on PATH, and headless auth must be configured (OAuth
# login is interactive-only and cannot run from an unattended cron dispatch).
_ai_gemini_load_env_impl() {
    command -v "${GEMINI_BIN:-gemini}" >/dev/null 2>&1 \
        || { echo "ai/gemini: '${GEMINI_BIN:-gemini}' not found on PATH" >&2; return 1; }
    [ -n "${GEMINI_API_KEY:-}" ] \
        || { echo "ai/gemini: GEMINI_API_KEY is not set — interactive OAuth login cannot run headless from the poller; set GEMINI_API_KEY (a Google AI Studio key) in the environment or .env" >&2; return 1; }
}

# ai_run_planning KEY BRANCH CTX DEC CWD — author/refine ticket $KEY's plan inside worktree $CWD.
# Reads GEMINI_BIN / GEMINI_FLAGS / GEMINI_TIMEOUT / STATE_DIR (set by intake-poll.sh) and
# AI_PLANNING_MODEL (from .ai/intake.config / env override / per-ticket profile) as globals —
# matching lib/ai/claude.sh's existing convention.
_ai_gemini_run_planning_impl() {
    local key="$1" branch="$2" ctx="$3" dec="$4" cwd="$5" prompt model_flag=""
    prompt="Ticket: $key  (phase: planning, branch: $branch)

You are the headless JIRA intake planning worker for THIS ONE ticket ($key). Do NOT act on any
other ticket. Do NOT call any Jira/Atlassian MCP tools and do NOT run git — the poller performs all
tracker I/O over REST and commits your plan. Your job: author files and emit a decision.

- Your working directory is a worktree of branch '$branch'. Author/refine the plan file here under
  .ai/plans/active/${key}-<slug>.md, and use exactly this branch in its **Branch**: line: $branch
- The ticket data (summary, status, description, comments) is JSON at: $ctx
- Follow the routine in: ai-intake-harness/prompts/intake-planning.md
- When finished, write your decision JSON to: $dec

Per project convention, the decision's 'comment' field MUST always contain a concise summary of
what you did (it is posted back to the ticket for the record)."
    [ -n "${AI_PLANNING_MODEL:-}" ] && model_flag="--model $AI_PLANNING_MODEL"
    # $STATE_DIR lives outside this worktree ($REPO_ROOT/.intake in the MAIN checkout) — same
    # reason claude.sh grants --add-dir; without it the worker can't reach $ctx/$dec.
    ( cd "$cwd" && timeout "$GEMINI_TIMEOUT" "${GEMINI_BIN:-gemini}" -p "$prompt" --include-directories "$STATE_DIR" ${GEMINI_FLAGS:-} $model_flag )
}

# ai_run_implementation LOGFILE PIDFILE — launch the gemini CLI as a DETACHED headless worker
# implementing $TICKET's approved plan in $WORKTREE_DIR. Mirrors claude.sh's
# _ai_claude_run_implementation_impl contract exactly: writes the worker's PID to PIDFILE (the
# poller's running-slot liveness check depends on this being the actual worker process, so the
# launch stays a plain nohup+exec with no extra wrapper layer). Reads WORKTREE_DIR / TICKET /
# GEMINI_BIN / HEADLESS_GEMINI_FLAGS as globals (set by worktree-go.sh).
_ai_gemini_run_implementation_impl() {
    local logfile="$1" pidfile="$2" settings_rel settings_file perm_flags model_flag="" prompt

    if command -v project_gemini_permission_profile >/dev/null 2>&1; then
        settings_rel="$(project_gemini_permission_profile)"
        settings_file="${WORKTREE_DIR}/${settings_rel}"
    fi

    if [ -n "${settings_file:-}" ] && [ -f "$settings_file" ]; then
        # --sandbox isolates *where* commands run; --approval-mode yolo is required headless
        # (no TTY to interactively approve). Neither restricts *which* tools are available —
        # the settings file's coreTools/excludeTools is the real boundary here. See header.
        perm_flags="--sandbox --approval-mode yolo --settings $settings_file"
    else
        echo "ai/gemini: no Gemini permission profile found (expected project_gemini_permission_profile to echo a path under \$WORKTREE_DIR to a coreTools/excludeTools settings file) — refusing to launch unrestricted. Implement project_gemini_permission_profile in your project adapter (see README's Project adapter contract), or use AI_PROVIDER=claude for implementation." >&2
        return 1
    fi

    prompt="Headless JIRA-intake implementation for ticket ${TICKET:-<none>}. Read and follow .ai/prompts/worktree-bootstrap-auto.md exactly: implement the approved (ready) plan for this ticket, build, verify, and post a result summary to the ticket with ai-intake-harness/tracker-comment.sh. Do not push, merge, or deploy."
    [ -n "${AI_IMPLEMENTATION_MODEL:-}" ] && model_flag="--model $AI_IMPLEMENTATION_MODEL"

    ( cd "$WORKTREE_DIR" && nohup bash -c \
        "exec ${GEMINI_BIN:-gemini} -p \"\$1\" ${perm_flags} ${HEADLESS_GEMINI_FLAGS:-} ${model_flag}" _ "$prompt" \
        >"$logfile" 2>&1 & echo "$!" > "$pidfile" )
}

ai_load_env()           { _ai_gemini_load_env_impl "$@"; }
ai_run_planning()       { _ai_gemini_run_planning_impl "$@"; }
ai_run_implementation() { _ai_gemini_run_implementation_impl "$@"; }
