#!/usr/bin/env bash
# flake-rate.sh — how often does a command fail? Run it N times, interleaved with the
# commands it is being compared against, and count.
#
# usage: flake-rate.sh --runs N [--nice] [--admit] [--log-dir DIR] LABEL 'COMMAND' [LABEL 'COMMAND' ...]
#
#   --runs N      rounds; every round runs each LABEL once, in the order given, so a
#                 before/after pair sees the same host load round by round
#   --nice        run each command under `nice -n 10` (CEO §78: this is how a test run
#                 goes ahead on a busy Mac instead of waiting)
#   --admit       before each run, take one CPU sample through ../testvm/reserve.py and
#                 skip the run when the Mac is 80% busy or more; a skipped run is counted
#                 as NOT ADMITTED, never as a pass or a failure
#   --log-dir DIR where each run's output goes (default: a new directory under $TMPDIR).
#                 Logs of passing runs are deleted; failing ones are kept and named. A
#                 default directory with nothing kept is removed.
#
# COMMAND is run with `bash -c`; exit 0 is a pass, anything else a failure.
# Prints one line per LABEL: pass, fail and not-admitted counts out of N.
#
# Exit: 0 when every LABEL was measured at least once (failures are the answer, not an
# error), 1 when some LABEL was never admitted and so was not measured, 2 on bad usage.
#
# Why it exists: the mobile-pwa flake of 2026-09-22 was measured with scratch loops that
# were rewritten three times in one afternoon. A failure rate is only comparable when it
# is counted the same way every time.
set -uo pipefail

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "flake-rate.sh: $1" >&2; exit 2; }

RUNS=""; NICE=0; ADMIT=0; LOGDIR=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --runs) [ "$#" -ge 2 ] || die "--runs needs a number"; RUNS="$2"; shift 2 ;;
    --nice) NICE=1; shift ;;
    --admit) ADMIT=1; shift ;;
    --log-dir) [ "$#" -ge 2 ] || die "--log-dir needs a directory"; LOGDIR="$2"; shift 2 ;;
    --) shift; break ;;
    -*) die "unknown option '$1' — see --help" ;;
    *) break ;;
  esac
done
case "$RUNS" in ''|*[!0-9]*|0) die "--runs must be a positive whole number" ;; esac
[ "$#" -ge 2 ] || die "give at least one LABEL 'COMMAND' pair"
[ $(( $# % 2 )) -eq 0 ] || die "every LABEL needs a COMMAND after it"

LABELS=(); CMDS=()
while [ "$#" -gt 0 ]; do
  case "$1" in ''|*[!A-Za-z0-9._-]*) die "a LABEL is letters, digits, '.', '_' or '-': '$1'" ;; esac
  LABELS+=("$1"); CMDS+=("$2"); shift 2
done

MADE=0
if [ -z "$LOGDIR" ]; then
  LOGDIR="$(mktemp -d "${TMPDIR:-/tmp}/flake-rate.XXXXXX")" || die "could not make a log directory"
  MADE=1
else
  mkdir -p "$LOGDIR" || die "could not make $LOGDIR"
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
admitted() {
  python3 - "$HERE/../testvm" <<'PY' >/dev/null 2>&1
import sys
sys.path.insert(0, sys.argv[1])
import reserve
reserve.cpu_admission(80, 0)
PY
}

run_one() {  # run_one COMMAND LOG — the command's own exit status
  if [ "$NICE" = 1 ]; then nice -n 10 bash -c "$1" > "$2" 2>&1
  else bash -c "$1" > "$2" 2>&1; fi
}

n=${#LABELS[@]}
PASS=(); FAIL=(); SKIP=(); KEPT=()
i=0; while [ "$i" -lt "$n" ]; do PASS[i]=0; FAIL[i]=0; SKIP[i]=0; i=$((i + 1)); done

round=1
while [ "$round" -le "$RUNS" ]; do
  i=0
  while [ "$i" -lt "$n" ]; do
    label="${LABELS[$i]}"; log="$LOGDIR/$label-$round.log"
    if [ "$ADMIT" = 1 ] && ! admitted; then
      SKIP[i]=$((SKIP[i] + 1))
    elif run_one "${CMDS[$i]}" "$log"; then
      PASS[i]=$((PASS[i] + 1)); rm -f "$log"
    else
      FAIL[i]=$((FAIL[i] + 1)); KEPT+=("$log")
    fi
    i=$((i + 1))
  done
  round=$((round + 1))
done

unmeasured=0
i=0
while [ "$i" -lt "$n" ]; do
  echo "${LABELS[$i]}: pass=${PASS[$i]} fail=${FAIL[$i]} not-admitted=${SKIP[$i]} of $RUNS"
  [ $(( PASS[i] + FAIL[i] )) -gt 0 ] || unmeasured=1
  i=$((i + 1))
done
if [ "${#KEPT[@]}" -gt 0 ]; then
  echo "failing runs kept:"
  for k in "${KEPT[@]}"; do echo "  $k"; done
elif [ "$MADE" = 1 ]; then
  rmdir "$LOGDIR" 2>/dev/null || true
fi
if [ "$unmeasured" = 1 ]; then
  echo "flake-rate.sh: at least one LABEL was never admitted, so it was not measured" >&2
  exit 1
fi
exit 0
