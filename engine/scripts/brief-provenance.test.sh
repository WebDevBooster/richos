#!/usr/bin/env bash
#
# brief-provenance.test.sh — the brief provenance annotator, proven by execution.
#
# EVERY CASE RUNS AGAINST A SYNTHETIC BRIEF built in a sandbox, never against a real payload.
# The same reason hardware-choice-check.test.sh gives: this file proves the MECHANISM, and the
# RATE on real briefs is a corpus measurement reported separately, in
# docs/verification/brief-provenance-2026-09-14.md. Scoring a check against the cases it was
# written from is how a check gets a number it did not earn.
#
# The three defects this exists for are the ones the brief that spawned `zach-opus-n3` shipped
# (type W, richos-hq docs/verification/lifecycle-failure-record-2026-09-13.md §10g). P1, P2 and
# P3 are those three, reduced to their shape.
#
# WHAT IS PROVEN:
#
#   P1   AN UNSOURCED NARRATIVE with a count is caught — "two workspaces were still present;
#        `workspaces.sh` refused to reap them". The first of the three real defects.
#   P2   A COUNT IS NOT SETTLED BY ONE QUOTED INSTANCE. A brief quoting the guard's output once
#        and then saying "twice" is still flagged on the count. This is exactly how "twice"
#        (the transcript shows three) survived a brief that looked sourced.
#   P3   A PRESCRIPTION RESTING ON AN UNSOURCED ACCOUNT is caught — "so the existing reap path
#        in `workspaces.sh` can take it". The defect the record calls the worst of them,
#        because it aims the engineer's design.
#   P4   A PRESCRIPTION THAT NAMES NO CODE ENTITY is NOT caught, and the test says so out loud.
#        "Do not build a second reaper" is formally identical to a legitimate constraint. A
#        known miss that is asserted here cannot quietly become a claim of coverage.
#   P5   THE SAME CLAIM WITH ITS COMMAND is SILENT. The negative half of P1 — without it, a
#        check that flags everything would pass P1.
#   P6   A count with a re-derive instruction in the same block is SILENT ("21 other sites …
#        Re-derive the list yourself"), the shape a good brief in this project actually uses.
#   P7   `unverified:` anywhere in the block silences it. The rule's own escape hatch, honored.
#   P8   A FABRICATED QUOTATION is caught against the file it is attributed to. THE POSITIVE
#        PROBE for check 1: on the real corpus that check fires on nothing, and a check that
#        never fires is indistinguishable from a broken one until something makes it fire.
#   P9   A TRUE quotation of the same file is SILENT — including one the author re-bolded, which
#        the first draft flagged because it compared the brief's markdown against the source's.
#  P10   A RESTATEMENT of a numbered point ("Point 7: both endings delete") is caught, while
#        REFERRING to the point ("read point 7 of <path>") is silent. Referring is what a brief
#        should do; restating is the surface that distorted point 4.
#  P11   A CLEAN BRIEF produces NO annotation and the payload is returned BYTE-IDENTICAL. The
#        property that keeps this from being a tax on every spawn.
#  P12   A COUNT INSIDE SOMEBODY ELSE'S QUOTED WORDS is not the author's claim and is silent.
#  P13   The stock instruction sections are not read as claims, so "21-181 s, exit 3" and the
#        `ceo-todos-deferred:` marker do not put an identical row on every brief ever written.
#  P15   A DURATION is not a COUNT. Found on the real corpus, not invented: "which had been
#        main three hours earlier" put a row on a brief that had done nothing wrong. A count
#        of the same shape ("three commits") still is one.
#  Y1    REACHABILITY REPORTED AS AN ACT is caught. `git branch --no-merged` returns one
#        branch; the sentence says "fully merged into main". The instance the CEO found.
#  Y2    --is-ancestor USED TO SINGLE OUT ONE MERGE is caught. Exit 0 is true of every
#        later merge, so it identifies none of them.
#  Y3    A COUNT NAMED BY A FILTER ITS SELECTOR NEVER APPLIED is caught. No actor appears
#        anywhere in it, which is why an actor detector alone would not do.
#  Y4    A MEASUREMENT REPORTED AS WHOSE MOVE IT IS is caught - 79 for the lead, called
#        waiting on him.
#  Y5    THE SAME VERB WITH A COMMAND THAT DOES RECORD THE ACT IS SILENT. `git reflog`
#        names the merge. Without this, the check flags the one document that got this
#        right, which is how a report becomes wallpaper.
#  Y6    THE CORRECT WORD FOR THE SAME MEASUREMENT IS SILENT ("reachable from main").
#  Y7    A COUNT WHOSE SELECTOR DOES FILTER ON ITS NAME IS SILENT.
#  Y8    A SPECIFICATION IS NOT A REPORT ("must be reconciled as landed"). Most of this
#        corpus is specifications.
#  Y9    A CITED COMMIT IS EVIDENCE OF AN ACT, so "deleted at `3ddc05a3`" is silent.
#  Y10   A DEFINITION AND AN INDIRECT QUESTION are not claims of authorization.
#  Y11   A KNOWN FALSE POSITIVE, asserted out loud: a sentence ABOUT these verbs is
#        flagged for containing them. Mention versus use is not decidable here, and a
#        file that quietly passed this would claim a precision it does not have.
#  Y12   CAPABILITY ROWS CARRY THEIR OWN INSTRUCTION. Under check 3's heading they would
#        tell the agent to re-derive the number - which CONFIRMS the sentence, and is
#        exactly how all four instances survived.
#  P14   The annotation is APPENDED and the brief is otherwise untouched — nothing is rewritten,
#        reordered or removed. What the lead wrote is what the agent reads, plus a section.
#
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/brief-provenance.py"

