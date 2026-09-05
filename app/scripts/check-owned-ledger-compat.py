#!/usr/bin/env python3
"""Read a new owned-work conversation with an actual older richos-core checkout.
Usage: python3 check-owned-ledger-compat.py OLD_CORE_DIR LEDGER [CARGO]
The old checkout is read only. Compilation and lockfiles stay in a temporary dir.
"""
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile
if len(sys.argv) not in (3, 4):
    sys.exit(__doc__)
old = Path(sys.argv[1]).resolve()
ledger = Path(sys.argv[2]).resolve()
cargo = sys.argv[3] if len(sys.argv) == 4 else "cargo"
with tempfile.TemporaryDirectory(prefix="richos-old-reader-") as directory:
    root = Path(directory)
    (root / "src").mkdir()
    (root / "Cargo.toml").write_text('[package]\nname="owned-ledger-compat"\nversion="0.0.0"\nedition="2021"\n[workspace]\n[dependencies]\nrichos-core={path=' + json.dumps(str(old)) + '}\n')
    (root / "src/main.rs").write_text(r'''
fn main() {
    let ledger = richos_core::Ledger::open(std::env::args().nth(1).unwrap()).expect("old reader must deserialize the complete ledger");
    let mut users = 0;
    let mut finished = false;
    for thread in ledger.threads() {
        for message in ledger.messages(&thread.id).expect("old reader must render the conversation") {
            if message.role == "user" { users += 1; assert!(!message.text.starts_with("Work on this task")); }
            finished |= message.text.starts_with("Finished and checked:");
        }
    }
    assert_eq!(users, 1, "one CEO request must survive restart and downgrade exactly once");
    assert!(finished, "verified completion must render in the old version");
    println!("PASS: actual older reader deserializes and renders the owned-work ledger without losing or duplicating the CEO request.");
}
''')
    result = subprocess.run([cargo, "run", "--offline", "--manifest-path", str(root / "Cargo.toml"), "--", str(ledger)], env=dict(os.environ, CARGO_TARGET_DIR=str(root / "target")))
    raise SystemExit(result.returncode)
