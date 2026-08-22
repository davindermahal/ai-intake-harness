#!/bin/bash
# One-time setup helper, run after vendoring this harness into a consumer repo via:
#   git subtree add --prefix=ai-intake-harness https://github.com/davindermahal/ai-intake-harness.git main --squash
#
# From the consumer repo root:
#   ai-intake-harness/install.sh
#
# Does eight things:
#   1. Sets up .env.local (repo root) if it doesn't already exist: interactively prompts for
#      JIRA_SITE_URL and either an API token or (if you don't have one) offers to set up the
#      browser-cookie3 venv fallback on the spot — when run at a real terminal. Piped/scripted/CI
#      runs (no TTY) fall back to copying .env.local.dist and printing instructions instead, so
#      nothing hangs waiting on input.
#   2. Sets up .ai/intake.config the same way: interactively prompts for TRACKER,
#      TRACKER_PROJECT_KEY, (for TRACKER=jira-tags) TRACKER_APP_TAG, and the default AI provider
#      at a real terminal; otherwise just prints what to fill in.
#   3. If .ai/intake.config resolves to AI_PROVIDER=gemini (from the wizard above, or a pre-existing
#      config — checked either way, so a later hand-edit + re-run picks this up too): scaffolds a
#      starter .gemini/settings.json permission profile if one doesn't exist, and appends the
#      boilerplate project_gemini_permission_profile function to the project adapter file if that
#      file already exists and doesn't define it yet — see README.md step 7.
#   4. Scaffolds scripts/intake-cron.sh (gitignored) from a template if it doesn't already exist —
#      the cron wrapper that holds host-specific paths/credentials, per README.md "Quickstart"
#      step 6. You still need to edit it (HOME, ANTHROPIC_API_KEY source).
#   5. Prints the crontab line to add for the poller, with the correct absolute repo path baked in,
#      and (pass --install-cron) installs it into your crontab directly.
#   6. Tests that the harness can reach Jira with whatever's currently in .env.local — skipped
#      (with instructions) if it still looks like the unfilled template. Re-run this script (or
#      pass --test-only) after filling in .env.local to run just the connectivity check.
#   7. Prints a "Config health check" summary at the end (report-only — doesn't affect this run's
#      exit code) — the same audit as --verify below, so even a first-time install sees where it
#      stands. See --verify for what's actually checked.
#   8. Pass --verify on its own for a standalone, non-destructive audit (skips steps 1-6 entirely):
#      checks .env.local, .ai/intake.config's keys, the configured AI provider and tracker adapter
#      (including, for TRACKER=jira/jira-tags, a LIVE check that the abstract-state -> Jira-status
#      mapping actually matches the target project's real workflow), the project adapter's
#      contract-function completeness, permission profile files, scripts/intake-cron.sh, the
#      crontab entry, and Makefile targets — printed as [OK]/[MISSING]/[WARN] lines, non-zero exit
#      if anything needs attention. Run this any time, especially right after `git subtree pull`,
#      to see what a harness update now expects that your install doesn't have yet. Add --fix
#      (requires --verify) to have it scaffold the subset that's safely automatable (net-new files
#      only — see _run_verify's header comment for exactly what --fix will and won't touch).
#
# Auth: an API token (JIRA_INTAKE_EMAIL + JIRA_INTAKE_API_TOKEN) if you have one, otherwise a
# browser session cookie extracted from a local Chrome/Firefox login — see .env.local.dist and
# .ai/plans/completed/jira-cookie-auth-fallback.md. Pass --test-cookie instead of --test-only to
# specifically verify the cookie path works, regardless of what's currently in .env.local (useful
# even when a valid token is already configured — see that plan's decision #6). The cookie path
# needs the browser_cookie3 python package; pass --install-browser-cookie3 to have this script set
# it up for you in a dedicated venv (~/.venvs/browser-cookie3) instead of installing it system-wide
# — see lib/tracker/jira-cookie.sh's _jira_cookie_python for how the harness finds it afterward.
#
# REPO_ROOT defaults to the consumer repo root (one level above this harness's own directory, per
# the git-subtree layout above). Pass an explicit path as the first argument to override — e.g.
# `./install.sh .` when running this from within a standalone checkout of the harness itself
# (self-testing, no subtree involved).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TEST_ONLY=0
TEST_COOKIE=0
INSTALL_CRON=0
INSTALL_BROWSER_COOKIE3=0
VERIFY=0
FIX=0
REPO_ROOT_ARG=""
for arg in "$@"; do
    case "$arg" in
        --test-only) TEST_ONLY=1 ;;
        --test-cookie) TEST_ONLY=1; TEST_COOKIE=1 ;;
        --install-cron) INSTALL_CRON=1 ;;
        --install-browser-cookie3) INSTALL_BROWSER_COOKIE3=1 ;;
        --verify) VERIFY=1 ;;
        --fix) FIX=1 ;;
        *) REPO_ROOT_ARG="$arg" ;;
    esac
done
if [ "$FIX" -eq 1 ] && [ "$VERIFY" -eq 0 ]; then
    echo "FAILED: --fix requires --verify (it only applies fixes found by the audit)." >&2
    exit 1
