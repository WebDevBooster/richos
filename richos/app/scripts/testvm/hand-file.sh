#!/usr/bin/env bash
# hand-file.sh — hand the app under test a FILE, the two ways a person does it.
#
#   testvm/hand-file.sh <vm> paste <guest-file>
#   testvm/hand-file.sh <vm> drag  <guest-file> --to <x>,<y>
#
#   paste  puts the file on the guest's pasteboard as macOS would (a .png as image data, which is
#          what a screenshot to the clipboard is; anything else as a file reference, which is what
#          Finder's Copy is), sends Command-V to the app by PID, and restores the text that was on
#          the pasteboard.
#   drag   places the file on the guest user's Desktop and drags it, with real mouse events, from
#          its Finder icon to <x>,<y> in screen coordinates (take them from `ax.sh find --json`).
#
# ===========================================================================
# WHY THIS IS IN THE TOOLKIT
# ===========================================================================
# `ax.sh type` hands the app TEXT. Nothing handed it a file, and the Mac composer takes files
# since CEO ruling §86 (2026-09-24): a screenshot pasted, a PDF dropped. A walk that needs this
# and writes it as a throwaway is the thing `scripts/qa/README.md` exists to stop.
#
# The file must already be in the guest: `guest.sh <vm> --push <host-file> <guest-dir>/`.
#
# ===========================================================================
# THE SAME DISCIPLINE AS ax.sh, BECAUSE IT SENDS THE SAME KIND OF INPUT
# ===========================================================================
# The Command-V and the drag both go only to the app under test, resolved by the PID run.sh
# recorded, and only once that PID is FRONTMOST. A key or a drag that lands anywhere else
# invalidates the test and, on 2026-09-19, reached the operator's Terminal. Everything runs in
# the owned guest; nothing here touches the host's display, pasteboard or input.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${TESTVM_AX_SUPERVISED:-}" != 1 ]; then
  exec env TESTVM_AX_SUPERVISED=1 python3 "$HERE/ax-deadline.py" --host "${TESTVM_AX_TIMEOUT:-30}" bash "$0" "$@" </dev/null
fi
. "$HERE/lib.sh"

usage="usage: hand-file.sh <vm> paste <guest-file> | hand-file.sh <vm> drag <guest-file> --to <x>,<y>"
VM="${1:-}"; MODE="${2:-}"; FILE="${3:-}"
[ -n "$VM" ] && [ -n "$MODE" ] && [ -n "$FILE" ] || die "$usage"
shift 3
TOX=""; TOY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --to)
      case "${2:-}" in
        *,*) TOX="${2%%,*}"; TOY="${2##*,}" ;;
        *) die "--to takes x,y in screen coordinates (for example --to 900,640)" ;;
      esac
      shift 2 ;;
    *) die "unknown argument: $1 — $usage" ;;
  esac
done
case "$MODE" in
  paste) [ -z "$TOX" ] || die "--to belongs to drag" ;;
  drag)
    [ -n "$TOX" ] || die "drag needs --to <x>,<y>: where on the app's window the file is let go"
    case "$TOX$TOY" in *[!0-9.]*) die "--to takes numbers, got $TOX,$TOY" ;; esac ;;
  *) die "$usage" ;;
esac
case "$FILE" in /*) ;; *) die "the guest file must be an absolute path in the guest: $FILE" ;; esac

ag() {  # one indirection to the guest, as ax.sh has, so the tests can use a stub guest
  if [ -n "${TESTVM_GUEST_EXEC:-}" ]; then "$TESTVM_GUEST_EXEC" "$VM" "$@"; else guest_ssh "$VM" "$@"; fi
}
if [ -z "${TESTVM_GUEST_EXEC:-}" ]; then
  preflight_tart
  require_vm_running "$VM"
fi
PID="$(cat "$TESTVM_RUN/$VM/app.pid" 2>/dev/null || true)"
[ -n "$PID" ] || die "no app pid recorded for $VM — was it started by run.sh?"

PARAMS="$(HF_MODE="$MODE" HF_PATH="$FILE" HF_PID="$PID" HF_TOX="$TOX" HF_TOY="$TOY" python3 -c '
import json, os
p = {"mode": os.environ["HF_MODE"], "path": os.environ["HF_PATH"], "pid": int(os.environ["HF_PID"])}
if os.environ["HF_TOX"]:
    p["tox"] = float(os.environ["HF_TOX"]); p["toy"] = float(os.environ["HF_TOY"])
print("var HAND_PARAMS = " + json.dumps(p) + ";")
')"

# The program travels on stdin, never in a remote command line.
{ printf '%s\n' "$PARAMS"; cat "$HERE/hand-file.js"; } | ag "osascript -l JavaScript -" 2>&1 | {
  answer="$(cat)"
  printf '%s\n' "$answer"
  case "$answer" in *'"error"'*) exit 3 ;; *'"handed"'*) exit 0 ;; *) exit 4 ;; esac
}
