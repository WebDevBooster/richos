# `ENABLE_TOOL_SEARCH=false` never stopped working, and the 8–12 s on the window is somewhere else

**2026-09-18 · branch `cc/echo-opus-toolsearch1` · CEO ruling §55
(`richos-hq` `wiki/ceo-decisions.md`) · run **E** of
`crates/richos-core/examples/first_reply_timing_e2e.rs`, continuing
`docs/verification/first-words-obligation-2026-09-18.md` (runs C and D)**

*"Rich **immediately** replies with: "On it!" and only after that does all that work."* …
*"Yes, a few seconds is fine. But 35 seconds of waiting for the first response is not. Go."*

**The brief this record answers was wrong, and so was the audit it came from.** Both held that
the tool-residency knob had stopped working between `claude` 2.1.275 and 2.1.277, on the
strength of one line in candidate .10's `app.log`. It had not. The line was raised by the WORK
lease, which is given no such variable by design. Escalated as
**`esc-20260918T192742Z-93c267c3`** before any of the work below was built on it.

---

## 1. The claim, and what refutes it

The accused line, `app.log` line 48 of the candidate-.10 walk, emitted at `native.rs:1886`:

```
[richos] THIS SESSION DEFERS ITS TOOLS. `ToolSearch` is in the child's own init inventory, so
the register has to be DISCOVERED before it can be called and the CEO waits a round trip for
that (measured: 7.5 s of one 23 s turn). `ENABLE_TOOL_SEARCH=false` is set for this lease and is
no longer having that effect — check `claude --version` against the last release gate.
```

Three independent things say the front desk was not deferring on that run.

### 1.1 The decision module did not change between the two releases

Re-derived from the shipped binary the way the original comment was, not from documentation.
`/Users/alex/.local/share/claude/versions/2.1.277`, decision module at byte offset
**175_107_000** (173_562_000 in 2.1.275):

| 2.1.277 | 2.1.275 | what it is |
|---|---|---|
| `b7e()` | `EYe()` | the mode: `"standard"` / `"tst"` / `"tst-auto"` |
| `Kg()` | `Mg()` | the session's one "is tool search on" decision |
| `Ebt()` | `f_t()` | the first, short-circuiting `"standard"` arm |
| `u()` | `u()` | the managed/admin-tier force override |
| `drr()` | `UQn()` | the `auto:N` parser |
| `Oe()` / `Eo()` | `Oe()` / `To()` | truthy / falsey string |

```text
function b7e(){ if(Ebt())return"standard"; if(u())return"tst";
  let e=process.env.ENABLE_TOOL_SEARCH, r=e?drr(e):null;
  if(r===0)return"tst"; if(r===100)return"standard";
  if(m(e))return"tst-auto"; if(Oe(e))return"tst"; if(Eo(e))return"standard";
  return"tst" }                                   // <- UNSET MEANS DEFERRAL IS ON
function Eo(e){ … return["0","false","no","off"].includes(String(e).toLowerCase().trim()) }
function Kg(){ let e=b7e(); if(e==="standard"){ …; return!1 } … }
```

Same functions, same order, same bodies. `Oe`/`Eo` are **byte-identical** to 2.1.275's
`Oe`/`To` — still `["1","true","yes","on"]` and `["0","false","no","off"]`. Nothing in it reads
a different input, so **there is no new spelling to set and nothing here is version-dependent.**
The brief's instruction *"if the knob is version-dependent, make the lease set every spelling"*
has no work to do, and adding a second spelling would have been scope invented to match a
premise that was false.

### 1.2 The wire, on the same binary that run used

A source reading is not a measurement. `/Users/alex/.local/bin/claude` → **2.1.277** — and
candidate .10 names that exact path in its own `app.log` line 23, *"compute connection: starts
with the first cancellable request over /Users/alex/.local/bin/claude"*. Driven directly with
the arg vector `native::child_args` builds, reading `system/init.tools`:

| environment / flags | tools | `ToolSearch` |
|---|---|---|
| `ENABLE_TOOL_SEARCH` unset | 28 | **PRESENT** |
| `ENABLE_TOOL_SEARCH=false` | 35 | absent |
| `ENABLE_TOOL_SEARCH=0` | 35 | absent |
| `=false` + `--permission-mode auto` | 35 | absent |
| `=false` + the inline `--settings` `EngineProfile::configure` sends | 35 | absent |
| `=false` + `--strict-mcp-config --mcp-config` | 27 | absent |

**The unset row is the positive control** — deferral is visibly live there, and the eight MCP
tools are missing from the inventory as well, which is what deferral looks like. The knob holds
on 2.1.277 in every shape the app spawns.

### 1.3 The log's own order

In candidate .10's `app.log` the warning sits **after** *"the register's receipt had already
been said"* and immediately **before** that turn's work-lease settlement line. The alarm fires
once, at the transition to `Yes`, on a lease's init frame — so if the conversation lease had
been deferring, its line would have come before the register call, not after it. The front desk
had already called the register on that turn, which is the one thing the alarm claims is
impossible.

---

## 2. The actual defect: an alarm that could not say which lease it was about

