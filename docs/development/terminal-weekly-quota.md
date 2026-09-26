# Claude quota in desktop and terminal

With automatic pause enabled, desktop work pauses at 99% overall weekly usage.
The terminal watcher applies the same weekly threshold. A free reset is an
exception: an eligible offer must have explicit, unused user approval. Otherwise
the orchestrator sends the existing standard pause message unchanged. The
five-hour threshold and its strictly-less-than-20-minute exception are unchanged.
The weekly threshold has no early-release exception.

Start `richos/engine/scripts/quota-watch.sh --watch` in the orchestrator's
background terminal at session start. It checks immediately and every five
minutes, including overall weekly and provider-named model windows. Model windows
are displayed; the reset trigger uses only overall weekly usage. The existing
watcher returns when it has a pause/resume event for the orchestrator. Restart it
as instructed in that event, including while agents are paused. Reset execution
inside a running watcher does not require a model turn.

User commands, from a terminal outside an agent session:

```sh
richos/engine/scripts/quota-reset.sh status
richos/engine/scripts/quota-reset.sh approve <offer-id>
richos/engine/scripts/quota-reset.sh revoke
```

Approval requires an interactive terminal and macOS device-owner authentication.
It can be given before 99%. There is no unattended approval flag. This protects
the supported approval interface; it is not an OS sandbox against arbitrary code
running as the same account. Revocation never consumes a reset.

The source wrapper uses Cargo. An installed engine uses its native `richos-quota`
helper or an installed desktop executable that advertises the headless quota
protocol. Older desktop executables are inspected without launching them. If no
compatible helper exists, redemption is unavailable and the weekly pause still
applies. No GUI launch, app installation or app packaging is performed by this wrapper.

Desktop and terminal share `~/Library/Application Support/com.richos.app/`:
`claude-reset-offers.json`, its `.lock` file and `claude-reset-refresh.json`.
The Rust service rechecks account, usage and the exact offer before redemption.
It consumes approval and records an uncertain attempt durably under the shared
process lock before making the request. Every attempted grant is fenced from
retry. An uncertain result also blocks other grants on that account.

Neither approval nor an elapsed reset time is proof of allowance. A fresh reading
must permit work before a weekly hold releases, and the five-hour rule must also
permit work. Missing weekly data cannot clear a known weekly hold.

The opt-in `terminal_quota_proof` example uses live account and offer reads with
an isolated approval record. Its transport cannot forward a redemption request.
A real account below 99% correctly reports the trigger as blocked; unit tests
exercise the 99% trigger and concurrent consumers with fake transport.
