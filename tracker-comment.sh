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
# tracker adapter (see ai-intake-harness/lib/intake-config.sh — TRACKER selects it). Run from the
# worktree (or anywhere with a .env).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Vendored (git subtree): this dir is a subdirectory of the consumer repo, so its own git
# top-level is the consumer root one level up. Self-hosted (this harness driving its own
# development, no subtree prefix): this dir IS the repo root, so its git top-level is itself —
# detect that and use SCRIPT_DIR directly instead of walking past the actual root.
if [ "$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" = "$SCRIPT_DIR" ]; then
    REPO_ROOT="$SCRIPT_DIR"
else
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

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

# shellcheck source=ai-intake-harness/lib/intake-config.sh
. "$SCRIPT_DIR/lib/intake-config.sh" "$REPO_ROOT"
tracker_load_env "$REPO_ROOT"

tracker_add_comment "$KEY" "$BODY"
echo "Posted comment to $KEY"
