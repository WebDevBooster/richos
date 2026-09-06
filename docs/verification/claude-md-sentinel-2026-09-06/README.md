# Does the Claude Code process that RichOS drives load a `CLAUDE.md`?

**Answer, in one line: NO — not as the app spawns it today.** With
`--setting-sources ''` (the value in `child_args`, `app/crates/richos-core/src/native.rs:325-341`, the flag pair at `:332-333`)
the child loads no `CLAUDE.md` from its working directory or from any ancestor of it. Add
`project` to that flag and the same file, in the same directory, is loaded and obeyed.

Measured 2026-09-06 against `claude` **2.1.263**, nine driven turns (seven on the
`CLAUDE.md` question, two on auto-memory), raw stream-json in
`raw/`. This settles **M0** in `docs/plans/richos-onboarding-2026-09-06.md` §5, which was
marked `unverified` there and correctly refused to be asserted from source.

**A second finding fell out of the same experiment and matters just as much: the child DOES
load auto-memory** from `~/.claude/projects/<cwd-slug>/memory/MEMORY.md` under the app's
current flags, unchanged (cells G1/G2 below). So a file-based instruction channel into the
app's inner Rich already exists and is already open. Nothing here acts on that — it is named
so the fix is designed with it on the table.

---

## The three things asked, and what was established

**1. Which path would the inner process read a `CLAUDE.md` from? — `<engine dir>/CLAUDE.md`,
and on this machine that is `/Users/alex/ab/richos/engine/CLAUDE.md`.** Plus any ancestor of
it (cell F proves ancestor discovery works), i.e. `/Users/alex/ab/richos/CLAUDE.md`,
`/Users/alex/ab/CLAUDE.md`, `/Users/alex/CLAUDE.md` — **none of which exist today**, verified:

```
$ ls -l /Users/alex/ab/richos/engine/CLAUDE.md /Users/alex/ab/richos/CLAUDE.md \
        /Users/alex/ab/CLAUDE.md /Users/alex/.claude/CLAUDE.md
ls: ...: No such file or directory        (all four)
```

The working directory is the engine directory —
`NativeCognition::start(claude_bin, engine_cwd)`, `native.rs:1414-1415`, `Command::current_dir(cwd)`
at `native.rs:714`. On this machine the engine-resolution pointer is a symlink:

```
$ ls -ld ~/.claude/richos-engine
lrwxr-xr-x  1 alex  staff  28  6 Sep 03:39 /Users/alex/.claude/richos-engine -> /Users/alex/ab/richos/engine
```

so `engine.rs` candidate 6 (the install pointer) and candidates 4/5 (the repo, found from the
executable or the working directory) all name the same absolute directory.

`unverified:` I did not **execute** `app/src-tauri/src/engine.rs::resolve_engine_dir` — that
needs the Tauri shell's build, which is deliberately detached from the spine. What would
settle it: `cargo test -p richos-tauri engine::`, or a boot line from a real `.app` launch.
The claim does not hinge on it: the mechanism below is governed by the flag, not by the path,
so the answer is the same wherever the engine directory turns out to be. Corroboration that a
real Claude Code process has run with exactly that working directory:
`~/.claude/projects/-Users-alex-ab-richos-engine/7900c0b3-….jsonl` carries
`"cwd": "/Users/alex/ab/richos/engine"` (version 2.1.232, 2026-08-28) — that is a transcript
from *some* session in that directory, not proof it was the app, which writes none
(`--no-session-persistence`).

**2. Did it actually read it? — No, by evidence.** Cells A and A2: the file was present in the
working directory, and neither the token nor the behavioral instruction it carried reached the
reply. Cell C: same file, same directory, same binary, same prompt, one flag value changed —
both arrived. See the table.

**3. Is `--setting-sources ''` what governs? — Yes, and specifically the absence of `project`
from it.** Five values of that one flag, everything else held constant:

| cell | `--setting-sources` | `CLAUDE.md` at | reply | read? |
|---|---|---|---|---|
| A | `''` (production) | cwd | `unknown` / `unknown` | **no** |
| A2 | `''` (repeat) | cwd | `unknown` / `unknown` | **no** |
| B | `''` (control) | *absent* | `unknown` / `unknown` | n/a |
| C | `project` | cwd | `Acknowledged.` / `BRIDLEVANE-7731` / `make thunderclap` | **yes** |
| D | *flag omitted* (default) | cwd | `Acknowledged.` / `BRIDLEVANE-7731` / `make thunderclap` | **yes** |
| E | `user` | cwd | `unknown` / `unknown` | **no** |
| F | `project` | **parent** of cwd | `Acknowledged.` / `BRIDLEVANE-7731` / `make thunderclap` | **yes** |

Cell E is the sharp one: a non-empty value is not enough. `user` alone leaves the file unread,
so it is the `project` source that carries `CLAUDE.md`, exactly as `claude --help` lines
219-220 describe the flag's three sources and nothing else in the help text mentions memory
files.

