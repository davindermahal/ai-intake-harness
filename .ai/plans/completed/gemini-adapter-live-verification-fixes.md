# Plan: Gemini adapter — live-verification fixes + Vertex/Code Assist auth support

**Status**: completed
**Branch**: feature/gemini-adapter-live-verification-fixes
**Created**: 2026-08-21
**Updated**: 2026-08-21

## Implementation notes (2026-08-21)

Implemented per this plan: `lib/ai/gemini.sh` (`_ai_gemini_run_implementation_impl` drops
`--settings`, adds `--skip-trust`, tightens `project_gemini_permission_profile`'s contract to
require exactly `.gemini/settings.json`; `_ai_gemini_load_env_impl` accepts
`GOOGLE_CLOUD_PROJECT`(`_ID`)+`GOOGLE_CLOUD_LOCATION` as an alternative to `GEMINI_API_KEY`; header
comment rewritten to record what was live-verified), `README.md` (Quickstart step 6, permission
sandbox section, `project_gemini_permission_profile` contract description, AI provider adapter
bullet), `docs/design-decisions.md` #5, `docs/lessons-learned.md`'s Gemini bullet.

Verified: `bash -n` and `shellcheck` clean (only the same pre-existing SC2086 info-level notice
`claude.sh` already has on the identical word-splitting pattern). Live end-to-end against the
installed gemini-cli 0.56.0: `_ai_gemini_run_implementation_impl` with a real temp worktree +
`.gemini/settings.json` no longer dies with "Unknown argument: settings" and no longer shows the
trust-downgrade warning (it hangs waiting on auth instead, since this machine has no live Gemini
credential configured — the correct behavior, matching the planning-phase auth check). The
permission-profile path guard correctly rejects a non-`.gemini/settings.json` path. `ai_load_env`
verified across all four combinations (neither var set → fails with the new message; `GEMINI_API_KEY`
alone → passes; `GOOGLE_CLOUD_PROJECT`+`GOOGLE_CLOUD_LOCATION` → passes; `GOOGLE_CLOUD_PROJECT_ID`
fallback + location → passes; project without location → fails).

All items from Scope/Implementation order are done except automated Docker-image pre-pull for
`--sandbox`, which was explicitly Out of scope.

## Goal

`lib/ai/gemini.sh`'s own header comment has said since it was written that its flag assumptions
(`-p`, `--model`, `--include-directories`, `--sandbox`, `--approval-mode`, `--settings`) came from
the DAV-2 plan's documented guesses, not a live `gemini --help`, because the build that wrote it
ran under a locked-down permission profile with no shell access to the real CLI. That live
verification has now been done (Gemini CLI **0.56.0**, installed and on `PATH`) and it found two
confirmed bugs in the implementation-phase launch path, plus a real gap in `ai_load_env`: it only
recognizes `GEMINI_API_KEY`, but Gemini CLI headless mode also supports Vertex AI / Gemini Code
Assist auth via `GOOGLE_CLOUD_PROJECT`(`_ID`) + `GOOGLE_CLOUD_LOCATION`, which is the path a user
with Code Assist access but no AI Studio key would actually be using. This plan fixes both, and
updates the docs (README, design-decisions, lessons-learned) that currently describe the wrong
mechanism.

## Verified findings (live, against installed gemini-cli 0.56.0)

1. **`--settings <path>` is not a recognized flag.** `gemini --settings x -p hi` →
   `Unknown argument: settings`, exit 1. Reproduced end-to-end: sourced `gemini.sh`, defined a
   fake `project_gemini_permission_profile`, called `_ai_gemini_run_implementation_impl` against a
   real temp worktree — it wrote a pidfile with a live PID, then the process died within ~2s, and
   the logfile captured the CLI's "Unknown argument" usage dump. Every `ai_run_implementation`
   call that has a permission profile configured fails this way today.
2. **Gemini auto-discovers `<cwd>/.gemini/settings.json` — no flag needed at all.** Confirmed:
   invalid JSON placed at that path makes `gemini --help` fail at startup
   (`Error in .../.gemini/settings.json: ...`); valid `{"tools": {"coreTools": [...],
   "excludeTools": [...]}}` there loads silently. This is the real mechanism — `--settings` was
   never how Claude's flag-based pattern maps onto Gemini.
