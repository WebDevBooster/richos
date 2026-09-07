# Installed broker shutdown finding

The final package at source `56a2805` passed all 20 then-defined installed
checks, but its disposable broker failed to exit after SIGTERM. Overall
acceptance failed despite successful volume reclamation and socket access.
The fixture was stopped and all its disposable storage was removed.

A separate read-only administrator diagnostic confirmed that both the root
launcher and its Python child inherited blocked SIGTERM and SIGINT. Installing
Python handlers did not unblock those signals. The broker now installs its
handlers, unblocks only those two control signals and then starts worker
threads. Unrelated inherited masks are preserved.

Review also identified a separate reentrancy hazard: a signal handler calling
`threading.Event.set()` can interrupt the same condition lock on the main
thread. The handler now only sets a boolean. The main loop performs normal
worker notification during shutdown.

Both failures have deterministic subprocess regressions. The inherited-mask
case failed before the change. A separate mutation retaining the mask fix but
restoring the locking handler deadlocked when a second signal arrived in the
stop-event critical section. The corrected CLTools Python suite passed all
35 tests. The corrected package subsequently passed all 26 installed checks, including
clean shutdown through the same launcher. See the [successful rerun](managed-workspace-installed-lifecycle-2026-09-07.md).

The [failed acceptance and actual masks](managed-workspace-broker-shutdown-2026-09-07.json)
preserve the evidence. Production cleanup remained inactive throughout.
