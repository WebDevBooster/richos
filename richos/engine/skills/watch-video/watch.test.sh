#!/usr/bin/env bash
# watch.test.sh — watch.sh keeps a frame at the start, at a scene change, and
# after 5 s without one; names each by its time; and interleaves frames with the
# transcript in watch.md. A recording with no sound still gets its frames.
#
# Fixture: 12 s of black with a white box appearing at 3.0 s, so the expected
# frames are exactly 0.0 s (start), 3.0 s (scene change) and 8.0 s (no change
# for 5 s). The speech is synthesized with `say -o` straight to a file: nothing
# is played through the speakers.
set -uo pipefail

HERE="$(cd -P "$(dirname "$0")" && pwd -P)"
ENGINE="$(cd -P "$HERE/../.." && pwd -P)"
SCRIPT="$HERE/watch.sh"
FAIL=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

echo "=== watch-video: watch.sh ==="
[ -x "$SCRIPT" ] || { bad "watch.sh exists and is executable at $SCRIPT"; echo "1 failure"; exit 1; }
command -v say >/dev/null 2>&1 || { bad "macOS say is available to make the speech fixture"; exit 1; }

. "$ENGINE/scripts/lib/scratch.sh"
SANDBOX="$(scratch_new watch-test --ttl 30)"
trap 'scratch_release "$SANDBOX"' EXIT

VIDEO_FILTER="drawbox=x=40:y=40:w=240:h=160:color=white:t=fill:enable='gte(t,3)'"
say -o "$SANDBOX/speech.aiff" "First the screen is empty. Now a white box appears on the screen."
ffmpeg -hide_banner -nostdin -loglevel error -y -f lavfi -i "color=c=black:s=320x240:r=30:d=12" \
    -i "$SANDBOX/speech.aiff" -vf "$VIDEO_FILTER" -c:v libx264 -c:a aac -t 12 "$SANDBOX/rec.mov"
ffmpeg -hide_banner -nostdin -loglevel error -y -f lavfi -i "color=c=black:s=320x240:r=30:d=12" \
    -vf "$VIDEO_FILTER" -c:v libx264 "$SANDBOX/mute.mov"

# 1. a recording with sound
OUT="$SANDBOX/out1"
PRINTED="$("$SCRIPT" "$SANDBOX/rec.mov" "$OUT" 2>"$SANDBOX/err1")"
STATUS=$?
if [ "$STATUS" -eq 0 ]; then ok "exit 0"; else bad "exit 0 (got $STATUS: $(tail -5 "$SANDBOX/err1"))"; fi
if [ "$PRINTED" = "$OUT/watch.md" ] && [ -f "$OUT/watch.md" ]; then ok "prints the index path"; else bad "prints the index path (printed: $PRINTED)"; fi
FRAMES="$(cd "$OUT/frames" 2>/dev/null && ls | tr '\n' ' ')"
EXPECT="frame-0001-t00m00.0s.png frame-0002-t00m03.0s.png frame-0003-t00m08.0s.png "
if [ "$FRAMES" = "$EXPECT" ]; then
    ok "frames at start, at the scene change and 5 s later, named by time"
else
    bad "frames at start, at the scene change and 5 s later (got: $FRAMES)"
fi
if grep -q 'frame-0001-t00m00.0s.png  (start)' "$OUT/watch.md" \
    && grep -q 'frame-0002-t00m03.0s.png  (scene change' "$OUT/watch.md" \
    && grep -q 'frame-0003-t00m08.0s.png  (no change for 5s)' "$OUT/watch.md"; then
    ok "watch.md says why each frame was kept"
else
    bad "watch.md says why each frame was kept"
fi
if grep -iq 'white box' "$OUT/transcript.md" 2>/dev/null; then ok "transcript has the spoken words"; else bad "transcript has the spoken words"; fi
FIRST_WORDS="$(grep -n '^\*\*\[' "$OUT/watch.md" | head -1 | cut -d: -f1)"
FIRST_FRAME="$(grep -n 'FRAME' "$OUT/watch.md" | head -1 | cut -d: -f1)"
LAST_FRAME="$(grep -n 'FRAME' "$OUT/watch.md" | tail -1 | cut -d: -f1)"
if [ -n "$FIRST_WORDS" ] && [ "$FIRST_FRAME" -lt "$FIRST_WORDS" ] && [ "$FIRST_WORDS" -lt "$LAST_FRAME" ]; then
    ok "watch.md interleaves frames and transcript in time order"
else
    bad "watch.md interleaves frames and transcript in time order"
fi
if file "$OUT/frames/frame-0002-t00m03.0s.png" | grep -q 'PNG image data, 320 x 240'; then
    ok "frames are full-size PNGs the Read tool can open"
else
    bad "frames are full-size PNGs the Read tool can open"
fi

# 2. a recording with no sound: frames, no transcript, said in watch.md
OUT2="$SANDBOX/out2"
"$SCRIPT" "$SANDBOX/mute.mov" "$OUT2" >/dev/null 2>&1
STATUS=$?
COUNT="$(ls "$OUT2/frames" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$STATUS" -eq 0 ] && [ "$COUNT" = 3 ] && grep -q 'no audio track' "$OUT2/watch.md" 2>/dev/null; then
    ok "a silent recording gets its 3 frames and watch.md says there is no transcript"
else
    bad "a silent recording gets its frames (exit $STATUS, $COUNT frames)"
fi

if [ "$FAIL" -eq 0 ]; then echo "PASS"; exit 0; fi
echo "$FAIL failure(s)"
exit 1
