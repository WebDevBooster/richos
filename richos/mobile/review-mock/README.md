# RichConnect review host (hosted mock backend for App Review and Play review)

**Built and unit-tested. Not deployed.** No cloud resource exists for it yet. The steps to deploy it
are below. Someone with the Cloudflare login (the CEO or Codex) runs them.

Apple and Google reviewers cannot pair RichConnect with a Mac, because they do not have one.
This folder is the service they use instead. It is a Cloudflare Worker that plays the Mac for
each reviewer's phone:

- **The ordinary store builds pair with it** through the ordinary pairing link or QR code, and
  they speak the real phone protocol. There is no review mode, demo switch or hidden origin in
  either app (Sage's rule M1).
- **Everything is fictional**: sample conversations, simulated replies that begin
  "Demo reply", and a short chime where a Mac would speak a reply. No AI runs anywhere in it, and
  it holds nothing of the CEO's. It never connects to a Mac (M4, M8).
- **Text, voice, attachments and real push notifications work.** Push goes through the
  production RichOS Connect Worker, exactly as a Mac's does.
- **Each reviewer gets a separate review host** with its own address, storage and credentials,
  so an Apple review, a Google review and a spare device can never replace each other's pairing.
- **A stable HTTPS access page** takes the reusable review credentials and plays the Mac's
  screen. It issues a fresh pairing link and QR code on demand, shows the six words once the phone
  has arrived, and carries the "They match" press on the Mac side (Sage's v2 pairing contract,
  section 3).

Design record: `richos-hq/docs/plans/2026-09-23-mobile-setup-decisions-and-review-access.md`,
"Chosen review approach". Pairing rules: `richos-hq/docs/research/2026-09-24-richconnect-pairing-protocol-review.md`
(Sage, commit `af6c4604`), section 3 and rules M1 to M9.

## How it fits together

```
reviewer's browser ──► https://<access name>/            access page (src/portal.mjs)
                          │ per-reviewer sign-in; fresh link + QR; six words; They match
                          ▼
reviewer's phone ───► https://<review host>/api/...     the phone protocol (src/phone.mjs)
                          │ one Durable Object per review host (src/worker.mjs ReviewHost)
                          ▼
                       review host state (src/host.mjs): paired phone, challenges, receipts,
                       conversations, staged file metadata, push desk
                          │ signed control requests, as a Mac sends them
                          ▼
                       https://connect.richos.ceo  (production Connect Worker) ──► APNs / FCM
```

| File | What it is |
|---|---|
| `src/worker.mjs` | Entry point. Routes by hostname to the access page or a review host's Durable Object. Any other name gets a flat 404. |
| `src/host.mjs` | One review host: the Mac's device desk, pairing window, challenges, receipts, attachment staging (metadata only), event stream, demo replies (Durable Object alarm) and push desk. |
| `src/phone.mjs` | The Mac's route table and response headers (`phone/routes.rs`, `phone/listen.rs`). |
| `src/portal.mjs`, `src/pages.mjs`, `src/session.mjs` | The access page, its HTML and palette, and credential and session handling. |
| `src/push.mjs`, `src/registration.mjs` | The Connect client and the Mac's push desk, preview sealing and registration rules. |
| `src/signing.mjs`, `src/attachments.mjs`, `src/wav.mjs` | The credential, file and audio rules, each ported from the Mac file it names. |
| `src/config.mjs` | Reads and refuses the deployment settings. It never serves a name in `richos.ceo`. |
| `src/script.mjs` | The fictional conversations and the demo reply text. |
| `src/qr.mjs` | The QR code (the Mac's own `app/ui/qr.js`) and the six words (the phone's own `web/web-app/lib/fingerprint.js`), both imported read-only. |
| `bin/review-secrets.mjs` | Creates the secrets and review credentials outside Git. It prints only public values. |
| `dev/local.mjs` | Runs the bundled Worker in workerd, Cloudflare's runtime, locally. |
| `wrangler.example.toml` | The deployment template. |

### What a review host does, exactly

Every rule restates a Mac rule and names its Rust source in a comment. In short: the four routes
and the flat 404; a challenge on every answer, including refusals and `GET /api/challenge`; raw
`r||s` signatures over challenge, method, path and body hash (high-S and padded base64url are
accepted, as the Mac accepts them); one phone per host; `403 {"revoked":true}` to a forgotten
phone; 60 requests a minute for the phone and one shared bucket for strangers; at most 4 streams;
durable receipts (a retry is a duplicate, and changed bytes under the same id are a conflict);
the Mac's attachment types, sniffing, naming and limits (25 MB a file, 10 files and 100 MB a
message); WAV voice notes validated as the Mac validates them (16 kHz mono PCM16, at most 30
minutes); the event stream with `hello`, `message` and `delta` frames, replay after `since`, and a
15-second keep-alive.

