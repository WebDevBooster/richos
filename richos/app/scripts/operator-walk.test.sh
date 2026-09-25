#!/usr/bin/env bash
# operator-walk.test.sh — the operator walk's back end and the operator mutation harness,
# proved without a VM, a model or a network.
#
#   scripts/operator-walk.test.sh
#
# The walk's back end (crates/richos-core/examples/operator_walk.rs) is what the W2 walk runs in
# the test VM in place of the app's window (operator back-end spec r3 §6 verification 5): it
# must answer the declaration gate exactly as the shell does, refuse to host his team without a
# valid declaration, and serve the report tool exactly as the app does. The mutation harness
# (scripts/operator-mutations.py) must still apply every mutant exactly once and name tests
# that exist; its full run needs cargo per mutant and is run by hand under reserve.py.
#
# run-tests: inputs richos/app/scripts/operator-walk.test.sh richos/app/crates/richos-core richos/app/scripts/operator-mutations.py
# run-tests: covers richos/app/crates/richos-core/examples/operator_walk.rs richos/app/scripts/operator-mutations.py
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$(cd "$HERE/.." && pwd)"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

if ! command -v cargo >/dev/null 2>&1; then
  echo "operator-walk.test.sh: no cargo on PATH; the walk's back end cannot be built." >&2
  exit 2
fi
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/operator-walk-test.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

if ! ( cd "$APP" && cargo build --quiet -p richos-core --example operator_walk ); then
  echo "operator-walk.test.sh: the example did not build" >&2
  exit 1
fi
WALK="${CARGO_TARGET_DIR:-$APP/target}/debug/examples/operator_walk"
[ -x "$WALK" ] || { echo "operator-walk.test.sh: no binary at $WALK" >&2; exit 1; }

# W1: no declaration is the product path, as the shell's gate says.
mkdir -p "$SCRATCH/none"
out="$("$WALK" gate "$SCRATCH/none")"
[ "$out" = '{"gate":"product"}' ] && ok "W1 no operator.json is the product path" || bad "W1 got: $out"

# W2: a present, broken declaration refuses, with his one sentence.
mkdir -p "$SCRATCH/broken"
printf '{ not json' > "$SCRATCH/broken/operator.json"
out="$("$WALK" gate "$SCRATCH/broken")"
case "$out" in
  *'"gate":"refused"'*'Your team is switched off on this Mac because '*'Rich can fix it.'*) ok "W2 a broken operator.json refuses with the sentence" ;;
  *) bad "W2 got: $out" ;;
esac

# W3: the walk will not host his team without a valid declaration, and says why.
err="$("$WALK" host "$SCRATCH/none" "$SCRATCH/state" "$SCRATCH/operator" 2>&1 >/dev/null </dev/null)"; code=$?
[ "$code" = 2 ] && [ "${err#*product path}" != "$err" ] && ok "W3 host refuses the product path (exit 2)" || bad "W3 exit $code: $err"
[ ! -e "$SCRATCH/operator" ] && ok "W3 a refusal writes nothing" || bad "W3 the refusal wrote $SCRATCH/operator"

# W4: the report tool is the app's own server: it speaks MCP and refuses without a scope.
reply="$(printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"report","arguments":{"kind":"update","text":"x"}}}' \
  | "$WALK" --operator-mcp "$SCRATCH/no-scope.json")"
case "$reply" in
  # serde_json writes keys in order, so the refusal's text comes before its isError flag.
  *'"serverInfo":{"name":"richos_operator"'*'report scope'*'"isError":true'*) ok "W4 the report server answers and refuses with no scope" ;;
  *) bad "W4 got: $reply" ;;
esac

# W5: every mutant of the mutation harness still applies, and names a test that exists.
if out="$(python3 "$APP/scripts/operator-mutations.py" --check 2>&1)"; then
  ok "W5 $out"
else
  bad "W5 $out"
fi

echo "operator-walk.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
