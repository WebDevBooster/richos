//! Durable receiving inbox for answers addressed to a product work assignment.
//! The existing work runner consumes these only at its assignment boundary.
use crate::questions::Delivery;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
#[derive(Serialize, Deserialize)]
struct Input {
    delivery: Delivery,
    handed: bool,
}
fn directory(root: &Path) -> PathBuf {
    root.join("questions/work-inputs")
}
fn path(root: &Path, id: &str) -> PathBuf {
    directory(root).join(format!("{:x}.json", Sha256::digest(id.as_bytes())))
}
fn write(path: &Path, value: &Input) -> Result<(), String> {
    use std::io::Write;
    let dir = path.parent().unwrap();
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let temp = dir.join(format!("{}.new", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut f = std::fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&temp)
            .map_err(|e| e.to_string())?;
        serde_json::to_writer(&mut f, value).map_err(|e| e.to_string())?;
        f.write_all(b"\n").map_err(|e| e.to_string())?;
        f.sync_all().map_err(|e| e.to_string())?;
        std::fs::rename(&temp, path).map_err(|e| e.to_string())?;
        std::fs::File::open(dir)
            .and_then(|f| f.sync_all())
            .map_err(|e| e.to_string())
    })();
    if result.is_err() {
        drop(std::fs::remove_file(temp));
    }
    result
}
fn read(path: &Path) -> Result<Input, String> {
    serde_json::from_slice(&std::fs::read(path).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())
}
/// Called under the question store lock. An uncertain retry keeps the same input.
pub fn enqueue(root: &Path, delivery: &Delivery) -> Result<bool, String> {
    let path = path(root, &delivery.id);
    if path.exists() {
        let held = read(&path)?;
        if held.delivery.text != delivery.text {
            return Err("Question input identity changed".into());
        }
        return Ok(!held.handed);
    }
    write(
        &path,
        &Input {
            delivery: delivery.clone(),
            handed: false,
        },
    )?;
    Ok(true)
}
pub fn pending(root: &Path) -> Result<Vec<Delivery>, String> {
    let mut values = Vec::new();
    let files = match std::fs::read_dir(directory(root)) {
        Ok(v) => v,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(values),
        Err(e) => return Err(e.to_string()),
    };
    for file in files {
        let path = file.map_err(|e| e.to_string())?.path();
        if path.extension().is_some_and(|s| s == "json") {
            let input = read(&path)?;
            if !input.handed {
                values.push(input.delivery);
            }
        }
    }
    values.sort_by(|a, b| a.id.cmp(&b.id));
    Ok(values)
}
/// Freeze the receiving turn's input before invoking a lease. A started turn follows
/// the existing work recovery policy; it is never silently invoked a second time.
pub fn take(root: &Path, entity: &str, thread: &str, asker: &str) -> Result<Vec<Delivery>, String> {
    let values: Vec<_> = pending(root)?
        .into_iter()
        .filter(|d| d.entity_id == entity && d.thread_id == thread && d.asker == asker)
        .collect();
    for delivery in &values {
        write(
            &path(root, &delivery.id),
            &Input {
                delivery: delivery.clone(),
                handed: true,
            },
        )?;
    }
    Ok(values)
}

/// The complete MCP result is the receiving input for a words answer. Keep it
/// durably bound to that turn before marking the set handed off. Repeating the
/// MCP call returns the same payload instead of starting another conversation turn.
pub fn tool_result(root: &Path, turn: &str, delivery: &Delivery) -> Result<String, String> {
    let receipt = format!("tool-result:{turn}:{}", delivery.id);
    let path = root
        .join("questions/tool-results")
        .join(format!("{:x}.json", Sha256::digest(receipt.as_bytes())));
    if path.exists() {
        let held = read(&path)?;
        if held.delivery.text != delivery.text {
            return Err("Question result identity changed".into());
        }
    } else {
        write(
            &path,
            &Input {
                delivery: delivery.clone(),
                handed: true,
            },
        )?;
    }
    Ok(receipt)
}
pub fn read_tool_result(root: &Path, turn: &str, set: &str) -> Result<Option<String>, String> {
    let receipt = format!("tool-result:{turn}:question-set:{set}");
    let path = root
        .join("questions/tool-results")
        .join(format!("{:x}.json", Sha256::digest(receipt.as_bytes())));
    if !path.exists() {
        return Ok(None);
    }
    Ok(Some(read(&path)?.delivery.text))
}

/// Record the receiving host's acknowledgement for exactly this logical input.
pub fn acknowledge(root: &Path, id: &str) -> Result<(), String> {
    let path = path(root, id);
    let mut input = read(&path)?;
    if !input.handed { input.handed = true; write(&path, &input)?; }
    Ok(())
}
