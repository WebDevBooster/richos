#!/usr/bin/env bash
#
# inflight-ack-durability.test.sh — row 3.19: an ack must still read as an ack
#                                   after the worktree it was written in is
#                                   gone.
#
# ===========================================================================
# WHAT THIS PROVES, AND WHY A /tmp DIRECTORY WOULD NOT PROVE IT
# ===========================================================================
# The defect: an ack was ONLY a file inside the teammate's worktree; both
# governed repositories gitignore `.claude/*`; the harness auto-cleans an
# UNCHANGED isolation worktree at completion; and a gitignored write does not
# make a tree changed. So an agent whose only writes were acks had its
# worktree, and every ack in it, deleted the moment it finished — and at the
# 30-minute timeout that reads exactly like an agent that never acked.
#
# The brief for this row was explicit that a test which removes a directory it
# made in /tmp is not a proof. So the removal here is done by the engine's OWN
# sanctioned remover, scripts/remove-agent-worktree.sh — the same command the
# orchestrator runs, running the same `git worktree remove`, against a real
# linked worktree of a real repository, which DEREGISTERS the worktree as well
# as deleting it. Case 3 asserts positively that the artifact was destroyed
# before it asserts that the ack still reads.
#
# BOTH DIRECTIONS, because a store that answers "acked" for everybody is worse
# than the bug it replaces:
#   - a teammate that acked reads as acked after a real removal   (case 3)
#   - a teammate that never acked reads as not acked, before AND after its own
#     worktree is removed                                          (cases 4, 7)
#   - one teammate's ack never discharges another's debt           (case 5)
#   - an ack for a different sha never counts                      (case 6)
#
# AND THE TEETH ARE PROVEN. Case 9 empties the ledger and re-runs case 3's own
# assertion, which must then FAIL. A check that passes when the mechanism is
# removed is the failure class this row belongs to; this suite refuses to be an
# instance of it.
#
# NOTHING IS STUBBED except the three ledgers, which are redirected into the
# sandbox because a test must never write into the operator's real state. Case
# 10 is the canary for exactly that: it snapshots the operator's real ledgers
# and the working directory before case 1 and proves nothing escaped.
#
# Run directly:  scripts/hooks/inflight-ack-durability.test.sh [--verbose]

set -uo pipefail

VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SRC_DIR/../.." && pwd)"
START_CWD="$(pwd)"

PASS=0
FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '         %s\n' "$2"; FAIL=$((FAIL + 1)); }
say() { [ "$VERBOSE" -eq 1 ] && printf '\n----- %s -----\n%s\n' "$1" "$2"; return 0; }

# A SUITE THAT CANNOT RUN SAYS SO AND NAMES ITSELF. It never reports a pass, and
# it never exits 0 — a green line from a suite that skipped its subject is the
# thing this row is about.
cannot_run() {
    printf '\n=== inflight-ack-durability.test.sh CANNOT RUN — NOTHING WAS ASSERTED ===\n' >&2
    printf '  %s\n' "$1" >&2
    printf '  No case below ran. This is NOT a pass.\n' >&2
    exit 2
}

command -v git      >/dev/null 2>&1 || cannot_run "git is not on PATH."
command -v python3  >/dev/null 2>&1 || cannot_run "python3 is not on PATH."
REMOVER="$ENGINE_ROOT/scripts/remove-agent-worktree.sh"
[ -f "$REMOVER" ] || cannot_run "the sanctioned remover is missing at $REMOVER — this suite's whole point is a REAL removal, and it will not fake one."
[ -f "$ENGINE_ROOT/scripts/inflight-ack.sh" ]  || cannot_run "scripts/inflight-ack.sh is missing."
[ -f "$ENGINE_ROOT/scripts/lib/inflight.py" ]  || cannot_run "scripts/lib/inflight.py is missing."

SANDBOX="$(mktemp -d -t inflight-ack-dur.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

REPO="$SANDBOX/repo"
TEAMS="$SANDBOX/teams"
TEAM_DIR="$TEAMS/session-deadbeef"
STATE="$SANDBOX/state"
mkdir -p "$REPO" "$TEAM_DIR" "$STATE"

