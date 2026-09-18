# The register is the first tool call — what six real turns showed, before and after

**2026-09-18 · branch `cc/echo-opus-register1` · CEO ruling §55
(`richos-hq` `wiki/ceo-decisions.md`), and the finding it answers,
escalation `esc-20260918T122522Z-bee1732c`**

*"Rich **immediately** replies with: "On it!" and only after that does all that work."* …
*"Yes, a few seconds is fine. But 35 seconds of waiting for the first response is not. Go."*

Three runs of `crates/richos-core/examples/first_reply_timing_e2e.rs` against a real provider on
the CEO's subscription — **six model turns, one task and one question in each run, which is the
whole of what was spent.** Logs verbatim in `first-reply-2026-09-18-logs/`. The before column is
`question-receipt-2026-09-18.md`, measured by `echo-opus-question1` on the same path the same day.

---

## The numbers

Send → his first words, off `LiveEvent::MessageStarted`/`MessageDelta` — the event the webview
renders his text from, so this is when the sentence appears rather than when the turn ends.

| | before (`question-receipt-2026-09-18.md`) | after, run 1 | after, run 2 | after, run 3 |
|---|---|---|---|---|
| a task turn, the lease's first | — (not measured before) | 13.464 s | 13.628 s | **15.513 s** |
| a question turn, warm | 12.197 s / 22.956 s | 8.505 s | 8.920 s | **7.128 s** |
| a question answered directly, warm | 19.343 s | — | — | — |
| the slowest measured | **31.023 s** | 13.464 s | 13.628 s | 15.513 s |
| `ToolSearch` round trips before the reply | **2** | 0 | 0 | 0 |
| a checkpoint before the reply | **yes, 12.980–17.023 s** | no | no | no |
| the register's place among the tool calls | **4th** | **1st** | **1st** | **1st** |
| runs of prose he can SEE | 1, implied by its single reply string — runs were not recorded then | 2 (a defect, below) | 2 (a defect, below) | **1** |

Run 3 is the shipped state. Its accounting, in the same form the before-record used:

```
he said    : Land the pricing branch and get the staging deploy done.
Rich said  : "On it!"
send -> first words : 15.513 s      send -> turn ended : 15.804 s
     11.714 s  mcp__richos_assignments__record        <- the FIRST tool call
     11.984 s  {"assignment":"Land the pricing branch and get the staging deploy done.","kind":"tas…
     14.086 s  tool_call
runs of prose he can see : 1
     15.513 s  "On it!"  (turn_d4be24b7591643e18d6e100417c4378d:text:0)

he said    : Why has the nightly build been failing since Tuesday? …
Rich said  : "I'll investigate."
send -> first words : 7.128 s       send -> turn ended : 7.405 s
      3.122 s  mcp__richos_assignments__record        <- the FIRST tool call
      4.040 s  {"assignment":"Why has the nightly build been failing since Tuesday, and what is act…
      6.034 s  tool_call
runs of prose he can see : 1
      7.128 s  "I'll investigate."  (turn_c4c0f9846d6e4c8fa7af435347d12d29:text:0)
```

Against the before-run's twelve frames over 22 s for the same question. **Both of the two things
that were spending his seconds are gone, and neither is gone by asking the model nicely.**

---

## What was changed, and why each is structural rather than a sentence

### 1. The front desk's tools are resident from its first turn — `ENABLE_TOOL_SEARCH=false`

The seven seconds the before-record could not explain were **tool discovery**: `ToolSearch` at
3.934 s to find the register, `ToolSearch` again at 7.593 s to find the continuity tools. The
doctrine has said *"The register is your FIRST tool call"* since the front desk existed, and a
model that has to look the register up cannot obey it.

**Re-derived from the shipped binary rather than from documentation** — `claude` 2.1.275, byte
offset 173_562_000, is the whole decision:

```
function EYe(){ if(f_t())return"standard"; if(u())return"tst";
  let e=process.env.ENABLE_TOOL_SEARCH, r=e?UQn(e):null;
  if(r===0)return"tst"; if(r===100)return"standard";
  if(m(e))return"tst-auto"; if(Oe(e))return"tst"; if(To(e))return"standard";
  return"tst" }                                    // UNSET MEANS DEFERRAL IS ON
function To(e){ … return["0","false","no","off"].includes(String(e).toLowerCase().trim()) }
function Mg(){ let e=EYe(); if(e==="standard"){ …; return!1 } … }
```

