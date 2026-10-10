#!/usr/bin/env bash
# dependency-license-inventory.test.sh — the committed Rust dependency license inventory matches
# the committed lockfiles, and every license expression in them has been reviewed against
# AGPL-3.0-only. A dependency arriving under an unreviewed license, or a lockfile change that
# leaves the inventory stale, fails here. Reads cargo metadata only; builds nothing, opens no window.
# run-tests: no-host-screen: reads lockfiles and metadata only; nothing is launched on any screen
# run-tests: inputs richos/app/scripts/dependency-license-inventory.test.sh richos/app/scripts/dependency-license-inventory.sh richos/app/scripts/lib/dependency_license_inventory.py docs/legal/THIRD-PARTY-RUST-DEPENDENCIES.md
# run-tests: covers richos/app/scripts/lib/dependency_license_inventory.py
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$here/dependency-license-inventory.sh" --check
