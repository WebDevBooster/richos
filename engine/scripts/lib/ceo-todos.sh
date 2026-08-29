#!/usr/bin/env bash
#
# scripts/lib/ceo-todos.sh — "WAITING ON THE CEO" AS A CHECKABLE CLAIM.
#
# ===========================================================================
# WHY THIS FILE EXISTS
# ===========================================================================
# The orchestrator writes long, exact briefs for every teammate: file paths,
# commands, constraints, a completion criterion. When the executor is the CEO,
# the brief collapses to one sentence. The most expensive executor in the
# system gets the worst brief, and the same 30-minute task was handed over
# three separate times with no file, no method and no definition of done.
#
# Underneath that is a structural defect, not a manners problem. A record can
# say an item is "waiting on the CEO" while the thing he is supposed to touch
# has never been prepared and does not exist. That claim is unfalsifiable by
# reading: it looks identical to a real one. So it sits, week after week,
# LOOKING blocked on the most expensive person in the company while it is in
# fact blocked on unfinished preparation by whoever wrote the row.
#
# One item in a real record read, in full: "A real recorded call, >= 10 min,
# human-verified transcript." That is a description of a desired state. There
# was no file to open, no method, no criterion — and it turned out to be
# waiting for something that was never going to arrive.
#
#   AN ITEM MAY NOT CLAIM TO BE WAITING ON THE CEO UNLESS THE THING HE TOUCHES
#   ALREADY EXISTS ON DISK.
#
# That sentence is the whole mechanism. Everything below is its enforcement.
#
# ===========================================================================
# THE RULE THIS FILE MUST NOT BREAK
# ===========================================================================
# A RULE ENFORCED BY SOMEONE'S ATTENTION LASTS EXACTLY AS LONG AS THEIR
# ATTENTION. That lesson was learned five times in one week here: a hand-typed
# "13/13 guards" that was not the registration; an "18/18 suites" that was one
# glob's size and not the inventory; a decode flag documented as the primary
# fix and wired only to the tier nobody ran; a CI workflow that had never
# executed once; and a fully-tested function called by nothing.
#
# So this predicate is not a checklist anybody has to remember to apply. It is
# run by guard-ceo-todos-commits.sh at every `git commit` in a repository that
# declares CEO TODOs, from any governed session, whether or not the commit
# touches the record. If the failure mode of this design were "somebody
# forgot", the design would be the defect wearing a new hat.
#
# ===========================================================================
# PREPARED IS HALF. THE OTHER HALF IS REACHABLE.
# ===========================================================================
# The first version of this mechanism enforced preparation and shipped with
# nowhere for the CEO to look. Nine prepared items sat inside a 173-line record
# mixed with everything else, and the only new artifact was a dotfile. The
# landing report read "the contract is live, 9 prepared items" — true of the
# record, false of his experience. His words were: "Why am I not IMMEDIATELY
# seeing my queue in the repo? Or is this supposed to be it: .ceo-queue?"
# (Quoted verbatim. The declaration was named `.ceo-queue` then; it is
# `.ceo-todos` now — see UPGRADING.md, "The CEO's TODOs: the rename".)
#
# THE REASON THAT HALF FELL OUT SILENTLY IS THE GENERAL CASE. Every acceptance
# criterion in that landing was INTERNAL — lint exit codes, guard tests, probe
# layers, git state. A view has no exit code, so it had no test that could
# fail, so it was never in scope and nothing said so. The half that could be
# verified was reported as the whole.
#
# So the contract now has three parts, and the third one is the one that keeps
# the other two honest:
#
#   1. PREPARED   an item may not claim to be waiting on the CEO unless the
#                 thing he touches already exists on disk.
#   2. REACHABLE  the TODOs have exactly ONE entry point: top-level, un-dotted,
#                 named at the head of the repo-root README, and CURRENT — a
#                 projection of the record, byte-checked at every commit, never
#                 a second copy maintained by hand.
#   3. READ FROM  a cold reader, who is not its builder and has no context, is
#      OUTSIDE    asked what the surface says and what he would do. The machine
#                 enforces that the reading HAPPENED, never what it concluded.
#                 scripts/cold-open.sh runs it; the transcript is the product.
#
# ===========================================================================
# TWO STATES, AND WHY THE SECOND ONE IS THE POINT
# ===========================================================================
#   READY-FOR-CEO      prepared. The artifact exists, the time cost is stated,
#                      "done" is written down, and what it unblocks is named.
#                      Only these may sit in a CEO section.
#
#   BLOCKED-ON-RICH    unprepared. Belongs in the preparer's own section.
#
# Moving an item to BLOCKED-ON-RICH is the system WORKING, not a failure. The
# value of the CEO sections comes entirely from the promise that everything
# else is already done; an unprepared item sitting there destroys that promise
# for every other item on the page.
#
# ===========================================================================
# WHAT IS DECLARED, AND BY WHOM
# ===========================================================================
# Scope is declared BY THE REPOSITORY THAT OWNS THE RECORD, in a committed
# `.ceo-todos` file at its root — exactly as `.publication-boundary` declares
# the publication split and `orchestration.config` declares engine adoption.
# Presence of the file IS the declaration; deleting it is a visible, reviewable
# diff and is meant to be.
#
# This matters more here than anywhere else in the engine, because THE
# REPOSITORY THAT OWNS THE RECORD MAY NOT HAVE ADOPTED THE ENGINE AT ALL. The
# guard resolves the DESTINATION repository from the commit and reads that
# repository's declaration, so it works from any governed session regardless of
# the destination's own adoption. See guard-ceo-todos-commits.sh for the honest
# statement of where that stops working.
#
# THE KEYS
#   TODO_RECORD       repo-relative path of the record. One file.
#   CEO_SECTIONS      numeric section headings that mean "waiting on the CEO".
#   PREPARER_SECTION  where a BLOCKED-ON-RICH item belongs instead.
#   ARTIFACT_ROOTS    space-separated <prefix>=<root> pairs. <root> is relative
#                     to the declaring repository's MAIN CHECKOUT. Every
#                     artifact path in the record starts with a <prefix>, so a
#                     reader always knows which repository a path is in and the
#                     checker never has to guess between two roots that both
#                     could match.
#   READY_STATE       default READY-FOR-CEO
#   BLOCKED_STATE     default BLOCKED-ON-RICH
#   TODO_VIEW         REQUIRED. The one entry point: a top-level, un-dotted
#                     file name (no '/'), generated from the record by
#                     scripts/ceo-todos-render.sh. Required because a TODO list
#                     with no entry point is the defect this half exists to
#                     remove — an optional entry point is an entry point that
#                     is missing on the day it matters.
#   ROOT_README       default README.md. The front door the view must be named
#                     from, in its first 40 lines.
#   COLD_OPEN_DIR     optional. Where cold-open transcripts live. Declaring it
#                     switches ON the cold-open freshness gate; NOT declaring
#                     it is a stated, printed limit in every verdict, never a
#                     silent absence.
#
# ===========================================================================
# MAIN CHECKOUT, NOT THE CURRENT ONE — measured, not assumed
# ===========================================================================
# Artifact roots resolve against the MAIN checkout of the declaring repository,
# via scripts/lib/resolve-main-checkout.sh. Two reasons, and the first one is
# not theoretical: a linked git worktree contains no gitignored files, and a
# private artifact prepared FOR the CEO is very often gitignored (that is the
# correct home for private material). Resolved against a worktree, every such
# artifact reads as missing and the guard blocks honest work. Second, the
# question being asked is "does this exist where the CEO works", and he works
# in the main checkout.
#
# ===========================================================================
# WHAT THIS CANNOT CATCH — stated here so nobody has to discover it
# ===========================================================================
#   * Whether the artifact is any GOOD. `stat` proves a file exists; it cannot
#     prove the worksheet is comprehensible or that the criterion is the right
#     one. It removes the failure of preparing nothing, not the failure of
#     preparing badly.
#   * A criterion that is well-formed and wrong. Four fields, all present, all
#     plausible, describing the wrong acceptance test, passes.
#   * An item that should exist and does not. Nothing here notices work that
#     was never filed.
#   * Rot between commits. The artifact can be deleted a minute after a clean
#     commit; the claim is re-checked at the NEXT commit in that repository,
#     not continuously.
#   * Deletion of `.ceo-todos` itself, or of the record. Both are visible diffs
#     rather than silent bypasses, but both are bypasses.
#   * Whether the VIEW is any good to read. It checks that the page exists, is
#     the only one, is named from the front door, and is byte-current with the
#     record. Whether a human can make sense of it is the cold open's job, and
#     the cold open's answer is prose a person has to read.
#   * Whether the cold reader was really cold. The transcript records WHO read
#     it; nothing can verify that claim. What it can do — and does — is refuse
#     to accept a transcript describing a front door that no longer exists.
#   * A second, hand-written TODOs page that never carried the generated
#     marker. The singularity check catches the realistic drift (a COPY of the
#     view that stops being regenerated), not an unrelated file someone writes
#     from scratch.
#
# Safe to source repeatedly. Never mutates state, never changes the caller's cwd.

