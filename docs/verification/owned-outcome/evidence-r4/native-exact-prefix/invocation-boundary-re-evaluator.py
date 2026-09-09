import ast,hashlib,importlib.util,json,re,time
from pathlib import Path
repo=Path('/Users/alex/ab/richos-wt/codex-owned-outcome-completion')
p=Path('/var/folders/mx/w46p9btx1t17wv9tbsq885qw0000gn/T/richos-owned-wake-native-gx6rw1a9')
script=repo/'app/scripts/test-owned-wake-native.py'
mod=ast.parse(script.read_text());fn=next(n for n in mod.body if isinstance(n,ast.FunctionDef) and n.name=='native_approval_boundary')
ns={'re':re};exec(compile(ast.Module(body=[fn],type_ignores=[]),str(script),'exec'),ns)
originals=['result.json','adapter-hooks.jsonl','terminal.log','terminal-events.jsonl','input-events.jsonl','source-identity.json','runtime-snapshot-identity.json']
before={n:hashlib.sha256((p/n).read_bytes()).hexdigest() for n in originals}
hooks=[json.loads(l) for l in (p/'adapter-hooks.jsonl').read_text().splitlines()]
events=[json.loads(l) for l in (p/'terminal-events.jsonl').read_text().splitlines()]
states=[json.loads(f.read_text()) for f in (p/'state').glob('*.json')]
cutoff=json.loads((p/'early-termination.json').read_text())['time']
events=[e for e in events if e['at']<cutoff]
terminal=(p/'terminal.log').read_bytes()[:events[-1]['end']]
boundary=ns['native_approval_boundary'](hooks,terminal,events,'python3 -m json.tool diagnosis.json',states)
assert boundary['observed']
s=next(s for s in states if s.get('last_permission_request',{}).get('disposition')=='awaiting_native_permission')
r=s['last_permission_request'];original=r['original_observation']['input'];effective=r['input']
normalized={k:v for k,v in effective.items() if k!='description'};normalized['command']=original['command']
assert normalized=={k:v for k,v in original.items() if k!='description'}
assert effective['command']=='set -e -o pipefail\n'+original['command']
spec=importlib.util.spec_from_file_location('owned',repo/'engine/scripts/lib/owned-session.py');owned=importlib.util.module_from_spec(spec);spec.loader.exec_module(owned)
assert owned.permission_operation_input('Bash',effective,r['original_observation'])==normalized
assert any(m.get('provenance')=='native_human_typed_v1' and original['command'] in m.get('text','') for m in s['messages'])
result=json.loads((p/'result.json').read_text());checks={**result['checks'],'native_approval_boundary_preserved':boundary['observed']}
assert all(checks.values())
assert result['operational_followups']==0
report={'passed':all(checks.values()),'checks':checks,'original_result_unchanged':before['result.json'],'originals_sha256':before,'outcome':'permission_required','operational_followups':0,'boundary':boundary,'final_restriction_proof':{'original_input':original,'effective_input':effective,'equal_except_fixed_prefix_and_description':True,'actual_final_python_normalization_passed':True,'required_command_present_in_verified_native_human_source':True,'adapter_sha256':hashlib.sha256((repo/'engine/scripts/lib/owned-session.py').read_bytes()).hexdigest(),'rust_sha256':hashlib.sha256((repo/'app/crates/richos-core/src/native_permission.rs').read_bytes()).hexdigest()},'limit':'Native rendered the current permission UI during the hook, before callback completion. No terminal change followed completed native_prompt and no answer was supplied. This proves permission_required, not task completion or zero transient UI.','provider_rerun':False,'terminal_cutoff_before_recorded_operator_SIGTERM':cutoff,'terminal_bytes_at_cutoff':len(terminal)}
(p/'invocation-boundary-re-evaluation.json').write_text(json.dumps(report,indent=2))
(p/'invocation-boundary-re-evaluator.py').write_text(Path(__file__).read_text())
(p/'invocation-boundary-corrected-harness.py').write_bytes(script.read_bytes())
assert before=={n:hashlib.sha256((p/n).read_bytes()).hexdigest() for n in originals}
print(json.dumps({'passed':report['passed'],'checks':checks,'invocation':r['invocation_id'],'operational_followups':0,'originals_preserved':True,'final_restriction_passed':True}))
