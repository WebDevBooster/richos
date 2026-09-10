#!/usr/bin/env bash
#
# ci-affected-units.sh — the verification units a DIFF can affect.
#
# ===========================================================================
# WHY THIS EXISTS: THE PROBLEM IS INFLOW, NOT PORTABILITY
# ===========================================================================
# Measured on 2026-09-09: 101 of this engine's 120 suites were created in the
# previous twelve days, 35 of them on one day. About eight suites land per day
# that have never run on Linux. Fixing today's red list therefore buys one green
# run, and next week's arrivals break it again — the full pass is the wrong
# instrument for that, because it takes 123 minutes and so it runs once a week
# at best, long after the author has moved on.
#
# The instrument that matches inflow is this one: a check, on every push, that
# runs the suites THIS DIFF can affect, on Linux, in a couple of minutes. A new
# suite gets its first Linux execution the day it lands, by its author, while
# they still have the context to fix it. Nothing accumulates.
#
# ===========================================================================
# THE MAPPING, AND THE MEASUREMENT THAT SAYS IT IS ENOUGH
# ===========================================================================
# For each changed path, in order:
#
#   1. THE PATH IS ITSELF A SUITE  -> its own unit(s).
#   2. A SIBLING SUITE EXISTS      -> `<stem>.test.sh` beside it.
#   3. A SUITE NAMES ITS BASENAME  -> `grep -lF <basename>` across every suite.
#      This is the load-bearing rule, and it was verified before being relied
#      on rather than assumed: all 96 files under `scripts/hooks/` are named by
#      at least one suite (`ci-affected-units.test.sh` case A5 re-derives that
#      and fails if it ever stops being true).
#   4. THE SECTIONED SUITE NAMES IT -> only the SECTIONS whose own bodies
#      mention it, not all 24. A one-line change to one guard costs that
#      guard's section, which is the whole reason `--only` exists.
#
# ===========================================================================
# AN UNMAPPED EXECUTABLE IS A FAILURE, AND THAT IS THE POINT
# ===========================================================================
# The dangerous case is not a changed file that maps to too much. It is a
# changed file that maps to NOTHING, because then this check exits 0 having run
# nothing and the push is certified by an empty set — the "18/18 suites" defect
# with a diff filter bolted on.
#
# So a changed file that is EXECUTABLE MACHINERY (`.sh`, `.py`, or anything with
# a shebang, under the engine) and that no suite names is reported by
# `--strict` as a failure, naming the file. The remedy is the engine's own
# doctrine and is never "add it to a list here": give it a suite, or make an
# existing suite name it. Prose, data and documentation map to nothing by
# design and are reported as such without failing.
#
# Usage:
#   ci-affected-units.sh --range <base>..<head>   compare two commits
#   ci-affected-units.sh --base <ref>             <ref>..HEAD
#   ci-affected-units.sh --paths-file <path>      one changed path per line
#   ci-affected-units.sh --paths <p>[,<p>…]       changed paths inline
#   options: --strict   unmapped executable machinery FAILS (exit 1)
#            --explain  print the mapping, path by path, to stderr
#
# Output: one unit id per line on stdout, LC_ALL=C sorted and unique. Empty
# output with exit 0 means "this diff can affect no suite", which is a real
# answer for a docs-only change and is announced on stderr.
#
# Exit codes:
#   0  the mapping succeeded (the unit list may legitimately be empty)
#   1  --strict, and a changed executable maps to no suite (each one named)
#   2  usage, or the diff could not be read
# ===========================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(git -C "$ENGINE_ROOT" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$ENGINE_ROOT")"
UNITS_SH="$SCRIPT_DIR/ci-units.sh"
SECTIONED_SUITE="scripts/hooks/contract-integrity.test.sh"

die() { echo "ERROR: ci-affected-units.sh: $1" >&2; exit "${2:-2}"; }