Where a review host differs from a Mac, it says so:

| | A Mac | A review host |
|---|---|---|
| Replies | Rich writes them | Canned text starting "Demo reply", streamed in pieces 4 seconds after each message |
| Spoken reply | Synthesized speech | A 1.2-second, quiet two-note chime; every demo reply says so |
| Voice notes | Transcribed | Measured, not transcribed; the conversation shows "Voice message (N seconds)…" |
| Attachments | Saved on the Mac | Checked exactly as a Mac checks them, then discarded; only the name, type, size and hash are kept until the message commits |
| Web Push (PWA) | Supported | Not offered; a Web Push subscription is refused, as the Mac refuses one it cannot use |
| `build` | The RichOS version | `review-demo` |
| Conversations | The CEO's | Three fictional conversations; an explicit reset restores them |

### Sage's pairing rules, as built

| Rule | How |
|---|---|
| F1: the Mac-side press | A new phone is **inactive**. Until "They match" is pressed on the access page, every signed request except its own six-word confirmation gets `409 {"awaiting_mac_confirmation":true,"reason":"Press They match on your Mac."}`, which has no `retry:false`, so clients wait instead of giving up (tested with the reference client). The phone's own "They match" is recorded and activates nothing. "They do not match" on either side forgets the phone. A phone nobody confirms is forgotten when the 5-minute window closes. **Spent-code alarm:** the correct code a second time removes a waiting phone, or only warns if the phone is already confirmed. |
| F2: words over origin, Mac value and key | `PAIRING_WORDS = "v2"` derives the words as section F2 specifies and advertises `pair-v2` and `pairing_version: 2`. **The default is `v2`**, as the Mac announces `pair-v2` and the corpus carries the v2 vectors (`fingerprint.json` v2, `pairing.json` pair_v2 and mac_confirmation). The pair answer also carries `confirm_within_seconds`, the bound on the phone's wait for the press, as the Mac's does. `v1` remains for a build that has not adopted v2 yet; with it the access page shows the words of the fingerprint alone. |
| F3: large bodies | A body larger than 64 KB is read only when the `Authorization` names the paired, **active** phone and a live challenge. Anything else is answered unread. |
| M1 | Nothing in either app changes. |
| M2 | `src/config.mjs` refuses any name in `richos.ceo`, and so do the CLI and the template test. Only custom domains are routed; there is never a wildcard. |
| M3 | `test/conformance.test.mjs` replays every Mac verdict and outcome in the corpus. |
| M4 | There is no upstream except the Connect Worker's push routes. |
| M5 | Each review host has its own admitted host identity, and the mock holds no APNs or FCM credential. **One deviation, raised as `esc-20260924T003116Z-d1e843d0`:** registrations use route `tailnet`, not `connect`. The `connect` shape needs a provisioned Cloudflare tunnel and a `c-<id>-g<n>.richos.ceo` DNS record per review host, which conflicts with M2. The Worker's device-hash check therefore does not apply to review hosts until F5's phone-signed registration exists. The route is one line in `src/registration.mjs`. |
| M6 | Credentials are per review host and unlock only that host's fictional data. No operator secret is reachable through them. |
| M7 | Previews are sealed as `notifications.rs` seals them (AES-256-GCM, a random 96-bit nonce, 240 characters, bound to the references), with fictional text. |
| M8 | Replies are canned. The review notes below say so. |
| M9 | HTTPS hostnames only. Plain HTTP is refused. |

`reference:` T3 Code adoption ledger (`richos-hq/docs/research/t3code-tooling-what-to-adopt-2026-09-19.md`)
and the store-approval research (`richos-hq/docs/research/2026-09-22-app-store-approval-t3-and-first-time.md`).
T3's repository has no reviewer server, demo account or App Review notes (research section 1.2).
Its showcase mode is a build-time flag, and M1 forbids one here. So there is nothing to adopt, and
the reviewer environment is **NOT APPLICABLE** to T3. From the research, this adopts its section B
items 8 to 10 (a password-protected page that issues a fresh link on every request, a demo video,
monitoring). Its item 6, a reviewer Mac, is superseded by the CEO's choice of a hosted mock.

## Decisions needed before deploying

1. **The zone.** The review names must be in a Cloudflare zone other than `richos.ceo` (M2). That
   zone must be in the account that runs the Connect Worker, so the custom domains can be created.
   The template uses `example.org` placeholders.
