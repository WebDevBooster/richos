import json,glob,os,datetime as dt,collections,re,statistics
names={}
for line in open('/Users/alex/.claude/state/worktree-ledger.jsonl'):
    try: r=json.loads(line)
    except: continue
    a=r.get('agent_id'); t=r.get('teammate')
    if a and t and a not in names: names[a]=t
files=glob.glob('/Users/alex/.claude/projects/*/*/subagents/agent-*.jsonl')
cut=dt.datetime.now(dt.timezone.utc)-dt.timedelta(days=8)
SUITE=re.compile(r'contract-integrity|run-all-tests|ci-verify|\.test\.sh|\.mutation\.sh|until .*sleep|pgrep|lsof -p|docker logs|suites?\b',re.I)
IDLE=15*60
rows=[];ref_costs=[]
for f in files:
    if dt.datetime.fromtimestamp(os.path.getmtime(f),dt.timezone.utc)<cut: continue
    ev=[]  # (T, kind, extra)
    for line in open(f,errors='replace'):
        try: r=json.loads(line)
        except: continue
        t=r.get('timestamp')
        if not t: continue
        try: T=dt.datetime.fromisoformat(t.replace('Z','+00:00'))
        except: continue
        c=(r.get('message') or {}).get('content')
        kind='msg';extra=None
        if isinstance(c,list):
            for b in c:
                if b.get('type')=='tool_use': kind='use';extra=(b.get('id'),b.get('name'),str(b.get('input',{}).get('command','')))
                elif b.get('type')=='tool_result':
                    cont=b.get('content'); txt=cont if isinstance(cont,str) else ' '.join(x.get('text','') for x in cont if isinstance(x,dict)) if isinstance(cont,list) else ''
                    kind='result';extra=(b.get('tool_use_id'),'Refusing to run it' in txt or 'too complex to verify' in txt)
        ev.append((T,kind,extra))
    if len(ev)<2: continue
    ev.sort(key=lambda e:e[0])
    span=(ev[-1][0]-ev[0][0]).total_seconds()
    active=0.0;idle=0.0
    for a,b in zip(ev,ev[1:]):
        g=(b[0]-a[0]).total_seconds()
        if g>IDLE: idle+=g
        else: active+=g
    pend={};bash=suite=0.0;ref=0
    for i,(T,k,x) in enumerate(ev):
        if k=='use': pend[x[0]]=(T,x[1],x[2])
        elif k=='result':
            p=pend.pop(x[0],None)
            if x[1]:
                ref+=1
                # cost: time from this refusal to the next tool_use
                for T2,k2,x2 in ev[i+1:]:
                    if k2=='use': ref_costs.append((T2-T).total_seconds()); break
            if p and p[1]=='Bash':
                d=(T-p[0]).total_seconds(); bash+=d
                if SUITE.search(p[2]): suite+=d
    aid=os.path.basename(f)[6:-6]
    rows.append((active,span,idle,bash,suite,ref,names.get(aid,'?'),aid[:8]))
rows.sort()
A=sum(r[0] for r in rows);S=sum(r[1] for r in rows);I=sum(r[2] for r in rows);B=sum(r[3] for r in rows);U=sum(r[4] for r in rows)
print('agents',len(rows),'span-h',round(S/3600,1),'ACTIVE-h',round(A/3600,1),'idle-h(gaps>15m)',round(I/3600,1))
print('bash-wait-h',round(B/3600,1),'suite/poll-wait-h',round(U/3600,1),'=> suite-wait share of ACTIVE',round(100*U/A),'%')
act=[r[0]/60 for r in rows]
print('active minutes: median',round(statistics.median(act)),'p75',round(statistics.quantiles(act,n=4)[2]),'p90',round(statistics.quantiles(act,n=10)[8]),'max',round(max(act)))
print('active>=180min:',sum(1 for a in act if a>=180),'60-180:',sum(1 for a in act if 60<=a<180),'<60:',sum(1 for a in act if a<60))
hi=[r for r in rows if r[0]>=3600]
print('agents active>=1h:',len(hi),'active-h',round(sum(r[0] for r in hi)/3600,1),'their suite-wait-h',round(sum(r[4] for r in hi)/3600,1),'share',round(100*sum(r[4] for r in hi)/sum(r[0] for r in hi)),'%')
print('refusals',len(ref_costs),'median cost s',round(statistics.median(ref_costs)) if ref_costs else 0,'total cost h',round(sum(ref_costs)/3600,1))
print('--- top 15 by ACTIVE: active_min span_min idle_min bash_min suite_min refusals name')
for r in rows[-15:]:
    print(round(r[0]/60),round(r[1]/60),round(r[2]/60),round(r[3]/60),round(r[4]/60),r[5],r[6],r[7])
