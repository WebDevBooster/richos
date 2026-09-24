#!/usr/bin/env bash
#
# qa.test.sh — the acceptance suite for the walk toolkit in scripts/qa/.
#
# WHY IT IS HERE AND NOT AT scripts/qa/qa.test.sh
# ===============================================
# `run-tests.sh` builds its inventory with `find -maxdepth 1`. A suite one
# directory down runs in no build and appears in no `--only` list — which is
# how `scripts/testvm/test/run-tests.sh` came to be invisible, recorded in
# `proof-for.sh`'s own comment. A toolkit whose tests never run is a toolkit
# whose next user rewrites it, so the suite sits where the harness looks and
# the tools sit next to each other.
#
# WHAT IT PROVES, AND WHAT IT DELIBERATELY DOES NOT
# =================================================
# Every case runs against committed fixtures in seconds. Nothing here boots a
# VM, opens a window, photographs a screen or presses a key: the two tools
# that CAN do those things are proved by driving them into their refusal.
#
# The refusals are the point of half of this file. Each tool replaces a
# scratch script that reported success in a state where it had measured
# nothing — a wait that timed out and exited 0, a gate whose reader was blind,
# a redactor that never re-read its output, a contrast estimator that took a
# single antialiasing pixel as the ink. Those are the cases with the long
# names.
#
# Cases:
#   H1-H9   every tool answers --help and exits 0
#   C1-C9   contrast: the arithmetic, the spellings, the thresholds, refusals
#   P1-P3   the PNG layer: the no-Pillow decoder agrees with Pillow, round trip
#   F1-F6   frame: pixels, extent, inset, motion, and mismatched sizes refused
#   O1-O6   the OCR gate and the finder, including a blind reader and an
#           empty frame set
#   R1-R4   redact: it covers the address, it keeps the evidence, it re-reads
#   W1-W6   wait-for: it succeeds, and it FAILS on timeout
#   T1-T6   timeline: first change, no change, no baseline, stats, refusals
#   N1-N5   phone-client: a foreign Mac that refuses the credential is the
#           answer, one that ACCEPTS it exits non-zero; argument refusals
#   K1-K5   flake-rate: counts, interleaving, a kept failing log, refusals
#   R5-R8   redact --phones: the gate flags a phone-shaped fixture, the redactor
#           covers it, the gate then passes the output, the evidence survives
#   A1-A17  phone-android: taps by the words on screen, refuses an unnamed or
#           unattached phone, times out as a failure, reads a closure state and
#           an idle-frame rhythm, types through a key map, reads the editable
#           field, runs one closure cell, finds unnamed controls, all against a
#           scripted adb (no phone)
#   L1-L4   lab-ledger: exactly once passes; missing, duplicated or altered
#           fails; a timeline without the isolated lab's owner marker is refused
#   I1-I16  phone-ios: a step list validated before any build, refusals, the
#           per-step log read once each, no picture of the person's account,
#           a reused build trusted only against its stamp, no lock without a
#           person to open it, a bounded log capture kept on the SSD
#   X1      the committed fixtures still match their generator
#
# run-tests: no-host-screen: its only capture/keystroke references are the strings it asserts those two tools REFUSE to act on, and its frames are committed PNG fixtures
# run-tests: inputs richos/app/scripts/qa.test.sh richos/app/scripts/qa
# run-tests: covers richos/app/scripts/qa/contrast.py richos/app/scripts/qa/frame.py richos/app/scripts/qa/lib/qaimg.py richos/app/scripts/qa/lib/qaocr.py richos/app/scripts/qa/ocr-find.py richos/app/scripts/qa/ocr-find.sh richos/app/scripts/qa/ocr-gate.sh richos/app/scripts/qa/ocr-read.py richos/app/scripts/qa/ocr-watch.sh richos/app/scripts/qa/redact.py richos/app/scripts/qa/timeline.py richos/app/scripts/qa/timeline-bounds.test.py richos/app/scripts/qa/wait-for.sh richos/app/scripts/qa/phone-client.mjs richos/app/scripts/qa/flake-rate.sh richos/app/scripts/qa/phone-android.py richos/app/scripts/qa/lab-ledger.py richos/app/scripts/qa/fixtures/make-fixtures.py richos/app/scripts/qa/phone-ios.py
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QA="$DIR/qa"
FIX="$QA/fixtures"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/qa-toolkit-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0; SKIP=0
ok()   { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL  %s\n         %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }
skip() { printf '  SKIP  %s\n         %s\n' "$1" "${2:-}"; SKIP=$((SKIP + 1)); }
run()  { OUT="$("$@" 2>&1)"; CODE=$?; return 0; }

expect() {  # expect <name> <exit> <substring>
  local name="$1" want="$2" needle="$3"
  if [ "$CODE" != "$want" ]; then
    bad "$name" "exit $CODE, wanted $want. Output: $(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-240)"
  elif ! printf '%s' "$OUT" | grep -Fq -- "$needle"; then
    bad "$name" "exit $want as wanted, but the output never said '$needle'. Output: $(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-240)"
  else
    ok "$name"
  fi
}

TESS="${RICHOS_QA_TESSERACT:-}"
[ -n "$TESS" ] || TESS="$(command -v tesseract || true)"
for c in /opt/homebrew/bin/tesseract /usr/local/bin/tesseract; do
  [ -n "$TESS" ] && break
  [ -x "$c" ] && TESS="$c"
done
HAVE_TESS=0; [ -n "$TESS" ] && HAVE_TESS=1

HAVE_PIL=0
python3 -c 'import PIL' >/dev/null 2>&1 && HAVE_PIL=1

echo ""
echo "=== H. every tool answers for itself ==="
for t in contrast.py frame.py redact.py timeline.py ocr-gate.sh ocr-find.sh \
         ocr-watch.sh wait-for.sh phone-client.mjs flake-rate.sh phone-android.py lab-ledger.py phone-ios.py fixtures/make-fixtures.py; do
  if [ ! -x "$QA/$t" ]; then
    bad "H $t is executable" "not present or not executable at $QA/$t"
    continue
  fi
  run "$QA/$t" --help
  if [ "$CODE" != 0 ]; then
    bad "H $t --help exits 0" "exit $CODE"
  elif [ "$(printf '%s' "$OUT" | wc -c)" -lt 80 ]; then
    bad "H $t --help says something" "only $(printf '%s' "$OUT" | wc -c) bytes of help"
  else
    ok "H $t --help exits 0 and describes the tool"
  fi
