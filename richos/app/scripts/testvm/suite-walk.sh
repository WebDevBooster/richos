#!/usr/bin/env bash
#
# suite-walk.sh — the part of run-suite.sh that holds a guest. run-walk.py runs it inside
#                 the guest slot, with the booted guest's name as its first argument.
#
#   suite-walk.sh <vm> --stage <dir> --suite <name> --engine <dir> --rc <file>
#                 [--runtime <dir>] [--results <dir>]
#
# It pushes the payload, runs the suite in the guest (suite-in-guest.sh), streams the
# suite's output as its own, and writes the suite's exit code to --rc. It exits 0 when the
# suite ran to the end, whatever the suite's verdict, and 3 when it could not get the suite
# to the end: the verdict is the suite's, read from --rc by run-suite.sh, and this script's
# own exit only says whether there is one. Nothing here boots or deletes a guest; run-walk.py
# does both, around this, however it ends.
#
# TESTVM_GUEST_EXEC, when set, replaces guest.sh as the way a command reaches the guest (the
# seam keychain.sh and tailnet.sh use), so run-tests.test.sh can run all of this against a
# stand-in guest.
#
# shellcheck disable=SC2016  # every single-quoted "$HOME" below is the GUEST's, expanded by the guest's shell, never this Mac's
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VM="${1:-}"; shift 2>/dev/null
STAGE=""; SUITE=""; ENGINE=""; RUNTIME=""; RC_FILE=""; RESULTS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --stage)   STAGE="${2:-}"; shift 2 ;;
    --suite)   SUITE="${2:-}"; shift 2 ;;
    --engine)  ENGINE="${2:-}"; shift 2 ;;
    --runtime) RUNTIME="${2:-}"; shift 2 ;;
    --rc)      RC_FILE="${2:-}"; shift 2 ;;
    --results) RESULTS="${2:-}"; shift 2 ;;
    *) echo "suite-walk.sh: unknown argument '$1'" >&2; exit 64 ;;
  esac
done
if [ -z "$VM" ] || [ -z "$STAGE" ] || [ -z "$SUITE" ] || [ -z "$ENGINE" ] || [ -z "$RC_FILE" ]; then
  echo "suite-walk.sh: usage: suite-walk.sh <vm> --stage <dir> --suite <name> --engine <dir> --rc <file> [--runtime <dir>] [--results <dir>]" >&2
  exit 64
fi

guest() {
  if [ -n "${TESTVM_GUEST_EXEC:-}" ]; then
    "$TESTVM_GUEST_EXEC" "$VM" "$@"
  else
    "$HERE/guest.sh" "$VM" "$@"
  fi
}

# push <host dir> <directory under the guest's $HOME/run-suite, or "">
# tar over ssh, never scp -r, for the reason run.sh gives: the runtime and the engine carry
# symlinks whose shape matters, and scp -r follows and flattens them.
push() {
  local dest='"$HOME/run-suite'"${2:+/$2}"'"'
  tar -C "$1" -cf - . | guest "mkdir -p $dest && tar -C $dest -xf -"
}

gone() { echo "suite-walk.sh: $*" >&2; exit 3; }

rm -f "$RC_FILE"
T0=$(date +%s)
guest 'rm -rf "$HOME/run-suite" && mkdir -p "$HOME/run-suite"' || gone "could not make the payload directory in $VM"
push "$STAGE" ""        || gone "the payload (the prebuilt executables and the scripts) did not arrive in $VM"
push "$ENGINE" engine   || gone "the engine at $ENGINE did not arrive in $VM"
if [ -n "$RUNTIME" ]; then
  push "$RUNTIME" runtime || gone "the runtime at $RUNTIME did not arrive in $VM"
fi
echo "  [guest $VM] payload in place in $(( $(date +%s) - T0 ))s; running $SUITE"

# The suite's output is this script's output, live. Its exit code is NOT read from ssh: 255
# is also ssh's own failure, so the suite writes its code to a file and that file is read.
guest "/bin/bash \"\$HOME/run-suite/tree/richos/app/scripts/testvm/suite-in-guest.sh\" $(printf '%q' "$SUITE")"
RC="$(guest 'cat "$HOME/run-suite/suite.rc" 2>/dev/null' | tr -d '[:space:]')"
case "$RC" in
  ''|*[!0-9]*) gone "$SUITE did not run to the end in $VM: it left no exit code (read '${RC}')" ;;
esac
printf '%s\n' "$RC" > "$RC_FILE"

# Its results folder comes back beside the host's, when the caller named one.
if [ -n "$RESULTS" ]; then
  mkdir -p "$RESULTS"
  guest 'cd "$HOME/run-suite/results" 2>/dev/null && tar -cf - .' | tar -C "$RESULTS" -xf - 2>/dev/null \
    || echo "  [guest $VM] the suite's results folder could not be brought back to $RESULTS"
fi
exit 0
