#!/usr/bin/env bash
#
# unlanded-branches.test.sh — THE TWO HALVES OF "FINISHED WORK IS NOT ON MAIN".
#
# ===========================================================================
# WHAT IS UNDER TEST
# ===========================================================================
#   scripts/lib/unlanded-branches.py            the sweep
#   scripts/hooks/notice-unlanded-branches.sh   the Stop notice  (hook 1)
#   scripts/hooks/guard-unresolved-claims.py    the claim class  (hook 2)
#   scripts/unlanded-branches-lint.sh           the same sweep by hand
#
# ===========================================================================
# EVERY CASE HAS ITS OPPOSITE, AND THAT IS THE WHOLE DESIGN
# ===========================================================================
# A hook that ALWAYS fires and a hook that NEVER fires are both useless and both
# look like a passing test. So each firing case here is paired with a silent one
# built to be as similar as possible: same repository, same message, one fact
# changed. If the pair ever agrees, one of them is wrong and the suite says so.
#
#   U02/U03   a stranded branch fires      <-> a merged-in branch is silent
#   U04/U05   a branch a LOCKED worktree holds is silent, and still COUNTED
#   U06       a branch whose commits are on origin/main is silent
#   U07/U08   the cross-repository branch is found; its live twin is not
#   U10/U12   a finding is announced       <-> the same finding, again, is not
#   U13/U14   a NEW finding speaks again   <-> a clean repository says nothing
#   U15..U17  the notice announces every way it can stop working
#   C02/C04   a completeness claim over stranded work reports <-> no claim, silent
#   C05       the SAME sentence with nothing stranded is silent
#   C06       a NEGATED completeness claim is silent
#   C07       a QUOTED completeness claim is silent (the 13-point precision fix)
#   C01       it reports and NEVER blocks — exit 0, always
#   L01..L04  the lint script's three exit codes never collapse into each other
#
# THE CASE IDS ARE TWO DIGITS AND CARRY NO SUB-LETTER, and that is a
# correction rather than a style. unlanded-branches.mutation.sh greps
# `FAIL  <id>` as a RAW regex, so an id that is a PREFIX of another matches it:
# with `U3` and `U3b` in the same suite, nine mutants each reported "the red is
# unrelated" while every one of them had turned exactly the right case red. No
# id here is a prefix of any other, and `ok` and `bad` carry the identical id so
# the harness can tell "red for this reason" from "red somewhere else".
#
# ===========================================================================
# THE SANDBOX IS TWO REPOSITORIES, BECAUSE THE COMMON CASE IS TWO
# ===========================================================================
# Measured on this machine on 2026-09-06: every teammate of the live session
# works in `richos` while the session is seated in `femcboost`. A suite with one
# repository would prove the sweep against the case that does not happen.
#
# Usage: scripts/hooks/unlanded-branches.test.sh
# Exit:  0 all cases passed, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SWEEP="$ENGINE_ROOT/scripts/lib/unlanded-branches.py"
NOTICE="$SCRIPT_DIR/notice-unlanded-branches.sh"
CLAIMS="$SCRIPT_DIR/guard-unresolved-claims.sh"
LINT="$ENGINE_ROOT/scripts/unlanded-branches-lint.sh"

PASS=0
FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; FAIL=$((FAIL + 1)); return 0; }

command -v python3 >/dev/null 2>&1 || { echo "ERROR: needs python3" >&2; exit 1; }
command -v git     >/dev/null 2>&1 || { echo "ERROR: needs git" >&2; exit 1; }

