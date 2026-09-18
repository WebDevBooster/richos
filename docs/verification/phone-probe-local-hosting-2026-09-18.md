# The phone probe, hosted on the Mac — what was established, and what was not

**2026-09-18 · Norm · branch `cc/norm-opus-probe2` · `richos/tools/phone-probe`**

CEO ruling, `wiki/ceo-decisions.md` §57: *"the user is not expected to have something like Railway and
I shouldn't provide that for a free and open-source app. Instead, the RichOS app should have
'something' running on the user's device (Mac in this case)."*

The probe is now served by this Mac over HTTPS, using a certificate authority this Mac mints. The
hosting step became **check 0** of the probe, because the real phone client will be served in exactly
this way. Checks 1–5 are unchanged.

Every command below was run on this machine. Where something could not be established, it says so and
names what would settle it.

---

## 1. The certificate

Minted by `lib/x509.js` (DER assembled by `lib/der.js`, signed with `crypto.sign`). Stored under
`~/Library/Application Support/RichOS/phone-probe/tls/`, keys mode `0600` in a `0700` directory.
Nothing is written into the repository.

```
Subject: CN=mm1.local, O=RichOS
Issuer:  CN=RichOS on MM1, O=RichOS
Signature Algorithm: ecdsa-with-SHA256        Public-Key: (256 bit) prime256v1
X509v3 Basic Constraints: critical            CA:FALSE
X509v3 Key Usage: critical                    Digital Signature
X509v3 Extended Key Usage: critical           TLS Web Server Authentication
X509v3 Subject Alternative Name:              DNS:mm1.local, IP Address:192.168.1.249
X509v3 Subject Key Identifier / Authority Key Identifier: present
Validity: 397 days (root: 3650 days, CA:TRUE pathlen:0, Certificate Sign + CRL Sign)
```

### Verified by three independent verifiers, each with a negative control

`node test/tls-verify.js` — 32 checks, all passing. A certificate that satisfies only its own author
has been verified by nobody, so each verifier is paired with a control that must FAIL:

| Verifier | Positive | Negative control |
|---|---|---|
| Node TLS, `ca:[root]`, `servername mm1.local` | `authorized: true`, TLSv1.3 | no CA → *"unable to verify the first certificate"*; wrong name → *"is not in the cert's altnames"* |
| `/usr/bin/openssl s_client` (LibreSSL 3.3.6) | `Verify return code: 0 (ok)` | no `-CAfile` → code 21 |
| `/usr/bin/security verify-cert -p ssl -s mm1.local` | *"certificate verification successful"* | wrong host → *Host name mismatch*; no anchor → rejected |

The third is **Apple's own trust evaluator** — the only one of the three whose opinion the iPhone
shares. The absolute path `/usr/bin/openssl` is deliberate: a bare `openssl` on this Mac resolves to a
Homebrew **OpenSSL 3.6.4**, a different implementation from the **LibreSSL 3.3.6** at `/usr/bin`.

**The login keychain was never touched.** Every verifier takes the root as a file on the command line.

### One deviation from the plan's §2.2 extension list, and one contradiction

- **Deviation, named in the code and pinned by a test:** `keyUsage` asserts `digitalSignature` and
  **not** `keyEncipherment`. The plan's `openssl` block asserts both, which is right for RSA and wrong
  for an EC key — RFC 5480 §3, because nothing encrypts to an EC key directly.
- **Contradiction, raised as `esc-20260918T110419Z-a27e1115` (state: proceeding).** The plan states
  Node "cannot issue an X.509 certificate at all". It can, and this does. What is true in the premise:
  there is no certificate-*issuing* API. What does not follow: a certificate is DER plus a signature,
  and `crypto.sign` signs arbitrary bytes. The evidence is the table above. **Everything else in §2.2
  and §2.1 was adopted** — `mm1.local`, port 8443, `richos.local` deferred, `pathlen:0`, critical
  `serverAuth`. If the lead rules for `openssl`, the change is one file and the tests stay.

---

## 2. The trust step (check 0) — counted

**Sixteen taps and his passcode, once, ever.** Derived here independently and equal, tap for tap, to
the plan's own count in §2.1: three in Safari (Install → Allow → Close), eight in Settings to install
the profile (General → VPN & Device Management → the profile → Install → *passcode* → Install →
Install → Done), five to switch it on (General → About → Certificate Trust Settings → the toggle →
Continue).

The page names the exact label iOS will put on both of those screens — the root's common name is
`RichOS on MM1`, read back out of the certificate — and **the server refuses to render the page at all
if any placeholder survives substitution**, because the alternative is telling him to look for a switch
labeled `{{CA_NAME}}`.

**Two things it tells him before he meets them.** iOS will show *"Not Signed"* in red, which is not
fixable and means *nobody vouched for this file except your own Mac*. And if the trust switch is
missing entirely, that is Apple's documented iOS 18.0/18.1 defect
(`developer.apple.com/forums/thread/764673`) — **a finding, not his mistake, and the single most
valuable thing this probe could return**, because it would mean the home-network design is blocked.

The trust page has **no JavaScript at all**: it has to work before the phone trusts anything.

---

## 3. Reachability from his phone

| | Measured |
|---|---|
| Bonjour name | `scutil --get LocalHostName` → `MM1`; `dscacheutil -q host -a name mm1.local` → `192.168.1.249`, **with nothing of ours running** |
| Firewall | `socketfilterfw --getglobalstate` → **`Firewall is disabled. (State = 0)`**; block-all disabled; stealth mode off; macOS 15.6 |
| What the user must allow | **Nothing, on this Mac.** No dialog will appear. If the firewall were on, macOS raises *"Do you want the application node to accept incoming network connections?"* on first bind → **Allow** |

