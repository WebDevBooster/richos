#!/usr/bin/env python3
"""Native Claude leader continuation. Source capture is synchronous; audit is asyncRewake.
No worker execution, detached leader or synthetic CEO prompt is created here.
"""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

CONFIG = '.richos-owned-work.json'


def observation(text):
    # Native wake/task notifications are transport observations, never a fresh
    # CEO request. The installed CLI emits these through UserPromptSubmit too.
    return text.lstrip().startswith(('<task-notification', '<teammate-message',
                                    '<system-reminder', '<local-command', '<command-name',
                                    'Stop hook feedback:'))


def atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(data, f, ensure_ascii=False)
            f.flush()
            os.fsync(f.fileno())
        os.replace(name, path)
        fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        if os.path.exists(name):
            os.unlink(name)


@contextlib.contextmanager
def locked(path, blocking=True):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with open(path, 'a') as f:
        os.chmod(path, 0o600)
        try:
            fcntl.flock(f, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        except BlockingIOError:
            yield False
            return
        try:
            yield True
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


def configuration(root):
    path = root / CONFIG
    if not path.exists():
        return None
    config = json.loads(path.read_text())
    if config.get('version') != 1 or config.get('enabled') is not True:
        return None
    binary = Path(config['runner'])
    if not binary.is_absolute() or not os.access(binary, os.X_OK):
        raise ValueError('Owned work runner is unavailable; completion is unverified')
    return config


def location(root, session):
    # Store outside working trees, so checkout cleanup cannot erase obligations.
    key = hashlib.sha256((str(root) + '\0' + session).encode()).hexdigest()
    return Path(os.environ.get('RICHOS_OWNED_STATE_DIR', str(Path.home() / '.claude/state/richos-owned-work'))) / (key + '.json')


def source_messages(transcript):
    messages = []
    questions = {}
    for line in Path(transcript).read_text().splitlines():
        row = json.loads(line)  # malformed records are unknown, never an empty scope
        if row.get('isSidechain') or row.get('isMeta') or row.get('isCompactSummary') or row.get('isSynthetic') or row.get('type') not in ('user', 'assistant'):
            continue
        content = row.get('message', {}).get('content', [])
        if isinstance(content, str):
            content = [{'type': 'text', 'text': content}]
        for c in content:
            if c.get('type') == 'tool_use' and c.get('name') == 'AskUserQuestion':
                questions[c.get('id')] = c.get('input', {}).get('questions', [])
        parts = [c['text'] for c in content if c.get('type') == 'text']
        for c in content:
            if c.get('type') == 'tool_result' and c.get('tool_use_id') in questions and not c.get('is_error'):
                # A proposed tool call alone is not proof it reached the CEO.
                # Its successful result supplies both presentation and response.
                prompts = questions[c['tool_use_id']]
                shown = '\n'.join(q.get('question', '') for q in prompts if isinstance(q, dict))
                if shown:
                    messages.append({'role': 'assistant', 'text': shown,
                                     'source_id': str(row.get('uuid') or hashlib.sha256(line.encode()).hexdigest()) + ':question'})
                parts.append('CEO response to an observed AskUserQuestion: ' + json.dumps(c.get('content'), ensure_ascii=False))
        text = '\n'.join(parts)
        if not text or observation(text):
            continue
        messages.append({'role': row['type'], 'text': text, 'source_id': row.get('uuid') or hashlib.sha256(line.encode()).hexdigest()})
    return messages


def capture(root, payload):
    session = payload['session_id']
    if not isinstance(session, str) or not session:
        raise ValueError('Missing native session identity')
    path = location(root, session)
    with locked(path.with_suffix('.lock')):
        state = json.loads(path.read_text()) if path.exists() else {'version': 1, 'session_id': session, 'workspace': str(root), 'messages': [], 'revision': 0, 'failures': 0, 'source_ids': []}
        state['messages'] = [m for m in state['messages'] if not (m['role'] == 'user' and observation(m['text']))]
        transcript = payload.get('transcript_path')
        if transcript and Path(transcript).exists():
            messages = source_messages(transcript)
            known = set(state.get('source_ids', []))
            for message in messages:
                key = message.pop('source_id')
                if key in known:
                    continue
                # Stop/UserPromptSubmit can precede the transcript write. Replace
                # the corresponding pending copy instead of duplicating authority.
                pending = next((m for m in state['messages'] if m.get('pending') and
                                m['role'] == message['role'] and m['text'] == message['text']), None)
                if pending is not None:
                    pending.pop('pending')
                else:
                    state['messages'].append(message)
                known.add(key)
            state['source_ids'] = sorted(known)
        if payload.get('hook_event_name') == 'UserPromptSubmit' and payload.get('prompt') and not observation(payload['prompt']) and not payload.get('isMeta'):
            state['retry_at'] = 0
            state['failures'] = 0
            msg = {'role': 'user', 'text': payload['prompt'], 'pending': True}
            if not state['messages'] or any(state['messages'][-1].get(k) != msg[k] for k in ('role', 'text')):
                state['messages'].append(msg)
        if payload.get('last_assistant_message'):
            msg = {'role': 'assistant', 'text': payload['last_assistant_message'], 'pending': True}
            if not state['messages'] or any(state['messages'][-1].get(k) != msg[k] for k in ('role', 'text')):
                state['messages'].append(msg)
        state['background_tasks'] = payload.get('background_tasks', [])
        state['revision'] += 1
        state['event'] = payload.get('hook_event_name')
        state['updated_at'] = time.time()
        atomic(path, state)
    return path


def validate_verdict(value):
    kind = value.get('kind')
    if kind in ('complete', 'incomplete'):
        field = 'evidence' if kind == 'complete' else 'remaining'
        if set(value) != {'kind', field} or not isinstance(value[field], str) or not value[field].strip():
            raise ValueError('Audit lacks evidence or remaining work')
    elif kind == 'decision':
        fields = ('question', 'why_ceo', 'recommendation')
        if set(value) != {'kind', *fields, 'options'} or any(not isinstance(value.get(k), str) or not value[k].strip() for k in fields):
            raise ValueError('Incomplete CEO decision')
        if not isinstance(value['options'], list) or len(value['options']) < 2 or any(not isinstance(x, str) or not x.strip() for x in value['options']):
            raise ValueError('Decision lacks concrete options')
    else:
        raise ValueError('Unknown audit verdict')
    return value


def audit_once(path, config):
    # Native hooks can overlap. One inspector per leader; source capture remains free.
    with locked(path.with_suffix('.audit-lock'), blocking=False) as acquired:
        if not acquired:
            return 0, ''
        with locked(path.with_suffix('.lock')):
            state = json.loads(path.read_text())
        if not state['messages']:
            return 0, ''  # a new session has no request yet
        revision = state['revision']
        data = {k: state[k] for k in ('messages', 'background_tasks')}
        prior = state.get('verdict', {})
        presented = False
        if prior.get('kind') == 'decision':
            question = ' '.join(prior['question'].split()).casefold()
            presented = any(m['role'] == 'assistant' and question in ' '.join(m['text'].split()).casefold()
                            for m in state['messages'][state.get('decision_message_count', 0):])
        user_key = hashlib.sha256(json.dumps([m for m in state['messages'] if m['role'] == 'user'], sort_keys=True).encode()).hexdigest()
        if presented and state.get('decision_user_key') == user_key:
            return 0, ''  # the actual question reached the conversation; await its answer
        fingerprint = hashlib.sha256(json.dumps(data, sort_keys=True).encode()).hexdigest()
        if state.get('checked') == fingerprint and state.get('verdict', {}).get('kind') in ('complete', 'decision'):
            return 0, ''
        delay = max(0, state.get('retry_at', 0) - time.time())
        if delay:
            deadline = time.monotonic() + min(delay, 3600)
            while time.monotonic() < deadline:
                time.sleep(min(1, deadline - time.monotonic()))
                with locked(path.with_suffix('.lock')):
                    if json.loads(path.read_text())['revision'] != revision:
                        return -1, ''

        try:
            result = subprocess.run([config['runner'], 'audit-session', state['workspace'], '120'], input=json.dumps(data), text=True, capture_output=True, timeout=270)
            if result.returncode:
                raise ValueError(result.stderr[-4000:] or 'Outcome inspection failed')
            verdict = validate_verdict(json.loads(result.stdout))
            failures = 0
        except (ValueError, subprocess.TimeoutExpired, OSError) as error:
            failures = state.get('failures', 0) + 1
            verdict = {'kind': 'incomplete', 'remaining': 'Outcome inspection failed; the assignment remains owned and unverified. Diagnose the failure and continue authorized work. No CEO resubmission is needed. Detail: ' + str(error)}
        with locked(path.with_suffix('.lock')):
            current = json.loads(path.read_text())
            if current['revision'] != revision:
                # A newer user instruction or worker result supersedes this audit.
                return -1, ''
            repeated_decision = presented and prior.get('question') == verdict.get('question')
            current.update(checked=fingerprint, verdict=verdict, failures=failures, retry_at=time.time() + (3600 if failures >= 3 else 15 if failures else 0))
            if verdict['kind'] == 'decision':
                current['decision_user_key'] = user_key
                if not repeated_decision:
                    current['decision_message_count'] = len(current['messages'])

            atomic(path, current)
        if verdict['kind'] == 'complete':
            return 0, ''
        if verdict['kind'] == 'decision':
            if repeated_decision:
                return 0, ''
            return 2, 'Independent review found a specific CEO dependency. Finish independent authorized work, then present this decision once: ' + json.dumps(verdict)
        return 2, 'Rich still owns unfinished authorized work. Continue without a CEO nudge. Inspect current effects before repeating actions. Do not ask whether to perform routine work.\n' + verdict['remaining']


def audit(path, config):
    while True:
        result = audit_once(path, config)
        if result[0] != -1:
            return result
        # An overlapping event is already durable. Audit its newest scope rather
        # than losing its wake or applying a verdict about the previous request.


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['capture', 'audit'])
    args = parser.parse_args()
    payload = json.load(sys.stdin)
    if payload.get('agent_id') or os.environ.get('RICHOS_OWNED_WORK_HOST') == 'controller':
        return 0
    root = Path(os.environ.get('CLAUDE_PROJECT_DIR') or payload['cwd']).resolve()
    config = configuration(root)
    if config is None:
        return 0
    path = capture(root, payload)
    if args.mode == 'capture':
        print(json.dumps({'hookSpecificOutput': {'hookEventName': payload['hook_event_name'], 'additionalContext': 'Rich owns authorized outcomes through verified completion. The continuation adapter retains this conversation. Routine repairs and diagnosis do not need CEO approval. Unrelated prepared questions cannot gate independent work. Preserve scope and explicit pause/end. Verify stale records and distinguish obsolete assertions from broken implementation. Record unrelated improvements separately.'}}))
        return 0
    code, message = audit(path, config)
    if message:
        print(message, file=sys.stderr)
    return code


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print('Owned work continuation could not verify this assignment: ' + str(error) + '. Keep the outcome unfinished; repair the continuation integration.', file=sys.stderr)
        sys.exit(2)
