# The four open questions from the inner-doctrine design, measured

**Q1 does NOT go against the recommendation.** A doctrine delivered by
`--append-system-prompt-file` survived **two consecutive `trigger: "auto"` compactions** with
its behavior and both invented facts intact, and the token accounting shows it was still in
the cached system prefix afterwards. `--append-system-prompt-file` remains the right channel.

**But one argument for it does not survive, and it is the argument Q1 was written to test.**
Sage's §3.2 kept the priming turn's last weakness as *"a long conversation's compaction is a
context event and a system prompt is not"*, marked `unverified:`. Measured: **the priming turn
survived too** — three auto-compactions, all six invented facts returned verbatim — because the
compaction summary reproduces standing instructions in full. The channel choice still holds on
its other three properties (§3.1 items 1, 2 and 4, plus the token accounting in §Q1.5 below),
and it should stop being argued on compaction-resistance.

| # | Question | One-line answer |
|---|---|---|
| **Q1** | Does the doctrine survive a compaction event, where a priming turn would not? | **The doctrine survives; so does the priming turn.** 14 `auto` compactions across 6 cells, no doctrine lost by either channel. The channels differ in the token accounting, not in what they survive. |
| **Q2** | What does `memory_paths.auto` resolve to on a customer install whose engine directory is not in a git repository? | **The working directory's own slug** — `~/.claude/projects/<cwd-with-slashes-as-dashes>/memory/`, one store per directory, so a customer install shares it with nothing. **Unless the customer keeps their home directory in git**, in which case it keys to the home repository's root and is shared with every session anywhere under `$HOME`. |
| **Q3** | Does anything actually write to the shared `-Users-alex-ab-richos` memory store during normal work? | **Nothing has ever written to it** — the directory's mtime still equals its birth time 13 days on. Not raised as an escalation. It is writable by the product, though: `decide_permission` allows every tool and the child's tool list includes `Write` and `Bash`. |
| **Q4** | Can a CI runner authenticate well enough to run the §7.3 sentinel? | **Yes, by mechanism — `CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token`, held as a repository secret.** Measured: with no credential the child answers `Not logged in · Please run /login`; with an invalid token it answers `401 Invalid bearer token`, so the variable is read. **Both come back as `subtype=success`, so a sentinel that checks the exit path reports green on a run that never authenticated.** End-to-end from a real runner is `unverified:` — no live credential was minted. |

**Measured 2026-09-06 against `claude` 2.1.263** (`~/.local/bin/claude -> ~/.local/share/claude/versions/2.1.263`),
model `claude-opus-5[1m]`, **33 driven turns across 13 cells**, on richos `9f433ae`. Raw
stream-json in `raw/`. Sage's Appendix A harness is reused, not replaced — `drive_asp.py` here
is his file with three additions, each marked `--- q14 addition ---` in the source and listed
in its docstring.

**No sound was produced and the app was never launched.** `claude --print` opens no audio
device; nothing here starts RichOS. **Q5 was not touched** — `managed_child_args` is unmodified,
per the brief.

---

## The standard this record holds itself to

Every answer below carries the command that produced it and that command's raw output.
Everything that could not be settled says `unverified:` and names what would settle it.

Two false greens were caught by controls rather than by care, and both are recorded because
they are the reason to keep building controls:

- **The attribution confound in Q1.4.** Cell C3 was designed so the sentinel token was never
  spoken in the conversation before compaction, on the theory that the summary then could not
  carry it. **It carried it anyway** — the summarizer sees the system prompt. The cell proves
  the doctrine still binds; it does **not** prove the system prompt is the route. The route is
  settled in §Q1.5 by token accounting instead, and the failed design is left here rather than
  deleted.
- **The redaction check found a second leak site.** `echo-opus-sn1` redacted the `account`
  object. That was correct and insufficient here: the **post-compaction summary quotes the
  `system-reminder` that names the operator's email address**, so the address also appears in
  `user` frames. `redact.py` now removes both and refuses to exit 0 while any email-shaped
  string remains.

---

## Q1 — Compaction

### Q1.1 How compaction was made to happen at all, and the deviation that made it affordable

The model in every cell is `claude-opus-5[1m]`, a **one-million-token** window. Filling it to
reach the stock autocompact threshold is not a measurement, it is a bill. Two knobs exist:

