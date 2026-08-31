#!/usr/bin/env bash
#
# measure-node-payload.sh — what the Node/ACP side of RichOS would add to a customer's
# download. Re-run it; do not quote the numbers below without re-running it.
#
# WHY THIS IS A SCRIPT AND NOT A PARAGRAPH. `richos-payload-architecture-2026-08-31.md`
# marks this the largest uncosted item in the design, on the critical path, and says to
# measure it before promising anyone a megabyte figure. A paragraph would have been true
# for one afternoon: the dominant term is a native Claude Code binary that ships as a
# platform-specific optional dependency and changes size with every release. The version
# this repository locks measured 306,111,312 bytes; the registry's `latest` on the same
# day advertised 197,172,264. A number with no way to reproduce it is a number that will
# be wrong and believed.
#
# WHAT IT DOES NOT DO IS DECIDE. Three placements are costed and none is recommended,
# because the difference between them is not an engineering difference — it is whether a
# customer is required to have Claude Code, and that is not this script's call.
#
# ------------------------------------------------------------------------------------
# THE RUN OF 2026-08-31, on this Mac, against `app/acp-adapter/package-lock.json` as
# locked (`@agentclientprotocol/claude-agent-acp` 0.70.0 →
# `@anthropic-ai/claude-agent-sdk` 0.3.232). All figures MEASURED unless labelled.
#
#   node_modules, installed from the lock              340,445,066 B    324.7 MiB
#     of which  the native `claude` binary             306,111,312 B    291.9 MiB
#     of which  everything else (JS, types, maps)       34,333,170 B     32.7 MiB
#     ...minus declarations, maps and docs              15,481,673 B     14.8 MiB
#     ...minus those AND vendored test/doc dirs         14,513,215 B     13.8 MiB
#   node v22.20.0 darwin-arm64, official build         111,332,720 B    106.2 MiB
#     ...`strip -x`ped and re-signed                    89,488,384 B     85.3 MiB
#
# The two prunings differ because they are two methods, and both are reported rather
# than one being picked: the script below subtracts by file extension, which is what a
# script can do to a tree it must not modify; the 14,513,215 figure is a tree that was
# actually built, had its vendored `test/` and `docs/` directories removed too, and was
# then RUN. Use the larger one for a promise and the smaller one for a ceiling.
#
# Assembled into real bundles and RUN, not added up on paper. These totals INCLUDE
# RichOS.app itself at 13,422,371 B:
#
#   A  bundle node + adapter + the Claude binary       403.9 MiB   gz 122.0 MiB
#   B  bundle node + adapter, customer's own Claude    112.0 MiB   gz  40.3 MiB
#   C  bundle neither; Node and the adapter are a       12.8 MiB   gz   5.6 MiB
#      prerequisite the customer installs
#
# The Node side is not a component of the download in options A and B; it IS the
# download. Whisper's 4 MB, and the 20 MB of screenshots that were removed from the
# binary on the same day, are both rounding errors against it.
#
# THREE THINGS THAT ARE NOT SIZES AND MATTER MORE:
#
#   1. The Claude binary is per-architecture — `darwin-arm64` and `darwin-x64` are
#      separate packages. A universal build carries both or ships two DMGs.
#   2. `strip` KILLS a macOS arm64 binary. The stripped node exited 137 (SIGKILL) until
#      it was re-signed: modifying the file invalidates its code signature and the kernel
#      refuses it. Any trimming step must be followed by a re-sign, which the app's own
#      codesign pass does anyway — but only if the trimming happens BEFORE it.
#   3. Option B's failure mode is clean and was checked: with no native package and no
#      `CLAUDE_CODE_EXECUTABLE`, the adapter throws "Claude native binary not found for
#      darwin-arm64" rather than hanging or half-working. `CLAUDE_CODE_EXECUTABLE` is read
#      first, ahead of package resolution, in `dist/acp-agent.js`. There is no PATH
#      fallback: an unset variable and an absent package is a hard failure, not a search.
# ------------------------------------------------------------------------------------
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$(cd "$DIR/.." && pwd)"
ADAPTER="$APP/acp-adapter"
NM="$ADAPTER/node_modules"

# Apparent bytes, never `du`. `du` reports allocated blocks, which is a property of this
# filesystem and not of what a customer downloads — it is how `app/ui` came to be called
# 27 MB when the bytes in it are 25,489,887.
bytes() { find "$@" -type f -print0 2>/dev/null | xargs -0 stat -f '%z' 2>/dev/null | awk '{s+=$1} END{print s+0}'; }
mib()   { awk -v b="$1" 'BEGIN{printf "%.1f", b/1048576}'; }
row()   { printf '  %-46s %13s B  %8s MiB\n' "$1" "$2" "$(mib "$2")"; }