PASS=0; FAIL=0
SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/brief-provenance-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s -- %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }

[ -f "$CHECK" ] || { echo "FATAL: missing $CHECK" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

echo "brief-provenance.test.sh"
echo "  sandbox: $SANDBOX"
echo

run() { python3 "$CHECK" "$SANDBOX/brief.md" --repo "$SANDBOX" 2>&1; }

# A case FLAGS when the report names the phrase; it is SILENT when it does not.
flags()  { # <case> <phrase>
  if run | grep -qF "$2"; then ok "$1"; else
    printf '  FAIL  %s\n' "$1"; printf '        expected a finding naming: %s\n' "$2"
    run | sed 's/^/          /'; FAIL=$((FAIL + 1)); fi
}
silent() { # <case> <phrase-that-must-not-appear>
  if run | grep -qF "$2"; then
    printf '  FAIL  %s\n' "$1"; printf '        must NOT have flagged: %s\n' "$2"
    run | sed 's/^/          /'; FAIL=$((FAIL + 1))
  else ok "$1"; fi
}

# --------------------------------------------------------------------------------
# The source document every quotation case is checked against.
# --------------------------------------------------------------------------------
mkdir -p "$SANDBOX/docs/plans"
cat > "$SANDBOX/docs/plans/spec.md" <<'SPEC'
4. **Landed means the workspace AND the branch are deleted — automatically, with nothing left
   undecided.** Finished garbage is cleaned up without anyone asking for it.

7. **Finished work ends in exactly one of two ways — landed or discarded. Both delete.**

11. **"Finished" means the agent's run has ended and Rich did not pause it.** That covers every
    ending: it handed in its work, crashed, was cut off by a limit, or was stopped.
SPEC

# --------------------------------------------------------------------------------
# P1 / P5 — an unsourced narrative, and the same narrative with its command
# --------------------------------------------------------------------------------
cat > "$SANDBOX/brief.md" <<'B'
## The defect

Observed by the CEO on 2026-09-13: two workspaces from agents he stopped were still present;
`workspaces.sh` refused to reap them because they were never marked finished.
B
flags "P1   unsourced narrative with a count is caught" "two workspaces from agents"

cat > "$SANDBOX/brief.md" <<'B'
## The defect

Two workspaces from agents he stopped are still present, and `workspaces.sh` refuses them.
Reproduce it:

    workspaces.sh status --all
    zach-opus-n1   present   not finished
    zach-opus-n2   present   not finished
B
silent "P5   the same claim WITH its command is silent" "Two workspaces from agents"

# --------------------------------------------------------------------------------
# P2 — a count is not settled by one quoted instance
# --------------------------------------------------------------------------------
cat > "$SANDBOX/brief.md" <<'B'
## The signal

The signal demonstrably exists. Twice in session `b7d89f44` tonight, `guard-workspace-gate.sh`
blocked a turn with: *"the platform recorded the end of its run (SubagentStop at
2026-09-13T23:50:04Z)"*.
B
flags "P2   a count is not settled by one quoted instance" "Twice in session"

