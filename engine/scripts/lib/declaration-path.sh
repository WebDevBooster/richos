#!/usr/bin/env bash
#
# scripts/lib/declaration-path.sh — WHERE A DECLARATION LIVES, ANSWERED IN ONE
#                                   PLACE, FOR EVERY GUARD THAT ASKS.
#
# ===========================================================================
# WHY THIS FILE EXISTS
# ===========================================================================
# This engine switches its contracts on by PRESENCE: a committed file at the
# governed repository's root is the whole adoption decision. `.publication-
# boundary` says this tree gets published; `.row-currency` says its rows are
# checked against a record. Presence IS adoption, and that design is right.
#
# It has one cost, and it is paid at the ROOT of every adopting repository: one
# more entry in the listing a person sees first. Three of them in `richos` —
# the boundary, its completeness exemptions, and the row pointer — and the
# repository is about to be read by strangers on a web page where the root
# listing is the first thing rendered.
#
# So the three move into `.richos/`, and this file is the ONE place that knows
# it. Every guard keeps asking the question it always asked — "does this
# repository declare X?" — and gets its answer from here.
#
# ===========================================================================
# THE NAME DID NOT CHANGE. ONLY THE DIRECTORY.
# ===========================================================================
# `PUBLICATION_DECLARATION` is still `.publication-boundary`. That string is
# what publication-completeness.sh DERIVES the set of shipped declarations
# from, what every refusal message names, and what an adopter reads about in
# README.md. Changing the name would have moved four other things; changing
# only the directory moves one.
#
# The file inside `.richos/` drops the leading dot, because a hidden file
# inside a hidden directory is a file nobody browsing `.richos/` will ever see,
# and `ls .richos/` returning nothing is how a directory gets deleted by
# someone tidying up. `.richos/publication-boundary` reads as what it is.
#
# ===========================================================================
# THE ROOT FORM STILL WORKS, AND THAT IS NOT A COURTESY
# ===========================================================================
# This engine is loaded at USER scope and governs every repository on the
# machine. `femcboost` carries a peer-form `.row-currency` at its root right
# now. An adopter who vendored this engine last month has declarations at
# their root and no idea this directory exists. If a path edit here made those
# declarations unfindable, the guards would not fail — they would STAND DOWN,
# silently, and a stood-down publication guard looks exactly like a clean one.
#
# So: `.richos/<stem>` first, `<root>/<name>` second, and NOTHING is a silent
# miss.
#
# ===========================================================================
# TWO COPIES ARE BROKEN, NEVER A CHOICE
# ===========================================================================
# If both forms exist, this refuses. Choosing one quietly is how the wrong one
# stays live — the same sentence `.ceo-todos` already carries about its own
# legacy name, and the same reason a mode signal in two places is a mode signal
# that drifts.
#
# ===========================================================================
# A DECLARATION IN `.richos/` THAT NOTHING READS IS BROKEN, AND THAT IS THE
# ONLY THING IN HERE THIS FILE HAS AN OPINION ABOUT
# ===========================================================================
# The moment `.richos/` exists as a convention, the trap it creates is obvious:
# somebody moves `.ceo-todos` in there, nothing reads it there, the guard
# stands down, and the repository reports green over an unenforced contract.
# That is the exact failure this directory must not introduce, so a declaration
# this file does not serve is BROKEN, loudly, naming the file.
#
# THE FIRST DRAFT OF THIS RULE WAS "ONLY DECLARATIONS AND A README MAY LIVE
# HERE", AND IT WAS WRONG ON THIS MACHINE THE DAY IT WAS WRITTEN.
# `.richos/` was already in use: the Executive Continuity System has kept its
# entity manifest at `.richos/entity.json` in `femcboost` since 2026-08-27, and
# `scripts/ecs/ecs_cli.py` takes it as a default argument. A whole-directory
# rule would have made `rc_load_declaration` return BROKEN there, which is
# `guard-row-currency-commits.sh` refusing EVERY commit in that repository —
# an outage in an adopter, caused by a guard policing files that were never
# its business.
#
# So the scope is exactly the defect: `.richos/` is a SHARED RichOS directory,
# and this file judges only the names it knows to be declarations. Everything
# else in there belongs to whoever put it there.
#
# The two lists below are the whole policy, and they cannot silently fall
# behind: publication-completeness.py derives the full set of declaration names
# from shipped source and FAILS if one of them appears in neither list. A
# declaration added tomorrow is therefore classified deliberately or not at
# all.
#
# Safe to source repeatedly. Never mutates state, never changes the caller's cwd.

if [ -n "${_DECLARATION_PATH_SH_SOURCED:-}" ]; then
    return 0 2>/dev/null || true
fi
_DECLARATION_PATH_SH_SOURCED=1

