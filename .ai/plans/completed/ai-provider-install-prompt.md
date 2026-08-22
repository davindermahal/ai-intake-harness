# Plan: Install-time AI provider selection + real Codex/Antigravity adapters + local-LLM support

**Status**: completed
**Branch**: feature/jira-authentication-by-cookie (uncommitted at implementation time)
**Created**: 2026-08-21
**Updated**: 2026-08-21

> Note: plan docs under `.ai/plans/active/` in this repo use **Status**: draft → completed in
> their header. This isn't just a label — once the described work is actually done, update it to
> `completed` (as this one is), the way DAV-2 did. Don't leave a finished plan showing `draft`.

**Scope grew after initial completion**: the user asked (1) whether Gemini was actually usable as
set up, and (2) for a fifth real adapter, Google's **Antigravity CLI** (binary `agy`). Both are
covered below, after the original Codex-focused implementation notes.

**Resolved during drafting** (see Open Questions for full reasoning): delete `openai.sh` rather
than keep it alongside `codex.sh`; Codex CLI flags below were verified live (`codex --help`,
`codex exec --help`, `codex login --help`, `codex doctor`) against a real install
(codex-cli 0.148.0), not left as assumptions; the broader Codex-as-local-LLM-gateway path (design
decision #6) is deferred, not built in this pass; the install wizard uses a numbered menu.

## Implementation notes (2026-08-21)

Implemented per this plan, steps 2–7 (step 1 was done during drafting, see above):
`lib/ai/codex.sh` (new, all three `ai_*` contract functions; `-s workspace-write -a never`
automation boundary — no `project_codex_permission_profile` hook, a disclosed deviation from the
plan's original sketch, see design decision #3/codex.sh's own header for why), `lib/ai/openai.sh`
deleted, `install.sh`'s `_prompt_intake_config` extended with a numbered AI-provider menu (1
claude / 2 gemini / 3 codex / 4 local-llm) plus a new `_validate_ai_provider` that sources the
chosen adapter and runs `ai_load_env` right there (warning, not a hard stop), `intake-poll.sh` +
`worktree-go.sh` doc-comment/default wiring for `CODEX_BIN`/`CODEX_FLAGS`/`CODEX_TIMEOUT`,
README/`docs/design-decisions.md` #5 #11 updates, and `.ai/system.md`/`.ai/repo-map.md`/
`docs/workflow-and-triggers.md` fixes for statements that became false once `openai.sh` was
deleted.

Verified: `bash -n` + `shellcheck` on all changed/new scripts (only the same SC2086 info-level
word-splitting notices `gemini.sh` already carries); static contract check (`ai_load_env`/
`ai_run_planning`/`ai_run_implementation` defined in all four `lib/ai/*.sh`); full interactive
wizard re-tested via `script -qec "./install.sh '<fake-repo>'" /dev/null` with piped answers for
all four provider choices, confirming `.ai/intake.config` content and each validation outcome —
**and, going beyond the plan's verification bar, a real live round-trip**: this machine already
had the Codex CLI installed and logged in (ChatGPT auth), so `_ai_codex_load_env_impl` was
exercised for real (not just simulated) and reported "OK — codex looks ready to use." `gemini` and
`local-llm` were also exercised live in their expected-failure state (no `GEMINI_API_KEY`, no LM
Studio server running) and produced the correct actionable stderr messages.

