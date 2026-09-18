//! **THE ROAD OUT — one stream, and the gate it inherits.** Plan §4.2 (iii), and it is the
//! property the plan calls *"the single most important … and the cheapest to get right"*:
//!
//! > *"`LiveObserver` is a single-method, non-blocking, infallible-from-the-spine trait, and
//! > the spine's `forward_live` chokepoint hands it **only `Visibility::Ceo` items**. So a
//! > phone emitter placed beside `TauriLiveEmitter` cannot leak a tool call, a file path or an
//! > internal turn **even by mistake** — the bytes never reach it."*
//!
//! [`PhoneLiveEmitter`] is that emitter. It holds one handle, a [`PhoneHub`], and **no path to
//! the ledger, to the raw event stream or to a `Timeline`.** That is not a rule this file
//! promises to follow; it is the only thing it has.
//!
//! # The cursor
//!
//! `<boot>-<seq>`: the millisecond the channel started, and a counter from 1 within that boot.
//! Monotone within a boot, and **deliberately different in shape across a restart**, so a
//! client can tell *"I missed some"* from *"that was a different run of the Mac"* without
//! asking. Contract §5.3.
//!
//! # Reconnection, and why the answer is never a silent gap
//!
//! The browser resends the last id in `Last-Event-ID` for free. If the boot matches and the
//! ring buffer still holds what follows it, the Mac replays exactly the tail
//! ([`Replay::Tail`]). Otherwise it sends a fresh snapshot ([`Replay::Snapshot`]). There is no
//! third answer — in particular there is no *"carry on from here and hope"*, which is what a
//! silent gap looks like from the inside.

use richos_core::live::{LiveEvent, LiveObserver};
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use tokio::sync::broadcast;

/// How many recent events the hub remembers for reconnection. 512 is roughly a long turn's
/// worth of live events; beyond it the honest answer is a fresh snapshot rather than a partial
/// tail.
const REPLAY_MEMORY: usize = 512;

/// How many events a slow consumer may fall behind before it is told to re-snapshot. A phone
/// that cannot keep up gets a correct snapshot, never a silently thinned stream.
const BROADCAST_DEPTH: usize = 256;

/// One thing to send down an open event stream.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    /// The SSE `id:` — the cursor. Minted by the Mac; never by a client (plan §4.2 vi:
    /// *"Server-issued, never client-generated ordering"*).
    pub cursor: String,
    /// The SSE `event:` name — `live`, `api-base` or `snapshot`.
    pub kind: &'static str,
    /// The SSE `data:` — one line of JSON.
    pub data: String,
}

impl Frame {
    /// The wire form, exactly as SSE specifies it: field lines then a blank line.
    ///
    /// `data` is written as ONE line because every payload here is compact JSON with no
    /// literal newline in it — serde never emits one — and a multi-line `data` would need
    /// splitting across several `data:` lines. There is a test that proves the invariant
    /// rather than trusting it.
    pub fn to_wire(&self) -> String {
        format!("id: {}\nevent: {}\ndata: {}\n\n", self.cursor, self.kind, self.data)
    }
}

/// What a reconnecting client should be sent.
#[derive(Debug, PartialEq, Eq)]
pub enum Replay {
    /// Exactly the frames after the cursor it presented.
    Tail(Vec<Frame>),
    /// A fresh snapshot: a different boot, a cursor we no longer hold, or no cursor at all.
    Snapshot,
}

/// The fan-out. One per running channel.
///
/// **It is inert until a listener runs** — an emitter attached at boot with no channel simply
/// drops what it is given, which is what makes it safe to install the emitter once, at start-up,
/// rather than reaching into the spine when a phone pairs.
pub struct PhoneHub {
    boot: u64,
    state: Mutex<HubState>,
    tx: broadcast::Sender<Frame>,
}

struct HubState {
    seq: u64,
    recent: VecDeque<Frame>,
    /// False until a listener is running. The emitter still receives events and still refuses
    /// to do anything with them, so there is no second code path to get wrong.
    live: bool,
}

impl PhoneHub {
    pub fn new() -> Arc<Self> {
        let (tx, _rx) = broadcast::channel(BROADCAST_DEPTH);
        Arc::new(PhoneHub {
            boot: super::now_millis(),
            state: Mutex::new(HubState { seq: 0, recent: VecDeque::new(), live: false }),
            tx,
        })
    }

    /// Start or stop accepting events. Called when the listener starts and stops.
    pub fn set_live(&self, live: bool) {
        let mut state = self.state.lock().unwrap();
        state.live = live;
        if !live {
            // Nothing that happened while a phone was paired is kept once it is not. The
            // ledger is the record; this buffer is only ever a reconnection convenience.
            state.recent.clear();
        }
    }

    pub fn is_live(&self) -> bool {
        self.state.lock().unwrap().live
    }