**What breaks it, none of which is our bug:** a guest network, or a router with client/AP isolation —
both block device-to-device traffic outright and also stop multicast DNS; the phone on cellular rather
than the Wi-Fi; a full-tunnel VPN on the phone. In all of those the LAN-address fallback fails too,
because the problem is the network and not the name.

**`richos.local` is not registered.** Deferred with its price stated (plan §2.1): an extra `.local`
record needs `DNSServiceRegisterRecord` or a new dependency, plus `NSLocalNetworkUsageDescription` and
a macOS 15 local-network permission prompt. It is also **not claimed in the certificate**, so nothing
asserts a name that does not resolve.

---

## 4. Push from the Mac

Confirmed to need **no inbound anything**: the sender opens an outbound HTTPS connection to the push
service, exactly as it did from a hosted server.

`VAPID_SUBJECT` is now `https://github.com/WebDevBooster/richos`, the public project page — lead's
decision on `esc-20260918T105634Z-85b52f90`. RFC 8292 §2.1 allows a `mailto:` or an `https:` URL and
Apple accepts either; **a personal address is never baked into a build, a config default or a record**.
Asserted by the harness: the boot output's subject line is exactly that URL, and nothing anywhere in
the boot output matches an email address.

**Improved by the move:** the VAPID pair is now generated once and kept at `vapid.json` (mode `0600`)
instead of per process. A pair that died with the process took every push subscription with it. Two
consecutive boots against one state directory returned the identical public key.

**NOT established, and only his phone can settle it:** whether Apple's push service accepts our VAPID
header in practice. Apple returns `BadJwtToken` for a fabricated endpoint, so this cannot be
discriminated from here — unchanged from the previous record.

---

## 5. Desktop verification, without his phone

`node test/desktop-verify.js` — **45 checks, all passing** (36 before this work; nine added, none
removed).

It drives `https://mm1.local:8799` — the same scheme, host and port shape the phone uses — not
`http://127.0.0.1`. Each of those three is part of a service worker's registration and a push
subscription's identity, so the old origin was testing something the phone never touches.

Chromium is given `--ignore-certificate-errors-spki-list=<sha256 of this leaf's public key>`. That
accepts **exactly one certificate** and keeps rejecting every other bad certificate in the world, which
`--ignore-certificate-errors` and Playwright's `ignoreHTTPSErrors` do not — and it leaves the origin a
secure context, which is what the features under test are actually gated on.

```
window.isSecureContext            -> true
location.host                     -> mm1.local:8799
service worker scope              -> https://mm1.local:8799/
without our root                  -> refused   (the control)
check 2, over the new origin      -> 1.92 s, peak +0.7 dBFS, 30720 samples at 16000 Hz,
                                     AudioWorklet, WAV accepted by the browser's own decoder
results panel                     -> 0. Trust … 5. Tap to open
both themes                       -> paint
```

`node test/qr-verify.js` — every QR this tool renders, decoded by **Apple's Vision framework**, the
detector behind the iPhone camera: v1/v2/v4/v5/v6 all round-trip byte-identical, with a corrupted-image
negative control that must NOT decode (exit 3). `test/tls-verify.js` additionally decodes the QR the
server actually serves and compares it to the HTTPS origin string, so the page cannot send him
somewhere else.

`npm test` — **83 unit tests**, no dependencies, no browser.

---

## 6. Contrast — WCAG AA, computed, both themes

The trust step shares the probe's stylesheet, so one test covers both screens. Five new pairs, every
one computed by `test/contrast.test.js` rather than eyeballed:

| Pair | Dark | Light | Floor |
|---|---|---|---|
| `.button-link` — the download control, `--on-gold` on `--gold` | 7.68:1 | 4.72:1 | 4.5 |
| `.plain-link` — `--gold-text` on `--card` | 6.36:1 | 6.65:1 | 4.5 |
| `.steps li` — the numbered taps, `--ink` on `--card` | 12.06:1 | 18.07:1 | 4.5 |
| the QR's own modules, `--qr-ink` on `--qr-paper` | 21.00:1 | 21.00:1 | 3.0 |
| `.qr` border, `--line-control` on `--qr-paper` | 4.06:1 | 4.17:1 | 3.0 |

The QR keeps its black-on-white in both themes on purpose — a code inverted to match a dark page is one
a scanner may refuse — and the light theme *needs* that border: white paper on the ivory ground is
1.2:1 and would have no visible edge at all.

**No exemptions are claimed anywhere in this tool.** Every string on both pages is meant to be read,
including the privacy note: he is being asked to believe it.

---

## 7. Railway

`deploy-railway.sh` and `railway.json` are **deleted**, not kept as a marked reference. The ruling makes
hosted deployment the wrong shape, so the script describes a path nobody should take — and a dead deploy
script in a tool directory is an invitation. Everything it knew that is still true (how Railway
authentication really works; why `railway up` fails with a mangled parse error rather than an auth
error) lives in femcboost's `scripts/deploy-avelor-staging.sh`, which is live and maintained. Its
content is in this repository's history at `6b70a704`.

---

## What is still NOT established

Three things, and only his iPhone can settle any of them:

1. **Whether the trust switch appears at all** on his iOS version (§2 — Apple's 18.0/18.1 defect).
2. **Whether Apple's push service accepts our VAPID header** (§4).
3. **Whether `mm1.local` resolves from his phone.** It resolves from this Mac with nothing of ours
   running, and iOS resolves `.local` through Bonjour by construction — but his phone, on his Wi-Fi, is
   the only thing that can turn that into a fact. If it does not, the plan's `richos.local` trade-off
   flips and that becomes slice-A work rather than a deferral.
