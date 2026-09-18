# The phone channel — the contract between the Mac and the phone app

**Status:** the contract for slice A of `richos-hq/docs/plans/richos-phone-client-2026-09-18.md`.
**Owner of the Mac half:** `richos/app/src-tauri/src/phone/`. **Owner of the phone half:**
`richos/app/phone/`. **This file is the seam between them** — it is written down before either side is
finished so the two halves are built against one document rather than against each other.

Every section below cites the plan section it implements. Where this file makes a choice the plan left
open, or departs from the plan's letter, it is marked **DEVIATION** with the reason. There are three of
them and they are all in §4.

---

## 1. The two listeners, and when they exist

| | Port | Scheme | Serves | Credential |
|---|---|---|---|---|
| The channel | **8443** | HTTPS, our leaf | the phone app plus four API routes | the paired device's key (§4) |
| The trust endpoint | **8444** | plain HTTP | exactly one file, the `.mobileconfig` | none — it cannot have one |

**The origin is `https://<LocalHostName>.local:8443` and it never changes** (plan §2.1, §10.7). The name
comes from `scutil --get LocalHostName`; the port is part of the origin, so it is pinned. A service
worker, a push subscription, a cache and a Home Screen icon are all scoped to that origin, so moving it
orphans the installed app.

**Neither listener exists until the CEO pairs a phone, and both stop when he unpairs the last one**
(plan §2.5 item 1). Off is the default, and off means no socket rather than a closed door.

**One qualification the plan implies rather than states, and the phone half depends on it:** the phone
gets the app *from* the Mac, so the listener must also be up during pairing, before any device is
paired. The rule as implemented is therefore: **the listener runs while a device is paired OR while a
60-second pairing window is open**, and stops otherwise.

**It binds the LAN interfaces only, never `0.0.0.0`** (plan §2.5 item 2). Loopback is included so a
developer can `curl` the Mac's own listener; every other address is one the Mac was told about by
enumerating its own interfaces.

---

## 2. The trust endpoint — `http://<name>.local:8444/ca`

One path. `GET /ca` returns the root certificate wrapped in a configuration profile:

```
200 OK
Content-Type: application/x-apple-aspen-config
Content-Disposition: attachment; filename="richos-local-ca.mobileconfig"
```

**Every other path and every other method returns a flat 404 with an empty body.** The profile is
unsigned and iOS will show "Unverified" in red; the Mac's own settings screen says so before he starts,
in his words, and the profile's own description repeats it (plan §2.1).

---

## 3. The static app

`GET /` and `GET /<asset>` on 8443 serve the files in `richos/app/phone/`, bundled into the
application as a resource. No credential is required and none can be: the phone loads the app in order
to pair, so a credential here would be a lock whose key is behind the lock.

That is safe because of what those files are: **the shell only, with no conversation in it.** Nothing
served here is derived from the ledger, from a thread, or from anything the CEO said. Everything with
his words in it is behind §4.

Rules: no directory listing; no path containing `..` or a null byte; no symbolic link followed out of
the directory; anything not present is a flat 404. `index.html` is served for `/` only, never as a
catch-all for unknown paths — a phone that asks for a file we do not have must be told we do not have
it, not handed an app shell that then fails in a way nobody can read.

---

## 4. The credential, and how a request is authenticated

At pairing the phone generates a **non-extractable** WebCrypto ECDSA P-256 key pair and registers the
public half (plan §2.7). Every API request after that is signed with the private half.

### 4.1 The headers

```
X-RichOS-Device:    <deviceId>
X-RichOS-Time:      <the server time the phone last saw, milliseconds>
X-RichOS-Nonce:     <base64url of 16 random bytes>
X-RichOS-Signature: <base64url of the ECDSA P-256 / SHA-256 signature, IEEE P1363 r||s, 64 bytes>
```

### 4.2 What is signed

Exactly this string, UTF-8, with `\n` between the parts and no trailing newline:

```
<METHOD>\n<path and query, without the credential parameters>\n<deviceId>\n<time>\n<nonce>\n<lowercase hex SHA-256 of the request body>
```

The body hash of an empty body is the SHA-256 of zero bytes,
`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`.

WebCrypto produces the P1363 form by default: `crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'}, key, bytes)`.

### 4.3 What the Mac checks, in this order

