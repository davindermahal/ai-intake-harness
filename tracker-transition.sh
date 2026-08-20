#!/bin/bash
# Transition a ticket to a target status via the configured tracker adapter (REST; no MCP).
#
# Used by the detached headless implementation worker (.ai/prompts/worktree-bootstrap-auto.md)
# to move a ticket to "Ready for Verification" after a SUCCESSFUL build + verify — the signal
# to the author that the AI is done and it is their turn to review/merge. On failure the worker
# leaves it *In Progress* instead, so "still In Progress" reliably means "not finished".
# Mirrors ai-intake-harness/tracker-comment.sh; the transition itself lives in the configured
# tracker adapter's tracker_transition_to_status (see ai-intake-harness/lib/intake-config.sh —
# TRACKER selects it), the single REST chokepoint. Also handy by hand.
#
# Usage:
#   ai-intake-harness/tracker-transition.sh <KEY> "<Target>"
#   ai-intake-harness/tracker-transition.sh TICKET-70 "Ready for Verification"     # TRACKER=jira
#   ai-intake-harness/tracker-transition.sh TICKET-70 ready-for-verification      # TRACKER=jira-tags
#
# TARGET's vocabulary is adapter-specific: a literal Jira status name for TRACKER=jira, or a
# state:<step> step name (e.g. "ready-for-implementation") for TRACKER=jira-tags — see the
# configured adapter's tracker_transition_to_status. Either way it only succeeds if that move is
# legal from the ticket's current state — so it can never perform the human-only Plan Review ->
# Ready for Implementation gate from an unrelated state.
#
# Credentials/config come from .env / .env.local and .ai/intake.config via the configured
# tracker adapter. Run from the worktree (or anywhere with a .env).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# See tracker-comment.sh for why: distinguishes a vendored (git-subtree) install, where this dir
# is a subdirectory of the consumer repo, from a self-hosted checkout where this dir IS the repo
# root (this harness driving its own development).
if [ "$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" = "$SCRIPT_DIR" ]; then
    REPO_ROOT="$SCRIPT_DIR"
else
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

KEY="${1:-}"
TARGET="${2:-}"
if [ -z "$KEY" ] || [ -z "$TARGET" ]; then
    echo "Usage: $0 <KEY> \"<Target Status Name>\"   (e.g. $0 TICKET-70 \"Ready for Verification\")" >&2
    exit 2
fi

# shellcheck source=ai-intake-harness/lib/intake-config.sh
. "$SCRIPT_DIR/lib/intake-config.sh" "$REPO_ROOT"
tracker_load_env "$REPO_ROOT"

tracker_transition_to_status "$KEY" "$TARGET"
echo "Transitioned $KEY -> $TARGET"
