#!/usr/bin/env bash
#
# publication-completeness.sh — THE MIRROR OF THE PUBLICATION BOUNDARY.
#
# ===========================================================================
# WHY THIS FILE EXISTS
# ===========================================================================
# On 2026-08-29 the publication boundary was built, and it works: it blocked
# five separate attempts to put private speech into the tree that goes public.
# It answers one question, completely —
#
#       MAY THIS LEAVE?
#
# and it has nothing to say about the other one:
#
#       IS EVERYTHING THAT MUST BE THERE, THERE — AND USABLE BY SOMEONE WHO
#       HAS ONLY THE PUBLIC REPOSITORY?
#
# That half was decided by hand, per artifact, all day. It was got wrong four
# times in one day, and all four are the same shape:
#
#   1. SHIPPED INERT. The engine shipped ceo-todos-lint.sh,
#      guard-ceo-todos-commits.sh, lib/ceo-todos.{sh,py} and a full test suite
#      — and no `.ceo-todos`, no template of one, and no mention in
#      ONBOARDING-RUNBOOK.md, WALKTHROUGH.md or the bootstrap-interview skill.
#      A customer receives enforcement machinery that can never fire.
#
#   2. MECHANISM IN THE PRIVATE TREE. The TODOs RENDERER — the only thing that
#      turns the record into something a CEO can look at — stayed in
#      richos-hq/scripts/. The customer got the enforcement and not the view.
#
#   3. UNREACHABLE BY CONSTRUCTION. engine/.github/workflows/
#      engine-self-verify.yml had never executed once, because GitHub Actions
#      discovers workflows only at a repository root. Not broken. Unreachable.
#
#   4. A CLAIM WITH NOTHING BEHIND IT. tools/richos-service/companion-windows/
#      README.md cites `.github/workflows/windows-companion-ci.yml` twice,
#      including "CI runs exactly this on windows-latest". That file exists in
#      no repository anywhere.
#
#   EVERY ONE IS THE PUBLIC TREE CLAIMING A CAPABILITY IT DOES NOT DELIVER.
#
# A leak guard cannot see any of them, because nothing leaked. This is the
# check for the other direction, and it is the same object one reflection over:
# the boundary derives "private" from declared sources and content; this
# derives "complete" from what the tree already declares about itself.
#
# ===========================================================================
# THE RULE THIS FILE MUST NOT BREAK
# ===========================================================================
# DO NOT BUILD A RULE SOMEONE MUST REMEMBER, AND DO NOT BUILD A HAND-MAINTAINED
# INVENTORY OF CAPABILITIES. Both failure modes are already in this engine's
# history, several times in one week: a hand-typed "13/13 guards" that was not
# the registration; an "18/18 suites" that was one glob's size and not the
# inventory; a decode flag documented as primary and wired to the tier nobody
# ran. A typed list of "capabilities that must ship" would go stale by Tuesday
# and would then be reporting a comfortable fraction over the wrong set.
#
# So nothing here is typed. Every input is derived:
#
#   the tree           `git ls-files` — tracked-and-not-ignored is not an
#                      approximation of what an adopter receives, it IS what an
#                      adopter receives
#   the declarations   grepped out of the shipped source that reads them, via
#                      the `${X_DECLARATION:=.name}` convention the engine
#                      already uses for both of its declaration-gated guards
#   the onboarding set README.md plus the transitive closure of the markdown it
#                      links to, plus every shipped SKILL.md
#   the workflows      the paths GitHub Actions itself discovers
#   the private trees  PRIVATE_SOURCES in .publication-boundary — the operator
#                      already maintains it for the boundary guard, and one
#                      declaration read by two contracts cannot drift apart
#
# ===========================================================================
# WHY NOT EXTEND scripts/demo.sh
# ===========================================================================
# demo.sh already builds a fresh adopter's world, and building one is the
# expensive part, so this was the first thing considered. It is the wrong host,
# for three reasons that are about what the two scripts prove, not about cost:
#
#   THE SAMPLE REPO IS DELIBERATELY A SUBSET. demo.sh synthesizes a sample
#   company from a DERIVED list of the files the guards need — hooks, libs, the
#   installer, the probe. It ships no README, no skills, no reference tier, no
#   docs, because the behavior it proves does not need them. Running a
#   completeness check inside that world would report every deliberate omission
#   as a defect. The adopter's world for THIS question is not a synthesized
#   subset; it is the published tree itself, and constructing it is one
#   `git ls-files`.
#
#   THE QUESTIONS ARE DIFFERENT IN KIND. demo.sh is behavioral: the guards
#   FIRE, against a real git repository, and their real exit codes decide. This
#   is structural: over the tree as published, does every capability it claims
#   have the declaration, the template, the document and the resolvable path
#   that make it usable. Folding a static audit into the seven-beat buyer proof
#   would make the 60-second demo longer and less about what it is for.
#
#   demo.sh's BEAT COUNT IS PINNED IN ci-verify.sh, on purpose, so that a beat
#   silently disappearing is a hard failure. Adding a beat of a different kind
#   spends that pin on the wrong thing.
#
# They are complements and they are both wired into ci-verify.sh: demo.sh
# proves the machinery WORKS for an adopter; this proves the adopter RECEIVES
# all of it.
#
# ===========================================================================
# WHAT THIS CANNOT CATCH — stated here so nobody has to discover it
# ===========================================================================
#   * A capability with NO declaration file. Check 2 finds enforcement that can
#     never fire because its switch is missing. A mechanism that needs no
#     switch, ships, and is documented nowhere is invisible to it.
#   * A capability that invents a DIFFERENT declaration convention. The
#     derivation reads `${X_DECLARATION:=.name}`, which is what both existing
#     guards use. A third that spells its gate some other way is not derived,
#     and therefore not checked. This is the one place a future author can
#     silently opt out, and the mitigation is that the convention is cheap and
#     already universal here.
#   * SEMANTIC honesty. Every path in a document can resolve while the sentence
#     around it is false. "CI runs exactly this" is checkable only as far as
#     "the file exists"; whether it runs is Check 3's question and only for
#     workflows.
#   * PROSE claims with no path in them at all — "supports Windows",
#     "backups are tested". No path, no check. That stays judgement.
#   * Citations in SOURCE files. Only .md and .txt are read for citations.
#     The engine's shell headers are long and cite a great deal, and including
#     them was measured as noise against signal; the claims a customer reads
#     are in the documents.
#   * WHETHER THE THING WORKS. This says the capability is delivered and
#     reachable. That it does what it says is what the test suites, the probe
#     and demo.sh are for.
#   * Deletion of `.publication-boundary`, which switches this off along with
#     the boundary guards. A visible, reviewable diff — and a bypass.
#
# ===========================================================================
# Usage
#   engine/scripts/publication-completeness.sh              check this tree
#   engine/scripts/publication-completeness.sh --explain    also show what was
#                                                           derived, and from where
#   engine/scripts/publication-completeness.sh --root DIR   check another tree
#
# Exit codes
#   0  complete — every capability the public tree claims is delivered
#   1  incomplete — each finding is named, with the file and the fix
#   2  broken or not applicable (no .publication-boundary, no python3, a
#      malformed .publication-completeness, a truncated walk). NEVER a quiet
#      pass: a completeness checker that degrades silently is the defect.
# ===========================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'

