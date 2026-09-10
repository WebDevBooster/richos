#!/usr/bin/env bash
#
# worktree-adoption.test.sh — behavioral tests for scripts/lib/worktree-adoption.py.
#
# ===========================================================================
# WHAT THIS SUITE IS SHAPED AROUND
# ===========================================================================
# Adoption is the one thing in this engine that CLAIMS a workspace nobody
# claimed. Every design before it that touched a workspace on inferred
# authority destroyed one, so the suite is organized by REFUSAL: for each of
# the nine gates there is a fixture that must be refused BY NAME, and beside
# every refusal sits the same fixture with one property repaired, which must be
# accepted. A resolver that refuses everything satisfies every safety assertion
# and adopts nothing, which is the failure this pairing exists to catch.
#
# THE 2026-09-05 CONTROL IS A REAL FIXTURE, NOT A COMMENT. A24/A25 build a
# registered worktree that CONTAINS another registered worktree and assert it is
# refused twice over: once because the registry sees a workspace under it, once
# because a shallow listing sees a nested `.git` pointer whose repository the
# record never named. That is the shape the malformed caller supplied when it
# handed the remover the container of all worktrees.
#
# EVERY WRITE IS SANDBOXED BY CONSTRUCTION. Both stores are overridden for the
# whole file (RICHOS_WORKTREE_LEDGER, RICHOS_WORKTREE_TX_DIR) and A40 proves
# the module REFUSES to write when only one of them is, which is the property
# that stops a suite renaming a live engineer's worktree into /tmp.
#
# Run directly: scripts/lib/worktree-adoption.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADOPT_PY="$SCRIPT_DIR/worktree-adoption.py"
LEDGER_PY="$SCRIPT_DIR/worktree-ledger.py"
TX_PY="$SCRIPT_DIR/worktree-transactions.py"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t worktree-adoption-test.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -f "$ADOPT_PY" ] || { echo "FATAL: missing $ADOPT_PY" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

# --- the sandbox rooting, for the whole file --------------------------------
export RICHOS_WORKTREE_LEDGER="$SANDBOX/ledger.jsonl"
export RICHOS_WORKTREE_TX_DIR="$SANDBOX/tx"
# The capture store too: the daily lane refuses to archive residue when the
# transaction store is redirected and the capture store is not (A61).
export RICHOS_WORKTREE_CAPTURE_DIR="$SANDBOX/captures"
# An empty process table by default: every "no live process" gate would
# otherwise depend on what the operator's machine happens to be running.
export RICHOS_ADOPTION_PROCESSES="none"
export RICHOS_DAILY_PROCESSES="none"
export RICHOS_RECONCILE_BACKOFF_BASE=0
REC_PY="$SCRIPT_DIR/../reconcile-terminal-worktrees.py"

A() { python3 "$ADOPT_PY" "$@"; }
L() { python3 "$LEDGER_PY" "$@"; }

# --- fixtures ---------------------------------------------------------------
REPO="$SANDBOX/repo"
WT="$SANDBOX/wt"
mkdir -p "$REPO" "$WT"
git -C "$REPO" init -q -b main
printf 'seed\n' >"$REPO/seed.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m seed

# A pid nobody holds. `process_status` answers `gone` for it, which is the T2
# evidence class: the host process every agent of that session ran inside is
# no longer in the table.
DEAD_PID=999999
LIVE_PID=$$

add_wt() { # <name> [branch]
    local name="$1" branch="${2:-$1}"
    git -C "$REPO" worktree add -q -b "$branch" "$WT/$name"
}

register() { # <path> <branch> <session-id> <session-pid> [agent-id]
    L record registered --teammate "$(basename "$1")" --worktree "$1" --repo "$REPO" \
        --branch "$2" --session-id "$3" --session-pid "$4" \
        ${5:+--agent-id "$5"} --class hand-rolled --source test >/dev/null
}

verdict() { # <path> -> "GATE" on a refusal, "ADOPTABLE" otherwise
    local out
    out="$(A evaluate --worktree "$1" 2>&1)"
    printf '%s' "$out" | cut -f1,2 | tr '\t' ' '
}

reason() { A evaluate --worktree "$1" 2>&1 | cut -f3-; }

SID_DEAD="00000000-0000-4000-8000-00000000dead"
SID_LIVE="00000000-0000-4000-8000-00000000live"

# ===========================================================================
# 1. THE POSITIVE — a worktree that must be adoptable, so that every refusal
#    below is a refusal of something and not of everything.
# ===========================================================================
add_wt good
register "$WT/good" good "$SID_DEAD" "$DEAD_PID" a1111111111111111
V="$(verdict "$WT/good")"
[ "$V" = "ADOPTABLE T2" ] \
    && ok "A01  a registered, merged, clean, unlocked worktree whose host session pid is gone is ADOPTABLE on T2" \
    || bad "A01  expected 'ADOPTABLE T2', got '$V' — $(reason "$WT/good")"

# ===========================================================================
# 2. G6 owner-terminated — the evidence gate, and the tier boundary
# ===========================================================================

# A02/A03. A LIVE session vetoes, and it vetoes even when a dead session is also
# on record for the same path. A worktree PATH is reusable; finding the dead
# owner first and stopping there is a verdict about the wrong owner.
add_wt live
register "$WT/live" live "$SID_LIVE" "$LIVE_PID"
V="$(verdict "$WT/live")"
[ "$V" = "REFUSED owner-terminated" ] \
    && ok "A02  a worktree whose host session is STILL RUNNING is refused (owner-terminated)" \
    || bad "A02  expected refusal, got '$V'"

register "$WT/live" live "$SID_DEAD" "$DEAD_PID"
V="$(verdict "$WT/live")"
R="$(reason "$WT/live")"
if [ "$V" = "REFUSED owner-terminated" ] && printf '%s' "$R" | grep -q 'STILL RUNNING'; then
    ok "A03  a dead session on record does NOT overrule a live one for the same path (the reusable-key failure)"
else
    bad "A03  expected a live-session veto, got '$V' — $R"
fi

# A04. No record at all is never a claim. This is the whole rule in one case.
add_wt norecord
V="$(verdict "$WT/norecord")"
R="$(reason "$WT/norecord")"
if [ "$V" = "REFUSED owner-terminated" ] && printf '%s' "$R" | grep -q 'absence of a record is never a claim'; then
    ok "A04  a worktree no record names is refused: absence of a record is never a claim"
else
    bad "A04  expected the no-record refusal, got '$V' — $R"
fi

# A05/A06. T3 NEVER AUTHORIZES. A persisted `terminated` witness — the sweep's
# own observation that a native lock was released — is quoted as corroboration
# and refuses on its own. Beside it, the same fixture with T2 added is accepted,
# so the refusal is about the TIER and not about the fixture.
mkdir -p "$REPO/.claude/worktrees"
git -C "$REPO" worktree add -q -b worktree-agent-a3333333333333333 "$REPO/.claude/worktrees/agent-a3333333333333333"
NATIVE="$REPO/.claude/worktrees/agent-a3333333333333333"
L record terminated --agent-id a3333333333333333 --worktree "$NATIVE" \
    --reason "native isolation worktree registered and unlocked" --witness reaper-observation >/dev/null
V="$(verdict "$NATIVE")"
R="$(reason "$NATIVE")"
if [ "$V" = "REFUSED owner-terminated" ] && printf '%s' "$R" | grep -q 'T3 witness (never authorizing)'; then
    ok "A05  a T3 witness alone does NOT authorize: it is quoted as corroboration and refused"
else
    bad "A05  expected a T3-only refusal naming the witness, got '$V' — $R"
fi

L record registered --teammate native1 --worktree "$NATIVE" --repo "$REPO" \
    --branch worktree-agent-a3333333333333333 --session-id "$SID_DEAD" --session-pid "$DEAD_PID" \
    --agent-id a3333333333333333 --class native --source test >/dev/null
V="$(verdict "$NATIVE")"
[ "$V" = "ADOPTABLE T2" ] \
    && ok "A06  the SAME native worktree becomes adoptable once T2 evidence exists — the refusal was the tier, not the fixture" \
    || bad "A06  expected 'ADOPTABLE T2' after registering a dead session, got '$V' — $(reason "$NATIVE")"

# A07. T1 — the transaction store's own terminal index authorizes, with no
# ledger session identity at all.
add_wt t1tree
mkdir -p "$RICHOS_WORKTREE_TX_DIR/terminal"
printf 'somesession\n' >"$RICHOS_WORKTREE_TX_DIR/terminal/a7777777777777777"
L record registered --teammate t1tree --worktree "$WT/t1tree" --repo "$REPO" \
    --branch t1tree --agent-id a7777777777777777 --class hand-rolled --source test >/dev/null
V="$(verdict "$WT/t1tree")"
[ "$V" = "ADOPTABLE T1" ] \
    && ok "A07  an agent the transaction store marks terminal authorizes on T1, with no session pid on record" \
    || bad "A07  expected 'ADOPTABLE T1', got '$V' — $(reason "$WT/t1tree")"

# ===========================================================================
# 3. G7 merged, G8 clean, G5 unlocked, G9 no-live-process — each refused, each
#    accepted again once the one property is repaired.
# ===========================================================================

# A10/A11. Unmerged work is never adopted; landing it makes the same tree
# adoptable. The escalation records that sat unread for three days in femcboost
# are exactly this population.
add_wt unmerged
register "$WT/unmerged" unmerged "$SID_DEAD" "$DEAD_PID"
printf 'blocked\n' >"$WT/unmerged/BLOCKED.md"
git -C "$WT/unmerged" add -A
git -C "$WT/unmerged" commit -q -m "an escalation nobody landed"
V="$(verdict "$WT/unmerged")"
[ "$V" = "REFUSED merged" ] \
    && ok "A10  a branch carrying commits the repository's HEAD does not have is refused (merged)" \
    || bad "A10  expected 'REFUSED merged', got '$V'"

git -C "$REPO" merge -q --no-edit unmerged
V="$(verdict "$WT/unmerged")"
[ "$V" = "ADOPTABLE T2" ] \
    && ok "A11  the same tree is adoptable once its branch is an ancestor of HEAD" \
    || bad "A11  expected adoptable after merge, got '$V' — $(reason "$WT/unmerged")"

# A12/A13. Dirty means UNTRACKED too. An untracked file is the one a teammate
# never committed, and it is the byte adoption must never move without capture.
add_wt dirty
register "$WT/dirty" dirty "$SID_DEAD" "$DEAD_PID"
printf 'scratch\n' >"$WT/dirty/notes.txt"
V="$(verdict "$WT/dirty")"
[ "$V" = "REFUSED clean" ] \
    && ok "A12  an UNTRACKED file refuses adoption (clean covers tracked and untracked)" \
    || bad "A12  expected 'REFUSED clean', got '$V'"
rm -f "$WT/dirty/notes.txt"
V="$(verdict "$WT/dirty")"
[ "$V" = "ADOPTABLE T2" ] \
    && ok "A13  the same tree is adoptable once the untracked file is gone" \
    || bad "A13  expected adoptable, got '$V' — $(reason "$WT/dirty")"

# A14/A15. The lock is the platform's own statement that a workspace may still
# be in use, and it is always respected.
add_wt lockedtree
register "$WT/lockedtree" lockedtree "$SID_DEAD" "$DEAD_PID"
git -C "$REPO" worktree lock "$WT/lockedtree"
V="$(verdict "$WT/lockedtree")"
[ "$V" = "REFUSED unlocked" ] \
    && ok "A14  a LOCKED worktree is refused whatever else is on record" \
    || bad "A14  expected 'REFUSED unlocked', got '$V'"
git -C "$REPO" worktree unlock "$WT/lockedtree"
V="$(verdict "$WT/lockedtree")"
[ "$V" = "ADOPTABLE T2" ] \
    && ok "A15  the same tree is adoptable once the lock is released" \
    || bad "A15  expected adoptable after unlock, got '$V' — $(reason "$WT/lockedtree")"

# A16/A17. A process holding the path refuses, and an UNREADABLE process table
# refuses too — unverifiable is not permission.
add_wt busy
register "$WT/busy" busy "$SID_DEAD" "$DEAD_PID"
V="$(RICHOS_ADOPTION_PROCESSES="4242 /bin/sh -c cd $WT/busy" verdict "$WT/busy")"
[ "$V" = "REFUSED no-live-process" ] \
    && ok "A16  a live process referencing the path refuses adoption" \
    || bad "A16  expected 'REFUSED no-live-process', got '$V'"
V="$(RICHOS_ADOPTION_PROCESSES="" verdict "$WT/busy")"
[ "$V" = "ADOPTABLE T2" ] \
    && ok "A17  an empty process table lets the same tree through" \
    || bad "A17  expected adoptable with an empty table, got '$V'"

# A18. A detached HEAD has no branch to verify against, and unverifiable is not
# permission.
add_wt detached
register "$WT/detached" detached "$SID_DEAD" "$DEAD_PID"
git -C "$WT/detached" checkout -q --detach
V="$(verdict "$WT/detached")"
R="$(reason "$WT/detached")"
if [ "$V" = "REFUSED merged" ] && printf '%s' "$R" | grep -q 'detached HEAD'; then
    ok "A18  a detached HEAD is refused: there is no branch to verify against"
else
    bad "A18  expected a detached-HEAD refusal, got '$V' — $R"
fi

# ===========================================================================
# 4. G2 linked-worktree, G3 not-a-container — the 2026-09-05 controls
# ===========================================================================

# A20. The MAIN checkout is never a teammate workspace.
L record registered --teammate main --worktree "$REPO" --repo "$REPO" --branch main \
    --session-id "$SID_DEAD" --session-pid "$DEAD_PID" --class hand-rolled --source test >/dev/null
V="$(verdict "$REPO")"
R="$(reason "$REPO")"
if [ "$V" = "REFUSED linked-worktree" ] && printf '%s' "$R" | grep -q 'MAIN checkout'; then
    ok "A20  the main checkout is refused even with a registration naming it"
else
    bad "A20  expected the main-checkout refusal, got '$V' — $R"
fi

# A21. THE CONTAINER OF ALL WORKTREES — the exact argument the malformed caller
# supplied on 2026-09-05 — is refused, and a registration naming it changes
# nothing.
L record registered --teammate container --worktree "$WT" --repo "$REPO" --branch main \
    --session-id "$SID_DEAD" --session-pid "$DEAD_PID" --class hand-rolled --source test >/dev/null
V="$(verdict "$WT")"
[ "$V" = "REFUSED linked-worktree" ] \
    && ok "A21  the CONTAINER of every worktree is refused (2026-09-05: a registration naming it changes nothing)" \
    || bad "A21  expected 'REFUSED linked-worktree' for the container, got '$V' — $(reason "$WT")"

# A22. A subdirectory of a worktree resolves to a different top level and is
# refused: adoption acts on an exact workspace or on nothing.
mkdir -p "$WT/good/sub"
V="$(verdict "$WT/good/sub")"
[ "$V" = "REFUSED linked-worktree" ] \
    && ok "A22  a SUBDIRECTORY of a worktree is refused — the target is an exact top level or nothing" \
    || bad "A22  expected 'REFUSED linked-worktree' for a subdirectory, got '$V'"

# A23. A path that does not exist is refused at the first gate rather than
# treated as already handled.
V="$(verdict "$SANDBOX/nowhere")"
[ "$V" = "REFUSED exists" ] \
    && ok "A23  a path that is not on disk is refused at 'exists'" \
    || bad "A23  expected 'REFUSED exists', got '$V'"

# A24/A25. NESTED WORKSPACES. A worktree that CONTAINS another worktree is a
# container wearing a workspace's clothes, and it is refused by the gate whose
# only job is that question. Both probes are exercised: the registry sees the
# inner tree because the record names it (A24), and the shallow `.git`-pointer
# scan sees an inner tree from a repository the record never named (A25).
add_wt outer
register "$WT/outer" outer "$SID_DEAD" "$DEAD_PID"
git -C "$REPO" worktree add -q -b inner "$WT/outer/inner"
L record registered --teammate inner --worktree "$WT/outer/inner" --repo "$REPO" \
    --branch inner --session-id "$SID_DEAD" --session-pid "$DEAD_PID" --class hand-rolled --source test >/dev/null
V="$(verdict "$WT/outer")"
R="$(reason "$WT/outer")"
if [ "$V" = "REFUSED not-a-container" ] && printf '%s' "$R" | grep -q '2026-09-05'; then
    ok "A24  a worktree CONTAINING a registered worktree is refused (not-a-container, registry probe)"
else
    bad "A24  expected 'REFUSED not-a-container', got '$V' — $R"
fi

# The second probe on its own: an inner worktree belonging to a repository the
# ledger has never heard of. Only the shallow `.git`-pointer scan can see it.
OTHER="$SANDBOX/other"
mkdir -p "$OTHER"
git -C "$OTHER" init -q -b main
printf 'seed\n' >"$OTHER/seed.txt"
git -C "$OTHER" add -A
git -C "$OTHER" commit -q -m seed
add_wt outer2
register "$WT/outer2" outer2 "$SID_DEAD" "$DEAD_PID"
git -C "$OTHER" worktree add -q -b stranger "$WT/outer2/stranger"
V="$(verdict "$WT/outer2")"
[ "$V" = "REFUSED not-a-container" ] \
    && ok "A25  a nested worktree of a repository the RECORD never named is still seen (pointer probe)" \
    || bad "A25  expected 'REFUSED not-a-container' from the pointer probe, got '$V' — $(reason "$WT/outer2")"

# ===========================================================================
# 5. G4 unclaimed — adoption never competes with the terminal reconciler
# ===========================================================================
add_wt claimed
register "$WT/claimed" claimed "$SID_DEAD" "$DEAD_PID"
mkdir -p "$RICHOS_WORKTREE_TX_DIR/aaaaaaaa"
cat >"$RICHOS_WORKTREE_TX_DIR/aaaaaaaa/a9999999999999999.json" <<JSON
{"record": "transaction", "session_id": "aaaaaaaa", "agent_id": "a9999999999999999",
 "kind": "native+external", "sealed": true, "state": "sealed", "terminal": null,
 "members": [{"class": "hand-rolled", "repo": "$REPO", "path": "$WT/claimed", "branch": "claimed", "state": "bound"}]}
JSON
V="$(verdict "$WT/claimed")"
[ "$V" = "REFUSED unclaimed" ] \
    && ok "A30  a worktree a live transaction already owns is refused (unclaimed) — adoption never competes" \
    || bad "A30  expected 'REFUSED unclaimed', got '$V' — $(reason "$WT/claimed")"

# A31. A transaction's QUARANTINE name is the same member under another path,
# and it is claimed too.
add_wt quar
register "$WT/quar" quar "$SID_DEAD" "$DEAD_PID"
cat >"$RICHOS_WORKTREE_TX_DIR/aaaaaaaa/a8888888888888888.json" <<JSON
{"record": "transaction", "session_id": "aaaaaaaa", "agent_id": "a8888888888888888",
 "kind": "native+external", "sealed": true, "state": "terminal",
 "terminal": {"ingress": "SubagentStop", "detail": "", "ts": "2026-09-06T00:00:00+00:00"},
 "members": [{"class": "hand-rolled", "repo": "$REPO", "path": "$SANDBOX/gone", "quarantine": "$WT/quar", "branch": "quar", "state": "quarantined"}]}
JSON
V="$(verdict "$WT/quar")"
[ "$V" = "REFUSED unclaimed" ] \
    && ok "A31  a directory that is another transaction's QUARANTINE is refused too" \
    || bad "A31  expected 'REFUSED unclaimed' for a quarantine, got '$V'"

# ===========================================================================
# 6. HERMETIC ROOTING — the property that stops a suite renaming a live tree
# ===========================================================================
OUT="$(RICHOS_WORKTREE_LEDGER="$SANDBOX/ledger.jsonl" env -u RICHOS_WORKTREE_TX_DIR python3 "$ADOPT_PY" rooting 2>&1)"
RC=$?
if [ "$RC" -eq 4 ] && printf '%s' "$OUT" | grep -q '^REFUSED'; then
    ok "A40  a ledger override WITHOUT a transaction-store override is REFUSED (exit 4)"
else
    bad "A40  expected exit 4 and REFUSED, got rc=$RC: $OUT"
fi

OUT="$(env -u RICHOS_WORKTREE_LEDGER RICHOS_WORKTREE_TX_DIR="$SANDBOX/tx" python3 "$ADOPT_PY" adopt --worktree "$WT/good" 2>&1)"
RC=$?
if [ "$RC" -eq 4 ] && printf '%s' "$OUT" | grep -q 'hermetic-rooting'; then
    ok "A41  adopt REFUSES to write when only the transaction store is overridden — it would quarantine a REAL worktree into a sandbox"
else
    bad "A41  expected a hermetic-rooting refusal, got rc=$RC: $OUT"
fi

OUT="$(A rooting 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^OK' \
    && ok "A42  both overrides set is a consistent sandbox rooting" \
    || bad "A42  expected OK, got rc=$RC: $OUT"

# ===========================================================================
# 7. THE CLAIM ITSELF — end to end, and idempotent
# ===========================================================================
OUT="$(A adopt --worktree "$WT/good" --dry-run 2>&1)"
if printf '%s' "$OUT" | grep -q '^WOULD-ADOPT' && [ -d "$WT/good" ]; then
    ok "A50  --dry-run reports WOULD-ADOPT and leaves the directory exactly where it was"
else
    bad "A50  dry-run: $OUT"
fi

OUT="$(A adopt --worktree "$WT/good" 2>&1)"
if printf '%s' "$OUT" | grep -q '^ADOPTED'; then
    ok "A51  adopt reports ADOPTED for a tree that passed every gate"
else
    bad "A51  adopt: $OUT"
fi

AID="$(python3 - "$ADOPT_PY" "$WT/good" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ad", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.adoption_agent_id(sys.argv[2]))
PY
)"
TXF="$RICHOS_WORKTREE_TX_DIR/adopted/$AID.json"
if [ -f "$TXF" ] && grep -q '"kind": "adopted"' "$TXF" && grep -q '"sealed_by": "adoption"' "$TXF"; then
    ok "A52  the transaction is written as kind=adopted / sealed_by=adoption — never disguised as a spawn the platform witnessed"
