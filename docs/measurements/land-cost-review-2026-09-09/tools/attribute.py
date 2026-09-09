import json,glob,os,datetime as dt,re,statistics,collections
files=glob.glob('/Users/alex/.claude/projects/*/*/subagents/agent-*.jsonl')
cut=dt.datetime.now(dt.timezone.utc)-dt.timedelta(days=8)
# Sage#2's exact regex
SAGE2=re.compile(r'contract-integrity|run-all-tests|ci-verify|\.test\.sh|\.mutation\.sh|until .*sleep|pgrep|lsof -p|docker logs|suites?\b',re.I)
ALTS=[('contract-integrity',re.compile(r'contract-integrity',re.I)),
      ('run-all-tests',re.compile(r'run-all-tests',re.I)),
      ('ci-verify',re.compile(r'ci-verify',re.I)),
      ('.test.sh',re.compile(r'\.test\.sh',re.I)),
      ('.mutation.sh',re.compile(r'\.mutation\.sh',re.I)),
      ('until..sleep',re.compile(r'until .*sleep',re.I)),
      ('pgrep',re.compile(r'pgrep',re.I)),
      ('lsof -p',re.compile(r'lsof -p',re.I)),
      ('docker logs',re.compile(r'docker logs',re.I)),
      ('word:suite(s)',re.compile(r'suites?\b',re.I))]
STRICT=re.compile(r'(^|[;&|(]\s*|&&\s*|\|\|\s*)\s*(bash\s+|sh\s+|zsh\s+|\./|time\s+)?[^\s;|&]*(contract-integrity\.test\.sh|run-all-tests\.sh|ci-verify\.sh|[\w.-]+\.test\.sh|[\w.-]+\.mutation\.sh)',re.I)
READONLY=re.compile(r'^\s*(cat|head|tail|sed -n|grep|rg|wc|ls|awk|nl|diff|git (show|diff|log|grep|status|rev-parse)|python3 -c|jq|find|md5|shasum|sha256sum|cp|mv|chmod|mkdir|echo|test -|\[)',re.I)
tot_bash=0.0; sage2=0.0; strict=0.0
alt_time=collections.Counter(); alt_n=collections.Counter()
ro=0.0; ro_n=0; poll=0.0; poll_n=0; strict_n=0; sage2_n=0
samples=collections.defaultdict(list)
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
            for b in c:
                if b.get('type')=='tool_use': ev.append((T,'use',(b.get('id'),b.get('name'),str(b.get('input',{}).get('command','')))))
                elif b.get('type')=='tool_result': ev.append((T,'result',(b.get('tool_use_id'),'')))
    ev.sort(key=lambda e:e[0])
    pend={}
    for T,k,x in ev:
        if k=='use': pend[x[0]]=(T,x[1],x[2])
        else:
            p=pend.pop(x[0],None)
            if not p or p[1]!='Bash': continue
            d=(T-p[0]).total_seconds(); cmd=p[2]
            if d<0 or d>3600: continue
            tot_bash+=d
            m2=bool(SAGE2.search(cmd)); ms=bool(STRICT.search(cmd))
            if m2:
                sage2+=d; sage2_n+=1
                for nm,rx in ALTS:
                    if rx.search(cmd): alt_time[nm]+=d; alt_n[nm]+=1
            if ms: strict+=d; strict_n+=1
            if m2 and not ms:
                if READONLY.match(cmd):
                    ro+=d; ro_n+=1
                    if d>60 and len(samples['ro'])<8: samples['ro'].append((round(d),cmd[:140]))
                else:
                    poll+=d; poll_n+=1
                    if d>120 and len(samples['poll'])<10: samples['poll'].append((round(d),cmd[:140]))
print('total Bash wait h  %.1f'%(tot_bash/3600))
print('SAGE#2 match     h  %.1f  (n=%d)'%(sage2/3600,sage2_n))
print('STRICT invoke    h  %.1f  (n=%d)'%(strict/3600,strict_n))
print('S2-not-strict READ-ONLY h %.1f (n=%d)'%(ro/3600,ro_n))
print('S2-not-strict other/poll h %.1f (n=%d)'%(poll/3600,poll_n))
print('--- time by regex alternative (overlapping) ---')
for nm,v in alt_time.most_common(): print('  %-16s %6.1f h  n=%d'%(nm,v/3600,alt_n[nm]))
print('--- READ-ONLY cmds counted as suite-wait (>60s) ---')
for d,c in samples['ro']: print('  %5ds  %s'%(d,c))
print('--- non-invoking poll/other counted as suite-wait (>120s) ---')
for d,c in samples['poll']: print('  %5ds  %s'%(d,c))
