"""Collect exact R7 verification bytes; private originals are never substituted."""
from pathlib import Path
import hashlib,json,os,re,subprocess
repo=Path('/Users/alex/ab/richos-wt/codex-owned-outcome-completion')
out=repo/'docs/verification/owned-outcome/evidence-r7'
private=Path('/Users/alex/.codex/artifacts/richos-owned-outcome-r7-2026-09-09')
private.mkdir(parents=True,exist_ok=True,mode=0o700);private.chmod(0o700)
records=[]
secret=re.compile(rb'(?:sk-ant-|sk-proj-|ghp_|github_pat_|Bearer )[A-Za-z0-9_-]{16,}|"(?:accessToken|refreshToken|apiKey)"\s*:\s*"[^"\s]{12,}|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}',re.I)
def retain(source,relative,restricted=False):
 source=Path(source);raw=source.read_bytes();digest=hashlib.sha256(raw).hexdigest()
 restricted=restricted or bool(secret.search(raw)) or (source.suffix in ('.json','.jsonl','.log','.txt') and b'permission_context' in raw)
 target=private/digest if restricted else out/relative
 target.parent.mkdir(parents=True,exist_ok=True)
 target.write_bytes(raw)
 if restricted: target.chmod(0o600)
 record={'original':str(source),'bytes':len(raw),'sha256':digest}
 record['private_copy' if restricted else 'copy']=str(target) if restricted else str(target.relative_to(repo))
 records.append(record)
# Mechanical collection preserves its own complete manifest, including failed originals.
for manifest in sorted([*out.glob('mechanical-*/artifact-index.json'),*out.glob('fresh-checkpoint-equivalence/artifact-index.json')]):
 data=json.loads(manifest.read_text());records.extend(data['records'])
 retain(manifest,manifest.relative_to(out))
temp=Path('/var/folders/mx/w46p9btx1t17wv9tbsq885qw0000gn/T')
trial_summaries=[]
for dirname,label in [('richos-owned-wake-native-ai5aryf1','native-fresh-initial'),('richos-owned-wake-native-pjdo181c','native-resume-initial'),('richos-owned-wake-native-mmdlv6q8','native-fresh-final'),('richos-owned-wake-native-n71tx1sj','native-resume-before-carrier-fix'),('richos-owned-wake-native-q1h35afd','native-resume-no-crash-window'),('richos-owned-wake-native-o33xokiz','native-resume-final')]:
 root=temp/dirname
 assert (root/'result.json').exists(), root
 result=json.loads((root/'result.json').read_text())
 source=json.loads((root/'source-identity.json').read_text())
 timing_path=root/'exhausted-crash-acceptance.json'
 timing=json.loads(timing_path.read_text()) if timing_path.exists() else {}
 trial_summaries.append({'label':label,'original_root':str(root),'result_sha256':hashlib.sha256((root/'result.json').read_bytes()).hexdigest(),
  'passed':result['passed'],'checks':result['checks'],'check_count':len(result['checks']),'checks_passed':sum(v is True for v in result['checks'].values()),
  'operational_followups':result.get('operational_followups'),'input_measurement_confirmed':result.get('input_measurement_confirmed'),
  'artifact_completion_verified':result.get('artifact_completion_verified'),'routine_parser_prose_asks':result.get('routine_parser_prose_asks'),
  'seconds_to_allowed_agent':timing.get('seconds_to_allowed_agent'),'claude_version':source['claude_version'],
  'runtime_sha256':source['sources']['engine/scripts/lib/owned-session.py'],'harness_sha256':source['sources']['app/scripts/test-owned-wake-native.py']})
 for p in sorted(root.rglob('*')):
  rel=p.relative_to(root)
  if not p.is_file() or p.is_symlink() or '.git' in rel.parts: continue
  binary=('runtime-snapshot' in rel.parts and p.name not in ('owned-session.py','owned-dispatch.py','owned-work-policy.sh')) or p.name=='richos-run-snapshot' or p.suffix in ('.pyc','.so','.dylib')
  binary=binary or p.name in ('terminal.log','terminal-events.jsonl','adapter-hooks.jsonl','engine-hooks.jsonl','audits.jsonl') or 'transcript' in p.name or p.name.startswith('before-restart-') or 'state' in rel.parts
  retain(p,Path(label)/rel,binary)
(out/'native-trials-summary.json').write_text(json.dumps({'derived_summary':True,'meaning':'Selected fields from immutable original results. Original failed checks and mixed source identities are retained. This summary never replaces the original records.','trials':trial_summaries},indent=2)+'\n')
for dirname,label in [('richos-r7-runner-lease-mtp1e2_s','runner-lease-initial'),('richos-r7-runner-lease-0tzav3w4','runner-lease-final')]:
 root=temp/dirname
 for p in sorted(root.rglob('*')):
  if p.is_file() and not p.is_symlink(): retain(p,Path(label)/p.relative_to(root))
for dirname,label in [('richos-r7-install-od_1dpa5','installer-before-feedback'),('richos-r7-install-ezthj75t','installer-before-resume'),('richos-r7-install-hni062g7','installer')]:
 root=temp/dirname
 for p in [root/'result.json',root/'install.log',*[root/'engine/scripts/lib'/n for n in ('owned-session.py','owned-dispatch.py','owned-work-policy.sh')]]:
  retain(p,Path(label)/p.relative_to(root))
for p in sorted(Path('/tmp').glob('richos-r7-*.log')): retain(p,Path('checks')/p.name)
for p in sorted(Path('/tmp').glob('richos-r7-engine*result.json')): retain(p,Path('checks')/p.name)
retain('/tmp/richos-r7-package-mechanical.py','mechanical-collection-script.py')
for extension in ['py','json']: retain('/tmp/richos-r7-resume-checkpoint-replay.'+extension,'checks/resume-checkpoint-replay.'+extension)
retain('/Users/alex/ab/richos/docs/reviews/sage-fable-r6-owned-outcome-2026-09-09.md','review-r6.md')
retain('/tmp/richos-r7-collect.py','collection-script.py')
for name in ['install-check.py','verify-evidence.py','check-runner-lease.py']: retain(out/name,name)
(out/'.gitattributes').write_text('# Captured artifacts retain exact bytes and observed whitespace.\n* -text -whitespace\n')
# Include each packaged supplemental manifest/script, with no unindexed files.
known={r['copy'] for r in records if 'copy' in r}
for p in sorted(out.rglob('*')):
 if p.is_file() and str(p.relative_to(out)) not in ('source-identity.json','artifact-index.json','.gitattributes') and str(p.relative_to(repo)) not in known:
  retain(p,p.relative_to(out))
(out/'artifact-index.json').write_text(json.dumps({'base_commit':'125906f5f02057091f3e427b5a89cfda834fcfa4','private_archive':str(private),'records':records},indent=2)+'\n')
files=subprocess.check_output(['git','diff','--name-only','125906f5'],cwd=repo,text=True).splitlines()+subprocess.check_output(['git','ls-files','-o','--exclude-standard'],cwd=repo,text=True).splitlines()
files=sorted(set(n for n in files if not n.startswith('docs/verification/owned-outcome/evidence-r7/')))
(out/'source-identity.json').write_text(json.dumps({'base_commit':'125906f5f02057091f3e427b5a89cfda834fcfa4','branch':'codex/owned-outcome-completion','files':{n:hashlib.sha256((repo/n).read_bytes()).hexdigest() for n in files}},indent=2)+'\n')
print(json.dumps({'records':len(records),'private':sum('private_copy' in r for r in records),'source_files':len(files)}))