# --- EVERY DURABLE LEDGER REDIRECTED INTO THE SANDBOX ----------------------
# The ack ledger is the subject; the worktree ownership ledger is written by
# the remover; the team directory holds the notice ledger. All three live under
# the operator's real home by default, and a suite that redirected one of them
# while a second still followed the working directory is the generic leak shape
# a sibling row is sweeping for. Case 10 proves this list is complete rather
# than merely intended.
export RICHOS_INFLIGHT_ACK_LEDGER="$STATE/inflight-acks.jsonl"
export RICHOS_WORKTREE_LEDGER="$STATE/worktree-ledger.jsonl"
export INFLIGHT_TEAMS_DIR="$TEAMS"
export RICHOS_ENTITY_ROOT="$REPO"

# --- LEAK CANARY: the "before" snapshot, taken before anything runs --------
REAL_ACK_LEDGER="$HOME/.claude/state/inflight-acks.jsonl"
REAL_WT_LEDGER="$HOME/.claude/state/worktree-ledger.jsonl"
# THE CANARY ASKS "DID MY WRITES ESCAPE", NOT "DID THE FILE CHANGE", and the
# difference is not pedantry. The first version of this check compared byte
# sizes and went red on its first run — over 327 bytes appended by two OTHER
# agent sessions finishing on the same machine while the suite was running.
# These ledgers are machine-wide and live; a size comparison against one is a
# proxy that a concurrent writer falsifies, and a canary that cries wolf is a
# canary somebody switches off. Every path this suite could leak is under
# $SANDBOX, so the precise question is whether that string reached a real
# ledger — which no other process can answer for it.
#
# WHAT THIS DOES NOT COVER, named rather than implied: a leak that writes to a
# real ledger WITHOUT naming a sandbox path would pass this. Nothing this suite
# drives can do that (every row it can produce carries the worktree or ledger
# path), but the limit is real and stated.
leaked_into() { # <real-ledger> -> prints offending lines, if any
    [ -f "$1" ] || return 0
    grep -nF "$SANDBOX" "$1" 2>/dev/null | head -5
}
BEFORE_CWD_LIST="$(ls -A "$START_CWD" 2>/dev/null | LC_ALL=C sort | cksum)"
BEFORE_ENGINE_LIST="$(ls -A "$ENGINE_ROOT" 2>/dev/null | LC_ALL=C sort | cksum)"

# --- the sandbox engine copy ----------------------------------------------
# A copy, not a symlink, so the library each script resolves relative to itself
# is the one under test and case 9 can swap a ledger without touching the real
# engine.
mkdir -p "$REPO/scripts/hooks" "$REPO/scripts/lib"
for h in notice-inflight-sends.sh notice-inflight-acks.sh; do
    cp "$SRC_DIR/$h" "$REPO/scripts/hooks/$h" && chmod +x "$REPO/scripts/hooks/$h"
done
for l in inflight.sh inflight.py teammate-identity.py agent-liveness.py \
         resolve-roots.sh resolve-main-checkout.sh seat-jurisdiction.sh \
         git-jurisdiction.sh stop-hook-notice.sh unevaluated-notice.sh; do
    cp "$ENGINE_ROOT/scripts/lib/$l" "$REPO/scripts/lib/$l" 2>/dev/null || true
done
cp "$ENGINE_ROOT/scripts/inflight-notify.sh" "$REPO/scripts/"
cp "$ENGINE_ROOT/scripts/inflight-ack.sh" "$REPO/scripts/"
chmod +x "$REPO/scripts/inflight-notify.sh" "$REPO/scripts/inflight-ack.sh"
printf 'PROTECTED_PATHS="src"\n' > "$REPO/orchestration.config"

RUNNER="$REPO/scripts/inflight-notify.sh"
ACKER="$REPO/scripts/inflight-ack.sh"
WITNESS="$REPO/scripts/hooks/notice-inflight-sends.sh"
STOPHOOK="$REPO/scripts/hooks/notice-inflight-acks.sh"

# --- a real repository, real linked worktrees ------------------------------
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email "$(git config user.email 2>/dev/null || echo tester@example.invalid)"
git -C "$REPO" config user.name  "$(git config user.name  2>/dev/null || echo tester)"
mkdir -p "$REPO/src"
echo "one" > "$REPO/src/a.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "base"

