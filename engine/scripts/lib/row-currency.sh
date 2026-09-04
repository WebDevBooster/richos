#!/usr/bin/env bash
#
# scripts/lib/row-currency.sh — A ROW THAT DESCRIBES WORK IS A CLAIM ABOUT
#                               BYTES, AND A CLAIM ABOUT BYTES IS CHECKABLE.
#
# ===========================================================================
# WHY THIS FILE EXISTS
# ===========================================================================
# On one day, four rows of one working record described work as unbuilt hours
# after it had landed. Every one of them was caught by a human reading the
# file. The CEO's question was not "why did this happen" — he already knew —
# it was: "when will rows STOP keeping being stale again?"
#
# The cause is the same every time, and it is not carelessness. Updating the
# row is a MANUAL STEP that comes after the merge, and:
#
#   A RULE ENFORCED BY ATTENTION LASTS EXACTLY AS LONG AS THE ATTENTION.
#
# That sentence is written at the top of the CEO-TODOs predicate as well. The
# TODOs contract closed it for the CEO's own two sections — an item may not
# claim to be waiting on him unless the thing he touches exists. It left the
# THIRD section, the working list, enforced by nobody. Which is the section
# that rotted four times in a day.
#
# ===========================================================================
# THE MECHANISM
# ===========================================================================
#   A ROW THAT DESCRIBES OPEN WORK STATES THE IDENTITY OF THE WORK IT
#   DESCRIBES. WHEN THAT IDENTITY CHANGES AND THE ROW DOES NOT, THE NEXT
#   LANDING IS REFUSED UNTIL SOMEBODY REWRITES THE ROW.
#
# The identity is an object id — the blob id of the file, or the tree id of
# the directory, that the row already points at. Those rows ALREADY carry a
# path; every one of the four did, on the day they rotted. This contract does
# not ask anybody to maintain a new fact. It asks the path the row already
# names to be pinned to the bytes the row was written about:
#
#     **State:** `OPEN` — `richos/app/crates/richos-voice/`@`4f2a9c1e83bd`
#
# That is the whole warrant: a status token, and one or more pinned paths.
#
# WHY AN OBJECT ID AND NOT A DATE. This engine's freshness doctrine is
# "identity or refuse" — never a timestamp, never "the deploy said success".
# An object id is content: it does not move when a branch is rebased, it does
# not need clocks to agree, and it answers the only question that matters —
# is this the same work the row was written about?
#
# WHY IT CANNOT BE AUTO-STAMPED. There is deliberately no "refresh all the
# stamps" command, and there never will be. A tool that re-stamps a row
# discharges the obligation without anybody reading the prose, which is the
# entire defect wearing a fix's clothes. The refusal PRINTS the warrant the
# row should carry, so the correction is a paste — into a row you are already
# looking at, next to a sentence you have to decide is still true.
#
# ===========================================================================
# THE SECOND WARRANT — A CEO ITEM'S PREMISE (added 2026-09-02)
# ===========================================================================
# The mechanism above answers "is this row still describing the work?". The
# CEO-TODOs contract answers "is this item already finished?". On 2026-09-02 an
# item on the CEO's own page was neither stale in that sense nor finished, and
# was still wrong:
#
#   Item 1.8 asked him to rule on whether this repository should enforce its own
#   rules. The question rested on a measurement taken three days earlier —
#   both declarations committed, "nothing reads either of them", 28 commits
#   with no check running. By the time he read it that was FALSE: scope is
#   declared by the destination, and both guards had refused commits into that
#   repository three times that same day. Its Done-check was correctly
#   unsatisfied, because he had never ruled. The item was never FINISHED.
#
#   ITS PREMISE HAD ROTTED, AND NOTHING IN THIS ENGINE HAD AN OPINION ABOUT
#   PREMISES.
#
# His attention is the scarcest thing in the system, and a question whose reason
# has evaporated spends it directly. So a CEO item may state the observable fact
# its question rests on, pinned exactly as a row pins work:
#
#     - **Premise:** `richos/engine/scripts/hooks/guard-x.sh`@`4f2a9c1e83bd` —
#       the guard exits before it reads this repository's declaration
#
# When that object id moves, the next landing is refused, naming the item and
# what moved. Same identity rule, same absence of a re-stamp command, same
# absence of an override.
#
# NOT EVERY QUESTION HAS A PINNABLE PREMISE, and forcing one would produce
# fiction. "Run `railway login`" rests on no artifact. The DONE-CHECK-MANUAL
# precedent is exactly right and is reused: an item may declare its premise
# unobservable — `unobservable "<why not>"` — and that declaration is COUNTED
# AND PRINTED by the census on every run, never a silent omission. A bare
# marker exempts nothing; it must carry a reason.
#
# WHERE IT IS DECLARED: `.ceo-todos`, key PREMISE_SECTIONS, because the CEO
# sections are that declaration's jurisdiction and CEO_SECTIONS is already
# stated there once. Undeclared = not adopted, and every verdict carries a
# `PC sections=-` census line saying so rather than passing in silence.
#
# ===========================================================================
# WHERE IT FIRES, AND WHY NOT EVERYWHERE
# ===========================================================================
# ONLY IN A MAIN CHECKOUT, ON AN ATTACHED HEAD — a LANDING.
#
# This is a precision decision and it is the most important one in the file.
# Engineers work in isolated worktrees on their own branches and commit a
# dozen times an hour; the work is a proposal until it lands. If this fired
# there, every engineer touching a directory some row points at would be
# blocked by a record they do not own and cannot reach, and the contract would
# be switched off inside a day. It would also be WRONG: a proposal has not
# changed anything the record describes.
#
# The moment truth changes is the merge into main, in the main checkout, by
# the one person who owns the record. That is the chokepoint, and it is the
# only one this guard stands at.
#
# ===========================================================================
# TWO WAYS A REPOSITORY IS GOVERNED
# ===========================================================================
# THE RECORD FORM. The repository that owns the record carries a
# `.row-currency` naming its governed sections and its status vocabulary. It
# does NOT re-state where the record is or where the artifact roots are: those
# are already declared once in `.ceo-todos`, and a second copy of a fact is
# the drift this engine keeps finding in itself. A `.row-currency` in a
# repository with no `.ceo-todos` is BROKEN, not "half configured".
#
# THE PEER FORM. The repository where the WORK lives is usually not the
# repository where the RECORD lives — that is the whole shape of the problem,
# and it is why "the same commit must edit the row" cannot be the rule: no
# commit can touch two repositories. A work repository carries a one-key
# `.row-currency` naming the record repository, and the guard checks that
# repository's rows against the tree this commit is about to create.
#
# THE DRIFT CHECK BETWEEN THEM. A peer's pointer and the record's own
# ARTIFACT_ROOTS are two statements about the same relationship, so they are
# compared: the record must declare a prefix that resolves back to the peer.
# If it does not, that is BROKEN — never a quiet pass on half a contract.
#
# THE ADOPTER CASE, and it must never break: a work repository whose record
# repository is NOT ON THIS MACHINE stands down, loudly, on stderr, and blocks
# nothing. A public repository whose private sibling nobody has cloned must
# not have every commit in it refused.
#
# ===========================================================================
# NO LIVE OVERRIDE — the decision, and the argument for it
# ===========================================================================
# The publication boundary has no in-the-moment override, on the stated
# grounds that what failed there was in-the-moment judgment and an override
# rebuilds it. That argument applies here with more force, not less: the
# judgment that failed four times in one day was precisely "I will update the
# row after the deploy", made by the lander, at the moment of the land, under
# exactly the pressure an override token is reached for. A prompt-line escape
# hatch would have been used all four times.
#
# The way through is the same one the boundary offers: a COMMITTED diff.
# Delete `.row-currency` and the mechanism is stood down — visibly, in a
# review, with the deleter's name on it. That is an override with a memory.
#
# ===========================================================================
# WHAT THIS RULE CANNOT SEE — stated here, not discovered later
# ===========================================================================
#   * A land that changes an item's truth without touching anything the row
#     points at, and without naming the item. Nothing observable connects
#     them. A row pointing at a SUMMARY rather than at the work is the common
#     shape of this, and it is the row author's to fix.
#   * Whether the new prose is TRUE. This contract forces the row into a
#     human's hands at the moment its subject moves. It has no opinion on
#     what they then write.
#   * A commit made outside a governed session: this is a hook, and a hook
#     that is not loaded is not enforcement. `engine-status.sh` announces that
#     at every session start.
#   * `git cherry-pick`, `git am`, `git rebase`, `git revert` — they create
#     commits without running `git commit` or `git merge`. `git merge` IS
#     covered here, which is a step past the CEO-TODOs guard, because the
#     merge is where the landing actually happens.
#   * A `git commit` whose message comes from an editor rather than -m/-F/-C.
#     The CURRENCY check is unaffected; only the CLAIM check goes blind, and
#     it says so on every such run rather than reporting a clean claim check.
#
# ===========================================================================
# USAGE
# ===========================================================================
#     . "$SCRIPT_DIR/../lib/row-currency.sh"
#     rc_load_declaration "$repo"   # 0 governed / 1 stand down / 2 broken
#     rc_resolve_record "$repo"     # -> RC_RECORD_REPO, RC_* from .ceo-todos
#     rc_lint "$repo" "$pending_record" "$out.json"

