# Verification input qualifications

Only checks named in `richos/app/scripts/proof-inputs.json` can reuse results.
The declaration, this qualification, the entire engine and the app runner scripts
are content inputs. This is the conservative declared-root tier. Changes within
either root rerun these checks until a narrower closure is separately qualified.
Checks without a declaration remain fresh with an explicit reason.

## Private fixture execution

`private-home-v1` creates separate HOME, config, temporary and Git-template
directories for each check. It seeds a fixed Git identity, disables system Git
configuration and clears inherited behavior overrides. Python runs with `-s -S`:
user packages, site packages, `.pth` files and site startup hooks cannot affect
these standard-library-only suites. Python's remaining import roots, bytecode,
executable and framework binary are fingerprinted. The declared command tools
are resolved and fingerprinted, including symlink targets. Platform identity
binds the OS implementation of native system libraries.

Machine admission, worker leases and process ownership still come from the
supervising runner. Those operational paths do not become test fixture inputs.
Known-red declarations are checked live and never cached. Coverage validation
runs again and validates original receipts against the current target.

This profile is an input recipe, not a filesystem sandbox. Qualification below
depends on reviewed concrete reads and writes. It does not qualify a test with a
hardcoded host path, live network input or host-process assertion. Such checks
need their own fixture/input contract or a specific fresh-run requirement.

## Reviewed units

| Unit | Production code and fixtures | Live input disposition |
| --- | --- | --- |
| `scripts/ci-verify.test.sh` | Reads `ci-verify.sh`. Copies it into a generated engine with stub install, probe, publication, demo and suite commands. Verifies inventory and split coverage using the real orchestrator. All generated files are beneath TMPDIR. | No network, current-time or host-process assertion. The stub commands are fixture data in the test source. |
| `scripts/install-ack-protocol.test.sh` | Runs `install-ack-protocol.sh` against generated agent definitions. Reads `reference/ack-protocol-seam.md`. Verifies drift, replacement, identity, missing-input refusal and read-only diff. Every installer invocation supplies a private `--repo`. | No operator definitions, Git history, network or live-clock behavior. Python uses only standard-library modules. |
| `scripts/install-escalation-protocol.test.sh` | Runs `install-escalation-protocol.sh` against generated definitions with single/multiple seams and neighboring acknowledgement text. Reads `reference/escalation-protocol-seam.md`. Every installer invocation supplies a private `--repo`. | No operator definitions, Git history, network or live-clock behavior. Python uses only standard-library modules. |

The shared engine shard reads the unit inventory, weights, known-red policy and
its own Python/shell helpers. The whole engine input includes their contents and
directory inventory. Its source and private-record canaries, worker admission,
deadline and cleanup remain required for each actual execution. Reuse retains
the original successful execution's canary/cleanup verdict; target source and
input identities are independently validated again. The shard's current commit
is receipt provenance, not an installer behavior input.

`proof-evidence.test.py` exercises private environment exclusion and seed identity,
runtime dependency changes, declared external inputs, changed tool bytes, modes,
directory inventories, changed commands, cross-commit reuse and original receipt
retention. Qualification never follows from an exit code alone.
