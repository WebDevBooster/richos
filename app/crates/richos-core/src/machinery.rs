//! The MACHINERY seam — every non-text ACP update, routed instead of dropped.
//!
//! Built to `docs/plans/richos-techy-mode-2026-08-26.md` (Sage, 2026-08-26), Phase 1
//! (§5), against the emission set actually measured on 2026-08-28
//! (`docs/verification/acp-emission-probe-2026-08-28.md`, five runs of
//! `claude-agent-acp` 0.70.0). Where the design's field-level assumptions and the wire
//! disagree, the wire wins and the deviation is named here.
//!
//! ## Why a second event family, and not new `StreamEvent` variants
//! `stream.rs:8-10` states the clean-output invariant as a property of the type: *"the
//! ONLY text that ever reaches a chunk event is assistant-message text … Tool calls,
//! worker chatter, hooks, and machinery have no path here at all."* Design §1.1/§1.3: if
//! machinery became a `StreamEvent`, that invariant would degrade from **structural** to
//! *"the renderer remembers to filter"*. So machinery travels on its own record, its own
//! observer trait, and its own Tauri event name — `rich://machinery` — and the default
//! UI's subscription list is the proof.
//!
//! ## ONE event name, deliberately (design §1.3)
//! `stream.rs` and `voice/event.rs` use one Tauri event per semantic event because those
//! sets are OURS and closed. The ACP update set is the VENDOR's and open. One name plus a
//! `kind` field means a new ACP kind needs no new event, no new subscription, and no
//! contract revision.
//!
//! ## What Phase 1 routes, and what it deliberately does not
//! Typed here: `tool_call`, `tool_call_update` (merged), `agent_thought_chunk`, the
//! client-directed `session/request_permission` and `fs/*` calls, and `Unknown`.
//!
//! `plan`, `usage_update` and the SessionMeta family (`available_commands_update`,
//! `current_mode_update`, `config_option_update`, `session_info_update`) are **Phase 2**
//! (§5) and get **no typed kind here**. They are NOT dropped: they fall to
//! `MachineryKind::Unknown`, which retains the vendor kind and the verbatim payload. That
//! is the honest fallback and it is chosen on purpose — §1.4 G5 forbids re-introducing a
//! silent drop, and the CEO's whole argument for landing routing before a renderer is
//! that a dropped byte is a permanent hole.
//!
//! **ONE of them is now read, and only one: `usage_update`.** [`MachineryRecord::context_usage`]
//! pulls `{used, size}` back out of the retained payload so the spine's rotation watermark
//! can be driven by the adapter's own measurement instead of a chars/4 estimate. This is
//! deliberately an ACCESSOR over `Unknown` rather than a new `MachineryKind`: typing the
//! kind is Phase 2 (Section 5) and would move this record's timeline visibility, which is
//! not this change's business. Everything else here is still retention, not interpretation.
//!
//! `user_message_chunk` is DROPPED (§1.2): it is our own prompt echoed back, and
//! `ledger.rs:386-409` already holds the CEO's words verbatim and fsync'd. A second copy
//! would create two sources of truth for the one thing that must have exactly one.
//!
//! ## Deviations from §1.3, all forced by measured wire data
//! 1. `locations` on the wire is `[{path, line?}]`, not `Vec<String>` — we extract `.path`.
//! 2. A `tool_call` OPEN event carries `rawInput: {}` and a placeholder `title`
//!    (`"Terminal"`, `"Preparing file…"`, `"Read File"`). The real title and arguments
//!    arrive on a LATER `tool_call_update`, so §1.4 G2's merge is mandatory, not an
//!    optimisation.
//! 3. The observed lifecycle is `pending → (no status field ×2–3) → completed | failed`.
//!    34 of 58 observed tool events carried NO `status`, and `in_progress` never appeared.
//!    `ToolStatus::Other` exists so an unrecognised wire status is retained rather than
//!    silently becoming `None`.
//! 4. Payload fields are `rawInput`/`rawOutput`, not `input`/`output`.

use crate::util::{new_id, now_millis};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The ONE Tauri event name for every machinery record (§1.3).
pub const EVENT_MACHINERY: &str = "rich://machinery";

/// Per-record cap on the raw `payload` (design §2.4). Measured in BYTES of the serialized
/// JSON, truncated at a char boundary — `&s[..n]` panics mid-codepoint on the first
/// non-ASCII byte, the same trap `ledger.rs:628-638` already warns about.
pub const PAYLOAD_MAX_BYTES: usize = 32 * 1024;

/// Cap on the bounded display `summary` (design §2.4): first non-empty line, 84 chars,
/// `"N lines"` fallback.
pub const SUMMARY_MAX_CHARS: usize = 84;

/// Our normalized kind. Deliberately NOT one-to-one with the vendor's `sessionUpdate` —
/// see the module doc for what Phase 1 types and what falls to `Unknown`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MachineryKind {
    ToolCall,
    Thought,
    PermissionRequested,
    ClientFsCall,
    Unknown,
}

