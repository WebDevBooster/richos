#!/usr/bin/env bash
# Reproduce the GUI condition for the loro resolver: launchd's environment and cwd `/`.
set -uo pipefail
export PATH="$HOME/.cargo/bin:$PATH"
cd /Users/alex/ab/richos-wt/echo-opus-in1/app
cargo build -q -p richos-core --example loro_reprime_demo 2>&1 | tail -5
BIN="/Users/alex/ab/richos-wt/echo-opus-in1/app/target/debug/examples/loro_reprime_demo"
echo "=== environment handed to the run ==="
cd /
/usr/bin/env -i HOME=/Users/alex PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/env
echo "=== run (cwd $(pwd)) ==="
/usr/bin/env -i HOME=/Users/alex PATH=/usr/bin:/bin:/usr/sbin:/sbin "$BIN" "the RichOS desktop app"
