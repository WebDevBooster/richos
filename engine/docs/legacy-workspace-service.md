# Automatic execution of armed legacy maintenance

The installed broker has a separate background worker for explicitly armed
legacy jobs. It does not create gates, arm jobs from a socket request or reboot
the computer. Normal managed-image sweeps and socket requests continue while a
legacy capture runs.

The protected administrator command `arm-job` validates an exact job selection
and its approved hash before reserving per-gate scratch storage. The job binds
every candidate and branch to its repository alias and original gate approval.
Its scope cannot expand during retries. `job-status` reads atomic records without
waiting on the gate lock. `advance-job` is an administrator recovery command;
normal advancement runs automatically in the broker.

The worker discovers only UUID gate directories containing an armed job. Before
each sweep it rereads the protected policy file supplied to the broker and
checks each gate's owner, group and repository aliases. A revoked or malformed
gate is reported and held while unrelated valid jobs continue. Moving the
configured storage root requires a daemon restart and administrative migration.

Before starting a long operation, the worker publishes the discovered job and
its last observed phase to an owner-filtered status cache. An `advancing` flag
identifies the in-flight operation. Status and health requests use this cache;
they do not execute maintenance. Unknown inventory is reported as unknown.

Waiting for a verified later boot is quiet. Progress schedules the next durable
step promptly. Unchanged waiting or failed states back off to the normal sweep
interval. The broker logs changes in actionable failures without repeating
unchanged warnings on every pass.

Completed jobs are not retired again. The worker separately advances their
saved clean recovery proofs under the current approved alias retention policy.
After the retention interval, verified bulk archives can be removed while
compact metadata and Git recovery refs remain. Historical, dirty or uncertain
archives stay retained. Expiry progress and bounded failure reasons appear in
the same owner-filtered status, independently of the completed retirement phase.

The complete disposable test drives the actual archive, recovery refs,
retirement journal, branch publication and gate restoration through this worker.
The broker socket test deliberately blocks a legacy capture and verifies that
normal requests and signal shutdown still work. Installed privilege and actual
reboot acceptance are separate from these fixtures.

See [job scope and replay](legacy-workspace-job.md) and
[directory reclamation](legacy-workspace-retirement.md).
