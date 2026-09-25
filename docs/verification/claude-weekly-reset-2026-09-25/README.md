# Desktop Claude weekly reset integration

Implemented on `codex/claude-reset-offers`, starting from `33db5a7a`, the quota merge
onto `9a51c580`. No engine quota watcher or private HQ rulings were changed.

## Behavior

- Five-hour automatic pause remains its existing, separate 93% rule.
- Reset offers are read at startup and session boundaries, then every five minutes.
  Errors honor the existing ten-minute backoff. Unknown data never means zero offers.
- Technical Settings shows the offer, remaining count, expiry and affected limits.
- The user can approve one use well before 99% weekly usage. Confirmation names the
  offer and condition. Approval survives app restarts and can be revoked before use.
- The desktop host runs the prepared action when **overall weekly usage reaches 99%**.
  It requires no model turn. Five-hour utilization never triggers this action.
- The work orchestrator also receives `richos_quota.status` and
  `richos_quota.use_approved_reset`. Neither tool can grant approval. The front desk
  does not receive reset execution tools.
- Account, grant, affected limits, expiry, remaining count and provider eligibility
  are checked again before use. Account changes invalidate approval.
- An exclusive process lock serializes approval, revocation and execution. A durable
  one-use attempt is saved and its directory synced before the request is sent.
  Success consumes approval. Ambiguous results or a crash block another attempt for
  that account and offer. No automatic POST retries are made.
- Quota is refreshed after an attempt; a reset response alone does not invent new
  usage figures or release paused work.

## Provider interface

Claude Code 2.1.282 contains and uses these internal interfaces:

- Read identity: `GET https://api.anthropic.com/api/oauth/profile`.
- Read offers: `GET https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1`.
- Redeem: `POST https://api.anthropic.com/api/organizations/{organization}/reset_rate_limits`
  with `program`, `grant_id` and a persisted `request_id`.

Only the GET interfaces were exercised against the real account during research.
**No real reset was redeemed or approved in this task.** Redemption tests use a fake
transport. UI screenshots use fictional quota/offer fixtures.

The normal `get_usage` response contains null offer blocks until explicitly queried.
A null block is unknown. The dedicated read supplies remaining resets, time bounds,
`clears`, `usable_now`, provider conditions and the next grant identifier. Some accounts
can receive an ineligible response for the CLI surface despite a web offer; the panel
preserves that distinction.

The transport uses the installed Claude version and saved Claude login. On macOS,
credentials come from the same Keychain service as Claude Code; tokens stay in memory
and HTTP request stdin, never process arguments, logs, snapshots or model responses.
Authentication overrides are refused rather than reading a different saved account.
These are internal APIs, not a documented stable integration contract. Malformed or
changed data fails closed. Reset authorization currently requires Unix file locking;
other platforms report unsupported instead of allowing an unguarded reset.

## Verification

The quota backend tests cover early approval, restart, revocation, account changes,
99% and 100% weekly boundaries, high five-hour usage with low weekly usage, malformed
and expired offers, changing grants, provider refusal, contention, scope revocation,
ambiguous replies and a crash after durable intent. UI tests cover early two-step
approval, cancellation, revocation, uncertain results and both themes.

### Result: verification blocked, not ready to merge

Implementation through `2495a072`; the working tree was clean for the final selection.
`origin/main` was `9a51c580`, already an ancestor of the worktree base.

- The requested `python3 richos/app/scripts/proof-run.py --keep-going origin/main..HEAD`
  was run. It found and led to fixes for a reset lock inheritance race and the earlier
  quota change's missing `time` dependency audit. The restarted default run waited
  for host CPU admission without starting a check and was interrupted.
- To obtain a complete bounded report without bypassing CPU or worker limits, the
  final invocation added `--admission-wait 0`. It exited **1**: **86 checks selected,
  0 passed, 0 test failures, 86 not admitted**. Host sampling reported mean 99% CPU,
  maximum 100%; all seven samples exceeded the 80% admission line. Some checks also
  encountered the shared machine worker ceiling. This is not a passing proof.
- The exact generated report is [proof-admission-report.md](proof-admission-report.md), with the
  tested commit recorded in the same report.
- Earlier executed checks: all 32 quota unit tests passed after the lock fix; the
  full core unit suite then passed 864 tests with one ignored. The core integration
  run stopped at the dependency audit, which is now corrected but not rerun.
- Tauri test compilation passed after the missing `quota` fixture was fixed.
  The standalone lint run passed before the final review fixes, reporting
  `clippy::let_underscore_must_use` at 777 for rust-fast and 165 for Tauri.
- The earlier UI run passed 15 of 16 checks. Its remaining selector was corrected,
  but the final quota UI suite and refreshed screenshots remain unverified because
  the full selection could not obtain admission. Do not treat older screenshots as
  proof of this final revision.

Rerun the full command above when host capacity is available. The full suite must
pass before handing this branch to Rich as merge-ready. No reset was approved or
redeemed and no app was installed by this work.
