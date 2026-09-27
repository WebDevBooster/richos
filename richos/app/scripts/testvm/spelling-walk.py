#!/usr/bin/env python3
"""spelling-walk.py — a reply the model writes in British spelling reaches him American (CEO §93).

Run by run-walk.py, which boots the guest, holds <TESTVM_ROOT>/guest.lock and removes the clone:

  run-walk.py --bundle ZIP --home EMPTY_DIR --engine ENGINE --report REPORT -- \\
      spelling-walk.py --out DIR --expect-sha SHA --expect american|as-written

run-walk.py passes the owned VM name as the first argument.

THE QUESTION. The CEO, 2026-09-27: "I just want to eliminate British spelling from the front-end
output." The app fixes safe British spellings at the one drain every reply passes
(richos-core `american_spelling.rs`, wired in `NativeClient::prompt`), before the reply is
stored, so the Mac's screen, speech, crash recovery and the phones all read the fixed text. This
walk asks the real model, on a fresh install, to copy a British sentence, and reads what each
surface actually holds.

WHAT IT DOES, in the guest, never on the host's screen (CEO ruling §65):
  identity   the running app says it was built from --expect-sha
  first-run  adopt-walk.py's: memory setup declined, company "Acme" registered, questions declined
  reply      types into the Mac's composer: copy this code and this sentence, keeping its
             spelling. The sentence is British on purpose and is read from the declared British
             test-input file (engine/scripts/lib/dialect/fixtures/stream-a-app.txt, section
             vm-sentence), because the write guard refuses British words anywhere else. Waits
             for the turn to end in the ledger, then reads, on the guest:
               - his words as STORED (PromptReceived), which must still be British;
               - the model's own words (the Stop callback's last_assistant_message in the engine's
                 evidence), which must be British, or the run proves nothing about the fixer;
               - the reply as STORED (the turn's AssistantDelta rows, concatenated in seq order),
                 which is what the phones receive: message-completed reads it back and
                 bridge.snapshot renders it (phone/rows.rs, phone/bridge.rs);
               - the reply as SHOWN (the accessibility text of the Mac's reply row);
               - first reply text stored, in ms after his words were stored (the ledger's own
                 clock; the chunk is shown right after it is stored, spine.rs), for comparison
                 with the same walk on the current nightly.
             --expect american: the stored and shown reply carry the American forms and none of
             the British ones. --expect as-written: the baseline build; only recorded.

  connect    command-walk.py's: the Acme folder connected, so work can be handed over
  document   asks for a file named note-<code>.md in the Acme repository holding only the same
             sentence, spelling as written, and landed. A document the app's sessions write is
             fixed in the desktop executable's PreToolUse wrapper (quota/gate.rs run_canonical),
             which hands the provider an updatedInput. Reads: the write as the model made it
             (the PreToolUse callback's tool_input in the engine's evidence), which must be
             British, and the file's bytes on disk (landed in Acme, or in the worker's worktree
             when it has not landed yet), which must be American. This is plan check C18: the
             bundled claude honoring updatedInput without permissionDecision is proven only by
             the bytes. A file written through the shell meets no write hook; that outcome is
             reported as INCONCLUSIVE, not as a pass.

Speech is not measured: the guest has no audio worth trusting (docs/testvm.md, CEO §53). What is
spoken is the `rich://chunk` payload the screen renders (ui/main.js relays it to
voice_speak_delta), so the shown text is the spoken text.

Exit 0 when every step passes. Every app instance is quit by run-walk.py's stop.sh (CEO §54).
"""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time
import uuid

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from relaunch import guest  # noqa: E402

_spec = importlib.util.spec_from_file_location('command_walk', HERE / 'command-walk.py')
command_walk = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(command_walk)
StepFailed = command_walk.StepFailed

STEPS = ['identity', 'first-run', 'reply', 'connect', 'document']
DOCUMENT = ('Please add a file named {name} to the Acme repository containing only this sentence, copied '
            'letter for letter with its spelling exactly as written, and land it: {sentence}')
