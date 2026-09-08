#!/usr/bin/env python3
"""Drive the real native protocol and shared outcome verifier with scripted reviews."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

app=Path(__file__).resolve().parents[1]
runner=app/'target/debug/richos-run'
root=Path(tempfile.mkdtemp(prefix='richos-escalation-test-'))
print('Evidence directory:', root, flush=True)
fake=root/'native'
fake.write_text('''#!/usr/bin/env python3
import json,sys,os
from pathlib import Path
for line in sys.stdin:
 m=json.loads(line)
 if m.get('type')=='control_request':
  print(json.dumps({'type':'control_response','response':{'subtype':'success','request_id':m['request_id'],'response':{}}}),flush=True)
 elif m.get('type')=='user':
  text=m['message']['content']
  if not isinstance(text,str): text=''.join(c.get('text','') for c in text)
  with Path(os.environ['TEST_LOG']).open('a') as f: f.write(json.dumps(text)+'\\n')
  if 'Independently challenge this proposed CEO escalation.' in text:
   r=json.loads(os.environ['TEST_CHALLENGE'])
  else:
   r={'kind':'decision','question':'Which filename should I use?','why_ceo':'The CEO must pick the filename.','recommendation':'Use report.txt','options':['report.txt','other.txt']}
  print(json.dumps({'type':'result','subtype':'success','stop_reason':'end_turn','structured_output':{'result':r}}),flush=True)
''')
fake.chmod(0o700)
data={'messages':[{'role':'user','text':'Write report.txt. Do not publish.'},{'role':'assistant','text':'Want me to start?'}],'background_tasks':[]}
valid_decision={'kind':'decision','question':'Approve the additional paid research subscription?', 'why_ceo':'The current authority prohibits new spending and the remaining research requires a subscription.', 'recommendation':'Reduce the report scope to public sources.', 'options':['Approve a subscription','Limit scope to public sources']}
cases=[
 ('routine-question', {'kind':'incomplete','remaining':'The CEO already authorized report.txt. Write and verify it without another question.'}, True),
 ('corrected-authority', valid_decision, True),
 ('completed', {'kind':'complete','evidence':'Inspected the final report.txt against every original requirement; no publication occurred.'}, True),
 ('empty-completion', {'kind':'complete','evidence':'  '}, False),
 ('empty-next-work', {'kind':'incomplete','remaining':'  '}, False),
]
for field in ['question','why_ceo','recommendation']:
 cases.append(('empty-'+field,dict(valid_decision,**{field:'  '}),False))
for index, options in enumerate([[], ['Only option'], ['Valid option','  ']]):
 cases.append(('invalid-options-'+str(index),dict(valid_decision,options=options),False))
for name, challenge, valid in cases:
 log=root/(name+'-calls.jsonl')
 env=dict(os.environ,RICHOS_CLAUDE_BIN=str(fake),TEST_LOG=str(log),TEST_CHALLENGE=json.dumps(challenge))
 r=subprocess.run([str(runner),'audit-session',str(root),'30'],input=json.dumps(data),text=True,capture_output=True,env=env,timeout=70)
 (root/(name+'-result.json')).write_text(json.dumps({'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr},indent=2))
 if valid:
  assert r.returncode==0, (name,r.stderr)
  assert json.loads(r.stdout)==challenge, (name,r.stdout,challenge)
 else:
  assert r.returncode!=0, (name,r.stdout)
  assert 'Escalation challenge returned no usable evidence.' in r.stderr, (name,r.stderr)
 calls=[json.loads(line) for line in log.read_text().splitlines()]
 assert len(calls)==2, (name,calls)
 assert all('Do not publish.' in text for text in calls), name
 assert 'Independently challenge' in calls[1], name
 print('PASS:',name,flush=True)
print(f'PASS: {len(cases)} real native-protocol challenge cases. Routine questions return next work; only validated final authority questions can escalate; original prohibitions reach both reviews.')