else
    bad "A52  transaction record at $TXF: $(cat "$TXF" 2>&1 | head -c 300)"
fi

if grep -q '"ingress": "Adoption"' "$TXF" && grep -q '"tier": "T2"' "$TXF"; then
    ok "A53  the claim records its ingress and the evidence tier that authorized it"
else
    bad "A53  ingress/tier missing from $TXF"
fi

# A54-A58 (rewritten 2026-09-10, round 10). Adoption used to RENAME the tree
# into a quarantine and hand it to a pipeline whose last two steps refuse to
# erase, so an adopted tree was archived at full size and kept. It now routes
# the member to the daily clean/integrated lane: the tree stays at its path,
# owned and untouched, until the reconciler proves it clean and integrated.
if [ -d "$WT/good" ] && [ -f "$WT/good/seed.txt" ] && ! ls -d "$WT"/good.richos-terminal-* >/dev/null 2>&1; then
    ok "A54  adoption itself moves nothing: the workspace stays at its path, no quarantine is created"
else
    bad "A54  expected the tree at its path with no quarantine; exists=$([ -d "$WT/good" ] && echo yes || echo no) quar=$(ls -d "$WT"/good.richos-terminal-* 2>/dev/null | head -1)"
fi

if grep -q '"cleanup_policy": "integrated-daily"' "$TXF" && grep -q '"state": "bound"' "$TXF"; then
    ok "A55  the adopted member is routed to the daily clean/integrated lane (cleanup_policy=integrated-daily, state bound)"