done

echo ""
echo "=== C. contrast: the arithmetic, once, for everyone ==="

run "$QA/contrast.py" '#767676' '#FFFFFF'
expect "C1 a known pair computes to its published ratio" 0 "4.54:1"

run "$QA/contrast.py" '#A0A0A0' '#FFFFFF'
expect "C2 a failing pair FAILS and exits non-zero" 1 "2.61:1"

# 3.03:1 — under the 4.5 floor for normal text, over the 3.0 floor for large.
run "$QA/contrast.py" '#949494' '#FFFFFF'
expect "C3 a mid pair fails as normal text" 1 "FAIL"
run "$QA/contrast.py" '#949494' '#FFFFFF' --large
expect "C3b the same pair passes as large text" 0 "PASS"

A="$("$QA/contrast.py" '#767676' '#ffffff' | sed -n 's/.*RATIO \([0-9.]*:1\).*/\1/p')"
B="$("$QA/contrast.py" '767676' 'FFFFFF' | sed -n 's/.*RATIO \([0-9.]*:1\).*/\1/p')"
C="$("$QA/contrast.py" '118,118,118' 'rgb(255,255,255)' | sed -n 's/.*RATIO \([0-9.]*:1\).*/\1/p')"
if [ "$A" = "$B" ] && [ "$B" = "$C" ] && [ -n "$A" ]; then
  ok "C4 hex, bare hex and rgb() spellings of one value agree ($A)"
else
  bad "C4 the three spellings of one value must agree" "got '$A' '$B' '$C'"
fi

run "$QA/contrast.py" 'not-a-color' '#fff'
expect "C5 an unparseable value is refused with a sentence" 1 "hex"

run "$QA/contrast.py" "$FIX/pair-pass.png" --box 0 0 240 80
expect "C6 a region just over the floor passes" 0 "4.54:1"

run "$QA/contrast.py" "$FIX/pair-fail.png" --box 0 0 240 80
expect "C7 a region under the floor fails and exits non-zero" 1 "2.61:1"

run "$QA/contrast.py" "$FIX/pair-pass.png" "off:5000,5000,5100,5100"
expect "C8 a region outside the frame is refused, never clamped to a guess" 1 "does not overlap"

# The whole reason this file exists: a single stray pixel must not set the figure.
python3 - "$QA/lib" "$TMP/stray.png" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import qaimg
img = qaimg.render_blocks(240, 80, (255, 255, 255), (0x76, 0x76, 0x76), (40, 20, 160, 40))
img.fill_box(0, 0, 2, 2, (0, 0, 0))          # four black pixels, 0.02% of the frame
qaimg.save(img, sys.argv[2])
PY
run "$QA/contrast.py" "$TMP/stray.png" --box 0 0 240 80
if [ "$CODE" = 0 ] && printf '%s' "$OUT" | grep -Fq "4.54:1"; then
  ok "C9 four stray black pixels do not become the text color"
else
  bad "C9 a sub-floor artifact set the reported ratio" \
      "$(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-240)"
fi

echo ""
echo "=== P. the PNG layer ==="

if [ "$HAVE_PIL" = 1 ]; then
  run python3 - "$QA/lib" "$FIX/pair-pass.png" "$FIX/pair-fail.png" "$FIX/ocr-control.png" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import qaimg
if not qaimg.HAVE_PIL:
    print("Pillow is not importable, so there is nothing to compare against")
    raise SystemExit(3)
bad = 0
for path in sys.argv[2:]:
    with_pil = qaimg.load(path)
    with open(path, "rb") as fh:
        without = qaimg._decode_png(fh.read())
    if (with_pil.w, with_pil.h) != (without.w, without.h):
        print("SIZE DIFFERS for %s" % path); bad += 1; continue
    if bytes(with_pil.px) != bytes(without.px):
        n = sum(1 for a, b in zip(with_pil.px, without.px) if a != b)
        print("PIXELS DIFFER for %s in %d bytes" % (path, n)); bad += 1
    else:
        print("identical %s" % path)
raise SystemExit(1 if bad else 0)
PY
  expect "P1 the no-Pillow decoder agrees with Pillow, byte for byte" 0 "identical"
else
  skip "P1 the no-Pillow decoder agrees with Pillow" "Pillow is not installed, so there is no reference to compare against"
fi

run python3 - "$QA/lib" "$TMP/roundtrip.png" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import qaimg
src = qaimg.render_blocks(37, 19, (10, 200, 30), (250, 4, 128), (5, 3, 20, 11))
qaimg.save(src, sys.argv[2])
back = qaimg.load(sys.argv[2])
assert (back.w, back.h) == (37, 19), "size changed"
assert bytes(back.px) == bytes(src.px), "pixels changed"
print("round trip exact at 37x19")
PY
expect "P2 save then load returns the same pixels" 0 "round trip exact"

printf 'this is not a PNG at all' > "$TMP/notapng.png"
run "$QA/frame.py" px "$TMP/notapng.png" 0 0
expect "P3 a file that is not a PNG is refused by name" 1 "could not read"

echo ""
echo "=== F. frame: where things actually are ==="

run "$QA/frame.py" px "$FIX/pair-pass.png" 120 40 5 5
if [ "$CODE" = 0 ] \
   && printf '%s' "$OUT" | grep -Fq "#767676" \
   && printf '%s' "$OUT" | grep -Fq "#FFFFFF"; then
  ok "F1 px reads the block color and the ground"
else
  bad "F1 px read the wrong colors" "$(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-200)"
fi

run "$QA/frame.py" px "$FIX/pair-pass.png" 9999 0
expect "F2 a point outside the frame is refused" 1 "outside the"

run "$QA/frame.py" extent "$FIX/pair-pass.png" 0 0 240 80
if [ "$CODE" = 0 ] \
   && printf '%s' "$OUT" | grep -Fq "content x 40..199" \
   && printf '%s' "$OUT" | grep -Fq "content y 20..59"; then
  ok "F3 extent finds the block the fixture was built with"
else
  bad "F3 extent reported the wrong box" "$(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-200)"
fi

