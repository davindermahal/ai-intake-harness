#!/bin/bash
# Load .ai/intake.config (TRACKER, TRACKER_PROJECT_KEY, PROJECT_ADAPTER, PROJECT_DB_PREFIX, AI_*),
# apply defaults, then source the selected tracker + project + AI adapters. This is the one place
# that turns the config selection into concrete `lib/tracker/<name>.sh` / `lib/project/<name>.sh` /
# `lib/ai/<name>.sh` files to source — the poller and worktree scripts stay adapter-agnostic and
# never hardcode which tracker, project, or AI backend they're driving.
#
# Usage: . "$(dirname "$0")/lib/intake-config.sh" <repo-root>
#
# Sets/exports: TRACKER TRACKER_PROJECT_KEY PROJECT_ADAPTER PROJECT_DB_PREFIX PROJECT_TICKET_REGEX
# (plus TRACKER_APP_TAG and TRACKER_GATE_COMMENTS, passed through with no default here — both are
# TRACKER=jira-tags-only and default inside lib/tracker/jira-tags.sh itself)
# PLAN_WORKTREE_PREFIX AI_PROVIDER AI_PLANNING_MODEL AI_IMPLEMENTATION_MODEL AI_LOCAL_LLM_BASE_URL
# AI_LOCAL_LLM_MODEL AI_LOCAL_LLM_TIMEOUT (plus any AI_PROFILE_* the config declares), and loads every tracker_* /
# project_* / ai_* function from the selected adapters. A per-ticket AI profile/provider override
# (Jira label) is resolved later, per-dispatch, by intake-poll.sh's
# resolve_ai_profile/load_ai_provider — this initial ai/${AI_PROVIDER}.sh load is just the
# env/config-default baseline.

# Guard against double-sourcing
[ -n "${_INTAKE_CONFIG_LOADED:-}" ] && return 0
_INTAKE_CONFIG_LOADED=1

_intake_repo_root="${1:?intake-config.sh requires <repo-root>}"
_intake_config_file="${_intake_repo_root}/.ai/intake.config"

# The config file is a plain KEY=value shell fragment (see .ai/intake.config) — sourcing it directly
# is equivalent to and simpler than parsing it, and matches how .env/.env.local are treated
# elsewhere in this repo's tooling.
#
# Env > config precedence: a caller-EXPORTED, non-empty value for any of the
# documented override keys must beat the config file — but sourcing a plain shell fragment would
# silently clobber it (which is exactly how `PROVIDER=... make worktree-go` and the poller's
# per-ticket PROVIDER/MODEL handoff used to get lost whenever the key also appeared in
# .ai/intake.config). Snapshot the caller's non-empty values first, restore them after sourcing.
_intake_env_keys="TRACKER TRACKER_PROJECT_KEY TRACKER_APP_TAG TRACKER_GATE_COMMENTS PROJECT_ADAPTER PROJECT_DB_PREFIX PROJECT_ADAPTER_PATH
    PLAN_WORKTREE_PREFIX AI_PROVIDER AI_PLANNING_MODEL AI_IMPLEMENTATION_MODEL
    AI_LOCAL_LLM_BASE_URL AI_LOCAL_LLM_MODEL AI_LOCAL_LLM_TIMEOUT"
for _k in $_intake_env_keys; do
    _v="$(eval "printf '%s' \"\${$_k:-}\"")"
    [ -n "$_v" ] && eval "_intake_env_$_k=\"\$_v\""
done
if [ -f "$_intake_config_file" ]; then
    # shellcheck source=/dev/null
    . "$_intake_config_file"
fi
for _k in $_intake_env_keys; do
    _v="$(eval "printf '%s' \"\${_intake_env_$_k:-}\"")"
    [ -n "$_v" ] && eval "$_k=\"\$_v\""
done
unset _intake_env_keys _k _v

export TRACKER="${TRACKER:-jira}"
export TRACKER_PROJECT_KEY="${TRACKER_PROJECT_KEY:-PROJ}"
export PROJECT_ADAPTER="${PROJECT_ADAPTER:-symfony-docker}"
export PROJECT_DB_PREFIX="${PROJECT_DB_PREFIX:-myapp}"
# Directory-name prefix for the ephemeral planning worktree the poller creates as a sibling of
# the repo root (see intake-poll.sh's dispatch_planning): "<prefix><TICKET-KEY>".
export PLAN_WORKTREE_PREFIX="${PLAN_WORKTREE_PREFIX:-.intake-plan-}"

# AI adapter selection (see ai-intake-harness/lib/ai/<name>.sh for the ai_* contract). Model
# overrides default to empty — "the claude CLI's own default" — so an unconfigured install behaves
# exactly as before this seam existed.
export AI_PROVIDER="${AI_PROVIDER:-claude}"
export AI_PLANNING_MODEL="${AI_PLANNING_MODEL:-}"
export AI_IMPLEMENTATION_MODEL="${AI_IMPLEMENTATION_MODEL:-}"
export AI_LOCAL_LLM_BASE_URL="${AI_LOCAL_LLM_BASE_URL:-http://localhost:1234/v1}"
export AI_LOCAL_LLM_MODEL="${AI_LOCAL_LLM_MODEL:-}"
export AI_LOCAL_LLM_TIMEOUT="${AI_LOCAL_LLM_TIMEOUT:-3600}"

_intake_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${_intake_lib_dir}/tracker/${TRACKER}.sh"
# Project adapter is in the consumer repo, not in the harness. Its directory can be overridden
# via PROJECT_ADAPTER_PATH in .ai/intake.config; otherwise defaults to scripts/lib/project/.
PROJECT_ADAPTER_PATH="${PROJECT_ADAPTER_PATH:-${_intake_repo_root}/scripts/lib/project}"
# shellcheck source=/dev/null
. "${PROJECT_ADAPTER_PATH}/${PROJECT_ADAPTER}.sh"
# shellcheck source=/dev/null
. "${_intake_lib_dir}/ai/${AI_PROVIDER}.sh"

# One tracker-owned ticket-id regex, wired into the project adapter's name derivation, in place of
# each independently hardcoding (or defaulting) the same pattern.
export PROJECT_TICKET_REGEX
PROJECT_TICKET_REGEX="$(tracker_ticket_regex)"
