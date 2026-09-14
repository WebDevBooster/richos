#!/usr/bin/env bash
#
# notice-claim-capability.test.sh — the delivery surface for check 4, proven by execution.
#
# EVERY CASE RUNS IN A SANDBOX. Nothing here touches a real record, the operator's memory
# directory, or a real repository. The RATE on the real corpus is a separate measurement and
# it is reported in docs/verification/claim-capability-delivery-2026-09-14.md — scoring a
# check against the cases it was written from is how a check gets a number it did not earn.
#
# THE NEGATIVES CARRY THE WEIGHT HERE. This hook's whole risk is becoming wallpaper, so the
# cases that prove it stays SILENT are the ones that decide whether it should exist. Six of
# the fourteen are negatives, and D5 is the single most important case in the file.
#
# WHAT IS PROVEN:
#
#   D1   THE KNOWN-BAD SENTENCE IS CAUGHT when a record is written with a heredoc — the form
#        records are actually written with (37 of the 41 recorded record-writes on this
#        machine were Bash, not the Write tool). Exit 2, the row names the ACT class.
#   D2   ALL FOUR known instances are caught, each written on its own. The positive probe.
#   D3   THE WRITE TOOL SHAPE FIRES TOO — `content`, not a command string.
#   D4   A WIKI PAGE AND A MEMORY NOTE FIRE. The surface list is three directories and all
#        three are exercised; without this, a typo in the path predicate ships silently.
#   D5   AN EDIT TO AN UNRELATED PARAGRAPH OF A FLAGGED RECORD IS SILENT.  <-- THE ONE THAT
#        DECIDES IT. The hook re-scans the whole file, so without the "only what this call
#        wrote" narrowing, one flagged record edited eight times costs eight copies of the
#        same rows. Measured on the real corpus, that single behavior is the difference
#        between 89 emissions and 32.
#   D6   READING A FLAGGED RECORD IS SILENT. `sed -n '1,40p' record.md` and
#        `git add record.md` name the path and write no sentence. Falls out of D5's rule
#        rather than needing a write-detector, and this case pins that it does.
#   D7   A RECORD WITH A SOURCED SENTENCE AND NO CAPABILITY CLAIM IS SILENT. Without this,
#        a check that fired on any sourced sentence would pass D1.
#   D8   A SOURCE FILE IS SILENT. The check reads prose; a shell script is not a record.
#   D9   A FIXTURE AND A `*.corpus.md` ARE SILENT. A corpus file asserts known-bad sentences
#        ON PURPOSE, and flagging it is the check reporting its own test data.
#  D10   RICH-TODOs.md IS SILENT — the reasoned exclusion, pinned. Its purpose is to record
#        what is awaited by a person, which rule A1 holds to be universally unestablishable,
#        so it would be flagged on every write. An exclusion no test pins is one that drifts
#        back in.
#  D11   A PAYLOAD NAMING NO RECORD IS SILENT AND EXIT 0. Registered against every
#        write-shaped tool, so this is the overwhelmingly common path.
#  D12   IT NEVER FAILS A TOOL CALL when the predicate itself is broken or missing. A check
#        that could not run must never look like a failed write.
#  D13   STDOUT STAYS EMPTY and THE RECORD IS BYTE-IDENTICAL afterwards. The rows are
#        transient and addressed to the author; this hook never edits what anybody wrote.
#  D14   A RELATIVE PATH IS RESOLVED AGAINST THE CALL'S OWN cwd. `cat > docs/verification/x.md`
#        after a `cd` is the normal authoring shape and must not be invisible.
#
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${NOTICE_HOOK_UNDER_TEST:-$SCRIPT_DIR/notice-claim-capability.sh}"
PROV="$SCRIPT_DIR/../brief-provenance.py"

PASS=0; FAIL=0
SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/notice-claim-capability.XXXXXX")" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s -- %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }

