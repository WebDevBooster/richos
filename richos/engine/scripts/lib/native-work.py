#!/usr/bin/env python3
"""Run native builds with one machine worker, one shared native build lane and
explicit compiler/JVM caps. A healthy external circuit breaker is required on Mac.
No environment variable exempts a caller from admission.
"""
import os
from pathlib import Path
import subprocess
import sys
import time
import worker_tokens
import cpu_guard


def capped(command):
    command = list(command)
    name = os.path.basename(command[0])
    if name == 'emulator' or name.startswith('qemu-system-') or (
            name in ('simctl', 'xcrun') and (name == 'simctl' or 'simctl' in command)
            and any(a in command for a in ('boot', 'diagnose'))):
        raise ValueError('native-work does not admit devices or diagnostic dumps; use testdevices for device leases')
    if name in ('gradlew', 'gradle'):
        if any(a.startswith(('--max-workers', '-Dorg.gradle.workers.max', '-Dorg.gradle.jvmargs', '-Dkotlin.daemon.jvm.options')) or a == '--parallel' for a in command[1:]):
            raise ValueError('worker/JVM overrides are not allowed through native admission')
        command += ['--no-daemon', '--no-parallel', '--max-workers=1',
                    '-Dorg.gradle.jvmargs=-Xmx1536m -XX:ActiveProcessorCount=1 -Dfile.encoding=UTF-8',
                    '-Pkotlin.compiler.execution.strategy=in-process']
    elif name == 'swift' and len(command) > 1 and command[1] in ('build', 'test'):
        if any(a in ('-j', '--jobs', '--parallel') or a.startswith('--jobs=') for a in command[2:]):
            raise ValueError('parallelism is owned by native admission')
        command += ['--jobs', '1']
    elif name == 'xcodebuild':
        if any(a in command for a in ('-jobs', '-parallel-testing-enabled', '-collect-test-diagnostics', '-enablePerformanceTestsDiagnostics')):
            raise ValueError('parallelism is owned by native admission')
        command += ['-jobs', '1', '-parallel-testing-enabled', 'NO',
                    '-collect-test-diagnostics', 'never', '-enablePerformanceTestsDiagnostics', 'NO']
    return command


def wait_for_headroom(reserve, timeout=1800):
    deadline = time.monotonic() + timeout
    announced = False
    while True:
        try:
            # macOS can return identical cached counters for a subsecond read.
            # Use reserve's full interval and retry an unavailable measurement.
            sample = reserve.host_sample()
        except BlockingIOError:
            sample = None
        if sample is not None and not reserve._refusal(sample, 60, 16) and sample['cpu_idle_percent'] >= 30:
            return
        if time.monotonic() >= deadline:
            raise TimeoutError('native build admission timed out waiting for measurable CPU/memory headroom')
        if not announced:
            print('native-work: waiting for measurable CPU/memory headroom', file=sys.stderr, flush=True)
            announced = True
        time.sleep(3)


def run(command):
    if sys.platform == 'darwin' and not cpu_guard.healthy():
        raise RuntimeError('CPU watchdog is not healthy; native work refused. Run cpu_guard.py status.')
    command = capped(command)
    if os.path.basename(command[0]) == 'xcodebuild' and any(a in command for a in ('test', 'test-without-building')):
        cpu_guard.require_ios()
    directory = worker_tokens.machine_directory()
    lane_dir = Path(directory).parent / 'native-build-v1'
    worker_tokens.init(lane_dir, 1)
    lane = worker_tokens.Budget(lane_dir, shared=False).acquire()
    token = None
    try:
        # A nested check borrows exactly its parent's slot. Acquiring another
        # machine token here deadlocks when every proof worker reaches a build.
        free = os.environ.get('RICHOS_WORKER_BORROW_LOCK') if os.environ.get('RICHOS_WORKER_SLOT_HELD') == '1' else None
        token = worker_tokens.Budget(directory, runner=True).acquire(free=free)
        if sys.platform == 'darwin':
            sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'app/scripts/testvm'))
            import reserve
            wait_for_headroom(reserve)
            if not cpu_guard.healthy():
                raise RuntimeError('CPU watchdog stopped during admission')
        env = {**os.environ, 'RICHOS_MACHINE_WORKERS': directory,
               'JAVA_TOOL_OPTIONS': (os.environ.get('JAVA_TOOL_OPTIONS', '') + ' -XX:ActiveProcessorCount=1').strip(),
               'CARGO_BUILD_JOBS': '1', 'SWIFTPM_MAX_CONCURRENT_OPERATIONS': '1'}
        cpu_guard.register(os.getpid(), 'native build: ' + os.path.basename(command[0]), 'workload')
        return worker_tokens.run_command(command, token, env)
    finally:
        if token: token.release()
        lane.release()


if __name__ == '__main__':
    try:
        if len(sys.argv) < 3 or sys.argv[1] != '--':
            raise ValueError('usage: native-work.py -- COMMAND ...')
        sys.exit(run(sys.argv[2:]))
    except (ValueError, RuntimeError, TimeoutError) as exc:
        print('native-work: ' + str(exc), file=sys.stderr)
        sys.exit(2)