# The declaration name, in the convention publication-completeness.sh derives
# from shipped source. Changing it here changes it everywhere, including the
# check that an adopter was given a template and a word of documentation.
: "${ROW_CURRENCY_DECLARATION:=.row-currency}"

_RC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# WHERE the declaration lives is scripts/lib/declaration-path.sh's answer and
# nobody else's — `.richos/row-currency` or the root `.row-currency`, resolved
# one way for every caller. A missing resolver is BROKEN rather than a quiet
# fall back to the root form: standing this contract down over a repository
# that has declared it is the failure the contract exists to end.
_RC_DECL_LIB="$_RC_LIB_DIR/declaration-path.sh"
if [ -f "$_RC_DECL_LIB" ]; then
    # shellcheck source=./declaration-path.sh
    . "$_RC_DECL_LIB"
else
    decl_find() {
        DECL_PATH=""
        DECL_BROKEN_REASON="scripts/lib/declaration-path.sh is missing at: $_RC_DECL_LIB — It is the only thing that knows where a declaration lives, and guessing the root form would stand this contract down over a repository that has declared it."
        return 2
    }
fi

# The CEO-TODOs library is the single parser of `.ceo-todos` and the single
# owner of ct_physical / ct_repo_root / ct_main_checkout / ct_resolve_roots.
# This file re-uses them rather than carrying a second copy, for the reason
# stated at the top of that file: a predicate in two copies is the defect
# class this engine keeps finding in itself.
_RC_CT_LIB="$_RC_LIB_DIR/ceo-todos.sh"

