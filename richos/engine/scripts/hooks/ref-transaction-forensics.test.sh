#!/usr/bin/env bash
#
# ref-transaction-forensics.test.sh — the recorder that attributes every ref
#                                     write, proven by making git call it.
#
# ===========================================================================
# WHY THIS SUITE EXISTS
# ===========================================================================
# ref-transaction-forensics.sh landed at fa3c9bb3 and, until this file, was
# named by NO suite — ci-affected-units case A5 said so:
#
#     1 of 100 hook(s) are named by NO suite: ref-transaction-forensics.sh
#
# That was a REAL gap and not bookkeeping. This hook is the only thing that
# can say WHO moved a ref: on 2026-09-13 refs/heads/main in the richos
# checkout moved three times leaving an EMPTY reflog message, and the reflog
# records the RESULT and nothing about the writer. The recorder exists so
# that class of write is attributable. Nothing proved it records.
#
# A recorder fails SILENTLY by construction, which is what makes an untested
# one dangerous. Its own contract forbids it to complain: git aborts the
# transaction if a `reference-transaction` hook exits non-zero during the
# `prepared` phase, so the hook runs without `set -e`, swallows every error
# and ends in an unconditional `exit 0`. A recorder that has stopped writing
# and a recorder with nothing to write are therefore byte-identical from the
# outside — both are silence and exit 0. The ONLY way to tell them apart is
# to make a ref move and look for the line. That is what this suite does.
#
# ===========================================================================
# THE CASES, AND WHICH ONE IS LOAD-BEARING
# ===========================================================================
#   F01  THE ONE THAT MATTERS. A real repository, the hook installed at
#        .git/hooks/reference-transaction the way it is installed for real,
#        and a real `git commit`. If the recorder stops recording, this case
#        goes red and no other evidence is needed. Every case below it drives
#        the hook directly, which is faster but tests the hook against this
#        suite's idea of git's contract; F01 tests it against git's.
#   F02  the recorded line is VALID JSON. A forensic log that cannot be parsed
#        is not evidence. Parsed with python3, never grepped.
#   F03  the line carries the three facts a reflog could not: which ref, the
#        old oid and the new oid.
#   F04  it attributes the WRITER — a pid and a non-empty parent chain. This
#        is the entire point of the hook; a line without it is a worse reflog.
#   F05  the ABSENCE of GIT_REFLOG_ACTION is recorded as null and distinct
#        from present-but-empty. Absence is the signature of the writes being
#        hunted, so the two must never collapse.
#   F06  APPEND-ONLY. A second transaction leaves the first line byte-intact.
#        A forensic log that can lose its earlier entries is worthless
#        precisely when someone is being forensic about it.
#   F07  one line per ref in a multi-ref transaction — a push or a fetch moves
#        several at once and each writer must be attributable.
#   F08  the three phases are recorded distinctly. `prepared` without
#        `committed` is an ABORTED write, which is a finding.
#   F09  IT NEVER FAILS, on any input. Garbage stdin, an unwritable log, no
#        stdin at all, a missing phase argument: exit 0 every time. A non-zero
#        exit during `prepared` would break the caller's git command outright,
#        so this is the hook's hardest constraint, not its softest.
#   F10  hostile bytes — quotes, backslashes, tabs in a ref name — still
#        produce parseable JSON. Escaping is where a hand-rolled JSON writer
#        fails, and it fails by corrupting the whole log.
#   F11  an over-long command is capped, and any truncation is MARKED with the
#        byte count dropped, so it can never be misread as a whole command.
#   F12  NEGATIVE CONTROL FOR THE SUITE ITSELF. A copy of the recorder with
#        its write disabled is run through F01's own assertion, and that
#        assertion MUST go red. Without this, F01 proves only that the suite
#        runs, not that it would notice a recorder that stopped recording.
#
# THE OPERATOR'S REAL LOG IS NEVER TOUCHED: RICHOS_REF_FORENSICS_DIR and
# RICHOS_REF_FORENSICS_LOG are redirected into a sandbox for every case, and
# the only git repositories used are created under that sandbox. This suite
# installs a git hook ONLY into repositories it made itself.
#
# Usage: scripts/hooks/ref-transaction-forensics.test.sh
# Exit:  0 all cases passed, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/ref-transaction-forensics.sh"

