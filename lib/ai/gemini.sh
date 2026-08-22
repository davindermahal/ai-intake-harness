#!/bin/bash
# AI adapter: Gemini CLI — see .ai/intake.config for selection (AI_PROVIDER=gemini).
#
# Implements the ai_* contract: ai_load_env, ai_run_planning, ai_run_implementation. Targets
# Google's official Gemini CLI (`npm install -g @google/gemini-cli`, binary `gemini`) — the
# direct analog to the Claude Code CLI: a one-shot non-interactive prompt mode with agentic
# tool-use (file read/write, shell).
#
# Flags below are live-verified against an installed Gemini CLI 0.56.0 (`gemini --help`), not
# just the DAV-2 plan's original guesses. Two of those guesses were wrong and are fixed here:
#   - `--settings <path>` is NOT a real flag (confirmed: `Unknown argument: settings`, exit 1).
#     Gemini instead auto-discovers `<cwd>/.gemini/settings.json` with no flag at all (confirmed:
#     invalid JSON there fails at startup, valid JSON loads silently) — so this adapter now `cd`s
#     into the worktree (already did, for other reasons) and just makes sure the file exists at
#     exactly that path, passing no settings flag.
#   - `--approval-mode yolo` is silently downgraded to `default` (interactive) when the CWD isn't
#     a Gemini "trusted" folder — which a freshly created worktree never is (confirmed via the
#     CLI's own "Approval mode overridden to default because the current folder is not trusted"
#     message). Under this function's detached nohup launch there's no TTY to satisfy that
#     interactive prompt, so this silently hangs the worker instead of erroring. Fixed by adding
#     `--skip-trust` alongside `--approval-mode yolo`.
# `-p`, `--model`, `--include-directories` (used by ai_run_planning) and `--sandbox` all matched
# the original assumption and needed no change.
#
# ai_run_implementation's automation boundary (design-decisions.md #5) is coarser-grained than
# Claude's: Gemini CLI has no per-command allow/deny settings.json equivalent, only --sandbox
# (execution isolation) + --approval-mode yolo + --skip-trust (both required headless — no TTY to
# interactively approve or confirm trust) + a project settings file's coreTools/excludeTools
# (tool-*category* restriction, not per-command patterns). This is an explicitly accepted gap (see
# DAV-2 plan's Key decisions) — the consumer project supplies the restriction via the OPTIONAL
# project_gemini_permission_profile contract function (mirrors project_permission_profile, but
# MUST echo exactly `.gemini/settings.json` — Gemini has no flag to point elsewhere, unlike
# Claude's arbitrary-named `--settings <path>`). If the consumer hasn't implemented it,
# ai_run_implementation refuses to launch rather than running unrestricted.
#
# Not guarded against re-sourcing — see ai/claude.sh's header comment for why (a per-ticket
# label can switch providers within one poller process).

# ai_load_env — the gemini CLI must be on PATH, and headless auth must be configured (interactive
# "Sign in with Google" OAuth cannot run from an unattended cron dispatch). Per Gemini CLI's own
# docs, headless mode accepts either an AI Studio key (GEMINI_API_KEY) or Vertex AI / Gemini Code
# Assist auth (GOOGLE_CLOUD_PROJECT, falling back to GOOGLE_CLOUD_PROJECT_ID, plus
# GOOGLE_CLOUD_LOCATION — backed by ADC/`gcloud auth application-default login`, a service-account
# key via GOOGLE_APPLICATION_CREDENTIALS, or GOOGLE_API_KEY). This only checks presence of one of
# those two var pairs, same as it never validated GEMINI_API_KEY is a live key either — actually
# authenticating the Vertex path (ADC/service-account/API key) is the user's/host's responsibility.
_ai_gemini_load_env_impl() {
    local project="${GOOGLE_CLOUD_PROJECT:-${GOOGLE_CLOUD_PROJECT_ID:-}}"
    command -v "${GEMINI_BIN:-gemini}" >/dev/null 2>&1 \
        || { echo "ai/gemini: '${GEMINI_BIN:-gemini}' not found on PATH" >&2; return 1; }
    if [ -n "${GEMINI_API_KEY:-}" ]; then
        return 0
    fi
    if [ -n "$project" ] && [ -n "${GOOGLE_CLOUD_LOCATION:-}" ]; then
        return 0
    fi
    echo "ai/gemini: no headless auth configured — interactive OAuth login cannot run headless from the poller; set EITHER GEMINI_API_KEY (a Google AI Studio key) OR both GOOGLE_CLOUD_PROJECT (or GOOGLE_CLOUD_PROJECT_ID) and GOOGLE_CLOUD_LOCATION (Vertex AI / Gemini Code Assist, backed by ADC / GOOGLE_APPLICATION_CREDENTIALS / GOOGLE_API_KEY) as real host environment variables, e.g. in scripts/intake-cron.sh (see README.md \"Quickstart\" step 6) — .env/.env.local are NOT read for these vars, only JIRA_* is" >&2
    return 1
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

    if [ -n "${settings_rel:-}" ] && [ "$settings_rel" != ".gemini/settings.json" ]; then
        # Gemini has no flag to point at an arbitrary settings path — it only ever auto-discovers
        # <cwd>/.gemini/settings.json (confirmed live; see header). Unlike Claude's --settings
        # <path>, a project adapter can't name this file anything else.
        echo "ai/gemini: project_gemini_permission_profile echoed '$settings_rel', but Gemini only auto-discovers a settings file at exactly .gemini/settings.json (no flag exists to point elsewhere) — refusing to launch unrestricted. Fix project_gemini_permission_profile in your project adapter to echo '.gemini/settings.json'." >&2
        return 1
    fi

    if [ -n "${settings_file:-}" ] && [ -f "$settings_file" ]; then
        # --sandbox isolates *where* commands run; --approval-mode yolo is required headless (no
        # TTY to interactively approve); --skip-trust is required alongside it — without it, an
        # untrusted CWD (every fresh worktree) silently downgrades yolo mode back to interactive
        # and hangs forever with no TTY to satisfy it (confirmed live; see header). None of these
        # three restrict *which* tools are available — the settings file's coreTools/excludeTools,
        # auto-loaded from $WORKTREE_DIR/.gemini/settings.json with no flag, is the real boundary.
        perm_flags="--sandbox --approval-mode yolo --skip-trust"
    else
        echo "ai/gemini: no Gemini permission profile found (expected project_gemini_permission_profile to echo '.gemini/settings.json', present under \$WORKTREE_DIR, with a coreTools/excludeTools settings file) — refusing to launch unrestricted. Implement project_gemini_permission_profile in your project adapter (see README's Project adapter contract), or use AI_PROVIDER=claude for implementation." >&2
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
