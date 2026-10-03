#!/usr/bin/env bash
# P5-54: two callers arriving together fetch a URL once.
# LIB_DIR overrides which copy of ci-surface.py is tested.
set -uo pipefail
D="${LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
export D
python3 - <<'PY'
import importlib.util, os, sys, threading, time
spec = importlib.util.spec_from_file_location("cis", os.path.join(os.environ["D"], "ci-surface.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.STATE_DIR = os.path.join(os.environ.get("TMPDIR", "/tmp"), "cis-inflight-%d" % os.getpid())
api = m.Api(cache_mode="off")
n = []
def slow(path):
    n.append(path); time.sleep(0.3); return ({"ok": 1}, None)
api._get_uncoalesced = slow
ts = [threading.Thread(target=api.get, args=("/x",)) for _ in range(2)]
[t.start() for t in ts]; [t.join() for t in ts]
if len(n) == 1:
    print("ok   P5-54 one fetch for two simultaneous callers"); sys.exit(0)
print("FAIL P5-54: %d fetches" % len(n)); sys.exit(1)
PY
