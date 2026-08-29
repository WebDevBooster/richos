#!/usr/bin/env bash
#
# ceo-todos-init.sh — GIVE A REPOSITORY A CEO TODOs, IN ONE COMMAND.
#
# ===========================================================================
# WHY THIS EXISTS
# ===========================================================================
# For one release the engine shipped a CEO-TODOs lint, a commit guard, a
# predicate and a test suite — and no `.ceo-todos`, no template, and no mention
# in the onboarding runbook or the bootstrap interview. All of that machinery is
# switched on by the presence of one declaration file, so every adopter received
# enforcement that COULD NEVER FIRE, and nothing told them.
#
# That is exactly the defect the machinery itself exists to catch, one level
# out: present, correct, and unreachable. It shipped because the landing
# criterion was "the files are in the tree" — an internal check again, with
# nobody asking what a person who had just cloned this would actually get.
#
# So adoption is a COMMAND, not a paragraph in a runbook telling somebody to
# copy four files and remember a fifth step.
#
# WHAT IT DOES, in order, and it prints every one of them:
#   1. writes `.ceo-todos`                    the declaration that switches the
#                                             guard on
#   2. writes the starter record              sections 1, 2, 3 and one worked
#                                             example, parked in section 3
#   3. creates the cold-open folder           with a note saying what goes in it
#   4. renders the entry point                an EMPTY list still renders a
#                                             real page: "Nothing is waiting on
#                                             you", both sections shown. The
#                                             surface exists from minute one
#                                             instead of appearing the day
#                                             something lands on it.
#   5. points the root README at it           TODOs nobody can find are TODOs
#                                             nobody has
#   6. runs a cold open                       and only declares COLD_OPEN_DIR if
#                                             it SUCCEEDS — see below
#   7. runs the lint                          so the adopter watches the whole
#                                             mechanism pass on their own
#                                             repository before typing anything
#
# WHY STEP 6 IS CONDITIONAL. Declaring COLD_OPEN_DIR switches on a gate that
# refuses commits until a transcript exists. Writing that key and then failing
# to produce the transcript — no network, no reader installed — would hand a new
# adopter a repository they cannot commit to, five minutes into owning it. So
# the key is written only once there is a transcript to satisfy it, and if the
# reading does not happen the file carries a commented key and an exact
# instruction. Never wedged, never silent.
#
# Usage:
#   scripts/ceo-todos-init.sh [repo]
#     --record <path>     record location   (default docs/open-items.md)
#     --view <NAME.md>    entry point       (default CEO-TODOs.md)
#     --cold-open <path>  transcript folder (default docs/cold-open)
#     --no-cold-open      skip step 6 entirely
#     --no-readme         do not touch README.md (the lint will then refuse
#                         until you add the pointer yourself)
#     --force             overwrite an existing declaration
#
# Exit codes:
#   0  the repository now has a working, lint-clean CEO TODOs
#   1  installed, but the lint is not clean yet — every reason is printed
#   2  cannot run

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$SCRIPT_DIR/lib/ceo-todos.sh"
TPL="$ENGINE_ROOT/reference/ceo-todos"

TARGET=""
RECORD_REL="docs/open-items.md"
VIEW="CEO-TODOs.md"
COLD_REL="docs/cold-open"
DO_COLD=1
DO_README=1
FORCE=0

die() { echo "ERROR: ceo-todos-init.sh: $1" >&2; exit 2; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --record)       shift; RECORD_REL="${1:-}" ;;
        --view)         shift; VIEW="${1:-}" ;;
        --cold-open)    shift; COLD_REL="${1:-}" ;;
        --no-cold-open) DO_COLD=0 ;;
        --no-readme)    DO_README=0 ;;
        --force)        FORCE=1 ;;
        -h|--help)      sed -n '46,70p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)             die "unrecognised argument '$1'" ;;
        *)              [ -z "$TARGET" ] || die "one target only"; TARGET="$1" ;;
    esac
    shift
