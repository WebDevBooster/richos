#!/usr/bin/env bash
# The quick suites of the area, sequentially, each through run-suite.sh.
set -uo pipefail
SP=/private/tmp/claude-501/-Users-alex-ab-femcboost/b7869424-972c-4693-80f8-5e034a119d86/scratchpad/r5
R="$SP/run-suite.sh"
bash "$R" process-identity scripts/lib/process-identity.test.sh | head -1
bash "$R" process-identity-ci RICHOS_SESSION_PROCESSES=none RICHOS_SESSIONS_DIR="$SP/empty-sessions" scripts/lib/process-identity.test.sh | head -1
bash "$R" hook-staleness scripts/hooks/hook-staleness.test.sh | head -1
bash "$R" land-disposition scripts/hooks/land-disposition.test.sh | head -1
bash "$R" completion-proof scripts/lib/completion-proof.test.sh | head -1
bash "$R" record-subagent-start scripts/hooks/record-subagent-start.test.sh | head -1
bash "$R" stop-hook-visibility scripts/hooks/stop-hook-visibility.test.sh | head -1
bash "$R" guard-ci-red-lands scripts/hooks/guard-ci-red-lands.test.sh | head -1
bash "$R" ci-run-record-check scripts/ci-run-record-check.test.sh | head -1
bash "$R" leak-canary scripts/lib/leak-canary.test.sh | head -1
bash "$R" global-state-witness scripts/lib/global-state-witness.test.sh | head -1
bash "$R" ci-units scripts/ci-units.test.sh | head -1
bash "$R" ci-affected-units scripts/ci-affected-units.test.sh | head -1
bash "$R" discard-workspace-backlog scripts/discard-workspace-backlog.test.py | head -1
bash "$R" engine-status scripts/hooks/engine-status.test.sh | head -1
