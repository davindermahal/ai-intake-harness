#!/bin/bash
# Browser session-cookie extraction for Jira auth, for accounts that can't get an API token
# issued. Sourced by lib/tracker/jira-common.sh; not a tracker_* adapter itself, and not meant to
# be sourced directly. See .ai/plans/active/jira-cookie-auth-fallback.md for the design.
#
# The cookie is never written to disk — jira_cookie_fetch prints it to stdout and the caller holds
# it only in a shell variable for the lifetime of the current process.
#
# Requires: python3 with the `browser_cookie3` package (`pip install browser_cookie3`).
# Optional: JIRA_COOKIE_BROWSER (e.g. "chrome", "firefox") to pin extraction to one browser
# instead of trying every browser_cookie3 knows about.

# Guard against double-sourcing
[ -n "${_TRACKER_JIRA_COOKIE_LOADED:-}" ] && return 0
_TRACKER_JIRA_COOKIE_LOADED=1

_jira_cookie_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# jira_cookie_available — checks python3 and browser_cookie3 are present, with a message on
# stderr distinguishing which is missing. Called by jira_cookie_fetch before shelling out, and
# directly by install.sh for an early, specific error before the generic connectivity test runs.
jira_cookie_available() {
    command -v python3 >/dev/null 2>&1 || {
        echo "tracker/jira-cookie: python3 not found — required for the browser-cookie auth fallback" >&2
        return 1
    }
    python3 -c "import browser_cookie3" >/dev/null 2>&1 || {
        echo "tracker/jira-cookie: browser_cookie3 is not installed — run: pip install browser_cookie3" >&2
        return 1
    }
}

# jira_cookie_fetch — derives the cookie domain from JIRA_SITE_URL, extracts a fresh session
# cookie from the local browser, and echoes it (name=value; name2=value2 ...). Non-zero and a
# stderr message on any failure (python3/browser_cookie3 missing, no matching cookies, browser
# store unreadable).
jira_cookie_fetch() {
    local host
    host="${JIRA_SITE_URL#http://}"
    host="${host#https://}"
    host="${host%%/*}"
    [ -n "$host" ] || { echo "tracker/jira-cookie: JIRA_SITE_URL must be set before fetching a cookie" >&2; return 1; }

    jira_cookie_available || return 1
    python3 "$_jira_cookie_dir/jira_cookie_extract.py" "$host" "${JIRA_COOKIE_BROWSER:-}"
}
