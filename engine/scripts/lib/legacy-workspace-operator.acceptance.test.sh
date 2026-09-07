#!/usr/bin/env bash
set -euo pipefail
exec python3 "$(cd "$(dirname "$0")" && pwd)/legacy-workspace-operator.acceptance.test.py"