PASS=0
FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; FAIL=$((FAIL + 1)); return 0; }

command -v python3 >/dev/null 2>&1 || { echo "ERROR: needs python3" >&2; exit 1; }
command -v git     >/dev/null 2>&1 || { echo "ERROR: needs git"     >&2; exit 1; }

[ -f "$HOOK" ] || { echo "ERROR: recorder not on disk: $HOOK" >&2; exit 1; }

SANDBOX="$(cd "$(mktemp -d -t reftxforensics.XXXXXX)" && pwd -P)"
trap 'chmod -R u+rwX "$SANDBOX" 2>/dev/null; rm -rf "$SANDBOX"' EXIT

# ===========================================================================
# THE SUITE IS HERMETIC AGAINST THE OPERATOR'S GIT CONFIG, AND THAT IS LOAD-
# BEARING RATHER THAN TIDY. Found while writing this file: this machine sets a
# GLOBAL core.hooksPath (/Users/alex/.config/git/hooks). A global hooksPath
# REPLACES .git/hooks for every repository on the machine — so the obvious way
# to write F01, copying the recorder into the sandbox repo's .git/hooks and
# committing, silently invokes the operator's hooks instead and NEVER RUNS THE
# RECORDER AT ALL. The case would then be reporting on somebody's global
# configuration while appearing to test this hook.
#
# It was caught only because those global hooks include an identity guard that
# refused the fixture's commit outright. Had they been silent, F01 would have
# passed while exercising nothing — the exact "negative test passes for the
# wrong reason" failure, and the reason F12 exists.
#
# So: global and system config are cut out entirely, and core.hooksPath is set
# EXPLICITLY per repository below. Nothing here is inherited from the host.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE 2>/dev/null || true

# Create a sandbox repository that runs EXACTLY the hook handed to it and no
# other, whatever the host is configured to do.
make_repo() { # <path> <hook-script>
    local repo="$1" hook="$2"
    mkdir -p "$repo"
    git init -q -b main "$repo" >/dev/null 2>&1 || return 1
    git -C "$repo" config user.email 'suite@example.invalid'
    git -C "$repo" config user.name  'Ref Forensics Suite'
    git -C "$repo" config commit.gpgsign false
    # The explicit pin. Without it a global core.hooksPath wins and this
    # repository runs the operator's hooks rather than the recorder.
    mkdir -p "$repo/.githooks"
    git -C "$repo" config core.hooksPath "$repo/.githooks"
    cp "$hook" "$repo/.githooks/reference-transaction"
    chmod +x "$repo/.githooks/reference-transaction"
}

# THE STORE IS SANDBOXED. Without this the fixture rows below land in the
# operator's real ~/.claude/state/ref-forensics/ref-transactions.jsonl, which
# is an append-only forensic record of their actual ref writes. A test never
# writes to the operator's state, and this log in particular is one somebody
# may later have to trust.
export RICHOS_REF_FORENSICS_DIR="$SANDBOX/forensics"
export RICHOS_REF_FORENSICS_LOG="$RICHOS_REF_FORENSICS_DIR/ref-transactions.jsonl"
mkdir -p "$RICHOS_REF_FORENSICS_DIR"

ZERO="0000000000000000000000000000000000000000"
OIDA="1111111111111111111111111111111111111111"
OIDB="2222222222222222222222222222222222222222"

reset_log() { : > "$RICHOS_REF_FORENSICS_LOG"; }

