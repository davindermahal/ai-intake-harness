#!/bin/bash
# AI adapter: Antigravity CLI — see .ai/intake.config for selection (AI_PROVIDER=antigravity).
# NOTE: the product is "Antigravity" but its binary is `agy`, not `antigravity` — deliberate, not
# a typo (see ANTIGRAVITY_BIN below).
#
# Implements the ai_* contract: ai_load_env, ai_run_planning, ai_run_implementation. Targets
# Google's Antigravity CLI (binary `agy`, v1.1.17 verified) — a one-shot non-interactive
# `-p`/`--print` mode with agentic tool-use, the direct analog to Claude Code CLI/Gemini
# CLI/Codex CLI. Flags below were verified live against a real install on this machine
# (`agy --help`), not left as assumptions.
#
# Auth, similar in spirit to codex.sh's finding: `agy --help` has no env-var-driven auth and no
# dedicated `login`/`whoami`/`status` subcommand either. It uses cached credentials from a prior
# interactive `agy` session on the machine (confirmed via product docs: headless mode requires
# signing in once interactively first; over SSH it prints a URL + one-time code instead).
# ai_load_env checks auth by running `agy models` — a lightweight, already-verified-live,
# network-backed call that lists available models and fails cleanly without valid credentials —
# there is no cheaper dedicated status command to use instead.
#
# Automation boundary (design-decisions.md #5): `--sandbox` ("run in a sandbox with terminal
# restrictions enabled") + `--dangerously-skip-permissions` (auto-approve all tool permission
# requests — required headless, there is no TTY to interactively approve). UNLIKE Codex's
# `-s workspace-write`, `--sandbox` here is a bare boolean with no documented breakdown of exactly
# what it restricts (filesystem/network/both) — this is a coarser, undisclosed-internals boundary,
# closer to Gemini's accepted gap than Codex's verified one. Treat this adapter as experimental
# until a real implementation-phase round-trip is run and its actual restrictions observed.
# `--mode accept-edits` mirrors Claude's own default CLAUDE_FLAGS value/vocabulary (both CLIs use
# the literal string "accept-edits"/"acceptEdits") for auto-accepting file-edit tool calls.
#
# Not guarded against re-sourcing — see ai/claude.sh's header comment for why (a per-ticket label
# can switch providers within one poller process).

# ai_load_env — the agy CLI must be on PATH, and it must already be logged in (a prior interactive
# `agy` session) — there is no env-var auth path and no non-interactive login flow other than the
# SSH device-code handshake, which still requires a human to complete it once.
_ai_antigravity_load_env_impl() {
    command -v "${ANTIGRAVITY_BIN:-agy}" >/dev/null 2>&1 \
        || { echo "ai/antigravity: '${ANTIGRAVITY_BIN:-agy}' not found on PATH" >&2; return 1; }
    "${ANTIGRAVITY_BIN:-agy}" models >/dev/null 2>&1 \
        || { echo "ai/antigravity: not logged in (or not reachable) — run an interactive '${ANTIGRAVITY_BIN:-agy}' session once on this machine to sign in (over SSH it prints an authorization URL + one-time code) before selecting this provider" >&2; return 1; }
}

# ai_run_planning KEY BRANCH CTX DEC CWD — author/refine ticket $KEY's plan inside worktree $CWD.
# Reads ANTIGRAVITY_BIN / ANTIGRAVITY_FLAGS / ANTIGRAVITY_TIMEOUT / STATE_DIR (set by
# intake-poll.sh) and AI_PLANNING_MODEL (from .ai/intake.config / env override / per-ticket
# profile) as globals — matching lib/ai/claude.sh's existing convention.
_ai_antigravity_run_planning_impl() {
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
    # reason claude.sh grants --add-dir (agy uses the identical flag name/shape).
    ( cd "$cwd" && timeout "$ANTIGRAVITY_TIMEOUT" "${ANTIGRAVITY_BIN:-agy}" -p "$prompt" \
        --add-dir "$STATE_DIR" --mode accept-edits ${ANTIGRAVITY_FLAGS:-} $model_flag )
}

# ai_run_implementation LOGFILE PIDFILE — launch the agy CLI as a DETACHED headless worker
# implementing $TICKET's approved plan in $WORKTREE_DIR. Mirrors claude.sh/gemini.sh/codex.sh's
# contract exactly: writes the worker's PID to PIDFILE (the poller's running-slot liveness check
# depends on this being the actual worker process, so the launch stays a plain nohup+exec with no
# extra wrapper layer). Reads WORKTREE_DIR / TICKET / ANTIGRAVITY_BIN / HEADLESS_ANTIGRAVITY_FLAGS
# as globals (set by worktree-go.sh).
_ai_antigravity_run_implementation_impl() {
    local logfile="$1" pidfile="$2" model_flag="" prompt
    prompt="Headless JIRA-intake implementation for ticket ${TICKET:-<none>}. Read and follow .ai/prompts/worktree-bootstrap-auto.md exactly: implement the approved (ready) plan for this ticket, build, verify, and post a result summary to the ticket with ai-intake-harness/tracker-comment.sh. Do not push, merge, or deploy."
    [ -n "${AI_IMPLEMENTATION_MODEL:-}" ] && model_flag="--model $AI_IMPLEMENTATION_MODEL"

    ( cd "$WORKTREE_DIR" && nohup bash -c \
        "exec ${ANTIGRAVITY_BIN:-agy} -p \"\$1\" --sandbox --dangerously-skip-permissions --mode accept-edits ${HEADLESS_ANTIGRAVITY_FLAGS:-} ${model_flag}" _ "$prompt" \
        >"$logfile" 2>&1 & echo "$!" > "$pidfile" )
}

ai_load_env()           { _ai_antigravity_load_env_impl "$@"; }
ai_run_planning()       { _ai_antigravity_run_planning_impl "$@"; }
ai_run_implementation() { _ai_antigravity_run_implementation_impl "$@"; }
