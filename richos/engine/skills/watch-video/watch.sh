#!/usr/bin/env bash
# watch.sh — "watch" a video or screen recording: a timestamped transcript of its
# sound (through the audio-transcription skill's script, i.e. RichOS's own
# pipeline) plus still frames at every scene change and at least one frame every
# N seconds while the screen does not change, and one time-ordered index that
# puts every frame beside the words spoken at that moment. Read the index, then
# Read the frame files it names. Everything is already installed; nothing is
# ever downloaded.
#
#   watch.sh <video-file> <output-dir> [--every <seconds>] [--lang <code>|auto]
#
# Writes:
#   <output-dir>/watch.md            THE INDEX: frames and transcript lines in time order
#   <output-dir>/frames/frame-NNNN-tMMmSS.Ss.png   one PNG per kept moment, at most 1920 px wide
#   <output-dir>/transcript.md       the transcript (see the audio-transcription skill)
#   <output-dir>/pipeline/, pipeline.log   the transcription pipeline's own record
#
# Exit: 0 frames written (and the transcript, if the file has sound); 1 usage or
# a missing tool; 2 frames written but the transcription pipeline failed (its
# reason is printed and is in watch.md).
#
# THE PARAMETERS, AND WHY
#   Scene changes are judged on the video sampled at 5 frames a second, so an
#   animated transition (a panel sliding in over 12 frames at 60 fps) adds up to
#   one jump instead of twelve small ones that each fall under the threshold.
#   SCENE=0.05: on the CEO's 141 s screen recording of 2026-10-07 the frame-to-frame
#   scene score was 0.10-0.30 when a panel opened or the view changed, and under
#   0.01 for typing and cursor moves; 0.05 keeps the first and skips the second.
#   GAP=1 s: one transition fires several scores over 0.05 in a row (33.0, 33.2,
#   33.4, 34.2, 34.4 s in that recording); one frame per second of it is enough.
#   EVERY=5 s (default): changes below the threshold (text typed into a field, a
#   slow scroll, the pointer showing what the speaker means) are never more than
#   5 s stale, which is about one spoken sentence (150 words a minute is 12 words
#   in 5 s), so every transcript line has a frame from inside its own sentence.
#   That costs at most 12 frames a minute; for recordings much over 10 minutes
#   pass --every 15 or read only the frames the index places where it matters.
set -euo pipefail

usage() {
    echo "usage: watch.sh <video-file> <output-dir> [--every <seconds>] [--lang <code>|auto]" >&2
    exit 1
}

SCENE=0.05
GAP=1
EVERY=5
[ "$#" -ge 2 ] || usage
INPUT="$1"
OUT="$2"
shift 2
LANG_ARGS=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --every) [ "$#" -ge 2 ] || usage; EVERY="$2"; shift 2 ;;
        --lang) [ "$#" -ge 2 ] || usage; LANG_ARGS=(--lang "$2"); shift 2 ;;
        *) usage ;;
    esac
done
case "$EVERY" in ''|*[!0-9.]*) echo "watch: --every takes a number of seconds" >&2; exit 1 ;; esac

[ -f "$INPUT" ] || { echo "watch: no such file: $INPUT" >&2; exit 1; }
HERE="$(cd -P "$(dirname "$0")" && pwd -P)"
TRANSCRIBE="$HERE/../audio-transcription/transcribe.sh"
[ -x "$TRANSCRIBE" ] || { echo "watch: transcribe script not found at $TRANSCRIBE" >&2; exit 1; }
for tool in ffmpeg ffprobe; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "watch: $tool is not on PATH. It is installed under /opt/homebrew/bin; fix PATH," >&2
        echo "watch: never install or download anything. Report it to the lead." >&2
        exit 1
    fi
done
if [ -z "$(ffprobe -v error -select_streams v -show_entries stream=index -of csv=p=0 "$INPUT")" ]; then
    echo "watch: $INPUT has no video track; use the audio-transcription skill instead" >&2
    exit 1
fi
if [ -e "$OUT" ] && [ -n "$(ls -A "$OUT")" ]; then
    echo "watch: output directory is not empty: $OUT (give a new or empty one)" >&2
    exit 1
fi
mkdir -p "$OUT"
OUT="$(cd -P "$OUT" && pwd -P)"
FRAMES="$OUT/frames"

# ---- 1. the transcript (exit 3 = no audio track, which is fine for a silent recording)
TSTATUS=0
TNOTE=""
if [ "${#LANG_ARGS[@]}" -gt 0 ]; then
    "$TRANSCRIBE" "$INPUT" "$OUT" "${LANG_ARGS[@]}" > /dev/null || TSTATUS=$?
