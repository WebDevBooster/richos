# An app that cannot start now says why, on the screen the person launched it from

**2026-09-10 · Echo · branch `echo-opus-st1` · from richos `a8fe95f3`**

`tom-opus-ui1` found, while auditing the affordance suite, that `app/src-tauri/src/main.rs`
could exit before Tauri existed and tell the user nothing at all:

```rust
let _update_session = match update_startup::prepare(&compiled_version) {
    Ok(session) => session,
    Err(error) => {
        eprintln!("[richos] application startup: {error}");
        return;
    }
};
```

Launched from Finder or the Dock, stderr goes nowhere anybody will look. The whole of the
user's experience was an icon that bounced once and stopped. He classified the nine failure
strings reachable from that path NOT-RENDERED, which was right: no surface existed that
could render them.

---

## 1. The class, enumerated — twelve sites, three shapes

Counted by reading `main()` and its `setup` closure end to end, not by grepping for the one
that was reported. The command:

```
$ awk 'NR>=888 && NR<=1940 { if ($0 ~ /expect\(/ || $0 ~ /unwrap\(\)/ || $0 ~ /process::exit/ \
      || $0 ~ /panic!/ || $0 ~ /return;/ || $0 ~ /\?;$/ || $0 ~ /\?$/) print NR": "$0 }' \
      app/src-tauri/src/main.rs
894:         return;
902:             return;
912:             std::process::exit(1);
914:         return;
1020:                 .expect("open launch record");
1035:                 let window = tauri::WebviewWindowBuilder::from_config(app.handle(), window_config)?
1066:                     .build()?;
1101:             let ledger = Ledger::open(&ledger_path).expect("open ledger");
1138:             let config = ConfigStore::open(&config_path).expect("open config store");
1256:                     let binding = spine.ensure_active_thread_in(entity).expect("ensure thread");
1938:         .expect("error while building RichOS")
```

(Line numbers are the PRE-CHANGE file. `894` is the identity probe's success return and is
not a failure.)

| Shape | Sites | What happens today |
|---|---|---|
| **1 — explicit early exit, before Tauri exists** | `main.rs:902` (`prepare`, the reported one), `main.rs:912` (`--onboarding-mcp`) | `eprintln!` then `return`/`exit(1)` |
| **2 — a panic inside `setup`** | `main.rs:1020`, `1101`, `1138`, `1256` | unwind, exit 101, macOS shows nothing |
| **3 — `?` out of `setup`, or the builder** | `main.rs:1035`, `1066`, `1938` | the `?` becomes the panic at `1938` |

Plus the seven `.lock().expect("… lock")` poisoned-mutex sites in `updates.rs`
(246, 327, 435, 450, 499, 667, 721), which are shape 2 by another name.

`updates.rs:858`'s `std::process::exit(code)` is deliberately **not** in the class: it is the
`RICHOS_UPDATE_SELFTEST` harness's own exit and its audience is `updater-e2e.sh`'s parser.

**Shapes 2 and 3 are one mechanism** — a Rust panic — so they are caught in one place. Only
shape 1 needed call sites. That is why the fix is a panic hook plus one function and not
twelve edits: the thirteenth site added next month is covered without anyone remembering.

### A second, quieter half of the same silence

The reported site did not only fail to speak to the person; it **reported success to any
script**. `return` from `main` is exit 0. Measured before the change, the same damaged bundle
run with a parent holding it:

```
exit=0 elapsed=0s
[richos] application startup: invalid bundle version
```

It is `std::process::exit(1)` now. Nothing reads that code today —
`gui-boot.test.sh` kills the process it boots, `make-release.sh:426` greps the executable
rather than running it, `rebuild-survival.sh` never runs it — so 1 costs nothing and stops
the next harness being lied to.

---

## 2. What was chosen, and what was rejected

**Chosen: `CFUserNotificationDisplayAlert`** (CoreFoundation) — in-process, no new crate, no
subprocess, no `NSApplication` and no run loop. It is the API macOS provides for a process
that must speak to the person before it is a GUI application.

It was measured before a line of the fix was written. `cf-alert-probe.c` in this folder,
compiled with `clang -framework CoreFoundation`, put a real system alert on screen and
returned `rc=0 resp=3` (`kCFUserNotificationCancelResponse`, which is what the timeout
returns), with `UserNotificationCenter` running alongside it.

Rejected, each with a reason:

* **A Tauri error window.** It would need the runtime whose prerequisite just failed. It is
  also specifically wrong here: two of `prepare`'s errors mean the bundle under this loaded
  image may already have been exchanged, and running the webview stack against resources the
  code has just refused to trust is what `update_startup.rs:90-92` exists to prevent.
* **`osascript -e 'display alert …'`.** Forks into the AppleScript stack at the one moment
  this process's environment is known to be broken, and requires interpolating an arbitrary
  error string into an AppleScript literal. CoreFoundation takes the message as data.
* **`NSAlert` through objc.** Needs `NSApplication.shared` and a run loop — exactly what has
  not happened yet.
* **`rfd` / `tauri-plugin-dialog`.** A new dependency in the one path whose job is to work
  when things are broken; `rfd`'s macOS backend is `NSAlert` anyway.
