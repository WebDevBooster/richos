#!/usr/bin/env python3
"""Background advancement of already armed, owner-scoped legacy jobs only."""
import importlib.util
import json
import os
from pathlib import Path
import threading
import time
import uuid


def load(name):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(name+'.py'))
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module


class LegacyMaintenanceService:
    def __init__(self,policy,*,require_root=True,job_module=None,gate_module=None,policy_path=None):
        self.policy=policy;self.require_root=require_root
        self.runtime=load('managed-workspace-broker')
        self.policy_path=None
        if require_root:
            release=self.runtime.validate_runtime()
            self.policy_path=self.runtime.protected_path(policy_path or release.parent.parent/'policy.json',regular=True)
        self.job=job_module or load('legacy-workspace-job')
        self.gate=gate_module or load('legacy-workspace-gate')
        self.root=Path(policy['private_root'])/'legacy-gates'
        self.lock=threading.Lock()
        self.cache={'inventory_complete':False,'records':[],'last_attempt_at':None,'last_completed_at':None,
                    'in_progress':False,'error':'not-yet-inspected'}

    def _protected(self,path,*,regular=None):
        if self.require_root:return self.runtime.protected_path(path,regular=regular)
        if path.is_symlink() or path.stat().st_uid!=os.geteuid():raise ValueError('unsafe disposable service path')
        return path

    def _discover(self):
        if self.policy_path is not None:
            policy=self.runtime.validate_policy(json.loads(self.runtime.protected_path(self.policy_path,regular=True).read_text()))
            if Path(policy['private_root'])/'legacy-gates'!=self.root:
                raise ValueError('legacy storage policy changed; daemon restart required')
            self.policy=policy
        if not os.path.lexists(self.root):return [],[]
        self._protected(self.root,regular=False)
        result=[];problems=[]
        for base in sorted(self.root.iterdir()):
            owner_uid=None
            try:
                if not base.is_dir() or base.is_symlink():raise ValueError('invalid legacy gate directory inventory')
                if str(uuid.UUID(base.name))!=base.name:raise ValueError('invalid legacy gate UUID')
                self._protected(base,regular=False)
                if not os.path.lexists(base/'job.json'):continue
                self._protected(base/'job.json',regular=True)
                state=json.loads(self._protected(base/'state.json',regular=True).read_text())
                context=state.get('inspection_context')
                if not isinstance(context,dict):raise ValueError('legacy job lacks approved owner context')
                owner_uid=context.get('owner_uid')
                owner=self.policy['owners'].get(str(owner_uid))
                if owner is None or owner['gid']!=context.get('owner_gid'):raise ValueError('legacy job owner no longer approved')
                plan=json.loads(self._protected(base/'plan.json',regular=True).read_text())
                for row in plan['repositories']:
                    repository=self.policy['repositories'].get(row['alias'])
                    if (repository is None or owner_uid not in repository['owners']
                            or repository['path']!=row['canonical_repository']['path']):
                        raise ValueError('legacy job repository policy no longer matches')
                gate=self.gate.LegacyGate(self.root,require_root=self.require_root,inspection_context=context)
                result.append((gate,base.name,owner_uid))
            except Exception as exc:
                problems.append({'gate_id':base.name,'owner_uid':owner_uid,'phase':'failed','last_error':str(exc)[:512]})
        return result,problems

    @staticmethod
    def _progress(value):
        # Ignore observation timestamps and repeated error text when deciding
        # whether another immediate advancement could make useful progress.
        result = {key:value.get(key) for key in ('phase','state','candidate_index','branch_group_index','step','complete')}
        expiry = value.get('recovery_expiry') or {}
        result['recovery_expiry'] = {key:expiry.get(key) for key in ('enabled','states')}
        return result

    def sweep(self):
        started=time.time();rows=[];progress=False;error=None
        with self.lock:
            self.cache.update(last_attempt_at=started,in_progress=True)
        try:
            jobs,problems=self._discover()
            rows.extend(problems)
            if problems:error=str(len(problems))+' legacy gates failed policy or inventory validation'
            before_states={}
            for gate,ident,owner in jobs:
                try:
                    before_states[ident]=self.job.status(gate,ident)
                    rows.append(self._compact(before_states[ident],ident,owner))
                except Exception as exc:
                    rows.append({'gate_id':ident,'owner_uid':owner,'phase':'failed','last_error':str(exc)[:512]})
            with self.lock:
                self.cache.update(inventory_complete=error is None,records=list(rows),error=error)
            for gate,ident,owner in jobs:
                if ident not in before_states:continue
                before=before_states[ident]
                try:
                    # Per-gate scratch lives in the protected namespace and
                    # never selects a source checkout or a different gate.
                    scratch=self.root/ident/'job-scratch'
                    if scratch.is_symlink():raise ValueError('legacy job scratch is a symlink')
                    scratch.mkdir(mode=0o700,exist_ok=True)
                    if before.get('phase')!='complete':
                        rows=[dict(row,advancing=True) if row['gate_id']==ident else row for row in rows]
                        with self.lock:self.cache['records']=list(rows)
                        self.job.advance(gate,ident,scratch_root=scratch)
                    after=self.job.status(gate,ident)
                    if after.get('phase') == 'complete':
                        self.job.expire_completed(gate, ident, repositories=self.policy['repositories'])
                        after=self.job.status(gate,ident)
                    progress |= self._progress(before)!=self._progress(after)
                    updated=self._compact(after,ident,owner)
                except Exception as exc:
                    updated={'gate_id':ident,'owner_uid':owner,'phase':'failed','last_error':str(exc)[:512]}
                rows=[updated if row['gate_id']==ident else row for row in rows]
                with self.lock:self.cache['records']=list(rows)
        except Exception as exc:
            error=str(exc)[:512]
        with self.lock:
            self.cache={'inventory_complete':error is None,'records':rows,'last_attempt_at':started,
                        'last_completed_at':time.time(),'in_progress':False,'error':error}
        return progress

    @staticmethod
    def _compact(value,ident,owner):
        compact={key:value.get(key) for key in ('phase','state','candidate_index','candidate_count','branch_group_index','branch_group_count','last_error','recovery_expiry') if key in value}
        if compact.get('last_error'):compact['last_error']=str(compact['last_error'])[:512]
        return dict(compact,gate_id=ident,owner_uid=owner)

    def status(self,owner_uid):
        with self.lock:
            snapshot=dict(self.cache)
            rows=[dict(row) for row in snapshot.pop('records') if row['owner_uid']==owner_uid]
        for row in rows:row.pop('owner_uid',None)
        return dict(snapshot,total=len(rows),records=rows[:100],truncated=len(rows)>100)