[ -f "$HOOK" ] || { echo "FATAL: missing $HOOK" >&2; exit 1; }
[ -f "$PROV" ] || { echo "FATAL: missing $PROV" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

echo "notice-claim-capability.test.sh"
echo "  hook:    $HOOK"
echo "  sandbox: $SANDBOX"
echo

# --- the harness -------------------------------------------------------------------------
# Builds the PostToolUse payload the host would build, runs the hook, and leaves the exit
# code in RC, stderr in ERR and stdout in OUT. Nothing else in this file shells out.
RC=0; ERR=""; OUT=""
fire() {                                   # fire <tool> <cwd> <json-of-tool_input>
    local tool="$1" cwd="$2" ti="$3"
    OUT="$SANDBOX/.out"; ERR="$SANDBOX/.err"
    python3 - "$tool" "$cwd" "$ti" >"$SANDBOX/.payload" <<'PY'
import json, sys
tool, cwd, ti = sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps({"session_id": "t", "cwd": cwd, "hook_event_name": "PostToolUse",
                  "tool_name": tool, "tool_input": json.loads(ti),
                  "tool_response": {"stdout": "", "stderr": "", "interrupted": False}}))
PY
    bash "$HOOK" <"$SANDBOX/.payload" >"$OUT" 2>"$ERR"
    RC=$?
    ERR="$(cat "$SANDBOX/.err")"
    OUT="$(cat "$SANDBOX/.out")"
}

# tool_input JSON for a Bash call carrying an arbitrary command string.
bash_ti() { python3 -c 'import json,sys; print(json.dumps({"command": sys.stdin.read(), "description": "d"}))'; }
write_ti() { python3 -c 'import json,sys,os; print(json.dumps({"file_path": sys.argv[1], "content": sys.stdin.read()}))' "$1"; }
edit_ti()  { python3 -c 'import json,sys; print(json.dumps({"file_path": sys.argv[1], "old_string": sys.argv[2], "new_string": sys.stdin.read()}))' "$1" "$2"; }

silent() {                                  # silent <case> — exit 0, nothing on stderr
    if [ "$RC" -eq 0 ] && [ -z "$ERR" ]; then ok "$1"; else bad "$1" "rc=$RC stderr=${ERR:0:160}"; fi
}
fires() {                                   # fires <case> <substring the row must contain>
    if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -qF "$2"; then ok "$1"
    else bad "$1" "rc=$RC (want 2) and stderr must contain '$2'; got: ${ERR:0:200}"; fi
}

REPO="$SANDBOX/repo"
mkdir -p "$REPO/docs/verification" "$REPO/wiki" "$SANDBOX/proj/memory" \
         "$REPO/engine/scripts/hooks/fixtures" "$REPO/engine/scripts"

# ------------------------------------------------------------------------------------------
# The four instances, each with the real command that was cited beside it.
# ------------------------------------------------------------------------------------------
record_1() { cat <<'DOC'
# Escalations

```
$ python3 ~/.claude/richos-engine/scripts/escalations.py outstanding | tail -3
79
```

79 teammate escalations outstanding, oldest 8 days, explicitly waiting on him.
DOC
}
record_2() { cat <<'DOC'
# The CEO's share

```
$ grep -c '"for": "ceo"' ~/.claude/state/escalations.jsonl
10
```

There are 10 outstanding for the CEO.
DOC
}
record_3() { cat <<'DOC'
# Branch state

```
$ git -C /Users/alex/ab/richos branch --no-merged main --list 'codex/*'
  codex/workspace-retirement-safety
```

All but one of the codex branches are fully merged into main.
DOC
}
record_4() { cat <<'DOC'
# How it arrived

```
$ git merge-base --is-ancestor 55728e67 f201e904 ; echo $?
0
```

Its own back-merge commit is an ancestor of the tip, which means the branch
`codex/workspace-retirement-safety` carried it in as a passenger.
DOC
}

heredoc_write() {                          # heredoc_write <abs-path> <record-fn>
    printf "cat > %s <<'DOC'\n" "$1"; "$2"; printf 'DOC\n'
}

# --- D1 --------------------------------------------------------------------------------
R3="$REPO/docs/verification/branch-state.md"
record_3 >"$R3"
fire Bash "$REPO" "$(heredoc_write "$R3" record_3 | bash_ti)"
fires D1 "It cannot establish that any operation was performed"