mkdir -p "$SANDBOX/wt"
# Hand-rolled worktrees (the shape this operation actually runs in), so they are
# PRESUMED LIVE and notices can be credited to them.
#   GONE  — acks, then its worktree is REALLY removed.        (the invariant)
#   NOACK — never acks. The negative control, before and after removal.
#   LOST  — acks, then only its ack FILE is destroyed while the worktree stays
#           registered and live. This is the case that produces the false chase.
for t in zach-opus-gone1 zach-opus-noack1 zach-opus-lost1; do
    git -C "$REPO" worktree add -q -b "wt-$t" "$SANDBOX/wt/$t" >/dev/null 2>&1
    echo "work by $t" > "$SANDBOX/wt/$t/src/$t.txt"
    git -C "$SANDBOX/wt/$t" add -A
    git -C "$SANDBOX/wt/$t" commit -q -m "commit by $t"
done
WT_GONE="$SANDBOX/wt/zach-opus-gone1"
WT_NOACK="$SANDBOX/wt/zach-opus-noack1"
WT_LOST="$SANDBOX/wt/zach-opus-lost1"

# main moves under all three — the whole failure, reproduced.
echo "two" >> "$REPO/src/a.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "a land that moves main"
TIP="$(git -C "$REPO" rev-parse HEAD)"
OTHER_SHA="$(git -C "$REPO" rev-parse HEAD~1)"

send_payload() { # <to> <body>
    TO="$1" BODY="$2" python3 -c '
import json, os
print(json.dumps({"tool_name": "SendMessage", "hook_event_name": "PostToolUse",
                  "session_id": "deadbeef-1111-4000-8000-000000000000",
                  "cwd": os.environ.get("REPO", ""),
                  "tool_input": {"to": os.environ["TO"], "message": os.environ["BODY"],
                                 "summary": "in-flight notice"}}))'
}
stop_payload() {
    python3 -c '
import json
print(json.dumps({"hook_event_name": "Stop", "session_id": "deadbeef-1111-4000-8000-000000000000",
                  "cwd": "", "stop_hook_active": False, "last_assistant_message": "Done.",
                  "background_tasks": [], "session_crons": []}))'
}

# All three are told, through the REAL witness hook, so the notice ledger is
# produced the only way it can be produced rather than hand-written.
for t in zach-opus-gone1 zach-opus-noack1 zach-opus-lost1; do
    REPO="$REPO" send_payload "$t" "main moved to $TIP — impact: none" \
        | bash "$WITNESS" >/dev/null 2>&1
done

DETAIL_GONE="This land rewrites the deploy script I am mid-way through rewriting, so my base copy is stale."
DETAIL_LOST="It grew the fixture set my suite enumerates, so a suite sized at spawn time would under-cover."

echo "=== row 3.19: does an ack survive the removal of the worktree it lived in? ==="

# ==========================================================================
# 1. THE ACK IS WRITTEN TO BOTH PLACES
# ==========================================================================
AOUT="$(cd "$WT_GONE" && bash "$ACKER" --sha "$TIP" --impact stale-record \
        --detail "$DETAIL_GONE" --paths "src/a.txt" --teammate zach-opus-gone1 2>&1)"
ARC=$?
say "1 ack write" "$AOUT"
[ "$ARC" -eq 0 ] && ok "1a. the ack command succeeds" \
                 || bad "1a. the ack command succeeds" "exit $ARC: $AOUT"
ARTIFACT="$WT_GONE/.claude/inflight-acks/$(printf '%s' "$TIP" | cut -c1-12).zach-opus-gone1.ack"
[ -f "$ARTIFACT" ] && ok "1b. the readable mirror is written into the worktree" \
                   || bad "1b. the readable mirror is written" "$ARTIFACT missing"
if [ -s "$RICHOS_INFLIGHT_ACK_LEDGER" ]; then
    ok "1c. a DURABLE row is written outside the worktree"
else
    bad "1c. a durable row is written outside the worktree" "$RICHOS_INFLIGHT_ACK_LEDGER is empty or absent"
fi
# THE LEDGER MUST BE THE AUTHORITY IN THE TEXT THE TEAMMATE READS, not a
# silent second write. A teammate that is told only about the file will report
# the file in its handoff — which is what echo-opus-529 did, correctly, right
# before the file was deleted.
case "$AOUT" in
    *"$RICHOS_INFLIGHT_ACK_LEDGER"*) ok "1d. the teammate is told WHERE the durable record is" ;;
    *) bad "1d. the teammate is told where the durable record is" "$AOUT" ;;
esac

