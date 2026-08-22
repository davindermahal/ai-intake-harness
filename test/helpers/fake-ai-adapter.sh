#!/bin/bash
# Fake ai_* adapter used by the intake-poll.sh test fixture (see poller_fixture_init in
# test/helpers/fakes.bash). Controlled per-test via env vars so a real AI CLI is never invoked:
#   FAKE_AI_LOAD_ENV_RC              ai_load_env's return code               (default 0)
#   FAKE_AI_RUN_PLANNING_RC          ai_run_planning's return code           (default 0)
#   FAKE_AI_RUN_PLANNING_DECISION    path to a decision JSON to copy to $DEC (default: none written)
#   FAKE_AI_RUN_IMPLEMENTATION_RC    ai_run_implementation's return code     (default 0)
# Every call is also appended to $CALL_LOG as "func_name arg1 arg2 ..." so tests can assert call
# counts/args without a mock framework.

ai_load_env() {
    printf 'ai_load_env %s\n' "$*" >> "$CALL_LOG"
    return "${FAKE_AI_LOAD_ENV_RC:-0}"
}

# ai_run_planning KEY BRANCH CTX DEC WT
ai_run_planning() {
    printf 'ai_run_planning %s\n' "$*" >> "$CALL_LOG"
    local dec="$4"
    if [ -n "${FAKE_AI_RUN_PLANNING_DECISION:-}" ] && [ -f "$FAKE_AI_RUN_PLANNING_DECISION" ]; then
        cp "$FAKE_AI_RUN_PLANNING_DECISION" "$dec"
    fi
    return "${FAKE_AI_RUN_PLANNING_RC:-0}"
}

# ai_run_implementation LOGFILE PIDFILE
ai_run_implementation() {
    printf 'ai_run_implementation %s\n' "$*" >> "$CALL_LOG"
    echo $$ > "$2"
    return "${FAKE_AI_RUN_IMPLEMENTATION_RC:-0}"
}
