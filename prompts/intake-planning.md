# Prompt: Intake Planning Routine (run per ticket on the planning queue)

You have been invoked by the intake poller for **one ticket** in the planning queue — abstract
state **`ready-for-planning`** (a literal Jira status or a `state:ready-for-planning` label,
depending on the configured tracker adapter). Your job is to turn that ticket into a structured
plan file and emit a **decision** telling the poller how to route it. Follow these steps exactly.

> **Full-REST design — you do NOT talk to the tracker.** The poller (`ai-intake-harness/intake-poll.sh`)
> performs all tracker I/O — read, comment, transition — over REST through the configured tracker
> adapter (Jira today, see `.ai/intake.config`), so this routine runs fully headless with no
> MCP/OAuth dependency. **Do not call any tracker/Atlassian MCP tools.** You only (a) read the
> ticket from a context file, (b) author/refine the plan file, and (c) write a decision JSON. The
> poller acts on your decision.

> **Scope — planning only.** You produce/refine a `draft` plan; you never write application code and
> never approve a plan for implementation. Implementing a `ready` plan is
> `.ai/prompts/worktree-bootstrap.md` (run by `make worktree-go`). The human approval gate
> (`Plan Review → Ready for Implementation`) is a person's job. See
> `.ai/plans/completed/jira-intake-layer.md`.

This routine is the build of **step 3** of that plan.

---

## 0. Inputs (provided by the poller)

**You are running inside an ephemeral git worktree of this ticket's feature branch.** Author/refine
the plan file here in the working tree; **do not run git** — the poller commits your plan onto the
branch after you finish. The dispatch prompt gives you:
- **Ticket id** — e.g. `TICKET-123`. Act on this ticket only.
- **Branch** — e.g. `feature/TICKET-123-<slug>`. Use **exactly this** in the plan's `**Branch**:` line
  (the poller already decided it; do not invent a different one).
- **Context file** — `.intake/context/<KEY>.json`: the ticket's current `summary`, `status`,
  `description`, and existing `comments` (tracker-normalized JSON; bodies are plain text), plus a
  top-level `abstract_state` field — the tracker-agnostic abstract state name (e.g.
  `ready-for-planning`), already translated from whichever tracker adapter is configured (Jira
  status name, Jira label, or otherwise). Use `abstract_state`, not the tracker's own raw
  `fields.status`/labels, so this routine never needs to know which tracker is configured.
- **Decision file** — `.intake/decision/<KEY>.json`: you **write** this at the end.

## 1. Read the ticket

Read the context file. Use the `description` as the original input and read the existing
`comments` so you don't re-ask something the author already answered.

If `abstract_state` is **not** `ready-for-planning`, write a decision with
`{"action":"skip","comment":"Ticket was no longer in the planning queue (abstract_state=<X>) — skipped."}`
and stop.

## 2. Find or create the plan file

The seam with the rest of the system is one artifact: `.ai/plans/active/${TICKET}-<slug>.md`.

```bash
ls .ai/plans/active/${TICKET}-*.md
```

- **Match → REFINE, do not regenerate.** This is a re-pickup after the author answered questions
  (the *Needs Author Input → Ready for Planning* loop). Read the existing plan, fold the new answers
  from the latest comments into it, and **accumulate** the Q&A — never overwrite from scratch.
- **No match → CREATE** a new plan file. Derive `<slug>` as kebab-case of the ticket summary.

### Plan file shape

Mirror `.ai/prompts/new-feature.md` + `.ai/context/conventions.md` → "Plans". Start with:

```markdown
# Plan: ${TICKET} <Title>

**Status**: draft
**Branch**: feature/${TICKET}-<slug>
**Created**: <YYYY-MM-DD>
**Updated**: <YYYY-MM-DD>
```

Then: **Goal**, **Scope** (in/out), **Files to change** (one-line reason each), **Key decisions**,
**Implementation order**, **Boundaries**, **Open Questions**. Always leave `**Status**: draft` —
flipping to `ready` happens at implementation (step 4), not here. Keep `Updated:` current.

### Write for a weaker executor (executor-ready steps)

The implementer may be a **smaller local model** (see AI profiles in `.ai/intake.config`), so the
plan must not lean on the implementer's judgment to fill gaps. Whoever implements it, these rules
make the plan mechanically executable:

