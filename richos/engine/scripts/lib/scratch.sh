#!/usr/bin/env bash
#
# scripts/lib/scratch.sh — ONE SCRATCH ROOT, ONE ALLOCATOR, ONE LEDGER.
#
# ===========================================================================
# THE NIGHT THIS EXISTS FOR
# ===========================================================================
# 2026-09-17 22:39. `scripts/hooks/root-contract.mutation.sh` allocated a
# sandbox with a bare `mktemp -d -t root-mutation.XXXXXX`, copied the engine
# into it four times, and was killed (exit 144) before its EXIT trap could
# fire. By the next morning that ONE directory held 105.3 GB and $TMPDIR held
# 114.5 GB in 88,829 entries. The Data volume had 49 GB free; the previous
# morning it had about 170 GB. A person deleted it by hand.
#
# THE SCRATCH REAPER WAS ALREADY INSTALLED AND ALREADY RUNNING. It fired at
# 21:40 (before the sandbox) and at 03:40 (five hours after it) and freed
# 156 KB, and the string "root-mutation" appears nowhere in its log, on any
# run, ever. It never considered the directory at all — because
# SCRATCH_TMP_PATTERNS was an ALLOWLIST of two globs, and a sandbox named by
# a bare mktemp matched neither.
#
# THAT IS THE DEFECT THIS FILE CLOSES, AND IT IS NOT "the harness forgot to
# clean up". A cleanup that depends on the maker remembering is a cleanup that
# is absent exactly when the maker dies, which is the only moment it was ever
# needed. An allowlist of names is the same bet in a different costume: it
# works until somebody allocates under a name nobody predicted, and predicting
# names is not a thing anyone can do.
#
# So: scratch does not get NAMED, it gets ALLOCATED. Every scratch location the
# engine creates comes from here, lands under ONE root, and is written down in
# ONE ledger with its owner's pid on it. The sweeper then needs to predict
# nothing — it reads the ledger, asks the process table who is still alive, and
# deletes what nobody owns. An allocation nobody recorded is still swept,
# because the ROOT is swept deny-by-default: a directory under the root with no
# ledger row is garbage by construction, since the only way to get a directory
# under the root is to ask for one here.
#
# ===========================================================================
# USAGE
# ===========================================================================
# As a command (prints the path on stdout, and NOTHING else — it is meant to be
# captured):
#
#     D="$("$ENGINE/scripts/lib/scratch.sh" new mutation)"
#     D="$("$ENGINE/scripts/lib/scratch.sh" new mutation --ttl 240)"
#     "$ENGINE/scripts/lib/scratch.sh" release "$D"
#     "$ENGINE/scripts/lib/scratch.sh" root          # print the root
#     "$ENGINE/scripts/lib/scratch.sh" ledger        # print the ledger path
#
# Sourced (the form a harness wants, because it also gets scratch_release):
#
#     . "$ENGINE/scripts/lib/scratch.sh"
#     D="$(scratch_new mutation)"
#     trap 'scratch_release "$D"' EXIT      # an OPTIMIZATION, never the mechanism
#
# THE TRAP IS AN OPTIMIZATION AND THE COMMENT SAYING SO IS LOAD-BEARING. It
# returns the space sooner on the happy path. It is not what guarantees the
# space comes back, because `trap ... EXIT` does not survive `kill -9`, an OOM
# kill, a power loss, or a terminal that goes away — and the 105 GB night was
# precisely a process that did not exit normally. What guarantees the space
# comes back is the sweeper, which needs nothing of the maker except that the
# maker allocated here.
#
# ===========================================================================
# WHY THE PID IS IN THE DIRECTORY NAME AS WELL AS IN THE LEDGER
# ===========================================================================
# Two records of the same fact, deliberately, because they fail differently.
# The ledger is rich (label, session, TTL, creation time) and is a file that
# can be truncated, lost with $HOME, or not yet flushed when the machine dies.
# The name is poor but it is ON the thing itself and cannot be separated from
# it. A sweeper that has lost the ledger entirely can still read `4815-` off
# the front of a directory and ask whether pid 4815 is alive. Neither is
# trusted alone: a pid is reused, so a live pid only ever means KEEP, never
# DELETE, and the age floor covers the reuse window.

