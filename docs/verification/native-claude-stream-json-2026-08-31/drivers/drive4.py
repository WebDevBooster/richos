import json, subprocess, sys, threading, time, os
outpath=sys.argv[1]
cmd=["claude","--print","--input-format=stream-json","--output-format=stream-json",
     "--include-partial-messages","--verbose","--model","sonnet",
     "--setting-sources","","--no-session-persistence"]
env=dict(os.environ); env.pop("ANTHROPIC_API_KEY",None)
p=subprocess.Popen(cmd,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                   text=True,bufsize=1,cwd=os.path.dirname(outpath) or ".",env=env)
lines=[]; t0=time.time(); result_at=[]
def rd():
    for l in p.stdout:
        lines.append(l); dt=time.time()-t0
        try:
            o=json.loads(l); t=o.get("type")
            if t.startswith("control"): print(f"  [{dt:6.2f}] << {t}: {json.dumps(o)[:300]}",flush=True)
            elif t=="result":
                print(f"  [{dt:6.2f}] << result {o.get('subtype')} stop={o.get('stop_reason')}",flush=True); result_at.append(dt)
            elif t!="stream_event": print(f"  [{dt:6.2f}] << {t}/{o.get('subtype','')}",flush=True)
        except Exception: print("  << UNPARSEABLE",l[:150],flush=True)
threading.Thread(target=rd,daemon=True).start()
def w(o):
    print(f"  [{time.time()-t0:6.2f}] >> "+json.dumps(o)[:120],flush=True)
    p.stdin.write(json.dumps(o)+"\n"); p.stdin.flush()
w({"type":"user","message":{"role":"user","content":[{"type":"text","text":"Write a long detailed essay, at least 2000 words, about the history of the metric system. Start immediately."}]}})
time.sleep(6)
w({"type":"control_request","request_id":"req_int","request":{"subtype":"interrupt"}})
time.sleep(25)
p.stdin.close()
try: p.wait(timeout=15)
except Exception: p.kill()
err=p.stderr.read(); open(outpath,"w").write("".join(lines))
print("EXIT",p.returncode,"STDERR:",err[:600])