run "$QA/frame.py" inset "$FIX/pair-pass.png" 0 0 240 80
if [ "$CODE" = 0 ] \
   && printf '%s' "$OUT" | grep -Eq "inset left +40" \
   && printf '%s' "$OUT" | grep -Eq "inset top +20" \
   && printf '%s' "$OUT" | grep -Eq "inset right +40" \
   && printf '%s' "$OUT" | grep -Eq "inset bottom +20"; then
  ok "F4 inset measures all four gaps (the 18/18 settings-button check)"
else
  bad "F4 inset reported the wrong gaps" "$(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-240)"
fi

run "$QA/frame.py" motion "$FIX/pair-pass.png" "$FIX/pair-pass.png"
expect "F5 a frame against itself shows no motion" 0 "changed 0/"

run "$QA/frame.py" motion "$FIX/pair-pass.png" "$FIX/ocr-control.png"
expect "F6 frames of different sizes are refused, not compared" 1 "cannot be compared"

echo ""
echo "=== O. the OCR gate and the finder ==="

if [ "$HAVE_TESS" = 0 ]; then
  skip "O1-O6 the OCR cases" "no tesseract on this machine (brew install tesseract) — the gate, the finder and the redactor's re-scan were NOT exercised"
else
  run "$QA/ocr-gate.sh" "$FIX/ocr-control.png"
  expect "O1 the gate finds an address-shaped string and exits non-zero" 1 "OCR GATE: 1 of 1"

  if printf '%s' "$OUT" | grep -Fq "qa-fixture@example.invalid"; then
    bad "O2 the gate does not echo the thing it is protecting" \
        "the match was printed verbatim into the log"
  else
    ok "O2 the gate names the hit by shape and length, never echoing it"
  fi

  run "$QA/ocr-gate.sh" "$FIX/pair-pass.png"
  expect "O3 a frame with no readable text passes the gate" 0 "0 of 1"

  run env RICHOS_QA_TESSERACT=/usr/bin/true "$QA/ocr-gate.sh" "$FIX/ocr-control.png"
  expect "O4 a blind reader is caught by the positive control, never reported clean" 2 "POSITIVE CONTROL FAILED"

  mkdir -p "$TMP/emptydir"
  run "$QA/ocr-gate.sh" "$TMP/emptydir"
  expect "O5 an empty frame set is refused, never called clean" 2 "found NO frames"

  run "$QA/ocr-find.sh" 'FIXTURE CARD' "$FIX/ocr-control.png"
  expect "O6 the finder finds text that is there" 0 "HIT"

  run "$QA/ocr-find.sh" 'a string that is definitely not on this card' "$FIX/ocr-control.png"
  expect "O6b the finder EXITS NON-ZERO when the text never appears" 1 "0 of 1"
fi

echo ""
echo "=== R. redact: covered, and proved covered ==="

if [ "$HAVE_TESS" = 0 ]; then
  skip "R1-R4 the redaction cases" "no tesseract, so neither the finding nor the re-scan can run"
else
  run "$QA/redact.py" "$FIX/ocr-control.png" "$TMP/red.png"
  expect "R1 an address is found and covered, and the output re-read" 0 "no address-shaped string survives"

  LEFT="$("$TESS" "$TMP/red.png" stdout 2>/dev/null || true)"
  if printf '%s' "$LEFT" | grep -qi 'example.invalid'; then
    bad "R2 the address is actually gone from the output" "it is still legible"
  elif ! printf '%s' "$LEFT" | grep -qi 'nothing here is real'; then
    bad "R2 the rest of the evidence survives" \
        "over-redaction: the unrelated lines were destroyed too. Read: $(printf '%s' "$LEFT" | tr '\n' ' ' | cut -c1-160)"
  else
    ok "R2 the address is gone and the surrounding evidence survives"
  fi

  run "$QA/redact.py" "$FIX/ocr-control.png" "$TMP/red2.png" --no-verify --box 0,0,1,1
  expect "R3 --no-verify says outright that it proves nothing" 0 "proves the output is clean"

  # A box in the wrong place must not be reported as a redaction.
  run "$QA/redact.py" "$FIX/ocr-control.png" "$TMP/red3.png" --box 0,0,4,4
  expect "R4 a box that misses leaves the address legible and exits non-zero" 1 "STILL LEGIBLE"

  # The gate and the redactor must agree on what a phone number looks like: a
  # gate that flags a frame the redactor cannot clean leaves the walker with a
  # frame that can never ship, which is how hand-drawn boxes creep back in.
  run "$QA/ocr-gate.sh" "$FIX/phone-control.png"
  expect "R5 the gate flags the phone-shaped fixture (it is a real positive)" 1 "OCR GATE: 1 of 1"
  run "$QA/redact.py" "$FIX/phone-control.png" "$TMP/phone-red.png" --phones
  expect "R6 --phones covers the number and re-reads the output" 0 "no address-shaped or phone-shaped string survives"
  run "$QA/ocr-gate.sh" "$TMP/phone-red.png"
  expect "R7 the gate passes what the redactor produced" 0 "0 of 1"
  LEFT="$("$TESS" "$TMP/phone-red.png" stdout 2>/dev/null || true)"
  if printf '%s' "$LEFT" | grep -qi 'nothing here is real'; then
    ok "R8 the rest of the phone card survives the redaction"
  else
    bad "R8 the rest of the phone card survives the redaction" "over-redaction. Read: $(printf '%s' "$LEFT" | tr '\n' ' ' | cut -c1-160)"
  fi
fi

echo ""
echo "=== W. wait-for: and, above all, wait-for failing ==="

touch "$TMP/present"
run "$QA/wait-for.sh" --file "$TMP/present" --timeout 5
expect "W1 a file that is already there returns at once" 0 "appeared"

run "$QA/wait-for.sh" --file "$TMP/never" --timeout 2 --poll 1
expect "W2 a file that never appears is a FAILURE, not a quiet success" 1 "TIMEOUT"

printf 'boot\nready to serve\n' > "$TMP/a.log"
run "$QA/wait-for.sh" --log "$TMP/a.log" 'ready to serve' --timeout 5
expect "W3 a log line already present matches at once" 0 "matched after"

run "$QA/wait-for.sh" --log "$TMP/a.log" 'never logged this' --timeout 2 --poll 1
expect "W4 a log line that never arrives EXITS NON-ZERO" 1 "TIMEOUT"