# --document-tool write: the same request, naming the file-writing tool, so the one path the
# document fix covers (a Write/Edit/MultiEdit) is exercised on purpose (plan check C18).
WITH_WRITE_TOOL = ' Create the file with your Write tool, not with a shell command.'
WRITE_TOOLS = ('Write', 'Edit', 'MultiEdit')
FIXTURE = HERE.parents[2] / 'engine/scripts/lib/dialect/fixtures/stream-a-app.txt'
# The instruction carries no British word; the sentence does, from the fixture.
PROMPT = ('Quick copying test, answered right here in this conversation, no task needed. Reply with '
          'one line only: the code {token}, one space, then this sentence copied letter for letter '
          'with its spelling exactly as written, no quotation marks: {sentence}')
MARK = 'copying test'


def section(name, text=None):
    """A named `=== name` section of the stream-A fixture, without its trailing newline."""
    text = FIXTURE.read_text() if text is None else text
    marker = f'=== {name}\n'
    start = text.index(marker) + len(marker)
    end = text.find('\n=== ', start)
    return text[start:end if end >= 0 else len(text)].strip('\n')


def words_in(text, words):
    return [w for w in words if re.search(r'(?<![A-Za-z])' + re.escape(w) + r'(?![A-Za-z])', text or '', re.I)]


def verdict(evidence, sentence, british, american, expect):
    """Every way the run fails, as sentences. Empty means PASS."""
    failures = []
    if evidence.get('ended') != 'TurnCompleted':
        failures.append(f"the turn did not complete: {evidence.get('ended')}")
    if sentence not in (evidence.get('prompt_stored') or ''):
        failures.append('his words were not stored as he wrote them')
    if expect == 'as-written':
        return failures
    raw_british = words_in(evidence.get('model_words'), british)
    if not raw_british:
        failures.append('INCONCLUSIVE: the model wrote no British word, so this run says nothing about '
                        'the fixer (model words: %r)' % (evidence.get('model_words') or '')[:200])
    for surface in ('reply_stored', 'reply_shown'):
        text = evidence.get(surface) or ''
        if not text:
            failures.append(f'{surface}: nothing was read')
            continue
        left = words_in(text, british)
        if left:
            failures.append(f'{surface}: still British: {left}')
        wanted = [american[british.index(w)] for w in raw_british]
        missing = [w for w in wanted if not words_in(text, [w])]
        if missing:
            failures.append(f'{surface}: the American forms are missing: {missing}')
    return failures


def document_verdict(written, on_disk, british, american):
    """The document step's failures, as sentences. Empty means PASS."""
    if written is None:
        return ['INCONCLUSIVE: no Write, Edit or MultiEdit of the file reached the hooks (a shell write '
                'meets no write hook), so this run says nothing about the document fix']
    failures = []
    raw_british = words_in(written, british)
    if not raw_british:
        failures.append('INCONCLUSIVE: the model wrote no British word into the file (%r)' % written[:200])
    if on_disk is None:
        failures.append('the file was never found on disk')
        return failures
    left = words_in(on_disk, british)
    if left:
        failures.append(f'the file on disk is still British: {left}')
    wanted = [american[british.index(w)] for w in raw_british]
    missing = [w for w in wanted if not words_in(on_disk, [w])]
    if missing:
        failures.append(f'the file on disk lacks the American forms: {missing}')
    return failures


