#!/usr/bin/env bash
# My own mutants for the owned-work predicate added in b80f9978. Each copies the
# codex engine subtree, removes ONE property, runs ceo-asks.test.sh, and reports
# which OWN* cases went red. RICHOS_MUTATION_INNER=1 skips the nested mutation harness.
set -uo pipefail
export RICHOS_MUTATION_INNER=1 PYTHONDONTWRITEBYTECODE=1
SRC=/Users/alex/ab/richos-wt/codex-owned-outcome-completion/engine
HERE="$(cd "$(dirname "$0")" && pwd)"
mutant() {
  local name="$1" rel="$2" old="$3" new="$4"
  local dir="$HERE/$name"; rm -rf "$dir"; cp -R "$SRC" "$dir"
  python3 - "$dir/$rel" "$old" "$new" <<'PY'
import sys
p,old,new=sys.argv[1:4]
s=open(p).read()
if old not in s:
    print("MUTATION TARGET ABSENT:", old); sys.exit(3)
open(p,'w').write(s.replace(old,new,1))
PY
  if [ $? -ne 0 ]; then echo "FAIL $name (did not apply)"; return; fi
  bash "$dir/scripts/hooks/ceo-asks.test.sh" >"$dir/out.txt" 2>&1; rc=$?
  echo "== $name: suite rc=$rc; red cases:"
  if ! grep -E '^\s*FAIL' "$dir/out.txt" | sed 's/^/     /'; then echo "     (none)"; fi
}
mutant policy-always-on  scripts/lib/owned-work-policy.sh "sys.exit(0 if d.get('version') == 1" "sys.exit(0 if True or d.get('version') == 1"
mutant policy-always-off scripts/lib/owned-work-policy.sh "sys.exit(0 if d.get('version') == 1" "sys.exit(1 if True else d.get('version') == 1"
mutant guard-ignores-policy scripts/hooks/guard-ceo-ask-first.sh 'if owned_work_policy "$ENTITY_ROOT"; then exit 0; fi' 'if false; then exit 0; fi'
mutant session-start-ignores-policy scripts/hooks/session-start-ceo-ask.sh 'if owned_work_policy "$ENTITY_ROOT"; then' 'if false; then'
mutant stop-notice-ignores-policy scripts/hooks/notice-ceo-unasked.sh 'if owned_work_policy "$ENTITY_ROOT"; then exit 0; fi' 'if false; then exit 0; fi'
mutant policy-accepts-any-json scripts/lib/owned-work-policy.sh "and d.get('decision_policy') == 'dependency'" "and True"
