#!/bin/bash
# AI adapter: Claude Code CLI — see .ai/intake.config for selection (AI_PROVIDER=claude, default).
#
# Implements the ai_* contract used by the intake poller and worktree-go: ai_load_env,
# ai_run_planning, ai_run_implementation. This is a behavior-preserving extraction of what used to
# be run_claude_planning() in intake-poll.sh and the HEADLESS=1 launch block in worktree-go.sh —
# same invocations, now selectable behind the AI_PROVIDER seam and able to take a model override
# via AI_PLANNING_MODEL / AI_IMPLEMENTATION_MODEL (--model, appended only when set; empty means the
# claude CLI's own default, i.e. today's behavior unchanged).
#
# Unlike the tracker_*/project_* adapters, this file is NOT guarded against re-sourcing: a Jira
# ticket label can select a different provider than the previous ticket's within the same poller
# process (see intake-poll.sh's resolve_ai_profile/load_ai_provider), so re-sourcing must be able
# to redefine ai_run_planning/ai_run_implementation/ai_load_env back to this adapter's versions.
#
# The internal _ai_claude_*_impl functions (not part of the ai_* contract) are also reused by
# ai/local-llm.sh, which wraps them with a local proxy pointed at LM Studio instead of Anthropic's
# API — see local-llm.sh for why the same claude -p invocation shape works unmodified there.

# ai_load_env — the claude CLI must be on PATH.
_ai_claude_load_env_impl() {
    command -v "${CLAUDE_BIN:-claude}" >/dev/null 2>&1 \
        || { echo "ai/claude: '${CLAUDE_BIN:-claude}' not found on PATH" >&2; return 1; }
}

# ai_run_planning KEY BRANCH CTX DEC CWD — author/refine ticket $KEY's plan inside worktree $CWD.
# Reads CLAUDE_BIN / CLAUDE_FLAGS / CLAUDE_TIMEOUT / STATE_DIR (set by intake-poll.sh) and
# AI_PLANNING_MODEL (from .ai/intake.config / env override) as globals — matching this script's
# existing convention of sharing state across sourced files rather than threading every value
# through as a parameter.
_ai_claude_run_planning_impl() {
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
    # The context file ($ctx) and decision file ($dec) live under $REPO_ROOT/.intake — the
    # MAIN checkout, outside this worktree cwd — so the worker must be granted access to that dir
    # (acceptEdits alone keeps it sandboxed to cwd). Without this it cannot read the ticket or write
    # its decision, and the poller sees "no decision file" and leaves the ticket in-flight.
    ( cd "$cwd" && timeout "$CLAUDE_TIMEOUT" "$CLAUDE_BIN" -p "$prompt" --add-dir "$STATE_DIR" $CLAUDE_FLAGS $model_flag )
}

# ai_run_implementation LOGFILE PIDFILE — launch the claude CLI as a DETACHED headless worker
# implementing $TICKET's approved plan in $WORKTREE_DIR, appending --model when
# AI_IMPLEMENTATION_MODEL is set. Writes the worker's PID to PIDFILE — the poller's running-slot
# liveness check (kill -0) depends on this being the actual worker process, so the launch stays a
# plain nohup+exec with no extra wrapper layer in between. Reads WORKTREE_DIR / TICKET / CLAUDE_BIN
# / HEADLESS_CLAUDE_FLAGS as globals (set by worktree-go.sh), same convention as above.
_ai_claude_run_implementation_impl() {
    local logfile="$1" pidfile="$2" permission_profile settings_file perm_flags model_flag="" prompt
    permission_profile="$(project_permission_profile)"
    settings_file="${WORKTREE_DIR}/${permission_profile}"
    prompt="Headless JIRA-intake implementation for ticket ${TICKET:-<none>}. Read and follow .ai/prompts/worktree-bootstrap-auto.md exactly: implement the approved (ready) plan for this ticket, build, verify, and post a result summary to the ticket with ai-intake-harness/tracker-comment.sh. Do not push, merge, or deploy."

    if [ -f "$settings_file" ]; then
        perm_flags="--settings ${permission_profile} --permission-mode default"
    else
        echo "   WARNING: ${settings_file} not found — using --permission-mode plan (read-only) so nothing runs unsupervised."
        perm_flags="--permission-mode plan"
    fi
    [ -n "${AI_IMPLEMENTATION_MODEL:-}" ] && model_flag="--model $AI_IMPLEMENTATION_MODEL"

    # Detached so the poller (our caller) returns once provisioning is done; the worker runs on.
    # We capture the worker PID into the running-slot pid file. Because the wrapper `exec`s claude,
    # this PID *is* the worker, so the poller's `kill -0` liveness check reaps the slot on exit.
    ( cd "$WORKTREE_DIR" && nohup bash -c \
        "exec ${CLAUDE_BIN:-claude} -p \"\$1\" ${perm_flags} ${HEADLESS_CLAUDE_FLAGS:-} ${model_flag}" _ "$prompt" \
        >"$logfile" 2>&1 & echo "$!" > "$pidfile" )
}

ai_load_env()           { _ai_claude_load_env_impl "$@"; }
ai_run_planning()       { _ai_claude_run_planning_impl "$@"; }
ai_run_implementation() { _ai_claude_run_implementation_impl "$@"; }