# The fixture repository is built with PLUMBING, never `git commit`. This
# machine's global hooks refuse a commit whose identity is not the owner's, and
# a throwaway repository under mktemp has no business borrowing that identity —
# `commit-tree` and `update-ref` write the same objects with no hook in the way.
REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
EMPTY_TREE="$(git -C "$REPO" hash-object -t tree -w /dev/null)"
SHA1="$(git -C "$REPO" commit-tree "$EMPTY_TREE" -m one)"
SHA2="$(git -C "$REPO" commit-tree "$EMPTY_TREE" -p "$SHA1" -m two)"
git -C "$REPO" update-ref refs/heads/qa-fixture "$SHA2"
run "$QA/wait-for.sh" --ref "$REPO" qa-fixture --from "$SHA1" --timeout 5
expect "W5 a ref that has moved is reported with both SHAs" 0 "moved $SHA1"

run "$QA/wait-for.sh" --ref "$REPO" no-such-branch --timeout 300
expect "W6 a branch that does not exist is refused at once, not after the timeout" 2 "does not exist"

echo ""
echo "=== T. timeline ==="

# A synthetic capture: nine frames on a clock, the region changing at frame 5.
python3 - "$QA/lib" "$TMP/tl" <<'PY'
import os
import sys
sys.path.insert(0, sys.argv[1])
import qaimg
out = sys.argv[2]
os.makedirs(out, exist_ok=True)
base = 1_700_000_000_000.0
rows = []
for n in range(9):
    color = (255, 255, 255) if n < 5 else (0, 90, 200)
    qaimg.save(qaimg.render_blocks(24, 12, color, color, (0, 0, 1, 1)),
               os.path.join(out, "%04d.png" % n))
    rows.append((n, base + n * 100.0))
with open(os.path.join(out, "meta.tsv"), "w") as fh:
    fh.write("action\tkey 36\n")
    fh.write("region\t0,0,24,12\n")
    fh.write("t_action_before\t%.1f\n" % (base + 250.0))
    fh.write("t_action_after\t%.1f\n" % (base + 260.0))
    for n, t in rows:
        fh.write("frame\t%d\t%.1f\n" % (n, t))
print("wrote 9 frames, change at 5")
PY

run "$QA/timeline.py" report "$TMP/tl"
if [ "$CODE" = 0 ] \
   && printf '%s' "$OUT" | grep -Fq "first change    : frame 0005" \
   && printf '%s' "$OUT" | grep -Fq "+250.0 ms"; then
  ok "T1 the first change is dated from the action, against the frame before it"
else
  bad "T1 the first change was mis-dated" "$(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-280)"
fi

cp -R "$TMP/tl" "$TMP/tl-flat"
for n in 5 6 7 8; do cp "$TMP/tl/0000.png" "$TMP/tl-flat/000$n.png"; done
run "$QA/timeline.py" report "$TMP/tl-flat"
expect "T2 a region that never changes is reported as NO CHANGE, not as a latency" 1 "NO CHANGE"

run "$QA/timeline.py" report "$TMP"
expect "T3 a directory with no meta.tsv is refused — those frames have no clock" 1 "no meta.tsv"

run "$QA/timeline.py" stats a=100 b=400 c=250 d=900 e=150
if [ "$CODE" = 0 ] \
   && printf '%s' "$OUT" | grep -Eq "min +100.0 ms" \
   && printf '%s' "$OUT" | grep -Eq "median +250.0 ms" \
   && printf '%s' "$OUT" | grep -Eq "max +900.0 ms"; then
  ok "T4 stats reports min, median and max over the samples given"
else
  bad "T4 stats computed the wrong summary" "$(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-240)"
fi

run "$QA/timeline.py" stats a=100 b=400
expect "T5 fewer than three samples are not summarized as a median" 0 "never as a median"

run env -u RICHOS_QA_CAPTURE "$QA/timeline.py" capture "$TMP/cap" 1 --region 0,0,10,10 --wait-only
expect "T6 capture refuses to photograph this machine's screen" 1 "never a test surface"

run env -u RICHOS_QA_CAPTURE "$QA/ocr-watch.sh" "$TMP/watch" --region 0,0,10,10 --count 1
expect "T7 ocr-watch refuses to photograph this machine's screen" 2 "never a test surface"

run "$QA/timeline.py" at "$TMP/tl" 0007.png
expect "T10 a frame chosen by reading is dated off the capture's own clock" 0 "+450.0 ms"

run "$QA/timeline.py" at "$TMP/tl" 99
expect "T11 a frame that clock does not cover is refused, not dated anyway" 1 "not in"

run "$QA/timeline.py" capture "$TMP/cap2" 1 --region 0,0,10,10 --also-region 1,2,3 --wait-only
expect "T8 --also-region without a full rectangle is refused, not silently dropped" 1 "takes a rectangle"

# Two regions, one action, one clock — driven against a FAKE `screencapture`
# first on PATH, so nothing photographs this machine. What is under test is the
# pair of calls `capture` BUILDS and the two meta.tsv files it writes; the
# guarantee that matters is that BOTH carry the SAME action instant, because
# two separate `capture` runs stamping their own is the defect this replaces.
mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/screencapture" <<'SH'
#!/bin/sh
for a in "$@"; do case "$a" in -R*) echo "${a#-R}" >> "$TMPDIR_RECT" ;; esac; done
out=""; for a in "$@"; do out="$a"; done
printf 'x' > "$out"
SH
chmod +x "$TMP/fakebin/screencapture"
: > "$TMP/rects"
run env PATH="$TMP/fakebin:$PATH" TMPDIR_RECT="$TMP/rects" RICHOS_QA_CAPTURE=allow \
    "$QA/timeline.py" capture "$TMP/cap3" 1 --region 0,25,100,50 \
    --also-region 200,25,60,50 --wait-only --baseline 0.3 --interval 0.05
