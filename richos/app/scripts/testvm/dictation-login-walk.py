#!/usr/bin/env python3
"""dictation-login-walk.py — start at login, quietly, and every way back into the app (dictation plan slice 5).

Run by run-walk.py, which holds one guest slot for this run only, boots the guest and removes the clone:

  run-walk.py --bundle ZIP --home EMPTY_DIR --engine ENGINE --report REPORT -- \\
      dictation-login-walk.py --out DIR --expect-sha SHA --wav SPOKEN.wav --long-wav LONG.wav \\
          --silent-wav SILENT.wav --model SMALL.bin --post-key POST_KEY --key-probe KEY_PROBE \\
          [--next-bundle NEXT.zip --next-sha SHA] [--steps a,b,c]

THE QUESTION. The CEO's answer A (2026-10-08): "Yes, quietly. But still show the splash screen etc
as usual (assuming the user hasn't turned off splash screen) when the user actually starts the
RichOS app as opposed to just using the dictation tool." Slice 5 of richos-hq
docs/plans/2026-10-08-dictation-anywhere.md (revision 2, section 9) is the LaunchAgent, its
refusals, the tool's handling of a Dock, Finder or `open -a` open, and the version restart; this
walk is its three-part proof, with the two steps slice 3 could only walk in child mode (the tool
outliving the app's window close and the app's self-quit).

WHAT IT DOES, in the guest, never on the host's screen (CEO ruling §65). THE INSTALLED COPY runs
on the guest's REAL home (/Users/admin), from ~/Applications/RichOS.app, with no HOME override:
only that copy may register the login start (login.rs, Frank's B2), and the guest is a disposable
clone, so its real home is a fixture too. No sound is played anywhere (CEO §53): the samples are
files put through the identical capture path by RICHOS_VOICE_INPUT_WAV; for the tool launchd
starts, that variable is set in launchd's own user environment (`launchctl config user
environment`, which survives the reboot), and the file sits under the real home.
  identity       the running app says it was built from --expect-sha
  stage          (dictation-walk.py) Microphone and Accessibility rows only; then the real home is
                 made ready: the fixture's claude sign-in, the engine at the place a double-clicked
                 app finds it (~/Library/Application Support/RichOS/engine), the models, the samples,
                 launchd's environment, and the bundle at ~/Applications/RichOS.app
  install        the installed copy started with the test switch on: the app says "an installed
                 copy", the LaunchAgent is registered (launchctl print gui/<uid>/com.richos.app.dictation
                 succeeds, sfltool dumpbtm lists it), the tool is launchd's (ppid 1, no --parent),
                 "by launchd at login" in dictation.log, the app connected; launches.json counted
                 this start
  window-closed  THE FIRST TOOL-STAYS STEP: the app's window closed with dictation on: the app
                 quits (idle), the tool and its menu bar item stay, and F1 still writes into TextEdit
  self-quit      THE SECOND: the app opened again and ended by its own quit path (the Quit menu
                 item's request_quit, through System Events): the tool keeps working afterwards
  reboot         `shutdown -r now`, the guest back, the user logged in
  login          (a) no RichOS window and no splash; the tool with no Dock presence; the front app
                 unchanged (Finder); the menu bar item present; no microphone or Accessibility
                 prompt on screen; launches.json gained no start; a dictation into TextEdit works
  ways-in        (a) from a state where only the tool runs, each of `open -a`, Finder, the Dock and
                 the menu's Open RichOS: the app's window appears, launches.json gains exactly one
                 start (a fresh start is the splash's own condition: splash.js shows it for `fresh`
                 and the switch), the window is then closed and the idle app quits; then the switch
                 off (config.json) and one more open: one more start, and the window's launch is
                 fresh with the splash off; then the switch back on, the app closed while idle and
                 opened again: one more start
  update         (c) with --next-bundle: the bundle at ~/Applications exchanged for the next candidate
                 while a dictation listens; the next candidate's app opened: the dictation in progress
                 is written first, then the tool ends for the new version (exit 4) and launchd starts
                 the one at the bundle path, whose start line names the next version; the agent is
                 still registered
  turn-off       Turn dictation off from the menu bar menu: the tool ends (exit 0, not restarted), and
                 the app unregisters the agent (launchctl print fails)
  folder-copy    (b) a copy started with nightly-launch.sh, dictation on: nothing registered, the
                 tool is that copy's child, and quitting the copy ends its tool within 1 s

Exit 0 when every step passes. Every app instance started here is quit by its own pid before the
step ends or by run-walk.py's stop.sh (CEO §54); the clone is removed with the guest.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from relaunch import guest  # noqa: E402

_spec = importlib.util.spec_from_file_location('dictation_bar_walk', HERE / 'dictation-bar-walk.py')
bar_walk = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bar_walk)
dictation_walk = bar_walk.dictation_walk
StepFailed = dictation_walk.StepFailed
command = dictation_walk.command
words_of = dictation_walk.words_of

STEPS = ['identity', 'stage', 'install', 'window-closed', 'self-quit', 'reboot', 'login', 'ways-in', 'update',
         'turn-off', 'folder-copy']
REAL_HOME = '/Users/admin'
INSTALLED = REAL_HOME + '/Applications/RichOS.app'
DATA = REAL_HOME + '/Library/Application Support/com.richos.app'
ENGINE_AT = REAL_HOME + '/Library/Application Support/RichOS/engine'
AGENT = 'com.richos.app.dictation'
TEXTEDIT = 'com.apple.TextEdit'
FINDER = 'com.apple.finder'
TOOL_ARG = '--richos-dictation'
# The tool's own start line (tool.rs): its version and who started it.
STARTED = re.compile(r'dictation tool started: version (\S+), key F(\d+), accuracy (\S+), (.*?), the key held at')
# A macOS privacy prompt on screen reads as one of these (dictation-sheet-walk.py).
PROMPTS = ('like to access', 'control this computer')
# The ways back into the app the plan names for part (a).
WAYS = ['open-a', 'finder', 'dock', 'menu']


def launches(text):
    """How many starts launches.json records (launch.rs: `starts`, one entry per fresh start)."""
    try:
        return len(json.loads(text or '{}').get('starts', []))
    except ValueError:
        return None


def started_line(line):
    """The tool's start line, parsed: version, key, accuracy, who started it."""
    m = STARTED.search(line)
    if not m:
        return None
    return {'version': m.group(1), 'key': int(m.group(2)), 'accuracy': m.group(3), 'started': m.group(4)}


