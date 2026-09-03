#!/usr/bin/env bash
#
# guard-sealed-worktree.test.sh — behavioral tests for the WRITE BARRIER,
# scripts/hooks/guard-sealed-worktree.sh.
#
# What is proven, each refusal beside its pass: the lead's own calls (no
# agent_id) are untouched; a sealed worker passes; an unsealed worker may use
# only the read-only allowlist and is REFUSED Bash, Agent, every editor and
# every unknown or MCP tool; the barrier waits for a late binding and passes
# once it seals; read-only agent types are exempt; a TERMINAL agent is refused
# everything; the guard fails CLOSED on an unsealed manifest AND on its own
# error alike (review 2026-09-03 blocker 3: python3 missing, the library
# missing, the root unresolvable, the payload unparseable, the resolver
# raising — every potentially writing or unknown worker tool is REFUSED, and
# only a proven lead call or a proven read-only tool passes).
#
# The mutation harness proving each assertion load-bearing is
# scripts/hooks/guard-sealed-worktree.mutation.sh, run at the end.
#
# Run directly: scripts/hooks/guard-sealed-worktree.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/guard-sealed-worktree.sh"
TX_PY="$SCRIPT_DIR/../lib/worktree-transactions.py"
RICHOS_ENTITY_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export RICHOS_ENTITY_ROOT
unset CLAUDE_PROJECT_DIR

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t guard-sealed-test.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -x "$HOOK" ] || { echo "FATAL: $HOOK missing/non-executable" >&2; exit 1; }

export RICHOS_WORKTREE_TX_DIR="$SANDBOX/tx"
export SEAL_WAIT_SECONDS=0
SID="deadbeef-0000-4000-8000-000000000000"
T() { python3 "$TX_PY" "$@"; }

ENTITY="$SANDBOX/entity"
mkdir -p "$ENTITY/.claude/worktrees"
git -C "$ENTITY" init -q -b main
printf 'seed\n' >"$ENTITY/seed.txt"; git -C "$ENTITY" add -A; git -C "$ENTITY" commit -q -m seed

seal_agent() { # <agent-id> <teammate>
    git -C "$ENTITY" worktree add -q -b "worktree-agent-$1" "$ENTITY/.claude/worktrees/agent-$1"
    printf '{"kind":"native","teammate":"%s","externals":[]}' "$2" | T intent --session-id "$SID" --tool-use-id "tu-$1" >/dev/null
    T bind --session-id "$SID" --tool-use-id "tu-$1" --agent-id "$1" >/dev/null
    T start --session-id "$SID" --agent-id "$1" --cwd "$ENTITY/.claude/worktrees/agent-$1" >/dev/null
    T seal --session-id "$SID" --agent-id "$1" >/dev/null
}

payload() { # <tool_name> <agent_id|""> [agent_type]
    python3 -c '
import json, sys
tool, aid, at = sys.argv[1:4]
d = {"session_id": "deadbeef-0000-4000-8000-000000000000", "hook_event_name": "PreToolUse", "tool_name": tool,
     "tool_input": {"file_path": "/tmp/x", "command": "ls"}, "tool_use_id": "toolu_x"}
if aid:
    d["agent_id"] = aid
    d["agent_type"] = at or "dev"
print(json.dumps(d))' "$1" "$2" "${3:-dev}"
}
run() { OUT="$(printf '%s' "$1" | "$HOOK" 2>&1)"; RC=$?; }

echo "=== guard-sealed-worktree tests ==="

# G01 the lead
run "$(payload Write "")"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "G01  the lead's own call (no agent_id) passes silently" || bad "G01  lead rc=$RC: $OUT"

# G02 a sealed worker
SEALED_AID="a00000000000sea1"
seal_agent "$SEALED_AID" dev-opus-g2
run "$(payload Write "$SEALED_AID")"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "G02  a SEALED worker's Write passes silently (the tool-specific guards decide next)" || bad "G02  sealed rc=$RC: $OUT"
run "$(payload Bash "$SEALED_AID")"
[ "$RC" -eq 0 ] && ok "G03  a SEALED worker's Bash passes" || bad "G03  sealed bash rc=$RC"

