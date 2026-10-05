#!/usr/bin/env python3
"""Read-only episode accounting, seeded from the fixed-interval episode counter.

Prints numeric aggregates and locators, never transcript content. No subprocesses,
network, transcript writes or persistent state. Signature matches are candidates,
not causal attribution. Verification source equality needs separate source receipts.
Codex exec wrappers are recognized only when their command is a literal string.
"""
import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import shlex
import time

KEYS = ('input_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens', 'output_tokens')
UI = {'ax.sh', 'shot.sh', 'ocr-find.sh', 'ocr-gate.sh', 'ocr-read.py', 'ocr-watch.sh'}
VERIFY = {'proof-run.py', 'run-tests.sh', 'ci-shard.sh'}
POLL = {'cat', 'tail', 'stat', 'ps', 'pgrep', 'wc', 'test'}
COLLECT = re.compile(r'\s*(?:python3\s+)?\S*agent_hold\.py\s+wait(?:\s+--max-seconds\s+\d+(?:\.\d+)?)?(?:\s+2>&1)?\s*\Z')
RECEIPT = re.compile(r'TASK\s+(\S+)\s+\(tool\s+(\S+)\)\s+EXIT STATUS\s+(-?\d+)')


def stamp(value):
    parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
    return parsed.replace(tzinfo=parsed.tzinfo or timezone.utc).timestamp()


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def signatures(command):
    # Only executable positions, not grep arguments or quoted source snippets.
    try:
        parts = shlex.shlex(command.replace('\n', ' ; '), posix=True, punctuation_chars=';&|()')
        parts.whitespace_split = True
        parts.commenters = '#'
        tokens = list(parts)
    except ValueError:
        return set()
    found, executable, current, arguments = set(), True, None, []
    def finish():
        if current and not any(x in ('--help', '-h') for x in arguments):
            found.add(current)
    for token in tokens:
        if token in (';', '&&', '||', '|', '&', '('):
            finish()
            current, arguments = None, []
            executable = True
        elif executable:
            name = Path(token).name
            if '=' in token and re.match(r'^[A-Za-z_][A-Za-z_0-9]*=', token):
                continue
            if name in ('env', 'bash', 'sh', 'python', 'python3', 'nice', 'command') or token.startswith('-'):
                continue
            current = name
            executable = False
        else:
            arguments.append(token)
    finish()
    return found


def command_text(name, args):
    if isinstance(args, dict):
        return args.get('command', args.get('cmd', ''))
    if name.endswith('exec') and isinstance(args, str):
        # Decode a literal argument only. Never evaluate JavaScript or shell code.
        matches = re.findall(r'(?:"cmd"|\bcmd)\s*:\s*("(?:\\.|[^"\\])*")', args)
        return '\n'.join(json.loads(x) for x in matches)
    return ''


def output_text(value):
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return '\n'.join(b.get('text', '') for b in value if isinstance(b, dict) and b.get('type') == 'text')
    return json.dumps(value, sort_keys=True)