EXPLAIN=0
START_DIR="$PWD"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --explain) EXPLAIN=1 ;;
        --root)
            shift
            [ "$#" -gt 0 ] || { echo "ERROR: --root needs a directory." >&2; exit 2; }
            START_DIR="$1" ;;
        -h|--help) sed -n '/^# Usage/,/^# ====/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "ERROR: publication-completeness.sh: unrecognized argument '$1'." >&2; exit 2 ;;
    esac
    shift
done

command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: publication-completeness.sh requires python3." >&2; exit 2; }
command -v git >/dev/null 2>&1 || {
    echo "ERROR: publication-completeness.sh requires git." >&2; exit 2; }

# ---------------------------------------------------------------------------
# The declaration is the boundary's own. ONE adoption declaration, read by both
# contracts — a second file saying "this tree is published" would be a copy of
# a fact, and copies of facts are what this engine keeps deleting.
# ---------------------------------------------------------------------------
PB_LIB="$ENGINE_ROOT/scripts/lib/publication-boundary.sh"
[ -f "$PB_LIB" ] || { echo "ERROR: publication-completeness.sh: $PB_LIB is missing from this engine checkout. The publication root, and the private trees, are read from the boundary's declaration through it. Refusing to guess." >&2; exit 2; }
# resolve-main-checkout.sh gives pb_resolve_sources its worktree fallback: a
# relative PRIVATE_SOURCES entry like ../richos-hq does not resolve from
# richos-wt/<branch>/, and without this the misplacement check would go quietly
# inert in exactly the place all the work happens.
RMC_LIB="$ENGINE_ROOT/scripts/lib/resolve-main-checkout.sh"
[ -f "$RMC_LIB" ] && . "$RMC_LIB"
# shellcheck source=lib/publication-boundary.sh
. "$PB_LIB"

