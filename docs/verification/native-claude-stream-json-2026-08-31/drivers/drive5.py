import json, subprocess, sys, threading, time, os
outpath=sys.argv[1]
cmd=["claude","--print","--input-format=stream-json","--output-format=stream-json",
     "--include-partial-messages","--verbose","--model","sonnet",
     "--setting-sources","","--no-session-persistence"]
env=dict(os.environ); env.pop("ANTHROPIC_API_KEY",None)
p=subprocess.Popen(cmd,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                   text=True,bufsize=1,cwd=os.path.dirname(outpath) or ".",env=env)
lines=[]; t0=time.time()
def rd():
    for l in p.stdout:
        lines.append(l); dt=time.time()-t0
        try:
            o=json.loads(l); t=o.get("type")
            if t.startswith("control"): print(f"  [{dt:6.2f}] << {t}: {json.dumps(o)[:200]}",flush=True)
            elif t=="result": print(f"  [{dt:6.2f}] << result {o.get('subtype')} stop={o.get('stop_reason')} text={repr(o.get('result'))[:60]}",flush=True)
            elif t=="assistant":
                for c in o["message"]["content"]:
                    if c.get("type")=="text": print(f"  [{dt:6.2f}] << assistant TEXT {repr(c['text'])[:70]}",flush=True)
            elif t!="stream_event": print(f"  [{dt:6.2f}] << {t}/{o.get('subtype','')}",flush=True)
        except Exception: print("  << UNPARSEABLE",l[:150],flush=True)
    print(f"  [{time.time()-t0:6.2f}] << STDOUT EOF",flush=True)
threading.Thread(target=rd,daemon=True).start()
def w(o):
    print(f"  [{time.time()-t0:6.2f}] >> "+json.dumps(o)[:110],flush=True)
    try:
        p.stdin.write(json.dumps(o)+"\n"); p.stdin.flush()
    except Exception as e:
        print(f"  [{time.time()-t0:6.2f}] >> WRITE FAILED: {e}",flush=True)
def usr(t): w({"type":"user","message":{"role":"user","content":[{"type":"text","text":t}]}})
usr("Remember the number 8813. Write a 2000-word essay on the history of the metre. Start immediately.")
time.sleep(6)
w({"type":"control_request","request_id":"req_int","request":{"subtype":"interrupt"}})
time.sleep(4)
print(f"  [{time.time()-t0:6.2f}] -- poll after interrupt: {p.poll()}",flush=True)
usr("Stop the essay. What number did I ask you to remember? Reply with just the digits.")
time.sleep(30)
print(f"  [{time.time()-t0:6.2f}] -- poll at end: {p.poll()}",flush=True)
p.stdin.close()
try: p.wait(timeout=15)
except Exception: p.kill()
err=p.stderr.read(); open(outpath,"w").write("".join(lines))
print("EXIT",p.returncode,"STDERR:",err[:600])
