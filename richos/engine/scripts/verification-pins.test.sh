#!/usr/bin/env bash
# Verify verification-dependencies.json's source, external and hook-reader pins
# with the selector's own validator, including known key/execute-edge floors.
# Parser/dependency semantics changes still run verification-inputs.test.sh.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 -B "$here/lib/affected_units.py" --validate-pins