fi
REPO_ROOT="$(cd "${REPO_ROOT_ARG:-$SCRIPT_DIR/..}" && pwd)"

ENV_LOCAL="$REPO_ROOT/.env.local"
ENV_DIST="$SCRIPT_DIR/.env.local.dist"
INTAKE_CONFIG="$REPO_ROOT/.ai/intake.config"
CRON_WRAPPER="$REPO_ROOT/scripts/intake-cron.sh"
CRON_LINE="*/2 * * * * $REPO_ROOT/scripts/intake-cron.sh >> $REPO_ROOT/.intake/poll.log 2>&1"
GEMINI_SETTINGS="$REPO_ROOT/.gemini/settings.json"

# shellcheck source=lib/tracker/jira-common.sh
. "$SCRIPT_DIR/lib/tracker/jira-common.sh"   # for JIRA_COOKIE_VENV, shared with jira-cookie.sh

# _install_browser_cookie3_venv — creates JIRA_COOKIE_VENV and installs browser_cookie3 into it,
# unless the plain python3 on PATH already has it. Shared by --install-browser-cookie3 and the
# interactive .env.local wizard below.
_install_browser_cookie3_venv() {
    command -v python3 >/dev/null 2>&1 || {
        echo "FAILED: no 'python3' command found on this machine." >&2
        return 1
    }
    if python3 -c "import browser_cookie3" >/dev/null 2>&1; then
        echo "==> browser_cookie3 is already importable by the plain 'python3' on PATH — nothing to do."
        return 0
    fi
    echo "==> Creating a venv at $JIRA_COOKIE_VENV and installing browser_cookie3 into it ..."
    python3 -m venv "$JIRA_COOKIE_VENV"
    "$JIRA_COOKIE_VENV/bin/pip" install --upgrade pip >/dev/null
    "$JIRA_COOKIE_VENV/bin/pip" install browser_cookie3
    echo "==> Installed. The harness picks this up automatically (see"
    echo "    lib/tracker/jira-cookie.sh's _jira_cookie_python) — no PATH changes needed."
}

# _prompt_required PROMPT VAR_NAME — reads a non-empty value into VAR_NAME, re-prompting until one
# is given. Internal helper for the interactive wizards below.
_prompt_required() {
    local prompt="$1" __var="$2" value
    while true; do
        read -r -p "$prompt" value
        [ -n "$value" ] && { printf -v "$__var" '%s' "$value"; return 0; }
        echo "    Required — try again."
    done
}

# _prompt_env_local — interactively builds .env.local: Jira site URL, then either an API token or
# (if none) an offer to set up the browser-cookie3 venv on the spot. Only called when stdin is a
# real terminal (see the TEST_ONLY block below) — never in scripted/CI runs.
_prompt_env_local() {
    local site_url email="" token="" has_token setup_venv
    echo "==> Let's set up $ENV_LOCAL."
    _prompt_required "    Jira site URL (e.g. https://your-site.atlassian.net): " site_url

    read -r -p "    Do you have a Jira API token? [y/N] " has_token
    if [[ "$has_token" =~ ^[Yy] ]]; then
        echo "    Get one at https://id.atlassian.com/manage-profile/security/api-tokens if needed."
        _prompt_required "    Jira account email: " email
        while [ -z "$token" ]; do
            read -r -s -p "    Jira API token (hidden): " token
            echo
            [ -n "$token" ] || echo "    Required — try again."
        done
    else
        echo "    OK — leaving JIRA_INTAKE_EMAIL/JIRA_INTAKE_API_TOKEN blank. The harness will fall"
        echo "    back to a browser session cookie instead (needs python3 + browser_cookie3, and a"
        echo "    logged-in Jira session in your browser here — see README.md \"Quickstart\" step 2)."
        read -r -p "    Set up browser_cookie3 now in a dedicated venv ($JIRA_COOKIE_VENV)? [Y/n] " setup_venv
        if [[ ! "$setup_venv" =~ ^[Nn] ]]; then
            _install_browser_cookie3_venv || echo "    (continuing anyway — retry later with --install-browser-cookie3)"
        fi
    fi

    {
        echo "JIRA_SITE_URL=$site_url"
        echo
        echo "JIRA_INTAKE_EMAIL=$email"
        echo "JIRA_INTAKE_API_TOKEN=$token"
    } > "$ENV_LOCAL"
    echo "==> Wrote $ENV_LOCAL."
}

# _validate_ai_provider PROVIDER — sources lib/ai/<PROVIDER>.sh and calls its ai_load_env right
# away, printing pass/fail. A failure is a warning, not a hard stop — the CLI might get installed
# or logged in later. Mirrors the "catch it now, not on the first real ticket" pattern install.sh
# already applies to the cookie-auth fallback (_install_browser_cookie3_venv /
# jira_cookie_available).
_validate_ai_provider() {
    local provider="$1" adapter="$SCRIPT_DIR/lib/ai/$1.sh"
    if [ ! -f "$adapter" ]; then
        echo "    WARNING: no adapter at $adapter for provider '$provider' — skipping validation."
        return 0
    fi
    # shellcheck source=/dev/null
    . "$adapter"
    if ai_load_env; then
        echo "    OK — $provider looks ready to use."
    else
        echo "    (not a hard stop — fix this before any ticket gets routed to $provider, then re-run"
        echo "    '$SCRIPT_DIR/install.sh --test-only' or just try a real ticket once it's fixed.)"
    fi
}

