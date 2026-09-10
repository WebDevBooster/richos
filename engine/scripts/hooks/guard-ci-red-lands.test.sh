#!/usr/bin/env bash
#
# guard-ci-red-lands.test.sh — what the CI red gate must and must NOT do.
#
# EVERY CASE RUNS OFFLINE. The gate's only network dependency is
# scripts/lib/ci-red.py, and this suite replaces it with a stub on PATH-order
# so that a red / clear / unknown answer is something the test DECIDES rather
# than something GitHub happens to be doing while the suite runs. A suite whose
# verdict depends on the state of a remote service is a suite that goes red for
# reasons unrelated to the code it tests, and gets ignored.
#
# THE CASES, and why each is here rather than asserted in a comment:
#
#   R1  a `git commit` on the watched branch is SILENT. The gate exists to stop
#       LANDS, and engineers commit dozens of times a day; if this case ever
#       fails the guard is dead within an hour.
#   R2  a push of a NON-watched branch is SILENT. This is the overwhelming
#       majority of pushes in this project — every teammate handoff is one.
#   R3  `--dry-run` is SILENT. It lands nothing.
#   R4  a push to the watched branch, with red standing, is REFUSED, and the
#       refusal NAMES every red workflow and the age of each streak. "Red" with
#       no age is the fact that let thirteen days happen.
#   R5  a merge while HEAD is on the watched branch is REFUSED. A merge takes
#       no branch argument, so the current branch is what makes it a land.
#   R6  a BARE ack does not exempt anything. Same discipline as the contrast
#       floor and the dialect guard: a marker with no reason is not a claim.
#   R7  a PARTIAL ack still refuses, and names only what was NOT acked. This is
#       the case that makes the hatch cost proportional to the breakage.
#   R8  an ack naming a workflow that is NOT red exempts nothing, and is called
#       out — it is either a typo or a copied line, and both are worth seeing.
#   R9  a COMPLETE ack allows, and every accepted ack is written to the log.
#   R10 the log drives a REPETITION COUNT that appears from the third use. The
#       anti-habit mechanism is the only thing standing between this hatch and
#       the fate of g11/g12/g13, so it is a case, not a hope.
#   R11 an UNKNOWN answer ALLOWS and ANNOUNCES. This is the deliberate inverse
#       of this engine's fail-closed instinct and the argument is in the
#       guard's header; if it ever silently allows, the announcement is what
#       was lost and this case is what notices.
#   R12 a CLEAR answer is SILENT — no output at all. A guard that prints on
#       every clean land teaches people to filter its output.
#   R13 the gate never fires on a repository with no GitHub origin.
#   R14 THE NEGATIVE CONTROL: with the stub forced to `red` and no ack, the
#       gate must exit 2. Without this, every "silent" case above would also
#       pass against a gate that had been accidentally disabled.
#
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/guard-ci-red-lands.sh"

