#!/usr/bin/env python3
"""update-relaunch-walk.py — a downloaded update relaunches by itself when nothing runs (CEO feedback 2026-10-06, item 1).

Run by run-walk.py, which holds one guest slot for this run only, boots the guest and removes the clone:

  run-walk.py --bundle ZIP --home EMPTY_DIR --engine ENGINE --report REPORT -- \\
      update-relaunch-walk.py --out DIR --expect-sha SHA --endpoint URL --expect-version VERSION

run-walk.py passes the owned VM name as the first argument. The bundle is the build under test,
whose version must be OLDER than the release --endpoint names (a development build of a branch
is `<version>-dev.<sha>`, which sorts below every nightly of the same version). --endpoint is a
published release's own `latest.json`, so what is downloaded, verified and staged is a real
signed release, and nothing about it is written here.

HIS WORDS. "there was no work going on at the time. So, there was nothing that could be
interrupted. In this case, the app should automatically re-launch immediately after downloading
the new version."

WHAT IT DOES, in the guest, never on the host's screen (CEO ruling §65):
  install    the bundle under test copied to the per-user destination (~/Applications/RichOS.app,
             where the CEO runs it) and started from there with --endpoint, by its pid
  identity   the running app says it was built from --expect-sha
  first-run  adopt-walk.py's: company "Acme"; the first conversation is the app's own
  ready      the update is offered once the app's own first turn has ended ("Download update")
  draft      an unsent sentence typed into the composer; the window's frame read
  download   the cue pressed, then "Download update"; within --within seconds: the notice
             "Restarting into RichOS <version>" is on screen (photographed), the old process
             ends, a new one starts by itself, its log says "update activated: <old> -> <new>",
             and the installed bundle is <new>
  after      the new process has a window with the same frame, the same conversation, and the
             unsent sentence still in the composer (photographed)

Every app instance is quit by run-walk.py's stop.sh (CEO §54): this walk records the relaunched
process's pid in the run state, so stop.sh quits the instance that is actually running.
Exit 0 when every step passes.
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
from relaunch import guest, relaunch  # noqa: E402

_spec = importlib.util.spec_from_file_location('adopt_walk', HERE / 'adopt-walk.py')
adopt = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(adopt)
StepFailed = adopt.StepFailed
command = adopt.command

STEPS = ['install', 'identity', 'first-run', 'ready', 'draft', 'download', 'after']
DRAFT = 'Half a sentence I have not sent yet'


class Walk(adopt.Walk):
    def __init__(self, a):
        super().__init__(a)
        self.state = Path(os.environ.get('TESTVM_ROOT', str(Path.home() / '.richos-testvm'))) / 'run' / a.vm
        self.dest = self.home + '/Applications/RichOS.app'

    def log_path(self):
        return self.facts.get('log') or (self.payload + '/app.log')

    def log(self):
        return guest(self.vm, 'cat ' + shlex.quote(self.log_path()) + ' 2>/dev/null || true', 60)

    def windows(self):
        return command([HERE / 'ax.sh', self.vm, '--windows'], 40).strip()

    def composer(self):
        rows = self.ax('find', '--role', 'AXTextArea', '--title', 'Message to Rich', '--contains', '--first')
        return next((r.get('value', '') for r in rows if 'value' in r), '')

    # --- steps --------------------------------------------------------------------------------
    def install(self):
        if guest(self.vm, 'test -e ' + shlex.quote(self.dest) + ' && echo yes || true'):
            raise StepFailed('fresh fixture required: ' + self.dest + ' already exists')
        app = guest(self.vm, 'find ' + shlex.quote(self.payload) + ' -maxdepth 1 -name "*.app" -type d -print').splitlines()[0]
        guest(self.vm, 'mkdir -p ' + shlex.quote(self.home + '/Applications') + ' && ditto '
              + shlex.quote(app) + ' ' + shlex.quote(self.dest), 120)
        started = relaunch(self.vm, self.dest, {'RICHOS_UPDATE_ENDPOINT': self.a.endpoint})
        self.facts.update({'log': started['log'], 'pid_before': started['pid']})
        self.save()
        return {'pid': started['pid'], 'log': started['log'], 'installed': self.dest}

    def identity(self):
        end = time.monotonic() + 60
        while time.monotonic() < end:
            m = re.search(r'this app: built from (\S+)', self.log())
            if m:
                break
            time.sleep(1)
        else:
            raise StepFailed('the app never said what it was built from')
        built = m.group(1)
        if not built.startswith(self.a.expect_sha):
            raise StepFailed(f'the running app was built from {built}, not {self.a.expect_sha}')
        version = guest(self.vm, '/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" '
                        + shlex.quote(self.dest + '/Contents/Info.plist'))
        self.facts.update({'built_from': built, 'version_before': version})
        self.save()
        return {'built_from': built, 'version': version}

    def ready(self):
        # The control appears only once the work gate is clear: the app's own first turn has
        # ended and the launch check has found the release.
        self.wait_for('is available', seconds=self.a.within)
        self.shot('1-available.png')
        return {'offered': True}

    def draft(self):
        self.type_into(DRAFT, '--role', 'AXTextArea', '--title', 'Message to Rich')
        time.sleep(1)  # the composer's own 400 ms park debounce, so this is the ordinary path too
        frame = self.windows()
        value = self.composer()
        if DRAFT not in value:
            raise StepFailed('the composer does not hold the typed sentence: ' + repr(value))
        self.facts.update({'frame_before': frame, 'composer_before': value})
        self.save()
        return {'frame': frame, 'composer': value}

    def download(self):
        old = str(self.facts['pid_before'])
        self.press('is available')
        self.wait_for('Download update', seconds=20)
        pressed = time.monotonic()
        self.press('Download update')
        notice = None
        new = None
        end = pressed + self.a.within
        while time.monotonic() < end:
            if notice is None and self.present('Restarting into RichOS'):
                notice = round(time.monotonic() - pressed, 1)
                self.shot('2-restarting-notice.png')
            alive = guest(self.vm, 'kill -0 ' + old + ' 2>/dev/null && echo alive || true') == 'alive'
            if not alive:
                rows = guest(self.vm, 'ps -axo pid=,ppid=,comm=')
                for line in rows.splitlines():
                    parts = line.split(None, 2)
                    if len(parts) == 3 and parts[0] != old and parts[1] == '1' and parts[2].startswith(self.dest) \
                            and parts[2].endswith('/richos-tauri'):
                        new = parts[0]
                if new:
                    break
            time.sleep(0.5)
        if notice is None:
            raise StepFailed('the restart notice never appeared')
        if not new:
            raise StepFailed(f'no new RichOS process within {self.a.within} s of the press')
        relaunched = round(time.monotonic() - pressed, 1)
        # stop.sh quits the recorded pid: record the instance that is actually running now.
        (self.state / 'app.pid').write_text(new + '\n')
        end = time.monotonic() + 60
        while time.monotonic() < end and 'update activated:' not in self.log():
            time.sleep(1)
        log = self.log()
        line = next((x for x in log.splitlines() if 'update activated:' in x), '')
        want = f"{self.facts['version_before']} -> {self.a.expect_version}"
        if want not in line:
            raise StepFailed('the relaunch did not activate the update: ' + (line or 'no activation line'))
        relaunch_line = next((x for x in log.splitlines() if 'relaunching into' in x), '')
        version = guest(self.vm, '/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" '
                        + shlex.quote(self.dest + '/Contents/Info.plist'))
        if version != self.a.expect_version:
            raise StepFailed('the installed bundle is ' + version)
        self.facts.update({'pid_after': int(new), 'version_after': version})
        self.save()
        return {'notice_after_s': notice, 'new_process_after_s': relaunched, 'pid_after': int(new),
                'relaunch_line': relaunch_line, 'activation_line': line, 'installed_version': version}

    def after(self):
        end = time.monotonic() + 60
        frame = ''
        while time.monotonic() < end:
            try:
                frame = self.windows()
            except StepFailed:
                frame = ''
            if frame and self.present('Message to Rich', role='AXTextArea'):
                break
            time.sleep(1)
        else:
            raise StepFailed('the relaunched app has no window with a composer')
        time.sleep(2)
        value = self.composer()
        title = self.facts.get('thread_title') or ''
        on_thread = self.present(title, role='AXStaticText') if title else None
        self.shot('3-after-relaunch.png')
        problems = []
        if frame != self.facts['frame_before']:
            problems.append(f'window frame {frame!r} is not {self.facts["frame_before"]!r}')
        if DRAFT not in value:
            problems.append('the unsent sentence is gone: ' + repr(value))
        if title and not on_thread:
            problems.append('the conversation "' + title + '" is not on screen')
        if problems:
            raise StepFailed('; '.join(problems))
        return {'frame': frame, 'composer': value, 'conversation': title}


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('vm')
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--expect-sha', required=True, help='the commit the bundle under test was built from')
    p.add_argument('--endpoint', required=True, help="a published release's own latest.json")
    p.add_argument('--expect-version', required=True, help='the version that endpoint offers')
    p.add_argument('--within', type=float, default=300, help='seconds for each wait on the app')
    p.add_argument('--steps', default=','.join(STEPS))
    a = p.parse_args()
    if '/releases/download/v' + a.expect_version + '/' not in a.endpoint:
        p.error('--endpoint must be the --expect-version release tag\'s own manifest')
    steps = a.steps.split(',')
    unknown = [s for s in steps if s not in STEPS]
    if unknown:
        p.error('unknown step(s): ' + ', '.join(unknown))
    walk = Walk(a)
    report = {'vm': a.vm, 'expect_sha': a.expect_sha, 'endpoint': a.endpoint, 'steps': []}
    ok = True
    for step in steps:
        began = time.monotonic()
        row = {'step': step}
        try:
            row['evidence'] = getattr(walk, step.replace('-', '_'))()
            row['outcome'] = 'PASS'
        except (StepFailed, RuntimeError, ValueError, subprocess.TimeoutExpired) as exc:
            row['outcome'] = 'FAIL'
            row['detail'] = str(exc)
            ok = False
        row['seconds'] = round(time.monotonic() - began, 1)
        report['steps'].append(row)
        (a.out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        print(f"{step}: {row['outcome']}" + (f" - {row.get('detail')}" if row['outcome'] != 'PASS' else ''), flush=True)
        if not ok:
            break
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
