# The fifty-second silence: which frame announces a compaction, and what the CEO is told

**Author:** Echo (Rust & Tauri desktop engineer). **Date:** 2026-09-06.
**Branch:** `echo-opus-cb1`, cut from `5ad505b`. **Measured against:** `claude` 2.1.263.

The first outside user of RichOS, relayed by the CEO on 2026-09-06: a long wait *"looks like a
crashed application"*. One cause was fixed earlier the same day — the waiting band
(`docs/verification/waiting-state-2026-09-06/`). This is the second one:

> Auto-compaction fires inside a turn the CEO is waiting on and costs **38.1 to 62.0 seconds**,
> during which the calm surface was told **nothing at all**.

---

## 1. The premise I was given, and the half of it that measurement refuted

The brief named `system/compact_boundary` as the frame to read, and asked whether it announces
the start of the pause or reports the end. **It reports the end, and something else announces
the start.** Both halves below are mine, re-derived rather than taken on trust.

### 1.1 `grep -c "compact" app/crates/richos-core/src/native.rs` — confirmed

```
$ cd /Users/alex/ab/richos-wt/echo-opus-cb1
$ grep -c "compact" app/crates/richos-core/src/native.rs
0
$ echo $?
1
```

Still true at `5ad505b`. The only other `compact` in the crate is `steering.rs`'s log
compaction, which is unrelated.

### 1.2 The cost — 14 boundaries re-derived from `echo-opus-q14`'s own frames

Their Q1.3 table says 38.4–62.0 s, mean 51.1 s. Recomputed from
`docs/verification/inner-doctrine-opens-2026-09-06/raw/*.jsonl` by summing every
`compact_metadata.duration_ms`:

```
n = 14
min = 38397   max = 62029   mean = 51149.4   (ms)
triggers = ['auto']
```

Their number stands exactly. **My own cell adds two more**, 43611 ms and 38138 ms, so the
population quoted from here on is **16 boundaries, 38138–62029 ms**.

### 1.3 The timing — and this is the finding that changed the design

`drive_compact.py` is `echo-opus-q14`'s `drive_asp.py` (itself Sage's Appendix A harness) with
the child argv unchanged — still `native.rs::child_args` verbatim — plus a monotonic arrival
stamp on every stdout line, written to a metadata-only sidecar. `python3 gaps.py` prints the
whole arrival timeline; the two compacting turns of `raw/cellT1.jsonl`:

| t (ms) | frame | Δ from previous |
|---|---|---|
| 5177 | **turn 3 prompt sent** | — |
| 5186 | `system/init` | 9 |
| 5187 | `system/status` `"requesting"` | 1 |
| **5190** | **`system/status` `"compacting"`** | 3 |
| **35190** | `system/status` `"compacting"` (repeat) | **30000** |
| 48805 | `system/status` `compact_result: "success"` | 13615 |
| 48805 | `system/compact_boundary` `duration_ms: 43611` | 0 |
| 52050 | `stream_event/message_start` — the reply finally begins | 3245 |

```
48805 - 5190 = 43615 ms observed   against   43611 ms reported   ->  4 ms apart
```

Turn 4 is the same story and it is the one worth reading twice, because the prompt was
**thirty characters** long — `Reply with the single word: ok`:

```
prompt 52075 -> "compacting" 52086 -> repeat 82086 (+30000) -> compact_result 90231
90231 - 52086 = 38145 ms observed   against   38138 ms reported   ->  7 ms apart
whole turn 39.7 s, of which 38.1 s was compaction
```

**So `compact_boundary` cannot drive a live label.** It arrives at the same millisecond the
silence ends, 38–44 s after it began, and its `duration_ms` is the span that already elapsed.
A label drawn from it would appear once the wait was over, which is close to worthless.

**`system/status` is the announcement, and it has three properties the surface needs:**

1. it lands **3 ms after** the child accepts the prompt (13 ms after we send it);
2. it **repeats every 30.000 s** while the compaction runs — measured twice, exactly;
3. the pause **ends with a positive frame in both outcomes**: `status: null` plus
   `compact_result: "success"` or `"failed"`.

Verbatim, from `raw/cellT1.jsonl`:

```json
{"type":"system","subtype":"status","status":"compacting","session_id":"…","uuid":"…"}
{"type":"system","subtype":"status","status":null,"compact_result":"failed",
 "compact_error":"too_few_groups","session_id":"…","uuid":"…"}
{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"auto",
 "pre_tokens":71895,"post_tokens":14640,"cumulative_dropped_tokens":57255,
 "duration_ms":43611,"preserved_segment":{…}},"session_id":"…","uuid":"…"}
```

**Nothing in the earlier record could have told anyone this**, and that is not a criticism of
it: `drive_asp.py` records no arrival times, so the ordering of `compact_boundary` against the
pause was simply not in the data. It took a new run to see it.

---

## 2. Method, and the deviation that makes it affordable

Every cell sets `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=2`, `echo-opus-q14`'s deviation, kept for
their reason: reaching the stock threshold (`window − 13000`) is a bill, not a measurement. It
changes **when** compaction fires and not **what** it does — the summarize-and-replace path,
the frames it emits and their cadence are the binary's own.

