#!/usr/bin/env bash
#
# rebuild.sh — regenerate every .woff2 in app/ui/fonts/ from upstream.
#
# ===========================================================================
# WHY THIS EXISTS
# ===========================================================================
# A vendored binary asset with no reproducible recipe is a fact nobody can
# check. Six .woff2 files landed in this repository as the output of six
# `pyftsubset` invocations; without this script the only record of those
# invocations would be a commit message, and the next person who needs to widen
# a unicode range or swap a face would be reverse-engineering a font file.
#
# It is also what makes "adopt the round-11.1 face" a small job rather than an
# investigation: change one URL and one line, re-run, commit the diff.
#
# NOT A TEST. It downloads and writes; it asserts nothing about the app. Run it
# when a face or a range changes, and never in CI.
#
# ===========================================================================
# WHAT IT NEEDS
# ===========================================================================
# python3 and the network. It builds a throwaway virtual environment for
# fonttools in a temporary directory and removes it on exit, so nothing is added
# to this repository's dependencies and nothing is left behind on the machine.
#
# Every archive is verified against the sha256 recorded in README.md BEFORE it
# is unpacked. A hash mismatch is a hard stop, not a warning: a font is code
# that runs in the customer's process, and "the download looked fine" is not a
# provenance claim.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$(cd "$HERE/../../ui/fonts" && pwd)"

WORK="$(mktemp -d -t richos-fonts)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

say() { printf '  %s\n' "$*"; }

# --- the upstream archives, pinned by version AND by content -----------------
# Downloaded from each project's own release page rather than a font CDN, so the
# license file that governs each face arrives in the same archive as the face.
FETCH=(
  "inter|https://github.com/rsms/inter/releases/download/v4.1/Inter-4.1.zip|9883fdd4a49d4fb66bd8177ba6625ef9a64aa45899767dde3d36aa425756b11e"
  "jbm|https://github.com/JetBrains/JetBrainsMono/releases/download/v2.304/JetBrainsMono-2.304.zip|6f6376c6ed2960ea8a963cd7387ec9d76e3f629125bc33d1fdcd7eb7012f7bbf"
  "nsym2|https://github.com/notofonts/symbols/releases/download/NotoSansSymbols2-v2.008/NotoSansSymbols2-v2.008.zip|346c930bbe8eb946701a05c54e9c11a2094dee1d93c387bf1771c0a3e335688f"
  "nsym1|https://github.com/notofonts/symbols/releases/download/NotoSansSymbols-v2.003/NotoSansSymbols-v2.003.zip|0c113cdcf6c31d050b80dac39fba2d804a6985281012e76e9220c0a00da007f3"
  "nmath|https://github.com/notofonts/math/releases/download/NotoSansMath-v3.000/NotoSansMath-v3.000.zip|ac351837b41f8a897f020b97fb0f075ad574c1e9669fb5839ada1f92fd748356"
)

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
    echo "claims to be. Neither is something to subset and ship. Check the" >&2
    echo "release, then update the hash in app/scripts/fonts/README.md and here." >&2
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

# The symbol faces answer for SEVEN glyphs the text faces do not carry, and for
# nothing else. Narrow on purpose: every codepoint added here is weight with no
# reader. These lists are mirrored by the `unicode-range` declarations in
# app/ui/fonts/fonts.css — change one and change the other.
SYM2="U+25BE,U+25C9,U+25D0,U+2630,U+2713,U+2715"
SYM1="U+2699"
MATH="U+22EF"

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
sub "$WORK/inter/web/InterVariable.woff2"                 Inter-Variable.woff2         "$TEXT"
sub "$WORK/inter/web/Inter-Italic.woff2"                  Inter-Italic.woff2           "$TEXT"
sub "$WORK/jbm/fonts/variable/JetBrainsMono[wght].ttf"    JetBrainsMono-Variable.woff2 "$TEXT"
sub "$WORK/nsym2/NotoSansSymbols2/unhinted/ttf/NotoSansSymbols2-Regular.ttf" \
                                                          NotoSansSymbols2-subset.woff2 "$SYM2"
sub "$WORK/nsym1/NotoSansSymbols/unhinted/variable-ttf/NotoSansSymbols[wght].ttf" \
                                                          NotoSansSymbols-subset.woff2  "$SYM1"
sub "$WORK/nmath/NotoSansMath/unhinted/ttf/NotoSansMath-Regular.ttf" \
                                                          NotoSansMath-subset.woff2     "$MATH"

# --- the license files travel with the fonts --------------------------------
# The OFL requires it, and these are embedded in the binary alongside the faces
# they govern. Copied from the archives rather than kept by hand, so a version
# bump cannot leave a stale license behind a new face.
cp "$WORK/inter/LICENSE.txt" "$DEST/LICENSE-Inter.txt"
cp "$WORK/jbm/OFL.txt"       "$DEST/LICENSE-JetBrainsMono.txt"
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
