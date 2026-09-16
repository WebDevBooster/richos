use richos_core::loro::{CorpusPaths, LoroInstall, ToolsSource};
use std::path::{Path, PathBuf};
use std::process::Command;

struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("richos delivered loro {}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(root.join("corpus/ceo/records")).unwrap();
        Self(root)
    }
    fn paths(&self, engine: PathBuf) -> CorpusPaths {
        CorpusPaths {
            home: Some(self.0.join("home")),
            env_corpus: Some(self.0.join("corpus").display().to_string()),
            engine_dir: Some(engine),
            // Source conformance uses an explicit developer runtime. Installed
            // delivery is checked separately against the complete runtime asset.
            env_node: Some(richos_core::loro::resolve_node_bin(&CorpusPaths {
                path_var: std::env::var("PATH").ok(), ..Default::default()
            })),
            path_var: std::env::var("PATH").ok(),
            ..Default::default()
        }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) { let _ = std::fs::remove_dir_all(&self.0); }
}

fn engine_source() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).ancestors().nth(3).unwrap().join("engine")
}

fn cli(install: &LoroInstall, writer: bool, args: &[&str]) -> serde_json::Value {
    let tools = install.tools();
    let program = if writer { tools.write_bin() } else { tools.context_bin() };
    let out = Command::new(tools.node()).arg(program).args(args)
        .arg("--corpus").arg(install.root().path())
        .env_remove("LORO_ROOT").env_remove("LORO_CORPUS").output().unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    serde_json::from_slice(&out.stdout).unwrap()
}

#[test]
fn selected_engine_reads_writes_and_keeps_the_superseded_reference() {
    let fixture = Fixture::new();
    let paths = fixture.paths(engine_source());
    let (install, _) = LoroInstall::locate(&paths).unwrap();
    let install = install.unwrap();
    assert_eq!(install.tools_source(), ToolsSource::EngineComponent);
    assert_eq!(install.tools().dir(), engine_source().join("loro"));
    cli(&install, true, &["append", "--id", "delivery", "--kind", "decision", "--scope", "org-shared",
        "--body", "The fictional depot ships replacement parts by the morning truck.", "--json"]);
    let slice = cli(&install, false, &["compile", "--topic", "replacement parts delivery truck"]);
    assert!(slice["items"].as_array().unwrap().iter().any(|r| r["ref"] == "rec:ceo/records/delivery"));
    cli(&install, true, &["supersede", "--ref", "rec:ceo/records/delivery", "--id", "delivery-revised",
        "--kind", "decision", "--scope", "org-shared", "--body", "The fictional depot now ships by the afternoon truck.",
        "--why", "The fictional timetable changed.", "--json"]);
    let old = cli(&install, false, &["fetch", "--ref", "rec:ceo/records/delivery"]);
    assert_eq!(old["status"], "superseded");
    let new = cli(&install, false, &["fetch", "--ref", "rec:ceo/records/delivery-revised"]);
    assert!(new["text"].as_str().unwrap().contains("afternoon"));
}

#[test]
fn desktop_corrections_preserve_the_company_ceo_and_unfiled_partitions() {
    use richos_core::correction::{CliLoroWriter, LoroWriteBackend, ProposedWrite};
    let fixture = Fixture::new();
    let (install, _) = LoroInstall::locate(&fixture.paths(engine_source())).unwrap();
    let install = install.unwrap();
    for company in ["alpha", "beta"] {
        cli(&install, true, &["create-company", "--id", company, "--json"]);
    }
    let writer = CliLoroWriter::from_install(&install);
    for (partition, prefix) in [("alpha", "companies/alpha/records"), ("ceo", "ceo/records"), ("unfiled", "ceo/unfiled")] {
        let old_id = format!("delivery-{partition}");
        let new_id = format!("delivery-{partition}-corrected");
        cli(&install, true, &["append", "--partition", partition, "--id", &old_id, "--kind", "fact",
            "--scope", "org-shared", "--body", "Fictional delivery uses the morning truck.", "--json"]);
        let old_ref = format!("rec:{prefix}/{old_id}");
        let new_ref = format!("rec:{prefix}/{new_id}");
        let proposal = ProposedWrite::Supersede { record_ref:old_ref.clone(), new_id,
            kind:"fact".into(), scope:Some("org-shared".into()), body:"Fictional delivery uses the afternoon truck.".into() };
        writer.preview(&proposal, "Fictional timetable correction").unwrap();
        // A preview must not publish the replacement or retire the original.
        assert_eq!(cli(&install, false, &["fetch", "--ref", &old_ref])["status"], "current");
        writer.commit(&proposal, "Fictional timetable correction").unwrap();
        assert_eq!(cli(&install, false, &["fetch", "--ref", &old_ref])["supersededBy"], new_ref);
        let replacement = cli(&install, false, &["fetch", "--ref", &new_ref]);
        assert_eq!(replacement["company"], if partition == "alpha" {serde_json::json!("alpha")} else {serde_json::Value::Null});
        if partition == "alpha" {
            let slice = cli(&install, false, &["compile", "--company", "beta", "--topic", "Fictional delivery afternoon truck"]);
            assert!(slice["items"].as_array().unwrap().iter().all(|item| item["ref"] != new_ref));
            assert!(!slice["text"].as_str().unwrap().contains("Fictional delivery uses the afternoon truck."));
        }
    }
}

#[test]
fn selected_engine_missing_loro_does_not_borrow_an_old_tools_install() {
    let fixture = Fixture::new();
    let paths = fixture.paths(fixture.0.join("missing-engine"));
    let decoy = richos_core::provision::compiler_install_dir(paths.home.as_ref().unwrap());
    std::fs::create_dir_all(decoy.join("bin")).unwrap();
    for entry in ["loro-context.mjs", "loro-write.mjs"] {
        std::fs::write(decoy.join("bin").join(entry), "// stale compiler").unwrap();
    }
    let error = LoroInstall::locate(&paths).err().expect("an explicit engine must fail closed");
    assert!(error.to_string().contains("selected engine"));
}

#[test]
fn selected_engine_node_never_falls_back_to_a_host_runtime() {
    let paths = CorpusPaths { engine_dir: Some(PathBuf::from("/fictional/selected-engine")),
        path_var: Some("/opt/homebrew/bin:/usr/bin".into()), ..Default::default() };
    assert_eq!(richos_core::loro::resolve_node_bin(&paths), "/fictional/selected-engine/runtime/bin/node");
}
