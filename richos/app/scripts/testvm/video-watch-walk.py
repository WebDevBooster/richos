#!/usr/bin/env python3
"""video-watch-walk.py — Rich downloads a YouTube video and says what is in it, once from its
captions and once from his own transcription with the large speech model (CEO 2026-10-07).

Run by run-walk.py, which holds one guest slot for this run only, boots the guest and removes the clone:

  run-walk.py --bundle ZIP --home EMPTY_DIR --engine ENGINE --report REPORT -- \\
      video-watch-walk.py --out DIR --expect-sha SHA [--url URL]

run-walk.py passes the owned VM name as the first argument. `--steps a,b,c` runs a subset.

THE QUESTION. The CEO, 2026-10-07: the tools are installed "for when the user tells Rich to watch
or download a Youtube video or some other video and handle it", and file transcription uses the
large model setup installs ("Both, in this nightly, yes."). Media-tools plan slice 4 (richos-hq
docs/plans/2026-10-07-media-tools.md §5): "download this video", "watch it and tell me what is
in it" on a video with captions, and the same on a video with no captions, transcribed with the
runtime's whisper-cli. The CEO's caption rule (2026-10-07: "relying on auto-generated Youtube
captions is generally a bad idea"): captions a person uploaded first, else Rich's own
transcription, auto-generated captions only when he cannot transcribe. So the captions half uses
a video with uploaded English captions (--captions-url, jNQXAC9IVRw), and the other half the
video the CEO named (--url, D8PikZ1KhUo), whose English captions are auto-generated: Rich must
take the Whisper path on it. The transcript he saves is copied out and compared with those
auto-generated captions on the host (scripts/qa/caption-wer.py).

WHAT IT DOES, in the guest, never on the host's screen (CEO ruling §65):
  identity     the running app says it was built from --expect-sha
  setup        "Set it up" on the setup sheet installs the video tools (yt-dlp and BOTH speech
               models, each checked against its pin), then "Close"
  first-run    adopt-walk.py's: memory setup declined, company "Acme" registered, questions declined
  connect      command-walk.py's: the Acme folder connected
  speech-env   every running provider lease has RICHOS_SPEECH_MODEL naming
               ggml-large-v3-turbo-q5_0.bin (the transcription model, not voice's)
  captions     "download this video and tell me what is in it" (--captions-url): PASS needs a Bash
               run of yt-dlp --write-subs, none with --write-auto-subs, the video saved in
               ~/Downloads, and an answer naming --captions-keyword
  transcribe   the same for --url, plus "save the full text of what is said in Downloads": PASS
               needs a Bash run of whisper-cli with the speech model (by $RICHOS_SPEECH_MODEL or
               the large model's file), none with --write-auto-subs, the transcript file with at
               least --min-words words, and an answer naming --keyword. Copied to --out.
Approve is pressed when the panel offers one, at most --approvals times per step. CEO §53: no
sound is played. Every app instance is quit by run-walk.py's stop.sh (CEO §54).
Exit 0 when every step passes.
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

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from relaunch import guest  # noqa: E402


def _load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


command_walk = _load('command_walk', 'command-walk.py')
setup_walk = _load('setup_walk', 'setup-walk.py')
StepFailed = command_walk.StepFailed
OPEN = command_walk.OPEN

STEPS = ['identity', 'setup', 'first-run', 'connect', 'speech-env', 'captions', 'transcribe']
URL = 'https://www.youtube.com/watch?v=D8PikZ1KhUo'  # the CEO's video; auto-generated captions only
CAPTIONS_URL = 'https://www.youtube.com/watch?v=jNQXAC9IVRw'  # uploaded English captions
LARGE = 'ggml-large-v3-turbo-q5_0.bin'
TRANSCRIPT = 'video-transcript.txt'
CAPTIONS_TASK = 'Please download this YouTube video for me and tell me what is in it: {url}'
TRANSCRIBE_TASK = ('Please download this YouTube video for me and tell me what is said in it: {url} '
                   'Also save the full text of what is said in it as a text file at ~/Downloads/' + TRANSCRIPT + '.')


def env_value(line, name):
    """The value of NAME in one `ps -E` line, or None. Values here are paths without spaces
    (the app's model folder is ~/.config/richos/models)."""
    m = re.search(r'(?:^|\s)' + re.escape(name) + r'=(\S+)', line)
    return m.group(1) if m else None


def ran(commands, *needles):
    """The Bash runs whose command contains every needle."""
    return [c for c in commands if all(n in c['command'] for n in needles)]


class VideoWatchWalk(command_walk.CommandWalk):
    def __init__(self, a):
        super().__init__(a)
        self.log = self.payload + '/app.log'
        self.models = self.home + '/.config/richos/models'
        self.downloads = self.home + '/Downloads'

    # --- helpers ---------------------------------------------------------------------------
    def read_log(self):
        return guest(self.vm, 'cat ' + shlex.quote(self.log) + ' 2>/dev/null || true', 60)

    def ledger(self):
        rows = guest(self.vm, 'cat ' + shlex.quote(self.data + '/conversation-ledger.jsonl') + ' 2>/dev/null || true', 60)
        out = []
        for r in rows.splitlines():
            try:
                out.append(json.loads(r))
            except ValueError:
                pass
        return out

    def bash_runs(self):
        """Every Bash PostToolUse in the app's hook evidence, any lease, a teammate's included."""
        script = ('import json,glob,sys\n'
                  'out=[]\n'
                  'for p in glob.glob(sys.argv[1]+"/engine-state/evidence/*/callbacks.jsonl"):\n'
                  '    for l in open(p):\n'
                  '        try: c=json.loads(l).get("callback",{})\n'
                  '        except Exception: continue\n'
                  '        if c.get("hook_event_name")=="PostToolUse" and c.get("tool_name")=="Bash":\n'
                  '            r=c.get("tool_response") or {}\n'
                  '            out.append({"command":c.get("tool_input",{}).get("command",""),\n'
                  '                        "background":bool(c.get("tool_input",{}).get("run_in_background")),\n'
                  '                        "agent":c.get("agent_id"),\n'
                  '                        "stdout":(r.get("stdout","") if isinstance(r,dict) else str(r))[-1500:]})\n'
                  'print(json.dumps(out))\n')
        return json.loads(guest(self.vm, 'python3 -c ' + shlex.quote(script) + ' ' + shlex.quote(self.data), 60))

    def approve_any(self):
        """One press of an Approve the window offers for a request (work-summary.js labels each
        "Approve <title>"), never the quota panel's reset approval."""
        try:
            found = self.ax('find', '--title', 'Approve ', '--role', 'AXButton', '--contains')
        except StepFailed:
            return False
        titles = [f.get('title') or '' for f in found]
        title = next((t for t in titles if t.startswith('Approve ') and 'reset' not in t), None)
        if not title:
            return False
        self.press(title, contains=False)
        return True

    def said_since(self, sent_ms):
        """What he was told since `sent_ms`: the turns' words and every assignment notice."""
        rows = self.ledger()
        words = ''.join(r.get('text') or '' for r in rows
                        if r.get('event') == 'AssistantDelta' and r.get('at', 0) >= sent_ms)
        records = [r for r in self.records() if r.get('registered_at_ms', 0) >= sent_ms]
        notices = [n.get('text') or '' for r in records for n in (r.get('notices') or [])]
        # The app's own `[re-prime]` priming prompt never records a TurnCompleted (measured in
        # the first run of this walk), so only his prompts count as open turns.
        turns = [r for r in rows if r.get('event') == 'PromptReceived' and r.get('at', 0) >= sent_ms
                 and not (r.get('text') or '').startswith('[re-prime]')]
        ended = {r.get('turn_id') for r in rows if r.get('event') in ('TurnCompleted', 'TurnInterrupted')}
        open_turn = any(t.get('turn_id') not in ended for t in turns)
        return {'words': words, 'notices': notices, 'records': records, 'open_turn': open_turn}

    def converse(self, text, done, seconds):
        """Send `text`, then poll until `done(said, runs)` holds with no turn or assignment open,
        or `seconds` pass. Approve is pressed as asked. Returns the last reading."""
        sent = self.send(text)
        end = time.monotonic() + seconds
        pressed, said, runs = 0, None, []
        while time.monotonic() < end:
            time.sleep(10)
            said, runs = self.said_since(sent[0]), self.bash_runs()
            busy = said['open_turn'] or any(r.get('state') in OPEN for r in said['records'])
            if not busy and done(said, runs):
                break
            if pressed < self.a.approvals:
                for record in said['records']:
                    if record.get('state') in OPEN and self.approve_if_asked(record.get('title', '')):
                        pressed += 1
                        break
                else:
                    if self.approve_any():
                        pressed += 1
        return {'sent_between_guest_ms': [round(v) for v in sent], 'approvals_pressed': pressed,
                'said': said, 'bash': runs}

    def answered(self, said, keywords):
        text = (said['words'] + ' ' + ' '.join(said['notices'])).lower()
        return all(k.lower() in text for k in keywords)

    # --- steps -----------------------------------------------------------------------------
    def setup(self):
        self.wait_for('Set it up', seconds=90)
        self.shot('setup-before.png')
        before = self.clock()
        self.press('Set it up')
        end = time.monotonic() + self.a.setup_within
        outcome = None
        while time.monotonic() < end:
            outcome = setup_walk.run_outcome(self.read_log())
            if outcome:
                break
            time.sleep(5)
        lines = [line for line in self.read_log().splitlines()
                 if line.startswith('[richos] setup') and '%' not in line]
        models = guest(self.vm, 'ls ' + shlex.quote(self.models) + ' 2>/dev/null || true').split()
        evidence = {'outcome': outcome, 'seconds': round((self.clock() - before) / 1000, 1),
                    'lines': lines[-20:], 'models': models}
        if outcome != 'finished' or LARGE not in models:
            raise StepFailed('setup did not install the video tools: ' + json.dumps(evidence)[:2000])
        self.shot('setup-after.png')
        if self.present('Close'):
            self.press('Close')
        return evidence

    def speech_env(self):
        end = time.monotonic() + 120
        leases = []
        while time.monotonic() < end:
            ps = guest(self.vm, 'ps -axwwE -o pid=,command= 2>/dev/null || true', 60)
            leases = [{'pid': int(line.split()[0]), 'model': env_value(line, 'RICHOS_SPEECH_MODEL')}
                      for line in ps.splitlines() if '/engine-profiles/' in line and '--plugin-dir' in line]
            if leases:
                break
            time.sleep(3)
        (self.out / 'speech-env.json').write_text(json.dumps(leases, indent=2) + '\n')
        if not leases:
            raise StepFailed('no provider lease was running to read its environment')
        wrong = [l for l in leases if not (l['model'] or '').endswith('/' + LARGE)]
        if wrong:
            raise StepFailed(f'RICHOS_SPEECH_MODEL does not name {LARGE} on every lease: {leases}')
        return {'leases': leases}

    def captions(self):
        keys = self.a.captions_keyword

        def done(said, runs):
            return self.answered(said, keys) and ran(runs, 'yt-dlp', '--write-subs')
        got = self.converse(CAPTIONS_TASK.format(url=self.a.captions_url), done, self.a.within)
        saved = guest(self.vm, 'ls -la ' + shlex.quote(self.downloads) + ' 2>/dev/null || true')
        got['downloads'] = saved
        (self.out / 'captions-observed.json').write_text(json.dumps(got, indent=2) + '\n')
        self.shot('captions-answer.png')
        failures = []
        if not ran(got['bash'], 'yt-dlp', '--write-subs'):
            failures.append('no Bash run of yt-dlp asked for uploaded subtitles')
        if ran(got['bash'], '--write-auto-subs'):
            failures.append('auto-generated captions were fetched although the video has uploaded ones')
        if not re.search(r'\.(mp4|webm|mkv)\b', saved):
            failures.append('no video file in ~/Downloads: ' + saved)
        if not self.answered(got['said'], keys):
            failures.append(f'the answer does not name {keys}')
        if failures:
            raise StepFailed('; '.join(failures))
        return {'yt_dlp': [c['command'] for c in ran(got['bash'], 'yt-dlp')],
                'answer': (got['said']['words'] or ' '.join(got['said']['notices']))[-3000:],
                'approvals_pressed': got['approvals_pressed'], 'downloads': saved}

    def transcript_words(self):
        text = guest(self.vm, 'cat ' + shlex.quote(self.downloads + '/' + TRANSCRIPT) + ' 2>/dev/null || true', 120)
        return text, len(text.split())

    def transcribe(self):
        keys = self.a.keyword

        def done(said, runs):
            return (self.answered(said, keys) and ran(runs, 'whisper-cli')
                    and self.transcript_words()[1] >= self.a.min_words)
        got = self.converse(TRANSCRIBE_TASK.format(url=self.a.url), done, self.a.transcribe_within)
        text, words = self.transcript_words()
        (self.out / TRANSCRIPT).write_text(text)
        got['transcript_words'] = words
        (self.out / 'transcribe-observed.json').write_text(json.dumps(got, indent=2) + '\n')
        self.shot('transcribe-answer.png')
        whisper = ran(got['bash'], 'whisper-cli')
        with_model = [c for c in whisper if 'RICHOS_SPEECH_MODEL' in c['command'] or LARGE in c['command']]
        failures = []
        if not with_model:
            failures.append('no Bash run of whisper-cli with the speech model: ' + json.dumps(whisper)[:1500])
        if words < self.a.min_words:
            failures.append(f'the saved transcript has {words} words, fewer than {self.a.min_words}')
        if ran(got['bash'], '--write-auto-subs'):
            failures.append('auto-generated captions were fetched although a speech model is installed')
        if not self.answered(got['said'], keys):
            failures.append(f'the answer does not name {keys}')
        if failures:
            raise StepFailed('; '.join(failures))
        return {'whisper_cli': [c['command'] for c in with_model], 'transcript_words': words,
                'captions_fetched': [c['command'] for c in ran(got['bash'], '-subs')],
                'answer': (got['said']['words'] or ' '.join(got['said']['notices']))[-3000:],
                'approvals_pressed': got['approvals_pressed']}


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('vm')
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--expect-sha', required=True, help='the commit the bundle under test was built from')
    p.add_argument('--url', default=URL, help='the video to transcribe (no uploaded captions)')
    p.add_argument('--captions-url', default=CAPTIONS_URL, help='a video with uploaded captions')
    p.add_argument('--keyword', action='append', default=None,
                   help='a word the transcribe answer must contain (repeatable; default: Claude)')
    p.add_argument('--captions-keyword', action='append', default=None,
                   help='a word the captions answer must contain (repeatable; default: elephant)')
    p.add_argument('--min-words', type=int, default=8000, help='fewest words in the saved transcript')
    p.add_argument('--setup-within', type=float, default=2700, help='seconds for "Set it up" (about 1 GB)')
    p.add_argument('--within', type=float, default=1800, help='seconds for the captions answer')
    p.add_argument('--transcribe-within', type=float, default=7200, help='seconds for the transcription answer')
    p.add_argument('--approvals', type=int, default=6, help='most Approve presses per step')
    p.add_argument('--steps', default=','.join(STEPS))
    a = p.parse_args()
    a.keyword = a.keyword or ['Claude']
    a.captions_keyword = a.captions_keyword or ['elephant']
    steps = a.steps.split(',')
    unknown = [s for s in steps if s not in STEPS]
    if unknown:
        p.error('unknown step(s): ' + ', '.join(unknown))
    walk = VideoWatchWalk(a)
    report = {'vm': a.vm, 'expect_sha': a.expect_sha, 'url': a.url, 'steps': []}
    ok = True
    for step in steps:
        began = time.monotonic()
        row = {'step': step}
        try:
            row['evidence'] = getattr(walk, step.replace('-', '_'))()
            row['outcome'] = 'PASS'
        except (StepFailed, RuntimeError, ValueError, KeyError, IndexError, subprocess.TimeoutExpired) as exc:
            row['outcome'] = 'FAIL'
            row['detail'] = str(exc)
            ok = False
        row['seconds'] = round(time.monotonic() - began, 1)
        report['steps'].append(row)
        (a.out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        print(f"{step}: {row['outcome']}" + (f" — {row.get('detail')}" if row['outcome'] != 'PASS' else ''), flush=True)
        if not ok:
            break
    try:
        walk.keep_logs()
    except (StepFailed, RuntimeError, subprocess.TimeoutExpired) as exc:
        print(f'logs not kept: {exc}', flush=True)
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