A_BEFORE="$(awk -F'\t' '$1=="t_action_before"{print $2}' "$TMP/cap3/meta.tsv" 2>/dev/null || true)"
B_BEFORE="$(awk -F'\t' '$1=="t_action_before"{print $2}' "$TMP/cap3/b/meta.tsv" 2>/dev/null || true)"
B_REGION="$(awk -F'\t' '$1=="region"{print $2}' "$TMP/cap3/b/meta.tsv" 2>/dev/null || true)"
if [ "$CODE" = 0 ] \
   && [ -n "$A_BEFORE" ] && [ "$A_BEFORE" = "$B_BEFORE" ] \
   && [ "$B_REGION" = "200,25,60,50" ] \
   && grep -Fq "200,25,60,50" "$TMP/rects" && grep -Fq "0,25,100,50" "$TMP/rects"; then
  ok "T9 --also-region captures the second rectangle on the SAME action instant"
else
  bad "T9 the second region was not captured against the same action" \
      "primary=$A_BEFORE also=$B_BEFORE region=$B_REGION code=$CODE"
fi

echo ""
run python3 "$QA/ocr-cache.test.py"
expect "OCR cache invalidation, reader failure, fresh control and multi-pattern timeline" 0 "OK"

run python3 "$QA/timeline-bounds.test.py"
expect "Monotonic visibility bounds and native input refusal" 0 "OK"

echo "=== N. phone-client: the headless phone ==="

if ! command -v node >/dev/null 2>&1; then
  skip "N1-N5 phone-client" "node is not installed, and the tool is the production mobile client, which is JavaScript"
else
  # A stub Mac on loopback: it issues a challenge like the real listener, then answers every
  # signed request with the status it was started with. 404 is what a RichOS listener says to
  # a device it never paired; 200 is the defect the tool exists to catch.
  cat > "$TMP/stub-mac.mjs" <<'JS'
import { createServer } from 'node:http';
import { writeFileSync } from 'node:fs';
const [status, portFile] = process.argv.slice(2);
const server = createServer((req, res) => {
  if (req.url === '/api/challenge') { res.writeHead(404, { 'X-RichOS-Challenge': 'stub-challenge' }); res.end(); return; }
  res.writeHead(Number(status), { 'Content-Type': 'application/json' }); res.end(status === '200' ? '{"accepted":true}' : '');
});
server.listen(0, '127.0.0.1', () => writeFileSync(portFile, String(server.address().port)));
setTimeout(() => process.exit(0), 20000).unref?.();
JS
  node -e '
    const { generateKeyPairSync } = require("node:crypto");
    const { privateKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
    require("node:fs").writeFileSync(process.argv[1], JSON.stringify({ key: privateKey.export({ format: "jwk" }),
      disk: { schema: 2, confirmed: true, api: { apiBase: "https://vm.example", deviceId: "dev_stub" } } }));
  ' "$TMP/phone.json"
  STUB_PID=""
  stub_start() {  # stub_start <status>: sets STUB_PID and ORIGIN (never in a subshell, so the pid is ours)
    rm -f "$TMP/stub.port"
    node "$TMP/stub-mac.mjs" "$1" "$TMP/stub.port" &
    STUB_PID=$!
    for _ in $(seq 1 100); do [ -s "$TMP/stub.port" ] && break; sleep 0.05; done
    ORIGIN="http://127.0.0.1:$(cat "$TMP/stub.port" 2>/dev/null)"
  }
  stub_stop() { [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null; STUB_PID=""; }

  stub_start 404
  run node "$QA/phone-client.mjs" foreign --state "$TMP/phone.json" --origin "$ORIGIN"
  stub_stop
  expect "N1 a foreign Mac that refuses this phone's credential is the answer, exit 0" 0 '"ok":true'

  stub_start 200
  run node "$QA/phone-client.mjs" foreign --state "$TMP/phone.json" --origin "$ORIGIN"
  stub_stop
  expect "N2 a foreign Mac that ACCEPTS another Mac's phone EXITS NON-ZERO" 1 '"accepted":true'

  run node "$QA/phone-client.mjs" foreign --state "$TMP/phone.json" --origin "http://127.0.0.1:9"
  expect "N3 an unreachable origin is 'could not ask', never a clean isolation verdict" 2 "cannot reach"

  run node "$QA/phone-client.mjs" pair --state "$TMP/new-phone.json" --link "https://vm.example:8443/#pair=ABCDEFGH"
  expect "N4 pair without a decision file is refused before anything is sent" 2 "--decision"

  run node "$QA/phone-client.mjs" send --state "$TMP/absent.json" --text hello
  expect "N5 a send with no paired phone state is refused by name" 2 "no phone state"
fi

echo ""
echo "=== K. flake-rate: a failure rate counted the same way every time ==="

run "$QA/flake-rate.sh" --runs 3 --log-dir "$TMP/fr1" good 'true' broken 'false'
expect "K1 counts every run of every label and exits 0 — failures are the answer" 0 "broken: pass=0 fail=3 not-admitted=0 of 3"

run "$QA/flake-rate.sh" --runs 2 --log-dir "$TMP/fr2" a "echo a >> '$TMP/order'" b "echo b >> '$TMP/order'"
if [ "$(tr -d '\n' < "$TMP/order" 2>/dev/null)" = "abab" ]; then ok "K2 rounds are interleaved, so a before/after pair sees the same load"
else bad "K2 rounds are interleaved" "order was '$(tr -d '\n' < "$TMP/order" 2>/dev/null)', wanted abab"; fi

# Fails on its second run only: a real flake, and the failing log must survive with its words.
run "$QA/flake-rate.sh" --runs 3 --log-dir "$TMP/fr3" flaky "n=\$(cat '$TMP/count' 2>/dev/null || echo 0); n=\$((n+1)); echo \$n > '$TMP/count'; [ \$n -ne 2 ] || { echo 'second run broke'; exit 1; }"
if [ "$CODE" = 0 ] && printf '%s' "$OUT" | grep -Fq "flaky: pass=2 fail=1" && grep -Fq "second run broke" "$TMP/fr3/flaky-2.log" 2>/dev/null && [ ! -e "$TMP/fr3/flaky-1.log" ]; then
  ok "K3 a one-in-three failure is counted, its log kept and named, passing logs removed"
else bad "K3 a one-in-three failure is counted and kept" "exit $CODE: $(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-240)"; fi

run "$QA/flake-rate.sh" --runs 0 x true
expect "K4 zero runs is refused, never reported as a clean rate" 2 "positive whole number"

run "$QA/flake-rate.sh" --runs 2 lonely
expect "K5 a label without its command is refused" 2 "LABEL"

echo ""
echo "=== A. phone-android: a physical phone, driven by what is on its screen ==="

# A scripted adb: it answers the handful of reads the tool makes and logs every
# input it is asked to inject. No phone, no emulator.
FAKE="$TMP/fake-adb"
cat > "$TMP/ui.xml" <<'XML'
<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0"><node index="0" text="" content-desc="Message Rich" class="android.view.View" package="dev.richos.connect" bounds="[16,1412][704,1516]" focused="false" clickable="false" /><node index="1" text="" content-desc="Send message" class="android.view.View" package="dev.richos.connect" bounds="[604,828][700,924]" focused="false" clickable="true" /><node index="2" text="draft words" content-desc="" class="android.widget.EditText" package="dev.richos.connect" bounds="[16,1412][604,1516]" focused="true" clickable="true" /><node index="3" text="" content-desc="" class="android.view.View" package="dev.richos.connect" bounds="[0,0][40,40]" focused="false" clickable="true" /></hierarchy>
XML
cat > "$TMP/framestats.txt" <<'TXT'
Window: dev.richos.connect/dev.richos.android.app.MainActivity
Stats since: 1ns
Total frames rendered: 3
---PROFILEDATA---
Flags,FrameTimelineVsyncId,IntendedVsync,Vsync
0,1,1000000000,1000000000
0,2,1500000000,1500000000
0,3,2000000000,2000000000
---PROFILEDATA---
TXT
cat > "$FAKE" <<SH
#!/usr/bin/env bash
LOG="$TMP/adb.log"
[ "\$1" = devices ] && { printf 'List of devices attached\nFAKE123\tdevice\n'; exit 0; }
[ "\$1" = -s ] || exit 9
shift 2
case "\$1 \$2" in
  "exec-out cat") cat "$TMP/ui.xml"; exit 0 ;;
  "exec-out screencap") cat "$FIX/pair-pass.png"; exit 0 ;;
