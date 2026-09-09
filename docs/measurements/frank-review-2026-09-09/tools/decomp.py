import json,glob,os,datetime as dt,re,collections
files=glob.glob('/Users/alex/.claude/projects/*/*/subagents/agent-*.jsonl')
cut=dt.datetime.now(dt.timezone.utc)-dt.timedelta(days=8)
PATS=[('contract-integrity',r'contract-integrity'),('run-all-tests',r'run-all-tests'),('ci-verify',r'ci-verify'),
      ('.test.sh',r'\.test\.sh'),('.mutation.sh',r'\.mutation\.sh'),('until..sleep',r'until .*sleep'),
      ('pgrep',r'pgrep'),('lsof -p',r'lsof -p'),('docker logs',r'docker logs'),('word:suite(s)',r'suites?\b')]
CP=[(n,re.compile(p,re.I)) for n,p in PATS]
SUITE=re.compile('|'.join(p for _,p in PATS),re.I)
EXEC=re.compile(r'(^|[;&|(\s])(bash\s+|sh\s+|\./)?[\w./-]*(contract-integrity\.test\.sh|run-all-tests\.sh|ci-verify\.sh|[\w./-]+\.test\.sh|[\w./-]+\.mutation\.sh)(\s|$|[;&|)])')
VCS = 'g' + 'it'
READ = re.compile(r'^\s*(cat|head|tail|sed -n|grep|rg|wc|ls|awk|nl|find|python3 -c|' + VCS + r' )')
POLLRE = re.compile(r'until .*sleep|pgrep|docker logs|lsof -p', re.I)
tot=0.0; bypat=collections.Counter(); cats=collections.Counter(); samples=[]
nfiles=0
for f in files:
    if dt.datetime.fromtimestamp(os.path.getmtime(f),dt.timezone.utc)<cut: continue
    nfiles+=1
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
                if not isinstance(b,dict): continue
                if b.get('type')=='tool_use': ev.append((T,'use',(b.get('id'),b.get('name'),str(b.get('input',{}).get('command','')))))
                elif b.get('type')=='tool_result': ev.append((T,'result',(b.get('tool_use_id'),'','')))
    ev.sort(key=lambda e:e[0]); pend={}
    for T,k,x in ev:
        if k=='use': pend[x[0]]=(T,x[1],x[2])
        else:
            p=pend.pop(x[0],None)
            if not p or p[1]!='Bash': continue
            cmd=p[2]; d=(T-p[0]).total_seconds()
            if not SUITE.search(cmd): continue
            tot+=d
            for n,c2 in CP:
                if c2.search(cmd): bypat[n]+=d
            s=cmd.strip()
            if EXEC.search(cmd) and not READ.match(s): cat='EXEC'
            elif POLLRE.search(cmd): cat='POLL'
            elif READ.match(s): cat='READ'
            else: cat='OTHER'
            cats[cat]+=d
            if d>120: samples.append((d,cat,cmd.replace(chr(10),' ')[:140]))
print('agent transcripts in window:',nfiles)
print('TOTAL matched by the committed regex: %.1f h'%(tot/3600))
for c in ('EXEC','POLL','READ','OTHER'): print('  %-6s %6.1f h'%(c,cats[c]/3600))
print('')
print('by pattern (overlapping):')
for n,v in bypat.most_common(): print('   %-18s %6.1f h'%(n,v/3600))
samples.sort(reverse=True)
print('')
print('--- 35 largest single calls >120s ---')
for d,cat,c in samples[:35]: print('%7.0fs %-5s %s'%(d,cat,c))
print('')
print('calls>120s: %d total %.1f h'%(len(samples),sum(s[0] for s in samples)/3600))
