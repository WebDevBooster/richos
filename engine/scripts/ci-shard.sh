#!/usr/bin/env bash
#
# ci-shard.sh — run one shard of the engine's verification units, and leave a
# RECEIPT that says which ones actually ran.
#
# ===========================================================================
# WHY A RECEIPT, AND NOT JUST AN EXIT CODE
# ===========================================================================
# Sharding a verification pass introduces a failure mode the serial runner does
# not have: a shard that runs FEWER units than it was given still exits 0. A
# section selector that stopped matching, a matrix entry that never started, a
# job stopped by a concurrency rule — each of those turns into a green tick on
# a commit nothing verified. That is the same defect as "all 18 suites green"
# when there were 23, which is the defect `run-all-tests.sh` was written to end,
# and it comes straight back the moment the pass is split across machines.
#
# So every unit this script runs is written to a receipt, one JSON object per
# line, carrying the unit id, the exit code, the verdict, the wall clock, the
# shard it belonged to and THE COMMIT IT RAN AT. `--verify-receipts` then reads
# every shard's receipt back and refuses unless:
#
#   * the union of units run equals the planned inventory EXACTLY — a missing
#     unit is named, an unplanned one is named,
#   * every receipt carries the SAME commit, so a shard that somehow checked
#     out a different tree cannot be averaged in with the others,
#   * and every unit reached a verdict this script is willing to call green.
#
# The exit code of the whole workflow is then a claim about a set somebody can
# read, rather than about twelve jobs nobody counted.
#
# ===========================================================================
# EXIT 3 IS A SCOPED SECTION'S GREEN, AND EXIT 0 IS ITS FAILURE
# ===========================================================================
# `contract-integrity.test.sh --only <section>` exits 3 when it is green,
# deliberately, so that nothing can read a partial run as a full pass. A shard
# therefore expects 3 from a section unit — and expects NEVER to see 0, because
# 0 from a scoped invocation would mean the scoping did not apply and the unit
# silently ran something other than what was asked. Both directions are
# checked; `ci-units.sh` supplies the expected code per unit as data.
#
# ===========================================================================
# THE LEAK CANARY IS NOT LOST BY SHARDING
# ===========================================================================
# `run-all-tests.sh` takes a per-suite leak baseline so a suite that writes
# outside its sandbox — or mutates a tracked engine file mid-run — is NAMED
# rather than bisected. Splitting the pass must not quietly drop that
# guarantee, so this script takes the same per-unit baseline through the same
# `lib/leak-canary.sh`, and refuses to report a pass if the canary could not
# witness one of its roots.
#
# ===========================================================================
# KNOWN-RED IS DECLARED, DATED, EXPIRING, AND ITS OWN NEGATIVE CONTROL
# ===========================================================================
# A suite can be red on `main` for a reason that is neither this gate's business
# nor its author's: on 2026-09-09 two suites were red on BOTH macOS and Linux
# because two commits changed a contract and did not update the suites that
# assert it. Leaving them red makes every check red forever, which is how a gate
# gets ignored; deleting or skipping their assertions hides a real defect, which
# is worse. So they are DECLARED, in `lib/ci-known-red.tsv`, with the date, the
# failing cases, the commit that broke them and an EXPIRY.
#
# Three rules keep that table from becoming a place defects go to die:
#
#   1. a declared unit that fails is reported KNOWN-RED and does not fail the
#      job — but it is printed, every run, with its expiry;
#   0. and a row may carry a CONDITION saying where it applies at all, because
#      the first entry that needed one was red on git >= 2.55 and green on 2.43
#      and 2.52 — an unconditional row would have been right on the runner and a
#      lie on the developer's machine, where rule 2 would then fire on every
#      local pass. Where the condition is false the unit is judged normally,
#      rule 2 included;
#   2. a declared unit that PASSES fails the job. The defect is fixed and the
#      entry is now a lie; delete it. This is the negative control, and without
#      it the table would silently outlive everything in it;
#   3. an entry past its expiry fails the job. The tolerance was time-boxed
#      when it was granted, and a decision — fix it, or re-declare it with a
#      reason — is forced rather than deferred indefinitely.
#
# Usage:
#   ci-shard.sh --shard <i>/<n>          run shard i of n of the full plan
#   ci-shard.sh --only-units <id[,id…]>  run exactly these units
#   ci-shard.sh --units-file <path>      run the units named in a file
#   ci-shard.sh --list                   print what would run, run nothing
#   ci-shard.sh --verify-receipts <dir>  the coverage proof over collected
#                                        receipts; runs no tests. Add
#                                        --units-file to certify a RESTRICTED
#                                        plan (the affected gate's set) rather
#                                        than the whole inventory.
#   ci-shard.sh --units-file <f> --shard i/N   pack THAT set into N shards and
#                                        run shard i — the affected gate on a
#                                        large diff, through the same planner
#                                        the full pass uses.
#   options: --receipt <path>  --verbose  --allow-empty  --shards <n>
#
# Exit codes:
#   0  every unit reached its expected verdict (KNOWN-RED counts as reached)
#   1  a unit failed, leaked, was declared-red-but-passed, or is past expiry;
#      or --verify-receipts found the union incomplete
#   2  usage, discovery, or a precondition (no units, unreadable engine)
# ===========================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UNITS_SH="$SCRIPT_DIR/ci-units.sh"
KNOWN_RED="$ENGINE_ROOT/scripts/lib/ci-known-red.tsv"

