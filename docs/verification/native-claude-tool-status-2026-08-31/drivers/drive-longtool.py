# Long-running-tool driver. Same shape as the 2026-08-31 spike's drive7.py (control
# initialize, one turn, can_use_tool auto-allowed with acp.rs's first-`allow*` policy),
# with ONE addition: every stdout line is stamped with the offset at which we READ it,
# and the offsets are written next to the raw JSONL. C2 is a question about what arrives
# BETWEEN two events, so a capture without timestamps cannot answer it.
#
# usage: drive-longtool.py <out.jsonl> <prompt> <wait_seconds> [extra claude args...]
import json, subprocess, sys, threading, time, os

outpath = sys.argv[1]; prompt = sys.argv[2]; wait_s = float(sys.argv[3]); extra = sys.argv[4:]
CWD = "/private/tmp/claude-501/-Users-alex-ab-femcboost/8a598936-e161-4b29-a91c-5a02800052aa/scratchpad/probecwd"
cmd = ["claude", "--print", "--input-format=stream-json", "--output-format=stream-json",
       "--include-partial-messages", "--verbose", "--model", "sonnet",
       "--setting-sources", "", "--no-session-persistence",
       "--permission-prompt-tool", "stdio"] + extra
env = dict(os.environ); env.pop("ANTHROPIC_API_KEY", None)
p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                     text=True, bufsize=1, cwd=CWD, env=env)
lines = []           # (offset_s, raw_line)
t0 = time.time(); lock = threading.Lock(); done = threading.Event()

def w(o):
    print(f"  [{time.time()-t0:7.3f}] >> {json.dumps(o)[:170]}", flush=True)
    with lock:
        p.stdin.write(json.dumps(o) + "\n"); p.stdin.flush()

def rd():
    for l in p.stdout:
        dt = time.time() - t0
        lines.append((dt, l))
        try:
            o = json.loads(l); t = o.get("type")
        except Exception:
            print(f"  [{dt:7.3f}] << UNPARSEABLE {l[:150]}", flush=True); continue
        if t == "control_request":
            print(f"  [{dt:7.3f}] << CONTROL_REQUEST {json.dumps(o)[:400]}", flush=True)
            w({"type": "control_response", "response": {"subtype": "success",
               "request_id": o["request_id"],
               "response": {"behavior": "allow", "updatedInput": o["request"].get("input", {})}}})
        elif t == "tool_progress":
            print(f"  [{dt:7.3f}] << *** TOOL_PROGRESS *** {json.dumps(o)}", flush=True)
        elif t == "result":
            print(f"  [{dt:7.3f}] << result {o.get('subtype')} stop={o.get('stop_reason')} "
                  f"terminal={o.get('terminal_reason')} text={repr(o.get('result'))[:70]}", flush=True)
            done.set()
        elif t == "assistant":
            for c in o["message"]["content"]:
                print(f"  [{dt:7.3f}] << assistant {c.get('type')} {json.dumps(c)[:160]}", flush=True)
        elif t == "user":
            print(f"  [{dt:7.3f}] << user {json.dumps(o['message']['content'])[:200]}", flush=True)
        elif t == "stream_event":
            ev = o.get("event", {})
            if ev.get("type") not in ("content_block_delta",):
                print(f"  [{dt:7.3f}] << stream_event/{ev.get('type')}", flush=True)
        else:
            print(f"  [{dt:7.3f}] << {t}/{o.get('subtype','')}", flush=True)
    print(f"  [{time.time()-t0:7.3f}] [reader] stdout EOF", flush=True)

threading.Thread(target=rd, daemon=True).start()
w({"type": "control_request", "request_id": "req_init", "request": {"subtype": "initialize", "hooks": {}}})
time.sleep(3)
w({"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": prompt}]}})
done.wait(timeout=wait_s)
time.sleep(2); p.stdin.close()
try: p.wait(timeout=15)
except Exception: p.kill()
err = p.stderr.read()
with open(outpath, "w") as f:
    for _, l in lines: f.write(l)
with open(outpath.replace(".jsonl", ".timings.tsv"), "w") as f:
    f.write("offset_s\ttype\tsubtype\n")
    for dt, l in lines:
        try: v = json.loads(l)
        except Exception: continue
        ty = v.get("type", "?")
        sub = (v.get("event", {}) or {}).get("type", "") if ty == "stream_event" else (
              (v.get("request", {}) or {}).get("subtype", "") if ty == "control_request" else v.get("subtype", "") or "")
        f.write(f"{dt:.3f}\t{ty}\t{sub}\n")
print("EXIT", p.returncode, "LINES", len(lines), "STDERR:", err[:600])
