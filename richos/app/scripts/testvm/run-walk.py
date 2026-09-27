#!/usr/bin/env python3
"""Hold one test VM guest slot through guest boot, a scenario command and guest cleanup.

The command after -- receives the owned VM name as its first argument. Example:
run-walk.py --bundle BUNDLE --home FIXTURE --engine ENGINE -- delta-walk.py --out OUT ...

CEO ruling §77: a walk is a test run, admitted by the CPU rule; it does not take
the nightly release.lock. The guest is a shared resource with TWO slots (slots.py):
this walk holds one of them for exactly its own run, boot to cleanup, and releases it
the instant the run ends (the CEO, 2026-09-27: no slot is ever held between runs,
across a job, a build or a debugging session). Hand-driven steps are a script run
here as the command, not a guest kept up while somebody thinks.

--wait SECONDS waits for a free slot and retries the CPU and memory admission for at most
SECONDS in total (slots.py). The default, 0, refuses at once, as before. Wrapping this in
`reserve.py --wait` does not help on a busy Mac: this script samples again as soon as the
outer one admits, and that second single sample decides the run (2026-09-24: outer
admitted, inner refused at 86.3%, exit 75).
"""
import argparse
import json
import os
from pathlib import Path
import signal
import shlex
import shutil
import time
import subprocess
import sys
import uuid
from slots import guest_slot
from relaunch import guest

HERE=Path(__file__).resolve().parent



def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--bundle',required=True);p.add_argument('--home',required=True);p.add_argument('--engine',required=True)
    p.add_argument('--previous-bundle',type=Path,help='published previous zip or app to stage for rollback')
    p.add_argument('--report',type=Path,required=True,help='whole-run boot/scenario/cleanup timing report outside scratch')
    p.add_argument('--state-dir',type=Path,default=Path.home()/'.richos-nightly',
                   help='accepted so older command lines parse; a walk no longer takes release.lock (CEO ruling §77)')
    p.add_argument('--wait',type=float,default=0,metavar='SECONDS',
                   help='wait for a free guest slot and CPU/memory admission for at most SECONDS (default 0: refuse at once)')
    p.add_argument('command',nargs=argparse.REMAINDER)
    a=p.parse_args();command=a.command[1:] if a.command[:1]==['--'] else a.command
    if not command:p.error('a scenario command is required after --')
    # Before a slot is taken and a guest is booted: a command that cannot start would
    # spend a boot and a slot to find that out.
    if shutil.which(command[0]) is None:p.error('the scenario command is not an executable file: '+command[0])
    vm='walk-'+uuid.uuid4().hex[:12]
    root=Path(os.environ.get('TESTVM_ROOT',str(Path.home()/'.richos-testvm')))
    state=root/'run'/vm
    def interrupted(signum,frame):raise KeyboardInterrupt('interrupted by signal '+str(signum))
    for sig in (signal.SIGTERM,signal.SIGHUP):signal.signal(sig,interrupted)
    with guest_slot(root=root,wait_seconds=a.wait,purpose='run-walk '+vm+' '+Path(command[0]).name) as slot:
        if state.exists():raise RuntimeError('owned VM name already exists')
        child=None;began=time.monotonic();result={'vm':vm,'load':os.getloadavg()[0],'outcome':'harness failure','reservation':str(slot.resolve()),'resources':{k:os.environ.get(k,v) for k,v in [('TESTVM_CPU','4'),('TESTVM_RAM_MB','7168'),('TESTVM_DISPLAY','1680x1050')]}}
        try:
            # Give each subprocess a group so interruption cannot strand the SSH
            # command. stop.sh subsequently reaps the captured VM process.
            boot=[str(HERE/'run.sh'),'--vm',vm,'--bundle',a.bundle,'--home',a.home,'--engine',a.engine]
            child=subprocess.Popen(boot,start_new_session=True)
            rc=child.wait(timeout=480)
            result['boot_seconds']=time.monotonic()-began
            if rc:return rc
            if a.previous_bundle:
                payload=(state/'payload').read_text().strip();target=payload+'/previous'
                guest(vm,'mkdir -p '+shlex.quote(target))
                subprocess.run([str(HERE/'guest.sh'),vm,'--push',str(a.previous_bundle),target+'/'],check=True,timeout=120)
                if a.previous_bundle.suffix=='.zip':
                    guest(vm,'ditto -x -k '+shlex.quote(target+'/'+a.previous_bundle.name)+' '+shlex.quote(target),120)
                apps=guest(vm,'find '+shlex.quote(target)+' -maxdepth 2 -name "*.app" -type d -print').splitlines()
                if len(apps)!=1:raise RuntimeError('previous bundle must contain exactly one app')
                command += ['--previous-app',apps[0]]
            scenario_start=time.monotonic()
            child=subprocess.Popen([command[0],vm,*command[1:]],start_new_session=True)
            rc=child.wait();result['scenario_seconds']=time.monotonic()-scenario_start
            result.pop('outcome',None)
            result.update(execution='completed',scenario_exit=rc)
            return rc
        finally:
            cleanup_start=time.monotonic()
            if child and child.poll() is None:
                os.killpg(child.pid,signal.SIGTERM)
                try:child.wait(timeout=25)
                except subprocess.TimeoutExpired:os.killpg(child.pid,signal.SIGKILL);child.wait()
            # Block repeated interruptions while the owned clone is being removed.
            for sig in (signal.SIGINT,signal.SIGTERM,signal.SIGHUP):signal.signal(sig,signal.SIG_IGN)
            try:
                if state.exists():
                    subprocess.run([str(HERE/'stop.sh'),vm],check=True,timeout=120)
                    if state.exists():raise RuntimeError('VM state remains after cleanup: '+str(state))
                result['cleanup_complete']=True
            except Exception as exc:
                result.update(cleanup_complete=False,cleanup_error=str(exc))
                raise
            finally:
                result.update(cleanup_seconds=time.monotonic()-cleanup_start,elapsed_seconds=time.monotonic()-began)
                a.report.parent.mkdir(parents=True,exist_ok=True)
                a.report.write_text(json.dumps(result,indent=2)+'\n')



if __name__=='__main__':
    try:sys.exit(main())
    except BlockingIOError as exc:print(str(exc),file=sys.stderr);sys.exit(75)
    except (Exception,KeyboardInterrupt) as exc:print(str(exc),file=sys.stderr);sys.exit(2)