# ---------------------------------------------------------------------------
# where things are
# ---------------------------------------------------------------------------

# The root lives under $TMPDIR because that is where the garbage was and
# because $TMPDIR is per-user on macOS. `richos-scratch` is a fixed name and
# not a pattern: the sweeper matches it exactly, so there is no glob to widen
# and nothing to predict. If $TMPDIR is unset, /tmp — the same fallback
# scratch-reaper.py uses, so the two agree about where to look.
scratch_root() {
    local base="${TMPDIR:-/tmp}"
    printf '%s/richos-scratch\n' "${base%/}"
}

# The ledger is machine-wide and OUTSIDE every repository, every worktree and
# every session directory — the same placement, for the same reason, as the
# escalation ledger and the worktree ledger. A record of what to delete that
# lived inside the thing being deleted would be the first casualty.
scratch_ledger() {
    local base="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    printf '%s/state/scratch-ledger.jsonl\n' "${base%/}"
}

# ---------------------------------------------------------------------------
# allocating
# ---------------------------------------------------------------------------

# scratch_new <label> [--ttl <minutes>]
#
# Prints the absolute, symlink-resolved path of a fresh directory. The label is
# free text from the caller and is slugified rather than validated: a label is
# for a HUMAN reading the sweeper's log at 3 AM trying to work out what made a
# 50 GB directory, so an awkward label must still produce a usable name instead
# of an error nobody sees.
scratch_new() {
    local label="${1:-scratch}"
    shift 2>/dev/null || true
    local ttl="${SCRATCH_DEFAULT_TTL_MINUTES:-360}"
    while [ $# -gt 0 ]; do
        case "$1" in
            --ttl) ttl="${2:-$ttl}"; shift 2 ;;
            *)     shift ;;
        esac
    done

    # Slugify: anything that is not a letter, a digit or a dash becomes a dash,
    # and runs collapse. Keeps the name a single path component whatever the
    # caller passed, which matters because the sweeper parses this name.
    label="$(printf '%s' "$label" | LC_ALL=C tr -c 'A-Za-z0-9-' '-' \
             | LC_ALL=C sed -E 's/-+/-/g; s/^-//; s/-$//')"
    [ -n "$label" ] || label="scratch"

    local root; root="$(scratch_root)"
    if ! mkdir -p "$root" 2>/dev/null; then
        echo "scratch: cannot create the scratch root at $root" >&2
        return 1
    fi
    # 0700: scratch regularly holds a copy of the engine, and on a shared host
    # that is somebody else's read. The root is created by whoever gets there
    # first, so the mode is set every time rather than only at creation.
    chmod 700 "$root" 2>/dev/null || true

    # <pid>-<label>-<random>. The pid leads because that is the field the
    # sweeper reads when it has nothing else, and a leading fixed-width-ish
    # number also sorts a directory listing into allocation order for a human.
    local dir=""
    local n=0
    while [ "$n" -lt 8 ]; do
        local rand
        rand="$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 8 || true)"
        [ -n "$rand" ] || rand="$$$n$(date +%s 2>/dev/null || true)"
        local cand="$root/$$-$label-$rand"
        # mkdir, not `-p`, and the failure is the point: mkdir is atomic, so
        # two concurrent allocators racing on the same name cannot both win.
        # Sixteen mutants allocating at once is the normal case here.
        if mkdir "$cand" 2>/dev/null; then
            dir="$cand"
            break
        fi
        n=$((n + 1))
    done
    if [ -z "$dir" ]; then
        echo "scratch: could not allocate a directory under $root after 8 tries" >&2
        return 1
    fi
    chmod 700 "$dir" 2>/dev/null || true

    _scratch_record "$dir" "$label" "$ttl"
    # `cd`+`pwd -P` rather than realpath: on macOS $TMPDIR is /var/folders/...
    # which is a symlink to /private/var/folders/..., and the sweeper resolves
    # its root the same way. Two spellings of one directory is how a containment
    # wall gets talked past.
    ( cd "$dir" && pwd -P )
}

