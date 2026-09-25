#!/usr/bin/env python3
"""Walk the two scratch-home launches in a test guest: gui_boot and the candidate walk recipe.

Run by run-walk.py, which boots the guest, holds <TESTVM_ROOT>/guest.lock and removes the clone:

  reserve.py -- run-walk.py --bundle ZIP --home FIXTURE --engine ENGINE --report REPORT -- \\
      scratch-home-walk.py --zip ZIP --before-lib OLD_GUI_LAUNCH_SH --out DIR

run-walk.py passes the owned VM name as the first argument.

THE QUESTION (escalation esc-20260924T211839Z-e3cbdda5). An instance started with HOME alone
wrote ~/Library/WebKit/com.richos.app and ~/Library/Caches/com.richos.app in the REAL home,
because Foundation answers NSHomeDirectory() from the account record. His daily driver uses
those folders (same bundle identifier). gui_boot (lib/gui-launch.sh) and the candidate walk
recipe (nightly-local.py) set HOME alone. Both now also set CFFIXED_USER_HOME, under env -i,
on .noindex folders.

WHAT IT DOES, in the guest, never on the host's screen (CEO ruling §65). Four launches of the
same ZIP, each on a fresh scratch home, each with the guest's real ~/Library cleared of
anything naming richos before it starts:

  gui_boot before   the pre-fix lib/gui-launch.sh (--before-lib), the contrast
  gui_boot after    this checkout's lib/gui-launch.sh
  recipe before     the pre-fix recipe's shape: HOME=<scratch>/home, the calling shell's env
  recipe after      this checkout's nightly-local.walk_recipe() lines, run as printed

After each: what now exists under the real ~/Library naming richos (a LEAK), and what exists
under the scratch home's own Library (where it went instead). A "before" that leaks is the
contrast reproduced; an "after" that leaks fails the walk. Every instance is quit by its pid
and verified gone.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from relaunch import guest  # noqa: E402

AFTER_LIB = HERE.parent / 'lib' / 'gui-launch.sh'
NIGHTLY_LOCAL = HERE.parent / 'nightly-local.py'
# Where WebKit's store and the URL cache land, and the other per-bundle places a launch can
# write, all within four levels of ~/Library.
FIND_RICHOS = "find {lib} -maxdepth 4 -iname '*richos*' 2>/dev/null | sort || true"


def utc():
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def recipe_after(bundle_zip, run_id, temp_root):
    spec = importlib.util.spec_from_file_location('nightly_local', NIGHTLY_LOCAL)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.walk_recipe(bundle_zip, run_id, temp_root=temp_root)


def recipe_before(bundle_zip, run_id, temp_root):
    """The shape nightly-local.py printed before 2026-09-24 (print_candidate), on a canonical
    folder so the product does not refuse it for a reason unrelated to this question."""
    scratch = f'{temp_root}/richos-qa-{run_id}'
    # The old recipe never created <scratch>/home, and the product refuses a home that does not
    # exist. It is created here so the contrast fails, if it fails, for the question asked.
    return scratch, [f'mkdir -p {scratch}/home && ditto -x -k {shlex.quote(str(bundle_zip))} {scratch}',
                     f'HOME={scratch}/home RICHOS_ACTIVATION=regular \\',
                     f"    '{scratch}/RichOS.app/Contents/MacOS/richos-tauri'"]


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('vm')
    p.add_argument('--zip', required=True, type=Path)
    p.add_argument('--before-lib', required=True, type=Path, help='the pre-fix lib/gui-launch.sh')
    p.add_argument('--out', required=True, type=Path)
    a = p.parse_args()
    vm, out = a.vm, a.out
    out.mkdir(parents=True, exist_ok=False)
    state = Path(os.environ.get('TESTVM_ROOT', str(Path.home() / '.richos-testvm'))) / 'run' / vm
    result = {'vm': vm, 'zip': a.zip.name, 'zip_sha256': sha256(a.zip),
              'after_lib_sha256': sha256(AFTER_LIB), 'before_lib_sha256': sha256(a.before_lib),
              'started_at': utc(), 'checks': {}, 'steps': [], 'phases': {}, 'verdict': 'in progress'}

    def save():
        (out / 'report.json').write_text(json.dumps(result, indent=2) + '\n')

    def step(name, **kw):
        result['steps'].append({'step': name, 'at': utc(), **kw})
        save()
        print(f'[walk] {name}: ' + ', '.join(f'{k}={v}' for k, v in kw.items() if not isinstance(v, (list, dict)))[:400], flush=True)

    def check(name, ok, detail=None):
        result['checks'][name] = {'ok': bool(ok), 'detail': detail}
        save()
        print(f'[walk] {"PASS" if ok else "FAIL"} {name}', flush=True)
        return ok

    def g(cmd, timeout=60):
        return guest(vm, cmd, timeout)

    def gr(cmd, timeout=120):
        r = subprocess.run([str(HERE / 'guest.sh'), vm, cmd], capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout, r.stderr

    def push(local, remote):
        subprocess.run([str(HERE / 'guest.sh'), vm, '--push', str(local), remote], check=True, timeout=300,
                       capture_output=True)

    def alive(pid):
        return gr(f'kill -0 {pid} 2>/dev/null')[0] == 0

    def quit_pid(pid, label):
        """Quit an instance THIS walk started, by the pid captured when it started."""
        gr(f'kill -TERM {pid} 2>/dev/null')
        forced = False
        for _ in range(30):
            if not alive(pid):
                break
            time.sleep(0.5)
        else:
            forced = True
            gr(f'kill -KILL {pid} 2>/dev/null')
            time.sleep(1)
        listed = gr(f'ps -p {pid} -o pid= 2>/dev/null || true')[1].strip()
        gone = not alive(pid) and not listed
        step(f'quit {label}', pid=pid, forced=forced, gone=gone)
        return gone

    def real_library():
        return [l for l in g(FIND_RICHOS.format(lib='~/Library'), 60).splitlines() if l]

    def clear_real_library():
        # The guest is a disposable clone and these are the previous launch's own writes.
        for path in real_library():
            gr('rm -rf ' + shlex.quote(path))
        left = real_library()
        if left:
            raise RuntimeError('could not clear the guest ~/Library of richos entries: ' + ', '.join(left))

    def wait_log(path, needle, seconds):
        end = time.monotonic() + seconds
        text = ''
        while time.monotonic() < end:
            text = gr('cat ' + shlex.quote(path) + ' 2>/dev/null || true', 60)[1]
            if needle in text:
                return True, text
            time.sleep(2)
        return False, text

    def app_env(pid):
        line = g(f'ps -wwE -p {pid} -o command= 2>/dev/null || true')
        toks = line.split()

        def val(key):
            return next((t.split('=', 1)[1] for t in toks if t.startswith(key + '=')), None)
        return {k: val(k) for k in ('HOME', 'CFFIXED_USER_HOME', 'TMPDIR', 'PATH', 'SCRATCH_WALK_CANARY')}

    def record(label, home):
        leaked = real_library()
        moved = [l for l in g(FIND_RICHOS.format(lib=shlex.quote(home + '/Library')), 60).splitlines() if l]
        result['phases'][label] = dict(result['phases'].get(label, {}), home=home, real_library=leaked,
                                       scratch_library=moved)
        step(f'{label}: recorded', leaked=len(leaked), in_scratch=len(moved))
        return leaked, moved

    started = []
    try:
        payload = (state / 'payload').read_text().strip()
        ghome = g('printf %s "$HOME"')
        W = ghome + '/scratch-home-walk'
        result.update(guest_home=ghome, walk_dir=W, payload=payload)

        # ---- 0. the run.sh instance: stop it by its recorded pid; record what it wrote --------
        old = (state / 'app.pid').read_text().strip()
        comm = g(f'ps -p {old} -o comm= 2>/dev/null || true') if old.isdigit() else ''
        if comm and payload in comm and comm.endswith('/richos-tauri'):
            quit_pid(old, 'the run.sh instance')
        else:
            step('run.sh instance already gone', pid=old, comm=comm)
        result['run_sh_instance_wrote_to_real_library'] = real_library()
        step('run.sh instance writes recorded', paths=len(result['run_sh_instance_wrote_to_real_library']))

        # ---- 1. the walk's files -----------------------------------------------------------
        g('rm -rf ' + shlex.quote(W) + ' && mkdir -p ' + shlex.quote(W))
        push(a.zip, W + '/' + a.zip.name)
        push(a.before_lib, W + '/gui-launch.before.sh')
        push(AFTER_LIB, W + '/gui-launch.after.sh')
        gzip = W + '/' + a.zip.name
        check('the ZIP in the guest is the ZIP named',
              g('shasum -a 256 ' + shlex.quote(gzip) + " | cut -d' ' -f1") == result['zip_sha256'])

        # ---- 2. gui_boot, before and after --------------------------------------------------
        for label, lib in (('gui_boot before', 'gui-launch.before.sh'), ('gui_boot after', 'gui-launch.after.sh')):
            clear_real_library()
            machine = f'{W}/{label.replace(" ", "-")}.noindex'
            g(f'mkdir -p {shlex.quote(machine)}/Applications && ditto -x -k {shlex.quote(gzip)} '
              f'{shlex.quote(machine)}/Applications', 180)
            log = machine + '.log'
            pids = machine + '.pids'
            # gui_boot records every pid it starts and ends it before it returns.
            cmd = (f'cd {shlex.quote(W)} && : > {shlex.quote(pids)} && GUI_LAUNCHED_PIDS={shlex.quote(pids)} '
                   f'bash -c \'. ./{lib}; gui_boot "$1" "$2" 90\' _ {shlex.quote(machine)} {shlex.quote(log)}')
            rc, o, e = gr(cmd, 200)
            booted = '[richos] boot complete' in gr('cat ' + shlex.quote(log) + ' 2>/dev/null || true')[1]
            launched = [x for x in gr('cat ' + shlex.quote(pids))[1].split() if x.isdigit()]
            leftover = [x for x in launched if alive(x)]
            for x in leftover:
                quit_pid(x, label + ' leftover')
            result['phases'][label] = {'gui_boot_exit': rc, 'boot_complete': booted, 'pids': launched,
                                       'still_running_after_gui_boot': leftover}
            step(f'{label}: gui_boot', exit=rc, boot_complete=booted, pids=len(launched))
            (out / (label.replace(' ', '-') + '.log')).write_text(gr('cat ' + shlex.quote(log))[1])
            leaked, moved = record(label, machine)
            check(f'{label}: the process gui_boot started is gone', launched and not leftover, launched)
            if label.endswith('before'):
                result['contrast_gui_boot'] = bool(leaked)
                step('gui_boot before: contrast', reproduced=bool(leaked))
            else:
                check('gui_boot after: booted to completion', booted)
                # An absence proves something only if this search saw the leak it looks for.
                check('gui_boot after: the before launch leaked, so this search can see a leak',
                      result.get('contrast_gui_boot'), result['phases']['gui_boot before'].get('real_library'))
                check('gui_boot after: nothing naming richos in the real ~/Library', not leaked, leaked)
                result['phases'][label]['webkit_in_machine'] = any('/Library/WebKit/com.richos.app' in m for m in moved)

        # ---- 3. the walk recipe, before and after -------------------------------------------
        base = W + '/qa'
        g('mkdir -p ' + shlex.quote(base))
        for label, maker in (('recipe before', recipe_before), ('recipe after', recipe_after)):
            clear_real_library()
            run_id = label.replace(' ', '-')
            scratch, lines = maker(Path(gzip), run_id, base)
            scratch = str(scratch)
            home = scratch + '/home' if label.endswith('before') else scratch + '/home.noindex'
            (out / f'{run_id}.sh').write_text('\n'.join(lines) + '\n')
            script = f'{W}/{run_id}.sh'
            push(out / f'{run_id}.sh', script)
            log = f'{W}/{run_id}.log'
            # As printed, from a shell carrying a canary that must not reach the "after" app.
            # `$!` is the app: the recipe's last command is the app itself (env execs it).
            start = (f'cd {shlex.quote(W)} && export SCRATCH_WALK_CANARY=from-the-shell && '
                     f'(nohup bash {shlex.quote(script)} > {shlex.quote(log)} 2>&1 & echo $! > {shlex.quote(log)}.pid)')
            g(start, 240)
            ok, text = wait_log(log, '[richos] boot complete', 120)
            shell_pid = g('cat ' + shlex.quote(log + '.pid'))
            app_pid = g(f"pgrep -P {shell_pid} 2>/dev/null | head -1 || true") or shell_pid
            comm = g(f'ps -p {app_pid} -o comm= 2>/dev/null || true')
            env = app_env(app_pid) if comm.endswith('/richos-tauri') else {}
            time.sleep(8)          # the web view loads after setup; give WebKit its first writes
            started.append(app_pid)
            result['phases'][label] = {'boot_complete': ok, 'shell_pid': shell_pid, 'app_pid': app_pid,
                                       'comm': comm, 'app_env': env}
            step(f'{label}: started', boot_complete=ok, app_pid=app_pid)
            gone = quit_pid(app_pid, label)
            if shell_pid != app_pid and alive(shell_pid):
                quit_pid(shell_pid, label + ' shell')
            (out / f'{run_id}.log').write_text(gr('cat ' + shlex.quote(log))[1])
            leaked, moved = record(label, home)
            check(f'{label}: quit and gone', gone, app_pid)
            if label.endswith('before'):
                result['contrast_recipe'] = bool(leaked)
                step('recipe before: contrast', reproduced=bool(leaked))
            else:
                check('recipe after: booted to completion', ok)
                check('recipe after: HOME and CFFIXED_USER_HOME are both the scratch home, nothing from the shell',
                      env.get('HOME') == home and env.get('CFFIXED_USER_HOME') == home
                      and env.get('PATH') == '/usr/bin:/bin:/usr/sbin:/sbin' and env.get('SCRATCH_WALK_CANARY') is None,
                      env)
                check('recipe after: the before launch leaked, so this search can see a leak',
                      result.get('contrast_recipe'), result['phases']['recipe before'].get('real_library'))
                check('recipe after: nothing naming richos in the real ~/Library', not leaked, leaked)
                check("recipe after: WebKit's store is in the scratch home's own Library",
                      any('/Library/WebKit/com.richos.app' in m for m in moved), moved)

        leftovers = [l for l in g('ps -axo pid=,comm=').splitlines() if '/scratch-home-walk/' in l]
        check('no process from this walk remains', not leftovers, leftovers)
    except Exception as exc:  # recorded, then re-raised so run-walk.py reports the failure
        result['error'] = f'{type(exc).__name__}: {exc}'
        save()
        raise
    finally:
        for pid in started:
            try:
                comm = gr(f'ps -p {pid} -o comm= 2>/dev/null || true')[1].strip()
                if '/scratch-home-walk/' in comm:
                    quit_pid(pid, 'cleanup')
            except Exception as exc:
                result.setdefault('cleanup_errors', []).append(str(exc))
        result['finished_at'] = utc()
        failed = [k for k, v in result['checks'].items() if not v['ok']]
        result['failed_checks'] = failed
        result['verdict'] = 'error' if result.get('error') else ('pass' if not failed else 'fail')
        save()
        print(f'[walk] verdict: {result["verdict"]} ({len(result["checks"]) - len(failed)}/{len(result["checks"])} checks)', flush=True)
    return 0 if result['verdict'] == 'pass' else 1


if __name__ == '__main__':
    sys.exit(main())