    pub fn boot(&self) -> u64 {
        self.boot
    }

    /// Subscribe an open stream. A late subscriber gets frames from now on; what it missed is
    /// [`Self::replay_after`]'s business.
    pub fn subscribe(&self) -> broadcast::Receiver<Frame> {
        self.tx.subscribe()
    }

    /// Mint a cursor and publish one frame. Returns the frame so a caller that wants the
    /// cursor (the snapshot path) has it.
    pub fn publish(&self, kind: &'static str, data: String) -> Option<Frame> {
        let mut state = self.state.lock().unwrap();
        if !state.live {
            return None;
        }
        state.seq += 1;
        let frame = Frame { cursor: format!("{}-{}", self.boot, state.seq), kind, data };
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

    /// The current cursor — what a snapshot should carry so the phone knows where it is.
    pub fn cursor_now(&self) -> String {
        let state = self.state.lock().unwrap();
        format!("{}-{}", self.boot, state.seq)
    }

    /// What to send a client that presented `last_event_id`.
    pub fn replay_after(&self, last_event_id: Option<&str>) -> Replay {
        let Some(id) = last_event_id else { return Replay::Snapshot };
        let Some((boot, seq)) = parse_cursor(id) else { return Replay::Snapshot };
        if boot != self.boot {
            // A different run of the Mac. The shape of the cursor says so, which is the whole
            // reason the boot is in it.
            return Replay::Snapshot;
        }
        let state = self.state.lock().unwrap();
        if !state.live {
            // No channel is running, so there is nothing to be the tail OF. Without this the
            // `seq == state.seq` branch below answers "you are up to date" to a client whose
            // buffer was just cleared by an unpair — a test caught exactly that, and "up to
            // date" would have been a claim about a stream that no longer exists.
            return Replay::Snapshot;
        }
        if seq > state.seq {
            // A cursor from the future — this build never issued it. Refuse to reason about
            // it and re-snapshot.
            return Replay::Snapshot;
        }
        let oldest_held = state.recent.front().and_then(|f| parse_cursor(&f.cursor)).map(|(_, s)| s);
        match oldest_held {
            // Everything after `seq` is still here, so the tail is exact.
            Some(oldest) if oldest <= seq + 1 => Replay::Tail(
                state
                    .recent
                    .iter()
                    .filter(|f| parse_cursor(&f.cursor).map(|(_, s)| s > seq).unwrap_or(false))
                    .cloned()
                    .collect(),
            ),
            // The buffer has rolled past what it asked for. A partial tail would be a silent
            // gap, so it gets the truth instead.
            Some(_) => Replay::Snapshot,
            // Nothing buffered at all. If it is already up to date that is an empty tail; if
            // it is behind, we cannot prove what it missed.
            None if seq == state.seq => Replay::Tail(Vec::new()),
            None => Replay::Snapshot,
        }
    }
}

/// `<boot>-<seq>`, or nothing.
pub fn parse_cursor(cursor: &str) -> Option<(u64, u64)> {
    let (boot, seq) = cursor.split_once('-')?;
    Some((boot.parse().ok()?, seq.parse().ok()?))
}

/// **The phone's emitter, beside `TauriLiveEmitter`.**
///
/// It receives only what `Spine::forward_live` allows through — `Visibility::Ceo` items — and
/// it holds nothing else. Same posture as the webview's emitter: best-effort, infallible from
/// the spine's view, never able to stall or fail a turn.
pub struct PhoneLiveEmitter {
    hub: Arc<PhoneHub>,
}

impl PhoneLiveEmitter {
    pub fn new(hub: Arc<PhoneHub>) -> Self {
        PhoneLiveEmitter { hub }
    }
}

impl LiveObserver for PhoneLiveEmitter {
    fn on_live_event(&self, event: &LiveEvent) {
        // The name and the payload, verbatim, exactly as `events.rs` relays them to the
        // webview. This layer resolves no scope, builds no payload and makes no visibility
        // decision — if it could construct an event, the gate would be one careless edit away
        // from being bypassed.
        let data = serde_json::json!({ "name": event.event_name(), "payload": event.payload() });
        let _ = self.hub.publish("live", data.to_string());
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
        // Plan §2.5 item 1 seen from the inside: the emitter can be installed at boot and it
        // does nothing at all until a phone is paired. That is why there is no second code
        // path for "attach the emitter later".
        let hub = PhoneHub::new();
        assert!(!hub.is_live());
        assert_eq!(hub.publish("live", "{}".into()), None);
        assert_eq!(hub.cursor_now(), format!("{}-0", hub.boot()));

        // POSITIVE CONTROL: the same call with the listener up does publish.
        hub.set_live(true);
        assert!(hub.publish("live", "{}".into()).is_some());
    }

