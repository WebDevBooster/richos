//! EVERY SIGNED REQUEST IN THE CORPUS, THROUGH THE MAC'S OWN VERIFIER.
//!
//! The corpus (`../vectors/*.json`) is generated from the phone's reference JavaScript. This
//! test is what anchors it to the Mac rather than only to the phone: for every request object
//! carrying `signed` and `mac`, it reads the credential the way `routes.rs` does, rebuilds the
//! canonical string with the production `signing_string`, makes the real `DeviceDesk` (paired
//! with the corpus's test key through the real `complete_pairing`) issue the challenge the
//! credential names, and asks the real `DeviceDesk::verify` for its verdict. The verdict must
//! equal the corpus's `mac.verdict` (and `mac.refusal`), and the canonical string must equal
//! `mac.signing_string`, byte for byte.
//!
//! One `#[test]`, because the clock and the randomness are process-wide test doubles.

use richos_conformance_verifier as mac;
use mac::device::{parse_authorization, signing_string, DeviceDesk, Presented, PublicKeyForm, Refusal};
use serde_json::Value;
use std::path::{Path, PathBuf};

/// The package root AT RUN TIME (cargo runs integration tests there), never the compile-time
/// `CARGO_MANIFEST_DIR`: a binary reused from another checkout must read THIS checkout's corpus.
fn package_root() -> PathBuf {
    std::env::current_dir().unwrap()
}

fn vectors() -> PathBuf {
    package_root().join("../vectors")
}

/// Refuse to pass on production code compiled from another checkout. Cargo can consider a build
/// fresh when a second checkout of this same crate shares its target directory.
fn same_checkout() {
    let here = package_root().join("../../../app/src-tauri/src/phone").canonicalize().unwrap();
    assert_eq!(
        here,
        Path::new(mac::PHONE_DIR),
        "this test binary compiled the Mac's code from another checkout; run `cargo clean -p richos-conformance-verifier` with this target directory, or use the crate's own target/"
    );
}

fn load(name: &str) -> Value {
    let path = vectors().join(name);
    serde_json::from_str(&std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display())))
        .unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

struct Scratch(PathBuf);
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Every object with both `signed` (an object) and `mac`, labeled by file and nearest case name.
fn signed_requests<'a>(file: &str, value: &'a Value, name: &str, out: &mut Vec<(String, &'a Value)>) {
    match value {
        Value::Object(map) => {
            let name = map.get("name").and_then(Value::as_str).unwrap_or(name);
            if map.get("signed").is_some_and(Value::is_object) && map.get("mac").is_some_and(Value::is_object) {
                out.push((format!("{file}: {name}"), value));
            }
            for v in map.values() {
                signed_requests(file, v, name, out);
            }
        }
        Value::Array(items) => items.iter().for_each(|v| signed_requests(file, v, name, out)),
        _ => {}
    }
}

fn body_bytes(body: &Value) -> Vec<u8> {
    use base64::Engine as _;
    if body.is_null() {
        return Vec::new();
    }
    if let Some(text) = body.get("utf8").and_then(Value::as_str) {
        return text.as_bytes().to_vec();
    }
    let b64 = body.get("base64").and_then(Value::as_str).expect("a body is utf8 or base64");
    base64::engine::general_purpose::STANDARD.decode(b64).expect("body base64")
}

/// Make the real desk issue exactly `challenge`: past the 30-second reuse window, with the
/// challenge's own 24 bytes queued as the randomness it draws.
fn issue(desk: &DeviceDesk, challenge: &str) {
    mac::advance(31_000);
    mac::queue_random(mac::unb64url(challenge).expect("challenge is base64url"));
    assert_eq!(desk.issue_challenge().unwrap(), challenge, "the desk did not issue the challenge it was given");
}

struct Read {
    method: String,
    path_with_query: String,
    device_id: String,
    challenge: String,
    signature: Vec<u8>,
    body: Vec<u8>,
}

/// The request as `listen.rs` + `routes.rs` read it: wire path verbatim under /api/, the raw
/// query, the credential from the header, or from `auth=` for the event stream.
fn read(label: &str, request: &Value) -> Read {
    let target = request["target"].as_str().unwrap();
    let (path, query) = target.split_once('?').unwrap_or((target, ""));
    let credential = match request["signed"]["credential"].as_str() {
        Some("query") => mac::routes::events_credential(query).unwrap_or_else(|| panic!("{label}: no auth parameter")),
        _ => request["headers"]["Authorization"].as_str().unwrap_or_else(|| panic!("{label}: no Authorization header")).to_string(),
    };
    let (device_id, challenge, signature) =
        parse_authorization(&credential).unwrap_or_else(|| panic!("{label}: the Mac cannot parse the credential {credential:?}"));
    Read {
        method: request["method"].as_str().unwrap().to_string(),
        path_with_query: mac::routes::signed_path(path, query),
        device_id,
        challenge,
        signature,
        body: body_bytes(&request["body"]),
    }
}

