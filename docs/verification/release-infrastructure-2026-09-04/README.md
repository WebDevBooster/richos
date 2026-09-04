# Release infrastructure — 2026-09-04

The pre-publication audit's §12 said the repository had no release, an updater endpoint that
could never resolve, and a packaging dry run that "does not create a distributable release".
This is what was built, what was measured, and the three defects the measuring found — the
third found by the second one's own new cases failing after they were merged.

Every number below was produced by a command in `raw/`, and every one of those commands can
be run again.

---

## Three defects, all found by running the thing rather than reading it

### 1. The engine asset digest was a function of the operator's umask and timezone

`make-engine-asset.sh` exists to produce an archive whose SHA-256 can be compiled into the
app and checked on a customer's Mac. It normalized member order, mtimes, ownership and the
gzip header, and it had a `--check` flag that built twice and compared. It was green.

It was green because both builds ran in the same shell, so neither could fail for any reason
the other would not have failed for. Two variables the caller controls moved the bytes:

```
umask 022, TZ=Europe/Berlin   2,021,839 B   cbee8763588469de4f01f04a8f3aeaec1dc7bb1225327119c51dbdd7ebd7afb2
umask 077, TZ=Europe/Berlin   2,021,655 B   fdae7195cf0083426ead2749fb4e3f87678e29c45cf5ac77d7cce3088e073e33
umask 022, TZ=UTC             2,021,895 B   bdb82559bce916dc8945142a1f85d02a2d831609fc91bf10c24d1ac280289d96
```

* **umask.** macOS bsdtar applies the caller's umask when it extracts as a non-root user, so
  the staging copy inherited it. All 531 members differed, and they differed only in mode:
  `0755` became `0700`, `0644` became `0600`.
* **TZ.** `date -u` printed the mtime stamp in UTC and `touch -t` read it back in the *local*
  zone, so every timestamp in the archive moved with wherever the Mac happened to be.

Fixed in `166e1fd`: the staged tree is flattened to 755 for directories, 755 for anything the
source marks user-executable and 644 for everything else — content plus the one permission bit
git records — and both ends of the timestamp are pinned to UTC. `--check` now runs its second
build under another umask, another `TMPDIR`, the C locale and UTC, and `L13` in
`make-engine-asset.test.sh` runs the real script under two opposed environments and requires
one digest.

**After the fix, `raw/engine-asset-determinism.txt`:**

```
umask 022  TZ=Europe/Berlin   bdb82559…  2021895 bytes
umask 077  TZ=UTC             bdb82559…  2021895 bytes
umask 027  TZ=Asia/Tokyo      bdb82559…  2021895 bytes
independent clone, other path  bdb82559…  2021895 bytes
```

The clone is a separate `git clone` of the same commit at a different absolute path, built
under `umask 027`, `TZ=Asia/Tokyo`, `LC_ALL=en_US.UTF-8`. Byte for byte the same archive.

### 2. A release could not be cut from a clean checkout

The first `package-app.sh` run in a fresh worktree exits 4:

```
Error Unable to find your web assets, did you forget to build your web app?
      Your frontendDist is set to "../ui-dist"
```

`build.rs` creates `app/ui-dist`, but it runs during the cargo build, and tauri-cli tests the
directory before that on nothing but `!web_asset_path.exists()`
(`tauri-cli-2.11.4/src/build.rs:198-207`). The development machine's older checkout worked
only because an earlier build had left the directory behind — so the failure was invisible
exactly where releases are not cut, and certain everywhere they are. Fixed in `73ac349` by
creating the directory and nothing else; `build.rs` still owns its contents, because a second
staging implementation is one that can drift from the one deciding what ships.

### 3. The asset was built from the operator's disk, not from the repository

Found the same day by defect 1's own new cases. `L12` and `L13` were green on the worktree
that wrote them at `166e1fd`; merged to main, both went red. **A fresh worktree has none of
the state a working checkout accumulates, which is exactly why the suite looked clean where it
was written.** Raw evidence: `raw/engine-asset-untracked-members.txt`.

The cause was one line:

```sh
( cd "$ENGINE_DIR" && /usr/bin/tar -cf - . ) | ( cd "$staging/engine" && /usr/bin/tar -xf - )
```

