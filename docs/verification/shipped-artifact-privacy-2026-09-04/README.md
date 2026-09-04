# What personal or private data reaches the artifact a stranger installs?

**Audited tree:** `fc56c20` (branch `zach-opus-p11`, worktree `/Users/alex/ab/richos-wt/zach-opus-p11`).
**Date:** 2026-09-04. **Scope:** the shipped artifacts only, not the repository at large.

## Why this pass exists

On 2026-09-04 `app/ui/mock.js` was found to carry the CEO's six real company names and 21
absolute paths under his own home directory — and `app/src-tauri/build.rs` embeds everything
under `app/ui` into the executable. Every RichOS.app ever built contained them. It was found
by accident, while fixing something else.

The pre-publication audit accepted personal machine paths **in the repository** as cosmetic.
That ruling says nothing about the **shipped binary**, and nobody had ever checked the shipped
binary against it. This is that check.

## Re-running it

```
bash docs/verification/shipped-artifact-privacy-2026-09-04/sweep.sh
```

Two helpers sit beside it, and both self-test:

| File | What it does |
|---|---|
| `sweep.sh` | Derives the three shipped sets from the build definition, then searches each for every category. |
| `rust-shipped-strings.py` | Strips comments and `#[cfg(test)]` from Rust source, so a sweep over its output describes the binary rather than the repository. `--self-test`. |
| `../../../app/scripts/lib/no_host_paths.py` | Refuses a built bundle that carries the build machine's home directory. `--self-test`. Run by `package-app.sh` before it signs. |

**`sweep.sh` asserts a positive control before it reports anything.** The first version of it
used `xargs -a`, which BSD xargs does not have; it found nothing anywhere and every category
came back empty. An empty category is only worth reading if the search that produced it is
known to be able to find something.

## The shipped sets, and how they were derived

Derived from the build definition. Not guessed, and not read off a hand-typed list.

### Set 1 — the embedded frontend: 30 files, 8,642,187 bytes

`app/src-tauri/build.rs` `stage_frontend()` mirrors `app/ui` into the directory
`tauri.conf.json` names as `build.frontendDist` (`../ui-dist`), skipping the top-level names in
`UI_NOT_SHIPPED` — `tests` and `node_modules`. `tauri-codegen` then walks `frontendDist` with
`WalkDir` filtered on nothing but `is_dir()` and brotli-compresses **every** file beneath it
into the executable.

So the set is `app/ui` minus those two names, at any depth, including dotfiles and including
anything untracked that happens to be sitting there. `sweep.sh` reads both `frontendDist` and
`UI_NOT_SHIPPED` out of the real files rather than repeating them, so it cannot drift from the
build.

Three things were checked about the set rather than assumed:

* **No symlinks** under `app/ui` — `sync_tree` uses a non-following `file_type()`, so a symlink
  would be read and copied as a file; there are none.
* **No nested `node_modules`.** The exclusion applies at the top level only (`top` is false in
  every recursive call), so `app/ui/<anything>/node_modules` **would** ship. None exists today.
  This is a live hole, not a closed one.
* **Every embedded file is git-tracked.** `git ls-files app/ui` minus `app/ui/tests/` is
  byte-identical to the derived list, so nothing untracked is riding along right now.

### Set 2 — the compiled Rust

`app/src-tauri/src` (9 files) plus the two path crates it depends on, `richos-core` (28) and
`richos-voice` (16): 53 files. Comments and `#[cfg(test)]` items cannot reach a release binary,
so the sweep runs over `rust-shipped-strings.py`'s output (18,525 lines) rather than the raw
source. That distinction changes the answer completely: a raw grep reports 40-plus hits on the
CEO's company names, and every one of them is inside a test module.

### Set 3 — the engine release asset: 436 files

`app/scripts/make-engine-asset.sh` archives **all** of `engine/`, with no exclusions, and the
customer downloads it from the GitHub release (`ceo-decisions.md` §19: the engine is not
bundled in the app, it ships as a release asset). It is not inside RichOS.app, but it lands on
the same stranger's machine, so it is in scope.

## Result, per category, per set

An empty cell means searched and nothing found.

| Category | Set 1 — embedded frontend | Set 2 — compiled Rust | Set 3 — engine asset |
|---|---|---|---|
| Absolute paths under `/Users/` | `/Users/you` only (invented) | `/Users/example` only (invented) | **`/Users/alex` — 23 sites** |
| Absolute paths under `~/` | `~/RichOS/corpus` (a product path) | `~/RichOS/corpus` (a product path) | ~45 distinct `~/...` paths |
| CEO company names | `deeply` ×2 files, `prospects` ×1, `richos-hq` ×5 — all comments | none | `femcboost` ×34, `richos-hq` ×26, `gpt-exporter` ×10, `prospects` ×8, `deeply` ×5 |
| Personal names, emails | none | none | `Alex Booster` (copyright line), `WebDevBooster` (repository URL) |
| Machine / account identifiers | none | none | none |
| Hostnames, serial shapes | none | none | `*.local` hits are all filenames (`settings.local`, `env.local`) |
| ChatGPT project ids (`g-p-…`) | none | none | **`g-p-67c804d0…` in `engine/tools/gpt-exporter/content.js`** |
| Vendor API keys / tokens | none | none | 5 hits, **all** fixtures in `scan-secrets.test.sh` |
| IPv4 literals | none | none | 4, and they are Resend's published webhook IPs in a vendor skill's reference |
| Real third-party names | none — `Acme`, `Hensley`, `Northwind` are invented | none | none |

