#!/usr/bin/env bash
# ax.sh — run an AppleScript inside the guest: read the accessibility tree, or
#         send a key to the app under test.
#
#   testvm/ax.sh <vm> '<applescript>'
#   testvm/ax.sh <vm> --focused              # what has focus right now
#   testvm/ax.sh <vm> --windows              # window names and sizes
#   testvm/ax.sh <vm> --key <keycode>        # a special key, to the app's pid
#
# ===========================================================================
# EVERY SYNTHETIC KEY IS ADDRESSED TO A PID, AND REFUSED IF IT IS NOT FRONTMOST
# ===========================================================================
# System Events sends keystrokes to whatever is frontmost. On 2026-09-19 that
# behavior sent a Command-Q into the CEO's Terminal. Inside a guest the blast
# radius is small, but the discipline is the same and it costs nothing: resolve
# the app's pid, verify THAT pid is frontmost, and only then send. A key that
# lands somewhere unintended invalidates the test it was part of.
#
# Note --key sends a KEYCODE, never Command-Q. Quitting is stop.sh's job and it
# does it by pid (see that script's header for why).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"

VM="${1:-}"; shift || true
[ -n "$VM" ] || die "usage: ax.sh <vm> '<applescript>' | --focused | --windows | --key <code>"
preflight_tart
require_vm_running "$VM"

PID="$(cat "$TESTVM_RUN/$VM/app.pid" 2>/dev/null || true)"

case "${1:-}" in
  --focused)
    [ -n "$PID" ] || die "no app pid recorded for $VM — was it started by run.sh?"
    SCRIPT="tell application \"System Events\"
      set p to first process whose unix id is $PID
      set out to \"\"
      try
        set fw to value of attribute \"AXFocusedWindow\" of p
        set out to out & \"window: \" & (name of fw) & linefeed
      end try
      try
        set fe to value of attribute \"AXFocusedUIElement\" of p
        set out to out & \"role: \" & (value of attribute \"AXRole\" of fe) & linefeed
        try
          set out to out & \"title: \" & (value of attribute \"AXTitle\" of fe) & linefeed
        end try
        try
          set out to out & \"description: \" & (value of attribute \"AXDescription\" of fe) & linefeed
        end try
        try
          set out to out & \"value: \" & (value of attribute \"AXValue\" of fe) & linefeed
        end try
      end try
      return out
    end tell"
    ;;
  --windows)
    [ -n "$PID" ] || die "no app pid recorded for $VM"
    SCRIPT="tell application \"System Events\"
      set p to first process whose unix id is $PID
      set out to \"\"
      repeat with w in windows of p
        set out to out & (name of w) & \" \" & (size of w as string) & \" at \" & (position of w as string) & linefeed
      end repeat
      return out
    end tell"
    ;;
  --key)
    CODE="${2:-}"; [ -n "$CODE" ] || die "--key needs a keycode"
    [ -n "$PID" ] || die "no app pid recorded for $VM"
    FRONT="$(guest_ssh "$VM" "osascript -e 'tell application \"System Events\" to unix id of first process whose frontmost is true' 2>/dev/null || echo 0" | tr -d '[:space:]')"
    [ "$FRONT" = "$PID" ] || die "refusing to send a key: frontmost pid is $FRONT, the app under test is $PID. A key sent now would land in another process."
    SCRIPT="tell application \"System Events\" to key code $CODE"
    ;;
  "") die "nothing to run" ;;
  *) SCRIPT="$1" ;;
esac

# The script goes in over stdin, never interpolated into a remote command line:
# AppleScript is full of quotes and newlines and a shell would shred it.
printf '%s' "$SCRIPT" | guest_ssh "$VM" "osascript -" 2>&1 || {
  echo "[testvm] osascript failed. If the error mentions 'not allowed assistive access',"  >&2
  echo "         the Accessibility TCC grant did not take — re-run testvm/setup.sh --reprovision." >&2
  exit 1
}
