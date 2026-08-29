#!/usr/bin/env bash
#
# scripts/lib/ceo-queue.sh — "WAITING ON THE CEO" AS A CHECKABLE CLAIM.
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
# run by guard-ceo-queue-commits.sh at every `git commit` in a repository that
# declares a queue, from any governed session, whether or not the commit
# touches the record. If the failure mode of this design were "somebody
# forgot", the design would be the defect wearing a new hat.
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
# `.ceo-queue` file at its root — exactly as `.publication-boundary` declares
# the publication split and `orchestration.config` declares engine adoption.
# Presence of the file IS the declaration; deleting it is a visible, reviewable
# diff and is meant to be.
#
# This matters more here than anywhere else in the engine, because THE
# REPOSITORY THAT OWNS THE RECORD MAY NOT HAVE ADOPTED THE ENGINE AT ALL. The
# guard resolves the DESTINATION repository from the commit and reads that
# repository's declaration, so it works from any governed session regardless of
# the destination's own adoption. See guard-ceo-queue-commits.sh for the honest
# statement of where that stops working.
#
# THE KEYS
#   QUEUE_RECORD      repo-relative path of the record. One file.
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
#   * Deletion of `.ceo-queue` itself, or of the record. Both are visible diffs
#     rather than silent bypasses, but both are bypasses.
#
# Safe to source repeatedly. Never mutates state, never changes the caller's cwd.

if [ -n "${_CEO_QUEUE_SH_SOURCED:-}" ]; then
    return 0 2>/dev/null || true
fi
_CEO_QUEUE_SH_SOURCED=1

# The declaration marker. One file, one name, checked one way, everywhere.
: "${CEO_QUEUE_DECLARATION:=.ceo-queue}"

_CQ_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Every key the declaration may carry. A key outside this set is a typo, and a
# typo that silently does nothing is the defect class this file exists to
# remove — so it is refused, loudly, by name.
_CQ_KNOWN_KEYS="QUEUE_RECORD CEO_SECTIONS PREPARER_SECTION ARTIFACT_ROOTS READY_STATE BLOCKED_STATE"