C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YEL=$'\033[33m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'

die() { printf '%sERROR: ci-shard.sh: %s%s\n' "$C_RED" "$1" "$C_RESET" >&2; exit "${2:-2}"; }

[ -f "$UNITS_SH" ] || die "missing $UNITS_SH — the unit inventory is not optional."

SHARD=""
SHARDS=""
ONLY_UNITS=""
UNITS_FILE=""
RECEIPT=""
VERIFY_DIR=""
LIST_ONLY=0
VERBOSE=0
ALLOW_EMPTY=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --shard)  [ "$#" -ge 2 ] || die "--shard needs <i>/<n> or <i>"
                  case "$2" in
                      */*) SHARD="${2%%/*}"; SHARDS="${2##*/}" ;;
                      *)   SHARD="$2" ;;
                  esac
                  shift 2 ;;
        --shards) [ "$#" -ge 2 ] || die "--shards needs a count"; SHARDS="$2"; shift 2 ;;
        --only-units) [ "$#" -ge 2 ] || die "--only-units needs a comma-separated list"
                  ONLY_UNITS="$ONLY_UNITS,$2"; shift 2 ;;
        --units-file) [ "$#" -ge 2 ] || die "--units-file needs a path"; UNITS_FILE="$2"; shift 2 ;;
        --receipt) [ "$#" -ge 2 ] || die "--receipt needs a path"; RECEIPT="$2"; shift 2 ;;
        --verify-receipts) [ "$#" -ge 2 ] || die "--verify-receipts needs a directory"; VERIFY_DIR="$2"; shift 2 ;;
        --list) LIST_ONLY=1; shift ;;
        --verbose|-v) VERBOSE=1; shift ;;
        --allow-empty) ALLOW_EMPTY=1; shift ;;
        -h|--help) sed -n '/^# Usage:/,/^# =\{10,\}$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unrecognized argument '$1' — see --help" ;;
    esac
done

[ -z "$SHARDS" ] && SHARDS="$(bash "$UNITS_SH" shard-count)"

# The commit under test. Baked into every receipt so the coverage proof can
# refuse a set of shards that did not all verify the same tree — identity, not
# a timestamp and not "the checkout said success".
sha_now() {
    git -C "$ENGINE_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown'
}

# ---------------------------------------------------------------------------
# the known-red table
# ---------------------------------------------------------------------------
# id <TAB> classified <TAB> expires <TAB> broken-by <TAB> failing <TAB> why [<TAB> when]
kr_field() { # <unit-id> <column>
    [ -f "$KNOWN_RED" ] || return 1
    awk -F'\t' -v want="$1" -v col="$2" '
        /^#/ { next } NF < 6 { next }
        $1 == want { print $col; found=1; exit }
        END { exit(found ? 0 : 1) }' "$KNOWN_RED"
}

