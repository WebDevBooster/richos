#!/usr/bin/env bash
# arg-parsers.test.sh — a value-taking option given last, with no value, ends the command at once
# with a nonzero exit that names the option (hunt part 2 v3, R44).
#
# Eight shell parsers read a value as "${2:-}" and then `shift 2` (wait-for.sh's --ref and --log:
# `shift 3`). Without errexit, a `shift` past the end fails and shifts nothing, so the loop saw the
# same option forever and the command spun until something killed it. run-tests.sh was fixed in
# 0a658a67; these eight were not.
#
# THE PARSER ALONE IS RUN, NEVER THE SCRIPT: each file's first top-level argument loop (from
# `while [ $# -gt 0 ]; do` to its `done`) is cut out and run under `set -uo pipefail` with a stub
# `die` and `usage`, so nothing a script does after parsing (a release build, a guest, a capture)
# can start. Every option whose line reads "${2:-...}" is given alone as the last word; a two-value
# option is also given one value. Each run gets 5 s; a run still going then is this suite's own
# child and is killed by its recorded pid.
#
# run-tests: no-host-screen: it runs only argument loops cut out of the scripts, never a script itself
# run-tests: inputs richos/app/scripts/arg-parsers.test.sh richos/app/scripts/rebuild-survival.sh richos/app/scripts/front-door.test.sh richos/app/scripts/make-release.sh richos/app/scripts/gui-proof-in-vm.sh richos/app/scripts/testvm/suite-walk.sh richos/app/scripts/qa/ocr-watch.sh richos/app/scripts/qa/ocr-gate.sh richos/app/scripts/qa/wait-for.sh
# run-tests: covers -
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/arg-parsers-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n         %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }

parser_of() {  # parser_of <script> <harness file>: the first top-level argument loop, runnable alone
  # shellcheck disable=SC2016  # the stub lines are written for the harness, where $1 expands, not here
  {
    echo 'set -uo pipefail'
    echo 'die() { echo "REFUSING: $1" >&2; exit 2; }'
    echo 'usage() { :; }'
    awk '/^while \[ \$# -gt 0 \]; do/ { on = 1 } on { print } on && /^done/ { exit }' "$1"
    echo 'echo "parsed to the end" >&2; exit 0'
  } > "$2"
}

bounded() {  # bounded <harness> <args...>: sets RC (or empty when it was still running after 5 s) and ERR
  bash "$@" > "$TMP/out" 2> "$TMP/err" &
  local pid=$! n=0
  while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null   # this suite's own child, by its recorded pid
    wait "$pid" 2>/dev/null
    RC=""
  else
    wait "$pid"; RC=$?
  fi
  ERR="$(cat "$TMP/err")"
}

for rel in rebuild-survival.sh front-door.test.sh make-release.sh gui-proof-in-vm.sh testvm/suite-walk.sh \
           qa/ocr-watch.sh qa/ocr-gate.sh qa/wait-for.sh; do
  harness="$TMP/$(basename "$rel").parser"
  parser_of "$DIR/$rel" "$harness"
  if ! grep -q '^done' "$harness"; then
    bad "R44 $rel" "no top-level argument loop was found to test"
    continue
  fi
  options="$(sed -n 's/^[[:space:]]*\(--[A-Za-z0-9-]*\))[[:space:]].*\${2:-.*/\1/p' "$harness")"
  [ -n "$options" ] || { bad "R44 $rel" "no value-taking option was found in its argument loop"; continue; }
  spun=""; silent=""; count=0
  for opt in $options; do
    calls=("$opt")
    if grep -q -- "^[[:space:]]*$opt).*shift 3" "$harness"; then calls+=("$opt one-value"); fi
    for call in "${calls[@]}"; do
      # shellcheck disable=SC2086  # the call is the option and, for a two-value option, one value
      bounded "$harness" $call
      count=$((count + 1))
      if [ -z "$RC" ]; then spun="$spun $call;"
      elif [ "$RC" -eq 0 ] || ! grep -q -- "$opt" <<<"$ERR"; then silent="$silent $call (exit $RC: $ERR);"
      fi
    done
  done
  if [ -n "$spun" ]; then
    bad "R44 $rel: an option with no value ends the parse" "still looping after 5 s:$spun"
  elif [ -n "$silent" ]; then
    bad "R44 $rel: an option with no value is refused by name" "$silent"
  else
    ok "R44 $rel: each of $count option(s) with its value missing exits nonzero at once and names the option"
  fi
done

# The control: a complete command line still parses to the end.
parser_of "$DIR/qa/wait-for.sh" "$TMP/control.parser"
bounded "$TMP/control.parser" --file /tmp/x --timeout 5
if [ "$RC" = 0 ] && grep -q 'parsed to the end' <<<"$ERR"; then
  ok "R44 control: a complete wait-for.sh command line still parses to the end"
else
  bad "R44 control: a complete command line parses" "exit ${RC:-still running}: $ERR"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "=== arg-parsers.test.sh: $FAIL FAILED, $PASS passed ==="
  exit 1
fi
echo "=== arg-parsers tests: all $PASS passed ==="
