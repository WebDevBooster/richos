import json, subprocess, sys, threading, time, os
outpath=sys.argv[1]
cmd=["claude","--print","--input-format=stream-json","--output-format=stream-json",
     "--verbose","--model","sonnet","--setting-sources","","--no-session-persistence"]
env=dict(os.environ); env.pop("ANTHROPIC_API_KEY",None)
p=subprocess.Popen(cmd,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                   text=True,bufsize=1,cwd=os.path.dirname(sys.argv[0]) or ".",env=env)
lines=[];t0=time.time()
def rd():
    for l in p.stdout:
        lines.append(l)
        try:
            o=json.loads(l)
            print(f"  [{time.time()-t0:6.2f}] << {json.dumps(o)[:400]}",flush=True)
        except Exception: print("  << UNPARSEABLE",l[:120],flush=True)
threading.Thread(target=rd,daemon=True).start()
def w(o):
    print(f"  [{time.time()-t0:6.2f}] >> "+json.dumps(o)[:150],flush=True)
    p.stdin.write(json.dumps(o)+"\n"); p.stdin.flush()
w({"type":"control_request","request_id":"c1","request":{"subtype":"set_permission_mode","mode":"bypassPermissions"}})
time.sleep(3)
w({"type":"control_request","request_id":"c2","request":{"subtype":"set_model","model":"opus"}})
time.sleep(3)
w({"type":"control_request","request_id":"c3","request":{"subtype":"no_such_subtype_at_all"}})
time.sleep(3)
p.stdin.write("this is not json at all\n"); p.stdin.flush()
time.sleep(3)
p.stdin.close()
try: p.wait(timeout=15)
except Exception: p.kill()
err=p.stderr.read(); open(outpath,"w").write("".join(lines))
print("EXIT",p.returncode,"STDERR:",err[:800])
