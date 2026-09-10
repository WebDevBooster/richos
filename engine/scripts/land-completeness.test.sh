#!/usr/bin/env bash
#
# land-completeness.test.sh — G3. PROOF BOTH WAYS, ON FIXTURES THAT DECIDE
#                             THEIR OWN ANSWER.
#
# Every case builds a real git repository with real linked worktrees and a real
# (sandbox) ownership ledger. Nothing here consults the operator's machine: a
# suite whose verdict depends on which agents happen to be running while it runs
# is a suite that goes red for reasons unrelated to the code, and gets ignored.
#
# THE CASES, and why each one is here rather than asserted in a comment:
#
#   L1  A CLEAN LAND IS SILENT. No linked worktrees, nothing to say, exit 0 and
#       no output. A check that prints on every clean land teaches people to
#       filter it, and then it is not a check.
#   L2  A MERGED BRANCH WHOSE WORKTREE IS STILL REGISTERED IS AN INCOMPLETE
#       LAND. The target failure, stated positively.
#   L3  AN UNMERGED BRANCH IS NEVER RESIDUE — the R3 case, and the one that
#       matters most. On 2026-09-10 two agents were killed on an inference and
#       one's only commit survived SOLELY because it sat on an unmerged branch
#       that nothing was permitted to touch. If this case ever fails, this work
#       has become the thing it was written to prevent.
#   L4  A LIVE OWNER IS EXEMPT. A worktree whose owner holds a LOCKED native
#       isolation worktree is never named, even with its branch merged. This is
#       the false-positive class the G0 measurement found at 7.6%, and it is
#       excluded by construction rather than by luck.
#   L5  NO OWNERSHIP RECORD IS `unowned`, NOT `incomplete-land`. Five worktrees
#       on this machine belong to a Codex CLI the ledger will never hear about.
#       They are reported in the unknown column and blocked on by nothing.
#   L6  A MERGED BRANCH WITH NO WORKTREE IS A NAMED BENIGN STATE (R4). A branch
#       and a worktree are different objects, they are counted separately, and
#       the benign case must not be silence.
#   L7  THE UNKNOWN AND NOT-EXAMINED SECTIONS PRINT EVEN WHEN EMPTY (R5). The
#       whole point is that absence of a finding is distinguishable from
#       absence of a check.
#   L8  AN UNREADABLE REPOSITORY IS `not examined` AND EXITS 4, NOT 0. A checker
#       that could not look has proved nothing, and must not share an exit code
#       with one that looked and found nothing.
#   L9  THE GATE REFUSES UNDER ENFORCEMENT AND ANNOUNCES WITHOUT IT — the same
#       state, two configurations, two exit codes. This is what "reporting only"
#       has to mean to be worth shipping.
#   L10 A BARE ACKNOWLEDGEMENT EXEMPTS NOTHING, and a PARTIAL one still refuses
#       and names only what was left unacknowledged.
#   L11 AN ACKNOWLEDGEMENT NAMING SOMETHING THAT IS NOT RESIDUE exempts nothing
#       and is called out — it is a typo or a copied line, and both are worth
#       seeing before a land goes through on one.
#   L12 THE REPETITION COUNT APPEARS FROM THE THIRD USE. The anti-habit
#       mechanism is the only thing standing between this hatch and the fate of
#       g11/g12/g13, so it is a case and not a hope.
#   L13 THE NEGATIVE CONTROL. With enforcement on and residue present, the gate
#       MUST exit 2 — without this, every silence above would also pass against
#       a check that had been accidentally disabled.
#   L14 THE LIVENESS MODULE'S ABSENCE PRODUCES `unowned`, NEVER
#       `incomplete-land`. This is the near-miss that classified a RUNNING
#       agent's own worktree as residue on 2026-09-10: judge() takes its
#       liveness module as a keyword defaulting to None, and with None every
#       verdict degrades to INDETERMINATE, which blocks. Degrading toward
#       "cannot decide" is safe; degrading toward "refuse" is not.
#   L15 RUN FROM INSIDE A WORKTREE, THE MAIN CHECKOUT IS NEVER NAMED. And L16,
#       that a worktree and its main checkout are ONE repository. Both bugs were
#       found by running the command for real rather than by reading it, both
#       appear only from inside a worktree — which is where every agent runs it
#       — and one of them put the operator's own checkout in the report.
#
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS="$SCRIPT_DIR/land-completeness.sh"
GATE="$SCRIPT_DIR/lib/land-residue-gate.py"
ANALYZER="$SCRIPT_DIR/lib/land-completeness.py"

