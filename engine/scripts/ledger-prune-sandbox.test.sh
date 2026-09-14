#!/usr/bin/env bash
#
# ledger-prune-sandbox.test.sh — PROVE THE PRUNER REFUSES BEFORE IT PROVES IT REMOVES.
#
# scripts/ledger-prune-sandbox.py deletes rows from the operator's durable
# ownership ledger. A cleaner for a record like that is judged on what it
# LEAVES, not on what it clears, so every case below that matters is a row the
# tool must NOT touch. A pruner that removed everything would pass a
# "did it shrink the file" check and destroy the machine's ownership history.
#
# The cases, in the order they matter:
#
#   P1  a row naming a REAL workspace                      -> KEPT
#   P2  a row naming BOTH a sandbox and a real path        -> KEPT (ambiguous)
#   P3  a row whose sandbox directory STILL EXISTS         -> KEPT (may be live)
#   P4  an unparseable line                                -> KEPT
#   P5  a row naming no path at all                        -> KEPT
#   P6  a row mentioning codex                             -> KEPT (CEO section 31)
#   P7  a row whose paths are ALL dead sandboxes           -> REMOVED
#   P8  the surviving rows are BYTE-IDENTICAL               (append-only respected)
#   P9  a second run removes nothing                        (idempotent)
#   P10 the census mode changes nothing at all
#   P11 the backup is written and holds every original row
#
# P7 is the positive control on the whole predicate: without it, a tool that
# simply never deletes would pass P1-P6 and look perfect.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$SCRIPT_DIR/ledger-prune-sandbox.py"
PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t ledger-prune-test.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '          %s\n' "$2"; FAIL=$((FAIL + 1)); }

if [ ! -x "$TOOL" ]; then
    printf '  FAIL  the pruner is not present/executable: %s\n' "$TOOL"
    exit 1
fi

# A sandbox directory that EXISTS, to stand in for a suite running right now.
LIVE_TMP="$(cd "$(mktemp -d -t ledger-prune-live.XXXXXX)" && pwd -P)"
# A temp path that is guaranteed NOT to exist.
DEAD_TMP="${TMPDIR:-/tmp}/ledger-prune-gone.XXXXXX.deadbeef"
rm -rf "$DEAD_TMP" 2>/dev/null || true

LEDGER="$SANDBOX/worktree-ledger.jsonl"
BACKUPS="$SANDBOX/backups"

{
  # P1 — a real workspace row.
  printf '{"agent_id": "a111", "event": "registered", "source": "create-teammate-worktree.sh", "teammate": "zach-opus-n7", "ts": "2026-09-14T00:00:00+00:00", "worktree": "/Users/alex/ab/richos-wt/zach-opus-n7"}\n'
  # P2 — sandbox AND real path in one row.
  printf '{"agent_id": "a222", "event": "finished", "source": "worker-ended-handoff.sh", "ts": "2026-09-14T00:00:01+00:00", "worktree": "%s/repo", "workspaces": ["/Users/alex/ab/richos-wt/real-one"]}\n' "$DEAD_TMP"
  # P3 — sandbox that still exists on disk.
  printf '{"agent_id": "a333", "event": "finished", "source": "worker-ended-handoff.sh", "ts": "2026-09-14T00:00:02+00:00", "worktree": "%s"}\n' "$LIVE_TMP"
  # P4 — unparseable.
  printf 'this is not json at all {{{\n'
  # P5 — no path field.
  printf '{"agent_id": "a555", "event": "finished", "source": "task-completed-handoff.sh", "ts": "2026-09-14T00:00:03+00:00"}\n'
  # P6 — a dead sandbox row that mentions codex.
  printf '{"agent_id": "a666", "event": "registered", "source": "detect-nonnative-worktree.sh", "branch": "codex/orchestrator-dispatch-recovery", "ts": "2026-09-14T00:00:04+00:00", "worktree": "%s/codexwork"}\n' "$DEAD_TMP"
  # P7 — three provably dead sandbox rows.
  printf '{"agent_id": "", "event": "finished", "source": "worker-ended-handoff.sh", "ts": "2026-09-14T00:00:05+00:00", "worktree": "%s/deadrow-a"}\n' "$DEAD_TMP"
  printf '{"agent_id": "", "event": "finished", "source": "teammate-idle-handoff.sh", "ts": "2026-09-14T00:00:06+00:00", "worktree": "%s/deadrow-b"}\n' "$DEAD_TMP"
  printf '{"agent_id": "", "event": "registered", "source": "detect-nonnative-worktree.sh", "repo": "%s/deadrow-c", "teammate": "reed-sonnet-sc1", "ts": "2026-09-14T00:00:07+00:00", "worktree": ""}\n' "$DEAD_TMP"
} > "$LEDGER"