impl MachineryKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            MachineryKind::ToolCall => "tool_call",
            MachineryKind::Thought => "thought",
            MachineryKind::PermissionRequested => "permission_requested",
            MachineryKind::ClientFsCall => "client_fs_call",
            MachineryKind::Unknown => "unknown",
        }
    }
}

/// A tool call's lifecycle status. The four the ACP schema declares, plus `Other` so an
/// unrecognised wire value is RETAINED rather than silently dropped (§1.4 G5's rule
/// applied one level down, to a field instead of a kind).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ToolStatus {
    Pending,
    InProgress,
    Completed,
    Failed,
    Other(String),
}

impl ToolStatus {
    pub fn from_wire(s: &str) -> ToolStatus {
        match s {
            "pending" => ToolStatus::Pending,
            "in_progress" => ToolStatus::InProgress,
            "completed" => ToolStatus::Completed,
            "failed" => ToolStatus::Failed,
            other => ToolStatus::Other(other.to_string()),
        }
    }
    pub fn as_str(&self) -> &str {
        match self {
            ToolStatus::Pending => "pending",
            ToolStatus::InProgress => "in_progress",
            ToolStatus::Completed => "completed",
            ToolStatus::Failed => "failed",
            ToolStatus::Other(s) => s,
        }
    }
    /// Terminal for the CEO's status dot. `Other` is deliberately NOT terminal — an
    /// unknown status is not a claim that the work finished.
    pub fn is_terminal(&self) -> bool {
        matches!(self, ToolStatus::Completed | ToolStatus::Failed)
    }
}

impl Serialize for ToolStatus {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(self.as_str())
    }
}
impl<'de> Deserialize<'de> for ToolStatus {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        Ok(ToolStatus::from_wire(&String::deserialize(d)?))
    }
}

/// The normalized machinery record (design §1.3), as written to the journal and delivered
/// on `rich://machinery`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MachineryRecord {
    /// Ours, because the vendor gives us none for thoughts (`util.rs:16`).
    pub machinery_id: String,
    pub thread_id: String,
    /// `None` for re-prime and between-turn traffic — a first-class state, not a bug (§1.5, G4).
    pub turn_id: Option<String>,
    /// Which compute lease produced it. Rotation is invisible to the CEO but must stay
    /// reconstructible (`ledger.rs:170`).
    pub session_id: String,
    /// THE ordering guarantee (§1.4 G1) — ONE counter per turn, shared with assistant text.
    pub seq: u64,
    /// Epoch millis. A LABEL, never the ordering key (`util.rs:5-8`, §1.4 G3).
    pub at: u64,
    pub kind: MachineryKind,
    /// The merge key for `tool_call` / `tool_call_update` (§1.4 G2).
    pub tool_call_id: Option<String>,
    pub status: Option<ToolStatus>,
    /// Empty string means "the wire carried no title on THIS event" — which is what makes
    /// the merge in `project()` correct rather than destructive.
    pub title: String,
    pub summary: Option<String>,
    /// File paths touched. Extracted from the wire's `[{path, line?}]` objects.
    pub locations: Vec<String>,
    /// `true` ⇒ never rendered in a thread view (§1.5): re-prime traffic, handoff
    /// summaries, crash-recovery machinery. Mirrors `ActionVisibility::Internal`
    /// (`ledger.rs:119-133`) and honours the standing order that Rich never reveals
    /// session rotation.
    pub internal: bool,
    /// The raw `update` JSON, subject to the raw window (§2.4). `None` on a record read
    /// back from the journal whose Tier-B sidecar has been evicted.
    #[serde(default)]
    pub payload: Option<Value>,
    pub truncated: bool,
}

impl MachineryRecord {
    /// Normalize ONE ACP `session/update` payload. Returns `None` for the two kinds that
    /// have no machinery record by design: `agent_message_chunk` (it is the clean-output
    /// text path) and `user_message_chunk` (dropped, §1.2).
    ///
    /// `thread_id` / `turn_id` / `internal` are stamped by the caller that knows them
    /// (the spine); the ACP client knows only the session and the seq.
    pub fn from_acp_update(update: &Value, session_id: &str, seq: u64) -> Option<MachineryRecord> {
        let wire_kind = update.get("sessionUpdate").and_then(|v| v.as_str()).unwrap_or("");
        match wire_kind {
            "agent_message_chunk" | "user_message_chunk" => return None,
            _ => {}
        }

        let (kind, title, summary) = match wire_kind {
            "tool_call" | "tool_call_update" => {
                let title = update
                    .get("title")
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string())
                    // No wire title on THIS event. Fall back to the vendor's real tool
                    // name (which lives in `_meta`, not in the coarse ACP `kind`) ONLY on
                    // the OPENING event. On an update it must stay empty — empty means
                    // "absent", and absent is what makes the merge non-destructive. The
                    // measured traffic proves why: run1 n=15 is a `tool_call_update` with
                    // no `title` but with `_meta.claudeCode.toolName: "Bash"`, arriving
                    // AFTER the real title "cat …/VERSION". Falling back there would
                    // overwrite the CEO's line with the word "Bash".
                    .or_else(|| {
                        if wire_kind == "tool_call" {
                            tool_name(update).map(|s| s.to_string())
                        } else {
                            None
                        }
                    })
                    .unwrap_or_default();
                (MachineryKind::ToolCall, title, tool_summary(update))
            }
            "agent_thought_chunk" => {
                let text = update
                    .get("content")
                    .and_then(|c| c.get("text"))
                    .and_then(|t| t.as_str())
                    .unwrap_or("");
                (MachineryKind::Thought, "thinking".to_string(), summarize(text))
            }
            // Every other vendor kind — including plan / usage_update / the SessionMeta
            // family, which are Phase 2 — is RETAINED verbatim under Unknown, with the
            // vendor kind preserved as the title so §1.4 G5's "one dim line" is truthful.
            other => (MachineryKind::Unknown, other.to_string(), None),
        };