esac
cmd="\$2"
case "\$cmd" in
  "input "*) echo "\$cmd" >> "\$LOG" ;;
  "dumpsys package "*) printf '    appId=10359\n    User 0: installed=true stopped=false\n' ;;
  "cat /proc/uptime") echo "1000.00 2000.00" ;;
  "am get-standby-bucket "*) echo 10 ;;
  "dumpsys power") printf 'mWakefulness=Awake\n  PARTIAL_WAKE_LOCK  "richos" ACQ=-1s (uid=10359 pid=42)\n' ;;
  "dumpsys window") printf 'isKeyguardShowing=false\n  mCurrentFocus=Window{1 u0 dev.richos.connect/dev.richos.android.app.MainActivity}\n' ;;
  "dumpsys battery") printf '  USB powered: true\n  level: 100\n' ;;
  "ps -A -o PID,NAME") printf 'PID NAME\n42 dev.richos.connect\n' ;;
  "cat /proc/42/stat") echo "42 (.richos.connect) S 1 1 0 0 -1 0 0 0 0 0 100 50 0 0 20 0 50 0 \${FAKE_BIRTH:-12345} 0 0" ;;
  "for t in /proc/42/task"*) printf '42|main|5 3\n43|RenderThread|1 0\n' ;;
  "dumpsys activity activities") echo "  topResumedActivity=ActivityRecord{1 u0 dev.richos.connect/.MainActivity t1}" ;;
  "dumpsys activity services "*) echo "  * ServiceRecord{abc u0 dev.richos.connect/dev.richos.android.platform.RichMessagingService}" ;;
  "cat /proc/net/"*) printf '  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid\n   0: 0100007F:1F90 0100007F:0050 01 00000000:00000000 00:00000000 00000000 10359 0 1\n' ;;
  "dumpsys notification") echo "  NotificationRecord(0x1: pkg=dev.richos.connect user=UserHandle{0} id=1)" ;;
  "dumpsys gfxinfo "*framestats) cat "$TMP/framestats.txt" ;;
  *) : ;;
esac
exit 0
SH
chmod +x "$FAKE"
PA="$QA/phone-android.py"

run "$PA" texts
expect "A1 no --serial is refused: a bare adb reaches whatever is attached" 2 "name the phone with --serial"
run "$PA" --adb "$FAKE" --serial NOTHERE texts
expect "A2 a serial adb does not list is refused, never guessed" 2 "is not an attached"
: > "$TMP/adb.log"
run "$PA" --adb "$FAKE" --serial FAKE123 tap "Send message" --timeout 1
if [ "$CODE" = 0 ] && grep -Fxq "input tap 652 876" "$TMP/adb.log"; then
  ok "A3 tap finds the control by its words and taps its center"
else bad "A3 tap finds the control by its words and taps its center" "exit $CODE, log: $(tr '\n' ' ' < "$TMP/adb.log")"; fi
run "$PA" --adb "$FAKE" --serial FAKE123 wait "Nowhere on this screen" --timeout 1
expect "A4 a wait that runs out is a failure, exit 1" 1 '"missing"'
printf "it's" > "$TMP/quote.txt"
run "$PA" --adb "$FAKE" --serial FAKE123 type-file "$TMP/quote.txt"
expect "A5 a character that input text cannot carry exactly is refused before typing" 2 "type-file types letters"
printf 'ab c' > "$TMP/abc.txt"; : > "$TMP/adb.log"
run "$PA" --adb "$FAKE" --serial FAKE123 type-file "$TMP/abc.txt"
if [ "$CODE" = 0 ] && [ "$(grep -c '^input text' "$TMP/adb.log")" = 4 ] && grep -Fxq "input text %s" "$TMP/adb.log"; then
  ok "A6 type-file sends one input per character, a space as %s"