# ==========================================================================
# 2. BEFORE THE REMOVAL — the sweep verifies it
# ==========================================================================
BEFORE="$(bash "$RUNNER" acks --repo "$REPO" 2>&1)"
say "2 acks before removal" "$BEFORE"
case "$BEFORE" in
    *"zach-opus-gone1"*) ok "2a. before removal, the sweep names the teammate that acked" ;;
    *) bad "2a. before removal the sweep names the acking teammate" "$BEFORE" ;;
esac
case "$BEFORE" in
    *"verified : YES"*) ok "2b. before removal, the ack VERIFIES" ;;
    *) bad "2b. before removal the ack verifies" "$BEFORE" ;;
esac

# ==========================================================================
# 3. THE REAL REMOVAL — the engine's own remover, not an rm in a scratch dir
# ==========================================================================
ROUT="$(bash "$REMOVER" --owner agone1-000000000000 --repo "$REPO" \
        --branch wt-zach-opus-gone1 --force --entity-repo "$REPO" "$WT_GONE" 2>&1)"
RRC=$?
say "3 removal" "$ROUT"
if [ "$RRC" -ne 0 ]; then
    # The suite's subject is what happens AFTER a real removal. If the removal
    # did not happen, every assertion below would be vacuous, so this is a
    # refusal to continue rather than a failed case among others.
    bad "3a. the sanctioned remover removes the worktree" "exit $RRC: $ROUT"
    cannot_run "the REAL removal did not happen (exit $RRC), so nothing after it could be tested: $ROUT"
fi
ok "3a. the sanctioned remover ran and removed the worktree"

# THE DESTRUCTION, ASSERTED POSITIVELY. Without this the rest of the case could
# pass over a worktree that was never removed.
[ ! -d "$WT_GONE" ]  && ok "3b. the worktree DIRECTORY is gone" \
                     || bad "3b. the worktree directory is gone" "$WT_GONE still exists"
[ ! -f "$ARTIFACT" ] && ok "3c. the ack FILE is gone with it — the evidence really was destroyed" \
                     || bad "3c. the ack file is gone with it" "$ARTIFACT still exists"
if git -C "$REPO" worktree list --porcelain | grep -qF "$WT_GONE"; then
    bad "3d. the worktree is DEREGISTERED, not merely deleted" "still listed by git worktree list"
else
    ok "3d. the worktree is DEREGISTERED — its teammate is in no per-worktree loop at all"
fi

# --- THE INVARIANT ---------------------------------------------------------
AFTER="$(bash "$RUNNER" acks --repo "$REPO" 2>&1)"
say "3 acks after removal" "$AFTER"
case "$AFTER" in
    *"zach-opus-gone1"*) ok "3e. THE INVARIANT: after a real removal, the teammate STILL reads as having acked" ;;
    *) bad "3e. THE INVARIANT: the ack survives the removal" "$AFTER" ;;
esac
case "$AFTER" in
    *"ACKED, WORKTREE GONE"*) ok "3f. it is reported as acked-and-finished, not as an outstanding debt" ;;
    *) bad "3f. it is reported as acked-and-finished" "$AFTER" ;;
esac
case "$AFTER" in
    *"$DETAIL_GONE"*) ok "3g. the teammate's own words survive verbatim — the part no machine can check" ;;
    *) bad "3g. the detail survives verbatim" "$AFTER" ;;
esac

# ==========================================================================
# 4. NEGATIVE CONTROL — the teammate that never acked
# ==========================================================================
SOUT="$(bash "$RUNNER" status --repo "$REPO" 2>&1)"
say "4 status" "$SOUT"
if printf '%s' "$SOUT" | grep -q "NOTIFIED-NO-ACK.*zach-opus-noack1"; then
    ok "4a. the teammate that never acked reads as NOTIFIED-NO-ACK"
else
    bad "4a. the teammate that never acked reads as NOTIFIED-NO-ACK" "$SOUT"
fi
case "$AFTER" in
    *"zach-opus-noack1"*) bad "4b. the acks report does NOT credit the teammate that never acked" "$AFTER" ;;
    *) ok "4b. the acks report does NOT credit the teammate that never acked" ;;
esac

