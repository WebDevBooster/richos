import json,glob,os,datetime as dt,re,collections
files=glob.glob('/Users/alex/.claude/projects/*/*/subagents/agent-*.jsonl')
print('transcripts on disk:',len(files))
SAGE2=re.compile(r'contract-integrity|run-all-tests|ci-verify|\.test\.sh|\.mutation\.sh|until .*sleep|pgrep|lsof -p|docker logs|suites?\b',re.I)
POLLIDIOM=re.compile(r'until .*sleep|pgrep|lsof -p|while .*sleep|wait \$|docker logs -f|tail -f',re.I)
RUNIDIOM=re.compile(r'(bash|sh|zsh|\./|time |timeout \S+ )\s*\S*(\.test\.sh|\.mutation\.sh|run-all-tests\.sh|ci-verify\.sh|contract-integrity|probe)',re.I)
inv=0.0;invn=0; pol=0.0;poln=0; s2=0.0
# also: active time under a 10-min idle cut (Sage#1) vs 15-min (Sage#2)
a10=0.0;a15=0.0;agents=0
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
        kind='msg';extra=None
        if isinstance(c,list):
            for b in c:
                if b.get('type')=='tool_use': kind='use';extra=(b.get('id'),b.get('name'),str(b.get('input',{}).get('command','')))
                elif b.get('type')=='tool_result': kind='result';extra=(b.get('tool_use_id'),'')
        ev.append((T,kind,extra))
    if len(ev)<2: continue
    agents+=1; ev.sort(key=lambda e:e[0]); pend={}
    for a,b in zip(ev,ev[1:]):
        g=(b[0]-a[0]).total_seconds()
        if g<=600: a10+=g
        if g<=900: a15+=g
    for T,k,x in ev:
        if k=='use': pend[x[0]]=(T,x[1],x[2])
        elif k=='result':
            p=pend.pop(x[0],None)
            if not p or p[1]!='Bash': continue
            d=(T-p[0]).total_seconds(); cmd=p[2]
            if d<0 or d>3600: continue
            if SAGE2.search(cmd): s2+=d
            if RUNIDIOM.search(cmd): inv+=d; invn+=1
            elif POLLIDIOM.search(cmd) and SAGE2.search(cmd): pol+=d; poln+=1
print('ALL-TIME, all transcripts (%d with >=2 events)'%agents)
print('  invoking calls        : %6.1f h  n=%d   <-- comparable to Sage#1 "46.9 h / 2,649 calls"'%(inv/3600,invn))
print('  polling-a-suite calls : %6.1f h  n=%d   <-- EXCLUDED by Sage#1, counted by Sage#2'%(pol/3600,poln))
print('  invoking + polling    : %6.1f h'%((inv+pol)/3600))
print('  Sage#2 regex total    : %6.1f h'%(s2/3600))
print('ACTIVE-time sensitivity to the idle threshold:')
print('  idle cut 10 min (Sage#1): %.1f h'%(a10/3600))
print('  idle cut 15 min (Sage#2): %.1f h'%(a15/3600))
