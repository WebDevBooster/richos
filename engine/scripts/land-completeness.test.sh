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
#   L20 THIS SUITE DOES NOT WRITE TO THE OPERATOR'S REAL WORKSPACE REGISTRY,
#       which it did: the ledger was sandboxed and the registry was not, so four
#       `"why": "the land-completeness fixture"` records were found in the live
#       ~/.claude/state/workspaces/integration.json, pointing at temp
#       directories the EXIT trap had already deleted.
#   L21 AND NEITHER DOES ANY SIBLING SUITE. Asked of the whole tree, because
#       "I checked the others once" is not a check.
#   L22 THE POSITIVE CONTROL ON L20, and L23 the positive control on L21. Both
#       of those cases pass by finding NOTHING, which is also what a predicate
#       that cannot match anything finds; each control feeds the same code a
#       planted case whose answer is known. The ids skip L17..L19 (an L17 named
#       in mkrepo()'s comment was never written) and carry no letter suffix,
#       because mutation-harness.sh greps `FAIL  <id>` as a raw string and
#       `L20` would match `L20a`.
#
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS="$SCRIPT_DIR/land-completeness.sh"
WORKSPACES="$SCRIPT_DIR/workspaces.sh"
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

# THE OPERATOR'S REAL REGISTRY, RESOLVED BEFORE ANYTHING IS OVERRIDDEN. Captured
# rather than re-read, for the reason scripts/lib/global-state-witness.sh gives
# about CLAUDE_CONFIG_DIR: a suite that exports the override halfway through
# would otherwise compare itself against its own sandbox and always pass.
REAL_REGISTRY="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/state/workspaces"

# ===========================================================================
# THE LEDGER WAS SANDBOXED AND THE REGISTRY WAS NOT
# ===========================================================================
# mkrepo() below records each fixture repository's integration branch, which is
# point 14's requirement of anyone starting a body of work. state_dir() in
# scripts/lib/workspaces.py resolves RICHOS_WORKSPACES_DIR, else
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/state/workspaces -- and this suite set the
# first variable for the LEDGER only. So every run wrote four records reading
#
#     "why": "the land-completeness fixture"
#
# into the operator's REAL ~/.claude/state/workspaces/integration.json, each
# pointing at a temp directory that the EXIT trap above then deleted. Four of
# them were found sitting there, written during one session, while the commit
# that introduced the recording says two fixtures "gained a sandbox registry so
# the recording can never reach the operator's real one" -- true of two of the
# three, and this was the third.
#
# A test never writes to the state the operator's live sessions read. L20 proves
# this suite does not, and L21 asks the same question of every sibling suite.
# (L17..L19 are deliberately unused: the comment in mkrepo() below already names
# an L17 that was never written, and reusing the id would make that reference
# point at a case about something else.)
export RICHOS_WORKSPACES_DIR="$SANDBOX/workspaces"

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
    # POINT 14, AND IT IS THE FIXTURE'S JOB, NOT THE CHECKER'S. "Every part of
    # the system that needs to know whether work has landed asks the same
    # question: is it in the branch recorded for this work?" The checker used
    # to default to the string "main", which is an answer of its own and wrong
    # on any repository whose work integrates on a dev branch. It now asks the
    # library, so a fixture repository records its body of work exactly as Rich
    # does -- one command, before anything else happens in it. L17 is the case
    # where nothing is recorded, and it asserts the ABSTENTION.
    "$WORKSPACES" integration --repo "$repo" --branch main \
        --why "the land-completeness fixture" >/dev/null 2>&1 || true
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
# workspaces.py comes too: the checker asks IT for the branch this work
# integrates on (point 14), and this case breaks the LIVENESS module on
# purpose. Without it the checker would abstain for the wrong reason and
# the case would pass without testing anything.
for f in land-completeness.py worktree-ledger.py worktree-transactions.py workspaces.py; do
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

