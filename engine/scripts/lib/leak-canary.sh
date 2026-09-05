#!/usr/bin/env bash
#
# scripts/lib/leak-canary.sh — DID THIS RUN WRITE SOMEWHERE IT SHOULD NOT HAVE?
#
# ===========================================================================
# WHERE THIS CAME FROM
# ===========================================================================
# escalations.test.sh grew a canary on 2026-09-05, after one of its fixtures
# was found as an untracked file in a working engineer's tree, reading exactly
# like a live escalation. He could not tell it from a real one and spent part
# of a handoff explaining a file he had not written. The cause was one argument
# away from a fix already in the file: the suite redirected the LEDGER into its
# sandbox, and a SECOND output followed the working directory.
#
# That canary was deliberately left per-suite, its author calling generalization
# "the better structural answer" but a widening he had not been asked for. This
# is the generalization, and the loop it protects is bigger than one suite: on
# the same day, TWO mutation harnesses were found mutating the SHIPPED guards in
# place — guard-worktree-isolation.sh among them, the spawn gate — and putting
# them back with `trap ... EXIT`. An EXIT trap does not survive `kill -9`.
#
# So there are two different findings, and they are NOT the same severity:
#
#   A TRACKED FILE UNDER THE ENGINE CHANGED DURING THE RUN. This is the worse
#   one, and it is not primarily about residue. It means the suites that ran
#   BEFORE the change and the suites that ran AFTER it tested DIFFERENT CODE.
#   The fraction at the bottom of the run is then a green tick over an
#   inventory that never existed in one state. Reporting that as a pass is the
#   engine's own founding defect.
#
#   AN UNTRACKED FILE APPEARED. This is the escalations shape: a suite wrote
#   outside its sandbox and left a stranger something to explain.
#
# ===========================================================================
# WHAT IT WATCHES, AND WHAT IT DOES NOT — stated, because a canary that
# overstates its reach is a lie in the other direction
# ===========================================================================
#   - It compares `git status --porcelain --untracked-files=all` before and
#     after, per watched root, with a CONTENT WITNESS on every untracked file.
#   - It is therefore BLIND TO GITIGNORED PATHS. Build output and state dirs
#     churning under another agent cannot turn it red; the cost is that a leak
#     into an ignored path is missed. Such a leak is also invisible to the
#     engineer this protects, which is the trade.
#   - It is INSENSITIVE TO A MERGE LANDING ON main DURING THE RUN, and that is
#     deliberate rather than lucky. A merge rewrites files and moves HEAD
#     together, so `git status` stays clean across it. A canary that hashed
#     file CONTENTS instead would go red on every land — measured, and the
#     reason this witnesses status rather than bytes.
#   - It does NOT watch the rest of the filesystem or $HOME.
#
# THE WITNESS IS CONTENTS, NOT PATHS. The first version of the escalations
# canary compared paths only and reported CLEAN on the second consecutive
# leaking run, because the residue was already in its baseline and the leak
# overwrote it in place. A canary that only catches the first occurrence goes
# quiet exactly when residue proves it is needed.
#
# A ROOT IT CANNOT READ IS A FAILURE, NEVER A QUIET PASS. An unreadable root
# yields an empty snapshot both times and so an empty diff, which is "green
# over something that never ran" wearing a clean sheet. LC_HEALTHY carries it.
#
# ITS FALSE-POSITIVE VECTOR, named so nobody rediscovers it: somebody editing
# a non-ignored file in the same checkout while the run is in flight. MEASURED
# 2026-09-05 on this machine, 10-second sampling with 68 agents live:
# the shared main checkout was 0% red over every window tried, because agents
# work in worktrees and only the lander touches it; an engineer's OWN worktree
# while he was actively editing it was 100% red at a 7-minute window. So the
# noise is self-inflicted and self-explaining — the report names the file, and
# the engineer recognizes his own save — and it is NOT the "another agent
# broke my run" flakiness the widening was feared for.

LC_ROOTS=""
LC_HEALTHY=1
LC_MAX_ENTRIES=2000

# lc_reset — start a fresh canary (roots, health). Callers that watch more than
# one set of roots in one process need this between them.
lc_reset() { LC_ROOTS=""; LC_HEALTHY=1; }

# lc_add_root <dir> — resolve to a git toplevel (or the directory itself) and
# remember it once. Silently ignores a path that does not exist, so a caller
# can offer optional roots without branching.
lc_add_root() {
    local r="$1" top
    [ -d "$r" ] || return 0
    top="$(git -C "$r" rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$top" ] || top="$(cd "$r" 2>/dev/null && pwd -P)"
    [ -n "$top" ] || return 0
    printf '%s\n' "$LC_ROOTS" | grep -qxF "$top" && return 0
    LC_ROOTS="${LC_ROOTS}${top}