There is **no flag** for it; it is an environment variable, and the default is deferral — a
third-party default this app had inherited unexamined. It is set on the **conversation** lease
only: nobody sits in front of a work lease's first token, and one measurement on one lease is not
evidence about the other.

**The loudness layer, because an unknown variable cannot fail a spawn.** The reader reads
`ToolSearch` out of the child's own `system/init.tools` into `ReaderState::tool_search_offered`
and says so on stderr. **The trap it exists for is the finding worth keeping from this work:
every init fact the app already reads — `assignment_tool_loaded`, `status_tool_loaded`,
`continuity_tools_loaded` — was `true` on the before-run whose model still spent 7.5 s discovering
the register.** A deferred tool is still in the init inventory, so those facts can never answer
this question; only the presence of the discovery tool can. Its positive control asserts exactly
that, on both frames, with no model turn.

### 2. The checkpoint is written after he has been answered, and that is a condition of the tool

The before-run's checkpoint occupied 12.980 s to 17.023 s of a 22.956 s wait. The doctrine had
asked for the reply first and was obeyed literally in the other direction: its own words were
*"the checkpoint of the conversation you are having, written as you go with the continuity
tools"*, and a model told *as you go* writes it before it speaks.

So the sentence changed AND `native.rs` refuses `mcp__richos_continuity__checkpoint` while nothing
has been said on the turn in flight — before the permission desk sees it, because the desk's
answer would be `allow` and correctly so: the tool is granted, just for after he has been
answered. `ReaderState::spoken_this_turn` is host-owned, set at the first text delta on both text
paths, and reset with the SEND.

`inspect` is deliberately not gated: a write is bookkeeping and has nowhere to be before the
reply, a read may BE the answer he is waiting for.

### 3. A hand-over turn carries no checkpoint at all — and this is the part the probe found

**Fix 2 introduced a defect, in his conversation.** Run 1 showed it as a doubled string
(`"On it!On it!"`); the probe was then taught to record every run of prose by `message_id`, and
run 2 showed what it actually was. With the checkpoint moved after the reply, the front desk said
its line, wrote the checkpoint, and said the line AGAIN:

```
run 2, task turn      13.628 s  "On it!"             (turn_330c…:text:0)
                      30.585 s  "On it!"             (turn_330c…:text:1)
run 2, question turn   8.920 s  "I'll investigate."  (turn_678f…:text:0)
                      13.237 s  "I'll investigate."  (turn_678f…:text:1)
```

Two separate runs of prose, not one doubled string — `message_id` is what settles that, which is
why the probe records runs by id rather than reasoning about a string.

**The mechanism, and it is why the obvious fix failed.** A tool call made after the reply forces
the model to produce a further assistant message when the tool result comes back, and it fills
that message with the line it has just been handed. *"Say it once"* was added first and run 2 is
its measurement: **it did not work**, because the model was not being polite, it was answering a
tool result. The second clause removes the tool call instead — the register has already written
that turn down, so a hand-over turn carries no checkpoint. Run 3: one run of prose on both turns,
and the turn ends 0.3 s after his first words instead of 17.0 s after them.

---

## FINDING — the same question is 3 to 16 seconds faster, and it is still NOT "a few seconds"

The nightly-build question is the one asked on both sides: **12.197 s and 22.956 s before,
7.128 s / 8.505 s / 8.920 s after**. The slowest figure anywhere went 31.023 s → 15.513 s. §55's
defect line is 35 s and its goal is *"a few seconds"*, and passing the line is not meeting the
goal — the same sentence the before-record had to write, with smaller numbers.

**Where the remaining time is, measured off run 3's own frames and not guessed:**

| term | warm | the lease's first turn |
|---|---|---|
| his prompt → the model's register call appears | 3.122 s | 11.714 s |
| that call → its result frame (the model streaming the arguments; the register itself is ~1 ms by `assignment_receipt_timing`) | 2.912 s | 2.372 s |
| the result → his first word | 1.094 s | 1.427 s |
| **total** | **7.128 s** | **15.513 s** |