if [ ! -d "$NM" ]; then
  echo "acp-adapter/node_modules is not installed. Installing from the lock — the point is"
  echo "to measure what the lock produces, so a fresh resolve would be measuring something else."
  ( cd "$ADAPTER" && npm ci --no-audit --no-fund ) || {
    echo "npm ci failed. Refusing to report a size for a tree that did not install." >&2
    exit 1
  }
fi

NATIVE_DIR="$(find "$NM/@anthropic-ai" -maxdepth 1 -type d -name 'claude-agent-sdk-*' 2>/dev/null | head -1)"
if [ -z "$NATIVE_DIR" ]; then
  # A missing platform package is the difference between option A and option B, and it is
  # exactly the kind of absence that would otherwise be reported as a pleasingly small number.
  echo "No @anthropic-ai/claude-agent-sdk-<platform> package under $NM." >&2
  echo "The native CLI is an OPTIONAL dependency; without it this tree cannot run the ACP" >&2
  echo "adapter at all, and any total printed from here would be option B's, not option A's." >&2
  exit 1
fi

TOTAL=$(bytes "$NM")
NATIVE=$(bytes "$NATIVE_DIR")
JS=$((TOTAL - NATIVE))

# What of the JS a customer would actually execute. TypeScript declarations, source maps
# and READMEs are 55% of that tree and are read by editors, never by node. Counted rather
# than deleted — this script measures, it does not modify the checkout — and the pruned
# tree was separately assembled and RUN on 2026-08-31 before this subtraction was trusted:
# `claude-agent-acp --version` and `--cli --version` both still answered.
PRUNED=$(( JS - $(bytes "$NM" \( -name '*.d.ts' -o -name '*.map' -o -name '*.ts' -o -name '*.mts' \
                                 -o -name '*.cts' -o -name '*.md' -o -name '*.markdown' -o -name '*.yml' \) \
                        -not -path "$NATIVE_DIR/*") ))

echo ""
echo "=== the ACP adapter's installed tree ==="
row "node_modules, whole"                      "$TOTAL"
row "  the native Claude binary"               "$NATIVE"
row "  everything else"                        "$JS"
row "    ...of that, what node actually loads" "$PRUNED"
echo "     $(basename "$NATIVE_DIR") $(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['version'])" "$NATIVE_DIR/package.json" 2>/dev/null)"

echo ""
echo "=== a Node runtime, if one is bundled ==="
# The `node` on THIS machine is Homebrew's: a 68 KB stub against a shared libnode, which is
# a package-manager artefact and not a shippable runtime. What would ship is the official
# self-contained build, whose only linkage is to system frameworks. Measured where present,
# and named as absent otherwise rather than substituted for.
NODE_BIN="$(command -v node || true)"
if [ -n "$NODE_BIN" ]; then
  row "node on PATH ($(node -v 2>/dev/null))" "$(stat -f '%z' "$(readlink -f "$NODE_BIN" 2>/dev/null || echo "$NODE_BIN")")"
  if otool -L "$NODE_BIN" 2>/dev/null | grep -q 'libnode'; then
    echo "     ...which links a shared libnode and is NOT shippable on its own."
  fi
fi
echo "     A shippable runtime is the official darwin build's single self-contained"
echo "     binary. Measured 2026-08-31 at 111,332,720 B for v22.20.0 darwin-arm64;"
echo "     89,488,384 B after strip -x and an ad-hoc re-sign. Re-measure on any bump:"
echo "       curl -sL https://nodejs.org/dist/vNN/node-vNN-darwin-arm64.tar.gz | tar xz"

echo ""
echo "=== what each placement costs, on top of RichOS.app itself ==="
row "A  node + adapter + Claude binary"    "$((89488384 + PRUNED + NATIVE))"
row "B  node + adapter, customer's Claude"  "$((89488384 + PRUNED))"
row "C  nothing bundled"                     0
echo "     (A and B count the pruned tree, because shipping .d.ts files to a customer"
echo "      would be the same defect as shipping the screenshots. Unpruned they are"
echo "      $(mib $((89488384 + JS + NATIVE))) MiB and $(mib $((89488384 + JS))) MiB.)"
echo ""
echo "  A ships everything and imposes nothing. B needs Claude Code on the customer's"
echo "  machine, found via CLAUDE_CODE_EXECUTABLE. C needs Node AND the adapter installed"
echo "  by the customer. B and C are prerequisites we impose on someone who bought an app;"
echo "  A is a 400 MB download. Which of those is acceptable is not an engineering"
echo "  question and this script does not answer it."
