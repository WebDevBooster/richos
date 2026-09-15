//! WHAT THE WORK GATE COSTS TO ASK — measured, because the ruling it serves is about not
//! getting in the way.
//!
//! The CEO's sentence that ranks this update against everything else: *"The update is not
//! important enough to get in the way of finishing work."* `updates.rs`'s watcher re-reads
//! the gate every 5 seconds while an update is waiting, and two of its three sources are
//! free — a mutex read and a `try_lock`. The third is not: `worker_status::current_status`
//! opens two files, parses every line and runs a liveness syscall per open run. **A claim
//! that this is negligible is a timing claim, and a timing claim gets measured rather than
//! asserted.**
//!
//! This is not a benchmark and its ceiling is not a target. The number that matters is
//! printed (`cargo test -p richos-core --test work_gate_cost -- --nocapture`); the assertion
//! is set two orders of magnitude above it so that it stays quiet on a loaded machine and
//! still catches the failure that would actually hurt — a change that makes this quadratic
//! in the number of worker rows, which is the shape `worker_events` grows in.

use richos_core::work_gate::{self, WorkSources};
use richos_core::worker_status;
use std::io::Write;
use std::time::Instant;

/// The scale the watcher meets on a real machine. Measured on the development machine on
/// 2026-09-05: the live session's `worker-events.jsonl` held 2,918 rows. This fixture is
/// built at that size rather than at a token 10, because a cost that is fine at 10 rows and
/// not at 3,000 is exactly the cost worth knowing about.
const ROWS: usize = 3000;

/// A read that takes this long means something structural broke, not that the laptop was
/// busy. At the measured cost it is roughly a 100x margin.
const CEILING_MS: u128 = 200;

fn fixture() -> std::path::PathBuf {
    let base = std::env::temp_dir().join(format!(
        "richos-work-gate-cost-{}-{}",
        std::process::id(),
        richos_core::util::now_millis()
    ));
    // NAMED for a session, so `SessionScope::from_team_dir` yields a real prefix and the
    // scope filter is exercised rather than bypassed — the same shape `worker_status`'s own
    // tests use.
    let dir = base.join("session-abcd1234");
    std::fs::create_dir_all(&dir).unwrap();

    let mut f = std::io::BufWriter::new(std::fs::File::create(dir.join("worker-events.jsonl")).unwrap());
    for i in 0..ROWS {
        // Every row a `run_ended`-matched pair would be the cheap case; alternating leaves
        // open runs, which is what triggers the liveness probe. PID 1 is `launchd` — always
        // present, never ours, and answering `kill(1, 0)` is the syscall being timed.
        let state = if i % 2 == 0 { "created" } else { "run_ended" };
        writeln!(
            f,
            r#"{{"timestamp":"2026-09-05T04:00:00+00:00","lifecycle_state":"{state}","source_hook":"h","agent_id":"a{i}","agent_type":"dev","session_id":"abcd1234-full","decision":"logged","host_pid":1}}"#
        )
        .unwrap();
    }
    drop(f);
    dir
}

#[test]
fn reading_the_gate_is_cheap_enough_to_do_every_five_seconds() {
    let dir = fixture();
    // `current_status` resolves its directory from the session id or from an explicit
    // override; the override is the only way to point it at a fixture.
    std::env::set_var("RICHOS_TEAM_DIR", &dir);

    // One warm read so the measurement is of the work and not of the first page fault.
    let _ = worker_status::current_status(None);

    const N: u32 = 20;
    let started = Instant::now();
    for _ in 0..N {
        let view = worker_status::current_status(None);
        // The decision itself, so the number covers the whole question the watcher asks
        // rather than only its expensive third.
        let (workers, gap) = work_gate::workers(&view);
        let _ = work_gate::decide(&WorkSources { workers, worker_gap: gap, ..WorkSources::all_clear() });
    }
    let per_read_us = started.elapsed().as_micros() / u128::from(N);

    std::env::remove_var("RICHOS_TEAM_DIR");
    let _ = std::fs::remove_dir_all(dir.parent().unwrap());

    // The arithmetic the watcher's doc comment quotes, shown rather than asserted:
    //   duty cycle = per-read time / WATCH_INTERVAL = per_read_us / 5_000_000 us
    let duty_percent = (per_read_us as f64) / 5_000_000.0 * 100.0;
    println!(
        "work gate over {ROWS} worker rows: {per_read_us} us per read; \
         at one read per 5 s that is {duty_percent:.4} % of one core"
    );

    assert!(
        per_read_us / 1000 < CEILING_MS,
        "reading the work gate took {per_read_us} us over {ROWS} rows — the watcher runs this \
         every 5 s while an update waits, and the ruling it serves is that the update must not \
         get in the way of finishing work"
    );
}
