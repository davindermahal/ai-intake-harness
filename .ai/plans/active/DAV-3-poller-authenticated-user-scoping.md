# Plan: DAV-3 Poller should only pick up the authenticated user's tickets

**Status**: completed
**Branch**: feature/DAV-3-ai-harness-poller-should-only-pick-up-authenticate
**Created**: 2026-08-22
**Updated**: 2026-08-24

## Implementation notes (headless worker, 2026-08-24)

Implemented per this plan, steps 1-5: `tracker_search_unassigned` added to `lib/tracker/jira-tags.sh`
(directly after `tracker_search`); `warn_unassigned_pipeline_tickets` added to `intake-poll.sh` (after
`process_watchdog`) and wired in after the `case "$POLL_MODE"` block; unit test added to
`test/unit/tracker_contract.bats`; integration tests added to `test/integration/dispatch_planning.bats`
(one asserting the warning fires when the adapter defines the function, one asserting a silent no-op
when it doesn't, matching `jira.sh`); FAQ entry added to `docs/faq.md` after "Which issue trackers are
supported?". Verified: `bash -n` on both changed shell scripts (exit 0), and `shellcheck` on all four
changed/added files — each reports only the same info-level notices (SC1091 source-follow, SC2030/
SC2031 bats-subshell-export, SC2317 indirectly-invoked-function) already present on the unchanged
surrounding code / identical existing test patterns; no new warning classes introduced.

**Deviation from plan, disclosed:** step 2's `test/bats-core/bin/bats` acceptance check, step 4's bats
run, and step 6 (`make lint` / `make test`) could not execute — this build ran under this repo's own
locked-down implementation-worker permission profile (`.claude/settings.ai-harness-dev.json`: only
`shellcheck`, `bash -n`, `git status/diff/add/commit/log`, `./tracker-comment.sh` allowed; no general
shell, so no `bats`, `make`, or `git submodule update` — and the bats-core/bats-support/bats-assert
git submodules aren't checked out in this worktree regardless). Same deviation class as DAV-2's
implementation notes. The new tests were written to match the existing suite's established patterns
exactly (same fake/fixture helpers, same assertion style) and read as correct by inspection, but are
unexecuted — re-run `make test` outside this locked-down profile to confirm before relying on them.

Also per this repo's `.ai/plans/active/` → `.ai/plans/completed/` convention, this file should move
to `.ai/plans/completed/` now that Status is `completed` — `git mv` isn't in the locked-down profile's
allowed command list (only `git status/diff/add/commit/log`), so the move didn't happen here; do it
at human review (`git mv .ai/plans/active/DAV-3-poller-authenticated-user-scoping.md
.ai/plans/completed/`).

## Goal

The ticket asks a multi-developer safety question: if several people each run their own harness
checkout against a shared Jira project, does everyone's poller only pick up *their own* tickets, so
two developers never dispatch duplicate work on the same ticket? The ticket description already
contains a prior investigation (a pasted chat transcript) that answered this for the two built-in
tracker adapters. This plan verifies that investigation against the current code, locks the
guarantee down permanently instead of leaving it as a one-off chat answer, and closes the one loose
thread the investigation explicitly left open (what happens to a ticket that sits **unassigned** in
the pipeline).

## Investigation findings (verified against current code)

- **`TRACKER=jira-tags`** (`lib/tracker/jira-tags.sh`) — this repo's own configured adapter, and the
  adapter intended for a Jira project shared by multiple repos/developers — already scopes every
  read and write to the authenticated account:
  - `tracker_search` (line 66-75) appends `assignee = currentUser()` to every JQL query.
  - `jira_tags_assert_assignee` (line 132-141) is a chokepoint every state-changing write
    (`jira_tags_set_state`, line 162) calls first: it re-fetches the ticket and refuses to act
    unless `fields.assignee.accountId` matches the authenticated account, closing the race where a
    ticket is reassigned between search and dispatch.
  - **This is already regression-tested**: `test/unit/tracker_contract.bats:99` ("jira-tags.sh:
    tracker_search scopes JQL to the app tag and assignee=currentUser()") already asserts the JQL
    contains `assignee = currentUser()`. No test gap here — confirmed by reading the test, not
    assumed.
- **`TRACKER=jira`** (`lib/tracker/jira.sh`) — has no assignee clause at all (`tracker_search`,
  line 50-59, is just `project = X AND status = Y`). This is **by design**, not a bug: it's the
  single-account model (`docs/design-decisions.md` #2 — "Full-REST tracker access with an API
  token"), meant for one dedicated account per project/repo. Pointing multiple developers' pollers
  at this adapter against the same project/status would reintroduce duplicate pickup, since nothing
  in this adapter scopes by identity. Out of scope to change (see Scope below).
- **Open thread from the investigation (not yet answered anywhere in the repo):** under
  `jira-tags`, a ticket that has a `state:ready-for-planning`-style label but **no assignee** never
  matches *anyone's* `assignee = currentUser()` search. It doesn't get double-picked-up — it gets
  **zero-picked-up**, silently, forever, with nothing today telling a team that it happened. This is
  the real, actionable gap this plan closes.
- The full answer to the original question exists only as code comments and this ticket's pasted
  chat transcript — not in the committed docs a future team member would actually go read
  (`docs/faq.md`). That's a documentation gap this plan also closes.

## Scope

**In scope:**
- Document the multi-developer assignee-scoping guarantee (and the jira/jira-tags distinction) in
  `docs/faq.md`, so the answer is committed and discoverable instead of living only in a chat
  transcript pasted into a ticket.
- Add `tracker_search_unassigned` to `lib/tracker/jira-tags.sh`: finds tickets under this repo's
  app tag that carry an active pipeline `state:*` label (i.e. still need *someone's* attention) but
  have no assignee.
- Wire it into `intake-poll.sh` so every poll cycle logs a warning for each orphaned ticket found —
  **log only, not a ticket comment** (see Key decisions for why).
- Unit tests locking in the new JQL and the poller's optional-call wiring.

**Out of scope:**
- Changing `lib/tracker/jira.sh`'s single-account model — that adapter intentionally has no
  assignee concept (`docs/design-decisions.md` #2). Not a bug to fix.
- Auto-assigning or auto-labeling unassigned tickets. This plan only makes the situation visible to
  a human; it doesn't decide who a ticket should belong to.
- Any change to `test/unit/tracker_contract.bats:99`'s existing assignee-scoping test — it already
  passes and needs no change.
- A GitHub Issues tracker adapter (not yet built; unrelated to this ticket).

## Files to change

- `lib/tracker/jira-tags.sh` — add `tracker_search_unassigned` (new, adapter-local function; not
  part of the required `tracker_*` contract in `README.md`/`test/unit/tracker_contract.bats`, so no
  other adapter needs to implement it).
- `intake-poll.sh` — call `tracker_search_unassigned` once per poll cycle if the loaded adapter
  defines it, logging one warning line per ticket found.
- `test/unit/tracker_contract.bats` — add a test asserting `tracker_search_unassigned`'s JQL shape
  (same pattern as the existing `tracker_search` test at line 99).
- `test/integration/dispatch_planning.bats` — add a test asserting the poll cycle logs a warning
  when `tracker_search_unassigned` reports a ticket, and asserting `jira.sh` (which doesn't define
  the function) is silently skipped with no error.
- `docs/faq.md` — new Q&A entry.

## Key decisions

- **Log-only, not a ticket comment, for orphaned-unassigned warnings.** The existing
  `tracker_add_comment` chokepoint (`jira-tags.sh:150`) has no dedup/rate-limit state, so a
  ticket-comment warning would repost every poll cycle (every few minutes) for as long as the
  ticket stays unassigned — comment spam. The poller log (`log()`, `intake-poll.sh:166`) already is
  the place operational/attention-needed conditions surface (see the "watchdog" pass's own log
  lines), so this follows existing convention rather than inventing a new one.
- **`tracker_search_unassigned` is optional, not added to the required `tracker_*` contract.** Only
  `jira-tags.sh`'s shared-project, multi-assignee model has an "unassigned" concept worth watching.
  `jira.sh`'s single-account model doesn't — every ticket in its queue is implicitly "the account's."
  Forcing `jira.sh` (and any future adapter) to implement a no-op version would be contract bloat for
  a condition that can't occur there. `intake-poll.sh` guards the call with
  `declare -F tracker_search_unassigned >/dev/null 2>&1` and simply skips it if undefined.
- **Which pipeline states count as "active."** `tracker_search_unassigned`'s JQL should match the
  same non-terminal `state:*` labels enumerated in `jira_tags_legal_move`
  (`ready-for-planning`, `needs-author-input`, `plan-review`, `ready-for-implementation`,
  `in-progress`, `ready-for-verification`) and exclude `done` — a finished ticket with no assignee
  isn't a problem.
- **Called once per poll cycle, not once per queue.** `process_queue` (line 798) runs once per
  queue (`planning`, `implementation`); checking for orphaned tickets is queue-agnostic, so it's
  called once at the end of the `if [ "${BASH_SOURCE[0]}" = "${0}" ]; then ... fi` dispatch block
  (`intake-poll.sh:823-837`), after the `case "$POLL_MODE"` block, regardless of which mode ran.

## Implementation order

1. **Add `tracker_search_unassigned` to `lib/tracker/jira-tags.sh`.** Place it directly after
   `tracker_search` (after line 75). Implementation:
   ```bash
   # tracker_search_unassigned — echoes one ticket key per line: this repo's tickets
   # (TRACKER_APP_TAG) that carry an active pipeline state:* label but have no assignee. These are
   # invisible to every developer's tracker_search (assignee = currentUser() never matches an
   # unassigned ticket for anyone) — surfaced so a human notices and assigns them, rather than the
   # ticket silently never being picked up. Optional: not part of the required tracker_* contract:
   # only this adapter's shared-project, multi-assignee model has an "unassigned" concept worth
   # watching (jira.sh's single-account model doesn't).
   tracker_search_unassigned() {
       jira_search_jql "project = ${TRACKER_PROJECT_KEY} AND labels = \"${TRACKER_APP_TAG}\" AND labels in (\"state:ready-for-planning\",\"state:needs-author-input\",\"state:plan-review\",\"state:ready-for-implementation\",\"state:in-progress\",\"state:ready-for-verification\") AND assignee is EMPTY ORDER BY created ASC"
   }
   ```
   Acceptance check: `bash -n lib/tracker/jira-tags.sh` exits 0 (syntax check).

2. **Add a unit test for the new JQL** in `test/unit/tracker_contract.bats`, directly after the
   existing test at line 99-108 (same fake-`jira_search_jql` pattern):
   ```bash
   @test "jira-tags.sh: tracker_search_unassigned scopes JQL to the app tag, active states, and no assignee" {
       export TRACKER_PROJECT_KEY=PROJ TRACKER_APP_TAG="app:my-app"
       source "$REPO_ROOT/lib/tracker/jira-tags.sh"
       local captured=""
       jira_search_jql() { captured="$1"; }
       tracker_search_unassigned
       [[ "$captured" == *'labels = "app:my-app"'* ]]
       [[ "$captured" == *'"state:ready-for-planning"'* ]]
       [[ "$captured" == *'"state:in-progress"'* ]]
       [[ "$captured" != *'"state:done"'* ]]
       [[ "$captured" == *'assignee is EMPTY'* ]]
   }
   ```
   Acceptance check: `test/bats-core/bin/bats test/unit/tracker_contract.bats` — new test passes,
   all existing tests in the file still pass.

3. **Wire the check into `intake-poll.sh`.** Add a new function near `process_watchdog`
   (after line 796):
   ```bash
   # warn_unassigned_pipeline_tickets — optional adapter capability: if the loaded tracker adapter
   # defines tracker_search_unassigned (only lib/tracker/jira-tags.sh does), log one warning line
   # per ticket it reports. Log-only by design (no ticket comment) — see the plan's Key decisions
   # for why. Silently a no-op for adapters (e.g. jira.sh) that don't define the function.
   warn_unassigned_pipeline_tickets() {
       declare -F tracker_search_unassigned >/dev/null 2>&1 || return 0
       local key count=0
       while IFS= read -r key; do
           [ -n "$key" ] || continue
           count=$((count+1))
           log "  warning: $key is in the pipeline under this repo's app tag but has no assignee — no harness install will pick it up until it's assigned"
       done < <(tracker_search_unassigned)
       [ "$count" -gt 0 ] && log "unassigned-pipeline check: $count ticket(s) need an assignee"
   }
   ```
   Then call it once, after the `case "$POLL_MODE"` block and before `log "poll complete"`
   (around line 834-836):
   ```bash
       esac

       warn_unassigned_pipeline_tickets

       log "poll complete"
   ```
   Acceptance check: `bash -n intake-poll.sh` exits 0.

4. **Add an integration test** in `test/integration/dispatch_planning.bats` (check the file's
   existing `setup()`/fake-adapter pattern first and match it) covering two cases: (a) with a fake
   `tracker_search_unassigned` defined that echoes a key, the poll log contains the warning line;
   (b) with `TRACKER=jira` (which never defines the function), the poll completes with no error and
   no warning line. Acceptance check: `test/bats-core/bin/bats test/integration/dispatch_planning.bats`
   passes.

5. **Add the FAQ entry** in `docs/faq.md`, after "Which issue trackers are supported?" (line 20-24):
   ```markdown
   ### I have a team all running this harness against the same Jira project — will two people's
   ### pollers pick up the same ticket?
   Not with the multi-developer-safe adapter (`TRACKER=jira-tags`, for a Jira project shared across
   repos): every search and every state-changing write is scoped to `assignee = currentUser()` /
   the authenticated account, so a poller only ever acts on tickets assigned to the identity it
   authenticated as — see `lib/tracker/jira-tags.sh`. The plain `TRACKER=jira` adapter has no such
   scoping; it's built for the single-account model (one dedicated account per project/repo — see
   `docs/design-decisions.md` #2) and would double-pick-up work if pointed at a project multiple
   developers poll simultaneously. One related edge case: a ticket that's queued (carries a pipeline
   label) but never assigned to anyone is invisible to *every* poller under `jira-tags` — the poller
   logs a warning for these so a human notices and assigns them, rather than the ticket silently
   never being picked up.
   ```
   Acceptance check: manual read-through — no command, just confirm the entry reads correctly and
   the heading format matches the rest of the file (`### Question?` followed by a paragraph).

6. **Run the full local suite** to confirm nothing else broke:
   ```bash
   make lint
   make test
   ```
   Acceptance check: both commands exit 0.

## Boundaries

- Do not modify `lib/tracker/jira.sh` — its lack of assignee scoping is an intentional design
  choice (`docs/design-decisions.md` #2), not a bug.
- Do not change `TRACKER_CONTRACT_FNS` in `test/unit/tracker_contract.bats` or the required
  `tracker_*` list in `README.md` — `tracker_search_unassigned` is optional, adapter-specific, and
  must stay outside the required contract.
- Do not add a ticket-comment path for the unassigned-ticket warning — log-only, per Key decisions.
- Do not touch `test/unit/tracker_contract.bats:99`'s existing `tracker_search` test — it already
  covers the original ask and needs no change.
- No schema/data-model changes, no destructive operations, no public API/route changes — none of
  this plan's changes fall into those categories.

## Open Questions

None blocking. One note to confirm at review: the plan chooses log-only visibility (no ticket
comment, no Slack/other notification) for orphaned-unassigned tickets, on the reasoning that the
existing `tracker_add_comment` chokepoint has no dedup state and would spam the ticket every poll
cycle. If the author wants ticket-visible signaling instead (e.g. a comment posted once, tracked via
a new label or a runtime-state marker to avoid repeats), that's a bigger change than this plan scopes
and should be a follow-up ticket rather than folded in here.
