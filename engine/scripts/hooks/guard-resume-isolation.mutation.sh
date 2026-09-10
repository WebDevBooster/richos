#!/usr/bin/env bash
#
# guard-resume-isolation.mutation.sh — PROVES THE RESUME-ISOLATION SUITE CAN FAIL.
#
# 48 green ticks are evidence of nothing until somebody shows them turning red
# for the right reason. That is this project's most-repeated defect, and this
# guard is unusually exposed to it: almost every property here is of the form
# "it did not quietly wave a resume through", and a test for "it did not quietly
# do the wrong thing" passes for free — including when the guard never ran at
# all. The standing scar is exact: a check was green for months over a scanner
# that never started, because "exit 2 = caught it" and "exit 2 = never ran" are
# the same byte.
#
# The 2026-09-02 repair makes that worse before it makes it better, because it
# adds an ALLOW path. An allow that fires for the wrong reason is invisible: the
# message goes through and nobody sees a refusal that should have happened. So
# every one of the new properties is removed here, one at a time, and the SPECIFIC
# named case must go red.
#
# So: take the shipped source, remove ONE property at a time, and assert that
#   1. guard-resume-isolation.test.sh FAILS,
#   2. the SPECIFIC named case fails — not merely "something went red", and
#   3. the mutation actually applied (a replacement that matched nothing gives
#      a green run that looks like a green run, which is the same trap again).
#
# Every mutant is a throwaway copy of the engine subtree. Nothing here touches
# the real tree.
#
# Run directly: scripts/hooks/guard-resume-isolation.mutation.sh
# Exit 0 = every property is proven load-bearing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t guard-resume-mutation.XXXXXX)" && pwd -P)"
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

# mutant <name> <expected-failing-case> <rel-file> <old> <new> <why>
# --- concurrency ------------------------------------------------------------
# Each mutant builds its own sandbox under $SANDBOX/<name> and runs a whole
# suite against it, so no two mutants share a path and none of them is ordered
# against another. They ran one at a time only because a `for` loop is what this
# harness was first written as. mutation-pool.sh bounds the fan-out, keeps the
# report in declaration order, and counts a KILLED mutant as a failure rather
# than letting it vanish from the tally. RICHOS_MUTANT_JOBS overrides the degree.
# shellcheck source=../lib/stopwatch.sh
. "$ENGINE_ROOT/scripts/lib/stopwatch.sh"
# shellcheck source=../lib/mutation-pool.sh
. "$ENGINE_ROOT/scripts/lib/mutation-pool.sh"
mut_pool_init
MUT_WALL_T0="$(sw_now_ms)"

_mutant_body() {
    local name="$1" want="$2" rel="$3" old="$4" new="$5" why="$6"
    local dir="$SANDBOX/$name"
    mkdir -p "$dir/scripts/hooks" "$dir/scripts/lib"
    cp "$ENGINE_ROOT/scripts/hooks/guard-resume-isolation.sh" \
       "$ENGINE_ROOT/scripts/hooks/guard-resume-isolation.test.sh" "$dir/scripts/hooks/"
    cp "$ENGINE_ROOT/scripts/lib/resolve-roots.sh" \
       "$ENGINE_ROOT/scripts/lib/resolve-main-checkout.sh" \
       "$ENGINE_ROOT/scripts/lib/agent-liveness.py" \
       "$ENGINE_ROOT/scripts/lib/teammate-identity.py" "$dir/scripts/lib/"
    printf 'SESSION_TEAMS_DIR=""\n' >"$dir/orchestration.config"
    chmod +x "$dir/scripts/hooks/"*.sh

    if ! python3 "$SANDBOX/mutate.py" "$dir/$rel" "$old" "$new" 2>"$dir/mutate.err"; then
        printf '  FAIL  %s — the mutation did not apply\n' "$name"
        sed 's/^/          /' "$dir/mutate.err"
        return 1
    fi

    bash "$dir/scripts/hooks/guard-resume-isolation.test.sh" >"$dir/out.txt" 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '  FAIL  %s — the suite still PASSED without this property.\n' "$name"
        printf '          %s\n' "$why"
        return 1
    fi
    if ! grep -q "FAIL  $want" "$dir/out.txt"; then
        printf '  FAIL  %s — the suite went red, but NOT at %s (so the red is unrelated).\n' "$name" "$want"
        grep '  FAIL' "$dir/out.txt" | sed 's/^/          /'
        return 1
    fi
    printf '  PASS  %s — removing it turns %s red\n' "$name" "$want"
    return 0
}
# mutant <name> ... — a SUBMISSION, not an execution. The body above is unchanged
# except that it returns its verdict instead of incrementing a counter: it runs
# in a pool worker, which is a subshell, so an increment in there would mutate a
# copy and be discarded. The pool prints the bodies in DECLARATION order, so this
# harness's report is byte-identical to the serial one but for the durations.
mutant() {
    mut_pool_submit "$1" _mutant_body "$@"
}

echo "=== resume isolation: every property, proven load-bearing by removing it ==="

# 1. THE AUTHORITATIVE CONSULT ITSELF. This is the 2026-09-02 defect restored:
#    the roster refuses on its own, and a live background agent — which the
#    roster structurally cannot see — is refused every single time.
mutant no-authoritative-consult "live background agent by agent-<id> -> allow" \
    scripts/hooks/guard-resume-isolation.sh \
    'if [ "$LKIND" = "ALIVE" ]; then
  exit 0
fi' \
    'if [ "$LKIND" = "NEVER-ALIVE" ]; then
  exit 0
fi' \
    "Every notice to a live background agent would need a resume-ack: waiver again."

