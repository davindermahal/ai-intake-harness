# Plan: Tag-based tracker adapter for work use (single-repo strategy)

**Status**: draft
**Created**: 2026-08-13
**Updated**: 2026-08-13

> Captures a brainstorming session. Not yet fleshed out into concrete implementation steps —
> revisit and flesh out before moving to `.ai/plans/active/`.

## Goal

Use this harness at work, where there's no Jira access and more constraints, without forking the
repo. Support a second tracker adapter for a tag/label-based tool (status-less workflow), while
keeping work-specific identifiers/secrets out of the public repo and preserving the ability to
pull harness improvements made at work back into this repo.

## Why single-repo, not a fork

The existing tracker/project/AI adapter seams already exist for exactly this: swapping tracker or
stack shouldn't require forking the core engine. A fork means permanently diverging copies and no
easy way to bring improvements back. Vendoring this repo into the private work repo via
`git subtree add` (already documented in `README.md`) is the intended integration path.

## Key decisions so far

- **New tracker adapter**: `lib/tracker/<work-tool-name>.sh`, implementing the same `tracker_*`
  contract as `lib/tracker/jira.sh` (`tracker_load_env`, `tracker_search`, `tracker_get_issue`,
  `tracker_add_comment`, `tracker_transition`, `tracker_ticket_regex`).
- **Config split follows the existing `jira.sh` pattern exactly**:
  - Non-secret identifiers (project/board key, tracker selection) → `.ai/intake.config`
    (`TRACKER=<name>`, `TRACKER_PROJECT_KEY=<key>`), committed.
  - Secrets/host (API token, base URL, etc.) → `.env` / `.env.local`, gitignored, pulled in by
    `tracker_load_env` with a `:?`-guard (fail loudly if unset) — mirrors `JIRA_SITE_URL` /
    `JIRA_INTAKE_EMAIL` / `JIRA_INTAKE_API_TOKEN` in `jira.sh`.
  - This means the adapter *file* itself never contains work secrets, so it's safe to keep in the
    public repo even though the work repo's `.env.local` never leaves work's machines.
- **Privacy boundary**: work-specific pieces (project adapter, `.ai/intake.config` values,
  `.env.local`) live entirely in the private work repo, outside the vendored `ai-intake-harness/`
  directory (per the existing documented pattern for project adapters). Only genuinely generic
  code (e.g. the tag-tracker adapter itself, if it has no company-specific logic) is a candidate
  to live inside the vendored subtree and flow back to the public repo.
- **Bringing improvements back**: `git subtree push --prefix=ai-intake-harness <public-remote>
  <branch>` from the work repo pushes only commits touching that prefix. `git subtree pull` does
  the reverse. Need to be deliberate about which commits touching `lib/tracker/<work-tool>.sh` are
  safe to push back (generic logic yes; anything with embedded work specifics no).

## Open design questions (not yet resolved)

1. **Which tag-based tool** is this targeting at work? (Not yet named — affects API shape,
   auth model, and query syntax for `tracker_search`.)
2. **Workflow-legality enforcement.** Jira's transition API itself enforces "only legal from the
   current status," which is what currently backs `tracker-transition.sh`'s guarantee that it
   can't be used to skip past `Plan Review → Ready for Implementation`. A tag system typically has
   no workflow graph — adding any tag from any state would normally just work. Decide whether
   `tracker_transition` for this adapter needs to self-enforce legal-transition checks (read
   current state-tag, reject illegal moves) to preserve that safety property, or whether some
   other mechanism covers it.
3. **Abstract state → tag mapping.** Exact tag names for the queues (`planning`,
   `implementation`, `in-progress`) and the states `tracker_transition` targets
   (`needs-author-input`, `plan-review`, `ready-for-implementation`, `in-progress`,
   `ready-for-verification`, `done`). Does the abstract-state vocabulary need any changes for a
   tag model, or does it map cleanly onto the existing six states?
4. **Ticket id / regex.** Confirm the work tool's ticket-id format for `tracker_ticket_regex` and
   `tracker_search`/`tracker_get_issue` key handling — may not be `PROJECT-123`-shaped.
5. **`tracker_search` query mechanism** — how the work tool's API expresses "issues with tag X",
   analogous to Jira's JQL `status = "..."` clauses in `jira.sh`.
6. **Comment/footer mechanics** — does the work tool support comments at all, and does the
   AI-footer-as-fingerprint trick (used by the watchdog to detect "worker already reported back")
   still work the same way?

## Next steps

- Pick/confirm the actual work tracker tool before writing adapter code.
- Resolve open question 2 (transition-legality enforcement) as a design decision, since it's
  safety-relevant, not just a porting detail.
- Sketch the tag→abstract-state mapping table.
- Only then flesh this plan into concrete implementation steps (mirroring the "Files to change" /
  "Implementation order" / "Boundaries" shape used for ticket-driven plans, per
  `prompts/intake-planning.md`).
