#!/usr/bin/env bash
# Five copies of this are registered on PreToolUse[Bash]. If the host runs them
# in PARALLEL the tool call is held ~2s; if SERIALLY, ~10s.
cat >/dev/null 2>&1
D="$(dirname "${BASH_SOURCE[0]}")"
python3 -c "import time;print('%s start %.3f' % ('$1', time.time()))" >> "$D/order.log"
sleep 2
python3 -c "import time;print('%s end   %.3f' % ('$1', time.time()))" >> "$D/order.log"
exit 0
