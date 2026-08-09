# Overview

## What it is

**ai-intake-harness** is a tracker- and project-agnostic automation harness that turns issue-tracker
tickets into AI-authored plans and AI-implemented code changes, with human approval gates in
between. The end-to-end flow it automates is:

> **ticket → plan → (human approval) → isolated worktree → build/verify → report back**

It is designed to drive an AI coding agent (today the Claude Code CLI, with seams intended for other
providers) from a background poller, so that routine planning and implementation work can proceed
largely unattended while a person stays in the loop at the decision points that matter.

## The problem it solves

Teams that want to use AI coding agents against a real backlog run into recurring friction:

- **Manual dispatch.** Someone has to notice a ticket is ready, gather its context, launch an agent,
  and babysit it. That does not scale across a backlog.
- **No safe boundary.** Letting an agent act directly on a shared branch — or on a shared database,
  or with permission to push/deploy — is risky. Work needs to happen in isolation and stop short of
  anything irreversible.
- **No approval checkpoints.** Planning and implementation should be reviewable by a human before
  anything is merged. Fully autonomous "ticket in, merge out" removes the judgment a person should
  apply to structural decisions.
- **Tight coupling.** Ad-hoc automation tends to hardcode one specific issue tracker, one specific
  tech stack, and one specific AI backend, so it cannot be reused on the next project.

The harness addresses these by providing a single background **poller** that watches abstract ticket
queues, dispatches an AI worker for the appropriate phase, isolates each unit of work in its own git
worktree and database, and enforces a hard automation boundary: **build and verify only — never
push, merge, or deploy.** A human reviews the branch and merges.

## Who it is for

- **Small teams and solo maintainers** who manage work through an issue tracker and want AI agents to
  take first-draft passes at planning and implementation without giving up review control.
- **Projects that already work "ticket-first"** and want each ticket to flow through a consistent,
  auditable pipeline.
- **People adopting it on a new codebase**, who write a small "project adapter" describing how to
  build/test/verify their stack and point the harness at their tracker via one config file.

## Why it exists

The harness was extracted and generalized from a working, single-project automation (the "JIRA
intake layer" of its first consumer). The original solved the problem for one Symfony + Docker
project driven through Jira; the generalization pulled the tracker-specific and stack-specific
knowledge out into replaceable adapters so the same core engine can drive a different tracker,
project, or AI backend without touching the poller or the prompts.

Its guiding principles:

- **Human approval gates are load-bearing, not optional.** The transition that approves a plan for
  implementation is reserved for a person; the automation will never perform it.
- **Isolation by default.** Every ticket gets its own worktree, its own app container, and its own
  freshly-seeded database, so concurrent work never collides and nothing touches shared state.
- **A hard automation boundary.** Unattended workers run under a restricted permission profile and
  are architecturally prevented from pushing, merging, deploying, or reading secrets.
- **Adapters, not forks.** Reusing it on a new project means writing small adapter files, not editing
  the engine.

> This document intentionally avoids implementation detail. See `architecture.md` for the high-level
> component picture, `workflow-and-triggers.md` for how you actually drive the flow (the status
> transitions that trigger each stage), and `design-decisions.md` for the reasoning behind the major
> choices.