# _scratch_record <dir> <label> <ttl-minutes>
#
# One JSON object, one line, appended. Hand-rolled rather than via python3
# because this runs in the allocation path of every harness in the engine and
# paying an interpreter start per mutant is a real cost at 526 mutants. The
# fields are all machine-generated (a slug, a pid, a number, an ISO stamp) with
# one exception — the session id — which is quoted through a JSON escaper.
_scratch_record() {
    local dir="$1" label="$2" ttl="$3"
    local ledger; ledger="$(scratch_ledger)"
    mkdir -p "$(dirname "$ledger")" 2>/dev/null || return 0

    local sid="${CLAUDE_SESSION_ID:-}"
    sid="$(printf '%s' "$sid" | LC_ALL=C sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/[[:cntrl:]]//g')"
    local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # A LEDGER WRITE THAT FAILS IS NEVER FATAL TO THE ALLOCATION. The caller
    # gets its directory either way, and the directory is still swept, because
    # the root is deny-by-default and an unledgered directory under it is
    # garbage by construction. Making this fatal would mean a full disk or a
    # read-only $HOME could stop a harness from running at all — turning a
    # cleanup mechanism into an availability risk, which is how cleanup
    # mechanisms get switched off.
    printf '{"path":"%s","label":"%s","pid":%d,"ppid":%d,"session":"%s","created":"%s","ttl_minutes":%s,"event":"new"}\n' \
        "$dir" "$label" "$$" "${PPID:-0}" "$sid" "$now" "$ttl" \
        >>"$ledger" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# releasing
# ---------------------------------------------------------------------------

# scratch_release <dir> — delete it now and say so in the ledger.
#
# REFUSES ANYTHING OUTSIDE THE ROOT, and that is not a formality. This function
# is called from `trap ... EXIT` handlers where the variable holding the path
# may be empty or unset because the allocation itself failed — and
# `rm -rf "$D"` with an empty D has removed people's home directories. The
# containment check turns the whole class into a refusal.
scratch_release() {
    local dir="${1:-}"
    [ -n "$dir" ] || return 0
    local root; root="$(scratch_root)"
    local rroot; rroot="$( cd "$root" 2>/dev/null && pwd -P || printf '%s' "$root" )"
    local rdir; rdir="$( cd "$dir" 2>/dev/null && pwd -P || printf '%s' "$dir" )"
    case "$rdir" in
        "$rroot"/?*) : ;;
        *)
            echo "scratch: refusing to release $dir — it is not under $rroot" >&2
            return 1 ;;
    esac
    [ -e "$rdir" ] || return 0
    rm -rf "$rdir" 2>/dev/null || {
        echo "scratch: could not remove $rdir" >&2
        return 1
    }
    local ledger; ledger="$(scratch_ledger)"
    local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"path":"%s","pid":%d,"released":"%s","event":"release"}\n' \
        "$rdir" "$$" "$now" >>"$ledger" 2>/dev/null || true
    return 0
}

# ---------------------------------------------------------------------------
# the command form
# ---------------------------------------------------------------------------
# Only when EXECUTED, never when sourced — a sourced file that ran a command
# parser against the caller's "$@" would react to the caller's arguments.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    set -uo pipefail
    _cmd="${1:-}"
    shift 2>/dev/null || true
    case "$_cmd" in
        new)     scratch_new "$@" ;;
        release) scratch_release "$@" ;;
        root)    scratch_root ;;
        ledger)  scratch_ledger ;;
        ""|--help|-h)
            sed -n '2,70p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            ;;
        *)
            echo "scratch: unknown command '$_cmd' (new|release|root|ledger)" >&2
            exit 2 ;;
    esac
fi