START_DIR="$(pb_physical "$START_DIR")"
ROOT="$(pb_repo_root "$START_DIR" 2>/dev/null || true)"
[ -n "$ROOT" ] || { echo "ERROR: publication-completeness.sh: $START_DIR is not inside a git repository." >&2; exit 2; }

# Walk up: a worktree, or engine/ inside a repo that carries a product too, must
# find the declaration wherever it actually lives — and "wherever it lives" is
# scripts/lib/declaration-path.sh's answer, so this script and the two leak
# guards can never disagree about which file the repository declared.
DECL_ROOT=""
DECL_UP_RC=0
decl_find_upward "$ROOT" "$PUBLICATION_DECLARATION" || DECL_UP_RC=$?
if [ "$DECL_UP_RC" -eq 2 ]; then
    echo "ERROR: publication-completeness.sh: $DECL_ROOT declares $PUBLICATION_DECLARATION unusably — $DECL_BROKEN_REASON" >&2
    exit 2
fi

if [ -z "$DECL_ROOT" ]; then
    cat >&2 <<EOF
${C_YELLOW}publication-completeness: NOT APPLICABLE${C_RESET}

  No ${PUBLICATION_DECLARATION} was found at or above $ROOT, so this tree does
  not declare itself publication-bound and there is no public/private split to
  hold it to. Adoption is DECLARED, never inferred — the same contract
  guard-publication-writes.sh holds.

  If this tree does get published, create ${PUBLICATION_DECLARATION} at its
  root — or ${DECLARATION_DIR}/${PUBLICATION_DECLARATION#.}, which is the same
  declaration in the grouped form; either one switches on the leak guards AND
  this check.
EOF
    exit 2
fi

# NOT `if ! pb_load_declaration ...; then RC=$?`. Inside an `if !`, `$?` is the
# NEGATED status, so a malformed declaration (rc 2) read back as 0 and the
# script reported "could not read" instead of naming the actual syntax error.
# Caught by this file's own suite, which is the point of having one.
pb_load_declaration "$DECL_ROOT"
PB_RC=$?
if [ "$PB_RC" -ne 0 ]; then
    if [ "$PB_RC" -eq 2 ]; then
        echo "ERROR: publication-completeness.sh: ${PB_DECLARATION_FILE:-$DECL_ROOT/$PUBLICATION_DECLARATION} is malformed — $PB_BROKEN_REASON" >&2
        exit 2
    fi
    echo "ERROR: publication-completeness.sh: could not read ${PB_DECLARATION_FILE:-$DECL_ROOT/$PUBLICATION_DECLARATION}." >&2
    exit 2
fi

PRIVATE_JSON="[]"
if pb_resolve_sources "$DECL_ROOT"; then
    PRIVATE_JSON="$(
        printf '%s' "$PB_SOURCES_OK" | tr '\t' '\n' | python3 -c '
import json,os,sys
out=[]
for line in sys.stdin.read().split("\n"):
    line=line.strip()
    if line and os.path.isdir(line):
        out.append([os.path.basename(line.rstrip("/")), line])
print(json.dumps(out))'
    )"
else
    echo "ERROR: publication-completeness.sh: $PUBLICATION_DECLARATION's PRIVATE_SOURCES is broken — $PB_BROKEN_REASON" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# .publication-completeness — the OPTIONAL exemption declaration.
#
# It carries no adoption switch (that is .publication-boundary's job) and no
# thresholds. It carries only deliberate, committed, reviewable exemptions,
# for the same reason the boundary has an ALLOWLIST and not an override token:
# a check with no sanctioned way through gets removed whole.
#
# It is safe to have ONLY because an exemption that suppresses nothing FAILS —
# see the analyser. The list cannot outlive its own justification.
# ---------------------------------------------------------------------------
COMPLETENESS_DECLARATION=".publication-completeness"
KNOWN_KEYS="CITATION_EXEMPT DECLARATION_EXEMPT WORKFLOW_EXEMPT INSTANCE_MECHANISMS"
EX_CITATION=""; EX_DECLARATION=""; EX_WORKFLOW=""; EX_INSTANCE=""
# Resolved the same way as the boundary declaration beside it: the grouped form
# first, the root form second, both at once refused. An exemption file the
# checker cannot find is an exemption file that silently stops exempting, and
# the symptom of that is a wall of findings nobody trusts.
CFILE_RC=0
decl_find "$DECL_ROOT" "$COMPLETENESS_DECLARATION" || CFILE_RC=$?
if [ "$CFILE_RC" -eq 2 ]; then
    echo "ERROR: publication-completeness.sh: $COMPLETENESS_DECLARATION is unusable — $DECL_BROKEN_REASON" >&2
    exit 2