```
$ ~/.local/bin/claude --help | sed -n '27,28p'
  --autocompact <auto|tokens>           Auto-compact window size (auto, or
                                        100k–1M tokens)
```

and, in the binary itself, an override that lowers the threshold rather than the window:

```
$ strings -a ~/.local/share/claude/versions/2.1.263 | grep -o -E "function BIe\(e,t\)\{.{0,150}" | head -1
function BIe(e,t){let r=e-13000,o=t.testPctOverride;if(o!==void 0&&!isNaN(o)&&o>0&&o<=100)return Math.min(Math.floor(e*(o/100)),r);return r}function Zot(e,t){return Mat

$ strings -a ~/.local/share/claude/versions/2.1.263 | grep -o -E "let o=process.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE.{0,120}" | head -1
let o=process.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE,d=process.env.CLAUDE_CODE_BLOCKING_LIMIT_OVERRIDE;return{enabled:tp(),precomputeBufferFraction:Hko(e,t,r),testPctOverri
```

Read plainly: the compaction threshold is normally `window − 13000`, and
`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` replaces it with `min(window × pct/100, window − 13000)`.

**Every cell below sets `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=2`. This is a deviation from the app
and it is stated because it changes what the evidence means — and what it does not.** It moves
**when** compaction fires. It does not touch **what** compaction does: the summarize-and-replace
path is the same code, and every one of the 14 boundaries observed reported
`"trigger": "auto"`, not `"manual"`. What the cells therefore cannot tell you is the token
count at which a real install compacts.

**And the arithmetic does not fully reproduce, which is said rather than smoothed over.** With
`pct=2` on a 1M window the formula predicts a 20,000-token threshold; the 14 boundaries fired at
**30,839–72,084** `pre_tokens`. So the override demonstrably lowers the threshold — 14
compactions in six short sessions where the stock setting would have produced none — but the
effective window it is a percentage *of* is not the 1M the model name advertises, and this
record does not claim to know what it is.

`unverified:` the stock threshold on a 1M-window install, and the effective window the override
is applied to. What would settle the first: one session driven past `window − 13000` tokens with
no override, which is a ~987k-token conversation and was not worth its cost against a question
the override answers.

### Q1.2 The cells

Filler is deterministic (`make_filler.py --seed N --kb 48`, ~49 KB and ~15k tokens per turn,
inventory-noise words, containing no sentinel token). The doctrine files are in `fixtures/`.

| cell | channel | doctrine | turns | compactions | sentinel BEFORE | sentinel AFTER |
|---|---|---|---|---|---|---|
| C0 | none (control) | — | 4 | 2 | `unknown` / `unknown` | `unknown` / `unknown` |
| C1 | `--append-system-prompt-file` | 2 facts | 4 | 2 | `Acknowledged.` `HALYARD-3175` `` `make lodestone` `` | **identical** |
| C2 | priming user turn | 2 facts | 5 | 3 | `Acknowledged.` `BINNACLE-8840` `` `make sextant` `` | **identical** |
| C3 | `--append-system-prompt-file` | 2 facts | 4 | 2 | *not asked* | `Acknowledged.` `HALYARD-3175` `` `make lodestone` `` |
| C5 | `--append-system-prompt-file` | 6 facts | 4 | 2 | *not asked* | all six, verbatim |
| C6 | priming user turn | 6 facts | 5 | 3 | *not asked* | all six, verbatim |

The sentinel is `echo-opus-sn1`'s design and it is kept for the same reason: it carries **a
behavior** (`begin every reply with Acknowledged.`) as well as invented facts, so a null result
separates *"the doctrine was lost"* from *"the doctrine held and the model declined to echo a
token"*. C0 is the control that makes the facts attributable at all — same filler, same
compactions, `unknown` twice.

C1, verbatim, first and last turns of one session with two auto-compactions between them:

```
===== TURN 1 =====
PROMPT: Answer in two short lines and use no tools: (1) the project status word, (2) the
project build command. If either is not defined in your instructions, write 'unknown' for it.
REPLY:
Acknowledged.
HALYARD-3175
`make lodestone`
[subtype=success stop_reason=end_turn tools_denied=[] compactions=0]

===== TURN 4 =====
PROMPT: (identical)
REPLY:
Acknowledged.
HALYARD-3175
`make lodestone`
[subtype=success stop_reason=end_turn tools_denied=[] compactions=2]
```

