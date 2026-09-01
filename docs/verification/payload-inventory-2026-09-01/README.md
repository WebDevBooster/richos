# What ships inside RichOS and what does not — measured, 2026-09-01

**Every figure below came out of a bundle assembled and RUN on this Mac today.** Nothing is
read off a lockfile, nothing is `du` on a source tree, nothing is arithmetic on somebody
else's number. Where a figure is arithmetic it says ESTIMATE; where nobody has checked
something it says **UNPROVEN**, in those words.

Cut against `richos` `4d3619f` on branch `echo-opus-p1`. Machine: macOS 15.6 (24G84),
Apple M4, `cargo 1.95.0`, `tauri-cli 2.11.4`. Every command is named in
[§9 Reproducing this](#9-reproducing-this) and the scripts are committed beside this file
under `scripts/`.

**Why it had to be redone.** `RICH-TODOs.md` row 3.14 costed three placements — A 403.9 MiB
/ 122.0 gz, B 112.0 MiB / 40.3 gz, C 12.8 MiB / 5.6 gz — all against the ACP adapter's npm
payload, and `wiki/ceo-decisions.md` §16 deleted the adapter that same night. All three
describe a build that no longer exists. **Every number in this file replaces them.**

---

## 1. The headline, in one table

| | inside the download | fetched later | must already be there |
|---|---:|---:|---|
| **Ship nothing extra** (today's build) | **8,754,980 B** `.dmg` | nothing | Claude Code, an Anthropic login, the engine directory |
| **Option D** — same app, drives Anthropic's own installer | **8,754,980 B** `.dmg` | **197,220,928 B** | an Anthropic login, the engine directory |
| **Ship the `claude` binary inside** | **94,389,896 B** `.dmg` | nothing | an Anthropic login, the engine directory |

And the question that had to be settled before any of them meant anything:

> ## Does RichOS still need Node? **NO.**
>
> MEASURED twice, not reasoned about. A real turn completed and the shipped bundle
> attached its compute lease with `node` and `npm` absent from `PATH`. §2.

---

## 2. The Node question, answered by measurement

### 2.1 A real turn, with no `node` on `PATH`

`scripts/nodetest2.sh`. The environment is a normal one; the only change is a `PATH` of
`/usr/bin:/bin:/usr/sbin:/sbin`, which on this Mac contains no `node` and no `npm`.

```
node on PATH? -> NONE
npm  on PATH? -> NONE
[roundtrip] claude  = /Users/alex/.local/bin/claude
[roundtrip] session = 9c98da3f-dda2-4b3e-88c8-929708715911

CEO> Reply with exactly: NODE-FREE-TURN-OK

Rich> NODE-FREE-TURN-OK

[roundtrip] turn state = Completed, stop = Some("end_turn")
```

Prompt in, model reply out, turn `Completed`, ledger written — no Node anywhere.

### 2.2 The SHIPPED bundle, with no `node`, no `whisper-cli`, no `ffmpeg`

`scripts/appboot2.sh`, run against the `.app` this branch produced:

```
node -> NONE; whisper-cli -> NONE; ffmpeg -> NONE
[richos] compute lease attached over /Users/alex/.local/bin/claude
[richos] loro Tier C: no corpus configured — re-primes carry no company memory
[richos] no RICHOS_SERVICE_BIN — spoken corrections will be recorded and asked, and
         confirming one will report that there is no vocabulary to write to
```

Raw: `raw/boot-engine-ok.log`.

### 2.3 What Node would still buy, and why none of it is on the critical path

Four callers of `node` survive in the tree. Every one is env-gated, every one returns
"absent is an ordinary install" rather than an error, and none is reached to talk to Rich:

| caller | gate | what is lost without Node |
|---|---|---|
| `crates/richos-core/src/loro.rs:143` context compiler | `LORO_CORPUS`/`LORO_ROOT` + `RICHOS_LORO_DIR` | re-primes carry no company memory (`LoroTier::NotWired`) |
| `crates/richos-core/src/correction.rs:286` loro writer | same | the correction desk refuses rather than pretends |
| `crates/richos-core/src/staging.rs:210` vocabulary | `RICHOS_SERVICE_BIN` | spoken corrections stage and ask, but confirming has nowhere to write |
| `tools/richos-service` call transcription | `RICHOS_SERVICE_BIN` | call transcription, which is not in the app at all |

The loro tools are deliberately outside this repository (`loro.rs:116-123` — "richos has no
`loro/` directory and never has"), so they could not be bundled even if the decision went
the other way.

**So: Node is not shipped, is not needed, and is not a prerequisite for the product's core
function.** It remains a prerequisite for *the CEO's own dogfood install*, where the loro
corpus and `richos-service` are configured.

---

## 3. What is actually in the `.app` — all four files of it

Built with `app/scripts/package-app.sh` (exit 0, cdhash `d6b3409f152809d7fd47195aa0f4885c50c8831d`).
`scripts/measure.sh` lists it; apparent bytes via `stat -f %z`, never `du`:

| file | bytes |
|---|---:|
| `Contents/MacOS/richos-tauri` | 17,267,552 |
| `Contents/Resources/icon.icns` | 1,092,207 |
| `Contents/_CodeSignature/CodeResources` | 2,440 |
| `Contents/Info.plist` | 1,275 |
| **total on disk** | **18,363,474** (17.51 MiB) |

**There is nothing else in there.** No models, no `node`, no `whisper-cli`, no `ffmpeg`, no
`claude`, no engine directory. The UI is not a directory in the bundle either — Tauri
brotli-compresses `ui-dist/` *into* the executable, which is why the whole application is
four files and why the 17.3 MB binary is bigger than a Rust binary has any business being.

Distribution artifacts built from it:

| artifact | bytes | command |
|---|---:|---|
| `.dmg` (UDZO, zlib-9) | **8,754,980** (8.35 MiB) | `scripts/dmg2.sh` |
| `.tar.gz` (gzip -9) | 8,651,494 (8.25 MiB) | `scripts/assemble.sh` |

> **A defect found on the way, and it is not cosmetic.** `cargo tauri build --bundles app,dmg`
> **FAILED** on this machine: `error running bundle_dmg.sh`, exit 4, with no further
> diagnosis in the log. The `.app` was produced correctly by the same run. This is exactly
> the DMG-flakiness-vs-`.app`-completeness split, so the `.dmg` figure above comes from
> `hdiutil create -format UDZO -imagekey zlib-level=9` run directly — the same primitive
> `bundle_dmg.sh` drives, minus its cosmetic window-layout step. **UNPROVEN:** that a
> tauri-produced `.dmg` is the same size, and why `bundle_dmg.sh` fails here.

> **A second defect: a fresh clone cannot package.** `package-app.sh` exits 4 with *"Unable
> to find your web assets"* on a checkout that has never been built, because `ui-dist/` is
> gitignored and staged by `src-tauri/build.rs` — which tauri-cli checks for *before* it runs
> cargo. Workaround used here: one `cargo build --release` in `src-tauri/` first. One line in
> the script fixes it; it is not fixed on this branch because this branch is a measurement.

---

## 4. What Claude Code costs, wherever it is put

MEASURED from Anthropic's own release endpoint today (`scripts/measure-installer.sh`),
`downloads.claude.ai/claude-code-releases`, latest = **2.1.252**, platform `darwin-arm64`:

| | bytes | MiB |
|---|---:|---:|
| the binary, on disk | 197,220,928 | 188.09 |
| the raw download (`.../darwin-arm64/claude`) | 197,220,928 | 188.09 |
| the zstd download (`.../darwin-arm64/claude.zst`) | 64,300,730 | 61.32 |

sha256 `b661c6a094fcc32656bf7c0071c5b45bf900b34d4f0a1ab3d78fd59aeba2c2c7` — and it agrees
three ways: the vendor's `manifest.json` (`raw/claude-manifest.json`), the file I downloaded,
and `shasum -a 256 ~/.local/share/claude/versions/2.1.252` already on this Mac.

> **The zstd figure is a trap and this is the finding that matters for option D's headline
> number.** `install.sh` takes the 61 MiB path only `if command -v zstd`. MEASURED: there is
> no `/usr/bin/zstd` and no `/usr/bin/zstdcat` on macOS 15.6. **A customer's Mac downloads
> 197,220,928 bytes, not 64,300,730.** RichOS could ship a zstd decompressor and fetch the
> small artifact itself, but that is a thing to build, not a thing that is true.

For comparison, the number row 3.14 was costed against — the npm SDK's bundled binary,
306,111,896 B for Claude Code 2.1.232 — is **108,890,968 bytes larger than the same product
installed natively today.** The old option A was carrying a third of a payload it never
needed.

Signature of the binary, MEASURED (`scripts/gatekeeper.sh`):

```
Authority=Developer ID Application: Anthropic PBC (Q6L2SF6YDW)
TeamIdentifier=Q6L2SF6YDW
flags=0x10000(runtime)
entitlements: allow-jit, allow-unsigned-executable-memory,
              disable-library-validation, apple-events, device.audio-input
```

---

## 5. The three placements, assembled and RUN

`scripts/assemble.sh`, `scripts/assemble2.sh`, `scripts/run-options.sh`, `scripts/dmg2.sh`.
Every row was built, signed, launched, and its own boot line read back.

| | on disk | `.tar.gz` | `.dmg` | ran? |
|---|---:|---:|---:|---|
| **ship nothing extra** | 18,363,474 | 8,651,494 | 8,754,980 | lease attached |
| **ship `claude`, pristine** | 215,584,620 | 92,079,024 | 94,389,896 | lease attached over the bundled binary |
| ship `claude`, re-signed by us | 216,736,716 | 93,220,436 | — | **NO COMPUTE LEASE — it is broken** |

Boot lines, verbatim:

```
########## RUN nothing-extra-claude-present ##########
[richos] compute lease attached over /Users/alex/.local/bin/claude

########## RUN nothing-extra-claude-absent ##########
[richos] NO COMPUTE LEASE — RichOS cannot talk to Rich.

-- the bundled binary answers for itself:
2.1.252 (Claude Code)
########## RUN bundled-claude-pristine ##########
[richos] compute lease attached over …/RichOS-claude-pristine.app/Contents/Resources/claude

########## RUN bundled-claude-resigned ##########
[richos] NO COMPUTE LEASE — RichOS cannot talk to Rich.
```

### 5.1 Two findings from the bundling attempt that outrank the sizes

**1. The binary CAN ship inside a signed bundle without being modified.** With the pristine
file dropped into `Contents/Resources/` and only the outer bundle signed:

```
codesign --verify --deep --strict --verbose=2 RichOS-claude-pristine.app
  → valid on disk
  → satisfies its Designated Requirement          (exit 0)
Authority=Developer ID Application: Anthropic PBC (Q6L2SF6YDW)   ← intact
sha256 of the nested binary == the vendor manifest's checksum     ← unmodified
```

So the technical objection to that branch is weaker than assumed. What remains against it is
the redistribution right, and that is not a thing a measurement settles — see §7.

**2. Re-signing Anthropic's binary DESTROYS it, and the cause is exact.** Our ad-hoc
re-sign drops its entitlements, and Claude Code is a Bun binary that needs JIT
(`scripts/resign-cause.sh`):

```
=== entitlements: RE-SIGNED ===
Executable=…/claude
(nothing — the dictionary is gone)

=== a REAL turn through the RE-SIGNED bundled binary ===
ReferenceError: SharedArrayBuffer is not defined
      at /$bunfs/root/chunk-nqmqabr8.js:11:726
Bun v1.4.1 (macOS arm64)
exit=1
```

`--version` still prints `2.1.252` on the broken copy, which is why a packaging script that
smoke-tests with `--version` would ship a dead application. This is the same shape as the
2026-08-31 finding that `strip` killed a macOS arm64 node until it was re-signed: **any step
that rewrites this file must preserve `com.apple.security.cs.allow-jit` and
`com.apple.security.cs.allow-unsigned-executable-memory` or the product does not run.**

---

## 6. The Apple constraint option D has to answer

`scripts/gatekeeper.sh`, on the file actually downloaded from Anthropic:

| check | result | offline? |
|---|---|---|
| `codesign --verify --strict` | **valid on disk; satisfies its Designated Requirement**, exit 0 | **yes** |
| designated requirement | `identifier "com.anthropic.claude-code" and anchor apple generic and … certificate leaf[subject.OU] = Q6L2SF6YDW` | **yes** |
| `xcrun stapler validate` | `claude does not have a ticket stapled to it`, **exit 65** | — |
| `spctl -a -t exec -vv` | `rejected (the code is valid but does not seem to be an app)`, exit 3, `origin=Developer ID Application: Anthropic PBC` | no |
| quarantine xattr after `curl` | none set | — |

Control pair, same machine: `xcrun stapler validate /Applications/Claude.app` → *"The
validate action worked!"*; the executable inside it → *"does not have a ticket stapled to
it."* Same notarized product, two answers, because only a bundle can hold the ticket.

**So the honest answer for D, in one sentence:** RichOS can verify a fetched `claude`
**offline** against a pinned designated requirement — Anthropic's team ID `Q6L2SF6YDW` and
the identifier `com.anthropic.claude-code` — which is a real, strong check that works on a
plane; what it *cannot* do offline is confirm the notarization ticket, because a loose Mach-O
cannot carry one. **The fetch itself needs the network anyway**, so the offline gap is not
where it hurts: a customer on a plane with no Claude Code installed has no product either
way. Pinning the requirement is the mitigation, and it is not built.

**UNPROVEN, in those words:** RichOS contains no code that runs an installer, fetches
anything, checks a signature, or asks consent. Option D is a design, not a capability. There
is no download manager, no consent sheet, no requirement pinning, no resume, no progress. The
`.dmg` figure for D is the figure for "ship nothing extra" because **today they are the same
build.**

---

## 7. The thing this measurement found that outranks the whole question

**A double-clicked RichOS cannot talk to Rich on a customer's Mac — with Claude Code
installed and logged in.** MEASURED, `scripts/cwd-isolate.sh`, `raw/run-cwd-root.log`. One
variable changes between these two runs and it is not the binary:

```
### A — cwd=/  RICHOS_ENGINE_DIR=<unset>
[richos] NO COMPUTE LEASE — RichOS cannot talk to Rich.
[richos]   cause : the claude binary was not found at /Users/alex/.local/bin/claude

### B — cwd=/  RICHOS_ENGINE_DIR=/…/fake-engine
[richos] compute lease attached over /Users/alex/.local/bin/claude
```

`/Users/alex/.local/bin/claude` exists in **both** runs. Two defects, one measurement:

1. **`main.rs:395` `engine_dir()` defaults to `cwd/../engine`.** A double-clicked `.app` has
   `cwd = /`, so that is `/../engine`, which does not exist. `Command::current_dir` on a
   missing directory fails with `ENOENT`, and `NativeError` reports `ENOENT` as
   `BinaryMissing`. **A missing working directory is announced as a missing binary** — the
   one message guaranteed to send whoever sets RichOS up looking in the wrong place.
2. **The engine directory is not in the payload at all, and there is no mechanism to put it
   on a customer's Mac.** MEASURED: 4,197,726 bytes in 340 files
   (`engine/{hooks,skills,team,scripts,ceo-wiki,…}`) — Rich's persona, hooks and skills. It
   is 4 MB. It is not big. **It is simply not on the list**, and none of the three placements
   in §5 changes that.

The same launch also refuses on entity:

```
[richos] entity not resolved from /: unknown root /: no registered entity owns this path — refusing to guess
[richos] operator: set RICHOS_ENTITY to one of femcboost, deeply, prospects or richos
```

Four entity names hard-wired to the CEO's own repositories. A customer is not one of them.

**None of this makes any option in §5 wrong. It means the payload question as posed —
"where does the `claude` binary go?" — is not the whole of "what does a customer need", and
answering only it would ship a 8.35 MB `.dmg` that opens a window and cannot talk.**

---

## 8. The inventory, for the recommended option (D)

### INSIDE the app the customer downloads — 8,754,980 B `.dmg`
- `richos-tauri`, the application binary — 17,267,552 B, with the whole web UI
  brotli-compressed inside it
- the app icon — 1,092,207 B
- `Info.plist` and the code signature — 3,715 B
- **that is the complete list**

### FETCHED at install or first run
- Claude Code `darwin-arm64` — **197,220,928 B** from `downloads.claude.ai` on a stock Mac
  (61 MiB only if `zstd` exists, and it does not); installed by **Anthropic's own installer**
  to `~/.local/share/claude/versions/<version>` behind a `~/.local/bin/claude` symlink it
  retargets itself. **Not built. Design only.**
- whisper models, **on consent, only when voice is first used** — `small.en`
  487,614,201 B is `stt.rs:41 DEFAULT_MODEL_ID`. **Not built. Design only.**

### Must ALREADY be on the machine
- an Anthropic account with a Claude subscription or credit — RichOS is BYO-Anthropic and
  never intermediates a credential
- a completed `claude` login. MEASURED: credentials live in the macOS login Keychain as
  `Claude Code-credentials`; there is no `~/.claude/.credentials.json`
- the **engine directory** — §7. No route exists.
- `whisper-cli` + its ggml dylibs, for voice only — 4,185,824 B, and the Homebrew build
  cannot ship (payload-architecture §"Why Homebrew's binary cannot ship")
- `ffmpeg`, for call transcription only — not part of the app
- `node`, only for the loro corpus and `richos-service` — **not needed for the product**, §2

### Must be done BY HAND
1. install RichOS (drag to Applications)
2. install Claude Code — the step D removes
3. **run `claude` in a terminal once and log in** — RichOS has no login flow. MEASURED:
   `grep -rn "login" crates/richos-core/src src-tauri/src` returns one comment and no code.
   And the failure is silent rather than loud: in a run where the child could not reach the
   Keychain, the lease attached, the turn reported `Completed`, and Rich's reply to the CEO
   was the literal string `Not logged in · Please run /login` — a terminal instruction
   rendered as if Rich had said it. **That un-logged-in state was induced with `env -i` on
   this machine, not by a genuinely fresh Anthropic account**, so the exact wording a new
   customer sees is UNPROVEN; that whatever the `claude` binary emits is rendered verbatim
   as Rich's words is not.
4. put the engine directory somewhere and set `RICHOS_ENGINE_DIR` — §7
5. set `RICHOS_ENTITY` — §7
6. for voice: install `whisper-cli` and a model

**Steps 3–6 are not on the CEO's radar and none of them is removed by any option in §5.**

---

## 9. Reproducing this

In order. Scripts are in `scripts/` beside this file; each is standalone.

```
git -C /Users/alex/ab/richos worktree add .worktrees/echo-opus-p1 -b echo-opus-p1
export PATH="$HOME/.cargo/bin:$PATH"

# 0. a fresh checkout cannot package — stage ui-dist first (§3, second defect)
cd app/src-tauri && RICHOS_REQUIRE_REAL_ICONS=1 cargo build --release   # 1m07s

# 1. the bundle
cd app && bash scripts/package-app.sh                                    # 35s, exit 0
bash scripts/measure.sh                                                  # §3 table

# 2. the Node question
bash scripts/nodetest2.sh                                                # §2.1
bash scripts/appboot2.sh                                                 # §2.2

# 3. Claude Code's real cost, from the vendor
bash scripts/measure-installer.sh                                        # §4

# 4. assemble, sign and RUN each placement
bash scripts/assemble.sh                                                 # §5, option E
bash scripts/assemble2.sh                                                # §5.1, pristine
bash scripts/run-options.sh                                              # §5 boot lines
bash scripts/resign-cause.sh                                             # §5.1 finding 2
bash scripts/dmg2.sh                                                     # §5 .dmg column

# 5. the Apple constraint, and the finding that outranks it
bash scripts/gatekeeper.sh                                               # §6
bash scripts/cwd-isolate.sh                                              # §7
bash scripts/whisper.sh                                                  # §8 prerequisites
```

`scripts/measure-installer.sh` downloads 261 MB into a scratch directory and installs
nothing; it never writes to `~/.local/share/claude`.

---

## 10. What is UNPROVEN, in those words

1. **Option D does not exist as code.** No installer invocation, no download, no consent
   sheet, no signature pinning, no progress, no resume. Its `.dmg` figure is today's build's
   figure because they are the same build. §6.
2. **The model-fetch path does not exist either.** Nothing in the app downloads a whisper
   model. §8's "fetched on consent" is design.
3. **Nothing here is notarized or Developer ID signed.** Every bundle in §5 is ad-hoc;
   `spctl` rejects the app. This machine still has no Developer ID Application certificate.
4. **`darwin-x64` was never measured.** Every figure is `darwin-arm64`. A universal build
   carries both Claude binaries or ships two `.dmg`s — the per-architecture finding from
   2026-08-31 still applies and this pass did not re-test it.
5. **Windows: nothing.** No figure in this file applies. No Windows code-signing certificate
   exists (architecture §4.4 gap 5).
6. **The tauri `.dmg` was never produced.** `bundle_dmg.sh` failed; the `.dmg` sizes come from
   `hdiutil` directly. §3.
7. **No fresh-machine install was tested.** Nothing was copied to a clean Mac and launched;
   §7's customer case was reproduced by controlling `cwd` and the environment on this Mac,
   which is a faithful simulation and not the real thing.
8. **The licensing question is not re-opened here** and no measurement in this file bears on
   it. Row 3.14 and `richos-hq/docs/research/claude-code-redistribution-2026-08-31.md` are
   the record; §5.1's finding that the binary can ship unmodified is a *technical* result
   only.
