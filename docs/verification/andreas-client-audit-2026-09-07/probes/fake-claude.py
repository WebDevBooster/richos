#!/usr/bin/env python3
import json,sys,time
from pathlib import Path
root=Path('/tmp/richos-audit-20260907/root/native')
for line in sys.stdin:
 m=json.loads(line)
 if m.get('type')=='control_request':
  print(json.dumps({'type':'control_response','response':{'subtype':'success','request_id':m['request_id'],'response':{}}}),flush=True)
 elif m.get('type')=='user':
  content=m.get('message',{}).get('content','')
  text=content if isinstance(content,str) else ''.join(x.get('text','') for x in content)
  if text=='AUDIT_SLOW_REPLY':
   (root/'visible-started').write_text(str(time.time()))
   for i in range(8):
    time.sleep(1)
    print(json.dumps({'type':'assistant','message':{'content':[{'type':'text','text':f'Chunk {i}. '}]}}),flush=True)
  print(json.dumps({'type':'result','subtype':'success','stop_reason':'end_turn','is_error':False}),flush=True)
