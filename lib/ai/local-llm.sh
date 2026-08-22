#!/bin/bash
# AI adapter: local LLM — the claude CLI as the agent, pointed DIRECTLY at LM Studio's native
# Anthropic-compatible API instead of Anthropic's servers, so this path never touches a paid API
# (Anthropic or OpenAI).
#
# Mechanism: recent LM Studio releases (0.3.x line, 2025) expose a native Anthropic-compatible
# `/v1/messages` endpoint expressly so Claude Code can drive local models directly — set
# ANTHROPIC_BASE_URL to LM Studio's server ROOT (e.g. http://localhost:1234, no /v1) and the
# claude CLI talks to it unmodified. An earlier design used a `claude-code-router`
# translation-proxy in front of LM Studio, but that router layer was never verified against live
# traffic, its generated config didn't match the real package's schema, and the native endpoint
# makes the whole layer (config generation, health checks, port management, npm dependency)
# unnecessary — so this adapter talks to LM Studio directly instead.
#
# Verification status: treat this as grounded in LM Studio's published docs until you've run a
# live round-trip yourself. Two guards keep that safe: (a) ai_load_env PROBES the native endpoint
# at selection time (cheap, no inference) and fails loudly with instructions if it's missing, so a
# wrong assumption can never fail silently mid-run; (b) `ai-intake-harness/local-llm-spike.sh`
# packages the full live checklist (models, native-endpoint inference, tool-use emission, optional
# real `claude -p` round-trip) — run it once from a host that can reach LM Studio before relying on
# this adapter for implementation work. Until it passes, treat local-llm implementation runs as
# unproven; falling back to planning-only use remains the floor if tool-use proves unreliable.
#
# Config (see .ai/intake.config): AI_LOCAL_LLM_BASE_URL (LM Studio's OpenAI-compatible /v1 base;
# the Anthropic endpoint lives at the same server's root), AI_LOCAL_LLM_MODEL (empty = the one
# model currently loaded in LM Studio; with several loaded it must be set explicitly — a profile
# does this, see AI_PROFILE_*). LM Studio is a single shared inference server, so the intake
# poller serializes local-llm implementation workers (see intake-poll.sh's local-llm slot check)
# and applies the longer AI_LOCAL_LLM_TIMEOUT to local-llm planning runs.
#
# Not guarded against re-sourcing — see ai/claude.sh's header comment for why.

# Reuses claude.sh's internal _ai_claude_run_planning_impl / _ai_claude_run_implementation_impl —
# same claude -p invocation shape, just with the ANTHROPIC_* env (subshell-scoped below) pointing
# at LM Studio instead of Anthropic's servers.
# shellcheck source=ai-intake-harness/lib/ai/claude.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/claude.sh"

# LM Studio server root for ANTHROPIC_BASE_URL: the configured base URL minus its /v1 suffix
# (Claude Code appends /v1/messages itself).
_ai_local_llm_server_root() {
    local u="${AI_LOCAL_LLM_BASE_URL%/}"
    printf '%s' "${u%/v1}"
}

# All model ids LM Studio currently serves, one per line (GET /v1/models).
_ai_local_llm_list_models() {
    curl -sS --max-time 5 "${AI_LOCAL_LLM_BASE_URL%/}/models" 2>/dev/null \
        | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/.*"([^"]*)"$/\1/'
}

# Echoes the model id to run: AI_LOCAL_LLM_MODEL if set, else the single model loaded in LM
# Studio. With SEVERAL models loaded it fails (listing them) instead of silently picking
# whichever /v1/models returns first — that would be an arbitrary choice. Resolved fresh
# on every call (no caching), so a model/config change is always picked up.
_ai_local_llm_resolve_model() {
    if [ -n "${AI_LOCAL_LLM_MODEL:-}" ]; then
        printf '%s' "$AI_LOCAL_LLM_MODEL"
        return 0
    fi
    local models count
    models="$(_ai_local_llm_list_models)"
    count="$(printf '%s' "$models" | grep -c . || true)"
    case "$count" in
        1) printf '%s' "$models"; return 0 ;;
        0) echo "ai/local-llm: no model loaded — ${AI_LOCAL_LLM_BASE_URL%/}/models returned nothing (load a model in LM Studio, or set AI_LOCAL_LLM_MODEL / use an AI profile)" >&2
           return 1 ;;
        *) echo "ai/local-llm: ${count} models are loaded in LM Studio and no explicit choice was made — refusing to pick one arbitrarily. Set AI_LOCAL_LLM_MODEL in .ai/intake.config, or select a profile (ai-impl-<profile> label / PROFILE=). Loaded:" >&2
           printf '%s\n' "$models" | sed 's/^/  - /' >&2
           return 1 ;;
    esac
}

