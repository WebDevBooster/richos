# Nightly releases

Nightlies use the next release version from `src-tauri/Cargo.toml`:

```text
1.2.0-nightly.20260911.1
1.2.0-nightly.20260911.9
1.2.0-nightly.20260911.10
1.2.0-nightly.20260912.1
```

The date is UTC, captured at allocation. The positive counter resets each UTC day
for each base version and is never padded. Failed attempts can leave gaps. After
publishing `v1.2.0`, bump the Cargo base version before the next nightly. The
allocator refuses a base that already has a stable tag.

## Schedule and manual builds

`.github/workflows/nightly.yml` runs on `main` only:

- Daily at 03:17 UTC.
- Every three hours at minute 17 while the repository variable
  `NIGHTLY_BURST_UNTIL` is in the future. Use a timezone-qualified value such as
  `2026-09-20T00:00:00Z`. Expiry automatically returns to the daily cadence.
- Manual dispatch of the same workflow. Set `force` to build an already published
  source again. Without it, both scheduled and manual runs skip a source commit
  that already has a successful nightly.

GitHub scheduling is best effort and can be delayed. All triggers share a
concurrency group with cancellation disabled. GitHub may replace older pending
runs with newer pending runs; the cadence does not promise a build for every slot.

## First-time configuration

The workflow is shipped disabled through `NIGHTLY_ENABLED`. Implementation and
local tests do not activate publishing or change repository settings.

1. Merge this implementation into `main`.
2. Create the GitHub Actions environment `nightly`, restricted to `main`. To run
   unattended, it must not require a reviewer on every deployment.
3. Configure these environment secrets:

   | Secret | Value |
   | --- | --- |
   | `APPLE_CERTIFICATE_P12_BASE64` | Base64 of the Developer ID Application certificate and private key exported as PKCS#12 |
   | `APPLE_CERTIFICATE_PASSWORD` | Password for the PKCS#12 export |
   | `APPLE_NOTARY_KEY_P8` | Contents of the App Store Connect notarization API key |
   | `APPLE_NOTARY_KEY_ID` | Notarization key ID |
   | `APPLE_NOTARY_ISSUER` | Notarization issuer UUID |
   | `TAURI_SIGNING_PRIVATE_KEY` | Existing updater private key matching the public key in `tauri.conf.json` |
   | `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` | Updater key password, or an empty value for an unencrypted key |
   | `RICHOS_NAMED_PERSONS` | Contents of the real private release deny-list |

4. Ensure repository rules permit the workflow token to create
   `v*-nightly.*` tags and create/fast-forward `nightly-channel`. Do not grant it
   permission to bypass protection of `main`. Treat nightly tags as permanent.
5. Set the repository variable `NIGHTLY_ENABLED=true`, then manually dispatch
   `nightly` on `main` and inspect the first release before enabling a burst window.

Only the release job gets `contents: write`. Credentials exist in temporary files
and a temporary signing keychain, removed by an `always()` cleanup step. The
workflow uses a disposable Apple Silicon macOS runner because the current bundled
runtime recipe supports only `aarch64-apple-darwin`. Intel and Windows builds are
not advertised by its manifest.

## Source and publication

The planner records an exact source SHA. Before any tag is pushed, the workflow
builds the pinned public runtimes, runs the core/updater/packaging tests and checks
the source tree against the private deny-list. Missing dependencies or failed
checks stop publication.

The allocator then creates a child commit containing only:

- The full nightly version in the app Cargo manifest and its lockfile entry.
- The nightly updater endpoint in `tauri.conf.json`.
- `richos/app/nightly-build.json`, recording the source SHA, version, UTC timestamp
  and Actions run/attempt.

It pushes a unique tag pointing at that child commit and builds from a clean,
detached checkout of it. It never commits version bumps to `main`. The tag's source
archive therefore contains exactly the version and channel configuration that
were built. Pushing the tag reserves the number; an existing tag is never forced
or reused. Competing allocators fail safely instead of replacing a reservation.

The pipeline reuses `make-release.sh` in this order:

1. Build and reproduce the engine asset, including the verified public runtimes.
2. Create a GitHub prerelease with `--latest=false` and upload its engine asset.
3. Download the published engine and verify the digest before compiling its pin
   into the app.
4. Build, Developer ID sign, notarize and staple the app. Check the full version in
   both its plist and the executable's isolated update-identity probe.
5. Upload the app archives, updater signature, build provenance and checksums.
   Upload the release's `latest.json` last. No asset upload uses `--clobber`.
6. Run `make-release.sh verify-assets` to download the immutable assets, compare
   their digests and verify the manifest's version and updater signature.
7. Publish `latest.json` and `build-info.json` together in a commit on the
   `nightly-channel` branch. A compare-and-swap push rejects a competing publisher.
   Promotion also rejects an older/equal version or a regressed/divergent source.

The public prerelease initially contains only the engine while the app builds.
It is not an available app update until step 7 succeeds. An incomplete release
never displaces the previous working nightly. The channel update is an atomic Git
ref change; GitHub's raw-content CDN may serve the previous good manifest briefly.

## Installing and leaving the channel

Downloading and installing a versioned nightly ZIP is the opt-in. That build uses:

```text
https://raw.githubusercontent.com/WebDevBooster/richos/nightly-channel/latest.json
```

Stable builds keep their existing stable endpoint. No settings toggle is added.
Nightlies use the same app identifier, signing identity and data as stable RichOS;
they are replacement builds, not a separate side-by-side application.

Nightly installs stay on the nightly channel. To leave it, install a stable build
whose version is at least as new as the installed nightly. For example, stable
`1.2.0` supersedes every `1.2.0-nightly.*`; stable `1.1.0` does not. Do not rely on
an automatic downgrade or on older binaries understanding newer application data.

## Failure and retry

A failed attempt leaves its reserved tag and any published assets intact for
inspection. Retry the workflow to allocate a fresh number; never replace files
under an existing nightly version. A successful run skipped on retry can be rebuilt
with manual `force=true`. The next allocation scans remote tags, including failed
attempts, so cleanup of CI logs does not reset the counter.

No automatic deletion of old releases is configured. Older installed apps pin
engine URLs from their own release. Deleting those assets can break first-run setup
or repair for those installations.

Disable new builds with `NIGHTLY_ENABLED=false`. This does not cancel an in-progress
release or remove the existing update manifest. To replace a bad offered build,
ship a corrected higher nightly version. The publisher deliberately refuses to
move the channel backwards.

## Local verification

```sh
bash richos/app/scripts/nightly.test.sh
bash richos/app/scripts/make-release.test.sh
cargo test --locked --manifest-path richos/app/crates/richos-user-update/Cargo.toml
# If installed:
actionlint .github/workflows/nightly.yml
```

The nightly suite uses local bare Git remotes to test immutable reservations,
clean generated source commits, numeric ordering, midnight rollover, schedule
expiry, skipped unchanged sources, source regression and publication races. Build,
upload and verification failures are injected to prove the channel does not move.
The native updater test installs fixture binaries through `.9`, `.10`, the next day
and the final stable version, preserving the full version and refusing downgrades.
These checks do not claim that Apple signing or the GitHub workflow has run; the
first configured hosted release must verify those external integrations.
