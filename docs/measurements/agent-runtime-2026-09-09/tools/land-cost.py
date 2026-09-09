import json,glob,os,datetime as dt,re
# Rich's main-session transcripts: top-level <session>.jsonl files
files=[f for f in glob.glob('/Users/alex/.claude/projects/*/*.jsonl') if '/subagents/' not in f]
cut=dt.datetime.now(dt.timezone.utc)-dt.timedelta(days=8)
uses=[]
for f in files:
    if dt.datetime.fromtimestamp(os.path.getmtime(f),dt.timezone.utc)<cut: continue
    for line in open(f,errors='replace'):
        try: r=json.loads(line)
        except: continue
        t=r.get('timestamp')
        if not t: continue
        c=(r.get('message') or {}).get('content')
        if not isinstance(c,list): continue
        for b in c:
            if b.get('type')=='tool_use' and b.get('name')=='Bash':
                cmd=str(b.get('input',{}).get('command',''))
                uses.append((dt.datetime.fromisoformat(t.replace('Z','+00:00')),os.path.basename(f)[:8],cmd))
uses.sort()
merges=[u for u in uses if re.search(r'git merge (--no-ff|--ff-only|)\s*\S*worktree|git merge --no-ff',u[2])]
pushes=[u for u in uses if 'git push origin main' in u[2] or re.search(r'git push\b.*\bmain\b',u[2])]
fulls=[u for u in uses if re.search(r'run-all-tests\.sh|ci-verify\.sh|contract-integrity\.test\.sh(?![^\n]*--only)',u[2])]
print('bash calls in main sessions',len(uses),'merges',len(merges),'pushes',len(pushes),'full-suite invocations by Rich',len(fulls))
# for each merge find the next push in same session and whether a full-suite call sits between
out=[]
for m in merges:
    nxt=[p for p in pushes if p[1]==m[1] and p[0]>m[0]]
    if not nxt: continue
    p=nxt[0]; d=(p[0]-m[0]).total_seconds()/60
    between=[u for u in fulls if u[1]==m[1] and m[0]<u[0]<p[0]]
    out.append((d,m[0].strftime('%m-%d %H:%M'),m[1],len(between)))
out.sort()
import statistics
ds=[o[0] for o in out]
if ds: print('merge->push minutes: n',len(ds),'median',round(statistics.median(ds),1),'p75',round(statistics.quantiles(ds,n=4)[2],1),'max',round(max(ds)))
print('lands with a full-suite call between merge and push:',sum(1 for o in out if o[3]>0))
for o in out[-8:]: print(round(o[0]),o[1],o[2],'fulls-between',o[3])
print('--- Rich full-suite invocations (time, session, cmd[:100])')
for u in fulls[-12:]: print(u[0].strftime('%m-%d %H:%M'),u[1],u[2][:100].replace('\n',' '))
