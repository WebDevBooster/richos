# First-run setup — measured 2026-09-02

Machine: macOS 15.6, Apple M4. Every number and every line below is a reading taken from a
running process, a real network request, or a directory on disk. Nothing is inferred from an
exit code.

**The gap this closes, in the record's own words** (`ceo-decisions.md` §19): *"today RichOS
runs on his Mac and would not run on anyone else's"* — a customer needs Claude Code **and**
the engine directory, and the engine *"ships in no payload and has no route onto another
machine at all"*.

This is the sibling of `first-run-provisioning-2026-09-01/`, not a replacement for it. That
one puts the CEO's **corpus** on a machine that has none; this one puts the two **executables**
there.

---

## 0. Where the engine comes from, and why it needed no new ruling

**Fetched from the public repository's Releases, as a deterministic tarball whose SHA-256 is
compiled into the app.** Not bundled. Four reasons, none of them a new decision:

1. **§19 lists the engine directory under "What is NOT bundled"** and fixes the payload at
   four files and 8,754,980 B, on a measurement of exactly that payload. The engine is 5.8 MB
   on disk. Putting it in `Contents/Resources/engine` contradicts a ruling made the same day
   on the number it would change.
2. **He ruled where the download lives the same day**: *"Where the download lives: THE PUBLIC
   GITHUB REPO'S RELEASES."* The engine already **is** in that repository — `<repo>/engine`,
   `VERSION` 1.0.0 — so the asset needs no new host and no new mechanism. This is the
   intersection of two rulings, not an invention.
3. **The engine moves on its own cadence.** Hooks, skills and agent definitions change without
   the Rust changing. A fetched engine updates without a new signed, notarized `.app`; a
   bundled one makes every hook edit a release.
4. **Verification is the same act either way.** The app's Developer ID signature covers the
   pinned digest, so a fetched engine's integrity rests on the same signature a bundled one
   would have rested on.

It lands at `~/Library/Application Support/RichOS/engine`, which is `engine.rs`'s **candidate
7 verbatim** — the slot its own header calls *"the known per-user location an installer could
populate on a customer's Mac"* and, until now, *"Nothing puts one there today either."* The
resolver needed no change. That is why this path and no other.

**The cost, stated:** the pin is per-release, and a build with no pin **refuses** to install an
engine rather than trusting whatever a URL returns. There is no "fetch latest because nobody
said" branch anywhere.

---

## 1. The gap, proved on a machine state with no engine — `raw/gap-proof.log`

`scripts/gap-proof.sh` builds the real binary, assembles it into a minimal `.app` **outside
the repository**, and boots it with `cwd = /` and `env -i HOME=<throwaway> PATH=…` — the GUI
condition LaunchServices produces. All seven of `engine.rs`'s candidates are genuinely absent,
and the bundle is outside the repo specifically so candidate 4 (an `engine/` above the
executable) cannot find the dogfood one and make the run meaningless.

```text
[richos] engine directory: NOT FOUND — 5 place(s) tried
[richos]   looked in …/RichOS.app/Contents/Resources/engine (app bundle resources)
[richos]   looked in …/RichOS.app/Contents/MacOS (repo layout above the executable)
[richos]   looked in / (repo layout above the working directory)
[richos]   looked in <HOME>/.claude/richos-engine (engine install pointer)
[richos]   looked in <HOME>/Library/Application Support/RichOS/engine (application support)
[richos] NO COMPUTE LEASE — RichOS cannot talk to Rich.
[richos]   binary: claude
[richos]   engine: <HOME>/Library/Application Support/RichOS/engine
[richos]   cause : the engine directory … does not exist — RichOS runs Claude with that
                  directory as its working directory and cannot start without it
                  (this is NOT a missing claude binary)
[richos] first-run setup: Claude Code is NOT installed — looked in: <HOME>/.local/bin/claude;
                  /usr/bin/claude; /bin/claude; /usr/sbin/claude; /sbin/claude
[richos] first-run setup: the RichOS engine is NOT installed — looked in: …
[richos] first-run setup: this build carries NO engine pin, so it cannot install one.
```

That is a customer's Mac, and the app on it. **Residue: 0.**

**The CEO's machine was not touched, and this script cannot touch it.** The provisioning proof
had to remove his corpus pointer and put it back — and *"his engine pointer was left dangling
once tonight by a red-run fixture"*. This one never removes anything: the customer state is
produced by a throwaway `HOME` and `env -i`, so there is nothing to restore and nothing to get
wrong. Verified anyway, before and after:

```text
~/.claude/richos-engine                          symlink -> /Users/alex/ab/richos/engine
~/Library/Application Support/RichOS/loro-root   symlink -> /Users/alex/ab/richos-hq
~/Library/Application Support/com.richos.app     6 files, sha256 diff EMPTY
```

