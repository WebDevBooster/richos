#!/usr/bin/env bash
#
# scripts/lib/named-persons.sh — the shell half of the named-person deny-list.
#
# The predicate, the match rule, the four surfaces and the honest statement of
# what a hook cannot see all live in scripts/lib/named-persons.py — one place,
# because THREE callers run the identical predicate (the write guard, the
# git/gh command guard, and the release check) and a predicate in three copies
# is the defect class this mechanism exists to end. This file carries only the
# things a shell caller needs: where the list is, whether this repository is
# one that publishes, and how to say the three verdicts out loud.
#
# WHY THE LIST IS NOT IN ANY REPOSITORY
# -------------------------------------
# A roster of the owner's clients, friends and family is worse to publish than
# any single name on it, and the list is exactly that roster. It lives at
# `~/.richos-privacy/named-persons`, operator scope, the same shape as
# `~/.richos-signing/`. named-persons.py REFUSES to load a list that resolves
# inside a git work tree, so "do not commit it" is a structural property rather
# than an instruction somebody remembers.
#
# THE THREE VERDICTS, AND WHY ABSENT IS NOT CLEAN
# -----------------------------------------------
#   CLEAN   nothing matched.
#   FOUND   a listed name is in this artifact. BLOCK.
#   ABSENT  there is no list on this machine. This is NOT "no names to check",
#           it is "nothing was checked", and the two are only the same to a
#           checker that lies. The write-time guards ANNOUNCE it — loudly, by
#           name, once per repository per session — and let the write through,
#           because a stranger who clones this repository has no roster of the
#           owner's acquaintances and must not be blocked by its absence. The
#           RELEASE-time check REFUSES on ABSENT, because a release happens on
#           the owner's machine, where the list must exist.
#   BROKEN  a list that cannot be trusted — inside a repository, unreadable,
#           malformed, or empty. Every caller BLOCKS. A guard that quietly
#           scans a broken list and passes is the "no media committed" check
#           wearing a different hat.
#
# Safe to source repeatedly. Never mutates state, never changes the caller's cwd.

if [ -n "${_NAMED_PERSONS_SH_SOURCED:-}" ]; then
    return 0 2>/dev/null || true
fi
_NAMED_PERSONS_SH_SOURCED=1

_NP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NP_PREDICATE="$_NP_LIB_DIR/named-persons.py"

# ---------------------------------------------------------------------------
# np_list_path
# ---------------------------------------------------------------------------
# One answer, in one place, to "which file is the deny-list?". The env override
# exists for the test suite and for an operator who keeps the roster on an
# encrypted volume; everything else uses the default.
np_list_path() {
    if [ -n "${RICHOS_NAMED_PERSONS_FILE:-}" ]; then
        printf '%s\n' "$RICHOS_NAMED_PERSONS_FILE"
        return 0
    fi
    printf '%s\n' "$HOME/.richos-privacy/named-persons"
}

# ---------------------------------------------------------------------------
# np_publication_bound <repo_root>
# ---------------------------------------------------------------------------
# Does this repository get published? Answered by the SAME declaration the
# publication-boundary guards read — `.publication-boundary`, resolved by
# scripts/lib/declaration-path.sh — and never by a second signal of its own.
# Two answers to one question is how the wrong one stays live.
#
#   rc 0  publication-bound      -> enforce
#   rc 1  not publication-bound  -> stand down silently (the precision floor:
#                                   get this wrong and the guard fires in every
#                                   repository on the machine)
#   rc 2  the declaration is BROKEN -> the caller blocks, with DECL_BROKEN_REASON
np_publication_bound() {
    local root="${1:-}" rc=0
    [ -n "$root" ] || return 1
    if ! command -v decl_find >/dev/null 2>&1; then
        # shellcheck source=./declaration-path.sh
        [ -f "$_NP_LIB_DIR/declaration-path.sh" ] || return 1
        . "$_NP_LIB_DIR/declaration-path.sh"
    fi
    decl_find "$root" ".publication-boundary" || rc=$?
    case "$rc" in
        0) return 0 ;;
        2) return 2 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# np_scan_payload <hook-json-on-stdin>
# ---------------------------------------------------------------------------
# Runs the predicate and echoes its raw output. The caller switches on line 1.
np_scan_payload() {
    python3 "$NP_PREDICATE" --scan-payload 2>/dev/null || printf 'PARSEFAIL\n'
}