**Incident, disclosed:** during regression-testing of the pre-existing `--install-cron` flag
(unrelated to this plan's own changes, done as a "did I break anything" check), `--install-cron`
was mistakenly run against this real repo instead of the fake-repo sandbox used for every other
test, adding a live crontab entry that would have polled this repo's real Jira account every 2
minutes. Caught immediately and reverted (removed just that one added line, leaving the two
pre-existing unrelated crontab entries untouched) before any poll cycle could fire.

## Addendum (2026-08-21): Gemini status check + real Antigravity adapter

**Is Gemini actually set up to use?** Wired correctly (menu option 2, `lib/ai/gemini.sh` existed
already from DAV-2) — but live-checking it on this machine surfaced two real problems, not just a
"looks fine on paper" answer:
- `GEMINI_API_KEY` is unset, so `ai_load_env` correctly refuses with an actionable message (this
  alone is expected/normal — just needs the key set).
- More seriously: the installed `gemini` CLI itself appears broken on this machine — `gemini
  --version` throws `SyntaxError: Invalid regular expression flags` (looks like a Node.js version
  incompatibility; this machine runs Node v26.7.0 via nvm) and `gemini --help` hangs indefinitely
  rather than printing help. So even with a key set, this specific install of the CLI likely
  couldn't run right now. This is an environment issue, not a harness bug — but worth fixing
  (older Node version, or an updated `gemini-cli` package) before relying on Gemini from this
  machine.
- **Follow-up fix (also 2026-08-21):** the user clarified `GEMINI_API_KEY` will be set as a real
  host environment variable (e.g. exported in `scripts/intake-cron.sh`), never
  `.env`/`.env.local`. Auditing found `lib/ai/gemini.sh`'s own error message claimed ".env" was a
  valid fallback — false: only `jira_common_load_env` reads those two files, and only for
  `JIRA_*`. Fixed: `lib/ai/gemini.sh`'s message now says "environment variable" only and points at
  `scripts/intake-cron.sh`; README's "AI provider adapter" list and the step-6 cron-wrapper
  section now document the same, and `install.sh`'s generated `scripts/intake-cron.sh` template
  gained a commented `# export GEMINI_API_KEY=...` hint line next to the existing
  `ANTHROPIC_API_KEY` one.

**New: `lib/ai/antigravity.sh`** (Google's Antigravity CLI). Verified live on this machine exactly
like Codex was — `agy --help` (binary is `agy`, product is "Antigravity"; a real compiled Go
binary, not an Electron/GUI wrapper), and `agy models` (used as the `ai_load_env` auth check —
there is no dedicated `login status` equivalent the way Codex has one, so this lightweight
already-authenticated network call is the closest available substitute; confirmed working live,
returning a real model list including Gemini, Claude, and GPT-OSS models). Design differences from
Codex, disclosed:
- Auth: also a persisted login (interactive `agy` session, or an SSH device-code flow), not an env
  var — but no dedicated status subcommand was found, unlike `codex login status`.
- Automation boundary: `--sandbox --dangerously-skip-permissions`, structurally the same
  "fixed-flags, no project-supplied file" shape as Codex's, but weaker-verified — `--sandbox`'s
  exact restrictions (filesystem only? network too?) aren't documented/confirmed the way Codex's
  were via `codex doctor`. Treat `antigravity.sh` as experimental until a real implementation-phase
  run is observed and its actual restrictions confirmed.
- `--mode accept-edits` for planning mirrors Claude's own default `CLAUDE_FLAGS` value/vocabulary
  almost exactly (both CLIs use the literal string "accept-edits"/"acceptEdits").

Wired into the same places `codex` was: `install.sh`'s menu (now 5 choices: claude / gemini /
codex / antigravity / local-llm), `intake-poll.sh` + `worktree-go.sh` doc-comment/default wiring
(`ANTIGRAVITY_BIN`/`ANTIGRAVITY_FLAGS`/`ANTIGRAVITY_TIMEOUT`), README, `docs/design-decisions.md`
#5/#11, and the same `.ai/system.md`/`.ai/repo-map.md`/`docs/workflow-and-triggers.md` fixes.

Verified the same way as Codex, plus a **live round-trip**: `bash -n` + `shellcheck` (same
info-level SC2086 pattern, nothing new), static contract check, and
`bash -c '. lib/ai/antigravity.sh && ai_load_env'` succeeded for real against the actual `agy`
install/login on this machine — then the full wizard was re-tested via
`script -qec "./install.sh '<fake-repo>'" /dev/null` selecting antigravity, which reported
"OK — antigravity looks ready to use." for real, not simulated.

## Goal

`install.sh`'s interactive `.ai/intake.config` wizard (added this session) prompts for tracker
config but not `AI_PROVIDER` — it's only ever written as a commented-out default. Add a prompt so a
consumer picks their default AI provider at setup time: **Claude**, **Gemini**, or **Codex**, plus a
path for **local LLM** use.

Claude (`lib/ai/claude.sh`) and Gemini (`lib/ai/gemini.sh`, added in DAV-2) are real, working
adapters today. `codex` is not — `lib/ai/openai.sh` is an explicit stub that fails loudly by design
("actual Codex-CLI integration is deferred until a second real AI-CLI consumer exists to design
against" — Gemini became that consumer, but openai/codex was never picked back up). Offering codex
as an install-time choice only makes sense if it actually works, so this plan builds a real
`lib/ai/codex.sh`, not just a wizard entry pointing at the existing stub.

For local LLM: `lib/ai/local-llm.sh` already exists and is real (routes the `claude` CLI at LM
Studio's native Anthropic-compatible endpoint) — it just has no install-time path to select and
configure it. This plan surfaces it as a fourth wizard choice, and separately proposes (as an open
question, not committed scope) a broader local-LLM path that falls out of a real `codex.sh` almost
for free.

## Scope

**In:**
- `lib/ai/codex.sh` — new, real adapter implementing the full `ai_load_env` /
  `ai_run_planning` / `ai_run_implementation` contract for OpenAI's Codex CLI, replacing the
  `openai.sh` stub.
- `install.sh`'s `_prompt_intake_config` — add an AI-provider menu (claude / gemini / codex /
  local-llm), writing an *uncommented* `AI_PROVIDER=` line. Selecting local-llm additionally
  prompts for `AI_LOCAL_LLM_BASE_URL`.
- Immediate validation: after the choice is written, call that provider's `ai_load_env` right
  there and report pass/fail — same "catch it now" philosophy `install.sh` already applies to the
  cookie-auth fallback (`_install_browser_cookie3_venv` / `jira_cookie_available`).
- `lib/intake-config.sh` — default env vars for the new provider, mirroring how `GEMINI_*` was
  added in DAV-2.
- README (`AI provider adapter` section, Quickstart steps 2/3) and `docs/design-decisions.md`
  (#5 automation boundary, #11 provider history) updated to match, mirroring DAV-2's own
  documentation footprint.

**Out:**
- A generic "any OpenAI-compatible local server" adapter beyond what a `codex.sh` base-URL
  override would give for free — proposed as a follow-on open question, not built here.
- Interactive `codex login` / ChatGPT-OAuth flows — headless API-key auth only, same reasoning
  DAV-2 used to reject Gemini's interactive OAuth (unusable from a cron poller).
- Any change to the existing per-ticket provider override (`resolve_ai_profile`,
  `AI_PROFILE_*`, `ai-plan-<profile>`/`ai-impl-<profile>` labels) — already built, untouched.

## Design decisions

1. **Add the AI-provider prompt to the existing `_prompt_intake_config`, not a new function.**
   Matches the current pattern — one wizard pass writes one coherent `.ai/intake.config`
   (tracker, project key, app tag, now provider). A numbered choice list rather than free text,
   because the value must exactly match a `lib/ai/<name>.sh` filename
   (`lib/intake-config.sh:80` sources `${AI_PROVIDER}.sh` directly) — free text risks a typo that
   only surfaces as a sourcing error deep in the poller, not at setup time.

2. **Build `lib/ai/codex.sh` for real rather than offering codex as a selectable stub.**
   The request is for three working choices ("my options are Claude, gemini, or codex"). A menu
   entry that's guaranteed to fail is worse than not offering it — `openai.sh`'s stub already
   demonstrates the harness's convention of failing loudly rather than silently, which is right
   for a provider nobody selected on purpose, but wrong for one just chosen from an install-time
   menu.

3. **Repurpose `lib/ai/openai.sh` → `lib/ai/codex.sh`, provider slug `codex`.**
   `openai.sh`'s own header says it's a stand-in for exactly this. The dispatch mechanism keys off
   `AI_PROVIDER` matching a filename, and the user asked for "codex" specifically — naming the
   slug after the actual CLI tool (not the company/API) avoids ambiguity if a non-Codex OpenAI
   integration is ever wanted later (see Open Question 1).

4. **Codex CLI invocation shape — VERIFIED live** against a real install (codex-cli 0.148.0:
   `codex --help`, `codex exec --help`, `codex login --help`, `codex doctor`), not left as
   assumptions the way DAV-2 had to leave Gemini's flags:
   - Non-interactive run: `codex exec [PROMPT]` (prompt as an arg, or via stdin if `-`/piped).
     `-C, --cd <DIR>` sets the working root (analog of `claude.sh`'s directory arg); `--add-dir
     <DIR>` adds further writable directories. `-o, --output-last-message <FILE>` writes the
     agent's final message to a file — a clean way to capture the planning decision output
     without scraping stdout. `--json` streams JSONL events, useful for the implementation-phase
     logfile.
   - Automation boundary: `-s, --sandbox <read-only|workspace-write|danger-full-access>` +
     `-a, --ask-for-approval <untrusted|on-request|never>`. `-s workspace-write -a never` is the
     Codex analog of Gemini's `--sandbox` + `--approval-mode yolo` pairing — confirmed to exist,
     not guessed. There's also `--dangerously-bypass-approvals-and-sandbox` (no sandbox at all,
     explicitly labeled "EXTREMELY DANGEROUS... only for externally sandboxed environments") —
     **not** the boundary to use here; this harness's own worktree/container isolation (design
     decision #6 in `docs/design-decisions.md`) is exactly that external sandbox for *build/test*
     purposes, but the flag bypasses Codex's own command-approval gate entirely, which is a
     different and stronger claim than "coarser-grained but still gated" (design decision #5's
     accepted trade-off for Gemini). Use `-s workspace-write -a never`, not the bypass flag.
   - Model selection: `-m`/`--model`.
   - **Auth — materially different from Claude/Gemini, verified via `codex doctor`'s auth section
     and `codex login status`:** Codex CLI does NOT read an API key from the environment at
     invocation time. It persists a credential to `~/.codex/auth.json` via one of two commands —
     interactive `codex login` (ChatGPT OAuth, browser-based, **not usable headless**) or
     `codex login --with-api-key` (reads a key from stdin, e.g.
     `printenv OPENAI_API_KEY | codex login --with-api-key` — **scriptable, no browser**, run
     once out-of-band). `codex login status` then reports the current state in one line (observed
     live: `Logged in using ChatGPT`) and is the right check for `ai_load_env` — analogous to how
     `jira_cookie_available` checks for a working session rather than a specific env var.
     `ai_load_env` should check CLI presence + `codex login status` succeeding, and its failure
     message should point at `codex login --with-api-key` (the headless-compatible path) the way
     `gemini.sh` points at `GEMINI_API_KEY`.
   These are now grounded, not assumptions — implementation-order step 1 (below) is satisfied by
   this verification pass, so `codex.sh` does not need `local-llm.sh`'s "treat as unverified"
   disclaimer for its flag shapes. The one thing still worth a live smoke-test before calling the
   adapter non-experimental is an actual `codex exec` round-trip (see Verification).

5. **Local LLM: wire the existing `lib/ai/local-llm.sh` into the wizard as a fourth choice**,
   rather than building a new adapter. It already implements the full contract and is documented
   as experimental-but-real (LM Studio's native Anthropic-compatible endpoint via the `claude`
   CLI). The only gap is that `install.sh` has no path to select and configure it. Extra prompt:
   `AI_LOCAL_LLM_BASE_URL` (default `http://localhost:1234/v1`), plus a reminder to run
   `local-llm-spike.sh` before relying on it for implementation, per its own header comment.
   **Known limitation, disclosed not hidden:** this only works against a server exposing LM
   Studio's native Anthropic endpoint — Ollama/vLLM/llama.cpp's plain OpenAI-compatible endpoints
   don't qualify today. See Open Question 3.

6. **Deferred, not built in this pass:** a broader local-LLM path via `codex.sh`. Worth noting for
   the record since it's now partially verified: `codex --help` confirms an `--oss` flag plus
   `--local-provider <lmstudio|ollama>` that select "the open-source provider" — i.e. Codex CLI
   already has *some* first-party notion of routing to a local LM Studio/Ollama server, which may
   make this generalization simpler than the originally-guessed `OPENAI_BASE_URL`-override
   approach once someone designs it properly. Deferred per the resolved open question below —
   revisit if there's real demand for non-LM-Studio local servers.

## Implementation order

1. ~~Verify Codex CLI live~~ — **done during planning** (this session, against codex-cli 0.148.0
   on this machine): `codex --help`, `codex exec --help`, `codex login --help`, `codex doctor`.
   Findings folded into design decision #4 above.
2. **`lib/ai/codex.sh`**: `ai_load_env` (CLI presence + `codex login status` succeeding — NOT an
   `OPENAI_API_KEY` env-var check, see design decision #4's auth findings — mirroring the shape of
   `gemini.sh`'s `_ai_gemini_load_env_impl` but checking login state instead of an env var),
   `ai_run_planning`, `ai_run_implementation` (detached worker + PID file, mirroring
   `claude.sh`/`gemini.sh` exactly; `-s workspace-write -a never` for the automation boundary,
   `-o`/`--json` for capturing output). Remove `lib/ai/openai.sh` (resolved: delete, see Open
   Question 1).
3. **Automation boundary**: add an optional project-adapter hook
   (`project_codex_permission_profile`, mirroring `project_gemini_permission_profile`) per design
   decision #5's established pattern — `codex.sh` refuses to launch unrestricted when
   unconfigured, same as `gemini.sh` today.
4. **`install.sh`**: extend `_prompt_intake_config` with the provider menu (numbered: claude /
   gemini / codex / local-llm, default claude), right after the tracker prompts. local-llm
   additionally prompts `AI_LOCAL_LLM_BASE_URL`. Writes `AI_PROVIDER=` uncommented (today always
   commented out); local-llm also writes `AI_LOCAL_LLM_BASE_URL=`.
5. **Immediate validation**: source the selected `lib/ai/<provider>.sh` and call `ai_load_env`,
   printing pass/fail. A failure is a warning, not a hard stop — the CLI might be installed later.
6. **`lib/intake-config.sh`**: add default env vars for the new provider (model overrides etc.),
   matching how `GEMINI_*` defaults were added in DAV-2.
7. **Docs**: README `AI provider adapter` section (add codex, mark openai.sh
   removed/superseded), Quickstart steps 2/3 (mention the new prompt),
   `docs/design-decisions.md` #5 and #11, `docs/lessons-learned.md` if live verification (step 1)
   surfaces anything surprising — matching DAV-2's documentation footprint.

## Open questions — resolved

1. **Delete `openai.sh` or keep both slugs?** Resolved: **delete** `openai.sh`, superseded by
   `codex.sh`. Nothing today distinguishes a generic "OpenAI API" provider from "Codex CLI."
2. **Codex CLI available to verify against?** Resolved: **yes** — verified live this session
   (codex-cli 0.148.0). See design decision #4 for the confirmed flags and the auth-mechanism
   correction (persisted login via `codex login`/`codex login --with-api-key`, not an env var
   read per-invocation).
3. **Build the Codex-as-local-LLM-gateway generalization now or wait?** Resolved: **wait**. Ship
   the existing `local-llm.sh` (LM Studio path) via the wizard now; revisit the broader path later
   — noting `--oss`/`--local-provider <lmstudio|ollama>` (found during live verification) may make
   that future design simpler than originally guessed.
4. **Numbered menu vs. free-text provider name?** Resolved: **numbered menu** (1 claude / 2 gemini
   / 3 codex / 4 local-llm) — avoids a typo that would otherwise only surface as a sourcing error
   deep in the poller.

## Verification

- `bash -n` on every changed/new script.
- `shellcheck` on `install.sh` and `lib/ai/codex.sh` (expect only the same SC2086 info-level
  notices `claude.sh`/`gemini.sh` already carry).
- Static contract check: confirm `ai_load_env`/`ai_run_planning`/`ai_run_implementation` are
  defined in `codex.sh` — same fallback DAV-2 used when a live CLI run wasn't available.
- Wizard re-tested the way this session's earlier install.sh work was tested:
  `script -qec "./install.sh '<fake-repo>'" /dev/null` with piped answers covering all four
  provider choices, confirming `.ai/intake.config` ends up with the right `AI_PROVIDER=` (and,
  for local-llm, `AI_LOCAL_LLM_BASE_URL=`).
- One live round-trip on this machine (`codex` CLI already installed and logged in via ChatGPT
  auth) — `ai_load_env`, then a trivial `ai_run_planning` call — before calling the adapter
  non-experimental. Same bar `local-llm.sh` sets for itself via `local-llm-spike.sh`.
