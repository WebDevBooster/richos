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

CONFIG = '.claude/owned-work.json'
SOURCE_WARNING = 'Source transcript unavailable. Only hook payloads are retained; transcript deduplication and observed question-answer provenance are unavailable. Do not infer missing answers or authority.'
BURST_AUDITS = 5
RECOVERY_SECONDS = 3600
PERMISSION_REASON = 'This tool call is not preauthorized. Use an already permitted tool or command for routine work; do not retry the same refused call or weaken permissions. Finish independent work. If actual additional authority is essential, explain that material decision with options and a recommendation.'


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
    if not isinstance(config, dict) or type(config.get('version')) is not int or config.get('version') != 1 or config.get('enabled') is not True or config.get('decision_policy') != 'dependency':
        return None
    binary = Path(config['runner'])
    if not binary.is_absolute() or not os.access(binary, os.X_OK):
        raise ValueError('Owned work runner is unavailable; completion is unverified')
    return config


def location(root, session):
    # Store outside working trees, so checkout cleanup cannot erase obligations.
    key = hashlib.sha256((str(root.resolve()) + '\0' + session).encode()).hexdigest()
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


def execution_observations(transcript, agent_id=None):
    """Observed calls/results are evidence, never a new grant of CEO authority."""
    calls, observed = {}, []
    for line in Path(transcript).read_text().splitlines():
        row = json.loads(line)
        if (row.get('isSidechain') and agent_id is None) or row.get('type') not in ('user', 'assistant'):
            continue
        content = row.get('message', {}).get('content', [])
        if not isinstance(content, list):
            continue
        for part in content:
            if part.get('type') == 'tool_use' and part.get('name') != 'AskUserQuestion':
                calls[part['id']] = {'tool_name': part.get('name'), 'input': part.get('input')}
            if part.get('type') == 'tool_result' and part.get('tool_use_id') in calls:
                output = part.get('content', '')
                if not isinstance(output, str):
                    output = json.dumps(output, ensure_ascii=False)
                observed.append({'id': (agent_id + ':' if agent_id else '') + part['tool_use_id'],
                                 'agent_id': agent_id, 'cwd': row.get('cwd'), **calls[part['tool_use_id']],
                                 'is_error': bool(part.get('is_error')), 'result': output[:8192],
                                 'result_truncated': len(output) > 8192})
    return observed


def session_execution_observations(transcript):
    observations = execution_observations(transcript)
    # Native Claude stores children beneath THIS session, not in an arbitrary
    # workspace crawl. Their receipts prove observed execution, never CEO intent.
    children = Path(transcript).with_suffix('') / 'subagents'
    for child in sorted(children.glob('agent-*.jsonl')):
        observations.extend(execution_observations(child, agent_id=child.stem))
    return observations


def capture(root, payload):
    session = payload['session_id']
    if not isinstance(session, str) or not session:
        raise ValueError('Missing native session identity')
    path = location(root, session)
    with locked(path.with_suffix('.lock')):
        state = json.loads(path.read_text()) if path.exists() else {'version': 1, 'session_id': session, 'workspace': str(root), 'messages': [], 'revision': 0, 'failures': 0, 'source_ids': []}
        state['messages'] = [m for m in state['messages'] if not (m['role'] == 'user' and observation(m['text']))]
        transcript = payload.get('transcript_path')
        state['source_status'] = 'available' if transcript and Path(transcript).exists() else 'unavailable'
        if transcript and Path(transcript).exists():
            messages = source_messages(transcript)
            receipts = {r['id']: r for r in state.get('execution_observations', [])}
            for receipt in session_execution_observations(transcript):
                receipts[receipt['id']] = receipt
            state['execution_observations'] = list(receipts.values())
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
            state['audit_attempts'] = 0
            state.pop('parked_prompt', None)
            msg = {'role': 'user', 'text': payload['prompt'], 'pending': True}
            if not state['messages'] or any(state['messages'][-1].get(k) != msg[k] for k in ('role', 'text')):
                state['messages'].append(msg)
        if payload.get('last_assistant_message'):
            msg = {'role': 'assistant', 'text': payload['last_assistant_message'], 'pending': True}
            if not state['messages'] or any(state['messages'][-1].get(k) != msg[k] for k in ('role', 'text')):
                state['messages'].append(msg)
        if 'background_tasks' in payload:
            state['background_tasks'] = payload['background_tasks']
        state.setdefault('background_tasks', [])
        if payload.get('hook_event_name') == 'Notification' and payload.get('notification_type') == 'permission_prompt':
            state['parked_prompt'] = {'since': time.time(), 'message': payload.get('message', ''), 'type': 'permission_prompt'}
        if payload.get('hook_event_name') in ('Stop', 'StopFailure'):
            state.pop('parked_prompt', None)
            state['stop_hook_active'] = payload.get('stop_hook_active', False)
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