---

## 2. A fresh install, set up, and booted — `raw/fresh-install.log`

`scripts/fresh-install.sh` against a `HOME` that has never seen RichOS.

### 2.1 The release asset, built deterministically

```text
version 1.0.0
bytes   1,471,173
sha256  780efe0ff79d5a9a23b23126bca3a9a68b64723d02bb6deb1a36927cbb206837
files   359
--check: built twice, first == second, IDENTICAL
```

That digest is then compiled into the demo and the app through `RICHOS_ENGINE_SHA256`, which
`crates/richos-core/build.rs` declares `rerun-if-env-changed` for — without that line a build
with a changed pin is a cache hit carrying the OLD digest while the log claims the new one.

### 2.2 Before

```text
Claude Code        MISSING   tried <HOME>/.local/bin/claude; /usr/bin/claude; /bin/claude;
                             /usr/sbin/claude; /sbin/claude
the RichOS engine  MISSING   tried …/Resources/engine; <HOME>/.claude/richos-engine;
                             <HOME>/Library/Application Support/RichOS/engine
engine pin         this build installs engine 1.0.0
```

And what the CEO would be shown — no path, no version, no terminal:

```text
Claude Code — the program I think with. It comes from Anthropic and installs itself;
              I only ask it to.
the RichOS engine — the part of me that knows how I work — my instructions and my team.
```

### 2.3 Claude Code, installed by Anthropic's own installer, over the real network

```text
url:       https://claude.ai/install.sh
installer: 9,704 bytes
installed: <HOME>/.local/bin/claude
signature: VERIFIED — valid on disk; satisfies the Anthropic PBC designated requirement
checked:   <HOME>/.local/share/claude/versions/2.1.258
```

RichOS wrote none of that. It downloaded Anthropic's script, ran it unmodified, then located
the result **from scratch** and verified it — an installer that exits 0 having installed
nothing is `ClaudeStillMissing`, not a success.

### 2.4 The engine, verified and installed atomically

```text
downloaded 1,471,173 bytes
digest     MATCHED the pin        (checked BEFORE tar was handed the bytes)
installed  <HOME>/Library/Application Support/RichOS/engine
version    1.0.0
files      360   (359 from the archive + INSTALLED-FROM)
```

The stamp, written inside the artifact so a stale copy is detectable rather than silent:

```text
engine 1.0.0
sha256 780efe0ff79d5a9a23b23126bca3a9a68b64723d02bb6deb1a36927cbb206837
bytes 1471173
from https://github.com/WebDevBooster/richos/releases/download/engine-v1.0.0/richos-engine-1.0.0.tar.gz
```

### 2.5 THE BOOT LINE — the same bundle, the same GUI condition, after setup

```text
[richos] engine directory: <HOME>/Library/Application Support/RichOS/engine (via application support)
[richos] compute lease attached over <HOME>/.local/bin/claude
[richos] first-run setup: nothing missing.
```

`via application support` is candidate 7 answering for the first time in this product's life.

**Residue: 0.** Throwaway HOME at the end: 195 MB, removed. His state: byte-identical, diff
empty.

### 2.6 What this run does NOT prove, said plainly

- **The engine asset's HTTPS transport.** `WebDevBooster/richos` is private today and §18
  sequences the license — and therefore the repository going public, and therefore its
  Releases — last. So the engine bytes came from the file `make-engine-asset.sh` had just
  produced. Everything downstream of the fetch is the shipping code, and the transport itself
  is `/usr/bin/curl`, which **the same run exercised for real** downloading Anthropic's
  installer, and which `failure-paths.sh` exercises against the real host for a real 404.
- **That a turn would answer.** The lease attached; RichOS is BYO-Anthropic and the customer
  still needs his own account and his own login. A handshake attaching is not a claim that a
  conversation would.
- **Signing and notarization of this bundle.** It is assembled unsigned, on purpose: it exists
  to put the resolver in a GUI launch's conditions. Signing is a different proof and lives in
  `docs/verification/developer-id-signing-2026-08-31/`.
- **Windows, and `darwin-x64`.** Neither was measured. `CurlFetcher`, `TarExtractor` and
  `BashRunner` are all absolute POSIX paths.

---

## 3. Every failure path, against the real system — `raw/failure-paths.log`

The unit suite exercises all twelve failures through injected seams, which is where they
belong. This runs the ones that only mean something against the real thing — because two
defects found on 2026-09-01 were invisible to a fake, and both are recorded in §4 below.

