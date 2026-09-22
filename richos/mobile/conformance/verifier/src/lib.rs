//! The Mac's production phone-credential code, compiled on its own so the conformance corpus
//! can be checked against it in seconds, without the Tauri app. See `build.rs` for exactly
//! which production items are included and how.
//!
//! This crate root stands where `richos/app/src-tauri/src/phone/mod.rs` stands for the real
//! modules, so their `super::…` paths resolve here. Everything below except the two test
//! doubles at the bottom is cut from the production source, unchanged.
#![allow(dead_code, unused_imports, clippy::all)]

include!(concat!(env!("OUT_DIR"), "/phone.rs"));

use std::collections::VecDeque;
use std::sync::Mutex;

// ---- the two test doubles -------------------------------------------------------------------

static NOW: Mutex<u64> = Mutex::new(1_790_000_000_000);
static RANDOM: Mutex<VecDeque<Vec<u8>>> = Mutex::new(VecDeque::new());

/// The test's clock (production: `richos_core::util::now_millis`).
pub fn now_millis() -> u64 {
    *NOW.lock().unwrap()
}

pub fn advance(ms: u64) {
    *NOW.lock().unwrap() += ms;
}

/// The test's randomness (production: `ring::rand::SystemRandom`). Hands out exactly the bytes
/// the test queued, and refuses a request it did not expect rather than inventing bytes.
pub fn random_bytes(n: usize) -> Result<Vec<u8>, PhoneError> {
    let next = RANDOM
        .lock()
        .unwrap()
        .pop_front()
        .unwrap_or_else(|| panic!("the production code asked for {n} random bytes the test did not queue"));
    assert_eq!(next.len(), n, "the production code asked for {n} random bytes; the test queued {}", next.len());
    Ok(next)
}

pub fn queue_random(bytes: Vec<u8>) {
    RANDOM.lock().unwrap().push_back(bytes);
}
