#!/usr/bin/env bash
#
# entrypoint-currency-lint.sh — DOES THE INSTRUCTION STILL NAME THE OLD PATH?
#
# ===========================================================================
# THE ONE QUESTION THIS ANSWERS
# ===========================================================================
# For every supersession declared in orchestration.config ENTRYPOINTS, and for
# every standing instruction declared in INSTRUCTION_SURFACES: does an
# instruction name a SUPERSEDED entrypoint while never naming the one that
# REPLACED it?
#
# That is the whole rule, and it is stated that way on purpose. It is not a
# language check. It does not decide whether a sentence is imperative, does not
# grade tone, and has no opinion about prose — because a check over prose with a
# large false-positive class gets waived on the day it lands, and a habitually
# waived check is worse than no check at all. This repository recorded three
# instances of exactly that pattern in one day.
#
# WHAT IT CATCHES, AND THE COST OF THE SIMPLE RULE
# ------------------------------------------------
# It catches the thing that actually cost the founder money: an instruction
# surface that routes people to a replaced command and has never heard of its
# replacement. `scripts/hooks/engine-status.sh` names prepare-agent-spawn.py and
# create-teammate-worktree.sh, and the string "spawn.sh" does not appear in it
# anywhere. femcboost/CLAUDE.md says "Rich creates every one with
# create-teammate-worktree.sh" and likewise never names spawn.sh. Both are found.
#
# It does NOT catch a surface that names both — one that says "use spawn.sh" in
# its spawn section and mentions create-teammate-worktree.sh 200 lines later in a
# ledger note passes, and SO DOES a badly-written one that names the replacement
# somewhere irrelevant. That is a real gap and it is deliberate: the tighter rule
# (proximity, or an imperative-verb list) is the one that fires on correct files,
# and this check is worth more enforced-and-coarse than clever-and-waived. The
# residue is left to attention, and it is named here so nobody believes coverage
# this does not have.
#
# ===========================================================================
# WHAT IT NEVER DOES
# ===========================================================================
# It does not change any guard's behavior, and superseded entrypoints keep
# working. This governs what we TELL people. spawn.sh itself CALLS both of the
# commands it supersedes.
#
# ===========================================================================
# THE EXEMPTION, AND WHY IT IS DECLARED RATHER THAN INFERRED
# ===========================================================================
# A legitimate mention must stay possible: a migration note, a history section, a
# test asserting the old path still works. A line carrying
#
#     entrypoint-exempt: <reason>
#
# is not checked. The reason is required and must be substantive — a bare marker
# exempts nothing, the same discipline `dialect-exempt:` and the contrast floor
# use. Calling a mention exempt is a CLAIM, and the claim sits on the line where
# a reviewer sees it.
#
# ===========================================================================
# USAGE
# ===========================================================================
#   entrypoint-currency-lint.sh [--root <repo>] [--engine <path>] [--list]
#
#   --root    the repository whose instruction surfaces are scanned
#             (default: the resolved entity root, else the current repository)
#   --engine  the engine root, used to find the fallback declaration
#   --list    print the resolved declaration and surfaces, scan nothing
#
# Exit codes:
#   0  no standing instruction names a superseded entrypoint without its
#      replacement (or nothing is declared, which is announced, not passed off
#      as clean)
#   1  findings, each naming file:line, the superseded entrypoint, and the
#      canonical one
#   2  usage error, or a declaration this cannot parse

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/lib/entrypoints.sh"

ROOT=""
ENGINE=""
LIST_ONLY=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --root)   [ "$#" -ge 2 ] || { echo "entrypoint-currency-lint.sh: --root needs a path" >&2; exit 2; }; ROOT="$2"; shift 2 ;;
        --root=*) ROOT="${1#--root=}"; shift ;;
        --engine)   [ "$#" -ge 2 ] || { echo "entrypoint-currency-lint.sh: --engine needs a path" >&2; exit 2; }; ENGINE="$2"; shift 2 ;;
        --engine=*) ENGINE="${1#--engine=}"; shift ;;
        --list) LIST_ONLY=1; shift ;;
        -h|--help)
            sed -n '/^# USAGE/,/^#   2  usage error/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "entrypoint-currency-lint.sh: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

[ -f "$LIB" ] || { echo "entrypoint-currency-lint.sh: the declaration parser is missing at $LIB — refusing to decide which command is current without it" >&2; exit 2; }
# shellcheck disable=SC1090
. "$LIB"

# --- roots -----------------------------------------------------------------
# The engine root is this script's own parent. The entity root defaults to the
# repository the caller is standing in; callers that already know better (the
# probe, a test) pass --root.
[ -n "$ENGINE" ] || ENGINE="$(cd "$SCRIPT_DIR/.." && pwd)"
if [ -z "$ROOT" ]; then
    if ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then :; else ROOT="$PWD"; fi
