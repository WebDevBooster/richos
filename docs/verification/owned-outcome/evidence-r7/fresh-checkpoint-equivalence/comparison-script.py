from pathlib import Path
import argparse,hashlib,importlib.util,json,os,tempfile
parser=argparse.ArgumentParser();parser.add_argument('--expected-new-sha',required=True);args=parser.parse_args()
repo=Path('/Users/alex/ab/richos-wt/codex-owned-outcome-completion')
original=Path('/var/folders/mx/w46p9btx1t17wv9tbsq885qw0000gn/T/richos-owned-wake-native-mmdlv6q8')
archive=Path('/Users/alex/.codex/artifacts/richos-owned-outcome-r7-2026-09-09');archive.mkdir(parents=True,exist_ok=True,mode=0o700)
out=Path(tempfile.mkdtemp(prefix='fresh-checkpoint-equivalence-',dir=archive));out.chmod(0o700)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
manifest=[]
def copy(src,dst):
 dst.parent.mkdir(parents=True,exist_ok=True,mode=0o700);dst.write_bytes(src.read_bytes());dst.chmod(0o600)
 manifest.append({'original':str(src),'copy':str(dst),'bytes':src.stat().st_size,'original_sha256':sha(src),'copy_sha256':sha(dst)})
 return dst
old=copy(original/'runtime-snapshot/engine/scripts/lib/owned-session.py',out/'old-adapter.py')
new=copy(repo/'engine/scripts/lib/owned-session.py',out/'new-adapter.py')
assert sha(new)==args.expected_new_sha
states=[p for p in (original/'state').glob('*.json') if json.loads(p.read_text()).get('completion_checkpoints')]
assert len(states)==1
source=copy(states[0],out/'original-state.json');state=json.loads(source.read_text());derived=json.loads(source.read_text())
last=state['completion_checkpoints'][-1];removed=last['invocations'];assert set(removed)<=set(state['completion_consumed_invocations'])
derived['completion_consumed_invocations']=[x for x in state['completion_consumed_invocations'] if x not in removed]
paths={}
for p in original.glob('transcript-*.jsonl'):
 if p.name.startswith('transcript-child-'):continue
 session=p.name[len('transcript-'):-len('.jsonl')]
 paths[session]=copy(p,out/'transcripts'/(session+'.jsonl'))
for p in original.glob('transcript-child-*.jsonl'):
 rows=[json.loads(line) for line in p.read_text().splitlines()]
 sessions={row.get('sessionId') for row in rows};assert len(sessions)==1
 session=sessions.pop();agent=p.name[len('transcript-child-agent-'):-len('.jsonl')]
 copy(p,out/'transcripts'/session/'subagents'/('agent-'+agent+'.jsonl'))
remap={state['source_transcript']:str(paths[state['session_id']])}
for path in state.get('recovered_transcripts',[]):remap[path]=str(paths[Path(path).stem])
derived['source_transcript']=remap[state['source_transcript']]
derived['recovered_transcripts']=[remap[p] for p in state.get('recovered_transcripts',[])]
derived['recovered_transcript_sessions']={remap.get(p,p):v for p,v in state.get('recovered_transcript_sessions',{}).items()}
(out/'derived-state.json').write_text(json.dumps(derived,indent=2)+'\n');(out/'derived-state.json').chmod(0o600)
def load(name,path):
 spec=importlib.util.spec_from_file_location(name,path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
before=load('old_owned',old).native_completion_batch(derived)
after=load('new_owned',new).native_completion_batch(derived)
expected={k:v for k,v in last.items() if k!='claimed_at'}
result={'passed':bool(before) and before==after==expected,'provider_calls':0,'hook_calls':0,'original_root':str(original),'evidence_root':str(out),'old_runtime_sha256':sha(old),'new_runtime_sha256':sha(new),
 'derivation':'Copied immutable final state and transcript snapshots. Removed only invocation IDs in its final recorded completion checkpoint from completion_consumed_invocations. Rebound transcript paths to byte-identical private snapshot copies. No messages, timing, execution, ownership or terminal rows changed. This is a derived preclaim classifier replay, not another live trial.',
 'removed_consumed_invocations':removed,'old_checkpoint':before,'new_checkpoint':after,'expected_recorded_checkpoint':expected,'manifest':manifest}
(out/'result.json').write_text(json.dumps(result,indent=2)+'\n');(out/'result.json').chmod(0o600)
for p in out.rglob('*'):p.chmod(0o700 if p.is_dir() else 0o600)
assert sha(repo/'engine/scripts/lib/owned-session.py')==args.expected_new_sha
print(json.dumps({'passed':result['passed'],'result':str(out/'result.json'),'positive_checkpoint':before is not None,'equal':before==after,'matches_recorded':after==expected}))
raise SystemExit(0 if result['passed'] else 1)
