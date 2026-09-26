# Work given from the phone starts like typed work — on-app proof, 2026-09-26

**CEO ruling §88:** *"The user should be able to answer on their phone just as well as they
can answer on the desktop app."* Acceptance for this branch: **a task he gives by voice, or
from the phone, starts immediately, exactly as a typed one does, on every install.**

Branch `cc/echo-opus-adopt1` (echo-opus-adopt1). Defect: esc-20260926T083231Z-23865924 (raised
by echo-opus-opshell1): on main `f6ea8d8d`, `WorkHost::adopt_registered` was called only from
`send_message`; a task registered in a spoken turn or a phone turn sat `Registered` until he
next typed in that conversation.

## What was measured, and where

Everything below ran in the test VM (CEO §65: never on his Mac's screen), through
`run-walk.py`, which holds `~/.richos-testvm/guest.lock`, and was quit and deleted by its
`stop.sh` (CEO §54). The bundle under test is an ad-hoc signed development build of this
branch, `1.2.0-dev.98c3aef5`; the app's own log line in the guest reads
`this app: built from 98c3aef5c1e76155e34a97018059fafc3314aa3f`. No app code changed after
98c3aef5 on this branch (`git diff --stat 98c3aef5..HEAD -- richos/app/src-tauri
richos/app/crates richos/app/ui richos/web richos/mobile` is empty at the time of the run).
Engine: nightly `.27`'s `richos-engine-1.2.0.tar.gz`, the pin compiled into the bundle.
Home: an EMPTY directory — a fresh install, first run included.

### Scripted run (the verification)

```
cd richos/app/scripts/testvm
TESTVM_AX_TIMEOUT=60 ./run-walk.py --wait 900 --bundle RichOS-dev-98c3aef5.zip \
  --home <empty dir> --engine <nightly .27>/richos-engine-1.2.0.tar.gz --report <out>/run.json -- \
  ./adopt-walk.py --out <out>/adopt --expect-sha 98c3aef5 --within 240
```

Output (the admission waited 187 s over 7 samples for the host's CPU to drop under 80%):

```
identity: PASS      first-run: PASS     watch: PASS
pair: PASS          phone-task: PASS    observe: PASS
[testvm] 12:49:36Z clean: app quit, VM stopped, clone deleted, state removed.
```

`scripted-run/observed.json`, on the guest's clock (ms):

| event | guest ms | from the phone's words |
|---|---|---|
| his words from the phone reach the ledger (`PromptReceived`, intake record `channel`, channel `phone`) | 1790426944898 | 0 |
| Rich registers the task inside the turn (`registered_at_ms`) | 1790426966157 | +21 259 |
| the phone turn completes (`TurnCompleted.at`) | 1790426970920 | +26 022 |
| the assignment leaves Registered: `preparing`, "Opening the work connection." | 1790426970931 | +26 033 |

**11 ms after the turn ended, with no typed message.** Every prompt on the conversation came
through the phone's intake channel (no `desk` record, no prompt without an intake id); the
walk's `analyze()` fails on either (test/adopt-walk.test.py).

### Hand-paired run, with a typed control (the same build)

The walk's steps were found by hand in a guest held by `hold-walk.py`; the scripted steps ran
against it with `--steps`. After the phone task, the SAME kind of task was then TYPED on the
Mac as the control. `hand-paired-run/adopt-watch.jsonl`:

| | phone task | typed control |
|---|---|---|
| prompt reaches the ledger | 1790426110247 (intake `channel`, `phone`) | 1790426188727 (intake `desk`) |
| registered in the turn | 1790426121693 | 1790426198166 |
| turn completed | 1790426123494 | 1790426200863 |
| `preparing` | 1790426123502 (**+8 ms** after the turn) | 1790426200871 (**+8 ms**) |
| `running`, "The back end has started on it." | 1790426127249 (+3.76 s) | 1790426201730 (+0.87 s) |
| then | `failed`, "No work was started, so nothing was landed." | the same |

The phone task now takes exactly the typed task's road through the work host. **Both then
ended the same way** — the back end ran and reported that no work was started (the phone
assignment's own record carries `repositories: []`; the typed one's was not read). That is the back end's outcome in this guest, the same
for both entrances, and it is not what this branch changes; it is named here rather than left
for someone to discover. Not diagnosed.

`observed-phone-part.json` is the same verdict run on the rows before the typed control
(PASS, +8 ms); on the whole file it fails, as it must: `a prompt on this conversation did not
come from the phone` (the typed control).

## Voice

**Not driven on the app, and why.** The guest has no speech toolchain (`[richos] voice: not
ready on this machine (toolchain-missing)`), and a spoken turn on this Mac may not be made
with `say` (CEO §53: the Mac's speakers are not a person). The spoken entrance is covered by
`turn_boundary_tests::work_he_gives_aloud_starts_without_a_typed_message` (a real Spine and
WorkHost; the tail of the voice callback is `run_the_spoken_turn`), by the entrance scan, and
by mutants M4 and M6.

## Found on the way, fixed on this branch: the phone sheet deadlocked on every install

The first guest (bundle `1.2.0-dev.590dda66`, before the fix) opened "Use Rich from your
phone" with a title and Close and nothing else, forever. `sample` of the app:
`phone-status-deadlock-sample-590dda66.txt` — `PhoneRuntime::status` parked in
`__psynch_mutexwait` while three more `status` calls waited in `sweep_expired_pairing`.
`status()` locked `rejected` twice in one struct literal (the first guard lives to the end of
the statement), holding `running` as it did. Introduced by `6415339e` (2026-09-24); nightly
`.27`'s source `f9b617bd` carries it. Fixed in `1598a5f2`, with two tests that fail first on
the unfixed code; on the fixed bundle the sheet drew and pairing completed in both runs above.
Raised as esc-20260926T121015Z-212dc350.

## Also recorded

- `mutants-e79659fe-private-target.log`: `scripts/turn-boundary-mutations.py`, 10 of 10
  mutants killed, each by its named test (M4 and M5 are the defect as it was on f6ea8d8d).
- esc-20260926T113721Z-70ef679e: the shared Cargo cache judges a workspace member fresh by
  mtime across checkouts; the harness's first version built mutants into it. It builds into a
  private target now.
- The guest's phone sheet names the Tailscale account it is signed in with; no screenshot of
  it is in this record.