C6, the priming-turn channel, after **three** auto-compactions:

```
===== TURN 5 =====
REPLY:
Acknowledged.
1. BINNACLE-8840
2. `make sextant`
3. `make holystone`
4. 39104
5. The copper marten
6. FATHOM-215
[subtype=success stop_reason=end_turn tools_denied=[] compactions=3]
```

### Q1.3 The 14 compaction events

Every boundary, from the `system/compact_boundary` frames in `raw/`:

| cell | trigger | pre_tokens | post_tokens | dropped | duration_ms | messages kept |
|---|---|---|---|---|---|---|
| C0 | auto | 51261 | 15095 | 36166 | 49790 | 3 |
| C0 | auto | 39675 | 3449 | 72392 | 59901 | 5 |
| C1 | auto | 51373 | 14842 | 36531 | 42950 | 3 |
| C1 | auto | 39339 | 2904 | 72966 | 38397 | 4 |
| C2 | auto | 30839 | 14555 | 16284 | 44813 | 3 |
| C2 | auto | 51032 | 15283 | 52033 | 50654 | 5 |
| C2 | auto | 39714 | 3199 | 88548 | 50411 | 3 |
| C3 | auto | 72025 | 14805 | 57220 | 46975 | 3 |
| C3 | auto | 39331 | 3073 | 93478 | 39085 | 5 |
| C5 | auto | 72084 | 15478 | 56606 | 58298 | 3 |
| C5 | auto | 40361 | 3513 | 93454 | 50158 | 4 |
| C6 | auto | 51510 | 15185 | 36325 | 61883 | 4 |
| C6 | auto | 52114 | 16277 | 72162 | 60747 | 5 |
| C6 | auto | 41255 | 4248 | 109169 | 62029 | 3 |

**A side finding this project should not discover later: compaction costs 38.4–62.0 s
(mean 51.1 s) inside a turn the CEO is waiting on.** 14 of 14 boundaries, `min=38397`,
`max=62029`, `mean=51149` ms. It happens under the app's exact production flags in
`--print` stream-json mode, self-triggered, with no signal to the parent except the
`compact_boundary` frame — which `native.rs` does not read today
(`grep -c "compact" app/crates/richos-core/src/native.rs` → `0`, exit 1). That frame is
free to consume.

> **CORRECTED 2026-09-06 by `echo-opus-cb1`, measured on a real `claude` 2.1.263 stream — this
> paragraph called `compact_boundary` "the only positive notice the app can get", and that is
> FALSE.** `compact_boundary` arrives at the same millisecond the silence ENDS, 38-44 s after it
> began, carrying the elapsed span as `duration_ms` — it REPORTS the pause, it cannot announce
> it. The announcement is `system/status` with `status: "compacting"`, which arrives **3 ms
> after the child accepts the prompt** and repeats every 30.000 s until a `compact_result`
> frame ends it. So the app CAN name the wait while the CEO is inside it, and a surface built
> on `compact_boundary` alone would have shown its caption at the one moment nobody needs it.
> Raised as `esc-20260906T123833Z-0ebed295` rather than left in a handoff, because this
> sentence is what a later agent would have built on.

The pause is ~51 s of the child not answering. This belongs to the rotation/watermark leg of the continuity design
(§3.2), and it is named here rather than fixed here.

### Q1.4 The attribution attempt that failed, kept because it failed

C3 withheld the sentinel question until after compaction so that no sentinel token would exist
in the transcript for a summary to copy. The summary carried the tokens regardless:

```
$ python3 - <<'PY'   # over raw/cellC3-system-prompt-token-never-spoken.jsonl
summary frame 1, 7134 chars: HALYARD-3175=True  'make lodestone'=True  'Acknowledged.'=True
summary frame 2, 8739 chars: HALYARD-3175=True  'make lodestone'=True  'Acknowledged.'=True
```

The summarizer reads the system prompt, so it restates the doctrine no matter whether the
conversation ever used it. C5's six-fact doctrine was copied into both summaries **complete**,
and C6's into all three. So **no behavioral cell can separate "the system prompt is still
applied" from "the summary re-supplied the content"** at this conversation size. Any claim that
it can is a false green.

### Q1.5 What separates the two channels, since behavior does not: the cached prefix

`cache_read_input_tokens` on the `result` frame is the size of the cached prompt prefix, which
is where a system prompt lives and where a conversation turn does not. Read across cells it
answers the attribution question arithmetically.

