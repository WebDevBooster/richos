import json,subprocess,sys,time
from pathlib import Path

import os

def identities():
 rows={}
 result=subprocess.run(['ps','-axo','pid=,ppid=,pgid=,stat=,lstart=,comm='],capture_output=True,text=True,check=True,env={**os.environ,'TZ':'UTC'})
 for line in result.stdout.splitlines():
  p=line.strip().split(None,9)
  if len(p)==10: rows[int(p[0])]={'pid':int(p[0]),'ppid':int(p[1]),'pgid':int(p[2]),'status':p[3],'started':' '.join(p[4:9]),'command':p[9]}
 return rows

def lineage():
 rows=identities(); result=[]; pid=os.getpid()
 while pid in rows:
  row=rows[pid]; result.append(row)
  if os.path.basename(row['command'])=='claude': break
  pid=row['ppid']
 return result

import fcntl
from datetime import datetime

def equal(left, right):
 return bool(left and right and all(left.get(k)==right.get(k) for k in ('pid','pgid','started','command')))

def emit(path, event):
 with path.open('a') as stream: stream.write(json.dumps(event)+'\n')

def main():
 payload=json.load(sys.stdin); control_path=Path(sys.argv[1]); events_path=Path(sys.argv[2])
 if not control_path.exists(): return 0
 control=json.loads(control_path.read_text()); owner=control['leader']; caller=lineage()
 read=control.get('read_receipt',{}); call=read.get('call',{}); result=read.get('result',{})
 call_parts=call.get('message',{}).get('content',[]); result_parts=result.get('message',{}).get('content',[])
 valid_read=(call.get('type')=='assistant' and result.get('type')=='user' and call.get('uuid') and
  result.get('sourceToolAssistantUUID')==call['uuid'] and
  call.get('sessionId')==result.get('sessionId')==control.get('session_id') and
  call.get('agentId')==result.get('agentId')==control.get('agent_id') and
  any(p.get('type')=='tool_use' and p.get('name')=='Read' and p.get('id')==read.get('tool_use_id') for p in call_parts) and
  any(p.get('type')=='tool_result' and p.get('tool_use_id')==read.get('tool_use_id') and not p.get('is_error') for p in result_parts))
 if not (valid_read and payload.get('hook_event_name')=='PreToolUse' and
  payload.get('session_id')==control.get('session_id') and payload.get('agent_id')==control.get('agent_id') and
  payload.get('tool_use_id') and payload['tool_use_id']!=read['tool_use_id'] and any(equal(p,owner) for p in caller)):
  return 0
 if not 0 < control.get('max_hold_seconds',0) <= 180: return 1
 with control_path.with_suffix('.claim-lock').open('a') as lock:
  fcntl.flock(lock,fcntl.LOCK_EX)
  control=json.loads(control_path.read_text())
  if control.get('claimed'): return 0
  hook=identities().get(os.getpid())
  if not hook or not equal(identities().get(owner['pid']),owner): return 0
  claim={'phase':'held','at':time.time(),'hook':hook,'lineage':caller,'leader':owner,'input':payload,'read_receipt':read,'original_agent_call_mode':control.get('original_agent_call_mode'),'signals':[]}
  control['claimed']=claim
  temporary=control_path.with_suffix('.claim.tmp');temporary.write_text(json.dumps(control));os.chmod(temporary,0o600);temporary.replace(control_path)
  emit(events_path,claim)
 started=time.monotonic(); cause='barrier_timeout'
 while time.monotonic()-started < control['max_hold_seconds']:
  try:
   if not equal(identities().get(owner['pid']),owner): cause='original_leader_identity_ended';break
  except Exception:
   cause='identity_inspection_failed';break
  time.sleep(max(0,min(.1,control['max_hold_seconds']-(time.monotonic()-started))))
 emit(events_path,{'phase':'released','at':time.time(),'held_seconds':time.monotonic()-started,'cause':cause,'hook':hook,'lineage':caller,'leader':owner,'signals':[]})
 print('Disposable crash-fixture timing barrier ended: '+cause+'. The held tool was not released for execution.',file=sys.stderr)
 return 2

sys.exit(main())
