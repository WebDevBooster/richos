//! **THE MESSAGE ROW — the one translation between the Mac's gated bytes and the phone's shape.**
//!
//! The landed phone merges rows shaped like this (`app/phone/CONTRACT-STUB.md` §2(b)):
//!
//! ```text
//! {"id","thread_id","cursor","role":"ceo"|"rich","kind":"text"|"voice","text","created_at",
//!  "client_id","has_audio","from_microphone","state","complete"}
//! ```
//!
//! and the Mac holds a `TimelineView` and a stream of `LiveEvent`s. This file is the whole of the
//! distance between the two.
//!
//! # WHAT MAKES THIS SAFE, AND IT IS NOT CARE
//!
//! Plan §4.2 (iii): *"the phone emitter must never read raw events or the ledger directly, only
//! this stream and the same gated timeline payload the webview gets."*
//!
//! Every function here takes **already-gated JSON** and nothing else: the value of
//! `Timeline::view(ViewMode::Ceo).payload()`, or the `payload()` of a `LiveEvent` the spine's
//! `forward_live` chokepoint already allowed through. There is no `Ledger`, no `Timeline` and no
//! `Spine` in this file's imports — so it cannot reach an ungated byte, rather than choosing not
//! to.
//!
//! # And what it throws away
//!
//! Machinery. A gated CEO timeline still contains `work_duration`, `activity` and
//! `worker_activity` rows, and plan §6 is explicit: *"**Machinery on the phone.** The drill-down
//! view is optional on the desktop and absent on the phone. The small screen is the one place
//! 'clean output' is most easily broken and hardest to recover."* [`rows_from_payload`] keeps
//! `user_message` and `rich_message` and drops everything else.
//!
//! # The cursor
//!
//! **A row's cursor is its 1-based position among the kept rows of the gated projection.** That
//! is a deterministic function of the append-only ledger, so a reload computes the same numbers
//! a stream sent — which is what makes `before=<cursor>` backfill and `since=<cursor>` agree
//! with each other across a restart. Live rows continue the count from the projection's length
//! at the moment the stream opened, and every `hello` re-seeds it from the projection, so a
//! drift cannot survive one reconnection.
//!
//! **Its honest limit, stated because the phone merges on it:** the cursor is a position, not an
//! identity. `id` is the identity — the timeline item's own derived id, stable across
//! re-projection by construction (`timeline.rs`: *"Re-projecting the same durable inputs after a
//! restart produces the same id"*).

use serde_json::{json, Value};

/// The rows the phone understands, in order, cursors assigned.
pub fn rows_from_payload(payload: &Value) -> Vec<Value> {
    let empty: Vec<Value> = Vec::new();
    let items = payload.get("items").and_then(|v| v.as_array()).unwrap_or(&empty);
    let mut out: Vec<Value> = Vec::new();
    for item in items {
        if let Some(mut row) = row_from_item(item) {
            row["cursor"] = json!(out.len() as u64 + 1);
            out.push(row);
        }
    }
    out
}

/// One gated timeline item as a phone row, or `None` when it is not a message.
fn row_from_item(item: &Value) -> Option<Value> {
    let kind = item.get("kind").and_then(|v| v.as_str())?;
    let id = item.get("id").and_then(|v| v.as_str())?.to_string();
    let thread_id = item.get("threadId").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let created_at = item.get("createdAt").and_then(|v| v.as_u64()).unwrap_or(0);
    let text = item.get("text").and_then(|v| v.as_str()).unwrap_or("").to_string();
    match kind {
        "user_message" => {
            // `source` is the ledger's own word for how the input arrived. `jam` is a spoken
            // turn, which the phone shows with its microphone marker; anything else is typed.
            let spoken = item.get("source").and_then(|v| v.as_str()) == Some("jam");
            Some(json!({
                "id": id,
                "thread_id": thread_id,
                "cursor": 0,
                "role": "ceo",
                "kind": if spoken { "voice" } else { "text" },
                "text": text,
                "created_at": iso8601(created_at),
                "client_id": Value::Null,
                "has_audio": false,
                "from_microphone": spoken,
                "state": "sent",
                "complete": true,
            }))
        }
        "rich_message" => Some(json!({
            "id": id,
            "thread_id": thread_id,
            "cursor": 0,
            "role": "rich",
            "kind": "text",
            "text": text,
            "created_at": iso8601(created_at),
            "client_id": Value::Null,
            // Nothing is synthesized until he asks for it (plan §3.4 verb 4), so a projected
            // row never claims audio is waiting. Slice B is what makes this ever true.
            "has_audio": false,
            "from_microphone": false,
            "state": "complete",
            "complete": true,
        })),
        // Machinery. Plan §6: absent on the phone, by construction rather than by a renderer
        // remembering to skip it.
        _ => None,
    }
}

