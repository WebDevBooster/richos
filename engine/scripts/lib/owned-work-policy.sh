# A repository explicitly adopts dependency-based CEO decisions. This predicate
# grants no tool permission and does not record a CEO answer.
owned_work_policy() {
    python3 - "$1/.richos-owned-work.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    sys.exit(0 if d.get('version') == 1 and d.get('enabled') is True and d.get('decision_policy') == 'dependency' else 1)
except (OSError, ValueError):
    sys.exit(1)
PY
}
