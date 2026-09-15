//! ONE JOB: make `cargo` notice when the engine pin changes.
//!
//! `setup.rs::engine_pin` reads its three values with `option_env!`, at COMPILE time, so the
//! digest ends up inside the executable the app's Developer ID signature covers. That is the
//! right place for it and it has one sharp edge: **cargo does not track environment variables
//! it was not told about.** Without the three lines below, a build with the pin set, followed
//! by a build with it changed, is a cache hit — and the binary keeps the OLD digest while the
//! build log says it used the new one.
//!
//! That is the exact shape of the failure this project keeps paying for: a step that reports
//! success while doing the wrong thing. It would surface on a customer's Mac as a
//! `DigestMismatch` against a release that was perfectly fine, and the person diagnosing it
//! would be looking at the release rather than at their own build cache.
//!
//! Nothing else belongs in this file. `richos-core` is native-dependency-free and fast to
//! test (`app/README.md`), and a build script that did work would be the first thing to cost
//! that.

fn main() {
    for key in ["RICHOS_ENGINE_VERSION", "RICHOS_ENGINE_URL", "RICHOS_ENGINE_SHA256"] {
        println!("cargo:rerun-if-env-changed={key}");
    }
}
