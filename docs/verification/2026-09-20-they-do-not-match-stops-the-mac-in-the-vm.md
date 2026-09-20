# `They do not match` on the phone now stops the Mac — walked in the test VM

**The defect.** Ray, nightly `.8`, defect 1 (HIGH),
`2026-09-20-nightly-1.2.0-nightly.20260919.8-phone-path-in-the-vm-audit.md`: pressing
`They do not match` dropped the credential and left the Mac answering on 8443 at t+10, 20,
30, 40, 50 and 60 s and two minutes later, with the pairing card unchanged on screen.

**Identity of what was walked.** `RichOSSourceCommit = 0a14d70379798b2bfb920b37c6b9e101b18ea29a`,
version `1.2.0-dev.0a14d703`, read out of the running bundle's own `Info.plist` inside the
guest. Guest `echo-forget1` (Tart clone, deleted afterwards), app pid 676, Safari in the same
guest standing in for the phone, side by side and never overlapping. **Nothing was rendered,
launched or clicked on the host**: `pgrep -fl richos-tauri` on the host is empty before and
after. No `pmset`, no `caffeinate -d`/`-u`, no modifier keystroke, no host keychain — the only
keychain this walk created lives inside the disposable guest.

## The measurement

`curl` on 8443 **from this Mac**, which is outside the guest entirely — Ray's own instrument,
over the tailnet:

```
BEFORE  exit=0  http=200          <- positive control: the Mac was answering
clicked "They do not match" on the phone page                     t0
t+0.35s  curl exit=0  http=200    <- still answering; the socket is closing
t+1.42s  curl exit=7  http=000    <- REFUSED
```

**1.42 s**, against Ray's criterion of seconds and this work's own ceiling of 5 s. The Rust
end-to-end test measures the same transition at **1 ms** over loopback; the difference is the
tailnet round trip and the one-second probe interval, not the app.

## What the person at the Mac sees

Before the press (`frames/2026-09-20-they-do-not-match/01-before-the-press.png`): the card reads *"It has reached this
Mac. Check that the six words on it are the six words below…"* over
`peanut flame hotel parlor orange filter`, and the phone is asking the question.

After it (`frames/2026-09-20-they-do-not-match/02-the-mac-says-it-stopped.png`), in one sentence:

> **I stopped**
> Your phone said the six words did not match, so I stopped answering, forgot the phone, and
> deleted the certificate this Mac was serving.
> `[ Set my phone up again ]`

The six words are gone, the paired card is gone, and the screen is not `This Mac is ready`.

**And the certificate really went** (`frames/2026-09-20-they-do-not-match/03-set-my-phone-up-again-new-words.png`): pressing
`Set my phone up again` minted a new authority, whose six words are
`farmer gutter ocean jaguar decade filter` — a different fingerprint from the one that was
rejected, which is what a deleted CA looks like from the outside.

## Cleanup (CEO §54)

`testvm/stop.sh echo-forget1`: *"clean: app quit, VM stopped, clone deleted, state removed"*,
with `pgrep` for `richos-tauri` verified empty in the guest (pid 676). The host was verified
clean afterwards too.

## Two harness notes, neither of them product faults

1. **Ray's defect 3 reproduced exactly.** `run.sh` printed `tailnet=not-joined` —
   *"failed to connect to local tailscaled … /var/run/tailscaled.socket: no such file or
   directory"*. A later `tailnet.sh join echo-forget1` succeeded in 37 s. The join still waits
   a fixed interval rather than for the daemon's socket.
2. **Ray's defect 5 reproduced, and here is the workaround that unblocks it.** An empty
   fixture home has no keychain, so `Set my phone up` raised `Keychain Not Found`. Creating one
   **inside the guest** unblocks it without going near the host's:
   `HOME=<payload>/home security create-keychain -p <pw> $HOME/Library/Keychains/login.keychain-db`,
   then `list-keychains -d user -s` and `default-keychain -d user -s` the same path; the app
   then asks for that password once, in its own dialog.