# Read every recorded line as JSON and print one python expression over the
# list `rows`. Parsing, never grepping: a grep would pass on a line that is
# not valid JSON, which is the very thing F02 exists to catch.
rows() {
    python3 - "$RICHOS_REF_FORENSICS_LOG" "$1" <<'PY'
import json, sys
path, expr = sys.argv[1], sys.argv[2]
rows = []
try:
    fh = open(path)
except OSError as exc:
    print('NOLOG %s' % exc)
    raise SystemExit(0)
with fh:
    for n, line in enumerate(fh, 1):
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except Exception as exc:
            print('UNPARSEABLE line %d: %s' % (n, exc))
            raise SystemExit(0)
try:
    print(eval(expr))
except Exception as exc:
    print('EXPRFAILED %s' % exc)
PY
}

echo "=== ref-transaction-forensics: does the recorder record, and can it ever break git? ==="

# ---------------------------------------------------------------------------
# F01 — the load-bearing case: REAL git, REAL hook, REAL commit.
# ---------------------------------------------------------------------------
# Everything below drives the hook by hand. This one does not: it installs the
# recorder where git looks for it and then moves a ref the ordinary way. If
# git's contract changes, or the hook stops being invoked, or it stops
# writing, this is the case that notices.
# Installed into a repository this suite created moments ago, with hooksPath
# pinned to it. The engine's own .git/hooks is never touched by this file.
REPO="$SANDBOX/real-repo"
make_repo "$REPO" "$HOOK"

reset_log
echo one > "$REPO/file.txt"
git -C "$REPO" add file.txt >/dev/null 2>&1
COMMIT_RC=0
git -C "$REPO" commit -q -m 'first' >/dev/null 2>&1 || COMMIT_RC=$?

if [ "$COMMIT_RC" -ne 0 ]; then
    bad "F01 real git commit is recorded" "the commit itself FAILED (rc=$COMMIT_RC) — the hook broke git, which is the one thing it must never do"
elif [ ! -s "$RICHOS_REF_FORENSICS_LOG" ]; then
    bad "F01 real git commit is recorded" "a real commit moved refs/heads/main and the recorder wrote NOTHING. The recorder is not recording."
else
    REAL_REF="$(rows "any(r['ref'] == 'refs/heads/main' for r in rows)")"
    if [ "$REAL_REF" = "True" ]; then
        ok "F01 a real git commit through a real .git/hooks/reference-transaction IS recorded, and the commit still succeeds"
    else
        bad "F01 real git commit is recorded" "log has lines but none names refs/heads/main: $REAL_REF"
    fi
fi

# F02-F04 are asserted about that SAME real transaction, so they describe
# git's own payload rather than a fixture this suite invented.
# ---------------------------------------------------------------------------
# F02 — valid JSON.
# ---------------------------------------------------------------------------
F02="$(rows "len(rows)")"
case "$F02" in
    UNPARSEABLE*|NOLOG*|EXPRFAILED*) bad "F02 every recorded line is valid JSON" "$F02" ;;
    ''|*[!0-9]*)                     bad "F02 every recorded line is valid JSON" "could not count rows: $F02" ;;
    0)                               bad "F02 every recorded line is valid JSON" "no rows to parse" ;;
    *)                               ok  "F02 every recorded line parses as JSON ($F02 rows from one real commit)" ;;
esac

# ---------------------------------------------------------------------------
# F03 — the three facts the reflog could not supply.
# ---------------------------------------------------------------------------
F03="$(rows "bool(rows) and all(('ref' in r and 'old' in r and 'new' in r) for r in rows) and all(len(r['new']) == 40 for r in rows if r['ref'] == 'refs/heads/main')")"
if [ "$F03" = "True" ]; then
    ok "F03 each line carries ref, old oid and new oid — the facts an empty reflog message hid"
else
    bad "F03 ref/old/new are recorded" "got: $F03"
fi