if [ -n "${_CEO_TODOS_SH_SOURCED:-}" ]; then
    return 0 2>/dev/null || true
fi
_CEO_TODOS_SH_SOURCED=1

# The declaration marker. One file, one name, checked one way, everywhere.
: "${CEO_TODOS_DECLARATION:=.ceo-todos}"

# ---------------------------------------------------------------------------
# THE LEGACY NAME — WHY AN ALIAS AND NOT A CLEAN CUT
# ---------------------------------------------------------------------------
# Until 2026-08-29 this mechanism was called the CEO QUEUE, its declaration was
# `.ceo-queue`, and its two path keys were QUEUE_RECORD and QUEUE_VIEW. The CEO
# renamed it: the audience is non-technical CEOs in the US, and "queue" is the
# British word for it.
#
# A rename of a STRICT-PARSED declaration has a nasty ordering property, and
# this engine had already been bitten by the milder half of it that same
# morning (UPGRADING.md, "Ordering trap"). Spelled out, with the failure of
# each direction named:
#
#   NEW ENGINE + OLD `.ceo-queue`   Without an alias the new engine finds no
#                                   declaration and STANDS DOWN — silently. The
#                                   repository looks governed, every commit
#                                   passes, and nothing anywhere says the guard
#                                   stopped running.
#   OLD ENGINE + NEW `.ceo-todos`   The same silent stand-down, and it cannot be
#                                   fixed from here: that code has already
#                                   shipped. Only a LAND ORDER fixes it — the
#                                   engine goes first, always.
#
# The first direction is the one an adopter actually meets, because an adopter
# updates the engine on the engine's schedule and their own repository on
# theirs. A clean cut would hand every one of them an invisible switch-off, and
# an invisible switch-off is the precise failure class this whole file exists to
# remove. So:
#
#   THE LEGACY DECLARATION IS STILL READ AND STILL ENFORCED, AND SAYS SO OUT
#   LOUD ON EVERY SINGLE VERDICT UNTIL IT IS RENAMED.
#
# Never silent, never a deadline, never a broken adopter. The notice rides the
# NOTE channel, which both the lint and the commit guard print on a CLEAN pass
# as well as on a refusal — the one channel in this design that cannot be
# reached only by failing.
#
# Carrying BOTH files is BROKEN, not "prefer the new one": two declarations are
# two answers to "what is the record", and picking one quietly is how the wrong
# one stays live.
#
# The variable below is deliberately NOT named `*_DECLARATION`. That convention
# is what publication-completeness.py greps to derive the set of declarations an
# adopter must be given a template and an onboarding paragraph for, and a legacy
# alias is the opposite of something a new adopter should be told to create.
# Documented here rather than hidden: the exclusion is a decision, not an
# oversight. The migration is in UPGRADING.md.
_CT_LEGACY_DECL_FILE=".ceo-queue"

