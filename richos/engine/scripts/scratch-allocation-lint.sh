#!/usr/bin/env bash
#
# scratch-allocation-lint.sh — DOES ANY ENGINE SCRIPT STILL NAME ITS OWN SCRATCH?
#
# ===========================================================================
# THE ONE QUESTION THIS ANSWERS
# ===========================================================================
# For every shell script under scripts/ (including hooks/ and lib/): does it
# create a temporary directory with a BARE `mktemp` instead of asking
# scripts/lib/scratch.sh for one?
#
# That is the whole rule. It is not a style check and it has no opinion about
# anything else in the file.
#
# ===========================================================================
# WHY IT MATTERS ENOUGH TO ENFORCE
# ===========================================================================
# 2026-09-17 22:39. scripts/hooks/root-contract.mutation.sh created a sandbox
# with `mktemp -d -t root-mutation.XXXXXX`, copied the engine into it four times,
# and was killed before its EXIT trap fired. By morning that ONE directory held
# 105.3 GB and $TMPDIR held 114.5 GB across 88,829 entries.
#
# THE REAPER WAS INSTALLED AND RUNNING THE WHOLE TIME. It fired at 21:40 and at
# 03:40 and freed 156 KB, and "root-mutation" appears nowhere in its log on any
# run ever, because SCRATCH_TMP_PATTERNS was an ALLOWLIST OF NAMES and nobody had
# thought of that one.
#
# An allowlist of names can only contain the names somebody thought of. That is
# why the allocator exists — one root, deny-by-default, so the sweeper predicts
# nothing — and it is why this lint exists: the allocator only helps for the code
# that USES it, and the next `mktemp -d` somebody writes is outside it again.
#
# ===========================================================================
# WHAT IT DOES NOT DO, AND WHY THE RULE IS THIS COARSE
# ===========================================================================
# It flags `mktemp -d` (a DIRECTORY, which is what grows without bound) and not
# plain `mktemp` for a single scratch FILE. A one-line temp file is not what fills
# a disk, and flagging every one of them would make this fire on most of the
# engine — and a check that fires on correct files gets waived on the day it
# lands, which this repository recorded three instances of in a single day. A
# habitually waived check is worse than no check.
#
# TEST FILES ARE EXEMPT BY DEFAULT and that is a deliberate hole with a reason: a
# suite needs its own throwaway world, it removes it on a normal exit, and the
# sweeper's legacy families cover what a killed suite leaves. Naming this here is
# cheaper than pretending to coverage that does not exist. `--strict` includes
# them for anybody who wants the full picture.
#
# ===========================================================================
# THE ESCAPE HATCH, DECLARED WHERE A REVIEWER SEES IT
# ===========================================================================
# A script with a real reason puts this on the line, or on the line before:
#
#     # scratch-exempt: <reason>
#
# A bare marker exempts nothing — the reason is the point, the same discipline
# the contrast floor and the dialect guard use. Every exemption is COUNTED and
# PRINTED in the summary, so a file that quietly accumulates them is visible.
#
# ===========================================================================
# THE BASELINE, AND WHY THIS LINT SHIPS WITH ONE
# ===========================================================================
# The first run of this lint found 51 sites. Migrating all of them in the change
# that introduced the allocator would have been a 51-file blind edit across the
# whole engine, and shipping a lint that fails on 45 pre-existing sites would
# have meant a check that is RED on the day it lands — which is a check that gets
# waived on the day it lands, and this repository recorded three of those in a
# single day.
#
# So the lint enforces against a DECLARED BASELINE: the number of pre-existing
# unallocated sites, written down in SCRATCH_LINT_BASELINE below. More than that
# is a failure. Fewer is a success that prints the new number to write down.
#
# WHAT MAKES THIS HONEST RATHER THAN A SUPPRESSION:
#   * the baseline is ONE NUMBER, visible, with a date on it — not a list of
#     paths nobody rereads;
#   * every baselined site IS COVERED — and the claim changed on 2026-09-18,
#     because the one it replaces was contradicted by a measurement. It used to
#     read "already covered by the reaper's legacy family sweep
#     (SCRATCH_LEGACY_TMP_PATTERNS), so they are swept today", and
#     frank-opus-garbage1 showed that was false for much of it: families like
#     `richos-owned-wake-native-*` were on disk, nine days old, and matched by no
#     declared pattern at all. The coverage is now structural rather than
#     name-based — $TMPDIR and /private/tmp are swept DENY-BY-DEFAULT
#     (SCRATCH_TMP_DENY_BY_DEFAULT), so an unallocated site is collected whatever
#     it is called. What a baselined site still lacks is SPEED: the deny-by-default
#     floor is days, the allocator root is minutes, and a declared legacy family
#     is two hours;
#   * the sites that could actually produce the 105 GB — the four harnesses that
#     COPY A TREE per mutant — were migrated rather than baselined, and their
#     mutation harnesses all still prove every property (12/12, 26/26, 26/26);
#   * the number only goes DOWN. A new bare `mktemp -d` pushes the count over the
#     baseline and fails immediately, which is the property that matters.
#
# The baseline is expected to reach 0. It is a countdown, not a permanent
# allowance.
#
# ===========================================================================
# USAGE
# ===========================================================================
#   scratch-allocation-lint.sh            lint the engine this script is in
#   scratch-allocation-lint.sh --strict   include *.test.sh
#   scratch-allocation-lint.sh --list     list every exemption and its reason
#   scratch-allocation-lint.sh --count    print the finding count and nothing else
#   scratch-allocation-lint.sh --zero     ignore the baseline: fail on ANY finding
#
# EXIT 0 at or under the baseline; 1 over it; 2 the tree could not be read.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="${SCRATCH_LINT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