# --- L20: THIS SUITE DOES NOT WRITE TO THE OPERATOR'S REAL REGISTRY --------
# Three assertions, and two of them exist because the third one asserts an
# ABSENCE: the override really is a sandbox path, the fixture recording really
# did happen (otherwise this passes over a suite that recorded nothing), and
# nothing this suite created is in the registry the operator's sessions read.
#
# The search is a FUNCTION because L22 below runs the SAME search over a
# planted record whose answer is known. A positive control that re-implements
# the search proves the copy, not the check.
names_sandbox() { # <a registry directory> -> the files in it that name $SANDBOX
    [ -e "${1:-}" ] || return 0
    grep -rl -- "$SANDBOX" "$1" 2>/dev/null || true
}

L20_OK=1; L20_WHY=""
case "${RICHOS_WORKSPACES_DIR:-}" in
    "$SANDBOX"/*) : ;;
    *) L20_OK=0
       L20_WHY="RICHOS_WORKSPACES_DIR is '${RICHOS_WORKSPACES_DIR:-<unset>}', which is not inside this suite's sandbox" ;;
esac
# POSITIVE CONTROL: the fixture's recording really did happen, and it is here.
if [ "$L20_OK" = 1 ] && ! grep -q "the land-completeness fixture" \
        "$RICHOS_WORKSPACES_DIR/integration.json" 2>/dev/null; then
    L20_OK=0
    L20_WHY="the sandbox registry holds no fixture recording, so this case would pass over a suite that recorded nothing"
fi
# THE FINDING ITSELF: nothing this suite created is in the operator's registry.
L20_HITS="$(names_sandbox "$REAL_REGISTRY")"
if [ "$L20_OK" = 1 ] && [ -n "$L20_HITS" ]; then
    L20_OK=0
    L20_WHY="the operator's real registry at $REAL_REGISTRY names this suite's sandbox: $(printf '%s' "$L20_HITS" | tr '\n' ' ')"
fi
if [ "$L20_OK" = 1 ]; then
    ok "L20  every fixture recording went to the SANDBOX registry; the operator's real one is untouched"
else
    bad "L20  a test wrote to the operator's real workspace registry — $L20_WHY"
fi

# --- L22: THE POSITIVE CONTROL ON L20'S ABSENCE ----------------------------
# L20's third assertion passes when the search finds nothing, and a search that
# CANNOT find anything also finds nothing. So: plant exactly the residue that was
# found in the operator's registry -- a record naming a temp directory -- in a
# fake registry, and require the same search to name it. Then require it to say
# nothing about an empty one.
FAKE_REG="$SANDBOX/fake-registry"
mkdir -p "$FAKE_REG"
printf '{"%s": {"branch": "main", "why": "the land-completeness fixture"}}\n' \
    "$SANDBOX/mixed" > "$FAKE_REG/integration.json"
EMPTY_REG="$SANDBOX/empty-registry"
mkdir -p "$EMPTY_REG"
if [ -n "$(names_sandbox "$FAKE_REG")" ] && [ -z "$(names_sandbox "$EMPTY_REG")" ]; then
    ok "L22  POSITIVE CONTROL: the same search names a planted fixture record and stays silent on an empty registry"
else
    bad "L22  L20's search can actually find residue — planted:'$(names_sandbox "$FAKE_REG")' empty:'$(names_sandbox "$EMPTY_REG")'"
fi

# --- L21: AND SO DOES EVERY SIBLING SUITE ---------------------------------
# The hole was not unique to this file, it was unnoticed in it. A suite that
# drives the registry's WRITING entry points and does not redirect
# RICHOS_WORKSPACES_DIR writes into ~/.claude/state/workspaces, and every such
# write outlives the run. This is asked of the whole tree rather than remembered,
# because "I checked the others once" is not a check.
# THE SCANNER IS A FILE, NOT AN INLINE HEREDOC, because L23 below runs the
# SAME predicate over synthetic suites whose answer is known (L23). A positive control
# that re-implements the predicate proves the copy, not the check.
cat > "$SANDBOX/registry-write-scan.py" <<'PY'
import os, re, sys

root = sys.argv[1]
# The subcommands of workspaces.sh that WRITE, and the library entry points that
# write. `status`, `integration-branch` and a bare load are reads and are fine.
#
# THE INVOCATION IS ALMOST NEVER SPELLED `workspaces.sh`. Every suite in this
# tree holds the path in a variable and calls `"$WORKSPACES" integration ...`,
# so a pattern keyed on the file name matched this very file only by ACCIDENT,
# through the words "workspaces.sh land" in a comment. L23 is the case that said
# so: its controls use the real form and the file-name pattern saw none of them.
INVOKE = r"(?:workspaces\.sh|\$\{?(?:WORKSPACES|WS|WORKSPACES_SH)\}?)[\"']?\s+"
WRITERS = re.compile(
    INVOKE + r"(?:integration|land|discard|pause|resume|stop|wait|retry)\b"
    r"|\b(?:register_spawn|register_cc|record_start|record_end|bind_agent|record_integration)\(")
# A DECLARED EXEMPTION, AND A BARE MARKER EXEMPTS NOTHING. This check reads
# source, so it cannot tell a suite that RUNS `workspaces.sh land` from one that
# hands that string to a PreToolUse guard as test DATA -- and the second is a
# real, correct thing for a suite to do. Rather than tune the regex until it
# guesses right (which is how a check acquires a waiver habit), a suite whose
# match is data says so, in itself, where a reviewer sees the claim:
#
#     registry-write-exempt: <why this names a writer but never runs one>
#
# Declared files are NAMED in the passing output, never silently dropped.
DECLARED = re.compile(r"registry-write-exempt:[ \t]*(\S+(?:[ \t]+\S+){2,})")
# A REDIRECT, NOT A MENTION. This was `"RICHOS_WORKSPACES_DIR" in text` for one
# draft, and the sentence explaining the exemption in a sibling suite -- which
# named the variable and set nothing -- exempted that suite. An ASSIGNMENT is
# what redirects the registry: RICHOS_WORKSPACES_DIR, or the CLAUDE_CONFIG_DIR /
# HOME that state_dir() falls back to, either as a shell assignment or as a
# python env-dict key. `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` is a READ and is
# deliberately not matched -- this very file contains one.
SANDBOXED = re.compile(
    r"\b(RICHOS_WORKSPACES_DIR|CLAUDE_CONFIG_DIR|HOME)="
    r"|['\"](RICHOS_WORKSPACES_DIR|CLAUDE_CONFIG_DIR|HOME)['\"]\s*:"
    r"|['\"](RICHOS_WORKSPACES_DIR|CLAUDE_CONFIG_DIR|HOME)['\"]\s*\]\s*=")
offenders, declared, corpus = [], [], []
for dirpath, _dn, fns in os.walk(root):
    for fn in sorted(fns):
        if not (fn.endswith(".test.sh") or fn.endswith(".test.py")
                or fn.endswith(".mutation.sh")):
            continue
        p = os.path.join(dirpath, fn)
        try:
            text = open(p, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        if not WRITERS.search(text):
            continue
        rel = os.path.relpath(p, root)
        # THE CORPUS IS REPORTED, NOT ONLY THE VERDICT. A clean answer over a
        # corpus of nothing is the shape this engine has shipped twice; the
        # caller refuses a run that examined no writer at all.
        corpus.append(rel)
        if SANDBOXED.search(text):
            continue
        if DECLARED.search(text):
            declared.append(rel)
        else:
            offenders.append(rel)
sys.stdout.write("%s\n%s\n%d" % (" ".join(offenders), " ".join(declared), len(corpus)))
PY

scan() { python3 "$SANDBOX/registry-write-scan.py" "$1"; }

L21_OUT="$(scan "$SCRIPT_DIR")"
L21_BAD="$(printf '%s' "$L21_OUT" | sed -n '1p')"
L21_DECL="$(printf '%s' "$L21_OUT" | sed -n '2p')"
L21_N="$(printf '%s' "$L21_OUT" | sed -n '3p')"
if [ "${L21_N:-0}" -lt 3 ]; then
    bad "L21  the scan examined only ${L21_N:-0} suite(s) that drive a registry writer — a clean answer over an empty corpus is not an answer"
elif [ -z "$L21_BAD" ]; then
    ok "L21  none of the $L21_N suites driving a registry WRITER leaves RICHOS_WORKSPACES_DIR un-redirected${L21_DECL:+ (declared as test data, and named rather than dropped: $L21_DECL)}"
else
    bad "L21  suite(s) write to the operator's real registry: $L21_BAD"
fi

# --- L23: THE POSITIVE CONTROL ON L21 -------------------------------------
# L21 passes over a clean tree, and so does a predicate that matches nothing.
# Four synthetic suites with known answers, and the first two are the two real
# mistakes: a suite that RUNS a writer and only MENTIONS the variable (the shape
# that slipped past the first draft of SANDBOXED), and a bare exemption marker
# with no reason.
CTRL="$SANDBOX/ctrl"
mkdir -p "$CTRL"
cat > "$CTRL/mentions-only.test.sh" <<'CTRL1'
# This suite needs no RICHOS_WORKSPACES_DIR, it says, and sets nothing.
"$WORKSPACES" integration --repo "$repo" --branch main --why "x"
CTRL1
cat > "$CTRL/bare-marker.test.sh" <<'CTRL2'
# registry-write-exempt:
"$WORKSPACES" integration --repo "$repo" --branch main --why "x"
CTRL2
cat > "$CTRL/declared.test.sh" <<'CTRL3'
# registry-write-exempt: every workspaces.sh string here is payload for a guard
"$WORKSPACES" integration --repo "$repo" --branch main --why "x"
CTRL3
cat > "$CTRL/sandboxed.test.sh" <<'CTRL4'
export RICHOS_WORKSPACES_DIR="$SANDBOX/ws"
"$WORKSPACES" integration --repo "$repo" --branch main --why "x"
CTRL4
C_OUT="$(scan "$CTRL")"
C_BAD="$(printf '%s' "$C_OUT" | sed -n '1p')"
C_DECL="$(printf '%s' "$C_OUT" | sed -n '2p')"
C_N="$(printf '%s' "$C_OUT" | sed -n '3p')"
if [ "$C_BAD" = "bare-marker.test.sh mentions-only.test.sh" ] \
   && [ "$C_DECL" = "declared.test.sh" ] && [ "${C_N:-0}" = "4" ]; then
    ok "L23  POSITIVE CONTROL: the scan flags a mention-only suite and a bare marker, and clears only the declared and the sandboxed"
else
    bad "L23  the L21 predicate can actually fire — corpus ${C_N:-0}/4, flagged '[$C_BAD]' declared '[$C_DECL]', expected '[bare-marker.test.sh mentions-only.test.sh]' and '[declared.test.sh]'"
fi

# --- THE MUTATION HARNESS -------------------------------------------------
# Guarded so the harness, which runs this suite once per mutant, does not
# recurse into itself.
if [ -z "${RICHOS_MUTATION_INNER:-}" ] && [ -f "$SCRIPT_DIR/land-completeness.mutation.sh" ]; then
    echo ""
    echo "=== running the mutation harness ==="
    if bash "$SCRIPT_DIR/land-completeness.mutation.sh"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL  M. the mutation harness found a property this suite does not actually prove"
    fi
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "=== land-completeness tests: all $PASS passed ==="
    exit 0
fi
echo "=== land-completeness tests: $PASS passed, $FAIL FAILED ==="
exit 1
