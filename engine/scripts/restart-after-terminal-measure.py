#!/usr/bin/env python3
"""DOES A TERMINAL AGENT RUN AGAIN? The falsifier of the agent-sized ground,
as a standing measurement instead of a sentence in a document.

WHY THIS SCRIPT EXISTS. Round 11 (2026-09-10) authorized deleting a workspace
in the terminal event on the ground that the platform's first `SubagentStop`
for an agent id meant the agent "cannot be given another turn -- structural
rather than temporal", and its section 7 named the fact that would prove it
wrong: "a terminal record written for an agent that then runs again". Two
independent reviewers and the lead each measured that fact the same day and
each got a different count (6, 7 and 7) from three different joins. All three
were right about the cluster and none of them could be re-run by the next
reader. This is the join, committed, with its corpus and its denominator
printed beside its numerator.

THE KEY IS THE REGISTRATION ID, NEVER THE PER-RUN PAYLOAD ID. The measurement
round 11 offered as proof ("1,153 WorkerRunEnded rows across 1,149 distinct
agent ids, 1,147 with exactly one") counts the id in the SubagentStop payload,
which `worktree-ledger.resolve_assignment` documents as a PER-RUN identifier.
Measured on this machine 2026-09-10 by `--census`: 1,765 run-end rows carry
1,756 distinct payload ids, and only 27 of those ids are an id this engine
ever registered a workspace to. A count of per-run ids shows one row per id by
construction; it measures the platform's id scheme and can never see a
restart.

TWO SOURCES, BOTH REPORTED, BECAUSE THEY DISAGREE AND THE DISAGREEMENT IS
INFORMATION:

  starts/   the transaction store's own start fact
            (<root>/<session>/starts/<agent_id>.json, written by
            record-subagent-start.sh). It is REWRITTEN in place on every
            start, so its `ts` is the LATEST start and it cannot count
            repeats -- but it exists for every session, including those
            predating the team event log.
  events    ~/.claude/teams/session-*/worker-events.jsonl `WorkerStarted`
            rows, which keep every start, and exist only for sessions since
            the start hook shipped.

No time window is applied. A start strictly after the terminal record is a
restart; the gap is reported so the reader can judge it rather than have an
arbitrary threshold judge it for them. (A two-second window is why one
independent run of this join reported 6 where another reported 7: it drops
`zach-opus-auto1` at +1.3s.)

USAGE
    python3 restart-after-terminal-measure.py            # the join
    python3 restart-after-terminal-measure.py --census   # the event vocabulary
    python3 restart-after-terminal-measure.py --json     # machine-readable

    RICHOS_WORKTREE_TX_DIR   transaction store (default ~/.claude/state/worktree-transactions)
    RICHOS_TEAMS_DIR         team event logs   (default ~/.claude/teams)

EXIT STATUS. 0 always. This is a measurement, not a gate: it reports what the
record holds and the reader decides. A number that cannot be re-derived from
its own command does not ship (CLAUDE.md, 2026-09-05).
"""
import collections
import datetime
import glob
import json
import os
import sys

TX_ROOT = os.environ.get('RICHOS_WORKTREE_TX_DIR') or os.path.expanduser(
    '~/.claude/state/worktree-transactions')
TEAMS_DIR = os.environ.get('RICHOS_TEAMS_DIR') or os.path.expanduser('~/.claude/teams')
RESERVED = ('terminal', 'terminal-names')


def parse_ts(value):
    try:
        return datetime.datetime.fromisoformat(str(value or '').replace('Z', '+00:00'))
    except (TypeError, ValueError):
        return None


def read_json(path):
    try:
        with open(path, encoding='utf-8') as stream:
            return json.load(stream)
    except (OSError, ValueError):
        return None


def event_rows():
    """Every row of every team event log, oldest first per file."""
    for path in sorted(glob.glob(os.path.join(TEAMS_DIR, 'session-*', 'worker-events.jsonl'))):
        try:
            with open(path, encoding='utf-8') as stream:
                for line in stream:
                    if not line.strip():
                        continue
                    try:
                        yield path, json.loads(line)
                    except ValueError:
                        continue
        except OSError:
            continue


def terminal_transactions():
    """Every SEALED transaction carrying a terminal record, adopted excluded.

    The corpus definition, stated so it can be argued with: an adopted
    transaction has no owning session and its terminal fact is this engine's
    own derivation from T1/T2 evidence, not a platform event about a worker,
    so a "restart" of it is not a thing the platform could report.
    """
    out = []
    try:
        sessions = sorted(os.listdir(TX_ROOT))
    except OSError:
        return out
    for session in sessions:
        if session in RESERVED:
            continue
        session_dir = os.path.join(TX_ROOT, session)
        if not os.path.isdir(session_dir):
            continue
        for path in sorted(glob.glob(os.path.join(session_dir, '*.json'))):
            record = read_json(path)
            if not isinstance(record, dict) or record.get('record') != 'transaction':
                continue
            if not record.get('sealed') or not isinstance(record.get('terminal'), dict):
                continue
            if record.get('kind') == 'adopted':
                continue
            out.append(record)
    return out


def start_fact(session_id, agent_id):
    return read_json(os.path.join(TX_ROOT, session_id, 'starts', agent_id + '.json'))


def owns_a_workspace(transaction):
    for member in transaction.get('members') or []:
        if isinstance(member, dict) and member.get('path'):
            return True
    return False