# Old key name -> current key name. Same contract as the file alias: accepted,
# translated, and named in a NOTE on every verdict.
_CT_LEGACY_KEY_MAP="QUEUE_RECORD=TODO_RECORD QUEUE_VIEW=TODO_VIEW"

_CT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Every key the declaration may carry. A key outside this set is a typo, and a
# typo that silently does nothing is the defect class this file exists to
# remove — so it is refused, loudly, by name.
_CT_KNOWN_KEYS="TODO_RECORD CEO_SECTIONS PREPARER_SECTION ARTIFACT_ROOTS READY_STATE BLOCKED_STATE TODO_VIEW ROOT_README COLD_OPEN_DIR"

# The verbatim cold-open prompt. Its sha256 is baked into every transcript, so
# changing a question invalidates every transcript on file — which is correct:
# a transcript answers the questions it was asked, and a new question has never
# been answered by anyone.
_CT_PROMPT_FILE_NAME="cold-open-prompt.md"

# ---------------------------------------------------------------------------
# ct_physical <path>
# ---------------------------------------------------------------------------
# The path with every symlinked ancestor resolved, WITHOUT requiring the path
# itself to exist. Same reason publication-boundary.sh carries the same helper:
# `git rev-parse --show-toplevel` always answers with a physical path while a
# payload carries whatever the caller typed, and on macOS /tmp and /var are
# symlinks, so the two disagree constantly and every prefix comparison silently
# stops matching.
ct_physical() {
    local p="${1:-}" head tail=""
    [ -n "$p" ] || return 1
    head="$p"
    while [ ! -d "$head" ] && [ "$head" != "/" ] && [ -n "$head" ]; do
        tail="$(basename "$head")${tail:+/$tail}"
        head="$(dirname "$head")"
    done
    [ -d "$head" ] || { printf '%s\n' "$p"; return 0; }
    head="$( (cd "$head" 2>/dev/null && pwd -P) || printf '%s' "$head" )"
    printf '%s\n' "${head%/}${tail:+/$tail}"
}

# ---------------------------------------------------------------------------
# ct_repo_root <path>
# ---------------------------------------------------------------------------
# The git top level containing <path> (which need not exist yet). Empty + rc 1
# when there is no repository.
ct_repo_root() {
    local p="${1:-}" d top
    [ -n "$p" ] || return 1
    d="$p"
    [ -d "$d" ] || d="$(dirname "$p")"
    while [ ! -d "$d" ] && [ "$d" != "/" ] && [ -n "$d" ]; do
        d="$(dirname "$d")"
    done
    [ -d "$d" ] || return 1
    top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" || return 1
    [ -n "$top" ] || return 1
    ct_physical "$top"
}

