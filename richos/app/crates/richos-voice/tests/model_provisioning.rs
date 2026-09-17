//! **CAN THE INSTALLED APP GET ITS OWN SPEECH MODEL, AND REFUSE EVERYTHING THAT IS NOT IT?**
//!
//! The behavior under test is `provision.rs` driven the way the Tauri shell drives it: plan,
//! open a part file, write whatever the network produced, finish. **No socket is opened by any
//! test in this file** — the bytes are supplied directly, which is the entire reason the transport
//! and the judgment were split in the first place. A captive portal, a corrupted body and a
//! connection that dies at 40% are all just different byte sequences, and a test that has to
//! arrange a real one of each is a test nobody runs.
//!
//! ## Every negative case here carries a positive control
//!
//! A check that reports green over something that never ran is the failure this project records
//! most, and a refusal test is the easiest place in the world to write one: assert "the model was
//! not installed" and it passes identically whether the refusal worked or the whole download
//! silently no-opped. So each refusal is paired with the SAME driver over correct bytes, asserting
//! the model IS installed and DOES verify — if the harness stopped exercising the code, the
//! control goes red first.
//!
//! ## The pins under test are synthetic, and that is deliberate
//!
//! A test cannot manufacture the 487,614,201 bytes of `ggml-small.en.bin`. `Pin` is therefore
//! constructed directly from small synthetic payloads — the same seam `model-catalog.js`'s
//! `requirePin` already offers a manifest-supplied pin. What is NOT synthetic is the shipped pin
//! table: `the_shipped_pin_table_is_usable_and_pins_what_the_live_ladder_can_ask_for` and
//! `the_two_tables_agree_on_every_size` assert against the real `model-pins.json` and
//! `model-costs.json`.

use richos_voice::provision::{
    self, Failure, FetchPlan, Outcome, PartFile, Pin, ResumeAction, Shape, Verdict,
};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

// ---------------------------------------------------------------------------------------------
// Harness.
// ---------------------------------------------------------------------------------------------

/// A scratch directory that removes itself. No `tempfile` dependency — this crate has none and
/// one test helper is not a reason to add supply-chain surface.
struct Scratch(PathBuf);