| What was done | What he reads | tag | Mac unchanged | residue |
|---|---|---|---|---|
| a host that cannot resolve (`.invalid`) | *"I couldn't reach the internet, so there's nothing to download yet. Connect and try again — nothing has been changed on your Mac."* | `no-network` | yes | none |
| a real 404 from the real host, for a tag that does not exist | *"The download didn't arrive (… answered curl: (56) The requested URL returned error: 404). Nothing has been changed on your Mac."* | `download-failed` | yes | none |
| a plain-http URL | *"… answered curl: (1) Protocol "http" disabled …"* | `download-failed` | yes | none |
| a tampered archive | *"What downloaded isn't what this copy of RichOS expects, so I stopped and installed nothing."* | `digest-mismatch` | yes | none |
| a real gzip tarball with the wrong thing inside, through real `tar` | *"The download opened, but what was inside it isn't a RichOS engine (expected a single `engine` folder inside, found: not-an-engine)."* | `engine-shape-invalid` | yes | none |
| an engine-shaped archive with the wrong version | *"The download is the wrong engine — it says version 9.9.9, and this copy of RichOS expects 1.0.0."* | `engine-version-mismatch` | yes | none |
| an unsigned file named `claude`, through real `codesign` | *"Claude Code installed, but macOS won't confirm it came from Anthropic, so I'm not going to run it."* | `signature-rejected` | no, and it says so | none |

The tampered-archive case is run with an extractor that **panics if it is ever called**. It is
not called: the digest is checked before `tar` is handed anything.

`http` being refused by curl itself matters because the pin's https rule is a string check —
this is the same rule enforced at the wire, so a redirect cannot talk it out of one.

The remaining five (`no-home`, `download-incomplete`, `engine-unpinned`, `installer-refused`,
`claude-still-missing`, `install-failed`) are covered in `crates/richos-core/tests/setup.rs`,
including a panic mid-install leaving no residue and a failed reinstall leaving the engine the
customer already had.

---

## 4. Two defects the tests found, and neither was visible to a fake

**1. `codesign -R <text>` reads its argument as a FILENAME.** Handed the requirement itself it
prints `<requirement>: No such file or directory` / `invalid requirement specification` and
exits non-zero — which is indistinguishable from a bad signature. The first version of this
module made that mistake, and the result was a **false rejection of a genuine Anthropic
binary**. A leading `=` makes `codesign` read the text; `setup::codesign_requirement_arg()`
carries it and a test asserts it does.

**2. `xcrun stapler` exits 0 on a symlink having validated nothing.** Measured both ways:

```text
xcrun stapler validate ~/.local/share/claude/versions/2.1.257
  -> "Stapler is incapable of working with Document files."   exit 66
xcrun stapler validate ~/.local/bin/claude          # the SYMLINK RichOS resolves
  -> "Stapler is incapable of working with Alias files."      exit 0    <-- A FALSE PASS
```

So stapling is not merely unavailable for a loose Mach-O (`Sealed Resources=none`) — it is a
**trap**, because the false pass lands on exactly the path RichOS uses. Nothing in this module
calls `stapler`. `verify_claude_signature` resolves the symlink first, so its verdict names
the file it actually checked.

**A third, found by a residue assertion rather than by reading:** a successful install left
`engine.incoming.<pid>.<nanos>` beside `engine` forever. The rename moved the engine *out* of
staging; the downloaded archive stayed *in*. There is no release path now — staging always
goes, on success, on every early return, and on unwind.

---

## 5. What can be pinned, and what cannot

| | pinned by | offline | measured |
|---|---|---|---|
| Claude Code | its **designated requirement** — `identifier "com.anthropic.claude-code" and anchor apple generic and certificate leaf[subject.OU] = "Q6L2SF6YDW"` | yes | `codesign --verify --strict -R` exit 0 against 2.1.257 and 2.1.258 |
| Claude Code | a **stapled notarization ticket** | — | **CANNOT.** `Sealed Resources=none`; a loose Mach-O has nowhere to carry one, and the symlink case is a false pass (§4) |
| the engine tarball | **SHA-256, compiled into the app binary**, covered by the app's own Developer ID signature | yes | digest checked before extraction; shape and version checked after |
| the engine tarball | a code signature | — | **CANNOT.** It is not code Apple signs |

---

## 6. Running it again

```sh
docs/verification/first-run-setup-2026-09-02/scripts/gap-proof.sh     <work-dir>
docs/verification/first-run-setup-2026-09-02/scripts/fresh-install.sh <work-dir>
docs/verification/first-run-setup-2026-09-02/scripts/failure-paths.sh <throwaway-home>
```

Each creates its own throwaway `HOME`, removes it, kills every process it started and prints
the surviving count as a number. None of them reads or writes anything of the CEO's; the two
that boot the app fingerprint his engine pointer, his loro-root and every file under
`com.richos.app` before and after and diff the two.

`fresh-install.sh` downloads ~195 MB (Anthropic's `claude`, uncompressed — macOS 15.6 ships no
`zstd`, and a GUI launch's `PATH` would not reach Homebrew's even if it did, so §19's finding
3 applies to every customer).
