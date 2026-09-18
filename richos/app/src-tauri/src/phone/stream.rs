//! **THE ROAD OUT — one stream, and the gate it inherits.** Plan §4.2 (iii), and the plan calls
//! this property *"the single most important … and the cheapest to get right"*:
//!
//! > *"`LiveObserver` is a single-method, non-blocking, infallible-from-the-spine trait, and the
//! > spine's `forward_live` chokepoint hands it **only `Visibility::Ceo` items**. So a phone
//! > emitter placed beside `TauriLiveEmitter` cannot leak a tool call, a file path or an internal
//! > turn **even by mistake** — the bytes never reach it."*
//!
//! [`PhoneLiveEmitter`] is that emitter. It holds two handles — a [`PhoneHub`] and nothing else —
//! and it has **no path to the ledger, to the raw event stream or to a `Timeline`.** That is not a
//! rule this file promises to follow; it is the only thing it has.
//!
//! # The wire shape is the landed phone's
//!
//! **RECONCILED 2026-09-18.** `web/web-app/lib/api.js` shipped first and subscribes to exactly five
//! event names — `hello`, `message`, `delta`, `state`, `heartbeat` — and merges on an integer
//! cursor. So the §13 live family is translated into those ([`super::rows`]) rather than forwarded
//! verbatim, and the cursor is an integer rather than the `<boot>-<seq>` string an earlier draft
//! of the contract specified. The translation reads only already-gated JSON, so §4.2 (iii) is
//! unaffected by it.

use super::rows::{event_from_live, opens_a_row};
use richos_core::live::{LiveEvent, LiveObserver};
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use tokio::sync::broadcast;

/// How many recent frames the hub remembers, so a reconnection with `since=` can be answered
/// from memory. Beyond it the phone is sent a fresh `hello` and backfills — never a partial tail,
/// because a gap it cannot see is the one failure this design refuses.
const REPLAY_MEMORY: usize = 512;

/// How many frames a slow consumer may fall behind before it is told to start again.
const BROADCAST_DEPTH: usize = 256;

/// One thing to send down an open event stream.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    /// The SSE `id:`. The phone does not read it — it tracks `cursor` inside the data — but it is
    /// what makes a reconnection answerable, and `EventSource` resends it for free.
    pub cursor: u64,
    /// The SSE `event:` name: one of the five the phone subscribes to.
    pub kind: &'static str,
    /// The SSE `data:` — one line of JSON.
    pub data: String,
}

impl Frame {
    /// The wire form, exactly as SSE specifies it: field lines, then a blank line.
    ///
    /// `data` is one line because every payload here is compact JSON with no literal newline in
    /// it — serde never emits one — and a multi-line `data` would silently split the event in
    /// two. There is a test that proves the invariant rather than assuming it.
    pub fn to_wire(&self) -> String {
        format!("id: {}\nevent: {}\ndata: {}\n\n", self.cursor, self.kind, self.data)
    }
}

/// What a reconnecting client should be sent.
#[derive(Debug, PartialEq, Eq)]
pub enum Replay {
    /// Exactly the frames after the cursor it presented.
    Tail(Vec<Frame>),
    /// A fresh `hello`: no cursor, a cursor we no longer hold, or a cursor this run never issued.
    Hello,
}

/// The fan-out. One per running channel.
///
/// **It is inert until a listener runs** — an emitter attached at boot with no channel simply
/// drops what it is given, which is what makes it safe to install the emitter once, at start-up,
/// rather than reaching into the spine when a phone pairs.
pub struct PhoneHub {
    state: Mutex<HubState>,
    tx: broadcast::Sender<Frame>,
}

struct HubState {
    /// The last cursor issued. Seeded from the gated projection's row count whenever a `hello`
    /// is built, so live cursors continue the projection rather than starting a second sequence.
    cursor: u64,
    recent: VecDeque<Frame>,
    live: bool,
}

