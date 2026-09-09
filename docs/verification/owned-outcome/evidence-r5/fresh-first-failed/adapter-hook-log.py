import json,subprocess,sys,time
from pathlib import Path
raw=sys.stdin.read()
result=subprocess.run(sys.argv[1:],input=raw,text=True,capture_output=True)
with Path('/var/folders/mx/w46p9btx1t17wv9tbsq885qw0000gn/T/richos-owned-wake-native-7b2h3xej/adapter-hooks.jsonl').open('a') as f:f.write(json.dumps({'mode':('dispatch' if any('owned-dispatch.py' in arg for arg in sys.argv) else sys.argv[-1]),'input':json.loads(raw),'stdout':result.stdout,'stderr':result.stderr,'exit':result.returncode,'time':time.time()})+'\n')
sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
sys.exit(result.returncode)
