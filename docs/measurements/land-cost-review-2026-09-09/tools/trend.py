import json,glob,os,datetime as dt,re,collections
files=glob.glob('/Users/alex/.claude/projects/*/*/subagents/agent-*.jsonl')
SAGE2=re.compile(r'contract-integrity|run-all-tests|ci-verify|\.test\.sh|\.mutation\.sh|until .*sleep|pgrep|lsof -p|docker logs|suites?\b',re.I)
POLLIDIOM=re.compile(r'until .*sleep|pgrep|lsof -p|while .*sleep|wait \$|docker logs -f|tail -f',re.I)
RUNIDIOM=re.compile(r'(bash|sh|zsh|\./|time |timeout \S+ )\s*\S*(\.test\.sh|\.mutation\.sh|run-all-tests\.sh|ci-verify\.sh|contract-integrity|probe)',re.I)
day=collections.Counter(); dayall=collections.Counter(); dayag=collections.defaultdict(set)
for f in files:
    ev=[]
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
                if b.get('type')=='tool_use': ev.append((T,'use',(b.get('id'),b.get('name'),str(b.get('input',{}).get('command','')))))
                elif b.get('type')=='tool_result': ev.append((T,'result',(b.get('tool_use_id'),'')))
    ev.sort(key=lambda e:e[0]); pend={}
    aid=os.path.basename(f)
    for T,k,x in ev:
        if k=='use': pend[x[0]]=(T,x[1],x[2])
        else:
            p=pend.pop(x[0],None)
            if not p or p[1]!='Bash': continue
            d=(T-p[0]).total_seconds(); cmd=p[2]
            if d<0 or d>3600: continue
            k2=p[0].date().isoformat(); dayall[k2]+=d; dayag[k2].add(aid)
            if RUNIDIOM.search(cmd) or (POLLIDIOM.search(cmd) and SAGE2.search(cmd)): day[k2]+=d
print('date        suite-wait_h  all-bash_h  agents')
for k in sorted(dayall):
    print('%s  %10.1f  %10.1f  %6d'%(k,day[k]/3600,dayall[k]/3600,len(dayag[k])))
