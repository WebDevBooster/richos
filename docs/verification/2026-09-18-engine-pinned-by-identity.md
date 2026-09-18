# The app pinned its engine by version string — what that cost, and what now identifies it

**Date:** 2026-09-18
**Engineer:** Echo (`echo-opus-enginepin2`)
**Branch:** `cc/echo-opus-enginepin2`, from richos main `ec620488`
**Occasioned by:** Ray's walk of candidate .8, escalations `esc-20260918T103641Z-1a073bd3`
(the seat failure) and `esc-20260918T104154Z-dc75f70b` (the bundle names no commit).

---

## 1. Where the engine content comes from — the answer, with citations

The question in the brief was *"find where the engine content comes from at all"*, because the
bundle carries no engine archive. It does not, and here is the whole chain.

| Step | Where | What happens |
|---|---|---|
| The asset is built | `richos/app/scripts/make-engine-asset.sh` | A deterministic `richos-engine-<version>.tar.gz` from **`git ls-files`**, not the working tree (mtimes pinned to the engine's commit time, uid/gid 0, fixed modes, `gzip -n`). It prints `engine-pin.env` with `RICHOS_ENGINE_VERSION`, `RICHOS_ENGINE_URL`, `RICHOS_ENGINE_SHA256`, and reports `repo HEAD` as `SOURCE_SHA` (`:181`, `:271`). |
| The pin enters the app | `richos/app/scripts/make-release.sh:432-438` | Those three variables are passed as ENVIRONMENT to `package-app.sh`, which passes them to `cargo tauri build`. |
| The pin is compiled in | `crates/richos-core/src/setup.rs:722-726` (`engine_pin`) | Three `option_env!` reads — **compile-time**, so the values are inside the executable and the Developer ID signature covers them. `None` is a refusal, never a fallback: there is no branch that fetches "latest" because nobody said. |
| The pin is proven to have landed | `make-release.sh:459` | `grep -a -q "$RICHOS_ENGINE_SHA256" "$exe"` — refuses to publish if the digest is not inside the executable, because an `option_env!` that never reached the compiler leaves a build that would install whatever the URL returns. |
| The asset is fetched | `crates/richos-core/src/setup.rs:1295` (`install_engine`), called from `src-tauri/src/setup_view.rs:307-333` | At FIRST NEED, from the first-run setup sheet — download, **digest before extraction**, extract, shape check, version check, `runtime::verify_engine` for 1.2.0, then an atomic swap that keeps the old copy until the new one is in place. |
| Where it lands | `setup.rs:306` (`engine_install_dir`) | `~/Library/Application Support/RichOS/engine` — `engine.rs` candidate 7, and **the only directory RichOS itself writes**. |
| What it records | `setup.rs:1413` | `INSTALLED-FROM`: `engine <version>`, `sha256 <digest>`, `bytes <n>`, `from <url>`. Written INSIDE the directory before the swap. |

**So a nightly pins an asset and ships a URL, and the engine is downloaded on the customer's
machine at first need.** Nothing is bundled — `docs/briefs/what-is-bundled-2026-09-01.md:7`:
*"No engine folder. Everything RichOS needs beyond those four files has to come from the"*
[customer]. Confirmed against the artifact: candidate .8's `Contents/Resources` holds exactly one
entry, `icon.icns`, and a `find` for `*engine*tar*` anywhere in the bundle returns nothing.

### The hole, stated as the one sentence it is

`INSTALLED-FROM` records the digest that was installed. `engine_pin()` carries the digest that is
wanted. **Before this branch, nothing compared them.** The only readers of `INSTALLED-FROM` in the
entire tree were two test assertions (`tests/setup.rs:651`, `src/provision.rs:1118`). Both halves of
the comparison were already on the machine; the fix is a comparison, not a mechanism.

---

## 2. The defect, measured on candidate .8

Every nightly publishes its own `richos-engine-1.2.0.tar.gz`, because `1.2.0` is the engine's
RELEASE and a nightly is a new CUT of it.

| | value | source |
|---|---|---|
| Installed engine's digest | `b7a882ef4381ca294259c1a01a6af29acc3159dc0b871e8064bd7f410b71da07` | its own `INSTALLED-FROM` |
| Installed engine's asset | `v1.2.0-nightly.20260917.2`, 119,463,136 B | same file |
| Candidate .8's pinned digest | `ea7f79043e7dc8f51b5f4207964ec5fa3e15ca11b44e5342a5fb4d38580db194` | `strings Contents/MacOS/richos-tauri` |
| Candidate .8's pinned asset | `v1.2.0-nightly.20260918.2` | same |
| `VERSION` in both directories | `1.2.0` | `cat VERSION` |

Cross-check, because a digest found near a URL is not yet a digest that binds: the candidate's
executable contains the **pinned** digest exactly **once** and the **installed** digest **zero**
times. The app was running an engine whose bytes it had never asked for.

`engine_accepted` (`setup.rs:244`) compared `VERSION` strings, so it returned `Ok(())`, and
`resolve_engine_dir` accepted the directory as *"engine 1.2.0 as this build pins"*.

**The consequence Ray hit:** the first background job failed 6.28 s after registration with *"the
selected engine cannot hold a separate seat for background work, and binding one here would
overwrite the CEO's own"* (`crates/richos-core/src/ecs.rs:328-333`, raised by `supports_work_seats`
at `:295`).

