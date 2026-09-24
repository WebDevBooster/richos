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
    // Every signed request in the corpus is one a paired phone sends AFTER the person pressed
    // "They match" on the Mac (Sage F1). The unconfirmed state is proven by the Mac's own tests.
    desk.confirm_on_mac().unwrap_or_else(|e| panic!("the press on the Mac was not recorded: {e}"));
    let device = desk.paired().expect("the paired device");

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

    // ---- the v2 six words: the Mac's own derivation over the corpus's inputs -------------------
    let v2 = v2_words();
    // ---- the press on the Mac: an unconfirmed device, through the production verifier --------
    let waiting = awaiting_the_press(&dir.join("unconfirmed"), &keys);
    println!("conformance verifier: {v2} v2 six-word expectations and {waiting} press-on-the-Mac verdicts proven against phone/words.rs and DeviceDesk::verify");

    // ---- the Mac-defined areas (attachments, FCM registration, the advertised surface) --------
    #[cfg(mac_native_v1)]
    {
        let proven = native_additions(&desk, &device.id);
        println!("conformance verifier: {proven} Mac-defined expectations proven against the production attachment, registration and capability code");
    }
    #[cfg(not(mac_native_v1))]
    println!(
        "conformance verifier: NOT PROVEN HERE: this tree's Mac predates protocol_version 1 (no attachments, FCM registration or delta thread_id), so the {} Mac-defined expectations in attachments.json and push-registration-fcm.json were not checked against production code",
        mac_defined_count()
    );

    println!(
        "conformance verifier: {} signed requests from {} files through the production DeviceDesk::verify: {accepted} accepted, {refused} refused as recorded; included modules {:?} from {}",
        requests.len(),
        files.len(),
        mac::INCLUDED_MODULES,
        mac::PHONE_DIR
    );
}

/// Every v2 case in fingerprint.json and the relay scenario in pairing.json, through the Mac's
/// production `phone/words.rs`: the same input text and the same six words, or the build is red.
fn v2_words() -> usize {
    let f = load("fingerprint.json");
    let mut proven = 0;
    for case in f["v2"]["cases"].as_array().expect("fingerprint.json has no v2 cases") {
        let name = case["name"].as_str().unwrap();
        let (origin, ca, point) = (case["origin"].as_str().unwrap(), case["ca_fingerprint_sha256"].as_str().unwrap(), case["device_point_b64url"].as_str().unwrap());
        assert_eq!(mac::words::v2_input(origin, ca, point), case["input_utf8"].as_str().unwrap(), "fingerprint.json v2: {name}: the Mac hashes different text");
        assert_eq!(mac::words::v2(origin, ca, point), strings(&case["words"]), "fingerprint.json v2: {name}: the Mac shows different words");
        proven += 1;
    }
    assert_eq!(f["v2"]["label"].as_str(), Some(mac::words::PAIR_V2_LABEL));
    let relay = &load("pairing.json")["pair_v2"]["relay_scenario"];
    let (ca, point) = (relay["ca_fingerprint_sha256"].as_str().unwrap(), relay["device_point_b64url"].as_str().unwrap());
    let at_the_mac = mac::words::v2(relay["mac_origin"].as_str().unwrap(), ca, point);
    let on_the_phone = mac::words::v2(relay["phone_dialed"].as_str().unwrap(), ca, point);
    assert_eq!(at_the_mac, strings(&relay["mac_words"]), "relay scenario: the Mac's words");
    assert_eq!(on_the_phone, strings(&relay["phone_words"]), "relay scenario: the phone's words, derived by the Mac's code");
    assert_ne!(at_the_mac, on_the_phone, "relay scenario: a relayed pairing shows the same words on both screens");
    proven + 3
}

