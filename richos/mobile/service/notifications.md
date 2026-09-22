# Native reply notifications

The Connect Worker also delivers optional native alerts. A Tailscale phone can opt into this hosted service without allocating a tunnel. The Mac signs every control request with its existing host identity. Closed pilot admission and the shared capacity bound apply to both routes.

Apply the idempotent `connect/schema.sql` before deploying the new modules. The private deployment profile may include `push: {teamId, sandboxKeyId, productionKeyId, topics}`. Topics must be the registered RichOS app identifiers. Install `APNS_SANDBOX_KEY` and `APNS_PRODUCTION_KEY` as separate Worker secrets, with their matching Apple environment keys. Keys never enter a Mac build, phone build, deployment artifact or Git. Missing environment configuration refuses registration. Debug builds use the sandbox entitlement and topic; Release uses production. TestFlight uses production APNs.

Signed routes:

- `POST /v1/push/hosts`: admit or recover the host identity without creating a tunnel.
- `PUT /v1/push/device`: register or revoke one paired phone with a monotonically increasing revision. Registration binds the device key hash, host generation, token, environment, topic and route. Token rotation replaces pending jobs. A null token revokes the registration.
- `POST /v1/push/events`: enqueue a generic reply-ready alert for the current device and registration revision. Only SHA-256 event and thread references are accepted. Extra fields, including text, are rejected.

The alert body is fixed: “Rich has replied.” Its data contains only the host ID and opaque event/thread references. The phone resolves the thread against its paired session and reconnects through authenticated HTTPS. Notification permission denial does not block text or voice. Apple controls delivery timing; provider acceptance is not proof that an alert reached a device.

Provider calls, token rotation and revocation share the host lease. Jobs expire after one hour, have at most five delivery attempts and are capped at 100 per host. The five-minute scheduler retries eligible failures and deletes expired jobs. A permanent invalid-token response immediately removes the stored token and pending jobs. Successful event IDs remain only until their one-hour expiry for deduplication. A transport failure after Apple accepted a request can result in a duplicate alert; stable collapse IDs reduce repeated pending alerts but are not an exactly-once guarantee. An alert already accepted by Apple cannot be recalled by later revocation.

Disable logs, traces, Logpush and tail consumers as in the Connect deployment. No content-bearing diagnostics are retained. Treat APNs tokens as private operational data. Rotate keys by installing a new server secret and matching key ID, verifying a physical notification then revoking the previous key in Apple Developer. Never revoke the old key first. Keep sandbox and production evidence separate.

Headless tests exercise the actual SQLite schema, signed service handler, token lifecycle, retry limits and APNs JWT/payload generation. Native notification delivery still requires a signed physical build and a real device token. Simulator acceptance, a fake provider and an HTTP 200 from the Worker do not establish device delivery.