### The brief's flagged negative claim, discharged

The brief warned that *"the seat feature ... never reaches them"* rested on `grep -c seat_of` — one
spelling of the thing. Broadened to the feature's root word, case-insensitively, across the whole of
`ecs/`:

- **stale tree:** no file beneath `ecs/` matches `seat` in any case. `ecs/adapters/app.py` is 194
  lines and contains the substring zero times.
- **tracked tree at this branch:** ten files match — `adapters/app.py`, `adapters/mcp.py`,
  `adapters/import_records.py`, `adapters/loro_receipts.py`, `core/ecs_core.py`,
  `core/ecs_inspect.py`, `core/ecs_checkpoint.py`, `CONTRACT.md`, `tests/test_app.py`,
  `tests/test_import.py`. `app.py` defines `seat_of` at `:53` and threads a seat through `bind`,
  `fence`, `fenced` and the `current` handler.

The claim holds on the broadened pattern, not merely on the identifier. One detail that the
narrow grep would have hidden and that matters: the stale tree **does** carry
`person_id TEXT PRIMARY KEY` (`ecs/migrations/001_initial.sql:58`). The schema half was already
there and the adapter ignored the field — which is exactly why the probe had to be positive-shaped
(ask for a seat that cannot exist; a returned binding proves the field was ignored) rather than a
version comparison. `supports_work_seats` answered correctly. The fault was never in the probe.

---

## 3. What changed

Three commits, oldest first.

1. **`806277c4`** — the comparison, in `richos-core`. `InstalledFrom` + `installed_from()` (parsed
   by key, not by line position); `EngineRejected::WrongIdentity`; `EngineIdentity` / `EngineDemand`
   / `engine_accepted_demand`; `engine_boot_refusal_demand`; and `detect_with_pin` finally passing
   `p.sha256`, which it had been holding and dropping.
2. **`e684cb42`** — the wiring: resolution (`resolve_engine_dir`), the lease gate (both
   `engine_boot_refusal` call sites in `main.rs`), and the boot line.
3. **`54e79b7f`** — the bundle names its source commit.

### The rule, in one sentence

**A build that NAMES an asset boots the directory installed from that asset, and nothing else.**
A build that names none demands nothing.

The order is shape → release → identity, so the sentence an operator reads names the coarsest thing
that is wrong; a directory that is not an engine is never reported as one with a bad digest.

### Why a missing manifest is refused rather than forgiven — Ray's second finding

The first draft forgave an absent `INSTALLED-FROM` ("if RichOS stamped it, RichOS checks it") on the
reasoning that a directory RichOS never installed has no identity to be stale against. That is true,
and it leaves a hole the same size as the one being closed.