/// **SAGE F1 AT THE PRODUCTION VERIFIER.** A second desk pairs the corpus key and is NOT pressed on
/// the Mac: the corpus's waiting probe is refused `AwaitingMacConfirmation`, the phone's own answer
/// is admitted by `verify_for_confirmation`, and after `confirm_on_mac` the same probe is accepted.
fn awaiting_the_press(dir: &Path, keys: &Value) -> usize {
    std::fs::create_dir_all(dir).unwrap();
    let desk = std::sync::Arc::new(DeviceDesk::open(dir).unwrap());
    mac::queue_random(vec![7, 6, 5, 4, 3, 2, 1, 0]);
    let window = desk.open_pairing().unwrap();
    desk.complete_pairing(&window.code, &PublicKeyForm::Jwk(keys["public_key_jwk"].clone()), "Conformance phone", "connect", "android")
        .unwrap_or_else(|r| panic!("pairing the unconfirmed desk was refused: {r:?}"));
    let m = &load("pairing.json")["mac_confirmation"];
    let probe = &m["probes"][0]["requests"][0];
    let r = read("pairing.json: mac_confirmation probe", probe);
    issue(&desk, &r.challenge);
    assert_eq!(verify(&desk, &r), Err(Refusal::AwaitingMacConfirmation), "an unconfirmed device's signed read was not answered awaiting");
    let answer = &m["phone_answer_while_waiting"]["requests"][0];
    let a = read("pairing.json: the phone's answer while waiting", answer);
    issue(&desk, &a.challenge);
    let presented = Presented { method: &a.method, path_with_query: &a.path_with_query, device_id: &a.device_id, challenge: &a.challenge, signature: a.signature.clone(), body: &a.body };
    assert!(desk.verify_for_confirmation(&presented).is_ok(), "the phone's own answer to the six words was refused while waiting");

    // ---- pair-wait (Sage's pair-v2 hypotheses review §1): the held ask and its release signal --
    let proven_pair_wait = pair_wait_release(&desk);

    desk.confirm_on_mac().unwrap();
    issue(&desk, &r.challenge);
    assert!(verify(&desk, &r).is_ok(), "the press on the Mac did not let the corpus key in");
    3 + proven_pair_wait
}

/// A waker that records being woken, so the production hold can be polled by hand with no runtime.
struct Woken(std::sync::atomic::AtomicBool);
impl std::task::Wake for Woken {
    fn wake(self: std::sync::Arc<Self>) {
        self.0.store(true, std::sync::atomic::Ordering::SeqCst);
    }
}

/// **THE PAIR-WAIT SECTION AGAINST THE PRODUCTION DESK**, on a desk whose device is still waiting for
/// the press: the recorded held ask carries `Prefer` outside the signature and is admitted as the
/// phone's own answer; the capability and the hold ceiling are the Mac's own constants; and a hold
/// begun on the production `DeviceDesk` is pending until `confirm_on_mac`, which wakes it and ends it
/// `Released` — the signal the listener answers the held phone on. Called BEFORE the press.
fn pair_wait_release(desk: &std::sync::Arc<DeviceDesk>) -> usize {
    use mac::device::{HoldEnd, PAIR_WAIT_CAPABILITY, PAIR_WAIT_MAX_SECONDS};
    use std::future::Future;
    use std::task::{Context, Poll, Waker};

    let pw = &load("pairing.json")["pair_wait"];
    assert_eq!(pw["capability"].as_str(), Some(PAIR_WAIT_CAPABILITY), "pairing.json pair_wait capability");
    assert_eq!(pw["hold_seconds_max"].as_u64(), Some(PAIR_WAIT_MAX_SECONDS), "pairing.json pair_wait hold_seconds_max");
    #[cfg(mac_native_v1)]
    assert!(mac::routes::capabilities(false, false).contains(&PAIR_WAIT_CAPABILITY), "the Mac does not advertise pair-wait");

    // Every recorded ask is the phone's own answer, admitted while the Mac waits, whatever it asks.
    let asks = pw["asks"].as_array().expect("pairing.json pair_wait has no asks");
    for case in asks {
        let name = case["name"].as_str().unwrap();
        let request = &case["requests"][0];
        let wait = case["wait_seconds"].as_u64().unwrap();
        let prefer = request["headers"]["Prefer"].as_str();
        assert_eq!(prefer.map(str::to_owned), (wait > 0).then(|| format!("wait={wait}")), "pair_wait: {name}: the Prefer header");
        assert!(!request["signed"]["signing_string"].as_str().unwrap().contains("wait="), "pair_wait: {name}: Prefer was signed");
        let ask = read(&format!("pairing.json: pair_wait: {name}"), request);
        issue(desk, &ask.challenge);
        let presented = Presented { method: &ask.method, path_with_query: &ask.path_with_query, device_id: &ask.device_id, challenge: &ask.challenge, signature: ask.signature.clone(), body: &ask.body };
        assert!(desk.verify_for_confirmation(&presented).is_ok(), "pair_wait: {name}: the held ask was refused while the Mac waits for its press");
    }

    // THE RELEASE SIGNAL FIRES ON THE PRESS ON THE MAC.
    let woken = std::sync::Arc::new(Woken(std::sync::atomic::AtomicBool::new(false)));
    let waker = Waker::from(std::sync::Arc::clone(&woken));
    let mut hold = desk.hold_answer(desk.hold_generation());
    let poll = |hold: &mut mac::device::HeldAnswer| std::pin::Pin::new(hold).poll(&mut Context::from_waker(&waker));
    assert_eq!(poll(&mut hold), Poll::Pending, "a held ask was not held on the production desk");
    assert!(!woken.0.load(std::sync::atomic::Ordering::SeqCst));
    desk.confirm_on_mac().unwrap();
    assert!(woken.0.load(std::sync::atomic::Ordering::SeqCst), "confirm_on_mac did not wake the held ask");
    assert_eq!(poll(&mut hold), Poll::Ready(HoldEnd::Released), "the held ask did not end on the press");
    asks.len() + 3
}