# --------------------------------------------------------------------------------
# P3 / P4 — the prescription, and the prescription nothing can catch
# --------------------------------------------------------------------------------
cat > "$SANDBOX/brief.md" <<'B'
## Then fix it

Make every ending mark the agent finished, automatically, so the existing reap path in
`workspaces.sh` can take it.
B
flags "P3   a prescription resting on an unsourced account is caught" "existing reap path"

cat > "$SANDBOX/brief.md" <<'B'
## Then fix it

Do not build a second reaper and do not add a liveness check.
B
silent "P4   a prescription naming no code entity is a KNOWN MISS, asserted here" \
       "Do not build a second reaper"

# --------------------------------------------------------------------------------
# P6 / P7 — the marked forms that already work, honored
# --------------------------------------------------------------------------------
cat > "$SANDBOX/brief.md" <<'B'
## Context

The same shape remains at 21 other sites in that file. A prior pass graded them. Re-derive the
list yourself rather than trusting these line numbers.
B
silent "P6   a count with a re-derive instruction in the block is silent" "21 other sites"

cat > "$SANDBOX/brief.md" <<'B'
## Context

unverified: 21 other sites carry the same shape; a grep for the pattern would settle it.
B
silent "P7   'unverified:' in the block silences it" "21 other sites"

# --------------------------------------------------------------------------------
# P8 / P9 — the quotation check, both halves
# --------------------------------------------------------------------------------
cat > "$SANDBOX/brief.md" <<'B'
## The spec

Point 11 of `docs/plans/spec.md`, verbatim:

> **"Finished" means the agent's run has ended and Rich did not pause it.** That covers every
> ending: it handed in its work, crashed, was cut off by a limit, or was stopped, or was reaped
> by the session-end sweep without any signal at all.
B
if python3 "$CHECK" "$SANDBOX/brief.md" --repo "$SANDBOX" --json \
      | grep -q '"check": "quotation"' \
   && python3 "$CHECK" "$SANDBOX/brief.md" --repo "$SANDBOX" --json | grep -q "reaped"; then
  ok "P8   a FABRICATED quotation is caught against the file named"
else
  printf '  FAIL  %s\n' "P8   a FABRICATED quotation is caught against the file named"
  python3 "$CHECK" "$SANDBOX/brief.md" --repo "$SANDBOX" --json | sed 's/^/          /'
  FAIL=$((FAIL + 1))
fi

cat > "$SANDBOX/brief.md" <<'B'
## The spec

Point 11 of `docs/plans/spec.md`, verbatim:

> **"Finished" means the agent's run has ended and Rich did not pause it.** That covers every
> ending: it handed in its work, crashed, **was cut off by a limit**, or was stopped.
B
silent "P9   a TRUE quotation, re-bolded by the author, is silent" "is NOT in that file"

# --------------------------------------------------------------------------------
# P10 — restating a point versus pointing at it
# --------------------------------------------------------------------------------
cat > "$SANDBOX/brief.md" <<'B'
## The spec

Point 7 of `docs/plans/spec.md`: both endings delete, so a stopped agent's workspace goes.
B
flags "P10a a RESTATEMENT of a numbered point is caught" "Point 7"

cat > "$SANDBOX/brief.md" <<'B'
## The spec

Read points 4, 7 and 11 of `docs/plans/spec.md` in full before you start.
B
silent "P10b REFERRING to a numbered point is silent" "restates"

# --------------------------------------------------------------------------------
# P11 / P13 / P14 — a clean brief, the stock sections, and append-only
# --------------------------------------------------------------------------------
cat > "$SANDBOX/brief.md" <<'B'
cross-repo-worktree: /Users/alex/ab/richos-wt/example-opus-a1

ceo-todos-deferred: the CEO is live in this session on CI being red; this is one of the three
red shards, not his prepared-question list.

## The failure

    FAIL  L21  suite(s) write to the operator's real registry: lib/containers.test.py

Read that output, reproduce it locally, and say which of the three kinds it is.

## Completion criterion — observable, not internal

1. Scoped runs only. If you need `contract-integrity.test.sh`, always `--only <the sections you
   touched>` — 21-181 s, exit 3 is success. Running it any other way is Rich's job at land time.
2. Atomic commits; each stands alone.