# ==========================================================================
# 5. ATTRIBUTION — one teammate's ack never discharges another's debt
# ==========================================================================
# A ledger row is in a machine-wide file next to everybody else's, so unlike an
# ack FILE its location proves nothing. gone1's row is for this exact tip and is
# sitting in the same ledger noack1 is read against; if matching were loose, it
# would clear noack1.
JOUT="$(IF_LIB="$REPO/scripts/lib" IF_REPO="$REPO" python3 -c '
import os, sys
sys.path.insert(0, os.environ["IF_LIB"])
import inflight
res = inflight.assess(os.environ["IF_REPO"], None, os.environ["INFLIGHT_TEAMS_DIR"] + "/session-deadbeef", 30, "", "")
for wt in res["worktrees"]:
    print("%s\t%s\t%s" % (os.path.basename(wt["path"]), wt["verdict"], (wt.get("ack") or {}).get("verified")))
' 2>&1)"
say "5 per-worktree verdicts" "$JOUT"
if printf '%s' "$JOUT" | grep -q "^zach-opus-noack1	NOTIFIED-NO-ACK	False"; then
    ok "5a. gone1's ledger row does NOT verify for noack1 — attribution is positive, not positional"
else
    bad "5a. one teammate's ledger row does not discharge another's debt" "$JOUT"
fi

# ==========================================================================
# 6. THE SHA IS THE FACT — an ack for a different land never counts
# ==========================================================================
bash "$ACKER" --sha "$OTHER_SHA" --impact none \
    --detail "Acknowledging an entirely different commit, which must not clear the current tip." \
    --paths none --worktree "$WT_NOACK" --teammate zach-opus-noack1 >/dev/null 2>&1
JOUT2="$(IF_LIB="$REPO/scripts/lib" IF_REPO="$REPO" python3 -c '
import os, sys
sys.path.insert(0, os.environ["IF_LIB"])
import inflight
res = inflight.assess(os.environ["IF_REPO"], None, os.environ["INFLIGHT_TEAMS_DIR"] + "/session-deadbeef", 30, "", "")
for wt in res["worktrees"]:
    print("%s\t%s" % (os.path.basename(wt["path"]), wt["verdict"]))
' 2>&1)"
if printf '%s' "$JOUT2" | grep -q "^zach-opus-noack1	NOTIFIED-NO-ACK"; then
    ok "6a. a durable row for a DIFFERENT sha does not clear the current tip"
else
    bad "6a. a durable row for a different sha does not clear the current tip" "$JOUT2"
fi

# ==========================================================================
# 7. THE NEGATIVE CONTROL SURVIVES REMOVAL TOO
# ==========================================================================
# A store that answered "acked" for everybody once their worktree was gone
# would be worse than the bug. noack1 is now removed the same real way gone1
# was; it must appear NOWHERE in the acks report for this tip.
bash "$REMOVER" --owner anoack1-000000000000 --repo "$REPO" \
    --branch wt-zach-opus-noack1 --force --entity-repo "$REPO" "$WT_NOACK" >/dev/null 2>&1
NRC=$?
if [ "$NRC" -ne 0 ] || [ -d "$WT_NOACK" ]; then
    bad "7a. the negative control's worktree is really removed too" "exit $NRC; dir present: $([ -d "$WT_NOACK" ] && echo yes || echo no)"
else
    ok "7a. the negative control's worktree is really removed too"
    AFTER2="$(bash "$RUNNER" acks --repo "$REPO" 2>&1)"
    say "7 acks after both removals" "$AFTER2"
    case "$AFTER2" in
        *"zach-opus-noack1"*) bad "7b. a teammate that never acked STILL does not read as acked once its worktree is gone" "$AFTER2" ;;
        *) ok "7b. a teammate that never acked STILL does not read as acked once its worktree is gone" ;;
    esac
    case "$AFTER2" in
        *"zach-opus-gone1"*) ok "7c. and the one that DID ack is still there — the store discriminates" ;;
        *) bad "7c. the one that did ack is still there" "$AFTER2" ;;
    esac
fi

# ==========================================================================
# 8. THE FALSE CHASE — artifact destroyed, worktree still registered and live
# ==========================================================================
# This is the harm the row names: at the timeout, an ack that was written and
# then deleted reads exactly like one that was never written, and the operator
# is told to chase a teammate that already complied. lost1 acks, then its ack
# FILE is destroyed while its worktree stays registered and presumed live.
bash "$ACKER" --sha "$TIP" --impact grew-scope --detail "$DETAIL_LOST" \
    --paths "src/a.txt" --worktree "$WT_LOST" --teammate zach-opus-lost1 >/dev/null 2>&1
