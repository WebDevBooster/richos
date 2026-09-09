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

/// Configuration acceptance is not proof that the subprocess connected. All exact app tool
/// names must appear in the native child's actual first system/init inventory.
pub fn verdict_from_init(init: &Value) -> OnboardingToolsVerdict {
    let Some(tools) = init.get("tools").and_then(Value::as_array) else {
        return OnboardingToolsVerdict::Rejected;
    };
    if [
        QUALIFIED_SAVE_TOOL,
        QUALIFIED_DECLINE_TOOL,
        crate::work_disposition::QUALIFIED_TOOL_NAME,
    ]
    .iter()
    .all(|name| tools.iter().any(|tool| tool.as_str() == Some(name)))
    {
        OnboardingToolsVerdict::Loaded
    } else {
        OnboardingToolsVerdict::Rejected
    }
}

/// A host-observed terminal result of an exact onboarding tool in this same visible turn.
/// This is evidence for the registrar's narrow inline-action disposition, never a blanket
/// exemption for unrelated work in the same CEO message. Uses retained summary fields, so
/// raw payload eviction cannot turn a completed interview operation into a new assignment.
pub fn handled_in_turn(records: Vec<crate::machinery::MachineryRecord>, turn_id: &str) -> bool {
    use crate::machinery::{MachineryKind, ToolStatus};
    let records: Vec<_> = records
        .iter()
        .filter(|r| {
            !r.internal
                && r.turn_id.as_deref() == Some(turn_id)
                && r.kind == MachineryKind::ToolCall
        })
        .collect();
    let known: std::collections::HashSet<_> = records
        .iter()
        .filter_map(|r| {
            let name = r
                .payload
                .as_ref()
                .and_then(|p| p.get("name"))
                .and_then(Value::as_str)
                .or_else(|| {
                    if r.status == Some(ToolStatus::Pending) {
                        Some(r.title.as_str())
                    } else {
                        None
                    }
                });
            if ![Some(QUALIFIED_SAVE_TOOL), Some(QUALIFIED_DECLINE_TOOL)].contains(&name) {
                return None;
            }
            Some((r.session_id.as_str(), r.tool_call_id.as_deref()?))
        })
        .collect();
    records.iter().any(|r| {
        r.status
            .as_ref()
            .map(ToolStatus::is_terminal)
            .unwrap_or(false)
            && r.tool_call_id
                .as_deref()
                .map(|id| known.contains(&(r.session_id.as_str(), id)))
                .unwrap_or(false)
    })
}

const MAX_FRAME_BYTES: usize = 128 * 1024;
const MAX_SCOPE_BYTES: u64 = 16 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OnboardingToolScope {
    pub version: u32,
    pub entity_id: String,
    pub central_root: Option<PathBuf>,
    pub record_path: Option<PathBuf>,
    /// App-issued grant for one visible conversation turn. Missing is denied.
    #[serde(default)]
    pub actions_allowed: bool,
    /// Only the host's current visible source turn may publish an intake disposition.
    #[serde(default)]
    pub work_disposition: Option<crate::work_disposition::WorkDispositionScope>,
}

impl OnboardingToolScope {
    pub fn new(entity: &EntityId, central_root: &Path, record_path: &Path) -> Self {
        Self {
            version: 1,
            entity_id: entity.to_string(),
            central_root: Some(central_root.into()),
            record_path: Some(record_path.into()),
            actions_allowed: false,
            work_disposition: None,
        }
    }