/// One live event as the phone's `(event name, data)`, or `None` when the phone has no use for
/// it.
///
/// `cursor` is the position the caller has assigned to this message — see the module doc.
pub fn event_from_live(name: &str, payload: &Value, cursor: u64) -> Option<(&'static str, Value)> {
    let message_id = payload.get("messageId").and_then(|v| v.as_str())?.to_string();
    let thread_id = payload.get("threadId").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let at = payload.get("at").and_then(|v| v.as_u64()).unwrap_or(0);
    match name {
        // A run of Rich's prose opens. The row goes out empty and incomplete; the deltas fill
        // it. This is what lets the phone show the reply arriving rather than appearing.
        "rich://message-started" => Some((
            "message",
            json!({
                "id": message_id,
                "thread_id": thread_id,
                "cursor": cursor,
                "role": "rich",
                "kind": "text",
                "text": "",
                "created_at": iso8601(at),
                "client_id": Value::Null,
                "has_audio": false,
                "from_microphone": false,
                "state": "streaming",
                "complete": false,
            }),
        )),
        "rich://message-delta" => Some((
            "delta",
            json!({
                "message_id": message_id,
                "cursor": cursor,
                "text": payload.get("textDelta").and_then(|v| v.as_str()).unwrap_or(""),
            }),
        )),
        // **The full text again, deliberately.** `MessageCompleted` carries the whole run read
        // back from the ledger *"so a consumer that missed every delta is still correct"* — so
        // the phone gets a complete row here, not just a state flag. A phone that came back
        // mid-reply is then right without a reload.
        "rich://message-completed" => Some((
            "message",
            json!({
                "id": message_id,
                "thread_id": thread_id,
                "cursor": cursor,
                "role": "rich",
                "kind": "text",
                "text": payload.get("text").and_then(|v| v.as_str()).unwrap_or(""),
                "created_at": iso8601(at),
                "client_id": Value::Null,
                "has_audio": false,
                "from_microphone": false,
                "state": "complete",
                "complete": true,
            }),
        )),
        // Everything else in the §13 family is either machinery or about a turn rather than a
        // message, and the phone has no row for it. Dropped here rather than sent and ignored,
        // so his cellular connection does not carry bytes nothing renders.
        _ => None,
    }
}

/// Does this live event open a new message row — that is, does it consume a cursor?
pub fn opens_a_row(name: &str) -> bool {
    name == "rich://message-started"
}

/// Milliseconds since the epoch as an ISO-8601 instant in UTC, e.g. `2026-09-18T12:34:56.789Z`.
///
/// Written out rather than adding a date crate: it is one function, the phone only ever parses
/// it with `new Date(...)`, and the algorithm is the standard civil-from-days one with its own
/// known-answer tests below.
pub fn iso8601(millis: u64) -> String {
    let secs = (millis / 1000) as i64;
    let ms = millis % 1000;
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let (hour, minute, second) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    let (year, month, day) = civil_from_days(days);
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}.{ms:03}Z")
}

