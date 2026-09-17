# Manual local nightly releases

A nightly is released **only when someone explicitly runs the release command**.
There is no scheduler, watcher, push hook or GitHub Actions release workflow.
The Mac must be awake, online and able to access its signing Keychain.

## Commands

From the repository root, check readiness without building or publishing:

```sh
python3 richos/app/scripts/nightly-local.py check
```

When you actively want to release a nightly:

```sh
python3 richos/app/scripts/nightly-local.py release
```

The command builds the current remote `main`, not uncommitted work or the current
local branch. It uses a dedicated detached worktree at `~/.richos-nightly/source`.
It never switches or resets the developer's checkout. If the dedicated worktree
has unexpected changes, it refuses rather than deleting them.

If that source commit already has a successful nightly, it does nothing. To
explicitly rebuild the same source with a fresh version:

```sh
python3 richos/app/scripts/nightly-local.py release --force
```

The command runs in the foreground. Logs and release artifacts are under
`~/.richos-nightly/logs` and `~/.richos-nightly/releases`. One local command can run
at a time. A failure leaves the previous published nightly available. Fix the
reported problem and explicitly invoke the command again to retry. Nothing
retries or publishes in the background.

## Version numbers

The base is the next release version in `src-tauri/Cargo.toml`:

```text
1.2.0-nightly.20260911.1
1.2.0-nightly.20260911.9
1.2.0-nightly.20260911.10
1.2.0-nightly.20260912.1
```

The UTC date is captured at allocation after checks finish. The counter resets
each day for each base version and is never padded. Failed attempts may leave
gaps. Tags reserve numbers permanently. After publishing stable `v1.2.0`, bump
the base version before creating more nightlies.

## Existing local credentials

The same credentials as stable releases are used:

- Developer ID Application identity in the macOS Keychain.
- `~/.richos-signing/notary.env`, containing plain `RICHOS_NOTARY_KEY`,
  `RICHOS_NOTARY_KEY_ID` and `RICHOS_NOTARY_ISSUER` assignments. A
  `RICHOS_NOTARY_PROFILE` Keychain profile is also supported.
- `~/.richos-signing/richos-updater.key` and its `.pub` file.
- `~/.richos-privacy/named-persons`, the real release privacy-check list.

The private files must belong to the current user and have mode 600. Their
contents are not copied to GitHub. `notary.env` is parsed as data, never executed
as a shell script. The check command signs a disposable local probe, checks Apple
notarization authentication and verifies the local updater public key matches the
app. It does not submit an app to Apple or create a GitHub release. The full
release path separately verifies the produced artifact's updater signature.

Credentials reach only the steps that use them: the preflight signing probe, the
notarization check, the updater signature, and the publisher. The gates, meaning the
two `cargo test` runs, the twelve `app/scripts` suites and the privacy sweep, run in
an environment holding no `RICHOS_NOTARY_*`, `TAURI_SIGNING_*`, `APPLE_*`,
`RICHOS_NOTARIZE` or `RICHOS_SIGNING_IDENTITY` variable, including any the operator's
own shell exported. This is a correctness rule before it is a secrecy one: on
2026-09-16 the first nightly attempt published nothing because four
`package-app.test.sh` cases that refuse when notary credentials are absent or
half-supplied ran with a complete key in their environment.

Python 3.11+, Git, GitHub CLI, Rust, Tauri CLI 2.11.4 and Xcode command-line tools
must be installed. GitHub CLI and Git must already be authenticated. A restricted
Keychain may require user interaction to sign; the command fails if its signing
probe cannot complete within 90 seconds. This implementation currently supports
Apple Silicon macOS, matching the bundled runtime recipe.

The runner verifies its public runtime cache before every build. If the cache at
`~/.richos-nightly/runtime` is absent, the release command builds it from the
pinned public source recipe. A stale or corrupted cache is a refusal. An existing
verified runtime directory can be selected with `--runtime-dir /absolute/path`.
The check command validates a present cache but never builds a missing one.

## Publication

The repository's `main-only` ruleset needs an exception for exactly
`refs/heads/nightly-channel`. Other non-main branches remain blocked. No GitHub
Actions secrets, environment or enabled CI workflows are needed.

Each explicitly triggered release:

1. Fetches and checks out a fixed remote `main` commit in the dedicated worktree.
2. Checks local signing, notarization and GitHub access.
3. Builds/verifies runtimes and runs core, updater, packaging and privacy gates.
4. Creates a tagged child commit with the nightly Cargo version, lockfile entry,
   nightly endpoint and source/run provenance. It does not bump `main`.
5. Publishes the reproducible engine asset to a versioned GitHub prerelease and
   downloads it to verify the digest before compiling that pin into the app.
6. Builds, signs, notarizes and staples the app locally. It verifies both the
   plist version and the executable's compiled update identity.
7. Uploads immutable artifacts, provenance and checksums, with the release's
   manifest last. It downloads them again and verifies bytes and signatures.
8. Atomically advances `nightly-channel` using a Git compare-and-swap push.
   Older versions and regressed/divergent source commits are refused.

The release is marked prerelease and `--latest=false`, so stable updates are
unaffected. An engine-only partial release is not offered to nightly users.
Existing tags and artifacts are never overwritten. Do not delete old release
assets automatically: installed apps may still need their pinned engine URLs.

## Installing and leaving the channel

Installing a versioned nightly ZIP is the opt-in. Nightlies use:

```text
https://raw.githubusercontent.com/WebDevBooster/richos/nightly-channel/latest.json
```

Stable builds keep their stable endpoint. Nightlies replace the same app and use
the same data; there is no separate side-by-side application or settings toggle.
To leave the channel, install a stable version at least as new as the nightly.
Stable `1.2.0` supersedes `1.2.0-nightly.*`; stable `1.1.0` does not.

## Tests

```sh
bash richos/app/scripts/nightly.test.sh
bash richos/app/scripts/nightly-local.test.sh
bash richos/app/scripts/make-release.test.sh
cargo test --locked --manifest-path richos/app/crates/richos-user-update/Cargo.toml
```

Tests cover version ordering, reservations, source isolation, private credential
parsing, concurrent commands, explicit-only publication, failed checks leaving
the existing channel intact, and the signing credentials never reaching a gate
subprocess. Local preflight is distinct from a complete signed release. Only an
explicit `release` invocation exercises actual publication.
