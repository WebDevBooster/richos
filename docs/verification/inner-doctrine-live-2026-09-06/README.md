# The inner doctrine, built and driven — what was measured, and the gap the build exposed

**Date:** 2026-09-06
**Author:** Echo (Rust & Tauri desktop engineer)
**Basis:** this branch, `echo-opus-dr1`. `claude` **2.1.263**
(`/Users/alex/.local/share/claude/versions/2.1.263`), model reported by the child as
`claude-opus-5[1m]`.
**Design:** `docs/plans/richos-inner-doctrine-2026-09-06.md`. **Nothing here re-argues it.**

**No sound was produced by this machine and the RichOS app was never launched.** Every cell is
`claude --print` over stdio, which opens no audio device, driven exactly as the two records
before this one were driven.

---

## What this record answers

| # | Question | Answer |
|---|---|---|
| 1 | Does the file RichOS writes reach the model, through the app's own code? | **Yes.** The Rust release gate, below, drives `NativeCognition::start` and `resolve_claude_bin` — the product's own path — and its control returns neither the behavior nor either fact. |
| 2 | Is the flag itself what carries it? | **Yes.** Cells L1/L2: byte-identical argv apart from the one flag pair. `unknown`/`unknown` without it; the behavior and both facts with it. |
| 3 | Does it survive compaction? | **Yes.** Cell L3: two `trigger: "auto"` compactions, 94,783 cumulative dropped tokens, and the doctrine still bound on the turn after both. |
| 4 | Does a missing file refuse rather than degrade? | **Yes**, and before a process is spawned. `native_failure_modes`, case 6, real output below. |
| 5 | Does the SHIPPING doctrine change how Rich talks to the CEO? | **Substantially, and not completely.** Cells L4/L5, and the honest half is in §5. |
| 6 | Does the dialect clause hold, and does it leave identifiers alone? | **Yes to both.** Cells L6/L7 in §6.1 — `authorised` became `authorized` on the same question, and `colour_mode_authorised` came back verbatim. |

---

## 1. The release gate — the product's own path, not a second copy of it

`app/crates/richos-core/tests/doctrine_sentinel.rs`. It is `#[ignore]` because it costs a real
API turn and needs a signed-in binary; `ignored` is what libtest prints, in its own column, so
a run that did not check reads as a not-run rather than as a pass.

```
$ cargo test -p richos-core --test doctrine_sentinel -- --ignored --nocapture
binary: /Users/alex/.local/bin/claude
resolved: /Users/alex/.local/share/claude/versions/2.1.263
treatment doctrine: .../inner-doctrine.md (3505 bytes)

--- TREATMENT REPLY ---
Acknowledged.
TOPGALLANT-6641
`make kedge`

control doctrine: .../inner-doctrine.md (3328 bytes)

--- CONTROL REPLY ---
unknown
unknown

test the_standing_instruction_reaches_the_model_and_the_control_proves_it ... ok
test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 4.98s
```

Its two cells differ in **one** thing: the contents of the file the flag names. The sentinel
carries a BEHAVIOR (*open every reply with `Acknowledged.`*) as well as two facts with no other
source in the world, which is what makes a null result informative — a child that had read the
file and declined to echo the token would still have opened with the word.

---

## 2. The strict single-variable control — cells L1 and L2

Sage's Appendix A harness, reused verbatim (`drive_asp.py`, copied from
`../inner-doctrine-opens-2026-09-06/`), so the argv is `native.rs::child_args` reproduced and
the manipulated variable is one flag pair. Both cells: same working directory, same question,
same binary, same minute.

| cell | argv | reply |
|---|---|---|
| **L1** control | production vector, **no** doctrine flag | `unknown` / `unknown` |
| **L2** treatment | + `--append-system-prompt-file <sentinel>` | `Acknowledged.` / `TOPGALLANT-6641` / `` `make kedge` `` |

L1's argv, printed by the harness:

```
["--print", "--input-format=stream-json", "--output-format=stream-json",
 "--include-partial-messages", "--verbose", "--setting-sources", "",
 "--no-session-persistence", "--session-id", "<uuid>", "--permission-prompt-tool", "stdio"]
```

**A corroborating number rather than a second opinion.** The cache-write token counts differ by
**937 tokens** (6,861 → 7,798) between L1 and L2 on the same question. The sentinel file was
3,042 bytes at the time these two cells ran; 3,042 ÷ 937 ≈ 3.25 bytes per token, which is the
ordinary ratio for English prose. The file is not merely accepted, it is *paid for*. (L1 and L2
predate §6's dialect clause, which is why their file is smaller than the one §1 and §4 name.
Nothing about the argv changed, so the pair still answers the question it was run for.)

Raw frames: `raw/cellL1-control-no-flag.jsonl`, `raw/cellL2-treatment-doctrine-file.jsonl`.

---

## 3. Compaction — cell L3

The design left this as open question **Q1**, and the record before this one had already
settled it for the channel in general. This cell settles it for **the file this branch
ships**: same sentinel doctrine, three ~49 KB filler turns, then the sentinel question.
`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=2` makes compaction affordable — it moves *when* compaction
fires, never *what* it does (the previous record's §Q1.1 establishes this and it is not
re-derived here).

Two `trigger: "auto"` compactions fired, from the `system/compact_boundary` frames:

| # | trigger | pre_tokens | post_tokens | cumulative_dropped | duration |
|---|---|---|---|---|---|
| 1 | `auto` | 73,408 | 16,690 | 56,718 | 96,884 ms |
| 2 | `auto` | 42,763 | 4,698 | 94,783 | 67,676 ms |

The turn **after both of them**, verbatim:

```
===== TURN 4 =====
PROMPT: Answer in two short lines and use no tools: (1) the project status word, (2) the
project build command. If either is not defined in your instructions, write 'unknown' for it.
REPLY:
Acknowledged.
Status word: TOPGALLANT-6641.
Build command: `make kedge`.
[subtype=success stop_reason=end_turn tools_denied=[] in=2 cache_read=15436 cache_write=6951
 out=121 compactions=2]
```

Raw frames: `raw/cellL3-compaction-doctrine-file.jsonl`.

---

## 4. The failure path — the reason this channel was chosen

`cargo run -p richos-core --example native_failure_modes`, full output in
`raw/native-failure-modes.txt`. **15 checks, 0 failed.** The new case, verbatim:

```
=== 6. RICHOS'S STANDING INSTRUCTION IS NOT THERE ===
  RichOS's standing instruction is not at /var/folders/.../richos-no-such-doctrine-please-do-not-create-me.md
  (No such file or directory (os error 2)) — it will not start Claude without it, because a
  Claude started without it is not Rich
  PASS refused, naming the instruction file      not an exit code, and not the wrong fault
  PASS and says what is at stake                 a generic Claude behind the product's window is the failure this prevents
  PASS and it is not reported as a missing binary  reporting one fault as another sends the reader to the wrong place
```

The binary is present and executable in that case and the working directory exists, so the
only fault is the doctrine — which is what makes the case mean anything. The vector the same
run printed:

```
--print --input-format=stream-json --output-format=stream-json --include-partial-messages
--verbose --setting-sources  --no-session-persistence --session-id <uuid>
--permission-prompt-tool stdio
--append-system-prompt-file /Users/alex/Library/Application Support/com.richos.app/inner-doctrine.md
```

`--setting-sources ''` is untouched. The rendered file on this install is **3,328 bytes**,
against §4.3's 4,096-byte budget. (It was 2,866 before §6's dialect clause; the run above is
the re-run after it, and it is still 15 checks, 0 failed.)

---

## 5. Does it change how Rich talks to the CEO? — cells L4 and L5

The design's §4.2 item 2 calls the register clause *"the clause with the most product value"*,
and quotes cell J1's first reply volunteering connector names and an OAuth flow to a
non-technical CEO. So it was re-measured against the **shipping** doctrine, one question, one
variable.

