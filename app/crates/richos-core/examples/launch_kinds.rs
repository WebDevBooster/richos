//! Drive the three launch kinds against a real file, and print the record after each.
//!
//! `cargo run -p richos-core --example launch_kinds`
//!
//! The tests in `launch.rs` assert these outcomes; this shows them. The difference matters
//! for one thing in particular — the local-vs-UTC bucketing at the end is a claim about
//! numbers, and a claim about numbers should be readable as numbers by anyone who wants to
//! check it rather than as an assertion inside a test that only fails when it is wrong.
//!
//! Each "process" below is a scope. Opening a `LaunchStore`, calling `begin_run`, and
//! letting it drop without `note_clean_exit` is exactly what a crash leaves behind: the
//! marker on disk, and nobody to clear it.

use richos_core::launch::{LaunchCounts, LaunchKind, LaunchStore, PriorRun};
use std::fs;

/// 2026-08-31T09:00:00Z. Every timestamp below is UTC epoch millis, because that is the
/// only thing this record ever stores.
const T0: u64 = 1_788_166_800_000;

/// US Pacific daylight time, the market's own offset — from UTC, positive east.
const PACIFIC: i32 = -420;

fn show(tag: &str, kind: LaunchKind, store: &LaunchStore, now: u64) {
    let counts = store.counts(now, PACIFIC);
    println!("  {tag}");
    println!("     kind        {}", kind.as_str());
    println!("     counted     {}", if kind.is_start() { "YES" } else { "no" });
    println!("     splash      {}", if kind.shows_splash() { "shown" } else { "NONE" });
    // WHICH START THIS IS, which is what the CEO's v1 splash rule is a table over: start 1
    // shows screen #1, start 2 shows #2, start 3 and after show #1. `None` is not a zero -
    // it means this run is not a start, or the record could not be read.
    println!(
        "     ordinal     {}",
        store
            .start_ordinal()
            .map(|n| n.to_string())
            .unwrap_or_else(|| "none — not a start, or the record is unreadable".to_string())
    );
    println!("     starts      {:?}", store.starts());
    match counts {
        Some(c) => println!(
            "     buckets     today {} · week {} · month {} · year {} · total {}",
            c.today, c.this_week, c.this_month, c.this_year, c.total
        ),
        None => println!("     buckets     unreadable record — no counts, rather than a zero that is a lie"),
    }
    println!("     ring        {:?}", store.recent_splashes());
    println!("     installed   {:?}", store.installed_at());
    println!("     run open    {}", store.run_is_open());
    println!();
}