fn strings(value: &Value) -> Vec<String> {
    value.as_array().unwrap().iter().map(|v| v.as_str().unwrap().to_string()).collect()
}

/// How many Mac-defined expectations the corpus carries, for the NOT PROVEN line.
#[cfg(not(mac_native_v1))]
fn mac_defined_count() -> usize {
    let a = load("attachments.json");
    let f = load("push-registration-fcm.json");
    ["attachment_id_cases", "upload_cases", "limit_sequence", "commit_cases"]
        .iter()
        .map(|k| a[*k].as_array().map_or(0, Vec::len))
        .sum::<usize>()
        + f["registration_cases"].as_array().map_or(0, Vec::len)
}

/// Every Mac-defined expectation, against the production code. Returns how many were proven.
#[cfg(mac_native_v1)]
fn native_additions(desk: &DeviceDesk, device_id: &str) -> usize {
    use mac::attachments::{valid_id, Upload, ACCEPTED, MAX_FILES_PER_MESSAGE, MAX_FILE_BYTES, MAX_MESSAGE_BYTES, UPLOAD_SECONDS};
    use mac::notifications::{Registration, APNS_TOPICS, FCM_APPS};
    let mut proven = 0;

    // The advertised surface: what hello and the pairing answer carry on a Mac with every feature.
    let events = load("events.json");
    let hello = &events["wire_cases"][0]["frames"][0]["data"];
    assert_eq!(strings(&hello["capabilities"]), mac::routes::capabilities(true, true), "hello capabilities (all features on)");
    assert_eq!(hello["protocol_version"].as_u64(), Some(mac::routes::PROTOCOL_VERSION), "hello protocol_version");
    let pairing = load("pairing.json");
    let answer = &pairing["pair_exchanges"][0]["mac_answers"][0]["body"];
    assert_eq!(strings(&answer["capabilities"]), mac::routes::capabilities(true, true), "pairing answer capabilities");
    assert_eq!(answer["protocol_version"].as_u64(), Some(mac::routes::PROTOCOL_VERSION), "pairing answer protocol_version");
    proven += 4;

    // The awaiting answer (Sage F1), byte for byte what `phone/routes.rs` sends.
    let m = &pairing["mac_confirmation"];
    assert_eq!(m["awaiting_body"].as_str(), Some(mac::routes::AWAITING_MAC_BODY), "pairing.json awaiting body");
    assert_eq!(m["awaiting_answer_classification"]["mac_answer"]["body"].as_str(), Some(mac::routes::AWAITING_MAC_BODY), "pairing.json awaiting classification body");
    assert_eq!(m["awaiting_answer_classification"]["mac_answer"]["status"].as_u64(), Some(409), "the awaiting answer is a 409");
    proven += 3;

    // Limits, identical in the corpus's attachments.json, hello and pairing answer.
    let a = load("attachments.json");
    for (label, limits) in [("attachments.json", &a["limits"]), ("hello", &hello["attachment_limits"]), ("pairing answer", &answer["attachment_limits"])] {
        assert_eq!(limits["max_file_bytes"].as_u64(), Some(MAX_FILE_BYTES as u64), "{label} max_file_bytes");
        assert_eq!(limits["max_files_per_message"].as_u64(), Some(MAX_FILES_PER_MESSAGE as u64), "{label} max_files_per_message");
        assert_eq!(limits["max_message_bytes"].as_u64(), Some(MAX_MESSAGE_BYTES), "{label} max_message_bytes");
        assert_eq!(limits["upload_seconds"].as_u64(), Some(UPLOAD_SECONDS), "{label} upload_seconds");
        assert_eq!(strings(&limits["media_types"]), ACCEPTED.iter().map(|k| k.media_type.to_string()).collect::<Vec<_>>(), "{label} media_types");
        proven += 5;
    }

    // FCM and APNs registrations: parse (unknown keys refused) and validate, as the route does.
    let fcm = load("push-registration-fcm.json");
    assert_eq!(strings(&fcm["allowed_ids"]["fcm"]), FCM_APPS, "FCM application IDs");
    assert_eq!(strings(&fcm["allowed_ids"]["apns"]), APNS_TOPICS, "APNs topics");
    proven += 2;
    for case in fcm["registration_cases"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let got = serde_json::from_value::<Registration>(case["native_push"].clone()).ok().filter(Registration::validate);
        let want = &case["mac_outcome"];
        match (want["accepted"].as_bool().unwrap(), got) {
            (true, Some(r)) => assert_eq!(r.transport(), want["transport"].as_str().unwrap(), "{name}: transport"),
            (false, None) => {}
            (want, got) => panic!("push-registration-fcm.json: {name}: the corpus says accepted={want}, the Mac parsed and validated {got:?}"),
        }
        proven += 1;
    }

    // Attachment IDs.
    for case in a["attachment_id_cases"].as_array().unwrap() {
        let id = case["id"].as_str().unwrap();
        assert_eq!(valid_id(id), case["mac_outcome"]["valid"].as_bool().unwrap(), "attachment id {id:?}");
        proven += 1;
    }

    // Uploads, in order, through the production AttachmentDesk::stage, read the way
    // routes.rs `attachment_upload` reads the request.
    let uploads = a["upload_cases"].as_array().unwrap().iter().chain(a["limit_sequence"].as_array().unwrap());
    for case in uploads {
        let name = case["name"].as_str().unwrap();
        let request = &case["request"];
        let target = request["target"].as_str().unwrap();
        let query = target.split_once('?').map_or("", |(_, q)| q);
        let client = mac::routes::query_param(query, "client_id").unwrap();
        let id = mac::routes::query_param(query, "attachment_id").unwrap();
        let file_name = mac::routes::query_param(query, "name");
        let content_type = request["headers"]["Content-Type"].as_str().unwrap();
        let body = body_bytes(&request["body"]);
        mac::queue_random(vec![1; 6]);
        mac::queue_random(vec![2; 6]);
        let outcome = desk.attachments.stage(device_id, &client, &id, file_name.as_deref(), content_type, &body).unwrap();
        mac::clear_random();
        let want = &case["mac_outcome"];
        let kind = match &outcome {
            Upload::Stored(_) => "stored",
            Upload::Duplicate(_) => "duplicate",
            Upload::Conflict => "conflict",
            Upload::Refused(_) => "refused",
            Upload::Limit(_) => "limit",
        };
        assert_eq!(kind, want["outcome"].as_str().unwrap(), "attachments.json: {name}: {outcome:?}");
        if let Upload::Stored(s) | Upload::Duplicate(s) = &outcome {
            let answer = &want["answer"];
            assert_eq!(s.name, answer["name"].as_str().unwrap(), "{name}: stored name");
            assert_eq!(s.media_type, answer["media_type"].as_str().unwrap(), "{name}: media type");
            assert_eq!(s.size, answer["size"].as_u64().unwrap(), "{name}: size");
            assert_eq!(s.sha256, answer["sha256"].as_str().unwrap(), "{name}: sha256");
        }
        proven += 1;
    }

    // Commits: which of the named files the Mac holds, through AttachmentDesk::staged.
    for case in a["commit_cases"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let body: Value = serde_json::from_slice(&body_bytes(&case["request"]["body"])).unwrap();
        let client = body["client_id"].as_str().unwrap();
        let wanted: Vec<(String, String)> = body["attachments"]
            .as_array()
            .unwrap()
            .iter()
            .map(|f| (f["id"].as_str().unwrap().to_string(), f["sha256"].as_str().unwrap().to_string()))
            .collect();
        let want = &case["mac_outcome"];
        match (desk.attachments.staged(device_id, client, &wanted), want["all_present"].as_bool().unwrap()) {
            (Ok(files), true) => {
                let names: Vec<(String, String)> = files.iter().map(|f| (f.id.clone(), f.name.clone())).collect();
                let expected: Vec<(String, String)> = want["files"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|f| (f["id"].as_str().unwrap().to_string(), f["name"].as_str().unwrap().to_string()))
                    .collect();
                assert_eq!(names, expected, "{name}: held files");
            }
            (Err(missing), false) => assert_eq!(missing.0, strings(&want["missing"]), "{name}: missing"),
            (got, want) => panic!("attachments.json: {name}: the corpus says all_present={want}, the Mac says {got:?}"),
        }
        proven += 1;
    }
    proven
}
