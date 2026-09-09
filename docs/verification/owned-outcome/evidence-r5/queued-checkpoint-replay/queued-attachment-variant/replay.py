import hashlib,importlib.util,json,os,subprocess
from pathlib import Path
from unittest.mock import patch
root=Path('/tmp/richos-r5-queued-checkpoint-replay/queued-attachment-variant');root.mkdir(parents=True,exist_ok=True)
original=Path('/var/folders/mx/w46p9btx1t17wv9tbsq885qw0000gn/T/richos-owned-wake-native-ekryio6b/state/868e21839f134d4e90fdaefde20bbecfac39e9d1a106cedd98742e8e6fa312d9.json')
state=json.loads(original.read_text());state_sha=hashlib.sha256(original.read_bytes()).hexdigest()
source=Path('/Users/alex/ab/richos-wt/codex-owned-outcome-completion/engine/scripts/lib/owned-session.py')
spec=importlib.util.spec_from_file_location('checkpoint',source);o=importlib.util.module_from_spec(spec);spec.loader.exec_module(o)
path=root/'scratch-state.json';o.atomic(path,state)
batch=o.native_completion_batch(state);assert batch and len(batch['invocations'])==2
observed=[]
def inspect(*args,**kwargs):
 saved=json.loads(path.read_text());assert saved['completion_consumed_invocations']==batch['invocations'];observed.append(args)
 return subprocess.CompletedProcess([],0,json.dumps({'kind':'incomplete','remaining':'Deterministic scheduling sentinel. This is not a real inspector verdict.'}),'')
with patch.dict(os.environ,RICHOS_OWNED_STATE_DIR=str(root/'isolated-state')),patch.object(o.time,'sleep',side_effect=AssertionError('Real completed batch must not wait an hour')),patch.object(o.subprocess,'run',side_effect=inspect):
 code,_=o.audit_once(path,{'runner':'mocked-inspector-only'});assert code==2 and len(observed)==1
saved=json.loads(path.read_text());assert saved['audit_attempts']==state['audit_attempts']+1;assert o.native_completion_batch(saved) is None
assert hashlib.sha256(original.read_bytes()).hexdigest()==state_sha
report={'mechanical_checkpoint_available':True,'mocked_inspection_calls':len(observed),'actual_provider_calls':0,'no_completion_claim':True,'original_saved_state_unchanged':True,'original_state_sha256':state_sha,'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'checkpoint':batch,'attempts_before':state['audit_attempts'],'attempts_after':saved['audit_attempts'],'consumed_before_inspection':True,'duplicate_checkpoint_unavailable':True}
(root/'result.json').write_text(json.dumps(report,indent=2));(root/'replay.py').write_text(Path(__file__).read_text());print(json.dumps({k:v for k,v in report.items() if k!='checkpoint'}))
