#!/usr/bin/env python3
"""Pure plan-bound operator maintenance authorization, not terminal history.

The root administrator authenticates and stores these bytes. This module neither
reads authority files nor grants a writer cutoff, branch deletion or execution.
"""
import copy
import hashlib
import json
import os
from pathlib import PurePosixPath
import re

FIELDS={'version','approval_kind','base_report_sha256','owner_uid','owner_gid','authorization','decisions'}
DECISION_FIELDS={'repo_alias','path','identity','git_admin_path','head','action'}
KINDS={'canonical-checkout','registered-linked-worktree','orphan-registration','external-common-git-directory'}
PIN_FIELDS=('path','device','inode','mode','uid','gid')


class OperatorError(ValueError):
    pass


def _require(value,message):
    if not value:raise OperatorError(message)


def digest(value):
    try:raw=json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False).encode()
    except (ValueError,TypeError) as error:raise OperatorError('finite JSON maintenance evidence required') from error
    _require(len(raw)<=32*1024*1024,'maintenance evidence exceeds limit')
    return hashlib.sha256(raw).hexdigest()


def _path(value):
    _require(isinstance(value,str) and 0<len(value)<=4096 and value==value.strip() and '\0' not in value
             and value.startswith('/') and '..' not in PurePosixPath(value).parts and os.path.normpath(value)==value,
             'exact normalized absolute maintenance path required')
    return value


def decision_record(repository,target,action):
    """Build the exact user-reviewed row without reading any filesystem path."""
    _require(action in ('remove','retain'),'explicit remove or retain decision required')
    kind=target.get('kind');_require(kind in KINDS,'unsupported gate target kind')
    path=_path(target.get('path'));alias=repository.get('alias')
    _require(isinstance(alias,str) and re.fullmatch(r'[A-Za-z0-9_-]{1,64}',alias),'explicit repository alias required')
    if kind=='external-common-git-directory':
        identity={key:target[key] for key in PIN_FIELDS}
        admin=path;head=None
    else:
        identity=target.get('identity');admin=_path(target.get('git_directory',{}).get('path'));head=target.get('head')
        _require(isinstance(head,str) and re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}',head),'exact observed workspace HEAD required')
    _require(isinstance(identity,dict) and identity.get('path')==path,'exact target identity required')
    _require(action=='retain' or kind not in ('canonical-checkout','external-common-git-directory'),
             'canonical checkout and common Git store must be retained')
    _require(action=='retain' or path!=repository.get('canonical_repository',{}).get('path'),
             'canonical repository cannot be removed')
    return dict(repo_alias=alias,path=path,identity=copy.deepcopy(identity),git_admin_path=admin,head=head,action=action)


def _base(report):
    _require(isinstance(report,dict) and report.get('version')==1 and report.get('mode')=='planning-only'
             and report.get('execution_authorized') is False and report.get('execution_ready') is False,
             'original planning-only report required')
    _require(not report.get('errors') and 'operator_maintenance' not in report,'complete unattested baseline report required')
    context=report.get('inspection_context')
    _require(isinstance(context,dict) and 'operator_attestation' not in context,'original owner inspection context required')
    _require(type(context.get('owner_uid')) is int and context['owner_uid']>0 and
             type(context.get('owner_gid')) is int and context['owner_gid']>=0,'exact unprivileged owner identity required')
    repositories=report.get('repositories')
    _require(isinstance(repositories,list) and 0<len(repositories)<=64,'bounded repository inventory required')
    index={};aliases=set()
    for row in repositories:
        _require(isinstance(row,dict) and row.get('inventory_complete') is True,'incomplete repository inventory cannot be attested')
        alias=row.get('alias');_require(alias not in aliases,'duplicate repository alias');aliases.add(alias)
        _path(row.get('canonical_repository',{}).get('path'));_path(row.get('common_git_directory',{}).get('path'))
        _require(isinstance(row.get('blockers'),list) and all(isinstance(b,str) for b in row['blockers']),'explicit blocker inventory required')
        _require(isinstance(row.get('gate_paths'),list) and row['gate_paths'] and
                 isinstance(row.get('gate_roots'),list) and row['gate_roots'] and
                 isinstance(row.get('temporary_parent_gates'),list) and row['temporary_parent_gates'],
                 'complete physical gate and shared-parent scope required')
        for target in row['gate_paths']:
            _require(isinstance(target,dict) and 'inventory_error' not in target,'invalid gate target inventory')
            expected=decision_record(row,target,'retain');key=(alias,expected['path'])
            _require(key not in index,'duplicate gate target')
            ownership=target.get('ownership',{})
            if target['kind']!='external-common-git-directory':
                _require(ownership.get('state') in ('live','unknown','terminal','gone'),'unclassified owner state')
                _require(ownership['state']!='live','live worker evidence cannot be waived')
                _require(not any(w.get('status')=='alive' or w.get('kind')=='explicit-user-active-path'
                                 for w in ownership.get('evidence',[])),'live owner witness cannot be waived')
            index[key]=(row,target)
    _require(len(index)<=1024,'maintenance target count exceeds limit')
    return context,index


