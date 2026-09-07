import json, pathlib, subprocess, tempfile, hashlib, sys
binary=pathlib.Path(sys.argv[1]).resolve()
root=pathlib.Path(tempfile.mkdtemp(prefix="richos-packaged-onboarding-"))
scope={"version":1,"entity_id":"packaged-fixture","central_root":str(root/"central"),"record_path":str(root/"config/onboarding.json"),"actions_allowed":False}
sp=root/"scope.json"
def save_scope(): sp.write_text(json.dumps(scope))
save_scope()
p=subprocess.Popen([str(binary),"--onboarding-mcp",str(sp)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
seq=0
def rpc(method,params):
 global seq
 seq+=1
 p.stdin.write(json.dumps({"jsonrpc":"2.0","id":seq,"method":method,"params":params})+"\n"); p.stdin.flush()
 r=json.loads(p.stdout.readline()); assert r["id"]==seq; assert "error" not in r,r
 return r["result"]
try:
 assert rpc("initialize",{"protocolVersion":"2025-11-25"})["serverInfo"]["name"]=="richos_onboarding"
 assert {t["name"] for t in rpc("tools/list",{})["tools"]}=={"save_company_notes","decline_onboarding"}
 args={"name":"save_company_notes","arguments":{"notes":"Packaged fixture makes notebooks. Shipping cutoff is 2 pm.","progress":"partial"}}
 assert rpc("tools/call",args)["isError"] is True
 assert not (root/"central").exists()
 scope["actions_allowed"]=True; save_scope()
 result=rpc("tools/call",args); assert result["isError"] is False,result
 details=json.loads(result["content"][0]["text"]); assert details["verified"] is True
 notes=root/"central/companies/packaged-fixture/company.md"
 before=notes.read_bytes(); assert b"Shipping cutoff is 2 pm" in before
 assert rpc("tools/call",{"name":"decline_onboarding","arguments":{}})["isError"] is False
 assert notes.read_bytes()==before
 scope["actions_allowed"]=False; save_scope()
 assert rpc("tools/call",args)["isError"] is True
 assert notes.read_bytes()==before
 p.stdin.close(); assert p.wait(timeout=5)==0
 stderr=p.stderr.read(); assert not stderr,stderr
 print(json.dumps({"result":"PASS","checks":["packaged MCP initialization","exact tool inventory","default-denied writes","granted partial save and verified readback","decline preserves notes","revoked grant refuses writes","clean protocol-only exit"],"binary":str(binary),"sha256":hashlib.sha256(binary.read_bytes()).hexdigest(),"scratch":str(root)},indent=2))
finally:
 if p.poll() is None: p.kill(); p.wait()
