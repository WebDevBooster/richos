#!/usr/bin/env bash
#
# proof-for.test.sh — what `proof-for.sh` answers, checked against THREE REAL LANDS.
#
# =========================================================================================
# WHY THE FIXTURES ARE REAL COMMITS AND NOT SYNTHETIC DIFFS
# =========================================================================================
# A synthetic diff proves the rules fire. It cannot prove the rules are RIGHT, because the
# author of the fixture and the author of the rule are the same person and they agree by
# construction. So the three fixtures here are lands that actually happened in this
# repository, each chosen because its commit message says in plain words what it changed —
# which is an independent statement of what the proof should be:
#
#   315baf03  phonelive3  the phone's send, its outbox, the pairing screen, the web app
#   e7facc99  harness1    one UI check, one core module's ordering, five testvm scripts
#   62e5affd  shots1      104 regenerated reference shots and the stability library
#
# Each case therefore asserts what the LAND says its own subject was, not what the script
# happens to print today.
#
# THE THIRD ONE IS THE HONEST CASE AND IT IS KEPT DELIBERATELY. shots1 maps to all 55 UI
# suites — no reduction at all — because it touched `lib/shot-stability.js`, which every
# suite reaches through `harness.js`. A targeting tool that quietly pretended otherwise
# would be worse than none, so the assertion is that it says 55 AND names the one file that
# caused it.
#
# run-tests: inputs richos/app/scripts/proof-for.test.sh richos/app/scripts/proof-for.sh richos/app/scripts/proof-for.ui-inputs richos/app/scripts/lib/proof_declarations.py richos/app/scripts/proof-for-declarations.test.py richos/app/scripts/proof-for-engine.test.py richos/engine
# run-tests: covers richos/app/scripts/proof-for.sh richos/app/scripts/lib/proof_declarations.py richos/app/scripts/proof-for-declarations.test.py richos/app/scripts/proof-for-engine.test.py
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$(cd "$DIR/.." && pwd)"
ROOT="$(git -C "$APP" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$APP")"
PF="$DIR/proof-for.sh"

