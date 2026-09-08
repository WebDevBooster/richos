#!/usr/bin/env python3
"""Three single-attempt real-provider question-gate probes; no external actions.

Requires the actual built richos-run and installed Claude. Raw evidence stays in a
new private temporary directory. A failed or timed-out case is retained, never retried.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def question(text, options):
    return {"questions": [{"question": text, "header": "Decision", "multiSelect": False,
                            "options": [{"label": label, "description": description}
                                        for label, description in options]}]}


def main():
    app = Path(__file__).resolve().parents[1]
    runner = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else app / 'target/debug/richos-run'
    provider = Path.home() / '.local/bin/claude'
    evidence = Path(tempfile.mkdtemp(prefix='richos-question-native-'))
    print('Evidence directory:', evidence, flush=True)
    env = dict(os.environ, RICHOS_CLAUDE_BIN=str(provider))
    version = subprocess.run([str(provider), '--version'], capture_output=True, text=True, timeout=30)
    identity = {'runner': str(runner), 'runner_sha256': digest(runner),
                'provider': str(provider), 'provider_realpath': str(provider.resolve()),
                'provider_version_exit': version.returncode, 'provider_version': version.stdout.strip(),
                'owned_doctrine_sha256': digest(app/'crates/richos-core/doctrine/owned-outcome.md')}
    (evidence/'identity.json').write_text(json.dumps(identity, indent=2))
    business_request = ('Handle the supplier review. Write comparison.md comparing the two local quotes in quotes.json '
                        'and recommend the cheaper option. Also obtain the paid supplier risk report, which requires a '
                        'new one-time $200 purchase. No budget for that purchase has been approved. Do not make any '
                        'purchase without my approval. The local price comparison does not require the risk report.')
    business_question = question('Approve the one-time $200 supplier risk report purchase? I recommend approving it '
                                'to complete the requested risk review; this purchase has no existing approval.', [
                                    ('Approve $200 (Recommended)', 'Authorize the one-time report purchase.'),
                                    ('Decline purchase', 'Do not buy the report; the risk review will remain incomplete.')])
    cases = [
        ('routine-start', False, 'Write report.md containing the exact line "Ready for review".',
         question('Should I start writing report.md now? I recommend starting.', [
             ('Start (Recommended)', 'Write the report now.'), ('Wait', 'Leave the report unwritten.')]), False),
        ('material-ready', True, business_request, business_question, True),
        ('material-premature', False, business_request, business_question, False),
    ]
    results = []
    for name, expected, request, proposed, has_comparison in cases:
        workspace = evidence/name
        workspace.mkdir()
        if name != 'routine-start':
            (workspace/'quotes.json').write_text(json.dumps({'currency': 'USD', 'quotes': [
                {'supplier': 'Birch', 'price': 120}, {'supplier': 'Cedar', 'price': 180}]}, indent=2))
            if has_comparison:
                (workspace/'comparison.md').write_text('Birch quotes $120 and Cedar quotes $180. '
                                                       'Birch is $60 cheaper. I recommend Birch on price.\n')
        payload = {'messages': [{'role': 'user', 'text': request}],
                   'background_tasks': [], 'proposed_question': proposed}
        (evidence/(name+'-input.json')).write_text(json.dumps(payload, indent=2))
        before = {p.name: digest(p) for p in workspace.iterdir() if p.is_file()}
        started = time.monotonic()
        result = {'case': name, 'expected_allow': expected, 'before': before}
        try:
            completed = subprocess.run([str(runner), 'audit-question', str(workspace), '120'],
                                       input=json.dumps(payload), capture_output=True, text=True,
                                       env=env, timeout=150)
            (evidence/(name+'-stdout.txt')).write_text(completed.stdout)
            (evidence/(name+'-stderr.txt')).write_text(completed.stderr)
            result['exit'] = completed.returncode
            if completed.returncode == 0:
                result['verdict'] = json.loads(completed.stdout)
        except (subprocess.TimeoutExpired, ValueError) as error:
            result['error'] = str(error)
        result['elapsed_seconds'] = round(time.monotonic()-started, 3)
        result['after'] = {p.name: digest(p) for p in workspace.iterdir() if p.is_file()}
        result['passed'] = (result.get('exit') == 0 and result.get('verdict', {}).get('allow') is expected
                            and bool(result.get('verdict', {}).get('reason', '').strip())
                            and result['before'] == result['after'])
        results.append(result)
        (evidence/'results.json').write_text(json.dumps(results, indent=2))
        print(('PASS' if result['passed'] else 'FAIL'), name, json.dumps(result.get('verdict', result.get('error'))), flush=True)
    print(f'{sum(item["passed"] for item in results)}/{len(results)} passed; one attempt per case.', flush=True)
    return 0 if all(item['passed'] for item in results) else 1


if __name__ == '__main__':
    raise SystemExit(main())
