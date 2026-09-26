# Selected verification results

See [README](README.md) for the original timeout, targeted retry and native GUI limitations.

## Non-engine checks from the completed full run

| Check | Result | Exit | Seconds |
| --- | --- | ---: | ---: |
| make-release | passed | 0 | 170.1 |
| slow-bridge.js | passed | 0 | 158.2 |
| proof-for | passed | 0 | 153.7 |
| contrast.js | passed | 0 | 147.5 |
| make-engine-asset | passed | 0 | 136.7 |
| splash.js | passed | 0 | 135.1 |
| phone.js | passed | 0 | 129.6 |
| quota.js | passed | 0 | 95.2 |
| affordances.js | passed | 0 | 87.6 |
| lint | passed | 0 | 79.0 |
| techy.js | passed | 0 | 66.8 |
| home.js | passed | 0 | 65.9 |
| appearance.js | passed | 0 | 60.6 |
| home-fit.js | passed | 0 | 55.0 |
| settings-fit.js | passed | 0 | 53.6 |
| updates.js | passed | 0 | 51.9 |
| cargo -p richos-core | passed | 0 | 43.9 |
| waiting-state.js | passed | 0 | 41.4 |
| mobile-pwa | passed | 0 | 40.3 |
| restart-scope.js | passed | 0 | 39.5 |
| memory-strategy.js | passed | 0 | 33.7 |
| cargo --bin richos-tauri | passed | 0 | 33.2 |
| setup.js | passed | 0 | 32.3 |
| compaction-progress.js | passed | 0 | 28.6 |
| feedback.js | passed | 0 | 28.2 |
| corrections.js | passed | 0 | 27.8 |
| chrome-align.js | passed | 0 | 27.4 |
| navigation-evidence.js | passed | 0 | 26.0 |
| waiting-lifecycle.js | passed | 0 | 25.0 |
| compaction-notice.js | passed | 0 | 24.4 |
| mobile-mac | passed | 0 | 21.6 |
| ticker-wrap.js | passed | 0 | 20.3 |
| scale.js | passed | 0 | 18.7 |
| voice-model.js | passed | 0 | 16.5 |
| onboarding.js | passed | 0 | 12.9 |
| cargo -p richos-core --lib | passed | 0 | 11.5 |
| escape.js | passed | 0 | 10.9 |
| retention.js | passed | 0 | 10.7 |
| second-mouth.js | passed | 0 | 9.7 |
| inspector.js | passed | 0 | 9.2 |
| steering.js | passed | 0 | 9.0 |
| attachments.js | passed | 0 | 8.6 |
| work-summary.js | passed | 0 | 8.4 |
| memory.js | passed | 0 | 8.4 |
| realbytes.js | passed | 0 | 6.1 |
| permissions.js | passed | 0 | 5.7 |
| onboarding-lifecycle.js | passed | 0 | 5.6 |
| no-compile-time-paths | passed | 0 | 5.1 |
| front-door.js | passed | 0 | 5.1 |
| cargo opener:: | passed | 0 | 4.9 |
| provider-auth.js | passed | 0 | 4.7 |
| local-notice.js | passed | 0 | 4.3 |
| repositories.js | passed | 0 | 4.3 |
| cargo work_host:: | passed | 0 | 4.3 |
| composer-scroll.js | passed | 0 | 4.3 |
| cargo native:: | passed | 0 | 4.3 |
| background-work.js | passed | 0 | 3.3 |
| ui-ledger | passed | 0 | 3.3 |
| thread-switch.js | passed | 0 | 2.9 |
| composer-off.js | passed | 0 | 2.9 |
| control-names.js | passed | 0 | 2.7 |
| claude-quota | passed | 0 | 2.7 |
| workers.js | passed | 0 | 2.5 |
| quit-question.js | passed | 0 | 2.3 |
| first-run-sheet.js | passed | 0 | 2.3 |
| interruption.js | passed | 0 | 2.1 |
| outage.js | passed | 0 | 2.1 |
| no-foreign-app-data | passed | 0 | 1.7 |
| cargo quota:: | passed | 0 | 1.6 |
| cargo -p richos-core --test native_cancel_tests | passed | 0 | 1.6 |
| live-workers.js | passed | 0 | 1.4 |
| markdown.js | passed | 0 | 1.2 |
| question-timer.js | passed | 0 | 1.2 |
| cargo -p richos-core --test engine_profile | passed | 0 | 1.2 |
| cargo -p richos-core --test between_turn_tests | passed | 0 | 1.0 |
| cargo -p richos-core --test native_onboarding_grant_tests | passed | 0 | 1.0 |
| frontend-payload | passed | 0 | 1.0 |
| cargo recovery:: | passed | 0 | 0.8 |
| cargo -p richos-core --test between_turn_thread_tests | passed | 0 | 0.8 |
| cargo -p richos-core --test launch_no_outbound_tests | passed | 0 | 0.6 |
| cargo assignment:: | passed | 0 | 0.6 |
| no-home-network.js | passed | 0 | 0.6 |
| cargo status_tools:: | passed | 0 | 0.6 |
| cargo -p richos-core --test feedback_no_outbound_tests | passed | 0 | 0.6 |
| cargo -p richos-core --test doctrine_sentinel | passed | 0 | 0.6 |
| front-door | passed (inner suite NOT RUN: no screen) | 0 | 0.4 |
| gui-boot | passed (inner suite NOT RUN: no screen) | 0 | 0.4 |
| dialect.js | passed | 0 | 0.4 |