    #[test]
    fn the_cursor_is_minted_by_the_mac_and_counts_from_one() {
        let hub = live_hub();
        let a = hub.publish("live", "{\"a\":1}".into()).unwrap();
        let b = hub.publish("live", "{\"a\":2}".into()).unwrap();
        assert_eq!(a.cursor, format!("{}-1", hub.boot()));
        assert_eq!(b.cursor, format!("{}-2", hub.boot()));
        assert_eq!(hub.cursor_now(), b.cursor);
    }

    #[test]
    fn two_runs_of_the_mac_mint_cursors_a_client_can_tell_apart() {
        // The whole reason the boot is in the cursor. Without it, cursor "…-7" from yesterday
        // would look like a valid position in today's stream and the phone would be sent a
        // tail that is not its tail.
        let first = live_hub();
        first.publish("live", "{}".into()).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(2));
        let second = live_hub();
        second.publish("live", "{}".into()).unwrap();
        assert_ne!(first.boot(), second.boot());
        assert_eq!(second.replay_after(Some(&format!("{}-1", first.boot()))), Replay::Snapshot);
    }

    #[test]
    fn a_reconnection_gets_exactly_its_tail() {
        let hub = live_hub();
        let first = hub.publish("live", "{\"n\":1}".into()).unwrap();
        hub.publish("live", "{\"n\":2}".into()).unwrap();
        hub.publish("live", "{\"n\":3}".into()).unwrap();

        match hub.replay_after(Some(&first.cursor)) {
            Replay::Tail(frames) => {
                assert_eq!(frames.len(), 2, "the tail was the wrong length");
                assert_eq!(frames[0].data, "{\"n\":2}");
                assert_eq!(frames[1].data, "{\"n\":3}");
            }
            other => panic!("expected a tail, got {other:?}"),
        }
    }

    #[test]
    fn a_client_that_is_already_up_to_date_gets_an_empty_tail_and_not_a_snapshot() {
        // The common case on a flaky Wi-Fi: the stream dropped after the last event. Sending a
        // whole snapshot there would redraw his thread for no reason.
        let hub = live_hub();
        let last = hub.publish("live", "{}".into()).unwrap();
        assert_eq!(hub.replay_after(Some(&last.cursor)), Replay::Tail(Vec::new()));
    }

    #[test]
    fn no_cursor_at_all_is_a_snapshot() {
        let hub = live_hub();
        hub.publish("live", "{}".into()).unwrap();
        assert_eq!(hub.replay_after(None), Replay::Snapshot);
    }

    #[test]
    fn a_cursor_the_buffer_has_rolled_past_is_a_snapshot_and_never_a_partial_tail() {
        // A partial tail is a silent gap, which is the one thing the contract says never
        // happens. The buffer holds 512, so 600 events past a cursor must re-snapshot.
        let hub = live_hub();
        let early = hub.publish("live", "{\"n\":0}".into()).unwrap();
        for n in 1..=REPLAY_MEMORY + 100 {
            hub.publish("live", format!("{{\"n\":{n}}}")).unwrap();
        }
        assert_eq!(hub.replay_after(Some(&early.cursor)), Replay::Snapshot);

        // POSITIVE CONTROL: a cursor still inside the window does get a tail.
        let recent = hub.publish("live", "{\"n\":\"recent\"}".into()).unwrap();
        hub.publish("live", "{\"n\":\"after\"}".into()).unwrap();
        assert!(matches!(hub.replay_after(Some(&recent.cursor)), Replay::Tail(f) if f.len() == 1));
    }

    #[test]
    fn a_malformed_or_impossible_cursor_is_a_snapshot_rather_than_an_argument() {
        let hub = live_hub();
        hub.publish("live", "{}".into()).unwrap();
        for bad in ["", "-", "abc", "1-", "-1", "1-2-3", "99999999999999999999-1"] {
            assert_eq!(hub.replay_after(Some(bad)), Replay::Snapshot, "{bad} was not refused");
        }
        // A cursor from this boot that this boot never issued.
        assert_eq!(hub.replay_after(Some(&format!("{}-99999", hub.boot()))), Replay::Snapshot);
    }

    #[test]
    fn unpairing_leaves_nothing_of_the_conversation_in_the_hub() {
        // The buffer is a reconnection convenience, never a second store. "Forget this phone"
        // must not leave his words sitting in a ring buffer in memory.
        let hub = live_hub();
        hub.publish("live", "{\"words\":\"where are we on the proposal\"}".into()).unwrap();
        hub.set_live(false);
        assert_eq!(hub.replay_after(Some(&format!("{}-1", hub.boot()))), Replay::Snapshot);
        assert_eq!(hub.publish("live", "{}".into()), None);
    }

