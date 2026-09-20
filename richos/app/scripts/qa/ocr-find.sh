#!/usr/bin/env bash
#
# ocr-find.sh — which of these frames shows this text?
#
#   ocr-find.sh <pattern> <dir-or-png> [more...] [--first] [--quiet] [--show]
#   ocr-find.sh --help
#
#   <pattern>   an extended regular expression, matched case-insensitively
#   --first     stop at the first hit and print only it (for "when did X appear")
#   --quiet     print only the hits, not the misses
#   --show      print the matching line from each hit
#
# Exit 0 at least one hit, 1 no hit, 2 the reader could not run.
#
# =============================================================================
# WHY THIS FILE EXISTS
# =============================================================================
# `findtext.sh`, `findphone.sh`, `findmac.sh`, `findsafari.sh`, `scanthread.sh`,
# `scan.py` and `ocrdump.py` were written across five walks and are one job with
# the directory hard-coded into each of them. A helper whose target directory is
# a constant inside the file has to be rewritten the next time the directory is
# different, which is every time.
#
# EXIT 1 ON NO HIT IS DELIBERATE. `findmac.sh` printed '--- frame' for every
# frame and exited 0, so a caller reading the exit code learned nothing and a
# caller reading the output had to count lines. "Did the reply ever arrive?" is
# a yes/no question and it gets a yes/no exit code.
set -uo pipefail

usage() { sed -n '3,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

FIRST=0; QUIET=0; SHOW=0
PATTERN=""
TARGETS=()

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --first)   FIRST=1; shift ;;
        --quiet)   QUIET=1; shift ;;
        --show)    SHOW=1; shift ;;
        -*)        echo "ocr-find.sh: unknown option '$1'. --help" >&2; exit 2 ;;
        *)
            if [ -z "$PATTERN" ]; then PATTERN="$1"; else TARGETS+=("$1"); fi
            shift ;;
    esac
done

if [ -z "$PATTERN" ] || [ "${#TARGETS[@]}" -eq 0 ]; then
    echo "ocr-find.sh: need a pattern and at least one frame or directory. --help" >&2
    exit 2
fi

TESS="${RICHOS_QA_TESSERACT:-}"
[ -n "$TESS" ] || TESS="$(command -v tesseract || true)"
for c in /opt/homebrew/bin/tesseract /usr/local/bin/tesseract; do
    [ -n "$TESS" ] && break
    [ -x "$c" ] && TESS="$c"
done
if [ -z "$TESS" ]; then
    echo "ocr-find.sh: no tesseract on this machine (\`brew install tesseract\`)." >&2
    exit 2
fi

FRAMES=()
for t in "${TARGETS[@]}"; do
    if [ -d "$t" ]; then
        while IFS= read -r f; do FRAMES+=("$f"); done \
            < <(find "$t" -type f \( -name '*.png' -o -name '*.PNG' \) | LC_ALL=C sort)
    elif [ -f "$t" ]; then
        FRAMES+=("$t")
    else
        echo "ocr-find.sh: no such file or directory: $t" >&2
        exit 2
    fi
done

if [ "${#FRAMES[@]}" -eq 0 ]; then
    echo "ocr-find.sh: found NO frames under the paths given." >&2
    exit 2
fi

HITS=0
for f in "${FRAMES[@]}"; do
    TXT="$("$TESS" "$f" stdout 2>/dev/null || true)"
    if printf '%s' "$TXT" | grep -qiE -- "$PATTERN"; then
        HITS=$((HITS + 1))
        echo "HIT  $f"
        if [ "$SHOW" -eq 1 ]; then
            printf '%s' "$TXT" | grep -iE -- "$PATTERN" | head -3 | sed 's/^/       /'
        fi
        [ "$FIRST" -eq 1 ] && break
    elif [ "$QUIET" -eq 0 ]; then
        echo "---  $f"
    fi
done

echo "--- $HITS of ${#FRAMES[@]} frame(s) match /$PATTERN/ ---"
[ "$HITS" -gt 0 ] && exit 0
exit 1
