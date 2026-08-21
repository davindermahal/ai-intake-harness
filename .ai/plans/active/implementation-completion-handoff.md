# Plan: Deterministic implementation-completion handoff + accurate watchdog escalation

**Status**: draft
**Created**: 2026-08-20
**Updated**: 2026-08-20

## Goal

DAV-2's headless implementation worker finished successfully twice in a row (commits `151a63e` and
`11358e2`, both verified clean) but never ran `./tracker-transition.sh DAV-2 ready-for-verification`
— the last of five steps in `.ai/prompts/worktree-bootstrap-auto.md`, which it's supposed to run as
its own final action. Nothing else in the pipeline can complete that transition for it, so the
ticket sat at `state:in-progress` after both runs. The watchdog then noticed the stuck ticket and
posted an escalation comment that unconditionally reads as "this looks like a failure, re-queue
it" — which is how a *second*, redundant full implementation pass got triggered on an already-done
ticket.

Two independent, compounding problems:

1. **The transition is the AI's responsibility as a free-standing last step**, with nothing checking
   it happened. Compare the *planning* phase, which has never shown this bug: `dispatch_planning`
   (`intake-poll.sh:368-475`) runs the planning AI **synchronously in the foreground**, then the
   poller itself — not the AI — reads a decision file and performs `tracker_transition`/`post_comment`
   deterministically. Implementation is architecturally different: `dispatch_implementation` launches
   a **detached background worker** and returns immediately (`intake-poll.sh:515-551`), so no poller
   invocation is around to synchronously read anything when the worker finishes. The worker has been
   made responsible for calling the tracker directly instead — and that's the exact link that broke,
   twice.
2. **The watchdog's "case C" escalation message presumes failure unconditionally.** `watchdog_check`
   (`intake-poll.sh:590-651`) can tell "the worker's PID is dead" from "an AI comment was posted after
   launch," but not "reported a real blocker" from "reported success and forgot to transition." Its
   message always says "likely repeat the same failure... move back to Ready for Implementation" —
   which is exactly the wrong instruction when the implementation actually finished.

Fix 1 removes the failure mode structurally, mirroring the pattern that already works for planning.
Fix 2 makes the escalation message honest regardless of whether Fix 1 ever has a gap.

## Scope

**In scope:**
- A small structured completion-result file the headless implementation worker writes as its last
  step, instead of calling `./tracker-transition.sh` itself.
- A deterministic finalize step added to `intake-poll.sh`'s existing slot-reaping code
  (`reap_running`), which performs the actual `tracker_transition` call once a worker's process has
  exited — the same "poller does the write, not the AI" pattern `dispatch_planning` already uses.
- Reworded watchdog case-C escalation message (`intake-poll.sh:621`) so it doesn't presume failure.
- Tightening `.claude/settings.ai-harness-dev.json` to remove the headless worker's
  `./tracker-transition.sh` permission, since after this fix it no longer needs it — one less way for
  a similar bug to recur in a different shape (e.g. calling it with the wrong target state).

**Out of scope:**
- `.ai/prompts/worktree-bootstrap.md` (the **interactive** `make worktree-go` variant) — a human is
  present there to confirm before implementing and to agree the work is done before the existing
  `./tracker-transition.sh` call, so the unsupervised-detached-worker failure mode this plan fixes
  doesn't apply to it. Left untouched.
- Any change to the watchdog's retry/attempts/escalation *thresholds* (`JIRA_MAX_ATTEMPTS`,
  `JIRA_WATCHDOG_GRACE_SECONDS`) — only the case-C message text changes.
- `lib/tracker/jira.sh` / `lib/tracker/jira-tags.sh` — both already support
  `tracker_transition "$key" ready-for-verification`; no adapter change needed.
- Re-litigating DAV-2 itself — it gets unblocked by hand (`tracker-transition.sh DAV-2
  ready-for-verification`) separately from this plan landing.

## Key decisions

1. **The result file lives inside the worktree, not `.intake/`.** `.intake/` only exists in the main
   repo root (`REPO_ROOT`) — a detached worker's cwd is the worktree, a sibling directory, and it has
   no visibility into or business writing to the main repo's state directory (that's the poller's
   territory; the worktree is deliberately the worker's whole sandboxed world). So the worker writes
   `.ai/impl-result.json` at its own worktree root — same directory tier as `.ai/plans/active/`, which
   it already writes to today — and the poller, running as trusted bash in `REPO_ROOT`, reaches into
   the worktree to read it after the fact, the same way it already reaches in to read/commit the plan
   file during planning.

2. **Stale-result hazard — the file must be cleared before every launch, not just consumed after.**
   Implementation worktrees are **not** ephemeral: DAV-2's run #2 reused run #1's worktree directory
   via `RESUME=1` (`intake-poll.sh` log: `existing worktree ... — will RESUME in place`). If a later
   run crashes hard before reaching its own final step (a real crash, not just a skipped step), a
   leftover `{"outcome":"success"}` from an *earlier* successful run would still be sitting in that
   worktree, and a naive "read the file when the slot frees" reaper would wrongly transition the
   ticket based on stale data from a prior attempt. So `launch_implementation_worker`
   (`intake-poll.sh:496-506`) must delete any pre-existing `impl-result.json` in the target worktree
   **before** every launch (fresh dispatch or watchdog restart) — never rely solely on read-then-delete
   after the fact.

