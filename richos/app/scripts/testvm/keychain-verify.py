#!/usr/bin/env python3
"""Observe real app keys after pairing, idle and relaunch. No key/ACL writes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import time
from relaunch import guest, relaunch
from scenario import Failure

HERE=Path(__file__).resolve().parent
ACCOUNTS=('certificate-authority-key','tls-leaf-key','vapid-signing-key')


def service_for(data):
    return 'com.richos.app.phone-channel.'+hashlib.sha256(os.fsencode(data)).hexdigest()[:12]


def keys(vm,home):
    service=service_for(home+'/Library/Application Support/com.richos.app')
    # The app uses this exact service/accounts and the default search list. Only
    # fingerprints leave the guest. No ACL broadening, regeneration or repair.
    code='''import hashlib,json,subprocess,sys
result={}
for account in sys.argv[2:]:
    try:
        r=subprocess.run(['/usr/bin/security','find-generic-password','-a',account,'-s',sys.argv[1],'-w'],capture_output=True,timeout=18)
    except subprocess.TimeoutExpired:
        raise SystemExit('existing app key access timed out: '+account)
    if r.returncode or not r.stdout.strip():raise SystemExit('existing app key unavailable: '+account)
    result[account]=hashlib.sha256(r.stdout.strip()).hexdigest()
print(json.dumps(result))'''
    user=home.split('/')[2]
    args=['sudo','launchctl','asuser','$(id -u '+user+')','sudo','-u',user,'env','HOME='+home,'python3','-c',code,service,*ACCOUNTS]
    cmd=shlex.join(args).replace(shlex.quote(args[3]),args[3])
    return json.loads(guest(vm,cmd,65))


def no_prompt(vm):
    result=subprocess.run([str(HERE/'ax.sh'),vm,'find','--app','SecurityAgent','--role','AXWindow','--first','--json'],capture_output=True,text=True,timeout=22)
    rows=[json.loads(x) for x in result.stdout.splitlines() if x.startswith('{')]
    absent=any(x.get('error') in ('noprocess','nowindow') for x in rows)
    if result.returncode==1 and absent:return
    if result.returncode==0:raise Failure('prerequisite unavailable','SecurityAgent prompt appeared; fixture is unusable')
    raise Failure('harness failure','could not inspect SecurityAgent: '+result.stderr)


def verify(vm,idle_seconds=1801):
    if idle_seconds<=300:raise ValueError('idle interval must exceed 300 seconds')
    state=Path(os.environ.get('TESTVM_ROOT',str(Path.home()/'.richos-testvm')))/'run'/vm
    home=(state/'payload').read_text().strip()+'/home'
    began=time.monotonic();no_prompt(vm);before=keys(vm,home)
    end=time.monotonic()+idle_seconds
    while time.monotonic()<end:
        time.sleep(min(15,max(0,end-time.monotonic())))
        no_prompt(vm) # No secret access during the idle interval.
    delayed=keys(vm,home)
    if delayed!=before:raise Failure('product failure','app keys changed while idle')
    started=relaunch(vm)
    deadline=time.monotonic()+25
    while time.monotonic()<deadline:
        no_prompt(vm)
        log=guest(vm,'cat '+shlex.quote(started['log'])+' 2>/dev/null || true')
        if 'the phone channel is listening on' in log:break
        if 'security: still running' in log:raise Failure('prerequisite unavailable','app secret-access timeout after relaunch')
        time.sleep(.5)
    else:raise Failure('product failure','app did not restart its paired channel within 25 seconds')
    after=keys(vm,home);no_prompt(vm)
    if after!=before:raise Failure('product failure','app replaced existing keys after relaunch')
    settings=subprocess.run([str(HERE/'keychain.sh'),'check',vm,home],capture_output=True,text=True,timeout=90)
    if settings.returncode:raise Failure('prerequisite unavailable',settings.stdout+settings.stderr)
    return {'idle_seconds':idle_seconds,'elapsed_seconds':time.monotonic()-began,
            'key_fingerprints':after,'existing_keys_reused':True,'boot_log':started['log'],
            'gui_settings':settings.stdout,'prompt_observation_interval_seconds':15}


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('vm');p.add_argument('--idle-seconds',type=float,default=1801)
    p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    try:
        evidence=verify(a.vm,a.idle_seconds);result={'outcome':'PASS','evidence':evidence}
    except Exception as exc:
        result={'outcome':getattr(exc,'outcome','harness failure'),'detail':str(exc)}
    a.output.write_text(json.dumps(result,indent=2)+'\n')
    sys.exit(0 if result['outcome']=='PASS' else 1)
