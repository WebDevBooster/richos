fn main() {
    std::process::exit(richos_core::quota::terminal::run(std::env::args().skip(1).collect()));
}
