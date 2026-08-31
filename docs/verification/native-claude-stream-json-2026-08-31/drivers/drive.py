import json, subprocess, sys, threading, time, os
outpath = sys.argv[1]
extra = sys.argv[2:] 
cmd = ["claude","--print","--input-format=stream-json","--output-format=stream-json",
       "--include-partial-messages","--verbose","--model","sonnet",
       "--setting-sources","","--no-session-persistence"] + extra
env = dict(os.environ); env.pop("ANTHROPIC_API_KEY", None)
p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                     text=True, bufsize=1, cwd=os.path.dirname(outpath) or ".", env=env)
lines=[]
def rd():
    for l in p.stdout:
        lines.append(l)
        try:
            o=json.loads(l)
            t=o.get("type")
            print(f"  << {t}/{o.get('subtype','')}", flush=True)
        except Exception as e:
            print("  << UNPARSEABLE", l[:100], flush=True)
threading.Thread(target=rd, daemon=True).start()
def send(text):
    m={"type":"user","message":{"role":"user","content":[{"type":"text","text":text}]}}
    print(f"  >> {text[:60]}", flush=True)
    p.stdin.write(json.dumps(m)+"\n"); p.stdin.flush()
send("Remember the number 4271. Reply with just: FIRST-OK")
time.sleep(25)
send("What number did I ask you to remember? Reply with just the digits.")
time.sleep(25)
p.stdin.close()
try: p.wait(timeout=20)
except Exception: p.kill()
err = p.stderr.read()
open(outpath,"w").write("".join(lines))
print("EXIT", p.returncode, "STDERR:", err[:500])
