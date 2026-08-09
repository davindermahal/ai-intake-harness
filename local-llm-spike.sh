#!/bin/bash
# Live spike / diagnostic for the local-llm AI adapter.
# Run this from any host that can reach LM Studio to prove the direct native-endpoint mode
# lib/ai/local-llm.sh relies on actually works with the installed LM Studio + loaded model:
#
#   1. GET  <base>/models             — LM Studio reachable; list loaded model ids
#   2. POST <root>/v1/messages  {}    — native Anthropic endpoint PRESENT? (404 = too old)
#   3. POST <root>/v1/messages  real  — a small inference round-trip through the native endpoint
#   4. POST <root>/v1/messages  tools — does the model emit a tool_use block? (agentic viability)
#   5. (--claude) a real `claude -p` round-trip via ANTHROPIC_BASE_URL — the full stack
#
# Checks 1–4 are pure curl (safe anywhere). Check 5 launches the claude CLI against the local
# model in an EMPTY temp dir with no tools allowed, so it can't touch this repo; it's optional
# because it needs the claude CLI installed and burns a real agent turn on the local model.
#
# Usage:
#   bash ai-intake-harness/local-llm-spike.sh [--claude]
#
# Reads AI_LOCAL_LLM_BASE_URL / AI_LOCAL_LLM_MODEL from the environment, falling back to
# .ai/intake.config, falling back to the same defaults the harness uses. Exit status: 0 when
# every check that ran passed, 1 otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RUN_CLAUDE=0
[ "${1:-}" = "--claude" ] && RUN_CLAUDE=1

# Env > config file > default — same precedence as lib/intake-config.sh, but without sourcing
# the tracker/project adapters this diagnostic doesn't need.
_env_base="${AI_LOCAL_LLM_BASE_URL:-}"
_env_model="${AI_LOCAL_LLM_MODEL:-}"
if [ -f "$REPO_ROOT/.ai/intake.config" ]; then
    # shellcheck source=/dev/null
    . "$REPO_ROOT/.ai/intake.config"
fi
[ -n "$_env_base" ] && AI_LOCAL_LLM_BASE_URL="$_env_base"
[ -n "$_env_model" ] && AI_LOCAL_LLM_MODEL="$_env_model"
BASE="${AI_LOCAL_LLM_BASE_URL:-http://localhost:1234/v1}"
BASE="${BASE%/}"
ROOT="${BASE%/v1}"
MODEL="${AI_LOCAL_LLM_MODEL:-}"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS  $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }
say()  { echo; echo "== $*"; }

echo "local-llm live spike — LM Studio at $ROOT (OpenAI base $BASE)"

# ----- 1. reachability + loaded models -------------------------------------------------
say "1. GET $BASE/models"
models_json="$(curl -sS --max-time 5 "$BASE/models" 2>&1)"
if [ $? -ne 0 ] || [ -z "$models_json" ]; then
    bad "LM Studio not reachable: ${models_json:-empty response}"
    echo
    echo "Nothing else can run. Start LM Studio's local server (Developer tab -> Start Server,"
    echo "'Serve on Local Network' ON if this host is remote) or fix AI_LOCAL_LLM_BASE_URL."
    exit 1