fi
[ -d "$ROOT" ] || { echo "entrypoint-currency-lint.sh: --root '$ROOT' is not a directory" >&2; exit 2; }

# --- the declaration -------------------------------------------------------
# Entity first, then the engine — the same resolution OWNED_SYSTEMS_DECLARATION
# uses, and for the same reason: an adopting repository may declare its own
# supersessions, and one that declares none still inherits the engine's, because
# the engine's scripts are the ones its instructions name.
_ep_read_key() {
    # _ep_read_key <config-file> <KEY> — prints the value of a simple
    # KEY="value" assignment without sourcing the file (sourcing an entity's
    # config here would import every other key it sets into this process).
    local f="$1" k="$2" line
    [ -f "$f" ] || { printf ''; return 0; }
    line="$(grep -E "^[[:space:]]*$k=" "$f" 2>/dev/null | tail -1 || true)"
    [ -n "$line" ] || { printf ''; return 0; }
    line="${line#*=}"
    line="${line%\"}"
    line="${line#\"}"
    printf '%s' "$line"
}

ENTITY_CONFIG="$ROOT/orchestration.config"
ENGINE_CONFIG="$ENGINE/orchestration.config"

SPEC="$(_ep_read_key "$ENTITY_CONFIG" ENTRYPOINTS)"
SPEC_SOURCE="$ENTITY_CONFIG"
if [ -z "$(printf '%s' "$SPEC" | tr -d '[:space:]')" ]; then
    SPEC="$(_ep_read_key "$ENGINE_CONFIG" ENTRYPOINTS)"
    SPEC_SOURCE="$ENGINE_CONFIG"
fi

SURFACES="$(_ep_read_key "$ENTITY_CONFIG" INSTRUCTION_SURFACES)"
SURFACES_SOURCE="$ENTITY_CONFIG"
if [ -z "$(printf '%s' "$SURFACES" | tr -d '[:space:]')" ]; then
    SURFACES="$(_ep_read_key "$ENGINE_CONFIG" INSTRUCTION_SURFACES)"
    SURFACES_SOURCE="$ENGINE_CONFIG"
fi

# BLANK IS ANNOUNCED, NEVER PASSED OFF AS CLEAN. An undeclared supersession set
# that exited 0 silently would look exactly like a repository with nothing stale
# in it, and this engine has twice shipped a green check over a defense that was
# not running.
if [ -z "$(printf '%s' "$SPEC" | tr -d '[:space:]')" ]; then
    echo "entrypoint-currency-lint: NOTHING IS DECLARED. No ENTRYPOINTS in $ENTITY_CONFIG or $ENGINE_CONFIG, so no supersession is known and nothing was checked. This is a stand-down, not a pass: declare a record the day a mechanism is replaced — <task> | <the command today> | <what it replaced>." >&2
    exit 0
fi

SPEC_PROBLEM="$(entrypoints_problem "$SPEC")"
if [ -n "$SPEC_PROBLEM" ]; then
    echo "entrypoint-currency-lint: ENTRYPOINTS in $SPEC_SOURCE: $SPEC_PROBLEM. Until the declaration parses, nothing checks whether a standing instruction still names a replaced command." >&2
    exit 2
fi

if [ -z "$(printf '%s' "$SURFACES" | tr -d '[:space:]')" ]; then
    echo "entrypoint-currency-lint: ENTRYPOINTS is declared in $SPEC_SOURCE but INSTRUCTION_SURFACES is blank in both $ENTITY_CONFIG and $ENGINE_CONFIG — the declaration has nothing to be checked against, so nothing was checked. Name the files that tell somebody what to do." >&2
    exit 0
fi

if [ "$LIST_ONLY" -eq 1 ]; then
    echo "declaration: $SPEC_SOURCE"
    echo "surfaces:    $SURFACES_SOURCE"
    echo "root:        $ROOT"
    echo
    printf '%-34s %-30s %s\n' "TASK" "CANONICAL TODAY" "SUPERSEDES"
    while IFS="$(printf '\t')" read -r task canon sup; do
        [ -n "$canon" ] || continue
        printf '%-34s %-30s %s\n' "$task" "$canon" "${sup:-(nothing)}"
    done <<EP_LIST_EOF
$(entrypoints_records "$SPEC")
EP_LIST_EOF
    echo
    echo "surfaces checked (patterns, relative to root):"
    # set -f: the patterns are DATA. Splitting them with globbing on would let
    # the current working directory rewrite the declaration — a cwd that happens
    # to contain a skills/ tree would replace `skills/*/SKILL.md` with ITS files
    # before the root was ever prefixed, and the lint would report on a
    # repository nobody asked about.
    set -f
    for pat in $SURFACES; do echo "  $pat"; done
    set +f
    exit 0
