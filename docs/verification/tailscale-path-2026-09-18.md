# The Tailscale path: what was decided, what was built, and what nobody has yet been able to prove

Branch `cc/echo-opus-tailscale1`. CEO decision §61; reach document §2.3 and §2.8; Urban's how-to
screens `richos-hq/docs/design/richos-tailscale-how-to-screens-2026-09-19.md`.

## The one fact that shapes everything below

**Tailscale is not installed on this Mac, so no part of this path has been run against a live
tailnet.** Raised as `esc-20260918T204405Z-e25d25de` (state: `proceeding`, for: `ceo`) — the brief
says the CEO installs it and that I must not install software on his Mac.

Verified absent eight ways, 2026-09-18:

| Check | Result |
|---|---|
| `ls -d /Applications/Tailscale.app` | no such file or directory |
| `which tailscale` | `tailscale not found` |
| `/usr/local/bin/tailscale`, `/opt/homebrew/bin/tailscale`, `/Applications/Tailscale.app/Contents/MacOS/Tailscale` | all absent |
| `ls ~/Library/Containers/io.tailscale*` | no such file or directory |
| `ls /var/run/tailscale*` | no such file or directory |
| `launchctl list \| grep -i tailscale` | nothing |
| `brew list \| grep -i tailscale` | not present |
| `scutil --dns \| grep -i ts.net` | no `ts.net` resolver |

The four `utun` interfaces present are not Tailscale's; none carries a `100.64.0.0/10` address.

**So every claim in this document is marked by how it was established**: *measured here*, *read
from upstream source*, or `unverified:` with the single command that would settle it.

---

## 1. Urban's open question, answered: what the six words fingerprint on this path

Urban's §6 seam 1 is the one open question that could change a shipped sentence, and it is mine.

**The answer: the six words stay, computed from the SHA-256 of the DER of the leaf certificate the
listener actually presents for the tailnet name. Screen 5's shipped six-word copy stands
unchanged. No sentence needs to change, and no change is needed in the PWA.**

### Why the mechanism carries over unchanged

*Read in the code today.* The Mac sends a hex string and the phone renders the words itself —
`web/web-app/app.js:223`, `words = fingerprint.phraseFromHex(answer.ca_fingerprint_sha256)`, with
`ca.rs`'s own note on why: *"if the Mac sent pretty words, a Mac that wanted to could send words
that do not belong to the certificate it is actually serving."* Nothing in `phraseFromHex` knows or
cares which authority the hex came from — it is 256 words, one per byte, over a list asserted
identical on both sides. **Feeding it the tailnet leaf's fingerprint instead of the RichOS CA's is a
change of input, not of mechanism**, and both screens therefore show the same six words for the
same connection by construction, which is the property Urban asked me to keep.

### What the check is worth on each path — the part that is NOT the same

This is the honest half, and it belongs in the record rather than in the copy.

**At home the six words are the only thing standing between the user and the one attack that
defeats everything else.** If `mm1.local` resolves to an attacker's Mac, the trust QR
(`http://mm1.local:8444/ca`) reaches the attacker too, so the user installs the *attacker's* CA and
the TLS handshake then succeeds honestly. Every automated link in the chain has been captured by
the same spoofed name. The user's eyes on the real Mac's screen are the only uncaptured channel,
and the words are what travels over it.

**On the tailnet path that attack is structurally impossible.** The name is bound to the machine by
a publicly trusted certificate the phone's own operating system verifies against a public root, and
an attacker cannot obtain one for a name inside someone else's tailnet. So the words are not
carrying the security property there; the certificate is.

**They are still worth showing, because a different failure is genuinely reachable.** A technical
user with a tailnet may well have more than one Mac on it, and may reach a stale bookmark, a
re-used QR from a previous setup, or a second RichOS instance. Then a *different* Mac answers, its
leaf differs, the words differ, and Screen 5's sentence — *"If they are not, something other than
this Mac answered"* — fires and is exactly right. That case is arguably likelier for this audience
than the mDNS spoof the words guard against at home.

**So: same ritual, same copy, different adversary.** Recorded here rather than in the UI because it
is a fact about threat models, not a thing to put in front of the CEO mid-pairing.

### What is left to build for it

