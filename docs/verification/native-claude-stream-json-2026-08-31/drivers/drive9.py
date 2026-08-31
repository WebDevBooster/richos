import json, subprocess, sys, threading, time, os
outpath=sys.argv[1]; extra=sys.argv[2:]
cmd=["claude","--print","--input-format=stream-json","--output-format=stream-json",
     "--verbose","--model","sonnet","--setting-sources","","--no-session-persistence"]+extra
env=dict(os.environ); env.pop("ANTHROPIC_API_KEY",None)
p=subprocess.Popen(cmd,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                   text=True,bufsize=1,cwd="/private/tmp/claude-501/-Users-alex-ab-femcboost/8a598936-e161-4b29-a91c-5a02800052aa/scratchpad/probecwd",env=env)
lines=[]; t0=time.time(); lock=threading.Lock()
def w(o):
    print(f"  [{time.time()-t0:6.2f}] >> "+json.dumps(o)[:170],flush=True)
    with lock:
        p.stdin.write(json.dumps(o)+"\n"); p.stdin.flush()
def rd():
    for l in p.stdout:
        lines.append(l); dt=time.time()-t0
        try:
            o=json.loads(l); t=o.get("type")
            if t=="control_request":
                print(f"  [{dt:6.2f}] << CONTROL_REQUEST {json.dumps(o)[:600]}",flush=True)
                # auto-approve, mirroring acp.rs's in-harness policy
                w({"type":"control_response","response":{"subtype":"success","request_id":o["request_id"],
                   "response":{"behavior":"allow","updatedInput":o["request"].get("input",{})}}})
            elif t=="control_response": print(f"  [{dt:6.2f}] << control_response {json.dumps(o)[:200]}",flush=True)
            elif t=="result": print(f"  [{dt:6.2f}] << result {o.get('subtype')} stop={o.get('stop_reason')} denials={o.get('permission_denials')} text={repr(o.get('result'))[:60]}",flush=True)
            elif t=="assistant":
                for c in o["message"]["content"]:
                    print(f"  [{dt:6.2f}] << assistant {c.get('type')} {json.dumps(c)[:120]}",flush=True)
            elif t=="user": print(f"  [{dt:6.2f}] << user {json.dumps(o['message']['content'])[:160]}",flush=True)
            elif t!="stream_event": print(f"  [{dt:6.2f}] << {t}/{o.get('subtype','')}",flush=True)
        except Exception as e: print("  << UNPARSEABLE",l[:150],e,flush=True)
threading.Thread(target=rd,daemon=True).start()
w({"type":"control_request","request_id":"req_init","request":{"subtype":"initialize","hooks":{}}})
time.sleep(3)
w({"type":"user","message":{"role":"user","content":[{"type":"text","text":"Think hard first, then do all three yourself, now, without asking. 1. Use the TodoWrite tool to create a todo list of these three items and keep it updated as you go. 2. Use the Edit tool to change the word beta to BETA in the file edit-target.txt in your current directory. 3. Reply with one short sentence."}]}})
time.sleep(50); p.stdin.close()
try: p.wait(timeout=15)
except Exception: p.kill()
err=p.stderr.read(); open(outpath,"w").write("".join(lines))
print("EXIT",p.returncode,"STDERR:",err[:600])
