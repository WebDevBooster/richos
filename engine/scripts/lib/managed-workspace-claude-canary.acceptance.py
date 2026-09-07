#!/usr/bin/env python3
"""External real-Claude lifecycle canary. Never install, activate or reboot.

The pinned launcher must copy this file AND the interrupted-creation acceptance
helper into the same protected staging directory. --engine is a protected copy
with a pinned manifest of every regular file (relative path -> SHA256). Only the
copied bridge CLIENT_CONFIG constant is substituted. This is a bounded lifecycle
hook profile, not acceptance of a user's complete settings or public activation.
Normal login is reused without copying secrets/settings. One new, explicitly
recorded project transcript remains in the normal Claude configuration directory.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import pwd
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import time
import uuid

PYTHON = '/Library/Developer/CommandLineTools/usr/bin/python3'
PREFIX = 'claude-canary-'
CONTENT = 'exact real Claude managed delivery\n'
HOOKS = {
    'PreToolUse': [(None, 'guard-sealed-worktree.sh'), ('Agent', 'guard-worktree-isolation.sh')],
    'PostToolUse': [('Agent', 'detect-nonnative-worktree.sh'), ('TaskStop', 'terminalize-agent-worktrees.sh')],
    'SubagentStart': [(None, 'record-subagent-start.sh')],
    'SubagentStop': [(None, 'terminalize-agent-worktrees.sh')],
    'WorktreeRemove': [(None, 'terminalize-agent-worktrees.sh')]}


def require(value, reason):
    if not value:
        raise RuntimeError(reason)


def module(path):
    spec = importlib.util.spec_from_file_location(path.stem.replace('-', '_'), path)
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result)
    return result


def file_manifest(root):
    result = {}
    for current, dirs, files in os.walk(root, followlinks=False):
        for name in dirs + files:
            path = Path(current) / name
            info = path.lstat()
            require(not stat.S_ISLNK(info.st_mode), 'engine snapshot contains a symlink')
            require(stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode), 'engine snapshot contains a special file')
            if stat.S_ISREG(info.st_mode):
                result[path.relative_to(root).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def substitute_bridge(engine, client):
    path = engine / 'scripts/lib/managed-workspace-integration.py'
    old = "CLIENT_CONFIG = Path('/Library/Application Support/RichOS/ManagedWorkspaces/client.json')"
    new = 'CLIENT_CONFIG = Path(' + repr(str(client)) + ')'
    original = path.read_bytes()
    require(original.count(old.encode()) == 1, 'exact bridge substitution anchor unavailable')
    updated = original.replace(old.encode(), new.encode(), 1)
    path.write_bytes(updated)
    return dict(path=path.relative_to(engine).as_posix(), before_sha256=hashlib.sha256(original).hexdigest(),
                after_sha256=hashlib.sha256(updated).hexdigest(), before=old, after=new)


def isolated_env(config, home):
    # Only auth retains its normal home/config identity. All lifecycle stores,
    # entity-local writes and team state are explicitly fixture-owned.
    root = Path(config['active_root'])
    return dict(PATH='/Library/Developer/CommandLineTools/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin',
        HOME=home, USER=pwd.getpwuid(config['owner_uid']).pw_name, LOGNAME=pwd.getpwuid(config['owner_uid']).pw_name, LC_ALL='C',
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1',
        RICHOS_ENTITY_ROOT=config['session_repo'], RICHOS_ENGINE_ROOT=config['engine'],
        RICHOS_WORKTREE_TX_DIR=str(root/'state/transactions'),
        RICHOS_WORKTREE_CAPTURE_DIR=str(root/'state/captures'),
        RICHOS_WORKTREE_LEDGER=str(root/'state/ledger.jsonl'),
        RICHOS_SESSIONS_DIR=str(root/'state/sessions'),
        RICHOS_PROJECTS_DIR=str(root/'state/project-scope'),
        RICHOS_LIVENESS_TEAMS_DIR=str(root/'state/teams'),
        GUARD_ISOLATION_TEAMS_DIR=str(root/'state/teams'),
        GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null')


def read_config(path):
    path = Path(path)
    for parent in (path, *path.parents):
        info = parent.lstat()
        require(info.st_uid == 0 and not info.st_mode & 0o022 and not stat.S_ISLNK(info.st_mode),
                'fixture configuration authority changed')
    value = json.loads(path.read_text())
    require(value['owner_uid'] == os.getuid() and os.getuid() > 0, 'owner-only canary operation')
    active = Path(value['active_root'])
    require(path == active/'canary.json' and re.fullmatch(PREFIX+'[0-9a-f]{32}', active.name)
            and value['session_repo'] == str(active/'session') and value['source_repo'] == str(active/'source')
            and value['engine'] == str(active/'engine'), 'fixture scope mismatch')
    return value




def verify_event_join(events, sid, aid, wrapper):
    require(all(event['input'].get('session_id')==sid for event in events),'foreign session hook event')
    before=[e for e in events if e['hook']=='guard-worktree-isolation.sh' and e['input'].get('tool_name')=='Agent']
    after=[e for e in events if e['hook']=='detect-nonnative-worktree.sh' and e['input'].get('tool_name')=='Agent']
    require(len(before)==len(after)==1 and before[0]['returncode']==after[0]['returncode']==0
            and before[0]['input'].get('tool_use_id')
            and before[0]['input']['tool_use_id']==after[0]['input'].get('tool_use_id'),'actual Agent intent/binding join missing')
    writing=[e for e in events if e['hook']=='guard-sealed-worktree.sh' and e['input'].get('agent_id')==aid
             and e['input'].get('tool_name')=='Bash' and shlex.split(e['input'].get('tool_input',{}).get('command',''))==[wrapper,'work']]
    require(writing and all(e['returncode']==0 for e in writing),'actual worker write did not pass the seal barrier')
    return before[0]['input']['tool_use_id']


def process_identity(pid):
    result=subprocess.run(['/bin/ps','-p',str(pid),'-o','lstart='],capture_output=True,text=True,
                          env={'PATH':'/usr/bin:/bin','LC_ALL':'C','LANG':'C','TZ':'UTC0'},timeout=5)
    start=' '.join(result.stdout.split())
    boot=subprocess.run(['/usr/sbin/sysctl','-n','kern.bootsessionuuid'],capture_output=True,text=True,timeout=5)
    require(result.returncode==0 and start and boot.returncode==0,'created process identity unavailable')
    return dict(pid=pid,pid_start='ps-lstart-utc-v1:'+start,boot_id=str(uuid.UUID(boot.stdout.strip())))


def operation(args):
    config = read_config(args.fixture_config)
    active = Path(config['active_root']); engine = Path(config['engine'])
    os.environ.update(isolated_env(config, pwd.getpwuid(os.getuid()).pw_dir))
    tx = module(engine/'scripts/lib/worktree-transactions.py')
    bridge = module(engine/'scripts/lib/managed-workspace-integration.py')
    sid = config['session_id']
    def transactions():
        rows = [row for row in tx.iter_transactions() if row.get('session_id') == sid]
        require(len(rows) <= 1, 'unexpected second canary agent')
        return rows
    def git(repo, *argv):
        return subprocess.check_output(['/usr/bin/git','-C',str(repo),*argv], env=os.environ, timeout=30).decode().strip()
    if args.op == 'prepare':
        pid = os.environ.get('CLAUDE_PID', '')
        require(pid.isdigit() and int(pid) > 0, 'actual Claude process PID unavailable')
        result = subprocess.run(['/bin/bash',str(engine/'scripts/create-teammate-worktree.sh'),
            config['source_repo'],config['agent_name'],'--session',sid,'--pid',pid],
            capture_output=True,text=True,timeout=150)
        require(result.returncode == 0, result.stderr[-2000:])
        # Read the exact prepared record after the real preparation helper.
        rows = [json.loads(line) for line in Path(os.environ['RICHOS_WORKTREE_LEDGER']).read_text().splitlines()]
        rows = [row for row in rows if row.get('event') == 'prepared' and row.get('session_id') == sid]
        require(len(rows) == 1 and rows[0].get('class') == 'managed-image', 'exact managed preparation unavailable')
        work = rows[0]['worktree']
        record = bridge.inspect_path(work, session_id=sid, agent_name=config['agent_name'])
        print(json.dumps(dict(manager_id=record['manager_id'], path=work, name=config['agent_name'],
            prompt='cross-repo-worktree: '+work+'\nRun '+config['wrapper']+' work once from your native worktree. '
                   'It writes and commits the fixture only in the assigned managed repository. Report the returned commit and finish.')))
        return 0
    if args.op == 'work':
        rows = transactions(); require(len(rows) == 1 and rows[0].get('sealed') and not rows[0].get('terminal'), 'sealed nonterminal transaction required')
        record = rows[0]
        native = [m for m in record['members'] if m['class'] == 'native']
        managed = [m for m in record['members'] if m['class'] == 'managed-image']
        require(len(native) == len(managed) == 1 and Path.cwd().resolve() == Path(native[0]['path']), 'worker must run in exact sealed native worktree')
        member = managed[0]; bridge.verify_member(member)
        work = Path(member['path'])
        target = work/'canary-delivered'
        require(not target.exists() and not target.is_symlink(), 'worker operation already performed')
        with target.open('x') as stream:
            stream.write(CONTENT); stream.flush(); os.fsync(stream.fileno())
        git(work,'config','user.name','RichOS canary'); git(work,'config','user.email','fixture@example.invalid')
        git(work,'add','--','canary-delivered'); git(work,'commit','-qm','real Claude delivered canary')
        print(json.dumps(dict(agent_id=record['agent_id'], manager_id=member['manager_id'], tip=git(work,'rev-parse','HEAD'))))
        return 0
    if args.op == 'finish':
        deadline = time.monotonic()+240
        last = 'awaiting actual terminal event'
        while time.monotonic() < deadline:
            rows = transactions()
            if rows and rows[0].get('terminal'):
                record = rows[0]
                subprocess.run([PYTHON,'-I','-S','-B',str(engine/'scripts/reconcile-terminal-worktrees.py'),
                    '--agent',sid+'/'+record['agent_id'],'--max-seconds','3'],env=os.environ,
                    capture_output=True,timeout=15)
                managed = [m for m in record['members'] if m['class'] == 'managed-image']
                require(len(managed) == 1, 'managed membership missing')
                try:
                    delivery = bridge.delivery_for(managed[0]['manager_id'],config['source_repo'])
                    git(config['source_repo'],'merge','--ff-only',delivery['tip'])
                    require((Path(config['source_repo'])/'canary-delivered').read_text() == CONTENT, 'delivered content mismatch')
                    print(json.dumps(delivery)); return 0
                except Exception as error:
                    last = str(error)
            time.sleep(1)
        raise RuntimeError('canary terminal/delivery deadline: '+last)
    if args.op == 'hook':
        require(args.hook in {name for hooks in HOOKS.values() for _,name in hooks}, 'unknown hook')
        payload = sys.stdin.buffer.read()
        value = json.loads(payload)
        require(value.get('session_id') == sid, 'hook belongs to another session')
        start = time.time()
        result = subprocess.run(['/bin/bash',str(engine/'scripts/hooks'/args.hook)], input=payload,
                                capture_output=True,env=os.environ,timeout=20)
        event = dict(hook=args.hook,input=value,stdout=result.stdout.decode(errors='replace'),
                     stderr=result.stderr.decode(errors='replace'),returncode=result.returncode,started_at=start,finished_at=time.time())
        path=active/'events'/(uuid.uuid4().hex+'.json')
        with path.open('x') as stream:
            json.dump(event,stream,sort_keys=True); stream.flush(); os.fsync(stream.fileno())
        sys.stdout.buffer.write(result.stdout); sys.stderr.buffer.write(result.stderr)
        return result.returncode
    raise RuntimeError('unsupported operation')


def execute(args, support, release, policy, owner):
    engine_source = support.protected(args.engine, False)
    manifest_path = support.protected(args.engine_manifest, True)
    expected_bytes = manifest_path.read_bytes()
    require(hashlib.sha256(expected_bytes).hexdigest() == args.engine_manifest_sha256, 'engine manifest pin mismatch')
    expected = json.loads(expected_bytes)
    require(file_manifest(engine_source) == expected, 'engine source does not match complete manifest')
    account = pwd.getpwuid(owner[0]); home=account.pw_dir
    claude=Path(home)/'.local/bin/claude'
    require(claude.is_file(), 'actual owner Claude executable unavailable')
    # Explicit settings suppress local configuration. Unknown managed policy is
    # not silently overridden; its hooks could run before stream initialization.
    for path in (Path('/Library/Application Support/ClaudeCode/managed-settings.json'),
                 Path('/Library/Managed Preferences/com.anthropic.claudecode.plist')):
        require(not path.exists() and not path.is_symlink(), 'managed Claude policy requires separate isolation review: '+str(path))
    env=dict(support.ENV,HOME=home,USER=account.pw_name,LOGNAME=account.pw_name)
    plugins=subprocess.run([str(claude),'--restricted','--setting-sources','','plugin','list','--json'],env=env,
        user=owner[0],group=owner[1],extra_groups=[],capture_output=True,timeout=30)
    require(plugins.returncode==0,'cannot inventory installed Claude plugins')
    plugin_rows=json.loads(plugins.stdout)
    require(isinstance(plugin_rows,list) and all(isinstance(row,dict) and isinstance(row.get('id'),str) and row['id'] for row in plugin_rows),'invalid plugin inventory')
    disabled_plugins={row['id']:False for row in plugin_rows}
    auth=subprocess.run([str(claude),'--setting-sources','','auth','status','--json'],env=env,
        user=owner[0],group=owner[1],extra_groups=[],capture_output=True,timeout=30)
    try: authenticated=json.loads(auth.stdout).get('loggedIn') is True
    except Exception: authenticated=False
    require(authenticated, 'normal owner login unavailable; no credentials copied or substituted')
    ident=PREFIX+uuid.uuid4().hex
    private=Path(policy['private_root'])/ident; active=Path(policy['active_root'])/ident
    require(not os.path.lexists(private) and not os.path.lexists(active), 'fixture namespace exists')
    manager=support.load(release,'managed-workspace-manager').WorkspaceManager(private,active,require_root=True)
    report=dict(version=1,acceptance_id=ident,session_id=str(uuid.uuid4()),owner_uid=owner[0],owner_gid=owner[1],
        private_root=str(private),active_root=str(active),root_pins=[support.pin(private),support.pin(active)],
        release=str(release),manifest_sha256=args.manifest_sha256,engine_original_manifest_sha256=args.engine_manifest_sha256,
        passed=False,activated=False,fixture_cleanup_complete=False,checks=[],normal_auth_reused=True,
        settings_sources=[],hook_profile='bounded native-plus-managed lifecycle',transcripts_retained=[])
    receipt=private/'acceptance.json'; support.save(receipt,report)
    server=cli=None
    def check(name,value,detail=''):
        report['checks'].append(dict(name=name,passed=bool(value),detail=detail));support.save(receipt,report)
        require(value,name+(': '+detail if detail else ''))
    def child(argv,**kwargs):
        return subprocess.run(argv,env=env,user=owner[0],group=owner[1],extra_groups=[],capture_output=True,
                              timeout=kwargs.pop('timeout',30),**kwargs)
    try:
        engine=active/'engine'; engine.mkdir(mode=0o755)
        for relative,digest in expected.items():
            source=engine_source/relative; destination=engine/relative
            payload=source.read_bytes(); require(hashlib.sha256(payload).hexdigest()==digest,'engine source changed during copy')
            destination.parent.mkdir(parents=True,exist_ok=True,mode=0o755)
            destination.write_bytes(payload);destination.chmod(0o755 if source.stat().st_mode & 0o111 else 0o644)
        report['bridge_substitution']=substitute_bridge(engine,active/'client.json')
        observed=file_manifest(engine)
        modified=report['bridge_substitution']['path']
        check('only-bridge-configuration-constant-substituted',set(observed)==set(expected) and
              all(observed[k]==expected[k] for k in expected if k!=modified))
        for current,dirs,files in os.walk(engine):
            Path(current).chmod(0o755)
            for name in files:
                path=Path(current)/name;path.chmod(0o755 if path.stat().st_mode & 0o111 else 0o644)
        for name in ('session','source','state','events'):
            path=active/name;path.mkdir(mode=0o700);os.chown(path,*owner)
        config=dict(owner_uid=owner[0],active_root=str(active),session_repo=str(active/'session'),
                    source_repo=str(active/'source'),engine=str(engine),session_id=report['session_id'],
                    agent_name='canary-sonnet-'+ident[-8:],wrapper=str(active/'canary-op'))
        project=Path(home)/'.claude/projects'/str(active/'session').replace('/','-')
        require(not project.exists() and not project.is_symlink(),'fresh canary project transcript namespace already exists')
        scope=active/'state/project-scope';scope.mkdir(mode=0o755)
        (scope/'canary-project').symlink_to(project,target_is_directory=True)
        report['normal_project_transcript_directory']=str(project)
        env=isolated_env(config,home)
        for repo in (active/'session',active/'source'):
            for argv in (['init','-q'],['config','user.name','RichOS canary'],['config','user.email','fixture@example.invalid']):
                result=child(['/usr/bin/git','-C',str(repo),*argv]);require(result.returncode==0,result.stderr.decode(errors='replace'))
        session=active/'session'
        def owner_write(path,content):
            result=child([PYTHON,'-I','-S','-c','import pathlib,sys; p=pathlib.Path(sys.argv[1]); p.parent.mkdir(parents=True,exist_ok=True);p.write_text(sys.stdin.read())',str(path)],input=content.encode())
            require(result.returncode==0,result.stderr.decode(errors='replace'))
        owner_write(session/'orchestration.config', 'SESSION_TEAMS_DIR='+shlex.quote(str(active/'state/teams'))+'\nALLOWED_MODELS="sonnet opus haiku fable"\n')
        owner_write(session/'.claude/agents/canary.md','---\nname: canary\ndescription: Execute the isolated managed worktree canary.\nmodel: sonnet\n---\nRun only the exact canary-op work command supplied. Do not create any other worktree. Return its commit then finish.\n')
        owner_write(session/'CLAUDE.md','This is a disposable lifecycle fixture. Only the exact canary-op wrapper is authorized for shell work.\n')
        owner_write(active/'source/tracked','initial canary source\n')
        for repo in (session,active/'source'):
            for argv in (['add','.'],['commit','-qm','fixture']):
                result=child(['/usr/bin/git','-C',str(repo),*argv]);require(result.returncode==0,result.stderr.decode(errors='replace'))
        before_heads=child(['/usr/bin/git','-C',str(active/'source'),'for-each-ref','--format=%(refname)','refs/heads/'])
        require(before_heads.returncode==0,'source branch inventory unavailable')
        report['initial_source_branches']=before_heads.stdout.decode().splitlines()
        support.save(active/'canary.json',config);(active/'canary.json').chmod(0o644)
        runtime_copy=active/'canary-runtime.py';runtime_copy.write_bytes(Path(__file__).read_bytes());runtime_copy.chmod(0o644)
        wrapper=Path(config['wrapper'])
        wrapper.write_text('#!/bin/bash\nset -euo pipefail\nexec '+shlex.quote(PYTHON)+' -I -S -B '+shlex.quote(str(runtime_copy))+' --fixture-config '+shlex.quote(str(active/'canary.json'))+' --op "$@"\n');wrapper.chmod(0o755)
        client=dict(version=1,socket=str(active/'b.sock'),active_root=str(active),repositories={'fixture':str(active/'source')})
        support.save(active/'client.json',client);(active/'client.json').chmod(0o644)
        fixture_policy=dict(version=1,private_root=str(private),active_root=str(active),owners={str(owner[0]):{'gid':owner[1]}},
            repositories={'fixture':dict(path=str(active/'source'),owners=[owner[0]],retention_days=14,size='128m')})
        support.save(private/'policy.json',fixture_policy)
        hook_settings={}
        for event,entries in HOOKS.items():
            hook_settings[event]=[]
            for matcher,name in entries:
                command=shlex.quote(str(wrapper))+' hook --hook '+shlex.quote(name)
                item=dict(hooks=[dict(type='command',command=command,timeout=25)])
                if matcher:item['matcher']=matcher
                hook_settings[event].append(item)
        settings=dict(hooks=hook_settings,enabledPlugins=disabled_plugins,permissions=dict(allow=['Agent(canary)','Bash('+str(wrapper)+' *)'],defaultMode='dontAsk'))
        support.save(active/'settings.json',settings);(active/'settings.json').chmod(0o644)
        plugin_check=child([str(claude),'--restricted','--setting-sources','','--settings',str(active/'settings.json'),'plugin','list','--json'])
        require(plugin_check.returncode==0,'effective plugin isolation preflight failed')
        effective_plugins=json.loads(plugin_check.stdout)
        check('all-installed-plugins-explicitly-disabled-before-model-execution',isinstance(effective_plugins,list) and
              {row['id'] for row in effective_plugins}==set(disabled_plugins) and all(row.get('enabled') is False for row in effective_plugins))
        report['explicitly_disabled_plugin_ids']=sorted(disabled_plugins)
        with (private/'broker.log').open('wb') as log:
            server=subprocess.Popen([PYTHON,'-I','-S','-B',str(release/'managed-workspace-broker.py'),'--policy',str(private/'policy.json'),'--socket',str(active/'b.sock')],
                env=support.ENV,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=log)
        report['broker_process']=process_identity(server.pid);support.save(receipt,report)
        deadline=time.monotonic()+15
        while time.monotonic()<deadline and not (active/'b.sock').exists():
            require(server.poll() is None,'fixture broker exited');time.sleep(.1)
        require((active/'b.sock').exists(),'fixture broker socket deadline')
        prompt='Run '+str(wrapper)+' prepare. Then launch exactly one Agent of subagent_type canary, name from the preparation response, isolation worktree and run_in_background true, using its exact prompt. After the async launch acknowledgement, run '+str(wrapper)+' finish with a 300000ms timeout. Report the resulting delivery. Do not use any other shell commands or edit tools.'
        argv=[str(claude),'-p','--session-id',report['session_id'],'--setting-sources','','--settings',str(active/'settings.json'),
              '--restricted','--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--no-chrome','--tools','Agent,Bash,Read',
              '--permission-mode','dontAsk','--output-format','stream-json','--include-hook-events','--verbose',
              '--agents',json.dumps({'canary':{'description':'Execute the isolated managed worktree canary.','prompt':'Run only the supplied canary-op work command and report its result.','model':'sonnet'}}),
              '--max-budget-usd',str(args.max_budget_usd),prompt]
        # exec preserves the launcher PID, which preparation records as Claude's.
        launch=['/bin/bash','-c','export CLAUDE_PID=$$; exec "$@"','canary-launch',*argv]
        with (private/'claude-stream.jsonl').open('wb') as output,(private/'claude-stderr.log').open('wb') as errors:
            cli=subprocess.Popen(launch,cwd=session,env=env,user=owner[0],group=owner[1],extra_groups=[],stdin=subprocess.DEVNULL,stdout=output,stderr=errors)
            report['claude_process']=process_identity(cli.pid);support.save(receipt,report)
            cli.wait(timeout=420)
        check('real-claude-process-completed',cli.returncode==0);cli=None
        stream=[json.loads(line) for line in (private/'claude-stream.jsonl').read_text().splitlines() if line.strip()]
        init=[row for row in stream if row.get('type')=='system' and row.get('subtype')=='init']
        check('actual-cli-reports-no-loaded-plugins-or-mcp',len(init)==1 and init[0].get('plugins')==[] and init[0].get('mcp_servers')==[])
        events=[json.loads(path.read_text()) for path in (active/'events').glob('*.json')]
        report['transcripts_retained']=sorted({event['input'][key] for event in events for key in ('transcript_path','agent_transcript_path') if event['input'].get(key)})
        starts=[e for e in events if e['input'].get('hook_event_name')=='SubagentStart']
        require(len(starts)==1,'exactly one real native agent start required')
        aid=starts[0]['input']['agent_id'];report['agent_id']=aid
        report['agent_tool_use_id']=verify_event_join(events,report['session_id'],aid,str(wrapper))
        check('actual-agent-binding-and-worker-write-events-match',True)
        tx_path=active/'state/transactions'/report['session_id']/(aid+'.json')
        transaction=json.loads(tx_path.read_text())
        managed=[m for m in transaction['members'] if m['class']=='managed-image']
        native=[m for m in transaction['members'] if m['class']=='native']
        check('real-hooks-sealed-native-and-managed-membership',transaction.get('sealed') and len(managed)==len(native)==1 and
              transaction['session_id']==report['session_id'] and transaction['agent_id']==aid)
        check('actual-subagent-stop-is-terminal-ingress',bool(transaction.get('terminal')) and any(
            e['input'].get('hook_event_name')=='SubagentStop' and e['input'].get('agent_id')==aid for e in events))
        manager_id=managed[0]['manager_id'];report['manager_id']=manager_id
        lifecycle=manager.inspect(manager_id)
        check('unattended-broker-reclaimed-the-managed-image',lifecycle['state']=='retained' and not (private/manager_id/'image.sparsebundle').exists())
        delivery=manager.delivery(manager_id);report['delivery']=delivery
        result=child(['/usr/bin/git','-C',str(active/'source'),'rev-parse','HEAD'])
        check('exact-delivery-merged-into-generated-source',result.returncode==0 and result.stdout.decode().strip()==delivery['tip'] and
              (active/'source/canary-delivered').read_text()==CONTENT)
        native_path=native[0]['path']
        removed_events=[e for e in events if e['input'].get('hook_event_name')=='WorktreeRemove' and e['input'].get('worktree_path')==native_path]
        registry=child(['/usr/bin/git','-C',str(session),'worktree','list','--porcelain','-z'])
        check('native-platform-checkout-and-registration-are-gone',bool(removed_events) and registry.returncode==0 and
              not Path(native_path).exists() and ('worktree '+native_path).encode() not in registry.stdout.split(b'\0') and
              all(not Path(native[0][key]).exists() and ('worktree '+native[0][key]).encode() not in registry.stdout.split(b'\0')
                  for key in ('quarantine','quarantine_path') if native[0].get(key)))
        after_heads=child(['/usr/bin/git','-C',str(active/'source'),'for-each-ref','--format=%(refname)','refs/heads/'])
        check('managed-delivery-created-no-ordinary-source-branches',after_heads.returncode==0 and after_heads.stdout.decode().splitlines()==report['initial_source_branches'])
        check('transaction-persisted-managed-delivery',managed[0].get('state')=='removed' and managed[0].get('delivery')==delivery)
        server.terminate();server.wait(timeout=15);check('fixture-broker-stops-cleanly',server.returncode==0);server=None
        report['passed']=True
    except Exception as error:
        report['error']=str(error)
    finally:
        support.stop(cli);support.stop(server)
        # Preserve all fixture evidence on both outcomes. A real background Agent
        # may outlive its lead on failure, so this runner has no recursive cleanup.
        try:
            require(report['root_pins']==[support.pin(private),support.pin(active)],'fixture roots changed')
            attachments=manager.provider.attachment_inventory()
            report['remaining_fixture_attachments']=[item['image-path'] for item in attachments if private in Path(item['image-path']).resolve().parents]
            report['strict_attachment_inventory_complete']=True
        except Exception as error:
            report['inventory_error']=str(error);report['passed']=False
        report['retained_fixture_receipt']=str(receipt);support.save(receipt,report)
        print(json.dumps(report,sort_keys=True,indent=2))
    return 0 if report['passed'] else 1


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--release');parser.add_argument('--manifest-sha256');parser.add_argument('--owner-uid',type=int)
    parser.add_argument('--engine');parser.add_argument('--engine-manifest');parser.add_argument('--engine-manifest-sha256')
    parser.add_argument('--max-budget-usd',type=float,default=1.0)
    parser.add_argument('--fixture-config');parser.add_argument('--op',choices=('prepare','work','finish','hook'))
    parser.add_argument('--hook')
    args=parser.parse_args()
    if args.op:
        require(args.fixture_config,'operation needs fixed fixture config');return operation(args)
    require(all(getattr(args,key) for key in ('release','manifest_sha256','owner_uid','engine','engine_manifest','engine_manifest_sha256')),'all runtime and engine pins required')
    require(0<args.max_budget_usd<=5,'bounded canary budget required')
    signal.pthread_sigmask(signal.SIG_UNBLOCK,{signal.SIGTERM,signal.SIGINT})
    support=module(Path(__file__).with_name('managed-workspace-interrupted-creation.acceptance.py'))
    support.protected(__file__,True)
    release,policy,owner=support.runtime(args)
    return execute(args,support,release,policy,owner)


if __name__=='__main__':
    raise SystemExit(main())
