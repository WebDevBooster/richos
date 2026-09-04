#!/usr/bin/env bash
# WHAT IS INSIDE THE ENGINE ASSET — every member accounted for, against git.
#
#   app/scripts/verify-engine-asset-members.sh <tarball> <repo-root> [<archive-path>=<repo-path> ...]
#
# WHY THIS EXISTS, AND WHY A DETERMINISM CHECK IS NOT ENOUGH
#
# `make-engine-asset.sh` used to copy the engine WORKING TREE into the archive:
#
#     ( cd "$ENGINE_DIR" && tar -cf - . ) | ( cd "$staging/engine" && tar -xf - )
#
# So everything gitignored in `engine/` went to the customer. Measured on main on
# 2026-09-04: 119 ignored files, among them fifteen
# `.claude/state/agent-definitions-*.snapshot` files, each carrying a SESSION UUID, a
# generation timestamp and the operator's absolute home path; 57 `scripts/hooks/*.sha256`
# sidecars that `install.sh` re-mints on every run; and `__pycache__` bytecode. Two separate
# defects wearing one coat:
#
#   1. THE DIGEST MOVED. A new session mints a new snapshot, so the sha256 compiled into the
#      app as `RICHOS_ENGINE_SHA256` was a property of WHEN the build ran. Reproduced: one
#      build, then one new snapshot file, then a second build — 4fcb8b46... became
#      e30083c5.... A customer discovers that as a DigestMismatch.
#   2. A PRIVACY LEAK INTO A PUBLISHED ARTIFACT. Session identifiers and an operator's home
#      directory shipped to everyone who downloads the engine. The 2026-09-04
#      shipped-artifact privacy pass removed exactly this class from the executable; it was
#      arriving through a different door, into a different artifact, and nothing was looking
#      at that door.
#
# THE SECOND DEFECT IS THE ONE THIS FILE IS FOR, because `--check` catches it only by
# accident. `--check` caught this one because the snapshot happened to change between two
# builds. AN IGNORED FILE THAT NEVER CHANGES PASSES A DETERMINISM CHECK FOREVER — proven
# rather than argued: with 205 ignored files planted and then left alone, all thirteen cases
# of `make-engine-asset.test.sh` reported green while 208 untracked members sat in the
# archive. Determinism asks "are the bytes the same twice?". Only this asks "what ARE the
# bytes?".
#
# THE RULE, AND WHY IT IS NOT AN ALLOWLIST
#
# Every regular file and symlink in the archive must be a file git TRACKS. Not "not one of
# the ignored things we thought of" — an allowlist of harmless ignored files is a list that
# drifts from the ignored files that exist, which is the defect this repository has already
# paid for five times. The expected set is `git ls-files`, derived on every run. The next
# ignored artifact somebody invents is excluded because it was never tracked, not because
# anybody remembered it.
#
# THE TWO FILES PACKAGING ADDS. The LICENSE and the third-party notices live at the
# repository root and are copied INTO `engine/` at packaging time, so they are not tracked at
# their archive path. They are declared as `<archive-path>=<repo-path>` pairs, and a pair is
# not a loophole: the repo path must itself be a tracked file, and the archived bytes must be
# byte-identical to it. Nothing untracked can be smuggled in through a pair.
#
# Exit 0 and it prints a count. Exit 1 and it names every member it refused.
set -uo pipefail

die() { echo "REFUSING — $*" >&2; exit 1; }

TARBALL="${1:-}"
REPO_ROOT="${2:-}"
[ -n "$TARBALL" ] && [ -n "$REPO_ROOT" ] || {
    echo "usage: $0 <tarball> <repo-root> [<archive-path>=<repo-path> ...]" >&2; exit 2; }
shift 2

[ -s "$TARBALL" ] || die "no archive at $TARBALL"
REPO_ROOT="$(cd "$REPO_ROOT" 2>/dev/null && pwd)" || die "no repository at $REPO_ROOT"
ENGINE_DIR="$REPO_ROOT/engine"
[ -d "$ENGINE_DIR" ] || die "no engine directory at $ENGINE_DIR"

git -C "$ENGINE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "$ENGINE_DIR is not inside a git checkout, so there is no tracked set to check against"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/engine-asset-members.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------------------
# EXPECTED — what git tracks, plus the declared packaging additions
# ---------------------------------------------------------------------------------------
# `-z` throughout, so a path with a space or a non-ASCII character is read as itself rather
# than as git's quoted rendering of itself. A path containing a NEWLINE would still defeat
# the line-oriented comparison below, so that one case is refused by name instead of being
# silently mis-compared.
git -C "$ENGINE_DIR" ls-files -z > "$WORK/tracked.z" || die "git ls-files failed under $ENGINE_DIR"
[ -s "$WORK/tracked.z" ] \
    || die "git tracks NOTHING under $ENGINE_DIR — refusing to check an archive against an empty expectation"

