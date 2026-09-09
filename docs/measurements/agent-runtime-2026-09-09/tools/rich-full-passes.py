import json,glob,os,datetime as dt,re
files=[f for f in glob.glob('/Users/alex/.claude/projects/*/*.jsonl') if '/subagents/' not in f]
cut=dt.datetime.now(dt.timezone.utc)-dt.timedelta(days=8)
FULL=re.compile(r'(^|[;&|]\s*|\bbash\s+|\bzsh\s+|\bnohup\s+)(\S*/)?(run-all-tests\.sh|ci-verify\.sh|contract-integrity\.test\.sh)(?![^\n;&|]*--only)',re.M)
POLL=re.compile(r'until .*(sleep|pgrep)|lsof -p|tail -f',re.I)
runs=[];polls=0.0;polln=0
for f in files:
    if dt.datetime.fromtimestamp(os.path.getmtime(f),dt.timezone.utc)<cut: continue
    pend={}
    for line in open(f,errors='replace'):
        try: r=json.loads(line)
        except: continue
        t=r.get('timestamp')
        if not t: continue
        T=dt.datetime.fromisoformat(t.replace('Z','+00:00'))
        c=(r.get('message') or {}).get('content')
        if not isinstance(c,list): continue
        for b in c:
            if b.get('type')=='tool_use' and b.get('name')=='Bash':
                cmd=str(b.get('input',{}).get('command',''))
                if '<<' in cmd: continue
                pend[b['id']]=(T,cmd,os.path.basename(f)[:8])
            elif b.get('type')=='tool_result':
                p=pend.pop(b.get('tool_use_id'),None)
                if not p: continue
                d=(T-p[0]).total_seconds()
                if FULL.search(p[1]): runs.append((p[0],p[2],d,p[1][:110].replace('\n',' ')))
                elif POLL.search(p[1]): polls+=d;polln+=1
runs.sort()
print('strict full-suite invocations by Rich (8 days):',len(runs),'| Rich polling calls',polln,'poll-wait-h',round(polls/3600,1))
for r in runs: print(r[0].strftime('%m-%d %H:%M'),r[1],round(r[2]/60,1),'min',r[3])
