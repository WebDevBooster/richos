//! EVERY WAY PROVISIONING REFUSES, ATTEMPTED RATHER THAN ASSERTED.
//!
//! The unit tests prove these against the same function; this proves them from OUTSIDE the
//! crate, in a process whose environment holds nothing, and prints the sentence a human
//! would be shown. A refusal nobody has attempted is a comment.
//!
//! ```bash
//! env -i HOME=/tmp/clean PATH=/usr/bin:/bin cargo run -p richos-core --example provision_refusals -- /tmp/work
//! ```
//!
//! Exit 0 means every attempt was refused. **Exit 1 means one of them succeeded**, which is
//! the failure this file exists to catch: a corpus created where none should be.

use richos_core::provision::{provision, ProvisionRequest};
use std::path::{Path, PathBuf};

fn attempt(label: &str, target: PathBuf, home: Option<PathBuf>) -> bool {
    println!("--- {label} ---");
    println!("    target: {:?}", target.display().to_string());
    match provision(&ProvisionRequest { target, home, companies: vec![], compiler_source: None }) {
        Ok(report) => {
            println!("    NOT REFUSED — created {}. THIS IS THE DEFECT.", report.root.display());
            false
        }
        Err(e) => {
            println!("    refused: {e}");
            true
        }
    }
}

fn main() {
    let work = PathBuf::from(std::env::args().nth(1).unwrap_or_else(|| "/tmp/richos-refusals".into()));
    std::fs::create_dir_all(&work).unwrap();
    let mut ok = true;

    println!("=== 1. no silent default: unset must be an error, never a fallback ===");
    ok &= attempt("nothing said at all", PathBuf::new(), None);
    ok &= attempt("blank", PathBuf::from("   "), None);
    ok &= attempt(
        "relative — a launched app's working directory is \"/\"",
        PathBuf::from("RichOS/corpus"),
        None,
    );
    // And the state that matters: nothing was created anywhere under the clean HOME.
    if let Some(home) = std::env::var_os("HOME").map(PathBuf::from) {
        let created = home.exists() && std::fs::read_dir(&home).map(|mut d| d.next().is_some()).unwrap_or(false);
        println!(
            "    and the clean HOME after three refusals: {}",
            if created { "NOT EMPTY — THIS IS THE DEFECT" } else { "still empty" }
        );
        ok &= !created;
    }

    println!();
    println!("=== 2. never inside a product checkout ===");
    // loro's own marker, reproduced exactly: `layout.js:391`.
    let loro_checkout = work.join("a-loro-checkout");
    mk(&loro_checkout.join("loro/lib"), "store.js");
    mk(&loro_checkout.join("loro/bin"), "loro-context.mjs");
    ok &= attempt(
        "inside a checkout carrying the compiler's source (loro's own marker)",
        loro_checkout.join("corpus"),
        None,
    );

    // The marker loro's detector cannot see, because richos ships no `loro/`.
    let richos_repo = work.join("a-richos-checkout");
    mk(&richos_repo.join("app/crates/richos-core"), "Cargo.toml");
    ok &= attempt(
        "inside the richos product repo (the marker loro cannot see)",
        richos_repo.join("app").join("corpus"),
        None,
    );
    ok &= attempt(
        "four levels down inside it — \"inside\" means the walk up, not the directory itself",
        richos_repo.join("a").join("b").join("c").join("corpus"),
        None,
    );

    println!();
    println!("=== 3. an existing corpus is left exactly alone ===");
    let his = work.join("his-corpus");
    std::fs::create_dir_all(his.join("ceo").join("records")).unwrap();
    std::fs::write(his.join("ceo").join("records").join("a-record.md"), "his own record\n").unwrap();
    ok &= attempt("a directory that is already a corpus", his.clone(), None);
    let untouched = std::fs::read_to_string(his.join("ceo").join("records").join("a-record.md")).unwrap();
    println!("    his record after the refusal: {untouched:?}");
    println!("    companies/ created by the refusal: {}", his.join("companies").exists());
    ok &= untouched == "his own record\n" && !his.join("companies").exists();

    println!();
    println!("=== 4. somebody else's folder is not a corpus ===");
    let occupied = work.join("occupied");
    std::fs::create_dir_all(&occupied).unwrap();
    std::fs::write(occupied.join("taxes.pdf"), "not a corpus").unwrap();
    ok &= attempt("a directory with unrelated files in it", occupied, None);

    println!();
    if ok {
        println!("every attempt was refused.");
    } else {
        println!("AT LEAST ONE ATTEMPT SUCCEEDED — read the lines above.");
        std::process::exit(1);
    }
}

fn mk(dir: &Path, file: &str) {
    std::fs::create_dir_all(dir).unwrap();
    std::fs::write(dir.join(file), "// marker\n").unwrap();
}