2. **Connect capacity (Sage F8).** Each review host with push is one host record in the Connect
   Worker, which allows **10 lifetime records** in total. `unverified:` how many are left; settle
   it with `SELECT count(*) FROM hosts` on the Connect D1. Raise `HOST_CAPACITY` deliberately if
   needed, and never set `ENROLLMENT_OPEN`.
3. **How many review hosts.** The template has three: Apple, Google and a spare.
4. **M5's route** (escalation above).

## Deploy (for the CEO or Codex)

Everything secret is created outside Git and handed to Cloudflare with `wrangler secret bulk`. The
paths below follow the other RichConnect records, which keep protected state under
`/Volumes/E1TB/state/`.

```sh
# 0. Log in to the Cloudflare account that runs connect.richos.ceo.
wrangler login

# 1. Copy the template outside the repository and edit it: replace every example.org name with a
#    name in the review zone, and set `main` to the absolute path of this checkout's
#    richos/mobile/review-mock/src/worker.mjs. Keep REVIEW_HOSTS and the routes in step.
mkdir -p /Volumes/E1TB/state/richos/review-mock && chmod 700 /Volumes/E1TB/state/richos/review-mock
cp richos/mobile/review-mock/wrangler.example.toml /Volumes/E1TB/state/richos/review-mock/wrangler.toml

# 2. Write REVIEW_HOSTS (the same JSON as in wrangler.toml) to a file, then create the secrets.
#    This prints each review host's public Connect host id and the SQL that admits it.
node richos/mobile/review-mock/bin/review-secrets.mjs create \
  --hosts /Volumes/E1TB/state/richos/review-mock/review-hosts.json \
  --out /Volumes/E1TB/state/richos/review-mock/secrets \
  --access <access name>

# 3. Admit the printed host ids at the Connect Worker. <connect D1 database> is the database the
#    Connect Worker binds as DB (its id is in richos-hq/docs/operations/richos-connect-deployment.json).
wrangler d1 execute <connect D1 database> --remote --command "SELECT count(*) FROM hosts"
wrangler d1 execute <connect D1 database> --remote --command "INSERT OR IGNORE INTO allowed_hosts(id) VALUES ('<printed id>')"

# 4. Check the bundle and bindings without deploying, then deploy and install the secrets.
wrangler deploy --dry-run --config /Volumes/E1TB/state/richos/review-mock/wrangler.toml --outdir /Volumes/E1TB/tmp/codex/review-mock-dry
wrangler deploy --config /Volumes/E1TB/state/richos/review-mock/wrangler.toml
wrangler secret bulk /Volumes/E1TB/state/richos/review-mock/secrets/worker-secrets.json --config /Volumes/E1TB/state/richos/review-mock/wrangler.toml
```

The Worker's secrets are `REVIEW_PASSWORD_HASHES`, `SESSION_KEY` and `REVIEW_HOST_KEYS`. Leave
`REVIEW_HOST_KEYS` out (`create --push off`) for a deployment with no push; the apps then show no
notification controls, because a review host that cannot push does not offer it. The review
credentials for the notes are in `secrets/review-credentials.json`. Treat them as public once they
are in the notes (M6). Rotating a password means running `create` into a new folder and installing
its `worker-secrets.json`, which also signs every reviewer out.

### Check it after deploying

1. `https://<access name>/healthz` answers `{"ready":true,…}`. A misconfigured deployment answers
   503 and names the setting, never its value.
2. From a phone on cellular (no Wi-Fi, no VPN), with the submitted build: sign in, get a link, scan
   it, compare the six words, press They match on the phone and on the page, then send text, a voice
   message, a photo and a file, play a reply, turn on notifications, close the app, send, receive
   the notification, tap it, and relaunch.
3. Repeat on Android. Then pair a second device on the spare host and confirm the first still works.
4. Point an uptime monitor at `/healthz` and at each review host's `GET /`. No monitor exists yet.

## Tests

```sh
cd richos/mobile/review-mock && node --test test/*.test.mjs
```

160 tests in 1.2 s on 2026-09-24, no network. `runtime.test.mjs` skips with the reason where no Wrangler is installed.
The registered suite is `richos/app/scripts/review-mock.test.sh`, so `proof-for.sh` selects it.

