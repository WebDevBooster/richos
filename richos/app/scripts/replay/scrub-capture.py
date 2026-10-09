#!/usr/bin/env python3
"""Take the account details out of a recorded `claude` session before it goes into RichOS.

  scrub-capture.py RAW.jsonl OUT.jsonl [--expect N:WORDS ...]
                                           write the scrubbed capture; refuse if anything is left
  scrub-capture.py --check FILE.jsonl      only look; exit 1 and name what is left

--expect N:WORDS marks the Nth sent line (0 is the first, the `initialize`) with the words the
host's message must contain to stand for it in a replay (`"expect": {"contains": WORDS}`): where
the host is meant to ask the back end for its report, a replay then refuses a host that asks
anything else there.

A capture is the JSON-lines record of one stream-json session (`{"t", "sent"}` and `{"t",
"frame"}` lines, `richos_core::replay`). RichOS is public, so what a capture says about the
account that recorded it stays out (richos-hq plan 2026-10-09 §4 row 6):

- the `initialize` reply (email, organization, plan) is never kept, only the marker the replay
  answers with a bare success;
- `system/init` keeps only what the reader reads (tools, model, permission mode, version,
  built-in plugins); the account's claude.ai connectors, skills, commands, memory path and
  socket go;
- `rate_limit_event` keeps its window type, status and reset times; the account's usage
  figures and its organization's overage settings go;
- thinking signatures go (opaque, and not ours to publish);
- the API's own message, request and tool-call ids become stable placeholders
  (`msg_replay_1`, ...), the same id the same placeholder everywhere, so the frames still
  agree with one another;
- the recording's working folder and the home folder's user name become `/replay/cwd` and
  `/Users/user`.

What the model said and what the commands printed are kept: they are the recording.
"""
import json
import re
import sys

KEEP_INIT = ('type', 'subtype', 'cwd', 'session_id', 'uuid', 'tools', 'model', 'permissionMode',
             'claude_code_version', 'apiKeySource', 'output_style', 'plugins', 'capabilities')
DROP_ANYWHERE = ('memory_paths', 'messaging_socket_path')
IDS = re.compile(r'\b(msg|req|toolu)_01[A-Za-z0-9]{16,}')
HOME = re.compile(r'/Users/([^/"\s]+)')
REPLAY_CWD = '/replay/cwd'
# What must not be left. Each is (name, pattern over the scrubbed text).
LEFT = (
    ('an email address', re.compile(r'[\w.+-]+@[\w-]+\.[A-Za-z]{2,}')),
    ('an account, email, organization or subscription field', re.compile(
        r'"(account|email|emailAddress|organization\w*|org_id|orgId|subscription\w*|billing\w*)"\s*:')),
    ('an API message, request or tool-call id', IDS),
    ('a claude.ai connector', re.compile(r'"source"\s*:\s*"claudeai"')),
    ('an organization overage setting', re.compile(r'overage\w*"\s*:')),
    ('a home folder other than /Users/user', re.compile(r'/Users/(?!user\b)[^/"\s]+')),
    ('a thinking signature', re.compile(r'"signature"\s*:\s*"[^"]+"')),
)


def scrub_value(value):
    if isinstance(value, dict):
        out = {}
        for key, inner in value.items():
            if key in DROP_ANYWHERE:
                continue
            if key in ('signature', 'data') and isinstance(inner, str) and (
                    key == 'signature' or value.get('type') == 'redacted_thinking'):
                out[key] = ''
                continue
            out[key] = scrub_value(inner)
        return out
    if isinstance(value, list):
        return [scrub_value(v) for v in value]
    return value


def scrub_frame(frame):
    kind = (frame.get('type'), frame.get('subtype'))
    if kind == ('system', 'init'):
        frame = {k: v for k, v in frame.items() if k in KEEP_INIT}
        frame['plugins'] = [p for p in frame.get('plugins', []) if isinstance(p, dict) and p.get('path') == 'builtin']
        frame['mcp_servers'] = []
    elif frame.get('type') == 'rate_limit_event':
        info = frame.get('rate_limit_info', {})
        kept = {k: info[k] for k in ('status', 'rateLimitType', 'resetsAt') if k in info}
        windows = info.get('unifiedWindows')
        if isinstance(windows, dict):
            kept['unifiedWindows'] = {name: {'utilization': 0.0, 'resetsAt': w.get('resetsAt')}
                                      for name, w in windows.items() if isinstance(w, dict)}
        frame = dict(frame, rate_limit_info=kept)
    elif frame.get('type') == 'control_response' and 'redacted' not in frame:
        # A recorder that kept the `initialize` reply: only the marker survives.
        if isinstance(frame.get('response', {}).get('response'), dict) and 'account' in json.dumps(frame):
            frame = {'type': 'control_response', 'redacted': 'initialize reply not recorded (account details)'}
    return scrub_value(frame)


def scrub_lines(lines, expect=None):
    rows = [json.loads(line) for line in lines if line.strip()]
    sent = [row for row in rows if 'sent' in row]
    for index, words in (expect or {}).items():
        if index >= len(sent):
            raise ValueError('--expect %d: the capture has %d sent lines' % (index, len(sent)))
        sent[index]['expect'] = {'contains': words}
    cwds = sorted({row['frame']['cwd'] for row in rows
                   if isinstance(row.get('frame'), dict) and row['frame'].get('subtype') == 'init'
                   and isinstance(row['frame'].get('cwd'), str)}, key=len, reverse=True)
    out = []
    for row in rows:
        if 'frame' in row:
            row = dict(row, frame=scrub_frame(row['frame']))
        elif 'sent' in row:
            row = dict(row, sent=scrub_value(row['sent']))
        out.append(json.dumps(row))
    text = '\n'.join(out) + '\n'
    for cwd in cwds:
        text = text.replace(cwd, REPLAY_CWD).replace(cwd.replace('/', '-'), REPLAY_CWD.replace('/', '-'))
    names = {}
    text = IDS.sub(lambda m: names.setdefault(m.group(0), '%s_replay_%d' % (
        m.group(1), 1 + sum(1 for k in names if k.startswith(m.group(1) + '_')))), text)
    text = HOME.sub('/Users/user', text)
    return text


def left_in(text):
    return [name for name, pattern in LEFT if pattern.search(text)]


def main(argv):
    if len(argv) == 3 and argv[1] == '--check':
        left = left_in(open(argv[2], encoding='utf-8').read())
        for name in left:
            print('LEFT: ' + name)
        return 1 if left else 0
    paths, expect, rest = [], {}, argv[1:]
    while rest:
        word = rest.pop(0)
        if word == '--expect' and rest and ':' in rest[0] and rest[0].split(':', 1)[0].isdigit():
            index, words = rest.pop(0).split(':', 1)
            expect[int(index)] = words
        elif word.startswith('-'):
            paths = []
            break
        else:
            paths.append(word)
    if len(paths) != 2:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    try:
        text = scrub_lines(open(paths[0], encoding='utf-8').read().splitlines(), expect)
    except ValueError as error:
        print('REFUSED: %s' % error, file=sys.stderr)
        return 2
    left = left_in(text)
    if left:
        print('REFUSED, still in the capture: ' + '; '.join(left), file=sys.stderr)
        return 1
    with open(paths[1], 'w', encoding='utf-8') as out:
        out.write(text)
    print('scrubbed: %d lines -> %s' % (text.count('\n'), paths[1]))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
