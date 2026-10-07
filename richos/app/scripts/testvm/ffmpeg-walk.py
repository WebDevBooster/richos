#!/usr/bin/env python3
"""ffmpeg-walk.py — on a Mac with no ffmpeg of its own, a Rich turn runs the engine's (CEO 2026-10-07).

Run by run-walk.py, which holds one guest slot for this run only, boots the guest and removes the clone:

  run-walk.py --bundle ZIP --home EMPTY_DIR --engine ENGINE --report REPORT -- \\
      ffmpeg-walk.py --out DIR --expect-sha SHA [--within SECONDS]

run-walk.py passes the owned VM name as the first argument. `--steps a,b,c` runs a subset.

THE QUESTION. The CEO, 2026-10-07: "Our RichOS desktop must also make sure that FFmpeg is installed
and ready on the user's machine". The engine's runtime now carries ffmpeg and ffprobe
(build-runtimes.py, media-tools plan slice 1), and Rich's PATH is that runtime's bin and the system
folders (engine_profile.rs, runtime.rs path()). This walk asks a clean guest, which has no Homebrew
and no ffmpeg, to run `ffmpeg -version` in a Rich turn.

WHAT IT DOES, in the guest, never on the host's screen (CEO ruling §65):
  identity   the running app says it was built from --expect-sha
  no-ffmpeg  `command -v ffmpeg` prints nothing in a login shell and in /bin/sh, and no Homebrew or
             /usr/local copy exists
  runtime    the engine's runtime/bin/ffmpeg and ffprobe exist, are listed in its delivery.json with
             their sha256, and say their versions
  first-run  adopt-walk.py's: memory setup declined, company "Acme" registered, questions declined
  connect    command-walk.py's: the Acme folder connected, so work can be handed over
  task       typed into the Mac's composer: run `ffmpeg -version` and say what it printed first
  observe    within --within seconds a Bash PostToolUse from the app's session (front desk or back
             end, whichever ran it) ran ffmpeg and printed the runtime's own first version line. An
             Approve the panel offers is pressed, at most --approvals times. Evidence in --out.

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
from relaunch import guest  # noqa: E402

_spec = importlib.util.spec_from_file_location('command_walk', HERE / 'command-walk.py')
command_walk = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(command_walk)
StepFailed = command_walk.StepFailed

STEPS = ['identity', 'no-ffmpeg', 'runtime', 'first-run', 'connect', 'task', 'observe']
# command-walk.py's TASK wording, the form proven to reach a turn that runs the command.
TASK = ('Please run this harmless test command for me yourself with your shell tool, in my Acme '
        'folder, and tell me when it has finished and the first line it printed: ffmpeg -version')


def ffmpeg_runs(rows):
    """The Bash PostToolUse rows that ran ffmpeg, from any lease of the app."""
    return [r for r in rows if 'ffmpeg' in r.get('command', '')]


def verdict(runs, version_line):
    """Why these rows do NOT show a turn printing the runtime's ffmpeg version ([] = they do)."""
    if not runs:
        return ['no Bash PostToolUse ran ffmpeg']
    if not any(version_line and version_line in r.get('stdout', '') for r in runs):
        return [f'no ffmpeg run printed {version_line!r}: ' + json.dumps(runs)[:2000]]
    return []


