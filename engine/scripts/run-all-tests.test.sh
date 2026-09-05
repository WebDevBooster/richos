#!/usr/bin/env bash
#
# run-all-tests.test.sh — THE RUNNER'S LEAK CANARY, PROVEN WHERE IT LIVES.
#
# scripts/lib/leak-canary.test.sh proves the DETECTOR. This proves the WIRING,
# and they are different claims: a correct detector that is never consulted, or
# consulted and then not allowed to change the verdict, is a green tick over
# the defect with extra steps. That distinction is not academic here — on
# 2026-09-02 five separate checks in this engine were found green over code
# that never ran.
#
# So every case below drives the REAL scripts/run-all-tests.sh against a
# throwaway engine containing throwaway suites, and reads its EXIT CODE and its
# OUTPUT — never the library's return value.
#
# BOTH DIRECTIONS, because a canary that reports everything is as useless as
# one that reports nothing: a suite that writes only in its own sandbox must
# leave the runner GREEN (case 1), and one that writes into the checkout must
# turn it RED and be NAMED (cases 2 and 3).
#
# NOT COVERED, by name: the cost of the canary on a real 68-suite run, and
# whether any SHIPPED suite trips it. That is a measurement over a run of about
# an hour, not a unit test, and it belongs in a measurement record rather than
# here.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t run-all-tests-test.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '          %s\n' "$2"; FAIL=$((FAIL + 1)); }

echo "=== run-all-tests: the leak canary is wired, and it decides the verdict ==="

NO_HOOKS="$SANDBOX/empty-hooks"; mkdir -p "$NO_HOOKS"
git_q() { git -C "$1" -c core.hooksPath="$NO_HOOKS" -c user.email=t@t -c user.name=t "${@:2}"; }

# build_engine <dir> — a throwaway engine checkout carrying the real runner and
# the real libraries, in a real git repository (the canary's primary branch is
# the git one, so a fixture that is not a repository would exercise the wrong
# half of it).
build_engine() {
    local d="$1"
    mkdir -p "$d/engine/scripts/lib" "$d/engine/scripts/hooks" "$d/engine/hooks"
    cp "$ENGINE_ROOT/scripts/run-all-tests.sh" "$d/engine/scripts/"
    cp "$ENGINE_ROOT/scripts/lib/tree-witness.sh" "$ENGINE_ROOT/scripts/lib/leak-canary.sh" "$d/engine/scripts/lib/"
    chmod +x "$d/engine/scripts/run-all-tests.sh"
    printf 'PROTECTED_PATHS="app"\n' > "$d/engine/orchestration.config"
    git init -q -b main "$d"
    git_q "$d" add -A
    git_q "$d" commit -q -m seed
}

# a suite that stays inside its own sandbox
clean_suite() {
    cat > "$1" <<'EOF'
#!/usr/bin/env bash
S="$(mktemp -d)"; trap 'rm -rf "$S"' EXIT
printf 'fixture\n' > "$S/fixture.txt"
echo "  PASS  wrote only inside its sandbox"
exit 0
EOF
    chmod +x "$1"
}

# ===========================================================================
# 1. GREEN: well-behaved suites leave the runner green, and it SAYS it checked.
# ===========================================================================
E1="$SANDBOX/e1"
build_engine "$E1"
clean_suite "$E1/engine/scripts/hooks/alpha.test.sh"
clean_suite "$E1/engine/scripts/hooks/beta.test.sh"
git_q "$E1" add -A; git_q "$E1" commit -q -m suites
OUT1="$( cd "$E1/engine" && bash scripts/run-all-tests.sh 2>&1 )"; RC1=$?
if [ "$RC1" -eq 0 ]; then
    ok "1a  GREEN: two suites that write only in their sandboxes leave the runner at rc 0 — the canary does not report activity"
else
    bad "1a  a clean run stays green" "rc=$RC1; the canary is firing on suites that leaked nothing:
$OUT1"
fi
case "$OUT1" in
    *"leak canary: watching"*) ok "1b  and it announces how many roots it is watching and what its witness is — a canary watching zero roots would pass forever in silence" ;;
    *)                         bad "1b  the canary announces itself" "no canary line in the output: $OUT1" ;;
esac
case "$OUT1" in
    *"none wrote outside its sandbox"*) ok "1c  and the green banner claims the sandbox check specifically, so a reader can tell this run from one where the canary was absent" ;;
    *)                                  bad "1c  the banner names the check" "got: $OUT1" ;;
esac

# ===========================================================================
# 2. RED on residue: a suite that writes an untracked file into the checkout.
#    This is the 2026-09-05 escalations defect.
# ===========================================================================
E2="$SANDBOX/e2"
build_engine "$E2"
clean_suite "$E2/engine/scripts/hooks/alpha.test.sh"
cat > "$E2/engine/scripts/hooks/leaky.test.sh" <<EOF
#!/usr/bin/env bash
printf 'id: looks-like-a-real-record\n' > "$E2/docs-escaped-record.md"
echo "  PASS  every assertion passed"
exit 0
EOF
chmod +x "$E2/engine/scripts/hooks/leaky.test.sh"
git_q "$E2" add -A; git_q "$E2" commit -q -m suites
OUT2="$( cd "$E2/engine" && bash scripts/run-all-tests.sh 2>&1 )"; RC2=$?
if [ "$RC2" -ne 0 ]; then
    ok "2a  RED: a suite whose own assertions all pass still fails the run because it wrote outside its sandbox"
