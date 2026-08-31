# RichOS applied a real update to itself — 2026-08-31

RICH-TODOs row 12 said, verbatim: *"There is no updater of any kind… the CEO's 'automatically
download and install whatever the user needs' currently rests on zero infrastructure."*

This directory is the run that answers it. `app/scripts/updater-e2e.sh` built RichOS **0.1.0**
and **0.1.1**, served a manifest from a local HTTP server, and made the first **become** the
second — then flipped one byte and required the install to fail.

```
=== updater-e2e: all 10 passed — an update was applied, and two bad ones were refused ===
```

| Case | Result | The line that proves it |
|---|---|---|
| A | PASS | `state=available current=0.1.0 available=0.1.1` |
| B | PASS | `state=ready current=0.1.0 available=0.1.1 percent=100`, exit 0 |
| C | PASS | the **installed** `Info.plist` reads `0.1.1` |
| D | PASS | a fresh process from the replaced bytes: `state=upToDate current=0.1.1` |
| T1–T3 | PASS | `failure=signature detail=The signature verification failed`, exit 12, bundle still 0.1.0 |
| K, K2 | PASS | `failure=signature detail=The signature was created with a different key than the one provided` |

## The numbers

| | |
|---|---|
| update archive | `RichOS.app.tar.gz`, **8,630,189 bytes**, 9 members, one `RichOS.app/` root |
| sha256, good | `f8e71eec8935e1551b6f6f8c80c1286c0cccd194341729ec9339205b2d66c82a` |
| sha256, tampered | `4ecd9cbc79a7b17da8ddf7a54874c54ce79ab522fc419b5f2733353fddcdeb03` |
| the tamper | byte 8,629,165 of 8,630,189, `0xEA -> 0x15` — one byte, deep in the payload, signature left intact |
| signing key | minisign `A6BCB0F9A1ADED42` (**a TEST key**; a real release key has not been generated) |
| platform key | `darwin-aarch64` |
| bundle signature | **ad-hoc** — this Mac has 0 Developer ID identities (`security find-identity -v -p codesigning`) |

`http-access.log` is the server's own record: three `GET /latest.json` for the check phase and
three `GET /RichOS.app.tar.gz` — the real one, the tampered one, the wrong-key one. The bytes
crossed a socket.

## Files

* `run-2026-08-31.txt` — the whole run, both builds included
* `served-latest.json` — the manifest as `package-app.sh --updater` wrote it (the copy in the
  server's directory was deliberately re-pointed at the wrong key by case K; this is the
  original)
* `http-access.log` — every request the app made

## Two defects this run found, both fixed in the same branch

1. **The manifest announced the wrong version.** `package-app.sh` read `version` out of
   `tauri.conf.json` instead of out of the produced bundle, so a build carrying a `--config`
   overlay (which is how a second version is made at all) produced a 0.1.1 bundle and a
   manifest saying 0.1.0. It now reads `CFBundleShortVersionString` from the `.app` that was
   actually built.
2. **Tauri refuses to launch from a path containing a symlink.** `$TMPDIR` on macOS is under
   `/var/folders/…` and `/var` is a symlink to `/private/var`, so `StartingBinary found
   current_exe() that contains a symlink on a non-allowed platform: /var` killed the app
   before it could check for anything — and cases T and K PASSED FOR THE WRONG REASON, because
   "the install failed" is true of an app that never started. Both cases now require the run
   to have reached `state=available` first, and the workspace path is resolved with `pwd -P`.

The second one is the more useful finding: it is also a fact about where an installed RichOS
may live.

## What this run does NOT prove, in those words

* **Nothing crossed a network.** Both ends were this machine, over `http://127.0.0.1:8973`.
* **HTTPS is unproven.** The two builds carried
  `plugins.updater.dangerousInsecureTransportProtocol: true` as a `--config` overlay, because
  a release build otherwise refuses a non-https endpoint outright. The shipping config keeps
  https mandatory; the flag is not in it.
* **Windows is unproven.** No Windows bundle has ever been built for RichOS.
* **Permission grants do not survive this.** The bundles are ad-hoc signed, so the update
  changes the app's identity as far as macOS is concerned and the microphone and accessibility
  grants die. That is a certificate problem, not an updater problem — see `app/UPDATES.md`.
* **The key is a TEST key.** A real release key has not been generated, and swapping it later
  requires every already-installed copy to be replaced by hand once.
