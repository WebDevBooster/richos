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

# Read-only boundary for declared dependencies. The authoritative TODO parser
# supplies the current items; the ask ledger is deliberately not an input.
# This recognizes explicit markers and a small vocabulary of missing-authority
# declarations. It does not claim to classify arbitrary prose or grant authority.
owned_work_dispatch() {
    python3 -c '
import json, re, sys
try:
    payload = json.load(sys.stdin)
    if payload.get("tool_name") not in (None, "", "Agent"):
        sys.exit(0)
    prompt = payload.get("tool_input", {}).get("prompt", "")
    if not isinstance(prompt, str):
        raise ValueError("Agent prompt is not text")
except (ValueError, AttributeError) as error:
    print("CEO dependency check could not read this dispatch: " + str(error), file=sys.stderr)
    sys.exit(2)

markers = re.findall(r"(?im)^\s*depends-on-ceo\s*:\s*([^\n]*)", prompt)
# Deliberately conservative positive declarations. Negated dependency statements
# do not match; quoted examples should be kept out of the executable brief.
unanswered = bool(re.search(r"\b(?:CEO|he)\s+(?:has\s+)?(?:not|never)\s+(?:answered|approved|authorized|decided)\b", prompt, re.I))
linked = bool(re.search(r"\b(?:this\s+)?(?:dispatch|task|work)\s+(?:depends?\s+on|cannot\s+proceed\s+without|requires?)\s+(?:that|this|his|the)\s+(?:answer|decision|approval|authorization|authority)\b", prompt, re.I))
direct_dependency = bool(re.search(r"(?<!not )(?<!n\x27t )\b(?:depends?\s+on|blocked\s+(?:on|by)|cannot\s+proceed\s+without|must\s+wait\s+for|awaiting)\s+(?:the\s+)?CEO(?:\x27s|’s)?\s+(?:answer|decision|approval|authorization|authority)\b", prompt, re.I))
missing = direct_dependency or (unanswered and linked)
if missing:
    print("CEO DEPENDENCY: this dispatch explicitly declares missing CEO authority. Do not execute the dependent step. Present the concrete decision with the affected deliverable and recommendation; continue independent authorized work. An ask or deferral marker is not approval.", file=sys.stderr)
    sys.exit(2)
if not markers:
    sys.exit(0)  # Independent dispatch has no per-session question quota.
try:
    items = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    print("CEO DEPENDENCY: the declared TODO record is unreadable; this dependent dispatch cannot be verified. Repair the record or declaration; independent work may continue.", file=sys.stderr)
    sys.exit(2)
for marker in markers:
    ids = [v.strip() for v in marker.split(",")]
    for item_id in ids:
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", item_id):
            print("CEO DEPENDENCY: depends-on-ceo needs a concrete TODO id, with multiple ids separated by commas.", file=sys.stderr)
            sys.exit(2)
        matches = [item for item in items if item.get("id") == item_id]
        if len(matches) != 1:
            print("CEO DEPENDENCY: " + item_id + " is unknown or ambiguous in the authoritative pending records. Absence is not evidence of approval. Reconcile the actual CEO answer and rebrief within that authority.", file=sys.stderr)
            sys.exit(2)
        item = matches[0]
        if item.get("state") == "READY-FOR-CEO":
            print("CEO DEPENDENCY: " + item_id + " remains pending: " + item.get("title", "") + ". Asking it this session does not authorize dependent work. Record the actual CEO ruling, then rebrief within that ruling. Continue independent authorized work.", file=sys.stderr)
            sys.exit(2)
        print("CEO DEPENDENCY: " + item_id + " is not a resolved authority record. Prepare or reconcile it before claiming a CEO dependency has cleared.", file=sys.stderr)
        sys.exit(2)
' "$1"
}
