#!/usr/bin/env python3
"""Regenerate an approved legacy inventory as its explicit unprivileged owner."""
import importlib.util
import json
import os
from pathlib import Path
import pwd
import re
import stat
import sys

FIELDS = {'version', 'owner_uid', 'owner_gid', 'owner_home', 'transactions', 'ledger'}


def normalized_context(value):
    if not isinstance(value, dict) or set(value) not in (FIELDS, FIELDS | {'operator_attestation'}) or value['version'] != 1:
        raise ValueError('explicit owner inspection context required')
    uid, gid = value['owner_uid'], value['owner_gid']
    if type(uid) is not int or uid <= 0 or type(gid) is not int or gid < 0:
        raise ValueError('unprivileged numeric inspection owner required')
    account = pwd.getpwuid(uid)
    if gid != account.pw_gid or value['owner_home'] != os.path.normpath(account.pw_dir):
        raise ValueError('inspection owner must match the local account identity')
    for key in ('owner_home', 'transactions', 'ledger'):
        path = value[key]
        if (not isinstance(path, str) or not path or '\0' in path or not os.path.isabs(path)
                or path != path.strip() or '..' in Path(path).parts or path != os.path.normpath(path)):
            raise ValueError('explicit normalized absolute inspection paths required')
    if 'operator_attestation' in value:
        descriptor = value['operator_attestation']
        if (not isinstance(descriptor, dict) or set(descriptor) != {'path', 'sha256'}
                or not isinstance(descriptor['path'], str) or not os.path.isabs(descriptor['path'])
                or descriptor['path'] != os.path.normpath(descriptor['path']) or descriptor['path'] != descriptor['path'].strip()
                or '..' in Path(descriptor['path']).parts or '\0' in descriptor['path']
                or not isinstance(descriptor['sha256'], str) or not re.fullmatch('[0-9a-f]{64}', descriptor['sha256'])):
            raise ValueError('exact operator attestation descriptor required')
    return dict(value)


def _history_path(value, *, directory):
    path = Path(value)
    for entry in (path, *path.parents):
        if stat.S_ISLNK(entry.lstat().st_mode):
            raise ValueError('symlink in explicit history path')
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    if not kind(path.lstat().st_mode):
        raise ValueError('explicit history path has wrong type')


def inspect_owner(policy, context, operator_attestation=None):
    context = normalized_context(context)
    if os.geteuid() == 0 or (os.geteuid(), os.getegid()) != (context['owner_uid'], context['owner_gid']):
        raise ValueError('inspection must execute as the approved unprivileged owner')
    _history_path(context['transactions'], directory=True)
    _history_path(context['ledger'], directory=False)
    # No ambient root HOME, injected process inventories, Git state or Python
    # hooks may select the history or executable used for this report.
    os.environ.clear()
    os.environ.update(PATH='/usr/bin:/bin:/usr/sbin:/sbin', HOME=context['owner_home'],
                      LC_ALL='C', LANG='C', TZ='UTC0',
                      RICHOS_WORKTREE_TX_DIR=context['transactions'],
                      RICHOS_WORKTREE_LEDGER=context['ledger'])
    path = Path(__file__).with_name('legacy-workspace-maintenance.py')
    spec = importlib.util.spec_from_file_location('legacy_owner_planner', path)
    planner = importlib.util.module_from_spec(spec);spec.loader.exec_module(planner)
    transactions, records, errors = planner.history.load_history()
    report = planner.plan(policy, transactions, records, input_errors=errors)
    baseline_context = {key: value for key, value in context.items() if key != 'operator_attestation'}
    report['inspection_context'] = baseline_context
    if 'operator_attestation' in context:
        if (not isinstance(operator_attestation, dict) or planner.history._digest(operator_attestation)
                != context['operator_attestation']['sha256']):
            raise ValueError('operator attestation payload differs from protected descriptor')
        spec = importlib.util.spec_from_file_location('legacy_operator', Path(__file__).with_name('legacy-workspace-operator.py'))
        operator = importlib.util.module_from_spec(spec);spec.loader.exec_module(operator)
        report = operator.validate_and_apply(report, operator_attestation)
    elif operator_attestation is not None:
        raise ValueError('unexpected operator attestation payload')
    report['inspection_context'] = context
    return report


def main():
    payload = json.load(sys.stdin)
    if not isinstance(payload, dict) or set(payload) not in ({'policy', 'inspection_context'}, {'policy', 'inspection_context', 'operator_attestation'}):
        raise ValueError('exact owner inspection request required')
    report = inspect_owner(payload['policy'], payload['inspection_context'], payload.get('operator_attestation'))
    print(json.dumps(report, sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(2)
