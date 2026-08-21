#!/bin/bash
# Shared Jira Cloud REST/auth plumbing for the Jira-flavored tracker adapters (lib/tracker/jira.sh,
# lib/tracker/jira-tags.sh). Not a tracker_* adapter itself — sourced by adapters, never selected
# directly via TRACKER.
#
# Required env, loaded from .env / .env.local by jira_common_load_env:
#   JIRA_SITE_URL=https://your-site.atlassian.net
#   JIRA_INTAKE_EMAIL=you@your-domain
#   JIRA_INTAKE_API_TOKEN=...
#
# Credential resolution is isolated behind jira_auth_curl_opts so a future non-API-key auth mode
# (e.g. a browser session cookie, for users without an API token) can replace just that one
# function later without touching jira_api's callers. Only the API-key path exists today.

# Guard against double-sourcing
[ -n "${_TRACKER_JIRA_COMMON_LOADED:-}" ] && return 0
_TRACKER_JIRA_COMMON_LOADED=1

# jira_common_load_env REPO_ROOT — export the three JIRA_* vars from .env then .env.local (local
# wins), validate tooling, and resolve the curl auth args once.
jira_common_load_env() {
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
    jira_auth_curl_opts
}

# jira_auth_curl_opts — resolves _JIRA_AUTH_OPTS, the curl auth args array every request uses. The
# one seam a future non-API-key auth mode would replace; only API-key auth exists today.
jira_auth_curl_opts() {
    _JIRA_AUTH_OPTS=(-u "$JIRA_INTAKE_EMAIL:$JIRA_INTAKE_API_TOKEN")
}

# jira_api METHOD PATH [JSON_BODY] — generic call, echoes response body. Internal helper, not part
# of the tracker_* contract.
jira_api() {
    local method="$1" path="$2" data="${3:-}"
    if [ -n "$data" ]; then
        curl -sS "${_JIRA_AUTH_OPTS[@]}" -X "$method" \
            -H "Content-Type: application/json" -H "Accept: application/json" \
            --data "$data" "$JIRA_SITE_URL$path"
    else
        curl -sS "${_JIRA_AUTH_OPTS[@]}" -X "$method" \
            -H "Accept: application/json" "$JIRA_SITE_URL$path"
    fi
}

# jira_search_jql JQL — echoes one issue key per line. Internal helper (raw JQL); each adapter's
# tracker_search translates its own abstract queue into JQL before calling this.
jira_search_jql() {
    local jql="$1" resp
    resp="$(curl -sS "${_JIRA_AUTH_OPTS[@]}" \
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

# jira_myself_account_id — echoes the authenticated account's accountId, memoized for the process
# lifetime. Used by lib/tracker/jira-tags.sh's assignee checks; jira.sh doesn't need it.
_JIRA_MYSELF_ACCOUNT_ID=""
jira_myself_account_id() {
    if [ -z "$_JIRA_MYSELF_ACCOUNT_ID" ]; then
        _JIRA_MYSELF_ACCOUNT_ID="$(jira_api GET "/rest/api/2/myself" | jq -r '.accountId // empty')"
        [ -n "$_JIRA_MYSELF_ACCOUNT_ID" ] || { echo "tracker/jira: could not resolve the authenticated account id" >&2; return 1; }
    fi
    printf '%s' "$_JIRA_MYSELF_ACCOUNT_ID"
}

# The single AI-comment footer. Stamped on EVERY comment posted through jira_common_add_comment so
# an AI-posted comment is distinguishable from a human one. Under the single-account model all
# comments attribute to the same Jira user, so this footer is the only signal that Claude wrote it.
# Because jira_common_add_comment is the ONE REST comment chokepoint shared by every Jira-flavored
# adapter's tracker_add_comment, keeping the footer here guarantees it can never be bypassed — the
# worker prompts forbid posting comments any other way (e.g. via an Atlassian MCP tool).
# Jira wiki markup: ---- = horizontal rule, _..._ = italic.
JIRA_AI_COMMENT_FOOTER='----
🤖 _Posted by Claude (JIRA intake automation)_'

# jira_common_add_comment KEY TEXT — post a plain-text/wiki comment. Returns non-zero on a reported error.
jira_common_add_comment() {
    local key="$1" text="$2" body resp
    text="$text

$JIRA_AI_COMMENT_FOOTER"
    body="$(jq -n --arg b "$text" '{body:$b}')"
    resp="$(jira_api POST "/rest/api/2/issue/$key/comment" "$body")"
    if echo "$resp" | jq -e 'has("errorMessages") or has("errors")' >/dev/null 2>&1; then
        # `//` would wrongly pick .errorMessages even when it's present-but-empty (a common Jira
        # shape: {"errorMessages":[],"errors":{"comment":"..."}}), hiding the actual message —
        # prefer whichever of the two is non-empty.
        echo "tracker/jira: comment on $key may have failed: $(echo "$resp" | jq -c 'if (.errorMessages // [] | length) > 0 then .errorMessages else .errors end')" >&2
        return 1
    fi
}