Nothing else governs it. The `system/init` frame is **byte-identical between cells A and C**
except exactly three fields — `session_id`, `uuid` and `messaging_socket_path` — 24 fields in each, none of them naming a
loaded instruction file. So this can only be measured through behavior; there is no field to
assert against, the same shape of gap `native.rs:78-88` already records for the permission
flag.

---

## The sentinel, and why it is shaped this way

`fixtures/with-claude-md/CLAUDE.md` carries three instructions:

- begin every reply with `Acknowledged.` on its own line — **a behavior**, not a phrase to
  repeat;
- the project status word is `BRIDLEVANE-7731`;
- the project build command is `make thunderclap`.

Both outcomes had to be informative, which is why the behavioral instruction is there. A null
result on the token alone would not separate *"the file was not read"* from *"the file was read
and the model declined to echo a token"*. A model that read the file and withheld the token
would still have opened with `Acknowledged.`; cells A, A2 and E open with neither. And the two
invented facts have no other source in the world — cell B, the same everything with the file
removed, answers `unknown` twice, so their appearance in C/D/F is attributable to the file and
to nothing else.

The prompt, identical in all nine runs:

> Answer in two short lines and use no tools: (1) the project status word, (2) the project
> build command. If either is not defined in your instructions, write 'unknown' for it.

`fixtures/with-claude-md/` and `fixtures/no-claude-md/` differ by exactly one file. They sit
inside a git repository (this worktree), which is the engine directory's situation; cells D and
E ran from `/private/tmp/…/nonrepo`, which is not a repository, and behaved identically — so
repository membership is not a variable here.

---

## How it was driven

`drive.py` (committed beside this file) reproduces `native.rs::child_args` verbatim and
manipulates one value:

```
--print --input-format=stream-json --output-format=stream-json --include-partial-messages
--verbose --setting-sources <VALUE> --no-session-persistence --session-id <uuid>
--permission-prompt-tool stdio
```

It performs the same `control_request{initialize}` handshake as `native.rs:833-839`
(answered in 0.518–3.047 s across the nine runs, against the 30 s `HANDSHAKE_TIMEOUT`), sends
one `{"type":"user",…}` frame in the shape of `native.rs:1218-1221`, and reads to the terminal
`result`. Every run ended `subtype = success`, `stop_reason = end_turn`. `ANTHROPIC_API_KEY` is
removed from the child's environment; every run reported `apiKeySource: "none"`.

**One deliberate deviation from the app, stated because it changes what the evidence means.**
`native.rs::decide_permission` allows every `can_use_tool`; this harness **denies**, so the
child could not read the sentinel off disk with a tool and hand it back. In practice it never
bound — every run reported `tool requests denied = []`, i.e. the child asked for no tools at
all. The route from file to reply was the binary's own context loading in every cell where the
token appeared.

The exact commands, one per cell (run from this directory):

```
python3 drive.py --cwd "$PWD/fixtures/with-claude-md" --sources ""        --prompt "<the prompt>" --out raw/cellA-empty-sources-with-claude-md.jsonl
python3 drive.py --cwd "$PWD/fixtures/with-claude-md" --sources ""        --prompt "<the prompt>" --out raw/cellA2-empty-sources-with-claude-md-repeat.jsonl
python3 drive.py --cwd "$PWD/fixtures/no-claude-md"   --sources ""        --prompt "<the prompt>" --out raw/cellB-empty-sources-no-claude-md.jsonl
python3 drive.py --cwd "$PWD/fixtures/with-claude-md" --sources "project" --prompt "<the prompt>" --out raw/cellC-project-sources-with-claude-md.jsonl
python3 drive.py --cwd "<scratch>/nonrepo"            --sources OMIT      --prompt "<the prompt>" --out raw/cellD-no-flag-nonrepo-with-claude-md.jsonl
python3 drive.py --cwd "<scratch>/nonrepo"            --sources "user"    --prompt "<the prompt>" --out raw/cellE-user-sources-nonrepo-with-claude-md.jsonl
python3 drive.py --cwd "<scratch>/parent/sub"         --sources "project" --prompt "<the prompt>" --out raw/cellF-project-sources-parent-dir-claude-md.jsonl
python3 drive.py --cwd "<scratch>/memcell"            --sources ""        --prompt "<the prompt>" --out raw/cellG1-memory-baseline.jsonl
python3 drive.py --cwd "<scratch>/memcell"            --sources ""        --prompt "<the prompt>" --out raw/cellG2-memory-sentinel-empty-sources.jsonl
```

`<scratch>` is
`/private/tmp/claude-501/-Users-alex-ab-femcboost/16b21750-131b-400e-a6b4-f9313174b201/scratchpad/sentinel`;
`<scratch>/nonrepo/CLAUDE.md` and `<scratch>/parent/CLAUDE.md` are copies of
`fixtures/with-claude-md/CLAUDE.md`. Each cell's full console output is in
`raw/<cell>.txt` and its raw frames in `raw/<cell>.jsonl`.