def read_log(path, provider, start, end, diagnostics):
    calls, usage, seen = {}, {}, set()
    size = path.stat().st_size  # A live file has a fixed snapshot boundary.
    with path.open('rb') as stream:
        for line_number, line in enumerate(stream, 1):
            if stream.tell() > size:
                diagnostics['partial_or_appended_lines'] += 1
                break
            try:
                rec = json.loads(line)
                when = stamp(rec['timestamp'])
            except (ValueError, KeyError, TypeError):
                diagnostics['unparsed_records'] += 1
                continue
            if not start <= when < end:
                continue
            msg = rec.get('message') or {}
            blocks = []
            if provider == 'claude':
                if rec.get('type') == 'assistant' and msg.get('id'):
                    if msg.get('usage'):
                        usage[msg['id']] = (when, line_number, msg['usage'])
                blocks = msg.get('content', [])
                blocks = blocks if isinstance(blocks, list) else []
            else:
                pay = rec.get('payload') or {}
                if rec.get('type') == 'token_usage_record' and pay.get('response_id'):
                    u = pay.get('usage') or {}
                    # Codex input includes cached input. Keep provider semantics explicit.
                    normalized = {'input_tokens': u.get('input_tokens'),
                                  'cache_read_input_tokens': u.get('cached_input_tokens'),
                                  'cache_creation_input_tokens': u.get('cache_write_input_tokens'),
                                  'output_tokens': u.get('output_tokens')}
                    usage[pay['response_id']] = (when, line_number, normalized)
                if rec.get('type') == 'response_item':
                    kind = pay.get('type', '')
                    if kind in ('function_call', 'custom_tool_call'):
                        args = pay.get('arguments', pay.get('input', ''))
                        if kind == 'function_call':
                            try:
                                args = json.loads(args)
                            except (TypeError, ValueError):
                                diagnostics['unparsed_arguments'] += 1
                        blocks = [{'type': 'tool_use', 'id': pay.get('call_id'),
                                   'name': pay.get('name', ''), 'input': args}]
                    elif kind in ('function_call_output', 'custom_tool_call_output'):
                        blocks = [{'type': 'tool_result', 'tool_use_id': pay.get('call_id'),
                                   'content': pay.get('output', '')}]
            for b in blocks:
                if not isinstance(b, dict):
                    continue
                if b.get('type') == 'tool_use' and b.get('id'):
                    key = b['id']
                    if key in seen:
                        diagnostics['duplicate_call_records'] += 1
                        continue
                    seen.add(key)
                    name = b.get('name', '')
                    cmd = command_text(name, b.get('input', {}))
                    sig = signatures(cmd) if name in ('Bash', 'exec_command', 'exec', 'functions.exec', 'functions.exec_command') else set()
                    collector = name == 'TaskOutput' or name == 'Bash' and bool(COLLECT.fullmatch(cmd))
                    family = 'ui' if sig & UI else 'verification' if sig & VERIFY else 'scripted_ui' if any(n.endswith(('-walk.py', '-walk.sh')) for n in sig) else None
                    if not family and (name in ('TaskOutput', 'write_stdin', 'functions.write_stdin') or sig & POLL):
                        family = 'observation'
                    calls[key] = {'line': line_number, 'start': when, 'end': None, 'tool_end': None,
                                  'collector': collector, 'background': False,
                                  'response': msg.get('id'), 'name': name, 'family': family,
                                  'signature': digest(cmd or json.dumps(b.get('input'), sort_keys=True)),
                                  'output_hash': None, 'canary_mention': False, 'canary_only_claim': False,
                                  'failure': False}
                elif b.get('type') == 'tool_result' and b.get('tool_use_id') in calls:
                    call = calls[b['tool_use_id']]
                    out = output_text(b.get('content', ''))
                    if call['tool_end'] is None:
                        call['tool_end'] = when
                        if 'Command running in background with ID:' in out:
                            call.update(background=True, handoff_line=line_number)
                        else:
                            result(call, out, when, line_number, bool(b.get('is_error')))
                    # Only the trusted collector boundary may complete another task.
                    # A source snippet mentioning TASK must not forge a receipt.
                    if call['collector']:
                        receipts = list(RECEIPT.finditer(out))
                        for i, match in enumerate(receipts):
                            target = calls.get(match[2])
                            if not target or not target['background'] or target['end'] is not None:
                                diagnostics['unlinked_or_duplicate_receipts'] += 1
                                continue
                            stop = receipts[i+1].start() if i+1 < len(receipts) else len(out)
                            result(target, out[match.end():stop], when, line_number, int(match[3]) != 0)
                            target['receipt_exit'] = int(match[3])
                            target['failure'] = int(match[3]) != 0
                            diagnostics['linked_background_receipts'] += 1
    return sorted(calls.values(), key=lambda c: c['line']), usage


def result(call, out, when, line, failure=False):
    call.update(end=when, end_line=line, output_hash=digest(out))
    call['canary_mention'] = bool(re.search(r'record[- ]canary', out, re.I))
    call['canary_only_claim'] = bool(re.search(r'(?:only[^\n]{0,70}record[- ]canary|record[- ]canary[^\n]{0,70}only)', out, re.I))
    call['failure'] = bool(failure or re.search(r'(?:Exit code [1-9]|exit(?:ed)?[ :=]+[1-9]|deadline exceeded|AX timeout)', out, re.I))


def union_seconds(intervals):
    total, stop = 0.0, float('-inf')
    for a, b in sorted(intervals):
        total += max(0, b - max(a, stop))
        stop = max(stop, b)
    return total