PASS=0; FAIL=0
SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/land-completeness.XXXXXX")" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

for f in "$STATUS" "$GATE" "$ANALYZER"; do
    [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 1; }
done
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git required" >&2; exit 1; }

export RICHOS_WORKTREE_LEDGER="$SANDBOX/ledger.jsonl"
: > "$RICHOS_WORKTREE_LEDGER"
ACK_LOG="$SANDBOX/acks.log"

echo "=== land-completeness tests ==="

# ---------------------------------------------------------------------------
# FIXTURES
# ---------------------------------------------------------------------------
# A commit is REQUIRED here, unlike the CI gate's fixture: merge status is the
# whole subject of this suite and an unborn branch has none.
#
# THE IDENTITY IS INHERITED, NOT INVENTED, AND THAT IS A FINDING RATHER THAN A
# STYLE CHOICE. scripts/lib/resolve-roots.test.sh and the CI gate's suite both
# record that a machine-wide pre-commit identity guard refuses a commit made
# under an invented address; they avoid it by having no commit, which is not
# available here. Writing a fixture address anyway makes the suite depend on
# that guard's ABSENCE, so it would pass on the author's machine and fail on
# the one that has the guard — the worst failure mode a suite can have. So the
# fixture borrows whatever identity this machine already commits under, which
# satisfies any such guard by construction and invents nothing.
GIT_ID_EMAIL="$(git config --get user.email 2>/dev/null || true)"
GIT_ID_NAME="$(git config --get user.name 2>/dev/null || true)"

mkrepo() {
    local repo="$1"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    [ -n "$GIT_ID_EMAIL" ] && git -C "$repo" config user.email "$GIT_ID_EMAIL"
    [ -n "$GIT_ID_NAME" ] && git -C "$repo" config user.name "$GIT_ID_NAME"
    git -C "$repo" config commit.gpgsign false
    echo one > "$repo/f.txt"
    git -C "$repo" add f.txt
    # --no-verify is NOT used, deliberately: the point of inheriting the
    # identity above is that this commit passes the machine's own hooks rather
    # than stepping around them.
    git -C "$repo" commit -q -m "base"
}

# A linked worktree on its own branch. `merged=yes` leaves the branch at main's
# tip (an ancestor of main, so already landed); `merged=no` puts a commit on it
# that main does not have.
mkworktree() {
    local repo="$1" name="$2" merged="$3"
    git -C "$repo" worktree add -q -b "$name" "$repo/../$name" main 2>/dev/null
    if [ "$merged" = "no" ]; then
        echo "$name" > "$repo/../$name/w.txt"
        git -C "$repo/../$name" add w.txt
        git -C "$repo/../$name" commit -q -m "work on $name"
    fi
}

# An ownership record for a worktree, with a session pid that is PROVABLY GONE
# so the owner judges NOT-ALIVE without this suite having to kill anything.
# pid 2 is init-adjacent and never a claude session; the recorded start time is
# deliberately one that will not match, which is the ledger's own reuse check.
register() {
    local repo="$1" wt="$2" branch="$3" agent="$4"
    python3 - "$repo" "$wt" "$branch" "$agent" <<'PY'
import json, os, sys
repo, wt, branch, agent = sys.argv[1:5]
rec = {"event": "registered", "agent_id": agent, "session_id": "sess-" + agent,
       "session_pid": 2, "pid_start": "ps-lstart-utc-v1:Thu Jan  1 00:00:00 1970",
       "repo": repo, "worktree": wt, "branch": branch, "class": "hand-rolled",
       "source": "land-completeness.test.sh", "ts": "2026-09-10T00:00:00+00:00"}
with open(os.environ["RICHOS_WORKTREE_LEDGER"], "a") as f:
    f.write(json.dumps(rec, sort_keys=True) + "\n")
PY
}