"
    return 0
}

# lc_roots — the watched roots, one per line.
lc_roots() { printf '%s' "$LC_ROOTS" | grep -v '^$'; }

# lc_count — how many roots are watched. Zero means this canary can never go
# red, and a caller MUST treat that as a failure rather than a pass.
lc_count() { lc_roots | grep -c . ; }

# lc_snapshot <root> — the watchable state of <root>, one entry per line, on
# stdout. Exit 1 if the root cannot be read or is too large to witness
# honestly. A root above the ceiling is REFUSED, never sampled: sampling is a
# canary that watches some of a tree and reports on all of it.
lc_snapshot() {
    local root="$1" line path n raw
    raw="$(mktemp)" || return 1
    if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
        if ! git -C "$root" status --porcelain --untracked-files=all > "$raw" 2>/dev/null; then
            rm -f "$raw"; return 1
        fi
    else
        if ! ( cd "$root" 2>/dev/null || exit 1; find . -print 2>/dev/null ) > "$raw"; then
            rm -f "$raw"; return 1
        fi
    fi
    n="$(wc -l < "$raw" | tr -d ' ')"
    if [ "$n" -gt "$LC_MAX_ENTRIES" ]; then rm -f "$raw"; return 1; fi
    # A path containing a space or a control character comes back from git in
    # double quotes, so the name below does not resolve and the entry keeps its
    # status line WITHOUT a witness — it degrades to path-only for that one
    # file rather than being dropped. A NEW escaped path is still caught; a
    # same-path OVERWRITE of a file whose name needs quoting is not.
    while IFS= read -r line; do
        case "$line" in
            '?? '*) path="$root/${line#?? }" ;;
            ./*)    path="$root/${line#./}" ;;
            *)      printf '%s\n' "$line"; continue ;;
        esac
        if [ -f "$path" ]; then
            printf '%s  [%s]\n' "$line" "$(tw_file_witness "$path")"
        else
            printf '%s\n' "$line"
        fi
    done < "$raw" | LC_ALL=C sort
    rm -f "$raw"
    return 0
}

# lc_baseline <state-dir> — snapshot every watched root into <state-dir>.
# Sets LC_HEALTHY=0 if any root could not be witnessed, so a later "nothing
# escaped" can be refused rather than printed over a canary with nothing to
# compare against.
lc_baseline() {
    local dir="$1" root i=0
    mkdir -p "$dir"
    while IFS= read -r root; do
        [ -n "$root" ] || continue
        i=$((i + 1))
        printf '%s\n' "$root" > "$dir/$i.root"
        if ! lc_snapshot "$root" > "$dir/$i.txt" 2>/dev/null; then
            LC_HEALTHY=0
            : > "$dir/$i.txt"
        fi
    done <<LC_ROOT_LIST
$(lc_roots)
LC_ROOT_LIST
    printf '%s\n' "$i" > "$dir/count"
    return 0
}

# lc_escaped <state-dir> [<exclude-substring>] — everything that APPEARED or
# CHANGED under any watched root since lc_baseline, as
# `<root><TAB><status-line>` records. Empty output means nothing escaped.
# <exclude-substring> drops entries whose text contains it, for the
# pathological case of a sandbox living inside a watched tree.
lc_escaped() {
    local dir="$1" exclude="${2:-}" i n root after
    n="$(cat "$dir/count" 2>/dev/null || printf '0')"
    after="$(mktemp)" || return 0
    i=0
    while [ "$i" -lt "$n" ]; do
        i=$((i + 1))
        root="$(cat "$dir/$i.root" 2>/dev/null)"
        [ -n "$root" ] || continue
        if ! lc_snapshot "$root" > "$after" 2>/dev/null; then
            printf '%s\tUNREADABLE\n' "$root"
            continue
        fi
        if [ -n "$exclude" ]; then
            comm -13 "$dir/$i.txt" "$after" | grep -vF "$exclude" | sed "s|^|$root	|"
        else
            comm -13 "$dir/$i.txt" "$after" | sed "s|^|$root	|"
        fi
    done
    rm -f "$after"
    return 0
}

# lc_is_tracked_change <status-line> — 0 when the entry is a change to a file
# git already tracks (modified, deleted, renamed, staged), rather than an
# untracked file appearing. This is the distinction that separates "this run's
# result is not about the code you have" from "this run left residue".
lc_is_tracked_change() {
    case "$1" in
        '?? '*) return 1 ;;
        ./*)    return 1 ;;
        *)      return 0 ;;
    esac
}
