#!/usr/bin/env bash
#
# scripts/lib/global-state-witness.sh — DID THIS RUN GIVE BACK WHAT IT BORROWED?
#
# ===========================================================================
# WHY THIS FILE EXISTS
# ===========================================================================
# On 2026-09-01 `~/.claude/richos-engine` — the pointer every session and the
# shipped app resolve the engine through — was found dangling at
# `.../scratchpad/g4/red/layerR`: a Layer R red-run fixture, deleted after the
# run that made it. The consequence was MEASURED, not imagined: a double-clicked
# RichOS reported NO COMPUTE LEASE, having attached its lease through that same
# pointer an hour earlier.
#
# The defect was not the dangling link. It was that a test could move a global
# pointer `install.sh` owns and leave it moved, and that NOTHING SAID SO. The
# run reported success. The pointer was wrong for an hour. Nobody was told.
#
#   A RED RUN MUST RESTORE WHAT IT BORROWS, OR MUST NEVER BORROW THE REAL ONE.
#
# install.sh now enforces the second half structurally — it refuses to aim the
# operator's real pointer at an ephemeral checkout. This file is the first half,
# for everything else: a suite snapshots the global state it could touch, and
# says so out loud if it is not the same afterwards.
#
# ===========================================================================
# WHY A WITNESS AND NOT A CLEANUP
# ===========================================================================
# The obvious alternative is to RESTORE the pointer in an EXIT trap. It was
# rejected, and the reason is the one this engine keeps rediscovering: a cleanup
# that runs makes a mutation invisible, and an invisible mutation is how you get
# a suite that quietly depends on borrowing global state. A witness leaves the
# damage visible and names the file — so the fix lands in the test that borrowed,
# not in a trap that hides it.
#
# It is also honest about what it can see. It watches NAMED paths that this
# engine's own scripts write. It is not a filesystem monitor and does not
# pretend to be one; anything not on the list is unwatched, and adding to the
# list is the whole maintenance burden.
#
# ===========================================================================
# WHAT IS WATCHED, AND WHY EACH
# ===========================================================================
#   <config>/richos-engine        THE POINTER. install.sh owns it; every session
#                                 and the shipped app resolve the engine through
#                                 it. This is the one that broke.
#   <config>/settings.json        THE USER-SCOPE REGISTRATION — the file that
#                                 says the engine plugin is enabled at all, and
#                                 the one `engine-status.sh` and the by-reference
#                                 resolution read. Nothing in this engine writes
#                                 it, which is precisely why it is watched: the
#                                 claim "nothing writes it" is worth more as a
#                                 check than as a sentence.
#
# `<config>` is `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` AS IT WAS WHEN THE
# SNAPSHOT WAS TAKEN — deliberately captured, not re-read, because a suite that
# exports CLAUDE_CONFIG_DIR halfway through would otherwise be compared against
# its own sandbox and always pass.
#
# ===========================================================================
# INTERFACE
# ===========================================================================
#   richos_global_snapshot              -> prints an opaque one-line record
#   richos_global_verify "<record>"     -> rc 0 unchanged; rc 1 and a named diff
#                                          on stderr if anything moved
#
# Safe to source repeatedly. Never changes the caller's cwd. Never writes.

if [ -n "${_GLOBAL_STATE_WITNESS_SH_SOURCED:-}" ]; then
    return 0 2>/dev/null || true
fi
_GLOBAL_STATE_WITNESS_SH_SOURCED=1

# The trailing sentinel keeps "absent" and "present but empty" distinguishable
# through command substitution, which strips trailing newlines. Getting that
# wrong would make a DELETED pointer read as unchanged — the failure mode this
# file exists to catch, reproduced inside the catcher.
_gsw_state() { # <path>
    if [ -L "$1" ]; then
        printf 'symlink:%s' "$(readlink "$1" 2>/dev/null)"
    elif [ -f "$1" ]; then
        if command -v shasum >/dev/null 2>&1; then
            printf 'file:%s' "$(shasum -a 256 "$1" 2>/dev/null | awk '{print $1}')"
        else
            printf 'file:%s' "$(wc -c <"$1" 2>/dev/null | tr -d ' ')"
        fi
    elif [ -d "$1" ]; then
        printf 'dir'
    else
        printf 'absent'
    fi
}

richos_global_snapshot() {
    local cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    printf '%s\t%s\t%s\n' "$cfg" \
        "$(_gsw_state "$cfg/richos-engine")" \
        "$(_gsw_state "$cfg/settings.json")"
}

richos_global_verify() { # <record>
    local rec="${1:-}" cfg before_ptr before_set now_ptr now_set rc=0
    [ -n "$rec" ] || { echo "richos_global_verify: no snapshot given — a witness with no 'before' proves nothing" >&2; return 1; }
    cfg="$(printf '%s' "$rec" | cut -f1)"
    before_ptr="$(printf '%s' "$rec" | cut -f2)"
    before_set="$(printf '%s' "$rec" | cut -f3)"
    now_ptr="$(_gsw_state "$cfg/richos-engine")"
    now_set="$(_gsw_state "$cfg/settings.json")"

    if [ "$before_ptr" != "$now_ptr" ]; then
        {
            echo "=== GLOBAL STATE WAS BORROWED AND NOT GIVEN BACK ==="
            echo "  path   : $cfg/richos-engine"
            echo "  before : $before_ptr"
            echo "  after  : $now_ptr"
            echo "  This pointer is how every session and the shipped app find the engine."
            echo "  A run that moves it and leaves it moved is the 2026-09-01 NO COMPUTE"
            echo "  LEASE incident. Borrow a scratch config dir instead — it costs nothing:"
            echo "    CLAUDE_CONFIG_DIR=\$(mktemp -d)"
            echo "===================================================="
        } >&2
        rc=1
    fi
    if [ "$before_set" != "$now_set" ]; then
        {
            echo "=== GLOBAL STATE WAS BORROWED AND NOT GIVEN BACK ==="
            echo "  path   : $cfg/settings.json"
            echo "  before : $before_set"
            echo "  after  : $now_set"
            echo "  This is the user-scope registration that says the engine is enabled at"
            echo "  all. Nothing in this engine writes it. A run that rewrote the operator's"
            echo "  live registration is not a test, it is an incident."
            echo "===================================================="
        } >&2
        rc=1
    fi
    return $rc
}