        let (payload, truncated) = cap_payload(update);
        Some(MachineryRecord {
            machinery_id: new_id("mach"),
            thread_id: String::new(),
            turn_id: None,
            session_id: session_id.to_string(),
            seq,
            at: now_millis(),
            kind,
            tool_call_id: update.get("toolCallId").and_then(|v| v.as_str()).map(|s| s.to_string()),
            status: update.get("status").and_then(|v| v.as_str()).map(ToolStatus::from_wire),
            title,
            summary,
            locations: extract_locations(update),
            internal: false,
            payload,
            truncated,
        })
    }

    /// The `{used, size}` pair off a `usage_update`, or `None` for every other record.
    ///
    /// **Read this from the STREAM, never from the journal.** `usage_update` lands in the
    /// evictable Tier B (`journal.rs`), so a record read back after eviction has
    /// `payload: None` and this returns `None` - correctly, because at that point the
    /// measurement genuinely is gone. The spine consumes it in `deliver`'s drain closure,
    /// as the record goes past.
    ///
    /// Returns `None` on a `truncated` record too: a truncated payload is a JSON *string*,
    /// not an object, and half a number is not a measurement. In practice this never
    /// fires - the measured `usage_update` payloads are ~120 bytes against a 32 KB cap -
    /// but the check is here so the type can never be built out of a fragment.
    pub fn context_usage(&self) -> Option<ContextUsage> {
        if self.truncated {
            return None;
        }
        let p = self.payload.as_ref()?;
        if p.get("sessionUpdate").and_then(|v| v.as_str()) != Some("usage_update") {
            return None;
        }
        // BOTH fields required. A `usage_update` carrying only `used` says nothing about
        // the denominator, and guessing a denominator is the exact failure this replaces.
        Some(ContextUsage { used: p.get("used")?.as_u64()?, size: p.get("size")?.as_u64()? })
    }

    /// Normalize a client-directed `session/request_permission` (§1.2). Recording the
    /// auto-approval is a FACT, not a policy: `acp.rs` still auto-approves exactly as it
    /// did, and this design says nothing else about gap #1.
    ///
    /// Measured shape (probe §5.6): `params = { sessionId, toolCall, options }`, where
    /// `toolCall` embeds the `toolCallId` and the resolved title — so the record links
    /// back to the tool call it is about.
    pub fn from_permission_request(
        params: &Value,
        chosen_option_id: &str,
        session_id: &str,
        seq: u64,
    ) -> MachineryRecord {
        let tool_call = params.get("toolCall");
        let title = tool_call
            .and_then(|t| t.get("title"))
            .and_then(|v| v.as_str())
            .unwrap_or("permission request")
            .to_string();
        let options: Vec<String> = params
            .get("options")
            .and_then(|v| v.as_array())
            .map(|a| {
                a.iter()
                    .filter_map(|o| o.get("optionId").and_then(|v| v.as_str()).map(|s| s.to_string()))
                    .collect()
            })
            .unwrap_or_default();
        let detail = serde_json::json!({
            "params": params,
            "chosen": chosen_option_id,
            "options": options,
            // Stated as an observation, exactly as §1.2 requires: this is what the client
            // DID, not a policy this design introduces.
            "auto": true,
        });
        let (payload, truncated) = cap_payload(&detail);
        MachineryRecord {
            machinery_id: new_id("mach"),
            thread_id: String::new(),
            turn_id: None,
            session_id: session_id.to_string(),
            seq,
            at: now_millis(),
            kind: MachineryKind::PermissionRequested,
            tool_call_id: tool_call
                .and_then(|t| t.get("toolCallId"))
                .and_then(|v| v.as_str())
                .map(|s| s.to_string()),
            status: None,
            title,
            summary: Some(format!("auto-approved: {chosen_option_id}")),
            locations: Vec::new(),
            internal: false,
            payload,
            truncated,
        }
    }

    /// Normalize a client-directed `fs/read_text_file` / `fs/write_text_file` (§1.2).
    ///
    /// **Named honestly:** across five probe runs, with both capabilities declared
    /// (`acp.rs:235`) and both the Read and Write tools actually exercised,
    /// `claude-agent-acp` 0.70.0 emitted **zero** of these. The route is built because the
    /// table routes it; it has no observed traffic behind it.
    pub fn from_client_fs_call(method: &str, params: &Value, session_id: &str, seq: u64) -> MachineryRecord {
        let path = params.get("path").and_then(|v| v.as_str()).unwrap_or("");
        let (payload, truncated) = cap_payload(&serde_json::json!({ "method": method, "params": params }));
        MachineryRecord {
            machinery_id: new_id("mach"),
            thread_id: String::new(),
            turn_id: None,
            session_id: session_id.to_string(),
            seq,
            at: now_millis(),
            kind: MachineryKind::ClientFsCall,
            tool_call_id: None,
            status: None,
            title: format!("{method} {path}"),
            summary: None,
            locations: if path.is_empty() { Vec::new() } else { vec![path.to_string()] },
            internal: false,
            payload,
            truncated,
        }
    }

    /// Stamp the fields only the spine knows (§1.5's `internal` rule included).
    pub fn stamp(mut self, thread_id: &str, turn_id: Option<&str>, internal: bool) -> MachineryRecord {
        self.thread_id = thread_id.to_string();
        self.turn_id = turn_id.map(|s| s.to_string());
        self.internal = internal;
        self
    }

    /// The JSON payload delivered on `rich://machinery`, camelCase for the JS side.
    pub fn event_payload(&self) -> Value {
        serde_json::to_value(self).unwrap_or(Value::Null)
    }
}

