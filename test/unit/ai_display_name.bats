#!/usr/bin/env bats
load '../helpers/load'

# ai_display_name is pure (no network) in every adapter — source directly. jira-common.sh's
# jira_common_ai_footer is likewise pure; bats runs each @test in its own subshell/process so
# function definitions from one `source` never leak into the next test.

@test "ai/claude.sh: ai_display_name prints Claude" {
    source "$REPO_ROOT/lib/ai/claude.sh"
    [ "$(ai_display_name)" = "Claude" ]
}

@test "ai/gemini.sh: ai_display_name prints Gemini" {
    source "$REPO_ROOT/lib/ai/gemini.sh"
    [ "$(ai_display_name)" = "Gemini" ]
}

@test "ai/codex.sh: ai_display_name prints Codex" {
    source "$REPO_ROOT/lib/ai/codex.sh"
    [ "$(ai_display_name)" = "Codex" ]
}

@test "ai/antigravity.sh: ai_display_name prints Antigravity" {
    source "$REPO_ROOT/lib/ai/antigravity.sh"
    [ "$(ai_display_name)" = "Antigravity" ]
}

@test "ai/local-llm.sh: ai_display_name prints Local LLM, not Claude" {
    source "$REPO_ROOT/lib/ai/local-llm.sh"
    [ "$(ai_display_name)" = "Local LLM" ]
}

@test "jira-common.sh: jira_common_ai_footer falls back to AI when no adapter is sourced" {
    source "$REPO_ROOT/lib/tracker/jira-common.sh"
    [[ "$(jira_common_ai_footer)" == *"Posted by AI"* ]]
}

@test "jira-common.sh: jira_common_ai_footer names the sourced adapter's provider" {
    source "$REPO_ROOT/lib/tracker/jira-common.sh"
    source "$REPO_ROOT/lib/ai/gemini.sh"
    [[ "$(jira_common_ai_footer)" == *"Posted by Gemini"* ]]
}
