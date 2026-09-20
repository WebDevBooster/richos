# Artifact verification ownership

| Property | Owner |
| --- | --- |
| Executable, signature, entitlements, signing identity and requested stapled ticket | `scripts/package-app.sh`, shared by build and `--verify-only` |
| Icon, version, microphone declaration, permissions and absence of application state | The same bundle verifier |
| Contained member paths, compiled source stamp, home paths and private names | `scripts/lib/bundle_invariants.py`, called by the bundle verifier |
| One top-level `engine/` in the archive and exact tracked membership plus declared runtime | `scripts/make-engine-asset.sh` and `scripts/verify-engine-asset-members.sh` |
| Installed engine files directly inside the installed engine root | `crates/richos-core/src/setup.rs` |
| Required normalized phone shell paths, including the uncached service worker | `src-tauri/build.rs`; embedded bytes are covered by the app signature |
| Compiled updater channel, engine pin and release version | `scripts/nightly.py`, `scripts/make-release.sh` and their release smoke checks |

Member counts are diagnostics. They are not completeness or performance limits.
Notarization is required only when requested. `--verify-only --expect-notarized`
checks a ticket without submitting, signing or modifying the bundle.

Finished-bundle privacy checks use the existing home-path predicate and the
external named-persons list. Set `RICHOS_NAMED_PERSONS_FILE` to override that
list's location. A missing or invalid list refuses verification. Binary printable
UTF-8 strings and member paths are scanned; compressed or encrypted payloads
are outside that string scan's coverage. Findings never echo a matched name.

## Headless packaged-component probe

The release builder calls `scripts/lib/probe_packaged.py` before creating the
first-install archive. It verifies the engine archive against the compiled pin,
stages the app and delivered engine in a disposable installation then runs:

- The app's existing `--richos-internal-update-identity` entry point.
- The engine's Loro compiler using the delivered Node executable and an empty
  disposable corpus.

The macOS sandbox grants content reads to that installation, `/System`,
`/usr/lib`, `/usr/share/icu`, `/private/var/db/dyld` and three device files:
`/dev/null`, `/dev/random` and `/dev/urandom`. dyld also needs to open the root
directory itself; that exact-directory allowance grants no recursive reads.
Metadata queries, system calls and Mach services needed by the loader are
allowed. Writes stay inside staging. Network access is denied. The environment
is replaced, Node's global search paths are disabled and inherited descriptors
other than standard input/output/error are closed by the process launcher.

Every probe also removes a required compiler module and leaves a valid copy
outside staging, connected by a symlink. The isolated compiler must fail.
Removing the read restriction must make that same negative case pass. Restoring
the module inside staging must recover the original result.

This checks native loading, identity and compiler dependency resolution.
It does not exercise the application window or invoke external providers such
as Claude or speech models. Full startup and provider acceptance remain VM work.
The isolation design follows the guard-the-guard principle in
[T3 Code's artifact builder](https://github.com/pingdotgg/t3code/blob/d6f291303ddc0c9a14f570266a4d9eff6d431593/scripts/build-desktop-artifact.ts).
