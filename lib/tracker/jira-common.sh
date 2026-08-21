#!/bin/bash
# Shared Jira Cloud REST/auth plumbing for the Jira-flavored tracker adapters (lib/tracker/jira.sh,
# lib/tracker/jira-tags.sh). Not a tracker_* adapter itself — sourced by adapters, never selected
# directly via TRACKER.
#
# Required env, loaded from .env / .env.local by jira_common_load_env:
#   JIRA_SITE_URL=https://your-site.atlassian.net
#
# Plus ONE of:
#   - JIRA_INTAKE_EMAIL + JIRA_INTAKE_API_TOKEN   (API-token / Basic auth — used if both are set)
#   - nothing                                     (falls back to a browser session cookie, via
#                                                    lib/tracker/jira-cookie.sh — for accounts that
#                                                    can't get an API token issued)
#
# See .ai/plans/active/jira-cookie-auth-fallback.md for the full design and its trade-offs.
#
# Credential resolution is isolated behind jira_auth_curl_opts, which is exactly the seam that let
# the cookie fallback be added without touching jira_api's callers.

# Guard against double-sourcing
[ -n "${_TRACKER_JIRA_COMMON_LOADED:-}" ] && return 0
_TRACKER_JIRA_COMMON_LOADED=1

_jira_common_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/tracker/jira-cookie.sh
. "${_jira_common_dir}/jira-cookie.sh"

# jira_common_load_env REPO_ROOT — export JIRA_SITE_URL (+ email/token if present) from .env then
# .env.local (local wins), validate tooling, resolve the auth mode, and eagerly verify the
# resolved credentials actually work against Jira.
jira_common_load_env() {
    local repo_root="$1" f resp
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
    JIRA_SITE_URL="${JIRA_SITE_URL%/}"
    # Tolerate a scheme-less host (e.g. your-site.atlassian.net) — without https:// the request
    # hits plain HTTP and gets a CloudFront 301 (HTML), which is not JSON.
    case "$JIRA_SITE_URL" in
        http://*|https://*) ;;
        *) JIRA_SITE_URL="https://$JIRA_SITE_URL" ;;
    esac
    command -v jq   >/dev/null || { echo "tracker/jira: jq not found" >&2; return 1; }
    command -v curl >/dev/null || { echo "tracker/jira: curl not found" >&2; return 1; }

    # Auth-mode resolution: JIRA_AUTH_MODE forces a mode (testing/verification only — see
    # .ai/plans/active/jira-cookie-auth-fallback.md decision #6, e.g. `install.sh --test-cookie`).
    # Otherwise: a full email+token pair means API-token auth; anything less falls back to cookie
    # auth.
    if [ -n "${JIRA_AUTH_MODE:-}" ]; then
        _JIRA_AUTH_MODE="$JIRA_AUTH_MODE"
    elif [ -n "${JIRA_INTAKE_EMAIL:-}" ] && [ -n "${JIRA_INTAKE_API_TOKEN:-}" ]; then
        _JIRA_AUTH_MODE=token
    else
        _JIRA_AUTH_MODE=cookie
    fi

    jira_auth_curl_opts || return 1

    # Eager validation: resolve /myself now so a bad token, an expired/missing cookie, or a
    # JIRA_AUTH_MODE=token override with no email/token configured fails loudly here rather than
    # deep inside the first real tracker call.
    resp="$(jira_api GET "/rest/api/2/myself")" || {
        case "$_JIRA_AUTH_MODE" in
            token)  echo "tracker/jira: could not authenticate — check JIRA_INTAKE_EMAIL/JIRA_INTAKE_API_TOKEN in .env.local" >&2 ;;
            cookie) echo "tracker/jira: could not authenticate with a browser session cookie — log into Jira in your browser, then retry" >&2 ;;
        esac
        return 1
    }
    _JIRA_MYSELF_ACCOUNT_ID="$(echo "$resp" | jq -r '.accountId // empty')"
    [ -n "$_JIRA_MYSELF_ACCOUNT_ID" ] || {
        echo "tracker/jira: Jira did not return an account for the resolved credentials (auth: $_JIRA_AUTH_MODE)" >&2
        return 1
    }
    _JIRA_MYSELF_DISPLAY_NAME="$(echo "$resp" | jq -r '.displayName // .emailAddress // .accountId')"
}

