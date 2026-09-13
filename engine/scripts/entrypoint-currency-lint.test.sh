#!/usr/bin/env bash
#
# entrypoint-currency-lint.test.sh — the suite for the type-V check.
#
# Every case is named for the INVARIANT it pins, not for the code it touches, so
# a failure reads as a broken promise rather than a broken line.
#
# The two cases that matter most are the paired ones: the lint REFUSES the real
# defect (an instruction surface naming a superseded entrypoint and never its
# replacement) and PASSES the corrected string. A negative test alone passes for
# the wrong reason — a lint that refuses everything satisfies it.
#
# Exit 0 all green, 1 any red.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="$SCRIPT_DIR/entrypoint-currency-lint.sh"
LIB="$SCRIPT_DIR/lib/entrypoints.sh"

PASS=0
FAIL=0
SANDBOXES=""

cleanup() {
    for d in $SANDBOXES; do
        case "$d" in
            /*/ep-lint.*) rm -rf "$d" ;;
        esac
    done
}
trap cleanup EXIT

ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

# sandbox <name> — a throwaway repository root with an orchestration.config.
sandbox() {
    local d
    d="$(mktemp -d -t ep-lint.XXXXXX)"
    SANDBOXES="$SANDBOXES $d"
    mkdir -p "$d/scripts/hooks" "$d/skills/demo" "$d/.claude/agents"
    printf '%s' "$d"
}

# declare_config <dir> <entrypoints> <surfaces>
declare_config() {
    {
        printf 'ENTRYPOINTS="%s"\n' "$2"
        printf 'INSTRUCTION_SURFACES="%s"\n' "$3"
    } >"$1/orchestration.config"
}

SPEC_REAL='starting a teammate | scripts/spawn.sh | scripts/prepare-agent-spawn.py scripts/create-teammate-worktree.sh'
SURFACES_REAL='CLAUDE.md skills/*/SKILL.md scripts/hooks/engine-status.sh'

echo "entrypoint-currency-lint.test.sh"
echo

# ---------------------------------------------------------------------------
echo "the parser refuses a declaration nobody could act on"
# ---------------------------------------------------------------------------
# shellcheck disable=SC1090
. "$LIB"

if [ "$(entrypoints_problem '')" = "ENTRYPOINTS is blank" ]; then
    ok "a blank declaration is named as blank, not treated as 'nothing superseded'"
else
    no "a blank declaration is named as blank" "got: $(entrypoints_problem '')"
fi

case "$(entrypoints_problem 'task | scripts/a.sh')" in
    *"expected exactly 3"*) ok "a record missing its superseded field is refused with the field count" ;;
    *) no "a record missing its superseded field is refused" "got: $(entrypoints_problem 'task | scripts/a.sh')" ;;
esac

case "$(entrypoints_problem 'task | scripts/a.sh | scripts/a.sh')" in
    *"cycle"*) ok "a path declared both canonical and superseded in one record is refused as a cycle" ;;
    *) no "a self-cycle is refused" "got: $(entrypoints_problem 'task | scripts/a.sh | scripts/a.sh')" ;;
esac

case "$(entrypoints_problem 'one | scripts/a.sh | scripts/b.sh; two | scripts/b.sh | scripts/c.sh')" in
    *"canonical in one record and superseded in another"*) ok "a path retired by one record and recommended by another is refused" ;;
    *) no "a cross-record cycle is refused" "got: $(entrypoints_problem 'one | scripts/a.sh | scripts/b.sh; two | scripts/b.sh | scripts/c.sh')" ;;
esac

if [ -z "$(entrypoints_problem 'one | scripts/a.sh | ')" ]; then
    ok "a task whose command never had a predecessor is legal, so it has somewhere to be written down"
else
    no "an empty superseded field is legal" "got: $(entrypoints_problem 'one | scripts/a.sh | ')"
fi

if [ "$(entrypoint_record_for_superseded 'prepare-agent-spawn.py' "$SPEC_REAL" | awk -F'\t' '{print $1}')" = "spawn.sh" ]; then
    ok "a superseded basename resolves to the command that replaced it"
else
    no "a superseded basename resolves to its replacement" "got: $(entrypoint_record_for_superseded 'prepare-agent-spawn.py' "$SPEC_REAL")"
fi

if [ -z "$(entrypoint_record_for_superseded 'something-else.sh' "$SPEC_REAL")" ]; then
    ok "an undeclared basename resolves to nothing, so the lint never invents a supersession"
else
    no "an undeclared basename resolves to nothing" "got a record"
fi

echo