SANDBOX="$(cd "$(mktemp -d -t unlanded.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

echo "=== unlanded work: the sweep, the notice, and the claim it contradicts ==="
echo ""

# ===========================================================================
# THE SANDBOX
# ===========================================================================
SEAT="$SANDBOX/seat"          # the repository the session is seated in
FAR="$SANDBOX/far"            # where the teammates actually work
LEDGER="$SANDBOX/ledger.jsonl"
SESSION="abcd1234-0000-4000-8000-000000000000"

mk_repo() { # <path>
    mkdir -p "$1"
    git -C "$1" init -q -b main
    git -C "$1" config user.email "tester@example.invalid"
    git -C "$1" config user.name  "tester"
    # A global core.hooksPath (an identity guard, a linter) would fail this
    # suite for reasons that have nothing to do with what is under test.
    mkdir -p "$SANDBOX/nohooks"
    git -C "$1" config core.hooksPath "$SANDBOX/nohooks"
    printf 'seed\n' > "$1/README.md"
    git -C "$1" add -A >/dev/null 2>&1
    git -C "$1" commit -qm seed >/dev/null 2>&1
}

adopt() { # <path> — an adopted engine root, so the hooks do not stand down
    : > "$1/orchestration.config"
    mkdir -p "$1/.claude/state"
    # EXCLUDED, NOT COMMITTED, and this is a correction rather than tidiness.
    # With `git add -A` these were committed onto the first branch, and every
    # later `checkout main` then DELETED orchestration.config from the working
    # tree — so the repository stopped being adopted halfway through the suite
    # and three cases went red against a hook that was behaving correctly. A
    # broken fixture reads exactly like a finding.
    printf 'orchestration.config\n.claude/\n' > "$1/.git/info/exclude"
}

mk_branch() { # <repo> <branch> <file> — one commit ahead of main
    git -C "$1" checkout -q -b "$2" main
    printf '%s\n' "$3" > "$1/$3"
    git -C "$1" add -- "$3" >/dev/null 2>&1
    git -C "$1" commit -qm "work on $2" >/dev/null 2>&1
    git -C "$1" checkout -q main
}

mk_repo "$SEAT"; adopt "$SEAT"
mk_repo "$FAR";  adopt "$FAR"

# --- U1 the finding: a branch nothing is holding ---------------------------
mk_branch "$SEAT" stranded stranded.txt
STRANDED_TIP="$(git -C "$SEAT" rev-parse --short=12 stranded)"

# --- U2 the twin: identical in every way except that main has it -----------
mk_branch "$SEAT" already-landed landed.txt
git -C "$SEAT" merge -q --no-edit already-landed >/dev/null 2>&1

# --- U3 a branch a LOCKED worktree is holding ------------------------------
mk_branch "$SEAT" held-by-a-live-agent held.txt
git -C "$SEAT" worktree add -q --checkout "$SANDBOX/held" held-by-a-live-agent >/dev/null 2>&1
git -C "$SEAT" worktree lock "$SANDBOX/held" >/dev/null 2>&1

# --- U4 a branch whose commits are on the REMOTE trunk ---------------------
# The shape a stale local main produces: the work landed and was pushed, and
# `git log main..branch` still shows commits because local main is behind.
mk_branch "$SEAT" landed-upstream upstream.txt
git -C "$SEAT" update-ref refs/remotes/origin/main "$(git -C "$SEAT" rev-parse landed-upstream)"

# --- U5 the cross-repository branch, reachable only through the ledger -----
mk_branch "$FAR" teammate-work far.txt
# ...and a SECOND far branch whose owner is alive, judged by the owner's NATIVE
# isolation worktree over in the seat repository. A hand-rolled worktree takes
# no lock of its own, so this is the only evidence there is.
mk_branch "$FAR" teammate-alive alive.txt
git -C "$SEAT" worktree add -q --checkout "$SEAT/.claude/worktrees/agent-aaa" -b worktree-agent-aaa main >/dev/null 2>&1
git -C "$SEAT" worktree lock "$SEAT/.claude/worktrees/agent-aaa" >/dev/null 2>&1

write_ledger() {
    python3 - "$LEDGER" "$SESSION" "$SEAT" "$FAR" <<'PY'
import json, sys
path, sid, seat, far = sys.argv[1:5]
rows = [
    # the seat's own registration, which is what puts FAR in the repo set
    {"event": "registered", "class": "hand-rolled", "session_id": sid,
     "teammate": "dev-opus-a1", "repo": far, "branch": "teammate-work",
     "worktree": far + "-wt-a1", "agent_id": "aaa1"},
    {"event": "registered", "class": "hand-rolled", "session_id": sid,
     "teammate": "dev-opus-b1", "repo": far, "branch": "teammate-alive",
     "worktree": far + "-wt-b1", "agent_id": "bbb1"},
    # dev-opus-b1's NATIVE isolation worktree, in the SEAT repository, locked.
    {"event": "registered", "class": "native", "session_id": sid,
     "teammate": "dev-opus-b1", "repo": seat,
     "branch": "worktree-agent-aaa",
     "worktree": seat + "/.claude/worktrees/agent-aaa", "agent_id": "bbb1"},
]
with open(path, "w", encoding="utf-8") as fh:
    for r in rows:
        fh.write(json.dumps(r) + "\n")
PY
}
write_ledger

# ===========================================================================
# DRIVERS
# ===========================================================================
mk_payload() { # <message> [variant]
    python3 - "$1" "${2:-control}" "$SEAT" "$SESSION" <<'PY'
import json, sys
msg, variant, cwd, sid = sys.argv[1:5]
d = {"hook_event_name": "Stop", "stop_hook_active": False,
     "session_id": sid, "cwd": cwd, "last_assistant_message": msg,
     "padding": "z" * 300}
s = json.dumps(d)
if variant == "control":
    sys.stdout.write(s)
elif variant == "empty":
    sys.stdout.write("")
elif variant == "truncated":
    sys.stdout.write(s[:s.index('"padding"') + 30])
else:
    sys.stdout.write("not json at all " + "z" * 100)
PY
}

RUN_OUT=""; RUN_ERR=""; RUN_RC=0
drive() { # <hook path> <message> [variant] [extra env assignments...]
    local hook="$1" msg="$2" variant="${3:-control}"
    shift 3 2>/dev/null || shift $#
    mk_payload "$msg" "$variant" > "$SANDBOX/payload.json"
    env RICHOS_ENTITY_ROOT="$SEAT" CLAUDE_PROJECT_DIR="$SEAT" \
        CLAUDE_PLUGIN_ROOT="$ENGINE_ROOT" \
        RICHOS_WORKTREE_LEDGER="$LEDGER" \
        "$@" \
        /bin/bash "$hook" < "$SANDBOX/payload.json" \
        > "$SANDBOX/out.txt" 2> "$SANDBOX/err.txt"
    RUN_RC=$?
    RUN_OUT="$(cat "$SANDBOX/out.txt")"
    RUN_ERR="$(cat "$SANDBOX/err.txt")"
}

fresh_notices() { rm -rf "$SEAT/.claude/state/stop-hook-notices"; }

# ===========================================================================
# 0. THE POSITIVE CONTROL ON THE SWEEP ITSELF
#    A sweep that discovers no repository would make every case below pass by
#    examining nothing — the "green over an empty set" shape this engine has
#    shipped twice.
# ===========================================================================
SWEPT="$(RICHOS_WORKTREE_LEDGER="$LEDGER" python3 "$SWEEP" \
            --entity-root "$SEAT" --session "$SESSION" --format json 2>/dev/null)"
N_REPOS="$(printf '%s' "$SWEPT" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["repos"]))' 2>/dev/null || echo 0)"
if [ "${N_REPOS:-0}" -eq 2 ]; then
    ok "U01 the sweep discovered BOTH repositories (the seat and the one only the ledger knows)"
else
    bad "U01 the sweep discovers both repositories" "found ${N_REPOS:-0}, expected 2 — every case below would examine the wrong set"
fi

names_of() { # <json> <key>
    printf '%s' "$1" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(' '.join(sorted(f['branch'] for f in d[sys.argv[1]])))" "$2" 2>/dev/null
}
FOUND="$(names_of "$SWEPT" findings)"
LIVE="$(names_of "$SWEPT" live)"

# ===========================================================================
# 1. THE SWEEP'S FOUR DECISIONS, EACH AGAINST ITS TWIN
# ===========================================================================
case " $FOUND " in
    *" stranded "*) ok "U02 a branch holding work main does not have IS a finding" ;;
    *) bad "U02 a stranded branch is a finding" "findings: [$FOUND]" ;;