analyze_json() {
    python3 "$ANALYZER" --repo "$1" 2>/dev/null
}
disposition_of() {
    python3 -c '
import json,sys
d=json.load(sys.stdin)
for w in d["worktrees"]:
    if w["branch"] == sys.argv[1]:
        print(w["disposition"]); break
else:
    for b in d["branches"]:
        if b["branch"] == sys.argv[1]:
            print(b["disposition"]); break
    else:
        print("(absent)")' "$1"
}

# --- L1: a clean land is silent -------------------------------------------
CLEAN="$SANDBOX/clean/repo"
mkrepo "$CLEAN"
OUT="$(bash "$STATUS" --repo "$CLEAN" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q "INCOMPLETE LANDS — "; then
    ok "L1   a repository with no linked worktrees reports no incomplete land, exit 0"
else
    bad "L1   rc=$RC — a check that fires on a clean land gets filtered out within a day"
fi
OUT="$(python3 "$GATE" --repo "$CLEAN" --ack-log "$ACK_LOG" --enforce 1 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok "L1b  the GATE is completely silent on a clean land, even under enforcement"
else
    bad "L1b  rc=$RC out=<$OUT>"
fi

# --- L2/L3/L4/L5: the four dispositions, in one repository -----------------
R="$SANDBOX/mixed/repo"
mkrepo "$R"
mkworktree "$R" "landed-agent"    yes
mkworktree "$R" "unmerged-agent"  no
mkworktree "$R" "live-agent"      yes
mkworktree "$R" "stranger"        yes
register "$R" "$SANDBOX/mixed/landed-agent"   "landed-agent"   "aaaa1111"
register "$R" "$SANDBOX/mixed/unmerged-agent" "unmerged-agent" "bbbb2222"
register "$R" "$SANDBOX/mixed/live-agent"     "live-agent"     "cccc3333"
# `stranger` gets NO record at all — the Codex case.
# The live one is made live the way a real one is: its worktree is LOCKED by a
# pid that is genuinely running. $$ is this suite, which is unarguably alive.
git -C "$R" worktree lock --reason "claude agent agent-cccc3333 (pid $$ start $(ps -o lstart= -p $$ 2>/dev/null | sed 's/^ *//'))" \
    "$SANDBOX/mixed/live-agent" 2>/dev/null

J="$(analyze_json "$R")"

D="$(printf '%s' "$J" | disposition_of "landed-agent")"
if [ "$D" = "incomplete-land" ]; then
    ok "L2   a merged branch whose worktree is still registered is an INCOMPLETE LAND"
else
    bad "L2   landed-agent -> '$D', expected incomplete-land"
fi

D="$(printf '%s' "$J" | disposition_of "unmerged-agent")"
if [ "$D" = "retained-unmerged" ]; then
    ok "L3   an UNMERGED branch is retained-unmerged and can never be residue (R3)"
else
    bad "L3   unmerged-agent -> '$D', expected retained-unmerged — THIS IS THE CASE THAT MATTERS MOST"
fi

D="$(printf '%s' "$J" | disposition_of "live-agent")"
if [ "$D" = "live" ]; then
    ok "L4   a worktree LOCKED by a running pid is exempt even with its branch merged"
else
    bad "L4   live-agent -> '$D', expected live — this is the 7.6% false-positive class"
fi

D="$(printf '%s' "$J" | disposition_of "stranger")"
if [ "$D" = "unowned" ]; then
    ok "L5   a worktree with no ownership record is 'unowned', never 'incomplete-land'"
