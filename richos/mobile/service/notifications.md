# Native reply notifications

The Connect Worker also delivers optional native alerts. A Tailscale phone can opt into this hosted service without allocating a tunnel. The Mac signs every control request with its existing host identity. Closed pilot admission and the shared capacity bound apply to both routes.

For a new database, apply `connect/schema.sql`. For an existing schema-2 database, inspect `PRAGMA table_info(push_jobs)` and add the nullable `preview` column with `ALTER TABLE push_jobs ADD COLUMN preview TEXT` only if it is missing, before deploying these modules. Existing generic jobs remain valid. The private deployment profile may include `push: {teamId, sandboxKeyId, productionKeyId, topics}`. Topics must be the registered RichOS app identifiers. Install `APNS_SANDBOX_KEY` and `APNS_PRODUCTION_KEY` as separate Worker secrets, with their matching Apple environment keys. Keys never enter a Mac build, phone build, deployment artifact or Git. Missing environment configuration refuses registration. Debug builds use the sandbox entitlement and topic; Release uses production. TestFlight uses production APNs.

Signed routes:

- `POST /v1/push/hosts`: admit or recover the host identity without creating a tunnel.
- `PUT /v1/push/device`: register or revoke one paired phone with a monotonically increasing revision. Registration binds the device key hash, host generation, token, environment, topic and route. Token rotation replaces pending jobs. A null token revokes the registration.
- `POST /v1/push/events`: enqueue a generic reply-ready alert for the current device and registration revision. SHA-256 event and thread references and an optional bounded AES-GCM envelope are accepted. Plaintext content fields are rejected. Ciphertext has the same one-hour job lifetime.

The fallback alert says “Rich has replied.” With previews on, the Mac encrypts a whitespace-normalized opening of at most 240 Unicode characters using a distinct 256-bit preview key and random 96-bit nonce. AES-GCM authenticates the version and opaque thread/event references. Only ciphertext crosses the provider/APNs path. The native notification extension decrypts locally without a network fetch, respects the app's preview switch and leaves the generic alert intact on any failure. The app and extension share a protected Keychain item scoped to the parent app identifier. The key changes when the paired origin changes, stays off the provider and is never saved in shared JavaScript state. The OS controls lock-screen preview visibility. Web Push is already encrypted and its service worker applies the same default-on preference. Notification taps select the referenced conversation/reply through the authenticated session. The Mac does not infer native foreground state from an open SSE socket, which a proxy may retain after the app closes. iOS suppresses foreground presentation through its notification delegate. Notification permission denial does not block text or voice. Apple controls delivery timing; provider acceptance is not proof that an alert reached a device.

Provider calls, token rotation and revocation share the host lease. Jobs expire after one hour, have at most five delivery attempts and are capped at 100 per host. The five-minute scheduler retries eligible failures and deletes expired jobs. A permanent invalid-token response immediately removes the stored token and pending jobs. Successful event IDs remain only until their one-hour expiry for deduplication. A transport failure after Apple accepted a request can result in a duplicate alert; stable collapse IDs reduce repeated pending alerts but are not an exactly-once guarantee. An alert already accepted by Apple cannot be recalled by later revocation.

Disable logs, traces, Logpush and tail consumers as in the Connect deployment. No content-bearing diagnostics are retained. Treat APNs tokens as private operational data. Rotate keys by installing a new server secret and matching key ID, verifying a physical notification then revoking the previous key in Apple Developer. Never revoke the old key first. Keep sandbox and production evidence separate.

## Android (FCM, schema 3)

The same routes deliver to the native Android app through Firebase Cloud Messaging HTTP v1 (`connect/fcm.mjs`). The job, retry, expiry, deduplication, revision and invalid-token rules above apply unchanged; only the provider differs. Each binding records its `platform`, and every job goes to exactly one provider: the registration's.

Registration body for an Android phone (`PUT /v1/push/device`), sent by the Mac:

```json
{"revision": 2, "generation": 1, "deviceHash": "<64 hex>", "token": "<FCM registration token>", "platform": "fcm", "topic": "<Android application ID>", "route": "connect"}
```

`platform` is required and is `fcm`; `topic` is the Android application ID and must be on the Worker's `FCM_APPS` list; there is no `environment`. The token is opaque: 32 to 4,096 characters of `A-Z a-z 0-9 _ - :`. APNs registrations are unchanged: the schema-2 body is still accepted as is, and `"platform": "apns"` may be added. A revocation (`token: null`) is unchanged and clears the platform. An older Worker refuses the Android body with 400, so a Mac can tell it is talking to a Worker without Android push.

The data message carries only strings: `v` (`"1"`), `host`, `thread`, `event` and, when previews are on, `preview`, which is the Mac's AES-GCM envelope as the same JSON string the APNs path carries. There is no `notification` block, so Google receives no visible text. It is sent with high priority, a TTL equal to the job's remaining lifetime, `collapse_key` equal to the event reference (the APNs collapse ID), and `restricted_package_name` equal to the registered application ID. The Android app must post a visible notification for every message it receives (generic "Rich has replied." when it cannot decrypt), because Android deprioritizes high-priority messages that show nothing.

Google answers map onto the APNs outcomes. `UNREGISTERED` (404), `SENDER_ID_MISMATCH` (403) and a 400 whose field violation names `message.token` delete the token and its pending jobs. 429 and 5xx retry on the shared backoff. 401 drops the cached access token and retries. Any other 4xx is a configuration failure and keeps the phone's token.

Configuration: plain-text bindings `FCM_PROJECT_ID` and `FCM_APPS` (from the private profile's `fcm: {projectId, apps}`), and the Worker secret `FCM_SERVICE_ACCOUNT`, which holds the service-account JSON file Google issues. The Worker signs an RS256 assertion with that key using WebCrypto, exchanges it for a one-hour access token (scope `firebase.messaging`) and reuses the token across requests in the isolate. A missing or mismatched project, key or application ID refuses registration. The key never enters Git, argv, a profile, a deployment artifact or a log.

Existing databases get schema 3 with the single `-- migrate 3:` statement in `connect/schema.sql`, applied once before the schema-3 Worker is uploaded. The column is nullable; rows written before it are APNs. The schema-2 Worker keeps working after the migration, and rolling the Worker back cannot send an FCM token to Apple, because an FCM row has no APNs environment.

Headless tests exercise the actual SQLite schema, signed service handler, token lifecycle, retry limits and APNs JWT/payload generation. Native notification delivery still requires a signed physical build and a real device token. Simulator acceptance, a fake provider and an HTTP 200 from the Worker do not establish device delivery.