- **Every Implementation order step is self-contained and literal.** Name the **exact file
  paths** the step touches, the **exact commands** to run (build, test, verify — copy-pasteable,
  including any `docker exec`/container wrapper), and what the change is. "Update the controller"
  is not a step; "In `src/Controller/EventController.php`, add … then run `make test-ci
  ARGS=--filter=EventControllerTest`" is.
- **Every step ends with an acceptance check**: one command (or one concrete observation) plus
  the expected pass output, so the implementer can prove the step worked **before moving to the
  next one**.
- **Add a `## Boundaries` section**: the files/directories the implementer must NOT touch, plus
  any standing rules that apply (e.g. "no schema changes", "don't edit templates/admin/",
  "harness/docs only — no Symfony code"). An explicit fence beats an implied one.
- **Prefer many small steps over few clever ones.** If a step needs a judgment call, either make
  the decision in the plan (record it under Key decisions) or route it to Open Questions — never
  leave it to the implementer.

Read the project context the plan touches before writing: `.ai/context/architecture.md`,
`.ai/context/conventions.md`, `.ai/context/domain.md` (always), and `.ai/context/design-system.md`
for public-facing UI/CSS work.

## 3. Decide: questions vs. clean

Judge whether **Open Questions** contains anything that genuinely blocks a confident plan (an
ambiguity only the author can resolve — not something you can settle from the codebase or a sensible
default).

**Structural decisions always block — even when a sensible default exists.** If the plan would
change the data model or another hard-to-reverse foundation, do **not** default it and route to
*Plan Review*; emit `questions` so the author confirms first. Treat these as blocking regardless of
how reasonable your default seems:

- **Schema / data-model changes to existing tables** — adding, removing, or renaming a column;
  **changing a primary key** (e.g. composite → surrogate id); altering types or constraints; any
  migration that rewrites or backfills existing rows.
- **Destructive or irreversible operations** — deleting data, dropping tables/columns, or anything
  a rollback can't cleanly undo.
- **Public contract changes** — new/changed/removed routes or URLs, or a change to a public
  API/response shape.

State your recommended option in the question so the author can confirm with a one-word reply, but
still route to *Needs Author Input*. Non-structural ambiguities you can settle from the codebase or a
safe default remain `clean` (note them under **Open Questions** as "confirm at review").

## 4. Write the decision JSON

Write `.intake/decision/<KEY>.json`. The **`comment` is mandatory in every case** — per project
convention the poller posts it to the ticket as the record of what you did (see
`.ai/context/conventions.md` → "Plans"). Use tracker-friendly plain text/markdown.

**Has blocking questions:**
```json
{
  "action": "questions",
  "comment": "Drafted/refined the plan at .ai/plans/active/${TICKET}-<slug>.md. I need answers before finalizing:\n1. <question>\n2. <question>\nReply in a comment and move this back to Ready for Planning.",
  "plan_file": ".ai/plans/active/${TICKET}-<slug>.md"
}
```
→ The poller posts the comment and transitions the ticket to **Needs Author Input**.

**No blocking questions:**
```json
{
  "action": "clean",
  "comment": "Plan ready for review at .ai/plans/active/${TICKET}-<slug>.md. Summary: <2-4 sentence summary of approach, files, and key decisions>.",
  "plan_file": ".ai/plans/active/${TICKET}-<slug>.md"
}
```
→ The poller posts the comment and transitions the ticket to **Plan Review**.

That is the end of your run. Do not transition anything yourself; do not move toward
*Ready for Implementation* (the human approval gate).

---

## Guardrails

- **No tracker/MCP calls, and no git.** Read the context file; write the plan file and the decision
  file. The poller does all tracker I/O and commits your plan onto the feature branch.
- **No application code** in this phase, and never run `make worktree-go`.
- **Use the branch the poller gave you** in the plan's `**Branch**:` line — don't invent one.
- **Always populate `comment`** — it is the ticket's record of the AI's work. A decision without a
  meaningful summary is incomplete.
- **Refine, don't regenerate** on re-pickup; accumulate the author's answers into the existing plan.
- **Leave the plan `draft`.** Flipping to `ready` is step 4's job.
- **If anything is off** (status not as expected, no plan could be formed), emit
  `{"action":"skip","comment":"<why>"}` rather than guessing.