3. **`--approval-mode yolo` is silently downgraded to `default` (interactive) in an untrusted
   folder**, and every freshly created worktree is untrusted. Confirmed via the CLI's own message:
   `Approval mode overridden to "default" because the current folder is not trusted`. Under the
   adapter's detached `nohup` launch there is no TTY to satisfy that interactive prompt, so this
   would hang the worker indefinitely rather than erroring — a worse failure mode than bug #1.
   `--skip-trust` (`Trust the current workspace for this session`) fixes it — confirmed: with it,
   only `YOLO mode is enabled` prints, no downgrade warning.
4. **`ai_load_env` fail-closes on a valid auth setup.** Per Gemini CLI's own bundled docs
   (`docs/get-started/authentication.mdx` in the installed package), headless mode accepts either
   `GEMINI_API_KEY` (AI Studio) **or** Vertex AI / Code Assist auth: `GOOGLE_CLOUD_PROJECT` (falls
   back to `GOOGLE_CLOUD_PROJECT_ID`) + `GOOGLE_CLOUD_LOCATION`, backed by ADC
   (`gcloud auth application-default login`), a service-account key
   (`GOOGLE_APPLICATION_CREDENTIALS`), or `GOOGLE_API_KEY`. Today `_ai_gemini_load_env_impl` only
   checks `GEMINI_API_KEY` and refuses to run otherwise — so a user authenticated via Code
   Assist/Vertex with no AI Studio key can never pass this check.
5. **Not a bug, a deployment note:** `--sandbox` shells out to Docker and pulls
   `us-docker.pkg.dev/gemini-code-dev/gemini-cli/sandbox:0.56.0` on first use — needs Docker +
   registry access wherever this runs headless. Worth a doc mention, no code change.
6. Planning-phase flags (`-p`, `--include-directories`, `--model`) all parse cleanly against
   0.56.0 — no change needed there.

## Scope

**In:**
- `lib/ai/gemini.sh`
  - `_ai_gemini_run_implementation_impl`: drop `--settings $settings_file` from `perm_flags`; add
    `--skip-trust`. The permission-profile check stays gated on `project_gemini_permission_profile`
    existing and pointing at a real file, but since Gemini only ever auto-loads
    `<worktree>/.gemini/settings.json` (no arbitrary-path flag exists), tighten the check to
    require the echoed path to be exactly `.gemini/settings.json` — fail closed with a clear
    message (naming the wrong path it got) if a project adapter returns something else.
  - `_ai_gemini_load_env_impl`: pass if `GEMINI_API_KEY` is set, **or** if (`GOOGLE_CLOUD_PROJECT`
    or `GOOGLE_CLOUD_PROJECT_ID`) **and** `GOOGLE_CLOUD_LOCATION` are set. Keep it a presence check
    only (matches today's behavior of not validating the API key is real either) — don't try to
    detect ADC/service-account/API-key credentials behind the project+location pair; that mirrors
    Gemini CLI's own division of labor (env vars pick the project/region, a separate credential
    source authenticates). Update the stderr message to describe both accepted paths and keep the
    existing "must be a real host env var, not `.env`/`.env.local`" warning for whichever path is
    missing.
  - Header comment: replace the "could not verify live, re-verify before relying on this" language
    with what was actually verified (version, date, findings above), since that's now done.
- `README.md`
  - "AI provider adapter" Gemini bullet (~line 344-350): fix the `--settings` mention → describe
    auto-discovered `.gemini/settings.json` + `--skip-trust`; mention the Vertex/Code-Assist auth
    alternative to `GEMINI_API_KEY`.
  - `project_gemini_permission_profile` contract description (~line 327-329): update from "echoes
    the path to a Gemini-schema settings file" (implying an arbitrary path, mirroring Claude's
    arbitrary-named-profile pattern) to "must echo exactly `.gemini/settings.json`" and explain why
    (Gemini has no flag to point elsewhere).
  - Permission-sandbox section (~line 284-289): same arbitrary-path wording fix
    (`.gemini/settings.<adapter-name>.json` → `.gemini/settings.json`, singular, fixed name).
  - Quickstart step 6 / auth section (~line 233-242): add the `GOOGLE_CLOUD_PROJECT` /
    `GOOGLE_CLOUD_LOCATION` alternative alongside the existing `GEMINI_API_KEY` guidance, same
    "must be a real host env var" caveat.
- `docs/design-decisions.md` #5: update the Gemini paragraph — same `--settings`→auto-discovery
  correction, note `--skip-trust` as part of the boundary now (it's not a security-relevant flag,
  but its absence was a silent-hang bug worth a one-line mention).
- `docs/lessons-learned.md`: resolve/update the existing Gemini bullet (~line 114-117) — it
  currently just says "coarser automation boundary, disclosed trade-off"; add a line that the flag
  assumptions have now been live-verified and what was wrong.

