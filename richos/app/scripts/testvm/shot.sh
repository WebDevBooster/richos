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

GUEST_PATH="/tmp/testvm-shot-$$.png"

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
VERDICT="$(python3 - "$OUT" <<'PY'
import subprocess, sys, json
png = sys.argv[1]
# sips is on every macOS; no third-party image library needed.
def prop(k):
    out = subprocess.run(["sips","-g",k,png],capture_output=True,text=True).stdout
    for line in out.splitlines():
        if k in line: return line.split(":")[-1].strip()
    return "?"
w,h = prop("pixelWidth"), prop("pixelHeight")
# Histogram via a tiny downscale to a raw bitmap: cheap and dependency-free.
tmp = png + ".probe.tiff"
subprocess.run(["sips","-s","format","tiff","-z","64","64",png,"--out",tmp],
               capture_output=True)
data = open(tmp,"rb").read()
import os; os.remove(tmp)
body = data[-64*64*3:] if len(data) > 64*64*3 else data
nonblack = sum(1 for b in body if b > 24)
pct = 100.0*nonblack/max(1,len(body))
print(json.dumps({"w":w,"h":h,"nonblack_pct":round(pct,1)}))
PY
)"
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
  guest_ssh "$VM" "screencapture -x -t png /tmp/ocr-$$.png && \
      /opt/homebrew/bin/tesseract /tmp/ocr-$$.png - 2>/dev/null; rm -f /tmp/ocr-$$.png"
fi
