#!/usr/bin/env bash
#
# shell-worktree-sparse.test.sh — behavioral tests for
# scripts/lib/shell-worktree-sparse.py and its one integration point,
# worktree-transactions.try_seal.
#
# WHAT IS PROVEN HERE. The five properties the CEO named when he chose this
# option, each of them a case rather than a claim:
#
#   1. the shell stays a REGISTERED, NON-PRUNABLE git worktree, and an
#      operation that cannot keep that promise is rolled back    S01 S06 S10
#   2. the lifecycle is untouched: the seal, the member states, the ingress,
#      the quarantine and the removal all behave as before        S01 S03 S08
#   3. the native-disappearance backstop still watches it         S06
#   4. sparse is NOT a data-loss path: untracked, ignored and modified bytes
#      are never removed, and a shell that has been written to is left at
#      full size                                                  S04 S07 S11
#      (the end-to-end positive probe — write into a sparsified shell, run
#      the reconciler, read the bytes back out of the archive — is C60-C62 in
#      reconcile-terminal-worktrees.test.sh, where the archive is)
#   5. everything reverses with one command                       S11
#
# And the two facts that make the design work at all: a plain `native`
# worker's worktree IS its workspace and is never touched (S02), and the
# escalation path — write BLOCKED.md at the root, add it, commit it — still
# works inside a sparsified shell (S12).
#
# The mutation harness proving each assertion load-bearing is
# scripts/lib/shell-worktree-sparse.mutation.sh, run at the end of this suite
# so the runner that discovers this file runs it too.
#
# Run directly: scripts/lib/shell-worktree-sparse.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SP_PY="$SCRIPT_DIR/shell-worktree-sparse.py"
TX_PY="$SCRIPT_DIR/worktree-transactions.py"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t shell-sparse-test.XXXXXX)" && pwd -P)"
trap 'chmod -R u+rwX "$SANDBOX" 2>/dev/null; rm -rf "$SANDBOX"' EXIT
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -f "$SP_PY" ] || { echo "FATAL: missing $SP_PY" >&2; exit 1; }
[ -f "$TX_PY" ] || { echo "FATAL: missing $TX_PY" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

export RICHOS_WORKTREE_TX_DIR="$SANDBOX/tx"
T() { python3 "$TX_PY" "$@"; }
S() { python3 "$SP_PY" "$@"; }
# sp <code> — run a snippet with the sparsifier loaded as `sp`.
sp() {
    SPPY="$SP_PY" python3 -c "
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location('sp', os.environ['SPPY']); sp = importlib.util.module_from_spec(spec); spec.loader.exec_module(sp)
$1
"
}
# txpy <code> — run a snippet with the transaction module loaded as `tx`.
txpy() {
    TXPY="$TX_PY" python3 -c "
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location('tx', os.environ['TXPY']); tx = importlib.util.module_from_spec(spec); spec.loader.exec_module(tx)
$1
"
}
# member_sparse <sid> <aid> <index> <key> — one field of the recorded block.
member_sparse() {
    python3 - "$RICHOS_WORKTREE_TX_DIR/$1/$2.json" "$3" "$4" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
m = d["members"][int(sys.argv[2])]
v = (m.get("sparse") or {}).get(sys.argv[3], "")
print(json.dumps(v) if isinstance(v, (dict, list)) else v)
PY
}
kb() { du -sk "$1" | cut -f1; }
tracked_files() { find "$1" -type f -not -path '*/.git/*' -not -name '.git' | sed "s|^$1/||" | sort | tr '\n' ' '; }

# --- the fixture: a repository shaped like the one that produced the 266 MB --
seed_entity() { # <path>
    mkdir -p "$1"
    git -C "$1" init -q -b main
    mkdir -p "$1/qa-audits/run" "$1/docs/deep" "$1/.claude/agents" "$1/.githooks"
    # qa-audits was 202 MB of the measured 266 MB; here it is 400 KB of the
    # same shape — many files under one top-level directory.
    for i in 1 2 3 4 5 6 7 8; do head -c 51200 /dev/urandom | base64 >"$1/qa-audits/run/shot-$i.b64"; done
    printf 'a\n' >"$1/docs/a.md"; printf 'b\n' >"$1/docs/deep/b.md"
    printf 'definition\n' >"$1/.claude/agents/zach.md"
    printf '#!/bin/sh\nexit 0\n' >"$1/.githooks/pre-commit"; chmod +x "$1/.githooks/pre-commit"
    printf 'root\n' >"$1/CLAUDE.md"; printf 'readme\n' >"$1/README.md"
    printf '*.env\n' >"$1/.gitignore"
    git -C "$1" add -A
    git -C "$1" commit -q -m seed
    mkdir -p "$1/.claude/worktrees"
}
seed_other() { mkdir -p "$1"; git -C "$1" init -q -b main; printf 'seed\n' >"$1/seed.txt"; git -C "$1" add -A; git -C "$1" commit -q -m seed; }

ENTITY="$SANDBOX/entity"; seed_entity "$ENTITY"
OTHER="$SANDBOX/other";   seed_other "$OTHER"
SID="5eeeeeee-0000-4000-8000-000000000001"

# seal_pair <aid> <kind: native|native+external> — create the worktrees the
# spawn would have created (unless the case already made the native one) and
# drive intent -> bind -> start -> seal.
seal_pair() {
    local aid="$1" kind="$2" ext="[]"
    [ -d "$ENTITY/.claude/worktrees/agent-$aid" ] \
        || git -C "$ENTITY" worktree add -q -b "worktree-agent-$aid" "$ENTITY/.claude/worktrees/agent-$aid"
    if [ "$kind" = "native+external" ]; then
        local path="$SANDBOX/other-wt/$aid"
        git -C "$OTHER" worktree add -q -b "b-$aid" "$path"
        ext="[{\"repo\":\"$OTHER\",\"path\":\"$path\",\"branch\":\"b-$aid\"}]"
    fi
    printf '{"kind":"%s","teammate":"t-%s","externals":%s}' "$kind" "$aid" "$ext" \
        | T intent --session-id "$SID" --tool-use-id "tu-$aid" >/dev/null
    T bind --session-id "$SID" --tool-use-id "tu-$aid" --agent-id "$aid" >/dev/null
    T start --session-id "$SID" --agent-id "$aid" --cwd "$ENTITY/.claude/worktrees/agent-$aid" >/dev/null
    T seal --session-id "$SID" --agent-id "$aid" >/dev/null
}

echo "=== shell-worktree-sparse tests ==="

# --- S01: the seal de-materializes the shell -----------------------------------
A1="a00000000000sp01"
N1="$ENTITY/.claude/worktrees/agent-$A1"
git -C "$ENTITY" worktree add -q -b "worktree-agent-$A1" "$N1"
BEFORE_KB="$(kb "$N1")"
seal_pair "$A1" "native+external"
AFTER_KB="$(kb "$N1")"
APPLIED="$(member_sparse "$SID" "$A1" 0 applied)"
if [ "$APPLIED" = "True" ] && [ "$AFTER_KB" -lt "$BEFORE_KB" ] && [ ! -e "$N1/qa-audits" ] && [ ! -e "$N1/docs" ] \
   && [ -f "$N1/CLAUDE.md" ] && [ -f "$N1/README.md" ] && [ -f "$N1/.gitignore" ]; then
    ok "S01  sealing a native+external spawn de-materializes the shell (${BEFORE_KB}K -> ${AFTER_KB}K) and keeps every top-level file"
else
    bad "S01  applied=$APPLIED before=${BEFORE_KB}K after=${AFTER_KB}K left: $(tracked_files "$N1")"
fi
KEEP="$(member_sparse "$SID" "$A1" 0 keep)"
if [ -f "$N1/.claude/agents/zach.md" ] && [ -f "$N1/.githooks/pre-commit" ]; then
    ok "S01b the configured keep-set stays materialized (keep=$KEEP)"
else
    bad "S01b keep=$KEEP left: $(tracked_files "$N1")"
fi
FREED="$(member_sparse "$SID" "$A1" 0 bytes_freed)"
BB="$(member_sparse "$SID" "$A1" 0 bytes_before)"
BA="$(member_sparse "$SID" "$A1" 0 bytes_after)"
if [ -n "$FREED" ] && [ "$FREED" -gt 0 ] && [ "$BB" -gt "$BA" ]; then
    ok "S01c the member records the measurement, not the command: bytes_before=$BB bytes_after=$BA bytes_freed=$FREED"
else
    bad "S01c before=$BB after=$BA freed=$FREED"
fi

# --- S02: a plain native worker's worktree IS its workspace --------------------
A2="a00000000000sp02"
N2="$ENTITY/.claude/worktrees/agent-$A2"
seal_pair "$A2" "native"
SPARSE2="$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print('present' if d['members'][0].get('sparse') is not None else 'absent')
" "$RICHOS_WORKTREE_TX_DIR/$SID/$A2.json")"
if [ -d "$N2/qa-audits" ] && [ -d "$N2/docs" ] && [ "$SPARSE2" = "absent" ] \
   && [ "$(git -C "$N2" config --get core.sparseCheckout)" = "" ]; then
    ok "S02  a plain native spawn is never touched and never even considered — its worktree IS its workspace"
else
    bad "S02  sparse-block=$SPARSE2 files: $(tracked_files "$N2")"
fi

# --- S03: the external member — the real workspace — is untouched --------------
E1="$SANDBOX/other-wt/$A1"
if [ -f "$E1/seed.txt" ] && [ "$(git -C "$E1" config --get core.sparseCheckout)" = "" ]; then
    ok "S03  the external member (the tree the teammate actually edits) is not sparsified"
else
    bad "S03  external: $(tracked_files "$E1") sparse=$(git -C "$E1" config --get core.sparseCheckout)"
fi

# --- S04: a shell that has been written to is left at FULL size ----------------
A4="a00000000000sp04"
N4="$ENTITY/.claude/worktrees/agent-$A4"
git -C "$ENTITY" worktree add -q -b "worktree-agent-$A4" "$N4"
printf 'work in progress\n' >"$N4/NOTES.md"          # untracked evidence
printf 'edited\n' >>"$N4/docs/a.md"                  # a modified tracked file
seal_pair "$A4" "native+external"
REASON4="$(member_sparse "$SID" "$A4" 0 reason)"
if [ "$(member_sparse "$SID" "$A4" 0 applied)" = "False" ] && [ -d "$N4/qa-audits" ] \
   && [ "$(cat "$N4/NOTES.md")" = "work in progress" ] && grep -q edited "$N4/docs/a.md" \
   && printf '%s' "$REASON4" | grep -q "written to"; then
    ok "S04  a shell with uncommitted work is left at full size, its bytes intact, with the reason recorded: $REASON4"
else
    bad "S04  applied=$(member_sparse "$SID" "$A4" 0 applied) reason=$REASON4 files=$(tracked_files "$N4")"
fi

# --- S05: the main checkout and the shared config are untouched ----------------
MAIN_OK=1
[ -d "$ENTITY/qa-audits" ] && [ -f "$ENTITY/docs/deep/b.md" ] || MAIN_OK=0
[ -z "$(git -C "$ENTITY" status --porcelain -- qa-audits docs)" ] || MAIN_OK=0
grep -q "sparseCheckout" "$ENTITY/.git/config" && MAIN_OK=0
if [ "$MAIN_OK" = "1" ] && grep -q "sparseCheckout" "$ENTITY/.git/worktrees/agent-$A1/config.worktree"; then
    ok "S05  core.sparseCheckout is written to the SHELL's own config.worktree; the main checkout keeps every file"
else
    bad "S05  main_ok=$MAIN_OK shared config: $(grep -c sparse "$ENTITY/.git/config") worktree config: $(cat "$ENTITY/.git/worktrees/agent-$A1/config.worktree" 2>/dev/null | tr '\n' ' ')"
fi

# --- S06: the native-disappearance backstop still watches it -------------------
GONE="$(txpy "
import json
m = json.load(open(os.path.join(os.environ.get('RICHOS_WORKTREE_TX_DIR',''), '$SID', '$A1.json')))['members'][0]
print(tx.native_member_gone(m)[0])
")"
REG="$(git -C "$ENTITY" worktree list --porcelain | grep -c "^worktree .*/agent-$A1$")"
PRUNABLE="$(git -C "$ENTITY" worktree list --porcelain | grep -A3 "^worktree .*/agent-$A1$" | grep -c prunable)"
if [ "$GONE" = "False" ] && [ "$REG" = "1" ] && [ "$PRUNABLE" = "0" ]; then
    ok "S06  the sparsified shell is still registered, still non-prunable, and native_member_gone is still False"
else
    bad "S06  gone=$GONE registered=$REG prunable=$PRUNABLE"
fi
mv "$N1" "$N1.moved"
GONE2="$(txpy "
import json
m = json.load(open(os.path.join(os.environ.get('RICHOS_WORKTREE_TX_DIR',''), '$SID', '$A1.json')))['members'][0]
print(tx.native_member_gone(m)[0])
")"
mv "$N1.moved" "$N1"
[ "$GONE2" = "True" ] && ok "S06b the backstop still FIRES when the sparsified shell disappears (the signal is not muted)" \
                      || bad "S06b gone-after-move=$GONE2"

# --- S07: an ignored, .worktreeinclude-style file survives ---------------------
A7="a00000000000sp07"
N7="$ENTITY/.claude/worktrees/agent-$A7"
git -C "$ENTITY" worktree add -q -b "worktree-agent-$A7" "$N7"
printf 'CONVEX_ADMIN_KEY=xxx\n' >"$N7/local.env"     # gitignored, exactly like the seeded ones
RES7="$(S sparsify --path "$N7" --repo "$ENTITY")"
if printf '%s' "$RES7" | grep -q '"applied": true' && [ "$(cat "$N7/local.env")" = "CONVEX_ADMIN_KEY=xxx" ] && [ ! -e "$N7/qa-audits" ]; then
    ok "S07  a gitignored file seeded into the shell survives sparsification byte-for-byte"
else
    bad "S07  $(printf '%s' "$RES7" | tr '\n' ' ' | cut -c1-200) local.env=$(cat "$N7/local.env" 2>/dev/null)"
fi

# --- S08: idempotent ------------------------------------------------------------
RES8="$(S sparsify --path "$N7" --repo "$ENTITY")"
SEAL8="$(T seal --session-id "$SID" --agent-id "$A1" 2>&1)"
KB8="$(kb "$N1")"
if printf '%s' "$RES8" | grep -q '"reason": "already sparse"' && [ -f "$N1/CLAUDE.md" ]; then
    ok "S08  a second run is a recorded no-op ('already sparse'), and re-sealing an already-sealed transaction changes nothing"
else
    bad "S08  $(printf '%s' "$RES8" | tr '\n' ' ' | cut -c1-200) reseal=$SEAL8"
fi

# --- S09: refusals that protect the wrong target ------------------------------
RES9A="$(S sparsify --path "$ENTITY" --repo "$ENTITY")"
mkdir -p "$SANDBOX/notaworktree"
RES9B="$(S sparsify --path "$SANDBOX/notaworktree" --repo "$ENTITY" 2>&1)"
if printf '%s' "$RES9A" | grep -q "main checkout, not a linked worktree" \
   && printf '%s' "$RES9B" | grep -qE "not the top level|cannot read" \
   && [ -d "$ENTITY/qa-audits" ]; then
    ok "S09  the main checkout and a non-worktree directory are both refused — only a registered linked worktree is ever touched"
else
    bad "S09  main=$(printf '%s' "$RES9A" | tr '\n' ' ' | cut -c1-160) other=$(printf '%s' "$RES9B" | tr '\n' ' ' | cut -c1-160)"
fi

# --- S10: a git failure is rolled back ----------------------------------------
A10="a00000000000sp10"
N10="$ENTITY/.claude/worktrees/agent-$A10"
git -C "$ENTITY" worktree add -q -b "worktree-agent-$A10" "$N10"
BEFORE10="$(tracked_files "$N10")"
mkdir -p "$ENTITY/.git/worktrees/agent-$A10/info"
chmod 500 "$ENTITY/.git/worktrees/agent-$A10/info"
RES10="$(S sparsify --path "$N10" --repo "$ENTITY" 2>&1)"
chmod 700 "$ENTITY/.git/worktrees/agent-$A10/info" 2>/dev/null
AFTER10="$(tracked_files "$N10")"
if printf '%s' "$RES10" | grep -q '"applied": false' && [ "$BEFORE10" = "$AFTER10" ] && [ -z "$(git -C "$N10" status --porcelain)" ]; then
    ok "S10  a git failure leaves the shell whole — every file back, status clean, nothing half-done"
else
    bad "S10  $(printf '%s' "$RES10" | tr '\n' ' ' | cut -c1-200) before=[$BEFORE10] after=[$AFTER10]"
fi

# --- S11: one command reverses it, exactly -------------------------------------
A11="a00000000000sp11"
N11="$ENTITY/.claude/worktrees/agent-$A11"
git -C "$ENTITY" worktree add -q -b "worktree-agent-$A11" "$N11"
SUM_BEFORE="$(cd "$N11" && find . -type f -not -path './.git*' -exec shasum {} + | sort | shasum | cut -d' ' -f1)"
S sparsify --path "$N11" --repo "$ENTITY" >/dev/null
SPARSE_KB="$(kb "$N11")"
S restore --path "$N11" --repo "$ENTITY" >/dev/null
SUM_AFTER="$(cd "$N11" && find . -type f -not -path './.git*' -exec shasum {} + | sort | shasum | cut -d' ' -f1)"
if [ "$SUM_BEFORE" = "$SUM_AFTER" ] && [ -z "$(git -C "$N11" status --porcelain)" ]; then
    ok "S11  restore brings back every file byte-for-byte (sparsified to ${SPARSE_KB}K and back, digest unchanged)"
else
    bad "S11  before=$SUM_BEFORE after=$SUM_AFTER status=[$(git -C "$N11" status --porcelain | tr '\n' ';')]"
fi

# --- S12: the escalation path still works inside a sparsified shell ------------
A12="a00000000000sp12"
N12="$ENTITY/.claude/worktrees/agent-$A12"
git -C "$ENTITY" worktree add -q -b "worktree-agent-$A12" "$N12"
S sparsify --path "$N12" --repo "$ENTITY" >/dev/null
printf 'blocked on X\n' >"$N12/BLOCKED.md"
ADD_RC=0; git -C "$N12" add BLOCKED.md || ADD_RC=$?
COMMIT_RC=0; git -C "$N12" commit -q -m "escalation" || COMMIT_RC=$?
if [ "$ADD_RC" = "0" ] && [ "$COMMIT_RC" = "0" ] && git -C "$N12" show --name-only --format= HEAD | grep -q BLOCKED.md; then
    ok "S12  a root BLOCKED.md can still be written, added and committed in a sparsified shell (the escalation path survives)"
else
    bad "S12  add_rc=$ADD_RC commit_rc=$COMMIT_RC $(git -C "$N12" log --oneline -1)"
fi

# --- S13: the policy switch is data, and off means off ------------------------
A13="a00000000000sp13"
N13="$ENTITY/.claude/worktrees/agent-$A13"
git -C "$ENTITY" worktree add -q -b "worktree-agent-$A13" "$N13"
RES13="$(RICHOS_SHELL_SPARSE=off S sparsify --path "$N13" --repo "$ENTITY")"
if printf '%s' "$RES13" | grep -q '"reason": "SHELL_SPARSE is off"' && [ -d "$N13/qa-audits" ]; then
    ok "S13  SHELL_SPARSE=off restores the previous behavior exactly — nothing is touched"
else
    bad "S13  $(printf '%s' "$RES13" | tr '\n' ' ' | cut -c1-200)"
fi

# --- S14: a repository's own hooks are never stranded -------------------------
A14="a00000000000sp14"
N14="$ENTITY/.claude/worktrees/agent-$A14"
git -C "$ENTITY" worktree add -q -b "worktree-agent-$A14" "$N14"
git -C "$N14" config core.hooksPath .githooks
RES14="$(RICHOS_SHELL_SPARSE_KEEP=".claude" S sparsify --path "$N14" --repo "$ENTITY")"
if [ -f "$N14/.githooks/pre-commit" ] && printf '%s' "$RES14" | grep -q '"applied": true'; then
    ok "S14  the directory core.hooksPath resolves to is kept materialized even when config does not name it"
else
    bad "S14  hooks: $(ls "$N14/.githooks" 2>/dev/null | tr '\n' ' ') $(printf '%s' "$RES14" | tr '\n' ' ' | cut -c1-200)"
fi

# --- S15: the extensions.worktreeConfig hazard --------------------------------
HAZ="$SANDBOX/haz"; seed_entity "$HAZ"
NH="$HAZ/.claude/worktrees/agent-hazard0001"
git -C "$HAZ" worktree add -q -b worktree-agent-hazard0001 "$NH"
printf '\n[core]\n\tbare = true\n' >>"$HAZ/.git/config"
RES15="$(S sparsify --path "$NH" --repo "$HAZ" 2>&1)"
python3 - "$HAZ/.git/config" <<'PY'
import re, sys
p = sys.argv[1]
src = open(p).read().replace("\n[core]\n\tbare = true\n", "\n")
open(p, "w").write(src)
PY
if printf '%s' "$RES15" | grep -q "worktreeConfig is off" && [ -d "$NH/qa-audits" ]; then
    ok "S15  a repository where enabling extensions.worktreeConfig would change how the MAIN checkout reads its config is refused"
else
    bad "S15  $(printf '%s' "$RES15" | tr '\n' ' ' | cut -c1-200)"
fi

# --- S16: an initialized submodule is left alone ------------------------------
SUBREPO="$SANDBOX/subsrc"; seed_other "$SUBREPO"
git -C "$ENTITY" -c protocol.file.allow=always submodule add -q "$SUBREPO" sub >/dev/null 2>&1
git -C "$ENTITY" commit -q -m "add submodule" >/dev/null 2>&1
A16="a00000000000sp16"
N16="$ENTITY/.claude/worktrees/agent-$A16"
git -C "$ENTITY" worktree add -q -b "worktree-agent-$A16" "$N16"
git -C "$N16" -c protocol.file.allow=always submodule update --init >/dev/null 2>&1
RES16="$(S sparsify --path "$N16" --repo "$ENTITY" 2>&1)"
if printf '%s' "$RES16" | grep -q "initialized submodule" && [ -d "$N16/qa-audits" ]; then
    ok "S16  a shell with an initialized submodule is refused — its working tree is not reconstructible from this object store"
else
    bad "S16  $(printf '%s' "$RES16" | tr '\n' ' ' | cut -c1-200)"
fi

# --- S17: a shell the platform is already tearing down is never raced --------
# The terminal event arrived BEFORE the manifest could seal. try_seal consumes
# it, the transaction is terminal on arrival, and the member is already
# quarantined. Sparsifying then would be a working-tree rewrite racing the
# capture that is about to read those bytes.
A17="a00000000000sp17"
N17="$ENTITY/.claude/worktrees/agent-$A17"
git -C "$ENTITY" worktree add -q -b "worktree-agent-$A17" "$N17"
git -C "$OTHER" worktree add -q -b "b-$A17" "$SANDBOX/other-wt/$A17"
printf '{"kind":"native+external","teammate":"t-%s","externals":[{"repo":"%s","path":"%s","branch":"b-%s"}]}' \
    "$A17" "$OTHER" "$SANDBOX/other-wt/$A17" "$A17" | T intent --session-id "$SID" --tool-use-id "tu-$A17" >/dev/null
T bind --session-id "$SID" --tool-use-id "tu-$A17" --agent-id "$A17" >/dev/null
T start --session-id "$SID" --agent-id "$A17" --cwd "$N17" >/dev/null
T claim --session-id "$SID" --agent-id "$A17" --ingress SubagentStop >/dev/null 2>&1
T seal --session-id "$SID" --agent-id "$A17" >/dev/null
Q17="$N17.richos-terminal-${SID:0:8}-$A17"
SPARSE17="$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print('present' if d['members'][0].get('sparse') is not None else 'absent', d.get('terminal') is not None)
" "$RICHOS_WORKTREE_TX_DIR/$SID/$A17.json")"
if [ "$SPARSE17" = "absent True" ] && [ -d "$Q17/qa-audits" ]; then
    ok "S17  a transaction that is terminal on arrival is never sparsified — the quarantine keeps every byte for the capture"
else
    bad "S17  state=$SPARSE17 quarantine=$(ls "$Q17" 2>/dev/null | tr '\n' ' ')"
fi

# --- S18: the saving is counted, and so is every refusal ----------------------
# A number that only ever went up would report the policy as always applying.
# S01 applied and S04 refused, so both counters must be non-zero here.
M18="$(T metrics)"
V18="$(printf '%s' "$M18" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d['shells_sparsified'] >= 1, d['shells_sparse_refused'] >= 1, d['shell_bytes_freed'] > 100000)
")"
if [ "$V18" = "True True True" ]; then
    ok "S18  --status counts the shells sparsified, the shells REFUSED, and the bytes actually freed ($(printf '%s' "$M18" | python3 -c "import json,sys; print(json.load(sys.stdin)['shell_bytes_freed'])") bytes so far)"
else
    bad "S18  [$V18] $(printf '%s' "$M18" | tr '\n' ' ' | cut -c1-200)"
fi

echo
if [ "$FAIL" -eq 0 ]; then
    echo "=== shell-worktree-sparse tests: all $PASS passed ==="
else
    echo "=== shell-worktree-sparse tests: $PASS passed, $FAIL FAILED ==="
    exit 1
fi

# The mutation harness runs LAST and only when the suite is green: a red suite
# proves nothing about which assertion is load-bearing.
MUT="$SCRIPT_DIR/shell-worktree-sparse.mutation.sh"
if [ -x "$MUT" ] && [ -z "${RICHOS_MUTATION_INNER:-}" ]; then
    echo
    bash "$MUT" || exit 1
fi
exit 0