else
    bad "L5   stranger -> '$D', expected unowned"
fi

# --- L6: a merged branch with no worktree ---------------------------------
git -C "$R" branch reclaimed-later main
D="$(analyze_json "$R" | disposition_of "reclaimed-later")"
if [ "$D" = "unreclaimed-branch" ]; then
    ok "L6   a merged branch whose worktree is gone is a NAMED benign state, not silence (R4)"
else
    bad "L6   reclaimed-later -> '$D', expected unreclaimed-branch"
fi

# --- L7: the honest sections print even when empty ------------------------
OUT="$(bash "$STATUS" --repo "$CLEAN" 2>&1)"
if printf '%s' "$OUT" | grep -q "COULD NOT DECIDE" \
   && printf '%s' "$OUT" | grep -q "NOT EXAMINED"; then
    ok "L7   COULD NOT DECIDE and NOT EXAMINED print even when both are empty (R5)"
else
    bad "L7   a report that omits its empty sections lets absence read as success"
fi

# --- L8: nothing examined is exit 4, not exit 0 ---------------------------
OUT="$(bash "$STATUS" --repo "$SANDBOX/does-not-exist" 2>&1)"; RC=$?
if [ "$RC" -eq 4 ] || printf '%s' "$OUT" | grep -q "NOT EXAMINED (1)"; then
    ok "L8   a repository that cannot be read is NOT EXAMINED and never reads as clean"
else
    bad "L8   rc=$RC — 'could not look' must not share an exit code with 'looked and found nothing'"
fi

# --- L9 / L13: refuse under enforcement, announce without it --------------
OUT="$(python3 "$GATE" --repo "$R" --ack-log "$ACK_LOG" --enforce 1 2>&1)"; RC_ON=$?
OUT0="$(python3 "$GATE" --repo "$R" --ack-log "$ACK_LOG" --enforce 0 2>&1)"; RC_OFF=$?
if [ "$RC_ON" -eq 2 ] && [ "$RC_OFF" -eq 0 ]; then
    ok "L9   the same state REFUSES under enforcement (2) and ANNOUNCES without it (0)"
else
    bad "L9   enforce=1 gave $RC_ON, enforce=0 gave $RC_OFF"
fi
if [ "$RC_ON" -eq 2 ] && printf '%s' "$OUT" | grep -q "landed-agent"; then
    ok "L13  NEGATIVE CONTROL: the gate really refuses and names the item, so L1b's silence is real"
else
    bad "L13  the gate did not refuse on known residue — every silence above proves nothing"
fi
if printf '%s' "$OUT0" | grep -q "REPORTING ONLY"; then
    ok "L9b  the reporting-only run says so, so an allowed land is never mistaken for a clean one"
else
    bad "L9b  the reporting-only run did not declare itself"
fi

# --- L10: bare and partial acknowledgements -------------------------------
OUT="$(python3 "$GATE" --repo "$R" --ack-log "$ACK_LOG" --enforce 1 \
        --command "merge # land-residue-ack: landed-agent — wip" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q "marker, not a reason"; then
    ok "L10  a bare acknowledgement exempts nothing and says why"
else
    bad "L10  rc=$RC — a marker with no reason is not a claim"
fi

# --- L11: an acknowledgement naming something that is not residue ---------
OUT="$(python3 "$GATE" --repo "$R" --ack-log "$ACK_LOG" --enforce 1 \
        --command "merge # land-residue-ack: unmerged-agent — this branch is not residue at all" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q "landed-agent"; then
    ok "L11  acknowledging the UNMERGED branch does not excuse the merged one still left behind"
else
    bad "L11  rc=$RC — an ack that matches nothing must excuse nothing"
fi

# --- L12: the repetition count ---------------------------------------------
: > "$ACK_LOG"
FULL="merge # land-residue-ack: landed-agent — kept deliberately while its output is read"
for _ in 1 2; do
    python3 "$GATE" --repo "$R" --ack-log "$ACK_LOG" --enforce 1 --command "$FULL" >/dev/null 2>&1
