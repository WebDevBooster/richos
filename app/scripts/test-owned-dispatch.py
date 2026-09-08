#!/usr/bin/env python3
"""Fixed, paid tool-free semantic controls. Each case is run once, never retried.

This exercises the real dispatch registrar, not leader continuation or an install.
Mechanical host membership checks and engine wiring have separate test suites.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def cases():
    base = {'proposed_dispatch': {'prompt': ''},
            'pending_items': [{'id': '1.1', 'state': 'READY-FOR-CEO', 'title': 'Apple signing identity: individual or company enrollment',
                               'unblocks': 'Implement the chosen signing enrollment mode.'}],
            'messages': [{'role': 'user', 'text': 'Repair the independent local parser defect. Also implement the signing enrollment choice once I actually rule; that choice is still undecided. Do not enroll, spend or publish.'}],
            'standing_rulings': [], 'source_unavailable': False}
    result = []
    def add(name, prompt, expected, change=None):
        data = copy.deepcopy(base); data['proposed_dispatch']['prompt'] = prompt
        if change: change(data)
        result.append({'name': name, 'expected': expected, 'input': data})
    add('independent_negation', "This in no way depends on the CEO's decision. Repair the local parser defect.", 'independent')
    add('independent_nothing_blocked', "Nothing here is blocked by the CEO's decision. Repair the local parser defect.", 'independent')
    add('independent_history', "An earlier brief said it depends on the CEO's decision but that is no longer true. Repair the independent local parser defect.", 'independent')
    add('pending_contraction', "Implement the signing enrollment choice. The CEO hasn't answered. This dispatch depends on that answer.", 'pending')
    add('pending_pronoun_ruling', 'Implement the signing enrollment choice. We cannot proceed without his ruling.', 'pending')
    add('pending_ordinary_waiting', "Implement the signing enrollment choice. We are waiting for the CEO's answer.", 'pending')
    add('pending_original_review', 'Implement the CEO answer to his prepared decision. He has NOT answered it. This dispatch DEPENDS on that answer and cannot proceed without it.', 'pending')
    signing = 'Implement the selected signing enrollment mode.\ndepends-on-ceo: 1.1'
    add('asked_is_not_answered', signing + '\nceo-todos-deferred: keep moving', 'pending',
        lambda d: d['messages'].append({'role': 'assistant', 'text': 'Should we use individual enrollment or company enrollment? I recommend individual.'}))
    def answered(d): d['messages'].append({'role': 'user', 'text': 'Use individual enrollment for signing. Implement that configuration now. Do not actually enroll or spend.'})
    add('actual_answer_same_pending_row', signing, 'authorized', answered)
    add('wrong_scope_answer', signing, 'pending', lambda d: d['messages'].append({'role': 'user', 'text': 'The webinar should be on Tuesday. Implement that calendar display.'}))
    def revoked(d):
        answered(d)
        d['messages'].append({'role': 'user', 'text': 'I revoke that signing choice. Do not implement either enrollment mode until I rule again.'})
    add('revoked_answer', signing, 'pending', revoked)
    def standing(d):
        d['messages'] = [{'role': 'user', 'text': 'Implement the signing configuration according to my current recorded ruling. Do not enroll or spend.'}]
        d['standing_rulings'] = [{'path': '/declared/wiki/ceo-decisions.md', 'text': 'CEO ruling: use individual enrollment for signing configuration. Implement that configuration; do not enroll or spend. This supersedes the old undecided TODO.'}]
    add('declared_ruling_same_pending_row', signing, 'authorized', standing)
    def missing_ruling(d):
        standing(d); d['standing_rulings'] = []
    add('removed_ruling_same_pending_row', signing, 'pending', missing_ruling)
    export = {'proposed_dispatch': {'prompt': 'Implement the export feature using the selected storage mode and verify it locally.'},
              'messages': [{'role': 'user', 'text': 'Handle implementation of the export feature using our selected storage mode. Honor the current decision records. Hold only steps that actually need a business choice from me; do not spend or publish.'}],
              'pending_items': [], 'standing_rulings': [], 'source_unavailable': False}
    for name, item, expected in [
        ('pending_record_relevant', {'id': '1.1', 'state': 'READY-FOR-CEO', 'title': 'Export storage choice remains undecided: local-only or paid cloud', 'unblocks': 'The export implementation requires this choice before its storage behavior can be implemented.'}, 'pending'),
        ('pending_record_unrelated', {'id': '1.1', 'state': 'READY-FOR-CEO', 'title': 'Webinar date remains undecided: Tuesday or Friday', 'unblocks': 'Publish the webinar date. This does not affect software exports.'}, 'independent'),
    ]:
        data = copy.deepcopy(export); data['pending_items'] = [item]
        result.append({'name': name, 'expected': expected, 'input': data})
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--runner', required=True)
    parser.add_argument('--output')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    binary = Path(args.runner).resolve()
    out = Path(args.output) if args.output else Path(tempfile.mkdtemp(prefix='richos-dispatch-r3-'))
    out.mkdir(parents=True, exist_ok=True)
    watched = [binary, Path(__file__).resolve(), root/'app/crates/richos-core/src/dispatch.rs']
    hashes = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
    records = []
    corpus = cases()
    (out/'inputs.json').write_text(json.dumps(corpus, indent=2)+'\n')
    print(str(out), flush=True)
    for case in corpus:
        run = subprocess.run([str(binary), 'audit-dispatch', str(root), '120'], input=json.dumps(case['input']), text=True, capture_output=True, timeout=150)
        row = {k: case[k] for k in ('name', 'expected')}
        row.update(returncode=run.returncode, stdout=run.stdout, stderr=run.stderr)
        try: row['passed'] = run.returncode == 0 and json.loads(run.stdout)['kind'] == case['expected']
        except (ValueError, KeyError): row['passed'] = False
        records.append(row)
        print(case['name'], 'PASS' if row['passed'] else 'FAIL', flush=True)
        (out/'result.json').write_text(json.dumps({'evidence_kind':'real tool-free registrar semantic controls; no installed or leader evidence', 'source_hashes':hashes, 'results':records}, indent=2)+'\n')
    unchanged = all(hashlib.sha256(p.read_bytes()).hexdigest() == hashes[str(p)] for p in watched)
    result = {'evidence_kind':'real tool-free registrar semantic controls; no installed or leader evidence', 'source_hashes':hashes, 'source_unchanged':unchanged, 'results':records,
              'passed':unchanged and len(records)==15 and all(r['passed'] for r in records)}
    (out/'result.json').write_text(json.dumps(result, indent=2)+'\n')
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
