# .ai/ orientation

**ai-intake-harness** is a tracker- and project-agnostic automation harness that turns issue-tracker
tickets into AI-authored plans and AI-implemented code changes, with human approval gates in
between: **ticket → plan → (human approval) → isolated worktree → build/verify → report back**. A
background poller drives it; a generic core engine knows nothing about the specific tracker,
project stack, or AI backend — those are supplied via three adapter seams. See
`README.md` at the repo root for the adapter contracts and integration quickstart.

This repo *is* the harness itself (the tool), not a project that consumes it. Its own docs/
directory (see below) is unusually complete — read it before asking questions the docs already
answer.

## Read order

1. **This file** — orientation.
2. [`system.md`](system.md) — what this project is, core concepts/glossary, core principles.
3. [`repo-map.md`](repo-map.md) — directory-by-directory map of the codebase.
4. `../README.md` (repo root) — the full adapter contracts, quickstart for vendoring the harness
   into a consumer project, and the runtime state directory layout.
5. `../docs/` — deep-dive docs, already comprehensive:
   - `overview.md` — what it is, the problem it solves, who it's for.
   - `architecture.md` — component picture, data flow, external systems.
   - `workflow-and-triggers.md` — the operator's runbook: exactly what you do (ticket status
     changes) to drive each stage, plus manual/observe commands.
   - `design-decisions.md` — numbered decisions with rationale and trade-offs.
   - `glossary.md` — terminology.
   - `faq.md` — common questions.
   - `lessons-learned.md` — hard-won fixes and open caveats.
   - `permissions.yaml` — publish-classification (PUBLIC/INTERNAL/CONFIDENTIAL/SECRET) of the
     content extracted into these docs.
   - `article.md` / `versions/` — a blog-post writeup derived from this project; not
     authoritative for how the code works.

## Plans convention

Three stages, each its own directory:

- **`.ai/plans/draft/`** — an idea or brainstorming session captured before it's fleshed into
  concrete implementation steps. Not forced to completeness just to have somewhere to put it; open
  questions are expected here.
- **`.ai/plans/active/`** — a fleshed-out plan, ready to implement or being implemented.
- **`.ai/plans/completed/`** — finished. Files here are never edited again, only superseded by a
  new plan.

Move the file between directories as it progresses; don't duplicate it.

## `.ai/docs/extracted/`

A generic drop point for scoped writeups extracted from this project for use outside it (e.g. for
article drafting) — not tied to any one extraction tool, so anyone can add to it even without
access to the specific skill that produced an existing file. Currently populated by the
`extract-for-aos` skill (`/extract-for-aos`, `aos-extract-*.md` files, fed into a separate
author-operating-system repo). A byproduct of writing about this project, not part of its own
documentation — see `repo-map.md` for details.
