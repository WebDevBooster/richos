#!/usr/bin/env python3
"""Evaluate the shipped registrar, prompt and default tier with no work execution.
Build: cargo build --manifest-path app/Cargo.toml -p richos-core --example registration_probe
Run: python3 app/scripts/test-registration-native.py [probe executable]
Every case is a first attempt. Failures are retained and produce a nonzero exit.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

app = Path(__file__).resolve().parents[1]
probe = Path(sys.argv[1]) if len(sys.argv) > 1 else app / 'target/debug/examples/registration_probe'
request = 'Handle this: create hello.txt containing exactly Hello Rich with no trailing newline. Do not create other files.'
plain = "I'll create hello.txt containing exactly Hello Rich, with no trailing newline and no other files, then verify it."
markdown = "I've got this one.\n\n**Deliverable:** a single file, `hello.txt`, in the working directory.\n\n**Acceptance constraints:**\n- Contents are exactly `Hello Rich`, with that capitalization and one space.\n- No trailing newline. The file is exactly 10 bytes.\n- No other files are created: no scratch files, backups or README.\n\nI'm handing that to my execution team now and will confirm once verified."
tail = 'CEO: We need a report using the approved Q3 figures.\nRich: I can write report.txt using those figures, with no external distribution.'
cases = [
    ('plain-work', request, plain, '', False, False, 'work'),
    ('discussion', 'What is our Q3 plan?', 'We are planning the Q3 launch. No changes are needed.', '', False, False, 'none'),
    ('amend-negative', 'Revise the report: use Q2 figures instead. Do not email it.', "I'll update report.txt with Q2 figures and keep it local. Nothing will be emailed.", '', True, False, 'amend'),
    ('anaphora', 'Yes, do that.', "I'll deliver report.txt using the approved Q3 figures without distributing it.", tail, False, False, 'work'),
    ('scope-in-tail', 'Yes, do that.', 'On it.', tail, False, False, 'work'),
    ('self-done', 'Rename draft.txt to report.txt.', 'Done. I renamed draft.txt to report.txt.', '', False, False, 'work'),
    ('decision-answer', 'Authorize ten more cycles.', "I'll use the additional ten cycles to finish the report.", '', True, True, 'answer_decision'),
    ('cancel', 'Cancel the report assignment.', "I'll cancel that assignment and stop further work on it.", '', True, False, 'cancel'),
    ('question-during-work', 'How is the report going?', 'The report is still being worked on.', '', True, False, 'none'),
] + [(f'markdown-{n}', request, markdown, '', False, False, 'work') for n in range(1, 4)]
root = Path(tempfile.mkdtemp(prefix='richos-registration-eval-'))
print('Evidence directory:', root, flush=True)
env = dict(os.environ)
env.pop('RICHOS_REGISTRATION_MODEL', None)  # Measure the shipped default.
results = []
for name, text, reply, context, has_run, pending, expected in cases:
    data = dict(request=text, reply=reply, tail=context, has_run=has_run, pending_decision=pending)
    run = subprocess.run([str(probe.resolve())], input=json.dumps(data), text=True, capture_output=True, env=env, timeout=100)
    try:
        result = json.loads(run.stdout)
    except ValueError:
        result = {'error': run.stderr + run.stdout}
    passed = run.returncode == 0 and result.get('handoff', {}).get('kind') == expected
    if passed and expected in ('work', 'amend'):
        criteria = result['handoff']['tasks'][0]['criteria']
        passed = text in criteria and reply in criteria and (not context or context in criteria)
    if expected in ('amend', 'answer_decision', 'cancel'):
        passed = passed and result.get('target') == '00000000-0000-4000-8000-000000000001'
    results.append(dict(name=name, passed=passed, input=data, result=result))
    (root / 'results.json').write_text(json.dumps(results, indent=2))
    print(('PASS' if passed else 'FAIL'), name, result.get('error', ''), flush=True)
print(f'{sum(r["passed"] for r in results)}/{len(results)} first-attempt registrations accepted correctly.', flush=True)
sys.exit(0 if all(r['passed'] for r in results) else 1)