done
[ -n "$TARGET" ] || TARGET="$PWD"

[ -f "$LIB" ] || die "scripts/lib/ceo-todos.sh is missing at $LIB"
[ -d "$TPL" ] || die "the starter templates are missing at $TPL. Without them this command would have to inline a copy of the declaration format, which is a second source for it — refusing."
# shellcheck source=lib/ceo-todos.sh
. "$LIB"

REPO="$(ct_repo_root "$TARGET" 2>/dev/null || true)"
[ -n "$REPO" ] || die "'$TARGET' is not inside a git repository."

case "$VIEW" in
    */*|.*) die "--view must be a bare TOP-LEVEL file name ('CEO-TODOs.md'), not '$VIEW'. The entry point is what a stranger sees listing the repository root." ;;
esac

DECL="$REPO/$CEO_TODOS_DECLARATION"
if [ -f "$DECL" ] && [ "$FORCE" -eq 0 ]; then
    echo "ERROR: ceo-todos-init.sh: $REPO already declares CEO TODOs ($CEO_TODOS_DECLARATION)." >&2
    echo "       Refusing to overwrite it. Check it with:  scripts/ceo-todos-lint.sh $REPO" >&2
    echo "       Re-install anyway with --force." >&2
    exit 2
fi
# A repository that already ran this under the pre-2026-08-29 name has a live,
# populated declaration; "init" would write a second one beside it and the
# predicate would then refuse BOTH as ambiguous. Say so, and give the rename.
if [ -f "$REPO/$_CT_LEGACY_DECL_FILE" ] && [ "$FORCE" -eq 0 ]; then
    echo "ERROR: ceo-todos-init.sh: $REPO already declares CEO TODOs under the pre-2026-08-29" >&2
    echo "       name ($_CT_LEGACY_DECL_FILE). It is still read and still enforced — this is a" >&2
    echo "       rename, not a re-install:" >&2
    echo "         git -C $REPO mv $_CT_LEGACY_DECL_FILE $CEO_TODOS_DECLARATION" >&2
    echo "       then rename QUEUE_RECORD -> TODO_RECORD and QUEUE_VIEW -> TODO_VIEW inside it," >&2
    echo "       and re-render:  scripts/ceo-todos-render.sh $REPO" >&2
    exit 2
fi

echo "=== CEO TODOs — installing into $REPO ==="

# --- 2. the record (first: the declaration must not name a file that is absent)
RECORD="$REPO/$RECORD_REL"
if [ -f "$RECORD" ]; then
    echo "  · record already present, kept: $RECORD_REL"
else
    mkdir -p "$(dirname "$RECORD")" || die "could not create $(dirname "$RECORD")"
    sed "s|@@TODO_VIEW@@|$VIEW|g" "$TPL/open-items.md" > "$RECORD" || die "could not write $RECORD"
    echo "  ✓ wrote the starter record: $RECORD_REL"
fi

# --- 3. the cold-open folder ----------------------------------------------
COLD_DIR="$REPO/$COLD_REL"
if [ "$DO_COLD" -eq 1 ]; then
    mkdir -p "$COLD_DIR" || die "could not create $COLD_DIR"
    [ -f "$COLD_DIR/README.md" ] || cp "$TPL/cold-open-README.md" "$COLD_DIR/README.md"
    echo "  ✓ transcript folder: $COLD_REL"
fi

# --- 1. the declaration ----------------------------------------------------
# COLD_OPEN_DIR starts COMMENTED. It is uncommented at step 6, and only if a
# transcript actually got filed — see the header.
write_declaration() {
    local cold_line="$1"
    sed -e "s|@@TODO_RECORD@@|$RECORD_REL|g" \
        -e "s|@@TODO_VIEW@@|$VIEW|g" \
        -e "s|@@CEO_SECTIONS@@|1 2|g" \
        -e "s|@@PREPARER_SECTION@@|3|g" \
        -e "s|@@ARTIFACT_ROOTS@@|repo=.|g" \
        -e "s|@@COLD_OPEN_DIR@@|$cold_line|g" \
        "$TPL/ceo-todos.example" > "$DECL"
}
write_declaration "# COLD_OPEN_DIR=\"$COLD_REL\"   # see step 6 of ceo-todos-init.sh"
echo "  ✓ wrote $CEO_TODOS_DECLARATION — the guard is now live in this repository"

# --- 4. the entry point ----------------------------------------------------
"$SCRIPT_DIR/ceo-todos-render.sh" "$REPO" 2>/dev/null | sed 's/^/  /' \
    || die "the renderer failed — the CEO's TODOs would have no page. Run scripts/ceo-todos-render.sh $REPO to see why."

# --- 5. the front door -----------------------------------------------------
README="$REPO/README.md"
POINTER="> ## → **[$VIEW]($VIEW)** — what is waiting on you right now"
if [ "$DO_README" -eq 0 ]; then
    echo "  · README untouched (--no-readme). The lint will refuse until it names $VIEW."
elif [ -f "$README" ] && head -40 "$README" | grep -qF "$VIEW"; then
    echo "  · README already names $VIEW in its first 40 lines"
else
    TMP_README="$(mktemp -t ceo-todos-readme.XXXXXX)" || die "mktemp failed"
    {
        printf '%s\n' "$POINTER"
        printf '>\n'
        printf '> Everything on that page is *prepared*: the file you open already exists, and each\n'
        printf '> item says what "done" means. Anything not in that state is not there.\n'
        printf '\n'
        [ -f "$README" ] && cat "$README"
    } > "$TMP_README"
    mv "$TMP_README" "$README" || die "could not write $README"
    echo "  ✓ pointed README.md at $VIEW (4 lines, at the top)"
fi

# --- 6. the cold open ------------------------------------------------------
COLD_OK=0
if [ "$DO_COLD" -eq 1 ]; then
    echo ""
    echo "  Running a cold open: a reader with no context, asked what this repository"
    echo "  wants from you. This is the one check the people who built a surface cannot"
    echo "  perform on it themselves."
    # Declared temporarily so the harness has somewhere to file to; reverted
    # immediately if the reading does not happen.
    write_declaration "COLD_OPEN_DIR=\"$COLD_REL\""
    if "$SCRIPT_DIR/cold-open.sh" --run "$REPO" 2>&1 | sed 's/^/    /'; then
        COLD_OK=1
    fi
    if [ "$COLD_OK" -eq 1 ]; then
        echo "  ✓ COLD_OPEN_DIR declared — the freshness gate is live"
    else
        write_declaration "# COLD_OPEN_DIR=\"$COLD_REL\"   # no transcript yet — see below"
        echo ""
        echo "  ⚠ the cold open did not run, so COLD_OPEN_DIR was left COMMENTED OUT."
        echo "    Declaring it without a transcript on file would refuse every commit in"
        echo "    this repository from now until one exists. When you are ready:"
        echo "      scripts/cold-open.sh --run $REPO       # a fresh reader"
        echo "      scripts/cold-open.sh --brief $REPO     # the prompt, for a person"
        echo "    then uncomment COLD_OPEN_DIR in $CEO_TODOS_DECLARATION."
    fi
fi

# --- 7. prove it -----------------------------------------------------------
echo ""
echo "=== the lint, on your repository ==="
LRC=0
"$SCRIPT_DIR/ceo-todos-lint.sh" "$REPO" 2>&1 | sed 's/^/  /' || LRC=1
echo ""
if [ "$LRC" -eq 0 ]; then
    echo "Done. Edit $RECORD_REL, then: scripts/ceo-todos-render.sh $REPO"
    echo "Never edit $VIEW by hand — it is generated, and the commit guard refuses a stale one."
    exit 0
fi
echo "Installed, but not clean yet — every reason is printed above, with the fix."
exit 1