else
    bad "2a  a leaking suite fails the run" "rc=0. The suite exited 0 and the canary did not change the verdict, so this is a green tick over the defect:
$OUT2"
fi
case "$OUT2" in
    *leaky.test.sh*) ok "2b  and the LEAKING SUITE is named — per-suite baselines mean nobody has to bisect 68 suites to find it" ;;
    *)               bad "2b  the leaking suite is named" "got: $OUT2" ;;
esac
case "$OUT2" in
    *docs-escaped-record.md*) ok "2c  and so is the file it left behind, so the reader can see at a glance it is residue rather than a real record" ;;
    *)                        bad "2c  the escaped file is named" "got: $OUT2" ;;
esac
case "$OUT2" in
    *"WROTE OUTSIDE ITS SANDBOX"*) ok "2d  and it is explained as residue, not as a test failure — the suite's assertions did pass" ;;
    *)                             bad "2d  residue is explained as residue" "got: $OUT2" ;;
esac
# The other suite must NOT be blamed. Per-suite baselines exist for this.
# THE ASSERTION IS ON alpha's OWN LINE, not on the whole output. A `case`
# against the whole string matched "alpha.test.sh ... PASS ... leaky ... FAIL"
# and reported the runner as broken when the runner was right — this case
# failed for a reason unrelated to what it tests, which proves nothing about
# anything. Its first version is why the line is isolated here.
ALPHA_LINE="$(printf '%s\n' "$OUT2" | sed $'s/\033\\[[0-9;]*m//g' | grep 'alpha\.test\.sh')"
case "$ALPHA_LINE" in
    *PASS*) ok "2e  and the innocent suite beside it is NOT blamed — the baseline is re-taken per suite, so residue is charged once, to its author" ;;
    "")     bad "2e  the innocent suite is not blamed" "alpha.test.sh has no line in the output at all, so it was not run" ;;
    *)      bad "2e  the innocent suite is not blamed" "alpha's own line is not a PASS, so the attribution is not per-suite: $ALPHA_LINE" ;;
esac

# ===========================================================================
# 3. RED on a TRACKED change: the mutation-harness defect. Different finding,
#    different explanation — this one means the run tested two different trees.
# ===========================================================================
E3="$SANDBOX/e3"
build_engine "$E3"
printf 'THE_SHIPPED_GUARD=1\n' > "$E3/engine/scripts/hooks/pretend-guard.sh"
clean_suite "$E3/engine/scripts/hooks/alpha.test.sh"
cat > "$E3/engine/scripts/hooks/mutating.test.sh" <<EOF
#!/usr/bin/env bash
# the old harness shape: mutate the shipped file and (here) never restore it
printf 'THE_SHIPPED_GUARD=0\n' > "$E3/engine/scripts/hooks/pretend-guard.sh"
echo "  PASS  every assertion passed"
exit 0
EOF
chmod +x "$E3/engine/scripts/hooks/mutating.test.sh"
git_q "$E3" add -A; git_q "$E3" commit -q -m suites
OUT3="$( cd "$E3/engine" && bash scripts/run-all-tests.sh 2>&1 )"; RC3=$?
if [ "$RC3" -ne 0 ]; then
    ok "3a  RED: a suite that modifies a TRACKED engine file mid-run fails it, however green its own assertions were"
else
    bad "3a  a tracked mid-run change fails the run" "rc=0:
$OUT3"
fi
case "$OUT3" in
    *"TRACKED FILE CHANGED DURING THE RUN"*)
        ok "3b  and it is explained as 'every suite after this one tested different code' — not as residue, which is a different and lesser problem" ;;
    *)  bad "3b  a tracked change gets its own explanation" "got: $OUT3" ;;
esac
case "$OUT3" in
    *pretend-guard.sh*) ok "3c  and the modified file is named" ;;
    *)                  bad "3c  the modified file is named" "got: $OUT3" ;;
esac

# ===========================================================================
# 4. A MISSING LIBRARY IS A REFUSAL, NOT A QUIET DEGRADATION. Under `set -u`
#    without `-e`, sourcing a file that is not there prints and carries on —
#    so without an explicit check the runner would report a fraction with its
#    own sandbox check silently absent.
# ===========================================================================
E4="$SANDBOX/e4"
build_engine "$E4"
clean_suite "$E4/engine/scripts/hooks/alpha.test.sh"
rm -f "$E4/engine/scripts/lib/leak-canary.sh"
OUT4="$( cd "$E4/engine" && bash scripts/run-all-tests.sh 2>&1 )"; RC4=$?
if [ "$RC4" -eq 2 ]; then
    ok "4a  the runner REFUSES (rc 2) when the canary's library is missing, rather than reporting a green fraction without it"
else
    bad "4a  a missing canary library is refused" "rc=$RC4, so a partial install would report a reassuring fraction with no sandbox check running at all:
$OUT4"
fi
case "$OUT4" in
    *leak-canary.sh*) ok "4b  and it names the file that is missing" ;;
    *)                bad "4b  the missing library is named" "got: $OUT4" ;;
esac

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
