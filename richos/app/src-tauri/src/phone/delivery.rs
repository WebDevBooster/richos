//! Durable replay protection at the phone intake boundary. A reservation is fsynced
//! before calling the bridge. A crash in the reservation/receipt gap is uncertain,
//! never permission to submit the same message again. Receipts retain no message text.
use super::PhoneError;
use serde::{Deserialize, Serialize};
use std::{collections::VecDeque, path::{Path, PathBuf}, sync::Mutex};

const MAX_RECEIPTS: usize = 4096;
const RETENTION_MS: u64 = 30 * 24 * 60 * 60 * 1000;

#[derive(Clone, Serialize, Deserialize)]
struct Receipt { device: String, client: String, body_hash: String, answer: Option<String>, at: u64 }

pub struct DeliveryDesk { path: PathBuf, receipts: Mutex<VecDeque<Receipt>> }
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
        Ok(Self { path, receipts: Mutex::new(receipts) })
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
    pub fn execute_prepared<T,P,F>(&self,device:&str,client:&str,body:&[u8],prepare:P,submit:F)->Result<Delivery,PhoneError>
    where P:FnOnce()->Result<T,String>, F:FnOnce(T)->Result<String,String> {
        let mut receipts = self.receipts.lock().unwrap();
        let now = super::now_millis();
        let hash = super::hex(&super::sha256(body));
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
        let prepared = match prepare() { Ok(value)=>value, Err(message)=>return Ok(Delivery::Rejected(message)) };
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