impl PhoneHub {
    pub fn new() -> Arc<Self> {
        let (tx, _rx) = broadcast::channel(BROADCAST_DEPTH);
        Arc::new(PhoneHub {
            state: Mutex::new(HubState { cursor: 0, recent: VecDeque::new(), live: false }),
            tx,
        })
    }

    /// Start or stop accepting events. Called when the listener starts and stops.
    pub fn set_live(&self, live: bool) {
        let mut state = self.state.lock().unwrap();
        state.live = live;
        if !live {
            // Nothing that happened while a phone was paired is kept once it is not. The ledger
            // is the record; this buffer is only ever a reconnection convenience, and his words
            // must not sit in memory after "Forget this phone".
            state.recent.clear();
        }
    }

    /// Whether a listener is running. Read by the tests that prove the hub is inert before one is,
    /// which is the property plan §2.5 item 1 turns into "off means no socket".
    #[allow(dead_code)]
    pub fn is_live(&self) -> bool {
        self.state.lock().unwrap().live
    }

    /// Set the cursor from the gated projection's row count. Called whenever a `hello` is built,
    /// so a drift between the live sequence and what a reload computes cannot survive one
    /// reconnection.
    pub fn seed_cursor(&self, rows: u64) {
        let mut state = self.state.lock().unwrap();
        if rows > state.cursor {
            state.cursor = rows;
        }
    }

    pub fn cursor_now(&self) -> u64 {
        self.state.lock().unwrap().cursor
    }

    /// Subscribe an open stream.
    pub fn subscribe(&self) -> broadcast::Receiver<Frame> {
        self.tx.subscribe()
    }

    /// Publish one frame under a cursor the caller has decided. Returns the frame, or `None`
    /// when no listener is running.
    pub fn publish(&self, kind: &'static str, cursor: u64, data: String) -> Option<Frame> {
        let mut state = self.state.lock().unwrap();
        if !state.live {
            return None;
        }
        // The high-water mark follows what was actually published, so `replay_after` can tell a
        // cursor this run issued from one it never did. A test caught the version that did not do
        // this: every reconnection was answered with a whole `hello`, because the hub believed it
        // had issued nothing.
        if cursor > state.cursor {
            state.cursor = cursor;
        }
        let frame = Frame { cursor, kind, data };
        state.recent.push_back(frame.clone());
        while state.recent.len() > REPLAY_MEMORY {
            state.recent.pop_front();
        }
        drop(state);
        // A send with no subscribers is not an error: the phone is not always looking, and
        // §13's rule that "missed UI events never block the spine" applies to this observer
        // exactly as it applies to the webview's.
        let _ = self.tx.send(frame.clone());
        Some(frame)
    }

    /// Take the next cursor, for a frame that opens a new row.
    pub fn next_cursor(&self) -> u64 {
        let mut state = self.state.lock().unwrap();
        state.cursor += 1;
        state.cursor
    }

    /// What to send a client that presented `since` (from the query, or from `Last-Event-ID`).
    pub fn replay_after(&self, since: Option<u64>) -> Replay {
        let Some(since) = since else { return Replay::Hello };
        let state = self.state.lock().unwrap();
        if !state.live {
            // No channel is running, so there is nothing to be the tail OF. Without this, a
            // buffer just cleared by an unpair would answer "you are up to date" about a stream
            // that no longer exists — a test caught exactly that.
            return Replay::Hello;
        }
        if since > state.cursor {
            // A cursor from the future: this run never issued it.
            return Replay::Hello;
        }
        let oldest_held = state.recent.front().map(|f| f.cursor);
        match oldest_held {
            Some(oldest) if oldest <= since + 1 => {
                Replay::Tail(state.recent.iter().filter(|f| f.cursor > since).cloned().collect())
            }
            // The buffer has rolled past what it asked for. A partial tail would be a silent
            // gap, so it gets the truth instead.
            Some(_) => Replay::Hello,
            None if since == state.cursor => Replay::Tail(Vec::new()),
            None => Replay::Hello,
        }
    }
}

