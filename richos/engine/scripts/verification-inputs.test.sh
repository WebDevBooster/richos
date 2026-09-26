#!/usr/bin/env bash
# Config/hook semantics owned by lib/verification_inputs.py and
# verification-inputs.test.py. lib/verification-dependencies.json binds the
# reviewed helper contracts. Fixtures never execute the parsed config.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 -B "$here/verification-inputs.test.py"