# ---------------------------------------------------------------------------
# np_announce_absent <hook> <repo>
# ---------------------------------------------------------------------------
# The loud half of "a missing list is never a silent pass". Once per hook per
# repository per session, via the same stamp mechanism seat-jurisdiction.sh
# uses for its stand-down banners — loud enough to be seen, quiet enough that
# it does not become the noise an operator learns to scroll past.
np_announce_absent() {
    local hook="${1:-<unknown hook>}" repo="${2:-$PWD}" path
    path="$(np_list_path)"
    if command -v _sj_once >/dev/null 2>&1; then
        _sj_once "np-absent|$hook|$repo" || return 0
    fi
    {
        echo "=== NAMED-PERSON DENY-LIST: ABSENT — NOTHING WAS CHECKED ==="
        echo "  hook       : $hook"
        echo "  repository : $repo   (this tree gets PUBLISHED)"
        echo "  expected   : $path"
        echo ""
        echo "  This is NOT 'no names to check'. It is 'no check ran'. A third"
        echo "  party's name reached this repository once already, and he found"
        echo "  it himself, because nothing here looks for a person's name."
        echo ""
        echo "  Create the list — it lives OUTSIDE every repository on purpose:"
        echo "    mkdir -p -m 700 $(dirname "$path")"
        echo "    touch $path && chmod 600 $path"
        echo "    <engine>/scripts/named-persons.sh --mint \"Firstname Lastname\""
        echo "  Then paste the printed line into that file."
        echo ""
        echo "  The release check REFUSES while this file is missing."
        echo "  (said once per hook per repository per session)"
        echo "==========================================================="
    } >&2
    return 0
}

# ---------------------------------------------------------------------------
# np_mask <text>
# ---------------------------------------------------------------------------
# Anything this file is about to ECHO goes through here first.
#
# NOT DEFENSIVENESS — A FIXED DEFECT. The banner below names the artifact it is
# refusing, and the artifact is routinely a FILE PATH. The leak this whole
# mechanism exists for WAS a filename, so the very case the guard is proudest of
# catching is the case whose refusal printed the name in full, into terminal
# scrollback and into whatever log captures stderr. Caught by running the guard
# against the real repository rather than a sandbox.
np_mask() {
    python3 "$NP_PREDICATE" --mask "${1:-}" 2>/dev/null || printf '%s' "${1:-}"
}

# ---------------------------------------------------------------------------
# np_block_banner <hook> <what-was-refused> <predicate-output>
# ---------------------------------------------------------------------------
# The refusal. It names the surface and a REDACTED form of the match, and it
# never prints the name — a block message that repeats the leak is a second
# copy of it in terminal scrollback and in whatever log is capturing stderr.
# That is scan-secrets.sh's rule and it is here for scan-secrets.sh's reason.
np_block_banner() {
    local hook="${1:-<unknown hook>}" what="${2:-this artifact}" result="${3:-}"
    what="$(np_mask "$what")"
    {
        echo "=== NAMED-PERSON DENY-LIST: BLOCKED ==="
        echo "  Refusing $what — it carries a name from the deny-list at"
        echo "  $(np_list_path):"
        printf '%s\n' "$result" | tail -n +2 | while IFS="$(printf '\t')" read -r surface preview; do
            [ -n "$surface" ] || continue
            echo "    - in the $surface (redacted: $preview)"
        done
        echo ""
        echo "  A NAME IS NOT A SECRET AND NEVER TRIPS A SECRET SCANNER, which is"
        echo "  why this check exists separately from scan-secrets.sh. This"
        echo "  repository gets published: a third party found his own name here"
        echo "  hours after it went public, and the commit that scrubbed it put"
        echo "  the same name in the COMMIT MESSAGE, where more people saw it."
        echo ""
        echo "  A scrub covers four surfaces: file content, commit message,"
        echo "  branch name, and PR/issue title. Rewrite this one without the"
        echo "  name — a variable, an environment variable, an initial, or a"
        echo "  synthetic stand-in all work, and the experiment stays"
        echo "  reproducible without publishing whose it was."
        echo ""
        echo "  If the person genuinely should not be on the list, edit"
        echo "  $(np_list_path) — never this repository."
        echo "(hook: $hook)"
    } >&2
}

# ---------------------------------------------------------------------------
# np_broken_banner <hook> <reason>
# ---------------------------------------------------------------------------
np_broken_banner() {
    local hook="${1:-<unknown hook>}" reason="${2:-}"
    {
        echo "=== NAMED-PERSON DENY-LIST: BROKEN — REFUSING ==="
        echo "  $reason"
        echo ""
        echo "  A list that cannot be trusted is not a reason to carry on"
        echo "  quietly. A check that read a broken list and reported clean is"
        echo "  the exact false green this mechanism exists to remove."
        echo "  Run: <engine>/scripts/named-persons.sh --doctor"
        echo "(hook: $hook)"
    } >&2
}