```
python3 make_filler.py --seed {1,2,3} --kb 48 --out <scratch>/f{1,2,3}.txt
CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=2 python3 drive_compact.py --cwd <scratch>/cwd --timeout 900 \
  --prompt-file <scratch>/f1.txt --prompt-file <scratch>/f2.txt --prompt-file <scratch>/f3.txt \
  --prompt "Reply with the single word: ok" --out raw/cellT1.jsonl
python3 gaps.py raw/cellT1.jsonl.timed.jsonl
python3 redact.py raw/cellT1.jsonl        # always, before committing
```

The working directory was a scratch directory outside every repository, so no `CLAUDE.md` of
this project entered the context. `redact.py` is q14's, unchanged; it removed the
`initialize` reply's `account` object from 3 frames and verifies its own result
(`grep -oE '<email-shape>' raw/cellT1.jsonl` returns nothing).

**No audio device was opened.** `claude --print` produces no sound, the RichOS app was never
launched, and the browser work below ran in headless WebKit with no voice mode. The CEO was
asleep; this was a standing order.

---

## 3. What was built

### 3.1 The frames become a typed record (`machinery.rs`)

`system/status` carrying a compaction phase is now `MachineryKind::Compaction` instead of
`Unknown`. Everything else on that subtype family is untouched, including
`status: "requesting"` (it fires on every turn, including the two in this cell that never
compacted) and `compact_boundary` (it arrives too late to say anything, and reading it would
have required an edit to `native.rs`, which belongs to another agent this round —
**no change to `native.rs` was needed**, because these frames already reach `machinery.rs` as
`ChunkMsg::Frame`).

### 3.2 The record becomes a CEO row (`timeline.rs`)

`machinery_visibility` returns `Ceo` for it — the one place a `system` frame reaches the calm
surface. The argument, in full, is beside the code: everywhere else vendor plumbing is
technical because the CEO is told about work rather than about the machine, and this is
plumbing that costs him a minute of his life while the screen says nothing.

It is **not** the rotation exception in disguise. A rotation is invisible because it costs him
nothing and Rich must never say it happened. This costs him a minute and says only what the
wire said.

### 3.3 The words

| phase | the sentence | ActivityState |
|---|---|---|
| `status: "compacting"` | **Making room to keep going** | `running` |
| `compact_result: "success"` | **Made room to keep going** | `completed` |
| `compact_result: "failed"` | **Kept going without making room** | `completed` |

Spoken, which is the test that matters (§25, voice-first): *"Rich is working, forty-four
seconds. Making room to keep going."* No pronoun, so nothing flips between reading and
hearing. No jargon — "auto-compaction" and "context window" are the model's words, not his
(§13).

**Rejected, and why** (the list is in the code, where the next author will meet it):
*"Tidying up"* (true of nothing in particular, and it sounds optional); *"Reorganizing"* (a
verb with no object); *"Summarizing the conversation so far"* (accurate, and it invites *"did
he lose it?"*, which five words cannot answer); *"Freeing up memory"* (reads as the machine
being short of RAM, which is false); *"Almost done"* (an estimate — forbidden below).

**No number of any kind is in these sentences, and a test enforces it.** The band already
shows the turn's own measured elapsed clock beside them. A percentage, an estimate or a
countdown would be invented: the spread is 38.1–62.0 s over 16 boundaries, and the only frame
carrying a duration arrives when it is already over.

**The failed ending is `completed`, deliberately.** The vendor's outcome stays truthful on the
record (`ToolStatus::Failed`) and in the raw payload technical mode reads. It is not what the
CEO's state says, because `ActivityState::Failed` draws a *"△ failed"* mark and would tell him
something of HIS went wrong. Measured twice in this cell: an abandoned attempt cost 1 ms and
the turn answered normally straight after. A red mark for that is a false alarm.

### 3.4 One pause is one row

The announcement, its heartbeats and its ending are four or five frames with **no correlation
id** — they share only `session_id`. So the merge key is the lease's, which is turn-scoped for
free in `live.rs` (a `LiveTurn` is built per turn) and re-scoped explicitly in
`machinery::project`, where one map spans every turn of the thread. Without that, this cell's
two compactions would have folded into one row and one real event would have vanished.

### 3.5 `QUIET_AFTER_MS`: 25000 -> 35000

Making the compaction visible exposed a defect in the band that landed hours earlier. Its
threshold was derived from five ACP-adapter runs of ordinary turns (n=192, max gap 20741 ms) —
a sample with no compaction and no long tool call in it, so it could not see that **the native
wire has two 30-second heartbeats, and both reach the band as accepted signals**:

```
tool_progress               run13  35.443s -> 65.445s = 30.002s
                            run16  32.962s -> 62.963s = 30.001s
   re-derived from docs/verification/native-claude-tool-status-2026-08-31/raw/*.timings.tsv

system/status "compacting"  turn 3  5190ms -> 35190ms = 30000ms
                            turn 4 52086ms -> 82086ms = 30000ms

max known heartbeat interval 30002ms -> 35000ms clears it by 4998ms (1.17x)
the pair it replaces was    20741ms -> 25000ms (4259ms, 1.21x)
```