def census():
    """The platform's whole event vocabulary, per session. Answers a question
    that keeps being answered by inference: is there an event that means THIS
    WORKER IS FINISHED? On this machine there is not -- the vocabulary is
    WorkerStarted / WorkerRunEnded / WorkerUpdated, and `run_ended` means the
    RUN ended (worker-ended-handoff.sh says so in its own header)."""
    per_file = collections.OrderedDict()
    for path, row in event_rows():
        name = os.path.basename(os.path.dirname(path))
        bucket = per_file.setdefault(name, {'events': collections.Counter(),
                                            'ids': collections.defaultdict(set)})
        event = str(row.get('event') or '?')
        bucket['events'][event] += 1
        if row.get('agent_id'):
            bucket['ids'][event].add(row['agent_id'])
    registered = set()
    for transaction in terminal_transactions():
        registered.add(transaction.get('agent_id'))
    print('EVENT VOCABULARY (corpus: every worker-events.jsonl under %s)' % TEAMS_DIR)
    for name, bucket in per_file.items():
        print('  %s' % name)
        for event, count in sorted(bucket['events'].items()):
            ids = bucket['ids'].get(event, set())
            known = len(ids & registered)
            print('    %-16s rows=%-6d distinct payload ids=%-6d of which registration ids=%d'
                  % (event, count, len(ids), known))
    print('')
    print('READ THIS BEFORE DIVIDING ONE OF THESE NUMBERS BY ANOTHER: rows and')
    print('distinct payload ids are the SAME population counted twice for helper')
    print('subagents, because the payload id is minted per run. "rows / number of')
    print('agents" is not "endings per agent"; it is a ratio between two different')
    print('id spaces. The only honest per-agent count is the registration-id column.')
    return 0


def measure(as_json=False):
    starts_by_id = collections.defaultdict(list)
    for _path, row in event_rows():
        if row.get('event') != 'WorkerStarted':
            continue
        when = parse_ts(row.get('timestamp'))
        if row.get('agent_id') and when:
            starts_by_id[row['agent_id']].append(when)

    corpus = terminal_transactions()
    workspace_owning = [t for t in corpus if owns_a_workspace(t)]
    findings = []
    for transaction in workspace_owning:
        terminal_ts = parse_ts((transaction.get('terminal') or {}).get('ts'))
        if terminal_ts is None:
            continue
        agent_id = transaction.get('agent_id') or ''
        session_id = transaction.get('session_id') or ''
        later_events = sorted(s for s in starts_by_id.get(agent_id, []) if s > terminal_ts)
        fact = start_fact(session_id, agent_id) or {}
        fact_ts = parse_ts(fact.get('ts'))
        later_fact = fact_ts if (fact_ts and fact_ts > terminal_ts) else None
        if not later_events and not later_fact:
            continue
        gaps = [(s - terminal_ts).total_seconds() for s in later_events]
        if later_fact:
            gaps.append((later_fact - terminal_ts).total_seconds())
        findings.append({
            'session': session_id[:8], 'teammate': transaction.get('teammate') or '?',
            'agent_id': agent_id, 'ingress': (transaction.get('terminal') or {}).get('ingress'),
            'terminal_ts': (transaction.get('terminal') or {}).get('ts'),
            'restarts_in_events': len(later_events),
            'restart_in_start_fact': bool(later_fact),
            'first_gap_s': round(min(gaps), 3), 'last_gap_s': round(max(gaps), 3),
        })
    findings.sort(key=lambda f: f['terminal_ts'] or '')

    result = {
        'corpus': 'sealed non-adopted transactions with a terminal record, in %s' % TX_ROOT,
        'terminal_transactions': len(corpus),
        'of_which_own_a_workspace': len(workspace_owning),
        'denominator': len(workspace_owning),
        'restarted_after_terminal': len(findings),
        'rate': (round(100.0 * len(findings) / len(workspace_owning), 3)
                 if workspace_owning else None),
        'event_logs_scanned': len(glob.glob(os.path.join(TEAMS_DIR, 'session-*', 'worker-events.jsonl'))),
        'findings': findings,
    }
    if as_json:
        print(json.dumps(result, indent=2))
        return 0
    print('RESTART AFTER TERMINAL -- the round-11 falsifier, re-derived')
    print('  corpus     : %s' % result['corpus'])
    print('  terminal transactions (sealed, non-adopted) : %d' % result['terminal_transactions'])
    print('  DENOMINATOR: those that own at least one workspace : %d' % result['denominator'])
    print('  NUMERATOR  : those with a start strictly after their terminal record : %d'
          % result['restarted_after_terminal'])
    print('  rate       : %s%%' % result['rate'])
    print('  event logs scanned (a session without one contributes only its start fact) : %d'
          % result['event_logs_scanned'])
    print('')
    if not findings:
        print('  no restart after a terminal record in this corpus.')
        print('  THIS IS NOT A PROOF THAT ONE CANNOT HAPPEN. It is the absence of one here,')
        print('  and absence of a record is never evidence (the rule this engine was built on).')
        return 0
    print('  %-16s %-18s %-24s %6s %6s %10s %10s' % (
        'teammate', 'agent', 'terminal_ts', 'events', 'fact', 'first_gap', 'last_gap'))
    for f in findings:
        print('  %-16s %-18s %-24s %6d %6s %10.1fs %10.1fs' % (
            f['teammate'][:16], f['agent_id'][:18], (f['terminal_ts'] or '')[:23],
            f['restarts_in_events'], 'yes' if f['restart_in_start_fact'] else 'no',
            f['first_gap_s'], f['last_gap_s']))
    print('')
    print('  Every row here is an agent this engine recorded as terminal and the platform')
    print('  then ran again. `events` counts WorkerStarted rows; `fact` is the start record')
    print('  in the transaction store, which is rewritten in place and so shows only that a')
    print('  later start happened, never how many.')
    return 0


def main(argv):
    if '--census' in argv:
        return census()
    return measure('--json' in argv)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
