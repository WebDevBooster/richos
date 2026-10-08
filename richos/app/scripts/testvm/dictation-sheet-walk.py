#!/usr/bin/env python3
"""dictation-sheet-walk.py — the Dictation sheet from no grants to a dictation in Try it here (dictation plan slice 2).

Run by run-walk.py, which holds one guest slot for this run only, boots the guest and removes the clone:

  run-walk.py --bundle ZIP --home EMPTY_DIR --engine ENGINE --report REPORT -- \\
      dictation-sheet-walk.py --out DIR --expect-sha SHA --wav SPOKEN.wav --model GGML.bin [--model-id small.en]

run-walk.py passes the owned VM name as the first argument. `--steps a,b,c` runs a subset.

THE QUESTION. Slice 2 of richos-hq docs/plans/2026-10-08-dictation-anywhere.md (revision 2,
section 9): "VM walk from no grants: turn the switch on; the microphone prompt appears and OCR
(scripts/qa/ocr-find.sh) reads Iris's sentence in it; Allow is pressed through the accessibility
tree; the Accessibility prompt appears; the guest grant is written; within 2 s the sheet says On
with no relaunch, and Try it here receives a dictation. Then the refused path: the sheet shows the
drawn denied line and Open System Settings opens the Accessibility pane. Then a second copy with
dictation on shows 'On even when RichOS is closed'. If the guest's prompt cannot be clicked through
the accessibility tree, the walk proves the prompt by OCR, grants the row, and says so in its
report." Measured against the CEO's words: "yes, also keep the sentence Iris wrote for when macOS
shows when RichOS asks for the microphone" and his "On even when RichOS is closed" (2026-10-08).

WHAT IT DOES, in the guest, never on the host's screen (CEO ruling §65). The app is started with
`open -n -a` (relaunch.py) and the tool is the app's child, never a binary run from ssh (minor 8).
No sound is played anywhere (CEO §53): the spoken sample is a file that RICHOS_VOICE_INPUT_WAV puts
through the identical capture path. The ways in are shown through RICHOS_DICTATION_PREVIEW=1, the
walks' preview, because DICTATION_READY stays false until slice 5.
  identity      the running app says it was built from --expect-sha
  stage         every TCC row for com.richos.app removed (no grants at all); the sample and the
                speech model copied in
  relaunch      the app relaunched on that guest with the preview and the sample as its microphone
  switch-on     Settings, Dictation, the switch pressed
  mic-prompt    macOS's microphone prompt is on screen, OCR reads Iris's sentence in it, and its
                Allow is pressed through the accessibility tree (or, when no process in the tree
                offers it, the Microphone row is written and the report says so)
  ax-prompt     macOS's Accessibility prompt is on screen (OCR)
  granted       the guest's Accessibility row is written; the tool makes its key tap and the sheet
                says On, with the app's pid unchanged (no relaunch); the time from the write to the
                tool's line is measured
  try-it        one dictation of the sample into Try it here; its text is the guest's own decode
  refused       the Accessibility row removed, the app relaunched: the sheet says the drawn denied
                line with Open System Settings beside it
  open-settings Open System Settings brings System Settings to the front on Accessibility
  second-copy   the Accessibility row back; a second copy of the bundle, on its own home with
                dictation on: its tool finds the key taken (exit 3), and its Settings row and sheet
                say "On even when RichOS is closed"; that copy is then quit by its pid

Exit 0 when every step passes. Every app instance is quit by run-walk.py's stop.sh (CEO §54); the
second copy is quit here, by its own pid, before the step ends.
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
QA = HERE.parent / 'qa'
sys.path.insert(0, str(HERE))
from relaunch import guest, relaunch  # noqa: E402

_spec = importlib.util.spec_from_file_location('dictation_walk', HERE / 'dictation-walk.py')
dictation_walk = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(dictation_walk)
StepFailed = dictation_walk.StepFailed


class StepUnproven(Exception):
    """A step whose claim the guest cannot settle: its outcome is UNPROVEN, with the reason and
    the evidence gathered, and the walk goes on to the steps after it."""

    def __init__(self, why, evidence):
        super().__init__(why)
        self.evidence = evidence
command = dictation_walk.command

STEPS = ['identity', 'stage', 'relaunch', 'switch-on', 'mic-prompt', 'ax-prompt', 'granted', 'try-it',
         'refused', 'open-settings', 'second-copy']

# macOS's own words in its two prompts, and Iris's sentence (Info.plist), as OCR fragments that sit on
# one line of a prompt: a wrapped sentence is never one OCR line (setup-walk.py, walk-d33d482c9645).
# Measured on walk-63fc2c726051 (mic-prompt-6.png): the prompt wraps after "would like to access"
# and after "press the talk", and OCR reads "F1" in its small type as "Ft", so no fragment holds the key.
# walk-8f45d498831b (ax-prompt-failed.png): OCR joins the sheet's line under the prompt with its
# title and drops the "w" ("Dictate in any app ould like to control this computer using"), so
# the titles are matched from their middle.
MIC_PROMPT = 'like to access'
IRIS_FRAGMENTS = ('talk instead of typing', 'only after you tap', 'press the talk')
AX_PROMPT = 'control this computer'
# The sheet's drawn words (round 19 and its more lines), read from the accessibility tree. A line
# with the key's cap in it is read by the text run after the cap.
ON_RUN = 'in any app, talk, and tap it again.'
DENIED_LINE = 'Not working yet: macOS has not let me type into other apps.'
OTHER_ROW = 'On even when RichOS is closed'
# The processes macOS has put its privacy prompts in, across releases; the first that answers wins.
PROMPT_PROCESSES = ('UserNotificationCenter', 'universalAccessAuthWarn', 'CoreServicesUIAgent', 'tccd')
USER_DB = '"$HOME/Library/Application Support/com.apple.TCC/TCC.db"'
SYS_DB = '"/Library/Application Support/com.apple.TCC/TCC.db"'
GRANT = ("INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, "
         "indirect_object_identifier_type, indirect_object_identifier, flags, last_modified) "
         "VALUES ('{svc}', 'com.richos.app', 0, 2, 2, 1, 0, 'UNUSED', 0, strftime('%s','now'));")
GRANTED_WITHIN = 2.0


def grant_seconds_ok(seconds):
    """The plan's "within 2 s", read as the walk measures it: from the row's write to the tool's
    key-tap line, each read one ssh round trip, so a reading is an upper bound."""
    return seconds is not None and seconds <= GRANTED_WITHIN + 1.0


class SheetWalk(dictation_walk.DictationWalk):
    def env(self):
        return {'RICHOS_VOICE_INPUT_WAV': self.wav, 'RICHOS_DICTATION_PREVIEW': '1'}

    # --- the guest's screen -----------------------------------------------------------------
    def by_id(self, dom_id):
        try:
            nodes = self.ax('find', '--id', dom_id, '--first')
        except StepFailed as exc:
            if 'notfound' in str(exc) or 'nothing matched' in str(exc) or 'guest_deadline' in str(exc):
                return None
            raise
        nodes = [n for n in nodes if not n.get('meta')]
        return nodes[0] if nodes else None

    def shows_text(self, text):
        try:
            return bool(self.ax('find', '--value', text, '--contains', '--first'))
        except StepFailed as exc:
            if 'notfound' in str(exc) or 'nothing matched' in str(exc) or 'guest_deadline' in str(exc):
                return False
            raise

    def present(self, title, role='AXButton', app=None):
        """adopt-walk's present(), with a read that hit ax.sh's deadline counted as not there yet:
        a relaunched app still building its tree answers nothing in 20 s (walk-918256bab6a4,
        the first run of this walk, failed its relaunch on exactly that)."""
        try:
            return super().present(title, role, app)
        except StepFailed as exc:
            if 'guest_deadline' in str(exc):
                return False
            raise

    def until(self, check, seconds, what):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            if check():
                return True
            time.sleep(1)
        raise StepFailed(f'{what} within {seconds} s')

    def frame_says(self, name, text):
        r = subprocess.run([str(QA / 'ocr-find.sh'), text, str(self.out / name), '--first', '--quiet'],
                           capture_output=True, text=True, timeout=120)
        if r.returncode not in (0, 1):
            raise StepFailed('ocr-find could not read the frame: ' + r.stderr)
        return r.returncode == 0

    def screen_says(self, name, text, seconds):
        """Frames of the guest's screen until OCR reads `text` in one (at most `seconds`)."""
        end, n = time.monotonic() + seconds, 0
        while time.monotonic() < end:
            frame = f'{name}-{n}.png'
            self.shot(frame)
            if self.frame_says(frame, text):
                return frame
            n += 1
            time.sleep(1)
        raise StepFailed(f'OCR did not read "{text}" on the guest screen within {seconds} s (frames {name}-*.png)')

    def open_sheet(self):
        self.ax('click', '--id', 'set-btn', '--first')
        self.until(lambda: self.by_id('set-dictation-open') is not None, 30, 'the Dictation row did not appear')
        self.ax('click', '--id', 'set-dictation-open', '--first')
        self.until(lambda: self.by_id('dict-switch') is not None, 30, 'the Dictation sheet did not open')

    def bring_front(self, pid):
        guest(self.vm, 'osascript -e ' + shlex.quote(
            f'tell application "System Events" to set frontmost of (first process whose unix id is {int(pid)}) to true'))
        time.sleep(1)

    def press_in_prompt(self, title):
        """Press `title` in macOS's prompt through the accessibility tree. The process that owns
        the prompt, or None when no process offered the button."""
        for process in PROMPT_PROCESSES:
            try:
                self.ax('click', '--title', title, '--role', 'AXButton', '--first', app=process)
                return process
            except StepFailed:
                continue
        return None

    def tcc_rows(self):
        # Each row with its auth_value (0 denied, 2 allowed): macOS itself records an app it has
        # checked as a denied row, which is no grant (walk of ee92df2c4, stage).
        query = "SELECT service || '=' || auth_value FROM access WHERE client='com.richos.app' ORDER BY service;"
        return {'user': guest(self.vm, f'sqlite3 {USER_DB} ' + shlex.quote(query)).splitlines(),
                'system': guest(self.vm, f'sudo -n sqlite3 {SYS_DB} ' + shlex.quote(query)).splitlines()}

    def grant(self, service, system):
        db = SYS_DB if system else USER_DB
        guest(self.vm, ('sudo -n ' if system else '') + f'sqlite3 {db} ' + shlex.quote(GRANT.format(svc=service)))

    def revoke(self, service, system):
        db = SYS_DB if system else USER_DB
        sql = f"DELETE FROM access WHERE client='com.richos.app' AND service='{service}';"
        guest(self.vm, ('sudo -n ' if system else '') + f'sqlite3 {db} ' + shlex.quote(sql))

    def post_ax_notice(self):
        """What System Settings does after a person flips an Accessibility switch: post the
        distributed notice "com.apple.accessibility.api", on which a running process drops the
        trust answer it holds (walk-46bb2eac452a: row written as allowed, tccd restarted, and the
        running app still read no for 30 s). Posted in the guest's GUI session, as the user."""
        script = ("ObjC.import('Foundation'); $.NSDistributedNotificationCenter.defaultCenter"
                  ".postNotificationNameObjectUserInfoDeliverImmediately('com.apple.accessibility.api', null, null, true);"
                  " 'posted'")
        return guest(self.vm, 'sudo -n launchctl asuser "$(id -u)" sudo -n -u "$(id -un)" osascript -l JavaScript -e '
                     + shlex.quote(script) + ' 2>&1 || echo refused')

    def tell_tool(self, kind):
        """One line to the tool's socket, as an app connection says it (ipc.rs AppMessage)."""
        code = ("import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); "
                "s.sendall(('{\"type\":\"%s\"}\\n' % sys.argv[2]).encode()); time.sleep(0.5); s.close(); print('told')")
        return guest(self.vm, 'python3 -c ' + shlex.quote(code) + ' "/private/tmp/richos-$(id -u)/dictation.sock" '
                     + shlex.quote(kind) + ' 2>&1 || echo refused')

    def save_dlog(self):
        (self.out / 'dictation.log').write_text('\n'.join(self.dlog_lines()) + '\n')

    def reload_tcc(self, system):
        """tccd answers from what it has already read: a row written behind its back (the walk's
        stand-in for a person's switch in System Settings, which goes through tccd itself) is seen
        once tccd restarts (walk-368bb9a01972: the Accessibility row was written and the app's
        AXIsProcessTrusted still said no for 30 s). Restarts only the guest's tccd, by its
        launchd label; the guest is disposable."""
        label = 'system/com.apple.tccd.system' if system else 'gui/$(id -u)/com.apple.tccd'
        return guest(self.vm, ('sudo -n ' if system else '') + f'launchctl kickstart -k {label} 2>&1 || echo refused')

    def app_log(self):
        return guest(self.vm, 'cat ' + shlex.quote(self.log) + ' 2>/dev/null || true', 30)

    def dlog_lines(self):
        return guest(self.vm, 'cat ' + shlex.quote(self.dlog) + ' 2>/dev/null || true', 30).splitlines()

    def launch(self):
        launched = relaunch(self.vm, environment=self.env())
        self.log = launched['log']
        self.facts.update({'log': self.log, 'app_pid': launched['pid']})
        self.save()
        # The window's tree first: the Settings button is on every screen, sheets or not.
        self.until(lambda: self.by_id('set-btn') is not None, 180, 'the relaunched app drew no Settings button')
        presses = self.decline_first_run_sheets(seconds=30)
        return launched, presses

    # --- steps --------------------------------------------------------------------------------
    def stage(self):
        for service, system in (('kTCCServiceMicrophone', False), ('kTCCServiceAccessibility', True),
                                ('kTCCServiceListenEvent', True), ('kTCCServicePostEvent', True)):
            self.revoke(service, system)
        rows = self.tcc_rows()
        allowed = [r for r in rows['user'] + rows['system'] if r.endswith('=2')]
        if allowed:
            raise StepFailed(f'com.richos.app is still allowed something: {rows}')
        guest(self.vm, 'rm -f ' + shlex.quote(self.data + '/dictation.json'))
        command([HERE / 'guest.sh', self.vm, '--push', self.a.wav, self.wav], 120)
        models = self.home + '/.config/richos/models'
        guest(self.vm, 'mkdir -p ' + shlex.quote(models))
        target = f'{models}/ggml-{self.a.model_id}.bin'
        command([HERE / 'guest.sh', self.vm, '--push', self.a.model, target], 900)
        return {'tcc': rows, 'no_grants': True, 'dictation_json': 'absent', 'wav': self.wav, 'model': target}

    def relaunch(self):
        launched, presses = self.launch()
        return {'app_pid': launched['pid'], 'first_run_sheets_declined': presses}

    def switch_on(self):
        self.open_sheet()
        self.shot('sheet-off.png')
        off = self.shows_text('Off. Turn it on to type with your voice')
        self.ax('click', '--id', 'dict-switch', '--first')
        return {'sheet_said_off_first': off}

    def mic_prompt(self):
        frame = self.screen_says('mic-prompt', MIC_PROMPT, 30)
        iris = {fragment: self.frame_says(frame, fragment) for fragment in IRIS_FRAGMENTS}
        if not all(iris.values()):
            raise StepFailed(f'OCR did not read Iris\'s sentence in the microphone prompt ({frame}): {iris}')
        pressed_in = self.press_in_prompt('Allow')
        fallback = None
        if pressed_in is None:
            # Minor 8's fallback, said in the report: no process offered Allow, so the row is written.
            self.grant('kTCCServiceMicrophone', False)
            fallback = 'no process in the accessibility tree offered Allow; the Microphone row was written instead'
        self.facts['mic_frame'] = frame
        self.save()
        return {'frame': frame, 'iris_sentence_ocr': iris, 'allow_pressed_in': pressed_in, 'fallback': fallback}

    def ax_prompt(self):
        frame = self.screen_says('ax-prompt', AX_PROMPT, 30)
        mic_line = [x for x in self.app_log().splitlines() if 'dictation: the microphone was' in x]
        return {'frame': frame, 'mic_answer_in_log': mic_line[-1:] or None, 'tcc': self.tcc_rows()}

    def granted(self):
        """Accessibility allowed while the app runs: the tool's key tap and the sheet's On, with
        no relaunch, within 2 s. The walk's grant is a row written into the guest's TCC.db; a
        person's switch in System Settings goes through tccd, which tells running processes.
        A running process does not read a row written behind tccd's back (walks 368bb9a01972,
        46bb2eac452a, b257f16e0001, 72c807eaccab: row allowed, tccd restarted, System Settings'
        notice posted, the tool told directly, and the running tool still read no; tccd logged no
        Accessibility question from the app for 30 s, so the answer comes from inside the
        process). So: the live answer is tried first and timed (the row; then tccutil's reset,
        which tccd announces, with the row straight after); if it does not come, the step
        says UNPROVEN and why, relaunches with the grant in place, and proves the sheet's On
        and the key tap from there, so the steps after it still run."""
        pid_before = self.facts['app_pid']
        taps_before = sum('key tap created for F1' in x for x in self.dlog_lines())
        self.grant('kTCCServiceAccessibility', True)
        noticed = self.post_ax_notice()
        written = time.monotonic()
        row_after_write = self.tcc_rows()['system']

        def tap_within(since, seconds):
            while time.monotonic() - since < seconds:
                if sum('key tap created for F1' in x for x in self.dlog_lines()) > taps_before:
                    return round(time.monotonic() - since, 2)
                time.sleep(0.2)
            return None

        seen, clock_from = tap_within(written, 5), 'row write'
        if seen is None:
            # A change tccd itself announces: tccutil's reset goes through tccd, which publishes it
            # to running processes as System Settings' switch does, and the allowed row is written
            # straight after it, so the process's next question reads it.
            reset_sql = shlex.quote(GRANT.format(svc='kTCCServiceAccessibility'))
            guest(self.vm, f'sudo -n tccutil reset Accessibility com.richos.app >/dev/null 2>&1; sudo -n sqlite3 {SYS_DB} {reset_sql}')
            row_after_write = self.tcc_rows()['system']
            seen, clock_from = tap_within(time.monotonic(), 5), 'tccutil reset, then the row'
        if seen is not None:
            on = self.until(lambda: self.shows_text(ON_RUN), 15, 'the sheet did not say On')
            dismissed_in = self.press_in_prompt('Deny')  # the prompt macOS left up
            self.grant('kTCCServiceAccessibility', True)  # whatever the prompt's button wrote
            pid_now = guest(self.vm, f'kill -0 {int(pid_before)} 2>/dev/null && echo alive || true')
            if pid_now != 'alive':
                raise StepFailed(f'the app (pid {pid_before}) is gone: the sheet must say On with no relaunch')
            self.shot('sheet-on.png')
            if not grant_seconds_ok(seen):
                raise StepFailed(f'the key tap came {seen} s after the Accessibility row, not within {GRANTED_WITHIN} s')
            return {'key_tap_after_row_seconds': seen, 'clock_from': clock_from, 'sheet_says_on': on, 'same_app_pid': pid_before,
                    'notice': noticed, 'row_after_write': row_after_write, 'prompt_dismissed_in': dismissed_in,
                    'tcc': self.tcc_rows()}

        # Not seen live. Evidence first, then the relaunch.
        self.shot('granted-unseen.png')
        lines_before = len(self.dlog_lines())
        told = self.tell_tool('permissions-changed')
        time.sleep(3)
        probe = self.dlog_lines()[lines_before:]
        tcc_log = guest(self.vm, "/usr/bin/log show --last 2m --style compact --predicate "
                                 + shlex.quote('subsystem == "com.apple.TCC" AND eventMessage CONTAINS[c] "richos"')
                                 + " 2>&1 | tail -300 || true", 120)
        (self.out / 'tcc-answers.log').write_text(tcc_log)
        dismissed_in = self.press_in_prompt('Deny')  # the prompt macOS left up
        self.grant('kTCCServiceAccessibility', True)  # whatever the prompt's button wrote
        self.reload_tcc(True)
        launched, presses = self.launch()
        self.open_sheet()
        relaunched_tap = tap_within(time.monotonic(), 60)
        if relaunched_tap is None:
            raise StepFailed('with the grant in place and a relaunch, the tool still made no key tap')
        on = self.until(lambda: self.shows_text(ON_RUN), 30, 'after the relaunch the sheet did not say On')
        self.shot('sheet-on-after-relaunch.png')
        raise StepUnproven(
            'the sheet\'s On with no relaunch is not proven in the guest: the walk\'s grant (a row written into '
            'TCC.db) never reaches a running RichOS; after a relaunch the tool made its key tap and the sheet says On',
            {'live_wait_seconds': 5, 'row_after_write': row_after_write, 'notice': noticed, 'told_tool': told,
             'tool_answered': probe, 'prompt_dismissed_in': dismissed_in, 'relaunched_pid': launched['pid'],
             'first_run_sheets_declined': len(presses or []), 'sheet_says_on_after_relaunch': on,
             'tcc': self.tcc_rows()})

    def try_it(self):
        pid = self.facts['app_pid']
        self.bring_front(pid)
        self.ax('click', '--id', 'dict-try', '--first')
        row = self.dictate('122', 'com.richos.app', 'clipboard-before-try-it')
        node = self.by_id('dict-try') or {}
        text = node.get('value') or node.get('title') or ''
        self.expect_words(text, row['expected'], 'Try it here')
        self.shot('try-it.png')
        return {'dictation': row, 'try_it_text': text}

    def refused(self):
        self.revoke('kTCCServiceAccessibility', True)
        self.reload_tcc(True)
        self.post_ax_notice()
        launched, presses = self.launch()
        self.open_sheet()
        self.until(lambda: self.shows_text(DENIED_LINE), 30, 'the sheet did not say the denied line')
        button = self.by_id('dict-switch') is not None and self.present('Open System Settings')
        if not button:
            raise StepFailed('Open System Settings is not beside the denied line')
        self.shot('denied.png')
        return {'app_pid': launched['pid'], 'denied_line': DENIED_LINE, 'open_system_settings': True, 'tcc': self.tcc_rows()}

    def open_settings(self):
        self.press('Open System Settings')
        end = time.monotonic() + 30
        front = None
        while time.monotonic() < end:
            front = self.front_bundle()
            if front == 'com.apple.systempreferences':
                break
            time.sleep(1)
        if front != 'com.apple.systempreferences':
            raise StepFailed(f'System Settings did not come to the front: {front}')
        time.sleep(2)
        windows = guest(self.vm, 'osascript -e ' + shlex.quote(
            'tell application "System Events" to get name of windows of process "System Settings"'))
        self.shot('system-settings.png')
        if 'Accessibility' not in windows:
            raise StepFailed(f'System Settings is not on Accessibility: {windows!r}')
        guest(self.vm, 'osascript -e ' + shlex.quote('tell application "System Settings" to quit'))
        return {'front': front, 'windows': windows}

    def second_copy(self):
        self.grant('kTCCServiceAccessibility', True)
        self.reload_tcc(True)
        self.post_ax_notice()
        first_pid = self.facts['app_pid']
        app = guest(self.vm, 'find ' + shlex.quote(self.payload) + ' -maxdepth 1 -name "*.app" -type d -print').splitlines()[0]
        second_dir, home2 = self.payload + '/second', self.payload + '/home2'
        second = second_dir + '/' + Path(app).name
        guest(self.vm, f'rm -rf {shlex.quote(second_dir)} {shlex.quote(home2)} && mkdir -p {shlex.quote(second_dir)} '
                       f'&& cp -Rc {shlex.quote(app)} {shlex.quote(second)} && cp -Rc {shlex.quote(self.home)} {shlex.quote(home2)}', 300)
        env = {'HOME': home2, 'CLAUDE_CONFIG_DIR': home2 + '/.claude', 'RICHOS_ACTIVATION': 'regular',
               'RICHOS_CLAUDE_BIN': '/Users/admin/.local/bin/claude', 'DISABLE_AUTOUPDATER': '1',
               'RICHOS_ENGINE_DIR': self.payload + '/engine', 'RICHOS_DICTATION_TEST_ON': '1', **self.env()}
        log2 = self.payload + f'/second-{time.time_ns()}.log'
        argv = ['open', '-n', '-a', second]
        for key, value in env.items():
            argv += ['--env', f'{key}={value}']
        argv += ['--stdout', log2, '--stderr', log2]
        guest(self.vm, shlex.join(argv))
        pid2 = None
        for _ in range(100):
            for line in guest(self.vm, 'ps -axo pid=,ppid=,comm=').splitlines():
                parts = line.split(None, 2)
                if len(parts) == 3 and parts[1] == '1' and parts[2].startswith(second_dir) and parts[2].endswith('/richos-tauri'):
                    pid2 = int(parts[0])
            if pid2:
                break
            time.sleep(0.2)
        if not pid2:
            raise StepFailed('the second copy did not start')
        state = Path(self.state_file('app.pid'))
        try:
            text2 = ''
            end = time.monotonic() + 60
            while time.monotonic() < end:
                text2 = guest(self.vm, 'cat ' + shlex.quote(log2) + ' 2>/dev/null || true', 30)
                if 'ended: exit status: 3' in text2 and 'connected to the tool' in text2:
                    break
                time.sleep(1)
            if 'ended: exit status: 3' not in text2:
                raise StepFailed('the second copy\'s tool did not find the key taken (exit 3); its log:\n' + text2[-3000:])
            # ax.sh drives the app whose pid run-walk recorded: the second copy, for this read only.
            state.write_text(f'{pid2}\n')
            self.decline_first_run_sheets(seconds=20)
            self.bring_front(pid2)
            self.ax('click', '--id', 'set-btn', '--first')
            self.until(lambda: self.by_id('set-dictation-open') is not None, 30, 'the second copy has no Dictation row')
            row = self.by_id('set-dictation-state') or {}
            row_text = row.get('value') or row.get('title') or ''
            if OTHER_ROW not in row_text and not self.shows_text(OTHER_ROW):
                raise StepFailed(f'the second copy\'s row does not say "{OTHER_ROW}": {row!r}')
            self.shot('second-copy-row.png')
            self.ax('click', '--id', 'set-dictation-open', '--first')
            self.until(lambda: self.shows_text(OTHER_ROW + '.'), 30, 'the second copy\'s sheet does not say it')
            self.shot('second-copy-sheet.png')
        finally:
            state.write_text(f'{first_pid}\n')
            guest(self.vm, f'kill -TERM {int(pid2)} 2>/dev/null || true')
        end = time.monotonic() + 10
        while time.monotonic() < end and guest(self.vm, f'kill -0 {int(pid2)} 2>/dev/null && echo alive || true') == 'alive':
            time.sleep(0.2)
        gone = guest(self.vm, f'kill -0 {int(pid2)} 2>/dev/null && echo alive || true') != 'alive'
        if not gone:
            raise StepFailed(f'the second copy (pid {pid2}) did not quit')
        return {'second_pid': pid2, 'second_tool_exit': 3, 'row': OTHER_ROW, 'sheet': OTHER_ROW + '.', 'second_quit': True,
                'first_pid': first_pid}


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('vm')
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--expect-sha', required=True, help='the commit the bundle under test was built from')
    p.add_argument('--wav', type=Path, required=True, help='a short spoken sample, 16 kHz mono WAV (say -o, then afconvert)')
    p.add_argument('--model', type=Path, required=True, help='the GGML weights to copy in, matching --model-id')
    p.add_argument('--model-id', default='small.en')
    p.add_argument('--steps', default=','.join(STEPS))
    a = p.parse_args()
    # DictationWalk's helpers read these; this walk posts no top-row event and runs no probe.
    a.post_key = a.key_probe = None
    a.idle = 0
    steps = a.steps.split(',')
    unknown = [s for s in steps if s not in STEPS]
    if unknown:
        p.error('unknown step(s): ' + ', '.join(unknown))
    walk = SheetWalk(a)
    report = {'vm': a.vm, 'expect_sha': a.expect_sha, 'steps': []}
    ok = True
    unproven = False
    for step in steps:
        began = time.monotonic()
        row = {'step': step}
        try:
            row['evidence'] = getattr(walk, step.replace('-', '_'))()
            row['outcome'] = 'PASS'
        except StepUnproven as exc:
            row['outcome'] = 'UNPROVEN'
            row['detail'] = str(exc)
            row['evidence'] = exc.evidence
            unproven = True
        except (StepFailed, RuntimeError, ValueError, KeyError, IndexError, subprocess.TimeoutExpired) as exc:
            row['outcome'] = 'FAIL'
            row['detail'] = str(exc)
            ok = False
        row['seconds'] = round(time.monotonic() - began, 1)
        report['steps'].append(row)
        (a.out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        print(f"{step}: {row['outcome']}" + (f" — {row.get('detail')}" if row['outcome'] != 'PASS' else ''), flush=True)
        if not ok:
            try:
                walk.shot(f'{step}-failed.png')
                (a.out / 'app.log.tail').write_text(guest(a.vm, 'tail -80 ' + shlex.quote(walk.log) + ' || true', 30))
                (a.out / 'dictation.log').write_text(guest(a.vm, 'cat ' + shlex.quote(walk.dlog) + ' 2>/dev/null || true', 30))
            except Exception as exc:  # evidence only; the step already failed
                (a.out / 'evidence-error.txt').write_text(str(exc))
            break
    # 2: every step that could be settled passed, and at least one could not be.
    return 1 if not ok else 2 if unproven else 0


if __name__ == '__main__':
    sys.exit(main())