`ReaderState` carried no lease role. One message served both leases, and it asserted
*"`ENABLE_TOOL_SEARCH=false` is set for this lease"* on a lease where `tool_residency_env`
deliberately sets nothing at all (`native.rs`: `LeaseRole::Work => None`, and the comment above
it says why). The work lease's own init frame tripped it.

Fixed at **`ed36decd`**: `ReaderState::tool_residency` is set at spawn from
`tool_residency_env(role)` itself, and `tool_search_notice(residency)` is a pure function with
one message per case. The work lease's message **does not contain the variable's name**,
deliberately — whoever chases the alarm greps `app.log` for that name, and a line containing it
that means the opposite is how this happened in the first place.

RED-FIRST, mechanically: with the `None` branch temporarily routed back to the single pre-fix
message, `the_work_lease_deferring_its_tools_is_never_reported_as_a_broken_knob` fails at
`native.rs:4225` quoting the front desk's sentence; restored, it passes.
`the_reader_is_told_which_lease_it_is_on` pins the WIRING on a real `spawn_with_tools`, one per
role — a pure-function pin alone would have passed on candidate .10's code, where the field did
not exist.

**What the false alarm cost.** Ray's audit named a working binary as the cause of "On it!" at
8–12 s (rows 1 and 4 of
`docs/verification/2026-09-18-nightly-1.2.0-nightly.20260918.5-onscreen-audit.md`), the brief
that followed inherited it, and the real cause went unlooked-at for a walk. A false alarm that
is believed costs more than silence.

---

## 3. Run E — the same probe, on 2.1.277, today

One run, **three model turns** on the CEO's subscription (priming, task, question — the shape
this example has always had; `RICHOS_PROBE_DISPATCH_ONLY=1` is the part that costs nothing).

| | run A (before the slice) | run D | **run E, on 2.1.277** |
|---|---|---|---|
| a task turn, the lease's first VISIBLE turn | 7.998 s | 5.612 s | **5.995 s** |
| a question turn, warm | 6.358 s | 5.702 s | **6.205 s** |
| the priming turn, before he typed | 2.768 s | 2.686 s | **2.927 s** |
| the register's position among the turn's tool calls | fourth | **first** | **first** |
| `ToolSearch` on the conversation lease | live | absent | **absent — no alarm printed** |
| model turns the run spent | 3 | 3 | 3 |

```
front desk made ready before he types : 2.927 s  (Ready { millis: 2926, spawned: false })
the continuity grant across the priming turn : shut at its start = true, opened at = None

he said    : Land the pricing branch and get the staging deploy done.
Rich said  : "On it!"
send -> first words : 5.995 s      send -> turn ended : 7.190 s
      3.915 s  mcp__richos_assignments__record        <- the FIRST tool call
      3.920 s  {"assignment":"Land the pricing branch and get the staging deploy done.","kind":"tas…
      5.995 s  HIS FIRST WORDS
      6.008 s  tool_call closed: {"recorded":true,"say":"On it!","say_nothing_else":true}

he said    : Why has the nightly build been failing since Tuesday? …
Rich said  : "I'll investigate."
send -> first words : 6.205 s      send -> turn ended : 7.673 s
      3.343 s  mcp__richos_assignments__record        <- the FIRST tool call
      6.205 s  HIS FIRST WORDS

PASS: the register was the first tool call on every turn that handed work over, and nothing
was discovered or written down ahead of his first word.
```

**Run E is the third refutation.** The alarm did not print, and the register was the first tool
call on both turns, on the binary that was accused.

Run E is 0.38 s and 0.50 s slower than run D on turns that are otherwise identical. That is one
run against one run, both against a live service, and **it is not evidence of a regression** —
it is stated so the next run has something to compare against, not so anything is concluded
from it.

---

## 4. Where the window's 11–12 s and 8–9 s actually live

Ray's two measurements, read off the frames in
`docs/verification/2026-09-18-nightly-10-onscreen/` with the app's own `Working for N s` counter
as the turn clock. Frames are about a second apart, so every figure here carries ±1 s.

### Measurement 1 — a brand-new thread, Send clicked at 18:57:50Z

| frame | elapsed | on screen | what the counter says the turn clock is |
|---|---|---|---|
| `21-fd-02` | +1 s | *Sending your message / Waiting for Rich to accept it* · 1s | the turn has not started |
| `21-fd-08` | +5 s | Rich is working / Nothing has come back yet | ~0 s |
| `21-fd-12` | +8 s | Working for 3s | start ≈ +5 s |
| `21-fd-16` | +10 s | Working for 6s | start ≈ +4 s |
| `21-fd-18` | **+12 s** | **"On it!"** · Working for 7s | start ≈ +5 s |

So it decomposes as **≈5 s before the turn started + ≈7 s of turn**, and the ≈7 s matches run
E's 5.995 s within the cadence. **The five seconds are not the model.**

**They are a lock.** `ready_the_front_desk` (`src-tauri/src/main.rs`) takes `state.spine.lock()`
and holds it for the whole of `prime_front_desk`; `send_message` opens by taking the same lock.
A Send issued while a brand-new thread's pre-prime is still running blocks for the REMAINDER of
that prime, and the UI honestly shows *"Sending your message / Waiting for Rich to accept it"*
throughout. That run's `app.log` logged the prime at **4412 ms**, and Ray opened a new thread
and typed into it straight away.