# ---------------------------------------------------------------------------
echo "the paired case: it refuses today's defect and passes the correction"
# ---------------------------------------------------------------------------
SB="$(sandbox)"
declare_config "$SB" "$SPEC_REAL" "$SURFACES_REAL"
cat >"$SB/scripts/hooks/engine-status.sh" <<'BAD'
#!/usr/bin/env bash
emit_context "Before each new Agent call, prepare its task-specific JSON with python3 prepare-agent-spawn.py --file <input.json>. Cross-repository work ALSO requires create-teammate-worktree.sh <repo> <teammate-name>."
BAD

OUT="$("$LINT" --root "$SB" --engine "$SB" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ]; then
    ok "an announcement naming the replaced path and never its replacement is REFUSED (exit 1)"
else
    no "the real defect is refused" "exit=$RC output: $OUT"
fi
case "$OUT" in
    *"engine-status.sh:2:"*) ok "the refusal names the file and the LINE, so the fix is one place" ;;
    *) no "the refusal names file:line" "got: $OUT" ;;
esac
case "$OUT" in
    *"prepare-agent-spawn.py"*) ok "the refusal names the superseded entrypoint it found" ;;
    *) no "the refusal names the superseded entrypoint" "got: $OUT" ;;
esac
case "$OUT" in
    *"scripts/spawn.sh"*) ok "the refusal names the canonical entrypoint, so it says what to DO and not only what is wrong" ;;
    *) no "the refusal names the canonical entrypoint" "got: $OUT" ;;
esac
case "$OUT" in
    *"create-teammate-worktree.sh"*) ok "BOTH superseded entrypoints on the line are named in ONE report, never one at a time" ;;
    *) no "both superseded entrypoints are reported together" "got: $OUT" ;;
esac

# THE CORRECTION. Same file, one clause changed, nothing else — and the old
# names stay, because the correction is additive: spawn.sh calls them.
cat >"$SB/scripts/hooks/engine-status.sh" <<'GOOD'
#!/usr/bin/env bash
emit_context "Start each new teammate with ONE command: scripts/spawn.sh <name> --repo <repo> --type <type> --brief <file>. It evaluates every PreToolUse[Agent] guard from every surface before anything is created, and does internally what prepare-agent-spawn.py and create-teammate-worktree.sh used to be run for by hand."
GOOD

OUT="$("$LINT" --root "$SB" --engine "$SB" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then
    ok "the corrected announcement PASSES (exit 0) — the check is not a lint that refuses everything"
else
    no "the corrected announcement passes" "exit=$RC output: $OUT"
fi

echo

# ---------------------------------------------------------------------------
echo "a legitimate mention stays possible, or the check gets waived"
# ---------------------------------------------------------------------------
SB2="$(sandbox)"
declare_config "$SB2" "$SPEC_REAL" "$SURFACES_REAL"
cat >"$SB2/CLAUDE.md" <<'MIG'
# Doctrine

Start a teammate with spawn.sh. Until 2026-09-13 this took four steps ending in
create-teammate-worktree.sh; that path still works and spawn.sh calls it.
MIG
OUT="$("$LINT" --root "$SB2" --engine "$SB2" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then
    ok "a migration note naming both the old and new command passes with no marker at all"
else
    no "a migration note passes unmarked" "exit=$RC output: $OUT"
fi

SB3="$(sandbox)"
declare_config "$SB3" "$SPEC_REAL" "$SURFACES_REAL"
cat >"$SB3/CLAUDE.md" <<'HIST'
# Doctrine

The four-step path ended in create-teammate-worktree.sh.  entrypoint-exempt: this section is the history of what the spawn path used to be, not an instruction to use it
HIST
OUT="$("$LINT" --root "$SB3" --engine "$SB3" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then
    ok "a history line carrying a substantive entrypoint-exempt: reason passes"
else
    no "a declared exemption passes" "exit=$RC output: $OUT"
fi

SB4="$(sandbox)"
declare_config "$SB4" "$SPEC_REAL" "$SURFACES_REAL"
cat >"$SB4/CLAUDE.md" <<'BARE'
# Doctrine

Create the worktree with create-teammate-worktree.sh.  entrypoint-exempt: ok
BARE
OUT="$("$LINT" --root "$SB4" --engine "$SB4" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ]; then
    ok "a BARE entrypoint-exempt: marker exempts nothing — an undeclared exemption is a stale instruction wearing a justification"
else
    no "a bare marker exempts nothing" "exit=$RC output: $OUT"
fi
case "$OUT" in
    *"carries no reason"*) ok "the refusal of a bare marker says WHY it was not accepted" ;;
    *) no "the bare-marker refusal explains itself" "got: $OUT" ;;
