> **REFERENCE EXAMPLE — advanced "identity-or-refuse" tier.** This document
> came from a real Convex + native-mobile project; product identifiers were
> genericized to placeholders (example / legacyapp). It documents a *pattern*
> (SHA-baked-in artifacts; verify rendered data — never trust a timestamp),
> not a drop-in spec. Adapt only if your project has an analogous deploy/
> device pipeline. See reference/advanced-tier/README.md.

# The Freshness Contract

**Last updated:** 2026-04-13
**Owner:** Rich (orchestrator)
**Status:** Mandatory for all code, QA, and deploy work.

## The rule

> Every artifact that exists anywhere on disk — on a device, on a server, in a
> working copy, in a build cache, in a reference design folder, in a memory
> file — has a commit SHA baked INSIDE it. Every consumer verifies that SHA
> against the expected SHA before trusting the artifact.
>
> No timestamps. No filenames. No "should be." No "I just built it." No "the
> deploy said success." **Identity or refuse.**

The single failure mode this exists to eliminate: consumers trust metadata
(timestamps, filenames, "deploy succeeded" log lines, SHA-in-the-commit-message)
instead of verifying identity from the artifact itself. Every "stale" bug in
this repo's history has been the same bug with a different surface.

## What "stamped" means

Each artifact carries its commit SHA in a location **inside** the artifact
that is impossible to fake or drift from the bytes the consumer is actually
executing:

| Artifact | Stamp location | How to read it |
|---|---|---|
| Android APK | `BuildConfig.GIT_SHA` (Kotlin), baked at gradle build time | Cold-start logcat line `BUILD_SHA=<12-char hash>`; also `aapt dump badging <apk>` shows the build-time string |
| iOS app bundle | `GIT_SHA` key in `Info.plist`, set at xcodebuild time | Console log on app launch `[BUILD_SHA] <hash>`; also `plutil -p <bundle>/Info.plist \| grep GIT_SHA` |
| Example web (SvelteKit) | `/api/__version` endpoint, SHA injected at build time via Vite `define` | `curl https://<host>/api/__version` → `{gitSha, deployedAt, tree: "example"}` |
| Legacyapp web (SvelteKit) | same | same, `tree: "legacyapp"` |
| Example Convex backend | `_version:get` public query, SHA injected into generated code at deploy time | `./scripts/convex --tree=example run _version:get` → `{gitSha, schemaHash}` |
| Legacyapp Convex backend | same | same |
| Deployed seed data (example + legacyapp) | `dataFreshnessProbe:verify` public query — asserts per-user, per-day, and per-table row counts for the canonical test user | `./scripts/convex --tree=<t> run dataFreshnessProbe:verify` → `{ok, checks: [{name, ok, detail?}, ...]}`. Every check must be `ok:true`. |
| Generated TypeScript types from Convex schema | leading `// SOURCE_SHA: <hash>` comment in generated file | codegen script fails if the embedded SHA doesn't match the current schema fingerprint |
| Seed data scripts | `SCHEMA_FINGERPRINT` constant at top of seed file | seed runner refuses to execute if `SCHEMA_FINGERPRINT` != current `convex/schema.ts` hash |
| Reference designs | locked PNG checked into `/coach-area-design/` | QA screenshot-diffs the implementation against the locked PNG |
| Main checkout working copy | n/a — the checkout itself IS the artifact | Rich's land sequence hard-asserts `git status --short` is empty after every land (`freshness-check.sh` `default-wc` layer). `default-wc` always targets the TRUE main checkout via `scripts/lib/resolve-main-checkout.sh` (dirname of `git rev-parse --git-common-dir`), so it gives the same answer whether `freshness-check.sh`'s own copy runs from main or from a linked worktree. |
| Checkout under test (opt-in `current-wc`) | n/a — the CURRENT checkout (which may legitimately be a linked worktree) IS the artifact | `freshness-check.sh <sha> --layers=current-wc` asserts the current checkout is clean AND its own `HEAD` short-SHA == the expected SHA, with **no `refs/heads/main` requirement** (a worktree HEAD is legitimately `refs/heads/worktree-<id>`). Opt-in only — NOT in the default layer set; use it to verify a worktree build. Distinct from `default-wc`: a detached HEAD at the right SHA still FAILS `default-wc` but passes `current-wc`. |
| git HEAD | n/a — HEAD itself IS the artifact | land sequence + `scripts/preflight.sh` check 8 assert `git symbolic-ref HEAD` = `refs/heads/main` (self-healing on detach) |
| Memory files (`~/.claude/projects/.../memory/*.md`) | n/a — content-based | session-start hook verifies every referenced file path/symbol still exists in current main |

## The 12-char hash

The canonical form everywhere is the **12-character short commit hash** produced by
`git rev-parse --short=12 HEAD`. Not 7 chars. Not 40 chars. Twelve.

This is non-negotiable: mixed lengths cause spurious mismatches where the
underlying state is fine. Twelve is the width Rich's freshness-check.sh asserts
against.

## The universal verifier — `scripts/freshness-check.sh`

```
scripts/freshness-check.sh <expected-sha>
```