3. **Missing/unreadable/`"blocked"` result → do nothing new; the existing watchdog stays the safety
   net.** This plan only adds a deterministic path for the confirmed-success case. A worker that
   crashes before writing the file, or that deliberately reports `"blocked"`, still leaves the ticket
   `In Progress` exactly as today, and the (now-more-honest) watchdog escalation is still what a human
   sees. No new failure mode is introduced for the cases this plan doesn't touch.

4. **The worker keeps posting its own narrative comment via `tracker-comment.sh`.** That part has
   worked correctly in both observed runs — the bug is specifically the state *transition*, not the
   comment. Moving comment-posting to the poller too (full parity with planning's architecture) would
   require restructuring how results flow out of a detached process and isn't needed to fix the
   observed bug — out of scope.

5. **Removing the worker's `tracker-transition.sh` permission is a deliberate hardening step, not
   just cleanup.** Once the poller owns the transition, the headless worker has no legitimate reason
   to call `tracker-transition.sh` at all. Leaving the permission in place would keep the door open for
   a future version of this same bug class (e.g., a worker calling it with an unexpected target state).
   Removing it from `.claude/settings.ai-harness-dev.json`'s allow list closes that door structurally,
   consistent with the profile's existing least-privilege design (it already denies `git push`,
   `git reset`, etc.).

## Files to change

- `.ai/prompts/worktree-bootstrap-auto.md` (**modify**) — step 5: write `.ai/impl-result.json`
  instead of calling `./tracker-transition.sh` directly.
- `intake-poll.sh` (**modify**):
  - `launch_implementation_worker` (~line 496) — clear any stale result file before launch.
  - `reap_running` (~line 187) — read + consume the result file when a slot frees; call
    `tracker_transition ... ready-for-verification` on confirmed success.
  - `watchdog_check` (~line 621) — reworded case-C escalation message.
- `.claude/settings.ai-harness-dev.json` (**modify**) — remove
  `"Bash(./tracker-transition.sh:*)"` from `allow`.

## Implementation order

### 1. Define the result-file contract and update the worker prompt

In `.ai/prompts/worktree-bootstrap-auto.md`, replace step 5's success/failure branches:

- **Success** (implemented, shellcheck/syntax clean, committed): keep the existing
  `./tracker-comment.sh <TICKET> "..."` call, then write the result file instead of transitioning:
  ```bash
  echo '{"outcome":"success"}' > .ai/impl-result.json
  ```
  Remove the `./tracker-transition.sh <TICKET> ready-for-verification` line entirely — the poller now
  performs that transition once it sees this file.
- **Failure/blocker**: keep "post a comment, leave the ticket In Progress, do not transition," and
  additionally write:
  ```bash
  echo '{"outcome":"blocked"}' > .ai/impl-result.json
  ```
  so a future watchdog-message refinement can tell "worker consciously stopped and said so" apart from
  "worker never got that far" if that distinction is ever needed — not used by this plan's reaper
  logic (Key decision 3), but cheap to record now.
- Update the `## Guardrails` bullet listing allowed scripts to drop `./tracker-transition.sh` (Key
  decision 5 removes the permission anyway, so the prompt should stop telling the worker it has it).

**Acceptance check**: `grep -n "tracker-transition.sh" .ai/prompts/worktree-bootstrap-auto.md`
returns nothing; `grep -n "impl-result.json" .ai/prompts/worktree-bootstrap-auto.md` shows both the
success and blocked branches.

### 2. Clear stale result files before every launch

In `intake-poll.sh`'s `launch_implementation_worker` (~line 496), before invoking `make worktree-go`,
compute the worktree dir (already done via `wtdir="$(worktree_dir_for_branch "$branch")"`) and remove
any leftover result file there unconditionally, whether or not the worktree pre-exists:
```bash
rm -f "$wtdir/.ai/impl-result.json"
```
Place this right after the existing `if [ -d "$wtdir" ]; then resume=1; ...; fi` block, before the
`make worktree-go` invocation, so it runs on both a fresh worktree (no-op, directory may not exist
yet — fine, `rm -f` on a missing path is silent) and a `RESUME=1` reused one (the case that matters,
per Key decision 2).

**Acceptance check**: with an existing worktree containing a stale `.ai/impl-result.json`, call
`launch_implementation_worker` (or run a dry pass) and confirm the file is gone before the worker
process starts — `test ! -e "$wtdir/.ai/impl-result.json"` immediately after the `rm -f` line runs,
before `make worktree-go` is invoked.

### 3. Consume the result file deterministically when a slot frees

