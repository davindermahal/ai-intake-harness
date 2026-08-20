# Plan: Jira label-based tracker adapter (shared project, multi-repo via app tag)

**Status**: completed
**Created**: 2026-08-13
**Updated**: 2026-08-20

> Superseded design note: earlier drafts of this plan assumed a non-Jira, status-less tool kept
> private to a work-only vendoring boundary. That framing is gone — see `git log -- '.ai/plans/**'`
> around commit `4f5c69d` for the abandoned approach; the draft file itself has been removed.

## Goal

Support one **shared Jira project used by multiple repos**. Each repo runs its own install of this
harness (vendored the normal way) and is assigned a unique **app tag** (e.g. `app:my-app-name-1`).
The tracker adapter uses that tag to scope every query to just that repo's tickets within the
shared project. Within a repo's own tickets, the AI workflow's fine-grained steps are represented
as **labels** (`state:<step>`) rather than Jira's native status field — the project only has three
native statuses (`Todo`, `In Progress`, `Code Review`), too coarse to carry the harness's full
abstract state machine (see `docs/architecture.md`'s `Backlog → Selected → Ready for Planning →
Needs Author Input ⇄ Ready for Planning → Plan Review → Ready for Implementation → In Progress →
Ready for Verification → Done`). The board is also **locked down past `Code Review`** — nothing in
this adapter ever attempts a native-status move beyond it.

The shared project may have **multiple assigned users**, each potentially running their own harness
install against it, so every read/write the adapter performs must be scoped to tickets assigned to
its own authenticated account — never act on someone else's ticket just because it matches the app
tag.

This is genuinely generic (no company-specific logic), so it lives directly in this public repo's
`lib/tracker/`, not a private/vendored extension. **The existing `lib/tracker/jira.sh` adapter's
behavior is unchanged** — status-based Jira projects keep working exactly as they do today; this is
an additional adapter selected via `TRACKER=jira-tags`.

## Scope

**In scope:**
- New `lib/tracker/jira-tags.sh` adapter implementing the full `tracker_*` contract.
- Extracting shared REST/auth/comment-footer plumbing out of `jira.sh` into
  `lib/tracker/jira-common.sh`, refactor-only (no behavior change to `jira.sh`).
- Wiring `TRACKER_APP_TAG` into `lib/intake-config.sh`'s config precedence handling.
- Fixing `tracker-comment.sh` / `tracker-transition.sh` to respect `TRACKER` instead of hardcoding
  `jira.sh` — a pre-existing gap that blocks *any* second adapter, not specific to this one.
- README documentation for the new adapter and config key.

**Out of scope:**
- A second auth backend (browser session cookie instead of API token) — only the extraction seam
  that would let one be added later, not the cookie-based adapter itself.
- Ticket creation / auto-tagging at creation time — nothing in this harness creates tickets today.
- The GitHub Issues adapter placeholder, or any project/AI adapter code.

## Key decisions

1. **Native-status mirroring.** The project's three real statuses collapse the tag vocabulary as:
   - `Todo` — pre-pipeline only (`Backlog`/`Selected`). The adapter **never writes** this status;
     a ticket simply starts here, untagged, until a human applies `state:ready-for-planning`.
   - `In Progress` — every active-but-not-yet-verified tag state: `ready-for-planning`,
     `needs-author-input`, `plan-review`, `ready-for-implementation`, `in-progress`.
   - `Code Review` — `ready-for-verification` and `done` (board locked past here; no further status
     move is ever attempted).

   Every write to a `state:*` label also best-effort mirrors the native status via this table (see
   `jira_tags_set_state` in step 2 below). If the native-status move itself fails (e.g. no legal
   Jira transition from the ticket's current status, or the board genuinely won't allow it), that
   failure is logged to stderr but does **not** fail the call — the label write, which is this
   adapter's actual source of truth, has already succeeded.

2. **Transition legality is self-enforced (defense-in-depth).** Jira's transitions API gives
   `jira.sh` "reject an illegal move" for free; labels give nothing for free. `jira-tags.sh`
   replicates that guarantee with its own legal-move table (`jira_tags_legal_move`, step 2),
   checked on every write — both the poller-driven `tracker_transition` and the human-facing
   `tracker_transition_to_status` (what `tracker-transition.sh` calls). This is in addition to, not
   instead of, the structural guarantee both adapters already share: `tracker_transition`'s own
   case statement has no `ready-for-implementation` case, so the automation can never emit that
   transition regardless of what any legality table would allow.

3. **Multi-user isolation via assignee scoping.** `tracker_search` adds `assignee = currentUser()`
   to every JQL query, so a harness install only ever *sees* tickets assigned to its own
   authenticated Jira account. Every write path — `tracker_transition`, `tracker_transition_to_status`,
   **and `tracker_add_comment`** — additionally re-checks the ticket's current assignee against the
   authenticated account immediately before writing, closing the race window between a search and
   an act (e.g. a ticket reassigned between poll cycles). This is deliberately the more restrictive
   option while this adapter is new/experimental, even though a stray comment is less damaging than
   a stray label write. If this ever needs relaxing (e.g. comments should be postable regardless of
   assignee), add a config key to `.ai/intake.config` (e.g. `TRACKER_GATE_COMMENTS=false`) rather
   than building a generic settings/feature-flag mechanism for it — there's no second use case yet
   to justify one.

4. **`lib/tracker/jira-common.sh` extraction**, shared by both `jira.sh` and `jira-tags.sh`:
   env loading, the `jira_api` curl wrapper, the raw-JQL search helper, and the AI-comment-footer
   `tracker_add_comment` body. The credential/auth step within that env loading is isolated behind
   one small function (`jira_auth_curl_opts`) specifically so a future non-API-key auth mode (e.g.
   a browser session cookie, for users without an API token) can replace just that function later
   without touching `jira_api`'s callers. **Only the API-key path is implemented now** — this is a
   seam, not a second auth adapter.

5. **`tracker-comment.sh` / `tracker-transition.sh` fixed** to source the `TRACKER`-selected
   adapter via `lib/intake-config.sh`, matching how `intake-poll.sh` already does it, instead of
   hardcoding `. lib/tracker/jira.sh`. Without this fix neither human-facing helper script can work
   with `jira-tags.sh` (or any second adapter) at all.

6. **`TRACKER_APP_TAG`** — new, required, non-secret config key (`app:<name>`, unique per repo),
   committed to `.ai/intake.config` (not `.env`, since it identifies a repo/install, not a
   credential). `jira-tags.sh`'s `tracker_load_env` fails loudly (`:?`-style guard) if it's unset,
   mirroring the existing Jira secret guards.

7. **No ticket-creation support** — confirmed out of scope; nothing in the harness creates tickets
   today.

## Tag & status vocabulary

| Abstract state | Jira tag | Who sets it |
|---|---|---|
| Ready for Planning | `state:ready-for-planning` | human (entry point) / human (re-plan loop) |
| Needs Author Input | `state:needs-author-input` | poller |
| Plan Review | `state:plan-review` | poller |
| Ready for Implementation | `state:ready-for-implementation` | **human only** (approval gate, via `tracker-transition.sh`) |
| In Progress | `state:in-progress` | poller |
| Ready for Verification | `state:ready-for-verification` | worker (via `tracker-transition.sh`) |
| Done | `state:done` | human |

`Backlog`/`Selected` are pre-pipeline (the harness never watches them) — no tag is needed; a ticket
carries no `state:*` label until a human adds `state:ready-for-planning`.

| Tag state(s) | Native status |
|---|---|
| *(no `state:*` label yet — pre-pipeline)* | `Todo` |
| `ready-for-planning`, `needs-author-input`, `plan-review`, `ready-for-implementation`, `in-progress` | `In Progress` |
| `ready-for-verification`, `done` | `Code Review` |

Legal `state:*` moves (`jira_tags_legal_move`, enforced on every write):
```
ready-for-planning       → needs-author-input | plan-review
needs-author-input       → ready-for-planning
plan-review              → ready-for-implementation        (human only, never automated)
ready-for-implementation → in-progress
in-progress               → ready-for-verification | ready-for-implementation   (re-run/retry)
ready-for-verification   → ready-for-implementation | done                       (bounce / close)
```

## Files to change

- `lib/tracker/jira-common.sh` (**new**) — shared REST/auth/comment-footer helpers extracted from `jira.sh`.
- `lib/tracker/jira.sh` (**modify**, refactor only) — delegates to `jira-common.sh`; no behavior change.
- `lib/tracker/jira-tags.sh` (**new**) — the tag-based adapter.
- `lib/intake-config.sh` (**modify**) — add `TRACKER_APP_TAG` to the env>config precedence list.
- `tracker-comment.sh` (**modify**) — source the configured adapter instead of hardcoding `jira.sh`.
- `tracker-transition.sh` (**modify**) — same fix.
- `README.md` (**modify**) — document the new adapter and `TRACKER_APP_TAG`.

## Implementation order

### 1. Extract `lib/tracker/jira-common.sh` from `jira.sh` (no behavior change)

- Create `lib/tracker/jira-common.sh` with the standard double-source guard, then move from
  `jira.sh` (verbatim logic, no changes):
  - `jira_common_load_env REPO_ROOT` — the `.env`/`.env.local` parsing loop, the three
    `JIRA_SITE_URL`/`JIRA_INTAKE_EMAIL`/`JIRA_INTAKE_API_TOKEN` `:?`-guards, the scheme-normalizing
    logic, and the `jq`/`curl` presence checks — everything currently in `jira.sh`'s
    `tracker_load_env`.
  - `jira_auth_curl_opts` (**new function, but not new behavior**) — returns the `-u
    "$JIRA_INTAKE_EMAIL:$JIRA_INTAKE_API_TOKEN"` curl args as a string. `jira_api` calls this
    instead of inlining the `-u` flag. This is the one seam a future non-API-key auth mode would
    replace.
  - `jira_api METHOD PATH [JSON_BODY]` — moved verbatim except using `jira_auth_curl_opts`.
  - `jira_search_jql JQL` — moved verbatim (both adapters use raw JQL executed the same way).
  - `jira_myself_account_id` (**new**) — `jira_api GET /rest/api/2/myself | jq -r '.accountId'`,
    memoized in `_JIRA_MYSELF_ACCOUNT_ID` for the process lifetime. Not used by `jira.sh`; exists
    here because `jira-tags.sh` needs it and the REST plumbing belongs in one place.
  - `JIRA_AI_COMMENT_FOOTER` and `jira_common_add_comment KEY TEXT` — moved verbatim from `jira.sh`'s
    `tracker_add_comment` body.
- Update `jira.sh`: source `jira-common.sh` at the top (after its own double-source guard);
  `tracker_load_env` becomes `jira_common_load_env "$1"` (jira.sh needs no extra validation beyond
  the shared secrets); `tracker_add_comment` becomes a one-line wrapper over
  `jira_common_add_comment`. `tracker_search`, `tracker_get_issue`, `tracker_transition_to_status`,
  `tracker_transition`, and `tracker_ticket_regex` are untouched — they already only call `jira_api`
  / `jira_search_jql`, which now resolve to the common versions.
- **Acceptance check:** `bash -n lib/tracker/jira-common.sh lib/tracker/jira.sh` (syntax OK); with a
  real `.env` configured for a status-based Jira project, `bash -c '. lib/tracker/jira.sh;
  tracker_load_env .; tracker_search planning'` returns the same ticket keys as before the refactor;
  `shellcheck lib/tracker/jira-common.sh lib/tracker/jira.sh` clean (or no new warnings vs. today's
  `jira.sh`).

### 2. Write `lib/tracker/jira-tags.sh`

- Source `jira-common.sh`.
- `tracker_load_env REPO_ROOT`: `jira_common_load_env "$1"`, then `: "${TRACKER_APP_TAG:?set
  TRACKER_APP_TAG in .ai/intake.config}"`.
- `tracker_search QUEUE`: builds JQL per queue and calls `jira_search_jql`:
  ```
  project = ${TRACKER_PROJECT_KEY} AND labels = "${TRACKER_APP_TAG}" AND labels = "state:<step>" \
    AND assignee = currentUser() ORDER BY created ASC
  ```
  `<step>` is `ready-for-planning` for `planning`, `ready-for-implementation` for
  `implementation`, `in-progress` for `in-progress` — same three queue names as `jira.sh`.
- `tracker_get_issue KEY`: `jira_api GET "/rest/api/2/issue/$1?fields=summary,status,description,comment,labels,assignee"`
  (adds `assignee` to the field list `jira.sh` fetches).
- `tracker_add_comment KEY TEXT`: calls `jira_tags_assert_assignee "$KEY"` first (return 1 on
  failure), then wraps `jira_common_add_comment` — same assignee guard as the write paths below
  (Key decision 3).
- `tracker_ticket_regex`: identical to `jira.sh` — `printf '%s' "${TRACKER_PROJECT_KEY}-[0-9]+"`.
- Internal `jira_tags_current_state KEY`: fetch labels via `tracker_get_issue`, extract the
  `state:*` label, echo the bare step name. Error to stderr and return 1 if none or more than one
  is found (data-integrity guard — a ticket should carry exactly one `state:*` label at a time).
- Internal `jira_tags_legal_move CURRENT TARGET`: a `case` implementing the edge table above;
  returns 1 with a stderr message (`"illegal move: $CURRENT -> $TARGET"`) for anything not listed.
- Internal `jira_tags_native_status TARGET`: a `case` implementing the tag→status table above,
  echoing `Todo` / `In Progress` / `Code Review`.
- Internal `jira_tags_assert_assignee KEY`: fetch the issue's `assignee.accountId` (via
  `tracker_get_issue`), compare to `jira_myself_account_id`. Return 1 with a stderr message
  (`"$KEY is not assigned to the authenticated account — refusing to act"`) on any mismatch or
  unassigned ticket.
