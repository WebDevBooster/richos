#!/usr/bin/env bash
#
# wait-for.sh — block until a thing happens, or fail loudly when it does not.
#
#   wait-for.sh --ref <gitdir-or-worktree> <branch> [--from <sha>]
#   wait-for.sh --log <file> <extended-regex>
#   wait-for.sh --file <path>
#   wait-for.sh --time <epoch-seconds>
#   wait-for.sh --new-process <pattern> [--not <pid> ...]
#   wait-for.sh --help
#
# Common options:
#   --timeout N   seconds to wait before giving up (default 300)
#   --poll N      seconds between checks (default 1)
#   --quiet       no progress line
#
# Exit 0 it happened (and the value is printed), 1 the timeout expired, 2 the
# arguments or the target were wrong.
#
# =============================================================================
# WHY THIS FILE EXISTS
# =============================================================================
# `waitref.sh`, `waitlog.sh` and `waituntil.sh` were written in one walk, each
# with its target hard-coded — one waited for a specific 40-character SHA to
# change in a specific scratch repository, one tailed a specific log file in a
# specific scratch directory. None of them could be used twice.
#
# ALL THREE EXITED 0 ON TIMEOUT. `waitref.sh` printed "waited 360s" and the
# unchanged SHA, and returned success; the caller's next step then ran against
# a state that had never arrived, and the failure surfaced somewhere else as
# something else. A wait that times out is a FAILURE and says so in a sentence.
#
# --new-process is the reusable half of the splash/relaunch traps: wait for a
# genuinely NEW top-level process matching a pattern, excluding the sidecar
# processes that share the binary name. The key choreography that follows it
# belongs to the walk, not here.
set -uo pipefail

usage() { sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

MODE=""; A=""; B=""; FROM=""; TIMEOUT=300; POLL=1; QUIET=0
EXCLUDE=()

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)      usage; exit 0 ;;
        --ref)          MODE=ref;  A="${2:-}"; B="${3:-}"; shift 3 ;;
        --log)          MODE=log;  A="${2:-}"; B="${3:-}"; shift 3 ;;
        --file)         MODE=file; A="${2:-}"; shift 2 ;;
        --time)         MODE=time; A="${2:-}"; shift 2 ;;
        --new-process)  MODE=proc; A="${2:-}"; shift 2 ;;
        --from)         FROM="${2:-}"; shift 2 ;;
        --not)          EXCLUDE+=("${2:-}"); shift 2 ;;
        --timeout)      TIMEOUT="${2:-}"; shift 2 ;;
        --poll)         POLL="${2:-}"; shift 2 ;;
        --quiet)        QUIET=1; shift ;;
        *)              echo "wait-for.sh: unexpected argument '$1'. --help" >&2; exit 2 ;;
    esac
done

[ -n "$MODE" ] || { echo "wait-for.sh: name one of --ref --log --file --time --new-process. --help" >&2; exit 2; }
case "$TIMEOUT$POLL" in *[!0-9]*) echo "wait-for.sh: --timeout and --poll are whole seconds." >&2; exit 2 ;; esac
[ "$POLL" -ge 1 ] || POLL=1

now() { date +%s; }
START="$(now)"
DEADLINE=$((START + TIMEOUT))

mains() {
    # Top-level processes only: a parent of 1 (launchd) is the app, a child is
    # a sidecar the app spawned under the same binary name.
    local pat="$1" pid ppid
    for pid in $(pgrep -f "$pat" 2>/dev/null || true); do
        ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
        [ "$ppid" = "1" ] && printf '%s\n' "$pid"
    done
}

# --- validate the target up front, so a typo is not a five-minute timeout ----
case "$MODE" in
    ref)
        [ -n "$A" ] && [ -n "$B" ] || { echo "wait-for.sh: --ref needs a repository and a branch." >&2; exit 2; }
        if ! git -C "$A" rev-parse --git-dir >/dev/null 2>&1; then
            echo "wait-for.sh: $A is not a git repository." >&2; exit 2
        fi
        if [ -z "$FROM" ]; then
            FROM="$(git -C "$A" rev-parse --verify "$B" 2>/dev/null || true)"
            if [ -z "$FROM" ]; then
                echo "wait-for.sh: branch '$B' does not exist in $A, so there is no" >&2
                echo "             starting point to move away from." >&2
                exit 2
            fi
        fi
        ;;
    log)
        [ -n "$A" ] && [ -n "$B" ] || { echo "wait-for.sh: --log needs a file and a pattern." >&2; exit 2; } ;;
    file|time|proc)
        [ -n "$A" ] || { echo "wait-for.sh: that mode needs an argument. --help" >&2; exit 2; } ;;
esac

if [ "$MODE" = time ]; then
    case "$A" in *[!0-9]*) echo "wait-for.sh: --time takes epoch seconds." >&2; exit 2 ;; esac
fi

BEFORE_PIDS=""
if [ "$MODE" = proc ]; then
    BEFORE_PIDS="$(mains "$A" | LC_ALL=C sort | tr '\n' ' ')"
    for x in ${EXCLUDE[@]+"${EXCLUDE[@]}"}; do BEFORE_PIDS="$BEFORE_PIDS $x "; done
fi

[ "$QUIET" -eq 1 ] || echo "waiting up to ${TIMEOUT}s ($MODE) ..."

while :; do
    case "$MODE" in
        ref)
            CUR="$(git -C "$A" rev-parse --verify "$B" 2>/dev/null || true)"
            if [ -n "$CUR" ] && [ "$CUR" != "$FROM" ]; then
                echo "$B moved $FROM -> $CUR after $(( $(now) - START ))s"
                exit 0
            fi ;;
        log)
            if [ -f "$A" ] && grep -qiE -- "$B" "$A" 2>/dev/null; then
                echo "matched after $(( $(now) - START ))s:"
                grep -iE -- "$B" "$A" | tail -3 | sed 's/^/  /'
                exit 0
            fi ;;
        file)
            if [ -e "$A" ]; then
                echo "$A appeared after $(( $(now) - START ))s"
                exit 0
            fi ;;
        time)
            if [ "$(now)" -ge "$A" ]; then
                echo "reached $A at $(now)"
                exit 0
            fi ;;
        proc)
            for pid in $(mains "$A"); do
                case " $BEFORE_PIDS " in
                    *" $pid "*) ;;
                    *) echo "new process $pid after $(( $(now) - START ))s"
                       ps -o pid=,lstart=,args= -p "$pid" 2>/dev/null | sed 's/^/  /'
                       exit 0 ;;
                esac
            done ;;
    esac

    if [ "$(now)" -ge "$DEADLINE" ]; then
        case "$MODE" in
            ref)  echo "wait-for.sh: TIMEOUT after ${TIMEOUT}s — $B in $A is still $FROM." >&2 ;;
            log)  echo "wait-for.sh: TIMEOUT after ${TIMEOUT}s — nothing in $A matched /$B/." >&2 ;;
            file) echo "wait-for.sh: TIMEOUT after ${TIMEOUT}s — $A never appeared." >&2 ;;
            time) echo "wait-for.sh: TIMEOUT after ${TIMEOUT}s — $A is still in the future." >&2 ;;
            proc) echo "wait-for.sh: TIMEOUT after ${TIMEOUT}s — no new process matched /$A/." >&2 ;;
        esac
        echo "             The thing waited for did NOT happen. Do not proceed as if it had." >&2
        exit 1
    fi
    sleep "$POLL"
done