rm -rf "$WT_LOST/.claude/inflight-acks"
[ ! -d "$WT_LOST/.claude/inflight-acks" ] \
    && ok "8a. lost1's ack FILE is destroyed while its worktree stays registered" \
    || bad "8a. lost1's ack file is destroyed" "directory still present"

sleep 2

# 8b IS THE POSITIVE PROBE, AND IT RUNS FIRST ON PURPOSE. Silence from a Stop
# hook is its healthy state, so "the nag did not name lost1" would be satisfied
# just as well by a hook that never ran at all — the exact "nothing
# distinguishes worked from never ran" shape. So the same hook is first run
# against an EMPTY ledger, where lost1 has no surviving ack anywhere and MUST be
# chased. Only once the chase is seen to happen does its absence mean anything.
: > "$STATE/probe-empty.jsonl"
PROBE_STOP="$(stop_payload | RICHOS_INFLIGHT_ACK_LEDGER="$STATE/probe-empty.jsonl" \
              INFLIGHT_ACK_TIMEOUT_MIN=0 bash "$STOPHOOK" 2>&1)"
say "8b probe: stop hook with no durable ack" "$PROBE_STOP"
PROBE_FIRED=0
case "$PROBE_STOP" in
    *"zach-opus-lost1"*)
        PROBE_FIRED=1
        ok "8b. POSITIVE PROBE: with no durable ack, the Stop hook DOES chase lost1 past the timeout" ;;
    *) bad "8b. POSITIVE PROBE: with no durable ack the Stop hook chases lost1" \
           "the nag did not fire even with the evidence removed, so 8c would assert nothing: $PROBE_STOP" ;;
esac

if [ "$PROBE_FIRED" -eq 1 ]; then
    STOP_OUT="$(stop_payload | INFLIGHT_ACK_TIMEOUT_MIN=0 bash "$STOPHOOK" 2>&1)"
    say "8c stop hook with the durable ack present" "$STOP_OUT"
    case "$STOP_OUT" in
        *"zach-opus-lost1"*) bad "8c. the operator is NOT told to chase a teammate that already complied" "$STOP_OUT" ;;
        *) ok "8c. the operator is NOT told to chase a teammate that already complied — the ledger answers for the deleted file" ;;
    esac
else
    # NOT reported as a pass. 8c is only meaningful downstream of 8b.
    bad "8c. the false chase is prevented" \
        "not asserted: 8b did not fire, so silence here would be indistinguishable from a hook that never ran"
fi

# ==========================================================================
# 9. THE TEETH — case 3's assertion must FAIL when the ledger is taken away
# ==========================================================================
# Everything above could pass over a mechanism that is not there if the acks
# report happened to name a teammate for some other reason. So case 3e is re-run
# against an EMPTY ledger; it must come back negative. A check that passes both
# with and without its subject is the failure class this row belongs to.
: > "$STATE/empty-ledger.jsonl"
PROBE="$(RICHOS_INFLIGHT_ACK_LEDGER="$STATE/empty-ledger.jsonl" bash "$RUNNER" acks --repo "$REPO" 2>&1)"
say "9 probe with an empty ledger" "$PROBE"
case "$PROBE" in
    *"zach-opus-gone1"*)
        bad "9a. POSITIVE PROBE: with the ledger emptied, case 3e must go red" \
            "gone1 is still reported as acked with an empty ledger, so 3e proves nothing: $PROBE" ;;
    *) ok "9a. POSITIVE PROBE: with the ledger emptied, the surviving ack disappears — 3e has teeth" ;;
esac
case "$PROBE" in
    *"no ack artifacts, no durable ledger rows"*) ok "9b. and the empty case says so plainly rather than printing nothing" ;;
    *) bad "9b. the empty case says so plainly" "$PROBE" ;;
esac

# ==========================================================================
# 10. UNREADABLE IS NOT EMPTY
# ==========================================================================
# A ledger that cannot be read must not report a clean world. This is the same
# distinction the whole row turns on, one level up.
UNREADABLE="$STATE/a-directory-not-a-file.jsonl"
mkdir -p "$UNREADABLE"
UOUT="$(RICHOS_INFLIGHT_ACK_LEDGER="$UNREADABLE" bash "$RUNNER" acks --repo "$REPO" 2>&1)"
say "10 unreadable ledger" "$UOUT"
case "$UOUT" in
    *"COULD NOT BE READ"*) ok "10a. an unreadable ledger is reported as unreadable, not as empty" ;;
    *) bad "10a. an unreadable ledger is reported as unreadable" "$UOUT" ;;