class SpellingWalk(command_walk.CommandWalk):
    def ledger(self):
        rows = guest(self.vm, 'cat ' + shlex.quote(self.data + '/conversation-ledger.jsonl') + ' 2>/dev/null || true', 60)
        return [json.loads(r) for r in rows.splitlines() if r.startswith('{')]

    def model_words(self, token):
        script = ('import glob,json,sys\n'
                  'hits=[]\n'
                  'for p in glob.glob(sys.argv[1]+"/engine-state/evidence/*/callbacks.jsonl"):\n'
                  '    for line in open(p):\n'
                  '        try: c=json.loads(line).get("callback",{})\n'
                  '        except Exception: continue\n'
                  '        m=c.get("last_assistant_message") or ""\n'
                  '        if c.get("hook_event_name")=="Stop" and sys.argv[2] in m: hits.append(m)\n'
                  'print(json.dumps(hits))\n')
        hits = json.loads(guest(self.vm, 'python3 -c ' + shlex.quote(script) + ' ' + shlex.quote(self.data)
                                + ' ' + shlex.quote(token), 60))
        return hits[-1] if hits else None

    def shown(self, token):
        rows = self.ax('tree')
        texts = [str(row.get(k, '')) for row in rows for k in ('title', 'desc', 'value')]
        return next((t for t in texts if token in t and MARK not in t), None)

    def reply(self):
        sentence = section('vm-sentence')
        british = section('vm-british-words').split()
        american = section('vm-american-words').split()
        token = 'x' + uuid.uuid4().hex[:10]
        before = self.clock()
        self.type_into(PROMPT.format(token=token, sentence=sentence), '--role', 'AXTextArea', '--title', 'Message to Rich')
        self.press('Send')
        sent = [before, self.clock()]
        end = time.monotonic() + self.a.within
        evidence = {'token': token, 'sent_between_guest_ms': [round(v) for v in sent]}
        while time.monotonic() < end:
            rows = self.ledger()
            asked = [r for r in rows if r.get('event') == 'PromptReceived' and token in (r.get('text') or '')]
            if asked:
                turn = asked[-1]['turn_id']
                ended = [r for r in rows if r.get('turn_id') == turn and r.get('event') in ('TurnCompleted', 'TurnInterrupted')]
                if ended:
                    deltas = sorted((r for r in rows if r.get('event') == 'AssistantDelta' and r.get('turn_id') == turn),
                                    key=lambda r: (r.get('seq') is None, r.get('seq') or 0))
                    evidence.update(
                        turn=turn, ended=ended[-1]['event'], prompt_stored=asked[-1]['text'],
                        reply_stored=''.join(r.get('text', '') for r in deltas), deltas=len(deltas),
                        first_reply_stored_ms=(min(r['at'] for r in deltas) - asked[-1]['at']) if deltas else None)
                    break
            time.sleep(1)
        else:
            raise StepFailed(f'the turn did not end within {self.a.within} s')
        time.sleep(2)  # the last chunk is shown right after it is stored
        evidence['model_words'] = self.model_words(token)
        evidence['reply_shown'] = self.shown(token)
        (self.out / 'reply-evidence.json').write_text(json.dumps(evidence, indent=2) + '\n')
        failures = verdict(evidence, sentence, british, american, self.a.expect)
        if failures:
            raise StepFailed('; '.join(failures))
        return {k: evidence.get(k) for k in ('token', 'ended', 'deltas', 'first_reply_stored_ms',
                                             'model_words', 'reply_stored', 'reply_shown')}

    def written(self, name):
        """The newest write of `name` as the model made it: the PreToolUse callback's own input."""
        script = ('import glob,json,sys\n'
                  'hits=[]\n'
                  'for p in glob.glob(sys.argv[1]+"/engine-state/evidence/*/callbacks.jsonl"):\n'
                  '    for line in open(p):\n'
                  '        try: c=json.loads(line).get("callback",{})\n'
                  '        except Exception: continue\n'
                  '        i=c.get("tool_input") or {}\n'
                  '        if (c.get("hook_event_name")=="PreToolUse" and c.get("tool_name") in sys.argv[3].split(",")\n'
                  '                and str(i.get("file_path","")).endswith("/"+sys.argv[2])): hits.append(i)\n'
                  'print(json.dumps(hits))\n')
        hits = json.loads(guest(self.vm, 'python3 -c ' + shlex.quote(script) + ' ' + shlex.quote(self.data) + ' '
                                + shlex.quote(name) + ' ' + ','.join(WRITE_TOOLS), 60))
        return hits[-1] if hits else None

    def calls_naming(self, name):
        """Every tool call whose input names the file, as the hooks saw it: which tool, whether a
        worker made it, and the first 300 characters of its input. Says HOW the file was made."""
        script = ('import glob,json,sys\n'
                  'out=[]\n'
                  'for p in glob.glob(sys.argv[1]+"/engine-state/evidence/*/callbacks.jsonl"):\n'
                  '    for line in open(p):\n'
                  '        try: c=json.loads(line).get("callback",{})\n'
                  '        except Exception: continue\n'
                  '        i=json.dumps(c.get("tool_input") or {})\n'
                  '        if c.get("hook_event_name")=="PreToolUse" and sys.argv[2] in i:\n'
                  '            out.append({"tool":c.get("tool_name"),"worker":bool(c.get("agent_id")),"input":i[:300]})\n'
                  'print(json.dumps(out))\n')
        return json.loads(guest(self.vm, 'python3 -c ' + shlex.quote(script) + ' ' + shlex.quote(self.data) + ' '
                                + shlex.quote(name), 60))

    def on_disk(self, name, written):
        """The file's bytes: landed in Acme if it has landed, else where the model wrote it."""
        landed = self.company + '/' + name
        paths = [landed] + ([written['file_path']] if written and written.get('file_path') else [])
        for path in paths:
            out = guest(self.vm, 'cat ' + shlex.quote(path) + ' 2>/dev/null || true', 30)
            if out.strip():
                return path, out
        return None, None

    def document(self):
        if not self.facts.get('thread'):
            raise StepFailed('first-run must have run (no thread on record)')
        sentence = section('vm-sentence')
        british = section('vm-british-words').split()
        american = section('vm-american-words').split()
        name = 'note-x' + uuid.uuid4().hex[:10] + '.md'
        request = DOCUMENT.format(name=name, sentence=sentence)
        if self.a.document_tool == 'write':
            request += WITH_WRITE_TOOL
        sent = self.send(request)
        landed = self.company + '/' + name
        end = time.monotonic() + self.a.document_within
        pressed, written, path, text = 0, None, None, None
        while time.monotonic() < end:
            written = self.written(name) or written
            path, text = self.on_disk(name, written)
            if written and path == landed:
                break
            record = self.ours(sent)
            if record and pressed < self.a.approvals and self.approve_if_asked(record.get('title', '')):
                pressed += 1
            time.sleep(3)
        body = None
        if written:
            body = written.get('content')
            if body is None:
                body = written.get('new_string') or ''.join(e.get('new_string', '') for e in written.get('edits', []))
        evidence = {'file': name, 'document_tool': self.a.document_tool,
                    'sent_between_guest_ms': [round(v) for v in sent], 'approvals_pressed': pressed,
                    'written_by_model': body, 'path_read': path, 'on_disk': text, 'landed': path == landed,
                    'calls_naming_the_file': self.calls_naming(name)}
        (self.out / 'document-evidence.json').write_text(json.dumps(evidence, indent=2) + '\n')
        failures = document_verdict(body, text, british, american)
        if failures and written is None:
            tools = sorted({c['tool'] for c in evidence['calls_naming_the_file']})
            failures.append('tool calls that named the file: ' + (', '.join(tools) or 'none'))
        if failures:
            raise StepFailed('; '.join(failures))
        return evidence


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('vm')
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--expect-sha', required=True, help='the commit the bundle under test was built from')
    p.add_argument('--expect', choices=['american', 'as-written'], required=True,
                   help='american: the build with the fixer; as-written: the baseline build, recorded only')
    p.add_argument('--within', type=float, default=180, help='seconds for the reply turn to end')
    p.add_argument('--document-within', type=float, default=300, help='seconds for the document to land')
    p.add_argument('--approvals', type=int, default=3, help='most Approve presses on the document assignment')
    p.add_argument('--document-tool', choices=['any', 'write'], default='any',
                   help='any: ask for the file as a person would; write: also name the Write tool (C18)')
    p.add_argument('--steps', default=','.join(STEPS))
    a = p.parse_args()
    steps = a.steps.split(',')
    unknown = [s for s in steps if s not in STEPS]
    if unknown:
        p.error('unknown step(s): ' + ', '.join(unknown))
    walk = SpellingWalk(a)
    report = {'vm': a.vm, 'expect_sha': a.expect_sha, 'expect': a.expect, 'steps': []}
    ok = True
    for step in steps:
        began = time.monotonic()
        row = {'step': step}
        try:
            row['evidence'] = getattr(walk, step.replace('-', '_'))()
            row['outcome'] = 'PASS'
        except (StepFailed, RuntimeError, subprocess.TimeoutExpired, ValueError, KeyError) as exc:
            row['outcome'] = 'FAIL'
            row['detail'] = str(exc)
            ok = False
        row['seconds'] = round(time.monotonic() - began, 1)
        report['steps'].append(row)
        (a.out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        print(f"{step}: {row['outcome']}" + (f" — {row.get('detail')}" if row['outcome'] != 'PASS' else ''), flush=True)
        if not ok:
            break
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