# --- D2 — all four -----------------------------------------------------------------------
d2_fail=""
i=0
for fn in record_1 record_2 record_3 record_4; do
    i=$((i + 1))
    P="$REPO/docs/verification/instance-$i.md"
    "$fn" >"$P"
    fire Bash "$REPO" "$(heredoc_write "$P" "$fn" | bash_ti)"
    [ "$RC" -eq 2 ] || d2_fail="$d2_fail instance-$i(rc=$RC)"
done
if [ -z "$d2_fail" ]; then ok "D2"; else bad "D2" "not flagged:$d2_fail"; fi

# --- D3 — the Write tool shape -----------------------------------------------------------
R3W="$REPO/docs/verification/via-write-tool.md"
record_3 >"$R3W"
fire Write "$REPO" "$(record_3 | write_ti "$R3W")"
fires D3 "branch tips are reachable"

# --- D4 — wiki page and memory note -------------------------------------------------------
WIKI="$REPO/wiki/branch-state.md"; record_3 >"$WIKI"
fire Bash "$REPO" "$(heredoc_write "$WIKI" record_3 | bash_ti)"
wiki_rc="$RC"
MEM="$SANDBOX/proj/memory/project_restart_demo.md"; record_1 >"$MEM"
fire Bash "$SANDBOX" "$(heredoc_write "$MEM" record_1 | bash_ti)"
if [ "$wiki_rc" -eq 2 ] && [ "$RC" -eq 2 ]; then ok "D4"
else bad "D4" "wiki rc=$wiki_rc memory rc=$RC (both want 2)"; fi

# --- D5 — an edit to an unrelated paragraph of a FLAGGED record is silent ------------------
# $R3 still holds the flagged sentence from D1. This call appends a sentence of its own.
{ record_3; printf '\nThe deploy script reads the tree at HEAD.\n'; } >"$R3"
fire Edit "$REPO" "$(printf 'The deploy script reads the tree at HEAD.\n' \
                     | edit_ti "$R3" "")"
silent D5

# --- D6 — reading a flagged record is silent ----------------------------------------------
fire Bash "$REPO" "$(printf "sed -n '1,40p' %s\n" "$R3" | bash_ti)"
read_rc="$RC"; read_err="$ERR"
fire Bash "$REPO" "$(printf 'git add %s\n' "$R3" | bash_ti)"
if [ "$read_rc" -eq 0 ] && [ -z "$read_err" ] && [ "$RC" -eq 0 ] && [ -z "$ERR" ]; then ok "D6"
else bad "D6" "sed rc=$read_rc/'${read_err:0:80}' gitadd rc=$RC/'${ERR:0:80}'"; fi

# --- D7 — sourced, no capability claim ----------------------------------------------------
CLEAN="$REPO/docs/verification/clean.md"
clean_record() { cat <<'DOC'
# Suite result

```
$ bash engine/scripts/brief-provenance.test.sh | tail -1
32 passed, 0 failed
```

The suite reports 32 passing cases and no failures.
DOC
}
clean_record >"$CLEAN"
fire Bash "$REPO" "$(heredoc_write "$CLEAN" clean_record | bash_ti)"
silent D7

# --- D8 — a source file ------------------------------------------------------------------
SRC="$REPO/engine/scripts/deploy.sh"
printf '#!/bin/sh\n# All but one of the codex branches are fully merged into main.\necho hi\n' >"$SRC"
fire Write "$REPO" "$(printf '#!/bin/sh\n# All but one of the codex branches are fully merged into main.\necho hi\n' | write_ti "$SRC")"
silent D8

# --- D9 — a fixture and a corpus file -----------------------------------------------------
FIX="$REPO/engine/scripts/hooks/fixtures/docs/verification/case.md"
mkdir -p "$(dirname "$FIX")"; record_3 >"$FIX"
fire Bash "$REPO" "$(heredoc_write "$FIX" record_3 | bash_ti)"
fix_rc="$RC"; fix_err="$ERR"
CORP="$REPO/wiki/capability.corpus.md"; record_3 >"$CORP"
fire Bash "$REPO" "$(heredoc_write "$CORP" record_3 | bash_ti)"
if [ "$fix_rc" -eq 0 ] && [ -z "$fix_err" ] && [ "$RC" -eq 0 ] && [ -z "$ERR" ]; then ok "D9"
else bad "D9" "fixture rc=$fix_rc/'${fix_err:0:80}' corpus rc=$RC/'${ERR:0:80}'"; fi