esac

# ==========================================================================
# 11. ACKING WHEN THE WORKTREE IS ALREADY GONE
# ==========================================================================
# zach-opus-not1's other half: after its worktree was cleaned, this command
# REFUSED outright with "worktree does not exist", so the teammate could not
# answer the next notice at all. The durable row does not need the directory.
GRC=0
GONE_OUT="$(bash "$ACKER" --sha "$TIP" --impact none \
            --detail "My worktree was removed under me; recording this against the ledger alone." \
            --paths none --worktree "$WT_GONE" --teammate zach-opus-gone1 --repo "$REPO" 2>&1)" || GRC=$?
say "11 ack with a vanished worktree" "$GONE_OUT"
[ "$GRC" -eq 0 ] && ok "11a. a teammate whose worktree is already gone can still ack" \
                 || bad "11a. a teammate whose worktree is already gone can still ack" "exit $GRC: $GONE_OUT"
case "$GONE_OUT" in
    *"NO readable mirror"*) ok "11b. and it is TOLD that only the durable row was written" ;;
    *) bad "11b. it is told that only the durable row was written" "$GONE_OUT" ;;
esac

# ==========================================================================
# 12. THE WRITER REFUSES TO FAIL QUIETLY
# ==========================================================================
# If the durable row cannot be written, a teammate must not walk away believing
# it acked. The file in the worktree would be deleted with the worktree, which
# is the entire defect.
BRC=0
BOUT="$(RICHOS_INFLIGHT_ACK_LEDGER="$STATE/a-directory-not-a-file.jsonl" \
        bash "$ACKER" --sha "$TIP" --impact none \
        --detail "This ack cannot be made durable, and the command must say so out loud." \
        --paths none --worktree "$WT_LOST" --teammate zach-opus-lost1 2>&1)" || BRC=$?
say "12 unwritable ledger" "$BOUT"
[ "$BRC" -ne 0 ] && ok "12a. an ack that cannot be made durable exits NON-ZERO" \
                 || bad "12a. an ack that cannot be made durable exits non-zero" "exit 0: $BOUT"
case "$BOUT" in
    *"NOT RECORDED"*|*"NOT WRITTEN"*) ok "12b. and it says the ack was not recorded, in those words" ;;
    *) bad "12b. it says the ack was not recorded" "$BOUT" ;;
esac

# ==========================================================================
# 14. THE NATIVE SHAPE — the one the harness actually auto-cleans
# ==========================================================================
# Everything above uses hand-rolled worktrees, which is the shape this
# operation runs in but NOT the shape row 3.19 is about: the auto-clean applies
# to a NATIVE isolation worktree at <repo>/.claude/worktrees/agent-<id>. The
# ledger logic does not branch on worktree kind, but identity resolution and
# LIVENESS both do, so "it works for hand-rolled" is an inference rather than a
# result. This runs the whole lifecycle in the native shape instead:
# locked with a live pid while it works, unlocked when it finishes, then removed
# by the sanctioned remover.
NAT_ID="azachnat-0123456789abcd"
NAT_WT="$REPO/.claude/worktrees/agent-$NAT_ID"
mkdir -p "$REPO/.claude/worktrees"
git -C "$REPO" worktree add -q -b wt-native "$NAT_WT" >/dev/null 2>&1
if [ ! -d "$NAT_WT" ]; then
    bad "14a. a native-shaped worktree can be created" "git worktree add failed for $NAT_WT"
