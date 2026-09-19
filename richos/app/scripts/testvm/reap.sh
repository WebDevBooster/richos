#!/usr/bin/env bash
# reap.sh — the backstop for VMs nobody cleaned up.
#
#   testvm/reap.sh            what it WOULD delete. Deletes nothing.
#   testvm/reap.sh --apply    delete it
#   testvm/reap.sh --notice   one line, only if there IS garbage (for session start)
#
# ===========================================================================
# WHY A SECOND CLEANER EXISTS WHEN stop.sh ALREADY CLEANS
# ===========================================================================
# CEO §54, 2026-09-18: garbage is ALWAYS cleaned up, or Rich gets a massive
# alert. An agent that is killed mid-run — quota pause, crash, a terminated
# session — never reaches its own stop.sh. That is not a hypothetical: one
# killed harness run left 105 GB in $TMPDIR overnight, which is the incident
# §54 was written for.
#
# A VM clone is worse than a directory: it holds 7 GB of RAM while its runner
# lives. So cleanup cannot depend on the thing that made the mess still being
# alive to tidy it.
#
# The engine's scratch-reaper does NOT cover this. Its first wall is
# containment in a declared scratch root, and ~/.richos-testvm is deliberately
# not one — the 25 GB base image must survive every sweep. So this harness
# cleans up after itself, and this is that cleaner.
#
# NOT DELETING IS THE DEFAULT, deliberately: a cleaner whose safe mode needs a
# flag deletes something precious the first time somebody types it wrong.
# ===========================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"
set +e

APPLY=0; NOTICE=0
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    --notice) NOTICE=1 ;;
    --dry-run) APPLY=0 ;;
    *) die "unknown argument: $a" ;;
  esac
done

[ -x "$TART_BIN" ] || { [ "$NOTICE" -eq 1 ] && exit 0; die "tart not installed"; }
preflight_tart

VICTIMS=(); KEPT=()

while read -r name; do
  [ -n "$name" ] || continue
  # WALL 1: never the base image. It is the template, it costs a 25 GB
  # download, and nothing about it is garbage.
  if [ "$name" = "$TESTVM_BASE_VM" ]; then KEPT+=("$name — the base template"); continue; fi
  # WALL 2: only VMs this harness made. A VM someone created by hand for their
  # own reasons is not ours to delete.
  case "$name" in richos-test-*) ;; *) KEPT+=("$name — not created by this harness"); continue ;; esac
  # WALL 3: never a RUNNING VM. A running guest belongs to a live agent that is
  # mid-proof; killing it destroys work in progress and proves nothing.
  if vm_running "$name" 2>/dev/null; then KEPT+=("$name — RUNNING, an agent is using it"); continue; fi
  VICTIMS+=("$name")
done < <("$TART_BIN" list --format json 2>/dev/null | python3 -c "
import json,sys
try: rows=json.load(sys.stdin)
except Exception: rows=[]
for r in rows:
    if r.get('Source')=='local': print(r.get('Name',''))
")

# Run-state directories whose VM is gone.
ORPHAN_STATE=()
if [ -d "$TESTVM_RUN" ]; then
  for d in "$TESTVM_RUN"/*; do
    [ -d "$d" ] || continue
    n="$(basename "$d")"
    vm_exists "$n" 2>/dev/null || ORPHAN_STATE+=("$d")
  done
fi

TOTAL=$(( ${#VICTIMS[@]} + ${#ORPHAN_STATE[@]} ))

# macOS ships bash 3.2, where expanding an EMPTY array under `set -u` is an
# "unbound variable" error rather than an empty list. The clean-machine case —
# nothing to reap — is precisely the empty case, so the naive "${arr[@]}" makes
# this script fail exactly when it has good news. ${arr[@]+"${arr[@]}"} expands
# to nothing when the array is empty and to the quoted elements otherwise.
if [ "$NOTICE" -eq 1 ]; then
  [ "$TOTAL" -eq 0 ] && exit 0
  echo "testvm: $TOTAL leftover item(s) — ${VICTIMS[*]+${VICTIMS[*]}} ${ORPHAN_STATE[*]+${ORPHAN_STATE[*]}} — run richos/app/scripts/testvm/reap.sh --apply"
  exit 0
fi

echo "testvm reap plan  ($(date -u +%FT%TZ))"
echo "  root: $TESTVM_ROOT"
for k in ${KEPT[@]+"${KEPT[@]}"};   do echo "  KEEP   $k"; done
for v in ${VICTIMS[@]+"${VICTIMS[@]}"}; do echo "  DELETE VM $v (stopped clone)"; done
for o in ${ORPHAN_STATE[@]+"${ORPHAN_STATE[@]}"}; do echo "  DELETE state $o (no such VM)"; done
[ "$TOTAL" -eq 0 ] && { echo "  nothing to reclaim."; exit 0; }

if [ "$APPLY" -eq 0 ]; then
  echo "  (dry run — nothing deleted. Re-run with --apply.)"
  exit 0
fi

FAILED=()
for v in ${VICTIMS[@]+"${VICTIMS[@]}"}; do
  tart delete "$v" 2>/dev/null
  vm_exists "$v" 2>/dev/null && FAILED+=("VM $v")
done
for o in ${ORPHAN_STATE[@]+"${ORPHAN_STATE[@]}"}; do
  rm -rf "$o" 2>/dev/null
  [ -e "$o" ] && FAILED+=("state $o")
done

if [ ${#FAILED[@]} -eq 0 ]; then
  echo "  applied: $TOTAL item(s) reclaimed."
  exit 0
fi
ALERT="$TESTVM_ROOT/CLEANUP-FAILED-reap-$(date -u +%Y%m%dT%H%M%SZ).txt"
{ echo "TESTVM REAP FAILED — $(date -u +%FT%TZ)"; for f in ${FAILED[@]+"${FAILED[@]}"}; do echo "  - $f"; done; } | tee "$ALERT" >&2
echo "MASSIVE ALERT: testvm reap could not delete the above. Rich: delete by hand. Record: $ALERT" >&2
exit 1