- Internal `jira_tags_set_state KEY TARGET` — the single chokepoint both write functions below
  funnel through:
  1. `jira_tags_assert_assignee "$KEY"` — return 1 on failure.
  2. `current="$(jira_tags_current_state "$KEY")"` — return 1 on failure.
  3. `jira_tags_legal_move "$current" "$TARGET"` — return 1 on failure.
  4. `PUT /rest/api/2/issue/$KEY` with
     `{"update":{"labels":[{"remove":"state:$current"},{"add":"state:$TARGET"}]}}`.
  5. If `jira_tags_native_status "$TARGET"` differs from the issue's current status, attempt the
     native-status move the same way `jira.sh`'s `tracker_transition_to_status` does (find the
     transition id whose `.to.name` matches, POST it); log a stderr warning and continue (don't
     fail the call) if unavailable.
- `tracker_transition KEY ABSTRACT_STATE` (poller-driven; same four cases as `jira.sh` —
  `needs-author-input`, `plan-review`, `in-progress`, `ready-for-verification`, **no
  `ready-for-implementation` case**): validates the case, then calls `jira_tags_set_state "$KEY"
  "$ABSTRACT_STATE"`.
- `tracker_transition_to_status KEY TARGET` (same function name as `jira.sh` so
  `tracker-transition.sh` stays adapter-agnostic; here `TARGET` is a `state:<step>` step name, e.g.
  `ready-for-implementation`, not a Jira status display name): calls `jira_tags_set_state "$KEY"
  "$TARGET"` directly. This is the entry point a human uses by hand to perform
  `plan-review → ready-for-implementation`.
