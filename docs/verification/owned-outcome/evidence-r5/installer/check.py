from pathlib import Path
import hashlib,json,os,shutil,subprocess,tempfile
repo=Path('/Users/alex/ab/richos-wt/codex-owned-outcome-completion')
root=Path(tempfile.mkdtemp(prefix='richos-r5-install-'))
engine=root/'engine'
shutil.copytree(repo/'engine',engine,ignore=shutil.ignore_patterns('*.sha256','__pycache__'))
config=root/'config';config.mkdir()
pointer=Path('/Users/alex/.claude/richos-engine')
before=os.readlink(pointer) if pointer.is_symlink() else None
env={**os.environ,'CLAUDE_CONFIG_DIR':str(config),'RICHOS_LAUNCH_AGENTS_DIR':str(root/'plists')}
argv=['bash',str(engine/'scripts/hooks/install.sh')]
p=subprocess.run(argv,cwd=engine,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
(root/'install.log').write_text(p.stdout)
checks={}
for name in ['owned-work-policy.sh','owned-dispatch.py','owned-session.py']:
 source=engine/'scripts/lib'/name; sidecar=Path(str(source)+'.sha256')
 checks[name]=sidecar.is_file() and sidecar.read_text().split()[0]==hashlib.sha256(source.read_bytes()).hexdigest()
after=os.readlink(pointer) if pointer.is_symlink() else None
result={'argv':argv,'exit':p.returncode,'checks':checks,'production_pointer_unchanged':before==after,'production_activation':False,'source_hashes':{name:hashlib.sha256((repo/'engine/scripts/lib'/name).read_bytes()).hexdigest() for name in checks}}
result['passed']=p.returncode==0 and all(checks.values()) and before==after
(root/'result.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({'directory':str(root),**result}))
raise SystemExit(0 if result['passed'] else 1)