def summarize(calls, usage, provider, task, family, all_calls=None):
    first, last = min(c['line'] for c in calls), max(c.get('end_line', c['line']) for c in calls)
    response_ids = {c['response'] for c in calls if c['response']}
    selected = {k: u for k, (t, n, u) in usage.items() if first <= n <= last or k in response_ids}
    span_calls = [c for c in (all_calls or calls) if first <= c['line'] <= last]
    complete = [c for c in span_calls if c['tool_end'] is not None and c['tool_end'] >= c['start']]
    intervals = [(c['start'], c['tool_end']) for c in complete]
    background = [c for c in span_calls if c['background']]
    ends = [c['tool_end'] for c in complete] + [c['end'] for c in calls if c['end'] is not None]
    elapsed = max(ends, default=calls[0]['start']) - calls[0]['start']
    tool_time = union_seconds(intervals)
    row = {'provider': provider, 'task': task, 'first_line': first, 'last_line': last,
           'date': datetime.fromtimestamp(calls[0]['start'], timezone.utc).date().isoformat(),
           'family': family, 'tool_calls': len(calls), 'span_tool_calls': len(span_calls), 'tool_names': dict(Counter(c['name'] for c in calls)),
           'model_requests': len(selected) if selected else None,
           'usage_missing_fields': {k: sum(u.get(k) is None for u in selected.values()) for k in KEYS},
           'usage': {k: sum(u[k] for u in selected.values() if u.get(k) is not None) if selected and any(u.get(k) is not None for u in selected.values()) else None for k in KEYS},
           'tool_seconds': round(tool_time, 3), 'non_tool_gap_seconds': round(max(0, elapsed-tool_time), 3),
           'elapsed_seconds': round(max(0, elapsed), 3), 'unmatched_calls': len(span_calls)-len(complete),
           'collector_calls': sum(c['collector'] for c in span_calls),
           'background_calls': len(background),
           'unresolved_background_calls': sum(c['end'] is None for c in background),
           'background_collection_upper_bound_seconds': round(union_seconds([(c['start'], c['end']) for c in background if c['end'] is not None]), 3),
           'canary_mentions': sum(c['canary_mention'] for c in span_calls),
           'canary_only_claims': sum(c['canary_only_claim'] for c in span_calls),
           'failed_calls': sum(c['failure'] for c in calls)}
    if family == 'verification':
        row['source_identity'] = 'unknown: compare full source receipts before attributing retries'
        row['eligible_unchanged_source'] = False
    return row


def episodes(calls):
    # Consecutive means consecutive tool calls, including intervening image reads.
    # Verification is a candidate group within one task, never claimed unchanged.
    logical = [c for c in calls if not c['collector']]
    for family, minimum in [('ui', 3), ('observation', 3), ('verification', 2), ('scripted_ui', 1)]:
        group = []
        sequence = [c for c in logical if c['family'] == family] if family in ('verification', 'scripted_ui') else logical
        for call in sequence + [None]:
            hit = call is not None and call['family'] == family
            same = bool(hit and (not group or call['start'] - group[-1]['start'] <= 1800))
            if family == 'observation' and group and hit:
                same = same and call['output_hash'] is not None and call['signature'] == group[-1]['signature'] and call['output_hash'] == group[-1]['output_hash']
            if group and (not same or (not hit and family != 'verification')):
                if len(group) >= minimum:
                    yield family, group
                group = []
            if hit:
                group.append(call)
            elif call is None and len(group) >= minimum:
                yield family, group
                group = []


