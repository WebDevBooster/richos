import json,os,subprocess,sys,time
from pathlib import Path
raw=sys.stdin.read()
env=dict(os.environ)
env.update(RICHOS_ENTITY_ROOT='/private/var/folders/mx/w46p9btx1t17wv9tbsq885qw0000gn/T/richos-owned-wake-native-tqk7ov8a/workspace',RICHOS_ADOPTION_MARKER='.ceo-todos',RICHOS_ENGINE_ROOT='/var/folders/mx/w46p9btx1t17wv9tbsq885qw0000gn/T/richos-owned-wake-native-tqk7ov8a/runtime-snapshot/engine')
result=subprocess.run(['bash',sys.argv[1]],input=raw,text=True,capture_output=True,env=env)
with Path('/var/folders/mx/w46p9btx1t17wv9tbsq885qw0000gn/T/richos-owned-wake-native-tqk7ov8a/engine-hooks.jsonl').open('a') as f:f.write(json.dumps({'hook':sys.argv[1],'input':raw,'stdout':result.stdout,'stderr':result.stderr,'exit':result.returncode,'time':time.time()})+'\n')
sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
sys.exit(result.returncode)
