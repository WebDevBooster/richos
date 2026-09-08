# Explicit adoption changes dispatch dependency handling, not tool permissions.
# An ask receipt is not a CEO answer or authorization.
owned_work_policy() {
    python3 - "$1/.claude/owned-work.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    sys.exit(0 if isinstance(d, dict) and type(d.get('version')) is int and d.get('version') == 1 and d.get('enabled') is True and d.get('decision_policy') == 'dependency' else 1)
except (OSError, ValueError):
    sys.exit(1)
PY
}

# Read actual sources and ask the tool-free registrar. No prompt phrase is an
# authority predicate, and the historical ask ledger is not an input.
owned_work_dispatch() {
    python3 "$SCRIPT_DIR/../lib/owned-dispatch.py" "$1"
}