# 2. INDETERMINATE IS NOT "ALLOW". A resolver that collapses "I could not tell"
#    into "go ahead" is the failure this engine keeps finding in itself.
mutant indeterminate-allows "INDETERMINATE liveness (git unqueryable) -> BLOCKED, not allowed" \
    scripts/hooks/guard-resume-isolation.sh \
    'if [ "$LKIND" = "ALIVE" ]; then
  exit 0
fi' \
    'if [ "$LKIND" = "ALIVE" ] || [ "$LKIND" = "INDETERMINATE" ]; then
  exit 0
fi' \
    "An unreadable repository would read as a live agent and wave the resume through."

# 3. NOT-ALIVE MUST STILL REFUSE. This is the protection the whole guard exists
#    for: a resumed teammate whose worktree was landed and removed wakes with no
#    workspace and improvises.
mutant not-alive-allows "completed + worktree REMOVED -> still BLOCKED" \
    scripts/hooks/guard-resume-isolation.sh \
    '    if v == al.ALIVE:
        emit("ALIVE", line)' \
    '    if v in (al.ALIVE, al.NOT_ALIVE):
        emit("ALIVE", line)' \
    "A landed-and-removed teammate would be resumed with nowhere to write."

# 4. THE EXACT NAME JOIN. Without it only the raw id forms work, and the lead
#    addresses teammates by NAME — which is the form that was refused.
mutant no-name-join "live background agent by NAME (not in roster) -> allow" \
    scripts/hooks/guard-resume-isolation.sh \
    '        if aid:
            targets.append((aid, "exact name join via %s" % (how or "the identity index")))' \
    '        if False:
            targets.append((aid, "exact name join via %s" % (how or "the identity index")))' \
    "A message addressed by the teammate's own unique spawn name would still be refused."

# 5. THE agent-<id> ADDRESS FORM.
mutant no-agent-dir-form "live background agent by agent-<id> -> allow" \
    scripts/hooks/guard-resume-isolation.sh \
    'if re.match(r"^agent-[A-Za-z0-9_]+$", to):
    targets.append((to, "addressed by agent directory name"))' \
    'if False:
    targets.append((to, "addressed by agent directory name"))' \
    "SendMessage to agent-<id> — a legal address — would be refused."

# 6. THE RAW AGENT ID ADDRESS FORM. SendMessage's own documentation sanctions
#    it, and the lead used it on 2026-09-01.
mutant no-raw-id-form "live background agent by RAW agent id -> allow" \
    scripts/hooks/guard-resume-isolation.sh \
    '        if to in (index.get("names") or {}):
            targets.append((to, "addressed by raw agent id"))' \
    '        if False:
            targets.append((to, "addressed by raw agent id"))' \
    "SendMessage to a bare agentId — the second legal form — would be refused."

# 7. NAMING THE DISAGREEMENT. A refusal that quotes only the roster is the
#    2026-09-02 defect wearing a nicer error message.
mutant no-liveness-evidence "refusal names the authoritative liveness source" \
    scripts/hooks/guard-resume-isolation.sh \
    'emit_liveness_evidence "$LKIND" "$LDETAIL"' \
    ': "$LKIND" "$LDETAIL"' \
    "The operator would see 'not in session roster' and never learn what the lock said."

# 8. THE ROSTER'S CHEAP ALLOW. It is advisory, but it is not decoration: an
#    in-process teammate takes no worktree lock at all and has nothing else.
mutant roster-allow-removed "active: present-worktree recipient -> allow" \
    scripts/hooks/guard-resume-isolation.sh \
    'if [ "$VKIND" = "ACTIVE" ]; then
  exit 0
fi' \
    'if [ "$VKIND" = "NEVER-ACTIVE" ]; then
  exit 0
fi' \
    "Every in-process teammate would be refused, since none of them hold a worktree lock."

# 9. THE FIXTURE'S OWN PRE-FLIGHT. If `git worktree lock` silently did nothing,
#    "the lock is held" and "the lock was never taken" would read the same and
#    the whole (m) block would be measuring nothing.
mutant fixture-preflight-honest "fixture: the live agent worktree is NOT locked" \
    scripts/hooks/guard-resume-isolation.test.sh \
    'git -C "$BG_REPO" worktree lock \
    --reason "claude agent agent-$LIVE_ID (pid $$ start Tue Sep  2 09:00:00 2026)" \
    "$BG_REPO/.claude/worktrees/agent-$LIVE_ID" >/dev/null 2>&1' \
    ': skip the lock entirely' \
    "A fixture that never locked would let the live-agent cases pass for the wrong reason."

# --- the verdict ------------------------------------------------------------
# Drained rather than accumulated: PASS/FAIL below come from the workers' exit
# codes, and a worker that left no exit code is counted as a FAILURE. The tally
# that follows is unchanged and still decides this harness's exit status.
# ADDITIVE, NOT ASSIGNMENT, and that is a correction found by measurement rather
# than by reading: mechanical-findings.mutation.sh scores one case BEFORE its
# mutants, and `PASS="$MUT_POOL_PASS"` silently discarded it. A tally that
# overwrites an earlier verdict is a green fraction over a case that ran and was
# thrown away. Harnesses that score nothing beforehand are unaffected, because
# adding to zero is assignment.
mut_pool_drain
# A harness that declared mutants and ran NONE must not exit 0 -- see
# mut_pool_require_submissions for the run where exactly that happened.
mut_pool_require_submissions "$(basename "$0")"
PASS=$(( PASS + MUT_POOL_PASS ))
FAIL=$(( FAIL + MUT_POOL_FAIL ))
mut_pool_report_line "$(( $(sw_now_ms) - MUT_WALL_T0 ))"
mut_pool_cleanup

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== resume-isolation mutation: $FAIL NOT proven, $PASS proven ==="
    exit 1
fi
echo "=== resume-isolation mutation: all $PASS properties proven load-bearing ==="
exit 0
