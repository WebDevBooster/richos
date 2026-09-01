#!/usr/bin/env bash
#
# rebuild.sh — regenerate the vendored .woff2 files in app/ui/fonts/ from upstream.
#
# ===========================================================================
# WHY THIS EXISTS
# ===========================================================================
# A vendored binary asset with no reproducible recipe is a fact nobody can
# check. Five .woff2 files here are the output of `pyftsubset` invocations;
# without this script the only record of those invocations would be a commit
# message, and the next person who needs to widen a unicode range or add a
# weight would be reverse-engineering a font file.
#
# NOT A TEST. It downloads and writes; it asserts nothing about the app. Run it
# when a face, a weight range or a unicode range changes, and never in CI.
#
# ===========================================================================
# WHAT IT NEEDS
# ===========================================================================
# python3 and the network. It builds a throwaway virtual environment for
# fonttools in a temporary directory and removes it on exit, so nothing is added
# to this repository's dependencies and nothing is left behind on the machine.
#
# Every archive is verified against a recorded sha256 BEFORE it is unpacked. A
# hash mismatch is a hard stop, not a warning: a font is code that runs in the
# customer's process, and "the download looked fine" is not a provenance claim.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$(cd "$HERE/../../ui/fonts" && pwd)"

WORK="$(mktemp -d -t richos-fonts)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

say() { printf '  %s\n' "$*"; }

# ===========================================================================
# NEWSREADER IS NOT REBUILT HERE, AND THAT IS DELIBERATE
# ===========================================================================
# The CEO approved Newsreader as SPECIFIC FILES — the two subsets in the
# round-11.1 mockup, whose sha256 is recorded in that round's README. Rebuilding
# them would produce a second, unreviewed artifact of an approved thing, and buy
# nothing: no text in the app is set in a serif yet, so there is no wider
# coverage for a rebuild to serve.
#
# So they are committed verbatim and VERIFIED here instead. If this check ever
# fails, somebody has regenerated an approved artifact and that is the thing to
# look at, not the number.
verify_newsreader() {
  local bad=0
  local expect_regular="e71a3bea5993009ab159b89d52d88ba515efd57e8d9324a94c681bfc72c9ac0f"
  local expect_italic="e384e31812c1d580b5ae2217ade8ca5fe9e5135ea9c27423359d00a954c28488"
  local got
  got="$(shasum -a 256 "$DEST/Newsreader-Regular.woff2" | awk '{print $1}')"
  if [ "$got" != "$expect_regular" ]; then
    echo "  MISMATCH Newsreader-Regular.woff2: $got != $expect_regular" >&2; bad=1
  else say "Newsreader-Regular.woff2 matches the approved artifact"; fi
  got="$(shasum -a 256 "$DEST/Newsreader-Italic.woff2" | awk '{print $1}')"
  if [ "$got" != "$expect_italic" ]; then
    echo "  MISMATCH Newsreader-Italic.woff2: $got != $expect_italic" >&2; bad=1
  else say "Newsreader-Italic.woff2 matches the approved artifact"; fi
  if [ "$bad" = 1 ]; then
    echo "" >&2
    echo "REFUSING: a Newsreader file is not the one the CEO approved. These are" >&2
    echo "committed verbatim from richos-hq design/mockups/rounds/round-11.1/v1/fonts/" >&2
    echo "and are not regenerated. Restore them rather than re-cutting them." >&2
    exit 1
  fi
}

# --- the upstream archives, pinned by version AND by content -----------------
# Downloaded from each project's own release page rather than a font CDN, so the
# license file that governs each face arrives in the same archive as the face.
FETCH=(
  "inter|https://github.com/rsms/inter/releases/download/v4.1/Inter-4.1.zip|9883fdd4a49d4fb66bd8177ba6625ef9a64aa45899767dde3d36aa425756b11e"
  "nsym2|https://github.com/notofonts/symbols/releases/download/NotoSansSymbols2-v2.008/NotoSansSymbols2-v2.008.zip|346c930bbe8eb946701a05c54e9c11a2094dee1d93c387bf1771c0a3e335688f"
  "nsym1|https://github.com/notofonts/symbols/releases/download/NotoSansSymbols-v2.003/NotoSansSymbols-v2.003.zip|0c113cdcf6c31d050b80dac39fba2d804a6985281012e76e9220c0a00da007f3"
  "nmath|https://github.com/notofonts/math/releases/download/NotoSansMath-v3.000/NotoSansMath-v3.000.zip|ac351837b41f8a897f020b97fb0f075ad574c1e9669fb5839ada1f92fd748356"
)

echo ""
echo "=== the approved serif, verified rather than rebuilt ==="
verify_newsreader

echo ""
echo "=== fetching upstream releases ==="
for entry in "${FETCH[@]}"; do
  IFS='|' read -r name url want <<<"$entry"
  say "$name"
  curl -sSL --max-time 300 -o "$WORK/$name.zip" "$url"
  got="$(shasum -a 256 "$WORK/$name.zip" | awk '{print $1}')"
  if [ "$got" != "$want" ]; then
    echo "" >&2
    echo "REFUSING: $name archive does not match its recorded hash." >&2
    echo "  url:      $url" >&2
    echo "  expected: $want" >&2
    echo "  got:      $got" >&2
    echo "" >&2
    echo "Either the upstream release was re-cut, or this is not the file it" >&2
    echo "claims to be. Neither is something to subset and ship." >&2
    exit 1
  fi
  unzip -o -q "$WORK/$name.zip" -d "$WORK/$name"
