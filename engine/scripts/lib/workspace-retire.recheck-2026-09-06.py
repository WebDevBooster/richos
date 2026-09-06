# VENDORED VERBATIM from richos-hq docs/verification/worktree-removal-fix-recheck-2026-09-06/
# reproduce.py (reviewer: Codex, 2026-09-06), the independent reproduction of the
# three findings against the 2026-09-06 fix at 3aa3acb — the second review. It is
# the ACCEPTANCE TEST for the third repair and is run by workspace-retire.test.sh
# on every run, so it stops being a thing somebody remembers to run.
#
# ONE line differs from the reviewer's file: ENGINE below is derived from this
# file's own location instead of the installed main checkout, so the script
# probes the engine it ships with. Every other byte is the reviewer's.
#
# The reviewer's own reading rule applies: "the script's successful exit indicates
# that the probes ran, not that the implementation is safe." The suite reads outcomes.
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

# Apply the same real acquisition interleaving to legacy removal, which now
# shares authority with retirement but still performs its own destructive act.
base, repo, entity, work = fixture('legacy-acquisition-after-preserve')
old, new = 'aaaa111122223333', 'bbbb111122223333'
register(repo, work, old)
terminate(work, old)
original_preserve = m.preserve
observed = {}
def preserve_then_acquire(ws, target, dest):
    result = original_preserve(ws, target, dest)
    assert result['status'] == 'verified', result
    live_native(entity, new)
    register(repo, work, new)
    (work / 'new-live-work.txt').write_text('only copy, written after archive\n')
    fresh = m.resolve_workspace(ws['id'])
    lib = fresh['_mod']
    auth = m.termination_authority(str(entity), str(repo), str(work), owner=old,
                                  records=fresh['_all'], ledger_mod=lib, live_mod=lib._liveness_module())
    observed['authority_after_acquisition'] = auth['reason_code']
    assert not auth['authorized'] and auth['verdict'] == 'ALIVE', auth
    return result
m.preserve = preserve_then_acquire
res = m.remove_legacy(str(entity), str(repo), str(work), old, force=True)
m.preserve = original_preserve
manifest = json.loads(Path(res['preservation']['manifest']).read_text())
results.append({'case': 'legacy_worker_acquires_after_preservation', **observed,
                'outcome': res['outcome'], 'reason_code': res.get('reason_code'),
                'workspace_survived': work.exists(),
                'new_file_in_archive': any(x['path'] == 'workspace/new-live-work.txt' for x in manifest['entries']),
                'new_file_survived': (work / 'new-live-work.txt').exists()})

# A non-forced removal can still erase ignored local content even when Git
# status is clean. Exercise the actual shell interface with no force flag.
base, repo, entity, work = fixture('legacy-ignored-without-force')
owner = 'cccc111122223333'
register(repo, work, owner)
terminate(work, owner)
(work / '.gitignore').write_text('local-draft.txt\n')
git(work, 'add', '.gitignore')
git(work, 'commit', '-qm', 'ignore local draft')
(work / 'local-draft.txt').write_text('only copy of a local draft\n')
status = git(work, 'status', '--porcelain=v1', '--untracked-files=all').stdout
assert status == '', status
r = run('bash', ENGINE / 'remove-agent-worktree.sh', '--owner', owner, str(work),
        '--repo', str(repo), '--entity-repo', str(entity), check=False)
res = json.loads(r.stdout)
results.append({'case': 'legacy_ignored_file_without_force', 'git_status': status,
                'exit': r.returncode, 'outcome': res['outcome'], 'reason_code': res.get('reason_code'),
                'workspace_survived': work.exists(), 'ignored_file_survived': (work / 'local-draft.txt').exists(),
                'preservation': res.get('preservation'),
                'archive_count': len(list(Path(os.environ['RICHOS_WORKSPACE_RETIRE_DIR']).rglob('workspace.tar')))})

# The branch option must be tied to the workspace being removed. An unrelated
# unmerged branch should never be deleted under the target workspace's backup.
base, repo, entity, work = fixture('legacy-unrelated-branch')
owner = 'dddd111122223333'
register(repo, work, owner)
terminate(work, owner)
git(repo, 'checkout', '-qb', 'unrelated-unmerged')
(repo / 'unrelated.txt').write_text('independent committed work\n')
git(repo, 'add', 'unrelated.txt')
git(repo, 'commit', '-qm', 'unrelated work')
tip = git(repo, 'rev-parse', 'HEAD').stdout.strip()
git(repo, 'checkout', '-q', 'main')
r = run('bash', ENGINE / 'remove-agent-worktree.sh', '--owner', owner, str(work),
        '--repo', str(repo), '--entity-repo', str(entity), '--branch', 'unrelated-unmerged', check=False)
res = json.loads(r.stdout)
refs = git(repo, 'for-each-ref', '--contains', tip, '--format=%(refname)').stdout.splitlines()
results.append({'case': 'legacy_unrelated_branch_deletion', 'exit': r.returncode,
                'outcome': res['outcome'], 'branch_option': 'unrelated-unmerged',
                'workspace_branch': res.get('branch', {}).get('checked_out'),
                'unrelated_branch_deleted': git(repo, 'show-ref', '--verify', '--quiet', 'refs/heads/unrelated-unmerged', check=False).returncode != 0,
                'refs_preserving_unrelated_tip': refs,
                'unrelated_commit_object_survives': git(repo, 'cat-file', '-e', tip, check=False).returncode == 0})

(ROOT / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
print(json.dumps(results, indent=2))
print('Evidence:', ROOT / 'results.json')
