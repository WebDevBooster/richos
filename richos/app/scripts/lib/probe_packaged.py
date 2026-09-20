#!/usr/bin/env python3
"""Headless delivery probe: app identity and the engine's Loro compiler only.

Allowed reads: the staged delivery, macOS system libraries and device files.
No checkout, user home, global Node modules or network. External providers are
not invoked: Claude, transcription models and other provider installations
remain outside this probe's claim. Full application acceptance belongs in a VM.
"""
import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tarfile
import tempfile


class ProbeCleanupError(RuntimeError):
    pass


@contextmanager
def staging(prefix):
    path = Path(tempfile.mkdtemp(prefix=prefix)).resolve()
    try:
        yield path
    except ProbeCleanupError as error:
        # A process blocked in the kernel may not reap even after KILL. Retain
        # its files and name the owned PID instead of deleting a live workspace.
        raise ProbeCleanupError(f"{error}; staging retained at {path}") from None
    except BaseException:
        shutil.rmtree(path)
        raise
    else:
        shutil.rmtree(path)


def profile(root):
    # /System includes the sealed dyld cache in Preboot Cryptexes.
    # dyld also opens the root directory while locating that cache; allow only
    # that directory itself, never a recursive read grant for the filesystem.
    # Filesystem enforcement is needed even with NODE_PATH cleared. A relative
    # import or a symlink can otherwise reach an intact dependency outside stage.
    # Approach inspired by T3 Code build-desktop-artifact.ts at d6f291303ddc.
    reads = [root.resolve(), Path('/System'), Path('/usr/lib'),
             Path('/usr/share/icu'), Path('/private/var/db/dyld')]
    return ('(version 1)(deny default)(allow process-exec)(allow sysctl-read)'
            '(allow mach-lookup)(allow file-read-metadata)'
            '(allow file-read* ' + ' '.join('(subpath ' + json.dumps(str(p)) + ')' for p in reads)
            + ' (literal "/") (literal "/dev/null") (literal "/dev/random") (literal "/dev/urandom"))'
            '(allow file-write* (subpath ' + json.dumps(str(root.resolve())) + '))')


def run(root, args, *, policy=None):
    env = {'HOME': str(root / 'home'), 'TMPDIR': str(root / 'home'),
           'PATH': str(root / 'engine/runtime/bin'), 'NODE_PATH': '', 'LC_ALL': 'C'}
    command = ['/usr/bin/sandbox-exec', '-p', policy or profile(root), *map(str, args)]
    p = subprocess.Popen(command, cwd=root, env=env, stdin=subprocess.DEVNULL,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                         start_new_session=True)
    try:
        out, err = p.communicate(timeout=15)
        if p.returncode:
            raise ValueError(f'packaged component refused inside isolation (exit {p.returncode}): ' + err[-1000:])
        return out
    finally:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            p.wait(timeout=3)
        except subprocess.TimeoutExpired:
            raise ProbeCleanupError(f"probe process {p.pid} did not reap after KILL") from None
        finally:
            p.stdout.close()
            p.stderr.close()


def compiler(root, *, policy=None):
    return run(root, [root / 'engine/runtime/bin/node', '--no-global-search-paths',
                      root / 'engine/loro/bin/loro-context.mjs', 'compile',
                      '--corpus', root / 'corpus', '--topic', 'packaging probe',
                      '--now', '2026-01-01T00:00:00Z'], policy=policy)


def guard_controls(root):
    intact = json.loads(compiler(root))
    dependency = root / 'engine/loro/lib/coverage.js'
    # The external copy is valid ESM and remains present for BOTH negative
    # controls. A missing file alone would prove nothing about confinement.
    with staging('richos-probe-outside-') as temp:
        outside = temp / 'coverage.mjs'
        shutil.copy2(dependency, outside)
        dependency.unlink()
        dependency.symlink_to(outside)
        cleanup_complete = True
        try:
            try:
                compiler(root)
            except ValueError:
                pass
            else:
                raise ValueError('guard-the-guard: external dependency satisfied the isolated probe')
            # Mutation control: removing only the read defense makes the same
            # broken delivery pass. Refusing every probe cannot satisfy this.
            open_reads = profile(root) + '(allow file-read*)'
            if json.loads(compiler(root, policy=open_reads)) != intact:
                raise ValueError('guard-the-guard: external positive control changed compiler output')
        except ProbeCleanupError:
            cleanup_complete = False
            raise
        finally:
            if cleanup_complete:
                dependency.unlink()
                shutil.copy2(outside, dependency)
    if json.loads(compiler(root)) != intact:
        raise ValueError('guard-the-guard: restored delivery did not recover')


def probe(app, archive, expected_sha):
    with archive.open('rb') as f:
        if hashlib.file_digest(f, 'sha256').hexdigest() != expected_sha:
            raise ValueError('engine archive does not match the declared compiled pin')
    with staging('richos-packaged-probe-') as root:
        (root / 'home').mkdir()
        (root / 'corpus/ceo').mkdir(parents=True)
        staged = root / 'RichOS.app'
        subprocess.run(['/usr/bin/ditto', str(app), str(staged)], check=True, timeout=30)
        with tarfile.open(archive) as tar:
            tar.extractall(root, filter='data')
        info = plistlib.loads((staged / 'Contents/Info.plist').read_bytes())
        exe = staged / 'Contents/MacOS' / info['CFBundleExecutable']
        identity = json.loads(run(root, [exe, '--richos-internal-update-identity']))
        if (identity.get('identifier') != 'com.richos.app'
                or identity.get('version') != info['CFBundleShortVersionString']):
            raise ValueError('isolated app identity differs from its bundle')
        guard_controls(root)
    print('packaged probe: app identity, Loro compilation and isolation defeat controls passed')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--engine-archive', type=Path, required=True)
    parser.add_argument('--engine-sha256', required=True)
    args = parser.parse_args()
    probe(args.app, args.engine_archive, args.engine_sha256)