# ---------------------------------------------------------------------------
# F04 — WHO wrote it. The whole reason the hook exists.
# ---------------------------------------------------------------------------
F04="$(rows "bool(rows) and all(r.get('writer_pid') and r.get('chain') and r['chain'][0].get('cmd') for r in rows)")"
if [ "$F04" = "True" ]; then
    ok "F04 every line attributes a writer: a pid and a non-empty parent chain carrying a command line"
else
    bad "F04 the writer is attributed" "a line recorded a ref move without saying who did it — that is a worse reflog, not a better one. got: $F04"
fi

# ---------------------------------------------------------------------------
# F05 — absent GIT_REFLOG_ACTION is null, and that differs from empty.
# ---------------------------------------------------------------------------
# Absence is the SIGNATURE of the writes this hook was built to catch, so the
# two must stay distinguishable in the record.
reset_log
env -u GIT_REFLOG_ACTION bash "$HOOK" committed <<< "$ZERO $OIDA refs/heads/absent" >/dev/null 2>&1
F05_ABSENT="$(rows "rows[0]['reflog_action'] is None")"
reset_log
GIT_REFLOG_ACTION='' bash "$HOOK" committed <<< "$ZERO $OIDA refs/heads/empty" >/dev/null 2>&1
F05_EMPTY="$(rows "rows[0]['reflog_action'] == ''")"
reset_log
GIT_REFLOG_ACTION='merge topic' bash "$HOOK" committed <<< "$ZERO $OIDA refs/heads/set" >/dev/null 2>&1
F05_SET="$(rows "rows[0]['reflog_action'] == 'merge topic'")"
if [ "$F05_ABSENT" = "True" ] && [ "$F05_EMPTY" = "True" ] && [ "$F05_SET" = "True" ]; then
    ok "F05 GIT_REFLOG_ACTION unset records null, present-but-empty records the empty string, set records the value — three states, never collapsed"
else
    bad "F05 unset and empty GIT_REFLOG_ACTION are distinguishable" "absent=$F05_ABSENT empty=$F05_EMPTY set=$F05_SET"
fi

# ---------------------------------------------------------------------------
# F06 — append-only.
# ---------------------------------------------------------------------------
reset_log
bash "$HOOK" committed <<< "$ZERO $OIDA refs/heads/first"  >/dev/null 2>&1
FIRST_LINE="$(head -1 "$RICHOS_REF_FORENSICS_LOG")"
bash "$HOOK" committed <<< "$OIDA $OIDB refs/heads/second" >/dev/null 2>&1
F06_COUNT="$(grep -c . "$RICHOS_REF_FORENSICS_LOG" || true)"
if [ "$(head -1 "$RICHOS_REF_FORENSICS_LOG")" = "$FIRST_LINE" ] && [ "$F06_COUNT" -eq 2 ]; then
    ok "F06 a later transaction APPENDS — the earlier line is byte-identical and nothing is rotated or truncated"
else
    bad "F06 the log is append-only" "the first line changed, or the count is $F06_COUNT rather than 2"
fi

# ---------------------------------------------------------------------------
# F07 — one line per ref in a multi-ref transaction.
# ---------------------------------------------------------------------------
reset_log
printf '%s %s refs/heads/a\n%s %s refs/heads/b\n%s %s refs/tags/v1\n' \
    "$ZERO" "$OIDA" "$OIDA" "$OIDB" "$ZERO" "$OIDB" \
    | bash "$HOOK" committed >/dev/null 2>&1
F07="$(rows "sorted(r['ref'] for r in rows) == ['refs/heads/a', 'refs/heads/b', 'refs/tags/v1']")"
if [ "$F07" = "True" ]; then
    ok "F07 a three-ref transaction records three lines — a push moves several refs and each stays attributable"
else
    bad "F07 one line per ref" "got: $F07"
fi