def is_tool(command_line, bundle):
    """A process line is THE installed tool: this bundle's executable with the tool's argument
    and no --parent (launchd's, not an app's child)."""
    return command_line.startswith(bundle + '/Contents/MacOS/') and TOOL_ARG in command_line and '--parent' not in command_line


def is_app(command_line, bundle):
    """A process line is the installed APP: this bundle's executable with no tool argument."""
    return command_line.startswith(bundle + '/Contents/MacOS/') and TOOL_ARG not in command_line


class LoginWalk(bar_walk.BarWalk):
    def __init__(self, a):
        super().__init__(a)
        # The installed copy's home is the guest's real home; everything below reads from there.
        self.real = REAL_HOME
        self.installed = INSTALLED
        self.rdata = DATA
        self.rdlog = DATA + '/dictation.log'
        self.rwav = REAL_HOME + '/dictation-sample.wav'
        self.rlong = REAL_HOME + '/dictation-long.wav'
        self.app_log = None

    # --- the real home --------------------------------------------------------------------------
    def rdlog_lines(self):
        return guest(self.vm, 'cat ' + shlex.quote(self.rdlog) + ' 2>/dev/null || true', 30).splitlines()

    def wait_rdlog(self, pattern, since, seconds=60):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            for line in self.rdlog_lines()[since:]:
                if pattern in line:
                    return line
            time.sleep(0.5)
        tail = '\n'.join(self.rdlog_lines()[-20:])
        raise StepFailed(f'dictation.log never said "{pattern}" within {seconds} s; its tail:\n{tail}')

    def processes(self):
        rows = guest(self.vm, 'ps -axo pid=,ppid=,command=')
        out = []
        for line in rows.splitlines():
            parts = line.split(None, 2)
            if len(parts) == 3:
                out.append({'pid': int(parts[0]), 'ppid': int(parts[1]), 'command': parts[2]})
        return out

    def tool(self):
        return [p for p in self.processes() if is_tool(p['command'], self.installed)]

    def app(self):
        return [p for p in self.processes() if is_app(p['command'], self.installed)]

    def agent_registered(self):
        out = guest(self.vm, f'launchctl print gui/$(id -u)/{AGENT} >/dev/null 2>&1 && echo yes || echo no')
        return out.strip() == 'yes'

    def launches_count(self):
        return launches(guest(self.vm, 'cat ' + shlex.quote(self.rdata + '/launches.json') + ' 2>/dev/null || true'))

    def set_splash(self, on):
        """The opening screen's switch, in config.json (config.rs `splash_enabled`), written while
        the app is closed."""
        code = ("import json,sys; p=sys.argv[1]; d=json.load(open(p)); d['splash_enabled']=sys.argv[2]=='1'; "
                "json.dump(d,open(p,'w'),indent=2); print(d['splash_enabled'])")
        return guest(self.vm, 'python3 -c ' + shlex.quote(code) + ' ' + shlex.quote(self.rdata + '/config.json') + (' 1' if on else ' 0'))

    def windows_of(self, pid):
        out = self.osa(f'tell application "System Events" to count windows of (first process whose unix id is {int(pid)})')
        return int(out.strip() or 0)

    def no_prompt_on_screen(self, name):
        self.grab(name)
        text = self.read(name)
        return {frag: bar_walk.read_contains(text, frag) for frag in PROMPTS}

    def wait_app(self, seconds=90, exclude=()):
        """The installed app's process (launchd's child, ppid 1), with a window, within `seconds`."""
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            apps = [p for p in self.app() if p['ppid'] == 1 and p['pid'] not in exclude]
            for p in apps:
                try:
                    if self.windows_of(p['pid']) > 0:
                        return p
                except (RuntimeError, ValueError):
                    pass
            time.sleep(1)
        raise StepFailed(f'no installed app with a window within {seconds} s; apps {self.app()}')

    def wait_gone(self, pid, seconds=30):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            if guest(self.vm, f'kill -0 {int(pid)} 2>/dev/null && echo alive || true') != 'alive':
                return round(seconds - (end - time.monotonic()), 2)
            time.sleep(0.2)
        return None

    def close_window(self, pid):
        self.osa(f'tell application "System Events" to tell (first process whose unix id is {int(pid)}) to '
                 'click (first button of window 1 whose subrole is "AXCloseButton")')

    def record_app(self, pid):
        """stop.sh quits the recorded pid at the end of the run; the last app started here."""
        Path(self.state_file('app.pid')).write_text(f'{int(pid)}\n')

    def launch_installed(self, env):
        """`open -n -a` the installed copy with no HOME override, its output to a log under the
        real home (the one launch this walk can read a log from; the tool's starts of the app go
        through LaunchServices and keep no log)."""
        log = f'{self.real}/richos-{time.time_ns()}.log'
        argv = ['open', '-n', '-a', self.installed]
        for k, v in env.items():
            argv += ['--env', f'{k}={v}']
        argv += ['--stdout', log, '--stderr', log]
        before = {p['pid'] for p in self.app()}
        guest(self.vm, shlex.join(argv))
        app = self.wait_app(exclude=before)
        self.app_log = log
        self.record_app(app['pid'])
        return app, log

    def decline_sheets(self, pid):
        """The first-run sheets an installed copy on a fresh home puts up, declined."""
        self.record_app(pid)
        for _ in range(4):
            try:
                if self.present('Not now'):
                    self.click('Not now')
                    time.sleep(3)
                    continue
            except StepFailed:
                pass
            break

    def dictate_installed(self, label):
        """One dictation into TextEdit through the launchd tool, from the long sample (spoken, then
        room noise): the second tap comes after the spoken part is in, by the sample's own length
        (there is no app log to read the injected source's end from, as the walks with a child
        tool do). Returns the log line, the model and the words."""
        guest(self.vm, f'cp {shlex.quote(self.rlong)} {shlex.quote(self.rwav)}')
        guest(self.vm, f': > /tmp/dictation-{label}.txt && open -a TextEdit /tmp/dictation-{label}.txt')
        time.sleep(3)
        if self.front_bundle() != TEXTEDIT:
            raise StepFailed(f'TextEdit is not in front: {self.front_bundle()}')
        since = len(self.rdlog_lines())
        self.press('122')
        self.wait_rdlog('listening (', since, 20)
        time.sleep(self.seconds + 3)
        self.press('122')
        line = self.wait_rdlog('dictation: model ', since, dictation_walk.DICTATION_WITHIN)
        if 'pasted' not in line:
            raise StepFailed(f'the dictation did not paste: {line}')
        model = re.search(r'dictation: model (\S+),', line).group(1)
        text = self.textedit_text()
        want = words_of(self.expected_real(model))
        if words_of(text) != want:
            raise StepFailed(f'TextEdit holds {words_of(text)}, not {want} ({text!r})')
        self.osa('tell application "TextEdit" to close every window saving no')
        return {'log': line, 'model': model, 'text': text}

    def expected_real(self, model_id):
        """This guest's decode of the sample with `model_id`, from the real home's models."""
        cache = self.facts.setdefault('expected_real', {})
        if model_id not in cache:
            whisper = self.engine + '/runtime/bin/whisper-cli'
            model = f'{self.real}/.config/richos/models/ggml-{model_id}.bin'
            raw = guest(self.vm, ' '.join([shlex.quote(whisper), '-m', shlex.quote(model), '-f', shlex.quote(self.rwav),
                                           *dictation_walk.DECODE_ARGS, '2>/dev/null']), 300)
            cache[model_id] = dictation_walk.strip_annotations(' '.join(l.strip() for l in raw.splitlines()))
            self.save()
        return cache[model_id]

    # --- steps ----------------------------------------------------------------------------------
    def stage(self):
        out = dictation_walk.DictationWalk.stage(self)
        r, q = self.real, shlex.quote
        # The fixture's sign-in and claude, so the installed copy is signed in as the fixture is.
        guest(self.vm, f'mkdir -p {q(r)}/.claude && cp -R {q(self.home)}/.claude/. {q(r)}/.claude/ 2>/dev/null || true', 120)
        guest(self.vm, f'test -f {q(self.home)}/.claude.json && cp {q(self.home)}/.claude.json {q(r)}/.claude.json || true')
        # The engine where a double-clicked app finds it (engine.rs candidate 7).
        guest(self.vm, f'mkdir -p {q(os.path.dirname(ENGINE_AT))} && rm -rf {q(ENGINE_AT)} && cp -R {q(self.engine)} {q(ENGINE_AT)}', 600)
        # The models and the samples under the real home.
        guest(self.vm, f'mkdir -p {q(r)}/.config/richos/models && cp {q(self.home)}/.config/richos/models/*.bin {q(r)}/.config/richos/models/', 900)
        for local, remote in ((self.a.wav, self.rwav), (self.a.long_wav, self.rlong)):
            command([HERE / 'guest.sh', self.vm, '--push', local, remote], 120)
        # launchd's own environment for the user: the tool it starts reads its microphone from
        # the sample. Persistent (survives the reboot); root writes it.
        env = guest(self.vm, f'sudo -n launchctl config user environment RICHOS_VOICE_INPUT_WAV={q(self.rwav)} 2>&1 || true')
        # The bundle, installed where the CEO runs his own copy.
        app = guest(self.vm, 'find ' + q(self.payload) + ' -maxdepth 1 -name "*.app" -type d -print').splitlines()[0]
        guest(self.vm, f'mkdir -p {q(r)}/Applications && rm -rf {q(self.installed)} && ditto {q(app)} {q(self.installed)}', 300)
        plist = guest(self.vm, f'test -f {q(self.installed)}/Contents/Library/LaunchAgents/{AGENT}.plist && echo yes || echo no')
        if plist != 'yes':
            raise StepFailed('the bundle carries no Contents/Library/LaunchAgents/' + AGENT + '.plist')
        guest(self.vm, f'rm -rf {q(self.rdata)}')
        out.update({'real_home': r, 'installed': self.installed, 'engine_at': ENGINE_AT, 'launchd_environment': env,
                    'launch_agent_plist_in_bundle': True, 'models': guest(self.vm, f'ls {q(r)}/.config/richos/models').split()})
        return out

    def install(self):
        app, log = self.launch_installed({'RICHOS_DICTATION_TEST_ON': '1', 'RICHOS_VOICE_INPUT_WAV': self.rwav})
        self.decline_sheets(app['pid'])
        end = time.monotonic() + 120
        text = ''
        while time.monotonic() < end:
            text = guest(self.vm, 'cat ' + shlex.quote(log) + ' 2>/dev/null || true', 30)
            if 'connected to the tool' in text and self.tool():
                break
            time.sleep(1)
        lines = [x for x in text.splitlines() if 'dictation' in x]
        if 'an installed copy' not in text:
            raise StepFailed('the app did not say it is an installed copy:\n' + '\n'.join(lines[-12:]))
        if 'login start is registered' not in text:
            raise StepFailed('the app did not register the login start:\n' + '\n'.join(lines[-12:]))
        if not self.agent_registered():
            raise StepFailed(f'launchctl print gui/<uid>/{AGENT} fails after the app registered it')
        tools = self.tool()
        if len(tools) != 1 or tools[0]['ppid'] != 1:
            raise StepFailed(f'the tool is not exactly one launchd child: {tools}')
        started = next((started_line(x) for x in self.rdlog_lines() if started_line(x)), None)
        if not started or 'launchd' not in started['started']:
            raise StepFailed(f'dictation.log does not say the tool was started by launchd: {started}')
        self.wait_rdlog('key tap created for F1', 0, 60)
        btm = guest(self.vm, f'sudo -n sfltool dumpbtm 2>/dev/null | grep -i -B2 -A8 {AGENT} | head -40 || true', 60)
        self.facts.update({'install_pid': app['pid'], 'install_log': log, 'starts_after_install': self.launches_count(),
                           'tool_version': started['version']})
        self.save()
        return {'app': app, 'app_log_lines': lines[-12:], 'registered': True, 'tool': tools[0], 'tool_started': started,
                'dumpbtm': btm, 'launches_json_starts': self.facts['starts_after_install']}

    def window_closed(self):
        pid = self.facts['install_pid']
        tool = self.tool()[0]
        self.close_window(pid)
        gone = self.wait_gone(pid)
        if gone is None:
            raise StepFailed(f'the idle app (pid {pid}) did not quit when its window closed')
        time.sleep(2)
        still = self.tool()
        if not still or still[0]['pid'] != tool['pid']:
            raise StepFailed(f'the tool did not stay after the app quit: before {tool}, after {still}')
        (ix, iy), item = self.item_center_real()
        row = self.dictate_installed('window-closed')
        return {'app_pid': pid, 'app_gone_after_seconds': gone, 'tool_stays': tool, 'menu_bar_item': item, 'dictation': row}

    def item_center_real(self):
        logged = [x for x in self.rdlog_lines() if 'menu bar item at ' in x]
        if not logged:
            raise StepFailed('the tool logged no menu bar item')
        n = [float(v) for v in re.findall(r'-?\d+', logged[-1].split('menu bar item at ', 1)[1])][:4]
        return (n[0] + n[2] / 2, n[1] + n[3] / 2), {'from': 'dictation.log', 'rect': n}

    def self_quit(self):
        """The app's own quit path (`request_quit`, the Quit menu item), with dictation on: the
        tool keeps working afterwards (Frank's M1, now not reachable because the tool is not in
        the app's process; this is the proof of that)."""
        app, log = self.launch_installed({'RICHOS_VOICE_INPUT_WAV': self.rwav})
        self.decline_sheets(app['pid'])
        starts = self.launches_count()
        tool = self.tool()[0]
        self.osa(f'tell application "System Events" to tell (first process whose unix id is {app["pid"]}) to '
                 'click menu item "Quit RichOS" of menu 1 of menu bar item 2 of menu bar 1')
        gone = self.wait_gone(app['pid'])
        if gone is None:
            raise StepFailed(f'the app (pid {app["pid"]}) did not quit from its Quit menu item')
        time.sleep(2)
        still = self.tool()
        if not still or still[0]['pid'] != tool['pid']:
            raise StepFailed(f'the tool did not stay after the app quit itself: before {tool}, after {still}')
        row = self.dictate_installed('self-quit')
        self.facts['starts_before_reboot'] = self.launches_count()
        self.save()
        return {'app_pid': app['pid'], 'app_gone_after_seconds': gone, 'tool_stays': tool, 'dictation': row,
                'launches_json_starts': self.facts['starts_before_reboot'], 'starts_at_open': starts}

    def reboot(self):
        before = self.tool()
        try:
            guest(self.vm, 'sudo -n shutdown -r now >/dev/null 2>&1 &')
        except RuntimeError:
            pass
        down = None
        started = time.monotonic()
        while time.monotonic() - started < 60:
            try:
                guest(self.vm, 'true', 5)
            except (RuntimeError, subprocess.TimeoutExpired):
                down = round(time.monotonic() - started, 1)
                break
            time.sleep(1)
        up = None
        while time.monotonic() - started < 300:
            try:
                guest(self.vm, 'true', 5)
                up = round(time.monotonic() - started, 1)
                break
            except (RuntimeError, subprocess.TimeoutExpired):
                time.sleep(2)
        if up is None:
            raise StepFailed('the guest did not come back within 300 s of the reboot')
        boot = guest(self.vm, 'sysctl -n kern.boottime')
        return {'tool_before': before, 'ssh_down_after_seconds': down, 'ssh_up_after_seconds': up, 'kern_boottime': boot}

    def login(self):
        # The user's session back: WindowServer and Finder, then the agent's tool.
        end = time.monotonic() + 180
        tools = []
        while time.monotonic() < end:
            tools = self.tool()
            if tools and 'key tap created for F1' in '\n'.join(self.rdlog_lines()[-40:]):
                break
            time.sleep(2)
        if len(tools) != 1 or tools[0]['ppid'] != 1:
            raise StepFailed(f'after the login the tool is not exactly one launchd child: {tools}')
        time.sleep(5)
        apps = self.app()
        if apps:
            raise StepFailed(f'the login started the app, not only the tool: {apps}')
        windows = self.windows_of(tools[0]['pid'])
        kind = guest(self.vm, f'lsappinfo info -only ApplicationType "$(lsappinfo find pid={tools[0]["pid"]})" 2>/dev/null || true')
        front = self.front_bundle()
        (ix, iy), item = self.item_center_real()
        prompt = self.no_prompt_on_screen('login')
        starts = self.launches_count()
        started = [started_line(x) for x in self.rdlog_lines() if started_line(x)]
        # The tool's microphone is the sample only if launchd's user environment carried the
        # variable across the reboot (stage: `launchctl config user environment`). Read off the
        # tool's own environment; when it is not there, the variable is set for launchd now and
        # the agent restarted by launchd (kickstart), which is said in the evidence: the login
        # start itself is already proven above, and the dictation then still runs through a tool
        # launchd started with no app.
        env = guest(self.vm, f'ps -wwE -p {tools[0]["pid"]} -o command= 2>/dev/null || true')
        sample_env = {'in_launchd_tool': 'RICHOS_VOICE_INPUT_WAV=' in env, 'kickstarted': False}
        if not sample_env['in_launchd_tool']:
            old_pid = tools[0]['pid']
            since = len(self.rdlog_lines())
            guest(self.vm, 'launchctl setenv RICHOS_VOICE_INPUT_WAV ' + shlex.quote(self.rwav))
            guest(self.vm, f'launchctl kickstart -k gui/$(id -u)/{AGENT}')
            sample_env.update({'kickstarted': True, 'old_pid': old_pid})
            self.wait_rdlog('key tap created for F1', since, 60)
            tools = self.tool()
            if len(tools) != 1 or tools[0]['pid'] == old_pid or tools[0]['ppid'] != 1:
                raise StepFailed(f'after kickstart the tool is not one new launchd child: {tools}')
        row = self.dictate_installed('login')
        if windows != 0:
            raise StepFailed(f'the tool has {windows} window(s) on screen after the login')
        if 'UIElement' not in kind:
            raise StepFailed(f'the tool has a Dock presence: lsappinfo says {kind!r}')
        if front != FINDER:
            raise StepFailed(f'the front app after the login is {front}, not Finder')
        if any(prompt.values()):
            raise StepFailed(f'a privacy prompt is on screen after the login: {prompt}')
        if starts != self.facts['starts_before_reboot']:
            raise StepFailed(f'launches.json gained a start at login: {self.facts["starts_before_reboot"]} -> {starts}')
        return {'tool': tools[0], 'tool_windows': windows, 'lsappinfo_type': kind, 'front': front, 'menu_bar_item': item,
                'prompt_on_screen': prompt, 'launches_json_starts': starts, 'tool_started_lines': started[-1:],
                'sample_in_launchd_environment': sample_env, 'dictation': row}

    def open_by(self, way):
        """One way back into the app, from a state where only the tool runs."""
        if way == 'open-a':
            guest(self.vm, 'open -a ' + shlex.quote(self.installed))
        elif way == 'finder':
            self.osa(f'tell application "Finder" to open POSIX file "{self.installed}"')
        elif way == 'dock':
            tile = ('<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key>'
                    f'<string>{self.installed}</string><key>_CFURLStringType</key><integer>0</integer></dict></dict></dict>')
            if not self.facts.get('dock_tile'):
                guest(self.vm, 'defaults write com.apple.dock persistent-apps -array-add ' + shlex.quote(tile) + ' && killall Dock')
                time.sleep(4)
                self.facts['dock_tile'] = True
                self.save()
            self.osa('tell application "System Events" to tell process "Dock" to click UI element "RichOS" of list 1')
        elif way == 'menu':
            (ix, iy), _ = self.item_center_real()
            since = len(self.rdlog_lines())
            self.click(ix, iy)
            self.wait_rdlog('menu shown at', since, 10)
            time.sleep(0.6)
            self.key(126)  # up arrow: from More accurate, wrapping, to the last row, Open RichOS
            self.key(49)   # space presses the focused row
            self.wait_rdlog('Open RichOS chosen', since, 10)
        else:
            raise StepFailed(f'unknown way {way}')

    def ways_in(self):
        out = {}
        starts = self.launches_count()
        for way in WAYS:
            if self.app():
                raise StepFailed(f'an app runs before the {way} open: {self.app()}')
            since = len(self.rdlog_lines())
            tool_before = self.tool()[0]['pid']
            self.open_by(way)
            app = self.wait_app()
            self.decline_sheets(app['pid'])
            time.sleep(3)
            after = self.launches_count()
            reached = [x for x in self.rdlog_lines()[since:] if 'RichOS asked for' in x or 'LaunchServices opened RichOS' in x]
            splash = self.splash_seen(f'ways-in-{way}')
            if after != starts + 1:
                raise StepFailed(f'{way}: launches.json went {starts} -> {after}, not exactly one more start')
            starts = after
            self.close_window(app['pid'])
            gone = self.wait_gone(app['pid'])
            if gone is None:
                raise StepFailed(f'{way}: the idle app did not quit when its window closed')
            time.sleep(1)
            if self.tool()[0]['pid'] != tool_before:
                raise StepFailed(f'{way}: the tool changed: {tool_before} -> {self.tool()}')
            out[way] = {'app': app, 'launches_json_starts': after, 'tool_log': reached, 'splash': splash, 'app_gone_after_seconds': gone}
        # The splash switched off: the window appears, the start is counted, the launch is fresh
        # with the splash off (the app's own window line, read from the one log this walk can keep).
        off = self.set_splash(False)
        app, log = self.launch_installed({'RICHOS_VOICE_INPUT_WAV': self.rwav})
        self.decline_sheets(app['pid'])
        time.sleep(2)
        text = guest(self.vm, 'cat ' + shlex.quote(log) + ' 2>/dev/null || true', 30)
        window_line = next((x for x in text.splitlines() if 'window: launch kind' in x), '')
        after = self.launches_count()
        if after != starts + 1:
            raise StepFailed(f'splash off: launches.json went {starts} -> {after}')
        if 'launch kind fresh' not in window_line or 'splash off by the switch' not in window_line:
            raise StepFailed(f'splash off: the window line is {window_line!r}')
        starts = after
        self.close_window(app['pid'])
        self.wait_gone(app['pid'])
        on = self.set_splash(True)
        # Closed while idle and opened again: the splash again, one more start.
        app, log = self.launch_installed({'RICHOS_VOICE_INPUT_WAV': self.rwav})
        self.decline_sheets(app['pid'])
        time.sleep(2)
        text = guest(self.vm, 'cat ' + shlex.quote(log) + ' 2>/dev/null || true', 30)
        again = next((x for x in text.splitlines() if 'window: launch kind' in x), '')
        after = self.launches_count()
        if after != starts + 1 or 'launch kind fresh, splash on' not in again:
            raise StepFailed(f'opened again: launches.json {starts} -> {after}, window line {again!r}')
        self.close_window(app['pid'])
        self.wait_gone(app['pid'])
        out['splash-off'] = {'config': off, 'window_line': window_line, 'launches_json_starts': starts}
        out['opened-again'] = {'config': on, 'window_line': again, 'launches_json_starts': after}
        return out

    def splash_seen(self, name):
        """The splash, best effort: a frame taken the moment the window exists, read for the
        wordmark; the gate is launches.json (a fresh, counted start is what splash.js shows the
        splash for, with the switch on)."""
        self.grab(name)
        text = self.read(name)
        return {'frame': name + '.png', 'reads_richos': bar_walk.read_contains(text, 'RichOS')}

    def update(self):
        if not self.a.next_bundle:
            raise StepFailed('--next-bundle is required for part (c)')
        q = shlex.quote
        target = self.payload + '/next'
        guest(self.vm, f'mkdir -p {q(target)}')
        command([HERE / 'guest.sh', self.vm, '--push', str(self.a.next_bundle), target + '/'], 300)
        guest(self.vm, f'cd {q(target)} && ditto -x -k {q(target + "/" + Path(self.a.next_bundle).name)} {q(target)}', 120)
        nxt = guest(self.vm, 'find ' + q(target) + ' -maxdepth 2 -name "*.app" -type d -print').splitlines()[0]
        next_version = guest(self.vm, '/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" ' + q(nxt + '/Contents/Info.plist'))
        tool_before = self.tool()[0]
        old_version = self.facts['tool_version']
        if next_version == old_version:
            raise StepFailed(f'the next candidate has the same version as the installed one ({old_version})')
        # The exchange at the registered path, as an update's directory exchange leaves it.
        guest(self.vm, f'rm -rf {q(self.installed + ".previous")} && mv {q(self.installed)} {q(self.installed + ".previous")} && ditto {q(nxt)} {q(self.installed)}', 300)
        # A dictation in progress while the next candidate's app opens.
        guest(self.vm, f'cp {q(self.rlong)} {q(self.rwav)}')
        guest(self.vm, ': > /tmp/dictation-update.txt && open -a TextEdit /tmp/dictation-update.txt')
        time.sleep(3)
        since = len(self.rdlog_lines())
        self.press('122')
        self.wait_rdlog('listening (', since, 20)
        guest(self.vm, 'open -a ' + q(self.installed))
        hello = self.wait_rdlog('an app connected: version ' + next_version, since, 60)
        restart_wanted = self.wait_rdlog('the tool restarts once no dictation is in progress', since, 10)
        time.sleep(self.seconds + 3)
        self.press('122')
        written = self.wait_rdlog('dictation: model ', since, dictation_walk.DICTATION_WITHIN)
        restarting = self.wait_rdlog('restarting for the new version', since, 30)
        gone = self.wait_gone(tool_before['pid'], 30)
        started = None
        end = time.monotonic() + 60
        while time.monotonic() < end:
            lines = [started_line(x) for x in self.rdlog_lines()[since:] if started_line(x)]
            if lines and lines[-1]['version'] == next_version:
                started = lines[-1]
                break
            time.sleep(1)
        tools = self.tool()
        text = self.textedit_text()
        self.osa('tell application "TextEdit" to close every window saving no')
        app = self.wait_app()
        self.decline_sheets(app['pid'])
        self.close_window(app['pid'])
        self.wait_gone(app['pid'])
        if 'pasted' not in written:
            raise StepFailed(f'the dictation in progress was not written before the restart: {written}')
        if gone is None:
            raise StepFailed(f'the old tool (pid {tool_before["pid"]}) did not end')
        if not started:
            raise StepFailed(f'no tool of version {next_version} started: {self.rdlog_lines()[-10:]}')
        if len(tools) != 1 or tools[0]['ppid'] != 1 or tools[0]['pid'] == tool_before['pid']:
            raise StepFailed(f'the new tool is not exactly one launchd child: {tools}')
        if not self.agent_registered():
            raise StepFailed('the agent is not registered after the update')
        self.facts['tool_version'] = next_version
        self.save()
        return {'from_version': old_version, 'to_version': next_version, 'hello': hello, 'restart_wanted': restart_wanted,
                'written_during_update': written, 'textedit_words': words_of(text), 'restarting': restarting,
                'old_tool_gone_after_seconds': gone, 'new_tool': tools[0], 'new_tool_started': started, 'registered': True}

    def turn_off(self):
        tool = self.tool()[0]
        app, log = self.launch_installed({'RICHOS_VOICE_INPUT_WAV': self.rwav})
        self.decline_sheets(app['pid'])
        (ix, iy), _ = self.item_center_real()
        since = len(self.rdlog_lines())
        self.click(ix, iy)
        self.wait_rdlog('menu shown at', since, 10)
        time.sleep(0.6)
        self.key(126)  # up: Open RichOS
        self.key(126)  # up: Turn dictation off
        self.key(49)
        chosen = self.wait_rdlog('Turn dictation off chosen', since, 10)
        gone = self.wait_gone(tool['pid'], 30)
        time.sleep(12)  # launchd's ThrottleInterval: a restarted tool would be back by now
        tools = self.tool()
        text = guest(self.vm, 'cat ' + shlex.quote(log) + ' 2>/dev/null || true', 30)
        unregistered = 'login start is unregistered' in text
        registered = self.agent_registered()
        on = guest(self.vm, 'python3 -c ' + shlex.quote("import json,sys; print(json.load(open(sys.argv[1]))['on'])") + ' ' + shlex.quote(self.rdata + '/dictation.json'))
        self.close_window(app['pid'])
        self.wait_gone(app['pid'])
        if gone is None or tools:
            raise StepFailed(f'the tool did not end, or came back: gone {gone}, tools {tools}')
        if registered or not unregistered:
            raise StepFailed(f'the agent is still registered after Turn dictation off (app said unregistered: {unregistered})')
        return {'chosen': chosen, 'tool_gone_after_seconds': gone, 'tool_restarted': False, 'agent_registered': registered,
                'app_unregistered_line': unregistered, 'dictation_json_on': on}

    def folder_copy(self):
        q = shlex.quote
        script = self.payload + '/nightly-launch.sh'
        command([HERE / 'guest.sh', self.vm, '--push', str(HERE.parent / 'nightly-launch.sh'), script], 120)
        guest(self.vm, f'chmod 755 {q(script)}')
        # run.sh unpacks the bundle and removes its zip, and nightly-launch.sh takes a zip holding
        # exactly one RichOS.app: made here from the payload's own bundle.
        app = guest(self.vm, 'find ' + q(self.payload) + ' -maxdepth 1 -name "*.app" -type d -print').splitlines()[0]
        zipped = self.payload + '/RichOS-folder-copy.zip'
        guest(self.vm, f'rm -f {q(zipped)} && ditto -c -k --keepParent {q(app)} {q(zipped)}', 300)
        zips = [zipped]
        # The script's own preconditions on the real home: the sign-in's three things and claude.
        guest(self.vm, f'test -f {q(self.real)}/.claude.json || echo "{{}}" > {q(self.real)}/.claude.json')
        guest(self.vm, f'rm -rf {q(self.real)}/myrichos-nightly-a')
        first = guest(self.vm, f'{q(script)} a {q(zips[0])} 2>&1 || true', 180)
        folder = self.real + '/myrichos-nightly-a'
        fdata = folder + '/home.noindex/Library/Application Support/com.richos.app'
        copies = lambda: [p for p in self.processes() if p['command'].startswith(folder + '/app.noindex/RichOS.app/Contents/MacOS/') and TOOL_ARG not in p['command']]
        end = time.monotonic() + 60
        while time.monotonic() < end and not copies():
            time.sleep(1)
        if not copies():
            raise StepFailed('nightly-launch.sh started no copy:\n' + first[-2000:])
        pid1 = copies()[0]['pid']
        self.record_app(pid1)
        self.decline_sheets(pid1)
        guest(self.vm, f'kill -TERM {pid1}')
        self.wait_gone(pid1)
        # Dictation on in the folder copy's own data, then started again from what it holds.
        guest(self.vm, f'mkdir -p {q(fdata)} && printf \'{{"on": true}}\' > {q(fdata)}/dictation.json')
        again = guest(self.vm, f'{q(script)} a --again 2>&1 || true', 180)
        end = time.monotonic() + 60
        while time.monotonic() < end and not copies():
            time.sleep(1)
        if not copies():
            raise StepFailed('nightly-launch.sh --again started no copy:\n' + again[-2000:])
        pid2 = copies()[0]['pid']
        self.record_app(pid2)
        self.decline_sheets(pid2)
        tool = None
        end = time.monotonic() + 60
        while time.monotonic() < end:
            tool = [p for p in self.processes() if TOOL_ARG in p['command'] and p['command'].startswith(folder)]
            if tool:
                break
            time.sleep(1)
        if not tool:
            raise StepFailed('the folder copy started no tool within 60 s')
        registered = self.agent_registered()
        guest(self.vm, f'kill -TERM {pid2}')
        app_gone = self.wait_gone(pid2)
        tool_gone = self.wait_gone(tool[0]['pid'], 10)
        copy_log = guest(self.vm, f'tail -30 "$(ls -t {q(folder)}/logs/*.log | head -1)" 2>/dev/null || true', 30)
        if registered:
            raise StepFailed('a folder copy registered the login start')
        if tool[0]['ppid'] != pid2:
            raise StepFailed(f'the folder copy\'s tool is not its child: {tool}')
        if app_gone is None or tool_gone is None or tool_gone > 1.0 + 0.5:
            raise StepFailed(f'quitting the copy did not end its tool within 1 s: app {app_gone}, tool {tool_gone}')
        if 'works only while RichOS is open' not in copy_log:
            raise StepFailed('the folder copy did not say it works only while RichOS is open:\n' + copy_log)
        return {'folder': folder, 'first_start': first[-600:], 'copy_pid': pid2, 'tool': tool[0], 'launchctl_print_fails': True,
                'app_gone_after_seconds': app_gone, 'tool_gone_after_seconds': tool_gone, 'copy_log_tail': copy_log}


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('vm')
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--expect-sha', required=True)
    p.add_argument('--wav', type=Path, required=True, help='the spoken sample, 16 kHz mono WAV')
    p.add_argument('--long-wav', type=Path, required=True, help='the spoken sample, then quiet room noise')
    p.add_argument('--silent-wav', type=Path, required=True)
    p.add_argument('--model', type=Path, required=True, help='ggml-small.en.bin')
    p.add_argument('--model-id', default='small.en')
    p.add_argument('--accurate-model', type=Path)
    p.add_argument('--post-key', type=Path, required=True)
    p.add_argument('--key-probe', type=Path, required=True)
    p.add_argument('--next-bundle', type=Path, help='the next candidate (part c), a zip of RichOS.app')
    p.add_argument('--idle', type=float, default=0)
    p.add_argument('--steps', default=','.join(STEPS))
    a = p.parse_args()
    steps = a.steps.split(',')
    unknown = [s for s in steps if s not in STEPS]
    if unknown:
        p.error('unknown step(s): ' + ', '.join(unknown))
    walk = LoginWalk(a)
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
                if walk.app_log:
                    (a.out / 'app.log.tail').write_text(guest(a.vm, 'tail -80 ' + shlex.quote(walk.app_log) + ' || true', 30))
                (a.out / 'dictation.log').write_text('\n'.join(walk.rdlog_lines()) + '\n')
            except Exception as exc:  # evidence only; the step already failed
                (a.out / 'evidence-error.txt').write_text(str(exc))
            break
    try:
        (a.out / 'dictation.log').write_text('\n'.join(walk.rdlog_lines()) + '\n')
    except Exception as exc:  # evidence only
        (a.out / 'evidence-error.txt').write_text(str(exc))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