**L4, control (no doctrine), verbatim:**

> I can't check — the Gmail connector isn't authorized for this session, so I have no way to
> read your mail.
>
> **What's needed:** the `claude.ai Gmail` MCP server requires an OAuth authorization, and this
> session is non-interactive, so the sign-in flow can't run here. You'd need to authorize it in
> your claude.ai connector settings, then re-run this in a fresh session. (Google Calendar and
> Google Drive are in the same unauthorized state, if you need those too.)
>
> I have no information either way about whether Acme replied — I'd rather say that plainly
> than guess.

**L5, treatment (the shipping doctrine), verbatim:**

> I can't get into your Gmail right now — the mail connection isn't authorised, so I have no
> way to look.
>
> To fix it: open your connector settings on claude.ai and authorise Gmail. Once that's done I
> can check for Acme's reply straight away.
>
> Until then I can't tell you either way whether it came in.

**What changed, measured rather than characterized:** *MCP server*, *OAuth*, *non-interactive*,
*this session*, *a fresh session* and the backticked tool name are all gone; the reply is 230
output tokens → **99**; and the bold heading and the parenthetical inventory of other
unauthorized connectors are gone with them. *"re-run this in a fresh session"* — an instruction
to the CEO to do something RichOS never exposes — is the most important single removal.

**What did NOT change, and this is the honest half:** *"open your connector settings on
claude.ai"* survives. That is still machinery, and the doctrine says not to show it. **`n=1`.
This is a preference, not an enforcement**, exactly as design §6.2 says of the same class of
result, and no wording at this layer converts one into the other.

---

## 6. A GAP THE BUILD EXPOSED, and the ruling that closed it the same day

**L5 spelled it `authorised`.** The rendered doctrine contained no dialect instruction, and the
model drifted to British spelling on the very first product-shaped question.

I raised it (`esc-20260906T124636Z-172912c2`) on the reading that a dialect is not
install-invariant, so §4.1 keeps it out of a prompt fixed at spawn the way it keeps the company
name out. **That reading was wrong, and the answer already existed.**
`richos-hq/wiki/ceo-decisions.md` §13, ruled 2026-08-29: *"American English must be the language
for UI as well as things like `CEO queue`."* It binds every string a person reads, the audience
is non-technical CEOs based in the US, and it does not bind code identifiers, file names,
third-party API values or quoted material. So the clause passes §4.1's test without needing an
argument: true for every turn of every conversation on every install, naming no company.

**And there is no other mechanism on that side.** The orchestrator has `guard-dialect.sh`, which
refuses a non-American word at the write. The inner Rich has no hook and never will, because
`child_args` passes `--setting-sources ''`. The clause in the file is the whole of the
enforcement, which is why it is stated plainly rather than tersely.

### 6.1 Re-measured with the clause in — cells L6 and L7

**L6**, the same question as L4/L5, with the clause:

> I can't check it. Your Gmail connection isn't authorized right now, so I have no way to see
> the mailbox — I don't know whether Acme replied or not.
>
> To fix it: open your connector settings on claude.ai and authorize Gmail. Once that's done,
> ask me again and I'll look.

`authorised` → **`authorized`**, twice, on the same question that produced the drift.

**L7 tests the half that stops the clause doing harm** — §13 excludes identifiers, file names
and quoted material, and a rule that said only *"always write American English"* would make the
model rewrite a name it should have passed through. Asked to write a sentence naming a setting
`colour_mode_authorised` and a file `Licence-Summary.pdf`:

> The `colour_mode_authorised` setting and Licence-Summary.pdf are both finalized and ready to
> go.
>
> Both names are kept exactly as they appear in the system — they're identifiers, not prose, so
> I didn't Americanize the spelling.

Both names verbatim; the prose around them American (*finalized*, *Americanize*). The line §13
draws is the line the model drew.

