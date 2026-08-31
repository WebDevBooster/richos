import json, subprocess, sys, threading, time, os
outpath=sys.argv[1]; extra=sys.argv[2:]
cmd=["claude","--print","--input-format=stream-json","--output-format=stream-json",
     "--include-partial-messages","--verbose","--model","sonnet",
     "--setting-sources","","--no-session-persistence"]+extra
env=dict(os.environ); env.pop("ANTHROPIC_API_KEY",None)
p=subprocess.Popen(cmd,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                   text=True,bufsize=1,cwd=os.path.dirname(outpath) or ".",env=env)
lines=[]
def rd():
    for l in p.stdout:
        lines.append(l)
        try:
            o=json.loads(l); t=o.get("type")
            if t.startswith("control"): print(f"  << {t}: {json.dumps(o)[:700]}",flush=True)
            elif t=="result": print(f"  << result {o.get('subtype')} stop={o.get('stop_reason')}",flush=True)
            elif t!="stream_event": print(f"  << {t}/{o.get('subtype','')}",flush=True)
        except Exception: print("  << UNPARSEABLE",l[:150],flush=True)
threading.Thread(target=rd,daemon=True).start()
def w(o):
    print("  >> "+json.dumps(o)[:150],flush=True)
    p.stdin.write(json.dumps(o)+"\n"); p.stdin.flush()
w({"type":"control_request","request_id":"req_1","request":{"subtype":"initialize"}})
time.sleep(4)
w({"type":"user","message":{"role":"user","content":[{"type":"text","text":"Reply with just: CTRL-OK"}]}})
time.sleep(20)
p.stdin.close()
try: p.wait(timeout=15)
except Exception: p.kill()
err=p.stderr.read(); open(outpath,"w").write("".join(lines))
print("EXIT",p.returncode,"STDERR:",err[:600])
