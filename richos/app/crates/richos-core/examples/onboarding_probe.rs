//! What this install will do about onboarding, and the exact bytes it would send.
//!
//! ```text
//! cargo run -q -p richos-core --example onboarding_probe -- [<entity-id> ...]
//! ```
//!
//! With no arguments it reports every company in this install's registry. With ids, only
//! those — including ids that are not registered, which is how you ask "what would a brand new
//! company look like" without registering one.
//!
//! # Why an example rather than a test
//!
//! Two jobs, and neither is assertion.
//!
//! **It is the diagnostic for a real install.** `onboarding.rs`'s unit tests run against
//! temporary directories, which is right for them and means none of them can answer "is the CEO
//! going to be asked, on THIS machine, tonight". This reads the real central folder, the real
//! registry and the real declination record and says so, in the same one-line-per-company form
//! the boot log uses.
//!
//! **And it is how the priming block gets measured against a live model.** The block is a
//! `const` in a Rust crate; a measurement harness that retyped it would be measuring a copy,
//! and the copy is exactly the thing that goes stale. `--block <entity>` prints the real bytes
//! so a driver can pipe them into a real `claude` child —
//! `docs/verification/onboarding-honesty-2026-09-06/` cell D1 does precisely that.
//!
//! It writes nothing, creates nothing, and opens no audio device.

use richos_core::company::CompanyLayer;
use richos_core::entity::{app_config_dir, EntityId, EntityRegistry};
use richos_core::onboarding::{describe, priming_block, record_path, OnboardingRecord};

fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();

    // `--block <entity>`: the exact bytes, and nothing else on stdout, so a harness can read
    // them without stripping a report off the front.
    let block_only = args.first().map(|a| a == "--block").unwrap_or(false);
    if block_only {
        args.remove(0);
    }

    let Some(home) = std::env::var_os("HOME").map(std::path::PathBuf::from) else {
        eprintln!("no HOME — nothing to report");
        std::process::exit(2);
    };
    let config_dir = app_config_dir(&home);
    let central = richos_core::company::install_central_root();
    let record = OnboardingRecord::load(&record_path(&config_dir));

    let ids: Vec<EntityId> = if args.is_empty() {
        let load = EntityRegistry::load(&richos_core::entity::entity_registry_path(&config_dir));
        load.registry.entities().iter().map(|e| e.id.clone()).collect()
    } else {
        args.iter()
            .filter_map(|a| match EntityId::parse(a) {
                Ok(id) => Some(id),
                Err(e) => {
                    eprintln!("skipping {a}: {e}");
                    None
                }
            })
            .collect()
    };

    if !block_only {
        eprintln!("central folder : {}", central.as_ref().map(|p| p.display().to_string()).unwrap_or_else(|| "(no HOME)".into()));
        eprintln!("record         : {}", record_path(&config_dir).display());
        eprintln!("declined       : {:?}", record.declined_at_millis());
        eprintln!("companies      : {}", ids.len());
        eprintln!();
    }

    for id in &ids {
        let layer = central.as_ref().map(|root| CompanyLayer::read(root, id));
        if block_only {
            if let Some(block) = priming_block(id, layer.as_ref(), &record.for_entity(id)) {
                print!("{block}");
            }
        } else {
            println!("{}", describe(id, layer.as_ref(), &record.for_entity(id)));
            if let Some(l) = &layer {
                println!("    {}", l.describe());
            }
        }
    }
}
