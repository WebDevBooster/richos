# The Tailscale path, proven live on this Mac — and the two defects the first run found

Branch `cc/echo-opus-tsscreens2`, base richos main `ec678bae`. CEO decision §61 and §61.1; Urban's
screens `richos-hq/docs/design/richos-tailscale-how-to-screens-2026-09-19.md`; the record this one
continues, `docs/verification/tailscale-path-2026-09-18.md`, whose first line was *"Tailscale is not
installed on this Mac, so no part of this path has been run against a live tailnet."*

**That sentence is no longer true.** The CEO installed Tailscale, signed in, and turned on HTTPS
certificates. Everything below was run on this Mac on 2026-09-19 and every line of output is
transcribed from the run.

**What is redacted, and nothing else is.** The login name is his personal address and appears here
as `<login>`; the run printed it in full. The tailnet name and the `100.64.0.0/10` addresses are
**not** redacted: a `ts.net` name with a certificate is published in Certificate Transparency by
construction, so quoting it discloses nothing new, and the addresses are reachable only from inside
his tailnet. Committed test fixtures keep the scrubbed placeholders they already used.

---

## 1. The two defects. Both were invisible without a live tailnet, and both are fixed here

### 1.1 Nothing in the product called the Tailscale path at all

`tailnet.rs` (detection, eight states, `fetch_cert`), `listen.rs` (`tls_config_with_tailnet`, the
two-certificate SNI resolver) and the how-to screens all landed at `ec678bae`. **No production code
called any of it.** Measured on that commit:

```
$ grep -rn 'fetch_cert\|tls_config_with_tailnet' --include=*.rs src/
phone/listen.rs:249:    tls_config_with_tailnet(leaf_der, leaf_key_pkcs8, None)   <- the home call, passing None
phone/listen.rs:259:pub fn tls_config_with_tailnet(                                <- the definition
phone/tailnet.rs:722:pub fn fetch_cert(...)                                        <- the definition
... every other hit is inside a #[cfg(test)] module
```

`PhoneRuntime::start` built a home-only TLS configuration, bound the home addresses, and minted the
pairing URL from `names.origin()` — `https://mm1.local:8443` — **whatever Tailscale was doing**. So
the screens guided a user to a Tailscale setup, and the channel then handed their phone a code that
only works inside the house, on the one path whose entire promise is that it works outside it.

Fixed by `phone::serving_plan` (`src-tauri/src/phone/mod.rs`), a free function over a detected state
so the decision is testable without a `tauri::AppHandle`. Four unit tests pin it: a ready tailnet is
served at its own origin and address; an address already in the home list is not bound twice; every
state short of `ready` leaves the home path byte-identical; a refused certificate is the home path
rather than a failure to start.

### 1.2 The key `tailscale cert` actually returns is SEC1, and rustls was told it was PKCS#8

Measured, by counting PEM labels only — the key itself went to `/dev/null` and was never written
anywhere:

```
$ tailscale cert --cert-file - --key-file - --min-validity 720h <name> | grep '^-{5}BEGIN' | sort | uniq -c
   4 -{5}BEGIN CERTIFICATE-{5}
   1 -{5}BEGIN EC PRIVATE KEY-{5}
```

`EC PRIVATE KEY` is **SEC1**. `listen::certified_key` wrapped every key as
`PrivateKeyDer::Pkcs8` unconditionally, so `ring` would have refused this one and the whole tailnet
configuration would have failed to build with *"rustls refused a private key"*. `tailnet::KeyDer`
had carried the distinction since the parser was written and the TLS side discarded it; every test
fed it a PKCS#8 key minted by our own authority, which is the one encoding a real `tailscale cert`
does not produce. Fixed by `listen::private_key_der`, and the encoding is asserted end to end in
`serving_plan`'s tests.

**Both of these are what the live run is for.** Neither is visible to any amount of reading.

---

## 2. The run

One command. `#[ignore]`d, because a suite may not depend on somebody's Tailscale account; it SKIPS
loudly on any state but `ready`, so it can never pass by being vacuous.

```
$ cargo test -q --bin richos-tauri phone::listen::tests::live -- --ignored --nocapture
running 1 test
state      = ready None
name       = mm1.tail770f6e.ts.net
origin     = https://mm1.tail770f6e.ts.net:8443
addresses  = [100.68.9.4, fd7a:115c:a1e0::6e31:905]
account    = Some("Google as <login>")
phone      = Some(PhonePeer { name: "HONOR X6b", online: true })
cert       = 4 certificate(s) in the chain, key is SEC1 (`EC PRIVATE KEY`)
listening  = 100.68.9.4:8443, 100.68.9.4:8444, [fd7a:115c:a1e0::6e31:905]:8443, [fd7a:115c:a1e0::6e31:905]:8444
GET https://mm1.tail770f6e.ts.net:8443/ -> 6876 bytes, curl ok
POST https://mm1.tail770f6e.ts.net:8443/api/pair -> {"api_base":"https://mm1.tail770f6e.ts.net:8443",
  "ca_fingerprint_sha256":"D1:B1:9B:BB:62:5B:70:92:D2:6C:9C:DF:90:BE:60:3D:94:A5:EC:44:BB:6D:61:8D:F9:50:EE:E8:B2:4D:72:07",
  "challenge":"mYj65bW1Y7DwBBofeSsdUK4ctR-HiWOL","device_id":"dev_2221beaa4ad2",
  "thread_id":"thr_4d59063c0adb4d1596294be8a9851c62","thread_title":"the proposal",
  "vapid_public_key":"BKQ1PzbMib1HIbgxP8_L-oRxC2Q1ZGLGo4vRaRDn0CWI8swecJqqb3WC4nHumhUCP_09DOYv4myt5D4XBns-8CM"}
pair url   = https://mm1.tail770f6e.ts.net:8443/#pair=M3RKDWBD
test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 309 filtered out; finished in 0.11s
```

