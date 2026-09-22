#!/usr/bin/env python3
"""Admit heavy work by measured CPU and memory. Example: reserve.py -- COMMAND ARGS...

CEO ruling §77 (2026-09-22): test runs and development builds, including land
checks, are admitted by the CPU rule alone and do not take the nightly
release.lock. Pass --release-lock only for a command that writes nightly or
release state; the nightly/release commands hold that lock themselves.

Admission is one cheap in-process sample (the kernel's own counters, read with
host_statistics and sysctl: no top, no lsof, no subprocess). It refuses when
user CPU is at or above --max-cpu (default 80%) or when the machine is swapping
hard (kernel pressure CRITICAL, or swap-out at or above --max-swapout-mb-s
during the sample). --wait N retries for at most N seconds, one sample every
--retry-every seconds (at least 30), and reports how long it waited.

--low-priority is CEO ruling §78's mode for the 30-hour native build: the CPU
line is not applied, the memory rule and the backoff still are, and the command
runs under nice -n 10. Every use is announced. When that build ends, the 80%
line applies again: stop passing the flag.
"""
import argparse
from contextlib import contextmanager, ExitStack
import ctypes
import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import math

MIN_RETRY_SECONDS = 30
LOW_PRIORITY_NICE = 10
MAX_WAIT_SECONDS = 3600
PRESSURE_NAMES = {1: 'normal', 2: 'warn', 4: 'critical'}


class _CpuLoad(ctypes.Structure):
    # host_cpu_load_info: ticks[CPU_STATE_MAX]; USER=0, SYSTEM=1, IDLE=2, NICE=3
    _fields_ = [('ticks', ctypes.c_uint * 4)]


class _Vm64(ctypes.Structure):
    # vm_statistics64 (<mach/vm_statistics.h>), HOST_VM_INFO64_COUNT = 38 words
    _fields_ = ([(n, ctypes.c_uint) for n in ('free_count', 'active_count', 'inactive_count', 'wire_count')]
                + [(n, ctypes.c_uint64) for n in ('zero_fill_count', 'reactivations', 'pageins', 'pageouts',
                                                  'faults', 'cow_faults', 'lookups', 'hits', 'purges')]
                + [(n, ctypes.c_uint) for n in ('purgeable_count', 'speculative_count')]
                + [(n, ctypes.c_uint64) for n in ('decompressions', 'compressions', 'swapins', 'swapouts')]
                + [(n, ctypes.c_uint) for n in ('compressor_page_count', 'throttled_count',
                                                'external_page_count', 'internal_page_count')]
                + [('total_uncompressed_pages_in_compressor', ctypes.c_uint64)])


class _SwapUsage(ctypes.Structure):
    _fields_ = [('total', ctypes.c_uint64), ('avail', ctypes.c_uint64), ('used', ctypes.c_uint64),
                ('pagesize', ctypes.c_uint32), ('encrypted', ctypes.c_int)]


_KERNEL = {}


def _kernel():
    """libSystem and one host port, opened once per process."""
    if not _KERNEL:
        lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
        lib.mach_host_self.restype = ctypes.c_uint
        _KERNEL.update(lib=lib, host=lib.mach_host_self())
    return _KERNEL['lib'], _KERNEL['host']


def _sysctl(name, value):
    lib, _ = _kernel()
    size = ctypes.c_size_t(ctypes.sizeof(value))
    if lib.sysctlbyname(name.encode(), ctypes.byref(value), ctypes.byref(size), None, ctypes.c_size_t(0)):
        raise OSError(ctypes.get_errno(), 'sysctl ' + name)
    return value