done

# --- fonttools, in a throwaway environment ----------------------------------
echo ""
echo "=== building a throwaway fonttools environment ==="
python3 -m venv "$WORK/venv" >/dev/null
"$WORK/venv/bin/pip" install -q "fonttools[woff]" brotli
PYFTSUBSET="$WORK/venv/bin/pyftsubset"
FONTTOOLS="$WORK/venv/bin/fonttools"
say "fonttools $("$WORK/venv/bin/python" -c 'import fontTools; print(fontTools.version)')"

# --- THE RANGES -------------------------------------------------------------
# Latin-1 and Latin Extended-A cover Western European text precomposed. The
# combining marks are carried because macOS hands out decomposed (NFD) file
# names, and a missing combining acute is exactly the kind of single character
# that would silently reach for a system font. Then the blocks an
# English-language interface actually draws from.
#
# Widening this is the whole cost of supporting more text: change it, re-run,
# and the README table's byte counts move. See README.md for what is
# deliberately NOT carried.
TEXT="U+0000-00FF,U+0100-017F,U+0300-036F,U+2000-206F,U+2070-209F,U+20A0-20BF,U+2100-214F,U+2190-21FF,U+2200-22FF,U+2300-23FF,U+25A0-25FF,U+2600-26FF,U+2700-27BF,U+FB00-FB06,U+FEFF,U+FFFD"

# The symbol faces answer for SEVEN glyphs neither Inter nor Newsreader carries,
# and for nothing else. Narrow on purpose: every codepoint added here is weight
# with no reader. These lists are mirrored by the `unicode-range` declarations in
# app/ui/fonts/fonts.css — change one and change the other.
SYM2="U+25BE,U+25C9,U+25D0,U+2630,U+2713,U+2715"
SYM1="U+2699"
MATH="U+22EF"

# THE WEIGHT RANGE INTER IS CUT TO. The app sets 400, 500, 600 and 700; shipping
# wght 100-900 costs 168KB against 122KB for this. Widen it here if a design
# round asks for a weight outside it — that is a rebuild, not a redesign.
INTER_WGHT="wght=400:700"

sub() {
  local in="$1" out="$2" ranges="$3"
  "$PYFTSUBSET" "$in" \
    --output-file="$DEST/$out" \
    --flavor=woff2 \
    --unicodes="$ranges" \
    --layout-features='*' \
    --no-hinting \
    --drop-tables+=DSIG
}

echo ""
echo "=== subsetting into $DEST ==="
# Inter, clipped on the weight axis first. The OPTICAL SIZE axis is deliberately
# kept: the app sets type from 12px to 31px and opsz is what makes one face read
# correctly across that range.
"$FONTTOOLS" varLib.instancer "$WORK/inter/web/InterVariable.woff2" "$INTER_WGHT" \
  -o "$WORK/inter-clipped.ttf" >/dev/null
sub "$WORK/inter-clipped.ttf"            Inter-Variable.woff2 "$TEXT"
sub "$WORK/inter/web/Inter-Italic.woff2" Inter-Italic.woff2   "$TEXT"

sub "$WORK/nsym2/NotoSansSymbols2/unhinted/ttf/NotoSansSymbols2-Regular.ttf" \
                                         NotoSansSymbols2-subset.woff2 "$SYM2"
sub "$WORK/nsym1/NotoSansSymbols/unhinted/variable-ttf/NotoSansSymbols[wght].ttf" \
                                         NotoSansSymbols-subset.woff2  "$SYM1"
sub "$WORK/nmath/NotoSansMath/unhinted/ttf/NotoSansMath-Regular.ttf" \
                                         NotoSansMath-subset.woff2     "$MATH"

# --- the license files travel with the fonts --------------------------------
# The OFL requires it, and these are embedded in the binary alongside the faces
# they govern. Copied from the archives rather than kept by hand, so a version
# bump cannot leave a stale license behind a new face. Newsreader's arrives with
# its approved files and is not touched here.
cp "$WORK/inter/LICENSE.txt" "$DEST/LICENSE-Inter.txt"
cp "$WORK/nsym2/OFL.txt"     "$DEST/LICENSE-NotoSansSymbols.txt"
cp "$WORK/nmath/OFL.txt"     "$DEST/LICENSE-NotoSansMath.txt"

echo ""
echo "=== result ==="
total=0
for f in "$DEST"/*.woff2; do
  n="$(stat -f%z "$f")"
  total=$((total + n))
  printf '  %9d  %s\n' "$n" "$(basename "$f")"
done
printf '  %9d  TOTAL woff2\n' "$total"
echo ""
echo "  sha256, for the table in README.md:"
shasum -a 256 "$DEST"/*.woff2 | sed "s|$DEST/|    |"
echo ""
echo "  If any byte count or hash above differs from README.md, update README.md."
echo "  It is the record of what shipped, and a record that disagrees with the"
echo "  directory it describes is worse than none."
echo ""
