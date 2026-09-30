//! Durable replay protection at the phone intake boundary. A reservation is fsynced
//! before calling the bridge. A crash in the reservation/receipt gap is uncertain,
//! never permission to submit the same message again. Receipts retain no message text.
use super::PhoneError;
use serde::{Deserialize, Serialize};
use std::{collections::{HashSet, VecDeque}, path::{Path, PathBuf}, sync::{Condvar, Mutex}};

const MAX_RECEIPTS: usize = 4096;
const RETENTION_MS: u64 = 30 * 24 * 60 * 60 * 1000;

#[derive(Clone, Serialize, Deserialize)]
struct Receipt { device: String, client: String, body_hash: String, answer: Option<String>, at: u64 }

pub struct DeliveryDesk {
    path: PathBuf,
    receipts: Mutex<VecDeque<Receipt>>,
    /// Messages (device, client id) whose preparation is running outside the receipts lock.
    preparing: Mutex<HashSet<(String, String)>>,
    /// Signaled whenever one of them finishes, so a second copy of the same message can look again.
    finished: Condvar,
}

/// Marks one message as being prepared, and clears the mark however its preparation ends.
struct Preparing<'a> { desk: &'a DeliveryDesk, key: (String, String) }
impl Drop for Preparing<'_> {
    fn drop(&mut self) {
        // A poisoned lock still has to be cleared, or a copy of this message would wait forever.
        self.desk.preparing.lock().unwrap_or_else(|e| e.into_inner()).remove(&self.key);
        self.desk.finished.notify_all();
    }
}
#[derive(Debug, PartialEq)]
pub enum Delivery { Accepted(String), Duplicate(String), Conflict, Uncertain, Full, Rejected(String) }

impl DeliveryDesk {
    pub fn open(dir: &Path) -> Result<Self, PhoneError> {
        let path = dir.join("phone/delivery.json");
        let receipts: VecDeque<Receipt> = match std::fs::read(&path) {
            Ok(bytes) => serde_json::from_slice(&bytes).map_err(|_| PhoneError::Malformed("Your Mac's message recovery history is unreadable. Whoever set RichOS up needs to recover it.".into()))?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => VecDeque::new(),
            Err(e) => return Err(e.into()),
        };
        if receipts.len() > MAX_RECEIPTS { return Err(PhoneError::Malformed("Your Mac's message recovery history exceeds its safe limit. Whoever set RichOS up needs to recover it.".into())); }
        Ok(Self { path, receipts: Mutex::new(receipts), preparing: Mutex::new(HashSet::new()), finished: Condvar::new() })
    }

    fn persist(&self, receipts: &VecDeque<Receipt>) -> Result<(), PhoneError> {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        std::fs::create_dir_all(self.path.parent().unwrap())?;
        let pending = self.path.with_extension("pending");
        let mut file = std::fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(&pending)?;
        file.write_all(&serde_json::to_vec(receipts).map_err(|e| PhoneError::Malformed(e.to_string()))?)?;
        file.sync_all()?;
        std::fs::rename(pending, &self.path)?;
        std::fs::File::open(self.path.parent().unwrap())?.sync_all()?;
        Ok(())
    }

