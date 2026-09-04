# Updating RichOS

RICH-TODOs row 12 said, verbatim:

> **There is no updater of any kind** — no `tauri-plugin-updater`, no Sparkle, nothing. The
> CEO's *"automatically download and install whatever the user needs"* currently rests on
> zero infrastructure, and so does every future signed release.

This is what replaced it, what is proven, and what is not.

---

## What is proven, and how

**An update was applied end to end on this machine on 2026-08-31.** `app/scripts/updater-e2e.sh`
builds RichOS 0.1.0 and 0.1.1, serves a manifest from a local HTTP server, and makes the first
become the second — then flips one byte of the served archive and requires the install to
fail. Six named cases:

| Case | What it proves |
|---|---|
| A | 0.1.0 fetches the manifest over HTTP and finds 0.1.1 |
| B | it downloads the archive, the minisign signature **verifies**, and it installs |
| C | the bundle on disk is now 0.1.1, read from the **installed** `Info.plist` |
| D | the replaced bundle **relaunches**, runs, and reports itself as 0.1.1 and up to date |
| T | a **tampered** archive is refused with `failure.kind == "signature"`, and the installed bundle is untouched |
| K | an archive signed by a **different key** is refused the same way |

T and K are the point as much as A–D. An updater that installs an unverified binary is worse
than no updater: it is a remote-code-execution channel with a progress bar. Neither case
asserts that the source *contains* a verification call — each one corrupts the artifact and
requires the install to **fail**.

The run's numbers are in `docs/verification/updater-e2e-2026-08-31/`.

### What that run differs from a shipping build by, exactly

Two `--config` keys, both echoed by `package-app.sh` when it builds:

1. `version`, because the whole test is that two versions exist.
2. `plugins.updater.dangerousInsecureTransportProtocol: true`, because the manifest is served
   from `127.0.0.1` over http, and a **release** build otherwise refuses a non-https endpoint
   outright (`tauri-plugin-updater-2.11.0/src/config.rs:validate_endpoints`). That refusal is
   correct and is **not** disabled in the shipping config.

The signing key, the public key, the archive format, the manifest shape, the signature check
and the install are the shipping ones. The transport is http instead of https, and that is the
whole of the delta.

---

## The signing key

Updates are signed with **minisign**, through `cargo tauri signer`. This has nothing to do
with Apple: Tauri verifies every downloaded byte against `plugins.updater.pubkey` before it
installs anything, and that check is independent of codesigning — which is why the whole
update path is provable today, on an ad-hoc bundle, with no certificate.

**The public key is committed** (`app/src-tauri/tauri.conf.json`, `plugins.updater.pubkey`).
It is compiled into every installed copy.

**The private key is never committed and never written anywhere inside either repository.**

```
# generate, OUTSIDE every git worktree
cargo tauri signer generate -w "$HOME/.richos-signing/richos-updater.key" -p '<password>'

# sign a release
export TAURI_SIGNING_PRIVATE_KEY_PATH="$HOME/.richos-signing/richos-updater.key"
export TAURI_SIGNING_PRIVATE_KEY_PASSWORD='<password>'
app/scripts/package-app.sh --updater
```

`package-app.sh` **refuses** a key path inside a git worktree, and **refuses** a key file
readable by other users of the Mac — the same two rules the Apple notary key already has. A
leaked updater key cannot be revoked: the public half is compiled into every copy already
installed, so the only remedy is a new key and a release nobody with the old build can reach.

### THE KEY IN `tauri.conf.json` TODAY IS A TEST KEY

minisign key ID **`A6BCB0F9A1ADED42`**, generated 2026-08-31, passwordless, private half at
`~/.richos-signing/richos-updater-TEST.key` (mode 600 in a 700 directory).

**A real release key has not been generated.** Doing so is one command, and it is deliberately
not done here because the choice that goes with it is not an engineering one: a release key
should carry a password, and where that password lives (a password manager, the login
keychain, a CI secret) is a decision about how releases get made. When it is made:

1. `cargo tauri signer generate -w "$HOME/.richos-signing/richos-updater.key" -p '<password>'`
2. put the `.pub` contents into `plugins.updater.pubkey`
3. rebuild — the pubkey is compiled in, so **every installed copy must be replaced by hand
   once**, because a copy carrying the old key will refuse everything signed by the new one.

Doing the swap before RichOS is installed anywhere but this Mac costs nothing. Doing it after
costs a manual reinstall for every copy.

### One consequence of a `pubkey` existing at all, measured rather than assumed

A **raw** `cargo tauri build` — bypassing `package-app.sh` — now **fails** when no signing key
is in the environment. Measured on 2026-08-31:

```
$ env -u TAURI_SIGNING_PRIVATE_KEY -u TAURI_SIGNING_PRIVATE_KEY_PATH \
      cargo tauri build --bundles app
...
    Finished 1 bundle at:
        …/bundle/macos/RichOS.app
        …/bundle/macos/RichOS.app.tar.gz (updater)
       Error A public key has been found, but no private key. Make sure to set
             `TAURI_SIGNING_PRIVATE_KEY` environment variable.
$ echo $?
1
```

That is tauri-cli 2.11.4 `src/bundle.rs:277-279`, and it fires **after** the bundle is built,
so the `.app` is on disk and the command still exits 1. It is not a defect — it is the CLI
refusing to publish an artifact it cannot sign.

`app/scripts/package-app.sh` is unaffected: it passes `--no-sign` on every build, which on
macOS disables exactly that one step (codesigning is gated on Windows,
tauri-bundler `bundle.rs:301-306`) and then owns the signing itself. **Build through
`package-app.sh`.** `cargo tauri dev` is untouched — it does not bundle.

---

## The manifest

Tauri's updater fetches one static JSON document. `app/updater/latest.example.json` holds the
exact shape; `package-app.sh --updater` writes the real one as `latest.json` beside the
archive.

```json
{
  "version": "0.1.1",
  "notes": "Faster launch, and the settings menu now says what version you are running.",
  "pub_date": "2026-08-31T21:04:11Z",
  "platforms": {
    "darwin-aarch64": {
      "signature": "<the whole contents of RichOS.app.tar.gz.sig>",
      "url": "https://<host>/richos/0.1.1/RichOS.app.tar.gz"
    }
  }
}
```

* The platform key is `{os}-{arch}` — `darwin-aarch64` on Apple silicon, `darwin-x86_64` on
  Intel (`tauri-plugin-updater-2.11.0/src/updater.rs:updater_os`/`updater_arch`). An Intel
  build needs its own entry; the same manifest can carry both.
* `signature` is the **whole** `.sig` file, base64, on one line — not a hash and not a
  fragment of one.
* `version` is compared with semver against the running version. A manifest offering a version
  that is not strictly greater produces `upToDate` and no download.
* The updater sends `Accept: application/json` and treats **`204 No Content` as "no update"**,
  which is the correct answer for an endpoint that wants to say "not yet" without a body.
* `notes` is shown to the CEO verbatim, in the settings menu's Updates row. It is never
  generated from a commit log: a changelog is not a sentence a non-technical reader can act on.

### `{{target}}`, `{{arch}}`, `{{current_version}}`

The endpoint may carry those placeholders and the plugin substitutes them, which is what lets
one URL serve a per-platform document. The committed endpoint uses them, so a static host that
serves a file tree works without a server.

---

## Where updates are hosted — DECIDED 2026-09-04: GitHub Releases

The endpoint committed in `tauri.conf.json` is

```
https://github.com/WebDevBooster/richos/releases/latest/download/latest.json
```

One static document, on the host the repository already lives on, reached through GitHub's
`latest` pointer so the URL compiled into every installed copy never has to change again.
`app/RELEASING.md` is the procedure; what follows is why this URL and not another.

