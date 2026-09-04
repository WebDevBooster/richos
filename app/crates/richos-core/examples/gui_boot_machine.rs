//! A COMPLETE MACHINE FOR A LAUNCH THAT HAS NO ENVIRONMENT — built out of the product's own
//! provisioning, so it cannot describe a shape the product does not create.
//!
//! `gui-boot.test.sh` boots the shipped binary under launchd's environment (`HOME`, `USER`,
//! `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, `cwd=/`) and asserts that no line of the boot log
//! reports a configuration it could not find. That assertion is only worth anything against
//! a machine on which every configuration *is* there: on an empty `$HOME` the boot says
//! "no corpus configured" and it is telling the truth. So this program builds the healthy
//! side of the two-sided check.
//!
//! # It cannot reach the CEO's corpus, by construction
//!
//! Everything it creates hangs off the scratch `$HOME` given as `argv[1]`. It READS one
//! thing from the real machine — the directory that already holds this machine's loro
//! compiler — and copies from it. `provision` refuses a target that already looks like a
//! corpus, refuses a non-empty target, and refuses anything inside a product checkout, so
//! there is no argument to this program that could point it at `~/ab/richos-hq`.
//!
//! # What it makes, and why each one is here
//!
//! | thing | why the boot needs it |
//! |---|---|
//! | a provisioned corpus at `<home>/RichOS/corpus` + its pointer | `loro Tier C` resolves a corpus and a compiler; without it the boot says `no corpus configured` |
//! | the loro tools, copied into `<home>/Library/Application Support/RichOS/loro-tools` | `provision` installs them; the READ half and the WRITE half both resolve through them |
//! | a saved company in `config.json` | `boot_entity` step 2. `cwd=/` owns no entity, so without a saved choice the boot says `no company resolved` |
//! | `<home>/.claude/richos-engine` (the shell writes it) | `engine.rs` candidate 6 — the one an installed `.app` on a customer Mac reaches |
//! | `<home>/.local/bin/claude` (the shell writes it) | `resolve_claude_bin` step 2 — without it there is no compute lease |
//!
//! # The compiler source is GIVEN, and that is deliberate
//!
//! The RichOS product repository ships no `loro/` (`provision.rs`'s own module doc says so),
//! so a scratch corpus can only get a compiler by copying one that already exists on this
//! machine. The obvious way to find it is [`LoroInstall::locate`] — the same call the boot
//! makes.
//!
//! **That was tried and it is wrong, and the red run proved it.** With the pre-`c179cc1`
//! read path put back, `LoroInstall::locate` resolves nothing, so the fixture could not
//! build a machine and the suite exited 2 saying *"this machine has no loro compiler to
//! copy"*. That is red, so nothing failed open — but it is red with the WRONG DIAGNOSIS,
//! and a check that sends its reader hunting the wrong thing is only marginally better than
//! one that says nothing. **A fixture must not be built by the component it tests.**
//!
//! So the source arrives as `argv[2]`, found by `gui-launch.sh` out of facts that do not go
//! through any Rust resolution. All this program does with it is check it with
//! [`compiler_looks_valid`] — a pure predicate, not a resolver — and refuse if it is not a
//! loro checkout.
//!
//! ```text
//! cargo run -q -p richos-core --example gui_boot_machine -- <scratch-home> <loro-checkout>
//! ```