* **A notification.** Needs authorization the app may never have, is dropped in a Focus mode,
  and is dismissible into a history the person does not know to open.

**Windows is a DECLARED GAP, not a finished port.** The equivalent is `MessageBoxW` from
`user32` with `MB_ICONERROR | MB_SETFOREGROUND`, which has the same before-any-window
property. It is not written, because it cannot be compiled here —
`rustup target list --installed` reports `aarch64-apple-darwin` and nothing else — and
untested FFI in the failure path is worth less than an honest gap. `prepare` is `Ok(None)`
off macOS today. It belongs with architecture §4.4 gap 5 and §3.3.

---

## 3. When the alert is armed — no new rule

A modal on every failing boot would hang `gui-boot.test.sh` and every harness written after
it. The alert is armed by **exactly** `activation::decide(…) == Presentation::Regular` — the
project's existing three facts: B (this build's own bundle), D (the installed data directory),
P (parent pid 1, because macOS hands a launch to launchd and a harness must hold what it
boots). A harness cannot be an installed launch by construction, so nobody has to add it to a
list — the inverse-rule argument `activation.rs` already makes.

Armed twice (before Tauri, where D is approximated; again in `setup` from the authoritative
decision) and **disarmed at `boot complete`**, because past that line the app owns a window
and its own surfaces are the right place for a failure.

---

## 4. The proof — a real failure, launched the way the CEO launches it

`force-a-startup-failure.sh` in this folder is the whole reproduction. It damages the one
field `richos_user_update::bundle_version` reads (`lib.rs:602-606`) — what a truncated
Info.plist looks like in the wild — so `prepare` fails at `update_startup.rs:65`, before any
lease is acquired, touching no real update state.

```
$ bash force-a-startup-failure.sh app/src-tauri/target/release/richos-tauri
…/RichOS-startup-failure-proof.app/Contents/Info.plist: OK
damaged: CFBundleShortVersionString = corrupt-not-a-semver

--- the person's path: LaunchServices, parent pid 1, no stderr anywhere ---
50793     1 /private/tmp/…/RichOS-startup-failure-proof.app/Contents/MacOS/richos-tauri

--- the same failure with a parent holding it: no modal, and it must not hang ---
[richos] application startup: invalid bundle version
exit=1 elapsed=0s

--- what an engineer can read afterwards ---
==== 2026-09-10T09:00:04Z RichOS 1.0.3 pid 50793 ====
executable: /private/tmp/…/RichOS-startup-failure-proof.app/Contents/MacOS/richos-tauri
failure: application startup: invalid bundle version

==== 2026-09-10T09:00:08Z RichOS 1.0.3 pid 51735 ====
executable: /tmp/…/RichOS-startup-failure-proof.app/Contents/MacOS/richos-tauri
failure: application startup: invalid bundle version
```

`ppid 1` is the point: this is LaunchServices, the same path a double-click takes, and the
process is alive because it is **blocked on the alert**. Full output in
`raw/force-a-startup-failure.out`; the log in `raw/startup.log`.

**What the person sees** — `alert-from-finder-launch.png`, cropped to the dialog:

> **RichOS could not open**
>
> RichOS stopped before it could open a window. It was working out which copy of itself to
> run, and that step did not finish — so it closed itself rather than start in a state it
> could not vouch for.
>
> Opening RichOS again is worth one try.
>
> The full details were written here:
> /Users/alex/Library/Logs/RichOS/startup.log
>
> `[ Show Details ]  [ OK ]`

**Both halves matter.** The second run in the transcript above is the negative case: with a
parent holding the process, there is no modal, the same `[richos]` line goes to stderr, it
exits in 0 seconds, and the log still gets the entry. That is what every harness needs, and
it falls out of the arming rule rather than out of a list of harnesses.

### The diagnostic is not traded for the friendly sentence

Three places, none dropped: `~/Library/Logs/RichOS/startup.log` (timestamped, with version,
pid and the executable path — and `~/Library/Logs` is where Console.app looks); stderr,
unchanged and still `[richos] `-prefixed for `gui-boot.test.sh`'s S1 accounting; and the alert,
which names the log's path in its own text. A panic keeps the previous hook, so the payload,
the location and any `RUST_BACKTRACE` output still reach stderr exactly as before.

### Not exercised, and not to be exercised here

The **Show Details** button's action (`/usr/bin/open -R <log>`) was not driven by a click —
sending a click needs Accessibility permission this environment does not hold. The button is
present and labeled in the screenshot; the reveal itself is four lines behind
`rc == 0 && response == kCFUserNotificationAlternateResponse`. Named here rather than left to
be discovered.

### The launches this proof cost, and why there will be no more of them

**Recorded because it is a real cost that was paid on the CEO's live desk, not a footnote.**
This is a modal system alert, so proving it means putting one on the screen of the machine
that is running the proof — and that machine is his. Three launches were made (pids 49840,
3873, 50793, each killed at the end of its capture); he saw one of them at 09:52 local and
asked what it was.

