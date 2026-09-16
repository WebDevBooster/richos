#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Owned inputs: model-catalog.js model-integrity.js model-fetch.js
# model-pins.json model-costs.json package.json models.test.mjs fetch.test.mjs
exec node "$HERE/run.mjs"