In `intake-poll.sh`'s `reap_running` (~line 187), inside the loop's dead-PID branch (where it
currently just logs `"slot freed for $key ..."` and removes the pid/meta files), add: resolve the
worker's branch and worktree dir the same way `launch_implementation_worker` does
(`existing_branch "$key"` → `worktree_dir_for_branch`), read `.ai/impl-result.json` from there if
present, and:
- `outcome == "success"` → `tracker_transition "$key" ready-for-verification || log "  $key: deterministic post-implementation transition FAILED — leaving for watchdog"` (best-effort: a transition failure here must not abort the reap loop given `set -euo pipefail` is active for the script as a whole — wrap the call so a non-zero return doesn't propagate).
- anything else (missing file, unreadable, `"blocked"`) → log which case it was
  (e.g. `"  $key: worker exited without a confirmed-success result (outcome=${outcome:-none}) — leaving for watchdog"`)
  and do nothing further — Key decision 3's existing-safety-net behavior.
- Either way, `rm -f` the result file after reading it (belt-and-suspenders on top of step 2's
  pre-launch clear — Key decision 2).

This only needs to run once per freed slot, so add it inside the existing
`if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then ... fi` branch, before its `continue`.

**Acceptance check**: manually place `{"outcome":"success"}` in a test ticket's worktree, kill/let its
worker pid die, run one poll cycle (or call `reap_running` directly in a `bash -c` harness), and
confirm the ticket's `state:*` label flips to `ready-for-verification` (or, for `TRACKER=jira`, status
moves to "Ready for Verification") without any `tracker-transition.sh` invocation from the worker
itself. Repeat with `{"outcome":"blocked"}` and confirm no transition is attempted and the log line
appears. Repeat with no file present and confirm the same no-transition, log-and-skip behavior (covers
a worker that crashes before step 1 ever runs).

### 4. Reword the watchdog's case-C escalation message

In `watchdog_check` (`intake-poll.sh:621`), replace the current message:
```
"already reported back (a blocker/failure comment posted after its last launch) — automatic restart would likely repeat the same failure. Move back to *Ready for Implementation* to re-queue after addressing it."
```
with one that doesn't presume the cause and explicitly warns against blind re-queuing, e.g.:
```
"$key's last worker exited and posted a comment, but the ticket was never transitioned out of In Progress. Read its most recent comment above: if it reported a genuine blocker, address that and move back to *Ready for Implementation* to re-queue. If the work actually finished, transition it by hand instead — \`tracker-transition.sh $key ready-for-verification\` — re-queuing a completed implementation triggers a redundant second implementation pass."
```
(Exact wording can be adjusted for length/tone; the required content is: don't assume failure, name
both possible outcomes, and give the by-hand transition command as the alternative to re-queuing.)

**Acceptance check**: `grep -n "likely repeat the same failure" intake-poll.sh` returns nothing;
the new message text mentions both "genuine blocker" and the manual `tracker-transition.sh ...
ready-for-verification` alternative.

### 5. Tighten the headless worker's permission profile

In `.claude/settings.ai-harness-dev.json`, remove `"Bash(./tracker-transition.sh:*)"` from
`permissions.allow`. Leave `"Bash(./tracker-comment.sh:*)"` in place (still used).

**Acceptance check**: `grep -n "tracker-transition" .claude/settings.ai-harness-dev.json` returns
nothing. Re-run (or dry-run) a headless implementation pass and confirm it completes successfully
without ever attempting `./tracker-transition.sh` (it shouldn't try — step 1 already removed that
instruction from its prompt — but the permission removal is defense-in-depth if it ever did).

## Boundaries

- Do not change `dispatch_planning` or anything in the planning phase — it doesn't have this bug.
- Do not change `lib/tracker/jira.sh` or `lib/tracker/jira-tags.sh` — `tracker_transition` already
  supports everything this plan needs from both adapters.
- Do not change `.ai/prompts/worktree-bootstrap.md` (interactive variant) — out of scope, see Scope.
- Do not change `JIRA_MAX_ATTEMPTS` / `JIRA_WATCHDOG_GRACE_SECONDS` or any other watchdog timing
  constant — only the case-C message text and the new pre-watchdog deterministic transition.
- Do not make the new reap-time transition block or slow down `reap_running` beyond one extra file
  read and (on success) one REST call per freed slot — it must stay safe to call as often as
  `running_count()` already calls `reap_running` today.

## Open questions (non-blocking)

- Step 3's transition call happens inside `reap_running`, which today has no tracker-adapter-specific
  knowledge beyond what's already globally sourced at the top of `intake-poll.sh`. Confirm during
  implementation that `tracker_transition` is safe to call from within `reap_running`'s call stack
  (i.e., no per-dispatch state `reap_running` doesn't have access to) — everything reviewed so far
  suggests yes (`tracker_transition` only needs `$key` and the abstract state name), but worth a final
  check against both adapters before landing.
- Should the deterministic transition failure (step 3's `||` branch) also post a ticket comment
  immediately, rather than waiting for the existing watchdog to eventually notice and escalate? Left
  as "leave for watchdog" for now (Key decision 3 keeps this plan's blast radius to the success path)
  — revisit if a transition-call failure turns out to be common enough that the extra watchdog-cycle
  delay matters in practice.
