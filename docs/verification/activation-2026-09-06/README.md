# A test boot no longer takes the CEO's screen — measured, 2026-09-06

**His words:** *"It opens in the foreground on the main monitor AND takes away focus from
the current app. So, if I'm typing something here, it takes away focus from here and
focuses on that app."* Several times in a row, because a harness proving an assignment
survives a restart boots, kills and reboots the binary. `app/scripts/gui-boot.test.sh` alone
launches it **seven times per run**.

**And the requirement is his second sentence:** *"GENERAL issue if and when the same or
similar tests are run by others in the future."* The rule is therefore inverted from
"detect a test": RichOS activates only when it can positively establish an installed launch.
The argument lives at `app/src-tauri/src/activation.rs`; the reader-facing version is in
`app/README.md` under *Booting the app in a test*.

Every number below was produced on this machine by the two scripts committed beside this
file, and both are re-runnable.

## The probe was made to fail on purpose before any green from it was believed

**A "it did not take focus" verdict passes trivially over an app that never launched, died
in `setup`, or came up with no webview.** The first version of `focus-probe.sh` computed its
verdict from the frontmost samples alone and would have reported `focus never left Terminal`
over a binary that did not exist — the exact failure class this repository has spent two days
removing from other checks, reproduced by the person removing it.

PASS now requires four facts, each measured and each printed: **L** the process was alive at
the end of sampling, **C** the log carries `[richos] boot complete`, **W** the log carries a
line only the webview can cause, **F** no sample named the app frontmost. Missing L, C or W
is `INCONCLUSIVE` and exit 2 — never a pass.

`probe-selftest.sh` boots four stubs that fail in four distinct ways. Every one of them
satisfies the naive check (`F=yes` in all four), which is the demonstration:

| stub | L | C | W | F | verdict | exit |
|---|---|---|---|---|---|---|
| N1 the binary does not exist | no | no | no | yes | INCONCLUSIVE | 2 |
| N2 prints a perfect boot log, then dies | no | yes | yes | yes | INCONCLUSIVE | 2 |
| N3 stays alive, never finishes booting | yes | no | no | yes | INCONCLUSIVE | 2 |
| N4 boots to completion, no webview ever answers | yes | yes | no | yes | INCONCLUSIVE | 2 |

And the **F** detector is alive on this build, proven against the build itself rather than
against an old one — `RICHOS_ACTIVATION=regular` forces the front:

| run | frontmost while it ran | verdict | exit |
|---|---|---|---|
| 07 default | `ChatGPT` 32 of 32 | PASS | 0 |
| 08 `RICHOS_ACTIVATION=regular` | `richos-tauri` 31 of 32 | IT TOOK FOCUS | 1 |

Rows 01-06 below were taken with the earlier, samples-only verdict; rows 07 and 08 re-take
the load-bearing pair under the hardened one, and agree.

## Method

`lsappinfo front` sampled every 250 ms for the life of the boot, resolved to a display name.
It needs no accessibility grant, so nothing here depends on a permission the next reader may
not have. `lsappinfo list` gives LaunchServices' own `type=` for the process, which is where
the Dock icon comes from: `Foreground` for a normal app, `UIElement` for
`NSApplicationActivationPolicyAccessory`.

* `focus-probe.sh` boots the binary the way a harness does — as a child process the script
  holds, `cd /`, `env -i HOME=<scratch> USER PATH=/usr/bin:/bin:/usr/sbin:/sbin`, which is
  the launchd condition measured in `../loro-write-path-2026-09-01/`.
* `real-launch-proof.sh` does **not** simulate his launch, it performs one: it assembles a
  bundle from the installed `Info.plist` plus this branch's binary, ad-hoc signs it, and
  hands it to `open`, which is LaunchServices — the same path a Finder double-click takes.

## Results

| # | what was booted | frontmost while it ran | LaunchServices `type=` | verdict |
|---|---|---|---|---|
| 01 | **before this change**, as a child process | `richos-tauri` 22 of 24 samples | `Foreground`, `(in front)` | took the keyboard |
| 02 | `ActivationPolicy::Accessory` + window `.focused(false)`, still visible | `richos-tauri` 22 of 24 samples | — | **the obvious fix does not work** |
| 03 | Accessory + window built **invisible** | `Terminal` 32 of 32 samples | `UIElement` | focus never moved |
| 04 | **ablation**: invisible window, policy *not* set | `Terminal` 32 of 32 samples | `Foreground` | a Dock icon appears |
| 05 | **a real launch**, this branch's binary, scratch `HOME` | `RichOS` 30 of 32 samples | `Foreground`, `(in front)` | unchanged, as it must be |
| 06 | **a real launch**, this branch's binary, his real `HOME` | `RichOS` 30 of 32 samples | `Foreground`, `(in front)` | unchanged, as it must be |

**Why row 02 matters more than row 03.** `ActivationPolicy::Accessory` plus a window built
unfocused is what a reasonable engineer writes first, and it leaves the defect exactly where
it was. tao takes the screen twice at `applicationDidFinishLaunching`
(`tao-0.35.3/src/platform_impl/macos/app_state.rs:284-299`) and neither call consults the
activation policy or the window's requested focus: `window_activation_hack`
(`app_state.rs:432-453`) sends `makeKeyAndOrderFront:` to every **visible** window, and
`ns_app.activateIgnoringOtherApps(ignore)` runs unconditionally with `ignore` defaulted true
(`app_delegate.rs:107`), reachable only through tao's `EventLoopExtMacOS`
(`platform/macos.rs:336`), which Tauri does not expose.