fi

# --- collect the surfaces --------------------------------------------------
# A pattern matching nothing is silent: one list serves the engine and every
# governed repository, and a repository without skills/ is not a finding.
FILES=""
set -f
set -- $SURFACES
set +f
for pat in "$@"; do
    for f in $ROOT/$pat; do
        [ -f "$f" ] || continue
        case " $FILES " in
            *" $f "*) ;;
            *) FILES="${FILES:+$FILES }$f" ;;
        esac
    done
done

if [ -z "$FILES" ]; then
    echo "entrypoint-currency-lint: no instruction surface exists in $ROOT (patterns from $SURFACES_SOURCE matched no file). Nothing to check." >&2
    exit 0
fi

SUPERSEDED_NAMES="$(entrypoints_superseded_names "$SPEC")"

FINDINGS=0
SCANNED=0

for f in $FILES; do
    SCANNED=$((SCANNED + 1))
    for sname in $SUPERSEDED_NAMES; do
        # Every line naming this superseded entrypoint, minus the ones carrying a
        # substantive exemption.
        hits="$(grep -n -F "$sname" "$f" 2>/dev/null || true)"
        [ -n "$hits" ] || continue

        rec="$(entrypoint_record_for_superseded "$sname" "$SPEC")"
        cname="$(printf '%s' "$rec" | awk -F'\t' '{print $1}')"
        cpath="$(printf '%s' "$rec" | awk -F'\t' '{print $2}')"
        ctask="$(printf '%s' "$rec" | awk -F'\t' '{print $3}')"

        # THE RULE: naming the old command is fine as long as this file also
        # names the one that replaced it. A migration note, a release note and a
        # "we used to do X, now do Y" all name Y by construction and pass.
        if grep -q -F "$cname" "$f" 2>/dev/null; then
            continue
        fi

        while IFS= read -r hit; do
            [ -n "$hit" ] || continue
            lno="${hit%%:*}"
            text="${hit#*:}"

            # Declared exemption. A bare marker exempts nothing: the reason must
            # be substantive, because an undeclared exemption is a stale
            # instruction wearing a justification.
            case "$text" in
                *"entrypoint-exempt:"*)
                    reason="${text#*entrypoint-exempt:}"
                    reason="$(printf '%s' "$reason" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
                    rwords="$(printf '%s' "$reason" | wc -w | tr -d ' ')"
                    rchars="$(printf '%s' "$reason" | wc -c | tr -d ' ')"
                    if [ "$rchars" -ge 20 ] && [ "$rwords" -ge 4 ]; then
                        continue
                    fi
                    echo "$f:$lno: entrypoint-exempt: carries no reason ('$reason') — a bare marker exempts nothing. Say why naming '$sname' here is a legitimate mention rather than an instruction." >&2
                    FINDINGS=$((FINDINGS + 1))
                    continue
                    ;;
            esac

            FINDINGS=$((FINDINGS + 1))
            echo "$f:$lno: STANDING INSTRUCTION NAMES A SUPERSEDED ENTRYPOINT." >&2
            echo "    names:      $sname" >&2
            echo "    superseded by: $cpath  (task: $ctask)" >&2
            echo "    and '$cname' appears NOWHERE in this file — so a reader following this instruction takes the replaced path and never learns there is another one." >&2
            echo "    declared in: $SPEC_SOURCE (ENTRYPOINTS)" >&2
            echo "    fix: change the instruction to name $cpath. Mentioning $sname alongside it is fine — spawn.sh calls the commands it supersedes — and a genuinely historical mention takes 'entrypoint-exempt: <reason>' on the line." >&2
        done <<EP_HITS_EOF
$hits
EP_HITS_EOF
    done
done

if [ "$FINDINGS" -gt 0 ]; then
    echo >&2
    echo "entrypoint-currency-lint: $FINDINGS finding(s) across $SCANNED instruction surface(s) in $ROOT." >&2
    echo "A capability that ships while the instruction keeps directing traffic to the thing it replaced is not landed — it is paid for and unused. That is failure type V, 2026-09-13: 130 s and two guard refusals per session against 1.3 s, reported as success every time." >&2
    exit 1
fi

echo "entrypoint-currency-lint: clean — $SCANNED instruction surface(s) in $ROOT, $(printf '%s' "$SUPERSEDED_NAMES" | wc -w | tr -d ' ') superseded entrypoint(s) declared in $SPEC_SOURCE, and every surface that names one also names its replacement."
exit 0