RANGE=""; BASE=""; PATHS_FILE=""; PATHS_INLINE=""; STRICT=0; EXPLAIN=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --range) [ "$#" -ge 2 ] || die "--range needs <base>..<head>"; RANGE="$2"; shift 2 ;;
        --base)  [ "$#" -ge 2 ] || die "--base needs a ref"; BASE="$2"; shift 2 ;;
        --paths-file) [ "$#" -ge 2 ] || die "--paths-file needs a path"; PATHS_FILE="$2"; shift 2 ;;
        --paths) [ "$#" -ge 2 ] || die "--paths needs a comma-separated list"; PATHS_INLINE="$PATHS_INLINE,$2"; shift 2 ;;
        --strict) STRICT=1; shift ;;
        --explain) EXPLAIN=1; shift ;;
        -h|--help) sed -n '/^# Usage:/,/^# =\{10,\}$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unrecognized argument '$1' — see --help" ;;
    esac
done

# --- the changed paths, repository-relative --------------------------------
CHANGED="$(mktemp)"; SUITES="$(mktemp)"; UNITS="$(mktemp)"; UNMAPPED="$(mktemp)"
trap 'rm -f "$CHANGED" "$SUITES" "$UNITS" "$UNMAPPED"' EXIT

if [ -n "$PATHS_FILE" ]; then
    [ -f "$PATHS_FILE" ] || die "--paths-file: no such file: $PATHS_FILE"
    cat "$PATHS_FILE" > "$CHANGED"
elif [ -n "$PATHS_INLINE" ]; then
    printf '%s\n' "${PATHS_INLINE#,}" | tr ',' '\n' > "$CHANGED"
else
    [ -n "$RANGE" ] || RANGE="${BASE:-HEAD^}..HEAD"
    git -C "$REPO_ROOT" diff --name-only "$RANGE" > "$CHANGED" 2>/dev/null \
        || die "could not read the diff for '$RANGE'. On a shallow clone, fetch the base commit first."
fi
# NOT `sed -i`: the BSD and GNU spellings of in-place editing differ, and that
# difference has already cost this tree a whole CI run (see the sed -i '' note
# in .github/workflows/engine-self-verify.yml). A pipe through a temp file is
# the same edit and is the same on every host.
_TRIMMED="$(mktemp)"
sed 's/^[[:space:]]*//; s/[[:space:]]*$//' "$CHANGED" > "$_TRIMMED" 2>/dev/null || cp "$CHANGED" "$_TRIMMED"
mv "$_TRIMMED" "$CHANGED"

# Every discovered suite, once, so the greps below read from a list rather than
# re-walking the tree per changed file.
bash "$UNITS_SH" suites > "$SUITES" || die "ci-units.sh could not enumerate the suites"

# Section bodies of the sectioned suite, as "<section><TAB><line>", so rule 4
# can ask which section mentions a name.
SECTION_BODIES="$(mktemp)"; trap 'rm -f "$CHANGED" "$SUITES" "$UNITS" "$UNMAPPED" "$SECTION_BODIES"' EXIT
if [ -f "$ENGINE_ROOT/$SECTIONED_SUITE" ]; then
    awk '
        /^if _section [A-Za-z0-9_.-]+; then$/ { cur=$3; sub(/;$/, "", cur); next }
        /^fi  # _section/ { cur=""; next }
        cur != "" { print cur "\t" $0 }
    ' "$ENGINE_ROOT/$SECTIONED_SUITE" > "$SECTION_BODIES"
fi

add_suite_units() { # <engine-relative suite path> <the path that caused it>
    local suite="$1" why="$2" sec
    if [ "$suite" = "$SECTIONED_SUITE" ]; then
        # Rule 4: only the sections that actually mention the changed name.
        local hits=0
        while IFS= read -r sec; do
            [ -n "$sec" ] || continue
            hits=1
            printf '%s:%s\n' "$suite" "$sec" >> "$UNITS"
            [ "$EXPLAIN" -eq 1 ] && printf '    %s -> %s:%s\n' "$why" "$suite" "$sec" >&2
        done < <(awk -F'\t' -v pat="$(basename "$why")" 'index($2, pat) { print $1 }' "$SECTION_BODIES" | LC_ALL=C sort -u)
        if [ "$hits" -eq 0 ]; then
            # The suite names it outside every section (its preamble or its
            # helpers), so which section is affected is unknown — and guessing
            # would be a scoped run pretending to be a targeted one. Take all
            # of them.
            while IFS= read -r sec; do
                [ -n "$sec" ] || continue
                printf '%s:%s\n' "$suite" "$sec" >> "$UNITS"
            done < <(cut -f1 "$SECTION_BODIES" | LC_ALL=C sort -u)
            [ "$EXPLAIN" -eq 1 ] && printf '    %s -> %s (ALL sections: named outside any section body)\n' "$why" "$suite" >&2
        fi
    else
        printf '%s\n' "$suite" >> "$UNITS"
        [ "$EXPLAIN" -eq 1 ] && printf '    %s -> %s\n' "$why" "$suite" >&2
    fi
}