# ---------------------------------------------------------------------------
# cq_physical <path>
# ---------------------------------------------------------------------------
# The path with every symlinked ancestor resolved, WITHOUT requiring the path
# itself to exist. Same reason publication-boundary.sh carries the same helper:
# `git rev-parse --show-toplevel` always answers with a physical path while a
# payload carries whatever the caller typed, and on macOS /tmp and /var are
# symlinks, so the two disagree constantly and every prefix comparison silently
# stops matching.
cq_physical() {
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
# cq_repo_root <path>
# ---------------------------------------------------------------------------
# The git top level containing <path> (which need not exist yet). Empty + rc 1
# when there is no repository.
cq_repo_root() {
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
    cq_physical "$top"
}

# ---------------------------------------------------------------------------
# cq_main_checkout <repo_root>
# ---------------------------------------------------------------------------
# The MAIN checkout of the repository <repo_root> belongs to. Delegates to the
# engine's existing resolver rather than carrying a second copy of that logic;
# falls back to <repo_root> when the resolver is unavailable, which is exactly
# what the resolver itself does without git.
cq_main_checkout() {
    local root="${1:-}"
    [ -n "$root" ] || return 1
    if [ -f "$_CQ_LIB_DIR/resolve-main-checkout.sh" ]; then
        # shellcheck source=./resolve-main-checkout.sh
        . "$_CQ_LIB_DIR/resolve-main-checkout.sh"
        cq_physical "$(resolve_main_checkout "$root" "$root")"
        return 0
    fi
    cq_physical "$root"
}

# ---------------------------------------------------------------------------
# cq_load_declaration <repo_root>
# ---------------------------------------------------------------------------
# Strict-parses <repo_root>/.ceo-queue into CQ_* variables.
#
#   rc 0  a well-formed declaration was loaded  -> enforce
#   rc 1  no declaration                        -> stand down
#   rc 2  BROKEN: present but malformed         -> caller must BLOCK
#
# PARSED, never sourced. Sourcing a file to read six settings out of it hands
# arbitrary code execution to anything that can write a config.
cq_load_declaration() {
    local root="${1:-}" f line key val pair
    CQ_QUEUE_RECORD=""
    CQ_CEO_SECTIONS="1 2"
    CQ_PREPARER_SECTION="3"
    CQ_ARTIFACT_ROOTS=""
    CQ_READY_STATE="READY-FOR-CEO"
    CQ_BLOCKED_STATE="BLOCKED-ON-RICH"
    CQ_BROKEN_REASON=""

    [ -n "$root" ] || return 1
    f="$root/$CEO_QUEUE_DECLARATION"
    [ -f "$f" ] || return 1

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
            *) CQ_BROKEN_REASON="line is not KEY=value: '$line'"; return 2 ;;
        esac
        key="${line%%=*}"
        val="${line#*=}"
        case "$val" in
            \"*\") val="${val#\"}"; val="${val%\"}" ;;
            \'*\') val="${val#\'}"; val="${val%\'}" ;;
            *) val="${val%%#*}"; val="${val%"${val##*[![:space:]]}"}" ;;
        esac
        case " $_CQ_KNOWN_KEYS " in
            *" $key "*) ;;
            *)
                CQ_BROKEN_REASON="unknown key '$key'. Known keys: $_CQ_KNOWN_KEYS. A key this guard does not read is a setting that silently does nothing — refusing rather than pretending it took effect."
                return 2 ;;
        esac
        case "$val" in
            *'$('*|*'`'*)
                CQ_BROKEN_REASON="value for '$key' contains shell substitution syntax; this file is parsed, never sourced, so it would be taken literally"
                return 2 ;;
        esac
        case "$key" in
            QUEUE_RECORD)     CQ_QUEUE_RECORD="$val" ;;
            CEO_SECTIONS)     CQ_CEO_SECTIONS="$val" ;;
            PREPARER_SECTION) CQ_PREPARER_SECTION="$val" ;;
            ARTIFACT_ROOTS)   CQ_ARTIFACT_ROOTS="$val" ;;
            READY_STATE)      CQ_READY_STATE="$val" ;;
            BLOCKED_STATE)    CQ_BLOCKED_STATE="$val" ;;
        esac
    done < "$f"

    if [ -z "$CQ_QUEUE_RECORD" ]; then
        CQ_BROKEN_REASON="QUEUE_RECORD is not set. A declaration that names no record declares nothing, and a guard with no subject would stand down while looking switched on."
        return 2
    fi
    case "$CQ_QUEUE_RECORD" in
        /*|~*|*..*)
            CQ_BROKEN_REASON="QUEUE_RECORD must be a plain repository-relative path, not '$CQ_QUEUE_RECORD'"
            return 2 ;;
    esac
    if [ -z "$CQ_CEO_SECTIONS" ]; then
        CQ_BROKEN_REASON="CEO_SECTIONS is empty. With no CEO section there is nothing to check, and a lint with nothing to check reports clean forever."
        return 2
    fi
    case "$CQ_CEO_SECTIONS" in
        *[!0-9\ ]*)
            CQ_BROKEN_REASON="CEO_SECTIONS must be space-separated section NUMBERS ('1 2'), not '$CQ_CEO_SECTIONS'"
            return 2 ;;
    esac
    case "$CQ_PREPARER_SECTION" in
        ''|*[!0-9]*)
            CQ_BROKEN_REASON="PREPARER_SECTION must be a single section NUMBER, not '$CQ_PREPARER_SECTION'"
            return 2 ;;
    esac
    for sec in $CQ_CEO_SECTIONS; do
        if [ "$sec" = "$CQ_PREPARER_SECTION" ]; then
            CQ_BROKEN_REASON="section $sec is declared as BOTH a CEO section and the preparer section; an item could then never be anywhere else"
            return 2
        fi
    done
    if [ -z "$CQ_ARTIFACT_ROOTS" ]; then
        CQ_BROKEN_REASON="ARTIFACT_ROOTS is empty, so no artifact path could ever resolve and every prepared item would read as missing"
        return 2
    fi
    for pair in $CQ_ARTIFACT_ROOTS; do
        case "$pair" in
            *=*) ;;
            *)
                CQ_BROKEN_REASON="ARTIFACT_ROOTS entry '$pair' is not <prefix>=<root>"
                return 2 ;;
        esac
        if [ -z "${pair%%=*}" ] || [ -z "${pair#*=}" ]; then
            CQ_BROKEN_REASON="ARTIFACT_ROOTS entry '$pair' has an empty prefix or root"
            return 2
        fi
    done
    if [ "$CQ_READY_STATE" = "$CQ_BLOCKED_STATE" ]; then
        CQ_BROKEN_REASON="READY_STATE and BLOCKED_STATE are the same string, so the two states are indistinguishable"
        return 2
    fi
    return 0
}

# ---------------------------------------------------------------------------
# cq_resolve_roots <repo_root>
# ---------------------------------------------------------------------------
# Turns CQ_ARTIFACT_ROOTS into two tab-separated <prefix>=<abs> lists:
#
#   CQ_ROOTS_OK       declared roots that are on this machine
#   CQ_ROOTS_ABSENT   declared roots that are not (a sibling repo nobody cloned)
#
# An ABSENT root is never an error and never a block. It makes every artifact
# under it UNCHECKABLE, and the verdict names each one it skipped — the same
# contract publication-boundary.sh keeps for a private source that is not on
# this machine. The alternative is a guard that wedges every commit in a
# repository because an unrelated sibling is not cloned, and a guard that
# blocks legitimate work gets switched off.
cq_resolve_roots() {
    local root="${1:-}" main pair prefix rel abs
    CQ_ROOTS_OK=""
    CQ_ROOTS_ABSENT=""
    [ -n "$root" ] || return 1
    main="$(cq_main_checkout "$root")"
    for pair in $CQ_ARTIFACT_ROOTS; do
        prefix="${pair%%=*}"
        rel="${pair#*=}"
        case "$rel" in
            /*) abs="$rel" ;;
            *)  abs="$main/$rel" ;;
        esac
        if [ -d "$abs" ]; then
            abs="$(cq_physical "$abs")"
            CQ_ROOTS_OK="${CQ_ROOTS_OK:+$CQ_ROOTS_OK$(printf '\t')}$prefix=$abs"
        else
            CQ_ROOTS_ABSENT="${CQ_ROOTS_ABSENT:+$CQ_ROOTS_ABSENT$(printf '\t')}$prefix=$rel"
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# cq_lint_file <label> <path-to-record-text>
# ---------------------------------------------------------------------------
# Runs the predicate. Prints the raw verdict lines (see ceo-queue.py) on
# stdout. Requires cq_load_declaration + cq_resolve_roots to have run.
#
# rc 0 whatever the verdict is; rc 2 only when the CHECKER could not run, which
# every caller must treat as BROKEN rather than as a clean record.
cq_lint_file() {
    local label="${1:-<record>}" src="${2:-}" job rc
    [ -n "$src" ] && [ -f "$src" ] || { echo "ERROR: cq_lint_file: no record text at '$src'" >&2; return 2; }
    [ -f "$_CQ_LIB_DIR/ceo-queue.py" ] || { echo "ERROR: cq_lint_file: scripts/lib/ceo-queue.py is missing" >&2; return 2; }
    command -v python3 >/dev/null 2>&1 || { echo "ERROR: cq_lint_file: python3 is required" >&2; return 2; }

    job="$(mktemp -t ceo-queue-job.XXXXXX.json)" || return 2
    CQ_J_LABEL="$label" CQ_J_SRC="$src" \
    CQ_J_CEO="$CQ_CEO_SECTIONS" CQ_J_PREP="$CQ_PREPARER_SECTION" \
    CQ_J_OK="$CQ_ROOTS_OK" CQ_J_ABSENT="$CQ_ROOTS_ABSENT" \
    CQ_J_READY="$CQ_READY_STATE" CQ_J_BLOCKED="$CQ_BLOCKED_STATE" \
    CQ_J_OUT="$job" python3 -c '
import json, os
def pairs(raw):
    out = {}
    for entry in (raw or "").split("\t"):
        if not entry or "=" not in entry:
            continue
        k, v = entry.split("=", 1)
        out[k] = v
    return out
with open(os.environ["CQ_J_SRC"], encoding="utf-8", errors="replace") as fh:
    text = fh.read()
job = {
    "record_label": os.environ.get("CQ_J_LABEL", "<record>"),
    "text": text,
    "ceo_sections": [s for s in os.environ.get("CQ_J_CEO", "").split() if s],
    "preparer_section": os.environ.get("CQ_J_PREP", ""),
    "artifact_roots": pairs(os.environ.get("CQ_J_OK")),
    "absent_roots": pairs(os.environ.get("CQ_J_ABSENT")),
    "ready_state": os.environ.get("CQ_J_READY", "READY-FOR-CEO"),
    "blocked_state": os.environ.get("CQ_J_BLOCKED", "BLOCKED-ON-RICH"),
}
with open(os.environ["CQ_J_OUT"], "w", encoding="utf-8") as fh:
    json.dump(job, fh)
' || { rm -f "$job"; echo "ERROR: cq_lint_file: could not build the lint job" >&2; return 2; }

    python3 "$_CQ_LIB_DIR/ceo-queue.py" "$job"
    rc=$?
    rm -f "$job"
    return "$rc"
}

# ---------------------------------------------------------------------------
# cq_broken_banner <caller> <reason>
# ---------------------------------------------------------------------------
cq_broken_banner() {
    local who="${1:-ceo-queue}" why="${2:-}"
    echo "=== CEO QUEUE: BROKEN DECLARATION — REFUSING ==="
    echo "  hook/tool : $who"
    echo "  reason    : $why"
    echo ""
    echo "  A queue declaration that cannot be read is not a queue with nothing"
    echo "  in it. Fix $CEO_QUEUE_DECLARATION, or delete it to stand this"
    echo "  mechanism down deliberately and visibly."
}

# ---------------------------------------------------------------------------
# cq_refusal <caller> <headline> <verdict-lines> <record-label>
# ---------------------------------------------------------------------------
# The human half. Every violation is named with its item id and what to do
# about it, because a refusal that does not say how to proceed is a refusal
# somebody routes around.
cq_refusal() {
    local who="${1:-ceo-queue}" headline="${2:-}" result="${3:-}" label="${4:-<record>}"
    echo "=== CEO QUEUE: $headline ==="
    echo "  record : $label"
    echo "  guard  : $who"
    echo ""
    printf '%s\n' "$result" | while IFS="$(printf '\t')" read -r kind sec iid code msg; do
        case "$kind" in
            V)    printf '  BLOCK  section %s, item %s — %s\n         %s\n' "$sec" "$iid" "$code" "$msg" ;;
            SKIP) printf '  SKIP   section %s, item %s — %s\n         %s\n' "$sec" "$iid" "$code" "$msg" ;;
        esac
    done
    echo ""
    echo "  THE CONTRACT. Every item in a CEO section carries all four fields —"
    echo "  **Open:** \`<prefix>/path\`, **Time:**, **Done:**, **Unblocks:** —"
    echo "  and the artifact must already exist on disk."
    echo ""
    echo "  If it is not prepared, that is not a failure: mark it $CQ_BLOCKED_STATE"
    echo "  and move it to section $CQ_PREPARER_SECTION. \"Waiting on the CEO\" is a"
    echo "  promise that everything else is done, and it is only worth something"
    echo "  while it stays true."
}