BEFORE_N="$(wc -l < "$LEDGER" | tr -d ' ')"
cp "$LEDGER" "$SANDBOX/pristine.jsonl"

# --- P10: census mode changes nothing ------------------------------------
CENSUS_OUT="$("$TOOL" --ledger "$LEDGER" --backup-dir "$BACKUPS" 2>&1)" || true
if cmp -s "$LEDGER" "$SANDBOX/pristine.jsonl"; then
    ok "P10 census mode left the ledger byte-identical"
else
    bad "P10 census mode MODIFIED the ledger" "$CENSUS_OUT"
fi
if printf '%s' "$CENSUS_OUT" | grep -q 'provably dead: 3'; then
    ok "P10 census counted the 3 dead rows without touching them"
else
    bad "P10 census miscounted" "$CENSUS_OUT"
fi

# --- the real run --------------------------------------------------------
RUN1="$("$TOOL" --ledger "$LEDGER" --backup-dir "$BACKUPS" --apply 2>&1)" || true
AFTER_N="$(wc -l < "$LEDGER" | tr -d ' ')"

keep_check() { # name, grep-pattern, label
    if grep -q "$2" "$LEDGER"; then ok "$1 $3"; else bad "$1 $3 — IT WAS REMOVED" "$RUN1"; fi
}
keep_check "P1 " '"a111"' "a row naming a real workspace was kept"
keep_check "P2 " '"a222"' "a row naming both a sandbox and a real path was kept"
keep_check "P3 " '"a333"' "a row whose sandbox still exists was kept"
keep_check "P4 " 'not json at all' "an unparseable line was kept"
keep_check "P5 " '"a555"' "a row naming no path was kept"
keep_check "P6 " '"a666"' "a codex-bearing dead sandbox row was kept"

# --- P7: the positive control -------------------------------------------
if grep -q "$DEAD_TMP/deadrow-" "$LEDGER"; then
    bad "P7  a provably dead sandbox row SURVIVED — the predicate never fires, so P1-P6 prove nothing" "$RUN1"
elif [ "$AFTER_N" -eq $((BEFORE_N - 3)) ]; then
    ok "P7  exactly the 3 provably dead rows were removed ($BEFORE_N -> $AFTER_N)"
else
    bad "P7  wrong number of rows removed: $BEFORE_N -> $AFTER_N (expected $((BEFORE_N - 3)))" "$RUN1"
fi

# --- P8: survivors are byte-identical ------------------------------------
EXPECTED="$SANDBOX/expected.jsonl"
grep -v -e "$DEAD_TMP/deadrow-" "$SANDBOX/pristine.jsonl" > "$EXPECTED" || true
if cmp -s "$LEDGER" "$EXPECTED"; then
    ok "P8  every surviving row is byte-identical to the original"
else
    bad "P8  a surviving row was rewritten" "$(diff "$EXPECTED" "$LEDGER" | head -5)"
fi

# --- P11: the backup ------------------------------------------------------
BK="$(ls "$BACKUPS"/worktree-ledger.*.jsonl 2>/dev/null | head -1 || true)"
if [ -z "$BK" ]; then
    bad "P11 no backup was written to $BACKUPS" "$RUN1"
elif cmp -s "$BK" "$SANDBOX/pristine.jsonl"; then
    ok "P11 the backup holds every original row, byte-identical ($BK)"
else
    bad "P11 the backup does not match the original ledger" "$BK"
fi

# --- P9: idempotent -------------------------------------------------------
cp "$LEDGER" "$SANDBOX/after-run1.jsonl"
RUN2="$("$TOOL" --ledger "$LEDGER" --backup-dir "$BACKUPS" --apply 2>&1)" || true
if cmp -s "$LEDGER" "$SANDBOX/after-run1.jsonl"; then
    ok "P9  a second --apply run changed nothing (idempotent)"
else
    bad "P9  a second run changed the file" "$RUN2"
fi
if printf '%s' "$RUN2" | grep -q 'nothing to remove'; then
    ok "P9  the second run said so rather than rewriting silently"
else
    bad "P9  the second run did not report an empty result" "$RUN2"
fi

rm -rf "$LIVE_TMP"
printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
