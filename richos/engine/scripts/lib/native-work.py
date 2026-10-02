#!/usr/bin/env python3
"""Run native builds with one machine worker, one shared native build lane and
explicit compiler/JVM caps. A healthy external circuit breaker is required on Mac.
No environment variable exempts a caller from admission.

HOW MANY CORES (2026-10-02). From September 24 every native build ran on one core
(one Gradle worker, one Swift/Xcode job, CARGO_BUILD_JOBS=1, every JVM told it had one
processor) whatever the Mac had free. The protection that one-core rule was written for
is kept by the rest of this file and the watchdog: one compiler lane, the machine worker
budget, admission below the 80 percent line, and cpu_guard's per-process runaway stop.
A build now gets the cores free at admission below a target that leaves the CEO room:

    cores = max(1, floor(cpus * (target - busy) / 100 / sharers))
    target  = the admission line (80) minus CEO_HEADROOM_PERCENT (20) = 60 percent
    busy    = total CPU (user + system) measured at admission, in percent
    sharers = machine worker permits held at admission, this build's own included

On a 10-core Mac: alone and quiet (busy 5) 5 cores; four workers admitted at once 1
each; busy 40 percent 2 cores; busy 59 percent or more 1 core. The most any build gets
is cpus * 60 / 100 (6 here), so a lone build at its allowance leaves the Mac at about
60 percent, 20 points (2 cores here) below the line where admission closes and the
watchdog may stop a process using more than three cores. An unmeasured host gets 1.
The decision is printed on stderr for every admitted build.
"""
import os
from pathlib import Path
import subprocess
import sys
import time
import worker_tokens
import cpu_guard
from cpu_policy import DEFAULT_MAX_CPU

CEO_HEADROOM_PERCENT = 20


