#!/usr/bin/env bash
#
# claim-capability-delivery.mutation.sh — PROVES notice-claim-capability.test.sh CAN FAIL.
#
# ===========================================================================================
# WHY THIS FILE EXISTS
# ===========================================================================================
# Fourteen green ticks are evidence of nothing until somebody shows them turning red for the
# RIGHT REASON, and this suite is unusually exposed to that: SIX of its fourteen cases are of
# the form "the hook stayed quiet". A test for staying quiet passes for free — including when
# the hook never ran, when the payload was malformed, when python3 was missing, and when the
# predicate it imports could not be loaded. Every one of those would print PASS.
#
# Worse, the whole argument for shipping this hook is that it is quiet 98.6% of the time. If
# the quiet cases are passing for the wrong reason, the measurement behind the decision is
# measuring a hook that does nothing.
#
# So: a CONTROL first (unmutated sandbox, same builder, must be green), then per mutant the
# mutation must APPLY, the suite must FAIL, and the NAMED case must be the one that fails.
#
# ===========================================================================================
# THE FIRST THING THIS HARNESS FOUND, KEPT HERE BECAUSE IT IS THE POINT
# ===========================================================================================
# `surface-widened` SURVIVED on its first run, and the survival was the finding: the surface
# list was written twice — once in the bash fast-path grep, once in the python resolver — so
# widening the python copy left the grep narrow and the mutant looked applied while changing
# nothing. Two copies of one predicate is the defect class this engine keeps finding in
# itself, and it had reappeared inside a hook whose whole job is to deliver a check rather
# than re-implement it. The hook now declares `RECORD_DIRS` once and both readers use it.
#
# WHAT IS DELIBERATELY NOT MUTATED, said out loud rather than quietly skipped: the fast path
# as a mechanism. With the surface list shared it is no longer separately mutable, and what
# remains of it — starting python3 or not — is a cost property, not a correctness one.
#
# Run directly: scripts/hooks/claim-capability-delivery.mutation.sh
# Exit 0 = every property below is proven load-bearing.

set -uo pipefail

# EXPORTED, not set per invocation: this harness runs the suite it mutates, and that suite
# invokes this harness at its end. One missed site is an infinite regress.
export RICHOS_MUTATION_INNER=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t claim-capability-delivery-mutation.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

cat >"$SANDBOX/mutate.py" <<'PYEOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as fh:
    src = fh.read()
if old not in src:
    sys.stderr.write("MUTATION TARGET ABSENT — the source has drifted:\n  %s\n" % old)
    sys.exit(3)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(src.replace(old, new, 1))
PYEOF

# build <dir> — an engine subtree the suite can run against, unmutated.
build() {
    local dir="$1"
    mkdir -p "$dir/scripts/hooks" "$dir/ass-kicker"
    cp "$ENGINE_ROOT/scripts/hooks/notice-claim-capability.sh" \
       "$ENGINE_ROOT/scripts/hooks/notice-claim-capability.test.sh" "$dir/scripts/hooks/"
    cp "$ENGINE_ROOT/ass-kicker/brief-provenance.py" "$dir/ass-kicker/"
    chmod +x "$dir/scripts/hooks/"*.sh
}

echo "=== claim-capability-delivery.mutation.sh ==="
echo ""
CTRL="$SANDBOX/control"
build "$CTRL"
bash "$CTRL/scripts/hooks/notice-claim-capability.test.sh" >"$CTRL/out.txt" 2>&1
CTRL_RC=$?
if [ "$CTRL_RC" -ne 0 ]; then
    echo "  FATAL: the CONTROL sandbox is already red, so no kill below would mean anything."
    echo "         A sandbox missing a dependency makes the subject refuse to start, and a"
    echo "         refusal reads exactly like a catch."
    grep '  FAIL' "$CTRL/out.txt" | sed 's/^/         /'
    exit 1
fi
CTRL_N="$(grep -c '  PASS' "$CTRL/out.txt")"
printf '  CONTROL  unmutated sandbox: %s cases pass, 0 fail — kills below are real\n\n' "$CTRL_N"

HOOK_REL="scripts/hooks/notice-claim-capability.sh"
PROV_REL="ass-kicker/brief-provenance.py"

