# VENDORED VERBATIM from richos-hq docs/verification/worktree-removal-fix-review-2026-09-06/
# reproduce.py (reviewer: Codex, 2026-09-06), the independent reproduction of the
# three findings against the 2026-09-05 fix. It is the ACCEPTANCE TEST for the
# 2026-09-06 repair and is run by workspace-retire.test.sh on every run, so it
# stops being a thing somebody remembers to run.
#
# ONE line differs from the reviewer's file: ENGINE below is derived from this
# file's own location instead of the installed main checkout, so the script
# probes the engine it ships with. Every other byte is the reviewer's.
#
# The reviewer's own reading rule applies: "Its exit status alone is not a
# pass/fail verdict; inspect the named outcomes." The suite does exactly that.
# Independent review probes. Creates disposable repositories under the system temp directory.
# Records observed outcomes; read results.json to assess failures. No real workspace is retired.
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile

ENGINE = Path(__file__).resolve().parent.parent   # <engine>/scripts — the one changed line
ROOT = Path(tempfile.mkdtemp(prefix='richos-retirement-audit-')).resolve()
spec = importlib.util.spec_from_file_location('retirement_audit', ENGINE / 'lib/workspace-retire.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
os.environ['PYTHONDONTWRITEBYTECODE'] = '1'

def run(*args, check=True):
    r = subprocess.run([str(a) for a in args], text=True, capture_output=True)
    if check and r.returncode:
        raise RuntimeError((args, r.returncode, r.stdout, r.stderr))
    return r

def git(repo, *args, check=True):
    return run('git', '-C', repo, *args, check=check)

def init(repo):
    repo.mkdir()
    git(repo, 'init', '-q', '-b', 'main')
    git(repo, 'config', 'user.name', 'Disposable Audit')
    git(repo, 'config', 'user.email', 'audit@example.invalid')
    git(repo, 'config', 'core.hooksPath', '/dev/null')
    (repo / 'seed').write_text('seed\n')
    git(repo, 'add', 'seed')
    git(repo, 'commit', '-qm', 'seed')

def fixture(name):
    base = ROOT / name
    base.mkdir()
    repo, entity, work = base / 'repo', base / 'entity', base / 'work'
    init(repo)
    init(entity)
    git(repo, 'worktree', 'add', '-qb', 'work', work)
    os.environ['RICHOS_WORKTREE_LEDGER'] = str(base / 'ownership.jsonl')
    os.environ['RICHOS_WORKSPACE_RETIRE_DIR'] = str(base / 'state')
    os.environ.pop('RICHOS_WORKSPACE_RETENTION_DAYS', None)
    return base, repo, entity, work

def ledger(*args):
    return run('python3', ENGINE / 'lib/worktree-ledger.py', '--ledger', os.environ['RICHOS_WORKTREE_LEDGER'], *args)

def register(repo, work, owner):
    ledger('record', 'registered', '--agent-id', owner, '--teammate', 'audit-' + owner,
           '--session-id', 'audit-session-' + owner, '--repo', repo, '--worktree', work,
           '--branch', 'work', '--class', 'hand-rolled')

def terminate(work, owner):
    ledger('record', 'terminated', '--agent-id', owner, '--worktree', work,
           '--reason', 'fixture witnessed termination', '--witness', 'audit')

def live_native(entity, owner):
    native = entity / '.claude/worktrees' / ('agent-' + owner)
    native.parent.mkdir(parents=True, exist_ok=True)
    git(entity, 'worktree', 'add', '-qb', 'native-' + owner, native)
    git(entity, 'worktree', 'lock', '--reason', f'claude agent agent-{owner} (pid {os.getpid()} start audit)', native)
    return native

results = []

# The sanctioned legacy helper must refuse a bogus owner for a live worker's
# registered external worktree. Every path below is an audit fixture.
base, repo, entity, work = fixture('legacy-live')
owner = '1111aaaa2222bbbb'
register(repo, work, owner)
native = live_native(entity, owner)
(work / 'uncommitted.txt').write_text('only copy of live work\n')
ws = m.resolve_workspace(m.workspace_id(str(repo), str(work)))
mod = ws['_mod']
verdict = mod.judge(str(entity), str(work), [], ws['_all'], write=False, repo=str(repo), mod=mod._liveness_module())
assert verdict['verdict'] == 'ALIVE', verdict
r = run('bash', ENGINE / 'remove-agent-worktree.sh', '--owner', 'never-registered', str(work),
        '--repo', str(repo), '--entity-repo', str(entity), '--force', check=False)
results.append({'case': 'legacy_unknown_owner_live_target', 'verified_liveness': verdict['verdict'],
                'exit': r.returncode, 'workspace_survived': work.exists(),
                'native_owner_workspace_survived': native.exists(), 'output': r.stdout + r.stderr})

# Schedule a real acquisition immediately after the archive completes, after
# the manager's second ownership check. The wrapper changes scheduling only.
base, repo, entity, work = fixture('startup-after-check')
old, new = '3333aaaa4444bbbb', '5555aaaa6666bbbb'
register(repo, work, old)
terminate(work, old)
original_preserve = m.preserve
race_observation = {}
def preserve_then_start(ws, target, dest):
    result = original_preserve(ws, target, dest)
    assert result['status'] == 'verified', result
    live_native(entity, new)
    register(repo, work, new)
    (work / 'new-live-work.txt').write_text('written after preservation\n')
    fresh = m.resolve_workspace(ws['id'])
    lib = fresh['_mod']
    v = lib.judge(str(entity), str(work), [], fresh['_all'], write=False, repo=str(repo), mod=lib._liveness_module())
    race_observation['liveness_before_rename'] = v['verdict']
    assert v['verdict'] == 'ALIVE', v
    return result
m.preserve = preserve_then_start
res = m.retire(m.workspace_id(str(repo), str(work)), entity=str(entity), retention=0)
m.preserve = original_preserve
q = Path(res.get('quarantine', {}).get('path', '/nonexistent-audit-result'))
preserved_names = []
if res.get('preservation', {}).get('manifest'):
    preserved_names = [e['path'] for e in json.loads(Path(res['preservation']['manifest']).read_text())['entries']]
before_sweep = (q / 'new-live-work.txt').exists()
sweep = m.sweep(retention=0, execute=True)
results.append({'case': 'worker_acquires_after_last_liveness_check', **race_observation,
                'outcome': res['outcome'], 'original_path_survived': work.exists(),
                'new_work_in_quarantine_before_sweep': before_sweep,
                'new_work_in_archive': 'workspace/new-live-work.txt' in preserved_names,
                'new_work_survived_sweep': (q / 'new-live-work.txt').exists(),
                'sweep': sweep['items']})

# A real permissions failure at the journal should never become successful
# retirement with no discoverable restore record.
base, repo, entity, work = fixture('journal-failure')
owner = '7777aaaa8888bbbb'
register(repo, work, owner)
terminate(work, owner)
state = Path(os.environ['RICHOS_WORKSPACE_RETIRE_DIR'])
state.mkdir()
journal = state / 'retirements.jsonl'
journal.write_text('')
journal.chmod(0o400)
wsid = m.workspace_id(str(repo), str(work))
res = m.retire(wsid, entity=str(entity))
restore = m.restore(wsid, str(base / 'restored'))
journal.chmod(0o600)
results.append({'case': 'retirement_journal_unwritable', 'outcome': res['outcome'],
                'workspace_survived_at_original_path': work.exists(),
                'journal_bytes': journal.stat().st_size,
                'restore_outcome': restore['outcome'], 'restore_reason': restore.get('reason_code')})

(ROOT / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
print(json.dumps(results, indent=2))
print('Evidence:', ROOT / 'results.json')