*Not built in this slice.* The pair answer must carry the fingerprint of the certificate presented
for **this** connection, and the listener will serve two. The right source is the SNI name from the
TLS handshake (`rustls::ServerConnection::server_name()`, available at the accept site in
`listen.rs`), not the `Host` header — the Host header would also work and leaks nothing (a
certificate fingerprint is public), but SNI is what actually selected the certificate, and deriving
the reported fingerprint from anything other than the thing that chose it is how the two drift.

---

## 2. `tailscale cert` rather than `tailscale serve`, and why

The brief asked me to decide from measurement. **I could not measure, because there is no Tailscale
here.** So the decision is argued from our own code, which I did read, and from upstream's
documented behavior, which I did fetch. It is reversible and the reasons are stated so it can be
re-argued rather than re-discovered.

**First, the thing I expected to be decisive and which is NOT.** I assumed a proxy would break the
device credential. It does not. *Measured in the code:* `device.rs:184-187`, the signed string is

```
{challenge}\n{METHOD}\n{path_with_query}\n{body_hash}
```

— **the origin, the host and the port are not in it.** Any proxy preserving method, path, query,
body and the `Authorization` header preserves the credential exactly. `tailscale serve` is
credential-compatible, and the case against it has to be made on other grounds.

Those grounds, in order of weight:

1. **`serve` puts the CEO's conversation in cleartext inside somebody else's process.** `serve` is
   an HTTPS reverse proxy: `tailscaled` terminates the TLS and re-encrypts, or talks plaintext, to
   our port. Sage's §2.8 praises Funnel *precisely* because *"Tailscale does not decrypt the
   traffic"*; `serve` gives that property up on the local machine. With `cert` we hold the key and
   terminate ourselves, and Tailscale carries ciphertext only. `mod.rs`'s own framing of this
   module is that *"it holds no handle that could reach anything else"*.
2. **`serve` mutates the user's own Tailscale configuration, and it persists.** It would keep
   answering that name after RichOS quits — a 502 where there used to be nothing. That breaks
   `mod.rs`'s replacement property 1 verbatim: *"the listener does not exist until he pairs a
   phone … unpairing the last device calls `stop`, which drops the socket rather than closing a
   door."* `forget()` would have to reach into another vendor's configuration to undo it, and a
   cleanup that depends on somebody else's software is a cleanup that can fail.
3. **`serve` needs a weakened backend hop.** Our listener is HTTPS-only on 8443. `serve` would need
   either a new cleartext port or an `https+insecure://` target. Reed's comparison names TLS
   throughout as our single biggest lead over T3 Code, who ship `NSAllowsArbitraryLoads` in
   production; spending it here would be a poor trade.
4. **`cert` writes to stdout, which crosses the App Store sandbox.** *Read from upstream:*
   `cmd/tailscale/cli/cert.go` documents `--cert-file` and `--key-file` as *"output cert file or
   `-` for stdout"*. Asking for stdout rather than a path sidesteps the sandboxed variant's write
   restrictions entirely **and means the private key never touches the disk** — straight into
   memory and then the Keychain, exactly as `ca.rs` already handles every other key.

**The honest counterweight**, so this is a decision and not an advertisement: `serve` defaults to
443, which would give a port-free origin (`https://name.ts.net`), and it would handle renewal
invisibly. With `cert` we keep `:8443` and renewal is ours — `tailscale cert --min-validity` exists
for exactly that and the call is idempotent. I judge the four points above to outweigh a prettier
origin. `unverified:` that `tailscale cert` succeeds on the Mac App Store variant; upstream
documents Funnel and the SSH server as unavailable there and says nothing about `cert`, and one
command on a machine with it installed settles it.

---

## 3. What was built, and what it proves

| | Commit | Tests |
|---|---|---|
| `phone/tailnet.rs` — detection, eight states, closed-label diagnostics | `32a04341` | 15 new |
| `PhoneStatus.tailnet` — the state on the wire for Urban's screens | `ba0bafd5` | 4 new |
| This record | `86f360f3` | — |
| `listen.rs` — SNI certificate resolution, one listener serving two names | `a0359ccd` | 1 new |
| `tailnet::fetch_cert` — the certificate, to stdout, key type read off the label | `e5e3b682` | 5 new |

