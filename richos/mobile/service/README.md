# Mobile update policy service

This service distributes update metadata independently of a user's Mac. It never carries conversation content. Executable application changes stay in signed app bundles distributed through Apple. Policies can choose notices and disable existing actions; they cannot supply scripts, screens or arbitrary navigation destinations.

## Run and publish

The module exports `serve`, `preview`, `publish` and `readPolicy`. It needs Node with no additional packages. On a development Mac, use the mobile CLI:

```sh
RICHOS_UPDATE_DIRECTORY=/Volumes/E1TB/caches/richos-policy node richos/mobile/cli/mobile.mjs update serve
RICHOS_UPDATE_DIRECTORY=/Volumes/E1TB/caches/richos-policy node richos/mobile/cli/mobile.mjs update preview /path/to/request.json
RICHOS_UPDATE_DIRECTORY=/Volumes/E1TB/caches/richos-policy node richos/mobile/cli/mobile.mjs update publish /path/to/request.json
```

The operator owns a mode-0700 directory. Publication uses a local exclusive lock, archives a revision with the operator identity and atomically activates it. HTTP has no publication route. Separate CLI locks allow publication while the service runs. A failed activation can consume a revision; the next attempt must use a higher number. Never manually replace `active.json` with an older record to roll back.

`serve` defaults to an ephemeral loopback port. `RICHOS_UPDATE_PORT` can select a fixed port. Deploy the exported service independently of user Macs behind HTTPS with a supervised process, protected operator access and a persistent private policy directory. Keep proxy buffering off for SSE and use `Cache-Control: no-store`. Do not log client IPs, cookies or request bodies in application or proxy logs. No public deployment is performed by the development CLI.

Public routes are `GET /v1/policy`, `GET /v1/events` and the bounded optional `POST /v1/metrics`. The stream checks activated revisions every second and sends keepalives every 15 seconds. Connections are capped. Native clients refetch on stream hints; the hint is not policy authority. They retain a 60-second foreground fallback and reconnect a failed hint stream after 15 seconds.

A publication request contains `policy`, `operator`, `previewDigest` and, when recommending a release, `availability`. Preview accepts the same `policy` plus a `clients` array and returns the digest and evaluated decisions. Copy that digest into the publication request only after reviewing the affected clients. Every policy change, including withdrawal and rollback, needs a new increasing revision.

## Policy and availability

Schema 1 requires:

- `revision`: positive integer, monotonically increasing.
- `issuedAt` and `expiresAt`: timestamps with a lifetime no longer than 24 hours.
- `severity`: `none`, `banner`, `dialog` or `blocking`.
- `title` and `message`: plain text, limited to 100 and 1,200 characters.
- `allowDismiss`: boolean, with `remindAfterSeconds` between 60 and 604,800.
- Optional `features`: boolean switches for `text` and `recording`.
- For a notice, `latest`: numeric `version`, `build`, `minimumOS`, fixed numeric `appId`, three-letter App Store `storefronts` and `verifiedAt`.
- Optional `minimum` version/build and `blockedBuilds` entries formatted `version+build`.

The minimum cannot exceed the replacement, and the replacement cannot itself be blocked. A blocking policy blocks only affected builds with an eligible replacement. Other eligible clients receive a dialog. Marketing versions and builds compare numerically. The client uses its actual StoreKit storefront, not a locale guess. Unknown storefront, unsupported OS, mismatched listing ID or an already-installed replacement prevents promotion. Version 1 supports iPhones meeting the OS floor without additional hardware requirements; release verification must confirm that remains true before publishing a receipt.

Availability must be verified recently, at most 24 hours before policy issue. The `availability` receipt repeats all `latest` fields, sets `downloadVerified: true` and includes an `evidence` reference. A trusted release operator must actually verify download availability for every included storefront and the minimum supported device/OS. This is an operator attestation, not an automated Apple availability oracle. Approval or a scheduled release is insufficient. Keep actual download evidence privately. No receipt may be created from a synthetic test policy for production use.

The app's compiled configuration supplies the Store ID and fixed support endpoint. Policy data cannot redirect either destination. The Update button opens `https://apps.apple.com/app/id<configured ID>`. Store authentication, download and installation remain Apple's controls.

## Failure and recovery

Ordinary notices wait while recording or sending. Critical policies stop affected new actions, retain captured audio and preserve drafts and queued work. Feature switches are checked at action and transport boundaries. Existing in-flight sends may already have reached the Mac; their idempotency IDs preserve safe acknowledgement/retry handling.

Invalid, stale or out-of-order policy responses are rejected. An outage retains the last validated policy without extending its expiry. On expiry, that policy's block and feature restrictions are released; the app keeps trying to fetch fresh policy. This is deliberate protection against a permanent lockout caused by a dead service. The Mac can still reject unsupported operations. Messages held after a disabled action remain visible and can be retried explicitly once it is restored.

To recover from a bad policy, preview and publish a higher revision restoring the intended switches and prominence. Do not reuse an old revision. Test cache expiry and offline recovery, including a phone that never received the withdrawal. Keep backward-compatible Mac and service contracts while an app fix is in review.

## Metrics and release operations

Client reporting is off in the development configuration. When enabled after privacy review, it sends only an event name, numeric app version/build and policy revision. Allowed events are policy-visible, policy-failed, store-opened and store-failed. The native boundary constructs the payload; there is no arbitrary analytics body. The service also counts policy responses. It aggregates by UTC day, event, build and revision, retains at most 30 days and writes counters every minute. Reports count events, not unique people or installs. No identity, stable device ID, conversation text or pairing information is collected.

`update metrics` reads the private aggregate report. Before enabling collection publicly, document the provider/proxy logging settings, retention, purpose and user-facing privacy disclosure. Review delivery failures and build adoption by counts; do not imply these counts prove installations or unique-user adoption.

Before the first public release: create the actual app listing, select and deploy the independent service/support endpoints, verify distribution rights and current Apple submission requirements, complete signing/artwork/privacy records and verify the actual Store Update button on a supported iPhone. Exercise an old-to-new Store installation once two released builds exist. Keep Connect and Tailscale coverage separate. Prepare a known-good higher-revision withdrawal and evidence for an expedited-review request before enabling a mandatory production block.

Apple's [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) and [StoreKit storefront documentation](https://developer.apple.com/documentation/storekit/skstorefront) govern the distribution and storefront checks. Remote policy controls do not bypass App Review.