else bad "A6 type-file sends one input per character, a space as %s" "exit $CODE, log: $(tr '\n' ' ' < "$TMP/adb.log")"; fi
run "$PA" --adb "$FAKE" --serial FAKE123 state --package dev.richos.connect --out "$TMP/s1.json"
if [ "$CODE" = 0 ] && python3 - "$TMP/s1.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
p = s["processes"][0]
assert s["uid"] == 10359 and s["stoppedFlag"] is False and s["standbyBucket"] == "10", s
assert p["pid"] == 42 and p["cpuTicks"] == 150 and p["birth"] == "12345" and p["threadCount"] == 2, p
assert s["resumedActivity"] and s["appHasFocus"] and s["screen"] == "Awake" and s["keyguardShowing"] is False
assert s["services"] == ["dev.richos.connect/dev.richos.android.platform.RichMessagingService"], s["services"]
assert len(s["wakeLocks"]) == 1 and s["openSockets"] == {"ESTABLISHED": 1} and s["ownNotifications"] == 1, s
PY
then ok "A7 state reads process, birth, ticks, services, wake locks, sockets and notifications"
else bad "A7 state reads process, birth, ticks, services, wake locks, sockets and notifications" "exit $CODE: $(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-240)"; fi
run env FAKE_BIRTH=12345 "$PA" --adb "$FAKE" --serial FAKE123 state --package dev.richos.connect --out "$TMP/s2.json"
run "$PA" compare "$TMP/s1.json" "$TMP/s2.json"
expect "A8 compare subtracts CPU for the same process" 0 '"cpuTicks": 0'
run env FAKE_BIRTH=99999 "$PA" --adb "$FAKE" --serial FAKE123 state --package dev.richos.connect --out "$TMP/s3.json"
run "$PA" compare "$TMP/s1.json" "$TMP/s3.json"
expect "A9 a restarted process (new birth) is never subtracted from the old one" 0 '"sameProcess": []'
run "$PA" --adb "$FAKE" --serial FAKE123 idle-frames --package dev.richos.connect --seconds 0.1
if [ "$CODE" = 0 ] && printf '%s' "$OUT" | grep -q '"totalFramesRendered": 3' && printf '%s' "$OUT" | tr -d ' \n' | grep -q '"gapsMs":\[500.0,500.0\]'; then
  ok "A10 idle-frames counts the frames and reports their rhythm"
else bad "A10 idle-frames counts the frames and reports their rhythm" "exit $CODE: $(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-240)"; fi
run "$PA" --adb "$FAKE" --serial FAKE123 field
if [ "$CODE" = 0 ] && printf '%s' "$OUT" | grep -q '"text": "draft words"'; then ok "A11 field reads the editable text back"
else bad "A11 field reads the editable text back" "exit $CODE: $(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-200)"; fi
printf '{"1":[40,1105]," ":[395,1470]}' > "$TMP/keymap.json"
printf '1 x' > "$TMP/keys-bad.txt"
run "$PA" --adb "$FAKE" --serial FAKE123 keys "$TMP/keys-bad.txt" --keymap "$TMP/keymap.json"
expect "A12 keys refuses a character the key map cannot type, before tapping anything" 2 "no key for"
printf '1 1' > "$TMP/keys-ok.txt"; : > "$TMP/adb.log"
run "$PA" --adb "$FAKE" --serial FAKE123 keys "$TMP/keys-ok.txt" --keymap "$TMP/keymap.json"
if [ "$CODE" = 0 ] && [ "$(grep -c 'input tap 40 1105' "$TMP/adb.log")" = 2 ] && grep -Fxq "input tap 395 1470" "$TMP/adb.log"; then
  ok "A13 keys taps the mapped key for every character"
else bad "A13 keys taps the mapped key for every character" "exit $CODE, log: $(tr '\n' ' ' < "$TMP/adb.log")"; fi
: > "$TMP/adb.log"
run "$PA" --adb "$FAKE" --serial FAKE123 observe --package dev.richos.connect --label cell --out-dir "$TMP/obs" --settle 0 --seconds 0 --action home
if [ "$CODE" = 0 ] && grep -Fxq "input keyevent KEYCODE_HOME" "$TMP/adb.log" && [ -f "$TMP/obs/cell-start.json" ] && [ -f "$TMP/obs/cell-end.json" ] && [ -f "$TMP/obs/cell-compare.json" ]; then
  ok "A14 observe performs the closure action and keeps both readings and the comparison"
else bad "A14 observe performs the closure action and keeps both readings and the comparison" "exit $CODE: $(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-200)"; fi
run "$PA" --adb "$FAKE" --serial FAKE123 observe --package dev.richos.connect --label x --out-dir "$TMP/obs" --settle 0 --seconds 0 --action reboot
expect "A15 observe refuses an action it does not know rather than guessing" 2 "--action must be one of"
run "$PA" --adb "$FAKE" --serial FAKE123 unlabeled --package dev.richos.connect
expect "A16 unlabeled finds the one clickable control with no name and exits 1" 1 '"bounds": [
        0,'
run "$PA" --adb "$FAKE" --serial FAKE123 unlabeled --package com.example.other
expect "A17 unlabeled is clean for a package with no unnamed controls" 0 '"unnamed": []'

echo ""
echo "=== L. lab-ledger: exactly once, word for word ==="
mkdir -p "$TMP/lab"
printf 'richos-mobile-isolated-v1' > "$TMP/lab/lab-owner"
cat > "$TMP/lab/timeline.json" <<'JSON'
{"items":[{"kind":"user_message","text":"one"},{"kind":"rich_message","text":"ack: one"},{"kind":"user_message","text":"two"},{"kind":"user_message","text":"two"},{"kind":"rich_message","text":"ack: two"}]}
JSON
run "$QA/lab-ledger.py" --timeline "$TMP/lab/timeline.json" one
expect "L1 a message and its reply there exactly once pass" 0 '"exactlyOnce": 1'
run "$QA/lab-ledger.py" --timeline "$TMP/lab/timeline.json" two
expect "L2 a duplicated message FAILS, exit 1" 1 '"userRows": 2'
run "$QA/lab-ledger.py" --timeline "$TMP/lab/timeline.json" "one "
expect "L3 an altered message (one character) FAILS, exit 1" 1 '"userRows": 0'
mkdir -p "$TMP/notlab"; cp "$TMP/lab/timeline.json" "$TMP/notlab/timeline.json"
run "$QA/lab-ledger.py" --timeline "$TMP/notlab/timeline.json" one
expect "L4 a timeline that is not the isolated lab's is refused, never read" 2 "owner marker"
echo "=== I. phone-ios: a physical iPhone's real controls, validated before any build ==="

printf '%s' '[{"do":"launch"},{"do":"tap","id":"composer.send"},{"do":"sleep","seconds":2},{"do":"alert","button":"Allow","in":"springboard"}]' > "$TMP/ios-ok.json"
run python3 "$QA/phone-ios.py" check "$TMP/ios-ok.json"
expect "I1 a well-formed step list validates without a device" 0 '"steps": 4'

