//! The app-owned MCP endpoint for onboarding. The model supplies answers, never a root or
//! company identity. Each call reads the current scope written by its own chat lease.
//! JSON-RPC/MCP stdio framing follows https://modelcontextprotocol.io/specification/2025-11-25/schema.

use crate::company::{self, InterviewProgress};
use crate::entity::EntityId;
use crate::onboarding::OnboardingRecord;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};

pub const SERVER_NAME: &str = "richos_onboarding";
pub const SAVE_TOOL_NAME: &str = "save_company_notes";
pub const DECLINE_TOOL_NAME: &str = "decline_onboarding";
pub const QUALIFIED_SAVE_TOOL: &str = "mcp__richos_onboarding__save_company_notes";
pub const QUALIFIED_DECLINE_TOOL: &str = "mcp__richos_onboarding__decline_onboarding";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OnboardingToolsVerdict {
    NotYetReported,
    Loaded,
    Rejected,
}

/// Configuration acceptance is not proof that the subprocess connected. Both exact tool
/// names must appear in the native child's actual first system/init inventory.
pub fn verdict_from_init(init: &Value) -> OnboardingToolsVerdict {
    let Some(tools) = init.get("tools").and_then(Value::as_array) else {
        return OnboardingToolsVerdict::Rejected;
    };
    if [QUALIFIED_SAVE_TOOL, QUALIFIED_DECLINE_TOOL]
        .iter()
        .all(|name| tools.iter().any(|tool| tool.as_str() == Some(name)))
    {
        OnboardingToolsVerdict::Loaded
    } else {
        OnboardingToolsVerdict::Rejected
    }
}

const MAX_FRAME_BYTES: usize = 128 * 1024;
const MAX_SCOPE_BYTES: u64 = 16 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OnboardingToolScope {
    pub version: u32,
    pub entity_id: String,
    pub central_root: PathBuf,
    pub record_path: PathBuf,
}

impl OnboardingToolScope {
    pub fn new(entity: &EntityId, central_root: &Path, record_path: &Path) -> Self {
        Self {
            version: 1,
            entity_id: entity.to_string(),
            central_root: central_root.into(),
            record_path: record_path.into(),
        }
    }

    fn validate(&self) -> Result<EntityId, String> {
        if self.version != 1 || !self.central_root.is_absolute() || !self.record_path.is_absolute()
        {
            return Err(
                "The app has not supplied a valid company scope. Nothing was changed.".into(),
            );
        }
        EntityId::parse(&self.entity_id).map_err(|_| {
            "The app supplied an invalid company identity. Nothing was changed.".into()
        })
    }
}

pub fn write_scope(path: &Path, scope: &OnboardingToolScope) -> Result<(), String> {
    scope.validate()?;
    let text = serde_json::to_string(scope).map_err(|e| e.to_string())?;
    crate::doctrine::write_verified(path, &text).map_err(|e| e.to_string())
}

