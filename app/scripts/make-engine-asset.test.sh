#!/usr/bin/env bash
#
# make-engine-asset.test.sh — the engine release asset carries its own license.
#
# THE DEFECT THIS EXISTS FOR, found by the 2026-09-04 pre-publication audit.
# `make-engine-asset.sh` archives the `engine/` directory. The canonical AGPL text is at
# the REPOSITORY root, one level above it. So the standalone engine tarball — the thing a
# customer's first run downloads from Releases, extracts, and installs — contained no
# license text of any kind. An AGPL work distributed without its terms, to the one reader
# who has no repository to go and look in.
#
# Three bundled skills had a second version of the same defect: `frontend-design/SKILL.md`
# said "Complete terms in LICENSE.txt" with no such file anywhere, and the vendored
# `marketing-strategy-pmm` and `resend` skills declared MIT with no MIT notice beside them.
# A claim pointing at nothing is worse than no claim, because it reads as diligence.
#
# WHAT IS CHECKED HERE AND WHAT IS CHECKED BY THE SCRIPT ITSELF. The script refuses at
# build time; this suite proves the refusals actually fire, using a synthetic repository
# it builds from scratch so a negative case is a real refusal rather than an assertion
# about one. The last three cases run against the REAL tree, because a fixture proving a
# refusal works says nothing about whether this repository would pass it.
#
# ONE BRANCH IS DELIBERATELY NOT COVERED, and saying so is better than a case that pretends.
# The script compares the LICENSE it read out of the finished archive against the canonical
# root file. Today those cannot differ: the same `cp` produced both. That comparison is a
# guard against a FUTURE packaging change — a filter, a transform, an exclusion list — that
# would otherwise ship a mangled license and exit 0. There is no way to trigger it from
# outside the script as written, so no case here claims to. The same is true of the
# "packaging dropped a license file" branch.
#
# Cases:
#   L1  no root LICENSE            → REFUSES, and names the file
#   L2  no third-party notices     → REFUSES, and names the file
#   L3  a complete fixture builds at all
#   L4  the archive contains engine/LICENSE
#   L5  ...byte-identical to that repository's root LICENSE
#   L6  the archive contains engine/THIRD-PARTY-NOTICES.md
#   L7  a bundled skill's own license file survives into the archive
#   L8  a skill DECLARING a license with no license file beside it → REFUSES
#   L9  the real repository has the root LICENSE, at the canonical sha256
#   L10 the real repository has docs/legal/THIRD-PARTY-NOTICES.md
#   L11 every real bundled directory that has a license file still has one
#   L12 the real archive builds, is deterministic, and carries the canonical LICENSE
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$(cd "$DIR/.." && pwd)"
ROOT="$(cd "$APP/.." && pwd)"
SCRIPT="$DIR/make-engine-asset.sh"

# The canonical AGPL v3 digest. Written here as a literal on purpose: if the root LICENSE
# is ever edited, this suite is one of the places that says so out loud. See
# docs/legal/LICENSING.md.
CANON_SHA="0d96a4ff68ad6d4b6f1f30f713b18d5184912ba8dd389f86aa7710db079abcb0"

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n         %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }

[ -f "$SCRIPT" ] || { echo "make-engine-asset.test.sh: no $SCRIPT — refusing to report a result." >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/engine-asset-test.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------------------
# A synthetic repository, shaped like this one and nothing like this one's size.
# ---------------------------------------------------------------------------------------
# $1 = destination root. Builds a minimal but COMPLETE tree: the script's own preconditions
# are all satisfied, so any refusal in a later case is caused by what that case removed.
make_fixture() {
    local r="$1"
    mkdir -p "$r/app/scripts" "$r/docs/legal" \
             "$r/engine/scripts/hooks" "$r/engine/skills/demo-skill" "$r/engine/tools/demo-tool"
    cp "$SCRIPT" "$r/app/scripts/make-engine-asset.sh"
    cp "$ROOT/LICENSE" "$r/LICENSE"
    printf 'notices for the fixture\n' > "$r/docs/legal/THIRD-PARTY-NOTICES.md"
    printf '1.0.0\n' > "$r/engine/VERSION"
    printf '#!/usr/bin/env bash\ntrue\n' > "$r/engine/scripts/hooks/guard-demo.sh"
    printf -- '---\nname: demo-skill\nlicense: MIT\n---\n\nbody\n' > "$r/engine/skills/demo-skill/SKILL.md"
    printf 'MIT License\n\nCopyright (c) 2026 Somebody Else\n' > "$r/engine/skills/demo-skill/LICENSE"
    printf 'MIT License\n\nCopyright (c) 2026 Somebody Else\n' > "$r/engine/tools/demo-tool/LICENSE"
}

# Runs the fixture's copy of the script. Never touches the real tree.
run_fixture() { bash "$1/app/scripts/make-engine-asset.sh" --out "$1/out" 2>&1; }

# ---------------------------------------------------------------------------------------
# L1 / L2 — the two preconditions, each removed on its own
# ---------------------------------------------------------------------------------------
F="$WORK/no-license"; make_fixture "$F"; rm -f "$F/LICENSE"
OUT="$(run_fixture "$F")"; CODE=$?
if [ "$CODE" -ne 0 ] && printf '%s' "$OUT" | grep -q 'no LICENSE at'; then
    ok "L1 a repository with no root LICENSE is REFUSED, by name"
else
    bad "L1 a repository with no root LICENSE is REFUSED, by name" "exit $CODE: $(printf '%s' "$OUT" | tail -1)"
fi

F="$WORK/no-notices"; make_fixture "$F"; rm -f "$F/docs/legal/THIRD-PARTY-NOTICES.md"
OUT="$(run_fixture "$F")"; CODE=$?
if [ "$CODE" -ne 0 ] && printf '%s' "$OUT" | grep -q 'no third-party notices at'; then
    ok "L2 a repository with no third-party notices is REFUSED, by name"
else
    bad "L2 a repository with no third-party notices is REFUSED, by name" "exit $CODE: $(printf '%s' "$OUT" | tail -1)"
fi

# ---------------------------------------------------------------------------------------
# L3–L7 — the complete fixture, and what its archive actually contains
# ---------------------------------------------------------------------------------------
F="$WORK/complete"; make_fixture "$F"
OUT="$(run_fixture "$F")"; CODE=$?
TARBALL="$F/out/richos-engine-1.0.0.tar.gz"
if [ "$CODE" -eq 0 ] && [ -s "$TARBALL" ]; then
    ok "L3 a complete fixture builds an archive"
else
    bad "L3 a complete fixture builds an archive" "exit $CODE: $(printf '%s' "$OUT" | tail -2)"
fi

X="$F/x"; mkdir -p "$X"
if [ -s "$TARBALL" ]; then
    /usr/bin/tar -x -z --no-same-owner -f "$TARBALL" -C "$X" 2>/dev/null
fi

if [ -f "$X/engine/LICENSE" ]; then
    ok "L4 the archive contains engine/LICENSE"
else
    bad "L4 the archive contains engine/LICENSE" "an AGPL work would ship with no terms"
fi

A="$(/usr/bin/shasum -a 256 "$F/LICENSE" 2>/dev/null | awk '{print $1}')"
B="$(/usr/bin/shasum -a 256 "$X/engine/LICENSE" 2>/dev/null | awk '{print $1}')"
if [ -n "$A" ] && [ "$A" = "$B" ]; then
    ok "L5 the archived LICENSE is byte-identical to the repository's root LICENSE"
else
    bad "L5 the archived LICENSE is byte-identical to the repository's root LICENSE" "$B vs $A"
fi

if [ -f "$X/engine/THIRD-PARTY-NOTICES.md" ]; then
    ok "L6 the archive contains engine/THIRD-PARTY-NOTICES.md"
else
    bad "L6 the archive contains engine/THIRD-PARTY-NOTICES.md" "the asset could not name what it bundles"
fi

if [ -f "$X/engine/skills/demo-skill/LICENSE" ] && [ -f "$X/engine/tools/demo-tool/LICENSE" ]; then
    ok "L7 bundled third-party license files survive into the archive"
else
    bad "L7 bundled third-party license files survive into the archive" "a bundled notice was lost in packaging"
fi

# ---------------------------------------------------------------------------------------
# L8 — a claim with nothing behind it. THE defect the audit found, three times over.
# ---------------------------------------------------------------------------------------
F="$WORK/claim-no-text"; make_fixture "$F"; rm -f "$F/engine/skills/demo-skill/LICENSE"
OUT="$(run_fixture "$F")"; CODE=$?
if [ "$CODE" -ne 0 ] && printf '%s' "$OUT" | grep -q 'declare a license with no license file'; then
    ok "L8 a skill declaring a license with no license file beside it is REFUSED"
else
    bad "L8 a skill declaring a license with no license file beside it is REFUSED" "exit $CODE: $(printf '%s' "$OUT" | tail -1)"
fi

# ---------------------------------------------------------------------------------------
# L9–L12 — the REAL tree. A fixture proving a refusal works says nothing about this one.
# ---------------------------------------------------------------------------------------
REAL_SHA="$(/usr/bin/shasum -a 256 "$ROOT/LICENSE" 2>/dev/null | awk '{print $1}')"
if [ "$REAL_SHA" = "$CANON_SHA" ]; then
    ok "L9 the real root LICENSE is the canonical AGPL v3 text"
else
    bad "L9 the real root LICENSE is the canonical AGPL v3 text" "sha256 $REAL_SHA, expected $CANON_SHA"
fi

if [ -f "$ROOT/docs/legal/THIRD-PARTY-NOTICES.md" ]; then
    ok "L10 the real repository has docs/legal/THIRD-PARTY-NOTICES.md"
else
    bad "L10 the real repository has docs/legal/THIRD-PARTY-NOTICES.md" "packaging would refuse"
fi

# Derived from disk, never typed: every directory under engine/ that carries its own
# license file today. If a vendored skill loses its notice, this count drops and this
# case says so without anyone having maintained a list.
REAL_TP="$( ( cd "$ROOT/engine" && find . -type f \( -name 'LICENSE' -o -name 'LICENSE.txt' -o -name 'LICENSE.md' \) ) | wc -l | tr -d ' ')"
if [ "$REAL_TP" -ge 16 ]; then
    ok "L11 the real engine carries $REAL_TP bundled license files (16 known bundled works)"
else
    bad "L11 the real engine carries at least 7 bundled license files" \
        "found $REAL_TP — a vendored work has lost its notice; see docs/legal/THIRD-PARTY-NOTICES.md"
fi

OUT="$(bash "$SCRIPT" --out "$WORK/real-out" --check 2>&1)"; CODE=$?
REAL_TARBALL="$(ls "$WORK/real-out"/richos-engine-*.tar.gz 2>/dev/null | head -1)"
RX="$WORK/real-x"; mkdir -p "$RX"
[ -n "$REAL_TARBALL" ] && /usr/bin/tar -x -z --no-same-owner -f "$REAL_TARBALL" -C "$RX" 2>/dev/null
SHIPPED="$(/usr/bin/shasum -a 256 "$RX/engine/LICENSE" 2>/dev/null | awk '{print $1}')"
if [ "$CODE" -eq 0 ] && [ "$SHIPPED" = "$CANON_SHA" ]; then
    ok "L12 the real archive builds deterministically and carries the canonical LICENSE"
else
    bad "L12 the real archive builds deterministically and carries the canonical LICENSE" \
        "exit $CODE, shipped sha256 ${SHIPPED:-<absent>}: $(printf '%s' "$OUT" | tail -1)"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== make-engine-asset tests: $FAIL FAILED, $PASS passed ==="
    exit 1
fi
echo "=== make-engine-asset tests: all $PASS passed ==="