# ---------------------------------------------------------------------------
# F08 — the phases are distinct.
# ---------------------------------------------------------------------------
# `prepared` with no matching `committed` is an ABORTED ref write. If the
# phase were not recorded, an abort and a success would look the same.
reset_log
bash "$HOOK" prepared  <<< "$ZERO $OIDA refs/heads/p" >/dev/null 2>&1
bash "$HOOK" committed <<< "$ZERO $OIDA refs/heads/p" >/dev/null 2>&1
bash "$HOOK" aborted   <<< "$ZERO $OIDA refs/heads/p" >/dev/null 2>&1
F08="$(rows "[r['phase'] for r in rows] == ['prepared', 'committed', 'aborted']")"
if [ "$F08" = "True" ]; then
    ok "F08 prepared, committed and aborted are each recorded under their own phase — an abort is visible as an abort"
else
    bad "F08 phases are recorded distinctly" "got: $F08"
fi

# ---------------------------------------------------------------------------
# F09 — it can never fail. The hook's hardest constraint.
# ---------------------------------------------------------------------------
# A non-zero exit during `prepared` ABORTS the caller's transaction and fails
# their git command. Every one of these must exit 0.
F09_FAILURES=""
check_exit0() { # <label> <phase> <stdin>
    local label="$1" phase="$2" input="$3" rc=0
    printf '%s' "$input" | bash "$HOOK" "$phase" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] || F09_FAILURES="$F09_FAILURES $label(rc=$rc)"
}
check_exit0 garbage-stdin prepared  'this is not a ref line at all'
check_exit0 empty-stdin   prepared  ''
check_exit0 partial-line  committed "$ZERO $OIDA"
check_exit0 blank-lines   committed $'\n\n\n'
check_exit0 control-bytes committed "$(printf '%s %s refs/heads/\001\002bin' "$ZERO" "$OIDA")"
# no phase argument at all
NOARG_RC=0
printf '%s %s refs/heads/x\n' "$ZERO" "$OIDA" | bash "$HOOK" >/dev/null 2>&1 || NOARG_RC=$?
[ "$NOARG_RC" -eq 0 ] || F09_FAILURES="$F09_FAILURES no-phase-arg(rc=$NOARG_RC)"
# an UNWRITABLE log: the recorder loses the line, but must not lose the commit.
UNWRITABLE="$SANDBOX/unwritable"
mkdir -p "$UNWRITABLE"
chmod 500 "$UNWRITABLE"
UNW_RC=0
RICHOS_REF_FORENSICS_DIR="$UNWRITABLE/sub" RICHOS_REF_FORENSICS_LOG="$UNWRITABLE/sub/l.jsonl" \
    bash "$HOOK" prepared <<< "$ZERO $OIDA refs/heads/x" >/dev/null 2>&1 || UNW_RC=$?
chmod 700 "$UNWRITABLE"
[ "$UNW_RC" -eq 0 ] || F09_FAILURES="$F09_FAILURES unwritable-log(rc=$UNW_RC)"
if [ -z "$F09_FAILURES" ]; then
    ok "F09 exit 0 on garbage, empty, partial, control-byte and absent stdin, on a missing phase argument, and on an UNWRITABLE log — it can never abort a transaction"
else
    bad "F09 the recorder can never fail" "non-zero exits would abort the caller's git command:$F09_FAILURES"
fi

# ---------------------------------------------------------------------------
# F10 — hostile bytes still produce parseable JSON.
# ---------------------------------------------------------------------------
# Hand-rolled JSON fails at escaping, and it fails by corrupting the log — so
# this is asserted by PARSING, and the value must survive the round trip.
reset_log
NASTY="$(printf 'refs/heads/quote"back\\slash\ttab')"
bash "$HOOK" committed <<< "$ZERO $OIDA $NASTY" >/dev/null 2>&1
F10="$(rows "len(rows) == 1 and rows[0]['ref'].startswith('refs/heads/quote\"back')")"
if [ "$F10" = "True" ]; then
    ok "F10 a ref name containing a quote, a backslash and a tab still yields ONE parseable JSON line with the value intact"