**`{{target}}`, `{{arch}}` and `{{current_version}}` are gone from the endpoint, deliberately.**
The plugin substitutes them into the URL (`updater.rs:475-487`), which is what lets one
endpoint address a per-platform file tree — and GitHub Releases is a flat asset store that
templates nothing, so a path built from them would simply 404. The per-platform split moves
into the document instead: `RemoteRelease` has two shapes, and the STATIC one is a
`platforms` map keyed by `{os}-{arch}` (`updater.rs:79-86`, `download_url`/`signature`).
One manifest carries every platform, and an Intel entry is a key beside the Apple silicon
one rather than a second URL.

**The redirect chain resolves, and it was measured rather than assumed.** GitHub answers
`/releases/latest/download/<asset>` with a 302 to `/releases/download/<tag>/<asset>`, which
redirects again to its asset CDN. Measured 2026-09-04 against a public Tauri project that
publishes exactly this file:

```
$ curl -sSL -o /dev/null -w '%{http_code} %{num_redirects} %{content_type}\n' \
       https://github.com/ayangweb/EcoPaste/releases/latest/download/latest.json
200 3 application/octet-stream
```

Three redirects, and `reqwest`'s default policy — which the plugin never overrides — follows
up to ten (`reqwest-0.13.4/src/redirect.rs:160-165`). The `Content-Type` comes back as
`application/octet-stream` rather than `application/json`, which does not matter: the plugin
reads the body with `Response::json`, and that deserializes the bytes without ever looking at
the content type (`reqwest-0.13.4/src/async_impl/response.rs:269-273`). Both of those are the
kind of thing a copied blog pattern gets right by luck.

**The failure mode this shape has, stated plainly.** `latest/download/<asset>` resolves
against whatever GitHub currently calls the latest release, and it 404s when that release
does not carry the asset. The same measurement found two live projects in exactly that
state — their newest release has no `latest.json`, so their updater endpoint answers 404 for
every installed copy. So:

* every release that ships an application MUST carry `latest.json`, and it is uploaded LAST,
  after the archive it names is already reachable;
* a release that ships something else — an engine asset on its own, say — must be marked
  pre-release, or it becomes "latest" and takes the manifest away from everybody.

`app/RELEASING.md` enforces both in the script rather than in a person's memory.

**A 404 is not `unconfigured`.** Until a release exists, a check reports a `manifest`
failure, because that is what the plugin returns (`Error::ReleaseNotFound`, classified in
`updates.rs`). The `unconfigured` state now only appears when a build is deliberately pointed
at the `.invalid` host through `RICHOS_UPDATE_ENDPOINT`. Publish the first release and the
build that carries this endpoint in the same step and nobody ever sees it.

**What was NOT chosen, and why it may still be right later.** A CDN bucket or a small
endpoint on existing infrastructure both buy things GitHub Releases cannot: a `204 No Content`
answer for "not yet", and a staged rollout to one machine before everybody. Neither is worth
a domain, a bill and a second thing to keep alive for a customer count of one. The
engineering is indifferent between them — all three serve one JSON document and one
`.tar.gz` — so this is reversible for the price of one config line and one rebuild.

## What the CEO sees

The universal settings button — the one that is on every screen — carries a **mark** when an
update is waiting or installed. Opening it shows an Updates row with, in every case, a sentence:

* *RichOS 0.1.0 is up to date.* / *Checked 8 minutes ago.*
* *RichOS 0.1.1 is available.* + the release notes + **Download and install**
* a progress bar, then *Checking the download and installing…*
* *RichOS 0.1.1 is installed.* / *Restart when you are ready — nothing is lost.* + **Restart to finish**
* every failure in its own words, with the vendor's own error text one click behind it