tr '\0' '\n' < "$WORK/tracked.z" | LC_ALL=C sort > "$WORK/expected"
NUL_COUNT="$(tr -dc '\0' < "$WORK/tracked.z" | wc -c | tr -d ' ')"
LINE_COUNT="$(wc -l < "$WORK/expected" | tr -d ' ')"
[ "$NUL_COUNT" = "$LINE_COUNT" ] \
    || die "a tracked path under engine/ contains a newline; this check cannot compare it honestly"

PAIRS=""
for pair in "$@"; do
    case "$pair" in
        *=*) ;;
        *) die "packaging addition '$pair' is not <archive-path>=<repo-path>" ;;
    esac
    a="${pair%%=*}"; r="${pair#*=}"
    [ -n "$a" ] && [ -n "$r" ] || die "packaging addition '$pair' has an empty half"
    git -C "$REPO_ROOT" ls-files --error-unmatch -- "$r" >/dev/null 2>&1 \
        || die "packaging adds engine/$a from $r, which git does NOT track — a packaging addition may only be a tracked file"
    printf '%s\n' "$a" >> "$WORK/expected"
    PAIRS="$PAIRS $pair"
done
LC_ALL=C sort -u "$WORK/expected" -o "$WORK/expected"

# ---------------------------------------------------------------------------------------
# ACTUAL — what is in the archive, read out of the archive
# ---------------------------------------------------------------------------------------
mkdir -p "$WORK/x"
/usr/bin/tar -x -z --no-same-owner -f "$TARBALL" -C "$WORK/x" || die "the archive does not open"

# NOTHING OUTSIDE engine/. An archive that unpacks a second top-level directory is not the
# asset this repository publishes, whatever else is true of its members.
STRAY_TOP="$( ( cd "$WORK/x" && ls -A ) | grep -v '^engine$' | tr '\n' ' ' )"
[ -z "$STRAY_TOP" ] || die "the archive has top-level entries outside engine/: $STRAY_TOP"
[ -d "$WORK/x/engine" ] || die "the archive has no engine/ directory"

# ONLY directories, regular files and symlinks. A fifo or a device node in a release asset is
# not something to discover on a customer's Mac.
ALL_N="$(find "$WORK/x/engine" | wc -l | tr -d ' ')"
DIR_N="$(find "$WORK/x/engine" -type d | wc -l | tr -d ' ')"
( cd "$WORK/x/engine" && find . \( -type f -o -type l \) -print ) | sed 's|^\./||' | LC_ALL=C sort > "$WORK/actual"
ACT_N="$(wc -l < "$WORK/actual" | tr -d ' ')"
[ "$ALL_N" = "$((DIR_N + ACT_N))" ] \
    || die "the archive holds $((ALL_N - DIR_N - ACT_N)) member(s) that are neither a directory, a regular file nor a symlink"

# ---------------------------------------------------------------------------------------
# THE COMPARISON, BOTH DIRECTIONS
# ---------------------------------------------------------------------------------------
# EXTRA is the leak: a member git does not track. MISSING is its mirror: a tracked file that
# packaging dropped. A future exclusion filter that dropped half the engine would exit 0
# against the leak check alone, so both directions are refused.
LC_ALL=C comm -13 "$WORK/expected" "$WORK/actual" > "$WORK/extra"
LC_ALL=C comm -23 "$WORK/expected" "$WORK/actual" > "$WORK/missing"

EXTRA_N="$(wc -l < "$WORK/extra" | tr -d ' ')"
MISSING_N="$(wc -l < "$WORK/missing" | tr -d ' ')"

if [ "$EXTRA_N" -ne 0 ]; then
    echo "REFUSING — the archive carries $EXTRA_N member(s) that git does not track. This is the" >&2
    echo "           file a stranger downloads, so an untracked member here is an operator's own" >&2
    echo "           disk being published. Every one of them, by name:" >&2
    sed 's|^|             engine/|' "$WORK/extra" >&2
    exit 1
fi

if [ "$MISSING_N" -ne 0 ]; then
    echo "REFUSING — packaging DROPPED $MISSING_N tracked file(s) that exist under engine/:" >&2
    sed 's|^|             engine/|' "$WORK/missing" >&2
    exit 1
fi

# THE PACKAGED PAIRS, BYTE FOR BYTE, read out of the finished archive. `cp` having exited 0
# during the build is a claim about a command; these bytes are the artifact.
for pair in $PAIRS; do
    a="${pair%%=*}"; r="${pair#*=}"
    want="$(/usr/bin/shasum -a 256 "$REPO_ROOT/$r" | awk '{print $1}')"
    got="$(/usr/bin/shasum -a 256 "$WORK/x/engine/$a" 2>/dev/null | awk '{print $1}')"
    [ -n "$got" ] || die "the archive has no engine/$a"
    [ "$want" = "$got" ] || die "engine/$a in the archive is NOT $r ($got vs $want)"
done

echo "  members             $ACT_N file(s)/symlink(s) in $DIR_N director(ies)"
echo "  tracked by git      $LINE_COUNT, all present, none extra"
echo "  packaged in        ${PAIRS:- none}, byte-identical to their tracked sources"
echo "  untracked members   0"