/// **The phone's emitter, beside `TauriLiveEmitter`.**
///
/// It receives only what `Spine::forward_live` allows through — `Visibility::Ceo` items — and it
/// holds nothing else. Same posture as the webview's emitter: best-effort, infallible from the
/// spine's view, never able to stall or fail a turn.
pub struct PhoneLiveEmitter {
    hub: Arc<PhoneHub>,
    /// The cursor of the message currently streaming, so its deltas and its completion carry the
    /// same one. A `Mutex<Option<u64>>` rather than a field on the hub, because it is per-emitter
    /// bookkeeping and not part of what any stream reads.
    open_row: Mutex<Option<u64>>,
}

impl PhoneLiveEmitter {
    pub fn new(hub: Arc<PhoneHub>) -> Self {
        PhoneLiveEmitter { hub, open_row: Mutex::new(None) }
    }
}

impl LiveObserver for PhoneLiveEmitter {
    fn on_live_event(&self, event: &LiveEvent) {
        let name = event.event_name();
        let cursor = if opens_a_row(name) {
            let next = self.hub.next_cursor();
            *self.open_row.lock().unwrap() = Some(next);
            next
        } else {
            // A delta or a completion belongs to the row that is open. If none is — the stream
            // opened mid-reply — the current cursor is the honest answer: it names the newest
            // row, which is the one being written.
            self.open_row.lock().unwrap().unwrap_or_else(|| self.hub.cursor_now())
        };
        // The translation reads the event's already-gated payload and nothing else. This layer
        // resolves no scope, builds no payload from the ledger and makes no visibility decision.
        if let Some((kind, data)) = event_from_live(name, &event.payload(), cursor) {
            let _ = self.hub.publish(kind, cursor, data.to_string());
        }
    }
}

/// **Fan one live stream out to several observers.**
///
/// `Spine::set_live_observer` takes ONE observer, and there are now two that want it: the
/// webview's and the phone's. Rather than change the spine's shape, this forwards to both — and
/// it forwards the SAME `&LiveEvent`, after the same gate, so neither observer can see anything
/// the other cannot.
pub struct FanOutLiveEmitter {
    observers: Vec<Box<dyn LiveObserver>>,
}

impl FanOutLiveEmitter {
    pub fn new(observers: Vec<Box<dyn LiveObserver>>) -> Self {
        FanOutLiveEmitter { observers }
    }
}