use richos_core::config::ConfigStore;
use richos_core::entity::EntityRegistry;
use richos_core::provision::{
    compiler_looks_valid, provision, CompanyOutcome, CompilerOutcome, ProvisionRequest,
};
use std::path::{Path, PathBuf};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let (Some(home), Some(compiler_source)) =
        (args.get(1).map(PathBuf::from), args.get(2).map(PathBuf::from))
    else {
        eprintln!("usage: gui_boot_machine <scratch-home> <loro-checkout>");
        std::process::exit(64);
    };
    if !home.is_absolute() {
        eprintln!("gui_boot_machine: <scratch-home> must be absolute, got {}", home.display());
        std::process::exit(64);
    }

    // ---- the compiler source, checked but NOT resolved here ----------------------------
    // `compiler_looks_valid` is the same predicate `LoroTools::locate` applies, so a source
    // that passes here produces an install that passes there. It is a predicate and not a
    // search: this program cannot be made to look somewhere the caller did not name, and it
    // therefore cannot be broken by breaking the resolver it exists to test.
    if !compiler_looks_valid(&compiler_source) {
        eprintln!(
            "gui_boot_machine: REFUSING — {} is not a loro checkout (wants bin/loro-context.mjs \
             and bin/loro-write.mjs). Provisioning a corpus with no compiler would hand the \
             check a machine that is missing the thing it is checking for.",
            compiler_source.display()
        );
        std::process::exit(3);
    }
    println!("compiler source : {}", compiler_source.display());

    // ---- the corpus, created exactly as first-run provisioning creates one -------------
    let registry = demo_registry(&home);
    let companies: Vec<(String, String)> =
        registry.entities().iter().map(|e| (e.id.to_string(), e.display_name.clone())).collect();
    let report = match provision(&ProvisionRequest {
        target: home.join("RichOS").join("corpus"),
        home: Some(home.clone()),
        companies,
        compiler_source: Some(compiler_source),
    }) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("gui_boot_machine: provisioning refused: {e}");
            std::process::exit(1);
        }
    };
    println!("corpus          : {}", report.root.display());
    println!("pointer         : {:?}", report.pointer.as_ref().map(|p| p.display().to_string()));

    // A half-built machine is worse than none: the check would read its own fixture's gap
    // as the product's defect. Every part of this is asserted, loudly, right here.
    match &report.compiler {
        CompilerOutcome::Installed { dest, files, .. } => {
            println!("loro tools      : {} ({files} files)", dest.display())
        }
        CompilerOutcome::AlreadyPresent(dest) => println!("loro tools      : {} (already)", dest.display()),
        other => {
            eprintln!("gui_boot_machine: the compiler was not installed ({other:?}) — refusing to \
                       hand the check a machine that is missing the thing it is checking for");
            std::process::exit(1);
        }
    }
    let unmade: Vec<&CompanyOutcome> = report.companies.iter().filter(|c| !c.created).collect();
    if !unmade.is_empty() {
        for c in &unmade {
            eprintln!(
                "gui_boot_machine: partition {} was not created — {}",
                c.id,
                c.problem.as_deref().unwrap_or("no reason given")
            );
        }
        std::process::exit(1);
    }
    println!("partitions      : {}", report.companies.len());

    // ---- the saved company answer -----------------------------------------------------
    // Written through `ConfigStore`, not as hand-built JSON, so the file this fixture leaves
    // behind is the file the app writes and cannot drift from its schema. The entity is READ
    // OFF THE REGISTRY rather than typed, for the reason `boot_entity`'s operator line is:
    // a hand-written id becomes wrong the day the registry changes.
    let Some(entity) = registry.entities().first().map(|e| e.id.clone()) else {
        eprintln!("gui_boot_machine: the entity registry is empty — nothing to save");
        std::process::exit(1);
    };
    let config_path = app_data_dir(&home).join("config.json");
    if let Some(parent) = config_path.parent() {
        std::fs::create_dir_all(parent).expect("the app data directory");
    }
    let mut config = ConfigStore::open(&config_path).expect("open the scratch config store");
    config.set_entity(&entity).expect("save the company answer");
    println!("saved company   : {entity} in {}", config_path.display());
}

/// `$HOME/Library/Application Support/com.richos.app` — where Tauri's `app_data_dir()` lands
/// for this bundle identifier, and therefore where the app will look for `config.json`.
fn app_data_dir(home: &Path) -> PathBuf {
    home.join("Library").join("Application Support").join("com.richos.app")
}

/// THE COMPANY THIS DEMO REGISTERS — invented, and belonging to nobody.
///
/// Before 2026-09-04 this was `EntityRegistry::ceos_companies()`: a `const` table of the
/// CEO's six real companies that shipped inside the binary and was the registry of every
/// install. The registry is per-user now (`entity.rs` rule 4) and a fresh machine has none,
/// so a demo that needs a company to exist REGISTERS one, exactly as a first-run user does.
fn demo_registry(home: &std::path::Path) -> EntityRegistry {
    let mut registry = EntityRegistry::empty();
    registry
        .register(
            richos_core::entity::Entity::try_new(
                "northwind",
                "Northwind Traders",
                vec![home.join("Projects").join("northwind")],
            )
            .expect("a valid demo company"),
        )
        .expect("the first registration cannot conflict with anything");
    registry
}