**Measured, from Ray's audit:** with the app-data engine directory absent, pid 66030 resolved its
engine to `/Users/alex/.claude/richos-engine` — the engine pointer on the machine that BUILT the
candidate, outside the walk's HOME entirely (`CLAUDE_CONFIG_DIR` was `/Users/alex/.claude`). A
signed, notarized, Developer-ID build silently running a developer's working tree.

That pointer is candidate 6 and is probed **before** the directory RichOS installs, so leniency
there is not a corner case — it is the answer a shipped build reaches first on any machine with the
engine checked out.

**Answering the question the coordinator asked directly — should that fallback exist in a release
build at all?** On the evidence: **not silently, and with this change it no longer does.** The pin
is the right discriminator, because a build carrying one is a build somebody cut and published and
has been told which engine it boots. Under this branch a pinned build refuses
`~/.claude/richos-engine` with *"the engine there has no record of what installed it, so its
contents are unknown, and this build pins ea7f79043e7d"*, and the path and that reason are both
printed at boot (`main.rs:1937` already prints every rejected candidate). An unpinned build — every
`cargo run` and `cargo test` here — resolves it exactly as before, so no developer's day changes.
The deliberate escape hatch is the documented one: `$RICHOS_ENGINE_DIR`, named once, explicitly,
which the resolver has always honored exclusively.

I did **not** remove candidate 6 from the order. Refusing it by identity achieves the safety the
finding asks for; deleting a resolution candidate is a change to Sage's documented seven-candidate
order and is not mine to make silently.

### The boot line

`engine 1.2.0 as this build pins` was the sentence candidate .8 printed *while running the wrong
engine*, so it is no longer sayable without the cut beside it:

```
engine 1.2.0 from ea7f79043e7d as this build pins
engine 1.2.0 from b7a882ef4381, NOT the ea7f79043e7d this build pins — taken as named
engine 1.2.0 with no record of what installed it, and this build pins ea7f79043e7d — taken as named
engine 1.2.0 installed from b7a882ef4381, pinned by nothing in this build
```

Read off the directory's own `INSTALLED-FROM`, never off the pin — the rule `release_note` already
stated for the version, because an explicit override may carry anything at all. Twelve hex
characters because a person reads it; the comparison behind the verdict is always over the full 64.
`gui-boot.test.sh` matches the success shape on `(via …)` with the parenthesis last; that shape is
unchanged and is now asserted rather than assumed.

---

## 4. Before and after, on this Mac, against the real directory

Run through the shipping predicates over **the actual engine directory the failing walk used** —
Rich's moved-aside copy at `…/scratchpad/richos-qa-cand8/engine-stale-103900`, read-only, nothing
written:

```
$ RICHOS_ENGINE_DIR_FIXTURE=<the real stale engine> \
  RICHOS_ENGINE_PIN_FIXTURE=ea7f79043e7dc8f51b5f4207964ec5fa3e15ca11b44e5342a5fb4d38580db194 \
  cargo test -p richos-core --test setup a_real_installed_engine -- --nocapture

shape     : engine
VERSION   : Some("1.2.0")
INSTALLED-FROM: Some("b7a882ef4381ca294259c1a01a6af29acc3159dc0b871e8064bd7f410b71da07")
  bytes  : Some(119463136)
  from   : Some("…/v1.2.0-nightly.20260917.2/richos-engine-1.2.0.tar.gz")
version-only gate : Ok(())
identity gate     : Err("the engine there carries the right version and different contents
                        — installed from b7a882ef4381, and this build pins ea7f79043e7d")
```

**BEFORE is the `version-only gate` line — `Ok(())`. That is why candidate .8 booted it.**
**AFTER is the `identity gate` line.**

Positive control, same real directory, judged against the digest it actually came from
(`b7a882ef…`): `version-only gate : Ok(())`, `identity gate : Ok(())`. The gate discriminates; it
does not merely refuse.

