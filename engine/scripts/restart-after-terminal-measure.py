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
            the start hook shipped -- AND ONLY WHILE THE SESSION'S TEAM
            DIRECTORY EXISTS. The platform deletes that directory at session
            end (Sage D3 / Frank F1, round three, 2026-09-10: session
            d0eef867's log, read by both round-two reviewers, was gone within
            an hour of the session ending), so this source is per-session and
            ephemeral. A session with no team directory writes to the
            FALLBACK file ~/.claude/worker-events.jsonl instead, keyed by the
            full session id, and that file is read here too (round 14): on
            the operator's machine 31 of 49 store sessions have rows only
            there. Every count that leans on `events` is therefore a claim
            with a date on it; the start fact is the durable one.

No time window is applied. A start strictly after the terminal record is a
restart; the gap is reported so the reader can judge it rather than have an
arbitrary threshold judge it for them. (A two-second window is why one
independent run of this join reported 6 where another reported 7: it drops
`zach-opus-auto1` at +1.3s.)

THE LOCK AGAINST THE START (`--locks`, round 13, 2026-09-10). Round 12 wrote
that the platform "re-locks the worktree BEFORE the run starts", measured as
the lock file's mtime 43 ms and 49 ms ahead of the SubagentStart hook on two
agents -- and both reviewers found the two samples were INITIAL starts, never a
restart. This mode joins every native admin directory still on disk to every
WorkerStarted for its agent, classifies each start as initial or restart, and
reports separately: (a) initial starts whose lock precedes the start, (b)
restarts with a lock file on disk whose lock mtime moved AFTER the restart --
a re-lock actually observed -- and (c) restarts into a tree the reaper had
witnessed UNLOCKED, whose admin directory is gone and whose re-lock is
therefore unobservable. (b) is the number the round-12 sentence needed and did
not have; when this mode was written it was 0 of 3 on this machine (fix1's
two restarts and sage-fable-cert2's one, each with the lock held throughout --
never released, never re-taken) and (c) was 4 (q1, inf1, gate1, own1 at
14:34:37Z). UNMEASURED is reported as unmeasured; re-run rather than quote.

USAGE
    python3 restart-after-terminal-measure.py            # the join
    python3 restart-after-terminal-measure.py --census   # the event vocabulary
    python3 restart-after-terminal-measure.py --locks    # the lock against the start
    python3 restart-after-terminal-measure.py --json     # machine-readable

    RICHOS_WORKTREE_TX_DIR   transaction store (default ~/.claude/state/worktree-transactions)
    RICHOS_TEAMS_DIR         team event logs   (default ~/.claude/teams)
    RICHOS_WORKTREE_LEDGER   ownership ledger  (default ~/.claude/state/worktree-ledger.jsonl)

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
LEDGER = os.environ.get('RICHOS_WORKTREE_LEDGER') or os.path.expanduser('~/.claude/state/worktree-ledger.jsonl')
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


FALLBACK_LOG = os.path.join(os.path.dirname(os.path.abspath(TEAMS_DIR)), 'worker-events.jsonl')


def event_log_paths():
    """Every per-session log still on disk, then the fallback file (the
    sibling of the teams directory, where a session with no team directory
    writes). Both are the platform's; only the fallback outlives a session."""
    paths = sorted(glob.glob(os.path.join(TEAMS_DIR, 'session-*', 'worker-events.jsonl')))
    if os.path.isfile(FALLBACK_LOG):
        paths.append(FALLBACK_LOG)
    return paths


def event_rows():
    """Every row of every event log the platform keeps, oldest first per file."""
    for path in event_log_paths():
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


def log_label(path):
    return 'fallback (%s)' % FALLBACK_LOG if path == FALLBACK_LOG else os.path.basename(os.path.dirname(path))


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
        name = log_label(path)
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
        'event_logs_scanned': len(event_log_paths()),
        'fallback_log_read': os.path.isfile(FALLBACK_LOG),
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
    print('  event logs scanned (per-session logs still on disk, plus the fallback file if present) : %d%s'
          % (result['event_logs_scanned'], '' if result['fallback_log_read'] else ' (no fallback file)'))
    print('  a session whose log the platform has deleted contributes only its start fact')
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


def all_transactions():
    """Every sealed transaction, terminal or not: the lock join wants every
    native admin directory the engine ever knew about."""
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
            if isinstance(record, dict) and record.get('record') == 'transaction' and record.get('sealed'):
                out.append(record)
    return out