| cell | channel | doctrine file | turn 1 … turn N `cache_read` |
|---|---|---|---|
| C0 | none | — | 14548 · 18247 · 14548 · **14548** |
| C2 | priming turn | — | 14548 · 18386 · 14548 · 14548 · **14548** |
| C6 | priming turn | — | 14548 · 18443 · 14548 · 14548 · **14548** |
| C1 | system prompt | 264 B | 11824 · 18342 · 14644 · **14644** |
| C3 | system prompt | 264 B | 14644 · 38916 · 14644 · **14644** |
| C5 | system prompt | 431 B | 11824 · 38975 · 14703 · **14703** |

The bolded turns are all **after** two or three auto-compactions.

```
no doctrine in the prefix                  14548
264-byte doctrine file    14644 − 14548 =     96 tokens   (264 / 96  = 2.75 bytes/token)
431-byte doctrine file    14703 − 14548 =    155 tokens   (431 / 155 = 2.78 bytes/token)
difference of the two     14703 − 14644 =     59 tokens   (167 / 59  = 2.83 bytes/token)
```

Three independent byte-per-token ratios agreeing to within 3 % is the delta being the doctrine
file's own text and nothing else. **The prefix still carries it after compaction** — had
compaction dropped the system prompt, C1/C3 would have fallen to 14548 and they did not. And
the priming-turn cells never raise the prefix at all: their doctrine is conversation, which is
exactly why its survival depends on a summarizer's judgment.

**So the honest statement of the difference is: both channels survived every compaction thrown
at them, and only one of them survives by construction.** The system prompt is a parameter
re-sent on every request; the priming turn is text a model chose to carry forward, three times
out of three, at `n=1` per cell.

### Q1.6 Limits of this answer

- `n=1` per cell. Model behavior under compaction is judgment, not a guarantee, and the
  priming-turn result especially should not be read as one.
- The conversations are 4–5 turns with ~15k-token filler. A real CEO conversation is longer and
  more varied, and a summary that faithfully carries six invented facts out of a 40k-token
  conversation may not carry them out of a 900k-token one. **What survived here is a small
  doctrine in a short conversation.**
- `unverified:` whether the doctrine survives when the summary is under real pressure — many
  turns, real work, competing content. What would settle it: the same two cells driven over a
  long session at the stock threshold, which is the ~987k-token run named in Q1.1.