**164 phone tests green; the 139 that existed before this branch are untouched** (`cargo test -p
richos-tauri --bins phone::`, measured before and after). **`ui/tests/phone.js`: 10 of 10 PASS**,
run against this branch after the `PhoneStatus` change.

### The SNI resolution is proved, and the proof was probed

`the_tailnet_name_gets_the_tailnet_certificate_and_every_other_name_still_gets_our_own` stands a
real listener on an ephemeral port and drives **four** handshakes against it:

| | Name asked for | Root trusted | Expected |
|---|---|---|---|
| 1 | `mm1.local` | home | Ok — the home path is untouched |
| 2 | the tailnet name | tailnet | Ok — SNI actually switched |
| 3 | the tailnet name | **home** | **Err — the control** |
| 4 | `127.0.0.1` (an IP-literal `ServerName`, so **no SNI at all**) | home | Ok — the fallback |

Case 3 is what makes the others mean anything: had the resolver ignored SNI and served home for
everything, 3 would have passed and 2 failed; had it served the tailnet leaf for everything, 1 and
4 would have failed. Case 4 running *after* case 3 and succeeding also rules out case 3 having
"passed" because the server had stopped accepting.

**Mutation-probed rather than assumed.** `&& false` was inserted into the SNI match arm; case 2
failed with *"the tailnet name was not served the tailnet certificate"* (`listen.rs:843`), 1 failed
/ 0 passed. Reverted, 164 passed. A negative assertion nobody has watched fail is not evidence.

`unverified:` that a real Let's Encrypt chain from `tailscale cert` is accepted by a phone. That is
a claim about certificate *contents*; the test above makes a claim about *which* certificate the
resolver hands out, which is the part we wrote. The stand-in for "publicly trusted" is a second
`PhoneCa` under its own root — a good stand-in for exactly one reason, that the home root knows
nothing about it, which is what turns case 3 into a control.

### The parser is pinned to upstream's declarations, not to a recollection

Quoted verbatim in the module header, from `tailscale/tailscale` `main`:

- `ipn/backend.go` — `stateStrings = [...]string{"NoState", "InUseOtherUser", "NeedsLogin",
  "NeedsMachineAuth", "Stopped", "Starting", "Running"}`. **Seven.** All seven are asserted by name
  in `every_one_of_the_seven_backend_states_lands_somewhere_named`, so a state added upstream
  surfaces as a failing test rather than as a silent "ready".
- `ipn/ipnstate/ipnstate.go` — `CertDomains []string`, *"the set of DNS names for which the control
  plane server will assist with provisioning TLS certificates … FQDNs without trailing periods."*
- `ipn/ipnstate/ipnstate.go` — `PeerStatus.DNSName`, *"It ends with a dot."*

`unverified:` that a real `tailscale status --json` on this Mac agrees with the fixture. **Settled
by one command** once it is installed. The standing insurance is
`the_parser_ignores_everything_it_was_not_told_about`: no `deny_unknown_fields`, every field
defaulted, so a real document — which carries `Peer`, `User`, `TUN`, `Health`, `ClientVersion` and
more — cannot break it by being larger.

### Three states the brief's list did not have

The brief named four (absent / installed not signed in / signed in, name known / serving). Building
it found eight. Three are new work for Urban's screens, and each is a different thing for the user
to do:

- **`certificates-off`** — signed in, online, name known, and `CertDomains` empty. The control plane
  will not certify this tailnet: **a switch in the user's own Tailscale admin console on the web.**
  Until it is on, the publicly trusted certificate this entire path exists for does not exist, and
  a screen saying "you're all set" here would be lying. The name is reported and the origin is
  deliberately withheld. **This is Urban's screen 7 and it is the state that screen is really for
  — his copy says "MagicDNS and HTTPS certificates", and `CertDomains` is precisely the second
  half of that, answered by the daemon rather than guessed.**
- **`needs-approval`** (`NeedsMachineAuth`) — signed in correctly, waiting for a tailnet admin.
  Telling this user to sign in again is wrong advice.
- **`other-user`** (`InUseOtherUser`) — another account on this Mac holds Tailscale.

### Addresses come from the daemon, not from `ifconfig`

A `100.64.0.0/10` address on a `utun` *would* survive `names::ipv4_addresses` — it filters only
loopback, link-local, unspecified and broadcast — so the listener would likely bind it by accident.
`Self.TailscaleIPs` asks the thing that knows. "It happens to appear in `ifconfig`" is an accident
of one variant's implementation on a machine nobody here has.