    fn validate(&self) -> Result<EntityId, String> {
        if self.version != 1 || self.central_root.is_some() != self.record_path.is_some()
            || self.central_root.as_ref().is_some_and(|p| !p.is_absolute())
            || self.record_path.as_ref().is_some_and(|p| !p.is_absolute())
        {
            return Err(
                "The app has not supplied a valid company scope. Nothing was changed.".into(),
            );
        }
        if let Some(scope) = &self.work_disposition {
            scope.validate()?;
            if scope.entity != self.entity_id {
                return Err("Work disposition belongs to a different company.".into());
            }
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

/// The native adapter grants only around visible delivery, then revokes on every result.
/// Hidden context injection never grants, even if the vendor bypasses permission callbacks.
pub fn set_actions_allowed(path: &Path, allowed: bool) -> Result<(), String> {
    let (mut scope, _) = read_scope(path)?;
    scope.actions_allowed = allowed;
    write_scope(path, &scope)
}

/// Change only the host's turn binding. Interview destinations and grants are preserved.
pub fn set_work_disposition_scope(
    path: &Path,
    work: Option<crate::work_disposition::WorkDispositionScope>,
) -> Result<(), String> {
    let mut scope = if path.exists() {
        read_scope(path)?.0
    } else if let Some(binding) = &work {
        binding.validate()?;
        OnboardingToolScope { version: 1, entity_id: binding.entity.clone(), central_root: None,
            record_path: None, actions_allowed: false, work_disposition: None }
    } else {
        return Ok(());
    };
    scope.work_disposition = work;
    write_scope(path, &scope)
}

fn require_action_grant(scope: &OnboardingToolScope) -> Result<(), String> {
    if scope.actions_allowed {
        Ok(())
    } else {
        Err("Company notes and interview preferences cannot change during internal context preparation. Wait for the CEO's visible conversation turn. Nothing was changed.".into())
    }
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
         "annotations":{"readOnlyHint":false,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}},
        {"name":crate::work_disposition::TOOL_NAME,
         "description":"Record the current CEO turn's work disposition for RichOS. Use work for an authorized new outcome, amend for changed scope, answer_decision for an actual answer, cancel for explicit cancellation or discussion when no work is requested. The host supplies the original source and identity. Success confirms durable intake only, never execution, completion or new tool permission. Do not put off accepted work or mistake an interruption for cancellation.",
         "inputSchema":crate::work_disposition::schema(),
         "annotations":{"readOnlyHint":false,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}}
    ]})
}