def _decisions(report,decisions):
    context,index=_base(report)
    _require(isinstance(decisions,list) and len(decisions)==len(index),'every gate target needs exactly one remove or retain decision')
    chosen={}
    for decision in decisions:
        _require(isinstance(decision,dict) and set(decision)==DECISION_FIELDS,'exact maintenance decision fields required')
        key=(decision['repo_alias'],decision['path'])
        _require(key in index and key not in chosen,'foreign or duplicate maintenance target')
        row,target=index[key]
        _require(decision==decision_record(row,target,decision['action']),'maintenance target identity, HEAD or administration changed')
        chosen[key]=decision
    for key,decision in chosen.items():
        if decision['action']!='remove':continue
        descendants=[other[1] for other in index if other!=key and PurePosixPath(key[1]) in PurePosixPath(other[1]).parents]
        _require(not descendants,'retirement containing another registered or retained target is unsupported')
    for row in report['repositories']:
        allowed={prefix+path for alias,path in index if alias==row['alias']
                 for prefix in ('unknown-owner:','registration-recovery-needs-exact-terminal-owner:')}
        forbidden=[blocker for blocker in row['blockers'] if blocker not in allowed]
        _require(not forbidden,'maintenance attestation cannot waive blockers: '+repr(forbidden))
    return context,index,chosen


def build_attestation(base_report,decisions,authorization):
    context,_,_=_decisions(base_report,decisions)
    _require(isinstance(authorization,str) and authorization.strip() and len(authorization)<=4096 and '\0' not in authorization,
             'bounded explicit operator authorization text required')
    result=dict(version=1,approval_kind='explicit-operator-maintenance',base_report_sha256=digest(base_report),
                owner_uid=context['owner_uid'],owner_gid=context['owner_gid'],authorization=authorization,
                decisions=copy.deepcopy(decisions))
    digest(result)
    return result


def validate_and_apply(base_report,attestation):
    _require(isinstance(attestation,dict) and set(attestation)==FIELDS and type(attestation.get('version')) is int
             and attestation['version']==1 and attestation.get('approval_kind')=='explicit-operator-maintenance',
             'exact operator maintenance attestation required')
    expected=build_attestation(base_report,attestation['decisions'],attestation['authorization'])
    _require(attestation==expected,'operator attestation owner or complete baseline hash differs')
    _,index,decisions=_decisions(base_report,attestation['decisions'])
    result=copy.deepcopy(base_report);authority=digest(attestation)
    result['operator_maintenance']=dict(attestation=copy.deepcopy(attestation),sha256=authority,
        authority='explicit operator downtime authorization; not terminal history or proof of worker death',
        cutoff_required='original verified later-boot gate',execution_authorized=False)
    for row in result['repositories']:
        prior=list(row['removal_candidates']);candidates=[]
        row['operator_waived_blockers']=list(row['blockers']);row['blockers']=[]
        for target in row['gate_paths']:
            decision=decisions[(row['alias'],target['path'])]
            target['operator_maintenance']=dict(action=decision['action'],attestation_sha256=authority,
                                                ownership_evidence_unchanged=True)
            if decision['action']!='remove':continue
            old=[candidate for candidate in prior if candidate['path']==target['path']]
            if old:
                for candidate in old:
                    candidate['operator_maintenance']=dict(action='remove',attestation_sha256=authority)
                    candidates.append(candidate)
            else:
                candidates.append(dict(path=target['path'],head=target['head'],branch=target.get('branch'),
                    identity=copy.deepcopy(target['identity']),kind=target['kind'],
                    gate_root=target.get('gate_root'),relative_path=target.get('relative_path'),contained_registered_targets=[],
                    provenance='explicit-operator-maintenance',operator_maintenance=dict(action='remove',attestation_sha256=authority),
                    status='operator-selected-requires-original-verified-later-boot',execution_authorized=False))
        row['removal_candidates']=candidates
        row['maintenance_ready']=False
    result['limits']=[text for text in result.get('limits',[]) if text!='Active or unknown workers veto maintenance. Finish all work and obtain separate explicit downtime authorization.']
    result['limits'].append('Known live workers and all inventory/storage errors still veto. Explicit plan-bound operator downtime may authorize unknown ownership; it does not prove processes dead. The original reboot cutoff is unchanged.')
    return result
