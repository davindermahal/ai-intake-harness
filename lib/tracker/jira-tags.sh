#!/bin/bash
# Tracker adapter: Jira Cloud via labels, for one shared project used by multiple repos — see
# .ai/plans/active/jira-tags-tracker-adapter.md for the design. Implements the same `tracker_*`
# contract as lib/tracker/jira.sh, sharing REST/auth plumbing with it via jira-common.sh, but:
#
#   - Represents the harness's abstract workflow state as `state:<step>` labels instead of the
#     native status field, which on this project only has three values (Todo / In Progress /
#     Code Review) — too coarse to carry the full state machine. Every label write best-effort
#     mirrors a collapsed native status for board legibility; the label is the source of truth.
#   - Scopes every query to one repo's tickets within the shared project via a TRACKER_APP_TAG
#     label (e.g. app:my-app-name-1), plus the authenticated account's own assignment
#     (assignee = currentUser()), since the shared project may have multiple assigned users and a
#     harness install must never touch a ticket assigned to someone else.
#   - Self-enforces transition legality (jira_tags_legal_move): Jira's transitions API rejects an
#     illegal status move for free; labels give nothing for free, so this adapter replicates that
#     guarantee with its own edge table. This is in addition to the structural guarantee shared with
#     jira.sh: tracker_transition has no `ready-for-implementation` case, so the automation can
#     never perform that transition regardless of what the legal-move table would allow.
#
# Required env (see jira-common.sh's jira_common_load_env): JIRA_SITE_URL, plus either
# JIRA_INTAKE_EMAIL + JIRA_INTAKE_API_TOKEN (API-token auth) or, if those are unset, a browser
# session cookie fallback (see lib/tracker/jira-cookie.sh and
# .ai/plans/active/jira-cookie-auth-fallback.md).
# Required config (.ai/intake.config): TRACKER_PROJECT_KEY, TRACKER_APP_TAG.
# Optional config: TRACKER_GATE_COMMENTS=true to also assignee-gate tracker_add_comment (default:
# false — see the module comment on tracker_add_comment for why comments are ungated by default).

# Guard against double-sourcing
[ -n "${_TRACKER_JIRA_TAGS_LOADED:-}" ] && return 0
_TRACKER_JIRA_TAGS_LOADED=1

_jira_tags_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/tracker/jira-common.sh
. "${_jira_tags_lib_dir}/jira-common.sh"

# Overridable so a differently-keyed Jira project only needs to set this in .ai/intake.config
# (TRACKER_PROJECT_KEY) rather than edit this file.
TRACKER_PROJECT_KEY="${TRACKER_PROJECT_KEY:-PROJ}"

# Default: comments are NOT assignee-gated (see tracker_add_comment below) — set to "true" in
# .ai/intake.config to re-enable the stricter, gated behavior this adapter shipped with.
TRACKER_GATE_COMMENTS="${TRACKER_GATE_COMMENTS:-false}"

# tracker_load_env REPO_ROOT — shared Jira secrets plus this adapter's own required config: the
# per-repo app-scoping tag. Fails loudly if TRACKER_APP_TAG is unset, same as the Jira secrets do.
tracker_load_env() {
    jira_common_load_env "$1" || return 1
    : "${TRACKER_APP_TAG:?set TRACKER_APP_TAG in .ai/intake.config (e.g. app:my-app-name-1)}"
}

# tracker_search QUEUE_NAME — echoes one ticket key per line: this repo's tickets (TRACKER_APP_TAG)
# in the named abstract queue's state, assigned to the authenticated account.
tracker_search() {
    local queue="$1" state
    case "$queue" in
        planning)       state="ready-for-planning" ;;
        implementation) state="ready-for-implementation" ;;
        in-progress)    state="in-progress" ;;
        *) echo "tracker/jira-tags: unknown queue '$queue' (expected planning|implementation|in-progress)" >&2; return 1 ;;
    esac
    jira_search_jql "project = ${TRACKER_PROJECT_KEY} AND labels = \"${TRACKER_APP_TAG}\" AND labels = \"state:${state}\" AND assignee = currentUser() ORDER BY created ASC"
}

# tracker_get_issue KEY — same fields as jira.sh plus `assignee`, needed for the per-write
# assignee check below.
tracker_get_issue() {
    jira_api GET "/rest/api/2/issue/$1?fields=summary,status,description,comment,labels,assignee"
}

# jira_tags_current_state KEY — echoes the bare step name of the ticket's single state:* label.
# Internal helper; a ticket should carry exactly one at a time.
jira_tags_current_state() {
    local key="$1" states n
    states="$(tracker_get_issue "$key" | jq -r '.fields.labels[]? | select(startswith("state:")) | sub("^state:";"")')"
    n="$(printf '%s\n' "$states" | grep -c .)"
    case "$n" in
        1) printf '%s' "$states" ;;
        0) echo "tracker/jira-tags: $key has no state:* label" >&2; return 1 ;;
        *) echo "tracker/jira-tags: $key has multiple state:* labels: $(printf '%s' "$states" | tr '\n' ' ')" >&2; return 1 ;;
    esac
}

# jira_tags_legal_move CURRENT TARGET — the abstract state machine's edges (see
# docs/architecture.md), self-enforced since labels aren't gated by Jira the way status transitions
# are. Internal helper, checked by jira_tags_set_state on every write.
jira_tags_legal_move() {
    local current="$1" target="$2"
    case "$current:$target" in
        ready-for-planning:needs-author-input) ;;
        ready-for-planning:plan-review) ;;
        needs-author-input:ready-for-planning) ;;
        plan-review:ready-for-implementation) ;;
        ready-for-implementation:in-progress) ;;
        in-progress:ready-for-verification) ;;
        in-progress:ready-for-implementation) ;;
        ready-for-verification:ready-for-implementation) ;;
        ready-for-verification:done) ;;
        *) echo "tracker/jira-tags: illegal move: $current -> $target" >&2; return 1 ;;
    esac
}

