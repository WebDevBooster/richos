#!/usr/bin/env python3
"""Source collection and host validation for the adopted Agent dependency gate.

The registrar interprets semantics; this host establishes citation membership.
No prompt token or recorded question can grant authority or a tool permission.
"""
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

PENDING = ('CEO DEPENDENCY PENDING: this dispatch has an unresolved authority dependency. '
           'Reconcile the actual CEO conversation and declared ruling for the affected work. '
           'An ask or deferral is not approval. Continue independent authorized work; '
           'present only a genuine unresolved CEO-level decision.')
UNVERIFIED = ('CEO DEPENDENCY UNVERIFIED: source or review evidence is unavailable. '
              'Repair the local integration and retry the dispatch review. '
              'This is not a new CEO decision or a grant of tool permission.')


def record(root, data, outcome, diagnostics):
    """Diagnostic receipt only. Never read as authority or forwarded as policy."""
    path = root / '.claude/state/owned-dispatch-reviews.jsonl'
    path.parent.mkdir(parents=True, exist_ok=True)
    row = {'input_sha256': hashlib.sha256(json.dumps(data, sort_keys=True).encode()).hexdigest(),
           'outcome': outcome, 'diagnostics': diagnostics[-4000:]}
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        os.write(fd, (json.dumps(row) + '\n').encode())
    finally:
        os.close(fd)


def resolve_records(root):
    lib = str(Path(__file__).resolve().parent)
    # Reuse the engine's declared-source resolution on every collection pass.
    # No source requested by the proposed dispatch enters this resolver.
    pending = subprocess.run(['bash', '-c', '\n'.join([
        '. "$1/ceo-asks.sh"', 'ca_require || exit 2',
        'rc=0; ca_resolve "$2" || rc=$?',
        'case "$rc" in 0) ca_items_json /dev/stdout;; 1) printf "[]";; *) exit 2;; esac'
    ]), 'bash', lib, str(root)], text=True, capture_output=True, timeout=15)
    rulings = subprocess.run(['bash', '-c', '\n'.join([
        '. "$1/ceo-ruled.sh"', 'cr_require || exit 2',
        'rc=0; cr_resolve "$2" || rc=$?',
        '[ "$rc" -ne 2 ] || exit 2', 'printf "%b" "$CR_SOURCES"'
    ]), 'bash', lib, str(root)], text=True, capture_output=True, timeout=15)
    if pending.returncode or rulings.returncode:
        raise ValueError('Declared CEO records cannot be resolved')
    return json.loads(pending.stdout), rulings.stdout


def collect(root, payload):
    spec = importlib.util.spec_from_file_location('owned_session_sources', Path(__file__).with_name('owned-session.py'))
    adapter = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(adapter)
    config = adapter.configuration(root)
    if config is None:
        raise ValueError('Adoption configuration is unavailable')
    pending, declared_sources = resolve_records(root)
    if not isinstance(pending, list) or any(not isinstance(item, dict) for item in pending):
        raise ValueError('Pending item parser did not return records')
    sources = []
    for line in declared_sources.splitlines():
        if line:
            path = str(Path(line.split('\t', 1)[0]).resolve())
            if not any(s['path'] == path for s in sources):
                sources.append({'path': path, 'text': Path(path).read_text()})
    messages, unavailable = [], False
    try:
        transcript = payload.get('transcript_path')
        if not isinstance(transcript, str) or not transcript:
            raise ValueError('Native transcript is absent')
        current = adapter.source_messages(transcript)  # must remain readable even with saved scope
        saved = None
        session = payload.get('session_id')
        if isinstance(session, str) and session:
            state_path = adapter.location(root, session)
            if state_path.exists():
                candidate = json.loads(state_path.read_text())
                if (candidate.get('session_id') == session
                        and Path(candidate.get('workspace', '')).resolve() == root.resolve()
                        and candidate.get('source_transcript') == str(Path(transcript).resolve())):
                    saved = candidate
        if payload.get('agent_id') and saved is None:
            raise ValueError('Child dispatch has no verified leader-source binding')
        if saved is not None:
            messages = [{'role': m['role'], 'text': m['text']} for m in saved['messages']]
            known = set(saved.get('source_ids', []))
            # Membership is by native source ID. A repeated CEO answer after a
            # revocation is new authority and must not be deduplicated by text.
            messages.extend({'role': m['role'], 'text': m['text']} for m in current if m['source_id'] not in known)
        else:
            messages = [{'role': m['role'], 'text': m['text']} for m in current]
        unavailable = not messages
    except (OSError, ValueError, TypeError, KeyError):
        unavailable = True
    data = {'proposed_dispatch': payload['tool_input'], 'pending_items': pending,
            'messages': messages, 'standing_rulings': sources, 'source_unavailable': unavailable}
    return config, data


def validate(data, verdict):
    if data['source_unavailable'] or not data['messages']:
        raise ValueError('Source conversation is unavailable')
    if not isinstance(verdict, dict) or set(verdict) != {'kind', 'citations'}:
        raise ValueError('Unsupported dispatch disposition')
    if verdict['kind'] not in ('independent', 'pending', 'authorized') or not isinstance(verdict['citations'], list):
        raise ValueError('Unsupported dispatch disposition')
    if verdict['kind'] == 'authorized' and not verdict['citations']:
        raise ValueError('Cleared dependency lacks cited authority')
    for cite in verdict['citations']:
        if not isinstance(cite, dict) or set(cite) != {'message_index', 'path', 'quote'}:
            raise ValueError('Malformed authority citation')
        index, path, quote = cite['message_index'], cite['path'], cite['quote']
        source = None
        if type(index) is int and 0 <= index < len(data['messages']) and path is None:
            message = data['messages'][index]
            if message['role'] == 'user':
                source = message['text']
        elif index is None and isinstance(path, str):
            matches = [r for r in data['standing_rulings'] if r['path'] == path]
            if len(matches) == 1:
                source = matches[0]['text']
        if not isinstance(quote, str) or not quote.strip() or source is None or quote not in source:
            raise ValueError('Authority quote is not from a CEO message or declared ruling')
    return verdict['kind']


def main():
    root, data, diagnostics = None, {}, ''
    try:
        root = Path(sys.argv[1])
        payload = json.load(sys.stdin)
        if payload.get('tool_name') not in (None, '', 'Agent'):
            return 0
        proposed = payload.get('tool_input')
        if not isinstance(proposed, dict) or not isinstance(proposed.get('prompt'), str) or not proposed['prompt'].strip():
            raise ValueError('Concrete Agent dispatch is missing')
        config, data = collect(root, payload)
        if data['source_unavailable']:
            raise ValueError('Native source conversation cannot be read')
        result = subprocess.run([config['runner'], 'audit-dispatch', str(root), '120'],
                                input=json.dumps(data), text=True, capture_output=True, timeout=150)
        diagnostics = result.stdout[-2000:] + '\n' + result.stderr[-2000:]
        if result.returncode:
            raise ValueError('Dispatch registrar did not return a successful review')
        kind = validate(data, json.loads(result.stdout))
        latest_config, latest_data = collect(root, payload)
        if latest_config != config or latest_data != data:
            raise ValueError('Source authority changed during dispatch review')
        record(root, data, kind, diagnostics)
        if kind == 'pending':
            print(PENDING, file=sys.stderr)
            return 2
        return 0
    except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.TimeoutExpired) as error:
        # Registrar prose and its own execution environment never become policy.
        if root is not None:
            try:
                record(root, data, 'unverified', str(error) + '\n' + diagnostics)
            except OSError:
                pass
        print(UNVERIFIED, file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
