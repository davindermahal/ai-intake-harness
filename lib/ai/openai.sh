#!/bin/bash
# AI adapter: OpenAI — STUB ONLY. Implements the ai_* contract (ai_load_env,
# ai_run_planning, ai_run_implementation) so AI_PROVIDER=openai / the ai-provider-openai Jira label
# exercise the seam end-to-end, but none of the three functions do anything real yet: actual
# Codex-CLI integration is deferred until a second real AI-CLI consumer exists to design against.
# Selecting this provider fails loudly and immediately rather than silently doing nothing.
#
# Not guarded against re-sourcing — see ai/claude.sh's header comment for why (a per-ticket label
# can switch providers within one poller process).

_ai_openai_not_implemented() {
    echo "ai/openai: openai provider not yet implemented (stub only). Select AI_PROVIDER=claude or AI_PROVIDER=local-llm instead." >&2
    return 1
}

ai_load_env()           { _ai_openai_not_implemented; }
ai_run_planning()       { _ai_openai_not_implemented; }
ai_run_implementation() { _ai_openai_not_implemented; }