1. the device id names a paired device;
2. `|time − now|` is at most **120000 ms** (two minutes), so a clock that drifts a little still works and
   a captured request does not work tomorrow;
3. the nonce has not been seen before (the Mac keeps the most recent **512** nonces per device);
4. the signature verifies over §4.2's exact bytes.

**Any failure at any step is a flat `404 Not Found` with an empty body** — never 401, never 403 (plan
§2.5 item 4, the tg-bridge's allowlist lesson). An unpaired caller learns nothing, not even that it
guessed a real path.

Every response, including a 404, carries `X-RichOS-Time: <now in milliseconds>`. That is how the phone
learns the server time it signs with, and it is why there is no separate challenge route.

**DEVIATION 1 — the challenge is not fetched, it is carried.** Plan §2.7 says the phone "signs a
server-issued challenge per session". A literal server-issued challenge needs either a fifth route or a
session store, and §2.5 caps the surface at four routes. What is implemented instead is a per-request
signature over a server-issued *time* — the Mac's own clock, which the phone only ever learns from the
Mac — plus a client nonce the Mac refuses to see twice. It is strictly stronger than a per-session
challenge (every request is bound, not just the session's first) and it costs one header instead of one
round trip.

**DEVIATION 2 — the events route carries its credential in the query string, and the signature is
reusable for ten minutes.** `EventSource` cannot set a request header, and on a dropped connection the
browser reconnects to *the identical URL*, which a single-use nonce would refuse. So `GET /api/events`
takes `device`, `time`, `nonce` and `sig` as query parameters (excluded from the signed path per §4.2),
and for that route alone the signature is a **ticket**: valid for **600000 ms** (ten minutes) from its
`time`, presentable more than once. After that the phone closes the stream and opens a new one with a
fresh ticket, which it can do at any moment because it holds the key. The exposure this trades away is
bounded: a copied events URL can read the CEO's own thread for at most ten minutes and can write
nothing.

**DEVIATION 3 — the bearer-token fallback is NOT taken.** Plan §2.7 names a long random bearer token as
the cheaper alternative "only if slice C runs over". It did not; the signed key is what is built, so
nothing extractable is stored on the phone.

---

## 5. The four routes

All four live under `/api/` on 8443. Bodies are JSON unless stated. **The maximum request body is
65536 bytes (64 KiB)**; anything larger is refused at the edge with `413` before it is read into memory.
(Slice B's voice note is a separate envelope with its own larger ceiling; it is not in this contract
yet, and the ceiling will be named here when it is.)

**Rate limits, sized for one CEO and one phone** (plan §2.5 item 6): **60 requests per rolling minute per
device**, and at most **4** concurrent event streams. Over either, the answer is `429` with a
`Retry-After` header.

### 5.1 `POST /api/pair` — the pairing endpoint

The only route with no signature, because it is where the key is registered. Open for **60 seconds** from
the moment the CEO opens "Use Rich from your phone", one shot. Outside that window, or with the wrong
code, it is a flat 404 like everything else.

Request:

```json
{
  "code": "K7QF2M9X",
  "publicKey": "<base64url of the SubjectPublicKeyInfo DER of the phone's P-256 public key>",
  "deviceName": "iPhone"
}
```

Response `200`:

```json
{
  "deviceId": "dev_9f21c0a4",
  "caFingerprintWords": ["harbor","candle","ripple","meadow","lantern","fossil"],
  "caFingerprintSha256": "3D:9C:...:A1",
  "apiBase": "https://mm1.local:8443",
  "serverTime": 1758200000000,
  "vapidPublicKey": "<base64url of the 65-byte uncompressed P-256 point>",
  "threadId": "thr_5c1e",
  "threadTitle": "Proposal"
}
```

The six words are the CA fingerprint rendered from a fixed word list; **the Mac's screen shows the same
six words at the same moment** and the CEO confirms they match before he taps Pair (plan §4.1). They are
derived from the SHA-256 of the root certificate's DER, six groups of eleven bits, so the comparison is
66 bits of the fingerprint rather than a friendly-looking hash of nothing.

`vapidPublicKey` is what the phone passes to `pushManager.subscribe({applicationServerKey})`.

**One device in v1.** Pairing a second device while one is paired is refused; "Forget this phone" at the
Mac is what makes the slot free again, and it also closes the listener.

### 5.2 `POST /api/message` — everything the phone tells the Mac

One authenticated door rather than three. The body is a typed envelope, and `clientId` is the phone's
own idempotency key — the Mac remembers the most recent **256** of them per device and answers a repeat
with the original answer rather than acting twice.

```json
{ "kind": "text",   "clientId": "01J8…", "threadId": "thr_5c1e", "text": "where are we on the proposal?" }
{ "kind": "push",   "clientId": "01J8…", "subscription": { "endpoint": "https://…push.apple.com/…", "keys": { "p256dh": "…", "auth": "…" } } }
{ "kind": "cursor", "clientId": "01J8…", "cursor": "1758200000000-412" }
```

- **`text`** — the CEO's words. Written to the intake log and `fsync`ed before the Mac answers, then
  handed to the spine (plan §4.2 i, ii). Response `202`:
  `{"accepted":true,"intakeId":41,"threadId":"thr_5c1e","at":1758200000123}`.
  **`intakeId` is the Mac's own de-duplication key** and it is what makes the drain at-least-once
  without ever asking the same question twice.
- **`push`** — register or replace this device's Web Push subscription. Response `200 {"accepted":true}`.
  Sending it again with a new endpoint replaces the old one; a subscription the push service later
  reports as gone (404/410) is dropped and the phone is asked for a new one at its next connection.
- **`cursor`** — the phone has durably seen everything up to this cursor. Response `200
  {"accepted":true}`. Advisory: it is what stops a push repeating something already read; it is never
  what decides what the ledger holds.

`kind` values other than these three are a flat 404.

### 5.3 `GET /api/events` — the stream

Server-sent events, `Content-Type: text/event-stream`, credential in the query string per DEVIATION 2:

```
GET /api/events?device=dev_9f21c0a4&time=1758200000000&nonce=…&sig=…
```

On connect the Mac sends a **snapshot** and then a live tail (plan §4.2 iii; the same
"full snapshot followed by events after a cursor" shape the desktop already uses):

```
event: snapshot
id: 1758200000000-1
data: {"threadId":"thr_5c1e","apiBase":"https://mm1.local:8443","serverTime":1758200000000,
       "cursor":"1758200000000-1","timeline":{ …the CEO-gated timeline payload… }}

event: live
id: 1758200000000-2
data: {"name":"rich://message-chunk","payload":{ … }}

event: api-base
id: 1758200000000-3
data: {"apiBase":"https://mm1.local:8443","reason":"home"}

: keep-alive 1758200015000
```

- **`snapshot`** carries the whole thread as the CEO sees it. It is the value of
  `Timeline::view(ViewMode::Ceo)` and nothing else — see §7.
- **`live`** carries one live event verbatim: its `name` is the event name the desktop webview
  subscribes to, its `payload` is that event's payload. The phone may ignore names it does not handle;
  it must not assume the set is closed.
- **`api-base`** is the reachability seam (§8). The phone stores the value and uses it for every
  subsequent request.
- A `: keep-alive` comment every **15 seconds**, so a silent stream is distinguishable from a dead one
  without a timer that wakes the Mac.

**The cursor** is the SSE `id` and it is minted by the Mac: `<boot>-<seq>`, where `boot` is the
millisecond the channel started and `seq` counts from 1 within that boot. It is monotone within a boot
and it changes shape across a restart on purpose — a client can tell "I missed some" from "that was a
different run of the Mac" without asking.

**Reconnection.** The browser resends the last id automatically in `Last-Event-ID`. If the boot matches
and the Mac's ring buffer (the most recent **512** events) still holds what follows it, the Mac replays
the tail and nothing else. Otherwise it sends a fresh `snapshot` — never a silent gap.

### 5.4 `GET /api/audio/<id>` — one audio blob, by an id the Mac minted

```
GET /api/audio/aud_3f9c1b2a
→ 200  Content-Type: audio/wav   (the bytes)
→ 404  for every id the Mac did not mint, in every case, with an empty body
```

`<id>` must match `aud_[0-9a-f]{8,32}` and must be present in the Mac's own mint table. There is no path
here, no file name, no extension and nothing derived from the request: the id indexes a table the Mac
wrote. That is the whole of plan §2.5 item 5's "no id it did not mint".

---

## 6. Push

Mac → Apple → phone, entirely outbound from the Mac, and **`*.push.apple.com` is the only host the Mac
ever dials for this feature** (plan §2.6). A subscription endpoint whose host does not end in
`.push.apple.com` is refused before a connection is opened.

- **RFC 8291** `aes128gcm`, AES-**128**-GCM (not 256 — the plan corrects its own earlier text on this).
- **RFC 8292** VAPID, `Authorization: vapid t=<ES256 JWT>, k=<base64url public point>`, where the JWT's
  `aud` is the **origin** of the endpoint and never the whole URL.
- `sub` is `https://github.com/WebDevBooster/richos`.
- `TTL: 120`, `Urgency: high` for an interrupt, `normal` for a digest.

Decrypted payload:

```json
{
  "v": 1,
  "kind": "reply",
  "threadId": "thr_5c1e",
  "messageId": "msg_…",
  "title": "Rich",
  "body": "…Rich's actual words…",
  "truncated": false,
  "cursor": "1758200000000-412",
  "apiBase": "https://mm1.local:8443",
  "at": 1758200000123
}
```

`kind` is `reply` or `proactive`. **The attention tiers already exist in the ledger and the phone obeys
them rather than inventing a policy** (plan §3.4): `interrupt_now` pushes immediately, `digest` batches,
`silent` never pushes at all.

**`truncated` is honest.** The APNs ceiling is 4096 bytes for the whole encrypted body. The framing is
fixed at 16 + 4 + 1 + 65 = **86** bytes of header, plus one delimiter byte and a 16-byte GCM tag, so the
plaintext ceiling is 4096 − 86 − 1 − 16 = **3993 bytes**, and the JSON around the body takes the rest.
When Rich's reply does not fit, the push carries its opening and `"truncated": true`, and the phone shows
that the rest is waiting on the Mac. It never shows a cut-off answer as a whole one.

---

## 7. What the phone can never be sent

**The outbound path reads one stream and no other:** the spine's `forward_live` chokepoint, which hands
an observer **only `Visibility::Ceo` items** (`app/src-tauri/src/events.rs:26-30`,
`app/crates/richos-core/src/live.rs:505-510`). The phone emitter is placed beside the desktop's
`TauriLiveEmitter` and inherits that gate by construction — the bytes of a tool call, a file path or an
internal turn never reach it.

The snapshot has the same property for the same reason: `Timeline` deliberately does not implement
`Serialize`, and `view(ViewMode::Ceo)` is the only way to obtain a payload
(`app/src-tauri/src/main.rs:664-673`).

**So: the phone emitter must never read the ledger, the raw event stream, or the timeline directly.**
That is not a rule to remember; it is why the emitter is given one stream and no handles.

---

## 8. The reachability seam — the address is DATA, never the origin

Plan §10.7, and it is the thing that keeps the phone app from being rewritten twice.

- **The origin is fixed forever** at `https://<name>.local:8443`. Service worker, push subscription,
  cache and icon are scoped to it.
- **The API base is one stored value the phone reads before every request.** It arrives in the pair
  response, in every `snapshot`, in an `api-base` event whenever it changes, and in every push payload.
- **The Mac holds a ranked list of providers** and offers the best one it currently has. **In this slice
  there is exactly one provider — `home`, which is the origin itself.** Later providers (a router door,
  an IPv6 address, a `ts.net` name) are new entries in that list and change nothing on the phone.
- **When no provider can be offered, the Mac says so rather than guessing**, and the phone shows its
  queued-send state with a reason the CEO can read: "waiting to send — your Mac isn't reachable from
  here."

`reason` on the `api-base` event is the provider's name, so the phone can say *why* in plain words.

---

## 9. Errors, in one table

| Situation | Status | Body |
|---|---|---|
| unpaired, wrong signature, stale time, replayed nonce, unknown route, unminted audio id, closed pairing window, wrong pairing code | **404** | empty |
| body over 64 KiB | 413 | empty |
| over the rate limit | 429 | empty, `Retry-After` set |
| malformed JSON, unknown `kind`, missing field | 404 | empty |
| the Mac accepted it | 200 / 202 | as above |

**404 for nearly everything is deliberate.** A caller that is not the paired phone gets one answer to
every question, so it cannot map the surface by the shape of the refusals.

---

## 10. What this contract deliberately does not contain

The voice envelope (slice B), thread creation or renaming, more than one paired device, more than one
company, any machinery or drill-down view, settings, permission approvals, and any route that takes a
file path. Plan §6 is the full list and none of it comes back through this door.