else
    "$TRANSCRIBE" "$INPUT" "$OUT" > /dev/null || TSTATUS=$?
fi
case "$TSTATUS" in
    0) ;;
    3) TNOTE="This recording has no audio track, so there is no transcript." ;;
    *) TNOTE="TRANSCRIPTION FAILED (exit $TSTATUS); see $OUT/pipeline.log. Frames are still below." ;;
esac
# frames/ is made only now: transcribe.sh refuses a directory that is not empty.
mkdir -p "$FRAMES"

# ---- 2. the frames
# select keeps a frame when it is the first one, when the scene changed by more
# than SCENE at least GAP seconds after the last kept frame, or when EVERY
# seconds passed without a kept frame. metadata prints what was kept, in order.
SELECT="isnan(prev_selected_t)+gte(t-prev_selected_t\\,$EVERY)+gt(scene\\,$SCENE)*gte(t-prev_selected_t\\,$GAP)"
KEPT="$FRAMES/.kept.txt"
ffmpeg -hide_banner -nostdin -nostats -loglevel error -y -i "$INPUT" -an \
    -vf "fps=5,select='$SELECT',metadata=mode=print:key=lavfi.scene_score:file='$KEPT',scale='min(1920,iw)':-2" \
    -fps_mode passthrough "$FRAMES/raw-%04d.png"

# ---- 3. name each frame by its time, and build the index
fmt_time() {  # seconds (float) -> MMmSS.Ss
    local tenths m s
    tenths="$(printf '%.0f' "$(echo "$1 * 10" | bc -l)")"
    m=$((tenths / 600))
    s=$((tenths % 600))
    printf '%02dm%02d.%ds' "$m" "$((s / 10))" "$((s % 10))"
}
ROWS="$OUT/.rows"
: > "$ROWS"
n=0
prev=""
t=""
while IFS= read -r line; do
    case "$line" in
        frame:*)
            t="$(printf '%s\n' "$line" | sed -E 's/.*pts_time:([0-9.]+).*/\1/')" ;;
        lavfi.scene_score=*)
            score="${line#lavfi.scene_score=}"
            n=$((n + 1))
            num="$(printf '%04d' "$n")"
            stamp="$(fmt_time "$t")"
            if [ -z "$prev" ]; then why="start"
            elif [ "$(echo "$score > $SCENE && $t - $prev >= $GAP" | bc -l)" = 1 ]; then why="scene change ($score)"
            else why="no change for ${EVERY}s"
            fi
            name="frame-$num-t$stamp.png"
            mv "$FRAMES/raw-$num.png" "$FRAMES/$name"
            printf '%010.2f\t[%s] FRAME %s  (%s)\n' "$t" "$stamp" "$FRAMES/$name" "$why" >> "$ROWS"
            prev="$t" ;;
    esac
done < "$KEPT"
rm -f "$KEPT"

if [ -f "$OUT/transcript.md" ]; then
    while IFS= read -r line; do
        case "$line" in
            '**['*) ;;
            *) continue ;;
        esac
        ts="${line#\*\*[}"
        ts="${ts%%]*}"
        IFS=: read -r a b c <<< "$ts"
        if [ -n "${c:-}" ]; then secs=$((10#$a * 3600 + 10#$b * 60 + 10#$c)); else secs=$((10#$a * 60 + 10#$b)); fi
        # The transcript's stamp is a whole second; .01 puts a frame taken at
        # exactly that second ahead of the words, so the picture comes first.
        printf '%010.2f\t%s\n' "$secs.01" "$line" >> "$ROWS"
    done < "$OUT/transcript.md"
fi

{
    echo "# Watch: $(basename "$INPUT")"
    echo
    echo "- Frames: $n in $FRAMES (scene change over $SCENE, or every ${EVERY}s without one)"
    if [ -f "$OUT/transcript.md" ]; then echo "- Transcript: $OUT/transcript.md (\"Me\" is the recording's sound, not a speaker)"; fi
    if [ -n "$TNOTE" ]; then echo "- $TNOTE"; fi
    echo "- Read this file top to bottom; Read each FRAME path to see the screen at that moment."
    echo
    sort "$ROWS" | cut -f2- | awk '{ print; print "" }'
} > "$OUT/watch.md"
rm -f "$ROWS"

echo "watch: $n frames, index $OUT/watch.md" >&2
[ -n "$TNOTE" ] && echo "watch: $TNOTE" >&2
echo "$OUT/watch.md"
if [ "$TSTATUS" -ne 0 ] && [ "$TSTATUS" -ne 3 ]; then exit 2; fi
exit 0
