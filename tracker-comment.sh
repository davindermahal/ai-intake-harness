#!/bin/bash
# Post a comment to a ticket via the configured tracker adapter (REST; no MCP).
#
# Used by the detached headless implementation worker (.ai/prompts/worktree-bootstrap-auto.md)
# to post its build/verify results back to the ticket — see the "always comment the work back
# to the ticket" convention (.ai/context/conventions.md -> "Plans"). Also handy by hand.
#
# Usage:
#   ai-intake-harness/tracker-comment.sh <KEY> "comment text"
#   ai-intake-harness/tracker-comment.sh <KEY> -          # read the comment body from stdin
#   echo "..." | ai-intake-harness/tracker-comment.sh <KEY> -
#
# Credentials/config come from .env / .env.local and .ai/intake.config via the configured
# tracker adapter (Jira today — ai-intake-harness/lib/tracker/jira.sh). Run from the worktree (or
# anywhere with a .env).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

KEY="${1:-}"
BODY_ARG="${2:-}"
if [ -z "$KEY" ] || [ -z "$BODY_ARG" ]; then
    echo "Usage: $0 <KEY> \"comment text\" | <KEY> -   (- reads body from stdin)" >&2
    exit 2
fi

if [ "$BODY_ARG" = "-" ]; then
    BODY="$(cat)"
else
    BODY="$BODY_ARG"
fi
[ -n "$BODY" ] || { echo "Refusing to post an empty comment to $KEY" >&2; exit 2; }

# shellcheck source=ai-intake-harness/lib/tracker/jira.sh
. "$SCRIPT_DIR/lib/tracker/jira.sh"
tracker_load_env "$REPO_ROOT"

tracker_add_comment "$KEY" "$BODY"
echo "Posted comment to $KEY"