# True if the server exposes the native Anthropic /v1/messages endpoint. A deliberately-minimal
# POST (no valid body, no inference): 404 means the endpoint doesn't exist (LM Studio too old);
# any other response (400/422/etc.) means it's there and rejecting the empty body, which is all
# this check needs to know.
_ai_local_llm_native_endpoint_present() {
    local code
    code="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' \
        -X POST -H 'Content-Type: application/json' -d '{}' \
        "$(_ai_local_llm_server_root)/v1/messages" 2>/dev/null)"
    [ -n "$code" ] && [ "$code" != "404" ] && [ "$code" != "000" ]
}

# ai_load_env — claude CLI present, LM Studio reachable, AND its native Anthropic endpoint
# available. Fails loudly at selection time (rather than deferring to a confusing failure
# mid-run) so a misconfigured/unreachable/too-old local-llm setup is obvious immediately.
_ai_local_llm_load_env_impl() {
    command -v "${CLAUDE_BIN:-claude}" >/dev/null 2>&1 \
        || { echo "ai/local-llm: '${CLAUDE_BIN:-claude}' not found on PATH" >&2; return 1; }
    curl -sS --max-time 5 -o /dev/null "${AI_LOCAL_LLM_BASE_URL%/}/models" 2>/dev/null || {
        echo "ai/local-llm: LM Studio not reachable at ${AI_LOCAL_LLM_BASE_URL} — start LM Studio's local server (or fix AI_LOCAL_LLM_BASE_URL in .ai/intake.config) before selecting this provider" >&2
        return 1
    }
    _ai_local_llm_native_endpoint_present || {
        echo "ai/local-llm: LM Studio at $(_ai_local_llm_server_root) has no native Anthropic /v1/messages endpoint — upgrade LM Studio to a 0.3.x+ build that ships it (run ai-intake-harness/local-llm-spike.sh for a full diagnostic)" >&2
        return 1
    }
}

# Subshell-scoped ANTHROPIC_* env: exported only inside the parens below, so nothing leaks into
# the poller's (or worktree-go's) own environment or affects any other AI provider dispatched
# afterward in the same process. Both ANTHROPIC_AUTH_TOKEN and ANTHROPIC_API_KEY are set — which
# one the installed claude CLI sends varies by version, LM Studio accepts any value either way —
# and ANTHROPIC_SMALL_FAST_MODEL is pinned so the CLI's background/small-model calls don't ask LM
# Studio for a Haiku model it doesn't have.
_ai_local_llm_run_with_env() {   # _ai_local_llm_run_with_env MODEL IMPL_FN ARGS...
    local model="$1" fn="$2"; shift 2
    ( local base_url; base_url="$(_ai_local_llm_server_root)"
      export ANTHROPIC_BASE_URL="$base_url"
      export ANTHROPIC_AUTH_TOKEN="lm-studio"
      export ANTHROPIC_API_KEY="lm-studio"
      export ANTHROPIC_MODEL="$model"
      export ANTHROPIC_SMALL_FAST_MODEL="$model"
      "$fn" "$@" )
}

_ai_local_llm_run_planning_impl() {
    local model="${AI_PLANNING_MODEL:-}"
    if [ -z "$model" ]; then
        model="$(_ai_local_llm_resolve_model)" || return 1
    fi
    _ai_local_llm_run_with_env "$model" _ai_claude_run_planning_impl "$@"
}

_ai_local_llm_run_implementation_impl() {
    local model="${AI_IMPLEMENTATION_MODEL:-}"
    if [ -z "$model" ]; then
        model="$(_ai_local_llm_resolve_model)" || return 1
    fi
    _ai_local_llm_run_with_env "$model" _ai_claude_run_implementation_impl "$@"
}

ai_load_env()           { _ai_local_llm_load_env_impl "$@"; }
ai_run_planning()       { _ai_local_llm_run_planning_impl "$@"; }
ai_run_implementation() { _ai_local_llm_run_implementation_impl "$@"; }
