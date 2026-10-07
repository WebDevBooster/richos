#!/usr/bin/env python3
"""setup-walk.py — setup is not complete until the video tools are installed (CEO 2026-10-07).

Run by run-walk.py, which holds one guest slot for this run only, boots the guest and removes the clone:

  run-walk.py --bundle ZIP --home EMPTY_DIR --engine ENGINE --report REPORT -- \\
      setup-walk.py --out DIR --expect-sha SHA

run-walk.py passes the owned VM name as the first argument.

THE QUESTION. The CEO, 2026-10-07: "The RichOS desktop app (once installed) neeeds to install the
necessary tools on the user's Mac such as Whisper, ffmpeg and the youtube download tool. These
tools need to be classed as necessary essentials." Media-tools plan slice 3 (richos-hq
docs/plans/2026-10-07-media-tools.md §2): `Component::MediaTools` is present only when yt-dlp is
installed and a pinned speech model resolves, and the setup sheet fetches the model.

The guest has Claude Code and the engine (run.sh's RICHOS_ENGINE_DIR), which is exactly an install
that finished setup before this change: the sheet must come up once, listing only the video tools.

WHAT IT DOES, in the guest, never on the host's screen (CEO ruling §65):
  identity    the running app says it was built from --expect-sha
  incomplete  the boot line names "my video tools" as NOT installed and nothing else; no speech
              model is on the guest; the sheet is up with one item, "my video tools"
  install     "Set it up" is pressed; the run's own lines are read until it finishes or fails
  installed   tools/yt-dlp verifies (launcher record = file hash) and answers --version on the
              runtime's Python; the model on disk has its pinned sha256; the sheet says
              "Setup is done."
  relaunch    the app is relaunched; the boot line says "nothing missing." and no sheet comes up

CEO §53: no sound is played. Every app instance is quit by run-walk.py's stop.sh (CEO §54).
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
from relaunch import guest, relaunch  # noqa: E402

_spec = importlib.util.spec_from_file_location('adopt_walk', HERE / 'adopt-walk.py')
adopt_walk = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(adopt_walk)
StepFailed = adopt_walk.StepFailed

STEPS = ['identity', 'incomplete', 'install', 'installed', 'relaunch']
PINS = HERE.parents[2] / 'engine' / 'voice' / 'models' / 'model-pins.json'


def boot_setup(text):
    """The first-run setup verdict a boot log states (main.rs's boot block): `None` if it has not
    printed one yet, else {'nothing_missing': bool, 'missing': [display names]}."""
    missing = re.findall(r'^\[richos\] first-run setup: (.+?) is NOT installed', text, re.M)
    nothing = bool(re.search(r'^\[richos\] first-run setup: nothing missing\.$', text, re.M))
    if not missing and not nothing:
        return None
    return {'nothing_missing': nothing, 'missing': missing}


def run_outcome(text):
    """How `run_setup` ended, from its own lines (setup_view.rs `emit`): 'finished', 'failed' or
    None while it is still running."""
    if re.search(r'^\[richos\] setup \d+/\d+ FAILED', text, re.M):
        return 'failed'
    if re.search(r'^\[richos\] setup \d+/\d+ finished:', text, re.M):
        return 'finished'
    return None


class SetupWalk(adopt_walk.Walk):
    def __init__(self, a):
        super().__init__(a)
        self.engine = self.payload + '/engine'
        self.log = self.payload + '/app.log'
        self.tools = self.home + '/Library/Application Support/RichOS/tools'
        self.models = self.home + '/.config/richos/models'

    def read_log(self, path=None):
        return guest(self.vm, 'cat ' + shlex.quote(path or self.log) + ' 2>/dev/null || true', 60)

    def wait_boot_setup(self, path, seconds=90):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            verdict = boot_setup(self.read_log(path))
            if verdict:
                return verdict
            time.sleep(1)
        raise StepFailed(f'the app printed no first-run setup verdict within {seconds} s ({path})')

    def incomplete(self):
        verdict = self.wait_boot_setup(self.log)
        if verdict['nothing_missing'] or verdict['missing'] != ['my video tools']:
            raise StepFailed(f'the boot should name the video tools alone as missing: {verdict}')
        looked = [line for line in self.read_log().splitlines() if '[richos]   looked in ' in line]
        models = guest(self.vm, 'ls ' + shlex.quote(self.models) + ' 2>/dev/null || true')
        if models:
            raise StepFailed(f'the guest already has a speech model, so this walk proves nothing: {models}')
        self.wait_for('Set it up', seconds=60)
        one = self.present("There's one thing I need on this Mac.", role='AXStaticText')
        item = self.present('my video tools', role='AXStaticText')
        self.shot('sheet-before.png')
        if not (one and item):
            raise StepFailed(f'the sheet should list the video tools as its one item (one={one}, item={item})')
        return {'boot': verdict, 'looked_in': looked, 'models_before': models or '(none)'}

    def install(self):
        before = self.clock()
        self.press('Set it up')
        end = time.monotonic() + self.a.within
        outcome = None
        while time.monotonic() < end:
            outcome = run_outcome(self.read_log())
            if outcome:
                break
            time.sleep(5)
        after = self.clock()
        lines = [line for line in self.read_log().splitlines()
                 if line.startswith('[richos] setup') or 'yt-dlp' in line or 'voice model' in line]
        progress = [line for line in lines if '%' in line]
        self.shot('sheet-after.png')
        evidence = {'outcome': outcome, 'seconds': round((after - before) / 1000, 1),
                    'lines': [line for line in lines if '%' not in line][-30:],
                    'progress_first_last': progress[:1] + progress[-1:], 'progress_lines': len(progress)}
        self.facts['install'] = evidence
        self.save()
        if outcome != 'finished':
            raise StepFailed(f'setup did not finish within {self.a.within} s: {json.dumps(evidence)[:2000]}')
        return evidence

    def installed(self):
        launcher = guest(self.vm, 'cat ' + shlex.quote(self.tools + '/yt-dlp'))
        record = re.search(r'^# yt-dlp nightly (\S+) sha256 ([0-9a-f]{64})$', launcher, re.M)
        if not record:
            raise StepFailed(f'tools/yt-dlp is not the launcher RichOS writes: {launcher!r}')
        tag, sha = record.groups()
        version_file = f'{self.tools}/yt-dlp-{sha[:12]}'
        got = guest(self.vm, 'shasum -a 256 ' + shlex.quote(version_file), 60).split()[0]
        if got != sha:
            raise StepFailed(f'yt-dlp {version_file} hashes to {got}, its record says {sha}')
        path = f'{self.engine}/runtime/bin:/usr/bin:/bin:/usr/sbin:/sbin'
        version = guest(self.vm, f'env -i HOME={shlex.quote(self.home)} PATH={shlex.quote(path)} '
                                 + shlex.quote(self.tools + '/yt-dlp') + ' --version', 60)
        pins = {m['file']: m for m in json.loads(PINS.read_text())['models']}
        models = guest(self.vm, 'ls ' + shlex.quote(self.models)).split()
        found = [name for name in models if name in pins]
        if len(found) != 1:
            raise StepFailed(f'expected one pinned model in {self.models}, found {models}')
        model_sha = guest(self.vm, 'shasum -a 256 ' + shlex.quote(f'{self.models}/{found[0]}'), 300).split()[0]
        if model_sha != pins[found[0]]['sha256']:
            raise StepFailed(f'{found[0]} hashes to {model_sha}, the pin says {pins[found[0]]["sha256"]}')
        done = self.present('Setup is done.', role='AXStaticText')
        if not done:
            raise StepFailed('the sheet does not say "Setup is done."')
        return {'yt_dlp': {'tag': tag, 'sha256': sha, 'version': version},
                'model': {'file': found[0], 'sha256': model_sha, 'bytes': pins[found[0]]['bytes']},
                'sheet': 'Setup is done.'}

    def relaunch(self):
        launched = relaunch(self.vm)
        self.facts['relaunch'] = launched
        self.save()
        verdict = self.wait_boot_setup(launched['log'])
        if not verdict['nothing_missing'] or verdict['missing']:
            raise StepFailed(f'after setup the next launch still finds something missing: {verdict}')
        # The window settles before it would ask; then the sheet must not be there.
        time.sleep(15)
        asked = self.present('Set it up') or self.present('my video tools', role='AXStaticText')
        self.shot('relaunch.png')
        if asked:
            raise StepFailed('the relaunched app put the setup sheet up again')
        return {'boot': verdict, 'sheet_shown': False, 'log': launched['log']}


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('vm')
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--expect-sha', required=True, help='the commit the bundle under test was built from')
    p.add_argument('--within', type=float, default=1500, help='seconds for "Set it up" to finish')
    p.add_argument('--steps', default=','.join(STEPS))
    a = p.parse_args()
    steps = a.steps.split(',')
    unknown = [s for s in steps if s not in STEPS]
    if unknown:
        p.error('unknown step(s): ' + ', '.join(unknown))
    walk = SetupWalk(a)
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
            break
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