esac

echo

# ---------------------------------------------------------------------------
echo "it governs instructions only, and never anything that merely describes"
# ---------------------------------------------------------------------------
SB5="$(sandbox)"
declare_config "$SB5" "$SPEC_REAL" "$SURFACES_REAL"
mkdir -p "$SB5/docs"
cat >"$SB5/docs/reference.md" <<'REF'
| Worktree helper | create-teammate-worktree.sh | creates, seeds and registers |
REF
cat >"$SB5/README.md" <<'RM'
Run prepare-agent-spawn.py to build a payload.
RM
OUT="$("$LINT" --root "$SB5" --engine "$SB5" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then
    ok "a reference table and a README are NOT instruction surfaces, so description that names an old command is left alone"
else
    no "docs and README are out of scope" "exit=$RC output: $OUT"
fi

SB6="$(sandbox)"
declare_config "$SB6" "$SPEC_REAL" "$SURFACES_REAL"
cat >"$SB6/scripts/hooks/engine-status.sh" <<'BAD2'
emit_context "prepare its JSON with prepare-agent-spawn.py"
BAD2
chmod +x "$SB6/scripts/prepare-agent-spawn.py" 2>/dev/null || true
: >"$SB6/scripts/prepare-agent-spawn.py"
chmod +x "$SB6/scripts/prepare-agent-spawn.py"
OUT="$("$LINT" --root "$SB6" --engine "$SB6" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && [ -x "$SB6/scripts/prepare-agent-spawn.py" ]; then
    ok "the superseded script is left executable and untouched — this governs what we TELL people, never what is allowed"
else
    no "the superseded script keeps working" "exit=$RC executable=$([ -x "$SB6/scripts/prepare-agent-spawn.py" ] && echo yes || echo no)"
fi

echo

# ---------------------------------------------------------------------------
echo "it never passes quietly over a defense that is not running"
# ---------------------------------------------------------------------------
SB7="$(sandbox)"
declare_config "$SB7" "" ""
OUT="$("$LINT" --root "$SB7" --engine "$SB7" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then
    case "$OUT" in
        *"NOTHING IS DECLARED"*) ok "an undeclared supersession set STANDS DOWN LOUDLY rather than exiting 0 looking clean" ;;
        *) no "a blank declaration announces itself" "got: $OUT" ;;
    esac
else
    no "a blank declaration exits 0 with an announcement" "exit=$RC output: $OUT"
fi

SB8="$(sandbox)"
declare_config "$SB8" 'broken record with no fields' "$SURFACES_REAL"
OUT="$("$LINT" --root "$SB8" --engine "$SB8" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ]; then
    ok "a declaration that cannot be parsed is exit 2 — an error, never a green run over an unreadable rule"
else
    no "an unparseable declaration is exit 2" "exit=$RC output: $OUT"
fi

# THE CWD TRAP. The surface patterns are DATA; a current working directory that
# happens to contain a matching tree must not be able to rewrite them.
SB9="$(sandbox)"
declare_config "$SB9" "$SPEC_REAL" "$SURFACES_REAL"
DECOY="$(sandbox)"
mkdir -p "$DECOY/skills/decoy"
cat >"$DECOY/skills/decoy/SKILL.md" <<'DEC'
Use create-teammate-worktree.sh for everything.
DEC
OUT="$(cd "$DECOY" && "$LINT" --root "$SB9" --engine "$SB9" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then
    ok "the working directory cannot rewrite the surface patterns — a clean root stays clean beside a dirty cwd"
else
    no "cwd cannot leak into the surface globs" "exit=$RC output: $OUT"
fi

echo

# ---------------------------------------------------------------------------
echo "the engine's declaration reaches a repository that declares none"
# ---------------------------------------------------------------------------
SBE="$(sandbox)"          # stands in for the engine
declare_config "$SBE" "$SPEC_REAL" "$SURFACES_REAL"
SBG="$(sandbox)"          # stands in for a governed repository
printf 'PROTECTED_PATHS="src"\n' >"$SBG/orchestration.config"
cat >"$SBG/CLAUDE.md" <<'GOV'
Rich creates every one with scripts/create-teammate-worktree.sh <repo> <name>.
GOV
OUT="$("$LINT" --root "$SBG" --engine "$SBE" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ]; then
    ok "a governed repository that declares no ENTRYPOINTS still inherits the engine's, so its own CLAUDE.md is checked"
else
    no "the engine declaration reaches a governed repo" "exit=$RC output: $OUT"
fi

echo
echo "----------------------------------------"
printf 'entrypoint-currency-lint: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