The test (`tests/setup.rs::a_real_installed_engine_is_judged_against_a_supplied_pin`) is env-var
gated and prints `SKIPPED` with a reason when unset — the shape `richos-voice` uses for the CEO's
private echo-path recording, so evidence that depends on something outside the repository stays
reproducible without failing a clean checkout. **It only reads.** It was deliberately NOT pointed at
`~/Library/Application Support/RichOS` — the brief forbids touching the CEO's real installation, and
a read that needs no permission still does not need doing.

### Test results

| Suite | Result |
|---|---|
| `cargo test -p richos-core` | all green, 0 failed (setup suite 52 passed, including 8 new) |
| `cargo test --bin richos-tauri` | 121 passed, 0 failed (engine module 23, including 4 new) |
| `cargo check` in `src-tauri` | Finished; **no new warning** (the one this work would have created is why `resolve_engine_dir_pinned` was removed rather than silenced) |
| `bash scripts/package-app.test.sh` | all 54 passed |
| `gui-boot.test.sh` | **NOT RUN** — a candidate was on screen for Ray's walk for the whole of this task. Rich runs it at the land, per the brief. |

---

## 5. The source commit — Ray's other finding

Measured on candidate .8: `strings` on the executable finds `1.2.0-nightly.20260918.2` and **no
commit**; `plutil -p Contents/Info.plist` prints 16 keys, of which the only identity is that same
version string. The bundle is Developer ID signed with hardened runtime
(`Authority=Developer ID Application: Alex Booster (TZ33A4QCZJ)`) — this is the artifact the CEO
walks, and it could not say what it was built from.

The asymmetry ran the wrong way: a `-dev.` build has carried its commit in its VERSION since
2026-09-17; release and nightly builds — the two that reach him — carried none.

`package-app.sh` now derives the commit once, before the build, and uses it twice: exported as
`RICHOS_SOURCE_SHA` for the cargo invocation (compiled in via `option_env!`, so the signature covers
it) and written to `Contents/Info.plist` as `RichOSSourceCommit`. It then reads the value back off
the plist and greps the SHA out of the executable, refusing to sign if either is missing.

**Why the plist write sits between the build and the signing, which had to be checked rather than
assumed:** Tauri's bundler signs the `.app` during `cargo tauri build` when it has an identity, so a
PlistBuddy write after that would invalidate the signature and the notarization with it. But
`package-app.sh` already re-signs with the full explicit argv (`--options runtime --timestamp
--entitlements`, `:1370`, added because the bundler omits `--timestamp`) and ad-hoc signs at `:1332`.
The stamp is written above both branches, so it is covered by the signature that ships.
`src-tauri/Info.plist` — which Tauri merges at bundle time — is deliberately not the place: the value
changes every commit, the file is tracked, and a build that rewrites a tracked file leaves the tree
dirty, which the freshness gates read as a build nobody can identify.

Measured: `RICHOS_SOURCE_SHA=e684cb42…-dirty cargo build` → the string is in the executable
(`grep -a -c` = 1); rebuilt with `0000…0abc` → new value present once, **old value absent**, so the
stamp cannot be served stale from cache (that needs the `cargo::rerun-if-env-changed` added to
`build.rs`). The PlistBuddy Add/Set fallback was exercised against a copy of candidate .8's real
`Info.plist`: `Add` succeeds when absent, is refused when present (so the `Set` fallback is a needed
path), and `CFBundleShortVersionString`, `CFBundleIdentifier` and `NSMicrophoneUsageDescription` all
survive. No real bundle was written to.

---

## 6. Should the asset travel with the build? — measured, and the answer is no

The brief asked for this *"or say exactly why not, with the size"*.