| File | Covers |
|---|---|
| `conformance.test.mjs` | Every Mac verdict and outcome in `mobile/conformance/vectors`: signing (valid, invalid, tolerated), challenges, pairing links and answer, fingerprint words, voice, attachments (uploads, the limit sequence, commits), push registrations, event wire and thread model, error classes. |
| `host.test.mjs` | The F1 gate, expiry, spent-code alarm, v1 and v2 words, one phone per host, isolation between hosts, receipts, demo replies and the chime, eviction, rate limits, streams, F3, reset. |
| `reference-client.test.mjs` | The real `web/web-app/lib/api.js` doing the whole review end to end. |
| `push.test.mjs` | Push through the production Connect Worker handler over its real D1 schema, with only the Apple and Google senders faked. It checks that no tunnel or DNS record is ever created. |
| `portal.test.mjs` | Configuration, sign-in, sessions, request forgery, per-reviewer isolation, fresh links, that the QR code matches the link, the press, replace and reset, escaping, the CSP, and WCAG AA contrast for every color pair in both themes. |
| `runtime.test.mjs` | The bundled Worker in workerd: sign-in, link, pairing, the press, a signed message and the stream. |
| `secrets.test.mjs`, `template.test.mjs` | The CLI and the deploy template. |


## What this cannot prove without deploying it and using a real phone

- **That the store builds pair with it.** The tests use the corpus, the reference web client and
  test keys, not the Swift and Kotlin apps. Every native-app behavior is proven only through the
  corpus they share. Whether each app accepts `api_base`, shows the v1 words and handles the
  `409 awaiting_mac_confirmation` answer gracefully is **not** shown. From reading the code, both
  classifiers treat that answer as a retryable fault and resend the same bytes with their backoff
  (Android `native-android/core/.../protocol/MacApi.kt:193-200`, iOS
  `native-ios/Core/Sources/RichOSCore/Protocol/APIClient.swift:162-179`). Neither app has the
  awaiting state's own screen yet (Sage section 3.2), so until the page is pressed a phone shows
  whatever it shows for a temporary fault.
- **That Apple and Google accept a disclosed simulation.** The setup record says acceptance is not
  confirmed with either store.
- **Real delivery.** The notification tests stop at the Connect Worker's sender boundary. Whether
  APNs and FCM deliver, and whether a tap opens the conversation, needs signed builds on devices.
- **Cloudflare specifics**: custom-domain certificates, Durable Object alarms firing on schedule in
  production, stream behavior through Cloudflare's edge over minutes, the rate-limit binding, and
  cold starts. Locally, workerd shows the bundle, WebCrypto, storage and the stream opening, and
  not the alarm schedule.
- **Reachability from outside**, IPv6 (Apple 2.5.5) and uptime over a review period.
- **The QR code scanned by a phone camera.** It comes from the Mac's encoder, which has been checked
  with Apple Vision. That this page's rendering scans is not shown.

## Battery-check

**NO.** A review host sends at most one notification per message the reviewer sends, as a Mac
does. Nothing is pushed on a timer, and no silent or data-only wakeups are added. The stream
keep-alive is the Mac's 15-second comment, sent only while the app holds the stream open. The
awaiting answer is bounded: after the 5-minute window an unconfirmed phone gets the final `403`
and stops. A failed notification is retried by the server every 5 minutes, for at most an hour,
and still arrives once. No app code is changed.

## DRAFT: review access instructions (for the CEO; not submitted)

**DRAFT. App Store Connect, App Review Information, Notes** (well under 4,000 bytes):

> RichConnect is the phone companion for RichOS, which runs on the user's own Mac. A reviewer has no
> such Mac, so we run a review service that stands in for one. It uses fictional conversations and
> sends simulated replies. Every reply starts with "Demo reply", and no AI is involved. It is
> otherwise the same service a Mac provides: the same pairing, messages, voice, files and
> notifications, and the app you are reviewing is the normal build.
>
> 1. On any computer or on this device, open https://<access name>/ and sign in: username
>    <apple username>, password <apple password>.
> 2. Select "Get a pairing link". In RichConnect, scan the code, or copy the link on this device and
>    paste it into the app's pairing link field.
> 3. The app shows six words. Check that they match the page, then press They match in the app, then
>    refresh the page and press They match there.
> 4. Send a text message. A demo reply arrives in a few seconds. Hold the microphone button to send a
>    voice message. Attach a photo or a file. Play a reply to hear a short chime, which stands in for
>    the Mac's spoken reply.
> 5. Turn on notifications, send a message, and close the app right away. The reply arrives as a
>    notification. Tap it to open the conversation.
>
> Only one phone can be paired at a time. To pair another device, use "Remove this phone and get a
> new link" on the page.

**DRAFT. Google Play Console, App content, App access** ("All or some functionality is restricted";
the instructions and credentials are the same with the Google username and password. Google asks
for English instructions and a static URL, and the access page is that URL).
