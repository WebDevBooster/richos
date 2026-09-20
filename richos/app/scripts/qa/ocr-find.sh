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
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$HERE/ocr-find.py" "$@"
