import json, subprocess, sys, threading, time, os
outpath = sys.argv[1]; prompt = sys.argv[2]; extra = sys.argv[3:]
cmd = ["claude","--print","--input-format=stream-json","--output-format=stream-json",
       "--include-partial-messages","--verbose","--model","sonnet",
       "--setting-sources","","--no-session-persistence"] + extra
env = dict(os.environ); env.pop("ANTHROPIC_API_KEY", None)
p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                     text=True, bufsize=1, cwd=os.path.dirname(outpath) or ".", env=env)
lines=[]; done=threading.Event()
def rd():
    for l in p.stdout:
        lines.append(l)
        try:
            o=json.loads(l); t=o.get("type")
            if t in ("control_request","control_response","control_cancel_request"):
                print(f"  << !!{t}!! {json.dumps(o)[:400]}", flush=True)
            elif t=="result":
                print(f"  << result {o.get('subtype')} stop={o.get('stop_reason')}", flush=True); done.set()
            elif t not in ("stream_event",):
                print(f"  << {t}/{o.get('subtype','')}", flush=True)
        except Exception:
            print("  << UNPARSEABLE", l[:120], flush=True)
threading.Thread(target=rd, daemon=True).start()
m={"type":"user","message":{"role":"user","content":[{"type":"text","text":prompt}]}}
p.stdin.write(json.dumps(m)+"\n"); p.stdin.flush()
done.wait(timeout=120)
time.sleep(2); p.stdin.close()
try: p.wait(timeout=15)
except Exception: p.kill()
err=p.stderr.read(); open(outpath,"w").write("".join(lines))
print("EXIT",p.returncode,"STDERR:",err[:600])