def walk_evidence(path):
    """Only explicitly supplied machine records. Never print their output or text."""
    source = path.read_bytes()
    value = json.loads(source)
    rows = value.get('calls') if isinstance(value, dict) else value
    if not isinstance(rows, list) or not rows:
        raise ValueError('expected nonempty calls or step records')
    counts, elapsed, missing, failures = Counter(), 0.0, 0, 0
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError('record must be an object')
        if 'argv' in row:
            argv = row['argv']
            if not isinstance(argv, list) or not all(isinstance(x, str) for x in argv):
                raise ValueError('argv must contain strings')
            names = {Path(x).name for x in argv[:1]}
            kind = 'ui' if names & UI else 'other'
        elif isinstance(row.get('step'), dict):
            kind = 'ui' if row['step'].get('op') in ('ax', 'tree', 'shot') else 'other'
        else:
            raise ValueError('expected argv or step')
        counts[kind] += 1
        seconds = row.get('seconds')
        if isinstance(seconds, (float, int)) and not isinstance(seconds, bool) and 0 <= seconds < float('inf'):
            elapsed += seconds
        else:
            missing += 1
        if isinstance(row.get('exit'), int) and row['exit'] != 0:
            failures += 1
    return {'file': path.name, 'sha256': hashlib.sha256(source).hexdigest(),
            'calls': dict(counts), 'recorded_call_seconds': round(elapsed, 3),
            'missing_durations': missing, 'failed_calls': failures,
            'model_requests': None, 'usage': None,
            'source_identity': 'unknown: validate product and harness identities separately'}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--claude-root', type=Path)
    p.add_argument('--codex-root', type=Path)
    p.add_argument('--since', required=True, help='inclusive UTC date or timestamp')
    p.add_argument('--until', required=True, help='exclusive UTC date or timestamp')
    p.add_argument('--reference', nargs=3, metavar=('FILE', 'FIRST', 'LAST'))
    p.add_argument('--walk-evidence', action='append', type=Path, default=[],
                   help='explicit steps.json or screen.json; numeric inner-call accounting only')
    p.add_argument('--duty-cycle', type=float, default=0.2, help='fraction of a core, approximate per-file pacing')
    a = p.parse_args()
    start, end = stamp(a.since), stamp(a.until)
    if not 0 < a.duty_cycle <= 1 or end <= start:
        p.error('require increasing UTC bounds and duty cycle in (0, 1]')
    result = {'schema': 2, 'window': {'since': a.since, 'until': a.until}, 'episodes': [], 'walk_evidence': [], 'diagnostics': {},
              'semantics': {'claude_input': 'uncached', 'codex_input': 'includes cached input',
                            'gaps': 'non-tool wall time, not pure model inference',
                            'tool_time': 'union of foreground tool request/return intervals, including collectors; never background process lifetime',
                            'background': 'start to linked collection is an upper bound including scheduling and holds, never pure execution time',
                            'logical_operations': 'collector calls do not break consecutive operations; their usage remains in episode spans',
                            'verification': 'candidates only; unchanged source requires receipt review',
                            'canary': 'mentions/only-claims are unresolved, not proof of sole cause',
                            'codex': 'response-ID usage only; older token_count-only logs have unknown request usage'}}
    diagnostics = Counter()
    reference = Path(a.reference[0]).resolve() if a.reference else None
    for provider, root, glob in [('claude', a.claude_root, '*/**/subagents/*.jsonl'), ('codex', a.codex_root, '**/*.jsonl')]:
        if root is None or not root.is_dir():
            diagnostics[provider+'_root_unavailable'] += 1
            continue
        for path in sorted(root.glob(glob)):
            if path.stat().st_mtime < start:
                continue
            began = time.process_time()
            try:
                calls, usage = read_log(path, provider, start, end, diagnostics)
            except OSError:
                diagnostics['unreadable_files'] += 1
                continue
            diagnostics[provider+'_files_read'] += 1
            task = str(path.relative_to(root))
            for family, group in episodes(calls):
                result['episodes'].append(summarize(group, usage, provider, task, family, calls))
            if reference == path.resolve():
                lo, hi = map(int, a.reference[1:])
                group = [c for c in calls if lo <= c['line'] <= hi]
                if group:
                    result['reference'] = summarize(group, usage, provider, task, 'reference')
            time.sleep(min(2, max(0, time.process_time()-began)*(1/a.duty_cycle-1)))
    result['diagnostics'] = dict(diagnostics)
    result['per_day'] = dict(Counter(r['date']+'/'+r['provider']+'/'+r['family'] for r in result['episodes']))
    result['source_verified_verification_episodes'] = 0
    for path in a.walk_evidence:
        try:
            result['walk_evidence'].append(walk_evidence(path))
        except (OSError, ValueError, TypeError) as exc:
            p.error('walk evidence unavailable or unsupported: ' + str(exc))
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == '__main__':
    main()
