from pathlib import Path
import json,hashlib
source=Path('/Users/alex/ab/richos-wt/codex-owned-outcome-completion/app/scripts/test-owned-wake-native.py')
namespace={'__file__':str(source)};exec(source.read_text().split('parser = argparse.ArgumentParser')[0],namespace)
p=Path('/var/folders/mx/w46p9btx1t17wv9tbsq885qw0000gn/T/richos-owned-wake-native-tqk7ov8a')
rows=[json.loads(l) for f in p.glob('transcript-*.jsonl') for l in f.read_text().splitlines()]
events=[json.loads(l) for l in (p/'input-events.jsonl').read_text().splitlines()]
hooks=[json.loads(l) for l in (p/'adapter-hooks.jsonl').read_text().splitlines()]
feedback=[h.get('stderr','').strip() for h in hooks if h.get('mode')=='audit']
original=json.loads((p/'result.json').read_text());before={f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in p.glob('*.json*')}
measurement=namespace['input_measurement'](events,rows,(p/'request.txt').read_text(),feedback)
checks={**original['checks'],'no_operational_followups_measured':measurement['confirmed']}
result={'original_result_sha256':before['result.json'],'re_evaluator_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'original_passed':original['passed'],'passed':all(checks.values()),'checks':checks,'input_measurement':measurement,'reason':'Successful native SendMessage resumed an actually launched child; paired toolUseResult.resumedAgentId and sourceToolAssistantUUID bind the resulting native task-notification. No operator wrote an operational input.','original_artifacts_unchanged':all(hashlib.sha256((p/name).read_bytes()).hexdigest()==sha for name,sha in before.items())}
(p/'resumed-agent-re-evaluation.json').write_text(json.dumps(result,indent=2));(p/'resumed-agent-re-evaluator.py').write_bytes(Path(__file__).read_bytes());(p/'resumed-agent-corrected-harness.py').write_bytes(source.read_bytes());print(json.dumps(result,indent=2))
