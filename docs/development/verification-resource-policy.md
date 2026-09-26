# Managed verification resources

The existing CPU controller advertises verification protocol 1. A matching proof
runner reserves CPU and memory before launching each check. The process supervisor
inherits the kernel lease, records the child generation before exec and holds the
reservation through descendant cleanup. Nested work belongs to that owned tree;
worker permits still govern its expansion and borrowing.

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

The enabled marker survives loss of controller telemetry, so deleting a heartbeat
cannot return an installed runner to legacy admission. Completed receipts retain their
original identities. Per-attempt logs, interrupted receipts and supervision records
remain in the run directory; summaries disclose repeated work.

Current qualification boundary: proof-run and its nested supervised work use this
protocol when advertised by the controller. Direct/nightly/older launcher routing,
explicit fixture-mode enforcement, resource recalibration and fixed integration
recovery still need qualification before installation. Do not describe this partial
protocol as universal shell interception or as measured production performance.
