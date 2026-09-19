# The test VM — on-screen proofs that never touch the CEO's screen

**What it is:** a macOS virtual machine on this same Mac that acts as the host for
anything that has to put the RichOS app on a screen. The app opens on the guest's
virtual display; the host renders no window at all. Two guests can run at once, so two
agents can each have a window instead of queueing behind one another — and behind the
CEO's working day.

**Why it exists,** in his words on 2026-09-19:

> "So, every engineer will keep opening the app making me unable to do anything here or WHAT???"

> "WHEN THE FUCK WILL THERE BE A PROPER FUCKING SETUP THAT WILL ENABLE SUPER FAST
> DEVELOPMENT AND NOT PATHETICALLY SLOW SNAIL PACE DEVELOPMENT???"

After this, no test opens a window on his Mac.

---

## The four commands

```sh
cd <repo>/richos/app/scripts/testvm

./run.sh  --bundle <RichOS.app.zip> --home <fixture-home-dir> [--vm <name>]
./shot.sh <vm> <out.png> [--ocr]
./ax.sh   <vm> '<applescript>' | --focused | --windows | --key <code>
./stop.sh <vm>
```

`run.sh` prints one line the caller can parse — this one is real output from the first
end-to-end run, on candidate `.5`:

```
vm=richos-test-1 ip=192.168.64.4 pid=717 ssh=admin@192.168.64.4 windows=1 elapsed=100s
```

**Measured, 2026-09-19.** First VM: `run.sh` to a window on screen in **100 s**
(guest boot 11 s, bundle copy 7 s, 1.8 GB fixture home 58 s, launch 3 s). Second VM
started while the first was running: **151 s** — slower only because the two were
copying payloads at once. A capture takes **~8 s**, an accessibility read **~3 s**,
and `stop.sh` **~8 s**.

Two at once is just two names:

```sh
./run.sh --bundle b.zip --home h --vm richos-test-1 &
./run.sh --bundle b.zip --home h --vm richos-test-2 &
```

**`stop.sh` is not optional.** A test instance of the app is garbage, and by CEO §54
garbage is always cleaned up. `stop.sh` quits the app, verifies `pgrep` is empty, stops
the VM, deletes the clone, and removes the run state. If any of that fails it prints a
massive alert naming exactly what to delete by hand.

---

## Does the Mac have to be left unlocked? No.

**Lock the screen, let the display sleep, walk away — the proofs keep running.** The
completion proof for this harness was deliberately captured with the host display
**asleep**, and the frame came back normally.

The reason is structural rather than lucky: the guest runs **its own WindowServer inside
the VM**. The host's screen — lit, dark, locked, or showing something else entirely — is
not connected to the guest's display in any way.

The one thing that *would* interrupt a run is the **whole Mac** going to sleep, because
that suspends the VM process along with everything else. So every VM is started under
`caffeinate -is`:

* `-i` holds off idle **system** sleep, `-s` does the same on AC power.
* **`-d` and `-u` are deliberately NOT used.** They prevent *display* sleep and declare
  the user active, which would hold the screen lit and unlocked for as long as any test
  ran — the exact intrusion this harness exists to remove.

So: **locked is fine, dark is fine, sleeping the whole Mac pauses everything.** The
assertion dies with the VM process, so nothing is left holding the machine awake after
`stop.sh`.

---

## One-time setup

```sh
./setup.sh
```

Installs Tart, pulls the guest image, provisions it, and verifies that a capture comes
back non-black before it claims success. Re-running it is safe; `./setup.sh
--reprovision` re-runs only the guest provisioning.

**Measured cost, 2026-09-19:** a **25.35 GB** compressed download (read from the registry
manifest, not estimated) taking **~65 minutes** on this connection, expanding to **62 GB
on disk** — the brief's unverified "~50 GB" was low for disk and high for the download.
Everything after the download took **2 minutes 22 seconds**: guest boot 9 s, ssh key
13 s, TCC grants 2 s, Homebrew tooling 46 s, Tailscale 11 s, reboot 25 s, capture
verification 25 s.

