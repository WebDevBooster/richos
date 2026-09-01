# A fresh user gets a Rich he can correct, in the session that created his memory

Until 2026-09-01, `AppState::correction` was a plain `Option` fixed in `setup`.
`provision_memory` re-wired the READ half into the running spine and could not re-wire the
desk, so the sequence a genuinely fresh customer follows was:

1. RichOS opens with no memory and offers to set it up.
2. He clicks yes. A corpus appears, and Rich can read it.
3. **He cannot correct anything until he quits and reopens.**

That was printed rather than hidden — *"corrections become available on the next launch"* —
which was the right call for a limit nobody had time to fix on the day it was found. It is
not a limit. It is a `Mutex`.

It never showed on the CEO's own install, whose corpus predates the app. It showed in every
customer's first five minutes, while the window told him *"From now on I'll keep what you
tell me in that folder and read it back when it matters."*

## The evidence

`raw/02-first-run-provision-then-correct.log` — the whole sequence in one process, under
launchd's environment (`cd /`, `env -i HOME=<scratch> USER PATH=/usr/bin:/bin:/usr/sbin:/sbin`)
on a machine that has no memory when the process starts:

```
--- boot, on a machine with no memory ---
BOOT   : no corpus. Looked in:
         <scratch>/Library/Application Support/RichOS/corpus — not present
         <scratch>/Library/Application Support/RichOS/loro-root — not present
         <scratch>/RichOS/corpus — not present
DESK   : CLOSED (nothing to write with)

--- he clicks "set it up" ---
OFFER  : <scratch>/RichOS/corpus
CORPUS : <scratch>/RichOS/corpus
READ   : <scratch>/Library/Application Support/RichOS/corpus via the corpus pointer in Application Support
DESK   : OPEN — installed by provisioning, NO RELAUNCH

--- the same session: he corrects something ---
PROPOSE: state=AwaitingCeo
BEFORE : exists=false at …/ceo/records/first-run-correction-same-session.md
CONFIRM: state=Written ref=rec:ceo/records/first-run-correction-same-session
AFTER  : exists=true at …/ceo/records/first-run-correction-same-session.md
```

**The written record, quoted from disk:**

```
---
id: first-run-correction-same-session
kind: decision
scope: ceo-private
title: A correction written in the session that created the corpus
confidence: 0.9
observedAt: "2026-09-01T17:18:14.020Z"
supersededBy: null
provenance: { method: explicit_ceo_instruction, source: conversation, ref: null }
---

Written by the app's own write path, on a machine that had no memory when this process
started, without a relaunch. Before 2026-09-01 the desk was fixed at boot and this write was
impossible until the CEO quit and reopened.
```

`SHOW` then resolves the same `ref` to the same file: the reader and the writer name one
corpus, which is the property the one-`LoroInstall` design exists to make structural.

## The change

| file | what moved |
|---|---|
| `main.rs` `AppState::correction` | `Option<SharedCorrectionDesk>` → `Mutex<Option<…>>` |
| `main.rs` `AppState::data_dir` | carried from `setup`, so the desk's log path has ONE expression |
| `main.rs` `install_correction_desk` | new; the ONLY place a desk is opened and wired, called by `setup` AND `provision_memory` |
| `main.rs` `desk()` | returns the `Arc` and the caller locks, so the outer lock is never held across a `loro-write` child process |
| `main.rs` `provision_memory` | takes an `AppHandle`, installs the desk, and says `OPEN … no relaunch` where it used to apologize |
| `ui/main.js` `provisionMemory` | `await refreshDesk()` — `loro_available` was answered at boot and has just changed |
| `ui/mock.js` `provision_memory` | opens the mock desk too, so the surface is rehearsed against the behavior the backend now has |

`install_correction_desk` is a function and not four lines inlined twice, for the reason
`wire_company_memory` is one: two copies of "open it, hand it to the spine, attach the
observer" would drift, and the copy that drifted would be the one a new customer hits first.

## What was NOT touched

`raw/01-ceo-state-before.txt`, `raw/03-ceo-state-after.txt`, `raw/04-ceo-state-diff.log`:
the six files under `~/Library/Application Support/com.richos.app` are **byte-identical by
sha256** either side, `~/Library/Application Support/RichOS/loro-root` still points at
`/Users/alex/ab/richos-hq`, and `~/ab/richos-hq` is clean.

Every path the run creates hangs off the scratch `$HOME` it is given. `provision` refuses a
target that is already a corpus, a target that is not empty, and any target inside a product
checkout, so there is no argument to this program that could reach his 626 records.

## What this does not cover

The IPC hop and the button — `ui/` → `invoke("loro_confirm_correction")` →
`desk(&state)?.lock().unwrap().confirm(…)`. The `#[tauri::command]`s take a
`State<AppState>` that only a running Tauri app can supply, and GUI automation is
unavailable on this machine: System Events reports zero windows for every visible process
(`docs/verification/loro-write-path-2026-09-01/raw/13-…`). Everything from
`install_correction_desk` down is exercised for real; the uncovered strip is the same one
`loro_gui_correction_e2e` names, and it is named here rather than implied away.
