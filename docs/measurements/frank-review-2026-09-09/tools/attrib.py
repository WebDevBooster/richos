import json,glob,os,datetime as dt,re,collections
files=glob.glob('/Users/alex/.claude/projects/*/*/subagents/agent-*.jsonl')
cut=dt.datetime.now(dt.timezone.utc)-dt.timedelta(days=8)
SUITE=re.compile(r'contract-integrity|run-all-tests|ci-verify|\.test\.sh|\.mutation\.sh|until .*sleep|pgrep|lsof -p|docker logs|suites?\b',re.I)
WT=re.compile(r'(?:richos-wt|femcboost-wt|richos-hq-wt|worktrees)/([A-Za-z0-9._-]+)')
peragent=[]
for f in files:
    if dt.datetime.fromtimestamp(os.path.getmtime(f),dt.timezone.utc)<cut: continue
    ev=[]; names=collections.Counter()
    for line in open(f,errors='replace'):
        try: r=json.loads(line)
        except: continue
        t=r.get('timestamp')
        if not t: continue
        try: T=dt.datetime.fromisoformat(t.replace('Z','+00:00'))
        except: continue
        c=(r.get('message') or {}).get('content')
        if isinstance(c,list):
            for b in c:
                if not isinstance(b,dict): continue
                if b.get('type')=='tool_use':
                    cmd=str(b.get('input',{}).get('command',''))
                    ev.append((T,'use',(b.get('id'),b.get('name'),cmd)))
                    for m in WT.findall(cmd+' '+json.dumps(b.get('input',{}))[:2000]): names[m]+=1
                elif b.get('type')=='tool_result': ev.append((T,'result',(b.get('tool_use_id'),'','')))
        elif isinstance(c,str):
            for m in WT.findall(c[:4000]): names[m]+=1
    if len(ev)<2: continue
    ev.sort(key=lambda e:e[0]); pend={}; suite=0.0; active=0.0
    for a,b in zip(ev,ev[1:]):
        g=(b[0]-a[0]).total_seconds()
        if g<=900: active+=g
    for T,k,x in ev:
        if k=='use': pend[x[0]]=(T,x[1],x[2])
        else:
            p=pend.pop(x[0],None)
            if p and p[1]=='Bash' and SUITE.search(p[2]): suite+=(T-p[0]).total_seconds()
    nm=names.most_common(1)[0][0] if names else '?'
    peragent.append((suite,active,nm,os.path.basename(f)[6:14]))
peragent.sort(reverse=True)
tot=sum(p[0] for p in peragent)
print('agents %d  total suite-wait %.1f h  total active %.1f h'%(len(peragent),tot/3600,sum(p[1] for p in peragent)/3600))
print('')
print('--- top 25 agents by suite-wait: suite_h active_h worktree-name id ---')
cum=0.0
for s,a,nm,i in peragent[:25]:
    cum+=s
    print('  %5.2f h  %5.2f h  %-28s %s   cum %.0f%%'%(s/3600,a/3600,nm,i,100*cum/tot))
print('')
by=collections.Counter()
for s,a,nm,i in peragent:
    role=re.split(r'[-_]',nm)[0] if nm!='?' else '?'
    by[role]+=s
print('--- suite-wait by role token of worktree name ---')
for r,v in by.most_common(12): print('  %-12s %6.1f h  (%.0f%%)'%(r,v/3600,100*v/tot))
