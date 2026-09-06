#!/usr/bin/env python3
"""Drive ONE turn of `claude` over the exact stream-json stdio wire RichOS uses.

Reproduces `app/crates/richos-core/src/native.rs::child_args` verbatim (richos main 36e48a3),
with the `--setting-sources` value as the single manipulated variable.

Usage: drive.py --cwd DIR --sources "|project|OMIT|user,project,local" --prompt TEXT --out RAW.jsonl
(an empty --sources value reproduces the app's `--setting-sources ''`)
"""
import argparse, json, os, subprocess, sys, threading, uuid, time

ap = argparse.ArgumentParser()
ap.add_argument("--cwd", required=True)
ap.add_argument("--sources", required=True, help="value for --setting-sources, or OMIT to drop the flag")
ap.add_argument("--prompt", required=True)
ap.add_argument("--out", required=True)
ap.add_argument("--bin", default=os.path.expanduser("~/.local/bin/claude"))
ap.add_argument("--timeout", type=float, default=180.0)
a = ap.parse_args()

session_id = str(uuid.uuid4())
args = ["--print", "--input-format=stream-json", "--output-format=stream-json",
        "--include-partial-messages", "--verbose"]
if a.sources != "OMIT":
    args += ["--setting-sources", a.sources]
args += ["--no-session-persistence", "--session-id", session_id,
         "--permission-prompt-tool", "stdio"]

print("[drive] bin  =", a.bin, file=sys.stderr)
print("[drive] cwd  =", a.cwd, file=sys.stderr)
print("[drive] argv =", json.dumps(args), file=sys.stderr)

env = dict(os.environ)
env.pop("ANTHROPIC_API_KEY", None)   # subscription OAuth only, as the 2026-08-31 spike ran it

p = subprocess.Popen([a.bin] + args, cwd=a.cwd, env=env,
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                     text=True, bufsize=1)

raw = open(a.out, "w")
frames = []
denied = []
done = threading.Event()
result_frame = {}

def send(obj):
    p.stdin.write(json.dumps(obj) + "\n"); p.stdin.flush()

def reader():
    for line in p.stdout:
        line = line.rstrip("\n")
        if not line.strip():
            continue
        raw.write(line + "\n"); raw.flush()
        try:
            f = json.loads(line)
        except Exception:
            continue
        frames.append(f)
        # THE ONE DELIBERATE DEVIATION FROM native.rs: the app's seam ALLOWS every
        # `can_use_tool` (native.rs::decide_permission). This harness DENIES, so the
        # child cannot read the sentinel file off disk and hand it back — the only
        # route from the file to the reply is the context the binary itself loaded.
        if f.get("type") == "control_request" and \
           f.get("request", {}).get("subtype") == "can_use_tool":
            send({"type": "control_response",
                  "response": {"subtype": "success", "request_id": f.get("request_id"),
                               "response": {"behavior": "deny",
                                            "message": "tools are denied in this measurement"}}})
            denied.append(f.get("request", {}).get("tool_name"))
        if f.get("type") == "result":
            result_frame.update(f)
            done.set()
    done.set()

errlines = []
def errreader():
    for line in p.stderr:
        errlines.append(line.rstrip("\n"))

threading.Thread(target=reader, daemon=True).start()
threading.Thread(target=errreader, daemon=True).start()

# handshake, the shape of native.rs::handshake
send({"type": "control_request", "request_id": "req_init",
      "request": {"subtype": "initialize", "hooks": {}}})
t0 = time.time()
while time.time() - t0 < 30:
    if any(f.get("type") == "control_response" for f in frames):
        break
    time.sleep(0.02)
else:
    print("[drive] HANDSHAKE TIMEOUT; stderr:", "\n".join(errlines), file=sys.stderr)
    p.kill(); sys.exit(2)
print("[drive] handshake ok in %.3fs" % (time.time() - t0), file=sys.stderr)

send({"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": a.prompt}]}})
done.wait(a.timeout)

try:
    p.stdin.close()
except Exception:
    pass
try:
    p.wait(timeout=10)
except Exception:
    p.kill()
raw.close()

text = []
for f in frames:
    if f.get("type") == "assistant":
        for c in f.get("message", {}).get("content", []):
            if c.get("type") == "text":
                text.append(c["text"])
print("----- ASSISTANT TEXT -----")
print("".join(text))
print("----- END -----")
print("[drive] result subtype =", result_frame.get("subtype"), "stop_reason =", result_frame.get("stop_reason"), file=sys.stderr)
print("[drive] tool requests denied =", denied, file=sys.stderr)
if errlines:
    print("[drive] stderr tail:", "\n".join(errlines[-10:]), file=sys.stderr)
