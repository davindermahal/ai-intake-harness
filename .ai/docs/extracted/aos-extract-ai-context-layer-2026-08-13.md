---
type: project-work
project: personal open-source automation tool (a tracker- and stack-agnostic harness that drives an AI coding agent through planning and implementation)
date: 2026-08-13
title: An AI-context layer for AI-assisted development (AGENT.md + .ai/)
summary: How a thin AGENT.md pointer plus a structured .ai/ directory (orientation docs + a versioned plans/ folder) became the author's standard way of planning and tracking AI-assisted work, reusing the same "plan file as seam" discipline the harness itself enforces for tickets.
---

## Problem

The repo had no `AGENT.md`, `CLAUDE.md`, or `.ai/` directory before this work, despite already
having an unusually thorough `docs/` set (`overview.md`, `architecture.md`,
`workflow-and-triggers.md`, `design-decisions.md`, `glossary.md`, `faq.md`,
`lessons-learned.md`). That documentation was written for a human reader working top-down; there
was no compact, evidence-grounded entry point an AI assistant (or a returning human) could read in
one pass to orient before working in the repo, and no durable, consistent place to capture and
track planning decisions as the author's own engineering work on the repo progressed. Separately,
the author wanted a repeatable convention they could carry between projects and eventually explain
to a work team, rather than a one-off documentation exercise specific to this repo.

## Decisions and Trade-offs

- **Thin root pointer + a directory of focused docs, not one big context file.** `AGENT.md` at the
  repo root stays short (a core-principle statement and a pointer to `.ai/README.md`), rather than
  holding all the orientation content itself. The detail lives in separate `.ai/` files
  (`README.md` for read-order, `system.md` for what-the-project-is/architecture/principles,
  `repo-map.md` for a directory-by-directory map). Trade-off: more files to keep in sync, but each
  one stays scannable and a reader can stop at the depth they need.
- **`AGENT.md` is deliberately not auto-loaded the way `CLAUDE.md` is.** The author accepted this
  gap rather than renaming/duplicating into a `CLAUDE.md`, and instead compensated for it with a
  separate mechanism (see Implementation Notes) — keeping the tool-agnostic name while still
  making sure the content gets surfaced at the start of future sessions.
- **Adopting the harness's own "plan file" convention for the harness's own development, not just
  for the tickets it processes.** The tool already prescribes, for any project that vendors it in,
  that a plan is a structured file with a `Status` field (`draft → ready → active → completed`),
  committed and refined rather than regenerated, never rewritten once `completed`
  (`docs/design-decisions.md` decision #3, in this same repo, about the harness's *product*
  behavior). The author chose to apply that identical discipline reflexively to planning work on
  the harness's own codebase, rather than using ad hoc notes or letting planning discussions live
  only in chat history.
- **A dedicated `draft/` stage, separate from `active/`**, added after the first pass at this
  convention turned out to conflate two different things: a plan actively being implemented, and
  an idea just captured from a conversation with open questions still unresolved. The convention
  became three directories — `.ai/plans/draft/` (an idea or brainstorming session, not yet fleshed
  into concrete steps, not forced to completeness just to have somewhere to put it), `.ai/plans/
  active/` (fleshed out, ready to implement or being implemented), `.ai/plans/completed/`
  (finished, never edited again) — rather than only two. Used immediately: `.ai/plans/draft/
  work-tag-tracker-adapter.md` captures a design discussion about building a second tracker
  adapter, explicitly flagged as unfinished, with an "Open design questions" section instead of
  invented answers.

## Mental Model

Treat AI-context the same way this project already treats its own product's plan files: a
versioned, git-committed artifact with an explicit status lifecycle, refined over time rather than
rewritten from scratch, and never edited once marked complete. Applied to `.ai/`, that means the
directory isn't after-the-fact documentation — it's a working planning surface: a fixed read-order
(`README.md` → `system.md` → `repo-map.md`) for orientation, and a `plans/` folder that becomes the
durable historical record of *why* changes happened, not just what changed. The same discipline the
author built into the harness for turning tickets into implementable plans gets pointed back at
their own development process.

## Implementation Notes

- `AGENT.md` (repo root, 12 lines): states the one non-negotiable principle for this repo (human
  approval gates / build-verify-only automation boundary) and the plans convention; links to
  `.ai/README.md`.
