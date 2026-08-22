#!/bin/bash
# Tracker adapter: Jira Cloud, full-REST (no MCP) — see .ai/intake.config for selection.
#
# Implements the `tracker_*` contract used by the intake poller and the worker scripts
# (ai-intake-harness/tracker-comment.sh, ai-intake-harness/tracker-transition.sh). A different
# tracker (e.g. GitHub Issues) implements this same contract in its own
# ai-intake-harness/lib/tracker/<name>.sh and is selected via TRACKER in .ai/intake.config; the
# poller and prompts never change. lib/tracker/jira-tags.sh is a second Jira-flavored adapter for a
# shared project used by multiple repos, sharing REST/auth plumbing with this one via jira-common.sh.
#
# Used by:
#   - ai-intake-harness/intake-poll.sh       (the cron poller)
#   - ai-intake-harness/tracker-comment.sh   (worktree workers posting their own results)
#   - ai-intake-harness/tracker-transition.sh
#
# All Jira I/O goes through one personal account (single-account model), authenticated either with
# an API token or, if no token is configured, a browser session cookie (see
# lib/tracker/jira-common.sh / lib/tracker/jira-cookie.sh and
# .ai/plans/completed/jira-cookie-auth-fallback.md). Required env, loaded from .env / .env.local by
# tracker_load_env:
#   JIRA_SITE_URL=https://your-site.atlassian.net
# plus JIRA_INTAKE_EMAIL + JIRA_INTAKE_API_TOKEN (API-token auth) or, if those are left unset, the
# harness falls back to extracting a session cookie from the local browser.
#
# Search uses REST v3 (/search/jql); read/comment/transition use v2 (plain-text comment
# bodies — no ADF construction needed). Transitions resolve by TARGET status name, which is
# more stable than transition id/name.

# Guard against double-sourcing
[ -n "${_TRACKER_JIRA_LOADED:-}" ] && return 0
_TRACKER_JIRA_LOADED=1

_jira_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/tracker/jira-common.sh
. "${_jira_lib_dir}/jira-common.sh"

# Overridable so a differently-keyed Jira project only needs to set this in .ai/intake.config
# (TRACKER_PROJECT_KEY) rather than edit this file.
TRACKER_PROJECT_KEY="${TRACKER_PROJECT_KEY:-PROJ}"

# tracker_load_env REPO_ROOT — see jira-common.sh; jira.sh needs no adapter-specific config beyond
# the shared Jira secrets.
tracker_load_env() {
    jira_common_load_env "$1"
}

# tracker_search QUEUE_NAME — echoes one ticket key per line for a named abstract queue
# ("planning", "implementation", or "in-progress"). Owns translating the abstract queue into this
# tracker's own query language (JQL) so callers never see Jira-specific syntax.
tracker_search() {
    local queue="$1" jql
    case "$queue" in
        planning)       jql="project = ${TRACKER_PROJECT_KEY} AND status = \"Ready for Planning\" ORDER BY created ASC" ;;
        implementation) jql="project = ${TRACKER_PROJECT_KEY} AND status = \"Ready for Implementation\" ORDER BY created ASC" ;;
        in-progress)    jql="project = ${TRACKER_PROJECT_KEY} AND status = \"In Progress\" ORDER BY created ASC" ;;
        *) echo "tracker/jira: unknown queue '$queue' (expected planning|implementation|in-progress)" >&2; return 1 ;;
    esac
    jira_search_jql "$jql"
}

# tracker_get_issue KEY — echoes issue JSON (summary, status, description, comments, labels; v2
# text bodies). `labels` feeds intake-poll.sh's resolve_ai_profile (ai-plan-<profile> /
# ai-impl-<profile> / legacy ai-provider-<name> labels -> per-ticket, per-phase AI
# provider+model selection).
tracker_get_issue() {
    jira_api GET "/rest/api/2/issue/$1?fields=summary,status,description,comment,labels"
}

# tracker_add_comment KEY TEXT — post a plain-text/wiki comment. Returns non-zero on a reported error.
tracker_add_comment() {
    jira_common_add_comment "$1" "$2"
}

# tracker_transition_to_status KEY STATUS_NAME — transition to a LITERAL target status name (e.g.
# "Plan Review"). Low-level; used for ad-hoc/human use (ai-intake-harness/tracker-transition.sh) where the
# caller already knows the tracker's own vocabulary. Internal callers within the generic poller
# should prefer the abstract tracker_transition below.
tracker_transition_to_status() {
    local key="$1" target="$2" id
    id="$(jira_api GET "/rest/api/2/issue/$key/transitions" \
        | jq -r --arg t "$target" '.transitions[] | select(.to.name==$t) | .id' | head -1)"
    [ -n "$id" ] || { echo "tracker/jira: no transition to '$target' available from $key's current status" >&2; return 1; }
    jira_api POST "/rest/api/2/issue/$key/transitions" "$(jq -n --arg id "$id" '{transition:{id:$id}}')" >/dev/null
}

# tracker_transition KEY ABSTRACT_STATE — the generic poller's dispatch code calls this with one
# of the abstract state names below rather than a tracker-specific status string, so it stays
# tracker-agnostic. This adapter maps each to Jira's own status name.
tracker_transition() {
    local key="$1" abstract="$2" target
    case "$abstract" in
        needs-author-input)     target="Needs Author Input" ;;
        plan-review)            target="Plan Review" ;;
        in-progress)            target="In Progress" ;;
        ready-for-verification) target="Ready for Verification" ;;
        *) echo "tracker/jira: unknown abstract state '$abstract'" >&2; return 1 ;;
    esac
    tracker_transition_to_status "$key" "$target"
}

# tracker_ticket_regex — echoes the extended-regex pattern for extracting this tracker's ticket id
# from a branch name (e.g. "PROJ-[0-9]+"). One adapter-owned value in place of the same pattern
# hardcoded separately in the project adapter and the poller.
tracker_ticket_regex() {
    printf '%s' "${TRACKER_PROJECT_KEY}-[0-9]+"
}

# tracker_abstract_state CTX_FILE — maps this adapter's own native-status vocabulary onto the
# harness's abstract state names, reading from an already-fetched tracker_get_issue JSON file
# (no extra REST call). Lets tracker-agnostic worker prompts (e.g.
# ai-intake-harness/prompts/intake-planning.md) check "is this ticket still eligible" without
# knowing this tracker's own status names. Echoes "" for anything outside the pipeline (Backlog,
# Selected, or an unrecognized status).
tracker_abstract_state() {
    local status
    status="$(jq -r '.fields.status.name // empty' "$1")"
    case "$status" in
        "Ready for Planning")       printf 'ready-for-planning' ;;
        "Needs Author Input")       printf 'needs-author-input' ;;
        "Plan Review")              printf 'plan-review' ;;
        "Ready for Implementation") printf 'ready-for-implementation' ;;
        "In Progress")              printf 'in-progress' ;;
        "Ready for Verification")   printf 'ready-for-verification' ;;
        "Done")                     printf 'done' ;;
        *) printf '' ;;
    esac
}
