# Phone protocol conformance corpus

Both native RichOS apps (Swift in `native-ios/`, Kotlin in `native-android/`) load these JSON files
in their fast logic tests and must pass every case. The corpus replaces a shared-code core: the two
apps share **data**, not code, and a drift from what the Mac serves shows up as a failing
logic test on the platform that drifted, in milliseconds, with no simulator or emulator.

```sh
node richos/mobile/conformance/generate.mjs --check     # the corpus is current (about 0.3 s)
node richos/mobile/conformance/generate.mjs             # regenerate after a deliberate change
cargo test --manifest-path richos/mobile/conformance/verifier/Cargo.toml --locked -- --nocapture
richos/app/scripts/native-conformance.test.sh           # both of the above, as the registered suite
```

## Where every value comes from

- **The phone side.** `generate.mjs` loads the real reference client modules, read-only:
  `web/web-app/lib/{api,queue,thread,inbound,fingerprint,wordlist,pcm}.js`, `mobile/core/client.js`
  and `mobile/platform/native.js`. It drives them against a scripted Mac that records every byte
  (`generator/harness.mjs`). No expected value is typed by hand. Where the phone protocol contract
  (Reed's 2026-09-22 specification, kept in the private RichOS records; the section numbers in this
  corpus are its sections) requires something other than what the reference does, the case says so
  in the open (see "Reference versus contract" below).
- **The Mac-defined areas.** Attachments and the FCM registration have no reference client. Their
  requests still use the real `api.js` canonicalization (and `registerNativePush` itself), but their
  expected Mac outcomes are declared in `generator/native.mjs` beside each case, citing the Mac
  commits they come from. `verifier/` proves every one against the production code
  (`Registration` parsing and `validate`, `AttachmentDesk::stage` and `staged`, `valid_id`, the
  limits and `capabilities`). On a Mac tree without those additions the verifier prints
  `NOT PROVEN HERE` with the count; once they are in the tree, a wrong expectation fails.
- **The Mac side.** `verifier/` compiles the Mac's production credential code
  (`app/src-tauri/src/phone/device.rs` and the modules it reaches, `signed_path` from `routes.rs`,
  the helpers from `mod.rs`) unchanged, in a small detached crate. Its one test runs every signed
  request in the corpus through the real `DeviceDesk::verify` and requires the verdict each case
  records. `verifier/build.rs` says exactly what is included and how.
- **Signatures are deterministic** (RFC 6979, `generator/p256.mjs`, self-tested against RFC 6979
  appendix A.2.5), so the corpus regenerates byte for byte. They are ordinary P-256 signatures. Your
  client's own signatures are randomized and will differ; they must verify the same way.
- **The key is test-only.** `vectors/keys.json` carries a published private scalar (SHA-256 of a seed).
  It is the same key as Reed's contract fixtures. Never ship it.

## Layout

| File | What a native suite must do with it |
|---|---|
| `keys.json` | Derive `device_id` and the JWK, point and SPKI forms from the private scalar. Load the key into your signer for tests. |
| `pairing.json` | `links`: parse every link; accept or refuse exactly as recorded (your message text may differ; the accept/refuse and origin/code must not). `api_base_validation`: same for an advertised `api_base`. `pair_exchanges`: send the recorded pairing body shape; reach the recorded outcome and state for each Mac answer. Native apps also send `platform` (see `platform_field`). `fingerprint_confirmations`: the signed confirm bodies. |
| `fingerprint.json` | For every case, compute the six words from the hex (or refuse). Ship the 256-word list and check it against `wordlist_sha256_of_newline_joined`. |
| `signing.json` | For every `valid` case, rebuild `mac.signing_string` from the request (challenge from the credential, method uppercased, wire path minus `auth`, SHA-256 hex of the body bytes or EMPTY with no body) and verify `signature_b64url` with the test key. For every `invalid` case, your Mac test double must refuse it, and your client must never produce it. `accepted_by_the_mac_though_unusual`: a test double must NOT refuse these (high-S, padded base64url). |
| `challenge.json` | Replay `mac_answers` in order against your API client; it must send exactly the recorded `requests` (count, challenge per attempt), end with the recorded `outcome` and hold `challenge_held_after`. The rule is in the file. |
| `retry.json` | Replay against your outbox; each flush pass at `at_ms` must match `passes`; every attempt carries the same body bytes (`body_bytes_identical_across_attempts`). Persist the bytes, not the fields. |
| `errors.json` | For each Mac answer, your client must take `required.client_action` (with `required.retry_after_ms`). `reference` is what the shipped web client did, for context. |
| `events.json` | `wire_cases`: parse `wire_utf8` as bytes cut per every `chunkings` plan (`every: n` or `cut_at: [offsets]`) and deliver exactly `expected_events`. `thread_cases`: apply `frames` for `selected_thread` and show exactly `expected_view` (ids, cursors, text, complete). `hello_cases`, `backfill_case`: the recorded state. |
| `voice.json` | Build the upload exactly: query parameter order, encoding, `Content-Type: audio/wav`, body hash. `limits` are read out of the Mac's Rust source, with the constant each came from. |
| `attachments.json` | Offer attachments only when `capabilities` has `attachments`; take the limits from `attachment_limits`. `attachment_id_cases`: accept or refuse each ID. `upload_cases` and `limit_sequence` (in order, one Mac): build each signed upload exactly and expect `mac_outcome` (`stored`, `duplicate`, `conflict`, `refused`, `limit`; the stored name the Mac gives the file). `commit_cases`: the commit body, and which files the Mac reports missing. `answers`: the client action for every status of both routes. |
| `push-registration-fcm.json` | Send the FCM shape only when `capabilities` has `native-push-fcm`. `registration_cases`: a test double of the Mac must accept or refuse each `native_push` value as `mac_outcome` says, and record the transport. `requests`: the signed registration, unregistration and the Android confirmation (`push_transport: "fcm"`). |
| `index.json` | Every file, its case count and where its expectations come from. Assert every file you expect is listed. |