# _ai_provider_ready PROVIDER — boolean sibling of _validate_ai_provider: does lib/ai/<PROVIDER>.sh
# exist and does its ai_load_env pass? Silent (no output either way) and runs in a subshell so it
# never pollutes the calling shell's functions with whichever provider it just checked — used by
# _run_verify, which wants a clean [OK]/[WARN] line rather than this function's own prose.
_ai_provider_ready() {
    local provider="$1" adapter="$SCRIPT_DIR/lib/ai/$1.sh"
    [ -f "$adapter" ] || return 1
    # shellcheck source=/dev/null
    ( . "$adapter"; ai_load_env ) >/dev/null 2>&1
}

# _intake_config_value KEY [DEFAULT] — echoes KEY's value from $INTAKE_CONFIG (first uncommented
# match, trailing whitespace/inline comment stripped), or DEFAULT (default: "") if the key isn't
# set or the file doesn't exist yet. Shared by every scaffold/verify check below that needs one
# specific key rather than the whole file — one sed pattern instead of each call site repeating it.
_intake_config_value() {
    local key="$1" default="${2:-}" value
    value="$(sed -n "s/^${key}=\([^ 	#]*\).*/\1/p" "$INTAKE_CONFIG" 2>/dev/null | head -1)"
    printf '%s' "${value:-$default}"
}

# _scaffold_gemini_permission_profile — when AI_PROVIDER=gemini, ai_run_implementation
# (lib/ai/gemini.sh) refuses to launch unless the consuming project both (a) has a
# .gemini/settings.json file present under the worktree, and (b) implements
# project_gemini_permission_profile in its project adapter to echo that fixed path — see
# README.md "Project adapter contract" and step 7. Part (a) is generic enough to scaffold safely
# here (same spirit as the CRON_WRAPPER template below); part (b) is one fixed boilerplate line
# with no project-specific variation (Gemini only ever auto-discovers that one filename, unlike
# Claude's arbitrary --settings <path>), so it's safe to auto-append to the project adapter file
# too, if one already exists. Called unconditionally near the end of the main flow whenever
# .ai/intake.config resolves to AI_PROVIDER=gemini — safe to re-run, everything here is guarded.
_scaffold_gemini_permission_profile() {
    if [ -f "$GEMINI_SETTINGS" ]; then
        echo "==> $GEMINI_SETTINGS already exists — leaving it alone."
    else
        mkdir -p "$(dirname "$GEMINI_SETTINGS")"
        cat > "$GEMINI_SETTINGS" <<'EOF'
{
  "excludeTools": [
    "web_fetch",
    "google_web_search"
  ]
}
EOF
        echo "==> Created $GEMINI_SETTINGS — a starter permission profile."
        echo "    Gemini's coreTools/excludeTools schema is tool-CATEGORY-level only (no equivalent"
        echo "    of denying 'git push' specifically while allowing other shell commands — see"
        echo "    README.md step 7); the real automation boundary is --sandbox, applied unconditionally"
        echo "    by lib/ai/gemini.sh. This starter just excludes the two external-network tools"
        echo "    (web_fetch, google_web_search) that a code-implementation worker shouldn't need."
        echo "    Review it against your stack — e.g. add coreTools to scope down further — before"
        echo "    relying on it."
    fi

    local adapter adapter_file snippet
    adapter="$(_intake_config_value PROJECT_ADAPTER symfony-docker)"
    adapter_file="$REPO_ROOT/scripts/lib/project/$adapter.sh"
    snippet='project_gemini_permission_profile() { echo ".gemini/settings.json"; }'

    if [ -f "$adapter_file" ]; then
        if grep -q 'project_gemini_permission_profile' "$adapter_file"; then
            echo "==> $adapter_file already defines project_gemini_permission_profile — leaving it alone."
        else
            {
                echo
                echo "# ai-intake-harness: required for AI_PROVIDER=gemini — echoes the fixed Gemini"
                echo "# settings path (see ai-intake-harness/lib/ai/gemini.sh)."
                echo "$snippet"
            } >> "$adapter_file"
            echo "==> Appended project_gemini_permission_profile to $adapter_file."
        fi
    else
        echo "==> $adapter_file doesn't exist yet (PROJECT_ADAPTER='$adapter') — once you write it"
        echo "    (README.md \"Write a project adapter for your stack\"), add:"
        echo "      $snippet"
    fi
}

# _scaffold_cron_wrapper — creates $CRON_WRAPPER from the template, unconditionally (callers check
# [ -f "$CRON_WRAPPER" ] first — same "leave it alone if it exists" convention as every other
# scaffold in this file). Factored out of the main flow so both the normal install flow and
# `install.sh --verify --fix` can create it without duplicating the heredoc.
_scaffold_cron_wrapper() {
    mkdir -p "$REPO_ROOT/scripts"
    cat > "$CRON_WRAPPER" <<EOF
#!/bin/bash
# Cron wrapper (consumer-created, gitignored; holds host-specific paths/credentials — see
# README.md "Quickstart" step 6). EDIT ANTHROPIC_API_KEY below before relying on this.
export HOME=$HOME
export PATH="\$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"   # claude + make + jq + docker
export ANTHROPIC_API_KEY="\$(cat "\$HOME/.secrets/anthropic_key")"   # or CLAUDE_CODE_OAUTH_TOKEN
# export GEMINI_API_KEY="\$(cat "\$HOME/.secrets/gemini_key")"   # only if AI_PROVIDER=gemini — a
#   real host env var, same as above; .env/.env.local are NOT read for this one, only JIRA_* is
cd $REPO_ROOT
exec /usr/bin/flock -n .intake/poll.lock bash ai-intake-harness/intake-poll.sh
EOF
    chmod +x "$CRON_WRAPPER"
    echo "==> Created $CRON_WRAPPER from template — edit it now:"
    echo "    fix the ANTHROPIC_API_KEY line (path to your key, or use CLAUDE_CODE_OAUTH_TOKEN"
    echo "    instead), uncomment+fix GEMINI_API_KEY too if AI_PROVIDER=gemini, and"
    echo "    double-check PATH covers claude/make/jq/docker on this host."
}

# _known_ai_providers — echoes every selectable AI_PROVIDER value: one line per lib/ai/<name>.sh in
# this harness. Discovered, not hardcoded, so a newly added adapter needs no edit here.
_known_ai_providers() {
    local f
    for f in "$SCRIPT_DIR"/lib/ai/*.sh; do
        basename "$f" .sh
    done
}

# _known_trackers — echoes every selectable TRACKER value: one line per lib/tracker/<name>.sh,
# excluding jira-common.sh/jira-cookie.sh (shared REST/auth plumbing sourced BY the Jira adapters,
# never selected directly via TRACKER — see jira-common.sh's own header comment).
_known_trackers() {
    local f name
    for f in "$SCRIPT_DIR"/lib/tracker/*.sh; do
        name="$(basename "$f" .sh)"
        case "$name" in
            jira-common|jira-cookie) ;;
            *) printf '%s\n' "$name" ;;
        esac
    done
}

# _v_ok / _v_missing / _v_warn — the three report lines _run_verify's category checks print.
# _v_missing/_v_warn also increment $_VERIFY_ISSUES (reset to 0 at the top of _run_verify, read
# back as its return code) — a global counter rather than a function-local one so these can stay
# ordinary top-level functions instead of needing to be redefined inside _run_verify's own body.
_VERIFY_ISSUES=0
_v_ok()      { echo "  [OK]      $1"; }
_v_missing() { echo "  [MISSING] $1"; _VERIFY_ISSUES=$((_VERIFY_ISSUES + 1)); }
_v_warn()    { echo "  [WARN]    $1"; _VERIFY_ISSUES=$((_VERIFY_ISSUES + 1)); }

# _run_verify — the --verify audit engine: a non-destructive, mostly-local checklist of everything
# this harness currently expects in $REPO_ROOT, printed as [OK]/[MISSING]/[WARN] lines in the same
# order as the README's Quickstart steps. Returns the number of MISSING+WARN findings (0 = clean) —
# used as --verify's own exit code, and as the trigger for --fix (see the --verify branch below).
# Every check here is local-only EXCEPT the tracker-adapter category's live native-status
# sub-check, which genuinely needs to ask Jira what statuses the target project's workflow has —
# see that check's own comment for why it's the one deliberate exception.
#
# --fix (only meaningful alongside --verify) applies exactly three kinds of finding, and nothing
# else: scaffolds $GEMINI_SETTINGS if AI_PROVIDER=gemini and it's missing, appends
# project_gemini_permission_profile to the project adapter file if that file exists and lacks it
# (both via the existing _scaffold_gemini_permission_profile), and scaffolds $CRON_WRAPPER if it's
# wholly absent (via _scaffold_cron_wrapper). It never edits a file that already exists with
# different content, and never touches the live crontab or the consumer's Makefile — those two
# always stay report-only, pointing at --install-cron and README step 5 respectively.
_run_verify() {
    _VERIFY_ISSUES=0
    local tracker ai_provider project_key app_tag adapter adapter_path adapter_file

    echo "==> Verifying $REPO_ROOT against what this harness currently expects:"

    # --- .env.local / .env ----------------------------------------------------------------
    if [ ! -f "$ENV_LOCAL" ] && [ ! -f "$REPO_ROOT/.env" ]; then
        _v_missing "No .env.local — run install.sh to create one (README.md \"Quickstart\" step 2)."
    elif grep -q '^JIRA_SITE_URL=https://your-site.atlassian.net$' "$ENV_LOCAL" 2>/dev/null; then
        _v_warn "$ENV_LOCAL still has placeholder values (README.md \"Quickstart\" step 2)."
    else
        _v_ok "$ENV_LOCAL configured."
    fi

    # --- .ai/intake.config ------------------------------------------------------------------
    if [ ! -f "$INTAKE_CONFIG" ]; then
        _v_missing "No .ai/intake.config — run install.sh to create one (README.md \"Quickstart\" step 3)."
        echo "  (skipping the remaining checks — they all read .ai/intake.config)"
        return "$_VERIFY_ISSUES"
    fi

    local keys="TRACKER TRACKER_PROJECT_KEY TRACKER_APP_TAG TRACKER_GATE_COMMENTS PROJECT_ADAPTER PROJECT_DB_PREFIX PLAN_WORKTREE_PREFIX AI_PROVIDER AI_PLANNING_MODEL AI_IMPLEMENTATION_MODEL AI_LOCAL_LLM_BASE_URL AI_LOCAL_LLM_MODEL AI_LOCAL_LLM_TIMEOUT"
    local total=0 set_count=0 k
    for k in $keys; do
        total=$((total + 1))
        grep -qE "^${k}=" "$INTAKE_CONFIG" && set_count=$((set_count + 1))
    done
    _v_ok "$set_count of $total intake.config keys set explicitly (defaults apply to the rest)."

    tracker="$(_intake_config_value TRACKER jira)"
    project_key="$(_intake_config_value TRACKER_PROJECT_KEY PROJ)"
    app_tag="$(_intake_config_value TRACKER_APP_TAG)"
    ai_provider="$(_intake_config_value AI_PROVIDER claude)"

    if [ "$tracker" = "jira-tags" ] && [ -z "$app_tag" ]; then
        _v_missing "TRACKER=jira-tags requires TRACKER_APP_TAG (README.md \"Quickstart\" step 3)."
    fi

    # --- AI provider --------------------------------------------------------------------
    # Captured to a variable before grepping (not piped live from the function): piping a
    # multi-line producer straight into `grep -q` races pipefail — grep exits the instant it
    # finds a match, SIGPIPEs the still-writing producer, and pipefail then reports that SIGPIPE
    # (a non-zero exit from the *other* side of the pipe) as the pipeline's own failure, even
    # though grep matched. Capturing first sidesteps the race entirely.
    if ! printf '%s\n' "$(_known_ai_providers)" | grep -qxF "$ai_provider"; then
        _v_missing "AI_PROVIDER='$ai_provider' doesn't match any lib/ai/*.sh adapter."
    elif AI_LOCAL_LLM_BASE_URL="$(_intake_config_value AI_LOCAL_LLM_BASE_URL http://localhost:1234/v1)" _ai_provider_ready "$ai_provider"; then
        _v_ok "AI_PROVIDER=$ai_provider looks ready to use."
    else
        _v_warn "AI_PROVIDER=$ai_provider isn't ready yet — run install.sh --test-only, or see lib/ai/$ai_provider.sh."
    fi

    # --- Tracker adapter, plus the live native-status mapping check ------------------------
    # Same capture-first reasoning as the AI-provider check above.
    if ! printf '%s\n' "$(_known_trackers)" | grep -qxF "$tracker"; then
        _v_missing "TRACKER='$tracker' doesn't match any lib/tracker/*.sh adapter."
    else
        _v_ok "TRACKER=$tracker is a known adapter."
        case "$tracker" in
            jira|jira-tags)
                # jira_common_load_env uses "${JIRA_SITE_URL:?msg}" — in a non-interactive shell,
                # an UNSET var there is fatal to the whole script (bash's own ${:?} behavior,
                # documented as bypassing errexit/if-guards entirely — it's not a normal non-zero
                # return), which would otherwise abort this whole --verify run the moment a
                # consumer has no .env.local at all yet. Run load+query together in ONE subshell
                # so that fatal path only kills the subshell; its result reaches us as ordinary
                # captured stdout, so a missing/bad Jira config degrades to the WARN below instead
                # of taking the rest of _run_verify down with it.
                local real_statuses missing_list=""
                real_statuses="$( (jira_common_load_env "$REPO_ROOT" >/dev/null 2>&1 && jira_project_statuses "$project_key") 2>/dev/null || true)"
                if [ -z "$real_statuses" ]; then
                    _v_warn "Skipping the Jira status-mapping check — Jira isn't reachable yet (see install.sh --test-only)."
                elif [ "$tracker" = "jira" ]; then
                    local s
                    for s in "Ready for Planning" "Needs Author Input" "Plan Review" "Ready for Implementation" "In Progress" "Ready for Verification" "Done"; do
                        printf '%s\n' "$real_statuses" | grep -qxF "$s" || missing_list="$missing_list, $s"
                    done
                    if [ -n "$missing_list" ]; then
                        _v_missing "This Jira project's workflow has no status(es) named:${missing_list#,} — lib/tracker/jira.sh's abstract->status mapping is fixed (not configurable), so rename the corresponding status(es) in Jira's workflow, or this project can't fully drive the pipeline via TRACKER=jira."
                    else
                        _v_ok "All jira.sh abstract-state status names exist in $project_key's workflow."
                    fi
                else
                    local in_progress_status code_review_status
                    in_progress_status="$(_intake_config_value TRACKER_NATIVE_STATUS_IN_PROGRESS "In Progress")"
                    code_review_status="$(_intake_config_value TRACKER_NATIVE_STATUS_CODE_REVIEW "Code Review")"
                    printf '%s\n' "$real_statuses" | grep -qxF "$in_progress_status" || missing_list="$missing_list, TRACKER_NATIVE_STATUS_IN_PROGRESS='$in_progress_status'"
                    printf '%s\n' "$real_statuses" | grep -qxF "$code_review_status" || missing_list="$missing_list, TRACKER_NATIVE_STATUS_CODE_REVIEW='$code_review_status'"
                    if [ -n "$missing_list" ]; then
                        _v_missing "${missing_list#, } doesn't match any status in $project_key's Jira workflow. The state:* label will still update correctly (that's the real source of truth), but the board's native status column won't mirror it — fix the TRACKER_NATIVE_STATUS_* value(s) in .ai/intake.config to match this project's actual board column name(s)."
                    else
                        _v_ok "Both TRACKER_NATIVE_STATUS_* values exist in $project_key's workflow."
                    fi
                fi
                ;;
        esac
    fi

    # --- Project adapter contract ------------------------------------------------------------
    adapter="$(_intake_config_value PROJECT_ADAPTER symfony-docker)"
    adapter_path="$(_intake_config_value PROJECT_ADAPTER_PATH "$REPO_ROOT/scripts/lib/project")"
    adapter_file="$adapter_path/$adapter.sh"
    if [ ! -f "$adapter_file" ]; then
        _v_missing "$adapter_file doesn't exist yet (README.md \"Write a project adapter for your stack\")."
    else
        local fn missing_fns="" required="project_derive_names project_install_deps project_provision_fresh project_migrate project_build project_test project_verify project_permission_profile"
        [ "$ai_provider" = "gemini" ] && required="$required project_gemini_permission_profile"
        for fn in $required; do
            grep -qE "(^|[[:space:]])(function[[:space:]]+)?${fn}[[:space:]]*\(\)" "$adapter_file" || missing_fns="$missing_fns $fn"
        done
        if [ -n "$missing_fns" ]; then
            _v_missing "$adapter_file is missing:$missing_fns"
        else
            _v_ok "$adapter_file defines every required contract function."
        fi
    fi

    # --- Permission profile file(s) -----------------------------------------------------------
    if [ "$ai_provider" = "gemini" ]; then
        if [ ! -f "$GEMINI_SETTINGS" ]; then
            _v_missing "$GEMINI_SETTINGS doesn't exist yet (install.sh --verify --fix will scaffold a starter one)."
        elif command -v jq >/dev/null 2>&1 && ! jq empty "$GEMINI_SETTINGS" >/dev/null 2>&1; then
            _v_warn "$GEMINI_SETTINGS exists but isn't valid JSON."
        else
            _v_ok "$GEMINI_SETTINGS exists."
        fi
    elif [ "$ai_provider" = "claude" ]; then
        local f found=0
        for f in "$REPO_ROOT"/.claude/settings.*.json; do
            [ -e "$f" ] || continue
            [ "$(basename "$f")" = "settings.local.json" ] && continue   # Claude Code's own local
                                                                          # settings, not a curated
                                                                          # permission profile
            found=1
        done
        if [ "$found" -eq 1 ]; then
            _v_ok "A .claude/settings.*.json permission profile exists."
        else
            _v_warn "No .claude/settings.<adapter-name>.json permission profile — unattended Claude workers will run in Claude's default permission mode (README.md \"Quickstart\" step 7)."
        fi
    fi

    # --- scripts/intake-cron.sh --------------------------------------------------------------
    if [ ! -f "$CRON_WRAPPER" ]; then
        _v_missing "$CRON_WRAPPER doesn't exist yet (install.sh --verify --fix will scaffold it)."
    elif ! grep -qF "cd $REPO_ROOT" "$CRON_WRAPPER"; then
        _v_warn "$CRON_WRAPPER's cd target doesn't match $REPO_ROOT — was this repo moved/renamed?"
    else
        _v_ok "$CRON_WRAPPER exists and points at $REPO_ROOT."
    fi

    # --- Crontab entry (silently skipped on a host with no crontab command at all) -----------
    if command -v crontab >/dev/null 2>&1; then
        if crontab -l 2>/dev/null | grep -qF "$REPO_ROOT/scripts/intake-cron.sh"; then
            _v_ok "Crontab has an entry for $REPO_ROOT/scripts/intake-cron.sh."
        else
            _v_warn "No crontab entry for the poller — run install.sh --install-cron."
        fi
    fi

    # --- Makefile targets (silently skipped if the consumer has no Makefile at all) ----------
    if [ -f "$REPO_ROOT/Makefile" ]; then
        local t missing_targets=""
        for t in worktree-go worktree-new worktree-remove intake-plan; do
            grep -qE "^${t}:" "$REPO_ROOT/Makefile" || missing_targets="$missing_targets $t"
        done
        if [ -n "$missing_targets" ]; then
            _v_warn "Makefile is missing target(s):$missing_targets (README.md \"Quickstart\" step 5)."
        else
            _v_ok "Makefile defines every required worktree/intake target."
        fi
    fi

    echo "==> $_VERIFY_ISSUES issue(s) found."
    return "$_VERIFY_ISSUES"
}

# _prompt_intake_config — interactively builds .ai/intake.config: tracker adapter, project key,
# (for jira-tags) the app-scoping tag, and the default AI provider — then validates that
# provider's CLI/auth right away. Only called when stdin is a real terminal.
_prompt_intake_config() {
    local tracker project_key app_tag="" ai_choice ai_provider="claude" local_llm_url=""
    echo "==> Let's set up $INTAKE_CONFIG."
    read -r -p "    Tracker adapter (jira / jira-tags / github / custom) [jira]: " tracker
    tracker="${tracker:-jira}"
    _prompt_required "    Tracker project key (e.g. PROJ): " project_key
    if [ "$tracker" = "jira-tags" ]; then
        _prompt_required "    App tag to scope this repo's tickets (e.g. app:my-app-name): " app_tag
    fi

    echo "    Default AI provider for this repo (overridable per-ticket via a tracker label):"
    echo "      1) claude        — Claude Code CLI"
    echo "      2) gemini        — Gemini CLI"
    echo "      3) codex         — OpenAI Codex CLI"
    echo "      4) antigravity   — Google Antigravity CLI (binary: agy)"
    echo "      5) local-llm     — claude CLI pointed at a local LM Studio server"
    read -r -p "    Choice [1]: " ai_choice
    case "${ai_choice:-1}" in
        1|"") ai_provider="claude" ;;
        2)    ai_provider="gemini" ;;
        3)    ai_provider="codex" ;;
        4)    ai_provider="antigravity" ;;
        5)    ai_provider="local-llm" ;;
        *)    echo "    Unrecognized choice '$ai_choice' — defaulting to claude."; ai_provider="claude" ;;
    esac
    if [ "$ai_provider" = "local-llm" ]; then
        read -r -p "    LM Studio base URL [http://localhost:1234/v1]: " local_llm_url
        local_llm_url="${local_llm_url:-http://localhost:1234/v1}"
        echo "    Run ai-intake-harness/local-llm-spike.sh once before relying on this for"
        echo "    implementation work — see lib/ai/local-llm.sh."
    fi

    mkdir -p "$(dirname "$INTAKE_CONFIG")"
    {
        echo "TRACKER=$tracker                    # or jira, jira-tags, github, or your custom tracker adapter"
        echo "TRACKER_PROJECT_KEY=$project_key      # your tracker's project identifier"
        if [ "$tracker" = "jira-tags" ]; then
            echo "TRACKER_APP_TAG=$app_tag   # required for TRACKER=jira-tags — scopes queries to this repo's tickets"
        else
            echo "# TRACKER_APP_TAG=app:my-app-name-1   # required only for TRACKER=jira-tags — see README.md"
        fi
        echo "# TRACKER_GATE_COMMENTS=true          # TRACKER=jira-tags only; default false (comments ungated) — see README.md"
        echo "# TRACKER_NATIVE_STATUS_IN_PROGRESS=In Progress   # TRACKER=jira-tags only; override if your board's column is named differently"
        echo "# TRACKER_NATIVE_STATUS_CODE_REVIEW=Code Review   # TRACKER=jira-tags only; override if your board's column is named differently"
        echo "# JIRA_COOKIE_BROWSER=chrome          # only relevant if you're using the cookie auth fallback"
        echo "#                                      # (no API token) and want to pin one browser;"
        echo "#                                      # otherwise it tries every browser it can find"
        echo "AI_PROVIDER=$ai_provider                # claude, gemini, codex, antigravity, or local-llm; overridable per-ticket via a tracker label"
        if [ "$ai_provider" = "local-llm" ]; then
            echo "AI_LOCAL_LLM_BASE_URL=$local_llm_url"
        else
            echo "# AI_LOCAL_LLM_BASE_URL=http://localhost:1234/v1   # only relevant for AI_PROVIDER=local-llm"
        fi
    } > "$INTAKE_CONFIG"
    echo "==> Wrote $INTAKE_CONFIG."

    if [ "$ai_provider" = "local-llm" ]; then
        AI_LOCAL_LLM_BASE_URL="$local_llm_url" _validate_ai_provider "$ai_provider"
    else
        _validate_ai_provider "$ai_provider"
    fi
}

if [ "$INSTALL_BROWSER_COOKIE3" -eq 1 ]; then
    _install_browser_cookie3_venv
    exit $?
fi

if [ "$INSTALL_CRON" -eq 1 ]; then
    if ! command -v crontab >/dev/null 2>&1; then
        echo "FAILED: no 'crontab' command found on this machine." >&2
        exit 1
    fi
    EXISTING_CRONTAB="$(crontab -l 2>/dev/null || true)"
    if printf '%s\n' "$EXISTING_CRONTAB" | grep -qF "$REPO_ROOT/scripts/intake-cron.sh"; then
        echo "==> Crontab already has an entry for $REPO_ROOT/scripts/intake-cron.sh — leaving it alone."
    else
        printf '%s\n%s\n' "$EXISTING_CRONTAB" "$CRON_LINE" | crontab -
        echo "==> Added to crontab:"
        echo "    $CRON_LINE"
    fi
    if [ ! -f "$CRON_WRAPPER" ]; then
        echo "    WARNING: $CRON_WRAPPER doesn't exist yet — the cron job will fail until you"
        echo "    create it (re-run $SCRIPT_DIR/install.sh without --install-cron to scaffold it)."
    fi
    exit 0
fi

if [ "$VERIFY" -eq 1 ]; then
    issues=0
    _run_verify || issues=$?
    if [ "$FIX" -eq 1 ]; then
        echo
        echo "==> Applying safe fixes (net-new files only — see install.sh's --verify doc comment) ..."
        if grep -qE '^AI_PROVIDER=gemini[[:space:]]*(#.*)?$' "$INTAKE_CONFIG" 2>/dev/null; then
            _scaffold_gemini_permission_profile
        fi
        if [ ! -f "$CRON_WRAPPER" ]; then
            _scaffold_cron_wrapper
        fi
        echo
        echo "==> Re-checking ..."
        echo
        issues=0
        _run_verify || issues=$?
    fi
    exit "$issues"
fi

if [ "$TEST_ONLY" -eq 0 ]; then
    echo "==> Repo root: $REPO_ROOT"

    if [ -f "$ENV_LOCAL" ]; then
        echo "==> $ENV_LOCAL already exists — leaving it alone."
    elif [ -t 0 ]; then
        _prompt_env_local
    else
        cp "$ENV_DIST" "$ENV_LOCAL"
        echo "==> Created $ENV_LOCAL from .env.local.dist."
        echo "    Edit it now and fill in JIRA_SITE_URL, JIRA_INTAKE_EMAIL, JIRA_INTAKE_API_TOKEN"
        echo "    (a Jira API token: https://id.atlassian.com/manage-profile/security/api-tokens)."
        echo "    No API token available? Leave JIRA_INTAKE_EMAIL/JIRA_INTAKE_API_TOKEN blank instead —"
        echo "    see .env.local.dist for the browser-cookie fallback (needs 'pip install browser_cookie3'"
        echo "    — or run '$SCRIPT_DIR/install.sh --install-browser-cookie3' to get it into a"
        echo "    dedicated venv instead of system-wide — and a logged-in Jira session in your browser here)."
    fi
    echo

    if [ -f "$INTAKE_CONFIG" ]; then
        echo "==> $INTAKE_CONFIG already exists — leaving it alone."
    elif [ -t 0 ]; then
        _prompt_intake_config
    else
        echo "==> Also create $INTAKE_CONFIG with TRACKER, TRACKER_PROJECT_KEY, and (for"
        echo "    TRACKER=jira-tags) TRACKER_APP_TAG — see README.md \"Quickstart\" step 3."
    fi
    echo

    if grep -qE '^AI_PROVIDER=gemini[[:space:]]*(#.*)?$' "$INTAKE_CONFIG" 2>/dev/null; then
        _scaffold_gemini_permission_profile
        echo
    fi

    if [ -f "$CRON_WRAPPER" ]; then
        echo "==> $CRON_WRAPPER already exists — leaving it alone."
    else
        _scaffold_cron_wrapper
    fi
    echo
    echo "==> Crontab entry (every 2 minutes):"
    echo "    $CRON_LINE"
    echo "    Add it yourself via 'crontab -e', or run:"
    echo "      $SCRIPT_DIR/install.sh --install-cron${REPO_ROOT_ARG:+ $REPO_ROOT_ARG}"
    echo "    to install it automatically (safe to re-run — skips if already present)."
    echo

    echo "==> Config health check:"
    _run_verify || true
    echo
fi

if [ "$TEST_COOKIE" -eq 1 ]; then
    echo "==> Testing Jira connectivity via the browser-cookie fallback (forced, ignoring any"
    echo "    API token in $ENV_LOCAL) ..."
else
    echo "==> Testing Jira connectivity with $ENV_LOCAL ..."
fi
if [ ! -f "$ENV_LOCAL" ] && [ ! -f "$REPO_ROOT/.env" ]; then
    echo "    No .env or .env.local at $REPO_ROOT yet — nothing to test."
    exit 0
fi
if [ "$TEST_COOKIE" -eq 0 ] && grep -q '^JIRA_SITE_URL=https://your-site.atlassian.net$' "$ENV_LOCAL" 2>/dev/null; then
    echo "    $ENV_LOCAL still has placeholder values — fill it in, then re-run:"
    echo "      $SCRIPT_DIR/install.sh --test-only${REPO_ROOT_ARG:+ $REPO_ROOT_ARG}"
    exit 0
fi

if [ "$TEST_COOKIE" -eq 1 ]; then
    export JIRA_AUTH_MODE=cookie
    if ! jira_cookie_available; then
        echo "    FAILED: browser-cookie fallback isn't usable — see error above." >&2
        exit 1
    fi
fi

if ! jira_common_load_env "$REPO_ROOT"; then
    echo "    FAILED: could not connect to Jira — see error above." >&2
    exit 1
fi

echo "    OK — connected to $JIRA_SITE_URL as $(jira_myself_display_name) (auth: $(jira_auth_mode))."