PASS=0; FAIL=0
SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ci-red-gate.XXXXXX")" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -f "$GUARD" ] || { echo "FATAL: missing $GUARD" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git required" >&2; exit 1; }

echo "=== guard-ci-red-lands tests ==="

# ---------------------------------------------------------------------------
# A repository to be judged. Real, because the guard resolves the branch and
# the origin through git and a fake would prove nothing about that path.
# ---------------------------------------------------------------------------
# DELIBERATELY NO COMMIT AND NO IDENTITY. Two reasons, and both are findings
# rather than convenience:
#
#   * A machine-wide pre-commit identity guard refuses a fixture commit made
#     under an invented address, and setting one anyway would make this suite
#     depend on that guard's absence. scripts/lib/resolve-roots.test.sh already
#     records the same constraint.
#   * The UNBORN branch is a case worth having. `git rev-parse --abbrev-ref
#     HEAD` exits 128 on it, which the guard originally used and which made it
#     blind on any checkout before its first commit. This fixture is the reason
#     that was found; the guard now asks `symbolic-ref` instead.
REPO="$SANDBOX/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" remote add origin "git@github.com:Example/thing.git"

NO_ORIGIN="$SANDBOX/bare"
mkdir -p "$NO_ORIGIN"
git -C "$NO_ORIGIN" init -q -b main

# ---------------------------------------------------------------------------
# THE STUB. It replaces scripts/lib/ci-red.py for the duration of the suite by
# pointing the guard at a copy of the engine whose lib/ci-red.py is this stub.
# The guard finds the probe RELATIVE TO ITSELF, so the copy is of the hooks
# directory, and that is deliberate: it exercises the same resolution the real
# guard uses rather than an environment variable that only tests set.
# ---------------------------------------------------------------------------
FAKE_ENGINE="$SANDBOX/engine"
mkdir -p "$FAKE_ENGINE/scripts/hooks" "$FAKE_ENGINE/scripts/lib"
cp "$GUARD" "$FAKE_ENGINE/scripts/hooks/"
for f in resolve-roots.sh git-jurisdiction.sh; do
    cp "$SCRIPT_DIR/../lib/$f" "$FAKE_ENGINE/scripts/lib/"
done
STUB_GUARD="$FAKE_ENGINE/scripts/hooks/guard-ci-red-lands.sh"

cat > "$FAKE_ENGINE/scripts/lib/ci-red.py" <<'STUB'
#!/usr/bin/env python3
"""Stand-in for the live probe. Answers whatever CI_RED_STUB says."""
import json, os, sys
mode = os.environ.get("CI_RED_STUB", "clear")
doc = {"repo": "Example/thing", "branch": "main", "read_at": "2026-09-10T00:00:00Z",
       "source": "stub", "workflows_seen": 3, "state": mode, "red": []}
if mode == "red":
    doc["red"] = [
        {"workflow": "alpha-ci.yml", "name": "alpha-ci", "conclusion": "failure",
         "run_number": 40, "since_run": 31, "days": 13, "days_is_a_floor": False,
         "last_green_run": 30, "file_backed": True, "path": ".github/workflows/alpha-ci.yml",
         "url": "https://example.invalid/40"},
        {"workflow": "beta-ci.yml", "name": "beta-ci", "conclusion": "failure",
         "run_number": 7, "since_run": 7, "days": 2, "days_is_a_floor": True,
         "last_green_run": None, "file_backed": True, "path": ".github/workflows/beta-ci.yml",
         "url": "https://example.invalid/7"},
    ]
elif mode == "unknown":
    doc["reason"] = "the stub was told to be unable to look"
print(json.dumps(doc, indent=2))
sys.exit({"clear": 0, "red": 1}.get(mode, 3))
STUB

# run <stub-mode> <cwd> <command> -> stdout+stderr in $OUT, rc in $RC
ACK_LOG="$SANDBOX/acks.log"
run() {
    local mode="$1" cwd="$2" cmd="$3" payload
    payload="$(python3 -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "cwd": sys.argv[1],
                  "tool_input": {"command": sys.argv[2]}}))' "$cwd" "$cmd")"
    OUT="$(printf '%s' "$payload" \
        | CI_RED_STUB="$mode" CI_RED_ACK_LOG="$ACK_LOG" bash "$STUB_GUARD" 2>&1)"
    RC=$?
}

G=git  # so this file's own commands are not mistaken for the gate's subject

# --- R1 --------------------------------------------------------------------
run red "$REPO" "$G commit -m 'work'"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok "R1   a commit on the watched branch is silent, even with red standing"
else
    bad "R1   rc=$RC out=<$OUT> — a gate that fires on `git commit` is dead within the hour"
fi

# --- R2 --------------------------------------------------------------------
run red "$REPO" "$G push origin worktree-abc123"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok "R2   pushing a non-watched branch is silent (every teammate handoff is one)"
else
    bad "R2   rc=$RC out=<$OUT>"
fi

# --- R3 --------------------------------------------------------------------
run red "$REPO" "$G push --dry-run origin main"
if [ "$RC" -eq 0 ]; then
    ok "R3   a dry run lands nothing and is allowed"
else
    bad "R3   rc=$RC — a dry run was refused"
fi

# --- R4 --------------------------------------------------------------------
run red "$REPO" "$G push origin main"
if [ "$RC" -eq 2 ] \
   && grep -q "alpha-ci.yml" <<<"$OUT" && grep -q "beta-ci.yml" <<<"$OUT" \
   && grep -q "13 day" <<<"$OUT" && grep -q "at least 2 day" <<<"$OUT"; then
    ok "R4   a push to main with red standing is REFUSED, naming both workflows and both ages"
else
    bad "R4   rc=$RC — the refusal did not name every red workflow with its age:"
    printf '%s\n' "$OUT" | sed 's/^/          /' | head -12
fi

# --- R5 --------------------------------------------------------------------
run red "$REPO" "$G merge some-branch"
if [ "$RC" -eq 2 ] && grep -q "REFUSED" <<<"$OUT"; then
    ok "R5   a merge while HEAD is on the watched branch is REFUSED"
else
    bad "R5   rc=$RC — a merge onto a red main was allowed"
fi

