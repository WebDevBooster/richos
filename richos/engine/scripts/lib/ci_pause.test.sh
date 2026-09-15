#!/usr/bin/env bash
# Focused pause checks. No network, model calls or writes to operator state.
set -euo pipefail
CI_PAUSE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CI_PAUSE_LIB
python3 - <<'PY'
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest.mock import patch

lib = Path(os.environ['CI_PAUSE_LIB'])
sys.path.insert(0, str(lib))
import ci_pause

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

with tempfile.TemporaryDirectory(prefix='ci-pause-test-') as temp:
    tmp = Path(temp)
    config = tmp / 'pauses.json'
    os.environ['CI_PAUSE_CONFIG'] = str(config)
    os.environ['CI_SURFACE_STATE_DIR'] = str(tmp / 'surface')
    record = {'paused': True, 'reason': 'operator requested pause', 'since': '2026-09-15'}
    config.write_text(json.dumps({'repositories': {'Example/paused': record}}))
    assert ci_pause.pause_for('git@github.com:example/paused.git')
    assert ci_pause.pause_for('https://github.com/Example/paused.git')
    assert not ci_pause.pause_for('https://elsewhere.invalid/Example/paused.git')
    assert not ci_pause.pause_for('Example/paused-extra')
    assert not ci_pause.pause_for('Example/active')
    repo = tmp / 'repo'
    subprocess.run(['git', 'init', '-q', str(repo)], check=True)
    subprocess.run(['git', '-C', str(repo), 'remote', 'add', 'origin',
                    'git@github.com:Example/paused.git'], check=True)
    assert ci_pause.pause_for(repo)
    print('PASS exact repository and worktree identity')

    red = load('pause_red_test', lib / 'ci-red.py')
    with patch.object(red.subprocess, 'run', side_effect=AssertionError('network attempted')):
        result, error = red.probe('Example/paused', 'main', 1)
        assert not error and result['state'] == 'paused'
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            assert red.main(['--repo', 'Example/paused', '--json', '--refresh']) == 0
        assert json.loads(output.getvalue())['state'] == 'paused'
    fake = subprocess.CompletedProcess([], 0, json.dumps({'workflow_runs': []}), '')
    with patch.object(red.subprocess, 'run', return_value=fake) as request:
        assert red.probe('Example/active', 'main', 1)[0]['state'] == 'clear'
        request.assert_called_once()
    print('PASS paused probe makes no API call while other repositories still do')

    surface = load('pause_surface_test', lib / 'ci-surface.py')
    repos = [(str(repo), 'Example/paused', 'explicit'),
             (str(tmp), 'Example/active', 'explicit')]
    received = []
    def collect(selected, *args):
        received.extend(selected)
        return []
    with patch.object(surface, 'discover_repos', return_value=repos), patch.object(surface, 'collect', collect):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            assert surface.main(['--offline']) == 0
        doc = json.loads(output.getvalue())
        assert [r[1] for r in received] == ['Example/active']
        assert doc['paused_repositories'][0]['slug'] == 'Example/paused'
    print('PASS scanner excludes only the paused repository before collection')

    owned = load('pause_owned_test', lib / 'owned-systems.py')
    systems = [{'id': 'ci', 'title': 'CI', 'why': '', 'match': '', 'jurisdiction': '',
                'check': 'false', 'timeout': 2, 'evidence': ''}]
    with patch.object(owned, 'run', side_effect=AssertionError('paused check executed')):
        doc = owned.sweep(str(repo), str(lib.parent.parent), 'fixture', systems)
    assert doc['systems'][0]['status'] == 'PAUSED'
    assert owned.ordered_standing(doc) == []
    assert 'intentionally paused' in owned.render(doc)
    assert 'Every system in jurisdiction is healthy' not in owned.render(doc)
    print('PASS ownership reports paused without demanding repairs or claiming health')

    gate_path = lib.parent / 'hooks' / 'guard-ci-turn-gate.py'
    if gate_path.exists():
        gate = load('pause_turn_test', gate_path)
        state = {'pushes': {'paused': {'dir': str(repo), 'at': 1, 'branch': 'main'}}}
        with patch.object(gate, 'load_state', return_value=state), \
             patch.object(gate, 'save_state'), \
             patch.object(gate, 'observe_pushes', return_value=([], None)), \
             patch.object(gate, 'repo_facts', return_value=(str(repo), 'Example/paused', None)), \
             patch.object(gate, 'verdict_for', side_effect=AssertionError('paused verdict requested')):
            assert gate.evaluate({'session_id': 'fixture'}, gate.Budget(2)) == (0, '', '')
        print('PASS turn ends without a CI verdict or acknowledgment')

    config.write_text(json.dumps({'repositories': {}}))
    assert not ci_pause.pause_for(repo)
    config.unlink()
    assert not ci_pause.pause_for('Example/paused')
    print('PASS removing the pause restores normal eligibility')
print('All focused CI pause checks passed.')
PY
