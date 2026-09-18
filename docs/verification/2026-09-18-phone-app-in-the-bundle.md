# The phone app is in the bundle, and the build machine's home directory is not

**Date:** 2026-09-18. **Branch:** `cc/echo-opus-phonebundle1`. **Companion record:**
`docs/verification/2026-09-18-phone-channel-mac-side.md`, which covers the channel itself.

Every number below names the command that produced it, and every command was run on this Mac. Where
something is not measured, the sentence says so.

---

## 1. The two defects this answers

Both were measured on the 2026-09-18 nightly build of `e6f62448`, before any of this was written.

**The bundle that nightly produced holds no phone app.**

```
$ ls ~/.richos-nightly/source/.../bundle/macos/RichOS.app/Contents/Resources
icon.icns
```

That `ls` reports what is in that directory now, which is not by itself a claim about how the bundle
was built. The claim rests on the second measurement, which is structural rather than momentary: at
`e6f62448`, the commit that build was cut from, `tauri.conf.json` declared no `resources` entry at
all —

```
$ git show e6f62448:richos/app/src-tauri/tauri.conf.json | grep -n 'resources'
$ echo $?
1
```

— so nothing in that build COULD have written `Contents/Resources/phone`, and no build from that
commit could either. `phone_assets()` looked there first, fell through to a source-tree path,
and on any Mac but the builder's fell through that too and returned `None`. `GET /` on the phone
channel was a 404 on every machine that was not the one that compiled it.

**The build machine's home directory was inside the executable.**

```
$ python3 richos/app/scripts/lib/no_host_paths.py <that bundle> --home "$HOME"
no-host-paths: ... carries 1 home-directory prefix(es) across 1 file(s).
  /Users/alex   (1 occurrence(s))
$ echo $?
1

$ strings -n 8 .../Contents/MacOS/richos-tauri | grep -o '/Users/[^" ]*' | sort -u
/Users/alex/.richos-nightly/source/richos/app/src-tauri
```

That string is `env!("CARGO_MANIFEST_DIR")` at the old `src/phone/mod.rs:633`. `package-app.sh`'s
`--remap-path-prefix` cannot reach it: the flag rewrites the compiler's path metadata, and a macro's
output is program data. The refusal is in the nightly's own run log,
`~/.richos-nightly/logs/20260918T175137Z-c63678de.log`, and it ended an otherwise complete release
build: *"refusing to sign or package a bundle that carries the build machine's home directory.
Nothing was signed."*

**They are one defect.** The fallback existed because there was no bundled copy, and the fallback is
what leaked the path.

---

## 2. What was done

The phone app — now `richos/web/web-app/`, moved there from `richos/app/phone/` on the CEO's own
instruction the same day — is **compiled into the executable** by `build.rs`'s `embed_phone`, which
stages it into `$OUT_DIR` and generates an `include_bytes!` table. `PhoneApp` (`src/phone/assets.rs`)
serves it by exact key lookup. Nothing is searched for at runtime, so no path of any kind is needed
to find it.

**The alternative was checked, not dismissed.** A declared `bundle.resources` would also have had one
lookup: `tauri_build::build()` copies declared resources into the cargo output directory on every
build (`tauri-build-2.6.3/src/lib.rs:555-572`) and `resource_dir` returns that same directory on a
developer run (`tauri-utils-2.9.3/src/platform.rs:297-302`). Embedding was chosen because these bytes
are program data served on a socket by our own HTTP stack — never a file anything needs to open — and
because it makes "the developer run and the bundle serve the same bytes" a compile-time fact rather
than a copy step that can be skipped, stale, or modified after signing.

---

## 3. The packaging run — red before, green after

**Before** is §1: the same gate, on the bundle built from the code this replaces, exit 1.

**After**, on this branch at `933bfad1`:

```
$ bash richos/app/scripts/package-app.sh          # exit 0

checking the source for compile-time paths...
no-compile-time-paths: clean — 29 Rust file(s), no compile-time path and no home
directory in shipped code.

...

checking the bundle for build-machine paths...
no-host-paths: clean — no home-directory path in .../RichOS.app

OK: RichOS.app is bundled, ad-hoc signed and verified — real icons, cdhash
f92a6ab154e0a980a8a6774d7f450062e600c510, microphone usage string present
```