**RichOS checks by itself, three seconds after launch.** The install is a button, and that is
deliberate: on macOS the installer deletes and replaces the running `.app` in place, and RichOS
holds a `claude-agent-acp` child process as a compute lease that the session-continuity design
forbids swapping mid-turn (the session-continuity design record,
`richos-session-continuity-2026-08-24.md` §3.1, which is kept privately in richos-hq and
is not part of this repository). Doing
that behind the CEO's back is that invariant broken by a background thread.

**A refused signature is never offered a retry.** Every other failure gets *Try again*; a
signature failure gets an explanation, because retrying a tampered artifact refuses
identically and a button that invites someone to keep pressing until a security check passes is
the wrong control.

---

## What is NOT proven, in those words

* **Windows is unproven.** `plugins.updater.windows.installMode` is configured, and no Windows
  bundle has ever been built for RichOS — that needs a .NET toolchain this machine does not
  have (RICH-TODOs row 8), and there is no Windows code-signing certificate
  (`richos-hq/wiki/packaging-and-signing.md`). Nothing here says Windows works.
* **Nothing has been served over HTTPS.** The end-to-end run used http on 127.0.0.1 with the
  insecure-transport flag; the shipping config keeps https mandatory. The TLS path is unproven
  because there is no host to prove it against.
* **No update has crossed a network.** Both ends were this machine.
* **Grants do not survive an ad-hoc update.** The bundles are ad-hoc signed, so every update
  changes the app's identity as far as macOS is concerned and the microphone and accessibility
  grants die — measured 2026-08-24, `richos-hq/wiki/packaging-and-signing.md`. That is a
  CERTIFICATE problem, not an updater problem, and it is the next paragraph.
* **Rollback does not exist.** A bad release is fixed by publishing a newer one. The updater
  compares semver and will not install a lower version.
* **There is no staged rollout and no channel.** One manifest, everyone gets it.

---

## What is still blocked on the Developer ID certificate

The Apple Developer Program membership **exists** as of 2026-08-31 — CEO decision 1.1 is
closed, and `richos-hq/wiki/packaging-and-signing.md` records it. What does not exist is the
**Developer ID Application certificate**: `security find-identity -v -p codesigning` on this
Mac reports **0 valid identities**, measured today.

Until it does:

* every update ships an **ad-hoc signed** bundle, whose designated requirement is a hash of
  that build and nothing else, so **microphone and accessibility grants die on every update**
  and cannot be migrated (toggling the switch in System Settings provably does not work);
* Gatekeeper rejects a downloaded copy, so the first install is a right-click-Open — and every
  *update* after that is silent, because the updater replaces the bundle rather than opening a
  download;
* nothing is notarized.

**None of that blocks the updater**, which is why it is built and proven now. The certificate
is two commands away and both are already written:
`app/scripts/make-signing-csr.sh` (already run — the CSR is waiting at
`~/.richos-signing/developer-id.certSigningRequest`), then the portal, then
`app/scripts/install-signing-cert.sh <the .cer>`. `docs/ceo/developer-id-setup-2026-08-31.md`
is the middle step in plain language.

---

## Running it

```
# the whole end-to-end, about the length of two release builds
app/scripts/updater-e2e.sh

# ...and keep the workspace (bundles, logs, served manifest) for inspection
app/scripts/updater-e2e.sh --keep

# just produce signed artifacts from a normal packaging run
TAURI_SIGNING_PRIVATE_KEY_PATH=$HOME/.richos-signing/richos-updater-TEST.key \
TAURI_SIGNING_PRIVATE_KEY_PASSWORD= \
RICHOS_UPDATE_BASE_URL=https://<host>/richos/0.1.1 \
RICHOS_UPDATE_NOTES='What changed, in the CEO's language.' \
  app/scripts/package-app.sh --updater
```

Without `RICHOS_UPDATE_BASE_URL` the artifacts are still built, verified and signed, and **no
manifest is written** — a manifest carrying a guessed URL is worse than no manifest, because it
is a file that looks publishable.
