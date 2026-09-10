#!/usr/bin/env python3
"""workspace-scope.py — THE CLOSED-WORLD REPORT: every worktree, decided.

===========================================================================
WHY THIS FILE EXISTS
===========================================================================
The CEO, 2026-09-10, on what he actually wants: *"finally NOT have anything
undecided AFTER the corresponding one was landed"*, and, when it had not
happened: *"WHEN THE FUCK WILL ALL THE FINISHED GARBAGE START GETTING CLEANED
UP AUTOMATICALLY AND STOP WASTING MY FUCKING TIME?"*

Every existing tool answers a question about the workspaces it OWNS.
`reconcile-terminal-worktrees.py --preview` reports the members of terminal
transactions. `reap-stale-worktrees.sh --discover` reports what it would
select. Neither of them can say the sentence he asked for, because neither
enumerates the things it does NOT own — and an item nobody enumerates is not
decided, it is invisible.

So this walks every worktree of every known repository and gives each one of
them exactly one of four dispositions, with the reason it was reached:

    OURS-READY         ours, and the lane would reclaim it right now: the next
                       terminal event or the nightly pass takes it
    OURS-HELD          ours, still standing, WITH THE CAUSE NAMED
    EXCLUDED           the CEO's codex ruling, by name (ceo-decisions.md 31)
    NOT-OURS           no declared owned shape matches; someone else's

There is no fifth bucket and there is deliberately no "unknown". A thing this
cannot classify is OURS-HELD with the reason "could not be classified", which
is a held item somebody has to look at rather than a silence.

(There is no OURS-RECLAIMED row, and that is not an omission: a reclaimed
workspace is not in any registry to enumerate. What was reclaimed is in the
transaction record and in the reconciler's own run log, which count it.)

REPORTING ONLY. This file removes nothing, renames nothing, and takes no lock.
It exists so that a number can be published before anything blocks, which is
R6 of the land-completeness specification and the discipline this whole area
was rebuilt under.

===========================================================================
WHAT "HELD" MUST NEVER MEAN
===========================================================================
A hold that says "undecidable" is a shrug wearing a status. Every hold here
carries a CAUSE and an OWNER of that cause:

    an external process has the tree open   -> named, with its pid and command
    uncommitted work                        -> the agent did not finish
    an unmerged branch                      -> nothing may ever sweep it (R3)
    a live agent                            -> its worktree is locked, and that
                                               is the platform saying so
    no ownership record and a session alive -> decidable the moment the last
                                               session ends (adoption T4)

The first is the one that matters most on this machine: on 2026-09-10 SEVEN
workspaces were held by one `com.apple.Virtualization.VirtualMachine` process
holding directory handles inside them. That is a true cause with an owner
outside this system, and reporting it as "undecidable" would have hidden the
one thing an operator could actually act on.
"""

import json
import os
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
ENGINE_ROOT = os.path.dirname(os.path.dirname(HERE))


