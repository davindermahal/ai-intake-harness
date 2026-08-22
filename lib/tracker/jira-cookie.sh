#!/bin/bash
# Browser session-cookie extraction for Jira auth, for accounts that can't get an API token
# issued. Sourced by lib/tracker/jira-common.sh; not a tracker_* adapter itself, and not meant to
# be sourced directly. See .ai/plans/completed/jira-cookie-auth-fallback.md for the design.
#
# The cookie is never written to disk — jira_cookie_fetch prints it to stdout and the caller holds
# it only in a shell variable for the lifetime of the current process.
#
# Requires: python3 with the `browser_cookie3` package (`pip install browser_cookie3`, or
# `ai-intake-harness/install.sh --install-browser-cookie3` to get it into a dedicated venv without
# touching the system python3 — see _jira_cookie_python below).
# Optional: JIRA_COOKIE_BROWSER (e.g. "chrome", "firefox") to pin extraction to one browser
# instead of trying every browser_cookie3 knows about.

# Guard against double-sourcing
[ -n "${_TRACKER_JIRA_COOKIE_LOADED:-}" ] && return 0
_TRACKER_JIRA_COOKIE_LOADED=1

_jira_cookie_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Dedicated venv for browser_cookie3, used as a fallback when the plain `python3` on PATH doesn't
# have the package (e.g. it's a system python3 you don't want to pip-install into). install.sh
# --install-browser-cookie3 creates this; see _jira_cookie_python for the resolution order.
JIRA_COOKIE_VENV="${JIRA_COOKIE_VENV:-$HOME/.venvs/browser-cookie3}"

# _jira_cookie_python — echoes the python3 command that has browser_cookie3 importable: the plain
# `python3` on PATH if it already has the package, else the JIRA_COOKIE_VENV venv if one was set
# up. Nothing on stdout and non-zero exit if neither works. Internal helper.
_jira_cookie_python() {
    if command -v python3 >/dev/null 2>&1 && python3 -c "import browser_cookie3" >/dev/null 2>&1; then
        echo python3
        return 0
    fi
    if [ -x "$JIRA_COOKIE_VENV/bin/python3" ] && "$JIRA_COOKIE_VENV/bin/python3" -c "import browser_cookie3" >/dev/null 2>&1; then
        echo "$JIRA_COOKIE_VENV/bin/python3"
        return 0
    fi
    return 1
}

# jira_cookie_available — checks python3 and browser_cookie3 (in either location _jira_cookie_python
# checks) are present, with a message on stderr on failure. Called by jira_cookie_fetch before
# shelling out, and directly by install.sh for an early, specific error before the generic
# connectivity test runs.
jira_cookie_available() {
    command -v python3 >/dev/null 2>&1 || {
        echo "tracker/jira-cookie: python3 not found — required for the browser-cookie auth fallback" >&2
        return 1
    }
    _jira_cookie_python >/dev/null || {
        echo "tracker/jira-cookie: browser_cookie3 is not installed (checked python3 and" >&2
        echo "  $JIRA_COOKIE_VENV) — run: ai-intake-harness/install.sh --install-browser-cookie3" >&2
        echo "  (or: pip install browser_cookie3)" >&2
        return 1
    }
}

# jira_cookie_fetch — derives the cookie domain from JIRA_SITE_URL, extracts a fresh session
# cookie from the local browser, and echoes it (name=value; name2=value2 ...). Non-zero and a
# stderr message on any failure (python3/browser_cookie3 missing, no matching cookies, browser
# store unreadable).
jira_cookie_fetch() {
    local host python_cmd
    host="${JIRA_SITE_URL#http://}"
    host="${host#https://}"
    host="${host%%/*}"
    [ -n "$host" ] || { echo "tracker/jira-cookie: JIRA_SITE_URL must be set before fetching a cookie" >&2; return 1; }

    jira_cookie_available || return 1
    python_cmd="$(_jira_cookie_python)"
    "$python_cmd" "$_jira_cookie_dir/jira_cookie_extract.py" "$host" "${JIRA_COOKIE_BROWSER:-}"
}