Disk left afterwards on this Mac: 175 GiB of 460 GiB.

### What still needs a human, once

| # | Action | Why it cannot be automated |
|---|---|---|
| 1 | **Tailscale sign-in in the guest.** `ssh admin@<guest-ip> 'tailscale up'` prints a URL; open it once and approve the node. | It needs the CEO's Tailscale account. No agent may hold or borrow those credentials. |
| 2 | **`claude` sign-in in the guest**, only if model turns are wanted there. `ssh admin@<guest-ip> 'claude /login'`. | The `claude` session lives in the **login keychain**, which macOS resolves through `HOME`. It cannot be copied from the host, and copying a credential is not something an agent does. See "Model turns" below. |

Nothing else needs a person. In particular **no host permission is required** — the
harness grants Screen Recording and Accessibility *inside the guest*, never on the host,
and the host never renders a VM window.

---

## What works in the guest, and what does not

All verified on 2026-09-19 against candidate `.5` unless marked otherwise.

| Capability | Status |
|---|---|
| App launches, window appears | **Yes** — `open -n -a` routes the launch through launchd into the auto-logged-in user's GUI session. `windows=1` reported, and the frame shows it |
| `screencapture` over ssh | **Yes** — 1680x1050, 64.3% non-black, once the TCC grant is written |
| System Events AX reads | **Yes** — `window: RichOS / role: AXTextArea / title: Message to Rich`; geometry `RichOS 1024x700 at (438,92)` |
| `tesseract` OCR | **Yes**, in-guest via `shot.sh --ocr` — it read the offer sheet's body text back. Note it cannot read from the guest's `/tmp`; everything is staged under `$HOME` |
| Home screen + engine-offer sheet | **Yes** — rendered identically to the host, including the fixture's thread history |
| Two VMs at once | **Yes** — both booted, both rendered, both captured, 32% host memory still free |
| Works with the host screen **locked/asleep** | **Yes** — the completion proof was captured with the host display asleep. The guest runs its own WindowServer; the host's screen state is irrelevant to it |
| WebGL splash / Metal rendering | Untested in this pass — the fixture home boots straight past the splash into the home screen. See "Graphics" |
| **Model turns (`claude`)** | **No, not without a one-time human sign-in** — see below |
| Audio | Out of scope. CEO §53 stands: the Mac's speakers cannot stand in for a person, and a VM's virtual audio device does not change that. Do not test barge-in here. |
| Tailscale as its own node | Installed and running, **left signed out** (action 1 above) |

**One observation worth passing on, not a harness fault:** the app derived a
**1024x700** window in the guest — its stated minimum — on a 1680x1050 screen, where on
the host it derives 1400x880. If window derivation is what you are testing, test it on
the host, or treat the guest's smaller screen as the input it is.

### Model turns — the honest answer

The app's spine shells out to `claude`. `setup.sh` copies the **binary** into the guest
so the app can find it, and copies **no credentials at all**.

With a scratch `HOME`, `claude` answers *"Not logged in · Please run /login"*. The thing
`HOME` takes away is the **login keychain** — macOS Security resolves it through the home
directory, and this was proved on the host by three probes in order: `CLAUDE_CONFIG_DIR`
alone → not logged in; plus a copied `~/.claude.json` and a `~/.claude` symlink → still
not logged in; plus `~/Library/Keychains` symlinked → ok.

A guest has no such keychain to symlink. **So: no model turns in the guest until a human
runs `claude /login` in it, once.** That is a finding, not a failure — and it does not
block the work this harness is for. The home screen, the engine-offer sheet, the splash,
window geometry, focus, theme and layout all render without a single model turn.

### Graphics

The splash uses WebGL. Apple Virtualization gives the guest a paravirtualized GPU with
Metal, so WebGL resolves — but the guest is not the host's M4 GPU and a frame is not
guaranteed pixel-identical to `ui/tests/shots-home/home-named.png`. Treat the guest as
authoritative for **layout, text, focus and state**, and confirm anything that depends on
exact GPU rasterization against a host capture.

