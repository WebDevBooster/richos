import hashlib,importlib.util,json,pathlib,shutil,tempfile
base=pathlib.Path('/var/folders/mx/w46p9btx1t17wv9tbsq885qw0000gn/T/richos-owned-wake-native-n71tx1sj')
manifest=json.loads((base/'resume-checkpoint-full-snapshot/manifest.json').read_text())
old=base/'runtime-snapshot/engine/scripts/lib/owned-session.py'
new=pathlib.Path('/Users/alex/ab/richos-wt/codex-owned-outcome-completion/engine/scripts/lib/owned-session.py')
def load(path,name):
 s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
assert digest(old)=='2eb1d3abce03e7f06ec67b4eb769773c5b0f33392ab3938bda22dc1dda5b2632'
statepath=pathlib.Path(manifest['state_snapshot']);assert digest(statepath)==manifest['state_snapshot_sha256']
for item in manifest['records']:assert digest(pathlib.Path(item['saved']))==item['sha256']
with tempfile.TemporaryDirectory(prefix='richos-r7-checkpoint-replay-') as d:
 root=pathlib.Path(d);state=json.loads(statepath.read_text());leader=root/(state['session_id']+'.jsonl')
 for item in manifest['records']:
  dest=leader if item['role']=='leader' else leader.with_suffix('')/'subagents'/pathlib.Path(item['source']).name
  dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(item['saved'],dest)
 state['source_transcript']=str(leader)
 original=load(old,'old_checkpoint').native_completion_batch(state);candidate=load(new,'new_checkpoint').native_completion_batch(state)
 assert original is None
 assert candidate is not None
 terminal=next(t for t in candidate['terminals'] if t.get('resumed_report_source_id'))
 assert terminal['resumed_report_source_id']=='660c2dfd-fa8e-4270-acee-0ee3bfaf56f5'
 assert terminal['prior_stopped_source_id']=='88bbff6d-afc8-425d-8506-c91e971f0130'
 assert terminal['source_id']=='326d0f68-98e7-42d0-9774-a77c45a7e4e3'
 before=leader.read_bytes();rows=[json.loads(l) for l in before.splitlines()]
 rejected=[]
 for mode in ('no-stop','human-stop','human-completion','old-completion-result'):
  altered=json.loads(json.dumps(rows))
  stop=next(r for r in altered if r.get('uuid')==terminal['prior_stopped_source_id'])
  complete=next(r for r in altered if r.get('uuid')==terminal['source_id'])
  if mode=='no-stop':altered.remove(stop)
  elif mode=='human-stop':stop['origin']={'kind':'human'}
  elif mode=='human-completion':complete['origin']={'kind':'human'}
  else:complete['message']['content']=complete['message']['content'].replace('<result>','<result>Historical completion: ',1)
  leader.write_text(''.join(json.dumps(r)+'\n' for r in altered))
  assert load(new,'mutated_checkpoint').native_completion_batch(state) is None,mode
  rejected.append(mode)
 leader.write_bytes(before)
 consumed=json.loads(json.dumps(state));consumed['completion_consumed_invocations']=candidate['invocations']
 assert load(new,'consumed_checkpoint').native_completion_batch(consumed) is None
 for item in manifest['records']:assert digest(pathlib.Path(item['saved']))==item['sha256']
 assert digest(statepath)==manifest['state_snapshot_sha256']
 print(json.dumps({'old_source_sha256':digest(old),'candidate_source_sha256':digest(new),'original_batch':original,'candidate_batch':candidate,'negative_mutations_rejected':rejected,'duplicate_checkpoint_rejected':True,'immutable_snapshot_hashes_unchanged':True,'provider_calls':0},indent=2))
