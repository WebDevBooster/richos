#!/usr/bin/env python3
"""voice-walk.py — on a Mac with no whisper-cli of its own, the app hears with the engine's (CEO 2026-10-07).

Run by run-walk.py, which holds one guest slot for this run only, boots the guest and removes the clone:

  run-walk.py --bundle ZIP --home EMPTY_DIR --engine ENGINE --report REPORT -- \\
      voice-walk.py --out DIR --expect-sha SHA --wav SPOKEN.wav --model GGML.bin [--model-id ID]

run-walk.py passes the owned VM name as the first argument.

THE QUESTION. The CEO, 2026-10-07: "I thought Whisper was a key part of the whole RichOS app ...
And now, you're telling me it's not guaranteed to be on the user's Mac??" The engine's runtime
now carries whisper-cli (build-runtimes.py), and the app resolves it before PATH and Homebrew
(richos-voice stt.rs). This walk asks a clean guest, which has no Homebrew and no whisper-cli,
to turn one spoken sample into words through the app.

WHAT IT DOES, in the guest, never on the host's screen (CEO ruling §65):
  identity    the running app says it was built from --expect-sha
  no-decoder  `command -v whisper-cli` prints nothing in a login shell and in /bin/sh, and no
              Homebrew or /usr/local copy exists
  runtime     the engine's runtime/bin/whisper-cli exists, is listed in its delivery.json with
              that sha256, and says its version
  first-run   adopt-walk.py's: memory setup declined, company "Acme" registered, questions declined
  stage       the spoken sample and the speech model are copied into the guest home. The model
              is copied, not downloaded: fetching weights is provision.rs's own, separate proof.
              The guest's microphone permission for com.richos.app is granted in its TCC.db,
              the "Allow" a person gives once (see grant_microphone)
  relaunch    the app is relaunched with RICHOS_VOICE_INPUT_WAV (capture.rs: the WAV stands in
              for the microphone through the identical capture path; no audio device is opened
              and nothing is played) and RICHOS_VOICE_WHISPER_MODEL_ID
  ready       the app's own voice-readiness line says ready, and its decoder sha256 is the
              runtime's whisper-cli
  heard       the home screen's door is passed, the talk control (#talk-toggle) is pressed and
              turns into "Stop talking"; the transcript the app stored (PromptReceived) is read
              from the guest's ledger

CEO §53: no sound is played anywhere. The sample is made with `say -o`, which writes a file.
Exit 0 when every step passes. Every app instance is quit by run-walk.py's stop.sh (CEO §54).
"""
import argparse
import importlib.util
import json
from pathlib import Path
import shlex
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from relaunch import guest, relaunch  # noqa: E402

_spec = importlib.util.spec_from_file_location('adopt_walk', HERE / 'adopt-walk.py')
adopt_walk = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(adopt_walk)
StepFailed = adopt_walk.StepFailed
command = adopt_walk.command

STEPS = ['identity', 'no-decoder', 'runtime', 'first-run', 'stage', 'relaunch', 'ready', 'heard']
READY = '[richos] voice: ready on this machine'
NOT_READY = '[richos] voice: not ready on this machine'


def spoken_prompt(rows):
    """The first stored prompt that came from voice: a PromptReceived with source "jam" (ledger.rs
    `Source::Jam`) and words in it. A re-prime or any other internal turn is never it (the first
    run of this walk read a "[re-prime]" turn as the transcript, which is why this is a function)."""
    for row in rows:
        if row.get('event') == 'PromptReceived' and row.get('source') == 'jam' and (row.get('text') or '').strip():
            return row
    return None


def decoder_sha12(line):
    """The `bin:<sha12>` the readiness line carries (toolchain.rs `provenance`), or None."""
    for word in line.split():
        if word.startswith('bin:'):
            return word[4:16]
    return None


