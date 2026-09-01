#!/usr/bin/env bash
# The whole first-send sequence under the GUI condition: launchd's environment, cwd `/`.
# Config and ledger are throwaway files in /tmp — nothing here touches the CEO's own state.
set -uo pipefail
export PATH="$HOME/.cargo/bin:$PATH"
cd /Users/alex/ab/richos-wt/echo-opus-in1/app
cargo build -q -p richos-core --example company_choice_roundtrip 2>&1 | tail -5
BIN=/Users/alex/ab/richos-wt/echo-opus-in1/app/target/debug/examples/company_choice_roundtrip
cd /
echo "############ A. with the corpus reachable (HOME=/Users/alex) ############"
/usr/bin/env -i HOME=/Users/alex PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    "$BIN" /Users/alex/.claude/richos-engine richos
echo
echo "############ B. same run, HOME with no pointer — the control ############"
NOHOME=$(/usr/bin/mktemp -d /tmp/richos-nohome-XXXX)
/usr/bin/env -i HOME="$NOHOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    RICHOS_CLAUDE_BIN=/Users/alex/.local/bin/claude \
    "$BIN" /Users/alex/.claude/richos-engine richos
rm -rf "$NOHOME"