### And what the binary itself says

`~/.richos-signing/rebuild-survival/builds/build-{1,2}/RichOS.app` are older builds, so they are
evidence about the **class** and not about `fc56c20`. Both are byte-identical at 17,253,952
bytes.

* `strings` finds asset keys (`/index.html`, `/assets/rich-hand.png`, `/main.js`, `/mock.js`, …)
  and **zero** `/tests/` keys — the `UI_NOT_SHIPPED` staging works, on the artifact.
* It also finds
  `/Users/alex/ab/femcboostfemcboostFemcBoost/Users/alex/ab/deeplydeeplyDeeply/Users/alex/ab/prospects…`
  — the old `EntityRegistry::ceos_companies()` string table. `fc56c20` removed it; Set 2 above
  confirms nothing of the kind survives at HEAD.
* And **657 occurrences of `/Users/alex`**. That is the finding below.

## Findings

### 1. FIXED — the build machine's home directory is compiled into the executable

657 occurrences in `Contents/MacOS/richos-tauri`: 472 distinct
`/Users/alex/.cargo/registry/src/…` paths from registry dependencies, and 23 distinct
`/Users/alex/ab/richos/.worktrees/zach-opus-c1/app/crates/…` paths from the two path crates —
**including the name of an internal agent worktree**. Rust bakes the compile-time path of every
crate into the binary as panic-location and debug metadata. None of it is a file, so no bundle
inspection could ever have seen it; `strings` reads all of it in a second.

That discloses the builder's account name, home-directory layout, repository location and
internal branch naming to anyone who installs the app.

**Fix, in `app/scripts/package-app.sh`:** export `--remap-path-prefix` for `$HOME`,
`$CARGO_HOME` and the app directory before `cargo tauri build`, and check the produced bundle
with `app/scripts/lib/no_host_paths.py` **before** it is signed — refusing rather than warning,
with `RICHOS_ALLOW_HOST_PATHS=1` as the deliberate override.

Four things about it were established by running them, not by reading about them:

1. Cargo's `trim-paths` profile key — the tidier route — **is not available**: cargo 1.95.0
   refuses it with *"the package requires the Cargo feature called `trim-paths`, but that
   feature is not stabilized in this version of Cargo."*
2. A minimal crate with no dependencies leaks nothing; add one registry dependency and the two
   `anyhow` paths appear. The defect is about dependencies and out-of-package path crates, which
   is exactly the shape RichOS has.
3. **rustc applies the LAST matching remap rule**, so general comes first and specific comes
   last. Getting this backwards silently changes which prefix wins.
4. **The replacement must not itself look like a home directory.** Remapping `$HOME` to `/home`
   produced `/home/.cargo/registry/…` — the same disclosure wearing a different name — and
   `no_host_paths.py` correctly refused it. The shipped mapping is `/build`, `/build/cargo`,
   `/build/app`.

End-to-end: with those exact flags, the probe binary contains **zero** `/Users/alex` strings and
`no_host_paths.py` reports clean.

**The untested hinge, stated plainly:** this has not been exercised against a real
`cargo tauri build` of `fc56c20`, because rebuilding the app was out of scope for this pass. The
first packaging run will also be a full recompile, since `RUSTFLAGS` is part of the fingerprint.
If the remap misses a path shape the probe did not have, the new gate stops the release rather
than shipping it quietly — which is the correct direction to fail, but it is a thing to run
before it is a thing to rely on.

### 2. FIXED — a path on the CEO's machine in a shipped stylesheet comment

`app/ui/style.css` cited the settings-button reference as
`~/ab/deeply/design/design-system/settings-button.reference.html`. That file is embedded in the
executable and is also readable in the webview's own source panel. The host prefix is gone; the
CEO's quoted ruling and the design provenance are untouched, because rewriting a quotation to
tidy a path would falsify it.

### 3. REPORTED, no action — internal design references in shipped UI comments

Roughly 30 sites across `style.css`, `home.css`, `home.js`, `index.html`, `splash.js`,
`splash-library.js` and `home/field-*.js` cite `richos-hq/design/mockups/rounds/…`,
`wiki/ceo-decisions.md` and internal plan documents. `splash-library.js` carries them as runtime
`"source"` fields rather than comments, though nothing renders them.

Not fixed, deliberately. These name a private planning repository and its layout, which is a
disclosure of internal process rather than of personal data; the same bytes are public in the
source repository as of today, so the binary adds nothing; and stripping them would delete a
genuinely useful provenance record across files other engineers are editing. **It is the CEO's
call whether `richos-hq` should be referred to by name in shipped source at all** — that is a
judgment about his own privacy, not a defect.