class FfmpegWalk(command_walk.CommandWalk):
    def engine_runtime(self):
        return self.payload + '/engine/runtime'

    def no_ffmpeg(self):
        found = guest(self.vm, "zsh -lc 'command -v ffmpeg ffprobe' 2>/dev/null; sh -c 'command -v ffmpeg' 2>/dev/null; "
                               "ls /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg 2>/dev/null; true").strip()
        if found:
            raise StepFailed('the guest has an ffmpeg of its own, so this walk could not tell which one ran: ' + found)
        return {'guest_ffmpeg': None}

    def runtime(self):
        root = self.engine_runtime()
        script = ('import json,hashlib,subprocess,sys\n'
                  'root=sys.argv[1]\n'
                  'files=json.load(open(root+"/delivery.json"))["files"]\n'
                  'out={}\n'
                  'for name in ("ffmpeg","ffprobe"):\n'
                  '    path=root+"/bin/"+name\n'
                  '    got=hashlib.sha256(open(path,"rb").read()).hexdigest()\n'
                  '    line=subprocess.run([path,"-version"],capture_output=True,text=True).stdout.splitlines()[0]\n'
                  '    out[name]={"listed":files.get("bin/"+name)==got,"sha256":got,"version":line}\n'
                  'print(json.dumps(out))\n')
        found = json.loads(guest(self.vm, 'python3 -c ' + shlex.quote(script) + ' ' + shlex.quote(root), 60))
        unlisted = [n for n, v in found.items() if not v['listed']]
        if unlisted:
            raise StepFailed('not listed in the runtime delivery with these bytes: ' + ', '.join(unlisted))
        self.facts['ffmpeg_version'] = found['ffmpeg']['version']
        self.save()
        return found

    def bash_runs(self):
        script = ('import json,glob,sys\n'
                  'out=[]\n'
                  'for p in glob.glob(sys.argv[1]+"/engine-state/evidence/*/callbacks.jsonl"):\n'
                  '    for l in open(p):\n'
                  '        try: c=json.loads(l).get("callback",{})\n'
                  '        except Exception: continue\n'
                  '        if c.get("hook_event_name")=="PostToolUse" and c.get("tool_name")=="Bash":\n'
                  '            r=c.get("tool_response") or {}\n'
                  '            out.append({"evidence":p.rsplit("/",2)[-2],"agent_id":c.get("agent_id"),\n'
                  '                        "command":c.get("tool_input",{}).get("command",""),\n'
                  '                        "stdout":(r.get("stdout","") if isinstance(r,dict) else str(r))[:2000]})\n'
                  'print(json.dumps(out))\n')
        return json.loads(guest(self.vm, 'python3 -c ' + shlex.quote(script) + ' ' + shlex.quote(self.data), 60))

    def observe(self):
        sent = self.facts.get('sent_ms')
        line = self.facts.get('ffmpeg_version')
        if not sent or not line:
            raise StepFailed('runtime and task must have run (no version line or no send time on record)')
        end = time.monotonic() + self.a.within
        pressed, runs, record = 0, [], None
        while time.monotonic() < end:
            runs = ffmpeg_runs(self.bash_runs())
            if not verdict(runs, line):
                break
            record = self.ours(sent)
            if record and pressed < self.a.approvals and self.approve_if_asked(record.get('title', '')):
                pressed += 1
            time.sleep(3)
        record = self.ours(sent)
        evidence = {'runtime_version_line': line, 'ffmpeg_runs': runs, 'approvals_pressed': pressed,
                    'assignment': record}
        (self.out / 'observed.json').write_text(json.dumps(evidence, indent=2) + '\n')
        try:
            self.shot('observe.png')
        except StepFailed as exc:
            evidence['screenshot'] = 'not taken: ' + str(exc)
        failures = verdict(runs, line)
        if failures:
            raise StepFailed('; '.join(failures))
        hit = next(r for r in runs if line in r['stdout'])
        return {'printed': hit['stdout'].splitlines()[0], 'command': hit['command'],
                'by': 'back end (assignment)' if record else 'front desk turn', 'approvals_pressed': pressed}


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('vm')
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--expect-sha', required=True, help='the commit the bundle under test was built from')
    p.add_argument('--task', default=TASK)
    p.add_argument('--within', type=float, default=240, help='seconds for a turn to run ffmpeg')
    p.add_argument('--approvals', type=int, default=3, help='most Approve presses')
    p.add_argument('--steps', default=','.join(STEPS))
    a = p.parse_args()
    steps = a.steps.split(',')
    unknown = [s for s in steps if s not in STEPS]
    if unknown:
        p.error('unknown step(s): ' + ', '.join(unknown))
    walk = FfmpegWalk(a)
    report = {'vm': a.vm, 'expect_sha': a.expect_sha, 'steps': []}
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
    try:
        report['logs_kept'] = walk.keep_logs()
    except (StepFailed, RuntimeError, subprocess.TimeoutExpired, OSError) as exc:
        report['logs_kept'] = 'the guest logs could not be copied: ' + str(exc)
    (a.out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