impl LiveObserver for FanOutLiveEmitter {
    fn on_live_event(&self, event: &LiveEvent) {
        for observer in &self.observers {
            observer.on_live_event(event);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn live_hub() -> Arc<PhoneHub> {
        let hub = PhoneHub::new();
        hub.set_live(true);
        hub
    }

    #[test]
    fn nothing_is_published_until_a_listener_is_running() {
        // Plan §2.5 item 1 seen from the inside: the emitter can be installed at boot and does
        // nothing at all until a phone is paired. That is why there is no second code path for
        // "attach the emitter later".
        let hub = PhoneHub::new();
        assert!(!hub.is_live());
        assert_eq!(hub.publish("message", 1, "{}".into()), None);
        assert_eq!(hub.cursor_now(), 0);
        hub.set_live(true);
        assert!(hub.publish("message", 1, "{}".into()).is_some());
    }

    #[test]
    fn the_cursor_is_minted_by_the_mac_and_continues_the_projection() {
        // Plan §4.2 (vi): "server-issued, never client-generated ordering". And it CONTINUES the
        // gated projection's row count rather than starting a second sequence, which is what
        // makes a live cursor and a reloaded one mean the same thing.
        let hub = live_hub();
        hub.seed_cursor(12);
        assert_eq!(hub.cursor_now(), 12);
        assert_eq!(hub.next_cursor(), 13);
        assert_eq!(hub.next_cursor(), 14);
        // Seeding never moves it backwards: a stale projection must not rewind a live stream.
        hub.seed_cursor(3);
        assert_eq!(hub.cursor_now(), 14);
    }

    #[test]
    fn a_reconnection_gets_exactly_its_tail() {
        let hub = live_hub();
        hub.publish("message", 1, "{\"n\":1}".into()).unwrap();
        hub.publish("message", 2, "{\"n\":2}".into()).unwrap();
        hub.publish("message", 3, "{\"n\":3}".into()).unwrap();
        match hub.replay_after(Some(1)) {
            Replay::Tail(frames) => {
                assert_eq!(frames.len(), 2);
                assert_eq!(frames[0].data, "{\"n\":2}");
                assert_eq!(frames[1].data, "{\"n\":3}");
            }
            other => panic!("expected a tail, got {other:?}"),
        }
    }

    #[test]
    fn a_client_that_is_already_up_to_date_gets_an_empty_tail_and_not_a_whole_hello() {
        // The commonest case on a flaky Wi-Fi: the stream dropped after the last event. A
        // `hello` there would redraw his thread for no reason.
        let hub = live_hub();
        hub.seed_cursor(4);
        hub.publish("message", 5, "{}".into()).unwrap();
        assert_eq!(hub.replay_after(Some(5)), Replay::Tail(Vec::new()));
    }

    #[test]
    fn no_cursor_at_all_is_a_hello() {
        let hub = live_hub();
        hub.publish("message", 1, "{}".into()).unwrap();
        assert_eq!(hub.replay_after(None), Replay::Hello);
    }

    #[test]
    fn a_cursor_the_buffer_has_rolled_past_is_a_hello_and_never_a_partial_tail() {
        // A partial tail is a silent gap, which is the one thing this design refuses.
        let hub = live_hub();
        for n in 1..=REPLAY_MEMORY as u64 + 100 {
            hub.publish("message", n, format!("{{\"n\":{n}}}")).unwrap();
        }
        assert_eq!(hub.replay_after(Some(1)), Replay::Hello);
        // POSITIVE CONTROL: a cursor still inside the window gets a tail.
        let inside = REPLAY_MEMORY as u64 + 99;
        assert!(matches!(hub.replay_after(Some(inside)), Replay::Tail(f) if f.len() == 1));
    }

    #[test]
    fn a_cursor_this_run_never_issued_is_a_hello() {
        let hub = live_hub();
        hub.publish("message", 1, "{}".into()).unwrap();
        assert_eq!(hub.replay_after(Some(99_999)), Replay::Hello);
    }

    #[test]
    fn unpairing_leaves_nothing_of_the_conversation_in_the_hub() {
        let hub = live_hub();
        hub.publish("message", 1, "{\"words\":\"where are we on the proposal\"}".into()).unwrap();
        hub.set_live(false);
        assert_eq!(hub.replay_after(Some(1)), Replay::Hello);
        assert_eq!(hub.publish("message", 2, "{}".into()), None);
    }

    #[test]
    fn the_wire_form_is_server_sent_events_and_the_payload_is_one_line() {
        // A literal newline inside `data` would silently split the event in two on the wire.
        let frame = Frame { cursor: 4, kind: "message", data: "{\"a\":\"b\"}".into() };
        assert_eq!(frame.to_wire(), "id: 4\nevent: message\ndata: {\"a\":\"b\"}\n\n");

        let awkward = serde_json::json!({ "text": "a line\nand another\r\nand a tab\t" }).to_string();
        assert!(!awkward.contains('\n'), "serde emitted a literal newline: {awkward}");
        assert!(!awkward.contains('\r'), "serde emitted a literal carriage return: {awkward}");
        let framed = Frame { cursor: 1, kind: "delta", data: awkward }.to_wire();
        assert_eq!(framed.matches("\n\n").count(), 1, "the frame was split: {framed}");
    }

    #[test]
    fn an_open_stream_receives_what_is_published_after_it_subscribed() {
        let hub = live_hub();
        let mut rx = hub.subscribe();
        let published = hub.publish("message", 1, "{\"n\":1}".into()).unwrap();
        assert_eq!(rx.try_recv().unwrap(), published);
        assert!(rx.try_recv().is_err(), "a second frame arrived from nowhere");
    }

    #[test]
    fn publishing_with_nobody_listening_is_not_an_error() {
        // §13's "missed UI events never block the spine", inherited: a phone that is not looking
        // must never be able to fail a turn.
        let hub = live_hub();
        assert!(hub.publish("message", 1, "{}".into()).is_some());
        let rx = hub.subscribe();
        drop(rx);
        assert!(hub.publish("message", 2, "{}".into()).is_some());
    }

    // -----------------------------------------------------------------------------------
    // THE GATE, THROUGH A REAL SPINE
    // -----------------------------------------------------------------------------------
    //
    // `LiveEvent` CANNOT BE CONSTRUCTED FROM THIS CRATE, and that is the fence working:
    // `EventFence::for_turn` is `pub(crate)` to richos-core and takes a `ThreadBinding` only the
    // ledger can issue. So these tests drive a real `Spine` with a mock lease instead of
    // hand-building events — a stronger test anyway, because it exercises the actual
    // `forward_live` chokepoint rather than a stand-in for it.

    use richos_core::cognition::MockLeaseFactory;
    use richos_core::entity::{Entity, EntityId, EntityRegistry};
    use richos_core::ledger::{Ledger, Source};
    use richos_core::spine::Spine;
    use richos_core::timeline::Visibility;

    struct VisibilityRecorder(Arc<Mutex<Vec<Visibility>>>);
    impl LiveObserver for VisibilityRecorder {
        fn on_live_event(&self, event: &LiveEvent) {
            self.0.lock().unwrap().push(event.visibility());
        }
    }

    struct NameRecorder(Arc<Mutex<Vec<String>>>);
    impl LiveObserver for NameRecorder {
        fn on_live_event(&self, event: &LiveEvent) {
            self.0.lock().unwrap().push(event.event_name().to_string());
        }
    }

    fn spine_for(tag: &str, reply: &'static str) -> (std::path::PathBuf, Spine, String) {
        let path = std::env::temp_dir().join(format!(
            "richos-phone-stream-{tag}-{}-{}.jsonl",
            std::process::id(),
            super::super::now_millis()
        ));
        let _ = std::fs::remove_file(&path);
        let mut spine = Spine::new(Ledger::open(&path).unwrap());
        spine.set_entity_registry(
            EntityRegistry::new(vec![
                Entity::new("femcboost", "FemcBoost", &["/fixture/femcboost"]).unwrap()
            ])
            .unwrap(),
        );
        let entity = EntityId::parse("femcboost").unwrap();
        let thread = spine.create_thread("the proposal", &entity).unwrap();
        spine.switch_thread(&thread).unwrap();
        spine.set_lease_factory(Box::new(MockLeaseFactory::new(vec![reply])));
        (path, spine, thread)
    }

    #[test]
    fn the_phone_emitter_only_ever_receives_ceo_items_because_the_spine_gate_is_upstream_of_it() {
        // Plan §4.2 (iii), asserted rather than described.
        let seen = Arc::new(Mutex::new(Vec::new()));
        let hub = live_hub();
        let (path, mut spine, _thread) = spine_for("gate", "On it! Here is where we are.");
        spine.set_live_observer(Box::new(FanOutLiveEmitter::new(vec![
            Box::new(PhoneLiveEmitter::new(Arc::clone(&hub))),
            Box::new(VisibilityRecorder(Arc::clone(&seen))),
        ])));

        spine.submit_prompt("where are we on the proposal?", Source::Text).unwrap();

        let recorded = seen.lock().unwrap().clone();
        assert!(!recorded.is_empty(), "the emitter received nothing at all — the test proves nothing");
        assert!(
            recorded.iter().all(|v| *v == Visibility::Ceo),
            "a non-CEO item reached the phone emitter: {recorded:?}"
        );
        assert!(hub.cursor_now() > 0, "no frame reached the hub");
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn the_fan_out_gives_the_webview_and_the_phone_the_same_events() {
        let a = Arc::new(Mutex::new(Vec::new()));
        let b = Arc::new(Mutex::new(Vec::new()));
        let (path, mut spine, _thread) = spine_for("fanout", "Two observers, one stream.");
        spine.set_live_observer(Box::new(FanOutLiveEmitter::new(vec![
            Box::new(NameRecorder(Arc::clone(&a))),
            Box::new(NameRecorder(Arc::clone(&b))),
        ])));
        spine.submit_prompt("say something", Source::Text).unwrap();
        assert!(!a.lock().unwrap().is_empty(), "the fan-out forwarded nothing");
        assert_eq!(*a.lock().unwrap(), *b.lock().unwrap(), "the two observers saw different streams");
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn a_real_turn_becomes_the_events_the_landed_phone_subscribes_to() {
        // END TO END THROUGH THE SPINE: a real reply, translated, and nothing on the wire that
        // `web/web-app/lib/api.js` does not handle. Its listener list is
        // ['hello','message','delta','state','heartbeat'] — so anything else here would be bytes
        // his cellular connection carries for nothing.
        let hub = live_hub();
        let mut rx = hub.subscribe();
        let (path, mut spine, _thread) = spine_for("translated", "On it! Here is where we are.");
        spine.set_live_observer(Box::new(PhoneLiveEmitter::new(Arc::clone(&hub))));
        spine.submit_prompt("where are we?", Source::Text).unwrap();

        let mut kinds: Vec<&'static str> = Vec::new();
        let mut delta_text = String::new();
        let mut completed = String::new();
        while let Ok(frame) = rx.try_recv() {
            assert!(
                ["hello", "message", "delta", "state", "heartbeat"].contains(&frame.kind),
                "the phone does not subscribe to {}",
                frame.kind
            );
            let value: serde_json::Value = serde_json::from_str(&frame.data).unwrap();
            if frame.kind == "delta" {
                delta_text.push_str(value["text"].as_str().unwrap());
            }
            if frame.kind == "message" && value["complete"] == true {
                completed = value["text"].as_str().unwrap().to_string();
            }
            kinds.push(frame.kind);
        }
        assert!(kinds.contains(&"message"), "no message row was sent: {kinds:?}");
        assert_eq!(completed, "On it! Here is where we are.", "the completed row lost the reply");
        assert!(
            delta_text.is_empty() || completed.contains(delta_text.trim_end()),
            "the deltas and the completion disagree: {delta_text:?} vs {completed:?}"
        );
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn every_frame_of_one_reply_carries_one_cursor() {
        // The phone merges a reply by cursor, so its opening, its deltas and its completion must
        // all name the same row. A delta under a different cursor is a second bubble.
        let hub = live_hub();
        let mut rx = hub.subscribe();
        let (path, mut spine, _thread) = spine_for("one-cursor", "One row, several frames.");
        spine.set_live_observer(Box::new(PhoneLiveEmitter::new(Arc::clone(&hub))));
        spine.submit_prompt("say something", Source::Text).unwrap();

        let mut cursors: Vec<u64> = Vec::new();
        while let Ok(frame) = rx.try_recv() {
            cursors.push(frame.cursor);
        }
        assert!(!cursors.is_empty(), "nothing was published");
        assert!(
            cursors.iter().all(|c| *c == cursors[0]),
            "one reply was spread over several cursors: {cursors:?}"
        );
        let _ = std::fs::remove_file(path);
    }
}
