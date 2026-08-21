#!/usr/bin/env python3
"""Print a Jira/Confluence session cookie string for one domain, extracted from a local browser's
cookie store via browser_cookie3. Invoked by lib/tracker/jira-cookie.sh's jira_cookie_fetch; not
meant to be run directly. See .ai/plans/active/jira-cookie-auth-fallback.md.

Usage: jira_cookie_extract.py HOST [BROWSER]
  HOST    the cookie domain to match, e.g. your-site.atlassian.net
  BROWSER optional: one browser_cookie3 function name (chrome, chromium, firefox, edge, brave,
          ...) to pin extraction to. Omitted/empty -> browser_cookie3.load() tries all of them.

Exit codes: 0 success (cookie string on stdout), 1 no cookies found, 2 browser_cookie3 not
installed, 3 bad arguments.
"""
import sys

try:
    import browser_cookie3
except ImportError:
    print(
        "browser_cookie3 is not installed — run: pip install browser_cookie3",
        file=sys.stderr,
    )
    sys.exit(2)


def main() -> int:
    if len(sys.argv) < 2 or not sys.argv[1]:
        print("usage: jira_cookie_extract.py HOST [BROWSER]", file=sys.stderr)
        return 3
    host = sys.argv[1]
    browser = sys.argv[2] if len(sys.argv) > 2 else ""

    cookies = []
    if browser:
        fn = getattr(browser_cookie3, browser, None)
        if fn is None:
            print(f"browser_cookie3 has no browser named '{browser}'", file=sys.stderr)
            return 3
        try:
            cookies = list(fn(domain_name=host))
        except Exception as exc:  # browser_cookie3 raises varied, browser-specific errors
            print(f"could not read {browser} cookies: {exc}", file=sys.stderr)
            return 1
    else:
        # Deliberately not browser_cookie3.load(): it only catches its own BrowserCookieError, so
        # one broken/unsupported browser probe (e.g. a snap-confined install with no resolvable
        # profile path) raises a raw exception and kills the whole "try everything" scan instead of
        # just being skipped. Do the same scan ourselves with a broad per-browser catch.
        for probe in browser_cookie3.all_browsers:
            try:
                cookies.extend(probe(domain_name=host))
            except Exception:
                continue

    cookie_str = "; ".join(f"{c.name}={c.value}" for c in cookies)
    if not cookie_str:
        print(
            f"no session cookies found for {host} — are you logged into Jira in your browser?",
            file=sys.stderr,
        )
        return 1

    print(cookie_str)
    return 0


if __name__ == "__main__":
    sys.exit(main())
