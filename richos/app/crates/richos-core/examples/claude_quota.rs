//! Read-only smoke test: cargo run -p richos-core --example claude_quota -- --live /path/to/claude
//! The same executable also exposes the desktop's hook entrypoint for integration checks.
use richos_core::quota::{self, Service};
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args_os().skip(1);
    match args.next().as_deref().and_then(|s| s.to_str()) {
        Some("--claude-quota-gate") => std::process::exit(quota::gate::run_cli()),
        Some("--live") => {}
        Some("--measure") => return measure(args),
        _ => return Err("Pass --live and the Claude Code executable path.".into()),
    }
    let bin = args.next().ok_or("Missing Claude Code executable path.")?;
    let root = std::env::temp_dir().join(format!("richos-quota-smoke-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&root)?;
    let result = (|| -> Result<(), Box<dyn std::error::Error>> {
        let service = Service::open(&root)?;
        let view = service.refresh(std::path::Path::new(&bin), true);
        service.shutdown();
        println!(
            "Quota state: {:?}; recognized windows: {}; no model turn requested.",
            view.state,
            view.windows.len()
        );
        if view.windows.is_empty() {
            return Err("No subscription windows returned.".into());
        }
        Ok(())
    })();
    std::fs::remove_dir_all(root)?;
    result
}

/// **What one quota reading costs** (fill-first, plan §15 answer 10: "check what one reading
/// costs" before choosing the fast interval). `--measure /path/to/claude N`: N forced reads on
/// ONE service, 6 s apart (past the 5 s double-click cooldown), each timed; after each, the
/// resident control-only child's memory and cumulative CPU time from `ps`. The first read is
/// cold (spawn, initialize, get_usage); the rest reuse the connection, as the app does.
/// Read-only: the same control-only `get_usage` the app's five-minute probe sends.
fn measure(mut args: impl Iterator<Item = std::ffi::OsString>) -> Result<(), Box<dyn std::error::Error>> {
    let bin = args.next().ok_or("Missing Claude Code executable path.")?;
    let reads: usize = args.next().and_then(|n| n.to_str()?.parse().ok()).unwrap_or(3);
    // The gap between reads, seconds (at least 6, past the 5 s cooldown). Two runs with
    // different gaps tell a read's own CPU from the idle child's.
    let gap: u64 = args.next().and_then(|n| n.to_str()?.parse().ok()).unwrap_or(6).max(6);
    let root = std::env::temp_dir().join(format!("richos-quota-measure-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&root)?;
    let result = (|| -> Result<(), Box<dyn std::error::Error>> {
        let service = Service::open(&root)?;
        for read in 1..=reads {
            let started = std::time::Instant::now();
            let view = service.refresh(std::path::Path::new(&bin), true);
            let ms = started.elapsed().as_millis();
            let me = std::process::id().to_string();
            let ps = std::process::Command::new("/bin/ps").args(["-A", "-o", "ppid=,rss=,time="]).output()?;
            let child: Vec<String> = String::from_utf8_lossy(&ps.stdout).lines()
                .map(|l| l.split_whitespace().map(str::to_string).collect::<Vec<_>>())
                .filter(|f| f.len() == 3 && f[0] == me).map(|f| format!("rss {} KiB, cpu {}", f[1], f[2])).collect();
            println!("read {read}: {ms} ms, state {:?}, windows {}; child: {}", view.state, view.windows.len(),
                if child.is_empty() { "none".to_string() } else { child.join("; ") });
            if read < reads { std::thread::sleep(std::time::Duration::from_secs(gap)); }
        }
        service.shutdown();
        Ok(())
    })();
    std::fs::remove_dir_all(root)?;
    result
}