# --- D10 — RICH-TODOs.md is excluded ------------------------------------------------------
TODO="$REPO/RICH-TODOs.md"
todo_record() { cat <<'DOC'
# What is open

```
$ git -C /Users/alex/ab/richos branch --no-merged main --list 'codex/*'
  codex/workspace-retirement-safety
```

WAITING ON HIS WORD — the calls for the next round, with the proof of each.
DOC
}
todo_record >"$TODO"
fire Bash "$REPO" "$(heredoc_write "$TODO" todo_record | bash_ti)"
silent D10

# --- D11 — no record named ----------------------------------------------------------------
fire Bash "$REPO" "$(printf 'npm test -- --runInBand\n' | bash_ti)"
silent D11

# --- D12 — a broken predicate never fails the tool call ------------------------------------
BROKEN="$SANDBOX/broken"
mkdir -p "$BROKEN/scripts/hooks"
cp "$HOOK" "$BROKEN/scripts/hooks/notice-claim-capability.sh"
printf 'def segment(  SyntaxError here\n' >"$BROKEN/scripts/brief-provenance.py"
record_3 >"$R3"
_saved_hook="$HOOK"; HOOK="$BROKEN/scripts/hooks/notice-claim-capability.sh"
fire Bash "$REPO" "$(heredoc_write "$R3" record_3 | bash_ti)"
broken_rc="$RC"; broken_err="$ERR"
rm -f "$BROKEN/scripts/brief-provenance.py"
fire Bash "$REPO" "$(heredoc_write "$R3" record_3 | bash_ti)"
HOOK="$_saved_hook"
if [ "$broken_rc" -eq 0 ] && [ -z "$broken_err" ] && [ "$RC" -eq 0 ] && [ -z "$ERR" ]; then ok "D12"
else bad "D12" "syntax-error rc=$broken_rc/'${broken_err:0:80}' missing rc=$RC/'${ERR:0:80}'"; fi

# --- D13 — stdout empty, record untouched ---------------------------------------------------
record_3 >"$R3"
before="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$R3")"
fire Bash "$REPO" "$(heredoc_write "$R3" record_3 | bash_ti)"
after="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$R3")"
if [ "$RC" -eq 2 ] && [ -z "$OUT" ] && [ "$before" = "$after" ]; then ok "D13"
else bad "D13" "rc=$RC stdout='${OUT:0:80}' sha ${before:0:8}->${after:0:8}"; fi

# --- D14 — a relative path resolves against the call's own cwd -------------------------------
REL="docs/verification/relative.md"
record_3 >"$REPO/$REL"
fire Bash "$REPO" "$(heredoc_write "$REL" record_3 | bash_ti)"
fires D14 "branch tips are reachable"

# --- THE MUTATION HARNESS RUNS FROM THE SUITE IT MUTATES ------------------------------------
# `run-all-tests.sh` discovers `*.test.sh`; a `*.mutation.sh` is invisible to it, and
# contract-integrity.test.sh names a hand-typed set this one is not in. Left to itself the
# harness would run exactly when somebody remembered to type its path — which is what
# happened to another harness in this engine for weeks (wiki/open-items.md row 3.29).
#
# ITS FAILURE IS THIS SUITE'S FAILURE, not a warning, and A MISSING HARNESS IS A FAILURE, NOT
# A SKIP. Six of the fourteen cases above are "it stayed quiet", and those pass for free.
#
# RICHOS_MUTATION_INNER is the only thing between this and an infinite regress: the harness
# EXPORTS it before running any copy of this suite. Never remove one half without the other.
if [ -z "${RICHOS_MUTATION_INNER:-}" ]; then
    echo
    echo "=== running the mutation harness: claim-capability-delivery.mutation.sh ==="
    if [ -x "$SCRIPT_DIR/claim-capability-delivery.mutation.sh" ]; then
        "$SCRIPT_DIR/claim-capability-delivery.mutation.sh" || FAIL=$((FAIL + 1))
    else
        echo "  FAIL  MUT. claim-capability-delivery.mutation.sh is missing or not executable — IT DID NOT RUN"
        FAIL=$((FAIL + 1))
    fi
fi

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
