//! Real Rust phone HTTP/auth/SSE, durable intake, Spine and gated timeline.
//! Only cognition and the Tauri AppHandle adapter are replaced. No model credentials,
//! production pairing, login keychain, microphone or desktop window are accessed.
//! Started by `mobile.mjs lab mac`; this module exists only in the Rust test binary.
use crate::phone::{
    self,
    api_base::ApiBaseDesk,
    assets::PhoneApp,
    ca::PhoneCa,
    device::DeviceDesk,
    listen::{tls_config, Listener},
    names::LocalNames,
    routes::{Accepted, Bridge, Channel, StopSwitch},
    stream::{PhoneHub, PhoneLiveEmitter},
};
use richos_core::{
    cognition::MockLeaseFactory,
    entity::{Entity, EntityId, EntityRegistry},
    ledger::Ledger,
    spine::Spine,
    steering::TurnControl,
};
use serde_json::{json, Value};
use std::{
    net::{IpAddr, Ipv4Addr},
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

// Test-only storage survives an isolated process restart. Production uses Keychain.
struct LabSecrets { directory: PathBuf }
impl phone::secrets::SecretStore for LabSecrets {
    fn get(&self, account: &str) -> Result<Option<Vec<u8>>, phone::PhoneError> {
        let path = self.directory.join(format!("secret-{}",phone::hex(&phone::sha256(account.as_bytes()))));
        match std::fs::read(path) { Ok(bytes)=>Ok(Some(bytes)), Err(e) if e.kind()==std::io::ErrorKind::NotFound=>Ok(None), Err(e)=>Err(e.into()) }
    }
    fn put(&self, account: &str, bytes: &[u8]) -> Result<(), phone::PhoneError> {
        use std::os::unix::fs::OpenOptionsExt;
        use std::io::Write;
        let path = self.directory.join(format!("secret-{}",phone::hex(&phone::sha256(account.as_bytes()))));
        let mut file = std::fs::OpenOptions::new().create(true).truncate(true).write(true).mode(0o600).open(path)?;
        file.write_all(bytes)?; file.sync_all()?; Ok(())
    }
    fn delete(&self, account: &str) -> Result<(), phone::PhoneError> {
        let path = self.directory.join(format!("secret-{}",phone::hex(&phone::sha256(account.as_bytes()))));
        match std::fs::remove_file(path) { Ok(())=>Ok(()), Err(e) if e.kind()==std::io::ErrorKind::NotFound=>Ok(()), Err(e)=>Err(e.into()) }
    }
}

struct IsolatedBridge {
    spine: Arc<Mutex<Spine>>,
    control: TurnControl,
    thread: String,
    entity: EntityId,
    workers: Mutex<Vec<std::thread::JoinHandle<()>>>,
}
impl Bridge for IsolatedBridge {
    fn submit_text(&self, thread_id: Option<&str>, text: &str) -> Result<Accepted, String> {
        let thread = thread_id.unwrap_or(&self.thread);
        if thread != self.thread {
            return Err("Unknown isolated conversation".into());
        }
        let record = self
            .control
            .submit_from_channel(thread, Some(self.entity.clone()), text, "phone")
            .map_err(|e| e.to_string())?;
        let spine = Arc::clone(&self.spine);
        self.workers
            .lock()
            .unwrap()
            .push(std::thread::spawn(move || {
                spine
                    .lock()
                    .unwrap()
                    .poll_intake()
                    .expect("isolated phone intake drain");
            }));
        Ok(Accepted {
            message_id: format!("intake_{}", record.id()),
            thread_id: thread.into(),
            at: phone::now_millis(),
        })
    }
    fn snapshot(&self, thread_id: Option<&str>) -> Result<Value, String> {
        crate::timeline_view::timeline_payload(
            &*self.spine.lock().unwrap(),
            thread_id.unwrap_or(&self.thread),
        )
    }
    fn current_thread(&self) -> Option<(String, String)> {
        Some((self.thread.clone(), "Isolated mobile check".into()))
    }
    fn threads(&self) -> Vec<(String, String)> {
        vec![self.current_thread().unwrap()]
    }
}

#[test]
#[ignore = "CLI-owned isolated server; requires an explicit scratch directory and stop signal"]
fn serve() {
    let dir = PathBuf::from(
        std::env::var_os("RICHOS_MOBILE_MAC_DIR").expect("CLI must supply isolated scratch"),
    );
    let dir = dir.canonicalize().unwrap();
    assert!(dir.starts_with("/Volumes/E1TB/"));
    let restarting = std::env::var("RICHOS_MOBILE_MAC_RESTART").as_deref() == Ok("1");
    if restarting {
        assert_eq!(std::fs::read_to_string(dir.join("lab-owner")).unwrap(), "richos-mobile-isolated-v1");
    } else {
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(),0,"never reuse an existing data directory");
        std::fs::write(dir.join("lab-owner"),"richos-mobile-isolated-v1").unwrap();
    }
    let connect_token_file = std::env::var_os("RICHOS_MOBILE_CONNECT_TOKEN_FILE");
    let managed = connect_token_file.is_some();
    let origin = std::env::var("RICHOS_MOBILE_MAC_ORIGIN").expect("explicit public test origin");
    let names = LocalNames {
        host: "Mobile integration".into(),
        bonjour: "localhost".into(),
        addresses: vec![IpAddr::V4(Ipv4Addr::LOCALHOST)],
    };
    let ca = PhoneCa::open(&dir, &LabSecrets {directory:dir.clone()}, names).unwrap();
    let mut spine = Spine::new(Ledger::open(dir.join("ledger.jsonl")).unwrap());
    let root = dir.to_str().unwrap();
    spine.set_entity_registry(
        EntityRegistry::new(vec![
            Entity::new("mobile-check", "Mobile check", &[root]).unwrap()
        ])
        .unwrap(),
    );
    let entity = EntityId::parse("mobile-check").unwrap();
    let thread = if restarting { std::fs::read_to_string(dir.join("lab-thread")).unwrap() }
        else { let thread=spine.create_thread("Isolated mobile check",&entity).unwrap();
            std::fs::write(dir.join("lab-thread"),&thread).unwrap(); thread };
    spine.switch_thread(&thread).unwrap();
    // Empty scripted replies make the existing test provider emit `ack: <fresh message>`.
    spine.set_lease_factory(Box::new(MockLeaseFactory::new(vec![])));
    let control = TurnControl::open(dir.join("intake.jsonl")).unwrap();
    spine.set_turn_control(control.clone());
    let hub = PhoneHub::new();
    spine.set_live_observer(Box::new(PhoneLiveEmitter::new(Arc::clone(&hub))));
    let bridge = Arc::new(IsolatedBridge {
        spine: Arc::new(Mutex::new(spine)),
        control,
        thread,
        entity,
        workers: Mutex::new(vec![]),
    });
    let devices = Arc::new(DeviceDesk::open(&dir).unwrap());
    let channel = Arc::new(Channel {
        devices: Arc::clone(&devices),
        rejected: StopSwitch::unwired(),
        api_base: Arc::new(ApiBaseDesk::only(&origin)),
        hub,
        bridge: bridge.clone(),
        assets: PhoneApp::embedded(),
        vapid_public: phone::push::VapidKey::generate()
            .unwrap()
            .application_server_key(),
        fingerprint_hex: ca.fingerprint_hex(),
        pairing_path: Mutex::new(if managed { phone::device::PairedVia::CONNECT } else { phone::device::PairedVia::TAILNET }),
    });
    let mut listener = if managed {
        Listener::start_connect(channel, phone::connect::PORT).unwrap()
    } else {
        Listener::start(channel, tls_config(&ca.leaf_der,&ca.leaf_key_pkcs8).unwrap(), &[IpAddr::V4(Ipv4Addr::LOCALHOST)],0).unwrap()
    };
    let _connector = connect_token_file.map(|file| {
        let path = PathBuf::from(file).canonicalize().unwrap();
        assert!(path.starts_with("/Volumes/E1TB/"));
        let token = std::fs::read_to_string(path).unwrap();
        let helper = std::env::var_os("RICHOS_CONNECT_HELPER").expect("explicit test helper");
        phone::connect::supervisor::Supervisor::start(&PathBuf::from(helper),token).unwrap()
    });
    if !devices.is_paired() { devices.open_pairing().unwrap(); }
    let ready = json!({"protocol":if managed {"http"} else {"https"},"port":listener.bound[0].port(), "ca":dir.join("phone/ca.crt"),
        "pairLink":devices.pairing_window().map(|window|format!("{origin}/#pair={}",window.code)),
        "words":ca.fingerprint_words().join(" "), "replyMarker":"ack: ", "pid":std::process::id()});
    std::fs::write(dir.join("ready.new"), ready.to_string()).unwrap();
    std::fs::rename(dir.join("ready.new"), dir.join("ready.json")).unwrap();
    let deadline = Instant::now() + Duration::from_secs(3600);
    while !dir.join("stop").exists() && Instant::now() < deadline {
        if let Ok(payload) = bridge.snapshot(None) {
            std::fs::write(dir.join("timeline.new"), payload.to_string()).unwrap();
            std::fs::rename(dir.join("timeline.new"), dir.join("timeline.json")).unwrap();
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    listener.stop();
    for worker in bridge.workers.lock().unwrap().drain(..) {
        worker.join().unwrap();
    }
    std::fs::write(
        dir.join("timeline.json"),
        bridge.snapshot(None).unwrap().to_string(),
    )
    .unwrap();
}
