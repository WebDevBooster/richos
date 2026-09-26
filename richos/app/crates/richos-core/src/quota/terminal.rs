//! Headless terminal entrypoint. Uses the desktop reset service, including its
//! record, flock, fresh preflight and durable fence before redemption.
use super::{reset_transport::System, resets::Service};
use serde_json::{json, Value};
use std::{io::{self, IsTerminal}, path::PathBuf, process::Command};

/// Also emitted in JSON so the installed wrapper can inspect the binary before launch.
pub const HEADLESS_PROTOCOL: &str = "--richos-quota-v1";

pub fn data_dir() -> Result<PathBuf, String> {
    let home = std::env::var_os("HOME").ok_or("HOME is unavailable")?;
    #[cfg(target_os = "macos")]
    return Ok(PathBuf::from(home).join("Library/Application Support/com.richos.app"));
    #[cfg(not(target_os = "macos"))]
    Ok(std::env::var_os("XDG_DATA_HOME").map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(home).join(".local/share")).join("com.richos.app"))
}

fn user_approval() -> Result<(), String> {
    if !io::stdin().is_terminal() || std::env::var_os("CLAUDECODE").is_some()
        || std::env::var_os("CLAUDE_CODE_ENTRYPOINT").is_some() {
        return Err("Approval must be given by the user in an interactive terminal, outside an agent session.".into());
    }
    #[cfg(target_os = "macos")]
    {
        // A PTY is not user identity. Require macOS device-owner authentication;
        // a model cannot answer this with a command-line flag or piped text.
        let status = Command::new("/usr/bin/swift").args(["-e", r#"
import Foundation
import LocalAuthentication
let context = LAContext()
context.touchIDAuthenticationAllowableReuseDuration = 0
var done = false
var allowed = false
context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Approve one free Claude weekly quota reset at 99% usage for RichOS") { success, _ in
    DispatchQueue.main.async { allowed = success; done = true }
}
let deadline = Date().addingTimeInterval(120)
while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
context.invalidate()
exit(allowed ? 0 : 1)
"#]).status().map_err(|_| "macOS user authentication requires the Swift command-line tools.".to_string())?;
        if status.success() { return Ok(()); }
    }
    Err("User authentication did not approve the reset. Nothing was armed.".into())
}

pub fn execute(args: &[String]) -> Result<Value, String> {
    let operation = args.first().map(String::as_str).unwrap_or("status");
    if !matches!(operation, "status" | "tick" | "approve" | "revoke")
        || args.len() > if operation == "approve" { 2 } else { 1 } {
        return Err("Usage: quota-reset.sh status | tick | approve <offer-id> | revoke".into());
    }
    if operation == "approve" && (!io::stdin().is_terminal()
        || std::env::var_os("CLAUDECODE").is_some()
        || std::env::var_os("CLAUDE_CODE_ENTRYPOINT").is_some()) {
        return Err("Only the user can approve a reset from an interactive terminal outside an agent session.".into());
    }
    let service = Service::new(&data_dir()?);
    if operation == "revoke" { return Ok(json!({"resets": service.revoke()?})); }
    let bin = std::env::var_os("QUOTA_CLAUDE_BIN").map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("claude"));
    let mut transport = System::connect(&bin)?;
    let mut view = service.refresh_transport(&mut transport)?;
    let mut action_error = None;
    if operation == "approve" {
        let id = args.get(1).ok_or("Choose an offer id from quota-reset.sh status.")?;
        let offer = view.offers.iter().find(|o| &o.id == id)
            .ok_or("That offer is not available. Refresh status.")?.clone();
        eprintln!("Approve one use of {} ({}) at 99% overall weekly usage. No reset is used by approval.", offer.label, offer.id);
        user_approval()?;
        // Authentication can take time. Refresh before binding approval to the offer.
        let _fresh = service.refresh_transport(&mut transport)?;
        view = service.approve(&offer)?;
    } else if operation == "tick" && service.prepared_action_due(crate::util::now_millis()) {
        match service.use_approved(&mut transport, || true) {
            Ok(result) => {
                view = result;
                // Reading after an attempt is allowed. It never retries redemption.
                if let Ok(fresh) = service.refresh_transport(&mut transport) { view = fresh; }
            }
            Err(error) => { action_error = Some(error); view = service.view(); },
        }
    }
    Ok(json!({"resets":view,"actionError":action_error}))
}

pub fn run(args: Vec<String>) -> i32 {
    match execute(&args) {
        Ok(mut value) => { value["protocol"] = json!(HEADLESS_PROTOCOL); println!("{value}"); 0 }
        Err(error) => { eprintln!("{error}"); 2 }
    }
}
