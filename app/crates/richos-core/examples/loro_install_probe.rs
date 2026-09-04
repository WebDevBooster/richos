//! WHAT DOES THIS LAUNCH RESOLVE? — both halves of loro, printed, from one resolution.
//!
//! Run it under the condition that matters and nothing else tells you the truth:
//!
//! ```text
//! cd / && env -i HOME="$HOME" USER="$USER" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
//!   app/target/debug/examples/loro_install_probe
//! ```
//!
//! That is launchd's environment, measured by `ps eww` on a Finder double-click of
//! `RichOS.app` on the CEO's machine — `HOME`, `USER`, `PATH`, and nothing else. Under it,
//! at `c6cf4ea`, the READ half resolved his corpus and the WRITE half resolved nothing,
//! because `CliLoroWriter::from_env()` read three environment variables a GUI launch does
//! not have. The desk was dead on the installed app and said nothing about it.
//!
//! **This probe is READ-ONLY.** It resolves directories and prints them. It opens no record,
//! starts no loro process, and writes nothing anywhere.

use richos_core::correction::CliLoroWriter;
use richos_core::loro::{CliContextCompiler, CorpusPaths, LoroInstall};

fn main() {
    println!("cwd  : {}", std::env::current_dir().map(|p| p.display().to_string()).unwrap_or_default());
    for k in ["LORO_CORPUS", "LORO_ROOT", "RICHOS_LORO_DIR", "RICHOS_NODE_BIN", "RICHOS_LORO_LANES", "HOME", "PATH"] {
        println!("env  : {k} = {:?}", std::env::var(k).ok());
    }

    // The exact call `src-tauri/src/memory.rs` makes at boot. ONE resolution.
    let (install, tried) = match LoroInstall::locate(&CorpusPaths::from_process()) {
        Ok(v) => v,
        Err(e) => {
            println!("INSTALL: refused — {e}");
            std::process::exit(3);
        }
    };
    let Some(install) = install else {
        println!("INSTALL: no corpus resolved. Looked in:");
        for t in &tried {
            println!("         {t}");
        }
        std::process::exit(2);
    };

    println!("INSTALL: root={} via {}", install.root().path().display(), install.source().as_str());
    println!("         tools={} via {}", install.tools().dir().display(), install.tools_source().as_str());
    println!("         node={}", install.tools().node());

    let writer = CliLoroWriter::from_install(&install);
    println!("WRITER : root={}", writer.root().path().display());
    println!("         bin={}", writer.tools().write_bin().display());

    // THE REGISTRY THIS INSTALL ACTUALLY HAS. It used to be a compiled-in constant; it is
    // read off disk now, and an install that has registered nothing yields an empty lane map
    // — which is a true statement about that install rather than a claim about a company
    // list it does not have.
    let registry = registry_on_this_machine();
    match CliContextCompiler::from_install(&install, &registry) {
        Ok(reader) => {
            println!("READER : root={}", reader.root().path().display());
            println!("         bin={}", reader.tools().context_bin().display());
            // THE PROPERTY, asserted rather than left for a reader to compare by eye.
            let agree = reader.root() == writer.root() && reader.tools().dir() == writer.tools().dir();
            println!("AGREE  : {}", if agree { "yes" } else { "NO — THIS BUILD WOULD WRITE TO THE WRONG CORPUS" });
            if !agree {
                std::process::exit(1);
            }
        }
        // A read-scoping failure does not un-resolve the corpus, and the desk stays open.
        Err(e) => println!("READER : unusable — {e} (the writer above is unaffected)"),
    }
}

/// The registry this install has, read from its own configuration directory.
///
/// Empty when nothing has been registered, which is the honest answer and is what an
/// unconfigured machine gets. The path is named in the output so a reader can see WHICH file
/// was consulted rather than inferring it.
fn registry_on_this_machine() -> richos_core::entity::EntityRegistry {
    let Some(home) = std::env::var_os("HOME").map(std::path::PathBuf::from) else {
        println!("REGISTRY: no HOME — no companies registered");
        return richos_core::entity::EntityRegistry::empty();
    };
    let path = richos_core::entity::entity_registry_path(&richos_core::entity::app_config_dir(&home));
    let load = richos_core::entity::EntityRegistry::load(&path);
    println!("REGISTRY: {} ({} compan(ies)) via {}", path.display(), load.registry.len(), load.source.as_str());
    for note in &load.notes {
        println!("          {note}");
    }
    load.registry
}
