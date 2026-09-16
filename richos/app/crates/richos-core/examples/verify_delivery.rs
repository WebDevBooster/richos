//! Inspect an extracted delivery without activating it or using private app state.
use std::path::PathBuf;
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let engine = PathBuf::from(std::env::args().nth(1).ok_or("supply the extracted engine directory")?);
    let runtime = richos_core::runtime::verify_engine(&engine)?;
    let state = std::env::temp_dir().join(format!("richos-delivery-check-{}", uuid::Uuid::new_v4()));
    let bridge = richos_core::ecs::EcsBridge::new(&runtime.python, &engine, &state)?;
    let reply = bridge.request("hello", serde_json::json!({}));
    let _ = std::fs::remove_dir_all(&state);
    reply?;
    println!("{}", serde_json::json!({"component_contracts":true, "runtime_inventory":true,
        "ecs_protocol":true, "versions":runtime.versions, "installed_acceptance":false}));
    Ok(())
}