# --- R6 --------------------------------------------------------------------
run red "$REPO" "$G push origin main # ci-red-ack: alpha-ci"
if [ "$RC" -eq 2 ] && grep -q "marker, not a reason" <<<"$OUT"; then
    ok "R6   a bare ack exempts nothing, and says why"
else
    bad "R6   rc=$RC — a bare marker was accepted as a declaration"
fi

# --- R7 --------------------------------------------------------------------
run red "$REPO" "$G push origin main # ci-red-ack: alpha-ci — the fix is in this very land"
if [ "$RC" -eq 2 ] && grep -q "beta-ci.yml" <<<"$OUT" && ! grep -q "  alpha-ci.yml   failure" <<<"$OUT"; then
    ok "R7   a partial ack still refuses, and names only the workflow that was not acked"
else
    bad "R7   rc=$RC — a partial ack did not behave as a partial ack:"
    printf '%s\n' "$OUT" | sed 's/^/          /' | head -10
fi

# --- R8 --------------------------------------------------------------------
run red "$REPO" "$G push origin main # ci-red-ack: gamma-ci — this workflow is not red at all"
if [ "$RC" -eq 2 ] && grep -q "alpha-ci.yml" <<<"$OUT" && grep -q "beta-ci.yml" <<<"$OUT"; then
    ok "R8   an ack naming a workflow that is not red exempts nothing"
else
    bad "R8   rc=$RC — an ack for a green workflow let a red land through"
fi

# --- R9 --------------------------------------------------------------------
rm -f "$ACK_LOG"
BOTH="$G push origin main # ci-red-ack: alpha-ci — upstream owns this repair today"
BOTH="$BOTH # ci-red-ack: beta-ci — a dedicated engineer is on it right now"
run red "$REPO" "$BOTH"
if [ "$RC" -eq 0 ] && grep -q "allowed on a declared ack" <<<"$OUT" \
   && [ -f "$ACK_LOG" ] && [ "$(grep -c . "$ACK_LOG")" -eq 2 ]; then
    ok "R9   a complete ack allows, and both acks are written to the durable log"
else
    bad "R9   rc=$RC log=$( [ -f "$ACK_LOG" ] && grep -c . "$ACK_LOG" || echo missing )"
fi

# --- R10 -------------------------------------------------------------------
run red "$REPO" "$BOTH"
run red "$REPO" "$BOTH"
if [ "$RC" -eq 0 ] && grep -q "ACK NUMBER 3" <<<"$OUT"; then
    ok "R10  the third ack for the same workflow says so — a habit is turned into evidence"
else
    bad "R10  rc=$RC — the repetition counter did not appear:"
    printf '%s\n' "$OUT" | sed 's/^/          /' | head -8
fi

# --- R11 -------------------------------------------------------------------
run unknown "$REPO" "$G push origin main"
if [ "$RC" -eq 0 ] && grep -q "COULD NOT LOOK" <<<"$OUT" && grep -q "NOT 'CI is clear'" <<<"$OUT"; then
    ok "R11  an unknown answer ALLOWS and ANNOUNCES — 'could not look' is never 'found nothing'"
else
    bad "R11  rc=$RC — an unreadable probe was either silent or blocking:"
    printf '%s\n' "$OUT" | sed 's/^/          /' | head -8
fi

# --- R12 -------------------------------------------------------------------
run clear "$REPO" "$G push origin main"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok "R12  a clear answer is completely silent"
else
    bad "R12  rc=$RC out=<$OUT> — the gate speaks on a clean land, which teaches people to filter it"
fi

# --- R13 -------------------------------------------------------------------
run red "$NO_ORIGIN" "$G push origin main"
if [ "$RC" -eq 0 ]; then
    ok "R13  a repository with no GitHub origin has no CI surface and is not gated"
else
    bad "R13  rc=$RC — a repository with no remote was gated on someone else's CI"
fi

# --- R14: THE NEGATIVE CONTROL ---------------------------------------------
# Every silent case above would also pass against a guard that had been
# neutered. This one fails if the guard has stopped refusing anything at all,
# which is the only way to know the silences mean what they say.
run red "$REPO" "$G push origin main"
if [ "$RC" -eq 2 ]; then
    ok "R14  NEGATIVE CONTROL: the gate still refuses, so the silences above are real silences"
else
    bad "R14  rc=$RC — THE GATE REFUSES NOTHING. Every 'silent' case above is meaningless."
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "=== guard-ci-red-lands tests: all $PASS passed ==="
    exit 0
fi
echo "=== guard-ci-red-lands tests: $PASS passed, $FAIL FAILED ===" >&2
exit 1
