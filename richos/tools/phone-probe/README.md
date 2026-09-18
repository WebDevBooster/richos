# The phone probe

**One page, five checks, twenty minutes on the CEO's iPhone.** It answers the one question that
decides whether the RichOS phone client can be a web app: **does the microphone work inside an
*installed* iOS web app?**

This is step 0 of `richos-hq/docs/plans/richos-phone-client-2026-09-18.md` (§3.2). It is a probe, not
a foundation. The relay, the pairing and the real PWA are separate work, written from what this
finds. Nothing here is meant to survive into the product except the recorder's approach, and the one
thing here that is meant to survive — `public/pcm.js` — says so at the top of the file.

**Why it cannot just be a local file.** A PWA cannot exist without an HTTPS origin: service workers,
push, and Add to Home Screen all require a secure origin with a real certificate. So the probe has to
be served from somewhere real, and that is the only reason there is a server in this directory at
all.

---

## The five checks

| # | Check | What a failure means |
|---|---|---|
| 1 | **Install** — Add to Home Screen gives a standalone window | Expected to pass. If it does not, nothing else is measurable. |
| 2 | **Microphone** — a held recording captures non-silent audio | **THE GATE.** If this fails, the PWA ships as text + push and voice notes move to the native track. |
| 3 | **Persistence** — is the permission asked again next launch? | A cost, never a blocker. Either answer is fine. |
| 4 | **Push with the app closed** — a notification arrives a minute later | If this fails, a PWA is a poor fit and native moves up the queue. |
| 5 | **Wake** — tapping the notification opens the app on the right view | A cost, not a verdict. |

Each check writes a line into a results panel on the page, with one tap to copy all five.

---

## Deploying it

```
./deploy-railway.sh --project <railway project id>
```

It creates ONE new Railway service, generates a VAPID key pair and an unguessable access code, sets
them as that service's own variables, deploys this directory, and prints the single link to send him.
It touches no other service.

**The project id is deliberately not committed.** This repository is published; a project id is not a
password, but it names infrastructure and has no reason to be on the internet. Pass `--project` or set
`RAILWAY_PROJECT_ID`.

### Railway authentication — how it really works here

Not an environment token. Authentication is a **machine-wide interactive OAuth session** in
`~/.railway/config.json`, shared across every checkout because it lives outside all of them. When it
lapses, `railway up` does not fail with an auth error — it fails with a mangled parse error thrown
from inside the multipart upload, which is why both this script and femcboost's
`scripts/deploy-avelor-staging.sh` check `railway whoami` up front. That script's own note from the
2026-07-31 incident is explicit: restoring it *"requires a HUMAN to complete a fresh interactive
`railway login` — no script can self-serve past a revoked OAuth session."*

Two ways to have a credential, and the second needs no browser:

1. `railway login` (or `railway login --browserless` and open the printed link)
2. a **project token** from the Railway dashboard, exported as `RAILWAY_TOKEN`

The deploy script refuses clearly and early if neither is present. Nothing else in this directory
needs Railway: the page, the recorder, the push sender and every test run locally without it.

---

## Running it locally

```
npm start                 # http://localhost:8788 — a secure origin, so service workers work
npm test                  # 30 unit tests, no dependencies, no browser
node test/desktop-verify.js   # drives the real page in a real browser
```

`localhost` counts as a secure origin, so the service worker and the recorder both work there.
Everything else — Add to Home Screen, a push with the app closed — needs the real HTTPS origin.

### Configuration

| Variable | Default | What it does |
|---|---|---|
| `PORT` | `8788` | |
| `VAPID_PUBLIC_KEY` / `VAPID_PRIVATE_KEY` | generated per process | `npm run keys` prints a pair. Without them every subscription dies on restart, and the server says so loudly at boot. |
| `VAPID_SUBJECT` | `mailto:probe@richos.invalid` | **Set a real one before deploying** — see the note on Apple below. |
| `PROBE_ACCESS_CODE` | unset (open) | An unguessable code. Unset means the origin is open to anyone who finds it. |
| `PROBE_BUILD_SHA` | `unset` | Printed on the page, so a stale deploy cannot masquerade as a fresh one. |

---

## Dependencies: none

`package.json` declares an empty `dependencies` block, and that is a decision rather than an
accident.

The obvious way to send a web push is the `web-push` package. Node's own `crypto` already has every
primitive the two relevant RFCs need — ECDH on P-256, HKDF-SHA256, AES-128-GCM, and ECDSA signing in
the raw IEEE-P1363 form a JWT wants — so `lib/webpush.js` implements **RFC 8291** (message
encryption) and **RFC 8292** (VAPID) directly, in about 200 readable lines. Three reasons:

1. This repository is published and the artifact is a thing the CEO installs on his own phone. Every
   package is a supply-chain surface on that.
2. The Mac side of the real phone client will do this in Rust with `ring`, which the plan flags
   `unverified:` at §3.5 assumption 3. Writing it out longhand once, in a language where it is easy
   to read, is the cheapest way to de-risk that.
3. It is testable against the RFC's own published vector, which a wrapper around a package is not.

Playwright is used by `test/desktop-verify.js` and is **not** a dependency: it is resolved from
wherever it already exists on the machine, and the script says so and skips rather than pretending if
it is absent.

---

## What it stores

- **His voice: nothing, anywhere.** It is measured in memory on the phone and discarded. There is no
  upload path for audio in this code at all — search for one.
- **The five results: on his phone only**, in `localStorage`. "Start over" erases them.
- **The push subscription: in the server's memory**, because a push cannot be sent without it. It is
  an endpoint URL and two keys — a mailbox, not a person. No database, no disk. A restart forgets it,
  and "Start over" deletes it immediately.

---

## Notes worth keeping

**The recording asks for permission on a separate button.** iOS raises its microphone dialog over the
page. If that happened while he was holding the record button, lifting his finger to reach "Allow"
would end the recording before the microphone ever opened — and a working microphone would be
reported as broken on the one check that decides the plan. Permission is therefore its own control,
and separately, a recording under 0.5 s is reported as "hold it longer", never as a failure.

**The service worker caches nothing and has no `fetch` handler.** A probe that serves a cached page
answers questions about the wrong build. Everything is `Cache-Control: no-store`.

**The push payload is also a valid Declarative Web Push document.** On iOS 18.4+ Safari may render
the declared notification itself without running our JavaScript; on 16.4–18.3 the service worker's
`push` handler is the only path. Both are covered, because we do not know which his phone takes.

**Web push content is encrypted end-to-end by the standard.** Apple relays ciphertext it cannot read.
This is the one axis on which the PWA is a *stronger* privacy story than a native app, whose push
payload is plaintext to Apple.

**A 410 from the push service is treated as a real event.** The subscription is forgotten and the
result says so. Plan risk 2: a silently dead channel is the failure that matters.

**`VAPID_SUBJECT` must be real before deploying.** Google's FCM accepts our VAPID header with
`mailto:probe@richos.invalid`; Apple returns `BadJwtToken` for every request against a fabricated
endpoint, so this could not be discriminated from here — see `docs/verification/` for what was and
was not established. Use a real `mailto:` or the deployed `https://` origin and do not rely on the
default.