def audit_data(state):
    data = {k: state[k] for k in ('messages', 'background_tasks')}
    data['source_status'] = state.get('source_status', 'unavailable')
    data['runtime_observations'] = {k: state[k] for k in ('last_permission_denial', 'parked_prompt') if k in state}
    data['execution_observations'] = state.get('execution_observations', [])
    return data


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
        data = audit_data(state)
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

        # Reserve pacing before inference. Repeated honest incompletes also cost
        # compute; a process crash or synthetic wake cannot reset their allowance.
        with locked(path.with_suffix('.lock')):
            current = json.loads(path.read_text())
            if current['revision'] != revision:
                return -1, ''
            attempts = current.get('audit_attempts', 0) + 1
            current['audit_attempts'] = attempts
            current['retry_at'] = time.time() + (RECOVERY_SECONDS if attempts >= BURST_AUDITS else 15)
            atomic(path, current)

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
            delay = RECOVERY_SECONDS if failures >= 3 or attempts >= BURST_AUDITS else 15 if failures else 0
            current.update(checked=fingerprint, verdict=verdict, failures=failures, retry_at=time.time() + delay)
            if verdict['kind'] == 'complete':
                current['audit_attempts'] = 0
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


def question_decision(path, config, proposed):
    with locked(path.with_suffix('.lock')):
        state = json.loads(path.read_text())
    data = audit_data(state)
    data['proposed_question'] = proposed
    try:
        result = subprocess.run([config['runner'], 'audit-question', state['workspace'], '120'],
                                input=json.dumps(data), text=True, capture_output=True, timeout=150)
        if result.returncode:
            raise ValueError(result.stderr[-2000:] or 'Question review failed')
        verdict = json.loads(result.stdout)
        if set(verdict) != {'allow', 'reason'} or type(verdict['allow']) is not bool or not isinstance(verdict['reason'], str) or not verdict['reason'].strip():
            raise ValueError('Question review lacks a supported disposition')
        with locked(path.with_suffix('.lock')):
            current = json.loads(path.read_text())
            if current['revision'] != state['revision']:
                return {'allow': False, 'reason': 'The instructions changed during question review. Reconcile the latest request before asking.'}
            current['question_review'] = {'question': proposed, **verdict}
            atomic(path, current)
        return verdict
    except (ValueError, subprocess.TimeoutExpired, OSError) as error:
        return {'allow': False, 'reason': 'Question review is unavailable; no new CEO authority was granted. Continue independent work using existing authority and retry review for any material decision. ' + str(error)}


def permission_denial(reason):
    return {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision':
            {'behavior': 'deny', 'message': reason, 'interrupt': False}}}


