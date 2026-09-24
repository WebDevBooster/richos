#!/usr/bin/env python3
"""Walk scripts/nightly-launch.sh in a test guest: window, pinned engine, and nothing written outside.

Run by run-walk.py, which boots the guest, holds <TESTVM_ROOT>/guest.lock and removes the clone:

  reserve.py -- run-walk.py --bundle ZIP --home FIXTURE --engine ENGINE --report REPORT -- \\
      nightly-launch-walk.py --zip ZIP --pin SHA256 --out DIR

run-walk.py passes the owned VM name as the first argument.

WHAT IT PROVES, in the guest, never on the host's screen (CEO ruling §65):
  1. folder a, from the ZIP, started from a shell carrying a canary, CLAUDECODE, a LORO_CORPUS,
     an engine directory and a Homebrew PATH: a window appears, and the app's own environment
     carries the folder's HOME, CFFIXED_USER_HOME and TMPDIR, launchd's PATH, and none of those;
  2. the pinned engine installs through the app's ordinary setup, and its INSTALLED-FROM
     names the pin the build was compiled with;
  3. folder a started again from the same ZIP is not unpacked again, and resolves that
     engine "via application support";
  4. folder b, with a roster page, installs its own engine, and on its next start (--again)
     reads its own memory folder with the memory compiler present;
  5. a file-date search, proved by a positive control, over the guest's homes, /Library
     and the temporary folders: what the launched nightlies wrote outside their folders,
     with exactly four places declared and why (the two sign-in links, and WebKit's two
     per-user service caches, which no environment variable reaches);
  6. every instance this walk started is quit by its pid and verified gone.

WHAT IT DOES NOT PROVE: the Claude sign-in through the keychain link. The guest is signed
in through claude's credential FILE (claude-login.sh), which the linked ~/.claude carries;
his Mac signs in through the keychain. That half is his run, on his Mac.

The run.sh instance that run-walk.py starts is stopped first, by its recorded pid, and
what IT wrote into the guest's real ~/Library is recorded: it was launched with HOME
alone, which is the contrast for CFFIXED_USER_HOME.
"""
import argparse
import hashlib
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

LAUNCHER = HERE.parent / 'nightly-launch.sh'
SEARCH = HERE / 'files-since.py'