RC_DEFAULT_STATUS_TOKENS="OPEN BUILT BOUNDED BLOCKED-ON-RICH CLOSED"
RC_DEFAULT_TERMINAL_TOKENS="CLOSED"
# The dialect that turns a number in a commit message into a claim about an
# item. An ALLOWLIST; the argument for that, and the 800-message sweep behind
# it, is at CHECK 2 in row-currency.py.
RC_DEFAULT_CLAIM_WORDS="item items open-item open-items decision decisions"

# ---------------------------------------------------------------------------
# rc_require_ceo_todos_lib
# ---------------------------------------------------------------------------
rc_require_ceo_todos_lib() {
    if [ ! -f "$_RC_CT_LIB" ]; then
        RC_BROKEN_REASON="scripts/lib/ceo-todos.sh is missing at $_RC_CT_LIB. The row-currency contract reads the record's location and its artifact roots out of the CEO-TODOs declaration, through that library and nowhere else."
        return 2
    fi
    # shellcheck source=./ceo-todos.sh
    . "$_RC_CT_LIB"
    return 0
}

# ---------------------------------------------------------------------------
# rc_load_declaration <repo_root>
# ---------------------------------------------------------------------------
# Strict-parses this repository's `.row-currency`. WHERE it is —
# `.richos/row-currency` or the root form — is decl_find's answer, and
# RC_DECLARATION_FILE is the path actually read. PARSED, never sourced:
# sourcing a file to read four settings out of it hands arbitrary code
# execution to anything that can write a config.
#
#   rc 0  governed        -> RC_MODE is "record" or "peer"
#   rc 1  no declaration   -> stand down
#   rc 2  BROKEN           -> caller must BLOCK (malformed, declared in two
#                             places at once, or unresolvable)
#
# Sets: RC_MODE RC_PEER_SPEC RC_ROW_SECTIONS RC_STATUS_TOKENS
#       RC_TERMINAL_TOKENS RC_DECLARATION_FILE RC_BROKEN_REASON
rc_load_declaration() {
    local root="${1:-}" f line key val
    RC_MODE=""
    RC_PEER_SPEC=""
    RC_ROW_SECTIONS=""
    RC_STATUS_TOKENS="$RC_DEFAULT_STATUS_TOKENS"
    RC_TERMINAL_TOKENS="$RC_DEFAULT_TERMINAL_TOKENS"
    RC_CLAIM_WORDS="$RC_DEFAULT_CLAIM_WORDS"
    RC_DECLARATION_FILE=""
    RC_BROKEN_REASON=""

    [ -n "$root" ] || return 1
    local _rc_drc=0
    decl_find "$root" "$ROW_CURRENCY_DECLARATION" || _rc_drc=$?
    case "$_rc_drc" in
        0) ;;
        2) RC_BROKEN_REASON="$DECL_BROKEN_REASON"; return 2 ;;
        *) return 1 ;;
    esac
    f="$DECL_PATH"
    [ -f "$f" ] || return 1
    RC_DECLARATION_FILE="$f"

    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*) continue ;;
        esac
        case "$line" in
            *=*) ;;
            *)
                # Whitespace-only lines are fine; anything else is a typo that
                # would otherwise be ignored into silence.
                case "$line" in
                    *[![:space:]]*)
                        RC_BROKEN_REASON="unparseable line in $ROW_CURRENCY_DECLARATION: $line"
                        return 2 ;;
                esac
                continue ;;
        esac
        key="${line%%=*}"
        val="${line#*=}"
        key="$(printf '%s' "$key" | tr -d '[:space:]')"
        val="$(printf '%s' "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")"
        case "$key" in
            ROW_RECORD_REPO)    RC_PEER_SPEC="$val" ;;
            ROW_SECTIONS)       RC_ROW_SECTIONS="$val" ;;
            ROW_STATUS_TOKENS)  RC_STATUS_TOKENS="$val" ;;
            ROW_TERMINAL_TOKENS) RC_TERMINAL_TOKENS="$val" ;;
            ROW_CLAIM_WORDS)    RC_CLAIM_WORDS="$val" ;;
            *)
                RC_BROKEN_REASON="unknown key '$key' in $ROW_CURRENCY_DECLARATION. A key nobody reads is a setting somebody believes is in force; the declaration refuses rather than ignoring it."
                return 2 ;;
        esac
    done < "$f"

    if [ -n "$RC_PEER_SPEC" ] && [ -n "$RC_ROW_SECTIONS" ]; then
        RC_BROKEN_REASON="$ROW_CURRENCY_DECLARATION declares BOTH ROW_RECORD_REPO (the peer form: the record is somewhere else) and ROW_SECTIONS (the record form: the record is here). One repository cannot be both, and guessing which was meant is how the wrong one stays live."
        return 2
    fi
    if [ -n "$RC_PEER_SPEC" ]; then
        RC_MODE="peer"
        return 0
    fi
    if [ -n "$RC_ROW_SECTIONS" ]; then
        RC_MODE="record"
        return 0
    fi
    RC_BROKEN_REASON="$ROW_CURRENCY_DECLARATION names neither ROW_SECTIONS (this repository owns the record) nor ROW_RECORD_REPO (the record is in a sibling repository). An empty declaration switches a guard on over nothing."
    return 2
}