## Rules

Work only in your worktree, on your branch. Never merge to main — Rich lands. Report worktree
path, branch and commit SHAs oldest-first as your final step.
B
if [ "$(run)" = "  provenance:  nothing asserted without a source" ]; then
  ok "P11  a clean brief produces NO finding"
else
  printf '  FAIL  %s\n' "P11  a clean brief produces NO finding"; run | sed 's/^/          /'
  FAIL=$((FAIL + 1))
fi
silent "P13a the stock instruction sections are not read as claims" "21-181"
silent "P13b the ceo-todos marker line is not read as a claim"      "red shards"

if diff -q "$SANDBOX/brief.md" <(python3 "$CHECK" "$SANDBOX/brief.md" --annotate --repo "$SANDBOX") \
      >/dev/null 2>&1; then
  ok "P14a a clean brief is returned BYTE-IDENTICAL"
else
  printf '  FAIL  %s\n' "P14a a clean brief is returned BYTE-IDENTICAL"; FAIL=$((FAIL + 1))
fi

# --------------------------------------------------------------------------------
# P12 — a count inside somebody else's quoted words
# --------------------------------------------------------------------------------
cat > "$SANDBOX/brief.md" <<'B'
## Why

**CEO CONSTRAINT, VERBATIM:** *"Local richos main is two commits behind and it has been broken
twice this week already."*
B
silent "P12  a count inside quoted words is not the author's claim" "CEO CONSTRAINT"

# --------------------------------------------------------------------------------
# P15 — a duration is not a count. Found on the real corpus: "which had been main
# three hours earlier" put a row on a brief that had done nothing wrong.
# --------------------------------------------------------------------------------
cat > "$SANDBOX/brief.md" <<'B'
## Why

For the 23:41:29 entry the direction is unambiguous: it pointed at a commit which had been
main three hours earlier, and stayed there for two days.
B
silent "P15a a DURATION is not a count" "three hours earlier"

cat > "$SANDBOX/brief.md" <<'B'
## Why

Main had just fast-forwarded, and three commits went in behind it.
B
flags "P15b a COUNT of the same shape still is" "three commits"

# --------------------------------------------------------------------------------
# P14b — annotation is appended, original bytes preserved
# --------------------------------------------------------------------------------
cat > "$SANDBOX/brief.md" <<'B'
## The defect

Observed by the CEO: two workspaces were still present and `workspaces.sh` refused them.
B
OUT="$(python3 "$CHECK" "$SANDBOX/brief.md" --annotate --repo "$SANDBOX")"
ORIG="$(cat "$SANDBOX/brief.md")"
case "$OUT" in
  "$ORIG"*) ok "P14b the original brief is a PREFIX of the annotated one (append-only)" ;;
  *) printf '  FAIL  %s\n' "P14b the original brief is a PREFIX of the annotated one"
     FAIL=$((FAIL + 1)) ;;
esac
if printf '%s' "$OUT" | grep -q "Provenance of this brief"; then
  ok "P14c the appended section reaches the agent"
else
  printf '  FAIL  %s\n' "P14c the appended section reaches the agent"; FAIL=$((FAIL + 1))
fi

# --------------------------------------------------------------------------------
# Y1-Y11 — CHECK 4, CAPABILITY. Type Y: the measurement is right and the word for it
# is false (richos-hq docs/verification/lifecycle-failure-record-2026-09-13.md §10i).
#
# Y1-Y4 ARE THE FOUR REAL INSTANCES, reduced to their shape. Y5-Y10 are the negative
# halves, and they carry more weight here than anywhere else in this file: a check
# whose trigger is a VERB would pass Y1-Y4 while flagging every correct sentence that
# uses the same verb, and the corpus is full of those. Y11 asserts a known FALSE
# POSITIVE, for the same reason P4 asserts a known miss.
# --------------------------------------------------------------------------------
cat > "$SANDBOX/brief.md" <<'B'
## The codex branches

    $ git branch --no-merged main --list 'codex/*'
    + codex/owned-outcome-prd

All but one of the codex branches are fully merged into main.
B
flags "Y1   reachability reported as an ACT is caught" "fully merged into main"

cat > "$SANDBOX/brief.md" <<'B'
## The passenger

The back-merge commit is an ancestor of the other tip, which means the retirement branch
carried it in.

    $ git merge-base --is-ancestor 55728e67 f201e904 ; echo $?
    0