---

## Where it all lives, and how to delete it

Everything is under **one** directory:

```
~/.richos-testvm/
  bin/tart.app        the pinned Tart binary
  tart/               TART_HOME — the base image and every clone
  run/<vm>/           per-run state: ip, app.pid, vm.pid, payload path
  log/                VM console logs
  MANIFEST            what was installed, when, from which digest
  IMAGE_DIGEST        the digest actually pulled
```

Disk: **62 GB** for the base image. Clones are **copy-on-write** on APFS — cloning the
base took **1 second** and near-zero disk until the guest diverges, which is what makes a
disposable per-run VM practical instead of a 62 GB copy each time.

**Delete everything:** `rm -rf ~/.richos-testvm` — and that is the whole story; nothing is
installed outside it. No Homebrew formula, no launch agent, no login item, no host TCC
change.

### Garbage, and CEO §54

The engine's `scratch-reaper.sh` does **not** cover this directory, deliberately: its
first wall is containment in a declared scratch root, and the 25 GB base image must
survive every sweep. So the harness cleans up after itself:

* `stop.sh` is the normal path, and verifies rather than assumes.
* `reap.sh` is the backstop for a run killed before it reached `stop.sh` — a quota pause,
  a crash, a terminated session. It deletes nothing by default:

```sh
./reap.sh            # the plan
./reap.sh --apply    # do it
./reap.sh --notice   # one line, only if there is garbage
```

It will never delete the base image, a VM it did not create, or a **running** VM.

---

## How it works, for the next person who has to fix it

### Nothing is executed before it is proven launchable

`preflight-binary.py` checks a binary's code signature, its Gatekeeper status, and —
the part that matters — that every **non-weak** dynamic dependency actually resolves,
either on disk through the binary's own `LC_RPATH` entries or in the dyld shared cache
(tested by asking the loader, in a throwaway python process).

This exists because a bare `tart --version` on 2026-09-19 put *"tart cannot be opened
because of a problem"* on the CEO's screen. Tart 2.36.0 and 2.37.0 hard-link
`@rpath/libswiftCompatibilitySpan.dylib`, a Swift 6.2 runtime that ships only with
macOS 26 / Xcode 26; this host is macOS 15.6, so dyld aborts before `main`. **A version
check is the most innocent thing you can run, and it still reached his screen** — so the
rule is not "be careful with GUI apps", it is that nothing runs until its dependencies
are proven.

The gate has a negative control: it passes 2.33.1's 71 dependencies and names the exact
missing library on 2.36.0.

### The TCC grant is the whole trick

Over ssh there is no GUI session, so the consent dialog that would grant Screen Recording
can never appear and nobody is there to click it. Without the grant `screencapture`
returns a **black frame, silently**.

`provision-guest.sh` writes the grants straight into `TCC.db`. That is only possible
because the cirruslabs base image ships with **SIP disabled** — on a stock Mac, SIP
protects those files from root itself. This is a VM-only trick and must never be done to
the host.

Two client shapes are granted, because Apple changed how the ssh session identifies
itself across releases: the bundle id `com.apple.sshd-session` and the executable path
`/usr/libexec/sshd-keygen-wrapper`. Guessing wrong costs a black frame with no error, so
both are granted. Columns are named, never positional — the `access` table has gained
columns in several macOS releases.

TCC caches decisions per process, so `setup.sh` **reboots the guest** after writing them.

### A black frame is a failure, not a picture

A missing grant, a slept display and an engaged screensaver all produce a perfectly valid
PNG full of black pixels. `shot.sh` measures every capture and refuses to return one that
is less than 2% non-black, because handing one back is how a harness reports a green run
of something it never saw. Provisioning separately disables display sleep, screensaver
and screen lock so that one of those three causes simply cannot happen.

### Quitting is by pid, never by keystroke

`stop.sh` sends `kill -TERM` to the pid `run.sh` launched. System Events addresses
whatever is **frontmost**, and on 2026-09-19 at 18:10Z a Command-Q sent that way landed
in the CEO's Terminal. `ax.sh --key` carries the same discipline: it resolves the app's
pid, verifies that pid is frontmost, and refuses to send otherwise.

