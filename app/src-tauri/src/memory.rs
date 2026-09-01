//! COMPANY MEMORY AT BOOT, AND AGAIN THE MOMENT THE CEO SETS IT UP.
//!
//! Everything in [`wire_company_memory`] lived inside `setup` until 2026-09-01, ran exactly
//! once, and printed the boot line. It moved here **unchanged** because first-run
//! provisioning has to run it a second time: the CEO answers "set my memory up", a corpus
//! appears on disk, and the app must start using it without being relaunched. Two copies of
//! this logic would drift, and the copy that drifted would be the one he actually hits.
//!
//! What this file adds on top of that move is [`MemoryStatus`] — the four outcomes the boot
//! log already distinguished, as a value the window can read, so the first-run question is
//! asked from the same fact the log states rather than from a second guess about it.

use richos_core::entity::EntityRegistry;
use richos_core::loro::{CliContextCompiler, CorpusLanes, CorpusPaths, SharedSliceProvenance};
use richos_core::provision;
use richos_core::spine::Spine;
use serde::Serialize;

/// WHAT THIS INSTALL'S MEMORY IS DOING, in the four states it can be in.
///
/// Four and not two, for the reason `LoroError::CompilerNotInstalled` exists: *"there is no
/// record here"* and *"there is a record here and I cannot read it"* are different sentences,
/// and a surface that collapsed them would offer to create a corpus he already has.
#[derive(Debug, Clone, Serialize, Default)]
pub struct MemoryStatus {
    /// `ready` — a corpus resolved and the compiler is wired to the spine.
    /// `none` — nothing resolved. The ordinary state of a fresh install, and the one the
    ///   first-run question answers.
    /// `no-compiler` — a corpus resolved and the program that reads it is not installed.
    /// `unusable` — something else refused; `detail` carries it verbatim.
    pub state: String,
    /// The corpus root, when one resolved.
    pub root: Option<String>,
    /// Which candidate answered — `CorpusSource::as_str`.
    pub source: Option<String>,
    /// The compiler directory in use, when one resolved.
    pub compiler: Option<String>,
    /// Every candidate considered and what became of it. Carried to the window so a state
    /// that needs an operator can say what was looked for rather than only that it failed.
    pub tried: Vec<String>,
    /// The machine-facing detail of a `no-compiler` or `unusable` state. Never shown to the
    /// CEO as it stands — the surface writes his sentence and keeps this for whoever set
    /// RichOS up, the same split `NO COMPUTE LEASE` already uses.
    pub detail: Option<String>,
    /// `~/RichOS/corpus`, as a string to SHOW him. Pre-filling it into the question is what
    /// makes his part a choice instead of a path he types. **It is not a fallback**: nothing
    /// but the surface reads it, and `provision` refuses a target nobody named.
    pub offered_location: Option<String>,
    /// Set only by the provisioning command, so the window can say "that is done" instead of
    /// re-rendering the question it just answered.
    pub provisioned_now: bool,
}

/// Fill in the location the CEO is offered. Separate from the states above because it is a
/// fact about the MACHINE and not about the memory: it is the same string whether or not a
/// corpus exists, and it is absent only when there is no `$HOME` to hang it off.
pub fn with_offered_location(mut status: MemoryStatus, home: Option<&std::path::Path>) -> MemoryStatus {
    if let Some(home) = home {
        status.offered_location = Some(provision::offered_corpus_dir(home).display().to_string());
    }
    status
}