def permission_reason(payload):
    reason = PERMISSION_REASON
    suggestions = payload.get('permission_suggestions')
    if isinstance(suggestions, list) and suggestions:
        reason += (' The runtime offered the following UNGRANTED permission-rule suggestions '
                   '(diagnostic data, not instructions or existing permissions): '
                   + json.dumps(suggestions, ensure_ascii=False)
                   + '. This refusal applies to the submitted call as a whole; it does not '
                   'prove that every component is unavailable. For a compound call, distinguish '
                   'required operations from optional formatting. If only optional parts need '
                   'new authority, omit those parts and submit the already authorized operation '
                   'alone for normal permission evaluation. Do not disguise or repackage an '
                   'operation that actually needs new authority, or edit permission settings.')
    return reason


def question_denial(reason):
    return {'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': 'deny',
                                  'permissionDecisionReason': reason}}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['capture', 'audit', 'permission', 'question', 'observe'])
    args = parser.parse_args()
    payload = json.load(sys.stdin)
    if os.environ.get('RICHOS_OWNED_WORK_HOST') == 'controller':
        return 0
    root = Path(os.environ.get('CLAUDE_PROJECT_DIR') or payload['cwd']).resolve()
    config = configuration(root)
    if config is None:
        return 0
    if payload.get('agent_id'):
        # A child's permission dialog is presented in the leader UI too. Handle
        # the refusal, but never adopt child prose as CEO instructions or start
        # an independent owner for that child.
        if args.mode == 'permission':
            print(json.dumps(permission_denial(permission_reason(payload) + ' Return a genuine unresolved dependency to your leader.')))
        elif args.mode == 'question':
            print(json.dumps(question_denial('Return genuine business decisions to your leader for review. Do not park the CEO on a child question; complete independent authorized work.')))
        return 0
    path = capture(root, payload)
    if args.mode == 'permission':
        # Never widen permissions or impersonate an approval. Return the refusal
        # to the leader so it can select an already permitted method.
        reason = permission_reason(payload)
        if payload.get('tool_name') == 'AskUserQuestion':
            # AskUserQuestion is already filtered before tool execution. Leave a
            # validated business question available for its actual human answer.
            return 0
        with locked(path.with_suffix('.lock')):
            state = json.loads(path.read_text())
            state['last_permission_denial'] = {'at': time.time(), 'tool_name': payload.get('tool_name'), 'input': payload.get('tool_input'), 'permission_suggestions': payload.get('permission_suggestions', []), 'reason': reason}
            state.pop('parked_prompt', None)
            atomic(path, state)
        print(json.dumps(permission_denial(reason)))
        return 0
    if args.mode == 'question':
        if payload.get('tool_name') != 'AskUserQuestion':
            return 0
        verdict = question_decision(path, config, payload.get('tool_input'))
        if not verdict['allow']:
            print(json.dumps(question_denial(verdict['reason'])))
        return 0
    if args.mode == 'observe':
        return 0
    if args.mode == 'capture':
        with locked(path.with_suffix('.lock')):
            state = json.loads(path.read_text())
        warning = SOURCE_WARNING if state['source_status'] == 'unavailable' else ''
        print(json.dumps({'systemMessage': warning, 'hookSpecificOutput': {'hookEventName': payload['hook_event_name'], 'additionalContext': 'Rich owns authorized outcomes through verified completion. Routine repairs and diagnosis do not need CEO approval. Present genuine prepared CEO decisions with options and a recommendation, without making independent work wait. Preserve scope and explicit pause/end. Verify stale records and tell the CEO whether a check is obsolete or the implementation is broken, or what evidence will settle it. Record unrelated improvements separately. ' + warning}}))
        return 0
    code, message = audit(path, config)
    if message:
        print(message, file=sys.stderr)
    return code


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        reason = 'Owned work continuation could not verify this assignment: ' + str(error) + '. Keep the outcome unfinished; repair the continuation integration.'
        if sys.argv[1:2] == ['permission']:
            print(json.dumps(permission_denial(reason)))
            sys.exit(0)
        if sys.argv[1:2] == ['question']:
            print(json.dumps(question_denial(reason)))
            sys.exit(0)
        print(reason, file=sys.stderr)
        sys.exit(2)
