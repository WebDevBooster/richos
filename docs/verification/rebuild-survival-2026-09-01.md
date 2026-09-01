# Rebuild survival, measured — 2026-09-01

**The question this answers, in the words it was asked in: will changing something
in the app cost the microphone and accessibility grants?**

**Layer 1 answer: NO. The grants are not bound to the build.** Two RichOS.app
bundles, differing by one shipped string literal, signed with the real Developer ID
Application certificate, produced **different code hashes and byte-identical
designated requirements**. The designated requirement is what macOS stores against
a permission grant; it names the bundle identifier and the team, and nothing about
the build. Every future build satisfies it.

Layers 2 and 3 are not answered here and are not claimed to be. What each one needs
is named at the bottom, and neither needs anything bought, requested, or waited for.

---

## What was signed

| | build 1 | build 2 |
|---|---|---|
| source | tree at `4d3619f` | the same, one shipped string literal changed |
| the change | — | `whoever set RichOS up needs to look.` → `…needs to take a look.` in `app/src-tauri/src/main.rs` (reverted after the measurement; it existed to move a byte, not to ship) |
| signing identity | `Developer ID Application: Alex Booster (TZ33A4QCZJ)`, SHA-1 `BF4D68E6F858688FDAD63148BD271FCA2D02474F` | the same |
| hardened runtime | on | on |
| secure timestamp | 1 Sep 2026 02:14:25 | 1 Sep 2026 02:15:58 |
| entitlements | `com.apple.security.device.audio-input` | the same |

Both bundles are kept at `~/.richos-signing/rebuild-survival/builds/build-{1,2}/RichOS.app`
(outside every checkout, deliberately: `rebuild-survival.sh` refuses to write its
records into a git worktree). Both still report `valid on disk` and
`satisfies its Designated Requirement` after being copied there.

## The two code hashes — DIFFERENT, which is what makes this a test

```
build 1   CDHash=8a69a6440b2aceaf2ea181a3133ef2cf28eb4104
build 2   CDHash=0c052ba84bd52bc0a18bebbddbf7acdf442ecef0
```

An unchanged binary was always going to match itself; that is the trap this file
exists to avoid. The ad-hoc signatures of the same two trees moved too
(`7c718675…` → `76c060c6…`), so the difference is in the shipped bytes and not in
the signing.

## The two designated requirements — IDENTICAL, verbatim

Build 1, read with `codesign -d -r-`:

```
designated => identifier "com.richos.app" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = TZ33A4QCZJ
```

Build 2:

```
designated => identifier "com.richos.app" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = TZ33A4QCZJ
```

Character for character the same, and there is **no `cdhash` term anywhere in
either**. Compare that with what the same two trees produce under ad-hoc signing:

```
# designated => cdhash H"7c718675e31ab7df91272a7e19fca553cfbec376"
```

— the whole requirement is the build's own hash, which is why every ad-hoc rebuild
started the permissions at zero.

## Each layer's real result

**Layer 1 — the mechanism. PASS.** Automatic, decisive, and reported above. This is
the layer that catches the mistake people actually make (a valid Developer ID
signature that still carries a cdhash requirement); it did not happen here.

**Layer 2 — the TCC database. INCOMPLETE, and NOT for the reason the harness
predicted.** `rebuild-survival.sh` warns that the system database is SIP-protected
and expects to report UNREADABLE. Measured: **both databases are fully readable
from this terminal** — the user database (122 rows) and the SIP-protected system
one (20 rows) both queried successfully. Layer 2 is therefore fully automatable
here. It is INCOMPLETE for a different and simpler reason:

```
tcc_microphone:     no-row
tcc_accessibility:  no-row
```

There is no grant for `com.richos.app` to survive, because no signed build has ever
been installed and granted on this machine. Build 1 was never installed. This is
the one step in the whole test that needs a person, and it takes about a minute.

**Layer 3 — zero user interaction. NOT MEASURED, and not measurable by any script.**
"No permission dialog appeared" is a thing a person saw not happen; no database
holds it.

## What is left, exactly

1. Install `~/.richos-signing/rebuild-survival/builds/build-1/RichOS.app` and grant
   it microphone and accessibility once, in System Settings.
   Note: launch it in a way that controls the working directory, or set
   `RICHOS_ENGINE_DIR`. A double-clicked bundle currently misreports a missing
   engine directory as `BinaryMissing` (`main.rs:395`, measured by echo-opus-p1 at
   `faa9b9d`). That is unrelated to signing and must not be read as a signing
   failure.
2. Install build 2 over it.
3. `app/scripts/rebuild-survival.sh compare --a 1 --b 2` — Layer 2 will now read
   real rows and answer itself.
4. Answer Layer 3 by hand: press the talk button and speak; use the global hotkey.
   Neither should raise a prompt.

Nothing in step 1 to 4 depends on anything being purchased, requested or waited
for. All of it was impossible before 2026-09-01 because there was no certificate.

## What this does NOT say

- It does not say the app is notarized. It is not; no notarization run has been
  made, and Gatekeeper will still block a downloaded copy.
- It does not say voice mode works under the hardened runtime. That is Layer 3.
- It does not say the login keychain's copy of the identity signs without a
  prompt. These two builds were signed from a throwaway keychain whose partition
  list this run set itself, precisely so that nothing could raise a dialog on the
  operator's screen. A key imported into the login keychain from the command line
  carries a trusted-application ACL but no partition list, so the first `codesign`
  use of it may ask once. That is a one-time click, not a failure, and it is called
  out in `install-signing-cert.sh`'s own output.

## Defects this run found, all fixed except one

- `app/src-tauri/Entitlements.plist` could never have signed anything: `--sign`
  written out literally inside its XML comment is a double hyphen, which XML
  forbids, and `codesign` refused the file with `AMFIUnserializeXML: syntax error
  near line 8`. `plutil -lint` reports the broken file OK, so the obvious check was
  never evidence here.
- `rebuild-survival.sh` read `none` off every Developer ID bundle: its requirement
  parser was anchored on the `# ` that only the implicit, ad-hoc form carries.
- `app/scripts/package-app.sh` HAS THE SAME PARSER BUG, at lines 331, 912 and 949,
  and it is **not fixed** — another engineer was in that file. It is not cosmetic:
  `--verify-only … --sign developer-id` FAILS a correctly signed bundle with
  "codesign printed no designated requirement", which happened on both builds
  above. The fix is the same substitution used in `rebuild-survival.sh`:
  `s/^#\{0,1\} *designated => //p`.