fi
model_ids="$(printf '%s' "$models_json" | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/.*"([^"]*)"$/\1/')"
if [ -n "$model_ids" ]; then
    ok "reachable; loaded model(s):"
    printf '%s\n' "$model_ids" | sed 's/^/          - /'
else
    bad "reachable but no models loaded — load one in LM Studio first"
    exit 1
fi
if [ -z "$MODEL" ]; then
    MODEL="$(printf '%s\n' "$model_ids" | head -1)"
    echo "        (no AI_LOCAL_LLM_MODEL set — using '$MODEL' for the remaining checks)"
fi

# ----- 2. native Anthropic endpoint present? --------------------------------------------
say "2. POST $ROOT/v1/messages (empty body — endpoint existence)"
code="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' \
    -X POST -H 'Content-Type: application/json' -d '{}' "$ROOT/v1/messages" 2>/dev/null)"
if [ "$code" = "404" ] || [ -z "$code" ] || [ "$code" = "000" ]; then
    bad "no native Anthropic endpoint (HTTP ${code:-none}) — this LM Studio predates it; upgrade to a 0.3.x+ build. The local-llm adapter cannot work until this passes."
    exit 1
else
    ok "endpoint exists (HTTP $code for an empty body)"
fi

# ----- 3. real inference through the native endpoint ------------------------------------
say "3. POST $ROOT/v1/messages (inference, model $MODEL)"
resp="$(curl -sS --max-time 120 -X POST -H 'Content-Type: application/json' \
    -H 'anthropic-version: 2023-06-01' -H 'x-api-key: lm-studio' \
    -d "{\"model\":\"$MODEL\",\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly the word: pong\"}]}" \
    "$ROOT/v1/messages" 2>&1)"
if printf '%s' "$resp" | grep -q '"type"[[:space:]]*:[[:space:]]*"message"'; then
    ok "native-endpoint inference works"
else
    bad "unexpected response: $(printf '%s' "$resp" | head -c 400)"
fi

# ----- 4. tool-use emission ---------------------------------------------------------------
say "4. POST $ROOT/v1/messages (tool_use, model $MODEL)"
resp="$(curl -sS --max-time 120 -X POST -H 'Content-Type: application/json' \
    -H 'anthropic-version: 2023-06-01' -H 'x-api-key: lm-studio' \
    -d "{\"model\":\"$MODEL\",\"max_tokens\":256,\"tools\":[{\"name\":\"get_weather\",\"description\":\"Get the current weather for a city.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}},\"required\":[\"city\"]}}],\"messages\":[{\"role\":\"user\",\"content\":\"Use the get_weather tool to check the weather in Paris.\"}]}" \
    "$ROOT/v1/messages" 2>&1)"
if printf '%s' "$resp" | grep -q '"type"[[:space:]]*:[[:space:]]*"tool_use"'; then
    ok "model emitted a tool_use block — agentic use looks viable"
else
    bad "no tool_use block in response — this model/endpoint may not support tool calling reliably; implementation runs should stay on Claude (planning-only floor). Response head: $(printf '%s' "$resp" | head -c 400)"
fi

# ----- 5. optional: the full claude CLI stack ---------------------------------------------
if [ "$RUN_CLAUDE" = "1" ]; then
    say "5. claude -p round-trip via ANTHROPIC_BASE_URL=$ROOT"
    if ! command -v "${CLAUDE_BIN:-claude}" >/dev/null 2>&1; then
        bad "'${CLAUDE_BIN:-claude}' not found on PATH — install the claude CLI to run this check"
    else
        tmpdir="$(mktemp -d)"
        out="$(cd "$tmpdir" && ANTHROPIC_BASE_URL="$ROOT" ANTHROPIC_AUTH_TOKEN=lm-studio \
            ANTHROPIC_API_KEY=lm-studio ANTHROPIC_MODEL="$MODEL" ANTHROPIC_SMALL_FAST_MODEL="$MODEL" \
            timeout 600 "${CLAUDE_BIN:-claude}" -p "Reply with exactly the single word: SPIKE-OK" \
            --model "$MODEL" --disallowedTools "*" 2>&1)"
        if printf '%s' "$out" | grep -q 'SPIKE-OK'; then
            ok "claude CLI round-trip against the local model works"
        else
            bad "claude CLI round-trip failed. Output head: $(printf '%s' "$out" | head -c 400)"
        fi
        rm -rf "$tmpdir"
    fi
else
    echo
    echo "(skipped check 5 — re-run with --claude for a real claude CLI round-trip)"
fi

echo
echo "== spike result: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