def allowance(cpus, busy, sharers, limit=DEFAULT_MAX_CPU):
    """Cores one native build may use. `busy` None (not measured) is always 1."""
    if busy is None or cpus < 1:
        return 1
    free = cpus * (limit - CEO_HEADROOM_PERCENT - busy) / 100.0
    return max(1, int(free // max(1, sharers)))


def capped(command, cores=1):
    command = list(command)
    cores = max(1, int(cores))
    name = os.path.basename(command[0])
    if name == 'emulator' or name.startswith('qemu-system-') or (
            name in ('simctl', 'xcrun') and (name == 'simctl' or 'simctl' in command)
            and any(a in command for a in ('boot', 'diagnose'))):
        raise ValueError('native-work does not admit devices or diagnostic dumps; use testdevices for device leases')
    if name in ('gradlew', 'gradle'):
        if any(a.startswith(('--max-workers', '-Dorg.gradle.workers.max', '-Dorg.gradle.jvmargs', '-Dkotlin.daemon.jvm.options')) or a == '--parallel' for a in command[1:]):
            raise ValueError('worker/JVM overrides are not allowed through native admission')
        command += ['--no-daemon', '--parallel' if cores > 1 else '--no-parallel', '--max-workers=%d' % cores,
                    '-Dorg.gradle.jvmargs=-Xmx1536m -XX:ActiveProcessorCount=%d -Dfile.encoding=UTF-8' % cores,
                    '-Pkotlin.compiler.execution.strategy=in-process']
    elif name == 'swift' and len(command) > 1 and command[1] in ('build', 'test'):
        if any(a in ('-j', '--jobs', '--parallel') or a.startswith('--jobs=') for a in command[2:]):
            raise ValueError('parallelism is owned by native admission')
        command += ['--jobs', str(cores)]
    elif name == 'xcodebuild':
        if any(a in command for a in ('-jobs', '-parallel-testing-enabled', '-collect-test-diagnostics', '-enablePerformanceTestsDiagnostics')):
            raise ValueError('parallelism is owned by native admission')
        # Plain repetition otherwise continues after a crash, accumulating macOS
        # crash dialogs. Reliability checks should stop at their first failure.
        # Keep an explicitly chosen Xcode repetition mode intact.
        if '-test-iterations' in command and not any(a in command for a in (
                '-retry-tests-on-failure', '-run-tests-until-failure')):
            index = command.index('-test-iterations')
            if index + 1 < len(command) and command[index + 1].isdigit() and int(command[index + 1]) > 1:
                command.append('-run-tests-until-failure')
        # Compile jobs follow the allowance; parallel TESTING stays off, because it
        # clones simulators and a run holds exactly one leased device.
        command += ['-jobs', str(cores), '-parallel-testing-enabled', 'NO',
                    '-collect-test-diagnostics', 'never', '-enablePerformanceTestsDiagnostics', 'NO']
    return command


def wait_for_headroom(reserve, timeout=1800):
    """Wait for admission; return the total CPU percent of the admitting sample."""
    deadline = time.monotonic() + timeout
    announced = False
    while True:
        try:
            # macOS can return identical cached counters for a subsecond read.
            # Use reserve's full interval and retry an unavailable measurement.
            sample = reserve.host_sample()
        except BlockingIOError:
            sample = None
        if sample is not None and not reserve._refusal(sample, reserve.DEFAULT_MAX_CPU, 16):
            return sample['cpu_user_percent'] + sample['cpu_system_percent']
        if time.monotonic() >= deadline:
            raise TimeoutError('native build admission timed out waiting for measurable CPU/memory headroom')
        if not announced:
            print('native-work: waiting for measurable CPU/memory headroom', file=sys.stderr, flush=True)
            announced = True
        time.sleep(3)


def sharers(directory):
    """Machine worker permits held now, this build's own included (at least 1)."""
    try:
        return max(1, worker_tokens.Budget(directory, runner=True).held())
    except (OSError, ValueError):
        return 1


def needs_compiler_lane(command):
    # A prebuilt UI test uses a leased device and a machine worker, but does
    # not compile. It must not block an unrelated Android or Swift build.
    builds = {'build', 'build-for-testing', 'test', 'archive', 'install', 'analyze', 'clean'}
    return not (os.path.basename(command[0]) == 'xcodebuild' and 'test-without-building' in command
                and not builds.intersection(command[1:]))


def run(command):
    cpu_guard.require_managed_ancestor()
    if sys.platform == 'darwin' and not cpu_guard.healthy():
        raise RuntimeError('CPU watchdog is not healthy; native work refused. Run cpu_guard.py status.')
    capped(command)  # a refused form is refused before any wait
    if os.path.basename(command[0]) == 'xcodebuild' and any(a in command for a in ('test', 'test-without-building')):
        cpu_guard.require_ios()
    directory = worker_tokens.machine_directory()
    lane_dir = Path(directory).parent / 'native-build-v1'
    worker_tokens.init(lane_dir, 1)
    lane = token = None
    try:
        # ONE ORDER, THE PROOF WORKERS' OWN: the machine worker first, the compiler lane
        # second. A proof worker already holds its slot when it reaches a build and then
        # waits for the lane. Taking the lane first here, then waiting for a slot, made a
        # circle whenever every slot belonged to proof workers waiting for this lane
        # (P5-21); only a budget timeout broke it. The lane holder always holds a slot, so
        # in this order somebody can always finish.
        # A nested check borrows exactly its parent's slot. Acquiring another
        # machine token here deadlocks when every proof worker reaches a build.
        free = os.environ.get('RICHOS_WORKER_BORROW_LOCK') if os.environ.get('RICHOS_WORKER_SLOT_HELD') == '1' else None
        token = worker_tokens.Budget(directory, runner=True).acquire(free=free)
        if needs_compiler_lane(command):
            lane = worker_tokens.Budget(lane_dir, shared=False, resource='native-build').acquire()
        busy = None
        if sys.platform == 'darwin':
            sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'app/scripts/testvm'))
            import reserve
            busy = wait_for_headroom(reserve)
            if not cpu_guard.healthy():
                raise RuntimeError('CPU watchdog stopped during admission')
        # Unmeasured (not macOS) is 1 core whoever else is admitted.
        cpus, held = os.cpu_count() or 1, sharers(directory) if busy is not None else 1
        cores = allowance(cpus, busy, held)
        print('native-work: %d core%s (%d cpus, %s, %d worker%s admitted, target %d%%)' % (
            cores, '' if cores == 1 else 's', cpus,
            'CPU not measured' if busy is None else '%.0f%% busy at admission' % busy,
            held, '' if held == 1 else 's', DEFAULT_MAX_CPU - CEO_HEADROOM_PERCENT), file=sys.stderr, flush=True)
        command = capped(command, cores)
        env = {**os.environ, 'RICHOS_MACHINE_WORKERS': directory,
               'JAVA_TOOL_OPTIONS': (os.environ.get('JAVA_TOOL_OPTIONS', '') + ' -XX:ActiveProcessorCount=%d' % cores).strip(),
               'CARGO_BUILD_JOBS': str(cores), 'SWIFTPM_MAX_CONCURRENT_OPERATIONS': str(cores)}
        cpu_guard.register(os.getpid(), 'native build: ' + os.path.basename(command[0]), 'workload')
        return worker_tokens.run_command(command, token, env)
    finally:
        # Reverse of the admission order: the lane first, the worker last.
        if lane: lane.release()
        if token: token.release()


if __name__ == '__main__':
    try:
        if len(sys.argv) < 3 or sys.argv[1] != '--':
            raise ValueError('usage: native-work.py -- COMMAND ...')
        sys.exit(run(sys.argv[2:]))
    except (ValueError, RuntimeError, TimeoutError) as exc:
        print('native-work: ' + str(exc), file=sys.stderr)
        sys.exit(2)