impl Scratch {
    fn new(tag: &str) -> Scratch {
        let dir = std::env::temp_dir().join(format!(
            "richos-provision-{tag}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("scratch dir");
        Scratch(dir)
    }
    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// whisper.cpp's GGML magic as it appears on disk: the uint32 0x67676d6c little-endian.
const GGML: [u8; 4] = [0x6c, 0x6d, 0x67, 0x67];

/// A body that IS a plausible model: the magic, then filler, to exactly `len` bytes.
fn model_bytes(len: usize, filler: u8) -> Vec<u8> {
    let mut v = Vec::with_capacity(len);
    v.extend_from_slice(&GGML);
    v.resize(len, filler);
    v
}

fn sha256_of(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

/// A pin for a synthetic payload — the exact bytes and the exact hash, like the real table.
fn pin_for_bytes(id: &str, bytes: &[u8]) -> Pin {
    Pin {
        id: id.to_string(),
        file: format!("ggml-{id}.bin"),
        bytes: bytes.len() as u64,
        sha256: sha256_of(bytes),
        provenance: vec!["x-linked-etag".into(), "ceo-disk".into()],
    }
}

/// Drive one whole download the way the shell does, with the server's bytes supplied directly.
///
/// `chunks` is what the transport delivered. `die_after` is how many chunks arrive before the
/// connection drops — `None` means it completes.
fn drive(pin: &Pin, dir: &Path, chunks: &[Vec<u8>], die_after: Option<usize>) -> Outcome {
    let plan = provision::plan_fetch(pin, dir, Some(u64::MAX));
    let FetchPlan::Fetch { dest, part, from, .. } = plan else {
        panic!("expected a fetch plan, got {plan:?}");
    };
    let mut f = PartFile::open(pin, &part, &dest, from).expect("open part file");
    for (i, c) in chunks.iter().enumerate() {
        f.write(c).expect("write chunk");
        if die_after == Some(i + 1) {
            return Outcome::Failed { finding: f.interrupted("the connection dropped") };
        }
    }
    f.finish()
}

// ---------------------------------------------------------------------------------------------
// The shipped tables — the only tests here that touch real product data.
// ---------------------------------------------------------------------------------------------

/// **THE POSITIVE CONTROL FOR EVERY PIN LOOKUP IN THIS FILE.** If the pin table stopped loading,
/// every "RichOS refused to download it" assertion below would still pass, for the wrong reason.
#[test]
fn the_shipped_pin_table_is_usable_and_pins_what_the_live_ladder_can_ask_for() {
    let ids = provision::pinned_ids();
    assert!(!ids.is_empty(), "the compiled-in pin table produced no models at all");

    // Every rung the LIVE ladder names, plus the safe rung an unmeasured machine lands on, must be
    // pinned — those are precisely the ids `resolve_model` can come back missing, and a missing
    // model RichOS cannot verify is a model RichOS will not fetch.
    let costs = richos_voice::hardware::Costs::load();
    let mut wanted = costs.live_ladder.clone();
    wanted.push(costs.safe_rung.clone());
    for id in &wanted {
        let pin = provision::pin_for(id).unwrap_or_else(|| panic!("the live path can ask for {id}, which is unpinned"));
        assert_eq!(pin.file, format!("ggml-{id}.bin"));
        assert_eq!(pin.sha256.len(), 64, "{id} has no usable sha256");
        assert!(pin.bytes > 0, "{id} has no pinned byte count");
    }

    assert!(
        provision::base_url().starts_with("https://"),
        "models are fetched over HTTPS or not at all"
    );
    assert_eq!(provision::ggml_magic_hex(), "6c6d6767");
}

/// **THE NUMBER THE CEO IS SHOWN AND THE NUMBER THE TRANSFER IS CHECKED AGAINST ARE ONE NUMBER.**
///
/// The offer reads its size from `model-costs.json` (the brief's instruction) and the download is
/// verified against `model-pins.json`. Those are two files. If they ever disagree, the app asks
/// for one amount of disk and transfers another, and nothing in either file would look wrong.
#[test]
fn the_two_tables_agree_on_every_size() {
    let costs = richos_voice::hardware::Costs::load();
    let mut checked = 0;
    for (id, cost) in &costs.models {
        let Some(pin) = provision::pin_for(id) else { continue };
        assert_eq!(
            cost.disk_bytes, pin.bytes,
            "model-costs.json and model-pins.json disagree about how big {id} is"
        );
        checked += 1;
    }
    assert!(checked >= 4, "only {checked} models cross-checked — the tables stopped lining up");
}

/// **WHAT A MACHINE WITH NO WEIGHTS AT ALL ASKS FOR.** The whole offer hangs off this answer.
///
/// `retain_installed` drops every rung whose weights are absent, so on a fresh Mac the live ladder
/// is EMPTY and `resolve_live` returns the safe rung — `hardware.rs` says so in as many words:
/// *"The safe rung is NOT protected from filtering: if it is absent too, the caller is about to
/// meet `SttError::ModelNotFound`."* That id is what an offer must name, and it is `small.en`
/// rather than the `q5_0` the batch path defaults to: `q5_0` sits at the top of the live ladder
/// and is rejected on every machine measured so far.
#[test]
fn a_machine_with_no_weights_resolves_to_the_safe_rung_and_that_rung_is_pinned() {
    use richos_voice::hardware::{self, Basis, Machine};

    let mut costs = hardware::Costs::load();
    let before = costs.live_ladder.len();
    costs.retain_installed(|_| false); // nothing installed — a customer's fresh Mac
    assert!(before > 0 && costs.live_ladder.is_empty(), "the filter did not actually run");

    let machine = Machine::read();
    let r = hardware::resolve_live(&costs, &machine, |_| panic!("nothing to measure — the ladder is empty"));
    assert_eq!(r.basis, Basis::Unmeasured);
    assert_eq!(r.model_id, "small.en", "the safe rung is what a bare machine resolves to");
    assert!(
        provision::pin_for(&r.model_id).is_some(),
        "the one model a bare machine asks for must be one RichOS can verify"
    );
}

// ---------------------------------------------------------------------------------------------
// Refusals — each with its positive control.
// ---------------------------------------------------------------------------------------------

/// **THE CONTROL FOR EVERY REFUSAL BELOW.** Correct bytes, through the same driver, install and
/// verify — and the file does not exist under its real name until they have.
#[test]
fn correct_bytes_install_and_the_model_never_exists_under_its_real_name_until_verified() {
    let s = Scratch::new("success");
    let body = model_bytes(4096, 0x5a);
    let pin = pin_for_bytes("control.en", &body);
    let dest = s.path().join(&pin.file);
    let part = s.path().join(format!("{}.part", pin.file));

    // Mid-transfer: the part file is on disk and the real name is not.
    let plan = provision::plan_fetch(&pin, s.path(), Some(u64::MAX));
    let FetchPlan::Fetch { from, .. } = &plan else { panic!("expected a fetch, got {plan:?}") };
    let mut f = PartFile::open(&pin, &part, &dest, *from).expect("open");
    f.write(&body[..2048]).expect("write");
    assert!(part.exists(), "the transfer writes to <name>.part");
    assert!(!dest.exists(), "a half-written model must never carry a model's name");
    f.write(&body[2048..]).expect("write");

    match f.finish() {
        Outcome::Installed { path, bytes, sha256, resumed_from } => {
            assert_eq!(path, dest);
            assert_eq!(bytes, pin.bytes);
            assert_eq!(sha256, pin.sha256);
            assert_eq!(resumed_from, 0);
        }
        other => panic!("correct bytes must install: {other:?}"),
    }
    assert!(dest.exists(), "and only now does it get a model's name");
    assert!(!part.exists(), "the part file is renamed, not left behind");
    assert!(provision::inspect_file(&dest, &pin, true).hashed(), "and it verifies on a full hash");
}

/// A captive portal is caught BY NAME, and nothing is installed.
///
/// The sentence matters as much as the refusal: *"you are behind a wifi sign-in page"* sends him
/// to the wifi login, where *"expected 4,096 bytes, got 137"* sends him to support.
#[test]
fn a_captive_portal_is_caught_by_name_and_nothing_is_installed() {
    let s = Scratch::new("portal");
    let body = model_bytes(4096, 0x11);
    let pin = pin_for_bytes("portal.en", &body);
    let page = b"<!DOCTYPE html>\n<html><head><title>Sign in to WiFi</title></head><body>Please log in.</body></html>".to_vec();

    let out = drive(&pin, s.path(), &[page], None);
    let Outcome::Failed { finding } = out else { panic!("a login page must not install") };
    assert_eq!(finding.kind, Failure::HtmlBody);
    assert!(!finding.retryable(), "retrying a portal in a loop is not a fix");
    assert!(
        finding.ceo_message().contains("sign-in page"),
        "the CEO is told what actually happened: {}",
        finding.ceo_message()
    );
    assert!(finding.describe(&pin.file, false).contains("hotel"));
    assert!(!s.path().join(&pin.file).exists(), "nothing installed");
    assert!(!s.path().join(format!("{}.part", pin.file)).exists(), "and nothing kept");
}

/// A portal that pads its page to the EXACT pinned length is STILL caught by name.
///
/// This is why content beats size in the order of diagnosis. On size alone this body is perfect.
#[test]
fn a_portal_that_pads_to_the_exact_pinned_length_is_still_caught_by_name() {
    let s = Scratch::new("portal-padded");
    let body = model_bytes(4096, 0x22);
    let pin = pin_for_bytes("padded.en", &body);
    let mut page = b"<html><head><title>Sign in</title></head><body>".to_vec();
    page.resize(pin.bytes as usize, b' ');
    assert_eq!(page.len() as u64, pin.bytes, "the fixture must be exactly the pinned size");

    let Outcome::Failed { finding } = drive(&pin, s.path(), &[page], None) else {
        panic!("a padded login page must not install")
    };
    assert_eq!(finding.kind, Failure::HtmlBody, "named as a web page, not as a hash mismatch");
    assert!(!s.path().join(&pin.file).exists());
}

/// A right-size, right-magic, WRONG-CONTENT body is caught by the hash and DELETED.
///
/// Size and magic are both satisfiable by anyone who can serve bytes. This is the case the pin
/// table exists for, and the part file must not survive it in any form.
#[test]
fn a_right_size_right_magic_wrong_content_body_is_caught_by_the_hash_and_deleted() {
    let s = Scratch::new("tampered");
    let real = model_bytes(4096, 0x33);
    let pin = pin_for_bytes("tampered.en", &real);
    let tampered = model_bytes(4096, 0x34); // same length, same magic, different bytes
    assert_eq!(tampered.len(), real.len());
    assert_ne!(sha256_of(&tampered), pin.sha256);

    let Outcome::Failed { finding } = drive(&pin, s.path(), &[tampered], None) else {
        panic!("tampered bytes must not install")
    };
    assert_eq!(finding.kind, Failure::HashMismatch);
    assert!(!finding.retryable(), "a corrupted download is never retried automatically");
    assert!(!s.path().join(&pin.file).exists(), "nothing installed");
    assert!(
        !s.path().join(format!("{}.part", pin.file)).exists(),
        "a failed hash is DELETED, never quarantined where a resolver could read it"
    );
}

/// An interrupted transfer keeps its prefix, says so, and is retryable.
#[test]
fn an_interrupted_transfer_keeps_its_prefix_says_so_and_is_retryable() {
    let s = Scratch::new("interrupted");
    let body = model_bytes(4096, 0x44);
    let pin = pin_for_bytes("flaky.en", &body);
    let chunks = vec![body[..1024].to_vec(), body[1024..2048].to_vec(), body[2048..].to_vec()];

    let Outcome::Failed { finding } = drive(&pin, s.path(), &chunks, Some(2)) else {
        panic!("an interrupted transfer has not installed anything")
    };
    assert_eq!(finding.kind, Failure::Short);
    assert!(finding.retryable(), "truncation is what a flaky connection does — it resumes");
    assert!(finding.resumable, "the prefix was kept");
    assert!(
        finding.ceo_message().contains("picks up where it left off"),
        "he is told it resumes: {}",
        finding.ceo_message()
    );
    let part = s.path().join(format!("{}.part", pin.file));
    assert_eq!(provision::file_bytes(&part), 2048, "exactly what arrived is kept");
    assert!(!s.path().join(&pin.file).exists(), "and nothing carries a model's name");
}

/// A flaky connection RESUMES from the kept prefix rather than starting over — and the resumed
/// file verifies, which is the half that proves the resume was correct rather than merely cheap.
#[test]
fn a_flaky_connection_resumes_from_the_kept_prefix_and_the_result_still_verifies() {
    let s = Scratch::new("resume");
    let body = model_bytes(8192, 0x55);
    let pin = pin_for_bytes("resume.en", &body);

    // Attempt 1 dies at 3,000 bytes.
    let first = vec![body[..3000].to_vec()];
    let Outcome::Failed { finding } = drive(&pin, s.path(), &first, Some(1)) else {
        panic!("attempt 1 should not have installed")
    };
    assert!(finding.resumable);

    // Attempt 2 plans a RESUME, not a restart.
    let plan = provision::plan_fetch(&pin, s.path(), Some(u64::MAX));
    let FetchPlan::Fetch { dest, part, from, .. } = plan else { panic!("expected a fetch") };
    assert_eq!(from, 3000, "the second attempt starts where the first stopped");

    let mut f = PartFile::open(&pin, &part, &dest, from).expect("open");
    f.write(&body[3000..]).expect("write the remainder");
    match f.finish() {
        Outcome::Installed { bytes, sha256, resumed_from, .. } => {
            assert_eq!(bytes, pin.bytes);
            assert_eq!(sha256, pin.sha256, "the hash is taken over the WHOLE file, not the resumed tail");
            assert_eq!(resumed_from, 3000);
        }
        other => panic!("a correct resume must install: {other:?}"),
    }
}

/// A partial that is NOT a model prefix is RESTARTED, never resumed.
///
/// Otherwise real bytes get appended onto a captive portal's login page and produce a file that is
/// exactly the right length and hashes to nothing.
#[test]
fn a_partial_that_is_not_a_model_prefix_is_restarted_rather_than_resumed() {
    let s = Scratch::new("bad-prefix");
    let body = model_bytes(4096, 0x66);
    let pin = pin_for_bytes("badprefix.en", &body);
    let part = s.path().join(format!("{}.part", pin.file));
    std::fs::write(&part, b"<html><body>Sign in to continue</body></html>").expect("seed a portal page");

    let plan = provision::plan_fetch(&pin, s.path(), Some(u64::MAX));
    let FetchPlan::Fetch { from, .. } = plan else { panic!("expected a fetch") };
    assert_eq!(from, 0, "a non-model prefix is not worth resuming");
    assert!(!part.exists(), "and it is removed rather than appended to");

    // POSITIVE CONTROL for the same decision: a REAL prefix of the same length does resume.
    std::fs::write(&part, &body[..45]).expect("seed a real prefix");
    let plan = provision::plan_fetch(&pin, s.path(), Some(u64::MAX));
    let FetchPlan::Fetch { from, .. } = plan else { panic!("expected a fetch") };
    assert_eq!(from, 45, "a genuine prefix of identical length DOES resume");
}

/// A full disk is refused before a single request is made — and a disk with room is not.
#[test]
fn a_full_disk_is_refused_before_a_single_request_and_a_roomy_one_is_not() {
    let s = Scratch::new("disk");
    let body = model_bytes(4096, 0x77);
    let pin = pin_for_bytes("disk.en", &body);

    // The model plus 10%: 4,096 -> 4,506 (integer ceiling, so no float rounding decides it).
    assert_eq!(pin.required_free_bytes(), 4506);

    let plan = provision::plan_fetch(&pin, s.path(), Some(4505));
    let FetchPlan::Refused { finding } = plan else { panic!("a full disk must refuse, got {plan:?}") };
    assert_eq!(finding.kind, Failure::NoSpace);
    assert!(
        finding.ceo_message().contains("enough room"),
        "he is told it is about disk: {}",
        finding.ceo_message()
    );
    assert!(!s.path().join(format!("{}.part", pin.file)).exists(), "nothing was started");

    // POSITIVE CONTROL: one byte more and the same call proceeds.
    let plan = provision::plan_fetch(&pin, s.path(), Some(4506));
    assert!(matches!(plan, FetchPlan::Fetch { .. }), "exactly enough room must proceed");

    // AND: an unknown free-space answer is not a refusal. Refusing on an answer nobody gave would
    // take voice away from a machine that had room all along.
    let plan = provision::plan_fetch(&pin, s.path(), None);
    assert!(matches!(plan, FetchPlan::Fetch { .. }), "unknown free space is not a refusal");
}

/// A declared length that disagrees with the pin stops the transfer BEFORE the body.
///
/// The one check that can save a whole download on a metered or slow connection.
#[test]
fn a_declared_length_that_disagrees_with_the_pin_stops_the_transfer_before_the_body() {
    let body = model_bytes(4096, 0x88);
    let pin = pin_for_bytes("declared.en", &body);

    // Short, and the body looks like a model: reported as a size disagreement.
    let f = provision::check_declared(&pin, Some(3000), &GGML).expect("a short declaration must refuse");
    assert_eq!(f.kind, Failure::Short);

    // Short, and the body is a login page: the BETTER sentence wins.
    let f = provision::check_declared(&pin, Some(3104), b"<html><body>Sign in</body></html>")
        .expect("a portal must refuse");
    assert_eq!(f.kind, Failure::HtmlBody, "a portal is named as a portal, never as a byte count");

    // POSITIVE CONTROLS: the right length passes, and so does a server that declines to say.
    assert!(provision::check_declared(&pin, Some(pin.bytes), &GGML).is_none());
    assert!(provision::check_declared(&pin, None, &[]).is_none(), "no declaration is not an error");
}

/// An unpinned model never reaches the network at all.
#[test]
fn an_unpinned_model_never_reaches_the_network_at_all() {
    assert!(
        provision::pin_for("definitely-not-a-model").is_none(),
        "an unknown id must not produce a pin"
    );
    // And the classifier refuses outright when handed no pin, whatever the bytes look like.
    let v = provision::classify(true, 4096, Some(&GGML), None, None);
    assert_eq!(v.finding().map(|f| f.kind), Some(Failure::Unpinned));

    // POSITIVE CONTROL: a real id from the shipped table does produce one.
    assert!(provision::pin_for("small.en").is_some());
}

/// A model already installed and verified is not downloaded again; one already installed and
/// CORRUPT is removed rather than left where a resolver would find it.
#[test]
fn an_installed_model_is_reused_when_it_verifies_and_removed_when_it_does_not() {
    let s = Scratch::new("present");
    let body = model_bytes(4096, 0x99);
    let pin = pin_for_bytes("present.en", &body);
    let dest = s.path().join(&pin.file);

    std::fs::write(&dest, &body).expect("place a good copy");
    match provision::plan_fetch(&pin, s.path(), Some(u64::MAX)) {
        FetchPlan::AlreadyPresent { path } => assert_eq!(path, dest),
        other => panic!("a verified copy must not be re-downloaded: {other:?}"),
    }

    // Same length, same magic, wrong bytes — the case a cheap check waves through.
    std::fs::write(&dest, model_bytes(4096, 0x9a)).expect("place a corrupt copy");
    let plan = provision::plan_fetch(&pin, s.path(), Some(u64::MAX));
    assert!(matches!(plan, FetchPlan::Fetch { .. }), "a corrupt copy must be re-fetched");
    assert!(
        !dest.exists(),
        "and removed first — leaving it lets resolve_model pick a file we have just disproved"
    );
}

/// An empty body is empty, and is retryable — a connection that dropped before anything arrived.
#[test]
fn an_empty_body_is_named_as_empty_and_can_be_tried_again() {
    let s = Scratch::new("empty");
    let body = model_bytes(4096, 0xaa);
    let pin = pin_for_bytes("empty.en", &body);

    let Outcome::Failed { finding } = drive(&pin, s.path(), &[Vec::new()], None) else {
        panic!("an empty body installs nothing")
    };
    assert_eq!(finding.kind, Failure::Empty);
    assert!(finding.retryable());
    assert!(!s.path().join(&pin.file).exists());
}

/// A body LONGER than the pin is refused, and the part file is deleted rather than truncated.
#[test]
fn an_oversize_body_is_refused_and_not_trimmed_to_fit() {
    let s = Scratch::new("oversize");
    let body = model_bytes(4096, 0xbb);
    let pin = pin_for_bytes("oversize.en", &body);
    let too_much = model_bytes(5000, 0xbb);

    let Outcome::Failed { finding } = drive(&pin, s.path(), &[too_much], None) else {
        panic!("an oversize body installs nothing")
    };
    assert_eq!(finding.kind, Failure::Oversize);
    assert!(!finding.retryable(), "a different file does not become the right one on a second try");
    assert!(!s.path().join(format!("{}.part", pin.file)).exists(), "not kept as a prefix");
}

// ---------------------------------------------------------------------------------------------
// Where the model lands, and what the resolver looks for.
// ---------------------------------------------------------------------------------------------

/// **THE DOWNLOAD IS ONLY WORTH ANYTHING IF THE RESOLVER LOOKS WHERE IT LANDED.**
///
/// Asserted over the pure `model_search_dirs` rather than by setting `HOME` to a temporary
/// directory: that would prove it for one run on one machine and would race every other test in
/// this crate that reads the environment, where this proves it for every `HOME` there will be.
#[test]
fn the_directory_the_app_installs_into_is_one_the_resolver_searches() {
    let dirs = richos_voice::stt::model_search_dirs("/home/someone", None);
    let owned = Path::new("/home/someone").join(richos_voice::stt::RICHOS_MODELS_SUBDIR);
    assert!(
        dirs.contains(&owned),
        "provision.rs installs into {owned:?}, which resolve_model does not search: {dirs:?}"
    );

    // It comes before the three directories that belong to OTHER software, because it is the only
    // one whose contents this product downloaded and verified itself.
    let at = dirs.iter().position(|d| d == &owned).expect("present");
    let others = [".config/open-wispr/models", "Models/Whisper", ".cache/whisper.cpp"];
    for other in others {
        let p = Path::new("/home/someone").join(other);
        let other_at = dirs.iter().position(|d| d == &p).unwrap_or_else(|| panic!("{other} vanished from the walk"));
        assert!(at < other_at, "RichOS's own directory must precede {other}");
    }

    // An explicit override still wins outright.
    let dirs = richos_voice::stt::model_search_dirs("/home/someone", Some("/tmp/pinned"));
    assert_eq!(dirs[0], PathBuf::from("/tmp/pinned"), "RICHOS_MODEL_DIR is not second-guessed");
}

// ---------------------------------------------------------------------------------------------
// Pure rules, asserted directly.
// ---------------------------------------------------------------------------------------------

/// The sniffer names the shapes a real first run meets, and does not cry wolf on model bytes.
#[test]
fn the_sniffer_names_what_it_is_looking_at() {
    assert_eq!(provision::sniff_body(&GGML), Shape::Ggml);
    assert_eq!(provision::sniff_body(b"<!DOCTYPE html><html>"), Shape::Html);
    assert_eq!(provision::sniff_body(b"<meta http-equiv=\"refresh\" content=\"0\">"), Shape::Html);
    assert_eq!(provision::sniff_body(b"<html>"), Shape::Html);
    assert_eq!(provision::sniff_body(&[0x1f, 0x8b, 0x08, 0x00]), Shape::Gzip);
    assert_eq!(provision::sniff_body(b"PK\x03\x04"), Shape::Zip);
    assert_eq!(provision::sniff_body(b"Service Unavailable\n"), Shape::Text);
    assert_eq!(provision::sniff_body(&[]), Shape::Empty);
    assert_eq!(provision::sniff_body(&[0x00, 0x01, 0x02, 0xff, 0xfe]), Shape::Binary);

    // NOT a web page: a binary blob that happens to contain "<head" as part of a longer word.
    let mut blob = vec![0x00u8, 0xff, 0x01, 0xfe];
    blob.extend_from_slice(b"<headlong");
    blob.extend_from_slice(&[0x00, 0xff, 0x02, 0xfd]);
    assert_eq!(provision::sniff_body(&blob), Shape::Binary, "a markup lookalike is not markup");
}

/// The cheap check can only ever mean "nothing disqualifying was VISIBLE".
#[test]
fn a_cheap_pass_is_marked_as_a_cheap_pass() {
    let body = model_bytes(4096, 0xcc);
    let pin = pin_for_bytes("cheap.en", &body);

    let cheap = provision::classify(true, pin.bytes, Some(&GGML), None, Some(&pin));
    assert!(cheap.is_ok());
    assert!(!cheap.hashed(), "no caller may install on the strength of this");

    let full = provision::classify(true, pin.bytes, Some(&GGML), Some(&pin.sha256), Some(&pin));
    assert!(matches!(full, Verdict::Ok { hashed: true }));
}

/// Resume arithmetic, decided without a socket.
#[test]
fn the_resume_plan_is_decided_by_the_prefix_not_by_hope() {
    assert_eq!(provision::resume_plan(0, 4096, None).action, ResumeAction::Start);
    assert_eq!(provision::resume_plan(1000, 4096, Some(&GGML)).action, ResumeAction::Resume);
    assert_eq!(provision::resume_plan(1000, 4096, Some(&GGML)).from, 1000);
    assert_eq!(
        provision::resume_plan(4096, 4096, Some(&GGML)).action,
        ResumeAction::Restart,
        "a partial at or past the pinned size is garbage with a model's name on it"
    );
    assert_eq!(provision::resume_plan(1000, 4096, Some(b"<html>")).action, ResumeAction::Restart);
}

/// A 206's `Content-Length` is the REMAINING bytes. Getting this wrong would compare a tail
/// against a whole file and refuse every resume there is.
#[test]
fn a_partial_responses_declared_length_is_made_absolute_before_it_is_compared() {
    assert_eq!(provision::declared_total(206, Some(487_613_201), None, 1000), Some(487_614_201));
    assert_eq!(provision::declared_total(200, Some(487_614_201), None, 0), Some(487_614_201));
    assert_eq!(
        provision::declared_total(206, Some(1), Some("bytes 1000-487614200/487614201"), 1000),
        Some(487_614_201),
        "Content-Range is authoritative and already absolute"
    );
    assert_eq!(provision::declared_total(200, None, None, 0), None, "no answer is not an error");
}

/// Sizes a person can read. "0.0 MB" about 4 kB is a message that reports the wrong number.
#[test]
fn sizes_pick_their_unit_rather_than_forcing_one() {
    assert_eq!(provision::human(487_614_201), "487.6 MB");
    assert_eq!(provision::human(1_624_555_275), "1.62 GB");
    assert_eq!(provision::human(4_096), "4.1 kB");
    assert_eq!(provision::human(512), "512 bytes");
}

/// **NO PATHS, NO HASHES, NO FILENAMES IN WHAT THE CEO READS** — the rule `SttError::ceo_message`
/// already set. The detail belongs in `describe`, on stderr, where it is useful.
#[test]
fn the_ceo_facing_sentences_never_carry_an_implementation_detail() {
    let body = model_bytes(4096, 0xdd);
    let pin = pin_for_bytes("private.en", &body);
    let kinds = [
        provision::classify(true, 4096, Some(b"<html><body>hi</body></html>"), None, Some(&pin)),
        provision::classify(true, 4096, Some(&GGML), Some(&"0".repeat(64)), Some(&pin)),
        provision::classify(true, 100, Some(&GGML), None, Some(&pin)),
        provision::classify(true, 9999, Some(&GGML), None, Some(&pin)),
        provision::classify(false, 0, None, None, Some(&pin)),
        Verdict::Bad(provision::disk_preflight(Some(1), 4506).expect("a full disk")),
    ];
    let mut seen = 0;
    for v in &kinds {
        let f = v.finding().expect("these are all failures");
        let s = f.ceo_message();
        assert!(!s.contains(".bin"), "a filename reached the CEO: {s}");
        assert!(!s.contains("sha256"), "a hash reached the CEO: {s}");
        assert!(!s.contains('/'), "a path reached the CEO: {s}");
        assert!(!s.is_empty());
        seen += 1;
    }
    assert_eq!(seen, 6, "every failure kind under test produced a sentence");

    // POSITIVE CONTROL: the engineer's sentence DOES carry the detail, so the two are genuinely
    // different vocabularies rather than one sentence used twice.
    let v = provision::classify(true, 4096, Some(&GGML), Some(&"0".repeat(64)), Some(&pin));
    let d = v.finding().expect("mismatch").describe(&pin.file, false);
    assert!(d.contains(".bin") && d.contains("sha256"), "the record keeps what the CEO does not need: {d}");
}