## Engine units

Every receipt names commit `db052bb816dfa366e69e601469220ff0c7ccb6c1`.
The scratch-reaper receipt comes from the targeted retry.

| Unit | Result | Actual / expected exit | Seconds |
| --- | --- | --- | ---: |
| ecs/tests/operator-complete.test.sh | PASS | 0 / 0 | 34.3 |
| mega-lander/tests/app.test.sh | PASS | 0 / 0 | 256.2 |
| mega-lander/tests/workspace-stopped-ending.test.sh | PASS | 0 / 0 | 15.1 |
| scripts/ci-verify.test.sh | PASS | 0 / 0 | 2.0 |
| scripts/hook-registration-completeness.test.sh | PASS | 0 / 0 | 8.1 |
| scripts/hooks/by-reference.test.sh | PASS | 0 / 0 | 558.3 |
| scripts/hooks/ceo-asks.test.sh | PASS | 0 / 0 | 78.7 |
| scripts/hooks/ceo-todos.test.sh | PASS | 0 / 0 | 319.0 |
| scripts/hooks/completeness-commits.test.sh | PASS | 0 / 0 | 14.1 |
| scripts/hooks/contract-integrity.test.sh:CL | PASS | 3 / 3 | 147.3 |
| scripts/hooks/contract-integrity.test.sh:IL | PASS | 3 / 3 | 247.5 |
| scripts/hooks/contract-integrity.test.sh:IP | PASS | 3 / 3 | 167.6 |
| scripts/hooks/contract-integrity.test.sh:K | PASS | 3 / 3 | 50.5 |
| scripts/hooks/contract-integrity.test.sh:M | PASS | 3 / 3 | 55.5 |
| scripts/hooks/contract-integrity.test.sh:MC | PASS | 3 / 3 | 79.8 |
| scripts/hooks/contract-integrity.test.sh:MC6 | PASS | 3 / 3 | 82.8 |
| scripts/hooks/contract-integrity.test.sh:MF | PASS | 3 / 3 | 229.0 |
| scripts/hooks/contract-integrity.test.sh:MT | PASS | 3 / 3 | 113.1 |
| scripts/hooks/contract-integrity.test.sh:N | PASS | 3 / 3 | 27.3 |
| scripts/hooks/contract-integrity.test.sh:P | PASS | 3 / 3 | 108.0 |
| scripts/hooks/contract-integrity.test.sh:Q | PASS | 3 / 3 | 224.1 |
| scripts/hooks/contract-integrity.test.sh:Qscope | PASS | 3 / 3 | 89.8 |
| scripts/hooks/contract-integrity.test.sh:RI | PASS | 3 / 3 | 317.9 |
| scripts/hooks/contract-integrity.test.sh:S | PASS | 3 / 3 | 45.4 |
| scripts/hooks/contract-integrity.test.sh:SA | PASS | 3 / 3 | 147.4 |
| scripts/hooks/contract-integrity.test.sh:SCR | PASS | 3 / 3 | 493.9 |
| scripts/hooks/contract-integrity.test.sh:WTI | PASS | 3 / 3 | 544.9 |
| scripts/hooks/contract-integrity.test.sh:WTR | PASS | 3 / 3 | 220.1 |
| scripts/hooks/contract-integrity.test.sh:base | PASS | 3 / 3 | 179.7 |
| scripts/hooks/contract-integrity.test.sh:config | PASS | 3 / 3 | 46.4 |
| scripts/hooks/contract-integrity.test.sh:manifest | PASS | 3 / 3 | 105.0 |
| scripts/hooks/contract-integrity.test.sh:python3 | PASS | 3 / 3 | 5.1 |
| scripts/hooks/contract-integrity.test.sh:shim | PASS | 3 / 3 | 66.6 |
| scripts/hooks/contract-integrity.test.sh:worktree | PASS | 3 / 3 | 35.3 |
| scripts/hooks/engine-status.test.sh | PASS | 0 / 0 | 5.1 |
| scripts/hooks/guard-resume-isolation.test.sh | PASS | 0 / 0 | 14.1 |
| scripts/hooks/guard-vendoring-commits.test.sh | PASS | 0 / 0 | 93.9 |
| scripts/hooks/named-persons.test.sh | PASS | 0 / 0 | 12.1 |
| scripts/hooks/publication-boundary.test.sh | PASS | 0 / 0 | 24.2 |
| scripts/hooks/row-currency.test.sh | PASS | 0 / 0 | 313.9 |
| scripts/lib/mutation-harness.test.sh | PASS | 0 / 0 | 1.0 |
| scripts/lib/pause_protocol.test.sh | PASS | 0 / 0 | 1.0 |
| scripts/operator-fences.test.sh | PASS | 0 / 0 | 220.1 |
| scripts/provision-claude-md.test.sh | PASS | 0 / 0 | 2.0 |
| scripts/quota-watch.test.sh | PASS | 0 / 0 | 502.3 |