else
    bad "F10 hostile bytes are escaped rather than corrupting the log" "got: $F10"
fi

# ---------------------------------------------------------------------------
# F11 — the command cap, and its mark.
# ---------------------------------------------------------------------------
# The cap exists because one ordinary `git commit -m` with a long body wrote
# ~24 kB. A silent cut would look like the end of the command; the mark is
# what stops a truncated command being read as a complete one. Asserted as an
# invariant over whatever was captured: every writer_cmd is either within the
# cap, or carries the marker naming the bytes dropped. Never both absent.
reset_log
LONGARG="$(python3 -c 'print("x" * 4000)')"
bash -c 'printf "%s %s refs/heads/long\n" "$2" "$3" | bash "$1" committed >/dev/null 2>&1' \
    _ "$HOOK" "$ZERO" "$OIDA" "$LONGARG" >/dev/null 2>&1
F11="$(rows "bool(rows) and all(len(r.get('writer_cmd', '')) <= 1000 or 'bytes truncated]' in r.get('writer_cmd', '') for r in rows)")"
if [ "$F11" = "True" ]; then
    ok "F11 every captured command is within the 1000-byte cap OR carries the marker naming the bytes dropped — a truncation can never read as a whole command"
else
    bad "F11 an over-long command is capped and the truncation is marked" "got: $F11"
fi

# ---------------------------------------------------------------------------
# F12 — NEGATIVE CONTROL FOR THIS SUITE.
# ---------------------------------------------------------------------------
# F01 passing proves the recorder recorded. It does NOT prove this suite would
# notice if it stopped — a suite whose assertions cannot fail is worse than no
# suite, because it reports green over a dead recorder. So: take a copy of the
# recorder, disable ONLY its write, run F01's own assertion against it, and
# require that assertion to go RED. The engine's real hook is never modified.
BROKEN="$SANDBOX/broken-recorder.sh"
sed 's#>> "$RICHOS_REF_FORENSICS_LOG"#>> /dev/null#' "$HOOK" > "$BROKEN"
chmod +x "$BROKEN"
if cmp -s "$BROKEN" "$HOOK"; then
    bad "F12 NEGATIVE CONTROL: a recorder that stopped recording is caught" \
        "the sabotage changed nothing — the write line this control depends on has moved, so the control is no longer controlling anything. Fix the sed; do not delete the case."
else
    REPO2="$SANDBOX/control-repo"
    make_repo "$REPO2" "$BROKEN"
    reset_log
    echo one > "$REPO2/file.txt"
    git -C "$REPO2" add file.txt >/dev/null 2>&1
    CTL_RC=0
    git -C "$REPO2" commit -q -m 'first' >/dev/null 2>&1 || CTL_RC=$?
    # F01's assertion, applied verbatim to the sabotaged recorder.
    if [ "$CTL_RC" -ne 0 ]; then
        bad "F12 NEGATIVE CONTROL: a recorder that stopped recording is caught" \
            "the control commit FAILED (rc=$CTL_RC); it should have succeeded while recording nothing, so this proves the wrong thing"
    elif [ -s "$RICHOS_REF_FORENSICS_LOG" ]; then
        bad "F12 NEGATIVE CONTROL: a recorder that stopped recording is caught" \
            "the sabotaged recorder still wrote to the log — F01 would pass over a dead recorder, so this suite is NOT load-bearing"
    else
        ok "F12 NEGATIVE CONTROL: with the recorder's write disabled the commit still SUCCEEDS and the log stays EMPTY — so F01 goes red when recording stops (these assertions can fail)"
    fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
    printf 'ref-transaction-forensics: %d/%d cases pass\n' "$PASS" "$PASS"
    exit 0
fi
printf 'ref-transaction-forensics: %d passed, %d FAILED\n' "$PASS" "$FAIL"
exit 1
