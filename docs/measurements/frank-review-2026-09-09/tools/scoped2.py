import json,glob,os,datetime as dt,re,collections
files=glob.glob('/Users/alex/.claude/projects/*/*/subagents/agent-*.jsonl')
cut=dt.datetime.now(dt.timezone.utc)-dt.timedelta(days=8)
EXEC=re.compile(r'(bash|sh|\./|timeout \d+ bash)\s+[\w./$-]*(contract-integrity\.test\.sh|run-all-tests\.sh|ci-verify\.sh|[\w./-]+\.test\.sh|[\w./-]+\.mutation\.sh)')
b=collections.Counter(); n=collections.Counter()
for f in files:
    if dt.datetime.fromtimestamp(os.path.getmtime(f),dt.timezone.utc)<cut: continue
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
            for x in c:
                if not isinstance(x,dict): continue
                if x.get('type')=='tool_use' and x.get('name')=='Bash': ev.append((T,'u',x.get('id'),str(x.get('input',{}).get('command',''))))
                elif x.get('type')=='tool_result': ev.append((T,'r',x.get('tool_use_id'),''))
    ev.sort(key=lambda e:e[0]); pend={}
    for T,k,i,cmd in ev:
        if k=='u': pend[i]=(T,cmd)
        else:
            p=pend.pop(i,None)
            if not p or not EXEC.search(p[1]): continue
            d=(T-p[0]).total_seconds(); c2=p[1]
            if 'contract-integrity' in c2: key='contract-integrity --only' if '--only' in c2 else 'contract-integrity FULL'
            elif re.search(r'run-all-tests|ci-verify',c2): key='whole-engine pass'
            elif '.mutation.sh' in c2: key='one mutation harness'
            else: key='one named .test.sh'
            b[key]+=d; n[key]+=1
tot=sum(b.values())
for k,v in b.most_common(): print('%-26s %6.2f h  %5d calls  mean %5.0f s'%(k,v/3600,n[k],v/n[k]))
print('total EXEC %.1f h'%(tot/3600))