# G04.. an UNSEALED worker: only the read-only allowlist
UNSEALED_AID="a00000000000uns1"
for tool in Write Edit MultiEdit NotebookEdit Bash Agent SendMessage mcp__github__create_issue SomeUnknownTool; do
    run "$(payload "$tool" "$UNSEALED_AID")"
    if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'REFUSED (worktree manifest not sealed)'; then
        ok "G04  unsealed worker: $tool -> REFUSED (exit 2, 'not sealed')"
    else
        bad "G04  unsealed worker: $tool rc=$RC: ${OUT:0:120}"
    fi
done
for tool in Read Glob Grep LS WebFetch WebSearch ListAgents; do
    run "$(payload "$tool" "$UNSEALED_AID")"
    [ "$RC" -eq 0 ] && ok "G05  unsealed worker: $tool -> allowed (read-only allowlist)" || bad "G05  unsealed $tool rc=$RC: ${OUT:0:120}"
done
run "$(payload Write "$UNSEALED_AID")"
printf '%s' "$OUT" | grep -q 'neither the bound record nor the start record exists' \
    && ok "G06  the refusal names WHICH fact is missing" || bad "G06  refusal reason: ${OUT:0:200}"
printf '%s' "$OUT" | grep -q 'do not work around it' \
    && ok "G07  the refusal tells the worker to report and stop, not to route around" || bad "G07  refusal guidance missing"

# G08 half-sealed: bound but not started; started but not bound
HALF1="a00000000000hal1"
printf '{"kind":"native","teammate":"dev-opus-h1","externals":[]}' | T intent --session-id "$SID" --tool-use-id tu-h1 >/dev/null
T bind --session-id "$SID" --tool-use-id tu-h1 --agent-id "$HALF1" >/dev/null
run "$(payload Write "$HALF1")"
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'no start record' && ok "G08  bound but not started -> REFUSED, naming the missing start" || bad "G08  rc=$RC: ${OUT:0:160}"
HALF2="a00000000000hal2"
git -C "$ENTITY" worktree add -q -b "worktree-agent-$HALF2" "$ENTITY/.claude/worktrees/agent-$HALF2"
T start --session-id "$SID" --agent-id "$HALF2" --cwd "$ENTITY/.claude/worktrees/agent-$HALF2" >/dev/null
run "$(payload Write "$HALF2")"
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'no bound record' && ok "G09  started but not bound -> REFUSED, naming the missing binding" || bad "G09  rc=$RC: ${OUT:0:160}"

# G10 the barrier WAITS: the binding lands 1s after the call starts -> sealed -> pass
LATE="a00000000000lat1"
git -C "$ENTITY" worktree add -q -b "worktree-agent-$LATE" "$ENTITY/.claude/worktrees/agent-$LATE"
T start --session-id "$SID" --agent-id "$LATE" --cwd "$ENTITY/.claude/worktrees/agent-$LATE" >/dev/null
printf '{"kind":"native","teammate":"dev-opus-late","externals":[]}' | T intent --session-id "$SID" --tool-use-id tu-late >/dev/null
( sleep 1; T bind --session-id "$SID" --tool-use-id tu-late --agent-id "$LATE" >/dev/null ) &
T0="$(date +%s)"
OUT="$(printf '%s' "$(payload Write "$LATE")" | SEAL_WAIT_SECONDS=4 "$HOOK" 2>&1)"; RC=$?
wait
ELAPSED=$(( $(date +%s) - T0 ))
if [ "$RC" -eq 0 ] && [ "$ELAPSED" -ge 1 ] && [ "$ELAPSED" -le 4 ]; then
    ok "G10  a binding that lands during the wait seals the manifest and the write passes (${ELAPSED}s)"
else
    bad "G10  late binding rc=$RC elapsed=${ELAPSED}s: ${OUT:0:120}"