printf '%s' '[{"do":"launch"},{"do":"reboot"}]' > "$TMP/ios-unknown.json"
run python3 "$QA/phone-ios.py" check "$TMP/ios-unknown.json"
expect "I2 an unknown step is refused by name before anything is built" 2 "unknown step 'reboot'"

printf '%s' '[{"do":"tap"}]' > "$TMP/ios-notarget.json"
run python3 "$QA/phone-ios.py" check "$TMP/ios-notarget.json"
expect "I3 a tap that names no element is refused" 2 "names no id or label"

printf '%s' '[{"do":"wait","id":"pair.link","timout":5}]' > "$TMP/ios-typo.json"
run python3 "$QA/phone-ios.py" check "$TMP/ios-typo.json"
expect "I4 a misspelled key is refused, never silently ignored" 2 "unexpected keys ['timout']"

printf '%s' '[{"do":"activate","in":"tailscale"},{"do":"value","kind":"switch","in":"tailscale"},{"do":"shot","screen":true}]' > "$TMP/ios-account.json"
run python3 "$QA/phone-ios.py" check "$TMP/ios-account.json"
expect "I8 a list that touches the person's Tailscale account may keep no picture of it" 2 "may not keep a shot, tree or audit"

printf '%s' '[{"do":"activate","in":"tailscale"},{"do":"value","kind":"switch","in":"tailscale"}]' > "$TMP/ios-switch.json"
run python3 "$QA/phone-ios.py" check "$TMP/ios-switch.json"
expect "I9 reading the route's switch by kind alone validates" 0 '"steps": 2'

run env RICHOS_IOS_DEVICE=x RICHOS_APPLE_TEAM=y python3 "$QA/phone-ios.py" run "$TMP/ios-ok.json" --out /Volumes/E1TB/nonexistent-qa-test --prebuilt
expect "I10 reusing an earlier build without its stamp is refused" 2 "--prebuilt needs --stamp"

mkdir -p "$TMP/Fake.app" && printf 'bytes' > "$TMP/Fake.app/RichOSNative"
printf '{"artifact":"%s","sha256":"0000000000000000","commit":"abc","dirty":false}' "$TMP/Fake.app" > "$TMP/fake-stamp.json"
run env RICHOS_IOS_DEVICE=x RICHOS_APPLE_TEAM=y python3 "$QA/phone-ios.py" run "$TMP/ios-ok.json" --out /Volumes/E1TB/nonexistent-qa-test --prebuilt --stamp "$TMP/fake-stamp.json"
expect "I11 a reused app whose bytes differ from its stamp is refused: identity or refuse" 2 "freshness mismatch"

printf '%s' '[{"do":"launch"},{"do":"lock"}]' > "$TMP/ios-lock.json"
run python3 "$QA/phone-ios.py" check "$TMP/ios-lock.json"
expect "I12 locking the phone without a person there to open it is refused" 2 "only a person can open the phone again"

printf '%s' '[{"do":"unlock"}]' > "$TMP/ios-unlock.json"
run python3 "$QA/phone-ios.py" check "$TMP/ios-unlock.json"
expect "I13 there is no scripted unlock: XCTest's Home press does not open an iOS 26 lock screen" 2 "unknown step 'unlock'"

run python3 "$QA/phone-ios.py" syslog --device x --seconds 0 --out /Volumes/E1TB/nonexistent-qa-test.txt
expect "I14 a log capture with no interval is refused" 2 "--seconds must be 1 to 3600"

run python3 "$QA/phone-ios.py" syslog --device x --seconds 5 --out "$TMP/syslog.txt"
expect "I15 a log capture off the external SSD is refused before the relay starts" 2 "--out must be on /Volumes/E1TB"

run python3 "$QA/phone-ios.py" battery --device 00000000-NOT-A-PHONE --network
expect "I16 a battery reading from a phone that is not there is refused, never a number" 2 "did not report the battery"

run env -u RICHOS_IOS_DEVICE python3 "$QA/phone-ios.py" run "$TMP/ios-ok.json" --out /Volumes/E1TB/nonexistent-qa-test
expect "I5 run refuses without a named phone" 2 "set RICHOS_IOS_DEVICE"

run env RICHOS_IOS_DEVICE=x RICHOS_APPLE_TEAM=y python3 "$QA/phone-ios.py" run "$TMP/ios-ok.json" --out "$TMP/ios-out"
expect "I6 run refuses an output directory off the external SSD" 2 "must be on /Volumes/E1TB"

{
  echo 'Test Case started'
  echo 'PHONE_STEP {"i": 0, "do": "launch", "ok": true}'
  echo '    t =  1.00s PHONE_STEP {"i": 0, "do": "launch", "ok": true}'
  echo 'PHONE_STEP {"i": 1, "do": "wait", "ok": false, "error": "not on screen'
  echo 'PHONE_STEP {"i": 1, "do": "wait", "ok": false, "error": "not on screen within 5 s"}'
} > "$TMP/ios-test.log"
run python3 "$QA/phone-ios.py" parse-log "$TMP/ios-test.log"
if [ "$CODE" = 0 ] && [ "$(printf '%s' "$OUT" | grep -c '"do"')" = 2 ] && printf '%s' "$OUT" | grep -Fq "not on screen within 5 s"; then
  ok "I7 parse-log keeps each step once and skips a line cut in half"
else bad "I7 parse-log keeps each step once" "exit $CODE: $(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-240)"; fi

echo ""
echo "=== X. the fixtures are still the fixtures ==="

if [ "$HAVE_PIL" = 0 ]; then
  skip "X1 the committed fixtures match their generator" \
       "Pillow is not installed, so they cannot be re-rendered here. The committed bytes were used by every case above, which is what they are for."
else
  run "$QA/fixtures/make-fixtures.py" --check
  expect "X1 the committed fixtures still match their generator" 0 "same     ocr-control.png"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "=== qa toolkit tests: $FAIL FAILED, $PASS passed, $SKIP skipped ==="
  exit 1
fi
if [ "$SKIP" -gt 0 ]; then
  echo "=== qa toolkit tests: all $PASS passed, $SKIP SKIPPED (named above) ==="
  exit 0
fi
echo "=== qa toolkit tests: all $PASS passed ==="
