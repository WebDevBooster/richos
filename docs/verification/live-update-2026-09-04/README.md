# A published RichOS updated itself over the internet — 2026-09-04

**Echo (Rust and Tauri desktop engineer), 2026-09-04, 18:42–18:48 local.** Every command in
`raw/` was run by the author of this record against the **published** artifacts, downloaded
from their public release URLs. Nothing here is copied from another agent's report.

Why this record exists: `app/UPDATES.md` had said, correctly, that no update had ever crossed
a network. That stopped being true today, and a document that swings from a false negative to
a cheerful positive is no better than the one it replaced. So the five separate claims are
measured separately below, and the things still not measured are named at the end.

## What was measured

| # | Claim | Command | Evidence |
|---|---|---|---|
| 1 | One Developer ID signing identity exists on this Mac | `security find-identity -v -p codesigning` | `raw/signing-identity.log` |
| 2 | v1.0.0, v1.0.1 and v1.0.2, downloaded from their public URLs, are Developer ID signed, hardened, notarized, stapled, and `accepted` by Gatekeeper | `spctl`, `codesign --verify`, `xcrun stapler validate` | `raw/published-artifacts-and-updated-bundle.log` |
| 3 | A published v1.0.1 finds, verifies and installs v1.0.2 from the live endpoint | `RICHOS_UPDATE_SELFTEST=install` on the downloaded bundle | `raw/selftest-1.0.1-install.log` |
| 4 | The bundle it left on disk is the published v1.0.2, still notarized and stapled | same assessments, run afterwards | `raw/published-artifacts-and-updated-bundle.log`, last block |
| 5 | The microphone grant on this Mac is bound to a requirement with no `cdhash` term | `sqlite3` against both TCC databases, read-only | `raw/tcc-grant-binding.log` |

### 1. The identity

```
1) BF4D68E6F858688FDAD63148BD271FCA2D02474F "Developer ID Application: Alex Booster (TZ33A4QCZJ)"
   1 valid identities found
```

### 2. The three published releases

Each `RichOS-<version>-macos-aarch64.zip` was fetched with `curl` from
`https://github.com/WebDevBooster/richos/releases/download/v<version>/…` and extracted with
`ditto -x -k`. All three answered identically apart from their code hashes:

```
accepted
source=Notarized Developer ID
origin=Developer ID Application: Alex Booster (TZ33A4QCZJ)
```

`codesign --verify --deep --strict` returned *valid on disk* and *satisfies its Designated
Requirement*; `xcrun stapler validate` returned *The validate action worked!* — so the ticket
is stapled and a machine with no network still sees a notarized app.

Code hashes, which differ per build as they must:

| Version | `CDHash` |
|---|---|
| 1.0.0 | `8eea7497a55c906d498457c9e4a39d111e15667f` |
| 1.0.1 | `21c1718c08a531acf7fb027d2737a07e457db017` |
| 1.0.2 | `6afdf4b804ffef3a7cbb1568b2309ebfc130747f` |

Designated requirements, which do **not**:

```
designated => identifier "com.richos.app" and anchor apple generic
              and certificate 1[field.1.2.840.113635.100.6.2.6]
              and certificate leaf[field.1.2.840.113635.100.6.1.13]
              and certificate leaf[subject.OU] = TZ33A4QCZJ
```

Character for character the same string on all three, with no `cdhash` term anywhere in it.

### 3. The update itself

A pristine copy of the downloaded v1.0.1 was run with `RICHOS_UPDATE_SELFTEST=install` and
**no `RICHOS_UPDATE_ENDPOINT` in the environment**, so it used the endpoint compiled into it —
`https://github.com/WebDevBooster/richos/releases/latest/download/latest.json`, over HTTPS,
through GitHub's redirect chain to its asset CDN.

```
RICHOS-UPDATE-SELFTEST state=available current=1.0.1 available=1.0.2 percent=- failure=- detail=-
RICHOS-UPDATE-SELFTEST state=ready current=1.0.1 available=1.0.2 percent=100 failure=- detail=-
RICHOS-UPDATE-SELFTEST exit=0
```

`ready` is reached only after `tauri-plugin-updater` verifies the downloaded archive against
the minisign public key compiled into the running build. A `signature` failure would have come
back on that first transition instead.

For completeness, and without installing anything: a published v1.0.0 also sees 1.0.2
(`state=available current=1.0.0 available=1.0.2`, exit 0), and a published v1.0.2 reports
`state=upToDate` and exit 10.

### 4. What was left on disk

The same bundle then reported `CFBundleShortVersionString` **1.0.2**, `spctl` **accepted /
Notarized Developer ID**, `codesign --verify --deep --strict` valid, and the ticket still
stapled. Its `CDHash` is `6afdf4b804ffef3a7cbb1568b2309ebfc130747f` — **identical to the
independently downloaded v1.0.2 zip**, which is what proves the installed bytes are the
published notarized artifact rather than anything assembled locally.

### 5. What the microphone grant is bound to

The user TCC database holds exactly one row for this application:

```
kTCCServiceMicrophone|com.richos.app|2|2026-09-04 14:53:11
```

Its requirement blob decodes to `com.richos.app`, the two Apple Developer ID certificate OIDs,
and `subject.OU = TZ33A4QCZJ`. A `cdhash` grep over the blob returns **0**. So the grant is
satisfied by any build carrying that bundle identifier and signed by that certificate, which
is the mechanism `docs/verification/rebuild-survival-2026-09-01.md` established off the
bundles, now observed on the live grant row.

## What this does NOT prove, stated so nobody reads it as more

- **No grant has been watched surviving an update.** Claim 5 is the mechanism, not the
  outcome. Nobody has granted the microphone to one version, updated, and used the microphone
  again without being asked. The system TCC database is readable here — 20 rows, 8 of them
  accessibility — and **`com.richos.app` has no row in it at all**, so accessibility has never
  been granted to RichOS and there is nothing there to survive.
- **The update ran from an ordinary directory, not a translocated one.** The copy under test
  carried no `com.apple.quarantine` attribute. `docs/verification/first-run-as-a-stranger-2026-09-04/`
  observed a genuinely quarantined 1.0.0 running **App-Translocated** from a read-only image,
  and no update has been attempted from a copy in that state.
- **Nothing was relaunched.** The self-test exits at `ready`. Case D of
  `app/scripts/updater-e2e.sh` covers relaunch, and that run was local and offline.
- **Nothing here is about Windows**, which has never been bundled at all.

## Re-running it

```
curl -sSL -o RichOS-1.0.1.zip \
  https://github.com/WebDevBooster/richos/releases/download/v1.0.1/RichOS-1.0.1-macos-aarch64.zip
ditto -x -k RichOS-1.0.1.zip .
RICHOS_UPDATE_SELFTEST=install ./RichOS.app/Contents/MacOS/richos-tauri
```

It reaches `state=ready` only while a release newer than 1.0.1 is the latest one, which is the
point of it: it exercises whatever is actually published.