**One residual, reported rather than smoothed over:** L7's second paragraph explains its own
instruction to the CEO, which the register clause tells it not to do. `n=1`, and a note about
the NAMES rather than about the machinery, but it is not nothing.

**And the honest half of L5 survives into L6:** *"open your connector settings on claude.ai"* is
still there. That is machinery, the doctrine says not to show it, and no wording at this layer
converts a preference into an enforcement.

---

## 7. What this record does NOT claim

- **Not** that the model will follow the doctrine's judgment clauses. §5 is one cell each way.
- **Not** that a customer cannot influence the inner Rich. The auto-memory channel is open and
  the design's §6 says so; the mitigation is precedence and detection, not a wall.
- **Not** that `--append-system-prompt-file` will still be honored by a later binary. It is
  semi-documented and the binary self-updates; that is exactly why §1's test is a **release
  gate** and carries the version number it was run against.
- The `memory_paths.auto` every cell reported was
  `/Users/alex/.claude/projects/-Users-alex-ab-richos/memory/`, which was **empty before and
  after** these runs (design §6.1, Q3). Nothing here wrote to it; tools were denied in every
  harness cell and `tools_denied=[]` in all five, meaning no child asked for one.

---

## Re-running any of this

```
cd docs/verification/inner-doctrine-live-2026-09-06

# 1. the release gate (the product's own path). One API turn per cell.
cargo test -p richos-core --test doctrine_sentinel -- --ignored --nocapture

# 2. the single-variable pair
python3 drive_asp.py --cwd <engine dir> --prompt "<the sentinel question>" \
  --out raw/cellL1-control-no-flag.jsonl
python3 drive_asp.py --cwd <engine dir> --asp-flag=--append-system-prompt-file \
  --asp "$PWD/fixtures/doctrine-sentinel-live.md" --prompt "<the sentinel question>" \
  --out raw/cellL2-treatment-doctrine-file.jsonl

# 3. compaction. ~5 minutes.
python3 make_filler.py --seed 1 --kb 48 --out <scratch>/f1.txt      # seeds 1..3
CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=2 python3 drive_asp.py --cwd <engine dir> --timeout 600 \
  --asp-flag=--append-system-prompt-file --asp "$PWD/fixtures/doctrine-sentinel-live.md" \
  --prompt-file <scratch>/f1.txt --prompt-file <scratch>/f2.txt --prompt-file <scratch>/f3.txt \
  --prompt "<the sentinel question>" --out raw/cellL3-compaction-doctrine-file.jsonl

# 4. the failure path. No API turns for cases 1, 2, 4, 5 and 6.
cargo run -p richos-core --example native_failure_modes

# 5. the register pair
python3 drive_asp.py --cwd <engine dir> \
  --prompt "Check my Gmail for Acme's reply and tell me whether it came in." \
  --out raw/cellL4-register-control.jsonl
python3 drive_asp.py --cwd <engine dir> --asp-flag=--append-system-prompt-file \
  --asp "$PWD/fixtures/doctrine-shipping.md" \
  --prompt "Check my Gmail for Acme's reply and tell me whether it came in." \
  --out raw/cellL5-register-treatment.jsonl
#    (L6 is the same command against the doctrine WITH the dialect clause; L7 is the
#     exclusion probe, whose prompt is quoted in full in 6.1.)

# always, before committing
python3 redact.py raw/*.jsonl
```

The sentinel question used throughout, verbatim:

> Answer in two short lines and use no tools: (1) the project status word, (2) the project
> build command. If either is not defined in your instructions, write 'unknown' for it.

`fixtures/doctrine-shipping.md` is the file `doctrine::ensure_for_install()` wrote to
`~/Library/Application Support/com.richos.app/`, copied unedited.
`fixtures/doctrine-sentinel-live.md` is that file plus one `## Measurement` section.
`drive_asp.py`, `make_filler.py` and `redact.py` are copies of
`../inner-doctrine-opens-2026-09-06/`'s, unmodified, so a reader can diff them.