/// A sink for machinery records. Deliberately a SEPARATE trait from `TurnObserver`
/// (`stream.rs:88`): two families means the default UI's subscription list is the proof
/// that the calm view carries no machinery (§3.3's provable-not-promised test (a)).
pub trait MachineryObserver: Send {
    /// MUST be non-blocking and infallible from the spine's view. A UI that isn't
    /// listening never stalls or fails a turn — and per §2.2, machinery is not truth.
    fn on_machinery(&self, record: &MachineryRecord);
}

// ---- normalization helpers -------------------------------------------------

/// The vendor's real tool name (`Bash`, `Write`, `Read`, `ToolSearch`), which lives in
/// `_meta.claudeCode.toolName`. The ACP `kind` field is only a coarse class
/// (`execute` / `edit` / `read` / `other`) — probe §5.5.
fn tool_name(update: &Value) -> Option<&str> {
    update.get("_meta")?.get("claudeCode")?.get("toolName")?.as_str()
}

/// Best available bounded preview of what a tool call did. Prefers the OUTPUT (which is
/// what the CEO wants to see), falls back to the display content blocks, then the input.
fn tool_summary(update: &Value) -> Option<String> {
    if let Some(out) = update.get("rawOutput") {
        if let Some(s) = out.as_str() {
            return summarize(s);
        }
        return summarize(&out.to_string());
    }
    if let Some(blocks) = update.get("content").and_then(|c| c.as_array()) {
        for b in blocks {
            if let Some(t) = b.get("content").and_then(|c| c.get("text")).and_then(|t| t.as_str()) {
                if let Some(s) = summarize(t) {
                    return Some(s);
                }
            }
        }
    }
    if let Some(cmd) = update.get("rawInput").and_then(|i| i.get("command")).and_then(|c| c.as_str()) {
        return summarize(cmd);
    }
    if let Some(p) = update.get("rawInput").and_then(|i| i.get("file_path")).and_then(|c| c.as_str()) {
        return summarize(p);
    }
    None
}

/// §2.4's summary rule, lifted as an IDEA from t3code (`session-logic.ts:1487-1518`) and
/// written from scratch in Rust — no vendored lines, so the open-source licence gate
/// (`wiki/open-source-strategy.md`) stays unencumbered (§4.2).
///
/// First non-empty line, capped at 84 chars; `"N lines"` when there is no non-empty line
/// to show. Char-boundary safe.
pub fn summarize(text: &str) -> Option<String> {
    if text.is_empty() {
        return None;
    }
    match text.lines().map(str::trim).find(|l| !l.is_empty()) {
        Some(line) => {
            if line.chars().count() <= SUMMARY_MAX_CHARS {
                Some(line.to_string())
            } else {
                let mut out: String = line.chars().take(SUMMARY_MAX_CHARS).collect();
                out.push('\u{2026}');
                Some(out)
            }
        }
        None => Some(format!("{} lines", text.lines().count())),
    }
}

/// `locations` on the wire is `[{path, line?}]` (probe §5.3), not §1.3's `Vec<String>`.
/// Plain strings are accepted too, so a future adapter that simplifies the shape does not
/// silently produce an empty list.
fn extract_locations(update: &Value) -> Vec<String> {
    let Some(arr) = update.get("locations").and_then(|v| v.as_array()) else {
        return Vec::new();
    };
    arr.iter()
        .filter_map(|l| {
            l.as_str()
                .map(|s| s.to_string())
                .or_else(|| l.get("path").and_then(|p| p.as_str()).map(|s| s.to_string()))
        })
        .collect()
}

/// The adapter's OWN statement of how much of the model's context window this session
/// has consumed - `{used, size}` off a `usage_update` `session/update`.
///
/// A MEASUREMENT, not an estimate. Measured on the wire 2026-08-28: 50 `usage_update`
/// events across five probe runs (`docs/verification/acp-emission-probe-2026-08-28/`),
/// `size` = **1_000_000** in 50 of 50, `used` ranging 30_322 -> 41_991. It was the second
/// most frequent event in the whole capture.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ContextUsage {
    /// Tokens consumed so far on this session, as the adapter counts them.
    pub used: u64,
    /// The session's context window, as the adapter reports it.
    pub size: u64,
}