def _counters():
    lib, host = _kernel()
    cpu, n = _CpuLoad(), ctypes.c_uint(4)
    if lib.host_statistics(host, 3, ctypes.byref(cpu), ctypes.byref(n)):          # HOST_CPU_LOAD_INFO
        raise OSError('host_statistics(HOST_CPU_LOAD_INFO) failed')
    vm, m = _Vm64(), ctypes.c_uint(ctypes.sizeof(_Vm64) // 4)
    if lib.host_statistics64(host, 4, ctypes.byref(vm), ctypes.byref(m)):          # HOST_VM_INFO64
        raise OSError('host_statistics64(HOST_VM_INFO64) failed')
    return list(cpu.ticks), vm.swapouts


def host_sample(interval=1.0):
    """One admission sample: CPU split and swap activity over `interval`, plus the
    kernel's memory-pressure level, its free-memory percentage and swap in use.
    Fails closed: anything unreadable raises BlockingIOError."""
    try:
        ticks0, out0 = _counters()
        time.sleep(interval)
        ticks1, out1 = _counters()
        page = _sysctl('hw.pagesize', ctypes.c_int()).value
        level = _sysctl('kern.memorystatus_vm_pressure_level', ctypes.c_int()).value
        free = _sysctl('kern.memorystatus_level', ctypes.c_int()).value
        swap = _sysctl('vm.swapusage', _SwapUsage())
    except (OSError, AttributeError) as exc:
        raise BlockingIOError('CPU/memory measurement unavailable; admission refused: ' + str(exc)) from exc
    delta = [(b - a) % 2**32 for a, b in zip(ticks0, ticks1)]
    total = sum(delta)
    if total <= 0:
        raise BlockingIOError('CPU measurement unavailable; the tick counters did not advance')
    pct = [100.0 * d / total for d in delta]
    return {'cpu_user_percent': pct[0] + pct[3], 'cpu_system_percent': pct[1], 'cpu_idle_percent': pct[2],
            'swapout_mb_per_s': (out1 - out0) * page / 1048576 / interval,
            'memory_pressure': PRESSURE_NAMES.get(level, str(level)), 'memory_free_percent': free,
            'swap_used_mb': swap.used / 1048576}


def cpu_busy_percent():
    """The CPU figure admission uses: user (+nice) time, not user+system. Under
    memory pressure the kernel's compressor and pager inflate system time while
    the processes asking for CPU are not busy; that condition is judged by the
    memory rule, beside it, rather than read as a full CPU."""
    return host_sample()['cpu_user_percent']


def _refusal(s, max_cpu, max_swapout, cpu_rule=True):
    if cpu_rule and s['cpu_user_percent'] >= max_cpu:
        return f"user CPU is {s['cpu_user_percent']:.1f}% (limit {max_cpu:g}%)"
    if s['memory_pressure'] == 'critical':
        return 'kernel memory pressure is CRITICAL'
    if s['swapout_mb_per_s'] >= max_swapout:
        return f"swapping out {s['swapout_mb_per_s']:.1f} MB/s (limit {max_swapout:g} MB/s)"
    return ''


def describe(s):
    return (f"user CPU {s['cpu_user_percent']:.1f}%, system {s['cpu_system_percent']:.1f}%, "
            f"idle {s['cpu_idle_percent']:.1f}%; memory pressure {s['memory_pressure']}, "
            f"free {s['memory_free_percent']}%, swap used {s['swap_used_mb']:.0f} MB, "
            f"swap-out {s['swapout_mb_per_s']:.1f} MB/s")


def cpu_admission(max_cpu=80, wait_seconds=0, retry_every=MIN_RETRY_SECONDS, max_swapout=16, cpu_rule=True):
    """Bounded admission before work or a paid send; never infer jobs from load.
    Retries at most every `retry_every` (>= 30) seconds, never spins.
    `cpu_rule=False` is the low-priority mode (CEO ruling §78): the CPU line is
    not applied, the memory rule still is."""
    if not math.isfinite(max_cpu) or not 0 < max_cpu <= 100:
        raise ValueError('max_cpu must be greater than 0 and at most 100')
    if not math.isfinite(wait_seconds) or not 0 <= wait_seconds <= MAX_WAIT_SECONDS:
        raise ValueError(f'admission wait must be between 0 and {MAX_WAIT_SECONDS} seconds')
    if not math.isfinite(retry_every) or retry_every < MIN_RETRY_SECONDS:
        raise ValueError(f'samples are at least {MIN_RETRY_SECONDS} seconds apart')
    if not math.isfinite(max_swapout) or max_swapout <= 0:
        raise ValueError('max_swapout must be a positive number of MB/s')
    started = time.monotonic()
    samples = 0
    while True:
        s = host_sample()
        samples += 1
        elapsed = time.monotonic() - started
        why = _refusal(s, max_cpu, max_swapout, cpu_rule)
        if not why:
            return {**s, 'cpu_busy_percent': s['cpu_user_percent'], 'load': os.getloadavg()[0],
                    'admission_wait_seconds': elapsed, 'admission_samples': samples}
        remaining = wait_seconds - elapsed
        if remaining <= 0:
            raise BlockingIOError(f'{why}; admission refused after {elapsed:.0f}s and {samples} sample(s). '
                                  f'{describe(s)}. Load average alone does not identify another running job.')
        print(f'admission waiting: {why}; next sample in {min(retry_every, remaining):.0f}s', file=sys.stderr,
              flush=True)
        time.sleep(min(retry_every, remaining))


@contextmanager
def exclusive_lock(path):
    """Hold one nonblocking exclusive flock on `path` for the whole interval."""
    path = Path(path)
    parent = path.parent
    parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if parent.is_symlink() or parent.stat().st_uid != os.getuid():
        raise ValueError('lock directory must be owned by the current user and not a symlink: ' + str(parent))
    with path.open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise BlockingIOError('reservation unavailable: ' + str(path)) from None
        print('reservation held: ' + str(path.resolve()), file=sys.stderr, flush=True)
        try:
            yield path.resolve()
        finally:
            print('reservation released', file=sys.stderr, flush=True)


@contextmanager
def reservation(state=None, max_load=None, max_cpu=80, release_lock=False, lock=None,
                wait_seconds=0, retry_every=MIN_RETRY_SECONDS, max_swapout=16, low_priority=False):
    """Admission for heavy work (CEO ruling §77).

    `low_priority=True` is CEO ruling §78's explicit mode for the 30-hour native
    build: the CPU line is not applied (the memory rule and the backoff still
    are) and the caller runs the command under `nice -n LOW_PRIORITY_NICE`. It
    is announced on every use; it is never a default.

    By default this is the CPU rule alone (with the memory rule beside it, see
    `cpu_admission`): nothing is locked and nothing under
    the nightly state directory is touched, so test runs and development builds
    never queue behind one another or behind a nightly. `release_lock=True`
    additionally holds `<state>/release.lock`, the lock `nightly-local.py`'s
    `exclusive()` takes; use it only for work that writes nightly/release state.
    `lock` holds a different single-owner resource lock (the test VM guest).
    Locks are taken first, so a held lock refuses without spending a sample."""
    if release_lock and state is None:
        raise ValueError('release_lock needs the nightly state directory')
    with ExitStack() as held:
        paths = []
        if release_lock:
            state = Path(state)
            paths.append(held.enter_context(exclusive_lock(state / 'release.lock')))
        if lock is not None:
            paths.append(held.enter_context(exclusive_lock(lock)))
        if max_load is not None:
            # Explicit opt-in for a controlled benchmark's historical load criterion.
            if not math.isfinite(max_load) or max_load <= 0 or os.getloadavg()[0] >= max_load:
                raise BlockingIOError('load is above the explicitly requested limit; admission refused')
        else:
            sample = cpu_admission(max_cpu, wait_seconds, retry_every, max_swapout, cpu_rule=not low_priority)
            print(f"admission: {describe(sample)}; waited {sample['admission_wait_seconds']:.0f}s over "
                  f"{sample['admission_samples']} sample(s); load {sample['load']:.2f} is informational",
                  file=sys.stderr, flush=True)
            if low_priority:
                over = sample['cpu_user_percent'] >= max_cpu
                print(f"LOW PRIORITY (CEO ruling §78): the {max_cpu:g}% CPU line was NOT applied"
                      f"{' and user CPU is over it' if over else ''}; the command runs under "
                      f"nice -n {LOW_PRIORITY_NICE}. The memory rule was applied.", file=sys.stderr, flush=True)
        if not paths:
            print('admitted without a lock (CEO ruling §77)', file=sys.stderr, flush=True)
        yield paths[0] if paths else None


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--state-dir', type=Path, default=Path.home()/'.richos-nightly',
                   help='same --state-dir as nightly-local.py; read only with --release-lock')
    p.add_argument('--release-lock', action='store_true',
                   help='also hold <state-dir>/release.lock: only for work that writes nightly/release state')
    p.add_argument('--max-load', type=float, help='opt in to a strict load-average gate for controlled measurements')
    p.add_argument('--max-cpu', type=float, default=80, help='maximum measured user CPU percentage (default: 80)')
    p.add_argument('--max-swapout-mb-s', type=float, default=16,
                   help='refuse while swapping out at least this many MB/s during the sample (default: 16)')
    p.add_argument('--wait', type=float, default=0, metavar='SECONDS',
                   help=f'retry admission for at most SECONDS (0-{MAX_WAIT_SECONDS}; default 0: refuse at once)')
    p.add_argument('--retry-every', type=float, default=MIN_RETRY_SECONDS, metavar='SECONDS',
                   help=f'seconds between samples while waiting (at least {MIN_RETRY_SECONDS})')
    p.add_argument('--low-priority', action='store_true',
                   help=f'CEO ruling §78, the 30-hour native build only: skip the CPU line (memory rule and '
                        f'backoff still apply) and run the command under nice -n {LOW_PRIORITY_NICE}; announced')
    p.add_argument('command', nargs=argparse.REMAINDER)
    args = p.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command:
        p.error('a command is required')
    if args.low_priority:
        command = ['/usr/bin/nice', '-n', str(LOW_PRIORITY_NICE), *command]
    with reservation(args.state_dir, args.max_load, args.max_cpu, release_lock=args.release_lock,
                     wait_seconds=args.wait, retry_every=args.retry_every, max_swapout=args.max_swapout_mb_s,
                     low_priority=args.low_priority):
        # Any lock FD stays in the supervisor until the command is reaped.
        child = subprocess.Popen(command, start_new_session=True)
        def stop(signum, frame):
            try:
                os.killpg(child.pid, signal.SIGTERM)
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
            except ProcessLookupError:
                pass
            raise SystemExit(128+signum)
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, stop)
        try:
            return child.wait()
        finally:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()


if __name__ == '__main__':
    try:sys.exit(main())
    except BlockingIOError as exc:print(str(exc),file=sys.stderr);sys.exit(75)
    except ValueError as exc:print('reserve.py: '+str(exc),file=sys.stderr);sys.exit(2)
