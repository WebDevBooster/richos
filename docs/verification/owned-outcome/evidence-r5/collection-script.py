from pathlib import Path
import hashlib,json,re,shutil
repo=Path('/Users/alex/ab/richos-wt/codex-owned-outcome-completion')
dest=repo/'docs/verification/owned-outcome/evidence-r5';dest.mkdir(exist_ok=True)
archive=Path('/Users/alex/.codex/artifacts/richos-owned-outcome-r5-2026-09-09');archive.mkdir(mode=0o700,parents=True,exist_ok=True)
temp=Path('/var/folders/mx/w46p9btx1t17wv9tbsq885qw0000gn/T')
records={}
private_pattern=re.compile(rb'(?:sk-ant-|sk-proj-|ghp_|github_pat_|Bearer )[A-Za-z0-9_-]{16,}|"(?:accessToken|refreshToken|apiKey)"\s*:\s*"[^"\s]{12,}|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}',re.I)
def retain(path,relative,copy=True):
 path=Path(path)
 if not path.is_file():return
 raw=path.read_bytes();digest=hashlib.sha256(raw).hexdigest()
 entry={'original':str(path),'bytes':len(raw),'sha256':digest};out=dest/relative
 if copy and not private_pattern.search(raw):
  out.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(path,out);entry['copy']=str(out.relative_to(repo))
 else:
  if out.exists():out.unlink()
  private=archive/digest
  if not private.exists():private.write_bytes(raw);private.chmod(0o600)
  assert hashlib.sha256(private.read_bytes()).hexdigest()==digest
  entry.update(local_only=True,private_copy=str(private),reason='Raw account context or immutable binary retained privately; no transformed evidence substituted.')
 records[str(path)]=entry
for pattern in ['richos-r5-*.log','r5-native-*.log','r5-queued-*.log','richos-r5-core-*.results.json','richos-r5-dispatch-size.json']:
 for p in Path('/tmp').glob(pattern):retain(p,Path('logs')/p.name)
fixtures={
 'richos-owned-wake-native-7b2h3xej':'fresh-first-failed',
 'richos-owned-wake-native-ulybu2cs':'resume-first-failed',
 'richos-owned-wake-native-nu04n__f':'fresh-corrected-meter',
 'richos-owned-wake-native-5rtp9ghb':'resume-corrected-meter',
 'richos-owned-wake-native-ekryio6b':'fresh-before-queued',
 'richos-owned-wake-native-eb0nlocp':'resume-final',
 'richos-owned-wake-native-0pp6t7vi':'fresh-queued-final',
}
for original,label in fixtures.items():
 root=temp/original
 for p in root.glob('*'):
  if p.is_file():retain(p,Path(label)/p.name,p.name!='richos-run-snapshot')
 for sub in ['state','workspace/.claude/state']:
  for p in (root/sub).rglob('*'):
   if p.is_file():retain(p,Path(label)/p.relative_to(root))
 for name in ['lifecycle.py','test_lifecycle.py','diagnosis.json','improvements.md','requirements.md','backlog.md','ceo-items.md','decision-D7.md']:
  retain(root/'workspace'/name,Path(label)/'workspace'/name)
for label,root in [('registration-protocol',temp/'richos-registration-protocol-c2kmn9qc')]:
 for p in root.rglob('*'):
  if p.is_file():retain(p,Path(label)/p.relative_to(root))
for label,dirname in [('installer-before-checkpoint','richos-r5-install-jnhnbazq'),('installer-before-queued','richos-r5-install-l1wnt914'),('installer','richos-r5-install-5rf_uw7z')]:
 root=temp/dirname
 for name in ['result.json','install.log']:retain(root/name,Path(label)/name)
for label in ['pacing-diagnosis','pacing-checkpoint-replay','ekryio6b-nested-terminal-diagnosis']:
 for source in Path('/tmp/richos-r5-'+label).glob('*'):
  if source.is_file() and source.stat().st_size: retain(source,Path(label)/source.name)
for source in Path('/tmp/richos-r5-queued-checkpoint-replay').rglob('*'):
 if source.is_file() and source.stat().st_size:retain(source,Path('queued-checkpoint-replay')/source.relative_to('/tmp/richos-r5-queued-checkpoint-replay'))
retain('/tmp/richos-r5-install-check.py',Path('installer/check.py'))
retain('/tmp/richos-r5-collect-evidence.py',Path('collection-script.py'))
(dest/'artifact-index.json').write_text(json.dumps({'base_commit':'e0679a553c6462b7e882135028577304f7f59faa','branch':'codex/owned-outcome-completion','kind':'R5 byte-identical evidence, including original failed runs.','records':sorted(records.values(),key=lambda r:r['original'])},indent=2)+'\n')
print(json.dumps({'records':len(records),'copied':sum('copy'in r for r in records.values()),'private':sum('private_copy'in r for r in records.values())}))
