#!/bin/bash
# One-time setup helper, run after vendoring this harness into a consumer repo via:
#   git subtree add --prefix=ai-intake-harness https://github.com/davindermahal/ai-intake-harness.git main --squash
#
# From the consumer repo root:
#   ai-intake-harness/install.sh
#
# Does four things:
#   1. Copies .env.local.dist -> .env.local (repo root) if it doesn't already exist, and reminds
#      you to fill in the Jira credentials.
#   2. Scaffolds scripts/intake-cron.sh (gitignored) from a template if it doesn't already exist —
#      the cron wrapper that holds host-specific paths/credentials, per README.md "Quickstart"
#      step 6. You still need to edit it (HOME, ANTHROPIC_API_KEY source).
#   3. Prints the crontab line to add for the poller, with the correct absolute repo path baked in,
#      and (pass --install-cron) installs it into your crontab directly.
#   4. Tests that the harness can reach Jira with whatever's currently in .env.local — skipped
#      (with instructions) if it still looks like the unfilled template. Re-run this script (or
#      pass --test-only) after filling in .env.local to run just the connectivity check.
#
# Auth: an API token (JIRA_INTAKE_EMAIL + JIRA_INTAKE_API_TOKEN) if you have one, otherwise a
# browser session cookie extracted from a local Chrome/Firefox login — see .env.local.dist and
# .ai/plans/active/jira-cookie-auth-fallback.md. Pass --test-cookie instead of --test-only to
# specifically verify the cookie path works, regardless of what's currently in .env.local (useful
# even when a valid token is already configured — see that plan's decision #6).
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
REPO_ROOT_ARG=""
for arg in "$@"; do
    case "$arg" in
        --test-only) TEST_ONLY=1 ;;
        --test-cookie) TEST_ONLY=1; TEST_COOKIE=1 ;;
        --install-cron) INSTALL_CRON=1 ;;
        *) REPO_ROOT_ARG="$arg" ;;
    esac
done
REPO_ROOT="$(cd "${REPO_ROOT_ARG:-$SCRIPT_DIR/..}" && pwd)"

ENV_LOCAL="$REPO_ROOT/.env.local"
ENV_DIST="$SCRIPT_DIR/.env.local.dist"
CRON_WRAPPER="$REPO_ROOT/scripts/intake-cron.sh"
CRON_LINE="*/2 * * * * $REPO_ROOT/scripts/intake-cron.sh >> $REPO_ROOT/.intake/poll.log 2>&1"

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

if [ "$TEST_ONLY" -eq 0 ]; then
    echo "==> Repo root: $REPO_ROOT"

    if [ -f "$ENV_LOCAL" ]; then
        echo "==> $ENV_LOCAL already exists — leaving it alone."
    else
        cp "$ENV_DIST" "$ENV_LOCAL"
        echo "==> Created $ENV_LOCAL from .env.local.dist."
    fi
    echo "    Edit it now and fill in JIRA_SITE_URL, JIRA_INTAKE_EMAIL, JIRA_INTAKE_API_TOKEN"
    echo "    (a Jira API token: https://id.atlassian.com/manage-profile/security/api-tokens)."
    echo "    No API token available? Leave JIRA_INTAKE_EMAIL/JIRA_INTAKE_API_TOKEN blank instead —"
    echo "    see .env.local.dist for the browser-cookie fallback (needs"
    echo "    'pip install browser_cookie3' and a logged-in Jira session in your browser here)."
    echo "    Also create $REPO_ROOT/.ai/intake.config with TRACKER, TRACKER_PROJECT_KEY, and"
    echo "    (for TRACKER=jira-tags) TRACKER_APP_TAG — see README.md \"Quickstart\" step 2."
    echo

    if [ -f "$CRON_WRAPPER" ]; then
        echo "==> $CRON_WRAPPER already exists — leaving it alone."
    else
        mkdir -p "$REPO_ROOT/scripts"
        cat > "$CRON_WRAPPER" <<EOF
#!/bin/bash
# Cron wrapper (consumer-created, gitignored; holds host-specific paths/credentials — see
# README.md "Quickstart" step 6). EDIT ANTHROPIC_API_KEY below before relying on this.
export HOME=$HOME
export PATH="\$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"   # claude + make + jq + docker
export ANTHROPIC_API_KEY="\$(cat "\$HOME/.secrets/anthropic_key")"   # or CLAUDE_CODE_OAUTH_TOKEN
cd $REPO_ROOT
exec /usr/bin/flock -n .intake/poll.lock bash ai-intake-harness/intake-poll.sh
EOF
        chmod +x "$CRON_WRAPPER"
        echo "==> Created $CRON_WRAPPER from template — edit it now:"
        echo "    fix the ANTHROPIC_API_KEY line (path to your key, or use CLAUDE_CODE_OAUTH_TOKEN"
        echo "    instead) and double-check PATH covers claude/make/jq/docker on this host."
    fi
    echo
    echo "==> Crontab entry (every 2 minutes):"
    echo "    $CRON_LINE"
    echo "    Add it yourself via 'crontab -e', or run:"
    echo "      $SCRIPT_DIR/install.sh --install-cron${REPO_ROOT_ARG:+ $REPO_ROOT_ARG}"
    echo "    to install it automatically (safe to re-run — skips if already present)."
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

# shellcheck source=lib/tracker/jira-common.sh
. "$SCRIPT_DIR/lib/tracker/jira-common.sh"

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
