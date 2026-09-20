#!/usr/bin/env python3
"""Run a bounded scenario DAG. Each action returns evidence; failures retain their category."""
from dataclasses import dataclass
import json
from pathlib import Path
import time

OUTCOMES=('PASS','product failure','harness failure','prerequisite unavailable')


class Failure(Exception):
    def __init__(self,outcome,detail):
        if outcome not in OUTCOMES[1:]: raise ValueError('invalid failure outcome')
        self.outcome=outcome
        super().__init__(detail)


@dataclass
class TurnBudget:
    limit:int=6
    used:int=0
    def take(self):
        if self.used>=self.limit: raise Failure('prerequisite unavailable','model-turn budget exhausted')
        self.used+=1
        return self.used


def run(manifest,actions,report,identity,budget=None):
    budget=budget or TurnBudget()
    steps=manifest['steps']
    known=set()
    for step in steps:
        if step['id'] in known:raise ValueError('duplicate step id')
        if any(d not in known for d in step.get('requires',[])):raise ValueError('dependencies must name earlier steps')
        if step['action'] not in actions:raise ValueError('unknown action: '+step['action'])
        known.add(step['id'])
    result={'scenario':manifest['name'],'identity':identity,'steps':[], 'model_turns':0}
    statuses={}
    began=time.monotonic()
    for step in steps:
        start=time.monotonic()
        row={'id':step['id'],'outcome':'PASS'}
        blocked=[d for d in step.get('requires',[]) if statuses[d]!='PASS']
        try:
            if blocked:raise Failure('prerequisite unavailable','dependencies did not pass: '+', '.join(blocked))
            row['evidence']=actions[step['action']](step,budget)
        except Failure as exc:
            row.update(outcome=exc.outcome,detail=str(exc))
        except Exception as exc:
            row.update(outcome='harness failure',detail=type(exc).__name__+': '+str(exc))
        row['elapsed_seconds']=round(time.monotonic()-start,3)
        statuses[step['id']]=row['outcome'];result['steps'].append(row)
        result['model_turns']=budget.used
        result['elapsed_seconds']=round(time.monotonic()-began,3)
        Path(report).write_text(json.dumps(result,indent=2))
        print(row['id']+': '+row['outcome'],flush=True)
    result['coverage']={'required':len(steps),'passed':sum(x['outcome']=='PASS' for x in result['steps']),
                        'not_reached':sum(x['outcome']=='prerequisite unavailable' for x in result['steps'])}
    Path(report).write_text(json.dumps(result,indent=2))
    return result
