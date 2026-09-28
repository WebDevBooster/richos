# Managed verification resources

The existing CPU controller advertises verification protocol 1. A matching proof
runner reserves CPU and memory before launching each check. The process supervisor
inherits the kernel lease, records the child generation before exec and holds the
reservation through descendant cleanup. Nested work belongs to that owned tree;
worker permits still govern its expansion and borrowing.
Main-checkout priority remains held while an eligible check waits for measured
capacity after obtaining a worker permit. Obtaining that permit alone does not
give competing work a gap in integration priority.

Reservations use measured tree demand with a safety margin. They leave explicit
headroom for unowned host and system-service demand. Unknown inputs calibrate
exclusively under finite execution deadlines. Short checks without representative
samples remain unqualified. Sampled live-process CPU is supplemented with reaped
child CPU; the records distinguish those measurements. This is not a kernel quota.

After ten seconds of sustained host pressure the controller closes expansion.
Because no live concurrency reducer is qualified, it contains a measured contributor
by twenty seconds. Selection considers integration priority, contribution and lost
CPU. The supervisor performs owned cleanup; the controller escalates against precise
native generations after fifteen seconds and reports failure at thirty seconds.
Controller health failure also stops already running managed checks.

Pressure containment is distinct from an assertion failure. Its result includes
cause, cleanup and lost work. The runner preserves the attempt and retries it before
new work after the controller's ten-second recovery window. Three containments for
unchanged inputs exhaust a durable separate budget and report scheduler starvation.
An owned demand-envelope breach uses a separate resource budget and requires measured
recalibration. Neither outcome becomes an accepted receipt or consumes the behavioral
failure budget.

When that policy is exhausted, the runner can make one recorded change to exclusive
calibration. The alternate identity is deterministic, links to the original counters
and requires matching completed cleanup evidence. Its measured envelope retains a
floor from the original fault measurements. It continues to reserve exclusive
capacity after qualification. Its own bounded recovery counters can never create
another alternate policy. Exhaustion refuses immediately and retains diagnostics;
it does not spend an admission wait on a policy that cannot run.

The enabled marker survives loss of controller telemetry, so deleting a heartbeat
cannot return an installed runner to legacy admission. Completed receipts retain their
original identities. Per-attempt logs, interrupted receipts and supervision records
remain in the run directory; summaries disclose repeated work.
Execution totals include earlier attempts, queue totals accumulate across retries
and available reaped CPU is reported separately from elapsed time. Missing CPU
measurement stays unknown. A resource-capacity refusal retains its own queue
reason instead of being reported as a shortage of worker permits.

Current qualification boundary: proof-run and its nested supervised work use this
protocol when advertised by the controller. Direct/nightly/older launcher routing,
explicit fixture-mode enforcement, measured concurrent demand and fixed integration
episodes still need qualification before installation. Do not describe this partial
protocol as universal shell interception or as measured production performance.
