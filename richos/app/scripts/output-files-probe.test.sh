#!/usr/bin/env bash
# Prove the Output file commands' probe (src-tauri/examples/output_files_probe.rs) records a file
# through the output record, describes it by its id, and refuses an id the record does not hold
# with the command's own sentence. The probe is what testvm/output-walk.py's open-reveal step runs
# in the guest; this test opens nothing on this Mac.
# run-tests: no-host-screen: the probe's own test; it records and describes a file and opens nothing
# run-tests: inputs richos/app/scripts/output-files-probe.test.sh richos/app/src-tauri/examples/output_files_probe.rs richos/app/src-tauri/src/output_files.rs richos/app/src-tauri/Cargo.toml richos/app/src-tauri/Cargo.lock
# run-tests: covers richos/app/src-tauri/examples/output_files_probe.rs
set -euo pipefail
cd "$(dirname "$0")/../src-tauri"
cargo test --example output_files_probe