fn read_scope(path: &Path) -> Result<(OnboardingToolScope, EntityId), String> {
    use std::io::Read;
    let file = std::fs::File::open(path)
        .map_err(|_| "Choose a company before saving interview answers.".to_string())?;
    let mut text = String::new();
    file.take(MAX_SCOPE_BYTES + 1)
        .read_to_string(&mut text)
        .map_err(|_| "The company scope could not be read.".to_string())?;
    if text.len() as u64 > MAX_SCOPE_BYTES {
        return Err("The company scope is too large.".into());
    }
    let scope: OnboardingToolScope =
        serde_json::from_str(&text).map_err(|_| "The company scope is invalid.".to_string())?;
    let entity = scope.validate()?;
    Ok((scope, entity))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SaveArguments {
    notes: String,
    progress: InterviewProgress,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DeclineArguments {}

pub fn tools() -> Value {
    json!({"tools":[
        {"name":SAVE_TOOL_NAME,
         "description":"Save the CEO-approved company interview notes for the company selected by RichOS. Use for partial checkpoints as well as completion. Success confirms atomic persistence and readback. If rejected, explain that the notes were not saved and correct the issue. Never substitute a shell or file write.",
         "inputSchema":{"type":"object","properties":{
             "notes":{"type":"string","minLength":1,"maxLength":8192,"description":"The entire current notes, including prior answers. Keep within 8192 UTF-8 bytes including the app's progress header; aim below 8000 bytes."},
             "progress":{"type":"string","enum":["partial","complete"],"description":"partial while any interview stages have not been discussed; complete when each was answered or explicitly deferred."}
         },"required":["notes","progress"],"additionalProperties":false},
         "annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":true,"openWorldHint":false}},
        {"name":DECLINE_TOOL_NAME,
         "description":"Record an explicit Not now answer to the company interview or resume offer. Only call when the CEO declines that specific offer in the current conversation. Never infer an interview decline from unrelated chat. Existing notes are preserved and other companies are unaffected.",
         "inputSchema":{"type":"object","properties":{},"additionalProperties":false},
         "annotations":{"readOnlyHint":false,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}}
    ]})
}

/// Application validation is shared by the protocol adapter and tests. Tool arguments cannot
/// redirect persistence, including by sneaking a path or entity beside otherwise valid notes.
pub fn call(scope_path: &Path, name: &str, arguments: Value) -> Result<Value, String> {
    // Validate arguments before touching the scope or disk.
    match name {
        SAVE_TOOL_NAME => {
            let args: SaveArguments = serde_json::from_value(arguments).map_err(|_| {
                "Use only notes and progress (partial or complete). Nothing was saved.".to_string()
            })?;
            let (scope, entity) = read_scope(scope_path)?;
            let bytes = company::save_company_notes(
                &scope.central_root,
                &entity,
                &args.notes,
                args.progress,
            )
            .map_err(|e| e.to_string())?;
            // A successful answer supersedes a prior Not now. Preserve the saved notes if
            // this independent status update fails, and report that distinction truthfully.
            let resumed =
                OnboardingRecord::clear_declination_for_entity(&scope.record_path, &entity).is_ok();
            Ok(
                json!({"status":"saved","entityId":entity.to_string(),"progress":args.progress,"bytes":bytes,"verified":true,
                "declinationCleared":resumed,"warning":if resumed { None } else { Some("Your notes were saved, but the interview reminder could not be updated. Retry the save to restore it.") }}),
            )
        }
        DECLINE_TOOL_NAME => {
            let _: DeclineArguments = serde_json::from_value(arguments).map_err(|_| {
                "Declining the interview takes no arguments. Nothing was changed.".to_string()
            })?;
            let (scope, entity) = read_scope(scope_path)?;
            // Preserve the first explicit timestamp on retries.
            let record = OnboardingRecord::load(&scope.record_path).for_entity(&entity);
            if !record.is_declined() {
                OnboardingRecord::record_declination_for_entity(
                    &scope.record_path,
                    &entity,
                    crate::util::now_millis(),
                )
                .map_err(|_| {
                    "I couldn't save your Not now answer. Please try again.".to_string()
                })?;
            }
            Ok(json!({"status":"declined","entityId":entity.to_string(),"notesPreserved":true}))
        }
        _ => Err("Unknown onboarding tool. Nothing was changed.".into()),
    }
}

fn error(id: Value, code: i64, message: &str) -> Value {
    json!({"jsonrpc":"2.0","id":id,"error":{"code":code,"message":message}})
}

fn response(scope: &Path, request: Value, initialized: &mut bool) -> Option<Value> {
    let id = request.get("id").cloned();
    let method = request.get("method").and_then(Value::as_str);
    if request.get("jsonrpc").and_then(Value::as_str) != Some("2.0") || method.is_none() {
        return Some(error(
            id.unwrap_or(Value::Null),
            -32600,
            "Invalid JSON-RPC request",
        ));
    }
    // MCP notifications never receive a response or execute a tool.
    let id = id?;
    if !id.is_string() && !id.is_number() {
        return Some(error(Value::Null, -32600, "Invalid request id"));
    }
    let result = match method.unwrap() {
        "initialize" => {
            *initialized = true;
            let requested = request
                .pointer("/params/protocolVersion")
                .and_then(Value::as_str)
                .unwrap_or("");
            let protocol = match requested {
                "2024-11-05" | "2025-03-26" | "2025-06-18" | "2025-11-25" => requested,
                _ => "2025-11-25",
            };
            json!({"protocolVersion":protocol,"capabilities":{"tools":{}},"serverInfo":{"name":SERVER_NAME,"version":"1.0.0"}})
        }
        "ping" => json!({}),
        _ if !*initialized => {
            return Some(error(
                id,
                -32002,
                "Initialize before calling onboarding tools",
            ))
        }
        "tools/list" => tools(),
        "tools/call" => {
            let Some(name) = request.pointer("/params/name").and_then(Value::as_str) else {
                return Some(error(id, -32602, "A tool name is required"));
            };
            let args = request
                .pointer("/params/arguments")
                .cloned()
                .unwrap_or_else(|| json!({}));
            match call(scope, name, args) {
                Ok(value) => {
                    json!({"content":[{"type":"text","text":value.to_string()}],"isError":false})
                }
                Err(why) => json!({"content":[{"type":"text","text":why}],"isError":true}),
            }
        }
        _ => return Some(error(id, -32601, "Method not found")),
    };
    Some(json!({"jsonrpc":"2.0","id":id,"result":result}))
}

/// Read newline-delimited JSON-RPC with bounded allocation. Oversized messages are drained
/// through their newline, rejected and cannot be interpreted as a following command.
pub fn serve(
    scope_path: &Path,
    mut reader: impl BufRead,
    mut writer: impl Write,
) -> io::Result<()> {
    let mut initialized = false;
    loop {
        let mut frame = Vec::new();
        let mut oversized = false;
        loop {
            let buf = reader.fill_buf()?;
            if buf.is_empty() {
                break;
            }
            let n = buf
                .iter()
                .position(|b| *b == b'\n')
                .map(|i| i + 1)
                .unwrap_or(buf.len());
            let ends = buf[n - 1] == b'\n';
            if frame.len() + n <= MAX_FRAME_BYTES && !oversized {
                frame.extend_from_slice(&buf[..n]);
            } else {
                oversized = true;
            }
            reader.consume(n);
            if ends {
                break;
            }
        }
        if frame.is_empty() && !oversized {
            break;
        }
        let reply = if oversized {
            Some(error(Value::Null, -32600, "Message too large"))
        } else {
            match serde_json::from_slice::<Value>(&frame) {
                Ok(value) => response(scope_path, value, &mut initialized),
                Err(_) => Some(error(Value::Null, -32700, "Invalid JSON")),
            }
        };
        if let Some(reply) = reply {
            serde_json::to_writer(&mut writer, &reply)?;
            writer.write_all(b"\n")?;
            writer.flush()?;
        }
    }
    Ok(())
}

/// Entry point used before the desktop shell initializes. Stdout is exclusively MCP frames.
pub fn run_stdio(scope_path: &Path) -> io::Result<()> {
    serve(scope_path, io::stdin().lock(), io::stdout().lock())
}