/// TIER C — COMPANY MEMORY (continuity §2.1 #8 / §4, open-items 3.5).
///
/// Prints exactly what it printed when it lived in `setup`: the boot log is an operator's
/// only window into this seam and its wording is load-bearing. What is new is the return
/// value, and one extra line in the `no-compiler` case — which used to be indistinguishable
/// from any other misconfiguration and is now the ordinary state of a provisioned corpus on
/// a machine where the compiler ships from nowhere (`BLOCKED.md`).
pub fn wire_company_memory(spine: &mut Spine, loro_provenance: &SharedSliceProvenance) -> MemoryStatus {
    match CliContextCompiler::locate(&CorpusPaths::from_process()) {
        Ok((Some((mut compiler, source)), _tried)) => {
            eprintln!(
                "[richos] loro Tier C: compiling from {} (via {}), node {}",
                compiler.root().path().display(),
                source.as_str(),
                compiler.tools().node()
            );
            let status = MemoryStatus {
                state: "ready".into(),
                root: Some(compiler.root().path().display().to_string()),
                source: Some(source.as_str().to_string()),
                compiler: Some(compiler.tools().dir().display().to_string()),
                ..Default::default()
            };
            // THE LANE MAP, RECONCILED AGAINST THE CORPUS — open item 3.5, and the
            // reason it is safe to stop being empty.
            //
            // The map defaults to the CEO's six companies now that he has ratified
            // the layout (`wiki/ceo-decisions.md` §5). A mapping is a CLAIM that a
            // partition exists, and loro refuses one it does not have — `exit 2: no
            // such company partition "femcboost" in this corpus. Known: (none).`
            // His corpus has zero partitions today, so a map that were merely
            // filled in would make every re-prime `Unavailable`. Asking the corpus
            // costs 0.06 s (measured, three runs) and turns the map from a claim
            // into a fact.
            //
            // A FAILED PROBE IS NOT "NO PARTITIONS". It leaves the map exactly as
            // configured and says so — inventing an empty corpus from a failure to
            // read one is the same class of lie the whole seam is built against.
            match CorpusLanes::probe(compiler.tools(), compiler.root()) {
                Ok(corpus) => {
                    for note in compiler.reconcile_lanes(&corpus) {
                        eprintln!("[richos] loro lane: {note}");
                    }
                    let unmapped = compiler.entities_with_no_lane(&EntityRegistry::ceos_companies(), &corpus);
                    if !unmapped.is_empty() {
                        // Loud, because the CEO's side of this is a re-prime that
                        // says "loro could not be consulted" every turn: with no
                        // lane the compile widens, loro returns another company's
                        // items, and the cross-entity re-assertion refuses the
                        // slice whole. Fail-closed and correct, and useless to him.
                        eprintln!(
                            "[richos] loro lane: this corpus has partitions ({}) but {} \
                             {} bound to none of them — every slice for {} will be \
                             REFUSED by the cross-entity guard. Set RICHOS_LORO_LANES.",
                            corpus.companies().join(", "),
                            unmapped.join(", "),
                            if unmapped.len() == 1 { "is" } else { "are" },
                            if unmapped.len() == 1 { "it" } else { "them" },
                        );
                    }
                    if compiler.lanes().is_empty() {
                        eprintln!(
                            "[richos] loro lane: no lane narrowing in force — every company \
                             reads the CEO layer, which is the whole of an unpartitioned corpus."
                        );
                    }
                    // WHOSE RECORD IS THIS, when the corpus is one repository's own
                    // AND HAS NO PARTITIONS.
                    //
                    // An UNPARTITIONED in-repo corpus has no company field on any
                    // item, so the lane map has nothing to narrow and the
                    // cross-entity guard has nothing to refuse — both work, and
                    // neither can see that a FemcBoost thread is being handed
                    // RichOS's record under a heading reading COMPANY MEMORY.
                    // Measured on 2026-09-01 against the CEO's only corpus.
                    //
                    // Once that corpus IS partitioned, `repo_layout_root()` returns
                    // None and this block does not run: the caveat asserts "holds no
                    // <entity> partition", which would then be false, and a false
                    // caveat tells a fresh Rich to discount memory correctly his.
                    //
                    // The REGISTRY answers whose it is, which it could not do
                    // before today: `richos-hq` became a registered root of the
                    // `richos` entity in this same pass. An unowned path leaves the
                    // owner unstated rather than guessed.
                    if let Some(repo) = corpus.repo_layout_root() {
                        let registry = EntityRegistry::ceos_companies();
                        match registry.resolve_root(repo) {
                            Ok(owner) => {
                                eprintln!(
                                    "[richos] loro corpus: in-repo layout at {} — this is {}'s own \
                                     record, and every other company's slice will say so.",
                                    repo.display(),
                                    owner.id
                                );
                                compiler.set_repo_corpus_owner(Some(owner.id.to_string()));
                            }
                            Err(e) => eprintln!(
                                "[richos] loro corpus: in-repo layout at {} but no registered \
                                 company owns that path ({e}) — the owner is left unstated \
                                 rather than guessed.",
                                repo.display()
                            ),
                        }
                    }
                }
                Err(e) => eprintln!(
                    "[richos] loro lane: could not read which partitions this corpus has ({e}) \
                     — the lane map is left exactly as configured rather than assumed empty."
                ),
            }
            compiler.set_provenance_sink(std::sync::Arc::clone(loro_provenance));
            spine.set_loro_context_compiler(Box::new(compiler));
            spine.set_loro_provenance(std::sync::Arc::clone(loro_provenance));
            status
        }
        Ok((None, tried)) => {
            eprintln!("[richos] loro Tier C: no corpus configured — re-primes carry no company memory");
            // WHAT WAS LOOKED FOR, not merely that it failed. This is the line that
            // would have turned "no corpus configured" from a shrug into an
            // instruction the first time anyone read it on a double-click.
            for t in &tried {
                eprintln!("[richos] loro Tier C: tried {t}");
            }
            // AND WHAT WILL HAPPEN ABOUT IT, which is the line this branch was missing on
            // 2026-09-01: until this pass, nothing anywhere created any of the candidates
            // above, so a reader who got this far had a list and no next step.
            eprintln!(
                "[richos] loro Tier C: RichOS will offer to set one up in the window, and will not \
                 pick a location on its own."
            );
            MemoryStatus { state: "none".into(), tried, ..Default::default() }
        }
        // A CORPUS WITH NO COMPILER IS ITS OWN LINE. It is not a misconfiguration — it is a
        // provisioned corpus on a machine where the compiler has not been installed, which
        // is the honest state of a fresh install until `BLOCKED.md`'s question is answered.
        Err(richos_core::loro::LoroError::CompilerNotInstalled { root, tried }) => {
            eprintln!(
                "[richos] loro Tier C: corpus at {root} — but the memory compiler is not installed, \
                 so re-primes carry no company memory. Looked in: {tried}"
            );
            MemoryStatus {
                state: "no-compiler".into(),
                root: Some(root),
                detail: Some(tried.clone()),
                tried: vec![tried],
                ..Default::default()
            }
        }
        Err(e) => {
            eprintln!("[richos] loro Tier C: configured but unusable, continuing without it: {e}");
            MemoryStatus { state: "unusable".into(), detail: Some(e.to_string()), ..Default::default() }
        }
    }
}
