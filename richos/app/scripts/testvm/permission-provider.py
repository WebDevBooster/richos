#!/usr/bin/env python3
"""Deterministic provider boundary for the native conversation permission walk.

Only the provider is a fixture. The installed application must create, render and
answer the permission through its normal policy. This script executes no tools.
It never logs prompts or provider account data. Use only in a disposable guest.
"""
import json
import sys
import uuid

MARKER = 'S7_NATIVE_PERMISSION_'


def emit(value):
    print(json.dumps(value), flush=True)


def result(text=None):
    if text:
        emit({'type': 'assistant', 'message': {'role': 'assistant', 'content': [
            {'type': 'text', 'text': text}]}})
    emit({'type': 'result', 'stop_reason': 'end_turn'})


def serve(lines):
    pending = None
    for line in lines:
        frame = json.loads(line)
        kind = frame.get('type')
        if kind == 'control_request':
            subtype = frame.get('request', {}).get('subtype')
            emit({'type': 'control_response', 'response': {
                'subtype': 'success', 'request_id': frame['request_id'], 'response': {}}})
            if subtype == 'interrupt':
                pending = None
                result()
        elif kind == 'user':
            # The app also supplies hidden context. Only an explicit visible
            # walk marker asks for permission; other turns have no tool action.
            content = frame.get('message', {}).get('content', '')
            text = content if isinstance(content, str) else '\n'.join(
                part.get('text', '') for part in content if isinstance(part, dict))
            if MARKER in text:
                if pending is not None:
                    raise ValueError('another turn arrived before the permission decision')
                pending = 's7-' + uuid.uuid4().hex
                emit({'type': 'control_request', 'request_id': pending, 'request': {
                    'subtype': 'can_use_tool', 'tool_name': 'Bash',
                    'description': 'Synthetic permission acceptance check',
                    'input': {'command': 'printf s7-permission-fixture'}}})
            else:
                result('S7 independent conversation replied.' if 'S7_INDEPENDENT' in text else None)
        elif kind == 'control_response' and pending is not None:
            response = frame.get('response', {})
            if response.get('request_id') != pending:
                continue
            decision = response.get('response', {}).get('behavior')
            if decision not in ('allow', 'deny'):
                raise ValueError('permission response has no allow/deny verdict')
            # This is receipt evidence, not a claim a shell action ran.
            result('S7 provider received ' + decision + ' for ' + pending + '.')
            pending = None
    if pending is not None:
        raise ValueError('input closed before the permission decision')


if __name__ == '__main__':
    if '--version' in sys.argv:
        print('2.1.283 (synthetic S7 acceptance provider)')
    else:
        serve(sys.stdin)