Point by point, against the six things the brief asked to be proven:

| # | Claim | How this run establishes it |
|---|---|---|
| 1 | Detection reports the signed-in state with the tailnet name | `state = ready`, `name = mm1.tail770f6e.ts.net`, no diagnostic |
| 2 | `tailscale cert` succeeds, key kept off disk | 4 certificates and a SEC1 key, **read from the command's stdout through a pipe** — `fetch_cert` asks for `--cert-file -` and `--key-file -` precisely so nothing is written |
| 3 | The channel serves on that origin | bound on `100.68.9.4:8443` and the IPv6 tailnet address, with the tailnet certificate in the resolver |
| 4 | `curl` reaches the listener with the public certificate and **no `-k`** | `GET https://mm1.tail770f6e.ts.net:8443/` returned 6876 bytes of the phone app. The curl invocation is `--silent --show-error --max-time 20` and the URL. **No `--insecure`, no `--cacert`, no `--resolve`** — the name was resolved by MagicDNS and the chain validated against the system's own roots, both of which had to work for this to return anything |
| 5 | The API, not only static assets | `POST /api/pair` over the same origin returned a real pairing answer with a `device_id`; its `api_base` is the tailnet origin |
| 6 | The pairing QR carries that origin | `https://mm1.tail770f6e.ts.net:8443/#pair=M3RKDWBD`, built exactly as `PhoneRuntime::status` builds it |

**Four certificates in the chain, not one.** `tailscale cert` returns the leaf and its issuing
intermediates, and `listen.rs`'s own note says why that matters: a public chain that omits the
intermediate is the classic "works in curl, fails on a phone" certificate. Curl proves the first
half here; the phone half is Ray's walk.

### What this run does NOT establish

- **The phone side.** Nothing here was seen on a phone. `curl` on this Mac validates the chain with
  the same trust store an iPhone would use, which is evidence and not the walk.
- **The production call path.** The live test builds the channel exactly as `PhoneRuntime::start`
  builds it, step for step, but it is not `start` itself — `start` needs a `tauri::AppHandle`.
  `serving_plan`'s four unit tests cover the decision `start` delegates to it; the remaining gap is
  the twenty lines of glue around them, and it is named here rather than papered over.
- **First issuance.** Every measurement below is of a CACHED certificate. The very first
  `tailscale cert` for a new tailnet goes out to the ACME endpoint and will be slower; nobody has
  measured that here.

---

## 3. Measurements, so the boot cost is a number rather than a hope

`serving_plan` runs inside `PhoneRuntime::start`, which a boot with a paired phone goes through, so
"how long does `tailscale cert` take" is a startup question. Three consecutive cached fetches:

```
run 1: 0.055 s
run 2: 0.053 s
run 3: 0.045 s
```

45–55 ms. `TAILNET_MIN_VALIDITY` is `720h`: `--min-validity` is how much life the cached certificate
must have LEFT before the client renews, so thirty days against a ninety-day public certificate
leaves two thirds of its life as slack.

---

## 4. What the live document says about the CEO's own phone, and what it changed

`tailscale status --json` on this Mac carried his Android **twice** — one stale registration per
reinstall — and earlier in the evening **both were `"Online": false`**, because Tailscale was
installed on the phone and switched off. By the time of the run above, one registration was live:
`PhonePeer { name: "HONOR X6b", online: true }`.

Read the way the landed parser read it, the earlier document said *"you have two phones and they are
both here."* Neither half was true. So `parse_status` now de-duplicates by `HostName`, carries
`Online` through, and prefers a live registration over a stale one — because the three states are
three different instructions to the user:

| What the Mac can see | What the screen must say |
|---|---|
| no phone peer at all | the phone is signed in to a **different identity** — name the one the Mac used |
| a phone peer, `Online: false` | Tailscale is **switched off** on the phone; turn it on in the app |
| a phone peer, `Online: true` | nothing to fix |

Telling the second case to go and check their identity is the loop that had him reinstalling the app
three times.

---

## 5. Hygiene

No RichOS app instance was launched for any of this (`pgrep -fl richos-tauri` → nothing, before and
after). The live test binds port 8443, the shipping port, deliberately — an ephemeral port would
prove a handshake and not the socket a phone will dial — and it SKIPS with a printed reason rather
than fighting a running app for it. It stops its listener and removes its temp directory on the way
out.

---

## Related

- `docs/verification/tailscale-path-2026-09-18.md` — the record this continues, written when
  Tailscale was absent
- `richos-hq/wiki/ceo-decisions.md` §61, §61.1
- `src-tauri/src/phone/mod.rs` — `serving_plan`, `TAILNET_MIN_VALIDITY`, `PhonePeer` in the view
- `src-tauri/src/phone/listen.rs` — `private_key_der`, and the live test