fn main() {
    let dir = std::env::temp_dir().join(format!("richos-launch-kinds-{}", std::process::id()));
    fs::create_dir_all(&dir).expect("temp dir");
    let path = dir.join("launches.json");
    println!("\nrecord: {}\n", path.display());

    // ---- 1. A FRESH LAUNCH. No file at all, so nothing was ever open: he quit (or has
    // never been here). Counted, and the splash shows.
    {
        let mut store = LaunchStore::open(&path, T0).expect("open");
        let kind = store.begin_run(T0, "pid-1", PriorRun::Unknown).expect("begin");
        store.note_splash_shown("round-11/v1").expect("ring");
        show("1. FRESH LAUNCH — no marker on disk, so the last thing that happened was a quit", kind, &store, T0);
        store.note_clean_exit().expect("quit");
    }

    // ---- 2. A SECOND FRESH LAUNCH, so there is more than one thing in the log to bucket.
    let t1 = T0 + 3_600_000; // an hour later, 03:00 Pacific, same local day
    {
        let mut store = LaunchStore::open(&path, t1).expect("open");
        let kind = store.begin_run(t1, "pid-2", PriorRun::Unknown).expect("begin");
        store.note_splash_shown("round-11/v2").expect("ring");
        show("2. FRESH LAUNCH again — he quit, he came back", kind, &store, t1);
        // NO `note_clean_exit`. What follows is what a power cut leaves.
    }

    // ---- 3. A CRASH-RESTART. The marker is still there and nobody said it was alive.
    let t2 = t1 + 30_000;
    {
        let mut store = LaunchStore::open(&path, t2).expect("open");
        let kind = store.begin_run(t2, "pid-3", PriorRun::Unknown).expect("begin");
        show(
            "3. CRASH-RESTART — the marker survived, PriorRun::Unknown, so it is read as a death",
            kind,
            &store,
            t2,
        );
        println!(
            "     -> the log is unchanged and the ring is unchanged: nothing was counted and\n\
             \x20       nothing was drawn, so there was nothing to record.\n"
        );
        // Again no clean exit, so the next one has a marker to find.
    }

    // ---- 4. A SECOND WINDOW, two ways.
    let t3 = t2 + 5_000;
    {
        // (a) A second COPY of the app, launched while one is running. The caller positively
        // observed the prior run to be alive, which is the only thing that distinguishes
        // this from case 3 — and the reason `PriorRun` is a parameter rather than a guess.
        let mut store = LaunchStore::open(&path, t3).expect("open");
        let kind = store.begin_run(t3, "pid-4", PriorRun::Alive).expect("begin");
        show("4a. SECOND WINDOW — a second copy, with the first positively observed alive", kind, &store, t3);

        store.note_clean_exit().expect("quit");
    }

    // (b) A second window of THIS run, which is what actually happens in the shell: one
    // process, several windows. The first window inherits the run's kind; every one after
    // it is a second window whatever the run was. A FRESH scope, because the store above
    // is a second copy whose first window is correctly also a second window — true, and
    // the wrong thing to demonstrate the inheritance with.
    let t4 = t3 + 1_000;
    {
        let mut store = LaunchStore::open(&path, t4).expect("open");
        let kind = store.begin_run(t4, "pid-5", PriorRun::Unknown).expect("begin");
        println!("  4b. SECOND WINDOW — one {} run, three windows opened in order", kind.as_str());
        for i in 1..=3 {
            let k = store.next_window_kind();
            println!("     window {i}    {} — splash {}", k.as_str(), if k.shows_splash() { "shown" } else { "NONE" });
        }
        println!();
        store.note_clean_exit().expect("quit");
    }

    // ---- 5. THE BOUNDARY. Same log, two calendars.
    println!("5. STORE UTC, BUCKET LOCAL — the same three launches, read two ways\n");
    let store = LaunchStore::open(&path, T0).expect("open");
    let now_local_early = T0 + 3_600_000 * 2; // 2026-08-31T11:00:00Z = 04:00 Pacific
    let local = LaunchCounts::of(store.starts(), now_local_early, PACIFIC);
    let utc = LaunchCounts::of(store.starts(), now_local_early, 0);
    println!("     (a) the CONTROL: no bucket boundary between the two calendars, so they agree");
    println!("     read at 2026-08-31T11:00:00Z, which is 04:00 on the 31st in California");
    println!("     LOCAL (-420)   today {} · week {} · month {} · year {} · total {}", local.today, local.this_week, local.this_month, local.this_year, local.total);
    println!("     UTC   (   0)   today {} · week {} · month {} · year {} · total {}", utc.today, utc.this_week, utc.this_month, utc.this_year, utc.total);
    println!();

    // And the case the ruling is actually about: an EVENING session, which is already
    // tomorrow in UTC.
    let evening = 1_788_148_800_000u64; // 2026-08-31T04:00:00Z = 2026-08-30 21:00 Pacific
    let after_midnight = 1_788_163_200_000u64; // 2026-08-31T08:00:00Z = 2026-08-31 01:00 Pacific
    let now = T0; // 2026-08-31T09:00:00Z = 02:00 Pacific on the 31st
    let two = [evening, after_midnight];
    let l = LaunchCounts::of(&two, now, PACIFIC);
    let u = LaunchCounts::of(&two, now, 0);
    println!("     (b) the case the ruling is about: an EVENING session, already tomorrow in UTC");
    println!("     two launches: 2026-08-31T04:00Z (Sunday 21:00 in California) and");
    println!("                   2026-08-31T08:00Z (Monday 01:00 in California)");
    println!("     read at       2026-08-31T09:00Z (Monday 02:00 in California)");
    println!("     LOCAL today   {}   <- one. His Sunday evening was Sunday.", l.today);
    println!("     UTC   today   {}   <- two. Both are the 31st in UTC, and neither of us lives there.", u.today);
    println!("     LOCAL week    {}   <- the Monday one only; the week starts Monday (WEEK_STARTS_ON)", l.this_week);
    println!("     total         {} either way — total is the one bucket that cannot disagree.", l.total);
    println!();

    // The sharper form, across a YEAR.
    let nye = 1_798_779_600_000u64; // 2027-01-01T05:00:00Z = 2026-12-31 21:00 Pacific
    let ny_day = 1_798_822_800_000u64; // 2027-01-01T17:00:00Z = 2027-01-01 09:00 Pacific
    println!("     (c) the sharper form, across a YEAR");
    println!("     one launch:   2027-01-01T05:00Z, which is NEW YEAR'S EVE in California");
    println!("     read at       2027-01-01T17:00Z, New Year's morning");
    println!("     LOCAL year    {}   <- he opened it last year, where he was.", LaunchCounts::of(&[nye], ny_day, PACIFIC).this_year);
    println!("     UTC   year    {}   <- UTC says this year.", LaunchCounts::of(&[nye], ny_day, 0).this_year);
    println!();

    fs::remove_dir_all(&dir).ok();
}