/// Days since 1970-01-01 to a calendar date. Howard Hinnant's `civil_from_days`, which is the
/// reference algorithm for this and is correct for every date the Gregorian calendar has.
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32; // [1, 12]
    (if m <= 2 { y + 1 } else { y }, m, d)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A gated CEO timeline payload with both message kinds and three machinery rows, in the
    /// shape `Timeline::view(ViewMode::Ceo).payload()` actually produces (`kind` is the serde
    /// tag, snake_case; the base is flattened; fields are camelCase).
    fn payload() -> Value {
        json!({
            "entityId": "femcboost",
            "threadId": "thr_5c1e",
            "mode": "ceo",
            "betweenTurns": [],
            "items": [
                { "kind": "user_message", "id": "i1", "threadId": "thr_5c1e", "turnId": "t1",
                  "createdAt": 1_758_200_000_000u64, "text": "where are we on the proposal?",
                  "source": "text", "slot": "opening", "visibility": "ceo", "sequence": null,
                  "entityId": "femcboost", "bindingRevision": 1 },
                { "kind": "work_duration", "id": "i2", "threadId": "thr_5c1e", "turnId": "t1",
                  "createdAt": 1_758_200_000_100u64, "state": "working", "slot": "terminal",
                  "visibility": "ceo", "sequence": null, "entityId": "femcboost",
                  "bindingRevision": 1 },
                { "kind": "activity", "id": "i3", "threadId": "thr_5c1e", "turnId": "t1",
                  "createdAt": 1_758_200_000_200u64, "slot": "stream", "visibility": "ceo",
                  "sequence": 1, "entityId": "femcboost", "bindingRevision": 1 },
                { "kind": "rich_message", "id": "i4", "threadId": "thr_5c1e", "turnId": "t1",
                  "createdAt": 1_758_200_000_300u64, "text": "On it! Here is where we are.",
                  "phase": "unknown", "slot": "stream", "visibility": "ceo", "sequence": 2,
                  "entityId": "femcboost", "bindingRevision": 1 },
                { "kind": "worker_activity", "id": "i5", "threadId": "thr_5c1e", "turnId": "t1",
                  "createdAt": 1_758_200_000_400u64, "slot": "stream", "visibility": "ceo",
                  "sequence": 3, "entityId": "femcboost", "bindingRevision": 1 },
                { "kind": "user_message", "id": "i6", "threadId": "thr_5c1e", "turnId": "t2",
                  "createdAt": 1_758_200_001_000u64, "text": "and the numbers?",
                  "source": "jam", "slot": "opening", "visibility": "ceo", "sequence": null,
                  "entityId": "femcboost", "bindingRevision": 1 }
            ]
        })
    }

    #[test]
    fn only_the_conversation_reaches_the_phone_and_no_machinery_does() {
        // Plan §6, as a property of the translation rather than of a renderer. The fixture
        // carries a work-duration row, an activity row and a worker row on purpose.
        let rows = rows_from_payload(&payload());
        assert_eq!(rows.len(), 3, "machinery reached the phone: {rows:?}");
        let ids: Vec<&str> = rows.iter().map(|r| r["id"].as_str().unwrap()).collect();
        assert_eq!(ids, vec!["i1", "i4", "i6"]);
        for row in &rows {
            assert!(matches!(row["role"].as_str().unwrap(), "ceo" | "rich"));
        }
    }

    #[test]
    fn the_cursor_is_the_position_among_the_kept_rows_and_counts_from_one() {
        // Not the position among ALL items — if it were, the cursors would have gaps wherever
        // machinery had been dropped, and `before=<cursor>` would skip real messages.
        let rows = rows_from_payload(&payload());
        assert_eq!(rows[0]["cursor"], 1);
        assert_eq!(rows[1]["cursor"], 2);
        assert_eq!(rows[2]["cursor"], 3);
    }

    #[test]
    fn the_same_payload_projects_the_same_cursors_every_time() {
        // What makes `since=` and `before=` survive a restart: the projection is a pure
        // function of the ledger, so the numbers are reproducible rather than remembered.
        assert_eq!(rows_from_payload(&payload()), rows_from_payload(&payload()));
    }

    #[test]
    fn a_spoken_turn_carries_the_microphone_marker_and_a_typed_one_does_not() {
        // The 🎤 marker the bridge established (plan §4.3), as data rather than as a character
        // in the text — so the phone decides how to show it.
        let rows = rows_from_payload(&payload());
        assert_eq!(rows[0]["from_microphone"], false);
        assert_eq!(rows[0]["kind"], "text");
        assert_eq!(rows[2]["from_microphone"], true);
        assert_eq!(rows[2]["kind"], "voice");
    }

    #[test]
    fn a_row_carries_every_field_the_phone_reads_and_nothing_else() {
        // The phone merges on these names. A missing field is a row it silently renders wrong.
        let rows = rows_from_payload(&payload());
        let mut keys: Vec<&String> = rows[0].as_object().unwrap().keys().collect();
        keys.sort();
        assert_eq!(
            keys,
            vec![
                "client_id",
                "complete",
                "created_at",
                "cursor",
                "from_microphone",
                "has_audio",
                "id",
                "kind",
                "role",
                "state",
                "text",
                "thread_id",
            ]
        );
    }

    #[test]
    fn an_empty_or_malformed_payload_is_no_rows_rather_than_a_panic() {
        // A thread with nothing in it is ordinary. A payload this build cannot read is not, and
        // it still must not take the stream down.
        assert!(rows_from_payload(&json!({ "items": [] })).is_empty());
        assert!(rows_from_payload(&json!({})).is_empty());
        assert!(rows_from_payload(&Value::Null).is_empty());
        assert!(rows_from_payload(&json!({ "items": [ { "kind": "user_message" } ] })).is_empty());
    }

    // --- the live events ------------------------------------------------------------------------

    fn live(name: &str, extra: Value) -> (&'static str, Value) {
        let mut payload = json!({
            "entityId": "femcboost",
            "threadId": "thr_5c1e",
            "turnId": "t1",
            "bindingRevision": 1,
            "visibility": "ceo",
            "messageId": "msg_1",
            "at": 1_758_200_000_300u64,
        });
        for (k, v) in extra.as_object().unwrap() {
            payload[k] = v.clone();
        }
        event_from_live(name, &payload, 7).expect("the event was dropped")
    }

    #[test]
    fn a_message_opening_streaming_and_completing_becomes_the_three_things_the_phone_handles() {
        let (name, started) = live("rich://message-started", json!({ "phase": "unknown", "seq": 2 }));
        assert_eq!(name, "message");
        assert_eq!(started["complete"], false);
        assert_eq!(started["state"], "streaming");
        assert_eq!(started["text"], "");
        assert_eq!(started["cursor"], 7);
        assert_eq!(started["role"], "rich");

        let (name, delta) = live("rich://message-delta", json!({ "seq": 3, "textDelta": "On it" }));
        assert_eq!(name, "delta");
        assert_eq!(delta["message_id"], "msg_1");
        assert_eq!(delta["text"], "On it");
        assert_eq!(delta["cursor"], 7);

        // THE COMPLETION CARRIES THE WHOLE TEXT AGAIN, deliberately: a phone that came back
        // mid-reply and missed every delta is correct without a reload.
        let (name, done) =
            live("rich://message-completed", json!({ "phase": "unknown", "text": "On it! Here it is." }));
        assert_eq!(name, "message");
        assert_eq!(done["complete"], true);
        assert_eq!(done["text"], "On it! Here it is.");
    }

    #[test]
    fn the_events_the_phone_has_no_row_for_are_dropped_rather_than_sent_and_ignored() {
        // His cellular connection should not carry bytes nothing renders.
        let payload = json!({
            "threadId": "thr_5c1e", "messageId": "msg_1", "at": 1u64, "visibility": "ceo"
        });
        for name in [
            "rich://turn-status",
            "rich://activity-upserted",
            "rich://worker-upserted",
            "rich://thread-summary-updated",
            "rich://something-added-later",
        ] {
            assert!(event_from_live(name, &payload, 1).is_none(), "{name} was forwarded");
        }
        // POSITIVE CONTROL: the three that ARE handled come through on the same payload.
        assert!(event_from_live("rich://message-started", &payload, 1).is_some());
        assert!(event_from_live("rich://message-delta", &payload, 1).is_some());
        assert!(event_from_live("rich://message-completed", &payload, 1).is_some());
    }

    #[test]
    fn only_an_opening_message_consumes_a_cursor() {
        assert!(opens_a_row("rich://message-started"));
        assert!(!opens_a_row("rich://message-delta"));
        assert!(!opens_a_row("rich://message-completed"));
        assert!(!opens_a_row("rich://turn-status"));
    }

    #[test]
    fn an_event_with_no_message_id_is_dropped_rather_than_given_an_empty_one() {
        let payload = json!({ "threadId": "t", "at": 1u64 });
        assert!(event_from_live("rich://message-started", &payload, 1).is_none());
    }

    // --- the timestamp ---------------------------------------------------------------------------

    #[test]
    fn the_timestamp_is_iso_8601_and_the_arithmetic_is_checked_against_known_dates() {
        // Known answers rather than a round trip against itself: a date function that is wrong
        // is wrong in both directions and a round trip cannot tell.
        assert_eq!(iso8601(0), "1970-01-01T00:00:00.000Z");
        assert_eq!(iso8601(1), "1970-01-01T00:00:00.001Z");
        assert_eq!(iso8601(86_399_999), "1970-01-01T23:59:59.999Z");
        assert_eq!(iso8601(86_400_000), "1970-01-02T00:00:00.000Z");
        // A leap day, which is the one the algorithm exists for.
        assert_eq!(iso8601(951_782_400_000), "2000-02-29T00:00:00.000Z");
        // 2100 is NOT a leap year — the century rule, which a naive "every four years" gets
        // wrong and which no test before 2100 would otherwise catch.
        //
        // EVERY VALUE IN THIS TEST WAS READ OFF `date -u -r <seconds>` RATHER THAN TYPED, and
        // that is not ceremony: the first draft of this line asserted `2100-03-01` from memory
        // and `date -u -r 4107456000` said `2100-02-28`. A date function checked against a
        // number somebody remembered is a date function checked against nothing.
        assert_eq!(iso8601(4_107_456_000_000), "2100-02-28T00:00:00.000Z");
        assert_eq!(iso8601(1_758_200_400_000), "2025-09-18T13:00:00.000Z");
    }
}