At 25000 ms a perfectly healthy compaction spent **5 seconds of every 30 in the attention
tone** saying *"Nothing new for 25s"*, then snapped back when the heartbeat landed. An alarm
twice a minute over work that is going fine is the same class of lie as a spinner that keeps
spinning.

**What it costs:** a genuinely hung turn is named 10 seconds later than before. It is still
named, the count is the same count, and the elapsed clock was ticking throughout.

---

## 4. What a person sees, before and after

`app/ui/tests/compaction-notice.js`, driving the SHIPPING renderer under WebKit with the
arrival offsets read off `raw/cellT1.jsonl.timed.jsonl`. Frames in `frames/`.

| t | BEFORE (`frames/before-dark-*.png`) | AFTER (`frames/after-dark-*.png`) |
|---|---|---|
| **10s** | Rich is working · 10s — *Nothing has come back yet* | Rich is working · 10s — **Making room to keep going · 9s ago** |
| **30s** | Rich is working · 30s — *Nothing has come back yet* | Rich is working · 30s — **Making room to keep going · 29s ago** |
| **60s** | Rich is working · 1m 0s — *Nothing new for 1m 0s* (attention) | Rich is working · 1m 0s — **Made room to keep going · 16s ago** |

The 60s "after" reads `Made room` because this compaction really ended at 43.6 s. For the
longest one ever measured (62.029 s, `echo-opus-q14` C6), the suite drives its heartbeats too:
30s and 60s both read *"Making room to keep going"* in the working tone, and the ending at
62.029 s changes the tense.

The transcript carries the row as well as the band, so a compaction explains its gap on a
reload and not only live.

### 4.1 The honest limit is a check, not a paragraph

A child that dies mid-compaction, from the same suite:

| t | on screen |
|---|---|
| 20s | Rich is working · 20s — Making room to keep going · 20s ago **[working]** |
| 40s | Rich is working · 40s — **Nothing new for 40s** **[quiet]** |
| 2m 40s | Rich is working · 2m 40s — **Nothing new for 2m 40s** **[quiet]** |
| `turn-status: failed` | **the band is gone** |

Two missed heartbeats is not *"still making room"*. Past the threshold the app genuinely does
not know whether the compaction is still running, so it drops the description and reports the
silence — a dead turn cannot inherit a busy label from an event that arrived a minute ago.

---

## 5. Contrast — computed, both themes, every element this copy lands in

`node compaction-notice.js`, measuring the real DOM with `app/ui/tests/lib/contrast.js` —
the same arithmetic the shipping `tests/contrast.js` runs.

| element | surface | dark | light | floor |
|---|---|---|---|---|
| `.wait-detail` | the waiting band | 6.47:1 | 5.86:1 | 4.5:1 |
| `.tl-activity-text` | the working transcript | 6.47:1 | 5.86:1 | 4.5:1 |
| `.tl-activity-state` (the word *running*) | the working transcript | 6.14:1 | 4.98:1 | 4.5:1 |
| `.tl-activity-mark` (the `◐` glyph) | the working transcript | 6.14:1 | 4.98:1 | 3:1 |

**No exemption is claimed anywhere in this change.** Every string it adds is meant to be read.

**Proven able to fail.** With light `--ink-soft` temporarily set to `rgba(12,19,34,0.30)` the
run went red — `light .wait-detail #a7a7a5 on #eae6dd at 16px = 1.94:1, floor 4.5:1` — and
`style.css` was restored to its committed bytes immediately. A contrast gate nobody has
watched fail is a contrast gate nobody should believe.

---

## 6. Open, and named rather than quietly absorbed

1. **Two compactions inside ONE turn would render as one row.** The wire gives the spans no
   correlation id, so the key is `(turn, lease)`. Never observed: 16 of 16 measured boundaries
   are one per turn, because the trigger is the incoming prompt. If the vendor ever ships a
   correlation id, that is the field to key on.
2. **A compaction between turns is unmeasured.** The between-turn lane keys `system:status`
   into the last-value-wins SessionMeta family, so a heartbeat repeat there would be
   suppressed and start/end would be two rows rather than one. Every compaction observed fired
   inside a turn, which is where the trigger is.
3. **`compact_result: "failed"` is only measured in the 1 ms `too_few_groups` shape**, which is
   what a 2% threshold override produces. A failure that costs 40 seconds and then fails has
   not been seen, and the copy was chosen to be true either way.
4. **The `compact_boundary` frame is still unread.** It carries `pre_tokens`, `post_tokens`,
   `cumulative_dropped_tokens` and the authoritative `duration_ms` — the numbers the
   continuity design's rotation watermark (§3.2) would want. Reading it is a `native.rs` change
   and `native.rs` belongs to `echo-opus-dr1` this round; nothing in THIS change needs it,
   because the app measures the same span from the status pair to within 4–7 ms.
5. **`docs/verification/waiting-state-2026-09-06/` states `QUIET_AFTER_MS` as 25000.** That
   record is evidence with a date on it and was not edited. §3.5 above is what superseded it,
   the same day.