# THE OPTIONAL SEVENTH COLUMN: a shell predicate saying WHERE the row applies.
#
# Added 2026-09-10, because the first entry that needed it proved the table
# could not describe a real defect. `scripts/lib/worktree-ledger.test.sh` is red
# on git >= 2.55 — which is what `ubuntu-latest` ships — and GREEN on 2.43 and
# on 2.52. An unconditional row would therefore be correct on the runner and a
# LIE on the machine the engine is developed on, where rule 2 would fire on
# every local full pass with "declared red, but it PASSED". A mechanism that can
# only say "red everywhere" describes a defect shape that is not the common one:
# this tree already carries launchd-only and darwin-only cases.
#
# Empty or absent means the row always applies, so every existing row keeps its
# meaning. A predicate that exits NON-ZERO means the row does not apply here and
# the unit is judged normally — including rule 2, so a host where the defect
# does not exist still gets a real verdict rather than a tolerated one.
#
# AN UNRUNNABLE PREDICATE IS NOT A PASS. If the condition cannot be evaluated,
# the row is treated as APPLYING and the reason is printed: a condition that
# silently fails open would turn the whole table back into a skip list, one
# broken shell expression at a time.
kr_applies() { # <unit-id> — 0 when the row is in force here
    local cond
    cond="$(kr_field "$1" 7 2>/dev/null || true)"
    [ -n "$cond" ] || return 0
    if bash -c "$cond" >/dev/null 2>&1; then
        return 0
    fi
    # distinguish "predicate said no" from "predicate could not run"
    if ! bash -n -c "$cond" >/dev/null 2>&1; then
        printf '%sWARNING%s ci-shard.sh: the known-red condition for %s is not valid shell (%s);\n' \
            "$C_YEL" "$C_RESET" "$1" "$cond" >&2
        printf '        treating the row as APPLYING rather than failing open.\n' >&2
        return 0
    fi
    return 1
}

kr_declared() { kr_field "$1" 1 >/dev/null 2>&1 && kr_applies "$1"; }
kr_expired()  { # <unit-id> — 0 when today is past the expiry
    local exp; exp="$(kr_field "$1" 3 2>/dev/null)" || return 1
    [ -n "$exp" ] || return 1
    [ "$(date -u +%Y-%m-%d)" \> "$exp" ]
}

# ---------------------------------------------------------------------------
# --verify-receipts: the coverage proof. Runs nothing.
# ---------------------------------------------------------------------------
if [ -n "$VERIFY_DIR" ]; then
    [ -d "$VERIFY_DIR" ] || die "--verify-receipts: no such directory: $VERIFY_DIR"
    PLAN_FILE="$(mktemp)"; trap 'rm -f "$PLAN_FILE"' EXIT
    # With --units-file the plan being certified is that SET, not the whole
    # inventory: the affected gate covers what the diff selected, and checking
    # its receipts against all 148 units would report 94 false absences.
    if [ -n "$UNITS_FILE" ]; then
        [ -f "$UNITS_FILE" ] || die "--units-file: no such file: $UNITS_FILE"
        bash "$UNITS_SH" units --units-file "$UNITS_FILE" | cut -f1 | LC_ALL=C sort > "$PLAN_FILE" \
            || die "could not read the restricted inventory"
    else
        bash "$UNITS_SH" units | cut -f1 | LC_ALL=C sort > "$PLAN_FILE" || die "could not read the planned inventory"
    fi
    find "$VERIFY_DIR" -type f -name '*.jsonl' -print0 2>/dev/null | xargs -0 cat 2>/dev/null \
        | python3 "$SCRIPT_DIR/lib/ci-receipts.py" verify --plan "$PLAN_FILE"
    exit $?
fi

# ---------------------------------------------------------------------------
# which units this invocation owns
# ---------------------------------------------------------------------------
ALL_UNITS="$(mktemp)"; SELECTED="$(mktemp)"
trap 'rm -f "$ALL_UNITS" "$SELECTED"' EXIT
bash "$UNITS_SH" units > "$ALL_UNITS" || die "ci-units.sh failed — the inventory could not be built."