# jira_auth_curl_opts — resolves _JIRA_AUTH_OPTS, the curl auth args array every request uses.
# Branches on _JIRA_AUTH_MODE (set by jira_common_load_env): "token" builds the existing Basic-auth
# flag; "cookie" extracts a fresh session cookie via jira-cookie.sh's jira_cookie_fetch (never
# cached to disk — re-extracted every time this runs) and builds the Cookie + anti-CSRF headers
# Atlassian requires for cookie-authenticated requests.
jira_auth_curl_opts() {
    case "$_JIRA_AUTH_MODE" in
        token)
            : "${JIRA_INTAKE_EMAIL:?JIRA_AUTH_MODE=token but JIRA_INTAKE_EMAIL is not set}"
            : "${JIRA_INTAKE_API_TOKEN:?JIRA_AUTH_MODE=token but JIRA_INTAKE_API_TOKEN is not set}"
            _JIRA_AUTH_OPTS=(-u "$JIRA_INTAKE_EMAIL:$JIRA_INTAKE_API_TOKEN")
            ;;
        cookie)
            local cookie
            cookie="$(jira_cookie_fetch)" || {
                echo "tracker/jira: could not get a Jira session cookie — log into Jira in your browser, then retry" >&2
                return 1
            }
            _JIRA_AUTH_OPTS=(-H "Cookie: $cookie" -H "X-Atlassian-Token: no-check")
            ;;
        *)
            echo "tracker/jira: unknown JIRA_AUTH_MODE '$_JIRA_AUTH_MODE' (expected token or cookie)" >&2
            return 1
            ;;
    esac
}

# jira_auth_mode — echoes which auth mode actually resolved ("token" or "cookie"), so a caller can
# report/confirm which credential path ran without parsing log text. Used by install.sh.
jira_auth_mode() {
    printf '%s' "$_JIRA_AUTH_MODE"
}

# jira_myself_display_name — echoes the authenticated account's display name (or email/accountId
# fallback), resolved once by jira_common_load_env's eager validation call. Used by install.sh so
# its connectivity check doesn't need a second /myself round-trip.
jira_myself_display_name() {
    printf '%s' "$_JIRA_MYSELF_DISPLAY_NAME"
}

# jira_api METHOD PATH [JSON_BODY] — generic call, echoes response body. Internal helper, not part
# of the tracker_* contract. Validates the response is JSON-shaped (not, e.g., an HTML login page —
# Atlassian's actual failure mode for an expired session cookie, often returned as a plain HTTP
# 200) so a stale/expired cookie fails loudly here instead of feeding garbage into a caller's jq.
jira_api() {
    local method="$1" path="$2" data="${3:-}" resp trimmed
    if [ -n "$data" ]; then
        resp="$(curl -sS "${_JIRA_AUTH_OPTS[@]}" -X "$method" \
            -H "Content-Type: application/json" -H "Accept: application/json" \
            --data "$data" "$JIRA_SITE_URL$path")" || { echo "tracker/jira: request failed" >&2; return 1; }
    else
        resp="$(curl -sS "${_JIRA_AUTH_OPTS[@]}" -X "$method" \
            -H "Accept: application/json" "$JIRA_SITE_URL$path")" || { echo "tracker/jira: request failed" >&2; return 1; }
    fi
    trimmed="${resp#"${resp%%[![:space:]]*}"}"
    case "${trimmed:0:1}" in
        '{'|'[') ;;
        *)
            echo "tracker/jira: non-JSON response from Jira (auth: ${_JIRA_AUTH_MODE:-unknown}) — likely an expired session cookie or auth failure" >&2
            return 1
            ;;
    esac
    printf '%s' "$resp"
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
# lifetime. Used by lib/tracker/jira-tags.sh's assignee checks; jira.sh doesn't need it. Usually
# already warm by the time this is called — jira_common_load_env resolves it eagerly.
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
    resp="$(jira_api POST "/rest/api/2/issue/$key/comment" "$body")" || return 1
    if echo "$resp" | jq -e 'has("errorMessages") or has("errors")' >/dev/null 2>&1; then
        # `//` would wrongly pick .errorMessages even when it's present-but-empty (a common Jira
        # shape: {"errorMessages":[],"errors":{"comment":"..."}}), hiding the actual message —
        # prefer whichever of the two is non-empty.
        echo "tracker/jira: comment on $key may have failed: $(echo "$resp" | jq -c 'if (.errorMessages // [] | length) > 0 then .errorMessages else .errors end')" >&2
        return 1
    fi
}