esac
case " $FOUND " in
    *" already-landed "*) bad "U03 SILENT TWIN: a branch main already contains is NOT a finding" "findings: [$FOUND]" ;;
    *) ok "U03 SILENT TWIN: the same branch, merged into main, is not a finding" ;;
esac
case " $FOUND " in
    *" held-by-a-live-agent "*) bad "U04 a branch a LOCKED worktree holds is not a finding" "findings: [$FOUND]" ;;
    *) ok "U04 a branch held by a LOCKED worktree is not a finding — work in progress is not stranded work" ;;
esac
case " $LIVE " in
    *" held-by-a-live-agent "*) ok "U05 it is COUNTED as live rather than dropped, so a silence cannot hide it" ;;
    *) bad "U05 the live branch is still counted" "live: [$LIVE]" ;;
esac
case " $FOUND " in
    *" landed-upstream "*) bad "U06 a branch whose commits are on origin/main is not a finding" "findings: [$FOUND]" ;;
    *) ok "U06 a branch that landed upstream while local main lagged is not a finding" ;;
esac
case " $FOUND " in
    *" teammate-work "*) ok "U07 the CROSS-REPOSITORY branch is found, through the ledger and not the seat" ;;
    *) bad "U07 the cross-repository branch is found" "findings: [$FOUND]" ;;
