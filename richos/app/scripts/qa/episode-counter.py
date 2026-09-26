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
    found, executable = set(), True
    for token in tokens:
        if token in (';', '&&', '||', '|', '&', '('):
            executable = True
        elif executable:
            name = Path(token).name
            if '=' in token and re.match(r'^[A-Za-z_][A-Za-z_0-9]*=', token):
                continue
            if name in ('env', 'bash', 'sh', 'python', 'python3', 'nice', 'command') or token.startswith('-'):
                continue
            found.add(name)
            executable = False
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
                    family = 'ui' if sig & UI else 'verification' if sig & VERIFY else None
                    if not family and (name in ('TaskOutput', 'write_stdin', 'functions.write_stdin') or sig & POLL):
                        family = 'observation'
                    calls[key] = {'line': line_number, 'start': when, 'end': None,
                                  'response': msg.get('id'), 'name': name, 'family': family,
                                  'signature': digest(cmd or json.dumps(b.get('input'), sort_keys=True)),
                                  'output_hash': None, 'canary_mention': False, 'canary_only_claim': False,
                                  'failure': False}
                elif b.get('type') == 'tool_result' and b.get('tool_use_id') in calls:
                    call = calls[b['tool_use_id']]
                    if call['end'] is not None:
                        continue
                    out = output_text(b.get('content', ''))
                    call.update(end=when, end_line=line_number, output_hash=digest(out))
                    call['canary_mention'] = bool(re.search(r'record[- ]canary', out, re.I))
                    call['canary_only_claim'] = bool(re.search(r'(?:only[^\n]{0,70}record[- ]canary|record[- ]canary[^\n]{0,70}only)', out, re.I))
                    call['failure'] = bool(b.get('is_error') or re.search(r'(?:Exit code [1-9]|exit(?:ed)?[ :=]+[1-9]|deadline exceeded|AX timeout)', out, re.I))
    return sorted(calls.values(), key=lambda c: c['line']), usage


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
    complete = [c for c in span_calls if c['end'] is not None and c['end'] >= c['start']]
    intervals = [(c['start'], c['end']) for c in complete]
    elapsed = max((c['end'] for c in complete), default=calls[0]['start']) - calls[0]['start']
    tool_time = union_seconds(intervals)
    row = {'provider': provider, 'task': task, 'first_line': first, 'last_line': last,
           'date': datetime.fromtimestamp(calls[0]['start'], timezone.utc).date().isoformat(),
           'family': family, 'tool_calls': len(calls), 'span_tool_calls': len(span_calls), 'tool_names': dict(Counter(c['name'] for c in calls)),
           'model_requests': len(selected) if selected else None,
           'usage_missing_fields': {k: sum(u.get(k) is None for u in selected.values()) for k in KEYS},
           'usage': {k: sum(u[k] for u in selected.values() if u.get(k) is not None) if selected and any(u.get(k) is not None for u in selected.values()) else None for k in KEYS},
           'tool_seconds': round(tool_time, 3), 'non_tool_gap_seconds': round(max(0, elapsed-tool_time), 3),
           'elapsed_seconds': round(max(0, elapsed), 3), 'unmatched_calls': len(span_calls)-len(complete),
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
    for family, minimum in [('ui', 3), ('observation', 3), ('verification', 2)]:
        group = []
        sequence = [c for c in calls if c['family'] == family] if family == 'verification' else calls
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


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--claude-root', type=Path)
    p.add_argument('--codex-root', type=Path)
    p.add_argument('--since', required=True, help='inclusive UTC date or timestamp')
    p.add_argument('--until', required=True, help='exclusive UTC date or timestamp')
    p.add_argument('--reference', nargs=3, metavar=('FILE', 'FIRST', 'LAST'))
    p.add_argument('--duty-cycle', type=float, default=0.2, help='fraction of a core, approximate per-file pacing')
    a = p.parse_args()
    start, end = stamp(a.since), stamp(a.until)
    if not 0 < a.duty_cycle <= 1 or end <= start:
        p.error('require increasing UTC bounds and duty cycle in (0, 1]')
    result = {'schema': 1, 'window': {'since': a.since, 'until': a.until}, 'episodes': [], 'diagnostics': {},
              'semantics': {'claude_input': 'uncached', 'codex_input': 'includes cached input',
                            'gaps': 'non-tool wall time, not pure model inference',
                            'tool_time': 'union of request/result intervals; background handoff is not process lifetime',
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
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == '__main__':
    main()
