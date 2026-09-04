> **REFERENCE EXAMPLE — advanced "identity-or-refuse" tier.** This document
> came from a real Convex + native-mobile project; product identifiers were
> genericized to placeholders (example / legacyapp). It documents a *pattern*
> (SHA-baked-in artifacts; verify rendered data — never trust a timestamp),
> not a drop-in spec. Adapt only if your project has an analogous deploy/
> device pipeline. See reference/advanced-tier/README.md.

# The Client Data-Render Contract

**Last updated:** 2026-07-08
**Owner:** Rich (orchestrator), the infrastructure engineer, the backend engineer (day-key timezone contract)
**Status:** Mandatory for all client-app QA, install, and audit work.

> **Jump to:** the [Canonical day-key timezone contract (2026-07-08)](#canonical-day-key-timezone-contract-2026-07-08)
> is the authoritative decision for how Android, iOS, and the server key
> `dailyActivity.date` / `foodLogs.date` / check-in weeks. It **supersedes**
> the in-code "Why UTC" doctrine currently baked into
> `example/ios/ExampleApp/Data/TodayKey.swift`, Android
> `DashboardRepository.kt` `todayDate`, and every reader that resolves
> "today" in UTC. Read it before touching any day-key call site.

## The rule

> Every freshly installed Example client app (Android / iOS) must render
> Marcus's canonical seeded values on Home byte-for-byte. No QA can run
> until the on-device render matches the canonical SSOT.
>
> No screenshots. No "looks right." No "the data is on staging." No "I
> signed in and it loaded." **Render-match or refuse.**

This contract is the **data-render plane** complement of the code-identity
plane established by [`docs/freshness-contract.md`](./freshness-contract.md).
Code-identity says "the bytes on the device are the commit we think." This
contract says "the numbers those bytes render match the numbers the seed
wrote." Both are necessary; neither alone is sufficient.

## What this eliminates

The **zero-steps class** of QA waste: Home renders `0` or `1,575` for a
canonical Marcus account where the seeded value is `10,500`. Every past
incident of this class has been the same bug with a different surface:

- 2026-04-13 — native Home rendered zeros because `seedE2E:run` had never
  been invoked against the deployed backend. Fixed by the backend's `dataFreshnessProbe`.
- 2026-04-22 — Android Home rendered `1,575` (partial-day HC counter) while
  iOS Home rendered `10,500` (Convex canonical). Two hours spent debugging
  a "parity bug" that was really a source-precedence issue between HC and
  Convex in `HomeViewModel.refresh`.
- 2026-04-22 (later) — QA rubber-stamped a HomeView parity audit PASS
  because the screen had "all the right primitives" even though the
  numbers disagreed by a factor of 7.

All three would have been caught in under a minute by a client-data render
check. This contract is the machinery that forces the check.

## What "canonical" means

The single source of truth is `scripts/client-data/canonical-values.sh` — an
illustrative adopter path. The genericized copy bundled with this reference is
[`canonical-values.sh`](canonical-values.sh), beside this file.
It is POSIX-`sh` sourceable, lives at the shell plane, and is consumed by
every layer that writes or verifies Marcus's state:

| Consumer | How it reads canonical | What it does with it |
|---|---|---|
| `scripts/android-hc-seed.sh` | `. scripts/client-data/canonical-values.sh` | passes `--steps $CANONICAL_TODAY_STEP_COUNT` to the HC seeder broadcast |
| Android HC seeder (`HcSeederReceiver.kt`) | `BuildConfig.CANONICAL_TODAY_STEP_COUNT` (gradle injects from the `.sh` file at configure time) | default step count when the broadcast omits `--ei stepsPerDay` |
| Convex seed (`seedE2E.ts`) | `import { CANONICAL_* } from "./canonicalValues"` — the TS mirror of the `.sh` file | writes Marcus's server-side state |
| Convex reverse-verify (`seedE2E:verify`) | same | reads server state back, asserts == canonical |
| Universal client-data verifier (`scripts/client-data-check.sh`) | `. scripts/client-data/canonical-values.sh` | compares on-device render to canonical |
| iOS HealthKit seeder (future) | same shell source (via xcodebuild `SetEnv` phase) | writes HealthKit samples on Simulator |

Hardcoded duplicates of canonical literals in seed files are a policy
violation enforced in the original project by `scripts/hooks/lint-canonical-literals.sh`.
That script is **not bundled with this reference**, so there is nothing here to link to;
an adopter writes their own.

## What parity checks must ignore

Parity checks must ignore values that are not stable seeded content and do
not define the visual contract:

- Wall-clock strings: `Last Sync`, "Today, 11:10 am", "minutes ago",
  generated week/date labels whose value is derived from the current day.
- Device-state diagnostics: permission cache timing, sync freshness,
  pending local upload counts and HealthKit/Health Connect runtime state
  unless those values change a visible status color, icon or CTA branch.
- Environment identifiers: build dates, seed IDs, debug metadata, simulator
  or emulator-only fields.
- Runtime-flex aggregates that are explicitly documented as MIN-floor
  checks, not exact pins.

Parity checks must still enforce values that affect visible layout, visual
state or user-facing content:

- Hero numbers, card counters, progress values, badge counts and list row
  values.
- Text that can change wrapping, row height, sort order, card state, icon
  state or color.
- Navigation chrome, pinned header behavior, bottom tabs, scroll behavior,
  typography, spacing and component geometry.

When a field is excluded, the exclusion must live in the adapter/verifier
contract, not in an auditer's subjective screenshot notes. HealthSync
`Last Sync` and `Last Date` are excluded for this reason: they are
wall-clock/device-state fields, while `isConnected` and
`isHealthDataAvailable` remain enforced because they drive visible status.

## The universal verifier — `scripts/client-data-check.sh`

```
scripts/client-data-check.sh <platform> [expected-sha]
```

Delegates to a platform adapter, parses its JSON dump, and compares every
canonical field. Prints one green ✓ or red ✗ per field. Exits:

| Exit | Meaning |
|---|---|
| `0` | every canonical field rendered matches |
| `2` | one or more fields MISMATCH — contract VIOLATED |
| `3` | platform adapter missing — contract NOT VERIFIED (rollout warning) |

Environment variable `CLIENT_DATA_CONTRACT_ENFORCE=1` promotes two
rollout-era soft failures to hard fails:

- adapter binary missing (exit 3) → exit 2
- adapter RAN but omitted a required v1 Home-surface key (exit 3 under
  the rollout-era policy) → exit 2 with a distinct
  "CLIENT DATA CONTRACT VIOLATED" diagnostic (M-2, automation-QA Layer 2
  remediation). This closes the "adapter regression masquerading as
  'not landed yet'" failure mode.

Flip the env var on once both adapters have landed stably; the rollout
phase ends when you stop seeing skipped fields on a healthy install.

## The adapter interface (§5)

Each platform ships a stand-alone adapter script at
`scripts/client-data/<platform>-home-state-adapter.sh`:

```
scripts/client-data/<platform>-home-state-adapter.sh <expected-sha>
```

**Contract:**

- Argv 1 is the 12-char commit hash the installed app MUST self-report. The
  adapter SHOULD do its own sanity check (e.g., grep BUILD_SHA) and refuse
  to dump if the on-device build isn't that SHA.
- On success, write a single well-formed JSON object to STDOUT and exit 0.
- On any error (no device, app not installed, no Home state exposed, etc.)
  write a diagnostic to STDERR and exit non-zero.
- STDERR is purely informational. STDOUT is machine-consumed.

### SSOT vs Home-render-surface — the intersection rule

`canonical-values.sh` declares **all** canonical Marcus state — including
server-only values like `clientEmail`, `displayName`, `totalKcal`,
`restingHeartRate`, and peer-breadth. Those are verified **server-side**
by `seedE2E:verify` (example/convex/seedE2E.ts), which reads Marcus's
row back after a seed and asserts every field matches canonical.

The **Home adapter surface** — the keys the client-data verifier actually
compares — is the intersection of those canonical values that actually
render on Home across BOTH Android and iOS. Server-only fields (no
visible rendering) + Android-only fields (totalKcal, restingHeartRate —
rendered on Android but not iOS today) + ancillary aggregates
(peerCount — not a discrete Home field) are dropped from the adapter
surface for v1. They remain canonical; they just aren't the client
verifier's responsibility.

**v1 Home adapter surface — 11 required keys + 1 gate:**

| Key | Type | Semantics |
|---|---|---|
| `cachePrimed` | boolean | **Gate.** When `false`, the Home view has not yet loaded canonical values from its local cache (profile + XP + latestActivity + homeRemote not all present). The verifier fails with exit 2 immediately, skipping the 11 numeric comparisons — they would be meaningless. |
| `steps` | int | Today's step count (DashboardState.stepCount on Android; HealthKit-derived on iOS). |
| `activeKcal` | int | Today's active calories. |
| `stepGoal` | int | Profile daily step goal. |
| `caloriesTarget` | int | Profile daily calorie target. |
| `proteinTargetG` | int | Profile daily protein target. |
| `xpLevel` | int | Current XP level. |
| `xpTotal` | int | Total XP accumulated. |
| `xpToNextLevel` | int | XP remaining to next level. |
| `xpProgressPercent` | int | Progress-into-current-level percentage (0–100). |
| `foodLogCount` | int | Food logs for today. Canonical is a minimum (≥ 3). |
| `dayNumber` | int | Day-of-program. Canonical is a minimum (≥ 1); rule-derived via `profile.createdAt`. |

Missing keys from the surface are reported as `⊘ SKIPPED` but — unlike
earlier drafts — every key above SHOULD be present on a healthy v1
adapter. A skip is a real signal that the adapter is incomplete, not
graceful degradation.

Extra keys the adapter may emit (ignored, never failed): `feastDay*`,
`activeChallenge*`, `plateauDaysRemaining`, `proteinG`,
`caloriesConsumed`, `foodStreak`, `availableFreezes`, `schemaVersion`,
forensic fields, etc. Any key not in the v1 surface table is allowed.

**Android adapter blueprint:** register a debug-only broadcast receiver
(mirror of `HcSeederReceiver`) that dumps `DashboardState` to logcat as
JSON when triggered. The adapter calls `adb shell am broadcast
com.example.app.debug.DUMP_HOME_STATE`, then greps logcat for the dump.

**iOS adapter blueprint:** register a debug-only URL scheme handler
(`example-debug://home-state`) that writes the current `HomeViewModel`
state to the Pasteboard or a well-known file. The adapter calls `xcrun
simctl openurl` then reads back.

### Derivation rules

Some canonical fields aren't fixed constants; they depend on today's wall
clock and the server state at seed time. The contract defines each rule
explicitly:

- `dayNumber` — `floor(localDate(now) - localDate(profile.createdAt)) + 1`,
  minimum 1. Today's seed pegs `createdAt = now` so dayNumber = 1 on the
  day of seed run, 2 the next day, and so on. Verifier accepts any integer
  ≥ 1; tighter assertion is possible once adapters report the profile's
  `createdAt` alongside the rendered `dayNumber`.

### HC seeder gap — `steps` / `activeKcal` `⊘ SKIPPED` on emulator runs

On Android-emulator-only installs, the adapter may legitimately return
`null` for `steps` and `activeKcal` even on a healthy install. The root
cause is upstream of the contract: the Android client sources today's
step count and active calories from Health Connect (HC), and HC on the
emulator is populated by a separate debug-only broadcast receiver
(`HcSeederReceiver`, fired by `scripts/android-hc-seed.sh`). If the HC
seeder has not yet fired against this emulator session — for example
during a bare `install-fresh` run before the HC broadcast step, or on
CI runners that skip HC seeding entirely — the emulator's HC store is
empty and the client dashboard renders `null` for both fields.

The contract is behaving correctly in that case:
`client-data-check.sh` reports `⊘ SKIPPED` for each null field, exit
code 3 ("adapter missing"), and the install-fresh gate prints a
warning rather than a hard fail. `CLIENT_DATA_CONTRACT_ENFORCE=1`
promotes the same situation to a hard fail (exit 2), which is the
correct end-state once HC seeding is reliably part of every install
path.

Not a contract bug; an HC-pipeline reliability gap owned by
the Android + device-QA pair. Documented here so future operators don't chase the
SKIPPED as a verifier defect or canonical-value drift.

## Where the contract is enforced

| Location | What runs | Fail behavior |
|---|---|---|
| `scripts/android-install-fresh.sh` (§9) | `client-data-check.sh android <sha> --screen <screen>` for Home, FoodLog, Pantry, Messages, Steps, Trophies, Leaderboard, Check-In, Challenges, HealthSync and Profile | exit 2 (violation) = hard fail; exit 3 (adapter missing) = warning during rollout, hard fail when `CLIENT_DATA_CONTRACT_ENFORCE=1` |
| `scripts/ios-install-fresh.sh` (§8) | same full-screen contract for iOS | same |
| `scripts/deploy-example-staging.sh` (data step) | `seedE2E:verify` runs alongside `dataFreshnessProbe:verify` | `ok:false` = hard fail (canonical drift in seed) |
| `scripts/hooks/verify-agent-prompt.sh` (V7) | blocks QA agent spawns for audit/parity/render tasks unless the prompt cites `android-install-fresh.sh` or `ios-install-fresh.sh` as precondition | blocks the Agent tool call |
| `scripts/hooks/lint-canonical-literals.sh` | scans seed files for canonical numeric drift | exit 2 when a canonical literal appears outside `canonical-values.sh` |

## QA consequence — simple and non-negotiable

Every QA agent (device, functional, automation) runs `android-install-fresh.sh` or
`ios-install-fresh.sh` before any audit work on an installed app. The
install-fresh script invokes `client-data-check.sh` automatically and
refuses to report exit 0 on a contract violation. So:

> If `android-install-fresh.sh <sha>` returns 0, the installed app is both
> the expected commit AND rendering canonical Marcus data across every
> covered screen. **Start the audit.**
>
> If it returns non-zero, **STOP**. Report "install-fresh failed:
> [SHA-mismatch | data-contract-violated | adapter-missing]" to Rich.
> Do NOT screenshot. Do NOT investigate. Do NOT patch.

This is the same policy as the Freshness Contract; both are enforced by
the same install-fresh flow, at the same exit-code.

## The six reasons this is a contract, not a suggestion

1. **Zero-value regressions look exactly like bugs.** Seed-side and
   client-side failures are observationally identical from a QA
   screenshot — "Home shows 1,575 steps" is the same pixel output
   regardless of whether HC overrode Convex (client bug) or the seed wrote
   1,575 (server bug). Only comparing rendered values to canonical can
   separate the two.

2. **Structural audits lie.** "Same primitives, same layout, same
   skeleton" is a PASS under a structural rubric AND a FAIL under a data
   rubric. QA has rubber-stamped the former when it matters is the
   latter. V7 + the contract remove the option.

3. **Every "fresh install" is not fresh.** APKs, HealthKit caches,
   Keychain entries, and Convex rows have historically persisted across
   what QA called a fresh install. The contract forces the render-time
   ground truth.

4. **Seed scripts drift silently.** A Convex schema change + a
   half-updated seed = wrong data in staging with no compile error. The
   reverse-verify query (`seedE2E:verify`) closes this loop.

5. **"Audit on staging" is ambiguous.** What values should staging show?
   Who decides? Without canonical SSOT, every agent answers differently
   and the question becomes "whose answer this week" not "what the
   contract says."

6. **The adapter interface scales to future platforms.** When Example
   ships watchOS, Wear OS, or a TV client, the contract onboarding is
   "add `<platform>-home-state-adapter.sh`." No rewrite. No committee.

## §7 — The data-contract seal: closing every testing channel

Install-fresh is the human-facing gate, but it isn't the only way a test
reaches the local app. Engineers can invoke `./gradlew test` from a
shell. Agents can run `xcodebuild test`. Even Rich can type a Playwright
invocation in the terminal. Each of those is a channel that the pre-§7
contract didn't cover.

§7 closes every channel with a single machine-checked artifact: the
**seal**.

### What the seal is

A JSON file at `.claude/state/client-data-seal-<platform>.json`, written
ONLY by `scripts/client-data-check.sh` on an all-green run. Shape:

```json
{
  "sha": "d6f0322dcb1a",
  "canonicalHash": "sha256:a6234769c7b49f9d...",
  "timestamp": "2026-04-22T09:10:19Z",
  "platform": "android",
  "deviceId": "emulator-5554",
  "values": { "steps": 10500, "xpLevel": 7, "cachePrimed": true, ... },
  "hmac": "hmac-sha256:BU8s5rEaaQIX5XEmvj1kuyuAmyErr+ymqMTx8LHF9sw="
}
```

`values` is forensic — it's the adapter's JSON dump at seal time, for
operators debugging a later failure. `hmac` authenticates the seal
against a secret the verifier also reads (see "HMAC signing" below).

### HMAC signing (v4 — automation-QA Layer 2 H-4 remediation)

Before v4, the seal was trusted purely by filename + content shape. An
attacker with filesystem write access to `.claude/state/` could forge a
valid seal in four fields — `sha` (from `jj log`), `canonicalHash` (from
`shasum`), `timestamp` (from `date`), `platform` — all computable from
whitelisted commands. No cryptographic check.

v4 adds an `hmac` field:

- **Format:** `hmac-sha256:<base64>` where `<base64>` is
  `HMAC-SHA256(secret, canonical_sorted_json(seal_minus_hmac))`.
- **Secret:** 32 random bytes at `.claude/state/seal-hmac.secret`
  (0600, gitignored via the blanket `/.claude/*` rule). Minted by
  `scripts/client-data-check.sh` on first seal write, reused thereafter.
- **Payload:** `python3 json.dumps(body, sort_keys=True, separators=(",",":"))`.
  Deterministic bytes — any change to any field, including key order,
  produces a different HMAC.
- **Enforcement:** `scripts/client-data-seal-verify.sh` reads the same
  secret, recomputes the HMAC, and rejects on mismatch / missing /
  malformed.

**Threat model bounds.** The HMAC does NOT defend against an adversary
with read access to `seal-hmac.secret` — they can mint a valid seal with
the real secret. The goal is closing the "naive agent writes a 4-field
JSON" bypass class the automation QA exploited in §F.38. A secret-leak attack requires
a compromised agent that can read from `.claude/state/`, which leaves
forensic trail (access to a clearly-named secret file is a red flag in
any audit).

If you need stronger guarantees in the future, the next step would be
OS-level filesystem ACLs on `.claude/state/` (not portable across dev
setups) or setuid install-fresh (significant operator complexity).
Neither is warranted for today's threat model.

### When the seal is invalid

Eight independent invalidation rules, checked by
`scripts/client-data-seal-verify.sh <platform>`:

1. **Missing** — the file doesn't exist for the platform.
2. **HMAC secret missing** (v4) — `.claude/state/seal-hmac.secret` is
   absent; the seal cannot be authenticated at all.
3. **HMAC missing / malformed / mismatch** (v4) — the seal has no `hmac`
   field, or it's the wrong format, or it doesn't match an HMAC computed
   from the current secret. This is the gate that fails the automation QA's §F.38
   forge attack.
4. **Stale SHA** — `sha` doesn't match the current main tip.
5. **Canonical drift** — `canonicalHash` doesn't match the current
   SHA256 of `scripts/client-data/canonical-values.sh`. Any
   canonical-values change invalidates every in-flight seal.
6. **TTL expiry** — `timestamp` is older than
   `CLIENT_DATA_SEAL_TTL_SECONDS` (default 1800 = 30 minutes).
7. **Future-dated** — `timestamp` is more than 60s in the future (clock
   skew caps at 60s; beyond that is a red flag).
8. **Parse-unparseable or platform-field-mismatch** — corrupted or
   hand-edited seals are rejected outright.

The HMAC check (rules 2–3) runs BEFORE the state-based checks (4–8),
so a forged seal that happens to match today's main SHA is still
rejected outright.

**Why 30 minutes?** An install-fresh cycle (build, erase, install,
launch, seed, adapter-dump, compare) takes 3–6 minutes on a modern Mac.
30 minutes gives a comfortable window for running the full test suite
while short enough that a Marcus-account drift (e.g., a manual reseed
during the window) bounds the staleness a developer can accidentally
trust.

### Invalidation triggers — automatic

The seal is wiped (so it cannot be trusted) at:

- **Start of `scripts/android-install-fresh.sh` / `ios-install-fresh.sh`**
  — pre-install wipe. Re-issued only if the install's post-gate
  `client-data-check.sh` returns 0.
- **Start of `scripts/android-hc-seed.sh`** — reseeding HC changes what
  the adapter would read next, so any prior seal is stale. (iOS seeder,
  when it lands, must do the same.)
- **Canonical-values file change** — enforced by the hashing rule; no
  manual wipe needed.
- **Main SHA advance past the sealed SHA** — enforced by the stale-SHA
  rule.
- **TTL expiry** — enforced by the timestamp rule.

> **UPDATE 2026-07-07 (hook-swap migration, step 1.5 —
> `docs/agentic-setup-migration-log.md`):** the always-on
> `PreToolUse[Bash]` test gate (`verify-test-bash.sh`) described in the
> next three subsections is **RETIRED**. The seal machinery itself is
> unchanged and still load-bearing: install-fresh mints seals,
> `client-data-seal-verify.sh` validates them,
> `freshness-check.sh --with-data-contract` hard-fails on invalid seals,
> and the Agent-spawn gate (V7 in `verify-agent-prompt.sh`) still blocks
> QA dispatches that don't cite install-fresh. What changed is WHERE
> enforcement fires: at the dispatch + install-fresh + deploy
> chokepoints, not on every Bash call. The subsections below are kept as
> the historical spec of the retired Bash channel; the git history of
> `scripts/hooks/verify-test-bash.sh` holds the implementation.

### What testing channels were gated (RETIRED 2026-07-07)

`scripts/hooks/verify-test-bash.sh` was a PreToolUse hook on the Bash
tool. Registered in `.claude/settings.json`; executed on every Bash
invocation by any actor (agent, Rich, or the user). It matched the
command string against an enumerated testing-pattern list. The table
below was the human-readable twin of the `TEST_PATTERNS` array in
`verify-test-bash.sh`:

v4 (automation-QA Layer 2 H-1/H-2/H-3/M-1) pivoted the patterns from "match
command shape" to **"match binary name anywhere"**. A test-runner
binary name appearing inside a `python -c` string, `bash -c` wrapper,
`npm run` subshell, or any other indirection still trips the hook
because the binary name is present in the raw command string that
Claude Code passes to Bash.

| Pattern (ERE) | Platform | What it covers |
|---|---|---|
| `gradlew[^[:alnum:]]+.*([[:alnum:]_]+[Tt]est[Ss]?\|connectedAndroidTest\|connectedCheck\|connectedDebugAndroidTest\|connectedStagingAndroidTest)` | android | Android test tasks — including `python -c "subprocess.run(['./gradlew','connectedAndroidTest'])"` (H-1) |
| `xcodebuild[^[:alnum:]]+.*\btest\b` | ios | iOS unit / UI test runner |
| `xcrun[[:space:]]+simctl[[:space:]]+launch.*\.xctest` | ios | Simulator test bundle launch |
| `adb[[:space:]]+(-s[[:space:]]+[^[:space:]]+[[:space:]]+)?shell[[:space:]]+am[[:space:]]+instrument` | android | Android instrumentation |
| `(^\|[^a-zA-Z0-9_-])playwright[[:space:]]+test\b` | both | Playwright E2E (any wrapper / path prefix) |
| `(^\|[^a-zA-Z0-9_-])(vitest\|jest\|mocha\|cucumber\|ava\|tap)([[:space:]]\|$\|'\|")` | both | JS test runners — binary name anywhere (M-1 dropped the `.*example` qualifier) |
| `(^\|[^a-zA-Z0-9_-])pytest([[:space:]]\|$\|'\|")` | both | Python pytest |
| `python[[:digit:].]*[[:space:]]+-m[[:space:]]+(pytest\|unittest)\b` | both | `python3 -m pytest` / `-m unittest` |
| `\./node_modules/\.bin/(vitest\|jest\|playwright\|mocha\|cucumber\|ava\|tap)([[:space:]]\|$)` | both | Direct bin-path invocation of JS runners |
| `(^\|[^a-zA-Z0-9_-])(npm\|pnpm\|yarn)[[:space:]]+test([[:space:]]\|$)` | both | **Bare** `npm test` / `pnpm test` / `yarn test` (H-2) |
| `(^\|[^a-zA-Z0-9_-])(npm\|pnpm\|yarn)[[:space:]]+run[[:space:]]+(test\|t\|e2e\|ci\|check\|spec)([[:space:]-]\|:\|$)` | both | `npm run test:e2e` and friends (H-2) |
| `(^\|[^a-zA-Z0-9_-])(npm\|pnpm\|yarn)[[:space:]]+(exec[[:space:]]+)?(vitest\|jest\|playwright\|mocha\|cucumber\|ava\|tap)([[:space:]]\|$)` | both | `npm exec vitest` and friends |
| `(^\|[^a-zA-Z0-9_-])(make\|gmake)[[:space:]]+([a-zA-Z0-9_-]+[:_-])?(test\|check\|ci\|e2e\|unit\|integration\|it\|spec\|verify)([a-zA-Z0-9_:.-]*)([[:space:]]\|$)` | both | Makefile test-shaped targets (H-3) |
| `(bash[[:space:]]+)?(example\|scripts)/[[:alnum:]/_-]*test[[:alnum:]/_-]*\.sh` | auto | Ad-hoc shell test runners under example or scripts |

On match, `verify-test-bash.sh` invokes
`client-data-seal-verify.sh <platform>`. A valid seal passes through; an
invalid/missing seal blocks with exit 2 and a diagnostic. The `both`
platform requires BOTH seals valid.

### Whitelist — the escape from circularity

The tools that ESTABLISH a seal cannot themselves require one. The
whitelist (`WHITELIST_PATTERNS` in `verify-test-bash.sh`) always allows:

- `scripts/{android,ios}-install-fresh.sh`
- `scripts/client-data-check.sh`
- `scripts/client-data-seal-verify.sh`
- `scripts/freshness-check.sh`
- `scripts/client-data/...` (canonical file + adapters)
- `scripts/hooks/lint-canonical-literals.sh`
- `scripts/android-hc-seed.sh` and the future iOS seeder
  (`scripts/ios-*-seed*.sh`)
- `scripts/convex` / `./scripts/convex` (Convex wrapper; handles
  `seedE2E:verify`)
- All `jj` / `git` commands (VCS introspection is always safe)
- `scripts/jj*`, `scripts/preflight.sh`, `scripts/lint-banned.sh`
- `scripts/deploy-*.sh` (deploy is the step that populates the
  server-side half of the contract)
- `scripts/hooks/*.test.sh` (every self-test harness, including this
  hook's own)
- `cat .claude/state/client-data-seal-*` (read-only seal introspection)
- `scripts/convex-codegen.sh`, `scripts/convex-schema-hash.sh`

### Rich is NOT exempt

Every other rule in this contract applies to Rich the same as to any
other agent. If Rich types `./gradlew :app:testStagingUnitTest` without
a valid seal, the PreToolUse hook blocks it and prints the same
diagnostic any agent would see. The contract has no orchestrator-only
escape hatch, by design: if Rich could bypass it, the whole guarantee
would be "trust Rich," which is the class of claim the contract was
built to avoid.

### The only sanctioned bypass: `data-contract-bypass:`

For genuinely-app-free testing (Convex-only UDF tests, pure shell unit
tests, server-side probe work) the Agent-spawn hook V7 accepts an
explicit opt-out line in the prompt:

```
data-contract-bypass: <human-readable reason>
```

Every bypass is logged to `.claude/state/data-contract-bypasses.log`
with timestamp, agent name, and the declared reason. Bypasses are
auditable after the fact. The Bash-level hook does NOT honor a bypass
directly — it only honors the seal — so a bypass is an Agent-level
concession, not a shell-level one. If a bypassed Agent task needs to
shell out to something that would normally match a test pattern, the
prompt has to either (a) not shell out (genuinely app-free) or (b) be
rewritten with a seal-citing precondition.

### Freshness-check composition

The Freshness Contract's `scripts/freshness-check.sh` has a new flag:

```
scripts/freshness-check.sh <sha> --with-data-contract [--tree=example]
```

This appends `android-seal,ios-seal` to the default layer set. Both
layers call `client-data-seal-verify.sh` under the hood; an invalid or
missing seal hard-fails the freshness check with exit 2. QA agents can
invoke the combined check as their single gate: SHA identity AND data
contract, in one command.

### First-time setup — installing the §7 hook stanza

`.claude/settings.json` is gitignored. Without it, Claude Code's tool
plane never invokes the Bash + Agent hooks and the §7 channel is
silently open. v5 (Frank F-4 closure) ships the canonical hook stanza
in `.claude/settings.local.json` — committed alongside this repo — and
provides a one-shot installer that resolves the placeholder paths into
the runtime `.claude/settings.json`.

**On a fresh clone, run once:**

```
scripts/hooks/install.sh
```

That reads `.claude/settings.local.json`, substitutes the
`$CLAUDE_PROJECT_DIR` placeholder with this repo's absolute path, and
writes `.claude/settings.json`. Idempotent — re-run any time you move
the repo or want to refresh the wiring.

**The shipped stanza wires four hooks (since 2026-07-07):**

- `PreToolUse[Agent]` → `scripts/hooks/verify-agent-prompt.sh`
  (spawn hygiene + the §7 qa-install-fresh dispatch gate).
- `PreToolUse[Write|Edit|MultiEdit|NotebookEdit]` →
  `scripts/hooks/guard-main-checkout-writes.sh`
  (worktree isolation; not part of §7).
- `TeammateIdle` → `scripts/hooks/teammate-idle-handoff.sh` and
  `TaskCompleted` → `scripts/hooks/task-completed-handoff.sh`
  (durable handoff event logs; not part of §7).

Removing the Agent gate opens the §7 dispatch channel the contract
wants closed.

**Verify the wiring is live:**

```
scripts/hooks/contract-integrity-probe.sh
```

That script checks seven layers — settings.json present, the write
guard and Agent gate wired to the right scripts (path-confined +
manifest-hash-matched), the wired write guard actually rejects a
known-bad main-checkout source write (canary), the wired Agent hook
script is executable, plus warn-only checks on the two event-log hooks.
Exit 0 means everything is enforced. Exit 2 prints which layer broke
and points at the fix.

**install-fresh runs the integrity probe automatically.** Both
`scripts/android-install-fresh.sh` and `scripts/ios-install-fresh.sh`
invoke the integrity probe at step 0a, before any device work. If the
probe fails, install-fresh aborts with the same diagnostic — no seal
gets minted on a machine where Claude Code's tool plane is bypassing
the contract.

### v5 §7 invariants (RETIRED 2026-07-07 with the Bash gate)

The Bash gate's contract is two-line:

> The gate must NEVER block a Bash command whose payload merely
> *describes* a forbidden pattern (a comment, a quoted-string literal
> mentioning the operator, an example in documentation). It MUST block
> a Bash command whose payload IS a forbidden pattern (a control
> operator that shell would interpret, a test-runner binary the shell
> would actually launch).

That distinction motivates v5's two HIGH-1 mechanisms:

1. **Compound REJECT** uses a quote-state-aware Python scanner that
   recognizes operators only OUTSIDE single quotes (and outside double
   quotes for `&&`/`;`/`|`/`&`). A literal `'a && b'` inside a Python
   string is data, not control flow, and stays allowed.
2. **Whitelist anchoring** binds whitelist matches to the start of the
   command string. A whitelist token appearing mid-command (`echo
   scripts/client-data/foo`) is data — the user is talking about the
   tool, not invoking it — so the whitelist refuses to short-circuit.

Future hook layers MUST preserve the same property. The R2-H2
"line-oriented grep" bug, the bootstrap-block bug the automation QA hit when its
own Write tool blocked his report file because the destination path
contained the word `report`, and the Frank F-2 fenced-code bypass are
all instances of the same anti-pattern: a static matcher conflating
data with control. Every new gate authored in this codebase must
state — in its source comments — which side of that line it sits on.

### v5.1 — determinism across seal states (third §7 invariant)

A post-v5 empirical review surfaced two regressions in the v5 hook
that v5.1 patches without changing any v5-era behavior for real test
invocations:

> **Invariant (seal-state determinism):** the §7 Bash gate's behavior
> is a pure function of the command string and the current policy
> config. Operator session history — specifically whether a valid
> seal exists in `.claude/state/` — must not flip the outcome for
> commands that are NOT test invocations.
>
> If the same command produces exit 0 under a valid seal and exit 2
> without one (for a non-test command), the gate is lying to QA:
> warm-state operators see nothing, cold-state operators see a
> "Client Data-Render Contract VIOLATED" diagnostic for a command
> that never executed a test.

The two v5.1 fixes that enforce this invariant:

1. **Bug A — data-mover whitelist.** `cat` / `tee` / `printf` /
   `echo` never execute their arguments. A `cat > findings.md <<EOF
   ... ./gradlew test ... EOF` writes a QA report; no test runs. v5
   matched the literal in the heredoc body, tried seal-verify, then
   flipped between ALLOW and BLOCK by seal state. v5.1 adds an
   anchored data-mover class to the whitelist so these short-circuit
   before test-pattern matching. `sed` / `awk` / `xargs` /
   `sh` / `bash` / `python` / `node` / `ruby` / `perl` are
   deliberately NOT in the class — each CAN execute its arguments.
2. **Bug B — fd-redirect look-behind.** The compound detector
   treated every bare `&` outside quotes as a background operator,
   including the `&` inside `2>&1`, `>&2`, `<&0`, `N>&M`, `&>file`.
   Every Bash tool call using stderr redirection was REJECTED. v5.1
   adds a look-behind: if the preceding literal char is `>` or `<`,
   the `&` is fd-redirect syntax, not control flow. A look-ahead on
   `>` covers the `&>` shorthand.

Same anti-pattern as v5's bootstrap-block class: a static matcher
that didn't distinguish data-shape (`&` as bash-redirect token,
test-invocation string as documented literal) from control-shape (`&`
as job-control separator, test-invocation as real execution). Each
future hook layer must carry a determinism assertion in its test
harness: "same command, same verdict, under every seal state." The
v5.1 harness does this explicitly with 6 World-B probes that mirror
the World-A cases.

### v5.2 — closing automation-QA Round-3 HIGH + MED class

v5 + v5.1 closed five HIGH findings. A Round-3 red team found the
machinery still honored five attack primitives against the enforcement
layer itself (not the app — the hooks). v5.2 closes every one:

> **Invariant (whitelist right-anchor):** every whitelist entry binds
> to a token boundary on BOTH sides. A whitelist hit means "this
> command IS the whitelisted tool" — never "this command STARTS WITH
> the whitelisted tool followed by something else." Prefix-only
> anchoring is a bypass, not a whitelist.
>
> **Invariant (whitelist + test-pattern mutual exclusion):** a
> command that matches BOTH a structural whitelist AND a test pattern
> is REJECTED. Whitelist entries grant permission for the tool; they
> do not grant permission to chain a test invocation. Data-movers
> (`cat`/`tee`/`printf`/`echo`) are exempt from this rule because
> they move bytes rather than execute — a test literal in their
> payload is documentation.
>
> **Invariant (markdown parsing for bypass detection):** the
> `data-contract-bypass:` opt-out line is recognized only when it
> appears as live prose — outside every fenced code block, HTML
> comment, blockquote, and indented code block. The stripper is a
> line-based state machine that treats both backtick and tilde
> fences, and REQUIRES the closing fence to lack an info string
> (markdown-spec rule). Adversarial nested fences no longer pair
> outer-open with inner-open.
>
> **Invariant (hook integrity content-hash not filename):** the
> integrity probe's Layer B resolves the wired Bash+Agent hook
> command to an absolute path, asserts the path equals the canonical
> `$REPO_ROOT/scripts/hooks/` location, AND asserts the file content
> hash matches the canonical source. Filename-substring matching
> (pre-v5.2) honored any shim named `verify-test-bash.sh` anywhere on
> disk.
>
> **Invariant (no path traversal from scripts/):** any command
> starting with `scripts/` that contains a `..` segment is REJECTED
> at the structural layer — it can only be (a) hiding the real target
> behind a whitelistable prefix or (b) bypassing the direct-children
> `.test.sh` whitelist. No legitimate tool invokes traversal from
> under `scripts/`.

The five fixes map 1:1 to the automation QA's Round-3 findings:

1. **HIGH R3-H2 — whitelist prefix bypass.** Every whitelist entry
   right-anchored via `REND=([[:space:]]|$)` (for script files) or
   `DREND=[^[:space:]/]+[[:space:]]*$` (for directory prefixes). A
   structural two-pass check re-scans the command for test patterns
   after a whitelist hit and REJECTS on dual-match. Data-movers live
   in a separate array exempt from the two-pass.
2. **HIGH R3-H3 — argv-list bypass for playwright + adb.** Binary-to-
   verb separator widened from `[[:space:]]+` to `[^[:alnum:]_-]+` /
   `[^[:alnum:]_]+`. `subprocess.run(['playwright','test'])` now
   matches on the apostrophe/comma/apostrophe sequence between the
   two tokens. Whitespace-separated forms still match.
3. **HIGH R3-H4 — V7 nested-fence bypass.** The v5 non-greedy regex
   (`\`\`\`[\s\S]*?\`\`\``) paired outer-open with inner-open under
   nested fences, leaking the bypass line at column 0. v5.2 uses a
   line-based state machine; a fence CLOSE requires the same marker
   char, at least as many marker chars as the opener, AND no info
   string. Adversarial nesting is impossible because a nested "opener"
   with info-string can't close the outer fence.
4. **HIGH R3-H5 — integrity probe path + content confinement.**
   Layer B resolves `$CLAUDE_PROJECT_DIR` placeholders, strips trailing
   args, follows symlinks via `realpath`, asserts the resolved path
   equals `$REPO_ROOT/scripts/hooks/verify-test-bash.sh`, AND asserts
   the file's sha256 matches the canonical source. Same for the Agent
   hook. Shims at arbitrary paths with matching filenames fail. Shims
   at the canonical path with modified content fail. Symlinks whose
   realpath escapes the repo fail.
5. **MED R3-M1 — `.test.sh` whitelist traversal.** Whitelist entry
   `scripts/hooks/[^/[:space:]]+\.test\.sh` (no slashes in the filename
   segment) combined with the new scripts-traversal reject gate (any
   `..` under `scripts/` → REJECT) closes both the whitelist-match
   and the fallthrough attack paths.

v5.2 also wires `scripts/hooks/install.sh` into `scripts/jj-land.sh`
step 7c. Every land re-resolves `$CLAUDE_PROJECT_DIR` in
`.claude/settings.json` from the committed `settings.local.json`,
so operator hand-edits to settings.json get overwritten on the next
land and the integrity probe stays GREEN.

### v5.3 — V8: no parallel teammate instances per team

CEO directive 2026-04-23. The bug class: `Agent{name: "X", team_name:
"T"}` when `T` already has a member named `X` silently auto-suffixes
to `X-2` and creates a second instance doing sequential work on the
same role. CEO has caught this on multiple sprints and declared it
must stop by mechanical means, not promises or memory files.

> **Invariant (no parallel teammate instances per team):** within a
> given team, there is at most one live teammate per name. An
> `Agent{name: X, team_name: T}` tool call is REJECTED when `T`'s
> `members[]` already contains an entry whose `name == X` and whose
> `status` is not `shutdown`. Auto-suffixed respawn (`X-2`,
> `X-3`, ...) is blocked at the tool-call boundary.
>
> **Resume** an existing teammate with new instructions:
> `SendMessage({to: "X", message: "..."})`.
>
> **Replace** a teammate with a fresh instance (intentional):
> (1) `SendMessage` a `shutdown_request`, (2) wait for
> `shutdown_response`, (3) THEN `Agent`-spawn with the same name.
> Never rely on auto-suffix.

V8 lives in `scripts/hooks/verify-agent-prompt.sh` and fires
independently of V1–V7 (it does not depend on `tool_input.prompt`).
It reads team configs from `$HOME/.claude/teams/<team_name>/config.json`
— outside the repo — so collision detection is a pure function of
the live team roster at spawn time. A race where a teammate is added
between read and spawn just means V8 fires correctly on the
subsequent spawn.

Schema note: members carry an optional `status` field. V8 treats
`status == "shutdown"` as permission to respawn. When the field is
absent (today's real-world schema), V8 treats the member as present
— the safest default for an over-broad block, and aligned with the
"block unless explicitly shutdown" spec.

### v5.3.1 — automation-QA Round 4 closures (R4-H1 + R4-H2)

Round 4 re-exercise found 1 HIGH + 1 MED against v5.3. Both are
closed; both introduce an invariant worth stating.

> **Invariant (Unicode-aware markdown parsing for bypass detection):**
> the V7 stripper's per-line classifiers (fence, blockquote, indent)
> treat the set of leading Unicode whitespace characters (categories
> `Zs` space-separator, `Cf` format including ZWSP/BOM, `Zl` line-
> separator, `Zp` paragraph-separator, plus ASCII tab) as equivalent
> to ASCII space BEFORE any markdown classification runs. Invisible-
> width attackers — ZWSP (U+200B), NBSP (U+00A0), LINE SEP (U+2028),
> IDEOGRAPHIC SPACE (U+3000), BOM/ZWNBSP (U+FEFF) — cannot bypass the
> fence / blockquote / indent stripper by prefixing a marker with an
> invisible char.
>
> **Invariant (integrity probe trusts a separate hash source):** the
> Bash + Agent hook files' content hashes are compared against
> committed `<hook>.sh.sha256` sidecar manifests, NOT against the live
> file itself. The sidecars are regenerated by
> `scripts/hooks/install.sh` from canonical source and committed on
> every land (`jj-land` step 7c). Any in-place edit of a canonical
> hook post-install-fresh but pre-next-land is caught by a manifest
> mismatch. The probe refuses to PASS when the manifest is missing
> or unreadable — no trusted hash source means no integrity guarantee.

The two fixes:

1. **HIGH R4-H1 — V7 Unicode-whitespace fence bypass.** The v5.2
   line-based fence stripper used `[ \t]{0,3}` — ASCII space/tab
   only — as the leading-whitespace allowance. An attacker prefixing
   `` ``` `` with a single ZWSP/NBSP/LS/IDEO-SP/ZWNBSP character
   bypassed fence recognition; any `data-contract-bypass:` line
   inside the "fenced" block leaked into the sanitized prompt. ZWSP
   especially is invisible to human reviewers.
   v5.3.1 normalizes each line's leading run of Unicode-whitespace
   chars (categories `Zs` + `Cf` + `Zl` + `Zp` + ASCII tab) to
   ASCII space before the fence, blockquote, and indent classifiers
   run. All 5 Round-4 bypass variants now BLOCK. ASCII space/tab
   regression preserved. The symmetric indent-code hole
   (`line.startswith('    ')` was ASCII-only) is closed the same
   way.
2. **MED R4-H2 — Integrity probe tautological hash.** The v5.2
   Layer B computed `sha256(WIRED)` and `sha256(CANONICAL)` where,
   after realpath resolution, both resolved to the same path — a
   hash-against-itself comparison. An inline edit of the canonical
   hook passed Layer B unchanged. v5.3.1 introduces committed
   `.sha256` sidecars written by `install.sh` from canonical source
   and checked by Layer B. `jj-land` step 7c already invokes
   `install.sh`, so a reviewer sees any hook diff alongside its
   matching manifest diff in the same commit. Bounded threat model
   documented: a local attacker who edits the hook BETWEEN two lands
   is now caught; an attacker who waits for a land to regenerate
   the manifest is not (by design — requires code review of the
   hook+manifest diff pair). R3-H5's shim-swap / path-confine
   defenses are preserved.

### v5.3.2 — automation-QA Round 5 closure (R5-H1)

Round 5 found one HIGH. The v5.2 test-pattern matcher was literal-
substring-oriented and did not interpret bash's brace-expansion or
filename-globs. An adversarial `./gradlew t{e,e}st` contains no
literal `test` at the hook-visible layer, yet bash expands it to
`./gradlew test test` at exec time. Same class affected every runner
in the pattern list: `playwright` via `p{,}laywright`, `vitest` via
`v{i,i}test`, `jest` via `j{e,e}st`, `npm` via `n{pm,pm}`, `make`
via `m{ake,ake}`, plus filename-glob `./gradlew t*` when the cwd
contains a `test`-prefixed file.

> **Invariant (pre-expansion literal parity):** the hook's view of a
> command must not diverge from the argv bash actually executes.
> For test-runner invocations, this means: (a) unquoted `*`/`?`
> glob metacharacters in the runner-head or any arg token →
> REJECT, and (b) unquoted `{...}` brace expansions are symbolically
> enumerated; if ANY alternative produces a token that matches a
> test verb (when substituted into the original token template),
> REJECT. Legitimate non-test brace usage
> (`./gradlew assemble{Debug,Release}`) passes through because no
> alternative is a test verb. Quoted braces (`"{a,b}"` or
> `'{e,e}'`) are bash-literal and therefore safe — they pass
> through at the tokenizer layer.

The v5.3.2 fix:

1. **R5-H1 closure — `verify-test-bash.sh` brace/glob detector.** A
   Python sub-process tokenizes the command respecting single/double
   quote spans, identifies the test-runner head (direct:
   `./gradlew`, `vitest`, `jest`, etc.; wrapped: `npx <runner>`,
   `npm/pnpm/yarn [exec|run] <runner>`, `env VAR=val <runner>`,
   `time <runner>`), then scans the runner token AND every following
   arg token for unquoted brace/glob metacharacters.
   - **Glob (`*`/`?`) in head or arg → REJECT.** Filesystem state is
     attacker-influenceable and cannot be simulated.
   - **Brace (`{...}`) → symbolic enumeration.** A purely-lexical
     parser (no bash invocation) enumerates alternatives up to a
     1024-expansion cap. For each alternative, substitute back into
     the original token template and check if the result matches any
     test-verb regex. If any alternative does → REJECT. If none do
     → pass through.
   - **Cap exceeded (pathological nesting) → REJECT.** A command
     that would explode to >1024 alternatives is structurally
     ambiguous to the hook and gets the conservative verdict.

Real bash expansion is deliberately NOT invoked in the hook. That
would re-open a historical shellshock-class surface and hand
attacker-controlled strings to bash as commands. The symbolic
enumerator is pure Python with zero exec paths.

Option B+C hybrid was chosen over Option B (blanket-reject any
brace) because `./gradlew assemble{Debug,Release}` is a legitimate
operator idiom in real build workflows; blanket rejection would
force operators to split every such call into two, degrading the
experience for no security win. The symbolic check preserves the
idiom while closing the attack class.

### v5.3.3 — automation-QA Round 6 closures (R6-H1 + R6-H2)

Round 6 found two HIGHs, both surgical extensions of the v5.3.2
brace/glob guard. This is the last round of the contract hardening
cycle; after v5.3.3 the contract enters maintenance mode.

> **Invariant (pre-expansion literal parity — extended to POSIX
> char-class and range-brace):** the hook's view of a command must
> not diverge from the argv bash actually executes. For test-runner
> invocations, v5.3.3 extends the v5.3.2 guarantee to cover two
> additional bash expansion mechanisms: POSIX character classes
> (`[tT]est`) and range-braces (`{a..z}est`). Both can produce a
> test verb at exec time from a pre-expansion string that contains
> no literal `test`. The guard treats `[` as a glob metacharacter
> (joined with `*` and `?`) subject to blanket REJECT in test-
> runner head/args, and extends the symbolic-brace enumerator to
> recognize range-brace syntax with per-alternative test-verb check
> under the same 1024-expansion cap.
>
> **Backslash-escaped glob metacharacters remain literal.** `\*`,
> `\?`, `\[` in a test-runner arg are bash-literal and pass through.

The two fixes:

1. **HIGH R6-H1 — POSIX character-class glob bypass.** The v5.3.2
   guard covered `*` and `?` but missed `[...]`. With a `test` file
   in cwd (common in repos with `src/test/` layouts), shapes like
   `./gradlew [tT]est`, `./gradlew t[es]st`, `./gradlew [!x]est`
   expand to `test` at exec time. v5.3.3 adds `[` to
   `GLOB_METACHARS` and introduces a `has_unescaped()` helper so
   backslash-escaped brackets (`\[`) remain literal. All 10 Round-6
   probes BLOCK; false-positive sanity preserved
   (`ls [tT]est`, `grep '[a-z]' file.txt` still ALLOW).
2. **HIGH R6-H2 — Bash range-brace bypass.** The v5.3.2 symbolic
   enumerator handled comma-brace `{a,b,c}` only. Bash also supports
   range-brace `{start..end[..incr]}` which is a separate syntax.
   `./gradlew {a..z}est` expanded to 26 args at exec time, one of
   which was `test`; the enumerator saw no alternatives and
   ALLOWed. v5.3.3 adds `_expand_range()` handling both alpha
   (single-char) and numeric ranges with optional increment. The
   enumerator tries range-brace first inside each `{...}` construct;
   on non-match, falls back to comma-brace. Nested cases
   (`{a,{b..d}}est`) work because `_parse_alternatives` calls
   `_expand_range` at nested brace openings too. Same
   EXPAND_CAP=1024 rule as comma-brace — pathological ranges
   (`{1..10000}`) REJECT under the cap.

Real bash is still NEVER invoked. The range enumerator is pure
Python; alpha ranges use ASCII ordinal arithmetic, numeric ranges
use Python ints.

**Known limitation (R6-N1 — below HIGH threshold):** bash's extended
glob `!(pattern)` (`@()`, `?()`, `*()`, `+()`) is OFF by default in
non-interactive `bash -c` invocations and requires
`shopt -s extglob` — typically set in interactive `~/.bashrc`. When
extglob is on AND a `test`-matching file exists in cwd,
`./gradlew !(xxx)` can expand to include `test`. The v5.3.3 guard
does not detect this because it depends on user-environment state
that varies across fresh clones and shells. Documented here for
future hardening if the threat surface evolves; not currently
exploitable by default.

### Operator cheatsheet

- **"I want to run a test"** → `scripts/<platform>-install-fresh.sh`
  first; seal appears on green; your test command passes through.
- **"The hook blocked me"** → read the diagnostic; run install-fresh;
  retry.
- **"install-fresh fails because the contract is violated"** → diagnose
  the seed or HC source-precedence; don't try to bypass.
- **"I'm running a test that's genuinely app-free"** → spawn via Agent
  with `data-contract-bypass: <reason>` in the prompt; the bypass is
  audited.
- **"I'm Rich and I need to land something without running tests"** →
  VCS commands are whitelisted; you can land freely. If you need to
  SHELL OUT A TEST, install-fresh first.

## Enforcement

This file is the canonical spec. `CLAUDE.md` links to it from the
Freshness Contract section. Every engineer and QA identity file will
link to it once the rollout closes. Every install-fresh script invokes
the verifier as the final gate. Every QA agent refuses to start work
until install-fresh returns 0.

If you catch yourself reasoning about "is this data right" or "the
staging backend looks right" or "the seed said success" — STOP. Run
install-fresh. Trust nothing else.

---

# Canonical day-key timezone contract (2026-07-08)

**Owner:** the backend engineer. **Status:** DECIDED. This section is the single
source of truth for how every layer keys a "day" for health activity, food
logs, and check-in weeks. It gates register **P0-3 / Cluster A** and plan
`docs/audits/2026-07-07-example-deep-audit/fix-sprint-1-plan.md` §T3. It
must land **before** Android or iOS changes any day-key call site; the two
clients currently agree with each other, so a one-sided change manufactures
real divergence. The Android and iOS engineers port in lockstep against this section;
The backend engineer aligns the server reads.

## 0. The decision, in one sentence

> **Every health/food day is keyed by the user's LOCAL calendar day
> (`YYYY-MM-DD` in the device's current IANA timezone), end-to-end — the
> writing client computes the key, the server stores it verbatim, and every
> read (client Home, client history, and the coach cross-timezone view)
> resolves "today" in the *data-owning client's* timezone, never in UTC and
> never in the reader's timezone.**

Regime chosen: **local-day keying end-to-end.** UTC end-to-end is
**rejected**; a UTC/local hybrid is **rejected**. Justification in §1.

## 1. Why local, not UTC, not a hybrid

The defect (P0-3): device health **writers** key `dailyActivity.date` by
**local** date while every server aggregation and every client **reader**
keys by **UTC**. A non-UTC user's Home/Steps hero renders 0 or stale for
hours daily (a UTC−5 user shows 0 steps from ~19:00 local until local
midnight). Same class as the 2026-04-22 "1,575 vs 10,500" incident: the
bytes are present on the server, but the reader looks under the wrong day
key and renders a wrong number. Seeds are UTC-keyed, so QA never sees it
(tests run in the window where local == UTC).

Three regimes were on the table. Evidence decides it:

**A. UTC end-to-end (readers already do this; make writers match).**
REJECTED. It removes the zero-render seam but replaces it with a
*wrong-meaning* render, which is the very failure class this contract
exists to kill:

- HealthKit and Health Connect roll steps/calories up against the user's
  **local** midnight-to-midnight window. `HealthDataReader.readDailyActivity`
  builds its `TimeRangeFilter` from `ZoneId.systemDefault()`
  (`HealthDataReader.kt:162-165`); `HealthKitRepository.readDailyActivity`
  builds its predicate from `Calendar.current`
  (`HealthKitRepository.swift:171-235`). The *unit* of the number is the
  local day. Keying that number under a UTC date attributes a local-day
  rollup to a civil date it does not belong to.
- "Today's steps" on Home must equal what the user's own Health/Fitness app
  shows them. Those apps show the **local** day. A UTC-keyed hero for a
  UTC−5 user at 22:00 would render a window that started at 19:00 the
  previous evening — a number the user's device never displays. Right
  bytes, wrong rendered number: exactly the contract's forbidden state.
- The coach still has to know *which* UTC window is the client's "now,"
  so UTC end-to-end does not even spare the cross-timezone read from
  needing the client's timezone. It buys nothing and costs correctness.

**B. Hybrid (write local, read UTC — the status quo, or any split).**
REJECTED. This *is* the bug. Any regime where the key a row is written
under can differ from the key it is read under reintroduces the zero-render
seam for some slice of the day. There is no stable hybrid; "write X, read
Y" is only safe when X ≡ Y, which is the single-regime case.

**C. Local-day keying end-to-end.** CHOSEN. The number's unit is the local
day, so keying by the local day makes the key *and* the value correct
simultaneously. Reads resolve "today" in the data-owning client's
timezone, so the client sees its own live day and the coach sees the
client's live day. No slice of the day renders zero for a day that has
data, and the rendered number always matches the device.

The in-code rationale that currently argues the opposite —
`example/ios/ExampleApp/Data/TodayKey.swift` ("## Why UTC"), the "MUST match
UTC-anchored seed day" comments in Android `DashboardRepository.kt` and
`StepsViewModel.kt` — is **superseded**. Those comments aligned the
*readers* to the UTC *seed fixture* instead of to the local *device
writers*. That was the wrong anchor: the seed is a test fixture and must be
corrected to match reality (see §5), never the reverse. Real devices
produce local-day rollups; the fixture masked the bug.

## 2. Exact specification

### 2.1 Storage key format (unchanged shape, redefined meaning)

- `dailyActivity.date` and `foodLogs.date` stay `v.string()` in
  `YYYY-MM-DD`, gregorian, `en_US_POSIX`. Schema shape does not change
  (`example/convex/schema.ts:878`).
- **New definition:** the string is the **local calendar day, in the
  device's current IANA timezone, of the instant the activity/log belongs
  to.** The "activity day" of a health sample is the local civil day
  containing the sample window that produced the rollup — which is already
  how the platforms window their reads.

### 2.2 Who computes the key

- **The writing client computes it.** Only the client knows the timezone
  the samples were recorded in and the local window that produced the
  count, so the key must be computed on the same side as the window. The
  server keeps trusting the client-supplied `date` arg
  (`dailyActivity.ts:32,58-60,131`; format-validated only — correct, keep).
- **The server never rewrites a client's stored `date`.** It only *derives*
  a "today" for its own reads (coach dashboard, cron), and it must derive
  it in the **client's** timezone — see §2.5.

### 2.3 Day boundary

Midnight `00:00:00.000` in the device's **current** IANA timezone. Formally
the key is `format(instant, tz = deviceCurrentZone, "yyyy-MM-dd")`. DST
transitions are handled for free because the platform day-window and the
key both use the same zone rules for that civil day.

### 2.4 Persisting the client timezone (the one additive requirement)

Local-day reads on the **server/coach** side require the server to know
each client's timezone. Add it to the profile:

- `users.timeZone: v.optional(v.string())` — IANA id (e.g.
  `"America/New_York"`), written/refreshed on **every** sync and on login
  (not just registration — cf. the "create hook fires at registration
  only" memory note). Fallback `"UTC"` when absent (pre-migration rows).
- `users.tzOffsetMinutes: v.optional(v.number())` — current UTC offset in
  minutes, as a cheap derivation aid and audit value.
- *(Optional, for historical fidelity)* stamp `tzOffsetMinutes` on each
  `dailyActivity` row at write time so a later timezone change cannot
  retroactively reinterpret a historical day. Not required for the P0-3
  acceptance invariant; list it as a follow-up, not a blocker.

This is the **only** schema addition the contract requires. The core
zero-render fix (client reads its own local day) needs no schema change at
all — it is purely aligning client readers to the client writers.

### 2.5 What each read must do to match

- **Client reads its own day** (`getActivityForDate`, food-log-by-date):
  already reads by the client-supplied `date` arg
  (`dailyActivity.ts:249-261`). No server change — the fix is that the
  client passes its **local** today (§3), not UTC today.
- **Coach cross-timezone view** (`dashboard.ts`): today MUST be computed
  **per client** from that client's `users.timeZone`, not once in UTC.
  Replace the single UTC `today/yesterday/dayBefore`
  (`dashboard.ts:23-33`) with a per-client local triple derived from the
  client's stored timezone (fallback UTC). This is BS-A: the coach must see
  a non-UTC client's steps/food in real time, not hours late.
- **Cron `markStaleRecords`** (`dailyActivity.ts:298`): staleness must not
  be decided by civil-date arithmetic in a single zone, or it will mark a
  live "today" row stale for users east/west of UTC. Decide staleness from
  `syncedAt` age (a row synced < 24 h ago is never stale, regardless of
  civil date) and/or widen the civil-date window to `today+1 … today−4`
  (covering every earthly zone UTC−12 … UTC+14). Prefer the `syncedAt`-age
  rule — it is timezone-free by construction.
- **Check-in "current week"** (`checkIns.ts` `getWeekStart`, defined at
  `:58-66`): the ISO week (Monday start) MUST be computed from the client's
  **local** date, not a UTC date, or an offline check-in lands on the wrong
  week (F-19) and `currentWeekSubmitted` reads the wrong week seam (F-30).

## 3. Per-owner change checklist (the lockstep alignment)

Line numbers verified against `main` at the audit SHA. Writers already key
local and **stay** local; the work is making every **reader** key local too
and adding the client-timezone plumbing.

### Android — Android engineer (`example/android/`)

Writers (already LOCAL — **do not change the anchor**, only verify):
- `data/health/HealthDataReader.kt:162-169` — `ZoneId.systemDefault()`
  window, `LocalDate.now(zone)` today. Correct; keep.
- `data/sync/SyncRepository.kt:111,137,148` — `LocalDate.now()` (local) for
  `syncForeground` / `syncBackfill` / `syncToday`. Correct; keep.

Readers (change UTC → LOCAL):
- `data/dashboard/DashboardRepository.kt:241-242` — `todayDate` is
  `LocalDate.now(ZoneOffset.UTC)`. Change to device-local; delete the
  "MUST match UTC-anchored seed day" comment.
- `ui/steps/StepsViewModel.kt:194` — synthetic-history anchor
  `LocalDate.now(ZoneOffset.UTC)`. Change to device-local.
- `ui/foodlog/FoodLogViewModel.kt:46,174,336,375,493` — all five
  `LocalDate.now(ZoneOffset.UTC)` occurrences → device-local.

Timezone plumbing + observer:
- Send `timeZone` (IANA) + `tzOffsetMinutes` on every sync payload so the
  server profile can be refreshed.
- `data/sync/TimeZoneChangeReceiver.kt:57-76` — already re-runs
  `syncForeground()` on `ACTION_TIMEZONE_CHANGED`. Once readers are local,
  this becomes correct (re-reads the current local day; the reader reads
  the current local day). Ensure it also pushes the updated timezone to the
  server profile. See §4 for the reconciliation rule (Android risk #5: do not
  "write both keys, reconcile neither").

### iOS — iOS engineer (`example/ios/`)

Writers (already LOCAL — **do not change the anchor**, only verify):
- `Data/HealthKit/HealthKitRepository.swift:171-235` — `Calendar.current`
  window; row keyed via `dateKey(startOfDay, calendar:)`.
- `Data/HealthKit/HealthKitRepository.swift:423-430` — `dateKey` uses
  `calendar.timeZone`. Correct for the local write; keep.

Readers (change UTC → LOCAL):
- `Data/Dashboard/DashboardRepository.swift:294` — `todayKey(...)` default
  is `TimeZone(identifier: "UTC")`. Change the production default to
  device-local (keep the `timeZone:` param for hermetic tests).
- `Data/Dashboard/DashboardRepository.swift:213` — `fetchTodayActivity`
  consumes `todayKey()`; inherits the fix.
- `Data/HealthKit/DailyActivityRepository.swift:266-271` — `dateKey` uses
  `utcCalendar`/`utcTimeZone`; and `decideSyncBranch:203-213` computes
  `todayKey`/`daysBetween` in UTC while feeding local `Date`s to the writer
  (P2-2 "mixes anchors"). Unify on local so the branch decision and the
  written key share one zone.
- `Data/TodayKey.swift:57-62` — invert the doctrine: `TodayKey.utc()` is no
  longer the server-keyed "today." Rewrite the "## Why UTC" section to
  "server-keyed today = LOCAL," make `TodayKey.local()` the server-key
  helper, and route the readers through it. (Keep a UTC formatter only if
  some genuinely UTC-anchored value still needs it — none in the day-key
  path after this change.)

Timezone plumbing + observer:
- Send `timeZone` + `tzOffsetMinutes` on every sync payload.
- Add the iOS timezone-change observer (ISAAC-P1-10 — none exists today):
  observe `NSSystemTimeZoneDidChange`, re-run the foreground sync, and push
  the updated timezone to the server profile. Mirror Android's receiver.

### Server — backend engineer (`example/convex/`)

- `schema.ts` — add `users.timeZone` + `users.tzOffsetMinutes` (both
  optional); optionally `dailyActivity.tzOffsetMinutes` for historical
  fidelity (follow-up).
- `dailyActivity.ts:32,58-60,131` — `syncActivity` keeps storing the
  client `date` verbatim; additionally persist `timeZone`/`tzOffsetMinutes`
  onto the client's `users` row (write-through on sync).
- `dashboard.ts:23-33` — replace the single UTC `today/yesterday/dayBefore`
  with a **per-client** local triple derived from `client.timeZone`
  (fallback UTC). Feeds both the steps read and the food-log/traffic-light
  read (F-12, `dashboard.ts:228-233`).
- `dailyActivity.ts:298` (`markStaleRecords`) — switch staleness to a
  `syncedAt`-age rule (timezone-free) and/or widen the civil-date window to
  `today+1 … today−4`.
- `checkIns.ts` `getWeekStart` (`:58-66`) — compute the ISO week from the
  client's local date, not a UTC date (F-19, F-30).

### Coach PWA — front-end engineer (acceptance case, likely no code change)

- The coach activity render (`example/src`) inherits corrected values once
  `dashboard.ts` keys per-client-local. It is an **acceptance case (BS-A)**,
  not necessarily a code change — verify it renders the client's live
  local-day number rather than a UTC-lagged one.

## 4. Timezone-change reconciliation rule (Android risk #5 / IOS-P1-10)

On a device timezone change (travel, DST):

1. Update the stored profile `timeZone`/`tzOffsetMinutes` (client → server
   write-through), so the coach view immediately follows the client.
2. Re-read and **upsert** the current local day and the previous local day
   under the **new** timezone (Android `syncForeground()` already does
   today + yesterday; iOS must do the same in its new observer).
3. Because storage is keyed `by_tenant_user_date` and the write is an
   upsert, re-writing the **same** civil-date key overwrites in place — no
   duplicate row for a given civil day.
4. If the timezone change shifts the civil date (rare — e.g. crossing the
   international date line), you legitimately get two rows for two adjacent
   civil days; that is two real days of the user's life, not a double
   count. The forbidden state is writing the **same** civil day under two
   keys and reconciling neither — the upsert-by-key rule prevents it.
5. The read side always resolves "today" in the device's **current**
   timezone, so the Home hero is correct the instant the change lands,
   regardless of how the historical rows fell out. Multi-day aggregates sum
   **distinct** civil-date rows only.

Historical backfill uses the same rule: each backfilled day is keyed by the
local civil day it represents; the reader reads by local civil day; they
align by construction.

## 5. Acceptance invariant (QA at a NON-UTC test clock)

The regime is invisible when local == UTC, so **all** P0-3 acceptance runs
MUST use a non-UTC test clock (device/emulator TZ set to, e.g., UTC−5
`America/New_York`, seed clock keying the same local day).

**Invariant.** For a client in UTC−5 at **22:00 local** (03:00 UTC the next
day) whose device has today's data:

1. The client's Home **Steps** hero renders the client's real **same
   local-day** step count — `CANONICAL_TODAY_STEP_COUNT` (**EXACT pin =
   `10500`**), not `0` and not the adjacent day.
2. The coach dashboard for that client renders the **same** number (BS-A) —
   no UTC lag, no hours-late under-report.
3. **No read returns `0` for a day that has data**, at any local hour,
   including the UTC-midnight-to-local-midnight window that previously
   showed zeros.
4. Food-log "today" for the client and on the coach traffic light reflects
   the same local day: `CANONICAL_TODAY_FOOD_LOG_COUNT` (**EXACT = `3`**;
   the `_MIN` floor `CANONICAL_TODAY_FOOD_LOG_COUNT_MIN = 3` is the
   at-least assertion), `CANONICAL_TODAY_FOOD_CALORIES = 1540` (F-12).
5. An offline check-in submitted at 22:00 local lands on the **correct ISO
   week** (Monday-start in local time) and `currentWeekSubmitted` reads
   that same week (F-19, F-30).

Drive every numeric assertion through the canonical-values SSOT,
`scripts/client-data/canonical-values.sh`, and honor MIN-floor vs EXACT-pin
semantics (per `feedback_canonical_min_vs_exact_pins`): `CANONICAL_TODAY_*`
step/calorie/food totals here are **EXACT pins**; the `*_MIN` variants
(`CANONICAL_TODAY_FOOD_LOG_COUNT_MIN`) are at-least floors — never assert a
floor as an equality or vice-versa.

**Seed/fixture co-requisite (do not skip).** The seed currently anchors
Marcus's rows to `todayUtcStart` (UTC-keyed) — that is exactly what masked
P0-3. When the clients+server land the local regime, the seed and the
canonical harness MUST key today under the **same local test-clock day** as
the device, or the acceptance test at a non-UTC clock is meaningless (it
would re-mask the bug). This is a downstream (T3 implementation) task, but
the contract records it here so no one lands the client fix against a
still-UTC fixture and declares green.

## 6. Folded symptoms → acceptance cases (do not re-file)

All of the following are one bug (P0-3) and become tests, not new tickets:
F-12 (coach traffic-light RED for non-UTC food loggers,
`dashboard.ts:23-24,228-233`), F-19 (offline check-in wrong week,
`checkIns.ts` week math), F-30 (`currentWeekSubmitted` UTC-week seam),
iOS P1-10 (no iOS TZ observer) / P2-2 (`decideSyncBranch` mixes anchors,
`DailyActivityRepository.swift:203-213`), Android risk #5 (TZ-change re-sync,
`TimeZoneChangeReceiver.kt:57-76`), automation-QA P0-3 (untested on all three
layers), and BS-A (coach cross-timezone under-report).