is_executable_machinery() { # <repo-relative path>
    local p="$1" abs="$REPO_ROOT/$1"
    case "$p" in
        *.sh|*.py|*.bash) return 0 ;;
    esac
    [ -f "$abs" ] || return 1
    head -c 2 "$abs" 2>/dev/null | grep -q '^#!' && return 0
    return 1
}

N_CHANGED=0
while IFS= read -r p; do
    [ -n "$p" ] || continue
    N_CHANGED=$((N_CHANGED + 1))
    [ "$EXPLAIN" -eq 1 ] && printf '  %s\n' "$p" >&2

    # Only the engine's own tree is verified by these suites. A change to app/
    # or tools/ has its own workflows and is not this gate's business.
    case "$p" in
        engine/*) ;;
        *) [ "$EXPLAIN" -eq 1 ] && printf '    (outside engine/ — not this gate)\n' >&2; continue ;;
    esac
    REL="${p#engine/}"
    BASENAME="$(basename "$REL")"
    MATCHED=0

    # 1. the path IS a suite
    if grep -qxF "$REL" "$SUITES"; then
        add_suite_units "$REL" "$p"; MATCHED=1
    fi

    # 2. a sibling suite
    STEM="${REL%.*}"
    for cand in "$STEM.test.sh" "$REL.test.sh"; do
        if grep -qxF "$cand" "$SUITES"; then
            add_suite_units "$cand" "$p"; MATCHED=1
        fi
    done

    # 3. any suite that names the basename. -F because a basename contains dots
    # and a regex read of it would match more than the file.
    while IFS= read -r suite; do
        [ -n "$suite" ] || continue
        add_suite_units "$suite" "$p"; MATCHED=1
    done < <(
        while IFS= read -r s; do
            [ -n "$s" ] || continue
            if grep -qlF -- "$BASENAME" "$ENGINE_ROOT/$s" 2>/dev/null; then printf '%s\n' "$s"; fi
        done < "$SUITES"
    )

    if [ "$MATCHED" -eq 0 ]; then
        if is_executable_machinery "$p"; then
            printf '%s\n' "$p" >> "$UNMAPPED"
            [ "$EXPLAIN" -eq 1 ] && printf '    NO SUITE NAMES IT (executable machinery)\n' >&2
        else
            [ "$EXPLAIN" -eq 1 ] && printf '    no suite names it (prose or data — by design)\n' >&2
        fi
    fi
done < "$CHANGED"

LC_ALL=C sort -u "$UNITS" | grep -v '^$' || true

N_UNITS="$(LC_ALL=C sort -u "$UNITS" | grep -c . || true)"
printf '%s changed path(s) -> %s unit(s)\n' "$N_CHANGED" "${N_UNITS:-0}" >&2
if [ "${N_UNITS:-0}" -eq 0 ]; then
    printf 'NOTHING TO RUN: this diff touches no file any suite names. For a docs-only change that is\n' >&2
    printf 'the correct answer, and it is printed rather than left implicit.\n' >&2
fi

if [ -s "$UNMAPPED" ]; then
    printf '\n%s changed executable file(s) are named by NO suite:\n' "$(grep -c . "$UNMAPPED")" >&2
    sed 's/^/    /' "$UNMAPPED" >&2
    printf '  Every guard in this engine is named by at least one suite, and that is what lets a diff\n' >&2
    printf '  select what to verify. Give this file a suite, or make an existing suite name it.\n' >&2
    printf '  Do NOT add it to an exclusion list here: the list would be the untested surface.\n' >&2
    [ "$STRICT" -eq 1 ] && exit 1
fi
exit 0