/// Application validation is shared by the protocol adapter and tests. Tool arguments cannot
/// redirect persistence, including by sneaking a path or entity beside otherwise valid notes.
pub fn call(scope_path: &Path, name: &str, arguments: Value) -> Result<Value, String> {
    // Validate arguments before touching the scope or disk.
    match name {
        crate::work_disposition::TOOL_NAME => {
            let args: crate::work_disposition::Disposition = serde_json::from_value(arguments)
                .map_err(|_| "Use only kind, optional target and a short reason. No disposition was recorded.".to_string())?;
            args.validate()?;
            let (scope, _) = read_scope(scope_path)?;
            require_action_grant(&scope)?;
            let work = scope.work_disposition.as_ref()
                .ok_or("The host has not bound this call to a current CEO source turn. No disposition was recorded.")?;
            let receipt = crate::work_disposition::record(work, args)?;
            Ok(
                json!({"status":"recorded","kind":receipt.disposition.kind,"executionStarted":false}),
            )
        }
        SAVE_TOOL_NAME => {
            let args: SaveArguments = serde_json::from_value(arguments).map_err(|_| {
                "Use only notes and progress (partial or complete). Nothing was saved.".to_string()
            })?;
            let (scope, entity) = read_scope(scope_path)?;
            require_action_grant(&scope)?;
            let central_root = scope.central_root.as_deref().ok_or("Choose a company notes destination before saving interview answers.")?;
            let record_path = scope.record_path.as_deref().ok_or("Choose a company before changing interview preferences.")?;
            let bytes = company::save_company_notes(
                central_root,
                &entity,
                &args.notes,
                args.progress,
            )
            .map_err(|e| e.to_string())?;
            // A successful answer supersedes a prior Not now. Preserve the saved notes if
            // this independent status update fails, and report that distinction truthfully.
            let resumed =
                OnboardingRecord::clear_declination_for_entity(record_path, &entity).is_ok();
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
            require_action_grant(&scope)?;
            let record_path = scope.record_path.as_deref().ok_or("Choose a company before changing interview preferences.")?;
            // Preserve the first explicit timestamp on retries.
            let record = OnboardingRecord::load(record_path).for_entity(&entity);
            if !record.is_declined() {
                OnboardingRecord::record_declination_for_entity(
                    record_path,
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

#[cfg(test)]
mod work_disposition_tests {
    use super::*;
    use crate::work_disposition::{self, WorkDispositionScope};

    #[test]
    fn work_receipt_requires_visible_grant_and_host_binding_and_preserves_interview_scope() {
        let root =
            std::env::temp_dir().join(format!("richos-disposition-tool-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let path = root.join("scope.json");
        let initial = OnboardingToolScope::new(
            &EntityId::parse("example").unwrap(),
            &root.join("central"),
            &root.join("record.json"),
        );
        write_scope(&path, &initial).unwrap();
        let args = json!({"kind":"work","reason":"Repair the requested defect."});
        assert!(call(&path, work_disposition::TOOL_NAME, args.clone()).is_err());
        let binding = WorkDispositionScope {
            source_turn: "turn-1".into(),
            thread: "thread-1".into(),
            entity: "example".into(),
            workspace: root.clone(),
            nonce: "nonce-1".into(),
            receipt_path: root.join("receipt.json"),
        };
        set_work_disposition_scope(&path, Some(binding.clone())).unwrap();
        assert!(call(&path, work_disposition::TOOL_NAME, args.clone()).is_err());
        assert!(!binding.receipt_path.exists());
        set_actions_allowed(&path, true).unwrap();
        assert_eq!(
            call(&path, work_disposition::TOOL_NAME, args.clone()).unwrap()["status"],
            "recorded"
        );
        assert!(work_disposition::read_bound_receipt(&binding)
            .unwrap()
            .is_some());
        set_actions_allowed(&path, false).unwrap();
        assert!(call(&path, work_disposition::TOOL_NAME, args.clone()).is_err());
        set_work_disposition_scope(&path, None).unwrap();
        set_actions_allowed(&path, true).unwrap();
        assert!(call(&path, work_disposition::TOOL_NAME, args).is_err());
        let (after, _) = read_scope(&path).unwrap();
        assert_eq!(after.central_root, initial.central_root);
        assert_eq!(after.record_path, initial.record_path);
        assert!(after.work_disposition.is_none());
        assert!(after.actions_allowed);
        let mut wrong = binding;
        wrong.entity = "different".into();
        assert!(set_work_disposition_scope(&path, Some(wrong)).is_err());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn disposition_without_company_notes_root_has_no_invented_interview_destination() {
        let root = std::env::temp_dir().join(format!("richos-disposition-no-root-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let path = root.join("scope.json");
        let binding = crate::work_disposition::WorkDispositionScope {
            source_turn: "turn-1".into(), thread: "thread-1".into(), entity: "example".into(),
            workspace: root.clone(), nonce: "nonce-1".into(), receipt_path: root.join("receipt.json"),
        };
        set_work_disposition_scope(&path, Some(binding.clone())).unwrap();
        let (scope, _) = read_scope(&path).unwrap();
        assert!(scope.central_root.is_none() && scope.record_path.is_none());
        assert!(!scope.actions_allowed);
        set_actions_allowed(&path, true).unwrap();
        assert_eq!(call(&path, crate::work_disposition::TOOL_NAME, json!({"kind":"work","reason":"Complete the authorized work."})).unwrap()["status"], "recorded");
        assert!(crate::work_disposition::read_bound_receipt(&binding).unwrap().is_some());
        assert!(call(&path, SAVE_TOOL_NAME, json!({"notes":"Example company notes", "progress":"complete"})).is_err());
        assert!(call(&path, DECLINE_TOOL_NAME, json!({})).is_err());
        set_actions_allowed(&path, false).unwrap();
        set_work_disposition_scope(&path, None).unwrap();
        let (dormant, _) = read_scope(&path).unwrap();
        assert!(dormant.central_root.is_none() && dormant.record_path.is_none() && dormant.work_disposition.is_none());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn legacy_scope_reads_without_disposition_but_tool_inventory_requires_the_new_tool() {
        let raw = json!({"version":1,"entity_id":"example","central_root":"/central","record_path":"/record","actions_allowed":true});
        let scope: OnboardingToolScope = serde_json::from_value(raw).unwrap();
        assert!(scope.work_disposition.is_none());
        assert_eq!(
            verdict_from_init(&json!({"tools":[QUALIFIED_SAVE_TOOL,QUALIFIED_DECLINE_TOOL]})),
            OnboardingToolsVerdict::Rejected
        );
        assert_eq!(
            verdict_from_init(
                &json!({"tools":[QUALIFIED_SAVE_TOOL,QUALIFIED_DECLINE_TOOL,work_disposition::QUALIFIED_TOOL_NAME]})
            ),
            OnboardingToolsVerdict::Loaded
        );
    }
}
