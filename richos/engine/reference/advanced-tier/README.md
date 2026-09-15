# Advanced tier — the "identity-or-refuse" pattern (REFERENCE ONLY)

Everything in this directory is a **reference example**, not part of the engine's
mechanical layer. Nothing here is wired into any hook or `settings.json`, and
nothing here is expected to run as-is. These files were lifted from a real
project (a Convex backend + native Android/iOS apps + Railway staging) and
**genericized**: every product identifier was replaced with a placeholder
(`example`, `legacyapp`), and the one hardcoded test credential was replaced
with `<TEST_PASSWORD>`. Cross-file path references still point at the original
layout and will not resolve here — that is expected for reference material.

## Why it's here

The mechanical layer (hooks + config) enforces **orchestration** discipline:
worktree isolation, spawn contracts, durable handoffs, single-writer landing.
This tier demonstrates a second, deeper idea that is worth stealing but is
inherently stack-bound:

- **Freshness / identity-or-refuse** (`freshness-check.sh`,
  `freshness-contract.md`): every build artifact carries the commit SHA baked
  *inside* it, and every consumer verifies that SHA before trusting the
  artifact. No timestamps, no "the deploy said success" — **identity or
  refuse**. The *idea* is universal; the implementation hardcodes Convex
  function names, staging hostnames, and a two-tree layout.
- **Client data-render contract** (`client-data-check.sh`,
  `canonical-values.sh`, `client-data-contract.md`): right bytes on the wire
  are not the same as the right numbers on screen. A single source of truth
  (`canonical-values.sh`) pins the expected rendered values, and a verifier
  checks the *rendered* app against them. The *pattern* (verify rendered data,
  not just transport) is reusable; every value here is one project's seed data.
- **Fresh-install gates** (`android-install-fresh.sh`, `ios-install-fresh.sh`):
  a device install that verifies SHA identity AND canonical render before any
  QA runs. Platform-specific (adb / xcrun simctl / Health Connect / HealthKit).
- **Zombie-worktree guard (Layer 1)** — each reference install-fresh inlines
  `assert_own_worktree_registered`, which proves at startup and before every
  state-write phase that the run's own location is the true main checkout or a
  path currently REGISTERED in `git worktree list`, aborting loudly otherwise.
  It stops an orphaned background install-fresh that outlived its agent AND its
  reaped worktree from re-creating the removed path and minting a seal into that
  ghost directory. Physical (`pwd -P`) path normalization avoids the macOS
  `/var`→`/private/var` mismatch. The *pattern* (a long-running writer verifies
  its own location is still live before writing) is reusable; the `git worktree`
  mechanics are specific to the native-isolation land model.

## The opt-in hook connection

The mechanical layer's `verify-agent-prompt.sh` carries an **OFF-by-default**
gate (`ENABLE_QA_INSTALL_FRESH_GATE` in `orchestration.config`) that, when
enabled, blocks any spawn which tests/audits/renders the local app unless the
prompt cites an install-fresh script as a precondition. Turn it on ONLY if you
adopt an analogous device pipeline; otherwise leave it off and ignore this tier.

## The seal / HMAC machinery — generate your own secret, never ship one

`client-data-check.sh` can write a signed "seal" JSON attesting an all-green
verification. The seal's `hmac` field is
`HMAC-SHA256(secret, canonical_sorted_json(seal_minus_hmac))`. The **secret is
minted on first use, never committed**:

- Location (example): `.claude/state/seal-hmac.secret`, `chmod 600`, gitignored.
- Generate a fresh one on any new machine (the machinery does this automatically
  on first seal write; to pre-seed it manually):

  ```sh
  mkdir -p .claude/state
  openssl rand -base64 32 > .claude/state/seal-hmac.secret   # fallback: head -c 32 /dev/urandom | base64
  chmod 600 .claude/state/seal-hmac.secret
  ```

The secret is **instance-specific by design** — it must never leave the machine
that minted it, and no secret value ships with this engine. Threat model (from the
original): the HMAC does not defend against an adversary who can already read
`.claude/state/`; it closes the "a naive agent hand-writes a plausible-looking
seal JSON" forgery class. Adopt the *mint-on-first-use, never-commit* pattern
verbatim; treat the actual bytes as unshippable.

## If you want to adopt this tier

1. Decide whether your project even has a deploy/device pipeline where "verify
   identity before trusting an artifact" applies. If not, skip it entirely.
2. Re-implement `freshness-check.sh` against YOUR deploy surface (your backend's
   version endpoint, your staging hostnames, your build markers).
3. Re-author `canonical-values.sh` with YOUR seed data, and rewrite the
   per-screen adapters in `client-data-check.sh` for YOUR rendered surfaces.
4. Adapt the install-fresh scripts to YOUR platforms.
5. Only then flip `ENABLE_QA_INSTALL_FRESH_GATE=1` in `orchestration.config`.