It copied the WORKING TREE, so every gitignored file in `engine/` went into the customer's
download. On main: **119 of them.** Fifteen `.claude/state/agent-definitions-*.snapshot`, each
carrying a **session UUID**, a generation timestamp and `/Users/alex/ab/richos/engine`. 57
`scripts/hooks/*.sha256` sidecars that `install.sh` re-mints on every run. `__pycache__`
bytecode. Two defects wearing one coat:

* **The digest moved.** A new session mints a new snapshot, so `RICHOS_ENGINE_SHA256` was a
  property of *when* the build ran. Reproduced with 205 ignored files planted: build, one new
  snapshot file, build — `4fcb8b46…` became `e30083c5…`. A customer meets that as a
  `DigestMismatch`.
* **A privacy leak into a published artifact.** Session identifiers and the builder's home
  path, to everyone who downloads the engine — the same class the shipped-artifact privacy
  pass had removed from the executable hours earlier, arriving through a different door into a
  different artifact, with nothing watching that door.

**Nothing published carried it.** `WebDevBooster/richos` has zero releases and zero tags
(`gh api repos/WebDevBooster/richos/releases` returns `[]`). A defect, not an incident.

**The fix, and the check that is not the fix.** The asset is built from `git ls-files`, so a
file that is not tracked is not in it — by construction, with no exclusion list, because an
allowlist of harmless ignored files drifts from the ignored files that exist. Outside a
checkout the script REFUSES rather than falling back to the working tree; a silent fallback
would be a fallback into the leak. Then the finished archive is read back by
`app/scripts/verify-engine-asset-members.sh`, which compares its members to the tracked set in
both directions and names every one it refuses.

**Why the members check exists at all, given `--check` caught this one.** It caught it by
accident — because that particular ignored file changed. **An ignored file that never changes
passes a determinism check forever**, and that is measured rather than argued: with 205 ignored
files planted and then left alone, all thirteen cases reported green while 208 untracked
members sat inside the archive. Determinism asks whether the bytes are the same twice; only a
content check asks what the bytes are. `L14`–`L18` ask it, and each was run red first — `L14`
and `L15` by restoring the old copy line (207 untracked members, named), `L16` against a
deliberately poisoned archive, `L17` by deleting the members check, `L18` by removing the
fixture's `.git`.

**The pin did not change.** The fixed build produces `bdb82559…` at 2,021,895 bytes — byte for
byte the archive the independent clone above produced, because a fresh clone never had the
ignored files in the first place.

---

## The updater endpoint

```
https://github.com/WebDevBooster/richos/releases/latest/download/latest.json
```

Read off `tauri-plugin-updater-2.11.0` and `reqwest-0.13.4` rather than off a blog:

| Claim | Where it comes from |
|---|---|
| a static manifest may carry every platform in one document | `updater.rs:79-86` — `RemoteReleaseInner::Static { platforms: HashMap<String, ReleaseManifestPlatform> }` |
| the platform key is `{os}-{arch}` | `updater.rs:1394-1424`, `updater_os` / `updater_arch`, composed by the public `target()` |
| `{{target}}` and friends are substituted into the URL, so they need a host that templates | `updater.rs:475-487` |
| three redirects are fine | `reqwest-0.13.4/src/redirect.rs:160-165` — the default policy is `limited(10)`, and the plugin never overrides it |
| a `Content-Type` that is not JSON is fine | `reqwest-0.13.4/src/async_impl/response.rs:269-273` — `json()` deserializes the body without looking at the content type |
| a release build refuses a non-https endpoint outright | `config.rs:validate_endpoints` |

**Measured, `raw/github-releases-url-shape.txt`:**

```
EcoPaste  /releases/latest/download/latest.json   200, 3 redirects, application/octet-stream, 8829 B
          top-level keys : notes, platforms, pub_date, version
          platform keys  : darwin-aarch64, darwin-aarch64-app, darwin-x86_64, …
```

**And the failure mode this shape has, which two live projects are sitting in:**

```
lencx/ChatGPT        404  ->  .../releases/download/v1.1.0/latest.json
pot-app/pot-desktop  404  ->  .../releases/download/3.0.7/latest.json
```

Their newest release carries no `latest.json`, so their updater endpoint answers 404 to every
copy they have shipped. `latest` resolves against whatever GitHub currently calls the newest
release, so an application release must always carry the manifest, and it is uploaded last.