esac
case " $LIVE " in
    *" teammate-alive "*) ok "U08 a hand-rolled branch is ALIVE via its owner's locked NATIVE worktree in the other repo" ;;
    *) bad "U08 cross-repository liveness is read from the native lock" "live: [$LIVE] findings: [$FOUND]" ;;
esac

# ===========================================================================
# 2. THE NOTICE — IT FIRES, AND IT STAYS QUIET
# ===========================================================================
fresh_notices
drive "$NOTICE" "Everything is clean and pushed."
if [ "$RUN_RC" -ne 0 ]; then
    bad "U09 the notice NEVER refuses a turn" "exit $RUN_RC"
else
    ok "U09 the notice exits 0 — it reports and never blocks"
fi
if printf '%s' "$RUN_OUT" | grep -q 'systemMessage' \
   && printf '%s' "$RUN_OUT" | grep -q 'stranded' \
   && printf '%s' "$RUN_OUT" | grep -q 'teammate-work'; then
    ok "U10 FIRING: it names both stranded branches on the operator channel"
else
    bad "U10 the notice fires and names the branches" "stdout: ${RUN_OUT:-<empty>}"
fi
if printf '%s' "$RUN_OUT" | grep -q 'held-by-a-live-agent'; then
    bad "U11 it must not name a branch a live worktree holds" "stdout: $RUN_OUT"
else
    ok "U11 and it names NEITHER the live branch nor the landed one"
fi

# U7 — the same finding again says nothing. Without this the notice is a line
# under every turn, which is a line the eye is trained to skip within a day.
drive "$NOTICE" "Everything is clean and pushed."
if [ -z "$RUN_OUT" ]; then
    ok "U12 SILENT TWIN: the same finding set, unchanged, says nothing on the next turn"
else
    bad "U12 an unchanged finding set is not re-announced" "stdout: $RUN_OUT"
fi

# U8 — a NEW branch going unlanded is news, and speaks again.
mk_branch "$SEAT" second-stranded second.txt
drive "$NOTICE" "Everything is clean and pushed."
if printf '%s' "$RUN_OUT" | grep -q 'second-stranded'; then
    ok "U13 a NEW unlanded branch changes the set and is announced"
