#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$SCRIPT_DIR" <<'PY'
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]).resolve().parents[2]
files = ['engine/hooks/hooks.json', 'app/scripts/rust-test-summary.py'] + [
    'engine/scripts/hooks/' + n for n in ('session-evidence.test.py', 'shell-evidence.py',
    'shell-evidence.sh', 'commit-ceo-inputs.py', 'notice-ceo-inputs-unheld.sh', 'turn-manifest.py')]
mutations = [
 ('shell failures hidden', 'engine/scripts/hooks/shell-evidence.py', 'set -e -o pipefail', 'set +e +o pipefail',
  'test_original_failures_are_reproduced_and_fixed_in_bash_and_zsh'),
 ('notifications treated as handovers', 'engine/scripts/hooks/commit-ceo-inputs.py',
  'text = re.sub(r"<(task-notification|system-reminder)\\b[^>]*>.*?</\\1>", "", text, flags=re.S)',
  'text = text', 'test_task_notification_does_not_become_a_handover'),
 ('directories treated as files', 'engine/scripts/hooks/commit-ceo-inputs.py',
  'if os.path.isdir(p) and not os.path.islink(p):', 'if False:', 'test_root_and_directories_do_not_reach_ledger'),
 ('historical directory noise retained', 'engine/scripts/hooks/notice-ceo-inputs-unheld.sh',
  'if os.path.isdir(p) and not os.path.islink(p):', 'if False:', 'test_historical_noise_is_retired_but_real_unheld_file_remains'),
 ('shell output called verified', 'engine/scripts/hooks/turn-manifest.py',
  'word = "RETURNED" if tool_name == "Bash" else "ok"', 'word = "ok"', 'test_manifest_does_not_call_unverified_bash_output_ok'),
 ('documentation counts mixed', 'app/scripts/rust-test-summary.py',
  'kind = "documentation"', 'kind = "ordinary"', 'test_rust_doc_tests_are_counted_separately'),
]
with tempfile.TemporaryDirectory(prefix='session-evidence-mutations-') as tmp:
    root = Path(tmp)
    for rel in files:
        target = root/rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source/rel, target)
    test = root/'engine/scripts/hooks/session-evidence.test.py'
    baseline = subprocess.run([sys.executable, str(test)], capture_output=True, text=True)
    if baseline.returncode:
        raise SystemExit('Baseline failed: '+baseline.stderr)
    for name, rel, old, new, method in mutations:
        path = root/rel
        original = path.read_bytes()
        text = original.decode()
        assert text.count(old) == 1, (name, 'mutation target must be unique')
        path.write_text(text.replace(old, new))
        try:
            run = subprocess.run([sys.executable, str(test), 'SessionEvidence.'+method], capture_output=True, text=True)
            if run.returncode == 0 or 'FAIL' not in run.stderr:
                raise SystemExit('Mutation was not caught by its regression: '+name+'\n'+run.stderr)
            print('PASS negative control:', name)
        finally:
            path.write_bytes(original)
            assert path.read_bytes() == original
print('6 negative controls passed; source worktree was never mutated.')
PY