else
    bad "A55  member routing in $TXF: $(grep -o '"cleanup_policy": "[^"]*"\|"state": "[^"]*"' "$TXF" | tr '\n' ' ')"
fi

if ! git -C "$REPO" rev-parse -q --verify "refs/richos/handoffs/adopted/$AID/good" >/dev/null; then
    ok "A56  no backup ref is minted by adoption alone — the lane deletes the branch only by exact compare-and-set against an integrated tip, so nothing needs pinning first"
else
    bad "A56  unexpected backup ref at refs/richos/handoffs/adopted/$AID/good"
fi

V="$(verdict "$WT/good")"
[ "$V" = "REFUSED unclaimed" ] \
    && ok "A57  the adopted path is refused on a second pass: its own transaction owns it, so an adoption is never taken twice" \
    || bad "A57  expected 'REFUSED unclaimed' after adoption, got '$V'"

# A58. The lane reclaims an adopted tree: clean, integrated (the branch was cut
# from main and never moved), unlocked, nobody standing in it. One reconciler
# run removes the worktree and deletes the branch by compare-and-set. This is
# the hand-off that used to end in `automatic erasure is disabled`.
#
# Its own container, deliberately: A21 registered $WT itself in the ledger (a
# malformed record naming the container of every worktree), and the lane's
# reservation check reads a registration of a PARENT path as a competing
# reservation over everything under it. So `good` stays HELD with exactly that
# reason — asserted below as the second half of this case — and the reclaim is
# proven on a tree whose container nothing ever registered.
WT2="$SANDBOX/wt2"; mkdir -p "$WT2"
git -C "$REPO" worktree add -q -b reclaim "$WT2/reclaim"
L record registered --teammate reclaim --worktree "$WT2/reclaim" --repo "$REPO" --branch reclaim \
    --session-id "$SID_DEAD" --session-pid "$DEAD_PID" --agent-id a2222222222222222 --class hand-rolled --source test >/dev/null