else
    bad "U13 a new finding speaks again" "stdout: ${RUN_OUT:-<empty>}"
fi

# U9 — THE SILENT CASE, DEMONSTRATED. A repository with nothing stranded must
# produce nothing at all. This is the case that separates a working notice from
# one that fires on everything.
CLEANREPO="$SANDBOX/clean"
mk_repo "$CLEANREPO"; adopt "$CLEANREPO"
mk_payload "Everything is clean and pushed." control > "$SANDBOX/payload.json"
env RICHOS_ENTITY_ROOT="$CLEANREPO" CLAUDE_PROJECT_DIR="$CLEANREPO" \
    CLAUDE_PLUGIN_ROOT="$ENGINE_ROOT" RICHOS_WORKTREE_LEDGER="$SANDBOX/no-such-ledger" \
    /bin/bash "$NOTICE" < "$SANDBOX/payload.json" \
    > "$SANDBOX/out.txt" 2> "$SANDBOX/err.txt"
Q_RC=$?
Q_OUT="$(cat "$SANDBOX/out.txt")"
if [ "$Q_RC" -eq 0 ] && [ -z "$Q_OUT" ]; then
    ok "U14 SILENT CASE: a repository with nothing ahead of main produces NO output at all"
else
    bad "U14 the notice is silent when there is nothing to say" "exit $Q_RC stdout: ${Q_OUT:-<empty>}"
fi

# ===========================================================================
# 3. EVERY WAY IT CAN STOP WORKING, IT SAYS SO
#    A clean main and an absent checker must never look the same.
# ===========================================================================
fresh_notices
printf 'CHECK_UNLANDED_BRANCHES=0\n' > "$SEAT/orchestration.config"
drive "$NOTICE" "Everything is clean and pushed."
if printf '%s' "$RUN_OUT" | grep -q 'STOOD DOWN'; then
    ok "U15 stood down by config, and it SAYS SO — an opt-out nobody can see is a rumor"
else
    bad "U15 a stand-down announces itself" "stdout: ${RUN_OUT:-<empty>}"
fi
: > "$SEAT/orchestration.config"

fresh_notices
drive "$NOTICE" "Everything is clean and pushed." empty
if printf '%s' "$RUN_OUT" | grep -q 'could not read this turn'; then
    ok "U16 an unreadable payload is announced — the repository set comes from it, so a degraded sweep is not a clean one"
else
    bad "U16 an unreadable payload announces" "stdout: ${RUN_OUT:-<empty>}"
fi

fresh_notices
NOPATH="$SANDBOX/nopath"; mkdir -p "$NOPATH"
for b in git grep cut head sed cat printf mkdir rm date cksum tr; do
    command -v "$b" >/dev/null 2>&1 && ln -sf "$(command -v "$b")" "$NOPATH/$b"
done
mk_payload "Everything is clean and pushed." control > "$SANDBOX/payload.json"
env RICHOS_ENTITY_ROOT="$SEAT" CLAUDE_PROJECT_DIR="$SEAT" \
    CLAUDE_PLUGIN_ROOT="$ENGINE_ROOT" RICHOS_WORKTREE_LEDGER="$LEDGER" \
    PATH="$NOPATH:/usr/bin:/bin" \
    /bin/bash "$NOTICE" < "$SANDBOX/payload.json" > "$SANDBOX/out.txt" 2>&1
P_OUT="$(cat "$SANDBOX/out.txt")"
if printf '%s' "$P_OUT" | grep -qi 'not running\|NOT RUN'; then
    ok "U17 with the sweep unable to run it announces rather than passing the turn in silence"