    #[test]
    fn the_wire_form_is_server_sent_events_and_the_payload_is_one_line() {
        // A literal newline inside `data` would silently split the event in two on the wire.
        // serde never emits one, and this asserts it rather than assuming it.
        let frame = Frame { cursor: "17582-4".into(), kind: "live", data: "{\"a\":\"b\"}".into() };
        assert_eq!(frame.to_wire(), "id: 17582-4\nevent: live\ndata: {\"a\":\"b\"}\n\n");

        let awkward = serde_json::json!({ "text": "a line\nand another\r\nand a tab\t" }).to_string();
        assert!(!awkward.contains('\n'), "serde emitted a literal newline: {awkward}");
        assert!(!awkward.contains('\r'), "serde emitted a literal carriage return: {awkward}");
        let framed = Frame { cursor: "1-1".into(), kind: "live", data: awkward }.to_wire();
        assert_eq!(framed.matches("\n\n").count(), 1, "the frame was split: {framed}");
    }

    #[test]
    fn an_open_stream_receives_what_is_published_after_it_subscribed() {
        let hub = live_hub();
        let mut rx = hub.subscribe();
        let published = hub.publish("live", "{\"n\":1}".into()).unwrap();
        assert_eq!(rx.try_recv().unwrap(), published);
        assert!(rx.try_recv().is_err(), "a second frame arrived from nowhere");
    }

    #[test]
    fn publishing_with_nobody_listening_is_not_an_error() {
        // §13's "missed UI events never block the spine", inherited: a phone that is not
        // looking must never be able to fail a turn.
        let hub = live_hub();
        assert!(hub.publish("live", "{}".into()).is_some());
        let rx = hub.subscribe();
        drop(rx);
        assert!(hub.publish("live", "{}".into()).is_some());
    }

    // -----------------------------------------------------------------------------------
    // THE GATE, THROUGH A REAL SPINE
    // -----------------------------------------------------------------------------------
    //
    // `LiveEvent` CANNOT BE CONSTRUCTED FROM THIS CRATE, and that is the fence working:
    // `EventFence::for_turn` is `pub(crate)` to richos-core and takes a `ThreadBinding` only
    // the ledger can issue. So these tests drive a real `Spine` with a mock lease instead of
    // hand-building events — which is a stronger test anyway, because it exercises the actual
    // `forward_live` chokepoint rather than a stand-in for it.

    use richos_core::cognition::MockLeaseFactory;
    use richos_core::entity::{Entity, EntityId, EntityRegistry};
    use richos_core::ledger::{Ledger, Source};
    use richos_core::spine::Spine;
    use richos_core::timeline::Visibility;

    /// Records what each event's visibility was, so a test can assert on the gate rather than
    /// on the absence of something.
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
            EntityRegistry::new(vec![Entity::new("femcboost", "FemcBoost", &["/fixture/femcboost"]).unwrap()])
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
        // Plan §4.2 (iii), asserted rather than described. The emitter sits beside the
        // webview's, behind `Spine::forward_live`, which hands an observer only
        // `Visibility::Ceo` items — so a tool call, a file path or an internal turn never
        // reaches these bytes.
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
        // And the hub really did get frames out of it.
        assert_ne!(hub.cursor_now(), format!("{}-0", hub.boot()), "no frame reached the hub");
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn the_fan_out_gives_the_webview_and_the_phone_the_same_events() {
        // The seam that lets one gated stream serve two consumers. If it forwarded different
        // things to each, the phone could show something the calm view cannot — or miss
        // something it shows.
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
    fn the_frames_the_phone_receives_carry_the_event_name_and_payload_verbatim() {
        // This layer relays a name and a payload and builds nothing. The assertion is that
        // what lands in a frame is exactly what the spine emitted, parsed back out.
        let hub = live_hub();
        let names = Arc::new(Mutex::new(Vec::new()));
        let (path, mut spine, _thread) = spine_for("verbatim", "Verbatim.");
        spine.set_live_observer(Box::new(FanOutLiveEmitter::new(vec![
            Box::new(PhoneLiveEmitter::new(Arc::clone(&hub))),
            Box::new(NameRecorder(Arc::clone(&names))),
        ])));
        let mut rx = hub.subscribe();
        spine.submit_prompt("say something", Source::Text).unwrap();

        let mut from_frames: Vec<String> = Vec::new();
        while let Ok(frame) = rx.try_recv() {
            assert_eq!(frame.kind, "live");
            let value: serde_json::Value = serde_json::from_str(&frame.data).unwrap();
            from_frames.push(value["name"].as_str().unwrap().to_string());
            assert!(value.get("payload").is_some(), "a frame carried no payload: {}", frame.data);
        }
        assert_eq!(from_frames, *names.lock().unwrap(), "the frames are not the events");
        let _ = std::fs::remove_file(path);
    }
}
