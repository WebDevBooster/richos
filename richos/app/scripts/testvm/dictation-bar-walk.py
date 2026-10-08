#!/usr/bin/env python3
"""dictation-bar-walk.py — the bar, the words' flight and the menu bar item (dictation plan slice 3).

Run by run-walk.py, which holds one guest slot for this run only, boots the guest and removes the clone:

  run-walk.py --bundle ZIP --home EMPTY_DIR --engine ENGINE --report REPORT -- \\
      dictation-bar-walk.py --out DIR --expect-sha SHA --wav SPOKEN.wav --long-wav LONG.wav \\
          --silent-wav SILENT.wav --model SMALL.bin [--accurate-model LARGE.bin] \\
          --post-key POST_KEY --key-probe KEY_PROBE [--steps a,b,c]

THE QUESTION. The CEO approved round 19 on 2026-10-08 ("it all looks awesome"); slice 3 of
richos-hq/docs/plans/2026-10-08-dictation-anywhere.md (revision 2, section 9) builds its states 13
to 19 and Iris's two bar lines: the bar over any app, the words' flight, the menu bar item and
its menu. This walk is that slice's proof, and its first two steps are the window check the plan
puts before any bar code (Frank's minor 3).

WHAT IT DOES, in the guest, never on the host's screen (CEO ruling §65). The app is started with
`open -n -a` (relaunch.py), the dictation tool is the app's child (slices 1 to 4). No sound is
played anywhere (CEO §53): the samples are files (`say -o`), put through the identical capture
path by RICHOS_VOICE_INPUT_WAV, and the walk swaps which file sits at that path between
dictations (each capture opens it afresh). Frames are taken in the guest with `screencapture` at
the moment they are needed and read with the guest's tesseract.
  identity       the running app says it was built from --expect-sha
  stage          (dictation-walk.py) Microphone and Accessibility rows only; the samples and models in
  check-window   THE WINDOW CHECK, plain window type: a held Fix it bar over a full-screen
                 TextEdit (read off a frame), a first click on Fix it (does it arrive, does the
                 front app stay TextEdit), and the menu opened from the item and closed with Escape
                 (does the front app stay TextEdit)
  check-panel    the same, nonactivating panel type
  relaunch       the app relaunched with the test switch on, the build's own window type
  settle         (dictation-walk.py) the app's voice readiness has finished
  frames         one dictation into TextEdit with frames of listening, writing and added; the
                 words' flight logged; `lsappinfo front` sampled every 250 ms names TextEdit
  fullscreen     the bar over a full-screen TextEdit, read off a frame; the words land
  menu           the menu from the item, Faster chosen with the keyboard, Escape: TextEdit in
                 front again, and the next dictation's log line names small.en and lands at the
                 same cursor
  nofield        the desktop in front (Finder, no window): the copied line, read off a frame
  nosound        a silent sample: the no-sound line, read off a frame, nothing pasted
  apps           (dictation-walk.py) a Chromium or Electron app present
  chromium       one dictation into the Chromium app's text box; whether the words flew
  window-closed  CHILD MODE (lead, esc-20261008T072600Z-d94d767e): the app's window closed with
                 dictation on quits the app exactly as with dictation off, and the tool ends with
                 it within a second. The tool outliving the app is slice 5's (dictation-login-walk.py).
  accuracy-mid   (review finding 6, 2026-10-08) Faster chosen from the menu WHILE a dictation
                 listens: that dictation's log line still names the model chosen when it began,
                 and the next dictation's names small.en; then More accurate is put back

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

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from relaunch import guest, relaunch  # noqa: E402

_spec = importlib.util.spec_from_file_location('dictation_walk', HERE / 'dictation-walk.py')
dictation_walk = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(dictation_walk)
StepFailed = dictation_walk.StepFailed
command = dictation_walk.command
words_of = dictation_walk.words_of

STEPS = ['identity', 'stage', 'check-window', 'check-panel', 'relaunch', 'settle', 'frames', 'fullscreen', 'menu',
         'nofield', 'nosound', 'apps', 'chromium', 'window-closed', 'accuracy-mid']
TEXTEDIT = 'com.apple.TextEdit'
# The bar's drawn lines as the guest's tesseract should find them (a fragment of each, so a
# line break or an apostrophe read as a quote does not decide the step).
READ = {
    'no-microphone': 'need the microphone to hear you',
    'listening': 'Listening',
    'writing': 'Writing it down',
    'added': 'Added',
    'no-text-box': 'No text box was selected',
    'no-sound': 'hear anything',
}
BAR_SHOWN = re.compile(r'bar shown: (\S+(?: \S+)?) at (-?\d+),(-?\d+) (\d+)x(\d+)(?:; Fix it at (-?\d+),(-?\d+) (\d+)x(\d+))?')
FULLSCREEN = 'tell application "System Events" to tell process "TextEdit" to set value of attribute "AXFullScreen" of window 1 to {on}'
IS_FULLSCREEN = 'tell application "System Events" to tell process "TextEdit" to get value of attribute "AXFullScreen" of window 1'


def bar_shown(line):
    """A `bar shown:` line of dictation.log: what, where, and Fix it's box."""
    m = BAR_SHOWN.search(line)
    if not m:
        return None
    out = {'view': m.group(1), 'frame': [int(m.group(i)) for i in range(2, 6)]}
    if m.group(6) is not None:
        out['fix'] = [int(m.group(i)) for i in range(6, 10)]
    return out