fi
# ...and the wait is bounded: with nothing coming, SEAL_WAIT_SECONDS=1 refuses in about a second
T0="$(date +%s)"
OUT="$(printf '%s' "$(payload Write "$UNSEALED_AID")" | SEAL_WAIT_SECONDS=1 "$HOOK" 2>&1)"; RC=$?
ELAPSED=$(( $(date +%s) - T0 ))
# The bound is what matters, not the exact second: under a loaded machine the
# guard's own python and git startups add seconds, so the ceiling is generous.
[ "$RC" -eq 2 ] && [ "$ELAPSED" -le 8 ] && ok "G11  the wait is bounded by SEAL_WAIT_SECONDS (refused after ${ELAPSED}s)" || bad "G11  bounded wait rc=$RC elapsed=$ELAPSED"

# G12 read-only agent types are exempt, plain and plugin-namespaced
run "$(payload Bash "a00000000000exp1" Explore)"
[ "$RC" -eq 0 ] && ok "G12  an Explore worker (read-only type) is exempt even for Bash" || bad "G12  Explore rc=$RC: ${OUT:0:120}"
run "$(payload Bash "a00000000000exp2" "richos-engine:Explore")"
[ "$RC" -eq 0 ] && ok "G13  ...and so is the plugin-namespaced form" || bad "G13  namespaced Explore rc=$RC"
run "$(payload Bash "a00000000000dev9" "richos-engine:dev")"
[ "$RC" -eq 2 ] && ok "G14  a namespaced FILE-CAPABLE type is not exempt (negative control for G13)" || bad "G14  namespaced dev rc=$RC"

# G15 a TERMINAL agent is refused everything, sealed or not, read-only or not
TERM_AID="a00000000000ter1"
seal_agent "$TERM_AID" dev-opus-term
T claim --session-id "$SID" --agent-id "$TERM_AID" --ingress SubagentStop >/dev/null
run "$(payload Write "$TERM_AID")"
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'REFUSED (terminal agent)' && ok "G15  a TERMINAL agent's Write is refused as terminal" || bad "G15  terminal write rc=$RC: ${OUT:0:120}"
run "$(payload Read "$TERM_AID")"
[ "$RC" -eq 2 ] && ok "G16  a TERMINAL agent's Read is refused too (nothing to read from; forbidden to return)" || bad "G16  terminal read rc=$RC"

# G17 FAIL CLOSED on the guard's own error (review 2026-09-03, blocker 3).
# Until this revision G17, G18 and G21 asserted the OPPOSITE — that a missing
# python3, a missing transaction library and an unparseable payload each let
# a worker's Write through. Those assertions were the defect written as
# tests, and they are inverted here:
#   old G17: python3 missing -> rc 0 + fail-open NOTICE      new: rc 2, REFUSED
#   old G18: library missing -> rc 0 + NOTICE                new: rc 2, REFUSED
#   old G21: unparseable payload -> rc 0 (read as the lead)  new: rc 2, REFUSED
# What still passes when the guard cannot evaluate: a payload PROVEN to be the
# lead's, and a tool PROVEN read-only, under the read-only policy.
FAKEBIN="$(mktemp -d -t sealed-nopy.XXXXXX)"
for t in cat grep sed cut tr date mkdir git mktemp basename dirname rm ln awk sort uniq wc head tail env sleep; do
    p="$(command -v "$t" 2>/dev/null || true)"; [ -n "$p" ] && ln -sf "$p" "$FAKEBIN/$t"
done
OUT="$(printf '%s' "$(payload Write "$UNSEALED_AID")" | PATH="$FAKEBIN" "$(command -v bash)" "$HOOK" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'REFUSED (the barrier cannot evaluate this call)' && printf '%s' "$OUT" | grep -q 'python3 is unavailable'; then
    ok "G17  python3 missing -> a worker's Write is REFUSED (exit 2) naming python3 (INVERTED: it used to pass)"
else
    bad "G17  nopy rc=$RC: ${OUT:0:200}"