B
flags "Y2   --is-ancestor used to single out ONE merge is caught" "carried it in"

cat > "$SANDBOX/brief.md" <<'B'
## The ledger

    $ grep -c '"for": "ceo"' escalations.jsonl
    10

There are 10 outstanding for the CEO.
B
flags "Y3   a count named by a filter the selector never applied is caught" "10 outstanding"

cat > "$SANDBOX/brief.md" <<'B'
## The escalations

    $ escalations.py outstanding
    by audience: {'lead': 79, 'ceo': 6}

79 teammate escalations are outstanding, explicitly waiting on him.
B
flags "Y4   a measurement reported as whose move it is, is caught" "waiting on him"

# --- the negatives, one per rule ---
cat > "$SANDBOX/brief.md" <<'B'
## The codex branches

    $ git reflog show main | grep 'merge codex/'
    f201e904 main@{31}: merge codex/workspace-retirement-safety: Merge made by 'ort'

Twelve codex branches were merged into main, and the reflog names each one.
B
silent "Y5   the SAME verb with a command that DOES record the act is silent" "were merged into main"

cat > "$SANDBOX/brief.md" <<'B'
## The codex branches

    $ git branch --no-merged main --list 'codex/*'
    + codex/owned-outcome-prd

Every codex branch except that one is reachable from main.
B
silent "Y6   the CORRECT word for the same measurement is silent" "reachable from main"

cat > "$SANDBOX/brief.md" <<'B'
## The ledger

    $ grep -c '"outstanding": true' escalations.jsonl
    6

There are 6 outstanding for the CEO.
B
silent "Y7   a count whose selector DOES filter on the name is silent" "6 outstanding"

cat > "$SANDBOX/brief.md" <<'B'
## The rule

    $ git branch --no-merged main --list 'codex/*'
    + codex/owned-outcome-prd

A branch that no longer appears here must be reconciled as landed and its workspace deleted.
B
silent "Y8   a SPECIFICATION is not a report, and is silent" "must be reconciled"

cat > "$SANDBOX/brief.md" <<'B'
## What happened

    $ ls .claude/worktrees/
    agent-aaaba572

Both hooks were deleted from the tree at commit `3ddc05a3` on 2026-08-28.
B
silent "Y9   a cited COMMIT is evidence of an act, so the act class is silent" "were deleted from the tree"

cat > "$SANDBOX/brief.md" <<'B'
## Scope

    $ grep -rn 'workspaces.sh' engine/scripts
    engine/scripts/land.sh:14

Nothing here changes what is allowed; whether it was authorized is a separate question.
B
silent "Y10  a DEFINITION and an indirect question are not claims of authorization" "what is allowed"

# Y11 — A KNOWN FALSE POSITIVE, asserted out loud so precision cannot be overclaimed.
# A document that DISCUSSES these verbs is flagged for containing them. Telling mention
# from use is not something a regular expression can do, and a file that quietly failed
# this case would be claiming a precision it does not have.
cat > "$SANDBOX/brief.md" <<'B'
## The tell

    $ git branch --list 'codex/*'
    codex/owned-outcome-prd

Verbs implying history — merged, landed, deleted, deployed — are claims a state command
cannot carry.
B
flags "Y11  KNOWN FALSE POSITIVE: a sentence ABOUT the verbs is flagged for using them" \
      "Verbs implying history"

# Y12 — the capability rows reach the agent under their own instruction. Sending them
# under check 3's heading would tell the agent to re-derive the number, which CONFIRMS
# the sentence and is exactly how all four instances survived.
cat > "$SANDBOX/brief.md" <<'B'
## The codex branches

    $ git branch --no-merged main --list 'codex/*'
    + codex/owned-outcome-prd

All but one of the codex branches are fully merged into main.
B
OUT="$(python3 "$CHECK" "$SANDBOX/brief.md" --annotate --repo "$SANDBOX")"
if printf '%s' "$OUT" | grep -qF "SOURCED" \
   && printf '%s' "$OUT" | grep -qF "re-running it will agree"; then
  ok "Y12  capability rows carry their OWN instruction, not check 3's"
else
  printf '  FAIL  %s\n' "Y12  capability rows carry their OWN instruction, not check 3's"
  FAIL=$((FAIL + 1))
fi

echo
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