class VoiceWalk(adopt_walk.Walk):
    def __init__(self, a):
        super().__init__(a)
        self.engine = self.payload + '/engine'
        self.wav = self.home + '/voice-sample.wav'
        self.log = self.payload + '/app.log'

    def no_decoder(self):
        login = guest(self.vm, "zsh -lc 'command -v whisper-cli || true'")
        plain = guest(self.vm, "/bin/sh -c 'command -v whisper-cli || true'")
        copies = guest(self.vm, 'ls /opt/homebrew/bin/whisper-cli /usr/local/bin/whisper-cli /usr/bin/whisper-cli '
                                '2>/dev/null || true')
        if login or plain or copies:
            raise StepFailed(f'this guest has its own whisper-cli: login={login!r} sh={plain!r} files={copies!r}')
        return {'command_v_login_shell': login, 'command_v_sh': plain, 'homebrew_or_usr_copies': copies}

    def runtime(self):
        path = self.engine + '/runtime/bin/whisper-cli'
        sha = guest(self.vm, 'shasum -a 256 ' + shlex.quote(path)).split()[0]
        listed = json.loads(guest(self.vm, 'cat ' + shlex.quote(self.engine + '/runtime/delivery.json')))
        if listed['files'].get('bin/whisper-cli') != sha:
            raise StepFailed(f'runtime whisper-cli {sha} is not the delivery.json entry {listed["files"].get("bin/whisper-cli")}')
        version = guest(self.vm, shlex.quote(path) + ' --version 2>/dev/null')
        self.facts['runtime_whisper_sha256'] = sha
        self.save()
        return {'path': path, 'sha256': sha, 'version': version, 'delivery_version': listed['versions'].get('whisper-cli')}

    def grant_microphone(self):
        """The "Allow" a person gives the first time voice opens. walk-e5e9903a36b4 (2026-10-07)
        pressed the talk control and macOS put up '"RichOS" would like to access the microphone.'
        over the window (talk-refused.png); start_voice_capture waited on it and the control never
        turned into "Stop talking". No walk in this harness answers a system privacy prompt by
        script; every grant the guest needs is written instead, as provision-guest.sh writes the
        screen-capture and accessibility grants. This one follows it: a row in the guest user's TCC.db
        (the guest image ships with SIP off; never on a host). The row is the same one tccd writes
        when a person presses Allow: service kTCCServiceMicrophone, client com.richos.app (the
        bundle identifier, tauri.conf.json), client_type 0, auth_value 2 (allowed)."""
        db = '"$HOME/Library/Application Support/com.apple.TCC/TCC.db"'
        sql = ("INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, "
               "auth_version, indirect_object_identifier_type, indirect_object_identifier, flags, last_modified) "
               "VALUES ('kTCCServiceMicrophone', 'com.richos.app', 0, 2, 2, 1, 0, 'UNUSED', 0, strftime('%s','now'));")
        guest(self.vm, f'sqlite3 {db} {shlex.quote(sql)}')
        row = guest(self.vm, f'sqlite3 {db} ' + shlex.quote(
            "SELECT service, client, auth_value FROM access WHERE service='kTCCServiceMicrophone' "
            "AND client='com.richos.app';"))
        if row != 'kTCCServiceMicrophone|com.richos.app|2':
            raise StepFailed(f'the guest microphone grant for com.richos.app did not take: {row!r}')
        return row

    def stage(self):
        microphone = self.grant_microphone()
        command([HERE / 'guest.sh', self.vm, '--push', self.a.wav, self.wav], 120)
        models = self.home + '/.config/richos/models'
        guest(self.vm, 'mkdir -p ' + shlex.quote(models))
        target = f'{models}/ggml-{self.a.model_id}.bin'
        command([HERE / 'guest.sh', self.vm, '--push', self.a.model, target], 900)
        return {'wav': self.wav, 'model': target, 'microphone_grant': microphone,
                'model_sha256': guest(self.vm, 'shasum -a 256 ' + shlex.quote(target), 120).split()[0]}

    def relaunch(self):
        launched = relaunch(self.vm, environment={'RICHOS_VOICE_INPUT_WAV': self.wav,
                                                  'RICHOS_VOICE_WHISPER_MODEL_ID': self.a.model_id})
        self.log = launched['log']
        self.facts['relaunch'] = launched
        self.facts['relaunched_at_ms'] = self.clock()
        self.save()
        self.wait_for('Talk to Rich', seconds=60)  # the home door or the talk control: the window is up
        return launched

    def ready(self):
        end = time.monotonic() + 60
        while time.monotonic() < end:
            text = guest(self.vm, 'cat ' + shlex.quote(self.log) + ' 2>/dev/null || true')
            lines = [line for line in text.splitlines() if READY in line or NOT_READY in line]
            if lines:
                line = lines[-1]
                if NOT_READY in line:
                    raise StepFailed(line)
                want = self.facts['runtime_whisper_sha256'][:12]
                if decoder_sha12(line) != want:
                    raise StepFailed(f'voice is ready on a decoder that is not the runtime\'s ({want}): {line}')
                return {'line': line}
            time.sleep(1)
        raise StepFailed('the app printed no voice-readiness line within 60 s')

    def by_id(self, dom_id):
        """The node whose DOM id is dom_id, or None when it is not in the accessibility tree."""
        try:
            nodes = self.ax('find', '--id', dom_id, '--first')
        except StepFailed as exc:
            if 'notfound' in str(exc) or 'nothing matched' in str(exc):
                return None
            raise
        nodes = [n for n in nodes if not n.get('meta')]
        return nodes[0] if nodes else None

    def talk(self):
        """Open the microphone the way a person does: through the home screen's door, then the talk
        control. TWO BUTTONS ARE NAMED "Talk to Rich". The home screen's door (#home-enter,
        home.js DOOR_LABEL) opens the conversation and nothing else, and while the home screen is
        up #app is inert, so the door is the ONLY "Talk to Rich" in the tree. The 2026-10-07 run
        (walk-1fede03eadc0) pressed it by title and waited 120 s for a capture that nothing had
        started. The talk control is #talk-toggle (index.html); its label turns into "Stop talking"
        only after start_voice_capture resolves (main.js enterVoiceMode), so that label is the
        proof the press opened capture."""
        door = self.by_id('home-enter')
        if door:
            self.ax('click', '--id', 'home-enter')
        end = time.monotonic() + 30
        toggle = None
        while time.monotonic() < end and not toggle:
            toggle = self.by_id('talk-toggle')
            if not toggle:
                time.sleep(1)
        if not toggle:
            self.shot('talk-missing.png')
            raise StepFailed('the talk control (#talk-toggle) is not on screen within 30 s of the home door')
        self.ax('click', '--id', 'talk-toggle')
        end = time.monotonic() + 30
        while time.monotonic() < end:
            toggle = self.by_id('talk-toggle') or {}
            if toggle.get('desc') == 'Stop talking':
                return {'home_door_pressed': bool(door), 'talk_control': toggle}
            time.sleep(1)
        self.shot('talk-refused.png')
        log = guest(self.vm, 'tail -40 ' + shlex.quote(self.log) + ' || true')
        raise StepFailed(f'the talk control did not turn into "Stop talking" within 30 s: {toggle}\nlog tail:\n{log}')

    def heard(self):
        talk = self.talk()
        end = time.monotonic() + self.a.within
        while time.monotonic() < end:
            rows = guest(self.vm, 'cat ' + shlex.quote(self.data + '/conversation-ledger.jsonl') + ' 2>/dev/null || true', 60)
            row = spoken_prompt(json.loads(r) for r in rows.splitlines() if '"PromptReceived"' in r)
            if row:
                log = guest(self.vm, 'grep -iE "richos-voice|\\[richos\\] voice|wav" ' + shlex.quote(self.log) + ' || true')
                self.shot('heard.png')
                return {'transcript': row['text'], 'row': row, 'talk': talk, 'voice_log': log.splitlines()[-20:]}
            time.sleep(2)
        log = guest(self.vm, 'tail -40 ' + shlex.quote(self.log) + ' || true')
        # What the window showed when nothing was heard: the 2026-10-07 run pressed "Talk to Rich"
        # and the app logged no capture at all, and only the screen can say why.
        self.shot('heard-failed.png')
        raise StepFailed(f'no transcript was stored within {self.a.within} s; log tail:\n{log}')


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('vm')
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--expect-sha', required=True, help='the commit the bundle under test was built from')
    p.add_argument('--wav', type=Path, required=True, help='a short spoken sample, 16 kHz mono WAV (say -o, then afconvert)')
    p.add_argument('--model', type=Path, required=True, help='the GGML weights to copy in, matching --model-id')
    p.add_argument('--model-id', default='small.en')
    p.add_argument('--within', type=float, default=120, help='seconds for the transcript to be stored')
    p.add_argument('--steps', default=','.join(STEPS))
    a = p.parse_args()
    steps = a.steps.split(',')
    unknown = [s for s in steps if s not in STEPS]
    if unknown:
        p.error('unknown step(s): ' + ', '.join(unknown))
    walk = VoiceWalk(a)
    report = {'vm': a.vm, 'expect_sha': a.expect_sha, 'steps': []}
    ok = True
    for step in steps:
        began = time.monotonic()
        row = {'step': step}
        try:
            row['evidence'] = getattr(walk, step.replace('-', '_'))()
            row['outcome'] = 'PASS'
        except (StepFailed, RuntimeError, ValueError, KeyError, subprocess.TimeoutExpired) as exc:
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
