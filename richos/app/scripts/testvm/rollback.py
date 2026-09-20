#!/usr/bin/env python3
"""Exercise real signed update/rollback in an owned VM, with pinned release identities."""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import sys
import time
from relaunch import guest, relaunch
from scenario import Failure


def receipts(vm,home):
    # Read only: these are the updater's own receipts, never synthesized here.
    code='''import json,pathlib,sys
r=pathlib.Path(sys.argv[1])/'Applications/.richos-updater'
p=json.loads((r/'published.json').read_text())
q=json.loads((r/p['archive_sha256']/'previous.json').read_text())
print(json.dumps({'current':p['version'],'previous':q['version']}))'''
    return json.loads(guest(vm,'python3 -c '+shlex.quote(code)+' '+shlex.quote(home)))


def wait_log(vm,path,needle,seconds=180):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        log=guest(vm,'cat '+shlex.quote(path)+' 2>/dev/null || true')
        if needle in log: return log
        time.sleep(1)
    raise RuntimeError('deadline waiting for '+needle+' in '+path)


def exercise(vm,previous,current,endpoint,previous_app=None,check_only=False):
    for version in (previous,current):
        if not re.fullmatch(r'[0-9A-Za-z.+-]+',version): raise ValueError('invalid pinned version')
    if previous==current: raise ValueError('previous and current must differ')
    # Pin the existing updater to an immutable manifest, retaining its signature check.
    if ('/releases/download/v'+current+'/') not in endpoint:
        raise ValueError('endpoint must name the pinned current release tag')
    state=Path(os.environ.get('TESTVM_ROOT',str(Path.home()/'.richos-testvm')))/'run'/vm
    payload=(state/'payload').read_text().strip();home=payload+'/home'
    env={'RICHOS_UPDATE_ENDPOINT':endpoint}
    result={'previous':previous,'current':current,'steps':[]}
    if check_only:
        try:result['receipts']=receipts(vm,home)
        except (RuntimeError,KeyError,ValueError) as exc:
            raise Failure('prerequisite unavailable','rollback history is absent or invalid: '+str(exc)) from exc
        if result['receipts']!={'current':current,'previous':previous}:raise Failure('prerequisite unavailable','receipt versions differ from pinned releases')
        return result
    if not previous_app: raise ValueError('--previous-app is required to prepare real history')
    actual=guest(vm,'/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" '+shlex.quote(previous_app+'/Contents/Info.plist'))
    if actual!=previous: raise Failure('prerequisite unavailable','previous bundle is '+actual+', expected '+previous)
    # Installing the actual previous bundle at the real per-user destination gives
    # the updater something to exchange. Only the updater writes its receipts.
    dest=home+'/Applications/RichOS.app'
    exists=guest(vm,'test -e '+shlex.quote(dest)+' && echo yes || true')
    if exists: raise Failure('prerequisite unavailable','fresh rollback fixture required: destination already exists')
    guest(vm,'mkdir -p '+shlex.quote(home+'/Applications')+' && ditto '+shlex.quote(previous_app)+' '+shlex.quote(dest),120)
    started=relaunch(vm,dest,{**env,'RICHOS_UPDATE_SELFTEST':'install'})
    log=wait_log(vm,started['log'],'RICHOS-UPDATE-SELFTEST exit=')
    result['steps'].append({'action':'update','log':log})
    if 'RICHOS-UPDATE-SELFTEST exit=0' not in log: raise Failure('product failure','real update did not stage successfully: '+log)
    activated=relaunch(vm,dest,env)
    time.sleep(2)
    record=receipts(vm,home)
    if record!={'current':current,'previous':previous}:raise Failure('product failure','real update did not produce the expected history: '+str(record))
    boot=guest(vm,'cat '+shlex.quote(activated['log']))
    if '[richos] update activated: '+previous+' -> '+current not in boot:
        raise Failure('product failure','update boot log does not name the exact activation direction')
    result['steps'].append({'action':'activate','receipts':record,'log':boot})
    started=relaunch(vm,dest,{**env,'RICHOS_UPDATE_SELFTEST':'rollback'})
    log=wait_log(vm,started['log'],'RICHOS-UPDATE-SELFTEST exit=')
    if 'RICHOS-UPDATE-SELFTEST exit=0' not in log: raise Failure('product failure','real rollback did not stage successfully: '+log)
    activated=relaunch(vm,dest,env);time.sleep(2)
    boot=guest(vm,'cat '+shlex.quote(activated['log']))
    record=receipts(vm,home)
    if record!={'current':previous,'previous':current}:raise Failure('product failure','rollback did not exchange the expected releases')
    if '[richos] rollback activated: '+current+' -> '+previous not in boot:
        raise Failure('product failure','rollback boot log does not name the exact activation direction')
    result['steps'].append({'action':'rollback','receipts':record,'log':boot})
    started=relaunch(vm,dest,{**env,'RICHOS_UPDATE_SELFTEST':'check'})
    log=wait_log(vm,started['log'],'RICHOS-UPDATE-SELFTEST exit=')
    if 'available='+current not in log or 'back=-' not in log:raise Failure('product failure','rollback did not restore update offer with no second rollback')
    result['steps'].append({'action':'check-again','log':log})
    return result


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('vm');p.add_argument('--previous',required=True);p.add_argument('--current',required=True)
    p.add_argument('--endpoint',required=True);p.add_argument('--previous-app');p.add_argument('--check-only',action='store_true')
    p.add_argument('--output',type=Path,required=True)
    a=p.parse_args()
    try:
        result=exercise(a.vm,a.previous,a.current,a.endpoint,a.previous_app,a.check_only)
        a.output.write_text(json.dumps({'outcome':'PASS',**result},indent=2));print(a.output)
    except (Failure,ValueError,RuntimeError,OSError,KeyError) as exc:
        a.output.write_text(json.dumps({'outcome':getattr(exc,'outcome','prerequisite unavailable' if a.check_only else 'harness failure'),'detail':str(exc)},indent=2))
        print(str(exc),file=sys.stderr);sys.exit(2)