### 4. REPORTED, no action — the CEO's ChatGPT project id in the engine asset

`engine/tools/gpt-exporter/content.js:317` carries
`g-p-67c804d08cac8191af6ee36ed6219624-software-hardware` in a doc comment illustrating the ID
format, and the engine ships to every customer as a release asset.

Not fixed, for two reasons that are checked rather than assumed. First,
`WebDevBooster/gpt-exporter` **is a public GitHub repository** (`gh repo view` →
`"visibility":"PUBLIC"`), so this identifier has been public for as long as that repository
has; removing it here changes nothing while it stands there. Second, `engine/tools/gpt-exporter/`
is vendored material with its own `LICENSE`, and `zach-opus-p8` is building a vendored-material
registry and vendoring guard in this same session — editing a vendored copy would put it out of
step with upstream and with his work. **The fix belongs upstream first.** The identifier is
account-scoped and useless without the CEO's own session, so this is tidiness, not exposure.

### 5. REPORTED, no action — `/Users/alex` and `~/…` paths in the engine asset

23 sites under `engine/docs/`, `engine/scripts/lib/` and `engine/scripts/hooks/`, plus about 45
distinct `~/...` paths naming `~/.claude/...`, `~/ab/...`, `~/.ssh/id_ed25519` and
`~/Library/Keychains/login.keychain-db`. All are documentation, comments, and test fixtures; the
`~/.ssh` and keychain paths are *patterns the secret scanner looks for*, not secrets.

This is the class the CEO already ruled cosmetic, and the engine asset is a copy of a repository
that is public as of today, so it adds no exposure over the repository itself. Re-raising it
would be re-litigating a decision he has made. Recorded so the next person does not rediscover
it and reach for it as new.

### 6. REPORTED, no action — `app/ui/assets/rich-hand.png` carries a signed C2PA manifest

15,172 bytes of Google-signed content credentials in a `caBX` chunk, embedded in the binary
along with the image. It records that the asset was *"Created by Google Generative AI"*, that a
SynthID watermark and a visible watermark were applied, that it was converted to `.png`, and the
timestamps of each step (2026-07-24 09:42:30Z).

**It carries no personal identifier** — the UUIDs in it are per-asset manifest instance IDs, and
there is no account, name, device or file path anywhere in it. It should **not** be stripped:
removing content credentials from AI-generated media defeats the purpose they exist for.
Recorded because it will look alarming to the next person who runs `strings` on the binary, and
because it is worth the CEO knowing that the shipped art declares its own provenance.

### 7. Checked and clean — things that turned out not to be findings

* **The macOS entitlements comment does not ship.** `app/src-tauri/Entitlements.plist` carries a
  long internal comment naming a certificate hash prefix and Apple team ID. Signing a throwaway
  binary with that exact file and reading the entitlements back out of the signature shows
  `codesign` re-serializes the parsed dictionary: the comment is **not** in the artifact.
  Settled by measurement, not by reasoning about it.
* **The app icons carry no metadata.** `icon.png`, `32x32.png`, `128x128.png`, `128x128@2x.png`
  contain `IHDR`/`IDAT`/`IEND` and nothing else — no EXIF, no XMP, no author.
* **The bundle contains four files**: `Info.plist`, the executable, `icon.icns`, and
  `_CodeSignature/CodeResources`. `Info.plist` holds nothing personal.
* **The updater key in `tauri.conf.json` is the public half**, and it is supposed to ship.
* **`app/ui/mock.js` is already clean** as of `fc56c20` — six invented companies at
  `/Users/you/...`. The `Acme` / `Hensley` / `Northwind` names in its fixture conversations are
  invented, and `index.html`'s user-visible placeholder is `/Users/you/Projects/northwind`.
* **The vendor-key-shaped strings in the engine are all fixtures** for `scan-secrets.test.sh`,
  including AWS's own documented example key. No live credential in any shipped set.

## The open hole, named so it is not a surprise

`UI_NOT_SHIPPED` filters the **top level** of `app/ui` only. A `node_modules` — or a `tests`,
or anything else — one directory deeper ships. `app/ui/tests/README.md` tells a developer to run
`npm install` in `app/ui/tests`, which is excluded today only because its parent is; the day
some other subdirectory of `app/ui` grows dependencies, 20 MB of them go into the executable
with the build asserting success. The build-time assertion in `stage_frontend` checks the same
top level, so it would not catch it either.

Not fixed here: `build.rs` is load-bearing and a stranger installs a build within hours, so this
is a change to make deliberately and not in a privacy sweep. It is a real defect of exactly the
family that cost 19.89 MiB before.

## Would I be comfortable with a stranger installing this build?

**Of a bundle produced from `fc56c20` through the amended `package-app.sh`: yes.** Nothing in
any of the three shipped sets names the CEO, his machine, his customers or his companies, and
the one mechanism that did — the compiled-in home directory — is now both prevented and checked
on the artifact before it is signed.

**Of a bundle produced from `fc56c20` without that amendment: no.** It would carry 657
occurrences of the builder's home directory including internal working-branch names, and nothing
in the pipeline would say so.