resolve_selection() {
    # --units-file AND --shard together: pack THAT set and take shard i of it.
    # The affected gate uses this, so a large diff is spread across machines by
    # exactly the planner the full pass uses rather than by a second mechanism
    # that has to be kept in step with it.
    if [ -n "$UNITS_FILE" ] && [ -n "$SHARD" ]; then
        [ -f "$UNITS_FILE" ] || die "--units-file: no such file: $UNITS_FILE"
        bash "$UNITS_SH" shards "$SHARDS" --units-file "$UNITS_FILE" \
            | awk -F'\t' -v i="$SHARD" '$1 == i { print $2 }' | LC_ALL=C sort
        return 0
    fi
    if [ -n "$ONLY_UNITS" ] || [ -n "$UNITS_FILE" ]; then
        {
            printf '%s' "${ONLY_UNITS#,}" | tr ',' '\n'
            [ -n "$UNITS_FILE" ] && { [ -f "$UNITS_FILE" ] || die "--units-file: no such file: $UNITS_FILE"; cat "$UNITS_FILE"; }
        } | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | grep -v '^#' | LC_ALL=C sort -u
        return 0
    fi
    if [ -n "$SHARD" ]; then
        bash "$UNITS_SH" shards "$SHARDS" | awk -F'\t' -v i="$SHARD" '$1 == i { print $2 }' | LC_ALL=C sort
        return 0
    fi
    # No selector at all is the WHOLE inventory in one process. Honest, and
    # the two-hour run this exists to replace, so it is allowed but named.
    cut -f1 "$ALL_UNITS" | LC_ALL=C sort
}

resolve_selection > "$SELECTED"

# Every selected id must be a real unit. An id that matches nothing is fatal:
# a shard silently selecting nothing is the whole failure this file is about.
UNKNOWN=0
while IFS= read -r id; do
    [ -n "$id" ] || continue
    if ! cut -f1 "$ALL_UNITS" | grep -qxF "$id"; then
        printf '%sERROR%s ci-shard.sh: %s is not a unit in the current inventory.\n' "$C_RED" "$C_RESET" "$id" >&2
        UNKNOWN=1
    fi
done < "$SELECTED"
[ "$UNKNOWN" -eq 0 ] || die "one or more requested units do not exist — run 'ci-units.sh units' to see the inventory." 2

N_SEL="$(grep -c . "$SELECTED" || true)"
if [ "${N_SEL:-0}" -eq 0 ]; then
    if [ "$ALLOW_EMPTY" -eq 1 ]; then
        printf '%s— ci-shard.sh: no units selected, and --allow-empty was given. Nothing was verified.%s\n' "$C_YEL" "$C_RESET"
        [ -n "$RECEIPT" ] && : > "$RECEIPT"
        exit 0
    fi
    die "no units selected. A shard that verifies nothing must never exit 0 — pass --allow-empty only where an empty selection is a real answer." 2
fi

if [ "$LIST_ONLY" -eq 1 ]; then
    cat "$SELECTED"
    printf '%s unit(s) selected of %s in the inventory\n' "$N_SEL" "$(grep -c . "$ALL_UNITS")" >&2
    exit 0
fi

# ---------------------------------------------------------------------------
# the leak canary — same library, same contract as run-all-tests.sh
# ---------------------------------------------------------------------------
for lib in tree-witness leak-canary record-canary; do
    [ -f "$ENGINE_ROOT/scripts/lib/$lib.sh" ] \
        || die "scripts/lib/$lib.sh is missing; refusing to report a pass with the sandbox check absent." 2
done
# shellcheck source=lib/tree-witness.sh
. "$ENGINE_ROOT/scripts/lib/tree-witness.sh"
# shellcheck source=lib/leak-canary.sh
. "$ENGINE_ROOT/scripts/lib/leak-canary.sh"
# the operator's record (ledger, fallback event log, team directories), per
# unit — the same library and contract as run-all-tests.sh (round 15)
# shellcheck source=lib/record-canary.sh
. "$ENGINE_ROOT/scripts/lib/record-canary.sh"

LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ci-shard.XXXXXX")"
trap 'rm -f "$ALL_UNITS" "$SELECTED"; rm -rf "$LOG_DIR"' EXIT
tw_pick_mtime "$LOG_DIR"
lc_add_root "$PWD"
lc_add_root "$ENGINE_ROOT"
[ "$(lc_count)" -gt 0 ] || die "the leak canary resolved NO watched root; it would report 'nothing leaked' without looking at anything." 2

SHA="$(sha_now)"
LABEL="${SHARD:+shard $SHARD/$SHARDS}"
printf '%s=== ci-shard: %s unit(s)%s at %s ===%s\n' \
    "$C_BOLD" "$N_SEL" "${LABEL:+, $LABEL}" "$SHA" "$C_RESET"

[ -n "$RECEIPT" ] && { mkdir -p "$(dirname "$RECEIPT")" 2>/dev/null; : > "$RECEIPT"; }