# jira_tags_native_status TARGET — maps a state:* step onto this project's 3-status board (Todo is
# pre-pipeline only and is never written here). Internal helper.
jira_tags_native_status() {
    case "$1" in
        ready-for-planning|needs-author-input|plan-review|ready-for-implementation|in-progress)
            printf 'In Progress' ;;
        ready-for-verification|done)
            printf 'Code Review' ;;
        *) echo "tracker/jira-tags: unknown state '$1' for native-status mapping" >&2; return 1 ;;
    esac
}

# jira_tags_assert_assignee KEY — refuse to act unless KEY is currently assigned to the
# authenticated account. Guards every state-changing write path because the shared project may
# have multiple assigned users. Internal helper.
jira_tags_assert_assignee() {
    local key="$1" assignee_id me
    assignee_id="$(tracker_get_issue "$key" | jq -r '.fields.assignee.accountId // empty')"
    me="$(jira_myself_account_id)" || return 1
    if [ -n "$assignee_id" ] && [ "$assignee_id" = "$me" ]; then
        return 0
    fi
    echo "tracker/jira-tags: $key is not assigned to the authenticated account — refusing to act" >&2
    return 1
}

# tracker_add_comment KEY TEXT — posts through the same REST chokepoint jira.sh uses. NOT
# assignee-gated by default: a comment is a worker's one channel to report back what happened
# (including that its own ticket got reassigned mid-flight), so gating it the same as a
# state-changing write turns a legitimate race into a silently swallowed failure — the poller log
# is the only place it would ever surface. Set TRACKER_GATE_COMMENTS=true in .ai/intake.config to
# re-enable the stricter, gated behavior (comments are lower-risk than a label/status write, but
# still cross-assignee if left ungated in a heavily shared project).
tracker_add_comment() {
    local key="$1" text="$2"
    if [ "$TRACKER_GATE_COMMENTS" = "true" ]; then
        jira_tags_assert_assignee "$key" || return 1
    fi
    jira_common_add_comment "$key" "$text"
}

# jira_tags_set_state KEY TARGET — the single chokepoint every state-changing call funnels through:
# assignee check, legality check, write the state:* label, then best-effort mirror the native
# status (a failed status mirror is logged but does not fail the call — the label write, this
# adapter's real source of truth, has already succeeded). Internal helper.
jira_tags_set_state() {
    local key="$1" target="$2" current want_status have_status id
    jira_tags_assert_assignee "$key" || return 1
    current="$(jira_tags_current_state "$key")" || return 1
    jira_tags_legal_move "$current" "$target" || return 1

    jira_api PUT "/rest/api/2/issue/$key" \
        "$(jq -n --arg rm "state:$current" --arg add "state:$target" \
            '{update:{labels:[{remove:$rm},{add:$add}]}}')" >/dev/null

    want_status="$(jira_tags_native_status "$target")" || return 0
    have_status="$(tracker_get_issue "$key" | jq -r '.fields.status.name')"
    if [ "$have_status" != "$want_status" ]; then
        id="$(jira_api GET "/rest/api/2/issue/$key/transitions" \
            | jq -r --arg t "$want_status" '.transitions[] | select(.to.name==$t) | .id' | head -1)"
        if [ -n "$id" ]; then
            jira_api POST "/rest/api/2/issue/$key/transitions" "$(jq -n --arg id "$id" '{transition:{id:$id}}')" >/dev/null
        else
            echo "tracker/jira-tags: warning: no Jira transition to '$want_status' available for $key; label updated, status left as '$have_status'" >&2
        fi
    fi
}

# tracker_transition KEY ABSTRACT_STATE — the poller-driven contract, same four cases as jira.sh
# (and deliberately no `ready-for-implementation` case — see module comment).
tracker_transition() {
    local key="$1" abstract="$2"
    case "$abstract" in
        needs-author-input|plan-review|in-progress|ready-for-verification) ;;
        *) echo "tracker/jira-tags: unknown abstract state '$abstract'" >&2; return 1 ;;
    esac
    jira_tags_set_state "$key" "$abstract"
}

# tracker_transition_to_status KEY TARGET — same function name as jira.sh so
# ai-intake-harness/tracker-transition.sh stays adapter-agnostic. Here TARGET is a state:<step> step
# name (e.g. "ready-for-implementation"), not a Jira status display name. This is the entry point a
# human uses by hand to perform the plan-review -> ready-for-implementation approval gate.
tracker_transition_to_status() {
    jira_tags_set_state "$1" "$2"
}

# tracker_ticket_regex — same shape as jira.sh; real Jira issue keys either way.
tracker_ticket_regex() {
    printf '%s' "${TRACKER_PROJECT_KEY}-[0-9]+"
}

# tracker_abstract_state CTX_FILE — same contract as jira.sh's function of the same name, reading
# from an already-fetched tracker_get_issue JSON file (no extra REST call): the state:* label IS
# the abstract state here, so this is a straight extraction rather than a status-name mapping.
# Lenient on purpose (unlike jira_tags_current_state, which is a write-path precondition and
# errors on zero/multiple labels) — a worker-prompt eligibility check should degrade to "" rather
# than fail outright on a data-integrity edge case; echoes the first match if more than one somehow
# exists.
tracker_abstract_state() {
    jq -r '.fields.labels[]? | select(startswith("state:")) | sub("^state:";"")' "$1" | head -1
}
