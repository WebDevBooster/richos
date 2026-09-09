import json,glob,os,datetime as dt,re,statistics
V='g'+'it'
MERGE=re.compile(V+r'\s+merge\b')
PUSH=re.compile(V+r'\s+push\b')
SUITE=re.compile(r'contract-integrity|run-all-tests|ci-verify|\.test\.sh|\.mutation\.sh|freshness-check|until .*sleep|pgrep|docker logs',re.I)
EXEC=re.compile(r'(bash|sh|\./|timeout \d+ bash)\s+[\w./$-]*(contract-integrity\.test\.sh|run-all-tests\.sh|ci-verify\.sh|[\w./-]+\.test\.sh|[\w./-]+\.mutation\.sh)')
cut=dt.datetime.now(dt.timezone.utc)-dt.timedelta(days=8)
sess=[p for p in glob.glob('/Users/alex/.claude/projects/*/*.jsonl') if os.path.getmtime(p)>cut.timestamp()]
episodes=[]
for f in sess:
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
                if b.get('type')=='tool_use' and b.get('name')=='Bash':
                    ev.append((T,'use',b.get('id'),str(b.get('input',{}).get('command',''))))
                elif b.get('type')=='tool_result':
                    ev.append((T,'result',b.get('tool_use_id'),''))
    if not ev: continue
    ev.sort(key=lambda e:e[0])
    dur={}; pend={}
    for T,k,i,cmd in ev:
        if k=='use': pend[i]=(T,cmd)
        else:
            p=pend.pop(i,None)
            if p: dur[i]=((T-p[0]).total_seconds(),p[1],p[0])
    order=[i for T,k,i,c in ev if k=='use' and i in dur]
    # build episodes: verification+mechanical time from previous push/merge boundary up to each push
    last_boundary=0
    for idx,i in enumerate(order):
        d,cmd,T0=dur[i]
        if PUSH.search(cmd):
            seg=order[last_boundary:idx+1]
            ver=0.0; mech=0.0; nmerge=0; span=0.0
            if seg:
                span=(dur[seg[-1]][2]-dur[seg[0]][2]).total_seconds()+dur[seg[-1]][0]
            for j in seg:
                dj,cj,_=dur[j]
                if MERGE.search(cj): nmerge+=1
                if SUITE.search(cj): ver+=dj
                if MERGE.search(cj) or PUSH.search(cj): mech+=dj
            if nmerge:
                episodes.append((ver/60,mech/60,span/60,len(seg),nmerge,dur[seg[0]][2]))
            last_boundary=idx+1
print('land episodes (previous push -> this push, containing >=1 merge):',len(episodes))
if episodes:
    ver=sorted(e[0] for e in episodes)
    print('verification minutes inside the episode: median %.1f  p75 %.1f  p90 %.1f  max %.1f  mean %.1f'%(
        statistics.median(ver),ver[int(.75*len(ver))-1],ver[int(.9*len(ver))-1],max(ver),statistics.mean(ver)))
    print('episodes with >=30 min verification:',sum(1 for v in ver if v>=30))
    print('episodes with  0 min verification:',sum(1 for v in ver if v==0))
    tot=sum(ver)
    print('total verification inside land episodes over 8 days: %.1f h'%(tot/60))
    print('')
    print('--- 12 heaviest episodes: ver_min mech_min span_min ncalls nmerges start ---')
    for e in sorted(episodes,reverse=True)[:12]:
        print('  %6.1f %6.1f %7.1f %5d %3d  %s'%(e[0],e[1],e[2],e[3],e[4],e[5].strftime('%m-%d %H:%M')))