STRICT=0
LIST=0
COUNT_ONLY=0
ZERO=0
while [ $# -gt 0 ]; do
    case "$1" in
        --strict) STRICT=1 ;;
        --list)   LIST=1 ;;
        --count)  COUNT_ONLY=1 ;;
        --zero)   ZERO=1 ;;
        --help|-h) sed -n '2,100p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)        : ;;
    esac
    shift
done

# SCRATCH_LINT_BASELINE — the number of pre-existing unallocated `mktemp -d`
# sites, MEASURED 2026-09-18 after the four tree-copying harnesses were migrated.
# A COUNTDOWN AND NOT AN ALLOWANCE: it may only ever be lowered. Raising it is
# how a lint becomes decoration, so anything that pushes the count above it fails.
SCRATCH_LINT_BASELINE="${SCRATCH_LINT_BASELINE:-45}"
[ "$ZERO" -eq 1 ] && SCRATCH_LINT_BASELINE=0

[ -d "$ENGINE_ROOT/scripts" ] || {
    echo "scratch-allocation-lint: no scripts/ under $ENGINE_ROOT" >&2
    exit 2
}

FINDINGS=0
EXEMPT=0
SCANNED=0

# The allocator itself, and the reaper that sweeps behind it, are the two files
# allowed to talk about scratch directly. A lint that flagged the mechanism it
# exists to enforce would be its own first false positive.
is_self() {
    case "${1#"$ENGINE_ROOT"/}" in
        scripts/lib/scratch.sh|scripts/lib/scratch.test.sh) return 0 ;;
        scripts/scratch-allocation-lint.sh) return 0 ;;
        scripts/scratch-allocation-lint.test.sh) return 0 ;;
        *) return 1 ;;
    esac
}