**One edit was made to the raw frames, and it is the only one.** The `initialize` reply
carries an `account` object with the operator's email address, organization name and
subscription type. This repository is public, so in each `.jsonl` that one object — and
nothing else — was replaced with a `REDACTED` marker naming what it held. RichOS itself
keeps nothing from it either (`native.rs:40-45`). Verified after redaction:
`grep -ro "[A-Za-z0-9._%+-]\+@[A-Za-z0-9.-]\+\.[A-Za-z]\{2,\}" .` returns nothing.

---

## The second channel: auto-memory IS loaded, under the current flags

The `system/init` frame announces `memory_paths.auto` in every cell, including under
`--setting-sources ''`. That is a path, not proof of loading, so it was measured the same way.

| cell | cwd | memory file | `--setting-sources` | reply |
|---|---|---|---|---|
| G1 | `<scratch>/memcell` | *absent* | `''` | `Status word: unknown` / `Build command: unknown` |
| G2 | `<scratch>/memcell` | present | `''` | `MARLINSPIKE-4402` / `` `make gundeck` `` |

G1 read the announced path off its own init frame:

```
MEMORY PATH: /Users/alex/.claude/projects/-private-tmp-claude-501--Users-alex-ab-femcboost-16b21750-…-scratchpad-sentinel-memcell/memory/
```

A second sentinel with different tokens was written to `MEMORY.md` there and G2 ran with the
identical production flag value. **It came back with both invented facts.** So under the flags
the app ships today, `~/.claude/projects/<cwd-slug>/memory/MEMORY.md` reaches the inner
process, while `<cwd>/CLAUDE.md` does not.

`unverified:` whether that memory path is stable enough to build on — the slug is derived from
the working directory, and in cells A/C it resolved to
`/Users/alex/.claude/projects/-Users-alex-ab-richos/memory/` for a working directory of
`/Users/alex/ab/richos-wt/echo-opus-sn1/docs/verification/…`, which is neither the working
directory's own slug nor an obvious function of it. What would settle it: drive one turn with
cwd set to the real engine directory and read `memory_paths.auto` off the init frame.

---

## State on this machine is exactly as it was found

- **`engine/CLAUDE.md` was never created.** Verified before and after:
  `ls /Users/alex/ab/richos/engine/CLAUDE.md` → `No such file or directory`, both times. The
  sentinel lived in this record's `fixtures/` and in scratch, never in the engine directory.
- The scratch memory directory created for cells G1/G2,
  `~/.claude/projects/-private-tmp-…-scratchpad-sentinel-memcell/`, held exactly one file
  (`memory/MEMORY.md`, listed with `find` before removal) and was removed;
  `ls -d` on it now returns `No such file or directory`. It did not exist before this
  measurement and it does not exist after.
- No `richos` working tree outside this worktree was written to. Nothing in `engine/**`,
  `app/ui/tests/**` or any other agent's territory was touched.
- Nothing in this measurement opens an audio device. `claude --print` produces no sound, the
  app was never launched, and no cell loaded a hook that plays one (the engine's `hooks.json`
  registers no audio command; the only `osascript` string in the engine is inside
  `scripts/lib/interactive-prompt.py`, which *detects* interactive commands).

---

## What this implies for the fix — named, not built

The brief said to stop here, and this stops here. Four mechanisms could carry an onboarding
instruction to the app's inner Rich; the measurement says which are open:

1. **Add `project` to `child_args`.** Smallest change, and it is a design decision rather than
   a mechanical fix: `native.rs:16` and `:316-317` state the intent that *"the operator's
   user/project/local settings stay out"*, so flipping it partially reverses a stated position
   and belongs to Sage or the CEO, not to whoever writes the patch. Scope note, measured:
   `project` would additionally load `<engine>/.claude/settings.json`, which **does not exist**
   (`ls` → absent; the engine's `.claude/` holds `settings.local.json`, a `local`-source file
   this value would not load). Cell D also shows the wider default loads the operator's
   plugins — `plugins` is `[]` in cells A and C and non-empty in D/E — so `project` alone
   keeps plugins out.
2. **`--append-system-prompt` / `--system-prompt`** — present in 2.1.263's help (lines 25,
   225). Carries an instruction without opening any settings source at all.
3. **The re-prime payload.** `reprime.rs` already injects an unrendered priming turn on every
   `session/new`, and `reprime.rs:313-316` already carries the identity assertion *because* no
   `CLAUDE.md` is provisioned. That comment is now confirmed correct, and for a stronger reason
   than it states: the file would not be read even if it existed.
4. **Auto-memory**, per the section above — already open, no flag change.

And the prerequisite that survives all four: under option 1 the file still has to exist. That
half of the chain is `docs/plans/richos-onboarding-2026-09-06.md` §4 rows 3 and M2 (the
provisioning script with no caller), which this measurement neither re-derived nor disturbed.
