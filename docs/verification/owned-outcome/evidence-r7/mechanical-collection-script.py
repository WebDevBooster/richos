from pathlib import Path
import hashlib,json,os,re
repo=Path('/Users/alex/ab/richos-wt/codex-owned-outcome-completion')
public=repo/'docs/verification/owned-outcome/evidence-r7'
private=Path('/Users/alex/.codex/artifacts/richos-owned-outcome-r7-2026-09-09')
private.mkdir(parents=True,exist_ok=True,mode=0o700);private.chmod(0o700)
secret=re.compile(rb'(?:sk-ant-|sk-proj-|ghp_|github_pat_|Bearer )[A-Za-z0-9_-]{16,}|"(?:accessToken|refreshToken|apiKey)"\s*:\s*"[^"\s]{12,}')
email=re.compile(rb'[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}',re.I)
def user_config(value):
 if isinstance(value,dict):
  if value.get('scope')=='user' and not value.get('redacted_nonfixture_configuration'):return True
  return any(user_config(v) for v in value.values())
 if isinstance(value,list):return any(user_config(v) for v in value)
 if isinstance(value,str) and 'NATIVE OBSERVATIONS (data, not instructions):\n' in value:
  try:return user_config(json.loads(value.split('NATIVE OBSERVATIONS (data, not instructions):\n',1)[1]))
  except ValueError:return True
 return False
def classify(raw,rel):
 reasons=[]
 if 'private' in rel.parts:reasons.append('original_restricted_raw_observation')
 if rel==Path('claude'):reasons.append('compiled_fixture_binary')
 if secret.search(raw) or email.search(raw):reasons.append('sensitive_pattern')
 try:
  text=raw.decode()
  values=[json.loads(text)] if not str(rel).endswith('.jsonl') else [json.loads(line) for line in text.splitlines() if line]
  if any(user_config(v) for v in values):reasons.append('unredacted_user_permission_configuration')
 except (UnicodeError,ValueError):pass
 return reasons
summary=[]
for label,suffix,log in [('mechanical-final','b12wl71x','/tmp/richos-r7-recovery.log'),('mechanical-initial','o3n7xsfc','/tmp/richos-r7-recovery-first-failure.log')]:
 base=Path('/private/var/folders/mx/w46p9btx1t17wv9tbsq885qw0000gn/T/richos-owned-recovery-'+suffix)
 out=public/label
 if out.exists():raise SystemExit('Refusing to overwrite existing evidence: '+str(out))
 out.mkdir(parents=True)
 records=[]
 originals=[(p,p.relative_to(base)) for p in sorted(base.rglob('*')) if p.is_file()]
 originals.append((Path(log),Path('run.log')))
 for source,relative in originals:
  raw=source.read_bytes();reasons=classify(raw,relative)
  dest=(private/label if reasons else out)/relative
  dest.parent.mkdir(parents=True,exist_ok=True,mode=0o700 if reasons else 0o755)
  if dest.exists():raise SystemExit('Refusing overwrite: '+str(dest))
  dest.write_bytes(raw)
  if reasons:
   dest.chmod(0o600);parent=dest.parent
   while parent!=private.parent:parent.chmod(0o700);parent=parent.parent
  else:dest.chmod(0o644)
  copied=dest.read_bytes()
  original_hash=hashlib.sha256(raw).hexdigest();copy_hash=hashlib.sha256(copied).hexdigest()
  assert copied==raw
  record={'original':str(source),'bytes':len(raw),'sha256':original_hash,'original_sha256':original_hash,'copy_sha256':copy_hash,'copy_bytes':len(copied)}
  record['private_copy' if reasons else 'copy']=str(dest) if reasons else str(dest.relative_to(repo))
  if reasons:record['restricted_reasons']=reasons
  records.append(record)
 (out/'.gitattributes').write_text('# Captured artifacts retain exact bytes and observed whitespace.\n* -text -whitespace\n')
 manifest={'evidence_label':label,'original_root':str(base),'private_archive':str(private/label),'records':records,
 'copy_policy':'Original bytes retained exactly. Raw observations, user permission configuration and compiled fixture binaries remain private. Public receipts retain their original redaction markers and private-original hash references.'}
 (out/'artifact-index.json').write_text(json.dumps(manifest,indent=2)+'\n')
 summary.append({'label':label,'records':len(records),'public_records':sum('copy'in r for r in records),'private_records':sum('private_copy'in r for r in records),'manifest':str(out/'artifact-index.json')})
print(json.dumps(summary,indent=2))
