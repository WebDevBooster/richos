#!/usr/bin/env bash
# Global orchestration.config syntax and unknown-key validation. Behavioral
# dependencies are selected separately by lib/affected_units.py.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 -B "$here/lib/affected_units.py" --validate-config