# mutant <name> <expected-failing-case> <rel-file> <old> <new> <why>
mutant() {
    local name="$1" want="$2" rel="$3" old="$4" new="$5" why="$6"
    local dir="$SANDBOX/$name"
    build "$dir"

    if ! python3 "$SANDBOX/mutate.py" "$dir/$rel" "$old" "$new" 2>"$dir/mutate.err"; then
        printf '  FAIL  %s — the mutation did not apply\n' "$name"
        sed 's/^/          /' "$dir/mutate.err"
        FAIL=$((FAIL + 1)); return
    fi

    bash "$dir/scripts/hooks/notice-claim-capability.test.sh" >"$dir/out.txt" 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '  FAIL  %s — the suite still PASSED without this property.\n' "$name"
        printf '          %s\n' "$why"
        FAIL=$((FAIL + 1)); return
    fi
    # A LITERAL WITH ESCAPED METACHARACTERS, never a bare regex: an unescaped `.` matches any
    # character, so `D1` would match `D14` and the harness would name the wrong witness. A
    # wrong witness is the whole second clause of this harness's contract.
    local want_re
    want_re="$(printf '%s' "$want" | sed 's/[[:space:]]*$//' | sed 's/[][\.*^$(){}?+|\/]/\\&/g')"
    if ! grep -q "FAIL  ${want_re}\b" "$dir/out.txt"; then
        printf '  FAIL  %s — the suite went red, but NOT at %s (so the red is unrelated).\n' "$name" "$want"
        grep '  FAIL' "$dir/out.txt" | sed 's/^/          /'
        FAIL=$((FAIL + 1)); return
    fi
    printf '  PASS  %s — removing it turns "%s" red\n' "$name" "$want"
    PASS=$((PASS + 1))
}

# --- THE CHECK ITSELF IS WHAT PRODUCES THE NOTICE ------------------------------------------
# The one mutant that answers "is this hook load-bearing, or is it printing something it
# invented?" With check 4 neutered in the imported predicate, the notice is GONE.
mutant "capability-check-neutered" "D1" "$PROV_REL" \
    "def check_capability(blocks):
    findings = []" \
    "def check_capability(blocks):
    return []
    findings = []" \
    "the rows come from brief-provenance.py's fourth check and from nowhere else; if the hook still spoke with the check gone, it would be a second implementation."

# --- THE NARROWING THAT DECIDES WALLPAPER --------------------------------------------------
mutant "written-filter-dropped" "D5" "$HOOK_REL" \
    'rows = [r for r in rows if PROV.norm(r["text"]) and PROV.norm(r["text"]) in norm_written]' \
    "rows = list(rows)" \
    "without it, every edit to a flagged record re-emits every row in the file — replaying the shipped hook over every recorded write event on this machine, it is what keeps 168 of 1035 calls quiet - calls that touched a flagged record and wrote none of its flagged lines - and it is the single mechanism that would otherwise turn this into the line nobody reads."

# --- THE SURFACE LIST ----------------------------------------------------------------------
mutant "surface-widened" "D10" "$HOOK_REL" \
    "RECORD_DIRS='docs/verification/|/wiki/|/memory/'" \
    "RECORD_DIRS='docs/verification/|/wiki/|/memory/|'" \
    "widened to every markdown file, RICH-TODOs.md is flagged on every write — a page whose PURPOSE is to say what is awaited, which rule A1 holds to be universally unestablishable. This mutant is also the one that FOUND the duplicated predicate: with the surface list written twice, widening one copy left the other narrow and the mutant survived."

mutant "exclusions-dropped" "D9" "$HOOK_REL" \
    'EXCLUDE = re.compile(r"(/fixtures/|\.corpus\.md$|/node_modules/)")' \
    'EXCLUDE = re.compile(r"(?!x)x")' \
    "without the exclusions a corpus file is flagged for the known-bad sentences it asserts ON PURPOSE — the check reporting its own test data as a finding."

# --- THE CHANNEL ---------------------------------------------------------------------------
mutant "context-key-dropped" "D1" "$HOOK_REL" \
    '"additionalContext": "\n".join(lines)},' \
    '"somethingElse": "\n".join(lines)},' \
    "additionalContext is the key the host lifts into the author's context; under any other name the rows are computed, serialized, and read by nobody."

mutant "back-to-the-blocking-channel" "D13" "$HOOK_REL" \
    'print(json.dumps({
    "hookSpecificOutput": {"hookEventName": "PostToolUse",
                           "additionalContext": "\n".join(lines)},
    "suppressOutput": True,
}))
sys.exit(0)' \
    'print("\n".join(lines), file=sys.stderr)
sys.exit(2)' \
    "stderr at exit 2 also reaches the author - both channels were measured in headless sessions and both do - but the host wraps that one in 'PostToolUse hook BLOCKING ERROR from command' over a write that SUCCEEDED, so the notice's own first sentence is contradicted by the banner above it."

mutant "record-edited" "D13" "$HOOK_REL" \
    'print(json.dumps({' \
    'open(out[0][0], "a", encoding="utf-8").write("\n".join(lines))
print(json.dumps({' \
    "the rows are 56% false on the measured corpus; appending them into the record would put that noise in the durable record forever, and D13 is the case that forbids it."

# --- NEVER A FAILED TOOL CALL ---------------------------------------------------------------
mutant "errors-propagate" "D12" "$HOOK_REL" \
    "except Exception:
    sys.exit(0)                        # a check that cannot run is silent, never a failure" \
    "except Exception:
    raise" \
    "a broken or missing predicate must never look like a failed write; the tool call already succeeded and this hook cannot undo it."

echo ""
echo "  $PASS mutants killed, $FAIL not killed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
