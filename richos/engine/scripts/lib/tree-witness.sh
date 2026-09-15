#!/usr/bin/env bash
#
# scripts/lib/tree-witness.sh — WITNESS A FILE WELL ENOUGH TO PROVE IT WAS NOT
# TOUCHED.
#
# ===========================================================================
# WHY THIS IS A LIBRARY AND NOT THREE COPIES OF FOUR LINES
# ===========================================================================
# Two callers need the same primitive, and it has a trap in it that is easy to
# get wrong in a way that LOOKS RIGHT:
#
#   `stat -f FMT` is an mtime FORMAT STRING on BSD and a FILESYSTEM QUERY on
#   GNU, AND BOTH EXIT 0.
#
# So a probe that checks the exit code accepts `stat -f %Fm` on GNU/Linux,
# gets the same constant filesystem description back for every file, and the
# mtime half of every witness is dead while looking alive. That is this
# project's recurring defect — a check reporting green over something that
# never ran — and it was found on 2026-09-05 in the first version of the leak
# canary in escalations.test.sh, which is where this picker comes from.
#
# THE CANDIDATE IS THEREFORE ACCEPTED ONLY ON WHAT IT DOES, NEVER ON ITS EXIT
# CODE: it must return a NUMBER, and that number must CHANGE when the same
# file is written twice in immediate succession. A second-resolution format
# fails that and is correctly rejected — it could not have distinguished the
# same-second case, which is the only case a content checksum does not already
# cover.
#
# A caller that gets no mtime format still gets a content checksum, and MUST
# say so rather than imply a witness it does not have. tw_mtime_available
# exists for exactly that sentence.
#
# WHAT AN MTIME BUYS THAT A CHECKSUM DOES NOT, stated because it is the whole
# reason for the trouble: a mutation harness that writes a file and writes the
# ORIGINAL BYTES BACK leaves the content identical. Only the mtime shows that
# the file was opened for writing at all. "Restored correctly" and "never
# touched" are different guarantees, and the second is the one that survives a
# `kill -9` landing between the two writes.

TW_MTIME_CMD=""
TW_MTIME_PROBED=0

# tw_pick_mtime [<scratch-dir>] — choose an mtime format and PROVE it moves.
# Sets TW_MTIME_CMD (empty when no format proved itself). Idempotent.
tw_pick_mtime() {
    [ "$TW_MTIME_PROBED" -eq 1 ] && return 0
    TW_MTIME_PROBED=1
    local dir="${1:-${TMPDIR:-/tmp}}" probe c t1 t2
    probe="$dir/.tree-witness-mtime-probe.$$"
    for c in "stat -f %Fm" "stat -c %.9Y"; do
        printf 'a\n' > "$probe" 2>/dev/null || continue
        t1="$($c "$probe" 2>/dev/null)"
        printf 'bb\n' > "$probe" 2>/dev/null
        t2="$($c "$probe" 2>/dev/null)"
        # Must be a bare number (GNU's `-f` answer is prose, and prose here is
        # the failure this whole comment is about) ...
        case "$t1" in ''|*[!0-9.]*) continue ;; esac
        # ... and must MOVE, or it cannot witness a same-second rewrite.
        [ "$t1" != "$t2" ] || continue
        rm -f "$probe"
        TW_MTIME_CMD="$c"
        return 0
    done
    rm -f "$probe"
    return 0
}

# tw_mtime_available — 0 when a sub-second mtime proved itself here.
tw_mtime_available() { [ -n "$TW_MTIME_CMD" ]; }

# tw_file_witness <path> — contents, plus an mtime where one was proven.
# An unreadable or absent file witnesses as `absent`, never as empty: an empty
# witness compares equal to another empty witness, which would make a file
# that VANISHED look like a file that never changed.
tw_file_witness() {
    local p="$1"
    if [ ! -e "$p" ]; then printf 'absent'; return 0; fi
    printf '%s' "$(cksum < "$p" 2>/dev/null || printf 'unreadable')"
    [ -n "$TW_MTIME_CMD" ] && printf ' @%s' "$($TW_MTIME_CMD "$p" 2>/dev/null || printf '?')"
    return 0
}

# tw_witness_list <root> <relative-path>... — one `path<TAB>witness` line per
# argument, on stdout, in the order given.
tw_witness_list() {
    local root="$1"; shift
    local rel
    for rel in "$@"; do
        printf '%s\t%s\n' "$rel" "$(tw_file_witness "$root/$rel")"
    done
}

# tw_witness_tree <root> [<find-args>...] — one line per regular file under
# <root>, sorted, each with its witness. Exits 1 if <root> is unreadable, so an
# unreadable tree can never be mistaken for a tree with nothing in it.
tw_witness_tree() {
    local root="$1"; shift
    [ -d "$root" ] || return 1
    find "$root" -type f "$@" -print 2>/dev/null | LC_ALL=C sort | while IFS= read -r p; do
        printf '%s\t%s\n' "${p#"$root"/}" "$(tw_file_witness "$p")"
    done
    return 0
}