## Shared shapes

Every file has `schema` (currently `1`) and `file`. Reject an unknown `schema` rather than guessing.

A **request** is what went on the wire:

```json
{
  "method": "POST",
  "target": "/api/messages",
  "headers": { "Authorization": "RichOS-Device dev_….<challenge>.<sig>", "Content-Type": "application/json" },
  "body": { "utf8": "…", "sha256_hex": "…", "length": 180 },
  "signed": {
    "credential": "header",
    "challenge": "…", "path_with_query": "/api/messages", "body_sha256_hex": "…",
    "signing_string": "…", "signature_b64url": "…", "authorization": "…"
  },
  "mac": { "signing_string": "…", "verdict": "accepted" }
}
```

- `target` is the path and query relative to the paired origin. For `GET /api/events` the credential is
  the LAST query parameter, `auth=<percent-encoded authorization>`, and `signed.credential` is `"query"`.
- `body` is `null`, `{ "utf8": … }` for JSON, or `{ "base64": … }` for WAV bytes.
- `signed` is what the CLIENT signed; `null` for unsigned requests (pairing, the challenge probe).
- `mac` is what the MAC computes from the request as sent and the verdict of its verifier
  (`accepted`, or `refused` with `refusal`). For every valid case the two signing strings are equal;
  for an invalid case, comparing them shows the mistake.

A Mac **answer** in a script is `{ "status", "body", "headers" }`, or `{ "transport": true }` for a
request that never reached a Mac (the platform's network call fails).

An **error** is `{ "reason": "unreachable" | "revoked" | "refused" | "fault", "status", "retryable",
"about_this_message" }`, the reference client's classification.

A case's **`mac_outcome`** (Mac-defined areas only) is what the Mac's own code decides about the
case's content: a registration accepted or refused, a file stored under a given name, a commit's
missing files. It sits beside `request`, whose `mac` is only the signature verdict.

## Consuming it from Swift and Kotlin

Read the files from the repository at test time, not a copy: a copy is exactly the drift this exists
to catch.

- **Swift (`swift test`).** Resolve the folder from the test file:
  `URL(fileURLWithPath: #filePath)` then walk up to the repository root and append
  `richos/mobile/conformance/vectors`. Decode with `JSONSerialization` or `Decodable` types that mirror
  the shapes above. Verify with `P256.Signing.PublicKey(x963Representation:)` and
  `P256.Signing.ECDSASignature(rawRepresentation:)`.
- **Kotlin (`./gradlew :core:test`).** Pass the folder in from Gradle
  (`systemProperty("richos.conformance", rootProject.file("../conformance/vectors").path)` or the right
  relative path from the module) and read it with `java.io.File`. Verify with
  `Signature.getInstance("SHA256withECDSA")`, which takes and returns **DER**: convert the corpus's raw
  64-byte `r||s` to DER to verify, and convert Keystore's DER output to raw before sending. The
  `invalid` case "DER-encoded signature …" is the Mac refusing exactly the unconverted form.
- **One test per case, named by the case's `name`,** so a failure names the case. Iterate the arrays;
  never hard-code a count.

## Adding or changing a case

1. Edit the generator (`generator/*.mjs`): add a Mac answer to a script, a link to `LINKS`, a
   mutation to `invalidCases`, and so on. Never edit `vectors/*.json` by hand; `--check` refuses it.
2. `node richos/mobile/conformance/generate.mjs`, then read the diff. **A changed vector is a changed
   protocol**, and both apps will fail until they follow it.
3. Run `richos/app/scripts/native-conformance.test.sh` (the Rust verifier must still agree).
4. When a shipped reference module changes, `--check` fails here first. Regenerate, and read the diff
   for what the phone now does differently.

## Reference versus contract

The reference is what the preserved clients do against today's Mac. Where Reed's contract says a
client must do otherwise, the case says so in the open and native clients follow the contract:

- `errors.json`: `413` is final for that exact request (the reference retries it forever); `429`
  waits `Retry-After` (the reference retries after 1 s); `422 {"retryable":false}` is final (the
  reference reads only `retry`). Each carries `required_source: "contract"` and `required_because`.
- `events.json`: the stream is global, so `expected_view` keeps only the selected conversation's
  `message` rows and the `delta`s whose `thread_id` is the selected conversation (`filter_rule`). A
  delta from an older Mac has no `thread_id` and is kept only for a row already held. The shipped
  clients do not filter; `unfiltered_view` is what they show, for contrast.
- `pairing.json`: native apps add `"platform"` to the pairing body (contract section 2.3); the shipped
  client does not send it.

## Not covered yet

- The build plan's section 3.4 also lists voice gesture thresholds, update policy, the headless
  scenario traces and design tokens. They are not in this corpus yet.
- The attachment and FCM routes' HTTP-level refusals (404 for a malformed query, 413 before the body
  is read) are listed in `answers` but not replayed: the verifier compiles the desks the routes call,
  not the route table itself.