def unlocked_witness_rows():
    """{agent_id: ts} for every ownership-ledger row in which the reaper
    WITNESSED a native isolation worktree registered and unlocked."""
    out = {}
    try:
        with open(LEDGER, encoding='utf-8') as stream:
            for line in stream:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(row, dict) or row.get('event') != 'terminated':
                    continue
                text = ' '.join(str(row.get(k) or '') for k in ('reason', 'detail', 'evidence'))
                if 'registered and unlocked' not in text:
                    continue
                when = parse_ts(row.get('ts'))
                aid = row.get('agent_id') or ''
                if aid and when and (aid not in out or when < out[aid]):
                    out[aid] = when
    except OSError:
        pass
    return out


def locks(as_json=False):
    starts_by_id = collections.defaultdict(list)
    for _path, row in event_rows():
        if row.get('event') == 'WorkerStarted' and row.get('agent_id'):
            when = parse_ts(row.get('timestamp'))
            if when:
                starts_by_id[row['agent_id']].append(when)
    rows = []
    seen = set()
    for transaction in all_transactions():
        aid = transaction.get('agent_id') or ''
        for member in transaction.get('members') or []:
            if not isinstance(member, dict) or member.get('class') != 'native':
                continue
            repo, path = member.get('repo') or '', member.get('path') or ''
            if not repo or not path or (aid, path) in seen:
                continue
            seen.add((aid, path))
            admin = os.path.join(repo, '.git', 'worktrees', os.path.basename(path))
            lock = os.path.join(admin, 'locked')
            admin_present = os.path.isdir(admin)
            lock_mtime = None
            if admin_present and os.path.lexists(lock):
                lock_mtime = datetime.datetime.fromtimestamp(os.stat(lock).st_mtime, datetime.timezone.utc)
            starts = sorted(starts_by_id.get(aid, []))
            for index, start in enumerate(starts):
                kind = 'initial' if index == 0 else 'restart'
                delta_ms = round((lock_mtime - start).total_seconds() * 1000, 1) if lock_mtime else None
                rows.append({'teammate': transaction.get('teammate') or '?', 'agent_id': aid, 'kind': kind,
                             'start_ts': start.isoformat(), 'admin_dir_present': admin_present,
                             'lock_present': lock_mtime is not None,
                             'lock_mtime': lock_mtime.isoformat() if lock_mtime else None,
                             'lock_minus_start_ms': delta_ms})
    witnessed = unlocked_witness_rows()
    session_of = {}
    for transaction in all_transactions():
        aid = transaction.get('agent_id') or ''
        if aid and aid not in session_of:
            session_of[aid] = transaction.get('session_id') or ''
    unlocked_restarts = []
    for aid, when in sorted(witnessed.items(), key=lambda kv: kv[1]):
        later = sorted(s for s in starts_by_id.get(aid, []) if s > when)
        source = 'events'
        sid = session_of.get(aid, '')
        if not later and sid:
            # THE EVENT LOG MAY BE GONE (Sage D3 / Frank F1, round three): the
            # platform deletes a session's log with its team directory, and
            # the four witnessed-unlocked restarts this mode was written on
            # dropped out of (c) with no line saying so once that happened.
            # The ledger witness is durable and so is the start fact; a start
            # fact later than the witness IS the restart, and it is reported
            # as known from that source rather than silently omitted.
            fact_ts = parse_ts((start_fact(sid, aid) or {}).get('ts'))
            if fact_ts and fact_ts > when:
                later, source = [fact_ts], 'start-fact'
        if not later:
            continue
        log_present = bool(sid) and os.path.isfile(os.path.join(TEAMS_DIR, 'session-%s' % sid[:8], 'worker-events.jsonl'))
        admin_present = any(r['agent_id'] == aid and r['admin_dir_present'] for r in rows)
        unlocked_restarts.append({'agent_id': aid, 'witnessed_unlocked_ts': when.isoformat(),
                                  'restart_ts': later[0].isoformat(),
                                  'gap_s': round((later[0] - when).total_seconds(), 1),
                                  'admin_dir_present': admin_present,
                                  'restart_source': source,
                                  'session_event_log_present': log_present})
    initial = [r for r in rows if r['kind'] == 'initial' and r['lock_present']]
    initial_before = [r for r in initial if r['lock_minus_start_ms'] < 0]
    restarts = [r for r in rows if r['kind'] == 'restart' and r['lock_present']]
    retaken = [r for r in restarts if r['lock_minus_start_ms'] > 0]
    result = {
        'corpus': 'native members of sealed transactions in %s whose admin directory is still on disk, '
                  'joined to WorkerStarted rows under %s; unlocked witnesses from %s' % (TX_ROOT, TEAMS_DIR, LEDGER),
        'initial_starts_with_lock_on_disk': len(initial),
        'initial_starts_lock_precedes_start': len(initial_before),
        'restarts_with_lock_on_disk': len(restarts),
        'restarts_lock_retaken_after_restart': len(retaken),
        'restarts_into_witnessed_unlocked_tree': len(unlocked_restarts),
        'restarts_into_witnessed_unlocked_tree_with_admin_dir': sum(1 for r in unlocked_restarts if r['admin_dir_present']),
        'restarts_into_witnessed_unlocked_tree_known_only_from_start_fact': sum(1 for r in unlocked_restarts if r['restart_source'] == 'start-fact'),
        'corpus_lifetime': ('per-session event logs are deleted by the platform with the session\'s team directory; '
                            '(a) and (b) can only be re-derived while a log exists, (c) falls back to the ledger '
                            'witness and the start fact'),
        'rows': rows, 'unlocked_restarts': unlocked_restarts,
    }
    if as_json:
        print(json.dumps(result, indent=2))
        return 0
    print('THE LOCK AGAINST THE START -- is "the platform re-locks before a restarted run" measured?')
    print('  corpus: %s' % result['corpus'])
    print('')
    print('  %-16s %-18s %-8s %-27s %-6s %-27s %s' % ('teammate', 'agent', 'kind', 'start_ts', 'lock', 'lock_mtime', 'lock-start'))
    for r in rows:
        print('  %-16s %-18s %-8s %-27s %-6s %-27s %s' % (
            r['teammate'][:16], r['agent_id'][:18], r['kind'], r['start_ts'][:27],
            'yes' if r['lock_present'] else ('gone' if not r['admin_dir_present'] else 'no'),
            (r['lock_mtime'] or '-')[:27],
            ('%+.1f ms' % r['lock_minus_start_ms']) if r['lock_minus_start_ms'] is not None else '-'))
    print('')
    print('  (a) initial starts with a lock file on disk : %d; lock PRECEDES the start in %d of them'
          % (result['initial_starts_with_lock_on_disk'], result['initial_starts_lock_precedes_start']))
    print('  (b) restarts with a lock file on disk       : %d; lock mtime moved AFTER the restart (a re-lock OBSERVED) in %d of them'
          % (result['restarts_with_lock_on_disk'], result['restarts_lock_retaken_after_restart']))
    print('  (c) restarts into a tree the reaper witnessed UNLOCKED : %d; admin directory still on disk for %d of them; '
          'known only from the start fact (event log gone) for %d of them'
          % (result['restarts_into_witnessed_unlocked_tree'], result['restarts_into_witnessed_unlocked_tree_with_admin_dir'],
             result['restarts_into_witnessed_unlocked_tree_known_only_from_start_fact']))
    for r in unlocked_restarts:
        print('      %-18s witnessed unlocked %s  restarted %s  (+%.0f s)  admin dir %s; restart from %s%s'
              % (r['agent_id'][:18], r['witnessed_unlocked_ts'][:19], r['restart_ts'][:19], r['gap_s'],
                 'present' if r['admin_dir_present'] else 'GONE -- re-lock unobservable',
                 r['restart_source'],
                 '' if r['session_event_log_present'] else ' -- session event log GONE (the platform deleted it with the session), unobservable from the log'))
    print('')
    print('  READ (b) AND (c) BEFORE QUOTING (a). (a) is what round 12 measured and it holds; it')
    print('  says the platform locks before an INITIAL run. Whether the platform re-takes a RELEASED')
    print('  lock for a RESTARTED run is answered only by (b) on a tree whose lock was absent before')
    print('  the restart, and by (c) if an admin directory survives. A lock held throughout a restart')
    print('  (fix1, twice) is not a re-lock. Until (b) has a sample, "re-locks on restart" is UNMEASURED.')
    print('')
    print('  CORPUS LIFETIME: %s. Every (a)/(b) number is a claim with the date of the run on it.' % result['corpus_lifetime'])
    return 0


def main(argv):
    if '--census' in argv:
        return census()
    if '--locks' in argv:
        return locks('--json' in argv)
    return measure('--json' in argv)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