fi
CFILE="$DECL_PATH"
if [ -n "$CFILE" ] && [ -f "$CFILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"
        case "$line" in ''|'#'*) continue ;; esac
        case "$line" in *=*) ;; *)
            echo "ERROR: $CFILE: line is not KEY=value: '$line'" >&2; exit 2 ;;
        esac
        key="${line%%=*}"; val="${line#*=}"
        case "$val" in
            \"*\") val="${val#\"}"; val="${val%\"}" ;;
            \'*\') val="${val#\'}"; val="${val%\'}" ;;
            *) val="${val%%#*}"; val="${val%"${val##*[![:space:]]}"}" ;;
        esac
        case " $KNOWN_KEYS " in
            *" $key "*) ;;
            *) echo "ERROR: $CFILE: unknown key '$key'. Known keys: $KNOWN_KEYS. A key nothing reads is a setting that silently does nothing — refusing rather than pretending it took effect." >&2; exit 2 ;;
        esac
        case "$val" in *'$('*|*'`'*)
            echo "ERROR: $CFILE: value for '$key' contains shell substitution syntax; this file is parsed, never sourced." >&2; exit 2 ;;
        esac
        case "$key" in
            CITATION_EXEMPT)     EX_CITATION="$val" ;;
            DECLARATION_EXEMPT)  EX_DECLARATION="$val" ;;
            WORKFLOW_EXEMPT)     EX_WORKFLOW="$val" ;;
            INSTANCE_MECHANISMS) EX_INSTANCE="$val" ;;
        esac
    done < "$CFILE"
fi

ANALYSER="$SCRIPT_DIR/publication-completeness.py"
[ -f "$ANALYSER" ] || { echo "ERROR: publication-completeness.sh: $ANALYSER is missing." >&2; exit 2; }

printf '%s=== publication completeness: %s ===%s\n' "$C_BOLD" "$DECL_ROOT" "$C_RESET"

OUT="$(
    ROOT="$DECL_ROOT" EXPLAIN="$EXPLAIN" DECLDIR="$DECLARATION_DIR" \
    EXC="$EX_CITATION" EXD="$EX_DECLARATION" EXW="$EX_WORKFLOW" EXI="$EX_INSTANCE" \
    PRIV="$PRIVATE_JSON" python3 -c '
import json, os, sys
cfg = {
    "root": os.environ["ROOT"],
    "explain": os.environ["EXPLAIN"] == "1",
    # Where a grouped declaration lives, passed in rather than re-declared:
    # scripts/lib/declaration-path.sh is the one place that name is written.
    "declaration_dir": os.environ["DECLDIR"],
    "private_roots": json.loads(os.environ["PRIV"]),
    "exempt": {k: os.environ[v].split() for k, v in
               (("CITATION_EXEMPT","EXC"),("DECLARATION_EXEMPT","EXD"),
                ("WORKFLOW_EXEMPT","EXW"),("INSTANCE_MECHANISMS","EXI"))
               if os.environ[v].split()},
}
sys.stdout.write(json.dumps(cfg))' | python3 "$ANALYSER"
)"
RC=$?

if [ "$RC" -eq 2 ]; then
    printf '%s✗ publication-completeness: BROKEN — the check did not run to completion.%s\n' "$C_RED" "$C_RESET" >&2
    exit 2
fi

if [ "$RC" -eq 0 ]; then
    printf '%s✓ Every capability this tree claims is delivered: no dangling citation, no\n' "$C_GREEN"
    printf '  declaration-gated mechanism without its declaration and its documentation,\n'
    printf '  no unreachable workflow, no public contract with its mechanism left behind\n'
    printf '  in the private tree.%s\n' "$C_RESET"
    exit 0
fi

N=0
while IFS=$'\t' read -r check path msg; do
    [ -n "$check" ] || continue
    N=$((N + 1))
    printf '\n%s%2d. [%s] %s%s\n' "$C_RED" "$N" "$check" "$path" "$C_RESET"
    printf '%s\n' "    $msg" | fold -s -w 96 | sed '2,$s/^/    /'
done <<EOF
$OUT
EOF

printf '\n%s✗ publication-completeness: %d finding(s). The public tree claims capabilities it\n' "$C_RED" "$N" >&2
printf '  does not deliver. Fix each, or add a reviewed entry to\n' >&2
printf '  %s (an entry that suppresses nothing FAILS,\n' "${CFILE:-$DECL_ROOT/$DECLARATION_DIR/${COMPLETENESS_DECLARATION#.}}" >&2
printf '  so an exemption cannot outlive its reason).%s\n' "$C_RESET" >&2
exit 1
