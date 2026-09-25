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

Full proof runner results are recorded after the final run below.
