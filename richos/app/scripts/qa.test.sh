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
#   X1      the committed fixtures still match their generator
#
# run-tests: no-host-screen: its only capture/keystroke references are the strings it asserts those two tools REFUSE to act on, and its frames are committed PNG fixtures
# run-tests: inputs richos/app/scripts/qa.test.sh richos/app/scripts/qa
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
         ocr-watch.sh wait-for.sh fixtures/make-fixtures.py; do
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