### No third-party default is trusted

| Setting | Value | Why not the default |
|---|---|---|
| Tart version | **2.33.1** | `latest` (2.37.0) aborts in dyld on macOS 15.6 |
| Install method | release tarball | `brew install cirruslabs/cli/tart` fails — the tap's formula uses a `depends_on` form current Homebrew refuses |
| Guest image | `macos-sequoia-base`, digest recorded in `IMAGE_DIGEST` | matches the host's major version; `base` has Homebrew **and SIP off**, which the TCC grants require. ghcr publishes only a `latest` tag, so the digest is the only pin with meaning |
| Display | **1680x1050** | Tart's default is 1024x768; the app derives a 1400x880 window and would be clipped — every screenshot would be a lie |
| Per VM | **4 cpu / 7168 MB** | two guests must fit beside the host: 2x7 GB of 24 GB leaves 10 GB. Below ~6 GB a macOS guest swaps and boots slowly |
| `TART_HOME` | inside `~/.richos-testvm` | tart defaults to `~/.tart`; one directory means one answer to "where is the disk" and one `rm` to remove it |
| Key install | `/usr/bin/expect` | `sshpass` is not in Homebrew core and needs a third-party tap |
| ssh known hosts | `/dev/null` | a clone's host key changes every run; the CEO's `known_hosts` is not polluted |
| `screencapture` | `-x` | the default plays a shutter sound, and guest audio is mixed into the host's output — it would make a noise in his room |
| ssh | `BatchMode=yes` | without it, failed key auth falls back to a password prompt: a hang, or an askpass **window** on his screen |
| `caffeinate` | `-is`, never `-dimsu` | `-d`/`-u` would keep his display lit and unlocked for the length of every test |
| Guest staging dir | `$HOME`, not `/tmp` | Homebrew's tesseract cannot read the guest's `/tmp` |

---

## Pointing the nightly's on-screen gate at a VM

The nightly build's gates phase runs `gui-boot.test.sh` **on screen** for ~162 s, so a
build cannot currently run on this Mac without touching the CEO's screen. The guest is a
general-purpose app host, not a screenshot tool: the app is launched with the same
environment the host recipe uses, so a host-side test script can be copied in and run
over the same ssh channel.

```sh
./run.sh --bundle <zip> --home <fixture> --vm richos-test-1
IP=$(cat ~/.richos-testvm/run/richos-test-1/ip)
scp -i ~/.richos-testvm/id_testvm gui-boot.test.sh admin@$IP:/tmp/
ssh -i ~/.richos-testvm/id_testvm admin@$IP 'bash /tmp/gui-boot.test.sh'
./stop.sh richos-test-1
```

---

## When it breaks

| Symptom | Cause and fix |
|---|---|
| `shot.sh` says **BLACK FRAME** | The TCC grant did not take. `./setup.sh --reprovision` (it reboots the guest so `tccd` reloads). |
| `osascript`: *not allowed assistive access* | The Accessibility grant did not take. Same fix. |
| `run.sh`: app started but **0 windows** | Read the app log: `ssh admin@<ip> cat ~/testvm/<vm>/app.log`. Usually the bundle kept its quarantine flag and a Gatekeeper dialog is waiting in the guest with nobody to click it. |
| `tesseract`: *image file not found*, naming a file that exists | It is reading from `/tmp`. Stage under `$HOME` — see the note in `shot.sh`. |
| `reap.sh`: *VICTIMS[@]: unbound variable* | A regression of the bash 3.2 empty-array bug; use `${arr[@]+"${arr[@]}"}`. |
| VM never reports an IP | `cat ~/.richos-testvm/log/<vm>.log`. |
| *"tart cannot be opened because of a problem"* | The pin was bypassed. Run `preflight-binary.py` against the binary and read what it names. |
| Disk filling up | `./reap.sh` — clones that outlived their agent. |