mkdir -p "$WT2/reclaim/__pycache__"; printf 'x' >"$WT2/reclaim/__pycache__/x.pyc"
printf '__pycache__/\n' >"$REPO/.git/info/exclude"
A adopt --worktree "$WT2/reclaim" >/dev/null 2>&1
AID2="$(python3 - "$ADOPT_PY" "$WT2/reclaim" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ad", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.adoption_agent_id(sys.argv[2]))
PY
)"
TXF2="$RICHOS_WORKTREE_TX_DIR/adopted/$AID2.json"
OUT="$(python3 "$REC_PY" --quiet 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [ ! -e "$WT2/reclaim" ] && ! git -C "$REPO" rev-parse -q --verify refs/heads/reclaim >/dev/null \
   && grep -q '"phase": "complete"' "$TXF2" && grep -q '"state": "removed"' "$TXF2" \
   && grep -q '"ignored_disposable": 1' "$TXF2" \
   && [ -d "$WT/good" ] && grep -q 'preparation reservation' "$TXF"; then
    ok "A58  one reconciler run RECLAIMS the adopted tree through the daily lane (worktree removed, branch deleted, the disposable __pycache__ dropped, member removed with phase complete) while a tree whose container a malformed record registered stays HELD with that reason"
else
    bad "A58  reclaim: rc=$RC exists=$([ -e "$WT2/reclaim" ] && echo yes || echo no) branch=$(git -C "$REPO" rev-parse -q --verify refs/heads/reclaim 2>/dev/null || echo gone) tx=$(grep -o '"phase": "[^"]*"\|"state": "[^"]*"\|"last_error": "[^"]*"\|"ignored_disposable": [0-9]*' "$TXF2" 2>/dev/null | tr '\n' ' ') good=$([ -d "$WT/good" ] && echo present || echo GONE) good-hold=$(grep -o '"last_error": "[^"]*"' "$TXF" | head -1) out=$(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"