**Rows 03 and 04 are an ablation, not two adopted beliefs.** The invisible window is what
keeps his keyboard; the activation policy is what keeps the Dock clean. Row 04 removes the
policy and the Dock icon comes back with focus still safe, so neither line is decoration.

**Condition P was measured, not assumed.** `ps -o ppid= -p <pid>` on the LaunchServices
launch of row 05 returned **1**, and `ps -axo pid,ppid,comm` reports ppid 1 for Finder (418)
and Terminal (1586). A harness cannot have ppid 1, because it has to hold the process it
boots in order to wait on it, read it and kill it.

## The window is still real — measured, not asserted

`accessory-child-boot.log` — the capture behind row 03 — ends with

```
[richos] voice: not offered on this machine — My ears aren't installed on this machine yet …
```

which `voice_readiness` prints (`app/src-tauri/src/main.rs`), a `#[tauri::command]` the
**page** invokes before rendering its greeting. Its presence in an accessory boot means the
WKWebView was created, the frontend loaded, JavaScript ran and an IPC round trip completed
into Rust — with an invisible, unfocused window under an Accessory policy.
`raw/03-accessory-policy-invisible-window-lsappinfo.txt` independently shows the three WebKit
XPC services ("richos-tauri Web Content", "Graphics and Media", "Networking") running beside
it.

**That witness is absent from row 06 and it is absent for the right reason:** voice IS
installed on his machine, so `speech_preflight` returns `Ok` and the line is never printed.
Row 06 proves the activation decision under his real home; row 03 is what proves the webview.
Neither is asked to prove the other.

## His own launch, twice

Rows 05 and 06 both report `[richos] activation: regular — an installed launch by the person
who installed it, so RichOS comes to the front and takes the keyboard`, frontmost `RichOS`,
`type="Foreground"`, `(in front)`. Row 06 ran against his real
`~/Library/Application Support/com.richos.app`; the directory was copied first, the only file
the run changed was `launches.json` (its `started_at` and `token`), and it was restored
byte-for-byte afterwards — `diff -r` clean.

## The check that holds this in place

`app/scripts/gui-boot.test.sh` accounts for every `[richos]` line a boot prints and treats
the `activation:` line as a **proof** whose absence fails, not as routine noise. Negative
control run: with the `eprintln!` replaced by `let _ = activation.log_message();` — so the
decision still ran and only the line disappeared — the suite reported

```
NOT RESOLVED  activation — nothing in this boot proved it was found.
FAIL  B2 every line of a healthy Finder-condition boot is accounted for
=== gui-boot.test.sh: 1 FAILED, 19 passed ===
```

That is B2 failing on the missing proof, not a build error and not a different case. Line
restored: `all 20 passed`, seven boots, none of them reaching his keyboard.

## Not covered, by name

* **Only macOS.** The activation policy is macOS-only and condition B is written in macOS
  bundle layout. A Windows or Linux port must decide its own equivalent; it will not inherit
  this one, and `activation.rs` says so at its own line.
* **A harness that sets `RICHOS_ACTIVATION=regular`.** It asked for the front and it gets it.
* **A second window opened later by the running app.** This decides the launch, once.
* **The published `v1.0.2` bundle at `~/Applications/RichOS.app` was never modified** and is
  not what any row above measured. Rows 05 and 06 built their own bundle in `/private/tmp`
  around this branch's binary; the installed app's `Info.plist` was copied, never edited.
* **The updater's relaunch was NOT exercised end to end.** `update_relaunch` now sets
  `RICHOS_ACTIVATION=regular` before `app.restart()`, because restart spawns a replacement
  and exits, so condition P would race the old process dying. The marker reaching the child
  is `std::process::Command`'s ordinary environment inheritance rather than a measurement —
  proving it needs a real staged update, which this run did not have. The override itself
  IS measured, in both directions and on a real boot: row 08 above, and the unit tests
  `the_override_answers_in_both_directions` and
  `an_unrecognized_override_value_decides_nothing`.
* **The 47 leftover `richos-owned-desktop-*` evidence directories (7.4 MB) were not
  cleaned up, and the one-line fix is not in this branch's territory.** They are created by
  a `tempfile.mkdtemp(prefix="richos-owned-desktop-")` in the owned-work desktop harness,
  a script that exists only on the unmerged `codex/durable-orchestration` branch and is the
  contractor's file — not in this tree at all. The fix belongs where the directory is made:
  remove it on the SUCCESS
  path only, since that script's own failure message tells its reader to inspect the
  directory. The existing 47 were left in place because they may still be evidence for a
  review in flight.
* **The contractor's harness phases cannot be broken by the invisible window**, and that is
  checked rather than assumed: `owned_work.rs::selftest` on that branch runs entirely
  Rust-side, calling the Tauri commands through `app.state()`, and never drives the page or
  reads window geometry. The webview loads either way, which row 03 measures.