PASS=0; FAIL=0; NOTRUN=0
ok()  { PASS=$((PASS + 1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && echo "        $2"; }
# NOT RUN is neither, and it is NAMED — the one thing this repository refuses to let a
# harness do is report green over a case that never executed.
notrun() { NOTRUN=$((NOTRUN + 1)); echo "  NOT RUN  $1 — $2"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/proof-for-test.XXXXXX")"
# §54: the scratch goes however this ends, including on a signal.
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

# The output goes to a FILE and the exit code is read from the call itself. A command
# substitution runs in a subshell, so `RC=$?` set inside one never reaches here — which is
# how the first draft of this suite read an unbound variable instead of an exit code.
RC=0
run_pf() {  # $@ -> proof-for.sh; leaves the output in $2's file, sets RC
  local dest="$1"; shift
  "$PF" "$@" > "$dest" 2>&1; RC=$?
}

have_commit() { git -C "$ROOT" rev-parse --verify --quiet "$1^{commit}" >/dev/null 2>&1; }

if PYTHONDONTWRITEBYTECODE=1 python3 "$DIR/proof-for-declarations.test.py"; then
  ok "J1 script dependencies and behavioral coverage reconcile independently"
else
  bad "J1 script declaration contract"
fi

if PYTHONDONTWRITEBYTECODE=1 python3 "$DIR/proof-for-engine.test.py"; then
  ok "J2 generated engine commands execute and preserve scoped verdicts"
else
  bad "J2 generated engine command contract"
fi

echo "=== proof-for: the three real lands ==="

# -----------------------------------------------------------------------------------------
# A. 315baf03 — the phone path. Its message names the send/outbox (Rust + web app), the
#    pairing screen (ui/phone.js) and the service worker's eviction (web app).
# -----------------------------------------------------------------------------------------
if have_commit 315baf03; then
  run_pf "$WORK/a.out" 315baf03; A_RC=$RC
  [ "$A_RC" -eq 0 ] && ok "A0 phonelive3 maps cleanly (exit 0 — nothing uncovered)" \
                    || bad "A0 phonelive3 maps cleanly" "exit $A_RC; see $WORK/a.out"

  if grep -q 'cargo test --bin richos-tauri phone::device::' "$WORK/a.out" \
  && grep -q 'cargo test --bin richos-tauri phone::secrets::' "$WORK/a.out"; then
    ok "A1 the shell's phone modules name their own unit tests"
  else
    bad "A1 the shell's phone modules name their own unit tests" "$(grep -c 'cargo test' "$WORK/a.out" || true) cargo lines"
  fi

  if grep -q 'node phone.js' "$WORK/a.out" && grep -q 'node no-home-network.js' "$WORK/a.out"; then
    ok "A2 the pairing screen's own two suites are named"
  else
    bad "A2 the pairing screen's own two suites are named"
  fi

  if grep -q 'test/queue.test.js' "$WORK/a.out" && grep -q 'test/api.test.js' "$WORK/a.out"; then
    ok "A3 the outbox's web-app suites are named"
  else
    bad "A3 the outbox's web-app suites are named"
  fi

  # The land's own escalation record is prose. It must be VISIBLE, not dropped.
  if grep -q 'NOT PROVEN BY A SUITE' "$WORK/a.out" \
  && grep -q '2026-09-19-echo-opus-phonelive3' "$WORK/a.out"; then
    ok "A4 the prose in the land is printed by name rather than silently dropped"
  else
    bad "A4 the prose in the land is printed by name rather than silently dropped"
  fi

  # 27 of 55 is the reduction that matters: it is less than the whole inventory.
  N="$(sed -n 's/^UI SUITES — \([0-9]*\) of \([0-9]*\)$/\1 \2/p' "$WORK/a.out")"
  set -- $N
  if [ "${1:-0}" -gt 0 ] && [ "${1:-0}" -lt "${2:-0}" ]; then
    ok "A5 the UI answer is a SUBSET (${1:-?} of ${2:-?}), not the whole inventory"
  else
    bad "A5 the UI answer is a SUBSET, not the whole inventory" "got '$N'"
  fi
else
  bad "A  315baf03 is not in this clone — the phone-path fixture could not run"
fi

# -----------------------------------------------------------------------------------------
# B. e7facc99 — the land whose three subjects are named one by one in its own message.
#    This is the case that found the nested-runner blind spot.
# -----------------------------------------------------------------------------------------
if have_commit e7facc99; then
  run_pf "$WORK/b.out" e7facc99; B_RC=$RC
  [ "$B_RC" -eq 0 ] && ok "B0 harness1 maps cleanly (exit 0)" \
                    || bad "B0 harness1 maps cleanly" "exit $B_RC; see $WORK/b.out"

  grep -q 'node no-home-network.js' "$WORK/b.out" \
    && ok "B1 the one UI check it changed is named" \
    || bad "B1 the one UI check it changed is named"

  grep -q 'cargo test -p richos-core --lib work_host::' "$WORK/b.out" \
    && ok "B2 work_host's own unit tests are named — and no integration target is, because none reads it" \
    || bad "B2 work_host's own unit tests are named"

  grep -q 'bash scripts/testvm/test/run-tests.sh' "$WORK/b.out" \
    && ok "B3 the NESTED testvm runner is named, which run-tests.sh's maxdepth 1 cannot reach" \
    || bad "B3 the NESTED testvm runner is named"

  N="$(sed -n 's/^UI SUITES — \([0-9]*\) of .*$/\1/p' "$WORK/b.out")"
  [ "${N:-0}" -eq 1 ] \
    && ok "B4 a one-check UI change costs ONE suite, not the 19-minute run" \
    || bad "B4 a one-check UI change costs ONE suite" "got ${N:-none}"
else
  bad "B  e7facc99 is not in this clone — the testvm fixture could not run"
fi

# -----------------------------------------------------------------------------------------
# C. 62e5affd — the honest case. 110 paths, and the right answer is "everything", with the
#    reason said out loud.
# -----------------------------------------------------------------------------------------
if have_commit 62e5affd; then
  run_pf "$WORK/c.out" 62e5affd; C_RC=$RC
  [ "$C_RC" -eq 0 ] && ok "C0 shots1 maps cleanly (exit 0)" \
                    || bad "C0 shots1 maps cleanly" "exit $C_RC; see $WORK/c.out"

  N="$(sed -n 's/^UI SUITES — \([0-9]*\) of \([0-9]*\)$/\1 \2/p' "$WORK/c.out")"
  set -- $N
  if [ -n "${1:-}" ] && [ "${1:-0}" -eq "${2:-0}" ]; then
    ok "C1 a shared-library change maps to every suite, and says so (${1} of ${2})"
  else
    bad "C1 a shared-library change maps to every suite" "got '$N'"
  fi

  grep -q 'widest cause:.*shot-stability.js' "$WORK/c.out" \
    && ok "C2 ...and NAMES the one file that made it every suite" \
    || bad "C2 ...and NAMES the one file that made it every suite" "$(grep 'widest cause' "$WORK/c.out" || echo 'no cause line')"

  # Every regenerated shot is claimed by the suite that owns its directory. If the shots
  # mapped to nothing, 104 images would be sitting in UNCOVERED or in the prose list.
  grep -q 'node memory-strategy.js' "$WORK/c.out" \
    && ok "C3 a regenerated shot reaches the suite that owns its directory" \
    || bad "C3 a regenerated shot reaches the suite that owns its directory"
else
  bad "C  62e5affd is not in this clone — the shots fixture could not run"
fi

echo
echo "=== the refusals, which are the part that must not be decorative ==="

# -----------------------------------------------------------------------------------------
# D. A changed CODE path nobody covers is a FAILURE, by name. This is the whole point: a
#    targeting tool that exits 0 over an empty set has certified nothing.
# -----------------------------------------------------------------------------------------
mkdir -p "$ROOT/richos/app/.proof-for-probe" 2>/dev/null
printf '#!/bin/sh\nexit 0\n' > "$ROOT/richos/app/.proof-for-probe/orphan.sh"
run_pf "$WORK/d.out" --paths richos/app/.proof-for-probe/orphan.sh; D_RC=$RC
rm -rf "$ROOT/richos/app/.proof-for-probe"
if [ "$D_RC" -eq 1 ] && grep -q 'UNCOVERED' "$WORK/d.out" && grep -q 'orphan.sh' "$WORK/d.out"; then
  ok "D1 a code path no suite claims exits 1 and is named"
else
  bad "D1 a code path no suite claims exits 1 and is named" "exit $D_RC"
fi

# The POSITIVE PROBE for D1: the same shape of path, but prose, must NOT fail. Without this
# the case above would pass just as well if the script failed on everything.
run_pf "$WORK/dp.out" --paths docs/a-file-that-is-only-prose.md; DP_RC=$RC
if [ "$DP_RC" -eq 0 ] && grep -q 'NOT PROVEN BY A SUITE' "$WORK/dp.out"; then
  ok "D2 (positive probe) prose in the same position exits 0 and is listed, not failed"
else
  bad "D2 (positive probe) prose exits 0 and is listed" "exit $DP_RC"
fi

# -----------------------------------------------------------------------------------------
# E. The reconciliation. Each of the four ways the declaration can go stale must REFUSE,
#    with exit 2, naming what is wrong. A map that answers from a stale row is worse than
#    no map, because it answers.
# -----------------------------------------------------------------------------------------
DECL="$DIR/proof-for.ui-inputs"
mutate() { cp "$DECL" "$WORK/decl"; printf '%s\n' "$1" >> "$WORK/decl"; \
           PROOF_FOR_UI_INPUTS="$WORK/decl" "$PF" --paths richos/app/ui/main.js 2>&1; }

OUT="$(mutate 'a-suite-that-does-not-exist.js richos/app/ui/main.js')"
printf '%s' "$OUT" | grep -q 'not a suite in ui/tests' \
  && ok "E1 a row naming a suite that is not there refuses" \
  || bad "E1 a row naming a suite that is not there refuses" "$OUT"

OUT="$(mutate 'home.js richos/app/ui/a-file-that-is-not-there.js')"
printf '%s' "$OUT" | grep -q 'not in the tree' \
  && ok "E2 a row naming a path that is not there refuses" \
  || bad "E2 a row naming a path that is not there refuses" "$OUT"

OUT="$(mutate 'home.js @nosuchalias')"
printf '%s' "$OUT" | grep -q 'which no line defines' \
  && ok "E3 a row using an alias nobody defines refuses" \
  || bad "E3 a row using an alias nobody defines refuses" "$OUT"

# A suite with NO row is the stale case that matters most: a suite lands, nobody declares
# it, and from that moment the map silently under-answers for every file that suite reads.
grep -v '^home.js ' "$DECL" > "$WORK/decl-missing"
OUT="$(PROOF_FOR_UI_INPUTS="$WORK/decl-missing" "$PF" --paths richos/app/ui/main.js 2>&1)"; E_RC=$?
if [ "$E_RC" -eq 2 ] && printf '%s' "$OUT" | grep -q "home.js' is a suite with NO row"; then
  ok "E4 a suite that landed with no row refuses — the stale case that under-answers"
else
  bad "E4 a suite that landed with no row refuses" "exit $E_RC"
fi

# The positive probe for E: unmutated, the same invocation must succeed. Four refusals that
# fire on everything would pass E1-E4 and mean nothing.
OUT="$("$PF" --paths richos/app/ui/main.js 2>&1)"; E0_RC=$?
[ "$E0_RC" -eq 0 ] \
  && ok "E5 (positive probe) the real declaration reconciles and answers" \
  || bad "E5 (positive probe) the real declaration reconciles" "exit $E0_RC: $OUT"

echo
echo "=== the declarations this script reads ==="

# -----------------------------------------------------------------------------------------
# F. Every script suite declares its inputs, and every declared path is in the tree. This
#    is the inventory check that keeps the script-suite half from drifting: a new suite
#    with no declaration is a suite `proof-for.sh` can never name.
# -----------------------------------------------------------------------------------------
N_SUITES=0; N_DECL=0; MISSING=""
for f in "$DIR"/*.test.sh; do
  [ -f "$f" ] || continue
  N_SUITES=$((N_SUITES + 1))
  d="$(sed -n 's/^# run-tests: inputs[[:space:]][[:space:]]*//p' "$f" | head -1)"
  if [ -z "$d" ]; then MISSING="$MISSING $(basename "$f")"; continue; fi
  N_DECL=$((N_DECL + 1))
  for p in $d; do
    [ -e "$ROOT/$p" ] || bad "F  $(basename "$f") declares '$p', which is not in the tree"
  done
done
if [ -z "$MISSING" ]; then
  ok "F1 all $N_SUITES script suites declare their inputs, and every declared path exists"
else
  bad "F1 every script suite declares its inputs" "no declaration:$MISSING"
fi

# -----------------------------------------------------------------------------------------
# G. It runs on the bash every Mac ships. `declare -A` is a syntax error in 3.2, and a
#    targeting script that only works on the author's shell targets nothing.
# -----------------------------------------------------------------------------------------
if /bin/bash -n "$PF" 2>/dev/null; then
  V="$(/bin/bash -c 'echo $BASH_VERSION')"
  ok "G1 parses under /bin/bash ($V)"
else
  bad "G1 parses under /bin/bash"
fi
if /bin/bash "$PF" --paths richos/app/ui/main.js >/dev/null 2>"$WORK/g.err"; then
  ok "G2 ...and runs under it with no shell errors"
else
  bad "G2 ...and runs under it" "$(head -3 "$WORK/g.err")"
fi
[ -s "$WORK/g.err" ] && bad "G3 nothing on stderr from a clean run" "$(head -3 "$WORK/g.err")" \
                     || ok "G3 nothing on stderr from a clean run"

echo
echo "=== the cargo targets it prints are real, per cargo itself ==="

# -----------------------------------------------------------------------------------------
# H. The Rust commands are ASSERTED AGAINST CARGO, not against the author's belief about
#    how cargo names a target. `--test <name>` is derived here from a file stem; if that
#    derivation were wrong every Rust line this script prints would be a command that
#    cannot run, and nothing else in this suite would notice.
# -----------------------------------------------------------------------------------------
CARGO=""
command -v cargo >/dev/null 2>&1 && CARGO=cargo
[ -z "$CARGO" ] && [ -x "$HOME/.cargo/bin/cargo" ] && CARGO="$HOME/.cargo/bin/cargo"
if [ -n "$CARGO" ]; then
  run_pf "$WORK/h.out" --paths richos/app/crates/richos-core/src/loro.rs
  sed -n 's/.*cargo test -p richos-core --test \([A-Za-z0-9_]*\).*/\1/p' "$WORK/h.out" \
    | LC_ALL=C sort -u > "$WORK/h.want"
  ( cd "$APP" && "$CARGO" metadata --no-deps --format-version 1 --offline 2>/dev/null ) \
    > "$WORK/meta.json"
  python3 - "$WORK/meta.json" "$WORK/h.want" > "$WORK/h.check" 2>&1 <<'PY'
import json, sys
meta = json.load(open(sys.argv[1]))
real = set()
for p in meta["packages"]:
    for t in p["targets"]:
        if "test" in t["kind"]:
            real.add(t["name"])
want = [l.strip() for l in open(sys.argv[2]) if l.strip()]
missing = [w for w in want if w not in real]
print("want=%d missing=%d" % (len(want), len(missing)))
if missing:
    print("MISSING: " + ", ".join(missing))
PY
  if [ -s "$WORK/h.want" ] && grep -q ' missing=0$' "$WORK/h.check"; then
    ok "H1 every --test target it printed is a real cargo target ($(head -1 "$WORK/h.check"))"
  else
    bad "H1 every --test target it printed is a real cargo target" "$(cat "$WORK/h.check")"
  fi

  ( cd "$APP/src-tauri" && "$CARGO" metadata --no-deps --format-version 1 --offline 2>/dev/null ) \
    | grep -q '"richos-tauri"' \
    && ok "H2 the shell's --bin name is the one cargo knows (detached nested workspace)" \
    || bad "H2 the shell's --bin name is the one cargo knows"
else
  notrun "H  the cargo target names" "no cargo on this machine or on PATH"
fi

# Execute exactly the generated engine command. Other selections are syntax
# checks only, so a selection containing this suite can never recurse.
run_pf "$WORK/engine.out" --paths richos/app/scripts/make-engine-asset.test.sh
if python3 - "$ROOT" "$WORK/engine.out" <<'PYTEST'
import os, signal, subprocess, sys
from pathlib import Path
lines = Path(sys.argv[2]).read_text().splitlines()
commands = [line.strip() for line in lines if line.startswith("  cd ")]
for command in commands:
    subprocess.run(["bash", "-n", "-c", command], check=True)
selected = [c for c in commands if c.endswith("&& bash scripts/make-engine-asset.test.sh")]
assert len(selected) == 1, selected
assert "RICHOS_RUNTIME_DIR" in "\n".join(lines)
command = selected[0]
assert "proof-for.test.sh" not in command
missing = dict(os.environ)
missing.pop("RICHOS_RUNTIME_DIR", None)
result = subprocess.run(["bash", "-c", command], cwd=sys.argv[1], env=missing,
                        capture_output=True, text=True, timeout=15)
assert result.returncode == 2 and "Prerequisite: set RICHOS_RUNTIME_DIR" in result.stderr
# This nested deadline owns a group too. Forward outer-gate cancellation into
# its finally block so the generated command cannot outlive the test runner.
def cancel(signum, frame):
    raise SystemExit(128 + signum)
signal.signal(signal.SIGTERM, cancel)
signal.signal(signal.SIGINT, cancel)
p = subprocess.Popen(["bash", "-c", command], cwd=sys.argv[1], start_new_session=True)
try:
    assert p.wait(timeout=600) == 0, "generated real-archive command failed"
finally:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    p.wait(timeout=5)
PYTEST
then
  ok "I1 generated engine command runs with its prerequisite and refuses without it; other commands parse"
else
  bad "I1 generated engine command and prerequisite contract"
fi

echo
TAIL=""
[ "$NOTRUN" -gt 0 ] && TAIL=", $NOTRUN NOT RUN"
if [ "$FAIL" -gt 0 ]; then
  echo "=== proof-for tests: $FAIL FAILED, $PASS passed$TAIL ==="
  exit 1
fi
echo "=== proof-for tests: all $PASS passed$TAIL ==="
exit 0