def utc():
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('vm')
    p.add_argument('--zip', required=True, type=Path)
    p.add_argument('--pin', required=True, help='the engine sha256 the build was compiled with')
    p.add_argument('--out', required=True, type=Path)
    p.add_argument('--baseline-seconds', type=int, default=60)
    a = p.parse_args()
    vm = a.vm
    out = a.out
    out.mkdir(parents=True, exist_ok=False)
    state = Path(os.environ.get('TESTVM_ROOT', str(Path.home() / '.richos-testvm'))) / 'run' / vm
    result = {'vm': vm, 'zip': a.zip.name, 'zip_sha256': sha256(a.zip), 'pin': a.pin,
              'started_at': utc(), 'checks': {}, 'steps': [], 'verdict': 'in progress'}

    def save():
        (out / 'report.json').write_text(json.dumps(result, indent=2) + '\n')

    def step(name, **kw):
        row = {'step': name, 'at': utc(), **kw}
        result['steps'].append(row)
        save()
        print(f'[walk] {name}: ' + ', '.join(f'{k}={v}' for k, v in kw.items() if not isinstance(v, (list, dict)))[:400], flush=True)
        return row

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

    def pull(remote, local):
        subprocess.run([str(HERE / 'guest.sh'), vm, '--pull', remote, str(local)], check=True, timeout=120,
                       capture_output=True)

    def ax(*args):
        r = subprocess.run([str(HERE / 'ax.sh'), vm, *args, '--json'], capture_output=True, text=True, timeout=40)
        return r.returncode, r.stdout

    def windows(pid):
        rc, o, _ = gr("osascript -e 'tell application \"System Events\" to count windows of "
                      f"(first process whose unix id is {pid})' 2>/dev/null || echo 0")
        try:
            return int(o.strip() or 0)
        except ValueError:
            return 0

    def alive(pid):
        rc, _, _ = gr(f'kill -0 {pid} 2>/dev/null')
        return rc == 0

    def quit_pid(pid, label):
        """Quit an instance THIS walk started, by the pid the launcher printed for it."""
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
        gone = not alive(pid)
        listed = gr(f'ps -p {pid} -o pid= 2>/dev/null || true')[1].strip()
        step(f'quit {label}', pid=pid, forced=forced, gone=gone and not listed)
        return gone and not listed

    def log_text(path):
        return gr('cat ' + shlex.quote(path) + ' 2>/dev/null || true', 60)[1]

    def wait_log(path, needle, seconds):
        end = time.monotonic() + seconds
        text = ''
        while time.monotonic() < end:
            text = log_text(path)
            if needle in text:
                return True, text
            time.sleep(2)
        return False, text

    def launch(label, args, extra_env=''):
        cmd = f'cd {shlex.quote(W)} && {extra_env} bash nightly-launch.sh {args}'
        rc, o, e = gr(cmd, 180)
        (out / f'launch-{label}.txt').write_text(f'$ nightly-launch.sh {args}\nexit {rc}\n{o}{e}')
        fields = {}
        for line in o.splitlines():
            for tok in line.split():
                if '=' in tok:
                    k, _, v = tok.partition('=')
                    fields[k] = v
        step(f'launch {label}', exit=rc, pid=fields.get('pid'), version=fields.get('version'), log=fields.get('log'))
        if rc != 0 or not fields.get('pid', '').isdigit():
            raise RuntimeError(f'launch {label} failed: {o}{e}')
        # Hand the pid to the harness, as relaunch.py does: ax.sh addresses it, and stop.sh
        # quits it if this walk dies before it does.
        (state / 'app.pid').write_text(fields['pid'] + '\n')
        return fields

    started = []
    try:
        payload = (state / 'payload').read_text().strip()
        ghome = g('printf %s "$HOME"')
        W = ghome + '/launcher-walk'
        folder_a = ghome + '/myrichos-nightly-a'
        folder_b = ghome + '/myrichos-nightly-b'
        result.update(guest_home=ghome, walk_dir=W, payload=payload)

        # ---- 0. the run.sh instance: stop it by its recorded pid, record what it wrote ----
        old = (state / 'app.pid').read_text().strip()
        comm = g(f'ps -p {old} -o comm= 2>/dev/null || true') if old.isdigit() else ''
        if comm and payload in comm and comm.endswith('/richos-tauri'):
            quit_pid(old, 'the run.sh instance (HOME only)')
        else:
            step('run.sh instance already gone', pid=old, comm=comm)
        contrast = g("find ~/Library -maxdepth 4 -iname '*richos*' 2>/dev/null | sort || true", 60)
        result['home_only_launch_wrote_to_real_library'] = contrast.splitlines()
        step('HOME-only contrast recorded', paths=len(contrast.splitlines()))

        # ---- 1. the walk's files -------------------------------------------------------
        g('rm -rf ' + shlex.quote(W) + ' && mkdir -p ' + shlex.quote(W))
        push(LAUNCHER, W + '/nightly-launch.sh')
        push(SEARCH, W + '/files-since.py')
        push(a.zip, W + '/' + a.zip.name)
        roster = out / 'fixture-roster.md'
        roster.write_text('# Team roster (fixture)\n\nFrank: expert advisor and devil\'s advocate.\n')
        push(roster, W + '/fixture-roster.md')
        guest_zip_sha = g('shasum -a 256 ' + shlex.quote(W + '/' + a.zip.name) + " | cut -d' ' -f1")
        check('the ZIP in the guest is the published ZIP', guest_zip_sha == result['zip_sha256'], guest_zip_sha)

        # ---- 2. the sign-in pieces the launcher links -----------------------------------
        fixture = []
        pieces = {}
        for piece in ['.claude', '.claude.json', 'Library/Keychains', '.local/bin/claude']:
            pieces[piece] = gr('test -e ' + shlex.quote(ghome + '/' + piece))[0] == 0
        if not pieces['.claude.json']:
            g("umask 077; printf '{}\\n' > ~/.claude.json")
            fixture.append('created an empty ~/.claude.json in the guest (it had none); the launcher copies it')
        result['guest_sign_in_pieces'] = pieces
        result['fixture_steps'] = fixture
        missing = [k for k, v in pieces.items() if not v and k != '.claude.json']
        if missing:
            raise RuntimeError('guest lacks ' + ', '.join(missing))
        real_cj_before = g('shasum -a 256 ~/.claude.json | cut -d" " -f1')
        step('sign-in pieces present', fixture=len(fixture))

        # ---- 3. the baseline window: what this guest writes when nothing runs ------------
        g(f'python3 {W}/files-since.py mark {W}/m0')
        time.sleep(a.baseline_seconds)
        g(f'python3 {W}/files-since.py mark {W}/m1')
        time.sleep(1.2)
        roots = [ghome, '/Users/Shared', '/Library', '/private/tmp', '/private/var/tmp', '/private/var/folders']
        root_args = ' '.join('--root ' + shlex.quote(r) for r in roots)
        rc, _, e = gr(f'python3 {W}/files-since.py scan --since {W}/m0 --until {W}/m1 {root_args} '
                      f'> {W}/baseline.json 2>{W}/baseline.err', 600)
        step('baseline window scanned', seconds=a.baseline_seconds, exit=rc)

        # ---- 4. folder a, from the ZIP, launched from a shell carrying things it must not pass on
        def wait_window(pid):
            n = 0
            for _ in range(60):
                n = windows(pid)
                if n >= 1:
                    break
                time.sleep(1)
            return n

        def app_env(pid, folder):
            line = g(f'ps -wwE -p {pid} -o command= 2>/dev/null || true')
            toks = line.split()

            def val(key):
                return next((t.split('=', 1)[1] for t in toks if t.startswith(key + '=')), None)
            facts = {k: val(k) for k in ('HOME', 'CFFIXED_USER_HOME', 'TMPDIR', 'PATH', 'LORO_CORPUS',
                                         'RICHOS_ENGINE_DIR', 'RICHOS_ACTIVATION', 'CLAUDECODE')}
            facts['shell_canary_reached_app'] = val('LAUNCHER_WALK_CANARY') is not None
            facts['shell_values_reached_app'] = '/nonexistent/from-the-shell' in line
            ok = (facts['HOME'] == folder + '/home.noindex' and facts['CFFIXED_USER_HOME'] == folder + '/home.noindex'
                  and facts['TMPDIR'] == folder + '/home.noindex/tmp/' and facts['PATH'] == '/usr/bin:/bin:/usr/sbin:/sbin'
                  and not facts['shell_canary_reached_app'] and not facts['shell_values_reached_app']
                  and facts['CLAUDECODE'] is None and facts['RICHOS_ENGINE_DIR'] in (None, ''))
            return ok, facts

        def setup_engine(label, log, folder):
            """The app's ordinary setup sheet: press "Set it up", wait for the engine, close it."""
            booted, text = wait_log(log, 'boot complete', 60)
            step(f'{label}: boot', complete=booted)
            if 'first-run setup: nothing missing.' not in text:
                rc, tree = ax('tree', '--in', 'dialog')
                (out / f'{label}-setup-dialog.jsonl').write_text(tree)
                rc, _ = ax('click', '--title', 'Set it up', '--role', 'AXButton', '--first')
                step(f'{label}: pressed "Set it up"', exit=rc)
                done, text = wait_log(log, '[richos] setup: engine ', 420)
                step(f'{label}: engine setup logged', done=done)
                subprocess.run([str(HERE / 'shot.sh'), vm, str(out / f'{label}-setup-finished.png')], timeout=60,
                               capture_output=True)
                for _ in range(60):
                    rc, tree = ax('tree', '--in', 'dialog')
                    if any('"Close"' in line and 'AXButton' in line for line in tree.splitlines()):
                        ax('click', '--title', 'Close', '--role', 'AXButton', '--first')
                        step(f'{label}: closed the setup sheet')
                        break
                    time.sleep(0.5)
            stamp = log_text(folder + '/home.noindex/Library/Application Support/RichOS/engine/INSTALLED-FROM')
            result[f'{label}_installed_from'] = stamp
            return ('sha256 ' + a.pin) in stamp, stamp

        shell_env = ('export LAUNCHER_WALK_CANARY=from-the-shell CLAUDECODE=1 LORO_CORPUS=/nonexistent/from-the-shell '
                     'RICHOS_ENGINE_DIR=/nonexistent/from-the-shell PATH=/opt/homebrew/bin:$PATH &&')
        f = launch('a-first', f'a {shlex.quote(W + "/" + a.zip.name)}', shell_env)
        pid = f['pid']; started.append(pid); log_a1 = f['log']
        n = wait_window(pid)
        check('a: the window appears', n >= 1, {'pid': pid, 'windows': n})
        subprocess.run([str(HERE / 'shot.sh'), vm, str(out / 'a-first-window.png')], timeout=60, capture_output=True)
        ok, facts = app_env(pid, folder_a)
        result['a_app_environment'] = facts
        check("a: the app runs on the folder's HOME, CFFIXED_USER_HOME and TMPDIR, launchd's PATH, and nothing from the shell",
              ok, facts)

        # ---- 5. the pinned engine installs through ordinary setup -----------------------
        ok, stamp = setup_engine('a', log_a1, folder_a)
        check('a: the pinned engine installed (INSTALLED-FROM names the compiled pin)', ok, stamp)
        (out / 'a-first.log').write_text(log_text(log_a1))
        check('a: first instance quit and gone', quit_pid(pid, 'a first'))

        # ---- 6. folder a again, same ZIP: no unpack, the pinned engine resolves ---------
        marker = folder_a + '/nightly-launch.txt'
        unpacked_before = g('sed -n "s/^unpacked_at=//p" ' + shlex.quote(marker))
        f = launch('a-again', f'a {shlex.quote(W + "/" + a.zip.name)}')
        pid = f['pid']; started.append(pid)
        unpacked_after = g('sed -n "s/^unpacked_at=//p" ' + shlex.quote(marker))
        check('a again: the same ZIP is not unpacked again', unpacked_before == unpacked_after,
              [unpacked_before, unpacked_after])
        n = wait_window(pid)
        check('a again: the window appears', n >= 1, {'pid': pid, 'windows': n})
        booted, text = wait_log(f['log'], 'boot complete', 60)
        engine_line = next((l for l in text.splitlines() if '[richos] engine directory:' in l), '')
        result['a_again_engine_line'] = engine_line
        check('a again: the engine resolves via application support, carrying the pin',
              a.pin[:12] in engine_line and 'via application support' in engine_line, engine_line)
        subprocess.run([str(HERE / 'shot.sh'), vm, str(out / 'a-again-window.png')], timeout=60, capture_output=True)
        (out / 'a-again.log').write_text(text)
        check('a again: quit and gone', quit_pid(pid, 'a again'))

        # ---- 7. folder b, with a roster page: its engine, then its memory ----------------
        f = launch('b-first', f'b {shlex.quote(W + "/" + a.zip.name)} --roster {shlex.quote(W + "/fixture-roster.md")}')
        pid = f['pid']; started.append(pid)
        n = wait_window(pid)
        check('b: the window appears', n >= 1, {'pid': pid, 'windows': n})
        ok, stamp = setup_engine('b', f['log'], folder_b)
        check('b: its own pinned engine installed', ok, stamp)
        (out / 'b-first.log').write_text(log_text(f['log']))
        check('b: first instance quit and gone', quit_pid(pid, 'b first'))
        f = launch('b-again', 'b --again')
        pid = f['pid']; started.append(pid)
        n = wait_window(pid)
        check('b again: the window appears', n >= 1, {'pid': pid, 'windows': n})
        booted, text = wait_log(f['log'], 'boot complete', 60)
        pointer = g('readlink ' + shlex.quote(folder_b + '/home.noindex/Library/Application Support/RichOS/loro-root') + ' || true')
        roster_ok = gr('cmp -s ' + shlex.quote(W + '/fixture-roster.md') + ' '
                       + shlex.quote(folder_b + '/memory/wiki/team-roster.md'))[0] == 0
        loro_lines = [l for l in text.splitlines() if 'loro' in l.lower()]
        result['b_loro_lines'] = loro_lines[:20]
        check('b: its memory pointer is its own memory folder, carrying the roster page',
              pointer == folder_b + '/memory' and roster_ok, {'pointer': pointer, 'roster_copied': roster_ok})
        check('b: the app reads that memory folder with its memory compiler installed',
              any('loro-root' in l or folder_b + '/memory' in l for l in loro_lines)
              and not any('not installed' in l or 'not found' in l for l in loro_lines), loro_lines[:8])
        subprocess.run([str(HERE / 'shot.sh'), vm, str(out / 'b-again-window.png')], timeout=60, capture_output=True)
        (out / 'b-again.log').write_text(text)
        check('b again: quit and gone', quit_pid(pid, 'b again'))

        status = gr(f'cd {shlex.quote(W)} && bash nightly-launch.sh status')[1]
        (out / 'status.txt').write_text(status)
        leftovers = [l for l in g('ps -axo pid=,ppid=,comm=').splitlines() if '/myrichos-nightly-' in l]
        check('no process from either folder remains', not leftovers, leftovers)
        real_cj_after = g('shasum -a 256 ~/.claude.json | cut -d" " -f1')
        check('the real ~/.claude.json was read, never written', real_cj_before == real_cj_after,
              [real_cj_before, real_cj_after])
        # Informational: whether Spotlight, if it indexes this guest at all, lists either
        # nightly bundle. The .noindex folders are meant to keep both out of it.
        result['spotlight'] = {
            'mdutil': gr('mdutil -s / 2>&1 | tail -1')[1].strip(),
            'mdfind_richos_bundles': gr("mdfind 'kMDItemCFBundleIdentifier == \"com.richos.app\"' 2>&1 | head -20")[1].splitlines(),
        }
        step('spotlight probe', mdutil=result['spotlight']['mdutil'], found=len(result['spotlight']['mdfind_richos_bundles']))

        # ---- 8. the file-date search, with its positive control --------------------------
        # Two places are DECLARED, with the reason, and nothing else: WebKit's GPU and
        # Networking XPC services are started by launchd outside the app's environment and
        # keep per-user caches under the OS's own per-user folders, named for the app's
        # bundle identifier. No environment variable reaches them (run 1 of this walk,
        # 2026-09-24, measured them there with HOME and CFFIXED_USER_HOME both set). They hold
        # shader and blob caches, no RichOS data. Any OTHER write naming richos still fails.
        ucache = g('getconf DARWIN_USER_CACHE_DIR').rstrip('/')
        utemp = g('getconf DARWIN_USER_TEMP_DIR').rstrip('/')
        os_caches = [
            (ucache + '/com.apple.WebKit.GPU+com.richos.app',
             "WebKit's GPU service cache, per user and bundle id, outside any environment's reach"),
            (utemp + '/com.apple.WebKit.Networking+com.richos.app',
             "WebKit's Networking service temp, per user and bundle id, outside any environment's reach"),
        ]
        result['declared_os_caches'] = [p for p, _ in os_caches]
        control = ghome + '/Library/Application Support/richos-launcher-walk-positive-control.txt'
        g('printf control > ' + shlex.quote(control))
        time.sleep(1.2)
        declared = [(ghome + '/.claude', 'linked from the folder home by design (sign-in, readiness review point 6)'),
                    (ghome + '/Library/Keychains', 'linked from the folder home by design (sign-in, readiness review point 6)'),
                    *os_caches]
        declared_args = ' '.join('--declared ' + shlex.quote(p + '=' + why) for p, why in declared)
        args = (f'python3 {W}/files-since.py scan --since {W}/m1 {root_args} '
                f'--inside {shlex.quote(folder_a)} --inside {shlex.quote(folder_b)} {declared_args} '
                f'--harness {shlex.quote(W)} --harness {shlex.quote(payload)} '
                f'--baseline {W}/baseline.json --control {shlex.quote(control)} --named richos '
                f'> {W}/search.json 2>{W}/search.err')
        rc, _, _ = gr(args, 900)
        pull(W + '/search.json', out / 'search.json')
        pull(W + '/baseline.json', out / 'baseline.json')
        search = json.loads((out / 'search.json').read_text())
        result['search'] = {k: search[k] for k in ('verdict', 'counts', 'controls_missing',
                                                   'controls_not_flagged_named', 'unreadable_count')}
        result['search']['named'] = [r['path'] for r in search['files'] if r['class'] == 'named']
        result['search']['declared'] = [r['path'] for r in search['files'] if r['class'] == 'declared']
        result['search']['other'] = [r['path'] for r in search['files'] if r['class'] == 'other']
        check('search: the positive control was found and would have been flagged', search['verdict'] != 'search-broken',
              search['controls_missing'] + search['controls_not_flagged_named'])
        check('search: nothing named "richos" was written outside the two folders, beyond the declared places',
              search['verdict'] == 'pass', result['search']['named'])
        step('file-date search', exit=rc, verdict=search['verdict'], counts=search['counts'])
    except Exception as exc:  # recorded, then re-raised so run-walk.py reports the failure
        result['error'] = f'{type(exc).__name__}: {exc}'
        save()
        raise
    finally:
        # Every instance this walk started, by the pid the launcher printed for it.
        for pid in started:
            try:
                # Only while that pid is still one of ours: a nightly under a walk folder.
                comm = gr(f'ps -p {pid} -o comm= 2>/dev/null || true')[1].strip()
                if '/myrichos-nightly-' in comm:
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
