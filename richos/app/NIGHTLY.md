# Manual local nightly releases

A nightly is released **only when someone explicitly runs the release command**.
There is no scheduler, watcher, push hook or GitHub Actions release workflow.
The Mac must be awake, online and able to access its signing Keychain.

## Commands

From the repository root, check readiness without building or publishing:

```sh
python3 richos/app/scripts/nightly-local.py check
```

When you actively want to release a nightly in one motion, with no QA pause
between the candidate being built and it becoming installable:

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

## QA before publication: `build`, `candidate`, `publish`

CEO ruling, 2026-09-17 (`ceo-decisions.md` §45 addendum 2): QA walks the
nightly's own candidate before it is published; publication happens only on a
READY verdict. `release` above still exists as the pre-authorized one-motion
path and is unchanged by this: it is `build` immediately followed by
`publish`, byte-for-byte. For everything else, split the two halves:

```sh
python3 richos/app/scripts/nightly-local.py build
```

Does everything `release` does up to and including compiling the signed,
notarized, engine-pinned app against a verified engine pin, and stops. It
still touches the network — the engine asset has to actually be published at
the URL the app's Developer-ID-signed pin claims, or the app cannot be
compiled against it (`make-release.sh` `verify-engine`, which `build` runs
itself, immediately before compiling) — but nothing here uploads the app
archive, writes `latest.json`, or advances the update channel. Nobody's
existing install can see or fetch anything `build` produced. It prints the run
id, the staged candidate's path and exactly how to walk it:

```
Candidate v1.2.0-nightly.20260917.1 (1.2.0-nightly.20260917.1), source aa0165cc...
  staged at : ~/.richos-nightly/releases/v1.2.0-nightly.20260917.1
  bundle zip: .../RichOS-1.2.0-nightly.20260917.1-macos-aarch64.zip

To walk it: unpack into a scratch HOME so it never touches the operator's own
app data (README.md's activation invariant D), and run it directly rather than
via `open`, so a harness/terminal holds the process (invariant P). Set
RICHOS_ACTIVATION=regular so the window is visible instead of accessory-hidden:

  mkdir -p /tmp/richos-qa-<run-id> && ditto -x -k '<bundle zip>' /tmp/richos-qa-<run-id>
  HOME=/tmp/richos-qa-<run-id>/home RICHOS_ACTIVATION=regular \
      '/tmp/richos-qa-<run-id>/RichOS.app/Contents/MacOS/richos-tauri'

Publish only on a READY verdict:  nightly-local.py publish --run <run-id>
```

A walker (or a walk brief) who only needs those instructions again, without
rebuilding, can ask for them directly:

```sh
python3 richos/app/scripts/nightly-local.py candidate --run <run-id>
```

`candidate` reads only the recorded build; it never runs any command and never
touches the network.

Once QA returns a READY verdict, publish the SAME candidate:

```sh
python3 richos/app/scripts/nightly-local.py publish --run <run-id>
```

`publish` refuses rather than uploading anything if the candidate's recorded
files (the app archive, its updater `.sig`, `latest.json` — version, SHA and
signature are all just files under the staged directory, so one check covers
all three) no longer match what `build` produced, or if the built source
commit is no longer an ancestor of the current `main` — a rebase or a
force-push that happened while a walker was on the candidate. Neither `build`
nor `candidate` needs a signing or notarization credential to have reached
this point; only `build` does (it is the step that signs and notarizes), and
`publish` does not re-request one.

`--run <run-id>` is the id `build` printed. It is looked up under
`~/.richos-nightly/runs/<run-id>.json`, which just points at the staged
candidate directory `build` already produced — nothing is copied or rebuilt.

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
- Your configured Git identity, `git config user.name` and `user.email`.

The release commit and the channel commit are authored with this Mac's
configured Git identity rather than a synthetic `nightly@` one, because the release is
your own act and this machine's commit-identity guard refuses to push a commit that
says otherwise; `check` prints the identity it will author with, and refuses in
milliseconds if none is configured instead of failing at the tag push after the gates.

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

The repository's `main-only` ruleset needs **no exception of any kind**, and the
publisher reads it back before every publish to make sure it still has none:
`nightly.py check-rules` refuses the run unless `main` is the only branch exempt
from it, the ruleset is active, nobody can bypass it, and both `creation` and
`update` are restricted. The runner asks the same question in preflight so a
widened rule costs seconds instead of forty minutes of gates.