- **Acceptance check:** `shellcheck lib/tracker/jira-tags.sh` clean. Against a real test ticket in
  the shared project (`app:<test-app>` + `state:ready-for-planning`, assigned to the API user):
  `TRACKER=jira-tags TRACKER_APP_TAG=app:<test-app> bash -c '. lib/intake-config.sh .;
  tracker_search planning'` echoes that ticket's key. `tracker-transition.sh <KEY>
  ready-for-implementation` run from `plan-review` succeeds, flips the label and the native status
  to `In Progress`. The same command attempted from an illegal current state (e.g.
  `needs-author-input`) is refused with a clear stderr message and no label change. Reassigning the
  test ticket to a different user and re-running any transition is refused by the assignee check.

### 3. Wire `TRACKER_APP_TAG` into `lib/intake-config.sh`

- Add `TRACKER_APP_TAG` to the `_intake_env_keys` list (~line 34-36) so the env>config precedence
  snapshot/restore covers it like every other adapter-specific key.
- No default-export line for it (unlike `TRACKER_PROJECT_KEY`'s `PROJ` default) — there's no sane
  default; `jira-tags.sh`'s own `tracker_load_env` guard is what enforces it's set.
- **Acceptance check:** with `TRACKER=jira-tags` and no `TRACKER_APP_TAG` set anywhere, the poller
  fails fast with the guard's message. `TRACKER_APP_TAG=app:foo make worktree-go ...`-style env
  override wins over any `.ai/intake.config` value, matching the existing `PROVIDER`/`MODEL`
  precedence behavior.

### 4. Fix the two hardcoded call sites

- `tracker-comment.sh`: replace `. "$SCRIPT_DIR/lib/tracker/jira.sh"` with sourcing
  `lib/intake-config.sh` (same pattern `intake-poll.sh` already uses), so it picks up whichever
  adapter `TRACKER` selects.
- `tracker-transition.sh`: same fix.
- **Acceptance check:** with `TRACKER=jira-tags` configured, `tracker-comment.sh <KEY> "test"` and
  `tracker-transition.sh <KEY> ready-for-implementation` both operate against `jira-tags.sh`
  (confirm the comment/label land on the test ticket). With `TRACKER=jira` unchanged, both scripts
  still work exactly as before against `jira.sh`.

### 5. README updates

- Add `jira-tags` next to the existing "Built-in adapter: `lib/tracker/jira.sh`" line
  (`README.md:215`), briefly describing the shared-project/app-tag/state-tag model.
- Add `TRACKER_APP_TAG` to the `.ai/intake.config` example block (`README.md:83-87`), noting it's
  required only for `TRACKER=jira-tags`.
- **Acceptance check:** doc-only, reviewed by eye.

## Boundaries

- Do not change `jira.sh`'s *behavior* — only its internals move into `jira-common.sh`; a
  status-based Jira project must see zero functional change.
- Do not implement the cookie/session auth path — only the `jira_auth_curl_opts` seam that would
  let it be added later.
- Do not add ticket-creation/auto-tagging support.
- Do not touch the GitHub Issues adapter placeholder or any project/AI adapter code.
- The automation must never write `state:ready-for-implementation` — enforced both structurally
  (absent from `tracker_transition`'s cases) and by the legal-move table (reachable only from
  `plan-review`, only via the human-facing `tracker_transition_to_status` entry point).
- Every write path (`tracker_transition`, `tracker_transition_to_status`, `tracker_add_comment`)
  must refuse to act on a ticket not assigned to the authenticated account. Don't build a general
  settings/feature-flag mechanism to make this toggleable — if it needs relaxing later, add one
  config key to `.ai/intake.config`, the same way every other adapter setting already works.

## Open questions (non-blocking)

- `jira_tags_assert_assignee` / `jira_tags_legal_move` failures currently just go to stderr (poller
  log), not a ticket comment — matches how `jira.sh`'s own internal guard failures behave today.
  Now that `tracker_add_comment` is also assignee-gated, this means a worker whose ticket was
  reassigned mid-flight fails to report back **silently from the ticket's point of view** (visible
  only in the poller log) — since the one channel that would normally announce a problem is itself
  the gated call. Revisit if this turns out to need a visible signal (e.g. logging louder, or an
  ungated last-resort escalation path) rather than just the poller log.