# ---------------------------------------------------------------------------
# ct_main_checkout <repo_root>
# ---------------------------------------------------------------------------
# The MAIN checkout of the repository <repo_root> belongs to. Delegates to the
# engine's existing resolver rather than carrying a second copy of that logic;
# falls back to <repo_root> when the resolver is unavailable, which is exactly
# what the resolver itself does without git.
ct_main_checkout() {
    local root="${1:-}"
    [ -n "$root" ] || return 1
    if [ -f "$_CT_LIB_DIR/resolve-main-checkout.sh" ]; then
        # shellcheck source=./resolve-main-checkout.sh
        . "$_CT_LIB_DIR/resolve-main-checkout.sh"
        ct_physical "$(resolve_main_checkout "$root" "$root")"
        return 0
    fi
    ct_physical "$root"
}

# ---------------------------------------------------------------------------
# ct_load_declaration <repo_root>
# ---------------------------------------------------------------------------
# Strict-parses <repo_root>/.ceo-todos — or, when that is absent, the legacy
# <repo_root>/.ceo-queue — into CT_* variables.
#
#   rc 0  a well-formed declaration was loaded  -> enforce
#   rc 1  no declaration                        -> stand down
#   rc 2  BROKEN: present but malformed         -> caller must BLOCK
#
# Also sets, for the migration notice every caller must surface:
#   CT_DECLARATION_FILE  absolute path of the file actually read
#   CT_LEGACY_DECL       the legacy file name if that is what was read, else ""
#   CT_LEGACY_KEYS       space-separated legacy key names that were translated
#
# PARSED, never sourced. Sourcing a file to read six settings out of it hands
# arbitrary code execution to anything that can write a config.
ct_load_declaration() {
    local root="${1:-}" f line key val pair legacy_f lk
    CT_TODO_RECORD=""
    CT_CEO_SECTIONS="1 2"
    CT_PREPARER_SECTION="3"
    CT_ARTIFACT_ROOTS=""
    CT_READY_STATE="READY-FOR-CEO"
    CT_BLOCKED_STATE="BLOCKED-ON-RICH"
    CT_TODO_VIEW=""
    CT_ROOT_README="README.md"
    CT_COLD_OPEN_DIR=""
    CT_BROKEN_REASON=""
    CT_DECLARATION_FILE=""
    CT_LEGACY_DECL=""
    CT_LEGACY_KEYS=""

    [ -n "$root" ] || return 1
    f="$root/$CEO_TODOS_DECLARATION"
    legacy_f="$root/$_CT_LEGACY_DECL_FILE"

    if [ -f "$f" ] && [ -f "$legacy_f" ]; then
        CT_BROKEN_REASON="this repository carries BOTH $CEO_TODOS_DECLARATION and the legacy $_CT_LEGACY_DECL_FILE. Two declarations are two answers to 'what is the record', and choosing one quietly is how the wrong one stays live. Delete $_CT_LEGACY_DECL_FILE; $CEO_TODOS_DECLARATION supersedes it."
        return 2
    fi
    if [ ! -f "$f" ]; then
        [ -f "$legacy_f" ] || return 1
        f="$legacy_f"
        CT_LEGACY_DECL="$_CT_LEGACY_DECL_FILE"
    fi
    CT_DECLARATION_FILE="$f"

    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*) continue ;;
        esac
        line="${line#"${line%%[![:space:]]*}"}"
        case "$line" in
            ''|'#'*) continue ;;
        esac
        case "$line" in
            *=*) ;;
            *) CT_BROKEN_REASON="line is not KEY=value: '$line'"; return 2 ;;
        esac
        key="${line%%=*}"
        val="${line#*=}"
        case "$val" in
            \"*\") val="${val#\"}"; val="${val%\"}" ;;
            \'*\') val="${val#\'}"; val="${val%\'}" ;;
            *) val="${val%%#*}"; val="${val%"${val##*[![:space:]]}"}" ;;
        esac
        # A legacy key name is TRANSLATED, never refused, and never silent —
        # see "THE LEGACY NAME" at the head of this file. Translation happens
        # before the strict known-key check, so the check below stays strict
        # about everything that is neither current nor a named legacy alias.
        for lk in $_CT_LEGACY_KEY_MAP; do
            if [ "$key" = "${lk%%=*}" ]; then
                CT_LEGACY_KEYS="${CT_LEGACY_KEYS:+$CT_LEGACY_KEYS }$key"
                key="${lk#*=}"
                break
            fi
        done
        case " $_CT_KNOWN_KEYS " in
            *" $key "*) ;;
            *)
                CT_BROKEN_REASON="unknown key '$key'. Known keys: $_CT_KNOWN_KEYS (the pre-2026-08-29 names QUEUE_RECORD and QUEUE_VIEW are also accepted, with a notice). A key this guard does not read is a setting that silently does nothing — refusing rather than pretending it took effect."
                return 2 ;;
        esac
        case "$val" in
            *'$('*|*'`'*)
                CT_BROKEN_REASON="value for '$key' contains shell substitution syntax; this file is parsed, never sourced, so it would be taken literally"
                return 2 ;;
        esac
        case "$key" in
            TODO_RECORD)     CT_TODO_RECORD="$val" ;;
            CEO_SECTIONS)     CT_CEO_SECTIONS="$val" ;;
            PREPARER_SECTION) CT_PREPARER_SECTION="$val" ;;
            ARTIFACT_ROOTS)   CT_ARTIFACT_ROOTS="$val" ;;
            READY_STATE)      CT_READY_STATE="$val" ;;
            BLOCKED_STATE)    CT_BLOCKED_STATE="$val" ;;
            TODO_VIEW)       CT_TODO_VIEW="$val" ;;
            ROOT_README)      CT_ROOT_README="$val" ;;
            COLD_OPEN_DIR)    CT_COLD_OPEN_DIR="$val" ;;
        esac
    done < "$f"

    if [ -z "$CT_TODO_RECORD" ]; then
        CT_BROKEN_REASON="TODO_RECORD is not set. A declaration that names no record declares nothing, and a guard with no subject would stand down while looking switched on."
        return 2
    fi
    case "$CT_TODO_RECORD" in
        /*|~*|*..*)
            CT_BROKEN_REASON="TODO_RECORD must be a plain repository-relative path, not '$CT_TODO_RECORD'"
            return 2 ;;
    esac
    if [ -z "$CT_CEO_SECTIONS" ]; then
        CT_BROKEN_REASON="CEO_SECTIONS is empty. With no CEO section there is nothing to check, and a lint with nothing to check reports clean forever."
        return 2
    fi
    case "$CT_CEO_SECTIONS" in
        *[!0-9\ ]*)
            CT_BROKEN_REASON="CEO_SECTIONS must be space-separated section NUMBERS ('1 2'), not '$CT_CEO_SECTIONS'"
            return 2 ;;
    esac
    case "$CT_PREPARER_SECTION" in
        ''|*[!0-9]*)
            CT_BROKEN_REASON="PREPARER_SECTION must be a single section NUMBER, not '$CT_PREPARER_SECTION'"
            return 2 ;;
    esac
    for sec in $CT_CEO_SECTIONS; do
        if [ "$sec" = "$CT_PREPARER_SECTION" ]; then
            CT_BROKEN_REASON="section $sec is declared as BOTH a CEO section and the preparer section; an item could then never be anywhere else"
            return 2
        fi
    done
    if [ -z "$CT_ARTIFACT_ROOTS" ]; then
        CT_BROKEN_REASON="ARTIFACT_ROOTS is empty, so no artifact path could ever resolve and every prepared item would read as missing"
        return 2
    fi
    for pair in $CT_ARTIFACT_ROOTS; do
        case "$pair" in
            *=*) ;;
            *)
                CT_BROKEN_REASON="ARTIFACT_ROOTS entry '$pair' is not <prefix>=<root>"
                return 2 ;;
        esac
        if [ -z "${pair%%=*}" ] || [ -z "${pair#*=}" ]; then
            CT_BROKEN_REASON="ARTIFACT_ROOTS entry '$pair' has an empty prefix or root"
            return 2
        fi
    done
    # TODO_VIEW's ABSENCE is not a broken declaration — it is a TODO list with no
    # entry point, which is a finding about the TODOs and is reported as one by
    # the predicate (NO-ENTRY-POINT-DECLARED). Only its SHAPE is checked here,
    # because a value the predicate could not use at all is a typo.
    case "$CT_TODO_VIEW" in
        '') ;;
        /*|~*|*..*|*/*)
            CT_BROKEN_REASON="TODO_VIEW must be a bare TOP-LEVEL file name ('CEO-TODOs.md'), not '$CT_TODO_VIEW'. The entry point is what a stranger sees listing the repository root."
            return 2 ;;
    esac
    case "$CT_ROOT_README" in
        '')
            CT_BROKEN_REASON="ROOT_README is empty. Set it, or leave the key out to accept the default README.md; an empty value would make the discoverability check compare against nothing."
            return 2 ;;
        /*|~*|*..*|*/*)
            CT_BROKEN_REASON="ROOT_README must be a bare top-level file name, not '$CT_ROOT_README'"
            return 2 ;;
    esac
    case "$CT_COLD_OPEN_DIR" in
        '') ;;
        /*|~*|*..*)
            CT_BROKEN_REASON="COLD_OPEN_DIR must be a plain repository-relative path, not '$CT_COLD_OPEN_DIR'"
            return 2 ;;
    esac
    if [ "$CT_READY_STATE" = "$CT_BLOCKED_STATE" ]; then
        CT_BROKEN_REASON="READY_STATE and BLOCKED_STATE are the same string, so the two states are indistinguishable"
        return 2
    fi
    return 0
}

# ---------------------------------------------------------------------------
# ct_resolve_roots <repo_root>
# ---------------------------------------------------------------------------
# Turns CT_ARTIFACT_ROOTS into two tab-separated <prefix>=<abs> lists:
#
#   CT_ROOTS_OK       declared roots that are on this machine
#   CT_ROOTS_ABSENT   declared roots that are not (a sibling repo nobody cloned)
#
# An ABSENT root is never an error and never a block. It makes every artifact
# under it UNCHECKABLE, and the verdict names each one it skipped — the same
# contract publication-boundary.sh keeps for a private source that is not on
# this machine. The alternative is a guard that wedges every commit in a
# repository because an unrelated sibling is not cloned, and a guard that
# blocks legitimate work gets switched off.
ct_resolve_roots() {
    local root="${1:-}" main pair prefix rel abs
    CT_ROOTS_OK=""
    CT_ROOTS_ABSENT=""
    # The DECLARED root of every prefix, verbatim, whether or not it is on this
    # machine. The renderer uses this and never the resolved path: a view that
    # rendered differently depending on which sibling repositories happen to be
    # cloned would make "is the view current?" a per-machine question, and the
    # staleness gate would be unusable.
    CT_ROOT_SPECS=""
    [ -n "$root" ] || return 1
    main="$(ct_main_checkout "$root")"
    for pair in $CT_ARTIFACT_ROOTS; do
        prefix="${pair%%=*}"
        rel="${pair#*=}"
        CT_ROOT_SPECS="${CT_ROOT_SPECS:+$CT_ROOT_SPECS$(printf '\t')}$prefix=$rel"
        case "$rel" in
            /*) abs="$rel" ;;
            *)  abs="$main/$rel" ;;
        esac
        if [ -d "$abs" ]; then
            abs="$(ct_physical "$abs")"
            CT_ROOTS_OK="${CT_ROOTS_OK:+$CT_ROOTS_OK$(printf '\t')}$prefix=$abs"
        else
            CT_ROOTS_ABSENT="${CT_ROOTS_ABSENT:+$CT_ROOTS_ABSENT$(printf '\t')}$prefix=$rel"
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# ct_prompt_file
# ---------------------------------------------------------------------------
# Absolute path of the verbatim cold-open prompt shipped with this engine.
ct_prompt_file() { printf '%s\n' "$_CT_LIB_DIR/$_CT_PROMPT_FILE_NAME"; }

# ---------------------------------------------------------------------------
# ct_sha256 <file>
# ---------------------------------------------------------------------------
ct_sha256() {
    local f="${1:-}"
    [ -f "$f" ] || return 1
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$f" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$f" | awk '{print $1}'
    else
        python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$f"
    fi
}

# ---------------------------------------------------------------------------
# ct_build_job <mode> <label> <record-text-path> <repo-root> <out.json>
# ---------------------------------------------------------------------------
# Assembles the whole job — the record AND the CEO-facing surface around it.
# Requires ct_load_declaration + ct_resolve_roots to have run.
#
# TWO OVERRIDES, and they exist for one reason: at `git commit` the bytes that
# LAND are the staged blob, not the worktree copy, and a gate that checks the
# worktree would pass a commit that stages a stale view.
#   CT_OVERRIDE_VIEW    path to the view bytes, or "-" meaning "not present"
#   CT_OVERRIDE_README  same, for the root README
# Unset = read the worktree.
ct_build_job() {
    local mode="${1:-lint}" label="${2:-<record>}" src="${3:-}" repo="${4:-}" out="${5:-}"
    [ -n "$src" ] && [ -f "$src" ] || { echo "ERROR: ct_build_job: no record text at '$src'" >&2; return 2; }
    [ -n "$out" ] || { echo "ERROR: ct_build_job: no output path" >&2; return 2; }
    command -v python3 >/dev/null 2>&1 || { echo "ERROR: ct_build_job: python3 is required" >&2; return 2; }

    local prompt_fp=""
    if [ -f "$(ct_prompt_file)" ]; then
        prompt_fp="$(ct_sha256 "$(ct_prompt_file)")"
    fi

    CT_J_MODE="$mode" CT_J_LABEL="$label" CT_J_SRC="$src" CT_J_REPO="$repo" \
    CT_J_CEO="$CT_CEO_SECTIONS" CT_J_PREP="$CT_PREPARER_SECTION" \
    CT_J_OK="$CT_ROOTS_OK" CT_J_ABSENT="$CT_ROOTS_ABSENT" CT_J_SPECS="$CT_ROOT_SPECS" \
    CT_J_READY="$CT_READY_STATE" CT_J_BLOCKED="$CT_BLOCKED_STATE" \
    CT_J_VIEW="$CT_TODO_VIEW" CT_J_README="$CT_ROOT_README" CT_J_COLD="$CT_COLD_OPEN_DIR" \
    CT_J_OVR_VIEW="${CT_OVERRIDE_VIEW:-}" CT_J_OVR_README="${CT_OVERRIDE_README:-}" \
    CT_J_LEGACY_DECL="${CT_LEGACY_DECL:-}" CT_J_LEGACY_KEYS="${CT_LEGACY_KEYS:-}" \
    CT_J_PROMPT_FP="$prompt_fp" CT_J_OUT="$out" python3 -c '
import json, os

def pairs(raw):
    out = {}
    for entry in (raw or "").split("\t"):
        if entry and "=" in entry:
            k, v = entry.split("=", 1)
            out[k] = v
    return out

def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except Exception:
        return None

def surface(name, override, repo):
    """The bytes that will BE there. "-" means the override says: absent."""
    if override == "-":
        return None
    if override:
        return read(override)
    if not name or not repo:
        return None
    return read(os.path.join(repo, name))

repo = os.environ.get("CT_J_REPO") or ""
view = os.environ.get("CT_J_VIEW") or ""
readme = os.environ.get("CT_J_README") or "README.md"
cold = os.environ.get("CT_J_COLD") or ""

top_level_md = []
if repo and os.path.isdir(repo):
    for name in sorted(os.listdir(repo)):
        if not name.lower().endswith(".md") or name == view:
            continue
        p = os.path.join(repo, name)
        if os.path.isfile(p):
            top_level_md.append([name, read(p) or ""])

cold_present = False
transcripts = []
if cold and repo:
    d = os.path.join(repo, cold)
    cold_present = os.path.isdir(d)
    if cold_present:
        for name in sorted(os.listdir(d)):
            # A folder README explains what the folder is for; it is not a
            # transcript and must not be reported as a broken one. Every other
            # .md in here is a transcript CANDIDATE — deliberately, so a file
            # that is nearly a transcript is named rather than skipped.
            if not name.lower().endswith(".md") or name.lower() == "readme.md":
                continue
            p = os.path.join(d, name)
            if os.path.isfile(p):
                transcripts.append([name, read(p) or ""])

job = {
    "mode": os.environ.get("CT_J_MODE") or "lint",
    "record_label": os.environ.get("CT_J_LABEL", "<record>"),
    "text": read(os.environ["CT_J_SRC"]) or "",
    "ceo_sections": [s for s in os.environ.get("CT_J_CEO", "").split() if s],
    "preparer_section": os.environ.get("CT_J_PREP", ""),
    "artifact_roots": pairs(os.environ.get("CT_J_OK")),
    "absent_roots": pairs(os.environ.get("CT_J_ABSENT")),
    "root_specs": pairs(os.environ.get("CT_J_SPECS")),
    "ready_state": os.environ.get("CT_J_READY", "READY-FOR-CEO"),
    "blocked_state": os.environ.get("CT_J_BLOCKED", "BLOCKED-ON-RICH"),
    "todo_view": view,
    "view_text": surface(view, os.environ.get("CT_J_OVR_VIEW") or "", repo),
    "root_readme": readme,
    "readme_text": surface(readme, os.environ.get("CT_J_OVR_README") or "", repo),
    "top_level_md": top_level_md,
    "cold_open_dir": cold,
    "cold_open_dir_present": cold_present,
    "cold_open": transcripts,
    "prompt_fingerprint": os.environ.get("CT_J_PROMPT_FP", ""),
    # The migration state, carried so the predicate can put it on the NOTE
    # channel — the one channel printed on a CLEAN verdict as well as a refusal.
    "legacy_declaration": os.environ.get("CT_J_LEGACY_DECL") or "",
    "legacy_keys": [k for k in (os.environ.get("CT_J_LEGACY_KEYS") or "").split() if k],
}
with open(os.environ["CT_J_OUT"], "w", encoding="utf-8") as fh:
    json.dump(job, fh)
' || { echo "ERROR: ct_build_job: could not build the job" >&2; return 2; }
    return 0
}

# ---------------------------------------------------------------------------
# ct_lint_file <label> <path-to-record-text> [repo-root]
# ---------------------------------------------------------------------------
# Runs the predicate. Prints the raw verdict lines (see ceo-todos.py) on
# stdout. Requires ct_load_declaration + ct_resolve_roots to have run.
#
# rc 0 whatever the verdict is; rc 2 only when the CHECKER could not run, which
# every caller must treat as BROKEN rather than as a clean record.
ct_lint_file() {
    local label="${1:-<record>}" src="${2:-}" repo="${3:-}" job rc
    [ -f "$_CT_LIB_DIR/ceo-todos.py" ] || { echo "ERROR: ct_lint_file: scripts/lib/ceo-todos.py is missing" >&2; return 2; }
    job="$(mktemp -t ceo-todos-job.XXXXXX.json)" || return 2
    ct_build_job lint "$label" "$src" "$repo" "$job" || { rm -f "$job"; return 2; }
    python3 "$_CT_LIB_DIR/ceo-todos.py" "$job"
    rc=$?
    rm -f "$job"
    return "$rc"
}

# ---------------------------------------------------------------------------
# ct_render <label> <path-to-record-text> [repo-root]
# ---------------------------------------------------------------------------
# Prints the rendered view on stdout. Same parse, same declaration, no
# filesystem lookups inside the render — see ceo-todos.py.
#
# rc 0 rendered; 2 the renderer could not run; 3 the record is not renderable
# (and stdout then carries a BROKEN line, never a partial document).
ct_render() {
    local label="${1:-<record>}" src="${2:-}" repo="${3:-}" job rc
    [ -f "$_CT_LIB_DIR/ceo-todos.py" ] || { echo "ERROR: ct_render: scripts/lib/ceo-todos.py is missing" >&2; return 2; }
    job="$(mktemp -t ceo-todos-job.XXXXXX.json)" || return 2
    ct_build_job render "$label" "$src" "$repo" "$job" || { rm -f "$job"; return 2; }
    python3 "$_CT_LIB_DIR/ceo-todos.py" "$job"
    rc=$?
    rm -f "$job"
    return "$rc"
}

# ---------------------------------------------------------------------------
# ct_verdict_fp <verdict-text>
# ---------------------------------------------------------------------------
# The front-door fingerprint out of a lint verdict. ONE number, computed in one
# place: the cold-open harness stamps what the gate will later demand, so the
# two can never drift into disagreeing about what "current" means.
ct_verdict_fp() {
    printf '%s\n' "${1:-}" | awk -F'\t' '$1=="FP" {print $2; exit}'
}

# ---------------------------------------------------------------------------
# ct_broken_banner <caller> <reason>
# ---------------------------------------------------------------------------
ct_broken_banner() {
    local who="${1:-ceo-todos}" why="${2:-}"
    echo "=== CEO TODOs: BROKEN DECLARATION — REFUSING ==="
    echo "  hook/tool : $who"
    echo "  reason    : $why"
    echo ""
    echo "  A TODOs declaration that cannot be read is not a TODO list with nothing"
    echo "  in it. Fix ${CT_DECLARATION_FILE:-$CEO_TODOS_DECLARATION}, or delete it to"
    echo "  stand this mechanism down deliberately and visibly."
}

# ---------------------------------------------------------------------------
# ct_refusal <caller> <headline> <verdict-lines> <record-label>
# ---------------------------------------------------------------------------
# The human half. Every violation is named with its item id and what to do
# about it, because a refusal that does not say how to proceed is a refusal
# somebody routes around.
ct_refusal() {
    local who="${1:-ceo-todos}" headline="${2:-}" result="${3:-}" label="${4:-<record>}"
    echo "=== CEO TODOs: $headline ==="
    echo "  record : $label"
    echo "  guard  : $who"
    echo ""
    printf '%s\n' "$result" | while IFS="$(printf '\t')" read -r kind sec iid code msg; do
        case "$kind" in
            V)    printf '  BLOCK  section %s, item %s — %s\n         %s\n' "$sec" "$iid" "$code" "$msg" ;;
            SKIP) printf '  SKIP   section %s, item %s — %s\n         %s\n' "$sec" "$iid" "$code" "$msg" ;;
            # A stated limit of this run. Printed on refusals too: a reader
            # fixing one problem must still be told what was never checked.
            NOTE) printf '  NOTE   %s\n         %s\n' "$sec" "$iid" ;;
        esac
    done
    echo ""
    echo "  THE CONTRACT, in three parts."
    echo "  1. PREPARED — every item in a CEO section carries all four fields:"
    echo "     **Open:** \`<prefix>/path\`, **Time:**, **Done:**, **Unblocks:** —"
    echo "     and the artifact must already exist on disk."
    echo "  2. REACHABLE — one top-level, un-dotted entry point, named at the head"
    echo "     of the root README, and byte-current with the record. Regenerate it:"
    echo "       scripts/ceo-todos-render.sh <repo>"
    echo "  3. READ FROM OUTSIDE — a cold reader who is not its builder has seen"
    echo "     the front door as it stands now:"
    echo "       scripts/cold-open.sh --run <repo>"
    echo ""
    echo "  If it is not prepared, that is not a failure: mark it $CT_BLOCKED_STATE"
    echo "  and move it to section $CT_PREPARER_SECTION. \"Waiting on the CEO\" is a"
    echo "  promise that everything else is done, and it is only worth something"
    echo "  while it stays true."
}
