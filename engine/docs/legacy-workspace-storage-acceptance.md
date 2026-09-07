# Installed storage metadata acceptance

`scripts/lib/legacy-workspace-storage.acceptance.py` is an external, pinned controller for a protected installed release. It accepts `--release`, `--manifest-sha256` and `--owner-uid`. It does not install a release, activate a service or select existing repositories.

The controller uses the installed fixture driver to mint a tiny canonical repository and worker. It creates linked files as the actual approved owner with `UF_TRACKED | UF_HIDDEN`, proves an outside alias refuses before metadata changes and injects a crash after protecting the first alias. Resume must retain both original owner records and protect both aliases as root. An actual owner subprocess must be unable to open held bytes.

The real same-boot frozen-view check must refuse. Only then does an instance-local `_boot` substitution allow the controller to exercise capture and restoration. The actual gate's recorded boot UUID is never rewritten. The result reports `tests_cutoff: false`; it is new-path integration evidence, separate from the recorded real-reboot acceptance.

Capture must preserve exact hardlink topology and flags. Restoration must return the original inode, bytes, owner, group, mode and flags to both aliases. All 12 named checks must pass. Successful synchronous fixtures are removed only after the gate is restored and both minted top-level root identities still match. Any failure retains the fixture and its receipt for inspection. Controller gates use `controller-only-gates`, outside automatic service discovery. The result also reports the exact source release, manifest hash, owner UID, `activated: false` and cleanup outcome.