fi

# A59. --all takes every adoptable candidate and REPORTS the refusals beside
# them: a pass that printed only what it took would be a pass with no
# denominator, which is the reporting failure this whole area was born from.
OUT="$(A adopt --all --dry-run 2>&1)"
if printf '%s' "$OUT" | grep -q '^REFUSED' && printf '%s' "$OUT" | grep -qE '^=== adoption: [0-9]+ of [0-9]+ candidate'; then
    ok "A59  --all prints refusals beside acceptances and a summary carrying its own denominator"
else
    bad "A59  --all output: $(printf '%s' "$OUT" | tail -3)"
fi

# A60. `candidates` comes from the RECORD, never from a directory scan: a
# worktree on disk that no record names is not a candidate.
add_wt unlisted
OUT="$(A candidates 2>&1)"
if printf '%s' "$OUT" | grep -qx "$WT/dirty" && ! printf '%s' "$OUT" | grep -qx "$WT/unlisted"; then
    ok "A60  candidates are enumerated from the record, so a directory nobody registered is not one"
else
    bad "A60  candidates: $(printf '%s' "$OUT" | tr '\n' ' ' | head -c 300)"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== worktree-adoption tests: $FAIL FAILED, $PASS passed ==="
    exit 1
fi
echo "=== worktree-adoption tests: all $PASS passed ==="

# The mutation harness is part of this suite's definition of green: a suite
# nobody has watched go red proves nothing (open-items rows 3.22-3.29).
if [ -f "$SCRIPT_DIR/worktree-adoption.mutation.sh" ]; then
    bash "$SCRIPT_DIR/worktree-adoption.mutation.sh" || exit 1
fi
exit 0