| | bytes | |
|---|---|---|
| Engine asset | 119,463,136 | **113.93 MiB** |
| Candidate .8's whole `.app` | — | 22.93 MiB on disk |
| Payload the CEO ruled on (per `make-engine-asset.sh`'s own citation of §19) | 8,754,980 | 8.35 MiB |

Bundling the asset takes the download from **22.93 MiB to roughly 136.9 MiB — about 6×** — on every
nightly, for a payload the CEO has already ruled on. `docs/briefs/what-is-bundled-2026-09-01.md:7`
states the decision in the repository: *"No engine folder."* `make-engine-asset.sh`'s header cites
`ceo-decisions.md` §19 as listing the engine under "What is NOT bundled", with *"Where the download
lives: THE PUBLIC GITHUB REPO'S RELEASES"* the same day. **I could not read `richos-hq` from this
worktree, so that §19 quotation is the script's, not mine** — the in-repo brief is the citation I
verified.

**So bundling it would reverse a CEO ruling, and that is his call and not an engineer's.** What this
branch does instead is make the identity travel: the app names the digest it requires, the installed
directory names the digest it came from, the two are compared, and a mismatch is refused and
reported. A candidate is therefore *verifiable* offline even though it is not *self-contained* —
`freshness-check.sh`-style verification can now read the app's source commit from `Info.plist` or
the executable and the engine's identity from `INSTALLED-FROM`, and compare both.

If the CEO wants a genuinely offline-testable candidate, the decision to put 114 MiB into every
nightly is available and is his; the mechanism would be `Contents/Resources/engine`, which
`engine.rs` already reserves as candidate 3 and which is empty today.

---

## 7. What this does NOT do — named rather than left to be discovered

1. **Nothing here performs the refresh automatically.** A stale engine is refused, reported at boot,
   and reported by detection as not installed, which routes it into the first-run setup sheet that
   already exists (`setup_view.rs` → `install_engine` → `engine_dir` rewired with no relaunch).
   I did not add a blocking 113.93 MiB download before the window opens: it would stall a cold start
   behind a network fetch, fail on a plane with nothing on screen to say why, and duplicate an
   install path that already reports progress and refuses honestly. **This is a deliberate narrower
   choice than the brief's "it (re)installs from the build's own asset", and the CEO-visible
   consequence is that a stale nightly asks him to press a button instead of fixing itself.** If
   that is the wrong trade, the automatic path belongs on the work host's thread after the window is
   up, not at boot.
2. **The refresh does re-deliver `runtime/`.** `install_engine` extracts the whole asset — which
   carries the untracked `runtime/` (`bin`, `git`, `node`, `python`, `delivery.json`,
   `runtime-sources.json`) — and runs `runtime::verify_engine` for 1.2.0 before swapping. So the
   `main.rs:2031` *"this launch has no verified Git runtime"* path is not entered by a refresh. A
   refresh that merely copied the tracked tree WOULD have caused it; nothing here does that.
3. **The engine pin's own `option_env!` staleness is not fixed.** `RICHOS_ENGINE_VERSION` / `_URL` /
   `_SHA256` are read in `richos-core`, which has no `build.rs`, so the `rerun-if-env-changed` added
   to `src-tauri/build.rs` cannot speak for them: a cached `richos-core` could in principle carry a
   previous pin. `make-release.sh:459` catches it after the fact by grepping the executable and
   refusing to publish. Whether `richos-core` should gain a `build.rs` is a question about that
   crate's deliberate no-build-script, fast-to-test shape, and is not answered silently from a
   sibling crate's build script.
4. **`gui-boot.test.sh` was not run**, because a candidate was on screen for the whole task.

---

## 8. Test-instance hygiene

**No app instance was launched by me at any point.** The candidate on screen (pid **85513**,
`./RichOS.app/Contents/MacOS/richos-tauri`, cwd `…/scratchpad/richos-qa-cand8`) is Ray's walk
instance; it was running before this task began and I neither started nor stopped it, so it is not
mine to quit. Everything above was established by reading that bundle's files (`strings`, `plutil`,
`codesign -d`), by unit tests, and by one read-only run of the shipping predicates over a directory
Rich had already moved aside. Scratch material written by me lives under the session scratchpad
(`echo-plist/`, `echo-beforeafter-home/`, `cand8-strings.txt`) and contains no copy of any engine —
the one HOME fixture is a symlink, not a copy.
