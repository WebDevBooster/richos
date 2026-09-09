from pathlib import Path
import hashlib,json,os,re,shutil,subprocess
repo=Path('/Users/alex/ab/richos-wt/codex-owned-outcome-completion')
out=repo/'docs/verification/owned-outcome/evidence-r6'
private=Path('/Users/alex/.codex/artifacts/richos-owned-outcome-r6-2026-09-09')
private.mkdir(parents=True,exist_ok=True,mode=0o700)
os.chmod(private,0o700)
records=[]
secret=re.compile(rb'(?:sk-ant-|sk-proj-|ghp_|github_pat_|Bearer )[A-Za-z0-9_-]{16,}|"(?:accessToken|refreshToken|apiKey)"\s*:\s*"[^"\s]{12,}')
email=re.compile(rb'[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}',re.I)
def retain(source,dest,restricted=False):
 source=Path(source);dest=Path(dest);raw=source.read_bytes()
 restricted=restricted or bool(secret.search(raw) or email.search(raw))
 target=(private if restricted else out)/dest
 target.parent.mkdir(parents=True,exist_ok=True,mode=0o700 if restricted else 0o755)
 target.write_bytes(raw)
 if restricted:
  target.chmod(0o600)
  parent=target.parent
  while parent!=private.parent:
   parent.chmod(0o700);parent=parent.parent
 record={'original':str(source),'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}
 record['private_copy' if restricted else 'copy']=str(target) if restricted else str(target.relative_to(repo))
 records.append(record)
for label,name in [('integration-first','yh8y44s0'),('integration-final','e3_9cztv')]:
 base=Path('/private/var/folders/mx/w46p9btx1t17wv9tbsq885qw0000gn/T/richos-owned-recovery-'+name)
 for p in sorted(base.rglob('*')):
  if p.is_file():
   rel=p.relative_to(base)
   retain(p,Path(label)/rel,'private' in rel.parts or rel==Path('claude'))
for label,name in [('installer-first','m3bvcc3s'),('installer-final','rajhhos_')]:
 base=Path('/var/folders/mx/w46p9btx1t17wv9tbsq885qw0000gn/T/richos-r6-install-'+name)
 for p in [base/'result.json',base/'install.log',*[base/'engine/scripts/lib'/n for n in ('owned-session.py','owned-dispatch.py','owned-work-policy.sh')]]:
  retain(p,Path(label)/p.relative_to(base))
for name in ['native.log','native-ownership-fence.log','dispatch.log','dispatch-final.log','echo-recovery-review.log','echo-ownership-fence.log','recovery-integration-first.log','recovery-integration.log','engine.log','engine-result.json','engine-final.log','engine-final-result.json','docs-claims.log','registry-probe.json','installer-final.log']:
 retain('/tmp/richos-r6-'+name,Path('checks')/name)
retain('/Users/alex/ab/richos/docs/reviews/sage-fable-r5-owned-outcome-2026-09-09.md','review-r5.md')
retain('/tmp/richos-r6-collect.py','collection-script.py')
for name in ['install-check.py','verify-evidence.py']:
 retain(out/name,name)
(out/'.gitattributes').write_text('# Captured artifacts retain exact bytes and observed whitespace.\n* -text -whitespace\n')
(out/'artifact-index.json').write_text(json.dumps({'base_commit':'d8afbc1fa6e2ae717e8736fb9a683dad9b3a4661','private_archive':str(private),'records':records},indent=2)+'\n')
files=subprocess.check_output(['git','diff','--name-only','d8afbc1f'],cwd=repo,text=True).splitlines()+subprocess.check_output(['git','ls-files','-o','--exclude-standard'],cwd=repo,text=True).splitlines()
files=sorted(set(n for n in files if not n.startswith('docs/verification/owned-outcome/evidence-r6/')))
identity={'base_commit':'d8afbc1fa6e2ae717e8736fb9a683dad9b3a4661','branch':'codex/owned-outcome-completion','files':{name:hashlib.sha256((repo/name).read_bytes()).hexdigest() for name in files}}
(out/'source-identity.json').write_text(json.dumps(identity,indent=2)+'\n')
print(json.dumps({'indexed_records':len(records),'private_records':sum('private_copy' in r for r in records),'source_files':len(files)}))
