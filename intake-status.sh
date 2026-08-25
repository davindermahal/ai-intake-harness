#!/bin/bash
# Read-only snapshot of what the intake pipeline is currently doing: the tracker's queued/
# in-progress tickets (from the same abstract planning/implementation/in-progress queues
# intake-poll.sh dispatches from), cross-referenced with local runtime state — live implementation
# workers (.intake/running/<KEY>.pid), in-flight markers (.intake/inflight/<KEY>), and watchdog
# attempt counts (.intake/attempts/<KEY>). Makes no tracker writes and never dispatches anything.
#
# Deliberately loads only the tracker_* adapter directly (NOT lib/intake-config.sh, which also
# forces a project_*/ai_* adapter to exist) — a status report has no business requiring a project
# adapter, and doing it this way keeps this command usable even on an install that hasn't finished
# wiring up scripts/lib/project/ yet.
#
# Excludes plan-review / needs-author-input / ready-for-verification: those are waiting on a human
# (you), not being actively worked by the automation, which is what this reports on.
#
# Usage: bash intake-status.sh [--mode planning|implementation|in-progress|all]   (default: all)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Same self-hosted-vs-vendored REPO_ROOT detection as intake-poll.sh (see its header comment).
if [ "$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" = "$SCRIPT_DIR" ]; then
    REPO_ROOT="$SCRIPT_DIR"
else
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
cd "$REPO_ROOT"

MODE="all"
while [ $# -gt 0 ]; do
    case "$1" in
        --mode) MODE="$2"; shift 2 ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

CONFIG_FILE="$REPO_ROOT/.ai/intake.config"
[ -f "$CONFIG_FILE" ] || { echo "intake-status: no .ai/intake.config found at $CONFIG_FILE" >&2; exit 1; }
# shellcheck source=/dev/null
. "$CONFIG_FILE"
TRACKER="${TRACKER:-jira}"

# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/tracker/${TRACKER}.sh"
tracker_load_env "$REPO_ROOT" || exit 1

STATE_DIR="$REPO_ROOT/.intake"
RUNNING_DIR="$STATE_DIR/running"
INFLIGHT_DIR="$STATE_DIR/inflight"
ATTEMPTS_DIR="$STATE_DIR/attempts"

# worker_status KEY — "pid <n> (running)" / "pid <n> (dead, awaiting reap)" / "-" (no running-slot
# file at all, i.e. no implementation worker was ever launched for this ticket by this checkout).
worker_status() {
    local key="$1"
    local pidfile="$RUNNING_DIR/$key.pid" pid
    [ -f "$pidfile" ] || { echo "-"; return; }
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        echo "pid $pid (running)"
    else
        echo "pid ${pid:-?} (dead, awaiting reap)"
    fi
}

# inflight_status KEY — "yes (<age>s ago)" while a poll pass has this ticket's marker held, else "no".
inflight_status() {
    local key="$1"
    local f="$INFLIGHT_DIR/$key" age
    [ -f "$f" ] || { echo "no"; return; }
    age=$(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))
    echo "yes (${age}s ago)"
}

# attempts_status KEY — watchdog dispatch history, or "-" if this ticket was never harness-dispatched.
attempts_status() {
    local key="$1"
    local f="$ATTEMPTS_DIR/$key" attempts launched escalated=""
    [ -f "$f" ] || { echo "-"; return; }
    attempts="$(sed -n 's/^attempts=//p' "$f")"
    launched="$(sed -n 's/^launched=//p' "$f")"
    [ -f "$f.escalated" ] && escalated=", ESCALATED"
    echo "attempt ${attempts:-?} (launched $(( $(date +%s) - ${launched:-0} ))s ago)${escalated}"
}

print_section() {
    local title="$1" queue="$2" show_worker="$3" key n=0
    echo
    echo "== $title =="
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        n=$((n + 1))
        if [ "$show_worker" = "1" ]; then
            printf '  %-12s in-flight: %-16s worker: %-28s %s\n' \
                "$key" "$(inflight_status "$key")" "$(worker_status "$key")" "$(attempts_status "$key")"
        else
            printf '  %-12s in-flight: %s\n' "$key" "$(inflight_status "$key")"
        fi
    done < <(tracker_search "$queue")
    if [ "$n" -eq 0 ]; then echo "  (none)"; fi
}

case "$MODE" in
    planning)       print_section "Queued for planning"       planning       0 ;;
    implementation) print_section "Queued for implementation" implementation 0 ;;
    in-progress)    print_section "In progress"                in-progress    1 ;;
    all)
        print_section "Queued for planning"       planning       0
        print_section "Queued for implementation" implementation 0
        print_section "In progress"                in-progress    1
        ;;
    *) echo "intake-status: invalid --mode '$MODE' (planning|implementation|in-progress|all)" >&2; exit 2 ;;
esac
echo
