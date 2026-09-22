# Connect endpoint bootstrap

`connect-bootstrap.mjs` reserves the managed control service's HTTPS address. It is not the managed connection implementation. `GET /healthz` reports that this worker is answering with `stage: bootstrap` and `ready: false`. The root returns 503 with a short unavailable message. Other paths and all mutation methods return 404. The worker never reads request bodies, logs requests, stores data or forwards requests to a Mac.

Run through the mobile development loop:

```sh
node richos/mobile/cli/mobile.mjs connect artifact
node --test richos/mobile/test/connect-bootstrap.test.js
```

The artifact command emits the exact Worker module, SHA-256 and multipart upload metadata. It makes no deployment or network requests. Tests import that same module and exercise refusal and readiness behavior, then execute the real CLI in an isolated session. No native or simulator rebuild is needed for this service change.

An operator can upload the artifact using Cloudflare's Workers Scripts API and attach an owned Custom Domain. Keep account/zone identifiers, hostname selection and deployment receipts in the private operations repository. Disable workers.dev and preview URLs using the artifact's `subdomain` settings. Workers observability, Logpush and tail consumers are off. This does not disable Cloudflare's own provider/security processing or establish future conversation-log privacy.

Check that the hostname is unallocated before attaching it. Cloudflare manages the Custom Domain's DNS record and certificate; do not add a placeholder CNAME or send the hostname to a local development server. Verify the external HTTPS response with certificate validation enabled. Check `/healthz` for the exact bootstrap payload, `/` for 503 and `/api/messages` for 404.

No tunnel, database or credential is created by this bootstrap. Enrollment, authenticated ownership, tunnel allocation and revocation, the signed Mac connector and a remote phone proof must land before Connect becomes usable. Conversation traffic will go directly through its tunnel endpoints, separately from this control Worker. The independent update-policy service is also not deployed by this step.

For rollback, remove only this worker's Custom Domain attachment and worker. Before doing so, recheck that the deployment is still this bootstrap and has no enrolled users. Never remove the domain's nameservers, unrelated DNS records or other account resources.
