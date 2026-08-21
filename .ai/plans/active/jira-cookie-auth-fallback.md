# Plan: Jira browser-cookie auth fallback (no API token available)

**Status**: completed
**Branch**: feature/jira-authentication-by-cookie
**Created**: 2026-08-20
**Updated**: 2026-08-20

## Implementation notes (2026-08-20)

Implemented per this plan: `lib/tracker/jira_cookie_extract.py` + `lib/tracker/jira-cookie.sh`
(new), `lib/tracker/jira-common.sh` (auth-mode resolution incl. the `JIRA_AUTH_MODE` test override,
eager `/myself` validation, `jira_auth_mode`/`jira_myself_display_name` accessors, `jira_api`
non-JSON response guard), `jira.sh`/`jira-tags.sh` header-comment updates (no logic changes),
`.env.local.dist`, `install.sh` (`--test-cookie` flag, `(auth: ...)` reporting), `README.md`,
`docs/design-decisions.md` decision #2, `.ai/system.md`.

Verified: `bash -n` + `shellcheck` (clean) on all changed/new shell files; `python3 -m py_compile`
on the new script. Live end-to-end against a real Jira Cloud account
(`https://dmahal.atlassian.net`), in a repo checkout with a genuinely valid API token already
configured in `.env.local`:
- `install.sh --test-only` — unchanged behavior, now reports `(auth: token)`.
- `install.sh --test-cookie` — **forced cookie mode with the valid token still present**, connected
  successfully via a real extracted browser session cookie, reported `(auth: cookie)`. This is the
  concrete verification the user asked for: proof the cookie path works on its own merits, not just
  as an untested fallback.
- `JIRA_AUTH_MODE=token` override, and `JIRA_COOKIE_BROWSER` pinning to a specific browser, both
  confirmed.
- Failure paths confirmed to fail loudly with actionable messages rather than crashes/garbage:
  `browser_cookie3` not installed (pip-install hint), no cookies found for a nonexistent domain,
  and an invalid/expired cookie (Jira's actual response was a plain-text "Client must be
  authenticated..." body — confirmed the non-JSON response guard in `jira_api` catches this
  correctly rather than feeding it to `jq`).
- **Bug found and fixed during live testing**: the default "try every installed browser" path
  (no `JIRA_COOKIE_BROWSER` set) initially crashed with `TypeError: expected str, bytes or
  os.PathLike object, not NoneType`. Root cause: `browser_cookie3.load()` only catches its own
  `BrowserCookieError`, so a broken/unsupported browser probe on this machine (a snap-confined
  install with no resolvable profile path) raised a raw exception and killed the whole scan instead
  of being skipped. Fixed in `jira_cookie_extract.py` by not calling `browser_cookie3.load()`
  directly — instead iterating `browser_cookie3.all_browsers` with a broad per-browser
  `except Exception: continue`, matching what `load()` was supposed to do. Confirmed working after
  the fix.
- Also surfaced, not a code bug: pinning `JIRA_COOKIE_BROWSER=chrome` on the test machine picked up
  a stale/invalid session cookie (a different, logged-out account) sitting in that browser's cookie
  store, correctly triggering the non-JSON-response failure path. The default (unpinned) scan found
  a working session in a different browser instead — real-world confirmation that the "try
  everything, first match wins" default is the right one, and that pinning one browser is
  best-effort (see "Open questions").

## Goal

Support Jira accounts that **cannot get an API token issued** (e.g. an org policy blocks
self-service Atlassian API tokens). For those accounts, the harness authenticates using the
session cookie from the user's already-logged-in browser (Chrome or Firefox) on the same machine
that runs the poller, instead of `JIRA_INTAKE_EMAIL` + `JIRA_INTAKE_API_TOKEN`.

Resolution order, decided once per process invocation (`intake-poll.sh` each poll cycle,
`tracker-comment.sh` / `tracker-transition.sh` each human invocation):

```
JIRA_INTAKE_EMAIL and JIRA_INTAKE_API_TOKEN both set and non-placeholder?
  yes → Basic auth (unchanged, existing behavior)
  no  → extract a fresh session cookie from the local browser and use Cookie auth
        (fails loudly, with a specific message, if that also doesn't work)
```

This exactly matches the seam `lib/tracker/jira-common.sh` already calls out for it:
`jira_auth_curl_opts` is "the one seam a future non-API-key auth mode would replace." Only the
API-key path exists today; this plan implements the second one. Source reference:
`.ai/guides/jira_authentication_report.md`.