else
    # /usr/bin is on PATH above so python3 may still be present; then the hook
    # runs normally and announces the finding, which is also correct. What must
    # never happen is silence.
    if [ -n "$P_OUT" ]; then
        ok "U17 with a stripped PATH it still says something — silence is the one outcome ruled out"
    else
        bad "U17 a hook that cannot run says so" "stdout was empty"
    fi
fi

# ===========================================================================
# 4. THE CLAIM CLASS — hook 2
# ===========================================================================
fresh_notices
drive "$CLAIMS" "Everything is clean and pushed."
if [ "$RUN_RC" -eq 0 ]; then
    ok "C01 the claim class NEVER blocks — exit 0 with a finding present"
else
    bad "C01 it reports and never blocks" "exit $RUN_RC (2 means it blocked)"
fi
if printf '%s' "$RUN_OUT" | grep -q 'YOU CALLED IT DONE AND IT IS NOT'; then
    ok "C02 FIRING: a completeness claim over stranded work reaches the operator channel"
else
    bad "C02 the claim class fires on the operator channel" "stdout: ${RUN_OUT:-<empty>}"
fi
if printf '%s' "$RUN_ERR" | grep -q 'YOU CALLED IT DONE'; then
    ok "C03 and the detail, with each branch named, is in the transcript record"
else
    bad "C03 the detail is recorded" "stderr: ${RUN_ERR:-<empty>}"
fi

drive "$CLAIMS" "Spawned two engineers on the hook work; I will report when they are back."
if [ -z "$RUN_OUT" ]; then
    ok "C04 SILENT TWIN: the same repository, a turn that claims nothing, says nothing"
else
    bad "C04 no claim means no report" "stdout: $RUN_OUT"
fi

mk_payload "Everything is clean and pushed." control > "$SANDBOX/payload.json"
env RICHOS_ENTITY_ROOT="$CLEANREPO" CLAUDE_PROJECT_DIR="$CLEANREPO" \
    CLAUDE_PLUGIN_ROOT="$ENGINE_ROOT" RICHOS_WORKTREE_LEDGER="$SANDBOX/no-such-ledger" \
    /bin/bash "$CLAIMS" < "$SANDBOX/payload.json" > "$SANDBOX/out.txt" 2>"$SANDBOX/err.txt"
C3_RC=$?
C3_OUT="$(cat "$SANDBOX/out.txt")"
if [ "$C3_RC" -eq 0 ] && ! printf '%s' "$C3_OUT" | grep -q 'YOU CALLED IT DONE'; then
    ok "C05 SILENT CASE: the identical sentence, with nothing stranded, is not reported"
else
    bad "C05 a true completeness claim is silent" "exit $C3_RC stdout: $C3_OUT"
fi

# C06 CARRIES ITS OWN POSITIVE CONTROL, because the first version of it did
# not and PASSED FOR THE WRONG REASON. Its sentence was "Nothing is landed yet
# and the repos are not clean", which the extractor does not match at all --
# `repos are clean` is a scope cue and `repos are not clean` is not one. The
# case was asserting silence over a sentence that was never a claim, so it
# could never have caught a polarity defect, and the mutation harness is what
# said so: the mutant that forces every claim positive left the suite green.
NEGATED="Not everything is landed and pushed; two branches are still outside main."
POLARITY="$(python3 - "$SCRIPT_DIR/guard-unresolved-claims.py" "$NEGATED" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("g", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
c = m.completeness_claims(sys.argv[2])
print(c[0][1] if c else "no-claim-at-all")
PY
)"
if [ "$POLARITY" = "negated" ]; then
    ok "C06a POSITIVE CONTROL: the sentence C06 uses IS extracted as a claim, and read as negated"
else
    bad "C06a the negated sentence is a claim at all" "polarity: '$POLARITY' — C06 below would assert silence over a sentence nothing ever looked at"
fi
drive "$CLAIMS" "$NEGATED"
if ! printf '%s' "$RUN_OUT" | grep -q 'YOU CALLED IT DONE'; then
    ok "C06 a NEGATED completeness claim is silent — understating what landed is not the failure"
