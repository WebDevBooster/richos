#!/usr/bin/env bash
#
# ocr-watch.sh — sample a screen region on an interval and read it out loud.
#
#   ocr-watch.sh <outdir> --region x,y,w,h [--every SECONDS] [--count N]
#                [--until <extended-regex>] [--stop-on-repeat N]
#   ocr-watch.sh --help
#
# Prints one line per sample: index, epoch milliseconds, and the text read.
# Exit 0 the watch finished (or --until matched), 1 --until never matched,
# 2 the tool could not run.
#
# =============================================================================
# WHY THIS FILE EXISTS
# =============================================================================
# `countdown.sh` sampled a 260x24 strip of a pairing dialog every 8 s and OCRed
# it, to check the wording against the time actually remaining. `scanthread.sh`
# paged through a thread OCRing each screenful and counting a greeting line.
# They are the same tool with different constants, and both had their region,
# their interval and their output directory baked in.
#
# The TIMESTAMP is the whole point and both of them nearly lost it: a countdown
# that says "about 2 minutes" is only wrong relative to a clock, so a sample
# without a time beside it cannot answer the question it was taken for.
#
# Like timeline.py, this photographs a screen, so it runs inside the test VM or
# with RICHOS_QA_CAPTURE=allow set deliberately.
set -uo pipefail

usage() { sed -n '3,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

OUT=""; REGION=""; EVERY=5; COUNT=40; UNTIL=""; STOP_REPEAT=0
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)        usage; exit 0 ;;
        --region)         REGION="${2:-}"; shift 2 ;;
        --every)          EVERY="${2:-}"; shift 2 ;;
        --count)          COUNT="${2:-}"; shift 2 ;;
        --until)          UNTIL="${2:-}"; shift 2 ;;
        --stop-on-repeat) STOP_REPEAT="${2:-}"; shift 2 ;;
        -*)               echo "ocr-watch.sh: unknown option '$1'. --help" >&2; exit 2 ;;
        *)                OUT="$1"; shift ;;
    esac
done

[ -n "$OUT" ] || { echo "ocr-watch.sh: name an output directory. --help" >&2; exit 2; }
case "$REGION" in
    *,*,*,*) ;;
    *) echo "ocr-watch.sh: --region is required, as x,y,w,h" >&2; exit 2 ;;
esac

GUEST_USER="${TESTVM_GUEST_USER:-admin}"
if [ "${RICHOS_QA_CAPTURE:-}" != "allow" ] && [ "$(id -un)" != "$GUEST_USER" ]; then
    echo "ocr-watch.sh will not photograph this screen." >&2
    echo "It runs inside the test VM, where the app under test lives. The" >&2
    echo "operator's own Mac is never a test surface." >&2
    echo "To override deliberately: RICHOS_QA_CAPTURE=allow" >&2
    exit 2
fi

TESS="${RICHOS_QA_TESSERACT:-}"
[ -n "$TESS" ] || TESS="$(command -v tesseract || true)"
for c in /opt/homebrew/bin/tesseract /usr/local/bin/tesseract; do
    [ -n "$TESS" ] && break
    [ -x "$c" ] && TESS="$c"
done
[ -n "$TESS" ] || { echo "ocr-watch.sh: no tesseract on this machine." >&2; exit 2; }

mkdir -p "$OUT"
MATCHED=0
LAST=""
SAME=0
i=0
while [ "$i" -lt "$COUNT" ]; do
    N="$(printf '%03d' "$i")"
    F="$OUT/w$N.png"
    TS="$(python3 -c 'import time;print("%.0f"%(time.time()*1000))')"
    screencapture -x -o -R"$REGION" "$F" 2>/dev/null || true
    TXT="$("$TESS" "$F" stdout 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//' || true)"
    echo "$N $TS :: $TXT"

    if [ -n "$UNTIL" ] && printf '%s' "$TXT" | grep -qiE -- "$UNTIL"; then
        echo "--- matched /$UNTIL/ at sample $N ---"
        MATCHED=1
        break
    fi

    if [ "$STOP_REPEAT" -gt 0 ]; then
        if [ "$TXT" = "$LAST" ]; then
            SAME=$((SAME + 1))
            if [ "$SAME" -ge "$STOP_REPEAT" ]; then
                echo "--- unchanged for $STOP_REPEAT samples, stopping ---"
                break
            fi
        else
            SAME=0
            LAST="$TXT"
        fi
    fi

    i=$((i + 1))
    [ "$i" -lt "$COUNT" ] && sleep "$EVERY"
done

if [ -n "$UNTIL" ] && [ "$MATCHED" -eq 0 ]; then
    echo "ocr-watch.sh: /$UNTIL/ never appeared in $i sample(s)." >&2
    exit 1
fi
exit 0