**The cookie is never written to disk** (not to `.env.local`, not to a temp file) — it's extracted
fresh into a shell variable at the start of each process and held only in that process's memory.
This is a deliberate security choice (a session cookie is bearer-equivalent to the logged-in
human's full Jira access, broader than a scoped API token) and it's also what makes "auto-refresh"
work for free: as long as the human stays logged into Jira in their browser, each new poll cycle
re-extracts a live cookie without anyone doing anything. See "Key decisions" #4 for what happens
when that's no longer true.

## Scope

**In scope:**
- A new `lib/tracker/jira-cookie.sh` module: browser cookie extraction (via a small Python helper,
  see decision #2) plus building the `Cookie` / `X-Atlassian-Token` curl headers.
- `lib/tracker/jira-common.sh` changes: make `JIRA_INTAKE_EMAIL` / `JIRA_INTAKE_API_TOKEN`
  optional, resolve auth mode, source the new module, and validate the resolved credentials with
  one eager `GET /rest/api/2/myself` call so a bad token *or* a stale/missing cookie fails loudly
  at load time instead of deep inside the first real tracker call.
- `jira_api` response validation: detect a non-JSON body (Atlassian's actual failure mode for an
  expired cookie is often an HTML login page with HTTP 200, not a clean 401) so a mid-cycle expiry
  during `tracker_transition` / `tracker_add_comment` also fails loudly instead of feeding an HTML
  page into `jq` and silently producing nulls.
- `install.sh` / `.env.local.dist` / `README.md` / `docs/design-decisions.md` updates describing
  the new mode, its setup (`pip install browser_cookie3`), and its trade-offs.
- A `JIRA_AUTH_MODE` override plus `install.sh --test-cookie`, so the cookie path can be verified
  end-to-end — against a real Jira account, with a real API round-trip — **even when a valid API
  token is also configured** in `.env.local`. Without this, the only way to exercise cookie auth
  would be to actually break your working token config first, which is a bad way to test anything.

**Out of scope:**
- Persisting or manually pasting a cookie string (`JIRA_COOKIE=...` in `.env.local`). The user
  asked specifically for automatic browser extraction; a manual-paste path is easy to add later if
  ever needed but isn't built now (avoids two cookie-sourcing code paths for one requirement).
- Any change to `jira.sh` / `jira-tags.sh`'s own logic — both keep working through `jira_api` /
  `jira_search_jql` exactly as today; only what backs those calls changes.
- Any tracker other than the two Jira adapters (GitHub Issues, etc. are unaffected).
- True "log back in" automation (storing/replaying a password, driving an SSO/MFA flow). See
  decision #4 for why this is explicitly not attempted.

## Key decisions

1. **Cookie extraction lives in a new Python helper, not pure bash.** Chrome encrypts its cookie
   store via the OS keyring (GNOME Keyring/KWallet on Linux); decrypting that in bash isn't
   practical, and Firefox's *unencrypted* `cookies.sqlite` path (the guide's bash+`sqlite3` option)
   would mean two separate, browser-specific extraction paths to maintain for one requirement. The
   Python library `browser_cookie3` already handles both browsers (and others) uniformly and does
   its own OS-keyring integration, matching the guide's §5/§6 recommendation. This is the **one**
   new non-bash, non-`jq`/`curl` dependency this repo picks up, and it's scoped strictly to users
   who don't have an API token — anyone with a token needs no Python at all.
   - `lib/tracker/jira_cookie_extract.py` (new): a small script, no repo-specific logic, that calls
     `browser_cookie3.load(domain_name=HOST)` (tries every browser it knows about and merges
     results) or `browser_cookie3.<name>(domain_name=HOST)` for one specific browser if
     `JIRA_COOKIE_BROWSER` is set, formats matches as `name=value; name2=value2`, prints to stdout,
     exits non-zero with a message on stderr if nothing is found.
   - `HOST` is parsed from `JIRA_SITE_URL` (strip scheme/path), e.g. `your-site.atlassian.net` —
     same domain-matching scope as the guide's Rust reference (`<domain>.atlassian.net`), not the
     broader `atlassian.com` SSO domain. Flagged as an open question below for orgs where that
     turns out to be insufficient.
2. **`JIRA_COOKIE_BROWSER`** (optional, `.ai/intake.config`, not `.env.local` — it's a mode
   selector, not a secret, same reasoning as `TRACKER_APP_TAG`): pins extraction to one browser
   (`chrome`, `chromium`, `firefox`, `edge`, `brave`, ...; any name `browser_cookie3` recognizes).
   Default (unset): try all installed browsers, first non-empty match for the Jira domain wins.
   Only useful if someone is logged into Jira in a non-default browser/profile; not required for
   the common case.
3. **Eager auth validation moves into `jira_common_load_env` for both modes.** Today neither
   adapter validates the token actually works until the first real tracker call fails somewhere
   deep in the poller. This plan adds one `GET /rest/api/2/myself` call right after credentials are
   resolved, checked for `.accountId`, with a mode-specific error message on failure ("check
   `JIRA_INTAKE_EMAIL`/`JIRA_INTAKE_API_TOKEN`" for token mode; "log into Jira in your browser and
   re-run" for cookie mode). This is an intentional, called-out behavior change to *both* existing
   adapters (one extra API call per process start) — accepted because it's the mechanism that makes
   "fail loudly" (the user's explicit requirement for expired cookies) actually happen at a useful
   point, and because it removes a genuine footgun that already existed for token mode (a typo'd
   token today fails confusingly inside whatever the first real call happens to be). The resolved
   `accountId` is cached into the existing `_JIRA_MYSELF_ACCOUNT_ID` memo while we're at it, so
   `jira-tags.sh`'s `jira_myself_account_id` (needed for every assignee check) doesn't cost a
   second call in the common case.
4. **No automatic re-login.** The user asked whether the harness could log back in automatically
   when a session has fully expired (not just gone stale-but-refreshable). It can't be done safely:
   there's no password on file (storing one would defeat the entire point of using a token-free,
   cookie-based mode instead of just storing a password), and most orgs front Jira with SSO + MFA
   that isn't scriptable regardless. What this plan *does* give you for free is the next best thing:
   because the cookie is re-extracted from the browser fresh on every process start rather than
   cached, if the browser's own session is still alive (most Atlassian sessions are long-lived,
   e.g. weeks, via "remember me") the harness picks up a fresh cookie automatically every poll cycle
   with no action from the human. Only when the browser session itself has actually ended does
   extraction fail — at that point the harness fails loudly (decision #3) with a message telling
   the human to log into Jira in their browser again; nothing it can do beyond that.
5. **`jira_api` gets minimal response-shape validation**, not a full schema check: if the response
   body's first non-whitespace character isn't `{` or `[`, treat it as an auth/network failure
   (most likely an HTML login-redirect page) and return non-zero with a clear stderr message,
   instead of letting a downstream `jq -r '.foo // empty'` silently coerce garbage into an empty
   string. Existing "valid JSON but Jira reports an error" handling (`.errorMessages`/`.errors`
   checks already in `jira_common_add_comment`, `jira_search_jql`) is untouched — this only catches
   the non-JSON case those checks can't see.
6. **`JIRA_AUTH_MODE` is a testing/verification override, not a persistent config knob.** Set to
   `token` or `cookie`, it overrides decision-time inference in `jira_common_load_env` — e.g.
   `JIRA_AUTH_MODE=cookie` forces cookie auth even though a valid `JIRA_INTAKE_API_TOKEN` is sitting
   right there in `.env.local`. This is what makes "verify the cookie path actually works" possible
   without touching your working token config: the eager `/rest/api/2/myself` validation call
   (decision #3) now happens over cookie auth specifically, against your real Jira account, and its
   success message reports which mode it used (`connected to ... as ... (cookie auth)`) so there's
   no ambiguity about which credential path was actually exercised. It's meant to be set ad hoc on
   the command line for a one-off check (or via `install.sh --test-cookie`, step 4), not committed
   anywhere — the day-to-day resolution stays the presence-based inference in the Goal section.

## Files to change

- `lib/tracker/jira_cookie_extract.py` (**new**) — the `browser_cookie3` extraction helper.
- `lib/tracker/jira-cookie.sh` (**new**) — `jira_cookie_available` (python3 + `browser_cookie3`
  present, with an actionable error if not) and `jira_cookie_fetch` (parses `JIRA_SITE_URL`'s host,
  invokes the helper, returns the cookie string or fails).
- `lib/tracker/jira-common.sh` (**modify**) — optional email/token, auth-mode resolution (with the
  `JIRA_AUTH_MODE` test override), sourcing `jira-cookie.sh`, the eager `/myself` validation call
  (reporting which mode it used), `jira_api` response-shape validation.
- `lib/tracker/jira.sh`, `lib/tracker/jira-tags.sh` (**modify, comments only**) — update the
  "Required env" header comments; no logic changes, both already go through `jira_common_load_env`
  / `jira_api` / `jira_search_jql`.
- `.env.local.dist` (**modify**) — document email/token as one option, note the cookie fallback and
  its `pip install browser_cookie3` prerequisite.
- `install.sh` (**modify**) — update the fill-in instructions; add a `browser_cookie3` import
  preflight check (with an actionable message) when it looks like cookie mode will be used; add a
  `--test-cookie` flag that verifies the cookie path specifically, regardless of what's in
  `.env.local`.
- `README.md` (**modify**) — Quickstart step 2 and the "Built-in adapter" bullets get the second
  auth mode documented.
- `docs/design-decisions.md` (**modify**) — extend decision #2 with the new trade-off (see
  "Boundaries").

## Implementation order

### 1. `lib/tracker/jira_cookie_extract.py` + `lib/tracker/jira-cookie.sh`

- `jira_cookie_extract.py`: argv is `HOST [BROWSER]`. `import browser_cookie3` inside a
  `try/except ImportError` that prints an actionable "pip install browser_cookie3" message to
  stderr and exits 2 (a distinct code from "no cookies found," so `jira-cookie.sh` can give a
  different error message for each). If `BROWSER` is given, call
  `getattr(browser_cookie3, BROWSER)(domain_name=HOST)`; else `browser_cookie3.load(domain_name=HOST)`.
  Format matches as `name=value` joined with `; `. Empty result → exit 1 with a stderr message
  ("no session cookies found for HOST — are you logged into Jira in your browser?"). Non-empty →
  print the cookie string to stdout, exit 0.
- `jira-cookie.sh`:
  - `jira_cookie_available`: `command -v python3` and `python3 -c "import browser_cookie3"`, both
    checked with a clear stderr message on failure (distinguish "no python3" vs "pip install
    browser_cookie3").
  - `jira_cookie_fetch`: derive `HOST` from `$JIRA_SITE_URL` (strip `https://`/`http://`, strip any
    trailing path), call `jira_cookie_available` first, then run
    `python3 "$_jira_cookie_dir/jira_cookie_extract.py" "$HOST" "${JIRA_COOKIE_BROWSER:-}"`,
    echoing stdout on success / propagating the helper's stderr + exit code on failure.
- **Acceptance check:** with a browser on the test machine logged into a real Jira Cloud site,
  `bash -c '. lib/tracker/jira-cookie.sh; JIRA_SITE_URL=https://your-site.atlassian.net jira_cookie_fetch'`
  prints a non-empty `name=value; ...` string. With `browser_cookie3` not installed,
  `jira_cookie_available` fails with the pip-install message rather than a raw Python traceback.

### 2. `lib/tracker/jira-common.sh`: optional credentials, auth-mode resolution, eager validation

- Source `jira-cookie.sh` at the top (own double-source guard, same pattern as `jira.sh` sourcing
  `jira-common.sh`).
- In `jira_common_load_env`, keep the `JIRA_SITE_URL:?` guard as-is (always required — it's also
  the cookie domain). Drop the `JIRA_INTAKE_EMAIL:?` / `JIRA_INTAKE_API_TOKEN:?` guards; instead:
  ```
  if [ -n "${JIRA_AUTH_MODE:-}" ]; then
      _JIRA_AUTH_MODE="$JIRA_AUTH_MODE"   # test override — decision #6
  elif [ -n "${JIRA_INTAKE_EMAIL:-}" ] && [ -n "${JIRA_INTAKE_API_TOKEN:-}" ]; then
      _JIRA_AUTH_MODE=token
  else
      _JIRA_AUTH_MODE=cookie
  fi
  ```
  If `JIRA_AUTH_MODE=token` is forced but email/token aren't actually set, this fails at the
  `jira_auth_curl_opts` step below with a plain "would use token auth but JIRA_INTAKE_EMAIL/
  JIRA_INTAKE_API_TOKEN aren't set" message — no separate guard needed for that combination.
- `jira_auth_curl_opts` branches on `_JIRA_AUTH_MODE`:
  - `token`: unchanged — `_JIRA_AUTH_OPTS=(-u "$JIRA_INTAKE_EMAIL:$JIRA_INTAKE_API_TOKEN")`.
  - `cookie`: `cookie="$(jira_cookie_fetch)"` — bail with `:?`-style message
    ("could not get a Jira session cookie — log into Jira in your browser, then retry" plus
    whatever `jira_cookie_fetch` already put on stderr) if that fails; else
    `_JIRA_AUTH_OPTS=(-H "Cookie: $cookie" -H "X-Atlassian-Token: no-check")`.
- After `jira_auth_curl_opts` returns successfully, `jira_common_load_env` makes one validation
  call: `resp="$(jira_api GET /rest/api/2/myself)"`; if `jq -e 'has("accountId")'` fails, bail with
  a mode-specific message (see decision #3). On success, memoize
  `_JIRA_MYSELF_ACCOUNT_ID="$(echo "$resp" | jq -r '.accountId')"` so `jira_myself_account_id`
  (below it in the same file) skips its own call when already warm. No new stderr output on the
  success path — every poll cycle already runs this, and `jira_common_load_env` succeeding
  silently is the existing, expected behavior.
- New accessor `jira_auth_mode` — echoes `$_JIRA_AUTH_MODE` (`token` or `cookie`). Exists purely so
  a caller can report *which* path actually succeeded without parsing log text; `install.sh`
  (step 4) is the only caller, for both `--test-only` and the new `--test-cookie`.
- `jira_api`: after the `curl` call, check the first non-whitespace character of the body; if it's
  not `{` or `[`, print a stderr message ("tracker/jira: non-JSON response from Jira — likely an
  expired session cookie or auth failure") and return 1 instead of echoing the body. All existing
  callers already either check `jira_api`'s output with `jq -e` (which would itself fail on HTML)
  or, per decision #5, gain a real failure signal they didn't reliably have before.
- **Acceptance check:** `bash -n lib/tracker/jira-common.sh lib/tracker/jira-cookie.sh` clean;
  `shellcheck` clean (or no new warnings). With `.env.local` fully configured (token mode),
  behavior is unchanged except for the one extra `/myself` call — `tracker_search planning`
  against a real token-mode project still returns the same keys as before this change. With
  `JIRA_INTAKE_API_TOKEN` removed/blank and a real logged-in browser session, the same command
  works via cookie mode. With the browser logged out, `jira_common_load_env` fails loudly with the
  "log into Jira in your browser" message rather than a JSON parse error somewhere downstream.
  **With a fully valid token still configured in `.env.local` and `JIRA_AUTH_MODE=cookie` forced**,
  `tracker_search planning` still returns the same real ticket keys and `jira_auth_mode` echoes
  `cookie` — proof the cookie path works end-to-end independent of whether a token is available,
  not just in the "no token" case.

### 3. `jira.sh` / `jira-tags.sh` header comments

- Update both files' "Required env" comment blocks (currently listing all three `JIRA_*` vars as
  unconditionally required) to describe the two modes and point at `jira-common.sh`'s new
  resolution logic. No function bodies change.
- **Acceptance check:** doc-only, reviewed by eye; `shellcheck` still clean.

### 4. `install.sh`

- Update the "Edit it now and fill in ..." text to describe both options: token (existing
  instructions) or leaving `JIRA_INTAKE_EMAIL`/`JIRA_INTAKE_API_TOKEN` blank/removed to use the
  browser-cookie fallback, noting the `pip install browser_cookie3` prerequisite and that it needs
  to run on the same machine as the logged-in browser.
- Before the connectivity test, if it looks like cookie mode will be used (token still placeholder
  or blank), run `jira_cookie_available` first and surface its message directly rather than letting
  the generic `jira_common_load_env` failure path handle it — gives a more specific first-run error
  than "could not load Jira credentials."
- The existing "OK — connected to $JIRA_SITE_URL as $name" line grows the auth mode:
  `"OK — connected to $JIRA_SITE_URL as $name (auth: $(jira_auth_mode))."` — cheap, always-on
  confirmation of which path actually ran, useful in the ordinary `--test-only` case too (e.g.
  confirming a `.env.local` you expected to be token-mode didn't silently fall back to cookie mode
  because of a typo'd variable name).
- New `--test-cookie` flag: same connectivity test as `--test-only`, but exports
  `JIRA_AUTH_MODE=cookie` for that run only (never written to `.env.local`) before calling
  `jira_common_load_env`. This is the concrete answer to "verify the cookie works even when the API
  key is valid" — run `ai-intake-harness/install.sh --test-cookie` any time, regardless of what
  `.env.local` currently has configured, and it proves cookie auth reaches your real Jira account
  right now, over a real API call, without touching your token setup. On success it prints the same
  "OK — connected to ... (auth: cookie)" line; on failure (browser logged out, `browser_cookie3`
  missing, wrong domain, ...) it surfaces whatever specific error `jira_cookie_available` /
  `jira_cookie_fetch` / the `/myself` validation call produced.
- **Acceptance check:** `install.sh --test-only` against a token-mode `.env.local` behaves exactly
  as before plus the new `(auth: token)` suffix. Against an `.env.local` with a blank/removed token
  and no `browser_cookie3` installed, it prints the pip-install hint instead of a stack trace. With
  `browser_cookie3` installed and a live browser session, it reports "OK — connected to ... as ...
  (auth: cookie)". **`install.sh --test-cookie` run against an `.env.local` that has a fully valid
  token configured** reports "OK — connected to ... (auth: cookie)" — confirming the cookie path
  works on its own merits, not merely as an untested fallback that happens to exist in the code.

### 5. `.env.local.dist` / `README.md` / `docs/design-decisions.md`

- `.env.local.dist`: reframe `JIRA_INTAKE_EMAIL` / `JIRA_INTAKE_API_TOKEN` as "fill these in if you
  have an API token; leave them blank/remove the lines to use the browser-cookie fallback instead
  (requires `pip install browser_cookie3` and being logged into Jira in Chrome or Firefox on this
  machine)."
- `README.md`: Quickstart step 2 gets a short "no API token?" note pointing at the same
  explanation; the "Built-in adapter" bullets for `jira.sh` / `jira-tags.sh` get one added sentence
  noting both now support the cookie fallback via shared `jira-common.sh` plumbing.
- `docs/design-decisions.md` decision #2: add a trade-off paragraph — the cookie fallback is
  opt-out-by-default (only engages when no token is configured), and it's a real, accepted
  departure from "runs unattended on a build host" for the specific case a token can't be issued:
  a session cookie is bearer-equivalent to the full logged-in human (broader than a scoped token),
  the machine running cron must have an actively logged-in browser session (an unlocked desktop
  session, not a headless box), and if that browser session ever fully ends the automation stops
  until a human logs back in — see the new plan doc for the full reasoning.
- **Acceptance check:** doc-only, reviewed by eye.

## Boundaries

- Do not persist a cookie anywhere on disk (`.env.local`, temp files, logs). It only ever lives in
  a shell variable for the lifetime of one process.
- Do not attempt to store or replay a password, or automate an SSO/MFA login flow — decision #4.
- Do not add a manual `JIRA_COOKIE=...` paste-in path — out of scope per the "Scope" section above;
  revisit only if browser auto-extraction turns out not to work for someone's setup.
- Do not change `jira.sh` / `jira-tags.sh`'s own tracker logic (search/transition/comment
  semantics) — only what backs their shared `jira_api` calls changes.
- The one accepted behavior change to the existing token-mode path is the added eager
  `/rest/api/2/myself` validation call (decision #3) — call this out explicitly in the PR
  description; don't let it slip in as an unremarked side effect of the refactor.
- `JIRA_AUTH_MODE` is scoped to testing/verification (decision #6) — don't document it in the
  README's `.ai/intake.config` quickstart block as a normal per-deployment setting, and don't build
  any UI/config affordance around it beyond an env-var override. If a real need for a persistent
  "always use cookie auth even though a token is configured" mode shows up later, that's a
  deliberate follow-up decision, not something this override should be assumed to already cover.

## Open questions (non-blocking)

- Cookie domain scope is `<host-from-JIRA_SITE_URL>` only (matching the reference guide), not the
  broader `atlassian.com` SSO domain. If some orgs' session actually lives on a different cookie
  domain than the tenant's own `*.atlassian.net` host, extraction would come back empty even with
  an active login — not verified against a real org that can't issue tokens yet. Revisit by
  widening `jira_cookie_fetch`'s domain match if that turns out to be needed.
- `browser_cookie3.load()` reads the OS's *default* browser profile per browser; a user logged into
  Jira only in a secondary Chrome profile won't be found without setting `JIRA_COOKIE_BROWSER`
  (which still doesn't disambiguate *profiles*, only browsers). No profile-selection support planned
  unless this turns out to matter in practice.
- The eager `/myself` validation call (decision #3) runs even in token mode now, where it wasn't
  wanted before. If that extra round-trip ever becomes a measurable cost (unlikely at a 2-minute
  poll interval), it could be made cookie-mode-only — not doing that now since the fail-fast benefit
  for token mode seems worth one extra call.
