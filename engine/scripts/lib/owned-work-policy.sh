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

# Register only changed verified human instructions, then reuse host-owned work.
# Dispatch selection cannot invent a brief or grant tool permissions.
owned_work_dispatch() {
    python3 "$SCRIPT_DIR/../lib/owned-dispatch.py" "$1"
}

# A config marker alone cannot disable the engine fallback. Verify that the
# direct installed adapter hook exists and runs this reviewed sidecar's bytes.
owned_work_adapter_dispatch_installed() {
    python3 - "$1" "$SCRIPT_DIR/../lib/owned-dispatch.py" <<'PYADAPTER'
import hashlib,json,shlex,sys
from pathlib import Path
try:
    root=Path(sys.argv[1]).resolve()
    config=json.loads((root/'.claude/owned-work.json').read_text())
    settings=json.loads((root/'.claude/settings.local.json').read_text())
    command=config.get('dispatch_command','')
    args=shlex.split(command)
    assert config.get('dispatch_owner')=='adapter' and len(args)==3 and args[0]=='python3'
    assert Path(args[2]).resolve()==root and Path(args[1]).name=='owned-dispatch.py'
    digest=hashlib.sha256(Path(args[1]).read_bytes()).hexdigest()
    assert digest==config.get('dispatch_script_sha256')==hashlib.sha256(Path(sys.argv[2]).read_bytes()).hexdigest()
    assert any(group.get('matcher')=='Agent' and any(h.get('type')=='command' and h.get('command')==command for h in group.get('hooks',[])) for group in settings.get('hooks',{}).get('PreToolUse',[]))
except (OSError,ValueError,TypeError,KeyError,AssertionError):
    sys.exit(1)
sys.exit(0)
PYADAPTER
}