else
    git -C "$REPO" worktree lock --reason "claude agent agent-$NAT_ID (pid $$ started now)" "$NAT_WT" >/dev/null 2>&1
    if git -C "$REPO" worktree list --porcelain | grep -q "locked claude agent agent-$NAT_ID"; then
        ok "14a. the native worktree is LOCKED with a live pid — the running-agent state"
    else
        bad "14a. the native worktree is locked with a live pid" "no lock line in git worktree list"
    fi
    REPO="$REPO" send_payload "zachnat" "main moved to $TIP — impact: none" \
        | bash "$WITNESS" >/dev/null 2>&1
    DETAIL_NAT="A native isolation worktree acking, then finishing, which is the exact case the harness cleans up."
    bash "$ACKER" --sha "$TIP" --impact none --detail "$DETAIL_NAT" \
        --paths none --worktree "$NAT_WT" --teammate zachnat >/dev/null 2>&1
    NAT_BEFORE="$(bash "$RUNNER" status --repo "$REPO" 2>&1)"
    say "14 native status before removal" "$NAT_BEFORE"
    case "$NAT_BEFORE" in
        *"NOTIFIED-ACKED"*) ok "14b. while it is live and locked, the native teammate reads as told AND proved" ;;
        *) bad "14b. the live native teammate reads as told and proved" "$NAT_BEFORE" ;;
    esac

    # The agent finishes: the harness releases the lock, then the worktree is
    # removed. Both steps, in that order, because the remover REFUSES a locked
    # worktree with a live pid — correctly.
    git -C "$REPO" worktree unlock "$NAT_WT" >/dev/null 2>&1
    NAT_ROUT="$(bash "$REMOVER" --owner "$NAT_ID" --repo "$REPO" \
                --branch wt-native --force --entity-repo "$REPO" "$NAT_WT" 2>&1)"
    NAT_RRC=$?
    say "14 native removal" "$NAT_ROUT"
    if [ "$NAT_RRC" -ne 0 ] || [ -d "$NAT_WT" ]; then
        bad "14c. the native worktree is really removed" "exit $NAT_RRC: $NAT_ROUT"
        bad "14d. the native teammate's ack survives its removal" \
            "not asserted: the removal did not happen, so this would assert nothing"
    else
        ok "14c. the native worktree is really removed, by the sanctioned remover"
        NAT_AFTER="$(bash "$RUNNER" acks --repo "$REPO" 2>&1)"
        say "14 native acks after removal" "$NAT_AFTER"
        case "$NAT_AFTER" in
            *"$DETAIL_NAT"*) ok "14d. THE INVARIANT IN THE NATIVE SHAPE: the ack survives the auto-clean" ;;
            *) bad "14d. the native teammate's ack survives its removal" "$NAT_AFTER" ;;
        esac
    fi
fi

# ==========================================================================
# 13. LEAK CANARY — nothing escaped the sandbox
# ==========================================================================
# Every case above wrote acks, removed worktrees and drove hooks. If any of the
# three ledger redirects at the top of this file is incomplete, the operator's
# real state grew while this suite "passed".
AFTER_CWD_LIST="$(ls -A "$START_CWD" 2>/dev/null | LC_ALL=C sort | cksum)"
AFTER_ENGINE_LIST="$(ls -A "$ENGINE_ROOT" 2>/dev/null | LC_ALL=C sort | cksum)"
LEAK_ACK="$(leaked_into "$REAL_ACK_LEDGER")"
LEAK_WT="$(leaked_into "$REAL_WT_LEDGER")"
[ -z "$LEAK_ACK" ] \
    && ok "13a. no row from this sandbox reached the operator's real ack ledger" \
    || bad "13a. no row from this sandbox reached the real ack ledger" "$REAL_ACK_LEDGER: $LEAK_ACK"
[ -z "$LEAK_WT" ] \
    && ok "13b. no row from this sandbox reached the operator's real worktree ledger" \
    || bad "13b. no row from this sandbox reached the real worktree ledger" "$REAL_WT_LEDGER: $LEAK_WT"
# THE CANARY'S OWN TEETH. An always-empty grep passes for free, so the same
# search is run against a file that DOES contain the sandbox path. If this goes
# red, 13a/13b were passing because the search was broken, not because nothing
# leaked.
printf 'a line naming %s\n' "$SANDBOX" > "$STATE/canary-selftest.txt"
if [ -n "$(leaked_into "$STATE/canary-selftest.txt")" ]; then
    ok "13e. the leak search finds a sandbox path when there IS one — 13a/13b are not free passes"
else
    bad "13e. the leak search finds a sandbox path when there is one" \
        "the search itself is broken, so 13a and 13b asserted nothing"
fi
[ "$BEFORE_CWD_LIST" = "$AFTER_CWD_LIST" ] \
    && ok "13c. nothing appeared in the directory this suite was started from" \
    || bad "13c. nothing appeared in the starting directory" "$START_CWD changed"
[ "$BEFORE_ENGINE_LIST" = "$AFTER_ENGINE_LIST" ] \
    && ok "13d. nothing appeared at the engine root" \
    || bad "13d. nothing appeared at the engine root" "$ENGINE_ROOT changed"

echo ""
echo "  passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