PASSED=0; FAILED=0; KNOWNRED=0
FAIL_LINES=()
i=0
while IFS= read -r id; do
    [ -n "$id" ] || continue
    i=$((i + 1))
    EXPECT_RC="$(awk -F'\t' -v want="$id" '$1 == want { print $3; exit }' "$ALL_UNITS")"
    LOG="$LOG_DIR/$i.log"
    printf '  [%3s/%3s] %-72s ' "$i" "$N_SEL" "$id"

    CANARY_DIR="$LOG_DIR/canary.$i"
    LC_HEALTHY=1
    lc_baseline "$CANARY_DIR"
    CANARY_BASE_HEALTHY="$LC_HEALTHY"
    rc_baseline "$CANARY_DIR/record.txt"
    RECORD_BASE_HEALTHY="$RC_HEALTHY"

    # The argv comes from ci-units.sh, so "how is a unit invoked" has exactly
    # one definition and a section's --only cannot drift from its id.
    ARGV=()
    while IFS= read -r tok; do ARGV+=("$tok"); done < <(bash "$UNITS_SH" cmd "$id" | tr '\t' '\n')

    START="$(python3 -c 'import time; print(time.time())')"
    "${ARGV[@]}" >"$LOG" 2>&1
    RC=$?
    END="$(python3 -c 'import time; print(time.time())')"
    SECS="$(python3 -c "print(round($END - $START, 1))")"

    ESCAPED="$(lc_escaped "$CANARY_DIR" "$LOG_DIR")"
    TOUCHED="$(rc_escaped "$CANARY_DIR/record.txt")"

    VERDICT=""
    if [ "$CANARY_BASE_HEALTHY" -ne 1 ] || [ "$RECORD_BASE_HEALTHY" -ne 1 ]; then
        VERDICT="CANARY-BLIND"
    elif [ -n "$TOUCHED" ]; then
        VERDICT="RECORD-TOUCHED"
    elif [ -n "$ESCAPED" ]; then
        VERDICT="LEAKED"
    elif [ "$EXPECT_RC" = "3" ] && [ "$RC" -eq 0 ]; then
        # Named as its own verdict rather than folded into FAIL: this one does
        # not mean the assertions failed, it means the SCOPING did not apply
        # and the unit ran something other than what its id says.
        VERDICT="SCOPE-LOST"
    elif [ "$RC" -eq "${EXPECT_RC:-0}" ]; then
        VERDICT="PASS"
    else
        VERDICT="FAIL"
    fi

    # known-red only ever RE-LABELS a failure, and only when the entry is live
    if kr_declared "$id"; then
        if kr_expired "$id"; then
            VERDICT="KNOWN-RED-EXPIRED"
        elif [ "$VERDICT" = "PASS" ]; then
            VERDICT="KNOWN-RED-BUT-PASSED"
        elif [ "$VERDICT" = "FAIL" ]; then
            VERDICT="KNOWN-RED"
        fi
    fi

    case "$VERDICT" in
        PASS)
            printf '%sPASS%s %ss\n' "$C_GREEN" "$C_RESET" "$SECS"
            PASSED=$((PASSED + 1))
            [ "$VERBOSE" -eq 1 ] && sed 's/^/        /' "$LOG"
            ;;
        KNOWN-RED)
            printf '%sKNOWN-RED%s %ss (expires %s)\n' "$C_YEL" "$C_RESET" "$SECS" "$(kr_field "$id" 3)"
            KNOWNRED=$((KNOWNRED + 1))
            printf '        declared %s, broken by %s: %s\n' \
                "$(kr_field "$id" 2)" "$(kr_field "$id" 4)" "$(kr_field "$id" 6)"
            CONDW="$(kr_field "$id" 7 2>/dev/null || true)"
            [ -n "$CONDW" ] && printf '        applies only where: %s\n' "$CONDW"
            printf '        failing: %s\n' "$(kr_field "$id" 5)"
            ;;
        KNOWN-RED-EXPIRED)
            printf '%sFAIL%s %ss — known-red entry EXPIRED\n' "$C_RED" "$C_RESET" "$SECS"
            FAILED=$((FAILED + 1))
            FAIL_LINES+=("$id — its known-red entry expired on $(kr_field "$id" 3). The tolerance was time-boxed when it was granted: either fix the suite, or re-declare the entry with a new expiry and a reason. Broken by $(kr_field "$id" 4).")
            ;;
        KNOWN-RED-BUT-PASSED)
            printf '%sFAIL%s %ss — declared red, but it PASSED\n' "$C_RED" "$C_RESET" "$SECS"
            FAILED=$((FAILED + 1))
            FAIL_LINES+=("$id — lib/ci-known-red.tsv declares this unit red and it PASSED. The defect is fixed; DELETE the entry. A known-red table that outlives its defects is how a skip becomes permanent.")
            ;;
        SCOPE-LOST)
            printf '%sFAIL%s %ss — scoped run exited 0\n' "$C_RED" "$C_RESET" "$SECS"
            FAILED=$((FAILED + 1))
            FAIL_LINES+=("$id — a scoped section exited 0, which it must never do: 3 is its green. The --only selector did not apply, so this unit did not run what its id says.")
            sed 's/^/        /' "$LOG"
            ;;
        LEAKED)
            printf '%sFAIL%s %ss — wrote outside its sandbox\n' "$C_RED" "$C_RESET" "$SECS"
            FAILED=$((FAILED + 1))
            FAIL_LINES+=("$id — wrote outside its sandbox")
            printf '%s\n' "$ESCAPED" | while IFS="$(printf '\t')" read -r croot centry; do
                if lc_is_tracked_change "$centry"; then
                    printf '        TRACKED FILE CHANGED DURING THE RUN — every unit after this one tested different code:\n'
                else
                    printf '        WROTE OUTSIDE ITS SANDBOX — residue a stranger will have to explain:\n'
                fi
                printf '          %s  (under %s)\n' "$centry" "$croot"
            done
            ;;
        RECORD-TOUCHED)
            printf '%sFAIL%s %ss — touched the operator'"'"'s record\n' "$C_RED" "$C_RESET" "$SECS"
            FAILED=$((FAILED + 1))
            FAIL_LINES+=("$id — touched the operator's record under $RC_CFG")
            printf '        TOUCHED THE OPERATOR'"'"'S RECORD — the class that wrote a false termination for a running agent on 2026-09-11:\n'
            printf '%s\n' "$TOUCHED" | sed 's/^/          /'
            ;;
        CANARY-BLIND)
            printf '%sFAIL%s %ss — canary blind\n' "$C_RED" "$C_RESET" "$SECS"
            FAILED=$((FAILED + 1))
            FAIL_LINES+=("$id — a canary could not witness one of its roots (leak: $CANARY_BASE_HEALTHY, record: $RECORD_BASE_HEALTHY), so this is NOT reported as a pass")
            ;;
        *)
            printf '%sFAIL%s %ss (rc=%s, expected %s)\n' "$C_RED" "$C_RESET" "$SECS" "$RC" "$EXPECT_RC"
            FAILED=$((FAILED + 1))
            FAIL_LINES+=("$id (rc=$RC, expected $EXPECT_RC)")
            sed 's/^/        /' "$LOG"
            ;;
    esac

    if [ -n "$RECEIPT" ]; then
        UNIT_ID="$id" UNIT_RC="$RC" UNIT_EXP="${EXPECT_RC:-0}" UNIT_VERDICT="$VERDICT" \
        UNIT_SECS="$SECS" UNIT_SHARD="${SHARD:-0}" UNIT_SHARDS="$SHARDS" UNIT_SHA="$SHA" \
        python3 "$SCRIPT_DIR/lib/ci-receipts.py" emit >> "$RECEIPT"
    fi
done < "$SELECTED"

echo ""
if [ "$FAILED" -eq 0 ]; then
    printf '%s✓ ci-shard%s: %s/%s unit(s) passed' "$C_GREEN" "${LABEL:+ $LABEL}" "$PASSED" "$N_SEL"
    [ "$KNOWNRED" -gt 0 ] && printf ', %s declared KNOWN-RED (see lib/ci-known-red.tsv)' "$KNOWNRED"
    printf '.%s\n' "$C_RESET"
    exit 0
fi
printf '%s✗ ci-shard%s: %s/%s unit(s) passed, %s FAILED.%s\n' \
    "$C_RED" "${LABEL:+ $LABEL}" "$PASSED" "$N_SEL" "$FAILED" "$C_RESET" >&2
for l in "${FAIL_LINES[@]}"; do printf '    - %s\n' "$l" >&2; done
exit 1