# ---------------------------------------------------------------------------
# rc_resolve_record <repo_root>
# ---------------------------------------------------------------------------
# Resolves the RECORD repository and loads everything the predicate needs from
# it. Requires rc_load_declaration to have run in <repo_root>.
#
#   rc 0  ready       -> RC_RECORD_REPO, RC_RECORD_REL, RC_ROW_SECTIONS,
#                        RC_STATUS_TOKENS, RC_TERMINAL_TOKENS, CT_ROOTS_OK,
#                        CT_ROOTS_ABSENT, RC_SELF_PREFIX
#   rc 1  the record repository is not on this machine -> STAND DOWN LOUDLY
#   rc 2  BROKEN
rc_resolve_record() {
    local root="${1:-}" main here spec abs pair prefix pabs
    RC_RECORD_REPO=""
    RC_RECORD_REL=""
    RC_SELF_PREFIX=""
    RC_STANDDOWN_REASON=""
    RC_BROKEN_REASON=""

    rc_require_ceo_todos_lib || return 2
    # TWO ANCHORS, and the difference matters when this runs by hand inside a
    # linked worktree. SIBLING repositories are found next to the MAIN
    # checkout, because that is what a relative declaration means. But THIS
    # repository is whichever tree the caller is standing in — resolving it to
    # main would answer about a record nobody is editing, which is the "two
    # different moments in time called consistent" mistake one level out.
    main="$(ct_main_checkout "$root")"
    here="$(ct_physical "$root")"

    if [ "$RC_MODE" = "peer" ]; then
        spec="$RC_PEER_SPEC"
        case "$spec" in
            /*) abs="$spec" ;;
            *)  abs="$main/$spec" ;;
        esac
        if [ ! -d "$abs" ]; then
            RC_STANDDOWN_REASON="the record repository declared as '$spec' is not on this machine (looked at $abs). Nothing here can be checked against a record nobody has, and refusing every commit in this repository over an absent sibling would be a defect, not a defense."
            return 1
        fi
        RC_RECORD_REPO="$(ct_repo_root "$abs")" || {
            RC_BROKEN_REASON="'$spec' resolves to $abs, which is not inside a repository. A record has to be under version control for a row to be comparable with anything."
            return 2
        }
        RC_RECORD_REPO="$(ct_main_checkout "$RC_RECORD_REPO")"
    else
        RC_RECORD_REPO="$here"
    fi

    # The record's own declaration is the single source for WHERE the record
    # is and WHAT the artifact roots are.
    local ctrc=0
    ct_load_declaration "$RC_RECORD_REPO" || ctrc=$?
    case "$ctrc" in
        0) ;;
        1)
            RC_BROKEN_REASON="the record repository $RC_RECORD_REPO carries no CEO-TODOs declaration ($CEO_TODOS_DECLARATION). The row-currency contract reads the record's path and its artifact roots from there and refuses to invent either."
            return 2 ;;
        *)
            RC_BROKEN_REASON="the record repository's CEO-TODOs declaration is broken: $CT_BROKEN_REASON"
            return 2 ;;
    esac
    RC_RECORD_REL="$CT_TODO_RECORD"
    [ -n "$RC_RECORD_REL" ] || {
        RC_BROKEN_REASON="the record repository's $CEO_TODOS_DECLARATION names no TODO_RECORD."
        return 2
    }

    # In the peer form, the row settings live in the RECORD's declaration.
    if [ "$RC_MODE" = "peer" ]; then
        local keep_peer="$RC_PEER_SPEC"
        local rcrc=0
        rc_load_declaration "$RC_RECORD_REPO" || rcrc=$?
        case "$rcrc" in
            0)
                if [ "$RC_MODE" != "record" ]; then
                    RC_BROKEN_REASON="$RC_RECORD_REPO was named as a record repository and its own $ROW_CURRENCY_DECLARATION is not in the record form."
                    return 2
                fi ;;
            1)
                RC_BROKEN_REASON="$RC_RECORD_REPO was named as this repository's record and carries no $ROW_CURRENCY_DECLARATION of its own. Half a contract enforces nothing; declare it there or delete the pointer here."
                return 2 ;;
            *) return 2 ;;
        esac
        RC_MODE="peer"
        RC_PEER_SPEC="$keep_peer"
    fi

    ct_resolve_roots "$RC_RECORD_REPO" || {
        RC_BROKEN_REASON="the record repository's artifact roots could not be resolved."
        return 2
    }

    # THE DRIFT CHECK. The peer's pointer and the record's ARTIFACT_ROOTS are
    # two statements about one relationship. They must agree, or one of them
    # is describing a layout that no longer exists.
    #
    # The prefix that names THIS repository is also re-pointed at the tree the
    # caller is standing in — see the two anchors above.
    RC_SELF_PREFIX=""
    local rebuilt="" IFS_SAVE="$IFS"
    IFS="$(printf '\t')"
    for pair in $CT_ROOTS_OK; do
        prefix="${pair%%=*}"
        pabs="${pair#*=}"
        if [ "$pabs" = "$main" ] || [ "$pabs" = "$here" ]; then
            RC_SELF_PREFIX="$prefix"
            pabs="$here"
        fi
        rebuilt="${rebuilt:+$rebuilt$(printf '\t')}$prefix=$pabs"
    done
    IFS="$IFS_SAVE"
    CT_ROOTS_OK="$rebuilt"
    if [ -z "$RC_SELF_PREFIX" ]; then
        RC_BROKEN_REASON="this repository ($here) is not any of the artifact roots the record declares ($CT_ARTIFACT_ROOTS, resolved against $RC_RECORD_REPO). The pointer here and the roots there are two statements about one relationship and they disagree, so no row could name work in this repository even if somebody wrote one."
        return 2
    fi
    return 0
}

# ---------------------------------------------------------------------------
# rc_is_landing <repo_root>
# ---------------------------------------------------------------------------
# 0 when a commit here is a LANDING: the main checkout of the repository, on
# an attached HEAD. 1 otherwise, with RC_NOT_LANDING_REASON set.
rc_is_landing() {
    local root="${1:-}" gitdir commondir
    RC_NOT_LANDING_REASON=""
    [ -n "$root" ] || return 1
    gitdir="$(git -C "$root" rev-parse --absolute-git-dir 2>/dev/null)" || {
        RC_NOT_LANDING_REASON="not a repository"
        return 1
    }
    # --git-common-dir may answer relatively depending on the git version and
    # the cwd, so it is resolved against the repository rather than trusted to
    # be absolute. A comparison of an absolute path with a relative one always
    # "differs", which would report every main checkout as a linked worktree
    # and stand the guard down everywhere while looking switched on.
    commondir="$(git -C "$root" rev-parse --git-common-dir 2>/dev/null)"
    case "$commondir" in
        ""|/*) ;;
        *) commondir="$root/$commondir" ;;
    esac
    if [ -n "$commondir" ] && [ "$(ct_physical "$gitdir")" != "$(ct_physical "$commondir")" ]; then
        RC_NOT_LANDING_REASON="a linked worktree, not the main checkout — work here is a proposal until it lands"
        return 1
    fi
    if ! git -C "$root" symbolic-ref -q HEAD >/dev/null 2>&1; then
        RC_NOT_LANDING_REASON="HEAD is detached"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# rc_pending_tree <repo_root> <mode> <merge_ref>
# ---------------------------------------------------------------------------
# The tree this operation is about to create, as an object id — so the check
# reads the bytes that LAND rather than the bytes that happen to be lying on
# disk. Prints the tree oid, or nothing (caller falls back to HEAD and says so).
#
#   mode "index"   a staged commit
#   mode "all"     `git commit -a`: tracked modifications that are not staged
#   mode "merge"   `git merge <ref>`
#
# The index is copied to a temporary file first and every read-tree/add runs
# against the COPY. A guard that mutates the index of the repository it is
# inspecting is a guard that changes the thing it is measuring.
rc_pending_tree() {
    local root="${1:-}" mode="${2:-index}" ref="${3:-}" tmpidx tree real
    [ -n "$root" ] || return 1

    if [ "$mode" = "merge" ]; then
        [ -n "$ref" ] || return 1
        # `merge-tree --write-tree` prints the merged tree even when the merge
        # conflicts (the conflicts follow on stderr/stdout), so a conflicted
        # land is still measured rather than skipped.
        tree="$(git -C "$root" merge-tree --write-tree HEAD "$ref" 2>/dev/null | head -1)"
        case "$tree" in
            [0-9a-f]*) printf '%s\n' "$tree"; return 0 ;;
        esac
        return 1
    fi

    real="$(git -C "$root" rev-parse --absolute-git-dir 2>/dev/null)/index"
    tmpidx="$(mktemp -t row-currency-index.XXXXXX)" || return 1
    if [ -f "$real" ]; then
        cp "$real" "$tmpidx" 2>/dev/null || { rm -f "$tmpidx"; return 1; }
    else
        rm -f "$tmpidx"
        return 1
    fi
    if [ "$mode" = "all" ]; then
        GIT_INDEX_FILE="$tmpidx" git -C "$root" add -u >/dev/null 2>&1 || {
            rm -f "$tmpidx"; return 1; }
    fi
    tree="$(GIT_INDEX_FILE="$tmpidx" git -C "$root" write-tree 2>/dev/null)"
    rm -f "$tmpidx"
    case "$tree" in
        [0-9a-f]*) printf '%s\n' "$tree"; return 0 ;;
    esac
    return 1
}

# ---------------------------------------------------------------------------
# rc_json_string <text>
# ---------------------------------------------------------------------------
rc_json_string() {
    RC_JSON_IN="${1-}" python3 -c 'import json,os,sys; sys.stdout.write(json.dumps(os.environ.get("RC_JSON_IN","")))'
}

# ---------------------------------------------------------------------------
# rc_build_job <out.json> <record-text-file> <baseline-1|-> <baseline-2|->
#              <message-file|-> <message-source> <action> <self-tree|->
# ---------------------------------------------------------------------------
# Requires rc_resolve_record to have run.
rc_build_job() {
    local out="${1:-}" rec="${2:-}" b1="${3:--}" b2="${4:--}" msg="${5:--}" \
          msrc="${6:-unavailable}" action="${7:-commit}" selftree="${8:--}"
    [ -n "$out" ] && [ -f "$rec" ] || return 2
    RC_JOB_OUT="$out" RC_JOB_REC="$rec" RC_JOB_B1="$b1" RC_JOB_B2="$b2" \
    RC_JOB_MSG="$msg" RC_JOB_MSRC="$msrc" RC_JOB_ACTION="$action" \
    RC_JOB_LABEL="$RC_RECORD_REL" RC_JOB_SECTIONS="$RC_ROW_SECTIONS" \
    RC_JOB_PREMISE_SECTIONS="${CT_PREMISE_SECTIONS:-}" \
    RC_JOB_PREMISE_REQUIRED="${CT_PREMISE_REQUIRED:-0}" \
    RC_JOB_TOKENS="$RC_STATUS_TOKENS" RC_JOB_TERMINAL="$RC_TERMINAL_TOKENS" \
    RC_JOB_CLAIM_WORDS="$RC_CLAIM_WORDS" \
    RC_JOB_ROOTS_OK="$CT_ROOTS_OK" RC_JOB_ROOTS_ABSENT="$CT_ROOTS_ABSENT" \
    RC_JOB_SELF_PREFIX="$RC_SELF_PREFIX" RC_JOB_SELF_TREE="$selftree" \
    RC_JOB_EXPLAIN="${RC_EXPLAIN:-}" \
    python3 - <<'PYEOF'
import json, os

def read(p):
    if not p or p == "-":
        return None
    try:
        with open(p, encoding="utf-8") as fh:
            return fh.read()
    except Exception:
        return None

def pairs(v):
    out = {}
    for item in (v or "").split("\t"):
        item = item.strip()
        if not item or "=" not in item:
            continue
        k, val = item.split("=", 1)
        out[k] = val
    return out

roots = pairs(os.environ.get("RC_JOB_ROOTS_OK"))
absent = pairs(os.environ.get("RC_JOB_ROOTS_ABSENT"))

revs = {}
self_prefix = os.environ.get("RC_JOB_SELF_PREFIX") or ""
self_tree = os.environ.get("RC_JOB_SELF_TREE") or "-"
if self_prefix and self_tree and self_tree != "-":
    revs[self_prefix] = self_tree

baselines = [b for b in (read(os.environ.get("RC_JOB_B1")),
                         read(os.environ.get("RC_JOB_B2"))) if b is not None]

job = {
    "record_label":    os.environ.get("RC_JOB_LABEL") or "<record>",
    "record_text":     read(os.environ.get("RC_JOB_REC")) or "",
    "baselines":       baselines,
    "row_sections":    (os.environ.get("RC_JOB_SECTIONS") or "").split(),
    "premise_sections": (os.environ.get("RC_JOB_PREMISE_SECTIONS") or "").split(),
    "premise_required": (os.environ.get("RC_JOB_PREMISE_REQUIRED") or "0") == "1",
    "status_tokens":   (os.environ.get("RC_JOB_TOKENS") or "").split(),
    "terminal_tokens": (os.environ.get("RC_JOB_TERMINAL") or "").split(),
    "claim_words":     (os.environ.get("RC_JOB_CLAIM_WORDS") or "").split(),
    "artifact_roots":  roots,
    "absent_roots":    absent,
    "identity_revs":   revs,
    "message":         read(os.environ.get("RC_JOB_MSG")),
    "message_source":  os.environ.get("RC_JOB_MSRC") or "unavailable",
    "action":          os.environ.get("RC_JOB_ACTION") or "commit",
    "explain":         bool(os.environ.get("RC_JOB_EXPLAIN")),
}
with open(os.environ["RC_JOB_OUT"], "w", encoding="utf-8") as fh:
    json.dump(job, fh)
PYEOF
}

# ---------------------------------------------------------------------------
# rc_run <job.json>
# ---------------------------------------------------------------------------
rc_run() {
    local job="${1:-}"
    [ -f "$_RC_LIB_DIR/row-currency.py" ] || {
        echo "ERROR: rc_run: scripts/lib/row-currency.py is missing" >&2
        return 2
    }
    python3 "$_RC_LIB_DIR/row-currency.py" "$job"
}

# ---------------------------------------------------------------------------
# rc_broken_banner <caller> <reason>
# ---------------------------------------------------------------------------
rc_broken_banner() {
    local who="${1:-row-currency}" why="${2:-}"
    echo "=== ROW CURRENCY: BROKEN DECLARATION — REFUSING ==="
    echo "  hook/tool : $who"
    echo "  reason    : $why"
    echo ""
    echo "  A contract that cannot be read is not a contract with nothing in it."
    echo "  Fix ${RC_DECLARATION_FILE:-$ROW_CURRENCY_DECLARATION}, or delete it to stand"
    echo "  this mechanism down deliberately and visibly. There is no in-the-moment"
    echo "  override, on purpose: the judgment that failed was made in the moment."
}

# ---------------------------------------------------------------------------
# rc_refusal <caller> <headline> <verdict-lines> <record-path>
# ---------------------------------------------------------------------------
rc_refusal() {
    local who="${1:-row-currency}" headline="${2:-}" result="${3:-}" label="${4:-<record>}"
    echo "=== ROW CURRENCY: $headline ==="
    echo "  record : $label"
    echo "  guard  : $who"
    echo ""
    # The census first, and with awk rather than inside the read loop below: a
    # `read -r kind a b c` splits a ten-field line into four and prints the tail
    # with its tab characters still in it. Same reason the guard and the CLI
    # both use awk for this line.
    printf '%s\n' "$result" | awk -F'\t' '$1=="PC" {printf "  PREMISE CENSUS  %s %s %s %s %s %s %s %s %s %s\n", $2,$3,$4,$5,$6,$7,$8,$9,$10,$11}'
    printf '%s\n' "$result" | while IFS="$(printf '\t')" read -r kind a b c; do
        case "$kind" in
            V)    printf '  BLOCK  item %s — %s\n         %s\n' "$a" "$b" "$c" ;;
            SKIP) printf '  SKIP   item %s — %s\n         %s\n' "$a" "$b" "$c" ;;
            NOTE) printf '  NOTE   %s\n         %s\n' "$a" "$b" ;;
            FIX)  printf '  PASTE  item %s should now carry:\n         %s\n' "$a" "$b" ;;
        esac
    done
    echo ""
    echo "  THE CONTRACT, in one sentence: a row that describes open work states the"
    echo "  identity of the work it describes, and when that identity changes the row"
    echo "  changes with it — in the same breath, not afterwards from memory."
    echo ""
    echo "  TO PROCEED: open $label, rewrite the row so it says what is true NOW, and"
    echo "  paste the warrant printed above. There is deliberately no command that"
    echo "  re-stamps a row for you: a re-stamp with nobody reading the sentence is"
    echo "  the original defect wearing a fix's clothes."
    echo ""
    echo "  TO CHECK BY HAND:  scripts/row-currency-lint.sh <repo>"
}