Ad-hoc signed, because that is what this machine's default packaging run does; a Developer ID run was
not part of this work and is not claimed.

---

## 4. Is the app actually in there?

Not "a directory exists" — the bytes. `include_bytes!` stores each file verbatim, so every shipped
file must appear in the executable exactly as it is on disk. Checked by reading both and asking:

```
executable: 24,557,232 bytes
  IN BUNDLE   app.js                              39,302 bytes
  IN BUNDLE   icons/apple-touch-icon.png          12,967 bytes
  IN BUNDLE   icons/icon-192.png                  14,384 bytes
  IN BUNDLE   icons/icon-512.png                  64,641 bytes
  IN BUNDLE   icons/icon-maskable-512.png         52,969 bytes
  IN BUNDLE   index.html                           6,223 bytes
  IN BUNDLE   lib/api.js                          13,326 bytes
  IN BUNDLE   lib/fingerprint.js                   3,857 bytes
  IN BUNDLE   lib/pcm.js                           9,968 bytes
  IN BUNDLE   lib/queue.js                         7,774 bytes
  IN BUNDLE   lib/recorder-worklet.js              1,523 bytes
  IN BUNDLE   lib/storage.js                      10,191 bytes
  IN BUNDLE   lib/thread.js                        5,780 bytes
  IN BUNDLE   lib/wordlist.js                      4,934 bytes
  IN BUNDLE   manifest.webmanifest                   629 bytes
  IN BUNDLE   styles.css                          14,458 bytes
  IN BUNDLE   sw.js                                7,992 bytes

17 file(s) of the phone app are in the executable byte for byte; 0 missing
workshop files found in the executable: none
/Users/ strings in the executable: 0
```

The workshop line is the negative half: `README.md`, `CONTRACT-STUB.md`, `package.json`,
`bin/make-icons.js` and two test files were looked for by content and are not there. The `/Users/`
line is the same question `no_host_paths.py` answers, asked independently of it — zero, against one
before.

**And it is served over the real socket, not merely present.** The end-to-end TLS test
(`phone::listen::tests::a_phone_pairs_posts_a_message_and_reads_richs_reply_over_real_tls`) now opens
with a step 0 that fetches `/`, `/app.js`, `/sw.js`, `/styles.css`, `/manifest.webmanifest` and
`/icons/icon-192.png` from the **real embedded table** through a real TLS client, asserts each content
type, and requires `/README.md`, `/package.json`, `/test/api.test.js` and `/../private.txt` to be
404s. That step is what the channel never had, and its absence is how a bundle shipped empty.

---

## 5. Suites

```
$ cd richos/app/src-tauri && cargo test
262 passed; 0 failed; 0 ignored; 0 filtered out     (of which `cargo test phone::` is 137)

$ cd richos/web/web-app && node --test "test/*.test.js"
tests 77   pass 77   fail 0

$ bash richos/app/scripts/no-compile-time-paths.test.sh
9 passed, 0 failed

$ python3 richos/app/scripts/lib/no_compile_time_paths.py --self-test
all 16 self-test cases pass
```

The node suite is listed because the directory move could have broken it silently, and it did break
it: `bin/make-icons.js` reached the desktop app's icon source two levels up and across, which is three
from the new home. Before the fix, `node --test` failed with `ENOENT` on an `icon-source` directory
directly under `richos/web/` — a path that has never existed and was never meant to.

---

## 6. What is NOT claimed here

- **No phone was involved.** Nothing here was run against a real iPhone. What is proven is that the
  bytes are in the shipped executable and that the Mac serves them over its own TLS socket to a real
  client in-process.
- **Not notarized, not Developer ID signed.** This was the default ad-hoc packaging run. Gatekeeper
  rejects it, as the script says in its own output.
- **The artifact check is still the guarantee.** `no_compile_time_paths.py` reads source, so a
  vendored C library baking in `__FILE__`, a new dependency shape, or a toolchain that starts leaking
  again would be invisible to it. `no_host_paths.py` on the built bundle remains the thing that
  actually answers for the artifact; the source check exists to make the cheap failure cheap.
- **The `.dmg` was not built.** `--bundles app` is what ran, which is the step `make-release.sh app`
  performs; the DMG's own flakiness is a separate, known question and was not exercised.