- The harness denies every tool (Sage's deliberate deviation, kept); the app allows every tool.
  No cell asked for one — `tools_denied=[]` in all 33 turns.

---

## Q2 — Where the auto-memory store lands on a customer install

One driven turn per cell, `memory_paths.auto` read off the `system/init` frame. **On 2.1.263
that frame arrives with the first turn, not with the handshake reply** — Sage's harness reads it
at handshake and raises `AttributeError` on `None`; the fix is marked in `drive_asp.py`.

| cell | working directory | in a git repo? | `memory_paths.auto` |
|---|---|---|---|
| M1 | `<scratch>/customer-home/.claude/richos-engine` | no | `…/projects/-private-tmp-…-q14-customer-home--claude-richos-engine/memory/` |
| M2 | …`/richos-engine/scripts` | no | `…/projects/-private-tmp-…-q14-customer-home--claude-richos-engine-scripts/memory/` |
| M3 | `/Users/alex/ab/richos-wt/echo-opus-q14/engine` | yes (a worktree) | `…/projects/-Users-alex-ab-richos/memory/` |
| M4 | `<scratch>/dotfiles-home/.claude/richos-engine` | yes (**the home dir is the repo**) | `…/projects/-private-tmp-…-q14-dotfiles-home/memory/` |

```
$ git -C "<scratch>/customer-home/.claude/richos-engine" rev-parse --show-toplevel
fatal: not a git repository (or any of the parent directories): .git
$ git -C "<scratch>/dotfiles-home" rev-parse --show-toplevel
<scratch>/dotfiles-home
```

**The rule, stated from the four cells:** the slug is the **repository root if there is one, and
the working directory itself if there is not** — path separators become dashes and a leading dot
becomes an extra dash (`.claude` → `--claude`).

**What that means for the question Sage asked** — *does the customer's engine share this store
with anything else on their machine?*

- **Ordinary install, `~/.claude/richos-engine`, home not in git: no.** M1/M2 show each
  directory keys to itself, so the only other thing that could share it is another Claude Code
  session started with that exact directory as its working directory. Nothing does that but
  RichOS.
- **Customer keeps their dotfiles in git — a common practice: yes, and widely.** M4 is the
  measurement: the store keys to the **home repository's root**, so RichOS's inner Rich and
  *every* Claude Code session the customer runs anywhere under `$HOME` read and write one file.
  That is a sharper version of the finding Sage recorded for this machine's worktrees, and it is
  on a customer's machine rather than a developer's.
- M3 re-derives Sage's A4 (his cells H4/H5) from a **third** worktree at 2.1.263: this
  worktree's `engine/` resolves to the same single `-Users-alex-ab-richos` store his two did.

**Derived, not measured:** applying the rule to the real customer path
`~/.claude/richos-engine` gives `~/.claude/projects/-Users-<user>--claude-richos-engine/memory/`.
It was not driven with that exact working directory because on this machine that path is a
symlink into the repository (`ls -ld ~/.claude/richos-engine` → `-> /Users/alex/ab/richos/engine`),
so a run there would measure the repository case, not the customer case. M1 uses the same
directory shape outside any repository, which is the customer case.

This does not change §6.3's recommendation. It changes how confidently the record can say the
customer store is private: it is private **unless the customer's home is a repository**, and
RichOS cannot detect that from inside the doctrine file.

---

## Q3 — Does anything write to the shared richos memory store?

**No. Nothing ever has.** Not raised as an escalation, because the condition Sage set —
*"if it does, that is a finding about this development machine that outranks everything else"* —
is not met.

**The historical evidence is stronger than the watch, and it is one command.** A directory's
mtime changes when an entry is added or removed, so an mtime still equal to birth time means no
entry has ever existed:

```
$ stat -f 'name=%N%nbirth=%SB%nmtime=%Sm%nctime=%Sc%nlinks=%l' -t '%Y-%m-%d %H:%M:%S' \
       ~/.claude/projects/-Users-alex-ab-richos/memory \
       ~/.claude/projects/-Users-alex-ab-femcboost/memory
name=/Users/alex/.claude/projects/-Users-alex-ab-richos/memory
birth=2026-08-24 10:50:58
mtime=2026-08-24 10:50:58
ctime=2026-08-24 10:50:58
links=2
name=/Users/alex/.claude/projects/-Users-alex-ab-femcboost/memory
birth=2026-03-25 08:44:42
mtime=2026-09-06 09:31:55
ctime=2026-09-06 09:31:55
links=237
```

**That is what makes the null informative.** The same mechanism, on the same machine, on the
same day, wrote to another store at 09:31:55 and has accumulated 235 files there. It is not
that auto-memory does not write; it is that it has never written *here*, in the 13 days since
the directory was created.

Machine-wide, 4 of 153 memory stores hold anything at all:

```
$ python3 -c 'import os,glob,time
base=os.path.expanduser("~/.claude/projects"); rows=[]
for d in glob.glob(base+"/*/memory"):
    fs=[os.path.join(d,f) for f in os.listdir(d)]; fs=[f for f in fs if os.path.isfile(f)]
    if fs: rows.append((max(os.path.getmtime(f) for f in fs), len(fs), os.path.basename(os.path.dirname(d))))
rows.sort(reverse=True)
print("non-empty:", len(rows), "of", len(glob.glob(base+"/*/memory")))
[print(time.strftime("%Y-%m-%d %H:%M",time.localtime(n)), "%4d files"%c, s) for n,c,s in rows]'
non-empty: 4 of 153
2026-09-06 09:31   235 files  -Users-alex-ab-femcboost
2026-08-26 18:08    66 files  -Users-alex-ab-prospects
2026-08-13 06:03    45 files  -Users-alex-ab-deeply
2026-04-19 15:06     2 files  -Users-alex-ab-clipboard-sanitizer
```

**The live watch.** `watch_memory.py` sampled both the richos store and the femcboost store
every 20 s from **10:34:22 to 11:08:31** (34 min 9 s) — `git -C /Users/alex/ab/richos worktree
list | grep -c "richos-wt/"` → `18` teammate worktrees of this repository present while it ran.
**No change to either store**, logged in `raw/q3-memory-watch.tsv` as a `BASELINE` and a `FINAL`
with nothing between: `richos 0 files` at both ends, `femcboost 235 files` at both ends.

**The in-window control was silent, so the window proves less than the mtime does, and that is
said rather than glossed.** The femcboost store was included precisely so that a write somewhere
would show the watcher working; none happened in those 34 minutes. What *was* proved is the
watcher's detection, deliberately, against a scratch canary created, modified and deleted —
caught in all three states (`raw/q3-watcher-selftest.tsv`):

```
2026-09-06T11:00:54  scratch  BASELINE  0   []
2026-09-06T11:01:03  scratch  CHANGE    added=['MEMORY.md']
2026-09-06T11:01:12  scratch  CHANGE    changed=['MEMORY.md']
2026-09-06T11:01:21  scratch  CHANGE    removed=['MEMORY.md']
```

**One scoping caveat, stated because it weakens the live watch specifically.** The store a
Claude Code session writes to is fixed by that session's own repository, and every teammate in
this session — including the ones working inside richos worktrees — belongs to a session rooted
in femcboost. So this window could not have produced a richos write even in principle; the
femcboost store is where those writes land. The load-bearing evidence for Q3 is the mtime, not
the window. `unverified:` what a session started directly in `~/ab/richos` does. What would
settle it: run one and re-read the mtime.

**A third witness fell out of the Q1 cells at no extra cost.** All six Q1 cells — **26 turns and
all 14 compactions** — ran in one working directory whose store was created fresh for this
measurement. When it was removed, `find <dir> -type f` returned **nothing**: 26 driven turns,
including 14 summarize-and-replace events, wrote not one memory file. The same held for the
three other stores the cells created. Auto-memory is *loaded* on this path (`echo-opus-sn1`'s
cells G1/G2); nothing observed here *writes* to it unprompted.

**What the answer does not say.** The store is empty, not closed. Two facts decide what it
would take to fill it:

```
$ sed -n '279,281p' app/crates/richos-core/src/native.rs
pub fn decide_permission(request: &Value) -> PermissionDecision {
    PermissionDecision::Allow { updated_input: request.get("input").cloned().unwrap_or_else(|| json!({})) }
}
```

and, from the `system/init` frame of cell M3, the child's own tool list under the app's
production flags — verbatim, 29 tools:

```
['Task', 'AskUserQuestion', 'Bash', 'CronCreate', 'CronDelete', 'CronList', 'DesignSync',
 'Edit', 'EnterPlanMode', 'EnterWorktree', 'ExitPlanMode', 'ExitWorktree', 'ListAgents',
 'Monitor', 'NotebookEdit', 'PushNotification', 'Read', 'RemoteTrigger', 'ReportFindings',
 'ScheduleWakeup', 'SendMessage', 'Skill', 'TaskOutput', 'TaskStop', 'ToolSearch', 'WebFetch',
 'WebSearch', 'Workflow', 'Write']
```

So the inner Rich has `Write` and `Bash`, every tool request is allowed unconditionally, and the
path it would write to is announced to it in its own init frame. **The store is not merely
readable by the product — it is writable by the product**, and today nothing watches it. That
is a fact for §6.3 to answer, not a new escalation.

---

## Q4 — Can a CI runner authenticate?

**By mechanism, yes.** Two paths exist in 2.1.263, neither of which is a settings source:

```
$ ~/.local/bin/claude --help | grep -n -E "setup-token|API key"
56:                                        (API key users only)
293:  setup-token                           Set up a long-lived authentication token
$ strings -a ~/.local/share/claude/versions/2.1.263 | grep -c CLAUDE_CODE_OAUTH_TOKEN
129
```

**Measured, three cells, identical argv and working directory, differing only in the child's
environment.** The environment is built inside the harness (`--empty-env` / `--child-env`) rather
than with `env -i HOME=…` in the shell, because rewriting this session's `HOME` is refused by the
worktree-isolation guard, correctly.

| cell | child environment | reply | `result.subtype` |
|---|---|---|---|
| R0 | inherited (control) | `ok` | `success` |
| R1 | `PATH`, `HOME=<fresh>`, `CI=true`, `GITHUB_ACTIONS=true` | `Not logged in · Please run /login` | **`success`** |
| R2 | R1 plus `CLAUDE_CODE_OAUTH_TOKEN=not-a-real-token-q14` | `Failed to authenticate. API Error: 401 Invalid bearer token` | **`success`** |

R1 → R2 is the positive control that matters: the two messages are **different**, so the
variable was read and used rather than ignored. A valid token from `claude setup-token`, held as
a repository secret, is therefore the path. The credential on this machine is not a file a
runner could ever inherit — it is a login-keychain item (`security find-generic-password -s
"Claude Code-credentials"` → `keychain: /Users/alex/Library/Keychains/login.keychain-db`,
created 2026-03-26), and `~/.claude/.credentials.json` does not exist. R1 shows a fresh `HOME`
already fails on this Mac, which is why R1 is a fair stand-in for a runner rather than a
weaker one.

**Three consequences for how §7.3 must be written, all of them measured above:**

1. **An unauthenticated run reports `subtype: "success"` with `stop_reason: "stop_sequence"`
   and zero token usage.** A sentinel asserting "the run succeeded" reports green having
   verified nothing — the exact failure `setup.rs:735` refuses. The sentinel must assert the
   **token**, and it must recognize `Not logged in` and `Invalid bearer token` and say *not
   authenticated* rather than *the flag stopped working*, because the two are indistinguishable
   from the token's absence alone. The test to copy is
   `app/crates/richos-core/tests/setup.rs:735`
   (`the_real_claude_binary_on_this_machine_satisfies_the_requirement`) — Sage cites it as
   `setup.rs:735`, and it is under `tests/`, not `src/`.
2. **The runner may not run the same model.** `grep -h "model =" raw/cellR{0,1,2}*.err` →
   `claude-opus-5[1m]`, `claude-opus-5[1m]`, **`claude-sonnet-5`** — the one cell that presented
   a credential of its own got a different model. Model selection follows the account, so a
   runner's green proves the flag under whatever model that runner's token resolves to, not
   under the model the release ships against. The sentinel must therefore record the model as
   well as the binary version, exactly as §5.4 says to record the version.
3. **The repository's workflows carry all three triggers**, so where the sentinel is attached
   decides whether it can authenticate at all:

   ```
   $ grep -n "pull_request\|workflow_dispatch\|^  push:" .github/workflows/*.yml
   app-spine-ci.yml:88:  push:      :101:  pull_request:   :109:  workflow_dispatch:
   app-voice-ci.yml:184:  push:     :196:  pull_request:   :205:  workflow_dispatch:
   ui-suite-ci.yml:147:  push:      :168:  pull_request:   :180:  workflow_dispatch:
   windows-companion-ci.yml:70: push :74: pull_request     :80:  workflow_dispatch:
   engine-self-verify.yml:134:  workflow_dispatch:
   packaging-ci.yml:129:  workflow_dispatch:
   vouch-pr.yml:76:  pull_request_target:
   ```

   A repository secret reaches `push` and `workflow_dispatch` runs and **not** a `pull_request`
   run from a fork, which is most of what a public repository receives. So a secret-gated
   sentinel on `app-spine-ci` would authenticate on push and skip on outside contributions —
   and the skip must read as *not verified*. Only `vouch-pr.yml:138` uses a secret today, and it
   is the built-in `GITHUB_TOKEN`. The `RICHOS_VOICE_LIVE_AUDIO` shape in `app-voice-ci.yml` is the right
   precedent: gate it, and let its absence mean *not verified* rather than *verified*.

`unverified:` that a real runner authenticates end-to-end. No live credential was minted —
`claude setup-token` produces a long-lived credential, and creating one to prove a point, on a
machine whose operator is asleep, is not a measurement anyone asked for. What would settle it:
one `workflow_dispatch` run with `CLAUDE_CODE_OAUTH_TOKEN` set from a repository secret,
asserting the sentinel token. `unverified:` also the subscription-quota cost of running it on
every release; that is a CEO question, not a measurement.

**So §7.4's fallback position holds, with one correction.** Sage wrote that the honest
consequence is that the sentinel runs on the release machine. It can also run on a runner, if
the CEO is willing to place a subscription token in a repository secret. That is a decision with
a price, and it is his.

---

## State on this machine is exactly as it was found

- **Nothing was written to `~/.claude/projects/-Users-alex-ab-richos/memory/`.** Verified before
  (`find … | wc -l` → 0, at 10:34) and after (below). Cell M3 ran with a working directory that
  resolves to that store and left it untouched.
- **Four project directories were created by the cells** — one per distinct working directory,
  each holding nothing but an empty `memory/` — and all four were removed. The before/after
  listing of `~/.claude/projects` (164 entries) is byte-identical:

  ```
  $ ls ~/.claude/projects > projects-before.txt          # before any cell
  … cells run …
  $ find <each of the four> -type f          # nothing: they held no files at all
  $ rm -rf <each of the four>
  $ ls ~/.claude/projects > projects-final.txt
  $ diff projects-before.txt projects-final.txt ; echo $?
  0
  ```
- The scratch tree under
  `/private/tmp/claude-501/-Users-alex-ab-femcboost/16b21750-…/scratchpad/q14/` holds the
  fixtures' working copies, the filler, the simulated customer homes and the runner `HOME`.
  Nothing outside it and outside this record was written.
- `engine/CLAUDE.md` was never created; no file in `engine/**`, `app/**`, `app/ui/**` or any
  other agent's territory was touched. The only files this task writes are in this directory.
- Nothing opened an audio device: `claude --print` produces none, the app was never launched,
  and every cell ran with `--setting-sources ''`, which loads no hooks.

**Redaction.** Two classes of operator identity were removed from `raw/*.jsonl` by `redact.py`,
which fails non-zero rather than exiting quietly if either survives: the `initialize` reply's
`account` object (email, organization, subscription type — `echo-opus-sn1`'s precedent), and
every email-shaped string in frame text, which exists because the **post-compaction summary
quotes the `system-reminder` naming the operator's email address**. Verified over the whole
record:

```
$ grep -rlo -E "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}" .
$ echo $?
1
```

---

## Re-running any of this

```
cd docs/verification/inner-doctrine-opens-2026-09-06

# Q2 — one turn, read memory_paths off the init frame
python3 drive_asp.py --cwd <DIR> --prompt "Reply with the single word: ok" --out raw/x.jsonl

# Q1 — the doctrine-through-compaction pair (C5/C6). ~5 minutes each.
python3 make_filler.py --seed 1 --kb 48 --out <scratch>/f1.txt      # seeds 1..3
CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=2 python3 drive_asp.py --cwd <DIR> --timeout 600 \
  --asp-flag=--append-system-prompt-file --asp "$PWD/fixtures/doctrine-six-q14.md" \
  --prompt-file <scratch>/f1.txt --prompt-file <scratch>/f2.txt --prompt-file <scratch>/f3.txt \
  --prompt "<the six-fact sentinel question>" --out raw/cellC5-six-facts-system-prompt.jsonl
CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=2 python3 drive_asp.py --cwd <DIR> --timeout 600 \
  --prompt-file "$PWD/fixtures/priming-six-q14.txt" \
  --prompt-file <scratch>/f1.txt --prompt-file <scratch>/f2.txt --prompt-file <scratch>/f3.txt \
  --prompt "<the six-fact sentinel question>" --out raw/cellC6-six-facts-priming-turn.jsonl

# Q4 — the runner simulation and its control
python3 drive_asp.py --cwd <DIR> --prompt "Reply with the single word: ok" --out raw/r0.jsonl
python3 drive_asp.py --cwd <DIR> --empty-env --child-env "HOME=<fresh>" --child-env CI=true \
  --child-env GITHUB_ACTIONS=true --prompt "Reply with the single word: ok" --out raw/r1.jsonl

# Q3 — the watch and its self-test
python3 watch_memory.py --minutes 150 --interval 20 --out raw/q3-memory-watch.tsv
python3 watch_memory.py --minutes 0.6 --interval 3 --target "scratch=<dir>" --out raw/self.tsv

# always, before committing
python3 redact.py raw/*.jsonl
```

The sentinel question used throughout, verbatim:

> Answer in two short lines and use no tools: (1) the project status word, (2) the project build
> command. If either is not defined in your instructions, write 'unknown' for it.

and its six-fact form:

> Answer with six short numbered lines and use no tools: (1) the project status word, (2) the
> project build command, (3) the project deploy command, (4) the release port number, (5) the
> project mascot, (6) the operation code name. Write 'unknown' for any that is not defined in
> your instructions.

**The version this was measured against is a fact about today, not about the world.** `claude`
self-updated three times on this machine in three days (`2.1.260` 4 Sep, `2.1.261` 4 Sep,
`2.1.263` 6 Sep, all present in `~/.local/share/claude/versions/`). Every answer above is
pinned to 2.1.263.
