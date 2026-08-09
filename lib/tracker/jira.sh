#!/bin/bash
# Tracker adapter: Jira Cloud, full-REST (no MCP) — see .ai/intake.config for selection.
#
# Implements the `tracker_*` contract used by the intake poller and the worker scripts
# (ai-intake-harness/tracker-comment.sh, ai-intake-harness/tracker-transition.sh). A different
# tracker (e.g. GitHub Issues) implements this same contract in its own
# ai-intake-harness/lib/tracker/<name>.sh and is selected via TRACKER in .ai/intake.config; the
# poller and prompts never change.
#
# Used by:
#   - ai-intake-harness/intake-poll.sh       (the cron poller)
#   - ai-intake-harness/tracker-comment.sh   (worktree workers posting their own results)
#   - ai-intake-harness/tracker-transition.sh
#
# All Jira I/O goes through the personal API token (single-account model). Required env,
# loaded from .env / .env.local by tracker_load_env:
#   JIRA_SITE_URL=https://your-site.atlassian.net
#   JIRA_INTAKE_EMAIL=you@your-domain
#   JIRA_INTAKE_API_TOKEN=...
#
# Search uses REST v3 (/search/jql); read/comment/transition use v2 (plain-text comment
# bodies — no ADF construction needed). Transitions resolve by TARGET status name, which is
# more stable than transition id/name.

# Guard against double-sourcing
[ -n "${_TRACKER_JIRA_LOADED:-}" ] && return 0
_TRACKER_JIRA_LOADED=1

# Overridable so a differently-keyed Jira project only needs to set this in .ai/intake.config
# (TRACKER_PROJECT_KEY) rather than edit this file.
TRACKER_PROJECT_KEY="${TRACKER_PROJECT_KEY:-PROJ}"

# tracker_load_env REPO_ROOT — export the three JIRA_* vars from .env then .env.local (local wins).
tracker_load_env() {
    local repo_root="$1" f
    for f in "$repo_root/.env" "$repo_root/.env.local"; do
        [ -f "$f" ] || continue
        # `|| [ -n "$line" ]` so a last line without a trailing newline is still processed.
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%$'\r'}"   # tolerate CRLF line endings too
            case "$line" in
                JIRA_SITE_URL=*|JIRA_INTAKE_EMAIL=*|JIRA_INTAKE_API_TOKEN=*)
                    eval "export ${line%%=*}=$(printf '%s' "${line#*=}" | sed -e 's/^["'\'']//' -e 's/["'\'']$//')" ;;
            esac
        done < "$f"
    done
    : "${JIRA_SITE_URL:?set JIRA_SITE_URL in .env (or .env.local)}"
    : "${JIRA_INTAKE_EMAIL:?set JIRA_INTAKE_EMAIL in .env (or .env.local)}"
    : "${JIRA_INTAKE_API_TOKEN:?set JIRA_INTAKE_API_TOKEN in .env (or .env.local)}"
    JIRA_SITE_URL="${JIRA_SITE_URL%/}"
    # Tolerate a scheme-less host (e.g. your-site.atlassian.net) — without https:// the request
    # hits plain HTTP and gets a CloudFront 301 (HTML), which is not JSON.
    case "$JIRA_SITE_URL" in
        http://*|https://*) ;;
        *) JIRA_SITE_URL="https://$JIRA_SITE_URL" ;;
    esac
    command -v jq   >/dev/null || { echo "tracker/jira: jq not found" >&2; return 1; }
    command -v curl >/dev/null || { echo "tracker/jira: curl not found" >&2; return 1; }
}

# jira_api METHOD PATH [JSON_BODY] — generic call, echoes response body. Internal helper, not
# part of the tracker_* contract.
jira_api() {
    local method="$1" path="$2" data="${3:-}"
    if [ -n "$data" ]; then
        curl -sS -u "$JIRA_INTAKE_EMAIL:$JIRA_INTAKE_API_TOKEN" -X "$method" \
            -H "Content-Type: application/json" -H "Accept: application/json" \
            --data "$data" "$JIRA_SITE_URL$path"
    else
        curl -sS -u "$JIRA_INTAKE_EMAIL:$JIRA_INTAKE_API_TOKEN" -X "$method" \
            -H "Accept: application/json" "$JIRA_SITE_URL$path"
    fi
}

# jira_search_jql JQL — echoes one issue key per line. Internal helper (raw JQL); the tracker_*
# contract exposes only the abstract tracker_search below.
jira_search_jql() {
    local jql="$1" resp
    resp="$(curl -sS -u "$JIRA_INTAKE_EMAIL:$JIRA_INTAKE_API_TOKEN" \
        -G "$JIRA_SITE_URL/rest/api/3/search/jql" \
        --data-urlencode "jql=$jql" \
        --data-urlencode "fields=key" \
        --data-urlencode "maxResults=50" \
        -H "Accept: application/json")" || { echo "tracker/jira: search request failed" >&2; return 1; }
    if echo "$resp" | jq -e 'has("errorMessages") and (.errorMessages | length > 0)' >/dev/null 2>&1; then
        echo "tracker/jira: search error: $(echo "$resp" | jq -r '.errorMessages | join("; ")')" >&2
        return 1
    fi
    echo "$resp" | jq -r '.issues[]?.key'
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

# The single AI-comment footer. Stamped on EVERY comment posted through tracker_add_comment so an
# AI-posted comment is distinguishable from a human one. Under the single-account model all
# comments attribute to the same Jira user, so this footer is the only signal that Claude wrote
# it. Because tracker_add_comment is the ONE REST comment chokepoint (used by both the poller and
# ai-intake-harness/tracker-comment.sh), keeping the footer here guarantees it can never be bypassed — the
# worker prompts forbid posting comments any other way (e.g. via an Atlassian MCP tool).
# Jira wiki markup: ---- = horizontal rule, _..._ = italic.
JIRA_AI_COMMENT_FOOTER='----
🤖 _Posted by Claude (JIRA intake automation)_'

# tracker_add_comment KEY TEXT — post a plain-text/wiki comment. Returns non-zero on a reported error.
tracker_add_comment() {
    local key="$1" text="$2" body resp
    text="$text

$JIRA_AI_COMMENT_FOOTER"
    body="$(jq -n --arg b "$text" '{body:$b}')"
    resp="$(jira_api POST "/rest/api/2/issue/$key/comment" "$body")"
    if echo "$resp" | jq -e 'has("errorMessages") or has("errors")' >/dev/null 2>&1; then
        echo "tracker/jira: comment on $key may have failed: $(echo "$resp" | jq -c '.errorMessages // .errors')" >&2
        return 1
    fi
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