### Raw output never leaves the module

`Diagnostic` is a closed label set, taken from T3 Code's own wrapper via Reed's read
(`t3code-mobile-vs-richos-phone-2026-09-18.md` idea 7): they classify this binary's stderr
*"because stderr can contain auth keys (`tskey-…`) and node names, and these labels are logged."*
`stderr_is_classified_into_the_closed_set_and_never_kept` pushes a fake `tskey-` and a node name
through and asserts neither reaches a label.

---

## 4. Not built in this slice, and what each one needs

Named plainly rather than left to be discovered. None is blocked by anything except time and the
missing tailnet.

1. **Keeping the certificate, and renewing it.** `fetch_cert` exists and is tested; **nothing calls
   it yet.** The remaining work is where the result lives — the chain and key into the Keychain
   beside the existing leaf via `secrets::Keychain`, re-fetched on a schedule. `tailscale cert`
   renews on call and `--min-validity` is already a parameter, so renewal is one idempotent call
   rather than an ACME client; the open question is only when to make it.
2. **Passing the certificate to the listener at start-up.** `tls_config_with_tailnet` takes it and
   `PhoneRuntime::start` still calls the `None` form. This is a small, purely local change and it
   is the next one to make — but it is gated on item 3 below, because a tailnet certificate with
   nothing bound on the tailnet address serves nobody.
3. **Binding the tailnet addresses.** `Listener::start` is all-or-nothing on bind failure by
   design. A tailnet address exists only while Tailscale is up, so adding it to the bind list needs
   that arm softened deliberately, or the channel will refuse to start when Tailscale is off.
   **This is a real trap and it is not hypothetical**: it would turn "Tailscale is off" into "the
   phone channel will not start at all", breaking the home path for a Tailscale user.
4. **The api_base provider and the paired origin.** `api_base.rs:21-22` already names `ts.net` as a
   future entry. The blocker is not the provider: **the device record does not record which origin
   the phone paired at**, and a home-paired phone must never be handed the tailnet origin (it is
   cross-origin, and `phone/*.rs` has no `Access-Control-Allow-Origin` anywhere, by design). The
   provider list has to be selected from the paired origin, so that field comes first.
5. **Urban's seven screens in `ui/phone.js`.** The state they switch on is on the wire and tested;
   the markup is not written. Urban's §5 has the four new CSS rules and the computed ratios, and
   his §3 state table maps one-to-one onto the tokens `TailnetView.state` emits — `absent`,
   `needs-sign-in`, `certificates-off`, `ready` and the rest — so the screen is a switch on one
   string. `ui/tests/phone.js` is 10 of 10 PASS on this branch and its check 10 (*"nothing on the
   sheet threw, in either theme"*) is what a new block has to keep true.
6. **The six words over the tailnet leaf** — §1 above. The decision is made and the copy is
   settled; the plumbing (SNI name → which fingerprint the pair answer reports) is not written.

## 5. Answers to Urban's other three seams

- **Seam 2, the precondition for a usable name.** It is two things, and `CertDomains` answers the
  second directly: a name (MagicDNS) **and** the tailnet's HTTPS-certificates switch. His screen 7
  copy naming both is correct. `unverified:` against a live account.
- **Seam 3, the admin console URL.** Not verified here either — it is behind a sign-in and I did not
  have one.
- **Seam 4, the poll interval.** Answered: `TAILNET_RECHECK_MS = 2000` in `phone/mod.rs`, with
  `recheck_tailnet()` as the Mac's half of `Check again`. Asserted in a test so the screens'
  document and the code cannot drift.

Urban's own check that the tailnet pairing URL (44 bytes) fits `ui/qr.js`'s 106-byte version-6
capacity is arithmetic I did not need to repeat and did not.

## 6. Housekeeping

No app instance was started, so there is none to quit (§54 addendum 4). No audio was played and no
`say` was run. Nothing under `.github/` was touched; CI is paused and nothing here is CI. `app/ui/**`,
`spine.rs` and `main.rs` were not modified — the detection state reaches the screens through
`PhoneStatus`, which is why no command and no `main.rs` line was needed.
