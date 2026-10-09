#!/usr/bin/env bash
# frames-at.sh — cut full-size frames from a video you already watched, at chosen
# times or inside a time window, so a long video is read as transcript first and
# then zoomed into only where it matters.
#
#   frames-at.sh <video-file> <output-dir> --at <time>[,<time>...]
#   frames-at.sh <video-file> <output-dir> --window <start> <end> [--step <seconds>]
#
# A <time> is seconds (125.5), MM:SS (02:05) or HH:MM:SS. --step defaults to 2 s.
# Writes <output-dir>/frame-at-tMMmSS.Ss.png (at most 1920 px wide) and prints each
# path on stdout. The output directory may exist; same-named files are replaced.
# `watch.sh` records the video's path in watched.md ("Video file:"); for a URL it
# keeps the download as <watch-output-dir>/video.<ext>.
#
# Exit: 0 frames written; 1 usage, missing file or tool, a time past the video's end.
set -euo pipefail

usage() {
    echo "usage: frames-at.sh <video-file> <output-dir> (--at <time>[,<time>...] | --window <start> <end> [--step <seconds>])" >&2
    exit 1
}

[ "$#" -ge 4 ] || usage
INPUT="$1"
OUT="$2"
shift 2
MODE=""
ATS=""
WSTART=""
WEND=""
STEP=2
while [ "$#" -gt 0 ]; do
    case "$1" in
        --at) [ "$#" -ge 2 ] || usage; MODE=at; ATS="$2"; shift 2 ;;
        --window) [ "$#" -ge 3 ] || usage; MODE=window; WSTART="$2"; WEND="$3"; shift 3 ;;
        --step) [ "$#" -ge 2 ] || usage; STEP="$2"; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$MODE" ] || usage
case "$STEP" in ''|*[!0-9.]*) echo "frames-at: --step takes a number of seconds" >&2; exit 1 ;; esac
[ -f "$INPUT" ] || { echo "frames-at: no such file: $INPUT" >&2; exit 1; }
for tool in ffmpeg ffprobe; do
    command -v "$tool" >/dev/null 2>&1 || { echo "frames-at: $tool is not on PATH; never install anything, report it to the lead" >&2; exit 1; }
done

to_secs() {  # 125.5 | MM:SS | HH:MM:SS -> seconds
    case "$1" in
        ''|*[!0-9.:]*) echo "frames-at: not a time: $1" >&2; exit 1 ;;
    esac
    printf '%s\n' "$1" | awk -F: '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; printf "%.3f\n", s }'
}
fmt_time() {  # seconds (float) -> MMmSS.mmms (milliseconds, so distinct times never share a name)
    local ms m s
    ms="$(printf '%.0f' "$(echo "$1 * 1000" | bc -l)")"
    m=$((ms / 60000))
    s=$((ms % 60000))
    printf '%02dm%02d.%03ds' "$m" "$((s / 1000))" "$((s % 1000))"
}

DURATION="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$INPUT")"
TIMES=()
if [ "$MODE" = at ]; then
    IFS=, read -r -a RAWT <<< "$ATS"
    for x in "${RAWT[@]}"; do TIMES+=("$(to_secs "$x")"); done
else
    a="$(to_secs "$WSTART")"
    b="$(to_secs "$WEND")"
    [ "$(echo "$b > $a" | bc -l)" = 1 ] || { echo "frames-at: the window must end after it starts" >&2; exit 1; }
    [ "$(echo "$STEP > 0" | bc -l)" = 1 ] || { echo "frames-at: --step must be above 0" >&2; exit 1; }
    t="$a"
    while [ "$(echo "$t <= $b" | bc -l)" = 1 ]; do
        TIMES+=("$t")
        t="$(echo "$t + $STEP" | bc -l)"
    done
fi
mkdir -p "$OUT"
for t in "${TIMES[@]}"; do
    if [ "$(echo "$t >= $DURATION" | bc -l)" = 1 ]; then
        echo "frames-at: $t s is past the end of the video ($DURATION s)" >&2
        exit 1
    fi
    file="$OUT/frame-at-t$(fmt_time "$t").png"
    ffmpeg -hide_banner -nostdin -nostats -loglevel error -y -ss "$t" -i "$INPUT" -an \
        -frames:v 1 -vf "scale='min(1920,iw)':-2" "$file"
    [ -s "$file" ] || { echo "frames-at: no frame at $t s" >&2; exit 1; }
    echo "$file"
done