That check exists because the opposite one used to. Until 2026-09-17 this page
asked for an exception for exactly `refs/heads/nightly-channel` and the runner
refused to start without one; on 2026-09-16 the exception was added, and the next
morning the public repository page read "2 Branches". The channel is a release tag
now (below), so there is nothing left to grant.

No GitHub Actions secrets, environment or enabled CI workflows are needed.

Each explicitly triggered release runs `build` (steps 1-6) immediately
followed by `finish` (steps 7-8) — or, under the QA-gated path above, an
arbitrary amount of time can pass between the two, with a walker on the
candidate in between:

**`build`:**

1. Fetches and checks out a fixed remote `main` commit in the dedicated worktree.
2. Checks local signing, notarization and GitHub access.
3. Builds/verifies runtimes and runs core, updater, packaging and privacy gates.
4. Creates a tagged child commit with the nightly Cargo version, lockfile entry,
   nightly endpoint and source/run provenance. It does not bump `main`.
5. Publishes the reproducible engine asset to a versioned GitHub prerelease and
   downloads it to verify the digest before compiling that pin into the app.
6. Builds, signs, notarizes and staples the app locally. It verifies both the
   plist version and the executable's compiled update identity, and records a
   SHA-256 of every staged file so `finish` can detect tampering later.

**`finish`** (what `publish --run <run-id>` invokes):

7. Refuses if any of the files `build` recorded no longer match what is on
   disk, or if the built source commit is no longer an ancestor of the
   current `main`. Otherwise uploads immutable artifacts, provenance and
   checksums, with the release's manifest last, then downloads them again and
   verifies bytes and signatures.
8. Advances the update channel, in that order: a Git compare-and-swap push moves
   the rolling `nightly` release tag to a commit carrying the new `latest.json`
   and `build-info.json`, and only then is that `latest.json` uploaded over the
   `nightly` release's asset, which is the file installed copies fetch. Older
   versions and regressed/divergent source commits are refused.

   The lease comes first deliberately. It is what decides who may publish, so a
   failure between the two steps leaves the tag naming a version whose asset was
   not replaced — installed copies simply stay on the previous nightly — and the
   command exits non-zero. Re-run `publish --run <run-id>`: it recognizes that the
   channel already records this exact candidate and re-uploads the asset without
   moving anything. The reverse order would put a build in front of users that no
   lease was ever taken for.

The release is marked prerelease and `--latest=false`, so stable updates are
unaffected. An engine-only partial release is not offered to nightly users.
Existing tags and artifacts are never overwritten. Do not delete old release
assets automatically: installed apps may still need their pinned engine URLs.

Note that `build` (step 5) already makes the release for this tag exist on
GitHub as a prerelease carrying only the engine asset — that is unavoidable,
because the app's compiled pin is a claim about bytes already served from
that exact tag's release, and the only way to make the claim true is to put
them there first. What a walker's candidate does NOT yet have is an
installable app archive, a `latest.json`, or any effect on the update channel
— those three are `finish`'s alone.

## Installing and leaving the channel

Installing a versioned nightly ZIP is the opt-in. Nightlies use:

```text
https://github.com/WebDevBooster/richos/releases/download/nightly/latest.json
```

That is an asset on `nightly`, a permanent prerelease whose tag moves on every
publish. It is pinned to that tag, so unlike the stable endpoint it does not
depend on which release GitHub considers `latest`, and it puts nothing on the
public repository but a release tag.

**Copies installed before 2026-09-17 point at the retired
`raw.githubusercontent.com/.../nightly-channel/latest.json` and will not see any
further nightly through the updater.** An endpoint is compiled into the binary,
so it cannot be changed by an update that copy can no longer fetch. Replace those
copies by hand, once, with any nightly published from this change onward.

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
explicit `release` or `publish` invocation exercises actual publication.

Specifically for the `build`/`publish`/`candidate` split: `nightly.test.py`
asserts `build` stops before any app upload or channel move; that `finish`
refuses a candidate whose recorded files were tampered with, with a
positive-control test that the same untouched candidate publishes under the
same mocked harness; that `finish` refuses when the built source is no longer
an ancestor of `main` (a real force-push-to-orphan-history fixture); and that
`release` (`build` immediately followed by `finish`, fused) reaches the same
call sequence and channel state as an explicit `build` followed by a separate
`finish`. `nightly-local.test.py` asserts the Runner-level wiring: `build`
records a run id and never calls the publishing subcommand; `publish` loads
the recorded candidate and calls only `finish`, without a signing credential;
`candidate` prints without running any command; and both `publish` and
`candidate` refuse a missing or unrecorded `--run <run-id>`.