The mitigation for an engine-only release was checked rather than assumed. `neovim/neovim`
publishes a `nightly` pre-release daily:

```
nightly  prerelease=true   published 2026-09-04T05:25:34Z
v0.12.5  prerelease=false  published 2026-08-23T18:27:13Z
releases/latest -> v0.12.5
```

`latest` skipped a release published twelve days later because it was marked pre-release.

---

## The signing key

Rotated from `A6BCB0F9A1ADED42` (`richos-updater-TEST.key`) to `2F218991C928FD0A`
(`richos-updater.key`), before anything was installed anywhere but the development machine.

The two keys are cryptographically identical, so the argument is the name: the old one was
the default key of an automated harness that also generates deliberately wrong keys, and a
file called TEST is one somebody deletes. Deleting it cannot be undone — the public half is
compiled into every installed copy, so the remedies are never shipping another update, or a
manual reinstall per machine. Rotating cost a rebuild today; it costs a person's reinstall
after the first external install, and ten people's after the tenth.

The reasoning, including why the key has no password and why adding one later should be
treated as a new pair, is in `app/UPDATES.md`.

**Proven on the new key, `raw/updater-e2e-on-the-new-key.txt` — all 10 cases:**

```
A   0.1.0 fetched the manifest and found 0.1.1
B   it downloaded the archive, the signature VERIFIED, and it installed
C   the bundle on disk is 0.1.1, read from the installed Info.plist
D   the replaced bundle relaunched and reports itself as 0.1.1 and up to date
T   a tampered archive was refused as a SIGNATURE failure; installed bundle untouched
K   an archive signed by another key was refused the same way
```

`T` and `K` are the point as much as `A`–`D`. Neither asserts that the code contains a check;
each corrupts the artifact and requires the install to fail.

---

## The release chain

`app/scripts/make-release.sh`, five subcommands, and `app/RELEASING.md` for why. It never
creates a release and never uploads; its only network calls are downloads.

The order is forced by the pin: the engine's URL and SHA-256 are compile-time constants inside
the executable the code signature covers, so the asset has to be published before the app that
pins it is compiled, and the digest has to come from the bytes that will actually be served.
`verify-engine` fetches them; `app` refuses to build without that receipt.

**Rehearsed end to end, `raw/release-rehearsal.txt`** — ad-hoc signed, with the engine asset
served from a local HTTP server so `verify-engine` had something real to read back:

```
the engine digest IS inside the executable, so the signature covers it.
extracted and checked: codesign OK
VERIFIED: latest.json  version 0.1.0  platform key darwin-aarch64
          signature matches the .sig and verifies over RichOS.app.tar.gz (9896982 bytes)
SHA256SUMS written, and read back with `shasum -c`:
  RichOS-0.1.0-macos-aarch64.zip: OK
  RichOS.app.tar.gz: OK
  RichOS.app.tar.gz.sig: OK
  latest.json: OK
  richos-engine-1.0.0.tar.gz: OK
```

The bundle reported `0.1.0` with no `version` key in `tauri.conf.json` at all, which is the
whole of the single-source change: the Cargo manifest is the only copy.

**And the refusals, `raw/make-release-refusals.txt` and
`raw/verify-release-refuses-an-unpublished-release.txt`:**

```
make-release.test.sh: all 10 passed
verify-release against the real, unpublished URLs: 5 MISSING, endpoint 404, exit 1
```

---

## What could not be verified without a published release

* That the endpoint returns the manifest. It answers 404 today, which is the correct answer
  for a repository with no releases, and it is the one thing only publication can change.
* That the redirect chain and the download behave the same on `WebDevBooster/richos` as on the
  public project measured above. The mechanism is GitHub's and is not per-repository, but the
  measurement is somebody else's repository.
* That notarization survives this chain. The rehearsal was ad-hoc signed on purpose — the
  Developer ID path was proven separately today and `make-release.sh app` defaults to it, but
  the two have not yet run in one pass.
* That an update crosses a real network. `updater-e2e.sh` is `127.0.0.1` over http with the
  insecure-transport flag; the shipping config keeps https mandatory and TLS remains unproven
  because there has been no host to prove it against.

## Whole suite, after all of it

```
8 suite(s) discovered under app/scripts
=== app/scripts: all 8 suites passed — 156 checks ===
```