# The directory, declared once. Overridable for tests, never in production.
: "${DECLARATION_DIR:=.richos}"

# The declarations that RESOLVE through this file, by stem (the name without
# its leading dot). A declaration adopting the directory adds its stem here in
# the same edit that makes it call decl_find.
DECL_ADOPTED_STEMS="publication-boundary publication-completeness row-currency"

# The declarations this engine ships that do NOT resolve from the directory.
# One of them appearing in `.richos/` is a contract somebody believes is live
# and is not, so it is refused by name. Move a stem from this list to the one
# above only in the edit that makes its own library call decl_find.
DECL_FOREIGN_STEMS="ceo-todos unstarted-rows"

# ---------------------------------------------------------------------------
# decl_find <repo_root> <declaration_name>
# ---------------------------------------------------------------------------
# <declaration_name> is the canonical dotted name, e.g. `.publication-boundary`.
#
#   rc 0  found     -> DECL_PATH is the file to read
#   rc 1  absent    -> the caller stands down; nothing is declared
#   rc 2  BROKEN    -> DECL_BROKEN_REASON is set; the caller must BLOCK
#
# Never sources, never reads the file: it answers WHERE, and the caller's own
# strict parser answers WHAT.
decl_find() {
    local root="${1:-}" name="${2:-}" stem grouped legacy entry base
    DECL_PATH=""
    DECL_BROKEN_REASON=""

    [ -n "$root" ] && [ -n "$name" ] || return 1
    stem="${name#.}"
    [ -n "$stem" ] || return 1
    grouped="$root/$DECLARATION_DIR/$stem"
    legacy="$root/$name"

    # A DECLARATION IN HERE THAT NOTHING READS. Checked before anything is
    # resolved, because it means somebody believes a contract is live and it is
    # not — and that belief must not survive one more command.
    #
    # ONLY the names this engine knows to be declarations are judged.
    # `.richos/` is a shared RichOS directory (the ECS entity manifest lives at
    # `.richos/entity.json`), and a resolver that refused files belonging to
    # other components would take an adopter's repository offline over
    # something that was never its business.
    if [ -d "$root/$DECLARATION_DIR" ]; then
        for entry in $DECL_FOREIGN_STEMS; do
            for base in "$entry" ".$entry"; do
                [ -f "$root/$DECLARATION_DIR/$base" ] || continue
                DECL_BROKEN_REASON="$DECLARATION_DIR/$base is a declaration, and nothing reads a declaration from there. Only $DECL_ADOPTED_STEMS resolve through scripts/lib/declaration-path.sh; .$entry is read at the repository root and nowhere else, so this copy switches its contract off in silence — which is the one thing this directory must never be able to do. Move it back to the repository root, or teach declaration-path.sh to resolve it."
                return 2
            done
        done
    fi

    if [ -f "$grouped" ] && [ -f "$legacy" ]; then
        DECL_BROKEN_REASON="this repository carries BOTH $DECLARATION_DIR/$stem and $name. Two declarations are two answers to one question, and choosing one quietly is how the wrong one stays live. Delete whichever is not current; $DECLARATION_DIR/$stem is the form this engine writes."
        return 2
    fi

    if [ -f "$grouped" ]; then DECL_PATH="$grouped"; return 0; fi
    if [ -f "$legacy" ]; then DECL_PATH="$legacy"; return 0; fi
    return 1
}

# ---------------------------------------------------------------------------
# decl_find_upward <start_dir> <declaration_name>
# ---------------------------------------------------------------------------
# The same answer, searched at <start_dir> and every ancestor — for the callers
# that may run from a worktree, or from `engine/` inside a repository that
# carries a product too, and must find the declaration wherever it actually
# lives.
#
#   rc 0  found   -> DECL_PATH, and DECL_ROOT is the directory that declares it
#   rc 1  absent at every level
#   rc 2  BROKEN at the nearest level that had an opinion
#
# The NEAREST level wins, and a broken nearest level is not walked past: an
# ancestor's declaration must never quietly answer for a repository whose own
# declaration is malformed.
decl_find_upward() {
    local d="${1:-}" name="${2:-}" rc next
    DECL_PATH=""
    DECL_ROOT=""
    DECL_BROKEN_REASON=""
    [ -n "$d" ] && [ -n "$name" ] || return 1
    while :; do
        rc=0
        decl_find "$d" "$name" || rc=$?
        case "$rc" in
            0) DECL_ROOT="$d"; return 0 ;;
            2) DECL_ROOT="$d"; return 2 ;;
        esac
        [ "$d" = "/" ] && break
        next="$(dirname "$d")"
        [ "$next" = "$d" ] && break
        d="$next"
    done
    return 1
}