def center(box):
    x, y, w, h = box
    return (x + w / 2.0, y + h / 2.0)


# The menu bar's band in top-left points (menubar.rs MENU_BAR_BAND): a logged item rectangle
# outside it is the unplaced frame Tauri reported before the run loop placed the item (walks
# 5028f74bc8b6 and 7bdbf43a6228 logged 0,1050 34x24), and the item is found through System
# Events instead.
# Seconds a fresh tool gets before its menu bar item is pressed (walk-c409831e46f9).
FRESH_TOOL_SETTLE = 8.0

MENU_BAR_BAND =100.0


def item_placed(rect):
    x, y, w, h = rect
    return w > 0 and h > 0 and 0 <= y < MENU_BAR_BAND


def read_contains(ocr, fragment):
    """OCR reads straight and curly quotes and spacing loosely; compare letters only."""
    squash = lambda s: re.sub(r'[^a-z]', '', s.lower())
    return squash(fragment) in squash(ocr)


class BarWalk(dictation_walk.DictationWalk):
    def __init__(self, a):
        super().__init__(a)
        self.spoken = self.home + '/dictation-spoken.wav'
        self.long = self.home + '/dictation-long.wav'
        self.silent = self.home + '/dictation-silent.wav'
        self.frames_dir = self.payload + '/frames'

    # --- helpers ------------------------------------------------------------------------------
    def dlog_lines(self):
        return guest(self.vm, 'cat ' + shlex.quote(self.dlog) + ' 2>/dev/null || true', 30).splitlines()

    def wait_dlog(self, pattern, since, seconds=30):
        """The first dictation.log line after line `since` that contains `pattern`."""
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            lines = self.dlog_lines()
            for line in lines[since:]:
                if pattern in line:
                    return line
            time.sleep(0.25)
        tail = '\n'.join(self.dlog_lines()[-20:])
        raise StepFailed(f'dictation.log never said "{pattern}" within {seconds} s; its tail:\n{tail}')

    def grab(self, name):
        """A frame of the guest's screen NOW (screencapture in the guest, under its home, where its
        tesseract can read it); pulled to --out and read later by `read`."""
        guest(self.vm, 'mkdir -p ' + shlex.quote(self.frames_dir) + ' && screencapture -x -t png ' +
              shlex.quote(f'{self.frames_dir}/{name}.png'))
        return name

    def read(self, name, box=None):
        """The frame's text by the guest's tesseract; with `box` (a bar's logged frame, x, y, w, h
        in points, which are this guest's pixels), that region too, cut out and enlarged 3x:
        walk-5028f74bc8b6's added.png showed "Added" plainly and the whole-screen read missed the
        short word on the light pill."""
        path = f'{self.frames_dir}/{name}.png'
        command([HERE / 'guest.sh', self.vm, '--pull', path, str(self.out / f'{name}.png')], 120)
        text = guest(self.vm, '/opt/homebrew/bin/tesseract ' + shlex.quote(path) + ' - 2>/dev/null || true', 120)
        if box:
            # The pill's words only: right of its orb (the page's 40 px of room, 9 px of padding,
            # the 40 px orb and its gap), the pill's own 58 px height below the 24 px of room
            # (ui/dictation-bar.js PAD_X, PAD_TOP; dictation-overlay.css .dh). With the orb in the
            # crop, tesseract read nothing of "Added"; without it, "Added" (walk-5028f74bc8b6).
            x, y, w, h = box[0] + 96, box[1] + 24, max(60, box[2] - 136), 58
            crop = f'{self.frames_dir}/{name}-bar.png'
            guest(self.vm, f'sips --cropOffset {int(y)} {int(x)} -c {int(h)} {int(w)} {shlex.quote(path)} --out {shlex.quote(crop)} '
                           f'>/dev/null && sips -z {int(h) * 3} {int(w) * 3} {shlex.quote(crop)} >/dev/null', 60)
            text += '\n' + guest(self.vm, '/opt/homebrew/bin/tesseract ' + shlex.quote(crop) + ' - 2>/dev/null || true', 120)
        return text

    def expect_read(self, name, fragment, box=None):
        text = self.read(name, box)
        if not read_contains(text, fragment):
            raise StepFailed(f'frame {name}.png does not read "{fragment}"; it reads: {text[:400]!r}')
        return f'{name}.png reads "{fragment}"'

    def wait_delivered(self, before, seconds=60):
        """Until capture.rs says the injected sample has gone downstream once more than `before`."""
        end = time.monotonic() + seconds
        while self.samples_delivered() <= before:
            if time.monotonic() > end:
                raise StepFailed(f'the sample was not delivered within {seconds} s of the first tap')
            time.sleep(0.2)

    def use_sample(self, path):
        guest(self.vm, f'cp {shlex.quote(path)} {shlex.quote(self.wav)}')

    def key(self, code):
        guest(self.vm, 'osascript -e ' + shlex.quote(f'tell application "System Events" to key code {int(code)}'))

    def click(self, x, y):
        guest(self.vm, shlex.quote(self.post_key) + f' --click {x:.0f},{y:.0f}')

    def osa(self, script, timeout=40):
        return guest(self.vm, 'osascript -e ' + shlex.quote(script), timeout)

    def textedit_text(self):
        nodes = [n for n in self.ax('find', '--role', 'AXTextArea', '--first', app='TextEdit') if n.get('role') == 'AXTextArea']
        return nodes[0].get('value', '') if nodes else ''

    def open_textedit(self, path):
        guest(self.vm, f': > {shlex.quote(path)} && open -a TextEdit {shlex.quote(path)}')
        time.sleep(3)
        if self.front_bundle() != TEXTEDIT:
            raise StepFailed(f'TextEdit is not in front: {self.front_bundle()}')

    def item_center(self):
        """The menu bar item's center: from the tool's own log line (menubar.rs `item_rect`), or
        else from the tool's process in System Events."""
        logged = [line for line in self.dlog_lines() if 'menu bar item at ' in line]
        if logged:
            n = [float(v) for v in re.findall(r'-?\d+', logged[-1].split('menu bar item at ', 1)[1])][:4]
            if len(n) == 4 and item_placed(n):
                return (n[0] + n[2] / 2, n[1] + n[3] / 2), {'from': 'dictation.log', 'rect': n}
        tool = self.tool_pids()
        if len(tool) != 1:
            raise StepFailed(f'not exactly one dictation tool: {tool}')
        for bar in (2, 1):
            script = (f'tell application "System Events" to tell (first process whose unix id is {tool[0]["pid"]}) to '
                      f'get {{position, size}} of menu bar item 1 of menu bar {bar}')
            try:
                out = self.osa(script)
            except RuntimeError:
                continue
            n = [float(v) for v in re.findall(r'-?\d+(?:\.\d+)?', out)]
            if len(n) == 4:
                return (n[0] + n[2] / 2, n[1] + n[3] / 2), {'menu_bar': bar, 'position': n[:2], 'size': n[2:]}
        raise StepFailed('the dictation tool has no menu bar item System Events can see')

    def wait_tool(self, seconds=60):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            text = guest(self.vm, 'cat ' + shlex.quote(self.log) + ' 2>/dev/null || true', 30)
            if 'key tap created for F1' in text and 'connected to the tool' in text and len(self.tool_pids()) == 1:
                return self.tool_pids()[0]
            time.sleep(1)
        raise StepFailed('the tool did not start, take the key and connect within 60 s')

    # --- steps --------------------------------------------------------------------------------
    def stage(self):
        out = super().stage()
        for local, remote in ((self.a.wav, self.spoken), (self.a.long_wav, self.long), (self.a.silent_wav, self.silent)):
            command([HERE / 'guest.sh', self.vm, '--push', local, remote], 120)
        if self.a.accurate_model:
            target = f'{self.home}/.config/richos/models/ggml-large-v3-turbo-q5_0.bin'
            command([HERE / 'guest.sh', self.vm, '--push', self.a.accurate_model, target], 1200)
            out['accurate_model'] = target
        out['samples'] = {'spoken': self.spoken, 'long': self.long, 'silent': self.silent}
        return out

    def check(self, kind):
        """THE WINDOW CHECK for one window type. Evidence, never a failure: the two types are
        compared, and `decide` says which passed both."""
        since = len(self.dlog_lines())
        launched = relaunch(self.vm, environment={'RICHOS_VOICE_INPUT_WAV': self.wav, 'RICHOS_DICTATION_TEST_ON': '1',
                                                  'RICHOS_DICTATION_WINDOW': kind, 'RICHOS_DICTATION_PREVIEW': 'no-microphone'})
        self.log = launched['log']
        self.facts['log'] = self.log
        self.facts['app_pid'] = launched['pid']
        self.save()
        built = self.wait_dlog(f'built as the {kind} type', since, 60)
        shown = bar_shown(self.wait_dlog('bar shown: problem no-microphone', since, 60))
        ev = {'kind': kind, 'built': built.split(' ', 1)[-1], 'bar': shown}
        self.open_textedit('/tmp/dictation-check.txt')
        self.osa(FULLSCREEN.format(on='true'))
        time.sleep(5)
        ev['fullscreen'] = self.osa(IS_FULLSCREEN) == 'true'
        ev['front_before'] = self.front_bundle()
        self.grab(f'check-{kind}-fullscreen')
        ev['bar_over_fullscreen'] = read_contains(self.read(f'check-{kind}-fullscreen'), READ['no-microphone'])
        mark = len(self.dlog_lines())
        if shown and shown.get('fix'):
            x, y = center(shown['fix'])
            self.click(x, y)
            time.sleep(3)
            pressed = [line for line in self.dlog_lines()[mark:] if 'Fix it pressed' in line]
            ev['fix_click'] = {'at': [round(x), round(y)], 'delivered': bool(pressed), 'log': pressed[-1:] }
        else:
            ev['fix_click'] = {'delivered': False, 'why': 'the bar logged no Fix it box'}
        ev['front_after_click'] = self.front_bundle()
        ev['fullscreen_after_click'] = self.osa(IS_FULLSCREEN) == 'true'
        self.grab(f'check-{kind}-after-click')
        self.read(f'check-{kind}-after-click')
        self.osa(FULLSCREEN.format(on='false'))
        time.sleep(4)
        try:
            (ix, iy), item = self.item_center()
            mark = len(self.dlog_lines())
            self.click(ix, iy)
            opened = self.wait_dlog('menu shown at', mark, 10)
            time.sleep(0.5)
            ev['menu'] = {'item': item, 'shown': opened.split(' ', 1)[-1], 'front_while_open': self.front_bundle()}
            self.grab(f'check-{kind}-menu')
            ev['menu']['reads_faster'] = read_contains(self.read(f'check-{kind}-menu'), 'Faster')
            self.key(53)  # Escape
            closed = self.wait_dlog('menu closed', mark, 10)
            time.sleep(0.5)
            ev['menu']['closed'] = closed.split(' ', 1)[-1]
            ev['menu']['front_after_close'] = self.front_bundle()
        except (StepFailed, RuntimeError) as exc:
            ev['menu'] = {'error': str(exc)}
        menu = ev.get('menu', {})
        ev['passes'] = {
            'bar_over_fullscreen': bool(ev['fullscreen'] and ev['bar_over_fullscreen']),
            'first_click_on_fix_it': bool(ev['fix_click'].get('delivered') and ev['front_after_click'] == TEXTEDIT),
            'menu_keeps_the_front': menu.get('front_while_open') == TEXTEDIT and menu.get('front_after_close') == TEXTEDIT,
        }
        ev['passes_both'] = ev['passes']['bar_over_fullscreen'] and ev['passes']['first_click_on_fix_it']
        self.facts.setdefault('check', {})[kind] = ev
        self.save()
        return ev

    def check_window(self):
        return self.check('window')

    def check_panel(self):
        return self.check('panel')

    def frames(self):
        self.open_textedit('/tmp/dictation-bar.txt')
        self.use_sample(self.long)
        sampler = self.sample_front()
        since = len(self.dlog_lines())
        self.press('122')
        listening = bar_shown(self.wait_dlog('bar shown: listening', since, 20))
        time.sleep(1.5)
        self.grab('listening')
        # The long sample is the spoken one and then quiet room noise: the words are in by now.
        time.sleep(4)
        self.press('122')
        self.grab('writing')
        writing = bar_shown(self.wait_dlog('bar shown: writing', since, 20))
        added_line = self.wait_dlog('bar shown: added', since, dictation_walk.DICTATION_WITHIN)
        self.grab('added')
        added = bar_shown(added_line)
        line = self.wait_dlog('dictation: model ', since, 30)
        if 'pasted' not in line:
            raise StepFailed(f'the dictation did not paste: {line}')
        flew = [x for x in self.dlog_lines()[since:] if 'the words flew to' in x]
        time.sleep(2)
        self.stop_front(sampler)
        time.sleep(0.5)
        fronts = self.front_samples(sampler)
        others = sorted(set(f for f in fronts if f != TEXTEDIT))
        if not fronts or others:
            raise StepFailed(f'lsappinfo front was not TextEdit throughout: {len(fronts)} samples, others {others}')
        reads = [self.expect_read('listening', READ['listening'], listening and listening['frame']),
                 self.expect_read('writing', READ['writing'], writing and writing['frame']),
                 self.expect_read('added', READ['added'], added and added['frame'])]
        text = self.textedit_text()
        if not words_of(text):
            raise StepFailed('TextEdit received no words')
        self.facts['frames_text'] = text
        self.save()
        if not flew:
            raise StepFailed('the words did not fly: TextEdit gave Accessibility no rectangle for them')
        return {'bars': {'listening': listening, 'writing': writing, 'added': added}, 'reads': reads, 'log': line,
                'flight': flew[-1].split(' ', 1)[-1], 'front_samples': len(fronts), 'textedit': text}

    def fullscreen(self):
        self.use_sample(self.spoken)
        guest(self.vm, 'open -a TextEdit /tmp/dictation-bar.txt')
        time.sleep(2)
        self.osa(FULLSCREEN.format(on='true'))
        time.sleep(5)
        if self.osa(IS_FULLSCREEN) != 'true':
            raise StepFailed('TextEdit did not go full screen')
        since = len(self.dlog_lines())
        delivered_before = self.samples_delivered()
        self.press('122')
        shown = bar_shown(self.wait_dlog('bar shown: listening', since, 20))
        self.grab('fullscreen-listening')
        self.wait_delivered(delivered_before)
        self.press('122')
        line = self.wait_dlog('dictation: model ', since, dictation_walk.DICTATION_WITHIN)
        front = self.front_bundle()
        still = self.osa(IS_FULLSCREEN) == 'true'
        read = self.expect_read('fullscreen-listening', READ['listening'], shown and shown['frame'])
        self.osa(FULLSCREEN.format(on='false'))
        time.sleep(4)
        if 'pasted' not in line or front != TEXTEDIT or not still:
            raise StepFailed(f'over full screen: {line}; front {front}; still full screen {still}')
        return {'bar': shown, 'read': read, 'log': line, 'front': front, 'stayed_full_screen': still}

    def bar_document(self):
        """The TextEdit document the frames step writes into, opened; made empty when a run
        without that step has none (the first run of the five open steps, walk-cf87b06695ad)."""
        guest(self.vm, 'test -f /tmp/dictation-bar.txt || : > /tmp/dictation-bar.txt; open -a TextEdit /tmp/dictation-bar.txt')
        time.sleep(2)

    def menu(self):
        self.use_sample(self.spoken)
        self.bar_document()
        before = self.textedit_text()
        (ix, iy), item = self.item_center()
        since = len(self.dlog_lines())
        self.click(ix, iy)
        shown = self.wait_dlog('menu shown at', since, 10)
        time.sleep(0.6)
        front_open = self.front_bundle()
        self.grab('menu')
        self.key(125)  # down arrow: from More accurate to Faster
        self.key(49)   # space presses the focused row
        chosen = self.wait_dlog('accuracy set to small.en', since, 10)
        self.key(53)   # Escape
        closed = self.wait_dlog('menu closed', since, 10)
        time.sleep(0.6)
        front_after = self.front_bundle()
        reads = [self.expect_read('menu', 'More accurate'), self.expect_read('menu', 'Open RichOS')]
        if front_open != TEXTEDIT or front_after != TEXTEDIT:
            raise StepFailed(f'the menu took the front: {front_open} while open, {front_after} after')
        row = self.dictate('122', TEXTEDIT, 'clipboard-before-menu')
        if row['model'] != 'small.en':
            raise StepFailed(f'the dictation after Faster used {row["model"]}')
        after = self.textedit_text()
        if not after.startswith(before) or words_of(after[len(before):]) != words_of(row['expected']):
            raise StepFailed(f'the words did not land at the same cursor: {before!r} then {after!r}')
        return {'item': item, 'shown': shown.split(' ', 1)[-1], 'chosen': chosen.split(' ', 1)[-1], 'closed': closed.split(' ', 1)[-1],
                'front_while_open': front_open, 'front_after_close': front_after, 'reads': reads, 'next_dictation': row,
                'textedit_after': after}

    def nofield(self):
        self.use_sample(self.spoken)
        # The desktop in front through System Events, the one app the session may drive
        # (dictation-walk.osa): an Apple event to Finder itself puts up a consent prompt nobody
        # answers (walk-d94269c3a41c, nofield: 40 s timeout under "sshd-keygen-wrapper wants
        # access to control Finder").
        self.osa('tell application "System Events" to set frontmost of process "Finder" to true')
        time.sleep(2)
        front = self.front_bundle()
        since = len(self.dlog_lines())
        delivered_before = self.samples_delivered()
        self.press('122')
        self.wait_delivered(delivered_before)
        self.press('122')
        shown = self.wait_dlog('bar shown: problem no-text-box', since, dictation_walk.DICTATION_WITHIN)
        self.grab('no-text-box')
        line = self.wait_dlog('dictation: model ', since, 30)
        read = self.expect_read('no-text-box', READ['no-text-box'], (bar_shown(shown) or {}).get('frame'))
        if 'copied (no text box)' not in line:
            raise StepFailed(f'with the desktop in front the words were not copied: {line}')
        return {'front': front, 'bar': bar_shown(shown), 'log': line, 'read': read}

    def nosound(self):
        self.use_sample(self.silent)
        self.bar_document()
        before = self.textedit_text()
        since = len(self.dlog_lines())
        self.press('122')
        shown = self.wait_dlog('bar shown: problem no-sound', since, 20)
        self.grab('no-sound')
        line = self.wait_dlog('nothing written, no-sound', since, 10)
        read = self.expect_read('no-sound', READ['no-sound'], (bar_shown(shown) or {}).get('frame'))
        if self.textedit_text() != before:
            raise StepFailed('a silent dictation changed TextEdit')
        return {'bar': bar_shown(shown), 'log': line, 'read': read}

    def chromium(self):
        self.use_sample(self.spoken)
        since = len(self.dlog_lines())
        out = super().chromium()
        flew = [x for x in self.dlog_lines()[since:] if 'the words flew to' in x]
        out['flight'] = flew[-1].split(' ', 1)[-1] if flew else 'no flight: the app gave Accessibility no rectangle, so the bar said Added alone'
        return out

    def close_window_quits(self, on):
        """Relaunch with dictation `on`, close the app's window, and time the app's end and the tool's."""
        launched = relaunch(self.vm, environment={'RICHOS_VOICE_INPUT_WAV': self.wav, 'RICHOS_DICTATION_TEST_ON': '1' if on else '0'})
        self.log = launched['log']
        app = launched['pid']
        tool = self.wait_tool()['pid'] if on else None
        time.sleep(8)
        script = (f'tell application "System Events" to tell (first process whose unix id is {app}) to '
                  'click (first button of window 1 whose subrole is "AXCloseButton")')
        self.osa(script)
        started = time.monotonic()
        app_gone = tool_gone = None
        while time.monotonic() - started < 30 and (app_gone is None or (on and tool_gone is None)):
            if app_gone is None and guest(self.vm, f'kill -0 {app} 2>/dev/null && echo alive || true') != 'alive':
                app_gone = round(time.monotonic() - started, 2)
            if on and tool_gone is None and guest(self.vm, f'kill -0 {tool} 2>/dev/null && echo alive || true') != 'alive':
                tool_gone = round(time.monotonic() - started, 2)
            time.sleep(0.1)
        return {'dictation_on': on, 'app_pid': app, 'app_gone_after_seconds': app_gone, 'tool_pid': tool,
                'tool_gone_after_seconds': tool_gone}

    def choose_accuracy(self, down_presses):
        """The menu from the item, the focused row moved `down_presses` times from More accurate,
        pressed, then Escape. Returns the tool's line for the choice."""
        (ix, iy), _ = self.item_center()
        since = len(self.dlog_lines())
        self.click(ix, iy)
        try:
            self.wait_dlog('menu bar item pressed', since, 5)
        except StepFailed:
            # walk-c409831e46f9, accuracy-mid: a press 3 s after a fresh tool's start reached no
            # item (no "pressed" line at all), where the menu step's press two minutes after the
            # start has passed three times. A person presses again; the count is reported.
            self.presses_to_open = 2
            self.click(ix, iy)
        else:
            self.presses_to_open = 1
        self.wait_dlog('menu shown at', since, 10)
        time.sleep(0.6)
        for _ in range(down_presses):
            self.key(125)
        self.key(49)
        line = self.wait_dlog('accuracy set to', since, 10)
        self.key(53)
        self.wait_dlog('menu closed', since, 10)
        time.sleep(0.6)
        return line

    def accuracy_mid(self):
        """Finding 6: the accuracy is pinned when a dictation begins."""
        launched = relaunch(self.vm, environment={'RICHOS_VOICE_INPUT_WAV': self.wav, 'RICHOS_DICTATION_TEST_ON': '1'})
        self.log = launched['log']
        self.facts['app_pid'] = launched['pid']
        self.save()
        self.wait_tool()
        # The menu step's press comes long after the tool's start (the settle step waits for the
        # app's voice-readiness line first); this one came 3 s after a fresh tool's start and
        # reached no item (walk-c409831e46f9). A settle before the press.
        time.sleep(FRESH_TOOL_SETTLE)
        # Whatever the file says, this dictation begins on More accurate.
        self.presses_to_open = 0
        self.choose_accuracy(0)
        presses = [self.presses_to_open]
        self.use_sample(self.long)
        self.open_textedit('/tmp/dictation-accuracy-mid.txt')
        since = len(self.dlog_lines())
        self.press('122')
        self.wait_dlog('listening (', since, 20)
        time.sleep(1.0)
        # Faster, chosen while it listens.
        changed = self.choose_accuracy(1)
        presses.append(self.presses_to_open)
        guest(self.vm, 'open -a TextEdit /tmp/dictation-accuracy-mid.txt')
        time.sleep(3)
        self.press('122')
        first = self.wait_dlog('dictation: model ', since, dictation_walk.DICTATION_WITHIN)
        first_model = re.search(r'dictation: model (\S+),', first).group(1)
        if first_model != 'large-v3-turbo-q5_0':
            raise StepFailed(f'the dictation in progress changed its model to {first_model}: {first}')
        self.use_sample(self.spoken)
        row = self.dictate('122', TEXTEDIT, 'clipboard-before-accuracy-mid')
        if row['model'] != 'small.en':
            raise StepFailed(f'the next dictation did not use Faster: {row["log"]}')
        restored = self.choose_accuracy(0)
        presses.append(self.presses_to_open)
        return {'changed_while_listening': changed, 'dictation_in_progress': first, 'next_dictation': row, 'restored': restored,
                'presses_to_open_each_menu': presses}

    def window_closed(self):
        off = self.close_window_quits(False)
        on = self.close_window_quits(True)
        quits_off = off['app_gone_after_seconds'] is not None
        quits_on = on['app_gone_after_seconds'] is not None
        if quits_off != quits_on:
            raise StepFailed(f'dictation changed what closing the window does: off {off}, on {on}')
        if quits_on and (on['tool_gone_after_seconds'] is None or on['tool_gone_after_seconds'] - on['app_gone_after_seconds'] > 1.5):
            raise StepFailed(f'the tool did not end with its app: {on}')
        return {'off': off, 'on': on, 'the_app_quits': quits_on,
                'note': 'the tool is the app\'s child and ends with it (the CEO, 2026-10-08: no start at login in this release)'}


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('vm')
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--expect-sha', required=True)
    p.add_argument('--wav', type=Path, required=True, help='the spoken sample, 16 kHz mono WAV')
    p.add_argument('--long-wav', type=Path, required=True, help='the spoken sample, then quiet room noise')
    p.add_argument('--silent-wav', type=Path, required=True, help='digital silence')
    p.add_argument('--model', type=Path, required=True, help='ggml-small.en.bin')
    p.add_argument('--model-id', default='small.en')
    p.add_argument('--accurate-model', type=Path, help='ggml-large-v3-turbo-q5_0.bin, so Faster is a real switch')
    p.add_argument('--post-key', type=Path, required=True)
    p.add_argument('--key-probe', type=Path, required=True)
    p.add_argument('--idle', type=float, default=0)
    p.add_argument('--steps', default=','.join(STEPS))
    a = p.parse_args()
    steps = a.steps.split(',')
    unknown = [s for s in steps if s not in STEPS]
    if unknown:
        p.error('unknown step(s): ' + ', '.join(unknown))
    walk = BarWalk(a)
    report = {'vm': a.vm, 'expect_sha': a.expect_sha, 'steps': []}
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
            try:
                walk.shot(f'{step}-failed.png')
                (a.out / 'app.log.tail').write_text(guest(a.vm, 'tail -80 ' + shlex.quote(walk.log) + ' || true', 30))
                (a.out / 'dictation.log').write_text(guest(a.vm, 'cat ' + shlex.quote(walk.dlog) + ' 2>/dev/null || true', 30))
            except Exception as exc:  # evidence only; the step already failed
                (a.out / 'evidence-error.txt').write_text(str(exc))
            break
    try:
        (a.out / 'dictation.log').write_text(guest(a.vm, 'cat ' + shlex.quote(walk.dlog) + ' 2>/dev/null || true', 30))
    except Exception as exc:  # evidence only
        (a.out / 'evidence-error.txt').write_text(str(exc))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
