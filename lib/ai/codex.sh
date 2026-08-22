#!/bin/bash
# AI adapter: Codex CLI — see .ai/intake.config for selection (AI_PROVIDER=codex).
#
# Implements the ai_* contract: ai_load_env, ai_run_planning, ai_run_implementation. Targets
# OpenAI's official Codex CLI (binary `codex`, package codex-cli) via its non-interactive
# `codex exec` mode with agentic tool-use (file read/write, shell) — the direct analog to Claude
# Code CLI and Gemini CLI. Flags below were verified live against a real install (codex-cli
# 0.148.0: `codex --help`, `codex exec --help`, `codex login --help`, `codex doctor`) while
# drafting the ai-provider-install-prompt plan — not left as assumptions the way the DAV-2 plan
# had to leave Gemini's. Re-verify if the installed CLI's version differs meaningfully.
#
# Auth is materially different from claude.sh/gemini.sh: Codex CLI does not read an API key from
# the environment at invocation time. It persists a credential to ~/.codex/auth.json via either
# interactive `codex login` (ChatGPT OAuth, browser-based, NOT usable headless) or
# `codex login --with-api-key` (reads a key from stdin, e.g.
# `printenv OPENAI_API_KEY | codex login --with-api-key` — scriptable, run once out-of-band, no
# browser needed). `codex login status` reports the current state and is what ai_load_env checks,
# rather than an env var.
#
# Automation boundary (design-decisions.md #5): `-s workspace-write -a never` — sandboxed
# filesystem writes scoped to the workspace, network restricted by the sandbox itself (confirmed
# via `codex doctor`'s "restricted fs + restricted network" report on this machine), no
# interactive approval possible or needed. Unlike Gemini's adapter, this needs no project-supplied
# settings/profile file: Codex's sandbox is a fixed pair of CLI flags, not a project-authored tool
# allow/deny list, so there's nothing for a project adapter to configure. (The
# ai-provider-install-prompt plan originally sketched an optional project_codex_permission_profile
# hook mirroring Gemini's; this is a deliberate, disclosed deviation from that sketch because
# Codex's real config model doesn't have an equivalent — `-c/--config` overrides TOML key=value
# pairs directly on the command line, not an external file path.)
#
# Not guarded against re-sourcing — see ai/claude.sh's header comment for why (a per-ticket label
# can switch providers within one poller process).

# ai_load_env — the codex CLI must be on PATH, and it must already be logged in (`codex login` or
# `codex login --with-api-key`) — interactive OAuth login cannot run from an unattended cron
# dispatch, and there is no env-var auth path to fall back on for this CLI.
_ai_codex_load_env_impl() {
    command -v "${CODEX_BIN:-codex}" >/dev/null 2>&1 \
        || { echo "ai/codex: '${CODEX_BIN:-codex}' not found on PATH" >&2; return 1; }
    "${CODEX_BIN:-codex}" login status >/dev/null 2>&1 \
        || { echo "ai/codex: not logged in — run '${CODEX_BIN:-codex} login' (interactive ChatGPT auth) or 'printenv OPENAI_API_KEY | ${CODEX_BIN:-codex} login --with-api-key' (scriptable, no browser) once on this machine before selecting this provider" >&2; return 1; }
}

# ai_run_planning KEY BRANCH CTX DEC CWD — author/refine ticket $KEY's plan inside worktree $CWD.
# Reads CODEX_BIN / CODEX_FLAGS / CODEX_TIMEOUT / STATE_DIR (set by intake-poll.sh) and
# AI_PLANNING_MODEL (from .ai/intake.config / env override / per-ticket profile) as globals —
# matching lib/ai/claude.sh's existing convention.
_ai_codex_run_planning_impl() {
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
    [ -n "${AI_PLANNING_MODEL:-}" ] && model_flag="-m $AI_PLANNING_MODEL"
    # $STATE_DIR lives outside this worktree ($REPO_ROOT/.intake in the MAIN checkout) — same
    # reason claude.sh grants --add-dir; without it the worker can't reach $ctx/$dec. Options
    # precede the positional PROMPT, matching `codex exec`'s own documented usage line — codex's
    # top-level -p means --profile (a config profile name), NOT prompt, unlike claude/gemini's -p,
    # so the prompt here is deliberately positional-only, never behind -p.
    ( cd "$cwd" && timeout "$CODEX_TIMEOUT" "${CODEX_BIN:-codex}" exec \
        -s workspace-write -a never --add-dir "$STATE_DIR" ${CODEX_FLAGS:-} $model_flag "$prompt" )
}

# ai_run_implementation LOGFILE PIDFILE — launch the codex CLI as a DETACHED headless worker
# implementing $TICKET's approved plan in $WORKTREE_DIR. Mirrors claude.sh/gemini.sh's contract
# exactly: writes the worker's PID to PIDFILE (the poller's running-slot liveness check depends on
# this being the actual worker process, so the launch stays a plain nohup+exec with no extra
# wrapper layer). Reads WORKTREE_DIR / TICKET / CODEX_BIN / HEADLESS_CODEX_FLAGS as globals (set
# by worktree-go.sh).
_ai_codex_run_implementation_impl() {
    local logfile="$1" pidfile="$2" model_flag="" prompt
    prompt="Headless JIRA-intake implementation for ticket ${TICKET:-<none>}. Read and follow .ai/prompts/worktree-bootstrap-auto.md exactly: implement the approved (ready) plan for this ticket, build, verify, and post a result summary to the ticket with ai-intake-harness/tracker-comment.sh. Do not push, merge, or deploy."
    [ -n "${AI_IMPLEMENTATION_MODEL:-}" ] && model_flag="-m $AI_IMPLEMENTATION_MODEL"

    ( cd "$WORKTREE_DIR" && nohup bash -c \
        "exec ${CODEX_BIN:-codex} exec -s workspace-write -a never ${HEADLESS_CODEX_FLAGS:-} ${model_flag} \"\$1\"" _ "$prompt" \
        >"$logfile" 2>&1 & echo "$!" > "$pidfile" )
}

ai_load_env()           { _ai_codex_load_env_impl "$@"; }
ai_run_planning()       { _ai_codex_run_planning_impl "$@"; }
ai_run_implementation() { _ai_codex_run_implementation_impl "$@"; }