impl ContextUsage {
    /// `used / size`, or 0.0 when the adapter reported a zero window (which would make the
    /// ratio meaningless - a zero denominator is refused rather than divided by).
    pub fn fraction(&self) -> f64 {
        if self.size == 0 {
            0.0
        } else {
            self.used as f64 / self.size as f64
        }
    }
}

/// Apply §2.4's 32 KB per-record payload cap. An over-cap payload is replaced by a
/// char-boundary-safe truncation of its serialized form, as a JSON string, with
/// `truncated: true` — visibly a different shape, so nothing can mistake it for the
/// complete object.
fn cap_payload(v: &Value) -> (Option<Value>, bool) {
    let s = v.to_string();
    if s.len() <= PAYLOAD_MAX_BYTES {
        return (Some(v.clone()), false);
    }
    let mut end = PAYLOAD_MAX_BYTES;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    (Some(Value::String(s[..end].to_string())), true)
}

// ---- the projection (§1.4 G2 + G6) -----------------------------------------

/// Fold an append-only journal into the rows a renderer would show.
///
/// §1.4 G6: the journal is append-only and each record immutable — a `tool_call_update`
/// APPENDS a line; the merge happens HERE, in the projection, never in the file.
///
/// §1.4 G2, and the reason it is load-bearing rather than decorative: 34 of the 58 tool
/// events measured on 2026-08-28 carried **no `status` field at all**, and the OPEN event
/// carries a placeholder title and an empty `rawInput`. So the rule is last-write-wins per
/// field **present** in the update, absent fields untouched. A whole-record overwrite
/// would blank the CEO's status dot on most events and leave him a column of "Terminal".
///
/// A `tool_call_update` for an id we never saw OPENS a record — adapters do reorder.
///
/// Identity and position come from the FIRST record for an id: `machinery_id`, `seq` and
/// `at` are where the tool call *started*, which is where §3.4 renders it in the
/// interleaved stream.
///
/// Ordering is `(turn, seq)` per §1.4 G3 — never the clock. Turns are ordered by first
/// appearance in the journal, which is append order, which is chronological.
pub fn project(records: Vec<MachineryRecord>) -> Vec<MachineryRecord> {
    let mut turn_order: Vec<Option<String>> = Vec::new();
    let mut out: Vec<MachineryRecord> = Vec::new();
    // index into `out` for each merged tool call, keyed by tool_call_id
    let mut by_tool: std::collections::HashMap<String, usize> = std::collections::HashMap::new();

    for r in records {
        if !turn_order.contains(&r.turn_id) {
            turn_order.push(r.turn_id.clone());
        }
        let mergeable = r.kind == MachineryKind::ToolCall && r.tool_call_id.is_some();
        if !mergeable {
            out.push(r);
            continue;
        }
        let key = r.tool_call_id.clone().unwrap();
        match by_tool.get(&key) {
            Some(&idx) => merge_into(&mut out[idx], r),
            None => {
                by_tool.insert(key, out.len());
                out.push(r);
            }
        }
    }

    let turn_rank = |t: &Option<String>| turn_order.iter().position(|x| x == t).unwrap_or(usize::MAX);
    out.sort_by(|a, b| turn_rank(&a.turn_id).cmp(&turn_rank(&b.turn_id)).then(a.seq.cmp(&b.seq)));
    out
}