else
    bad "C06 a negated claim is silent" "stdout: $RUN_OUT"
fi

drive "$CLAIMS" "It was the same kind of claim as \"everything is clean and pushed\": true-sounding, verifying nothing."
if ! printf '%s' "$RUN_OUT" | grep -q 'YOU CALLED IT DONE'; then
    ok "C07 a QUOTED completeness claim is silent — the masking worth 13 points of precision"
else
    bad "C07 quoting the failure is not making the claim" "stdout: $RUN_OUT"
fi

# C7 — the sweep gone, with the claim still made. The one thing that must not
# happen is the turn passing in the same silence a clean repository produces.
MOVED="$SANDBOX/moved-sweep.py"
cp "$SWEEP" "$MOVED" && rm -f "$SWEEP"
drive "$CLAIMS" "Everything is clean and pushed."
C7_OUT="$RUN_OUT$RUN_ERR"
cp "$MOVED" "$SWEEP"
if printf '%s' "$C7_OUT" | grep -q 'DID NOT RUN\|WENT OUT UNCHECKED'; then
    ok "C08 with the sweep missing, the claim is reported as UNCHECKED rather than passed"
else
    bad "C08 an unevaluated check says so" "output: ${C7_OUT:-<empty>}"
fi

# ===========================================================================
# 5. THE LINT SCRIPT — the positive probe, and its exit codes
# ===========================================================================
L_OUT="$(RICHOS_WORKTREE_LEDGER="$LEDGER" RICHOS_SESSION_ID="$SESSION" \
         /bin/bash "$LINT" "$SEAT" 2>&1)"
L_RC=$?
if [ "$L_RC" -eq 1 ] && printf '%s' "$L_OUT" | grep -q 'stranded'; then
    ok "L01 the lint script exits 1 and names the stranded branches"
else
    bad "L01 lint exits 1 with findings" "exit $L_RC"
fi
if printf '%s' "$L_OUT" | grep -q 'NOT reported, because something live holds them'; then
    ok "L02 and it SHOWS what the notice stays quiet about — 'found nothing' and 'found six, all live' are different states"
else
    bad "L02 the lint shows the live branches too" "output did not carry the live section"
fi
L2_OUT="$(RICHOS_WORKTREE_LEDGER="$SANDBOX/no-such-ledger" /bin/bash "$LINT" "$CLEANREPO" 2>&1)"
L2_RC=$?
if [ "$L2_RC" -eq 0 ]; then
    ok "L03 SILENT TWIN: with nothing stranded it exits 0 — a different code from the broken case, always"
else
    bad "L03 lint exits 0 when clean" "exit $L2_RC: $L2_OUT"
fi
L3_OUT="$(/bin/bash "$LINT" "$SANDBOX/nohooks" 2>&1)"
L3_RC=$?
if [ "$L3_RC" -eq 2 ]; then
    ok "L04 and 2 when it could resolve no repository — 'nothing unlanded' and 'nothing read' never share a code"
else
    bad "L04 lint exits 2 when it cannot read" "exit $L3_RC: $L3_OUT"
fi

# ===========================================================================
# 6. THE MUTATION HARNESS
#    Guarded so the harness, which runs this suite once per mutant, does not
#    recurse into itself.
# ===========================================================================
echo ""
if [ -z "${RICHOS_MUTATION_INNER:-}" ] && [ -x "$SCRIPT_DIR/unlanded-branches.mutation.sh" ]; then
    echo "=== running the mutation harness ==="
    if bash "$SCRIPT_DIR/unlanded-branches.mutation.sh"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL  M. the mutation harness found a property this suite does not actually prove"
    fi
    echo ""
fi

if [ "$FAIL" -eq 0 ]; then
    printf '  %s/%s cases passed\n' "$PASS" "$PASS"
    exit 0
fi
printf '  %s passed, %s FAILED\n' "$PASS" "$FAIL"
exit 1