    pub fn execute<F>(&self, device: &str, client: &str, body: &[u8], submit: F) -> Result<Delivery, PhoneError>
    where F: FnOnce() -> Result<String, String> {
        self.execute_prepared(device,client,body,|| Ok(()),|_| submit())
    }
    /// Preparation has no intake side effect. A failed transcription must not create
    /// an uncertain delivery reservation; a completed receipt skips preparation entirely.
    ///
    /// **The receipts lock is NOT held while preparing** (hunt 2026-09-29, part 1, finding 20):
    /// preparing a voice note is a transcription that may run for its whole 90 s deadline, and
    /// every other delivery, to any conversation, waited behind it. What the lock protected is
    /// kept another way: the same message (device + client id) arriving while its first copy is
    /// being prepared waits for that copy and is then answered from its receipt, so it is still
    /// prepared once and submitted once. A different message never waits.
    pub fn execute_prepared<T,P,F>(&self,device:&str,client:&str,body:&[u8],prepare:P,submit:F)->Result<Delivery,PhoneError>
    where P:FnOnce()->Result<T,String>, F:FnOnce(T)->Result<String,String> {
        let hash = super::hex(&super::sha256(body));
        let key = (device.to_string(), client.to_string());
        // Declared BEFORE `receipts`, so on every exit the receipts lock is released first and
        // a waiting copy of this message wakes to a receipt that is already on file.
        let mut _preparing = None;
        let mut receipts;
        loop {
            receipts = self.receipts.lock().unwrap();
            let now = super::now_millis();
            // Keep unfinished reservations even after expiry. Uncertainty cannot become
            // an automatic retry solely because time passed.
            receipts.retain(|r| r.answer.is_none() || now.saturating_sub(r.at) < RETENTION_MS);
            if let Some(previous) = receipts.iter().find(|r| r.device == device && r.client == client) {
                if previous.body_hash != hash { return Ok(Delivery::Conflict); }
                if let Some(answer) = previous.answer.clone() {
                    self.persist(&receipts)?;
                    return Ok(Delivery::Duplicate(answer));
                }
                return Ok(Delivery::Uncertain);
            }
            if receipts.len() >= MAX_RECEIPTS { return Ok(Delivery::Full); }
            let mut preparing = self.preparing.lock().unwrap();
            if preparing.insert(key.clone()) {
                drop(preparing);
                _preparing = Some(Preparing { desk: self, key: key.clone() });
                break;
            }
            // The same message is being prepared right now. Let go of the receipts, wait for that
            // copy to finish (the condvar releases `preparing` while waiting), then look again.
            drop(receipts);
            drop(self.finished.wait(preparing).unwrap());
        }
        // The receipts lock is released for the slow part and taken again for the reservation.
        drop(receipts);
        let prepared = match prepare() { Ok(value)=>value, Err(message)=>return Ok(Delivery::Rejected(message)) };
        let mut receipts = self.receipts.lock().unwrap();
        if receipts.len() >= MAX_RECEIPTS { return Ok(Delivery::Full); }
        let now = super::now_millis();
        receipts.push_back(Receipt { device: device.into(), client: client.into(), body_hash: hash, answer: None, at: now });
        if let Err(error) = self.persist(&receipts) { receipts.pop_back(); return Err(error); }
        let answer = match submit(prepared) { Ok(answer) => answer, Err(_) => return Ok(Delivery::Uncertain) };
        receipts.back_mut().unwrap().answer = Some(answer.clone());
        self.persist(&receipts)?;
        Ok(Delivery::Accepted(answer))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn failed_preparation_is_retryable_but_receipts_skip_it_after_restart() {
        let dir=Scratch::new();
        let desk=DeliveryDesk::open(&dir.0).unwrap();
        assert_eq!(desk.execute_prepared::<(),_,_>("phone","voice",b"wav",||Err("no speech".into()),|_|panic!("submitted")).unwrap(),Delivery::Rejected("no speech".into()));
        assert_eq!(desk.execute_prepared("phone","voice",b"wav",||Ok("transcript"),|text| {assert_eq!(text,"transcript");Ok("receipt".into())}).unwrap(),Delivery::Accepted("receipt".into()));
        drop(desk);
        let reopened=DeliveryDesk::open(&dir.0).unwrap();
        assert_eq!(reopened.execute_prepared::<(),_,_>("phone","voice",b"wav",||panic!("transcribed twice"),|_|panic!("submitted twice")).unwrap(),Delivery::Duplicate("receipt".into()));
    }
    struct Scratch(PathBuf);
    impl Scratch { fn new() -> Self { let p=std::env::temp_dir().join(format!("phone-receipts-{}",super::super::hex(&super::super::random_bytes(8).unwrap()))); std::fs::create_dir_all(&p).unwrap(); Self(p) } }
    // Said, not asserted: a panic inside Drop while a failing test unwinds would abort the run.
    impl Drop for Scratch { fn drop(&mut self) { if let Err(e)=std::fs::remove_dir_all(&self.0) { eprintln!("test scratch {} was not removed: {e}",self.0.display()); } } }
    /// **ONE SLOW RECORDING DOES NOT HOLD UP AN UNRELATED MESSAGE** (hunt 2026-09-29, part 1,
    /// finding 20). Preparation of a voice note is a transcription that may run its whole 90 s
    /// deadline; it used to run with the receipts lock held, so a typed message to another
    /// conversation waited behind it.
    #[test]
    fn a_slow_preparation_does_not_block_an_unrelated_delivery() {
        use std::sync::{mpsc, Arc};
        let dir = Scratch::new();
        let desk = Arc::new(DeliveryDesk::open(&dir.0).unwrap());
        let (started_tx, started_rx) = mpsc::channel::<()>();
        let (release_tx, release_rx) = mpsc::channel::<()>();
        let slow = {
            let desk = Arc::clone(&desk);
            std::thread::spawn(move || {
                desk.execute_prepared("phone", "voice-1", b"wav", || {
                    started_tx.send(()).unwrap();
                    // Stands in for the recognizer; released by the test, never by a clock.
                    release_rx.recv().unwrap();
                    Ok("transcript")
                }, |_| Ok("voice receipt".into())).unwrap()
            })
        };
        started_rx.recv_timeout(std::time::Duration::from_secs(10)).expect("the slow preparation never started");

        let (done_tx, done_rx) = mpsc::channel();
        let typed = {
            let desk = Arc::clone(&desk);
            std::thread::spawn(move || {
                done_tx.send(desk.execute("phone", "typed-1", b"hello", || Ok("typed receipt".into())).unwrap()).unwrap();
            })
        };
        let outcome = done_rx.recv_timeout(std::time::Duration::from_secs(5));
        // Let the recording finish whatever the verdict, so a failure does not leave threads behind.
        release_tx.send(()).unwrap();
        assert_eq!(slow.join().unwrap(), Delivery::Accepted("voice receipt".into()));
        typed.join().unwrap();
        assert_eq!(
            outcome.expect("an unrelated typed message waited behind a recording being transcribed"),
            Delivery::Accepted("typed receipt".into())
        );
    }

    /// The reason the lock was held is kept: the same message sent twice while its first copy is
    /// still being prepared is answered from the first copy's receipt, and is prepared once.
    #[test]
    fn the_same_message_arriving_during_its_preparation_waits_and_is_not_prepared_twice() {
        use std::sync::{mpsc, Arc};
        let dir = Scratch::new();
        let desk = Arc::new(DeliveryDesk::open(&dir.0).unwrap());
        let (started_tx, started_rx) = mpsc::channel::<()>();
        let (release_tx, release_rx) = mpsc::channel::<()>();
        let first = {
            let desk = Arc::clone(&desk);
            std::thread::spawn(move || {
                desk.execute_prepared("phone", "voice-1", b"wav", || {
                    started_tx.send(()).unwrap();
                    release_rx.recv().unwrap();
                    Ok("transcript")
                }, |_| Ok("receipt".into())).unwrap()
            })
        };
        started_rx.recv_timeout(std::time::Duration::from_secs(10)).expect("the preparation never started");
        let second = {
            let desk = Arc::clone(&desk);
            std::thread::spawn(move || {
                desk.execute_prepared::<(), _, _>("phone", "voice-1", b"wav", || panic!("prepared twice"), |_| panic!("submitted twice")).unwrap()
            })
        };
        std::thread::sleep(std::time::Duration::from_millis(200));
        release_tx.send(()).unwrap();
        assert_eq!(first.join().unwrap(), Delivery::Accepted("receipt".into()));
        assert_eq!(second.join().unwrap(), Delivery::Duplicate("receipt".into()));
    }

    #[test]
    fn lost_ack_retry_after_relaunch_does_not_submit_twice_and_is_body_bound() {
        let dir=Scratch::new();
        let desk=DeliveryDesk::open(&dir.0).unwrap();
        assert_eq!(desk.execute("phone", "id", b"hello", || Ok("receipt".into())).unwrap(),Delivery::Accepted("receipt".into()));
        drop(desk);
        let desk=DeliveryDesk::open(&dir.0).unwrap();
        assert_eq!(desk.execute("phone", "id", b"hello", || panic!("duplicate submitted")).unwrap(),Delivery::Duplicate("receipt".into()));
        assert_eq!(desk.execute("phone", "id", b"changed", || panic!("changed request submitted")).unwrap(),Delivery::Conflict);
        assert_eq!(desk.execute("another-phone", "id", b"hello", || Ok("second".into())).unwrap(),Delivery::Accepted("second".into()));
        assert!(!std::fs::read_to_string(dir.0.join("phone/delivery.json")).unwrap().contains("hello"));
    }
    #[test]
    fn uncertain_intake_is_not_replayed_after_restart() {
        let dir=Scratch::new();
        let desk=DeliveryDesk::open(&dir.0).unwrap();
        assert_eq!(desk.execute("phone","id",b"hello",||Err("crashed after durable intake".into())).unwrap(),Delivery::Uncertain);
        drop(desk);
        assert_eq!(DeliveryDesk::open(&dir.0).unwrap().execute("phone","id",b"hello",||panic!("replayed")).unwrap(),Delivery::Uncertain);
    }
    #[test]
    fn storage_failure_prevents_submission_and_corrupt_receipts_refuse_to_open() {
        let dir=Scratch::new(); std::fs::create_dir_all(dir.0.join("phone/delivery.pending")).unwrap();
        let desk=DeliveryDesk::open(&dir.0).unwrap();
        assert!(desk.execute("phone","id",b"hello",||panic!("submitted without reservation")).is_err());
        std::fs::write(dir.0.join("phone/delivery.json"),b"broken").unwrap();
        assert!(DeliveryDesk::open(&dir.0).is_err());
    }
}