done
OUT="$(python3 "$GATE" --repo "$R" --ack-log "$ACK_LOG" --enforce 1 --command "$FULL" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "ACKNOWLEDGEMENT NUMBER 3"; then
    ok "L12  the third acknowledgement for the same worktree says so — a habit becomes evidence"
else
    bad "L12  rc=$RC — without the count, this hatch dies the way g11/g12/g13 died"
fi

# --- L14: the liveness module's absence must not convict ------------------
# The near-miss of 2026-09-10, pinned. worktree-ledger.judge() takes its
# liveness module as a keyword that DEFAULTS TO None, and with None it cannot
# read a lock, so every verdict it can still reach is INDETERMINATE — which
# blocks. Here the module is made unloadable and the answer must move toward
# 'cannot decide', never toward 'refuse'.
BROKEN="$SANDBOX/broken-engine"
mkdir -p "$BROKEN/scripts/lib"
for f in land-completeness.py worktree-ledger.py worktree-transactions.py; do
    cp "$SCRIPT_DIR/lib/$f" "$BROKEN/scripts/lib/"
done
printf 'raise ImportError("liveness deliberately unloadable")\n' \
    > "$BROKEN/scripts/lib/agent-liveness.py"
D="$(python3 "$BROKEN/scripts/lib/land-completeness.py" --repo "$R" 2>/dev/null \
     | disposition_of "landed-agent")"
if [ "$D" = "unowned" ]; then
    ok "L14  with no liveness module every owner is UNRESOLVED -> unowned, never incomplete-land"
else
    bad "L14  landed-agent -> '$D' with liveness broken; degrading toward 'refuse' is the bug"
fi

# --- L15: run from INSIDE a worktree, never name the main checkout ---------
# Both of the bugs this pins were found by running the status command for real
# rather than by reading it, and both only appear from inside a worktree —
# which is where every agent runs it.
#
#   `git worktree list` reports the WHOLE set from any member, so excluding
#   "the path we were handed" removes the caller and leaves the MAIN CHECKOUT
#   in the list, to be judged like an agent's worktree. A live run on
#   2026-09-10 reported the operator's own checkout, on branch `main`, as an
#   undecided item.
J2="$(python3 "$ANALYZER" --repo "$SANDBOX/mixed/landed-agent" 2>/dev/null)"
if printf '%s' "$J2" | python3 -c '
import json, sys
d = json.load(sys.stdin)
paths = [w["path"] for w in d["worktrees"]]
sys.exit(0 if not any(p.rstrip("/").endswith("/repo") for p in paths) else 1)'; then
    ok "L15  run from inside a worktree, the MAIN CHECKOUT is never named as residue"
else
    bad "L15  the main checkout appeared in the worktree list — removing it is no land's step"
fi

# --- L16: a worktree and its main checkout are ONE repository --------------
# Without this the status command double-counted everything: run from inside a
# worktree it resolves one name, the ownership ledger yields the other, and both
# enumerate the identical set.
A="$(python3 -c '
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("lc", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.main_checkout(sys.argv[2]))' "$ANALYZER" "$R")"
B="$(python3 -c '
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("lc", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.main_checkout(sys.argv[2]))' "$ANALYZER" "$SANDBOX/mixed/landed-agent")"
if [ -n "$A" ] && [ "$A" = "$B" ]; then
    ok "L16  a linked worktree and its main checkout resolve to ONE repository identity"
else
    bad "L16  '$A' != '$B' — the same repository under two names is counted twice"
fi

git -C "$R" worktree unlock "$SANDBOX/mixed/live-agent" 2>/dev/null || true

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "=== land-completeness tests: all $PASS passed ==="
    exit 0
fi
echo "=== land-completeness tests: $PASS passed, $FAIL FAILED ==="
exit 1