fi
OUT="$(printf '%s' "$(payload Write "")" | PATH="$FAKEBIN" "$(command -v bash)" "$HOOK" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "G17b python3 missing -> a payload with NO agent_id (proven the lead's) still passes" || bad "G17b lead nopy rc=$RC: ${OUT:0:160}"
OUT="$(printf '%s' "$(payload Read "$UNSEALED_AID")" | PATH="$FAKEBIN" "$(command -v bash)" "$HOOK" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'read-only policy' && ok "G17c python3 missing -> a worker's Read passes under the read-only policy (announced)" || bad "G17c read nopy rc=$RC: ${OUT:0:160}"
OUT="$(printf '{"session_id":"x","agent_id":"a00000000000uns1","tool_name":"Bash","tool_input":{"command":"echo \\"agent_id\\""}}' | PATH="$FAKEBIN" "$(command -v bash)" "$HOOK" 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok "G17d python3 missing -> a worker's Bash is REFUSED even though the only readable tell is the raw key" || bad "G17d bash nopy rc=$RC"
rm -rf "$FAKEBIN"
# ...library missing -> REFUSED, naming it; Read still passes
NOLIB="$(mktemp -d -t sealed-nolib.XXXXXX)"
mkdir -p "$NOLIB/scripts/hooks" "$NOLIB/scripts/lib"
cp "$HOOK" "$NOLIB/scripts/hooks/"; cp "$SCRIPT_DIR/../lib/resolve-roots.sh" "$SCRIPT_DIR/../lib/resolve-main-checkout.sh" "$NOLIB/scripts/lib/"
OUT="$(printf '%s' "$(payload Write "$UNSEALED_AID")" | "$NOLIB/scripts/hooks/guard-sealed-worktree.sh" 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'worktree-transactions.py is missing' && printf '%s' "$OUT" | grep -q 'cannot evaluate' \
    && ok "G18  transaction library missing -> a worker's Write is REFUSED (exit 2) naming the library (INVERTED: it used to pass)" || bad "G18  nolib rc=$RC: ${OUT:0:200}"
OUT="$(printf '%s' "$(payload Grep "$UNSEALED_AID")" | "$NOLIB/scripts/hooks/guard-sealed-worktree.sh" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "G18b transaction library missing -> a worker's Grep passes under the read-only policy" || bad "G18b nolib grep rc=$RC: ${OUT:0:160}"
OUT="$(printf '%s' "$(payload Write "")" | "$NOLIB/scripts/hooks/guard-sealed-worktree.sh" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "G18c transaction library missing -> the lead's own Write passes" || bad "G18c nolib lead rc=$RC: ${OUT:0:160}"
# ...resolve-roots.sh missing -> REFUSED
rm "$NOLIB/scripts/lib/resolve-roots.sh"
OUT="$(printf '%s' "$(payload Write "$UNSEALED_AID")" | "$NOLIB/scripts/hooks/guard-sealed-worktree.sh" 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'resolve-roots.sh is missing' && ok "G18d resolve-roots.sh missing -> a worker's Write is REFUSED (exit 2)" || bad "G18d noroots rc=$RC: ${OUT:0:200}"
rm -rf "$NOLIB"
# ...and the two failure classes are different refusals: the unsealed refusal says so
run "$(payload Write "$UNSEALED_AID")"
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'REFUSED (worktree manifest not sealed)' && ok "G19  ...while an UNSEALED manifest with the guard healthy is REFUSED for THAT reason — a different banner, the same exit" || bad "G19  rc=$RC"

# G20 not-adopted repository: stand down (a RESOLVED state, not a failure)
NOADOPT="$(mktemp -d -t sealed-noadopt.XXXXXX)"
OUT="$(cd "$NOADOPT" && printf '%s' "$(payload Write "$UNSEALED_AID")" | RICHOS_ENTITY_ROOT="" CLAUDE_PROJECT_DIR="$NOADOPT" "$HOOK" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "G20  a repository that never adopted the engine: the barrier stands down" || bad "G20  noadopt rc=$RC: ${OUT:0:120}"
rm -rf "$NOADOPT"

# G21 an UNPARSEABLE payload is NOT the lead (INVERTED: it used to pass)
OUT="$(printf 'not json' | "$HOOK" 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'unparseable' && ok "G21  an unparseable payload -> REFUSED (exit 2): a payload that cannot be proven the lead's is treated as a worker's" || bad "G21  rc=$RC: ${OUT:0:160}"
OUT="$(printf '{"tool_name": "Read", "broken' | "$HOOK" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "G21b ...unless the raw text names a read-only tool, which passes under the read-only policy" || bad "G21b rc=$RC: ${OUT:0:120}"

# G24 root resolution BROKEN (an explicit RICHOS_ENTITY_ROOT that is not adopted) -> REFUSED
BROKENROOT="$(mktemp -d -t sealed-brokenroot.XXXXXX)"
OUT="$(printf '%s' "$(payload Write "$UNSEALED_AID")" | RICHOS_ENTITY_ROOT="$BROKENROOT" "$HOOK" 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'governed root could not be resolved' && ok "G24  a broken root resolution -> a worker's Write is REFUSED (exit 2)" || bad "G24  brokenroot rc=$RC: ${OUT:0:200}"
OUT="$(printf '%s' "$(payload Read "$UNSEALED_AID")" | RICHOS_ENTITY_ROOT="$BROKENROOT" "$HOOK" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "G24b ...and a worker's Read still passes under the read-only policy" || bad "G24b brokenroot read rc=$RC"
rm -rf "$BROKENROOT"

# G25 the resolver RAISES (the transaction store is a file, not a directory) -> REFUSED
NOTADIR="$(mktemp -t sealed-notadir.XXXXXX)"
OUT="$(printf '%s' "$(payload Write "$UNSEALED_AID")" | RICHOS_WORKTREE_TX_DIR="$NOTADIR" "$HOOK" 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'cannot evaluate' && ok "G25  transaction state unreadable (the resolver raised) -> a worker's Write is REFUSED (exit 2)" || bad "G25  notadir rc=$RC: ${OUT:0:200}"
OUT="$(printf '%s' "$(payload Glob "$UNSEALED_AID")" | RICHOS_WORKTREE_TX_DIR="$NOTADIR" "$HOOK" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "G25b ...and a worker's Glob still passes under the read-only policy" || bad "G25b notadir glob rc=$RC"
rm -f "$NOTADIR"

# G22 a crash after the transaction's terminal write but BEFORE the index
# write (blocker 5): the barrier must read terminal from the transaction.
CRASH_AID="a00000000000cra1"
seal_agent "$CRASH_AID" dev-opus-crash
RICHOS_TX_CRASH_AFTER=tx T claim --session-id "$SID" --agent-id "$CRASH_AID" --ingress SubagentStop >/dev/null 2>&1
[ ! -f "$SANDBOX/tx/terminal/$CRASH_AID" ] || bad "G22-setup  the crash point did not fire (index present)"
run "$(payload Write "$CRASH_AID")"
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'REFUSED (terminal agent)' \
    && ok "G22  a terminal transaction whose index write never happened is still REFUSED as terminal (the transaction is the truth)" || bad "G22  crash-orphaned terminal rc=$RC: ${OUT:0:160}"
[ -f "$SANDBOX/tx/terminal/$CRASH_AID" ] && ok "G23  ...and the barrier's exact lookup repaired the index on its way out" || bad "G23  index not repaired"


echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== guard-sealed-worktree tests: $FAIL FAILED, $PASS passed ==="
    exit 1
fi
echo "=== guard-sealed-worktree tests: all $PASS passed ==="

if [ -f "$SCRIPT_DIR/guard-sealed-worktree.mutation.sh" ]; then
    bash "$SCRIPT_DIR/guard-sealed-worktree.mutation.sh" || exit 1
fi
exit 0
