#!/bin/bash
# One-time setup helper, run after vendoring this harness into a consumer repo via:
#   git subtree add --prefix=ai-intake-harness https://github.com/davindermahal/ai-intake-harness.git main --squash
#
# From the consumer repo root:
#   ai-intake-harness/install.sh
#
# Does three things:
#   1. Copies .env.local.dist -> .env.local (repo root) if it doesn't already exist, and reminds
#      you to fill in the Jira credentials.
#   2. Prints the crontab line to add for the poller, with the correct absolute repo path baked in.
#   3. Tests that the harness can reach Jira with whatever's currently in .env.local — skipped
#      (with instructions) if it still looks like the unfilled template. Re-run this script (or
#      pass --test-only) after filling in .env.local to run just the connectivity check.
#
# REPO_ROOT defaults to the consumer repo root (one level above this harness's own directory, per
# the git-subtree layout above). Pass an explicit path as the first argument to override — e.g.
# `./install.sh .` when running this from within a standalone checkout of the harness itself
# (self-testing, no subtree involved).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TEST_ONLY=0
REPO_ROOT_ARG=""
for arg in "$@"; do
    case "$arg" in
        --test-only) TEST_ONLY=1 ;;
        *) REPO_ROOT_ARG="$arg" ;;
    esac
done
REPO_ROOT="$(cd "${REPO_ROOT_ARG:-$SCRIPT_DIR/..}" && pwd)"

ENV_LOCAL="$REPO_ROOT/.env.local"
ENV_DIST="$SCRIPT_DIR/.env.local.dist"

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
    echo "    Also create $REPO_ROOT/.ai/intake.config with TRACKER, TRACKER_PROJECT_KEY, and"
    echo "    (for TRACKER=jira-tags) TRACKER_APP_TAG — see README.md \"Quickstart\" step 2."
    echo
    echo "==> Crontab entry (every 2 minutes) — add via 'crontab -e':"
    echo "    */2 * * * * $REPO_ROOT/scripts/intake-cron.sh >> $REPO_ROOT/.intake/poll.log 2>&1"
    echo "    (scripts/intake-cron.sh is a consumer-created, gitignored wrapper — see README.md"
    echo "    \"Quickstart\" step 5 for its template; it doesn't ship with the harness.)"
    echo
fi

echo "==> Testing Jira connectivity with $ENV_LOCAL ..."
if [ ! -f "$ENV_LOCAL" ] && [ ! -f "$REPO_ROOT/.env" ]; then
    echo "    No .env or .env.local at $REPO_ROOT yet — nothing to test."
    exit 0
fi
if grep -q '^JIRA_SITE_URL=https://your-site.atlassian.net$' "$ENV_LOCAL" 2>/dev/null \
    || grep -q '^JIRA_INTAKE_API_TOKEN=your-api-token-here$' "$ENV_LOCAL" 2>/dev/null; then
    echo "    $ENV_LOCAL still has placeholder values — fill it in, then re-run:"
    echo "      $SCRIPT_DIR/install.sh --test-only${REPO_ROOT_ARG:+ $REPO_ROOT_ARG}"
    exit 0
fi

# shellcheck source=lib/tracker/jira-common.sh
. "$SCRIPT_DIR/lib/tracker/jira-common.sh"
if ! jira_common_load_env "$REPO_ROOT"; then
    echo "    FAILED: could not load Jira credentials from $ENV_LOCAL — see error above." >&2
    exit 1
fi

resp="$(jira_api GET /rest/api/2/myself)"
if echo "$resp" | jq -e 'has("accountId")' >/dev/null 2>&1; then
    name="$(echo "$resp" | jq -r '.displayName // .emailAddress // .accountId')"
    echo "    OK — connected to $JIRA_SITE_URL as $name."
else
    echo "    FAILED: Jira did not return a valid account. Response:" >&2
    echo "$resp" | jq -c '.' >&2 2>/dev/null || echo "$resp" >&2
    exit 1
fi
