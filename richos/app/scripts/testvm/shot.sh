#!/usr/bin/env bash
# shot.sh — capture a real frame of the guest's screen to a host file.
#
#   testvm/shot.sh <vm> <out.png> [--ocr]
#
# --ocr also runs tesseract IN THE GUEST and prints the text, which is the
# cheap gate for "is the thing actually on screen" without a human looking.
#
# A BLACK FRAME IS TREATED AS A FAILURE, NOT A PICTURE. Three different faults
# — a missing TCC ScreenCapture grant, a slept display, an engaged screensaver
# — all produce a perfectly valid PNG full of black pixels. Returning that as
# success is how a harness reports a green run of something it never saw. So
# every capture is measured before it is handed back.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"

VM="${1:-}"; OUT="${2:-}"; shift 2 || true
[ -n "$VM" ] && [ -n "$OUT" ] || die "usage: shot.sh <vm> <out.png> [--ocr]"
WANT_OCR=0
for a in "$@"; do [ "$a" = "--ocr" ] && WANT_OCR=1; done

preflight_tart
require_vm_running "$VM"

# Staged under $HOME, deliberately NOT /tmp. Homebrew's tesseract cannot read a
# file in the guest's /tmp: leptonica's fopenReadStream fails, tesseract then
# falls back to treating the image's own bytes as a list of filenames, and the
# error it prints ("image file not found") names a path that plainly exists.
# Measured in the guest: the identical file OCRs fine from $HOME and fails from
# /tmp. Everything staged guest-side therefore lives under $HOME.
GUEST_PATH="testvm-shot-$$.png"

# -x silences the camera shutter sound. Not cosmetic: the guest's audio is
# mixed into the host's output device, so without it every screenshot makes a
# noise in the CEO's room — the exact intrusion this harness removes.
guest_ssh "$VM" "screencapture -x -t png '$GUEST_PATH'" \
  || die "screencapture failed inside the guest"

mkdir -p "$(dirname "$OUT")"
IP="$(cat "$TESTVM_RUN/$VM/ip" 2>/dev/null || vm_ip "$VM")"
scp "${TESTVM_SSH_OPTS[@]}" -O -i "$TESTVM_SSH_KEY" \
  "$TESTVM_GUEST_USER@$IP:$GUEST_PATH" "$OUT" >/dev/null \
  || die "could not copy the frame out of the guest"
guest_ssh "$VM" "rm -f '$GUEST_PATH'" || true

# --- is it a picture, or is it black? ----------------------------------------
# The measurement is frame-probe.py (decoded pixels, unit-tested on a black and a white frame).
# If it cannot measure, that is a refusal: set -e stops here rather than reading "no answer" as lit.
VERDICT="$(python3 "$HERE/frame-probe.py" "$OUT")" \
  || die "could not measure the captured frame, so it cannot be shown to be a picture. Not returning it."
W="$(echo "$VERDICT"  | python3 -c 'import json,sys;print(json.load(sys.stdin)["w"])')"
H="$(echo "$VERDICT"  | python3 -c 'import json,sys;print(json.load(sys.stdin)["h"])')"
NB="$(echo "$VERDICT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["nonblack_pct"])')"

if [ "$(printf '%.0f' "$NB")" -lt 2 ]; then
  die "captured a BLACK FRAME (${W}x${H}, ${NB}% non-black) — the file exists but shows nothing.
       Cause is one of: the TCC ScreenCapture grant did not take (re-run
       testvm/setup.sh --reprovision, which reboots the guest so tccd reloads),
       the display slept, or a screensaver is up. Not returning this as a capture."
fi

log "captured ${W}x${H}, ${NB}% non-black -> $OUT"

if [ "$WANT_OCR" -eq 1 ]; then
  # cd to $HOME and use a bare filename — see the GUEST_PATH comment above.
  guest_ssh "$VM" "cd \$HOME && screencapture -x -t png ocr-$$.png && \
      /opt/homebrew/bin/tesseract ocr-$$.png - 2>/dev/null; rm -f \$HOME/ocr-$$.png"
fi
