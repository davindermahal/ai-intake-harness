#!/bin/bash
# Transition a ticket to a target status via the configured tracker adapter (REST; no MCP).
#
# Used by the detached headless implementation worker (.ai/prompts/worktree-bootstrap-auto.md)
# to move a ticket to "Ready for Verification" after a SUCCESSFUL build + verify — the signal
# to the author that the AI is done and it is their turn to review/merge. On failure the worker
# leaves it *In Progress* instead, so "still In Progress" reliably means "not finished".
# Mirrors ai-intake-harness/tracker-comment.sh; the transition itself lives in the tracker
# adapter (ai-intake-harness/lib/tracker/jira.sh's tracker_transition_to_status), the single REST
# chokepoint. Also handy by hand.
#
# Usage:
#   ai-intake-harness/tracker-transition.sh <KEY> "<Target Status Name>"
#   ai-intake-harness/tracker-transition.sh TICKET-70 "Ready for Verification"
#
# Resolves by TARGET status name (more stable than a transition id) and only succeeds if a
# transition to that status is available from the ticket's current status — so it can never
# perform the human-only Plan Review -> Ready for Implementation gate from an unrelated state.
#
# Credentials/config come from .env / .env.local and .ai/intake.config via the configured
# tracker adapter. Run from the worktree (or anywhere with a .env).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

KEY="${1:-}"
TARGET="${2:-}"
if [ -z "$KEY" ] || [ -z "$TARGET" ]; then
    echo "Usage: $0 <KEY> \"<Target Status Name>\"   (e.g. $0 TICKET-70 \"Ready for Verification\")" >&2
    exit 2
fi

# shellcheck source=ai-intake-harness/lib/tracker/jira.sh
. "$SCRIPT_DIR/lib/tracker/jira.sh"
tracker_load_env "$REPO_ROOT"

tracker_transition_to_status "$KEY" "$TARGET"
echo "Transitioned $KEY -> $TARGET"
