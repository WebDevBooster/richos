# Passing full proof report

Tested commit: `9cb275328ac5e09e0a5336a0bf918f00ad44ffb4`.
Base: `261bc268bb87d488407f0b2cc6a88d06a08aff02`.

Command: `python3 richos/app/scripts/proof-run.py --keep-going origin/main..HEAD`.

Exit **0**. **88 of 88 selected checks passed** in 625 seconds.
Source was clean at start and unchanged at completion.

host during the run: 57 samples, total CPU mean 51%, max 94%, at or over the 80% admission line in 11 of them (system CPU mean 17%, max 56%); worker tokens held: max 8 of 8, nested workers waiting for one: max 0

Two native GUI suites report NOT RUN because the selector specifies `--no-host-screen`:
`front-door.test.sh` and `gui-boot.test.sh`. Their wrapper exit codes are 0.
Browser UI suites ran, including `front-door.js`.

| Check | Result | Seconds | Exit | Command |
| --- | --- | ---: | ---: | --- |
| proof-for | passed | 206.8 | 0 | `cd richos/app && scripts/run-tests.sh --no-host-screen --only proof-for.test.sh` |
| make-release | passed | 178.5 | 0 | `cd richos/app && scripts/run-tests.sh --no-host-screen --only make-release.test.sh` |
| slow-bridge.js | passed | 157.1 | 0 | `cd richos/app/ui/tests && node slow-bridge.js` |
| contrast.js | passed | 147.6 | 0 | `cd richos/app/ui/tests && node contrast.js` |
| make-engine-asset | passed | 140.3 | 0 | `cd richos/app && bash scripts/make-engine-asset.test.sh` |
| splash.js | passed | 137.6 | 0 | `cd richos/app/ui/tests && node splash.js` |
| phone.js | passed | 133.2 | 0 | `cd richos/app/ui/tests && node phone.js` |
| quota.js | passed | 96.3 | 0 | `cd richos/app/ui/tests && node quota.js` |
| affordances.js | passed | 94.0 | 0 | `cd richos/app/ui/tests && node affordances.js` |
| home.js | passed | 73.7 | 0 | `cd richos/app/ui/tests && node home.js` |
| lint | passed | 69.2 | 0 | `cd richos/app && scripts/run-tests.sh --no-host-screen --only lint.test.sh` |
| techy.js | passed | 68.6 | 0 | `cd richos/app/ui/tests && node techy.js` |
| appearance.js | passed | 63.3 | 0 | `cd richos/app/ui/tests && node appearance.js` |
| home-fit.js | passed | 57.0 | 0 | `cd richos/app/ui/tests && node home-fit.js` |
| settings-fit.js | passed | 53.3 | 0 | `cd richos/app/ui/tests && node settings-fit.js` |
| cargo -p richos-core | passed | 53.2 | 0 | `cd richos/app && cargo test -p richos-core` |
| updates.js | passed | 52.9 | 0 | `cd richos/app/ui/tests && node updates.js` |
| waiting-state.js | passed | 43.3 | 0 | `cd richos/app/ui/tests && node waiting-state.js` |
| mobile-pwa | passed | 40.5 | 0 | `cd richos/app && scripts/run-tests.sh --no-host-screen --only mobile-pwa.test.sh` |
| restart-scope.js | passed | 39.9 | 0 | `cd richos/app/ui/tests && node restart-scope.js` |
| memory-strategy.js | passed | 33.1 | 0 | `cd richos/app/ui/tests && node memory-strategy.js` |
| feedback.js | passed | 30.1 | 0 | `cd richos/app/ui/tests && node feedback.js` |
| corrections.js | passed | 30.0 | 0 | `cd richos/app/ui/tests && node corrections.js` |
| chrome-align.js | passed | 29.5 | 0 | `cd richos/app/ui/tests && node chrome-align.js` |
| compaction-progress.js | passed | 28.7 | 0 | `cd richos/app/ui/tests && node compaction-progress.js` |
| navigation-evidence.js | passed | 28.3 | 0 | `cd richos/app/ui/tests && node navigation-evidence.js` |
| setup.js | passed | 27.3 | 0 | `cd richos/app/ui/tests && node setup.js` |
| waiting-lifecycle.js | passed | 25.7 | 0 | `cd richos/app/ui/tests && node waiting-lifecycle.js` |
| compaction-notice.js | passed | 25.1 | 0 | `cd richos/app/ui/tests && node compaction-notice.js` |
| ticker-wrap.js | passed | 20.7 | 0 | `cd richos/app/ui/tests && node ticker-wrap.js` |
| scale.js | passed | 17.1 | 0 | `cd richos/app/ui/tests && node scale.js` |
| cargo --bin richos-tauri | passed | 16.8 | 0 | `cd richos/app/src-tauri && cargo test --bin richos-tauri` |
| voice-model.js | passed | 14.9 | 0 | `cd richos/app/ui/tests && node voice-model.js` |
| mobile-mac | passed | 14.1 | 0 | `cd richos/app && scripts/run-tests.sh --no-host-screen --only mobile-mac.test.sh` |
| cargo opener:: | passed | 12.8 | 0 | `cd richos/app/src-tauri && cargo test --bin richos-tauri opener::` |
| onboarding.js | passed | 12.4 | 0 | `cd richos/app/ui/tests && node onboarding.js` |
| cargo -p richos-core --lib | passed | 11.6 | 0 | `cd richos/app && cargo test -p richos-core --lib` |
| escape.js | passed | 10.4 | 0 | `cd richos/app/ui/tests && node escape.js` |
| retention.js | passed | 10.2 | 0 | `cd richos/app/ui/tests && node retention.js` |
| second-mouth.js | passed | 8.9 | 0 | `cd richos/app/ui/tests && node second-mouth.js` |
| memory.js | passed | 8.4 | 0 | `cd richos/app/ui/tests && node memory.js` |
| attachments.js | passed | 8.4 | 0 | `cd richos/app/ui/tests && node attachments.js` |
| inspector.js | passed | 8.4 | 0 | `cd richos/app/ui/tests && node inspector.js` |
| steering.js | passed | 8.3 | 0 | `cd richos/app/ui/tests && node steering.js` |
| work-summary.js | passed | 7.0 | 0 | `cd richos/app/ui/tests && node work-summary.js` |
| cargo -p richos-core --test engine_profile | passed | 5.8 | 0 | `cd richos/app && cargo test -p richos-core --test engine_profile` |
| onboarding-lifecycle.js | passed | 5.5 | 0 | `cd richos/app/ui/tests && node onboarding-lifecycle.js` |
| permissions.js | passed | 5.2 | 0 | `cd richos/app/ui/tests && node permissions.js` |
| provider-auth.js | passed | 4.6 | 0 | `cd richos/app/ui/tests && node provider-auth.js` |
| front-door.js | passed | 4.5 | 0 | `cd richos/app/ui/tests && node front-door.js` |
| no-compile-time-paths | passed | 4.3 | 0 | `cd richos/app && scripts/run-tests.sh --no-host-screen --only no-compile-time-paths.test.sh` |
| repositories.js | passed | 4.3 | 0 | `cd richos/app/ui/tests && node repositories.js` |
| composer-scroll.js | passed | 4.3 | 0 | `cd richos/app/ui/tests && node composer-scroll.js` |
| cargo native:: | passed | 4.3 | 0 | `cd richos/app && cargo test -p richos-core --lib native::` |
| cargo work_host:: | passed | 2.9 | 0 | `cd richos/app && cargo test -p richos-core --lib work_host::` |
| local-notice.js | passed | 2.5 | 0 | `cd richos/app/ui/tests && node local-notice.js` |
| composer-off.js | passed | 2.5 | 0 | `cd richos/app/ui/tests && node composer-off.js` |
| cargo quota:: | passed | 2.2 | 0 | `cd richos/app && cargo test -p richos-core --lib quota::` |
| thread-switch.js | passed | 2.1 | 0 | `cd richos/app/ui/tests && node thread-switch.js` |
| ui-ledger | passed | 2.1 | 0 | `cd richos/app && scripts/run-tests.sh --no-host-screen --only ui-ledger.test.sh` |
| control-names.js | passed | 2.1 | 0 | `cd richos/app/ui/tests && node control-names.js` |
| quit-question.js | passed | 2.1 | 0 | `cd richos/app/ui/tests && node quit-question.js` |
| claude-quota | passed | 1.9 | 0 | `cd richos/app && scripts/run-tests.sh --no-host-screen --only claude-quota.test.sh` |
| background-work.js | passed | 1.9 | 0 | `cd richos/app/ui/tests && node background-work.js` |
| first-run-sheet.js | passed | 1.9 | 0 | `cd richos/app/ui/tests && node first-run-sheet.js` |
| realbytes.js | passed | 1.9 | 0 | `cd richos/app/ui/tests && node realbytes.js` |
| workers.js | passed | 1.7 | 0 | `cd richos/app/ui/tests && node workers.js` |
| interruption.js | passed | 1.5 | 0 | `cd richos/app/ui/tests && node interruption.js` |
| no-foreign-app-data | passed | 1.5 | 0 | `cd richos/app && scripts/run-tests.sh --no-host-screen --only no-foreign-app-data.test.sh` |
| cargo -p richos-core --test native_cancel_tests | passed | 1.4 | 0 | `cd richos/app && cargo test -p richos-core --test native_cancel_tests` |
| question-timer.js | passed | 1.3 | 0 | `cd richos/app/ui/tests && node question-timer.js` |
| markdown.js | passed | 1.2 | 0 | `cd richos/app/ui/tests && node markdown.js` |
| live-workers.js | passed | 1.2 | 0 | `cd richos/app/ui/tests && node live-workers.js` |
| outage.js | passed | 1.0 | 0 | `cd richos/app/ui/tests && node outage.js` |
| cargo assignment:: | passed | 1.0 | 0 | `cd richos/app && cargo test -p richos-core --lib assignment::` |
| cargo -p richos-core --test native_onboarding_grant_tests | passed | 1.0 | 0 | `cd richos/app && cargo test -p richos-core --test native_onboarding_grant_tests` |
| cargo recovery:: | passed | 1.0 | 0 | `cd richos/app && cargo test -p richos-core --lib recovery::` |
| frontend-payload | passed | 0.8 | 0 | `cd richos/app && scripts/run-tests.sh --no-host-screen --only frontend-payload.test.sh` |
| cargo -p richos-core --test between_turn_tests | passed | 0.8 | 0 | `cd richos/app && cargo test -p richos-core --test between_turn_tests` |
| cargo status_tools:: | passed | 0.8 | 0 | `cd richos/app && cargo test -p richos-core --lib status_tools::` |
| cargo -p richos-core --test between_turn_thread_tests | passed | 0.6 | 0 | `cd richos/app && cargo test -p richos-core --test between_turn_thread_tests` |
| cargo -p richos-core --test launch_no_outbound_tests | passed | 0.6 | 0 | `cd richos/app && cargo test -p richos-core --test launch_no_outbound_tests` |
| cargo -p richos-core --test doctrine_sentinel | passed | 0.6 | 0 | `cd richos/app && cargo test -p richos-core --test doctrine_sentinel` |
| dialect.js | passed | 0.4 | 0 | `cd richos/app/ui/tests && node dialect.js` |
| no-home-network.js | passed | 0.4 | 0 | `cd richos/app/ui/tests && node no-home-network.js` |
| gui-boot | passed | 0.4 | 0 | `cd richos/app && scripts/run-tests.sh --no-host-screen --only gui-boot.test.sh` |
| front-door | passed | 0.4 | 0 | `cd richos/app && scripts/run-tests.sh --no-host-screen --only front-door.test.sh` |
| cargo -p richos-core --test feedback_no_outbound_tests | passed | 0.4 | 0 | `cd richos/app && cargo test -p richos-core --test feedback_no_outbound_tests` |
