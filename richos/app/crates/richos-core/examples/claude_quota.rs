//! Read-only smoke test: cargo run -p richos-core --example claude_quota -- --live /path/to/claude
//! The same executable also exposes the desktop's hook entrypoint for integration checks.
use richos_core::quota::{self, Service};
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args_os().skip(1);
    match args.next().as_deref().and_then(|s| s.to_str()) {
        Some("--claude-quota-gate") => std::process::exit(quota::gate::run_cli()),
        Some("--live") => {}
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