def _load(name):
    import importlib.util
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), os.path.join(HERE, name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def known_repos():
    """Every repository this machine's record has ever named, plus whatever an
    operator declared. Read from the same list the reaper uses, the transaction
    store's own members, and the ownership ledger — never a filesystem scan for
    things that look like repositories."""
    repos = set()
    # RICHOS_KNOWN_REPOS redirects the list, the same way every other store in
    # this engine is redirected under test. Without it a hermetic suite would
    # survey the OPERATOR'S machine, which is both wrong and slow.
    listed = (os.environ.get('RICHOS_KNOWN_REPOS') or '').strip() or \
        os.path.join(os.path.expanduser('~'), '.claude', 'state', 'reap-known-repos.txt')
    try:
        with open(listed, encoding='utf-8') as stream:
            for line in stream:
                line = line.strip()
                if line and not line.startswith('#') and os.path.isdir(line):
                    repos.add(os.path.realpath(line))
    except OSError:
        pass
    tx = _load('worktree-transactions')
    for transaction in tx.iter_transactions():
        for member in transaction.get('members') or []:
            repo = member.get('repo')
            if repo and os.path.isdir(repo):
                repos.add(os.path.realpath(repo))
    ledger = _load('worktree-ledger')
    for row in ledger.read_all():
        repo = row.get('repo')
        if repo and os.path.isdir(repo):
            repos.add(os.path.realpath(repo))
    return sorted(repos)


def _git(repo, *args):
    return subprocess.run(['git', '-C', repo, *args], capture_output=True, text=True, timeout=60)


def _owner_index(tx):
    index = {}
    for transaction in tx.iter_transactions():
        for i, member in enumerate(transaction.get('members') or []):
            if member.get('path'):
                index[os.path.realpath(member['path'])] = (transaction, i)
    return index


def _hold_reason(tx, daily, transaction, index):
    try:
        decision, reason = daily.assess(tx, tx.load_tx(transaction['session_id'], transaction['agent_id']), index)
        return decision, reason
    except Exception as error:
        return 'hold', 'the reclaim lane could not judge it: %s' % error


def _adoption_verdict(path):
    """(adoptable, reason) from scripts/lib/worktree-adoption.py — the one
    place allowed to claim a workspace no record names. Its refusals already
    state the unmet precondition in words, which is what a report owes a
    reader."""
    try:
        adopt = _load('worktree-adoption')
        result = adopt.evaluate(path)
    except Exception as error:
        return False, 'the adoption claim could not be evaluated (%s); held' % error
    if result.get('adoptable'):
        return True, ('no ownership record names it, and adoption would claim it now: %s'
                      % (result.get('tier_detail') or result.get('reason') or 'evidence on record'))
    return False, ('no ownership record names it, and adoption refuses at gate %s: %s'
                   % (result.get('gate') or '?', result.get('reason') or '?'))


def _process_holders(daily, path):
    try:
        pids = daily.processes_using(path)
    except Exception:
        return []
    out = []
    for pid in pids:
        try:
            res = subprocess.run(['ps', '-o', 'comm=', '-p', str(pid)], capture_output=True, text=True, timeout=10)
            out.append('%s (%s)' % (pid, os.path.basename(res.stdout.strip()) or 'unknown'))
        except Exception:
            out.append(str(pid))
    return out


def survey():
    """[{path, repo, branch, disposition, kind, reason}] for every worktree of
    every known repository. Never raises for one repository's sake."""
    tx = _load('worktree-transactions')
    daily = _load('daily-workspace-cleanup')
    shapes = _load('workspace-shapes')
    proof = _load('completion-proof')
    owners = _owner_index(tx)
    rows = []

    for repo in known_repos():
        try:
            registry = proof.registry(repo)
        except Exception as error:
            rows.append({'path': repo, 'repo': repo, 'branch': '', 'kind': 'unclassified',
                         'disposition': 'OURS-HELD',
                         'reason': 'the worktree registry of %s could not be read (%s), so nothing '
                                   'under it could be classified' % (repo, error)})
            continue
        for path, row in sorted(registry.items()):
            if os.path.realpath(path) == os.path.realpath(repo):
                continue
            branch = (row.get('branch') or '').replace('refs/heads/', '')
            kind, why = shapes.classify(path, branch, repo)
            entry = {'path': path, 'repo': repo, 'branch': branch, 'kind': kind}
            if kind == 'codex':
                entry.update(disposition='EXCLUDED', reason=why)
                rows.append(entry)
                continue
            if kind == 'not-ours':
                entry.update(disposition='NOT-OURS', reason=why)
                rows.append(entry)
                continue
            owner = owners.get(os.path.realpath(path))
            if owner:
                decision, reason = _hold_reason(tx, daily, owner[0], owner[1])
                if decision in ('remove', 'branch-only'):
                    entry.update(disposition='OURS-READY',
                                 reason='%s; the next terminal event or the nightly pass takes it' % reason)
                else:
                    holders = _process_holders(daily, path)
                    if holders:
                        reason = ('an external process holds the tree open: %s. Nothing here kills a '
                                  'process; close it and this clears' % ', '.join(holders))
                    entry.update(disposition='OURS-HELD', reason=reason)
            else:
                # NO OWNERSHIP RECORD. The report does not guess what would
                # happen to it: it asks the sanctioned claim path, which
                # answers with its tier when it would take the workspace and
                # with the exact unmet precondition when it would not.
                verdict, why_adopt = _adoption_verdict(path)
                entry.update(disposition=('OURS-READY' if verdict else 'OURS-HELD'), reason=why_adopt)
            rows.append(entry)
    return rows


def counts(rows):
    out = {}
    for row in rows:
        out[row['disposition']] = out.get(row['disposition'], 0) + 1
    return out


def _main(argv):
    import argparse
    ap = argparse.ArgumentParser(prog='workspace-scope.py',
                                 description='Closed-world report over every worktree. Changes nothing.')
    ap.add_argument('--json', action='store_true')
    a = ap.parse_args(argv)
    rows = survey()
    if a.json:
        print(json.dumps({'rows': rows, 'counts': counts(rows)}, indent=1, sort_keys=True))
        return 0
    width = max([len(r['path']) for r in rows] + [20])
    for row in sorted(rows, key=lambda r: (r['disposition'], r['path'])):
        print('%-11s %-16s %-*s %s' % (row['disposition'], row['kind'], width, row['path'], row['reason']))
    total = len(rows)
    summary = counts(rows)
    print('')
    print('=== %d worktree(s) across %d repositories, every one decided: %s ==='
          % (total, len(known_repos()),
             ', '.join('%s=%d' % (k, v) for k, v in sorted(summary.items())) or 'none'))
    return 0


if __name__ == '__main__':
    import sys
    sys.exit(_main(sys.argv[1:]))