- `.ai/README.md`: one-paragraph project summary, numbered read order across `.ai/` and the
  existing `docs/` set, and the plans convention.
- `.ai/system.md`: what the project is, its layered adapter architecture, core principles pulled
  from `docs/design-decisions.md`, a glossary of load-bearing terms, and explicit non-goals — every
  claim traceable to an existing doc or file rather than invented.
- `.ai/repo-map.md`: a directory-by-directory map of every script and `lib/` file, including what's
  deliberately *not* in this repo (e.g. project adapters and runtime state, which live in
  downstream "consumer" repos that vendor this harness in).
- `.ai/plans/draft/`, `.ai/plans/active/`, and `.ai/plans/completed/`: plan files carry
  `**Status**: draft|ready|active|completed`, `**Created**`/`**Updated**` dates, and sections for
  Goal, Key decisions, Open Questions; the file physically moves directory as it progresses through
  the three stages, and moving a file to `completed/` means it is never edited again, only
  superseded.
- Generated using a reusable Claude Code skill (`init-agent-context`, invoked as
  `/init-agent-context`) that investigates the repo first (README, manifests, build tooling,
  directory structure) and is explicitly instructed to never invent content, using
  `[CONFIRM: ...]` placeholders for anything it can't ground in evidence — none were needed here
  because the existing `docs/` set already covered the ground.
- Compensating for `AGENT.md` not being auto-loaded: the author is layering Claude Code's separate
  per-project persistent memory system (local, not git-committed, keyed to the repo's filesystem
  path) on top — a "reference" memory entry that tells future sessions to read `AGENT.md` first,
  plus a "feedback" memory entry recording the plans-workflow convention itself, so both get
  reapplied automatically without being restated each session.

## Evidence

- Before: `find . -maxdepth 2 -iname "agent.md" -o -iname "claude.md"` returned nothing; no `.ai/`
  directory existed.
- After: commit `757c26c` ("init ai setup for development") added `AGENT.md`, `.ai/README.md`,
  `.ai/system.md`, `.ai/repo-map.md`, and `.ai/plans/{active,completed}/.gitkeep` — 230 insertions
  across 7 files. A follow-up pass added `.ai/plans/draft/.gitkeep` as a third stage and updated
  `AGENT.md`/`.ai/README.md`/`.ai/repo-map.md` to describe it.
- A live example of the plans convention already in use: `.ai/plans/draft/
  work-tag-tracker-adapter.md`, opened at `Status: draft` with the header note "Captures a
  brainstorming session. Not yet fleshed out into concrete implementation steps — revisit and
  flesh out before moving to `.ai/plans/active/`," and an "Open design questions" section listing
  six unresolved points rather than guessed answers.
- The convention being reused is documented, for the harness's own product behavior, in
  `docs/design-decisions.md` decision #3 ("The plan file as the seam between planning and
  implementation... versioned from creation, refined on re-pickup, never rewritten from scratch")
  and in `docs/glossary.md`'s "Plan status (draft / ready / active / completed)" entry.

## Author Context

This has become the author's standard way of doing AI-assisted development, used at work as well
as on personal projects. The intent behind writing it up is to explain to a work team why they like
working this way — specifically how it helps formulate plans, keep track of them over time, and
build a historical record of *why* changes were made to an application, not just what changed. The
author also plans a substantial amount of further work inside this specific harness repo to
generalize it further, with the explicit goal of reusing the harness itself across other projects
(distinct from, but related to, the `.ai/`-layer convention this extraction covers).

## Possible Article Angles

1. Treat your AI context like your product's plan files: the same versioned, status-driven,
   never-rewritten discipline this tool enforces for tickets, turned back on the author's own
   planning process — a case for "eating your own dog food" in how you plan with AI, not just in
   what you ship.
2. A brainstorming session doesn't have to become a fully-specified plan or get lost in chat
   history — capturing it as a `draft` plan with an explicit "open questions" section is a middle
   state worth having.
3. Why a thin `AGENT.md` pointer plus a structured `.ai/` directory beats one big context file: different readers (a new teammate, an AI assistant mid-session, or the author six months later) need different altitudes of detail, and one monolithic file can't serve all three well.
4. The gap between "context that lives in git" and "context the assistant remembers between
   sessions" is real (a root pointer file isn't auto-loaded the way some tools' convention files
   are) — and it's worth closing deliberately rather than assuming either mechanism alone is
   enough.