Checks every layer listed above that is relevant to the current tree
(`example/` vs `legacyapp/`) and prints one green check or one red fail per layer.
Exits `0` if every layer matches the expected SHA, non-zero otherwise.

### The `data` layer (added 2026-04-13)

Code identity is necessary but not sufficient. Shipping the right bytes to
staging does nothing for QA if the deployed backend has no rows for today.
The `data` layer closes that gap: it calls
`./scripts/convex --tree=<t> run dataFreshnessProbe:verify` and asserts the
returned `{ ok: boolean, checks: [...] }` structure is 100% green. Every
`ok:false` check hard-fails freshness-check with exit 2.

The probe is invoked automatically as part of the default layer set
(`git,default-wc,web,convex,data` — the `jj` layer was retired with the
2026-07-07 git migration) and is enforced inside both
`scripts/deploy-example-staging.sh` and `scripts/deploy-staging.sh` as a
post-deploy gate (see table below).

### Where the contract is enforced

| Location | What runs | Fail behavior |
|---|---|---|
| Rich's land sequence (every land — `skills/rich-lander/SKILL.md`) | asserts git status clean, HEAD attached to main, `freshness-check.sh --layers=git,default-wc` green | failure blocks deploy |
| `scripts/deploy-example-staging.sh` (post-deploy) | `seedE2E:run` → `dataFreshnessProbe:verify` → `freshness-check.sh --tree=example` | non-zero seed or probe = hard fail; freshness exit 2 = hard fail; exit 3 = warning during rollout |
| `scripts/deploy-staging.sh` (post-deploy) | same as above, `--tree=legacyapp` | same |
| QA agents (functional, automation, device, design gate) | `freshness-check.sh <expected> --tree=<t>` before any test | any `✗` → STOP, report "freshness mismatch" to Rich |
| `scripts/android-install-fresh.sh` / `ios-install-fresh.sh` | force-stop → uninstall → build → install → logcat grep for `BUILD_SHA=<expected>` | non-zero on mismatch |
| Playwright suites (automation QA) | fixture fetches `/api/__version`, throws on `gitSha !== EXPECTED_GIT_SHA` | suite fails loudly |
| Seed scripts (backend) | `SCHEMA_FINGERPRINT` constant vs current `convex/schema.ts` | seed refuses to run on drift |
| Convex codegen (backend) | leading `// SOURCE_SHA:` comment in generated types | codegen wrapper fails on mismatch |

Used in two places, mandatorily:

1. **Rich, after every land**: runs `freshness-check.sh <new-main-sha>`
   immediately after the merge + `deploy-*-staging.sh` complete. If the
   check fails, the land is NOT considered complete. Do not kick off QA, do
   not report done — diagnose the mismatch first.

2. **Every QA agent, before every test**: functional, automation, device and the design gate MUST run
   `freshness-check.sh <expected-sha>` before touching the device / browser
   / API. If the check fails, STOP — do NOT test, do NOT investigate, do
   NOT patch. Report "freshness mismatch against <expected> — actual:
   <observed>" back to Rich. Rich triages.

## Why this is a contract, not a suggestion

The 2026-04-13 "zero-data" incident is the reason the `data` layer exists.
The seed code deployed cleanly, every code-identity layer reported green
(5/5 ✓), and the native Android Home screen still rendered zeros because
`seedE2E:run` mutations had never actually executed against the deployed
backend and no per-day rows existed for today. One round of QA and a CEO
escalation later, it was clear the contract was only verifying code identity
and silently trusting that data would "just be there." The new `data` layer
asserts deployed-backend data completeness via `dataFreshnessProbe:verify`
and is refreshed + verified as a mandatory post-deploy gate in both
`deploy-example-staging.sh` and `deploy-staging.sh`. Code identity AND data
identity, every deploy, or refuse.

The entire "stale APK" incident on 2026-04-12 cost:
- one failed round of QA
- one round of code review that confirmed correct code
- one round of the owning engineer reproducing on the device QA's exact device
- one observability commit
- one re-deploy
- one re-test

...all to work out that the build on the test device had never actually been
the SHA we thought it was. The `lastUpdateTime` of the APK matched the build
artifact to the minute, and was wrong anyway. **Trusting metadata is exactly
how this bug class persists.**

Under the contract, that entire sequence would have been:

> The device QA runs `freshness-check.sh c71e0bca` before testing.
> Check fails: Android APK reports `BUILD_SHA=<older>` instead of `c71e0bca`.
> The device QA reports "freshness mismatch" to Rich.
> Rich re-runs `android-install-fresh.sh c71e0bca`.
> The device QA tests. Done.

Zero wasted rounds. Zero wasted thinking. Zero "why doesn't this work."

## Enforcement

This file is the canonical spec. CLAUDE.md links to it. Every engineer and QA
identity file under `.claude/agents/` links to it. Every deploy script runs
the verifier as the final step before reporting success. Every QA agent
refuses to start work until the verifier passes.

If you catch yourself reasoning about "is this fresh" or "the timestamp looks
right" or "the deploy said success" — STOP. Run the verifier. Trust nothing
else.