**Two model round trips are the floor, and this app owns neither.** The register hands back the
sentence that the model then says; nothing in the front desk can make the model speak without
being asked twice. The ~8 s difference in the first column is the lease waking up while he waits.

**Both remaining levers are outside this brief's scope and are named rather than taken**
(`Not in scope: the register's own logic, the §58 sentences, the timer, the UI`):

1. **The app says the register's fixed sentence the moment the tool returns**, and the model's own
   copy is suppressed. His words would arrive at ~3 s warm. It is the app speaking rather than the
   model, which is a decision about what Rich's voice IS.
2. **The lease is primed before he types**, which is the ~8 s in front of the register on a first
   turn.

Raised as `esc-20260918T132721Z-19c84d88`, `--state work-complete`.

---

## The budgets, and how they were taken

`first_reply::FIRST_WORDS_BUDGET` = **12 s**, from the three warm turns (7.128, 8.505, 8.920) —
the slowest plus ~35%. `first_reply::FIRST_TURN_BUDGET` = **20 s**, from the three first turns
(13.464, 13.628, 15.513) — the slowest plus ~29%.

**Two constants, not an average.** One budget covering both would be 20 s everywhere, and a
regression on a warm turn would pass it: a returned `ToolSearch` is +7.5 s and a pre-reply
checkpoint is +4.0 s. `every_turn_the_fix_was_measured_on_passes_its_own_budget` pins all six
figures and asserts that a cold turn is not excused on the warm budget.

**They are budgets, not his goal**, and the probe prints the figure rather than only the verdict
for exactly that reason.

## Proven able to fail

* `the_measured_defect_of_2026_09_18_is_red` feeds the rule the before-run's own six merged frames
  and asserts **seven** faults, including the register being tool call 6 of 6 — under both budgets,
  so a cold-start allowance cannot forgive it.
* The permission gate: with `!spoken &&` replaced by `false &&`, both of its tests go red
  (`native.rs:4293`, `native.rs:4313`); restored, the suite is green. Its fixture child exits
  9/8/7/6 on the wrong behavior, so the wire is asserted from the child's side too, and its second
  turn exists only to prove the per-turn reset.
* The double reply: the probe fails by name (`he was told the same thing twice`), which is how it
  was found.

`cargo test -p richos-core`: **724 passed, 0 failed, 1 ignored** (713 before this work).

## What this record does NOT claim

* **The app was never put on screen.** No window, no `richos-tauri` process, no GUI walk — the
  probe is headless, nothing was launched, and there is no pid to report gone (CEO §54 addendum 4).
  So this record says nothing about what the timer beside his reply reads; that is
  `ui/tests/question-timer.js`, and an on-screen walk is a QA leg.
* **Nothing here was tested with audio.** No `say`, no playback, no microphone (CEO §53).
* **The work lease is unmeasured and unchanged.** `ENABLE_TOOL_SEARCH` is not set on it and the
  checkpoint gate cannot reach it (it is never given the continuity server, §5.8a-ii seam 1).
* **`HOME` was not replaced.** The provider credentials live there and a synthetic one would have
  made this probe measure a sign-in failure. What is throwaway is the whole app state root under
  the system temp directory, removed on the way out (CEO §54).
* **Three runs, not one.** Run 1 measured the two in-scope fixes, run 2 measured *"Say it once"*
  failing, run 3 measured the shipped state. Stated here rather than left to be noticed.
* **The absence of the deferral diagnostic is not the positive control.** No `[richos] THIS
  SESSION DEFERS ITS TOOLS.` line appears in any of the three logs, which is consistent with the
  variable working; the reading itself is proven by a unit test that feeds it a frame containing
  `ToolSearch`.

## Reproducing it

```
cd richos/app
cargo run -q -p richos-core --example first_reply_timing_e2e -- \
  <path-to>/richos/engine /Users/alex/.richos-nightly/runtime
```

Two model turns, a temp directory it removes, no audio device, no window.
