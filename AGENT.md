# AGENT.md

Start with [.ai/README.md](.ai/README.md) for a condensed orientation to this repo (what it is,
directory map, primary workflow) before reading other docs in full.

Human approval gates are load-bearing, not optional: the automation this harness implements is
built so it can never perform the `Plan Review → Ready for Implementation` transition, and
unattended workers may only build/test/verify — never push, merge, or deploy. Any change to this
repo's own code must preserve that boundary; see `docs/design-decisions.md` #4 and #5.

Plans: capture a new idea or brainstorming session in `.ai/plans/draft/`. Once fleshed into
concrete implementation steps, move it to `.ai/plans/active/`. Once implemented, move to
`.ai/plans/completed/` — files there must never be edited afterward.