/// Last-write-wins per field PRESENT. Absent fields are untouched (§1.4 G2).
///
/// `pub(crate)` so the LIVE upsert path (`live.rs`) merges by the SAME rule the
/// batch projection uses, incrementally, rather than re-implementing it.
pub(crate) fn merge_into(base: &mut MachineryRecord, incoming: MachineryRecord) {
    if !incoming.title.is_empty() {
        base.title = incoming.title;
    }
    if incoming.status.is_some() {
        base.status = incoming.status;
    }
    if incoming.summary.is_some() {
        base.summary = incoming.summary;
    }
    if !incoming.locations.is_empty() {
        base.locations = incoming.locations;
    }
    if incoming.payload.is_some() {
        base.payload = incoming.payload;
        base.truncated = incoming.truncated;
    }
    // machinery_id / seq / at / turn_id / thread_id / session_id / internal keep the
    // OPENING record's values — see the `project` doc.
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn open_bash() -> Value {
        // Verbatim shape from docs/verification/.../run1.raw.jsonl n=11.
        json!({"_meta":{"claudeCode":{"toolName":"Bash"}},"toolCallId":"toolu_A",
               "sessionUpdate":"tool_call","rawInput":{},"status":"pending",
               "title":"Terminal","kind":"execute","content":[]})
    }

    #[test]
    fn agent_message_chunk_and_user_message_chunk_are_not_machinery() {
        let text = json!({"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi"}});
        let echo = json!({"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"hi"}});
        assert!(MachineryRecord::from_acp_update(&text, "s", 0).is_none());
        assert!(MachineryRecord::from_acp_update(&echo, "s", 0).is_none());
    }

    #[test]
    fn phase_two_kinds_are_retained_as_unknown_not_dropped() {
        // plan / usage_update / the SessionMeta family have no typed kind in Phase 1.
        // They must still be RETAINED verbatim — a silent drop is what §1.4 G5 forbids.
        for k in ["plan", "usage_update", "available_commands_update", "session_info_update", "current_mode_update"] {
            let u = json!({"sessionUpdate": k, "used": 30477, "size": 1000000});
            let r = MachineryRecord::from_acp_update(&u, "s", 3).expect("retained");
            assert_eq!(r.kind, MachineryKind::Unknown);
            assert_eq!(r.title, k, "the vendor kind must survive as the dim line's text");
            assert_eq!(r.payload.as_ref().unwrap()["sessionUpdate"], k);
        }
    }

    #[test]
    fn a_usage_update_yields_the_measured_used_and_size_pair() {
        // The EXACT wire shape, copied from run1.raw.jsonl n=8
        // (docs/verification/acp-emission-probe-2026-08-28/run1.raw.jsonl).
        let u = json!({"sessionUpdate":"usage_update","used":30477,"size":1000000});
        let r = MachineryRecord::from_acp_update(&u, "sess", 8).unwrap();
        let usage = r.context_usage().expect("a usage_update carries a measurement");
        assert_eq!(usage.used, 30_477);
        assert_eq!(usage.size, 1_000_000);
        // 30477 / 1000000 = 0.030477 - re-derived here rather than trusted.
        assert!((usage.fraction() - 0.030_477).abs() < 1e-9, "got {}", usage.fraction());
    }

    #[test]
    fn the_rate_limit_meta_variant_still_yields_the_measurement() {
        // run1 n=30: the same event with `_meta._claude/rateLimit` attached. 2 of the 8
        // usage_updates in run1 carry it. An extra field must not cost us the numbers.
        let u = json!({"sessionUpdate":"usage_update","used":30873,"size":1000000,
                       "_meta":{"_claude/rateLimit":{"status":"allowed","resetsAt":1787958600}}});
        let r = MachineryRecord::from_acp_update(&u, "sess", 30).unwrap();
        assert_eq!(r.context_usage().map(|u| (u.used, u.size)), Some((30_873, 1_000_000)));
    }

    #[test]
    fn only_a_usage_update_is_a_measurement() {
        // Every other machinery record must return None - a tool call is not a token count,
        // and a watermark that read one would be worse than the estimate it replaced.
        for u in [
            json!({"sessionUpdate":"plan","used":99,"size":100}),
            json!({"sessionUpdate":"session_info_update","used":99,"size":100}),
            json!({"sessionUpdate":"agent_thought_chunk","content":{"text":"t"}}),
        ] {
            let r = MachineryRecord::from_acp_update(&u, "s", 0).unwrap();
            assert_eq!(r.context_usage(), None, "non-usage kind must carry no measurement: {u}");
        }
        // `plan` carrying used/size is not hypothetical caution: the wire is the vendor's
        // and open, so the KIND, not the field names, is what makes a number a measurement.
    }

    #[test]
    fn half_a_measurement_is_no_measurement() {
        for u in [
            json!({"sessionUpdate":"usage_update","used":30477}),
            json!({"sessionUpdate":"usage_update","size":1000000}),
            json!({"sessionUpdate":"usage_update"}),
            json!({"sessionUpdate":"usage_update","used":"30477","size":"1000000"}),
        ] {
            let r = MachineryRecord::from_acp_update(&u, "s", 0).unwrap();
            assert_eq!(r.context_usage(), None, "must refuse a partial/untyped pair: {u}");
        }
    }

    #[test]
    fn a_zero_window_is_refused_rather_than_divided_by() {
        let u = json!({"sessionUpdate":"usage_update","used":500,"size":0});
        let r = MachineryRecord::from_acp_update(&u, "s", 0).unwrap();
        let usage = r.context_usage().unwrap();
        assert_eq!(usage.fraction(), 0.0, "a zero denominator must not become inf/NaN");
    }

    #[test]
    fn an_evicted_payload_reports_no_measurement_rather_than_a_stale_one() {
        // Tier B is evictable (journal.rs). A record read back after eviction has
        // payload: None, and the honest answer there is "gone", not a remembered number.
        let u = json!({"sessionUpdate":"usage_update","used":30477,"size":1000000});
        let mut r = MachineryRecord::from_acp_update(&u, "s", 0).unwrap();
        r.payload = None;
        assert_eq!(r.context_usage(), None);
    }

    #[test]
    fn a_truncated_payload_reports_no_measurement() {
        let u = json!({"sessionUpdate":"usage_update","used":30477,"size":1000000});
        let mut r = MachineryRecord::from_acp_update(&u, "s", 0).unwrap();
        r.truncated = true;
        assert_eq!(r.context_usage(), None, "half a number is not a measurement");
    }

    #[test]
    fn an_open_tool_call_carries_a_placeholder_title_and_no_arguments() {
        // The measured reality that makes the merge mandatory (probe §5.1).
        let r = MachineryRecord::from_acp_update(&open_bash(), "sess", 7).unwrap();
        assert_eq!(r.kind, MachineryKind::ToolCall);
        assert_eq!(r.title, "Terminal");
        assert_eq!(r.tool_call_id.as_deref(), Some("toolu_A"));
        assert_eq!(r.status, Some(ToolStatus::Pending));
        assert_eq!(r.seq, 7);
        assert_eq!(r.session_id, "sess");
    }

    #[test]
    fn merge_keeps_the_real_title_and_never_blanks_a_status() {
        // The exact sequence measured for toolu_01SRK… in run1: pending, then two
        // status-less updates, then completed.
        let seq = vec![
            open_bash(),
            json!({"toolCallId":"toolu_A","sessionUpdate":"tool_call_update",
                   "rawInput":{"command":"cat VERSION"},"title":"cat VERSION","kind":"execute"}),
            json!({"toolCallId":"toolu_A","sessionUpdate":"tool_call_update",
                   "_meta":{"claudeCode":{"toolResponse":{"stdout":"1.0.0"},"toolName":"Bash"}}}),
            json!({"toolCallId":"toolu_A","sessionUpdate":"tool_call_update",
                   "status":"completed","rawOutput":"1.0.0"}),
        ];
        let recs: Vec<_> = seq
            .iter()
            .enumerate()
            .map(|(i, u)| MachineryRecord::from_acp_update(u, "s", i as u64).unwrap().stamp("thr", Some("t1"), false))
            .collect();
        let opening_id = recs[0].machinery_id.clone();
        let rows = project(recs);
        assert_eq!(rows.len(), 1, "four wire events, ONE row — never a second row (G2)");
        let row = &rows[0];
        assert_eq!(row.title, "cat VERSION", "the real title from a later update wins");
        assert_eq!(row.status, Some(ToolStatus::Completed));
        assert_eq!(row.summary.as_deref(), Some("1.0.0"));
        assert_eq!(row.seq, 0, "position is where the call STARTED");
        assert_eq!(row.machinery_id, opening_id, "identity is the opening record's");
    }

    #[test]
    fn a_status_less_update_does_not_erase_a_status_already_seen() {
        // The failure a naive whole-record overwrite would produce, pinned as a test.
        let recs: Vec<_> = [
            json!({"toolCallId":"t","sessionUpdate":"tool_call","status":"pending","title":"Terminal"}),
            json!({"toolCallId":"t","sessionUpdate":"tool_call_update","title":"ls -la"}),
        ]
        .iter()
        .enumerate()
        .map(|(i, u)| MachineryRecord::from_acp_update(u, "s", i as u64).unwrap())
        .collect();
        let rows = project(recs);
        assert_eq!(rows[0].status, Some(ToolStatus::Pending));
        assert_eq!(rows[0].title, "ls -la");
    }

    #[test]
    fn a_tool_call_update_for_an_unseen_id_opens_a_record() {
        // "adapters do reorder" (§1.4 G2).
        let u = json!({"toolCallId":"orphan","sessionUpdate":"tool_call_update","status":"completed","title":"x"});
        let rows = project(vec![MachineryRecord::from_acp_update(&u, "s", 0).unwrap()]);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].status, Some(ToolStatus::Completed));
    }

    #[test]
    fn failed_is_carried_through_and_is_terminal() {
        // Measured in run5: cat of a missing file.
        let u = json!({"toolCallId":"t","sessionUpdate":"tool_call_update","status":"failed",
                       "rawOutput":"Exit code 1\ncat: /Users/alex/nope: No such file or directory"});
        let r = MachineryRecord::from_acp_update(&u, "s", 0).unwrap();
        assert_eq!(r.status, Some(ToolStatus::Failed));
        assert!(r.status.as_ref().unwrap().is_terminal());
        assert_eq!(r.summary.as_deref(), Some("Exit code 1"));
    }

    #[test]
    fn an_unrecognised_wire_status_is_retained_not_dropped() {
        let u = json!({"toolCallId":"t","sessionUpdate":"tool_call_update","status":"quiesced"});
        let r = MachineryRecord::from_acp_update(&u, "s", 0).unwrap();
        assert_eq!(r.status, Some(ToolStatus::Other("quiesced".into())));
        assert!(!r.status.unwrap().is_terminal(), "an unknown status is not a claim of completion");
    }

    #[test]
    fn locations_are_extracted_from_the_wires_object_shape() {
        let u = json!({"toolCallId":"t","sessionUpdate":"tool_call_update","kind":"edit",
                       "locations":[{"path":"/tmp/a.txt"},{"path":"/tmp/b.rs","line":1}]});
        let r = MachineryRecord::from_acp_update(&u, "s", 0).unwrap();
        assert_eq!(r.locations, vec!["/tmp/a.txt".to_string(), "/tmp/b.rs".to_string()]);
    }

    #[test]
    fn thought_chunks_route_to_thought() {
        // Zero of these were observed on claude-agent-acp 0.70.0 (probe §4.1) — the route
        // exists so that the day one arrives, there is no hole.
        let u = json!({"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"Let me check the frame math.\nsecond line"}});
        let r = MachineryRecord::from_acp_update(&u, "s", 2).unwrap();
        assert_eq!(r.kind, MachineryKind::Thought);
        assert_eq!(r.title, "thinking");
        assert_eq!(r.summary.as_deref(), Some("Let me check the frame math."));
    }

    #[test]
    fn permission_requests_record_the_auto_approval_as_a_fact() {
        // Verbatim shape from run1 n=20 (probe §5.6).
        let params = json!({
            "sessionId":"sess",
            "toolCall":{"toolCallId":"toolu_Q","title":"grep -rn \"sessionUpdate\" app","kind":"execute"},
            "options":[{"kind":"reject_once","optionId":"reject"},
                       {"kind":"allow_once","optionId":"allow"},
                       {"kind":"allow_always","optionId":"allow_always"}]});
        let r = MachineryRecord::from_permission_request(&params, "allow", "sess", 4);
        assert_eq!(r.kind, MachineryKind::PermissionRequested);
        assert_eq!(r.title, "grep -rn \"sessionUpdate\" app");
        assert_eq!(r.tool_call_id.as_deref(), Some("toolu_Q"), "links back to its tool call");
        assert_eq!(r.payload.as_ref().unwrap()["auto"], json!(true));
        assert_eq!(r.payload.as_ref().unwrap()["chosen"], json!("allow"));
    }

    #[test]
    fn client_fs_calls_route_with_their_path() {
        let r = MachineryRecord::from_client_fs_call("fs/read_text_file", &json!({"path":"/tmp/x"}), "s", 1);
        assert_eq!(r.kind, MachineryKind::ClientFsCall);
        assert_eq!(r.locations, vec!["/tmp/x".to_string()]);
    }

    #[test]
    fn summary_takes_the_first_non_empty_line_capped_at_84_chars() {
        assert_eq!(summarize("\n\n  hello  \nworld"), Some("hello".to_string()));
        let long = "x".repeat(200);
        let s = summarize(&long).unwrap();
        assert_eq!(s.chars().count(), SUMMARY_MAX_CHARS + 1, "84 chars plus the ellipsis");
        assert!(s.ends_with('\u{2026}'));
        assert_eq!(summarize("\n\n\n"), Some("3 lines".to_string()));
        assert_eq!(summarize(""), None);
    }

    #[test]
    fn summary_truncation_is_char_boundary_safe() {
        // `&s[..84]` would panic mid-codepoint here — the trap ledger.rs:628-638 warns about.
        let s = summarize(&"é".repeat(200)).unwrap();
        assert_eq!(s.chars().count(), SUMMARY_MAX_CHARS + 1);
    }

    #[test]
    fn an_over_cap_payload_is_truncated_at_a_char_boundary_and_flagged() {
        let big = json!({"sessionUpdate":"tool_call_update","toolCallId":"t","rawOutput":"é".repeat(40_000)});
        let r = MachineryRecord::from_acp_update(&big, "s", 0).unwrap();
        assert!(r.truncated);
        let held = r.payload.unwrap();
        let s = held.as_str().expect("an over-cap payload becomes a string, visibly not the object");
        assert!(s.len() <= PAYLOAD_MAX_BYTES);
        // The record itself still renders: title, status, summary all survive the cap.
        assert!(r.summary.is_some());
    }

    #[test]
    fn a_record_round_trips_through_json_in_camel_case() {
        let r = MachineryRecord::from_acp_update(&open_bash(), "sess", 1).unwrap().stamp("thr_1", Some("turn_1"), true);
        let v = r.event_payload();
        assert_eq!(v["machineryId"], json!(r.machinery_id));
        assert_eq!(v["threadId"], json!("thr_1"));
        assert_eq!(v["turnId"], json!("turn_1"));
        assert_eq!(v["toolCallId"], json!("toolu_A"));
        assert_eq!(v["kind"], json!("tool_call"));
        assert_eq!(v["status"], json!("pending"));
        assert_eq!(v["internal"], json!(true));
        let back: MachineryRecord = serde_json::from_value(v).unwrap();
        assert_eq!(back, r);
    }

    #[test]
    fn ordering_is_by_turn_then_seq_never_by_the_clock() {
        // Same `at` on every record — millisecond timestamps collide inside a streaming
        // turn (§1.4 G3, util.rs:5-8). Only (turn, seq) may decide order.
        let mk = |turn: Option<&str>, seq: u64| {
            let mut r = MachineryRecord::from_acp_update(
                &json!({"sessionUpdate":"agent_thought_chunk","content":{"text":"t"}}),
                "s",
                seq,
            )
            .unwrap()
            .stamp("thr", turn, false);
            r.at = 1_700_000_000_000;
            r
        };
        let rows = project(vec![mk(Some("t1"), 2), mk(Some("t2"), 0), mk(Some("t1"), 0), mk(None, 9)]);
        let got: Vec<_> = rows.iter().map(|r| (r.turn_id.clone(), r.seq)).collect();
        assert_eq!(
            got,
            vec![
                (Some("t1".to_string()), 0),
                (Some("t1".to_string()), 2),
                (Some("t2".to_string()), 0),
                (None, 9),
            ]
        );
    }
}