fn verify(desk: &DeviceDesk, r: &Read) -> Result<String, Refusal> {
    desk.verify(&Presented {
        method: &r.method,
        path_with_query: &r.path_with_query,
        device_id: &r.device_id,
        challenge: &r.challenge,
        signature: r.signature.clone(),
        body: &r.body,
    })
    .map(|device| device.id)
}

#[test]
fn every_signed_request_in_the_corpus_gets_the_verdict_the_corpus_records() {
    same_checkout();
    let dir = std::env::temp_dir().join(format!("richos-conformance-verifier-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let _scratch = Scratch(dir.clone());

    // ---- pairing with the corpus key, through the production path --------------------------
    let keys = load("keys.json");
    let point = mac::unb64url(keys["public_point_b64url"].as_str().unwrap()).unwrap();
    for form in [
        PublicKeyForm::Jwk(keys["public_key_jwk"].clone()),
        PublicKeyForm::Bytes(keys["public_point_b64url"].as_str().unwrap().into()),
        PublicKeyForm::Bytes(keys["public_key_spki_b64url"].as_str().unwrap().into()),
    ] {
        assert_eq!(form.to_point().unwrap(), point, "every public key form the pairing body may carry names the same point");
    }
    let desk = DeviceDesk::open(&dir).unwrap();
    mac::queue_random(vec![0, 1, 2, 3, 4, 5, 6, 7]);
    let window = desk.open_pairing().unwrap();
    let device = desk
        .complete_pairing(&window.code, &PublicKeyForm::Jwk(keys["public_key_jwk"].clone()), "Conformance phone", "tailnet", "android")
        .unwrap_or_else(|r| panic!("pairing with the corpus key was refused: {r:?}"));
    assert_eq!(device.id, keys["device_id"].as_str().unwrap(), "the Mac derives the corpus device_id from the corpus key");

    // ---- every signed request ---------------------------------------------------------------
    let mut files: Vec<String> = std::fs::read_dir(vectors())
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .filter(|n| n.ends_with(".json"))
        .collect();
    files.sort();
    let loaded: Vec<(String, Value)> = files.iter().map(|f| (f.clone(), load(f))).collect();
    let mut requests = Vec::new();
    for (file, value) in &loaded {
        signed_requests(file, value, "", &mut requests);
    }
    assert!(requests.len() >= 40, "the corpus should carry at least 40 signed requests, found {}", requests.len());

    let (mut accepted, mut refused) = (0, 0);
    let mut first_accepted: Option<Read> = None;
    for (label, request) in &requests {
        let expected = &request["mac"];
        let r = read(label, request);
        assert_eq!(
            signing_string(&r.challenge, &r.method, &r.path_with_query, &r.body),
            expected["signing_string"].as_str().unwrap(),
            "{label}: the Mac's canonical string differs from the corpus"
        );
        issue(&desk, &r.challenge);
        match (expected["verdict"].as_str().unwrap(), verify(&desk, &r)) {
            ("accepted", Ok(id)) => {
                assert_eq!(id, device.id);
                accepted += 1;
                first_accepted.get_or_insert(r);
            }
            ("refused", Err(refusal)) => {
                assert_eq!(format!("{refusal:?}"), expected["refusal"].as_str().unwrap(), "{label}: refused for another reason");
                refused += 1;
            }
            (want, got) => panic!("{label}: the corpus says {want}, the Mac's verifier says {got:?}"),
        }
    }

    // ---- controls: the same machinery refuses what it must ---------------------------------
    let mut control = first_accepted.expect("at least one accepted request");
    issue(&desk, &control.challenge);
    assert!(verify(&desk, &control).is_ok(), "control: the untouched request verifies");
    control.signature[20] ^= 1;
    assert_eq!(verify(&desk, &control), Err(Refusal::BadSignature), "control: one flipped bit is refused");
    control.signature[20] ^= 1;
    let live = control.challenge.clone();
    control.challenge = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA".into();
    assert_eq!(verify(&desk, &control), Err(Refusal::UnknownChallenge), "control: a challenge the Mac never issued");
    control.challenge = live;
    mac::advance(mac::device::CHALLENGE_LIFETIME_MS + 1);
    assert_eq!(verify(&desk, &control), Err(Refusal::StaleChallenge), "control: a challenge past its lifetime (the reason for the 404 re-sign rule)");

    println!(
        "conformance verifier: {} signed requests from {} files through the production DeviceDesk::verify: {accepted} accepted, {refused} refused as recorded; included modules {:?} from {}",
        requests.len(),
        files.len(),
        mac::INCLUDED_MODULES,
        mac::PHONE_DIR
    );
}
