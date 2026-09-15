//! Real startup/exec coverage without a webview, release signing or live app launch.
//! Both fixture binaries import the shipping activation and update_startup modules.
#![cfg(target_os = "macos")]
use flate2::{write::GzEncoder, Compression};
use richos_user_update::{stage_verified, StartupLease};
use std::{
    fs, io,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::{Child, Command},
    time::{Duration, Instant},
};

fn build_fixture(work: &Path, version: &str) -> PathBuf {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source = manifest.join("../../src-tauri/src").canonicalize().unwrap();
    let project = work.join("fixture");
    fs::create_dir_all(project.join("src")).unwrap();
    fs::write(project.join("Cargo.toml"), format!("[package]\nname=\"richos-update-fixture\"\nversion={version:?}\nedition=\"2021\"\n[workspace]\n[dependencies]\nrichos-user-update={{path={:?}}}\nserde_json=\"1\"\n", manifest)).unwrap();
    fs::write(project.join("src/main.rs"), format!(r#"
#[path={activation:?}] mod activation;
#[path={startup:?}] mod update_startup;
fn main() {{
    if update_startup::identity_probe(env!("CARGO_PKG_VERSION")) {{ return; }}
    let _lease = match update_startup::prepare(env!("CARGO_PKG_VERSION")) {{
        Ok(lease) => lease,
        Err(error) => {{ eprintln!("startup refused: {{error}}"); std::process::exit(42); }}
    }};
    let home = std::path::PathBuf::from(std::env::var_os("HOME").unwrap());
    let proof = serde_json::json!({{"version":env!("CARGO_PKG_VERSION"),"pid":std::process::id(),"hint":std::env::var_os("RICHOS_UPDATE_SESSION_FD").is_some(),"args":std::env::args().skip(1).collect::<Vec<_>>()}});
    std::fs::write(home.join("runtime.json"), serde_json::to_vec(&proof).unwrap()).unwrap();
    if std::env::var_os("RICHOS_FIXTURE_HOLD").is_some() {{
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
        while !home.join("release").exists() {{
            assert!(std::time::Instant::now() < deadline, "fixture release timed out");
            std::thread::sleep(std::time::Duration::from_millis(10));
        }}
    }}
}}
"#, activation=source.join("activation.rs"), startup=source.join("update_startup.rs"))).unwrap();
    let target = manifest.join("target/startup-fixtures");
    let out = Command::new(env!("CARGO"))
        .args(["build", "--offline", "--quiet", "--manifest-path"])
        .arg(project.join("Cargo.toml"))
        .env("CARGO_TARGET_DIR", &target)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "fixture build failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let binary = work.join(format!("fixture-{version}"));
    fs::copy(target.join("debug/richos-update-fixture"), &binary).unwrap();
    binary
}
fn info(version: &str) -> Vec<u8> {
    format!(r#"<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.richos.app</string><key>CFBundleShortVersionString</key><string>{version}</string><key>CFBundleExecutable</key><string>fixture</string></dict></plist>"#).into_bytes()
}
fn bundle(root: &Path, version: &str, binary: &Path) -> PathBuf {
    fs::create_dir_all(root.join("Contents/MacOS")).unwrap();
    fs::write(root.join("Contents/Info.plist"), info(version)).unwrap();
    let exe = root.join("Contents/MacOS/fixture");
    fs::copy(binary, &exe).unwrap();
    fs::set_permissions(&exe, fs::Permissions::from_mode(0o755)).unwrap();
    exe
}
fn archive(version: &str, binary: &Path) -> Vec<u8> {
    let mut builder = tar::Builder::new(GzEncoder::new(Vec::new(), Compression::default()));
    for (path, bytes, mode) in [
        ("RichOS.app/Contents/Info.plist", info(version), 0o644),
        (
            "RichOS.app/Contents/MacOS/fixture",
            fs::read(binary).unwrap(),
            0o755,
        ),
    ] {
        let mut header = tar::Header::new_gnu();
        header.set_mode(mode);
        header.set_size(bytes.len() as u64);
        header.set_cksum();
        builder.append_data(&mut header, path, &bytes[..]).unwrap();
    }
    builder.into_inner().unwrap().finish().unwrap()
}
fn command(exe: &Path, home: &Path) -> Command {
    let mut command = Command::new(exe);
    command
        .env("HOME", home)
        .env_remove("RICHOS_TEST_DATA_DIR")
        .env_remove("RICHOS_UPDATE_SESSION_FD")
        .env_remove("RICHOS_FIXTURE_HOLD");
    command
}
fn proof(home: &Path, child: &mut Child) -> serde_json::Value {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Ok(bytes) = fs::read(home.join("runtime.json")) {
            if let Ok(value) = serde_json::from_slice(&bytes) {
                return value;
            }
        }
        assert!(
            child.try_wait().unwrap().is_none(),
            "fixture exited before runtime proof"
        );
        assert!(Instant::now() < deadline, "startup timed out");
        std::thread::sleep(Duration::from_millis(10));
    }
}
fn new_home(work: &Path, name: &str) -> PathBuf {
    let path = work.join(name);
    fs::create_dir(&path).unwrap();
    path
}

#[test]
fn shipping_startup_activates_and_execs_with_lifetime_exclusion() {
    let temporary = tempfile::tempdir().unwrap();
    let work = temporary.path().canonicalize().unwrap();
    let old = build_fixture(&work, "1.0.0");
    let new = build_fixture(&work, "2.0.0");
    let newer = build_fixture(&work, "4.0.0");
    let home = new_home(&work, "home");
    let original = bundle(&home.join("Original.app"), "1.0.0", &old);
    let original_bytes = fs::read(&original).unwrap();
    stage_verified(&home, &archive("2.0.0", &new), "2.0.0").unwrap();
    assert!(
        !home.join("Applications/RichOS.app").exists(),
        "live staging published prematurely"
    );
    let mut child = command(&original, &home)
        .env("RICHOS_FIXTURE_HOLD", "1")
        .arg("preserved-argument")
        .spawn()
        .unwrap();
    let value = proof(&home, &mut child);
    assert_eq!(value["version"], "2.0.0");
    assert_eq!(value["pid"], child.id());
    assert_eq!(value["hint"], false);
    assert_eq!(value["args"][0], "preserved-argument");
    assert_eq!(
        fs::read(&original).unwrap(),
        original_bytes,
        "original bundle was modified"
    );
    let mut observer = StartupLease::acquire(&home).unwrap();
    assert!(!observer.can_activate());
    // A newly staged update cannot replace the bundle used by the live fixture runtime.
    assert!(stage_verified(&home, &archive("3.0.0", &new), "3.0.0").is_err());
    stage_verified(&home, &archive("4.0.0", &newer), "4.0.0").unwrap();
    assert_eq!(
        richos_user_update::activate_prepared_above(&mut observer, "2.0.0")
            .unwrap_err()
            .kind(),
        io::ErrorKind::WouldBlock
    );
    drop(observer);
    fs::write(home.join("release"), b"exit").unwrap();
    assert!(child.wait().unwrap().success());
    // The mismatched package was rejected before publication. The subsequent valid
    // package activates at the next normal launch with the same production bootstrap.
    fs::remove_file(home.join("runtime.json")).unwrap();
    assert!(command(
        &home.join("Applications/RichOS.app/Contents/MacOS/fixture"),
        &home
    )
    .status()
    .unwrap()
    .success());
    let activated: serde_json::Value =
        serde_json::from_slice(&fs::read(home.join("runtime.json")).unwrap()).unwrap();
    assert_eq!(activated["version"], "4.0.0");

    let external = new_home(&work, "external-newer");
    let external_exe = bundle(&external.join("External.app"), "4.0.0", &newer);
    stage_verified(&external, &archive("2.0.0", &new), "2.0.0").unwrap();
    assert!(command(&external_exe, &external)
        .status()
        .unwrap()
        .success());
    assert!(
        !external.join("Applications/RichOS.app").exists(),
        "stale staging downgraded newer external build"
    );
    let current: serde_json::Value =
        serde_json::from_slice(&fs::read(external.join("runtime.json")).unwrap()).unwrap();
    assert_eq!(current["version"], "4.0.0");
    assert!(
        richos_user_update::staged(&external).unwrap().is_none(),
        "obsolete readiness would hide all future server checks"
    );

    let isolated = new_home(&work, "debug-isolation");
    let isolated_exe = bundle(&isolated.join("Fixture.app"), "1.0.0", &old);
    assert!(command(&isolated_exe, &isolated)
        .env("RICHOS_TEST_DATA_DIR", isolated.join("test-data"))
        .status()
        .unwrap()
        .success());
    assert!(
        !isolated.join("Applications").exists(),
        "debug data isolation touched updater namespace"
    );
}
