//! The replay child: a recorded real `claude` session played back where `claude` would run
//! (`richos_core::replay`). Spawned by tests in place of the provider binary.
fn main() {
    std::process::exit(richos_core::replay::run(std::env::args().skip(1).collect()));
}