while IFS= read -r file; do
    [ -f "$file" ] || continue
    case "$file" in
        *.test.sh) [ "$STRICT" -eq 1 ] || continue ;;
    esac
    is_self "$file" && continue
    SCANNED=$((SCANNED + 1))

    # `mktemp -d` in any flag order: -d, -dt, -d -t, --directory.
    #
    # COMMENT LINES ARE EXCLUDED, and this was the lint's own first false
    # positive: its first run flagged the two files that had just been MIGRATED,
    # because the comments explaining the migration quote the `mktemp -d -t
    # root-mutation.XXXXXX` they replaced. A check that fires on its own
    # documentation is one nobody keeps — and an engine whose convention is to
    # record what a line used to be would trip it constantly.
    hits="$(grep -n 'mktemp[[:space:]]\+\(-[a-zA-Z]*d[a-zA-Z]*\|--directory\)' \
            "$file" 2>/dev/null \
            | grep -v '^[0-9]\+:[[:space:]]*#' || true)"
    [ -n "$hits" ] || continue

    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        lineno="${hit%%:*}"
        # The marker is accepted ON the line or on the line BEFORE it, because a
        # long allocation often wraps and a reviewer reads the two together.
        prev=""
        [ "$lineno" -gt 1 ] 2>/dev/null && \
            prev="$(sed -n "$((lineno - 1))p" "$file" 2>/dev/null || true)"
        marker=""
        case "$hit$prev" in
            *scratch-exempt:*) marker="yes" ;;
        esac
        if [ -n "$marker" ]; then
            reason="$(printf '%s\n%s' "$hit" "$prev" \
                      | sed -n 's/.*scratch-exempt:[[:space:]]*//p' \
                      | head -1 | sed 's/[[:space:]]*$//')"
            # A BARE MARKER EXEMPTS NOTHING. The reason is the whole point of
            # declaring it where a reviewer will see it.
            if [ -z "$reason" ]; then
                FINDINGS=$((FINDINGS + 1))
                {
                    echo "${file#"$ENGINE_ROOT"/}:$lineno — a BARE scratch-exempt marker with no reason."
                    echo "    A marker without a reason exempts nothing. Say why:"
                    echo "        # scratch-exempt: <reason>"
                } >&2
                continue
            fi
            EXEMPT=$((EXEMPT + 1))
            [ "$LIST" -eq 1 ] && \
                printf '  exempt  %s:%s — %s\n' "${file#"$ENGINE_ROOT"/}" "$lineno" "$reason"
            continue
        fi
        FINDINGS=$((FINDINGS + 1))
        {
            echo "${file#"$ENGINE_ROOT"/}:$lineno — a bare \`mktemp -d\`."
            echo "    $(printf '%s' "$hit" | cut -d: -f2- | sed 's/^[[:space:]]*//' | cut -c1-96)"
            echo "    Allocate instead, so the sweeper can find it without being told its name:"
            echo "        . \"\$ENGINE/scripts/lib/scratch.sh\""
            echo "        D=\"\$(scratch_new <label>)\""
            echo "    or, as a command:  D=\"\$(\"\$ENGINE/scripts/lib/scratch.sh\" new <label>)\""
            echo "    If there is a real reason, declare it where a reviewer sees it:"
            echo "        # scratch-exempt: <reason>"
        } >&2
    done <<LINT_HITS_EOF
$hits
LINT_HITS_EOF
done <<EOF
$(find "$ENGINE_ROOT/scripts" -type f -name '*.sh' 2>/dev/null | sort)
EOF

if [ "$COUNT_ONLY" -eq 1 ]; then
    printf '%s\n' "$FINDINGS"
    exit 0
fi

if [ "$FINDINGS" -gt "$SCRATCH_LINT_BASELINE" ] 2>/dev/null; then
    echo >&2
    echo "scratch-allocation-lint: $FINDINGS unallocated scratch directories across $SCANNED script(s), and the declared baseline is $SCRATCH_LINT_BASELINE." >&2
    echo >&2
    echo "  $((FINDINGS - SCRATCH_LINT_BASELINE)) MORE THAN WHEN THE BASELINE WAS SET. The findings above are all of" >&2
    echo "  them; the new one is among them. Allocate it, or declare a reason." >&2
    echo >&2
    echo "On 2026-09-17 a bare \`mktemp -d\` in one harness left 105.3 GB in a single directory, and the reaper — installed, running, and firing either side of it — never considered the path, because its coverage was an allowlist of names and nobody had thought of that one. Allocated scratch needs no name to be predicted." >&2
    exit 1
fi

if [ "$FINDINGS" -gt 0 ]; then
    # Reported on stdout, NOT stderr, and exit 0: this is the baseline being
    # held, which is the normal state until the countdown reaches zero. The
    # findings themselves were printed to stderr above, so the work left to do is
    # visible without the run being a failure.
    echo "scratch-allocation-lint: $FINDINGS unallocated scratch directories across $SCANNED script(s) — AT OR UNDER the declared baseline of $SCRATCH_LINT_BASELINE${EXEMPT:+, plus $EXEMPT declared exemption(s)}."
    if [ "$FINDINGS" -lt "$SCRATCH_LINT_BASELINE" ] 2>/dev/null; then
        echo "  DOWN $((SCRATCH_LINT_BASELINE - FINDINGS)) from the baseline. Lower SCRATCH_LINT_BASELINE to $FINDINGS so the"
        echo "  ground that was gained cannot be given back."
    fi
    echo "  Every one of these IS collected — \$TMPDIR and the shared temp roots are"
    echo "  swept deny-by-default, so a name nobody declared is still a candidate."
    echo "  What they lack is SPEED: the deny-by-default floor is days, a declared"
    echo "  legacy family is two hours, and the allocator root is minutes."
    exit 0
fi

echo "scratch-allocation-lint: clean — $SCANNED script(s) in $ENGINE_ROOT create no unallocated scratch directories${EXEMPT:+, $EXEMPT declared exemption(s)}."
echo "  The baseline is $SCRATCH_LINT_BASELINE and the count is 0: set SCRATCH_LINT_BASELINE to 0 and delete the baseline machinery."
exit 0