It is not a regression and the pre-prime is not wrong — before that slice he paid the whole
prime inside his turn. It is that *"ready before he types"* is only true when he is slower than
the prime, and when he is not, the difference lands on §55's clock. **And nothing wrote it
down**: `app.log` carried the prime's duration and never the part of it he paid for, which is
why it had to be inferred from screenshots. Instrumented at **`98a638c4`**
(`send_wait_notice`), silent by arithmetic on an uncontended lock rather than by a chosen
threshold.

### Measurement 2 — an existing thread, Return at 19:01:34Z

| frame | elapsed | on screen | turn clock |
|---|---|---|---|
| `27-g-05` | +3 s | Rich is working · 2s | start ≈ +1 s |
| `27-g-12` | +8 s | Working for 8s | start ≈ 0 s |
| `27-g-13` | **+9 s** | **"On it!"** | |

The desk took the turn immediately — there is no *"Waiting for Rich to accept it"* band at all,
which is the warm-lease case and agrees with that run's second readiness line, `0 ms`. So the
whole 8–9 s is the turn, against run E's 6.205 s for a warm question turn: **a residual of
about 2 s, and ±1 s of that is frame cadence.**

### What the residual is NOT, and what is left

- **Not deferral.** §1, three ways.
- **Not the lease being cold.** The band is absent and readiness logged 0 ms.
- **Not the register being late.** Run E has it as the first tool call at 3.343 s.

What is left, named rather than guessed, with the test each one needs:

1. **Thread depth.** Ray's second message went into a thread already carrying a failed
   work report; run E's question turn is the second turn of a fresh lease. More context in
   means more time to the first tool call. *Test: run the probe with a third and fourth turn
   and see whether time-to-register grows.*
2. **The webview path.** Everything between `LiveEvent::MessageStarted` — which is where the
   probe stops — and the pixels: the Tauri emit, `ui/main.js`'s chunk listener, the DOM write.
   The probe cannot see it and neither can `app.log`. *Test: a timestamp at the UI's first
   paint of a chunk, joined to the spine's own.*

**Both are outside this slice**, which is the lease's environment and the reader. Item 2 in
particular is a UI measurement and belongs with whoever owns `ui/main.js` and the on-screen
walk. Stated here rather than attempted, as the brief's own instruction says.

---

## 5. What this record does NOT claim

- **It does not claim the 8–12 s is now explained end to end.** Measurement 1 is:
  ≈5 s of lock + ≈7 s of turn, both accounted for. Measurement 2 leaves ≈2 s unattributed,
  and §4 says what it might be rather than picking one.
- **It does not claim run E's 0.4–0.5 s against run D means anything.** One run against one run.
- **It says nothing about what the timer beside his reply reads.** The probe is headless.
- **It does not re-open the register's position or the receipt's authorship.** Both were already
  right on candidate .10 and Ray's audit says so.

## 6. Garbage (CEO §54), and no app on screen (§54 addendum 4)

- **The probe's own fixture is gone.** `first_reply_timing_e2e` removes the directory it makes;
  verified absent afterwards by path.
- **No app instance was launched by this work.** Everything here is headless — a binary probe, a
  test suite and one run of the example. `pgrep -fl richos-tauri` returns nothing, exit 1. Ray's
  instance and its scratch `HOME` were read and never touched.
- **REPORTED, NOT SWEPT — and this one is a gap.** The two Rust suites leave scratch
  directories under `$TMPDIR` named `richos-*`: **1116 entries, 14128 KB** were present after
  this work. They cannot be swept by the agent that made them, because `$TMPDIR` is shared and
  another agent's suite was running in it at that moment (`echo-opus-settle1`, measured with
  `pgrep`), so a blanket delete would destroy a live fixture. `native.rs`'s own module moved to
  a single self-removing root at `61aa950a`; the other modules have not. **This is a §54 gap
  that belongs to the scratch reaper, not to a per-agent judgment call.**

## 7. Reproducing it

```
# the binary's decision, from the binary — no model turn, no network
grep -ao -b 'ENABLE_TOOL_SEARCH' /Users/alex/.local/share/claude/versions/2.1.277
dd if=/Users/alex/.local/share/claude/versions/2.1.277 bs=1 skip=175107000 count=6000 | tr ';' '\n'

# the wire: drive the binary with `child_args`'s vector, read `system/init.tools`, kill at init
#   (a one-character prompt; the init frame arrives before the model is called)

# run E — three model turns
cd richos/app
cargo run -q -p richos-core --example first_reply_timing_e2e -- \
  <path-to>/richos/engine /Users/alex/.richos-nightly/runtime

# the two suites
cargo test -p richos-core --lib                           # 748 passed, 0 failed, 1 ignored
cargo test --manifest-path src-tauri/Cargo.toml           # 265 passed, 0 failed
#   (263 at the commit that added the test; 265 after rebasing onto `48104748`,
#    which brought two of its own — both figures are real and neither is a target)
```
