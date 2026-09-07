//! Accepted requests own preparation, cancellation and every terminal outcome.
use richos_core::{
    cognition::{
        Cognition, CognitionError, LeaseFactory, MockCognition, MockLeaseFactory, TurnItem,
    },
    entity::EntityId,
    ledger::{Ledger, Source, TurnState},
    live::{LiveEvent, LiveObserver},
    spine::Spine,
    steering::{StopOutcome, TurnCancel, TurnControl},
};
use std::sync::{mpsc, Arc, Mutex};
use std::time::Duration;
mod support;
#[derive(Clone, Default)]
struct Events(Arc<Mutex<Vec<(String, serde_json::Value)>>>);
impl LiveObserver for Events {
    fn on_live_event(&self, event: &LiveEvent) {
        self.0
            .lock()
            .unwrap()
            .push((event.event_name().into(), event.payload()));
    }
}
impl Events {
    fn statuses(&self) -> Vec<String> {
        self.0
            .lock()
            .unwrap()
            .iter()
            .filter(|(n, _)| n == "rich://turn-status")
            .map(|(_, p)| p["status"].as_str().unwrap().into())
            .collect()
    }
}
fn fixture() -> (Spine, TurnControl, Events, std::path::PathBuf) {
    let root = std::env::temp_dir().join(format!("richos-preparation-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&root).unwrap();
    let mut spine = support::spine(Ledger::open(root.join("ledger.jsonl")).unwrap());
    spine
        .ensure_active_thread_in(&EntityId::parse("femcboost").unwrap())
        .unwrap();
    let control = TurnControl::open(root.join("intake.jsonl")).unwrap();
    spine.set_turn_control(control.clone());
    let events = Events::default();
    spine.set_live_observer(Box::new(events.clone()));
    (spine, control, events, root)
}
struct FailedPrime;
impl Cognition for FailedPrime {
    fn session_id(&self) -> &str {
        "failed-prime"
    }
    fn reprime(&mut self, _: &str, _: &mut dyn FnMut(TurnItem)) -> Result<(), CognitionError> {
        Err(CognitionError::Io("first prime disconnected".into()))
    }
    fn prompt(&mut self, _: &str, _: &mut dyn FnMut(TurnItem)) -> Result<String, CognitionError> {
        panic!("user prompt must not follow failed priming")
    }
}
#[test]
fn prime_failure_terminalizes_the_accepted_turn_and_survives_reload() {
    let (mut spine, control, events, root) = fixture();
    spine.attach_lease(Box::new(FailedPrime));
    assert!(spine
        .submit_prompt("start the interview", Source::Text)
        .is_err());
    let turn = spine
        .ledger()
        .turns()
        .iter()
        .find(|t| t.source == Source::Text)
        .unwrap();
    assert_eq!(turn.state, TurnState::Interrupted);
    assert!(turn.ended_at.is_some());
    assert_eq!(events.statuses(), vec!["queued", "working", "failed"]);
    assert!(control.active_turn().is_none());
    assert!(!spine.is_turn_in_progress());
    let id = turn.id.clone();
    drop(spine);
    assert_eq!(
        Ledger::open(root.join("ledger.jsonl"))
            .unwrap()
            .turn(&id)
            .unwrap()
            .state,
        TurnState::Interrupted
    );
}
struct NotifyCancel(Mutex<mpsc::Sender<()>>);
impl TurnCancel for NotifyCancel {
    fn cancel(&self) -> bool {
        self.0.lock().unwrap().send(()).is_ok()
    }
}
struct WaitingPrime {
    entered: mpsc::Sender<()>,
    cancelled: mpsc::Receiver<()>,
    handle: Arc<NotifyCancel>,
    natural_finish: bool,
}
impl Cognition for WaitingPrime {
    fn session_id(&self) -> &str {
        "waiting-prime"
    }
    fn reprime(&mut self, _: &str, _: &mut dyn FnMut(TurnItem)) -> Result<(), CognitionError> {
        self.entered.send(()).unwrap();
        self.cancelled.recv_timeout(Duration::from_secs(5)).unwrap();
        if self.natural_finish {
            Ok(())
        } else {
            Err(CognitionError::PrimingStopped("cancelled".into()))
        }
    }
    fn prompt(&mut self, _: &str, _: &mut dyn FnMut(TurnItem)) -> Result<String, CognitionError> {
        panic!("Stop during preparation must prevent user-prompt delivery")
    }
    fn cancel_handle(&self) -> Option<Arc<dyn TurnCancel>> {
        Some(self.handle.clone())
    }
}
fn stop_prime(natural_finish: bool) {
    let (mut spine, control, events, _) = fixture();
    let (tx, rx) = mpsc::channel();
    let (cx, cr) = mpsc::channel();
    spine.attach_lease(Box::new(WaitingPrime {
        entered: tx,
        cancelled: cr,
        handle: Arc::new(NotifyCancel(Mutex::new(cx))),
        natural_finish,
    }));
    let worker = std::thread::spawn(move || {
        let id = spine.submit_prompt("start", Source::Text).unwrap();
        (spine, id)
    });
    rx.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(events.statuses(), vec!["queued", "working"]);
    assert!(matches!(
        control.request_stop().unwrap(),
        StopOutcome::Requested {
            reached_lease: true,
            ..
        }
    ));
    let (spine, id) = worker.join().unwrap();
    assert_eq!(spine.ledger().turn(&id).unwrap().state, TurnState::Stopped);
    assert_eq!(events.statuses(), vec!["queued", "working", "stopped"]);
    assert!(control.active_turn().is_none());
}
#[test]
fn first_prime_is_cancellable() {
    stop_prime(false)
}
#[test]
fn stop_landing_as_internal_prime_completes_still_prevents_the_user_prompt() {
    stop_prime(true)
}
#[test]
fn recovery_factory_failure_always_resolves_recovering() {
    let (mut spine, control, events, _) = fixture();
    spine.attach_lease(Box::new(FailedPrime));
    let factory = MockLeaseFactory::new(vec!["unused"]);
    factory.fail_next_spawn();
    spine.set_lease_factory(Box::new(factory));
    assert!(spine.submit_prompt("retry", Source::Text).is_err());
    assert_eq!(events.statuses().last().unwrap(), "failed");
    assert!(spine
        .ledger()
        .pending_turns()
        .iter()
        .all(|t| t.source == Source::Internal));
    assert!(control.active_turn().is_none());
}
#[test]
fn prime_failure_has_one_bounded_recovery_and_one_visible_exchange() {
    let (mut spine, _, events, _) = fixture();
    spine.attach_lease(Box::new(FailedPrime));
    spine.set_lease_factory(Box::new(MockLeaseFactory::new(vec!["ready"])));
    spine.submit_prompt("start", Source::Text).unwrap();
    assert_eq!(events.statuses().last().unwrap(), "completed");
    assert_eq!(
        spine
            .ledger()
            .turns()
            .iter()
            .filter(|t| t.source == Source::Text && t.superseded_by.is_none())
            .count(),
        1
    );
}
#[test]
fn restart_marks_orphan_received_and_inflight_requests_failed_without_replaying() {
    let (spine, _, _, root) = fixture();
    let binding = spine.active_binding().unwrap().clone();
    drop(spine);
    let mut ledger = Ledger::open(root.join("ledger.jsonl")).unwrap();
    let first = ledger
        .record_prompt_received(&binding, "not started", Source::Text)
        .unwrap();
    let second = ledger
        .record_prompt_received(&binding, "may have side effects", Source::Text)
        .unwrap();
    ledger.mark_turn_started(&second, "old").unwrap();
    drop(ledger);
    let mut restored = support::spine(Ledger::open(root.join("ledger.jsonl")).unwrap());
    restored.set_turn_control(TurnControl::open(root.join("intake.jsonl")).unwrap());
    let mock = MockCognition::new("new", vec![]);
    let prompts = mock.prompts.clone();
    restored.attach_lease(Box::new(mock));
    restored.reconcile_intake().unwrap();
    for id in [first, second] {
        assert_eq!(
            restored.ledger().turn(&id).unwrap().state,
            TurnState::Interrupted
        );
    }
    assert!(prompts.lock().unwrap().is_empty());
}
struct WaitingFactory {
    entered: Mutex<mpsc::Sender<()>>,
}
impl LeaseFactory for WaitingFactory {
    fn spawn(&self) -> Result<Box<dyn Cognition>, CognitionError> {
        panic!("must use cancellable launch")
    }
    fn spawn_cancellable(&self, c: &TurnControl) -> Result<Box<dyn Cognition>, CognitionError> {
        self.entered.lock().unwrap().send(()).unwrap();
        let start = std::time::Instant::now();
        while c.stop_claim().is_none() {
            assert!(start.elapsed() < Duration::from_secs(5));
            std::thread::sleep(Duration::from_millis(1));
        }
        Err(CognitionError::Io("launch cancelled".into()))
    }
}
#[test]
fn stop_during_initial_launch_is_terminal_and_never_retried() {
    let (mut spine, control, events, _) = fixture();
    let (tx, rx) = mpsc::channel();
    spine.set_lease_factory(Box::new(WaitingFactory {
        entered: Mutex::new(tx),
    }));
    let worker = std::thread::spawn(move || {
        let id = spine.submit_prompt("first request", Source::Text).unwrap();
        (spine, id)
    });
    rx.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(events.statuses(), vec!["queued", "working"]);
    assert!(matches!(
        control.request_stop().unwrap(),
        StopOutcome::Requested { .. }
    ));
    let (spine, id) = worker.join().unwrap();
    assert_eq!(spine.ledger().turn(&id).unwrap().state, TurnState::Stopped);
    assert_eq!(events.statuses().last().unwrap(), "stopped");
}

struct UnacknowledgedPrime {
    control: TurnControl,
    dropped: Arc<std::sync::atomic::AtomicBool>,
}
impl Drop for UnacknowledgedPrime {
    fn drop(&mut self) {
        self.dropped
            .store(true, std::sync::atomic::Ordering::SeqCst);
    }
}
impl Cognition for UnacknowledgedPrime {
    fn session_id(&self) -> &str {
        "deaf-prime"
    }
    fn reprime(&mut self, _: &str, _: &mut dyn FnMut(TurnItem)) -> Result<(), CognitionError> {
        self.control.request_stop().unwrap();
        Err(CognitionError::PrimingStopped(
            "cancel_unacknowledged".into(),
        ))
    }
    fn prompt(&mut self, _: &str, _: &mut dyn FnMut(TurnItem)) -> Result<String, CognitionError> {
        panic!("a deaf prime must never receive a user prompt or a handoff request")
    }
}
#[test]
fn an_unacknowledged_priming_stop_retires_the_child_before_the_next_request() {
    let (mut spine, control, _, _) = fixture();
    let dropped = Arc::new(std::sync::atomic::AtomicBool::new(false));
    spine.attach_lease(Box::new(UnacknowledgedPrime {
        control,
        dropped: dropped.clone(),
    }));
    spine.set_lease_factory(Box::new(MockLeaseFactory::new(vec!["new answer"])));
    let stopped = spine.submit_prompt("stop this", Source::Text).unwrap();
    assert_eq!(
        spine.ledger().turn(&stopped).unwrap().state,
        TurnState::Stopped
    );
    assert!(dropped.load(std::sync::atomic::Ordering::SeqCst));
    assert!(!spine.has_lease());
    let next = spine.submit_prompt("a new request", Source::Text).unwrap();
    assert_eq!(
        spine.ledger().turn(&next).unwrap().assistant_text,
        "new answer"
    );
    assert_eq!(
        spine.ledger().turn(&next).unwrap().state,
        TurnState::Completed
    );
}