**Out:**
- No change to the `coreTools`/`excludeTools` settings *schema* itself — still correct, just
  delivered via auto-discovery instead of a flag.
- No move to Gemini's newer Policy Engine (`--policy`/`--admin-policy`) — `--allowed-tools` is
  deprecated in favor of it, but `coreTools`/`excludeTools` in `settings.json` still works and is a
  smaller change; a Policy Engine migration is a separate future decision, not bundled here.
- No automated Docker image pre-pull for `--sandbox` — deployment prerequisite, documented not
  automated.
- No changes to `intake-poll.sh` — it only reads `GEMINI_BIN`/`GEMINI_FLAGS`/`GEMINI_TIMEOUT` as
  opaque passthroughs and doesn't reference `--settings` or auth vars directly (verify in step 1
  below; if a stray comment there also says `--settings`, fix it as part of this pass).

## Key decisions

- **Tighten `project_gemini_permission_profile`'s contract to a fixed filename.** The current
  contract (mirroring Claude's arbitrary-named-profile pattern) doesn't map onto Gemini, which has
  no flag to point at an arbitrary settings path. Requiring exactly `.gemini/settings.json` is a
  breaking contract change for any consumer project that already implemented this function with a
  different filename — but no real consumer adapter exists yet in this repo (per DAV-2's own
  closing note), so there's nothing to migrate. Fail closed with a specific error naming the bad
  path if a future adapter gets this wrong.
- **`ai_load_env`'s Vertex check stays presence-only**, matching the existing `GEMINI_API_KEY` path
  (which also never validates the key is live). Deeper validation (e.g. shelling out to check ADC)
  would be a bigger, slower check for a script whose job is "fail fast on the obvious case," not
  "fully authenticate."

## Implementation order

1. Re-confirm `intake-poll.sh` and `worktree-go.sh` have no other `--settings`/Gemini-auth
   references beyond passthrough vars (`grep -n "settings\|GEMINI_API_KEY\|GOOGLE_CLOUD" intake-poll.sh worktree-go.sh`).
2. Fix `_ai_gemini_run_implementation_impl` in `lib/ai/gemini.sh`: drop `--settings`, add
   `--skip-trust`, tighten the permission-profile path check to require `.gemini/settings.json`.
3. Fix `_ai_gemini_load_env_impl`: accept the `GOOGLE_CLOUD_PROJECT`(`_ID`)+`GOOGLE_CLOUD_LOCATION`
   alternative to `GEMINI_API_KEY`; update the error message.
4. Rewrite `lib/ai/gemini.sh`'s header comment to reflect what's now live-verified.
5. Update `README.md` in the four spots listed under Scope.
6. Update `docs/design-decisions.md` #5.
7. Update `docs/lessons-learned.md`'s Gemini bullet.
8. Verify: `bash -n lib/ai/gemini.sh`, `shellcheck lib/ai/gemini.sh`. Then live-test against the
   installed CLI: source `gemini.sh`, fake `project_gemini_permission_profile` to return
   `.gemini/settings.json`, create that file with valid `coreTools`/`excludeTools` JSON in a temp
   worktree, call `_ai_gemini_run_implementation_impl`, confirm the log no longer shows "Unknown
   argument" or the trust-downgrade warning (won't complete a real model call without live
   credentials, but the launch-path bugs are directly observable without one). Also confirm
   `_ai_gemini_load_env_impl` passes when only `GOOGLE_CLOUD_PROJECT`+`GOOGLE_CLOUD_LOCATION` are
   set (no `GEMINI_API_KEY`), and still fails closed when neither auth path is present.
9. Mark this plan's **Status** `completed` once done — don't leave it at `draft`.

## Acceptance checks

- `grep -n -- '--settings' lib/ai/gemini.sh` finds nothing in the implementation-launch path.
- `grep -n -- '--skip-trust' lib/ai/gemini.sh` finds it alongside `--approval-mode yolo`.
- `grep -n 'GOOGLE_CLOUD_PROJECT\|GOOGLE_CLOUD_LOCATION' lib/ai/gemini.sh` finds the new check.
- `shellcheck lib/ai/gemini.sh` clean (or only the same SC2086 info-level notices `claude.sh`
  already has on the identical word-splitting pattern).
- Live dry run from step 8 shows neither the "Unknown argument: settings" error nor the
  trust-downgrade warning in the log.
- `README.md` no longer says `.gemini/settings.<adapter-name>.json` (arbitrary name) anywhere.