The reproduction script is committed so the proof is repeatable, and it should be run on a
machine nobody is working at, or at a time arranged with him. `startup.log` in `raw/` carries
the two entries from the final run at `09:00:04Z` and `09:00:08Z`; the screenshot is the
one from that same run. **Nothing further needs a live launch** except the Show Details
branch above, which is declared unexercised rather than quietly claimed.

---

## 5. Contrast — measured, and one platform-owned value declared

Computed off the screenshot's own pixels (`contrast.py`, in this folder), not eyeballed:

```
headline               paper=rgb(232, 232, 231) ink=rgb(53, 53, 52) ratio=10.02:1
body text              paper=rgb(232, 232, 231) ink=rgb(53, 53, 52) ratio=10.02:1
log path               paper=rgb(232, 232, 231) ink=rgb(63, 63, 62) ratio=8.60:1
Show Details button    paper=rgb(206, 206, 205) ink=rgb(61, 61, 61) ratio=6.90:1
OK button (default)    paper=rgb(3, 124, 255) ink=rgb(255, 255, 255) ratio=3.94:1
```

Everything a person reads to understand what happened clears AA with room to spare — the
sentence, the headline and the log path are all above 8.6:1.

**DECLARED, not glossed: the default button measures 3.94:1, below the 4.5:1 normal-text
floor.** It is white on the macOS accent color and it is drawn entirely by the system; this
code supplies the string `"OK"` and nothing else. Every native alternative — `NSAlert`,
`rfd`, `osascript` — renders the identical control with the identical color, so the value is a
property of native macOS alerts and not of this choice. It clears the 3:1 non-text-indicator
threshold. The mitigation that is actually available was taken: **no information lives in the
buttons.** The message carries the reason, the advice and the log's path at 8.6:1 or better,
and a person who cannot read the word "OK" still has a dismissible alert with a default action.

**Also declared: only the light appearance was measured.** `defaults read -g
AppleInterfaceStyle` reports the key absent, so this machine is in Light. Measuring the dark
rendering means changing the operator's live system appearance while other work is running,
which was judged not mine to do. The dark rendering uses the same system semantic label
colors on the same system alert material.

---

## 6. `gui-boot.test.sh` is RED on main, and it was red before this change

Measured both ways. `791cc73d` is this branch's first commit (a one-line `Cargo.lock` fix),
whose parent is main at `a8fe95f3`; the tree was extracted with `git archive` and run
untouched:

```
$ bash app/scripts/gui-boot.test.sh                        # with this change
=== gui-boot.test.sh: 3 FAILED, 18 passed ===
$ bash app/scripts/gui-boot.test.sh                        # baseline, git archive 791cc73d
=== gui-boot.test.sh: 3 FAILED, 18 passed ===
```

The two logs are **byte-identical apart from the `mktemp` directory names**
(`raw/gui-boot-with-the-change.log`, `raw/gui-boot-baseline-791cc73d.log`). The same three
cases fail — B1, B2, B6a — with the same seven unaccounted lines.

The cause, and it is worth naming: every boot dies with

```
UNACCOUNTED  [richos] application startup: No such file or directory (os error 2)
```

`app/scripts/lib/gui-launch.sh:194-195` builds the harness bundle as
`<machine>/Applications/RichOS.app/Contents/MacOS/richos-tauri` and **writes no
`Info.plist`**. `update_startup::prepare` now requires one — `richos_user_update::bundle_version`
at `update_startup.rs:65`, added by `01e9b8d8` — so the boot dies at `main.rs:898` and never
reaches `setup`. B1/B2 are the POSITIVE half of that check ("the healthy machine boots to
completion"), so the half that proves the boot works is currently dead.

CI does not see it: `gui-boot.test.sh` is a declared host gap on the public runner
(`.github/workflows/packaging-ci.yml:166-167`, the loro compiler is not tracked), so it exits
2 there and is allowed. **This is left as found.** It is a real defect in someone else's
change, the fixture repair turns on real update-lease code inside the harness, and three other
agents were working across these repositories. It is escalated rather than quietly patched.

---

## 7. The suites

```
$ cargo test -p richos-core                       # app/
   43 result lines: 985 passed, 0 failed, 4 ignored  (largest single line: 537 passed)

$ cargo test                                      # app/src-tauri/
   test result: ok. 77 passed; 0 failed; 0 ignored     (9 of them new, in startup_alert.rs)

$ RUN_TESTS_DECLARED_GAPS="" bash app/scripts/run-tests.sh
   9 suite(s) discovered
   frontend-payload      all 10 passed
   gui-boot              3 FAILED, 18 passed   <- red before this change too, see §6
   make-engine-asset     all 18 passed
   make-release          all 11 passed
   package-app           all 25 passed
   rebuild-survival      all 17 passed
   run-tests             all  7 passed
   signing-setup         all 28 passed
   updater-setup         all 33 passed
   === app/scripts: 1 of 9 suite(s) FAILED: gui-boot.test.sh ===
```

Full output: `raw/app-scripts-run-tests.log`.

`gui-boot.test.sh`'s S1 case — every `eprintln!` in `src-tauri` outside its tests carries the
`[richos] ` prefix — passes, which it had to: the new module prints through that prefix so the
boot-log accounting can still see it.
