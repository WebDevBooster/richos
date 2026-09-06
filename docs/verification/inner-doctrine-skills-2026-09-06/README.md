# Do skills reach the inner Rich? — measured, then built, then measured again

**Date:** 2026-09-06
**Author:** Echo (Rust & Tauri desktop engineer)
**Basis:** branch `echo-opus-dr1`. `claude` **2.1.263**
(`/Users/alex/.local/share/claude/versions/2.1.263`), child-reported model `claude-opus-5[1m]`.
**Companion record:** `../inner-doctrine-live-2026-09-06/` — the system-prompt half.

**No sound was produced by this machine and the RichOS app was never launched.** Every cell is
`claude --print` over stdio, which opens no audio device.

---

## The answer in four lines

1. **A project `.claude/skills/` does NOT reach a child started with `--setting-sources ''`**
   (K0), and the positive control proves that is why (K1).
2. **`--plugin-dir <path>` DOES** (K2), and the model invokes what it finds there (K3). It is
   the same shape as `--append-system-prompt-file`: an explicit flag naming a directory RichOS
   wrote and owns, opening no settings source.
3. **A missing `--plugin-dir` is SILENT** (K4) — exit 0, clean handshake, `plugins: []`, an
   ordinary turn. That is the quiet degradation this whole evening was about, and it is the
   reason `skills.rs` and `preflight` exist in the shape they do.
4. **Built, and proven end to end through the production vector** (K5): the skill loads, the
   model invokes it, and it survives two auto-compactions (K9). **What it did NOT do is improve
   correctness over the doctrine's one-line clause on the two hardest prompts I could construct
   (K6, K7/K8) — and on one of them it was worse.** §5 states that plainly.

---

## 1. Why the engine's 28 skills never reached it

The engine ships its skills inside a plugin (`engine/.claude-plugin/plugin.json`), and that
plugin is registered in `~/.claude/settings.json` — a **user** settings file. `child_args`
passes `--setting-sources ''`, which drops user, project and local settings alike; it is the
same flag that stops `CLAUDE.md` loading. So the orchestrator has 28 skills and the inner Rich
had none, from one cause.

A customer has no `~/.claude/settings.json` of ours in any case, so restoring it that way would
have been a fix that worked on exactly one machine.

---

## 2. The discriminator, and why a null here means something

The `system/init` frame carries a **`skills`** array and a **`plugins`** array. So *"was it
discovered"* is a fact on the wire, not an inference from whether the model happened to use it —
which is what the brief asked for: a null that distinguishes "never found" from "found and not
invoked". Every cell below reads them off the frame.

`drive_skill.py` is `../inner-doctrine-opens-2026-09-06/drive_asp.py` with three marked
additions: `--extra-arg` (so `--plugin-dir` is the manipulated variable), `--sources` (so the
control can open a settings source), and `--allow-tool` — because a skill is invoked THROUGH the
`Skill` tool, and a harness that denies every tool cannot tell "never found" from "found, and
the harness refused the only way to reach it". `native.rs::decide_permission` allows everything
in production, so allowing `Skill` is the closer reproduction; every other tool stays denied.

| cell | delivery | `--setting-sources` | in `init.skills`? |
|---|---|---|---|
| **K0** | `<cwd>/.claude/skills/rig-status/` | `''` (production) | **no** |
| **K1** | the same directory, unchanged | `project` | **yes**, first in the list |
| **K2** | `--plugin-dir <path>` | `''` (production) | **yes**, as `rig-probe:rig-status` |
| **K3** | the same, and the question asked | `''` | **invoked** |
| **K4** | `--plugin-dir <path that is not there>` | `''` | **no — and silently** |

K1 is what makes K0 evidence rather than an absence: the same directory, the same skill file,
one flag changed, and it appears. K2's frame, verbatim:

```
[drive] init.plugins = [{"name": "rig-probe", "path": "/private/tmp/.../plug",
                         "source": "rig-probe@inline", "version": "1.0.0"}]
```

K3's invocation, off the wire rather than inferred from the prose:

```
tool_use   | "Skill" | {"skill": "rig-probe:rig-status"}
tool_result|         | "Launching skill: rig-probe:rig-status"
```

---

## 3. K4 IS THE FINDING THAT SHAPED THE CODE

`--append-system-prompt-file` gave the loud failure for free: a missing file is
`Error: Append system prompt file not found`, exit 1, zero bytes of stdout. **`--plugin-dir`
does not.** K4, verbatim:

```
[drive] argv = [... "--plugin-dir", "/private/tmp/.../definitely-not-there"]
[drive] init.skills  = [17 built-in skills, and nothing of ours]
[drive] init.plugins = []
REPLY: ok
[subtype=success stop_reason=end_turn tools_denied=[] compactions=0]
EXIT=0
```

Everything about that launch reads healthy. So the loudness is built rather than inherited, in
**two layers**, because one is not enough:

- **Before the spawn.** `skills::verify_present` checks the manifest and every `SKILL.md` this
  build declares; `native.rs::preflight` turns any gap into `NativeError::SkillsMissing` naming
  the file. That catches deleted, emptied, and not-a-file.
- **On the wire.** A directory that exists and that the BINARY declines would still be silent —
  a schema this version does not accept, a name collision, a self-update. So the reader thread
  reads `system/init.plugins` and records `skills::SkillsVerdict`, three states, and shouts on
  `Rejected`. **This is a mitigation `--permission-prompt-tool` cannot have**: `native.rs`'s
  module doc records that the initialize reply carries no field naming the permission prompt
  tool, so there is nothing to assert against. Here the field exists, so it is asserted against.

`native_failure_modes` case 7 is that path executed: 18 checks, 0 failed
(`raw/native-failure-modes-with-skills.txt`).

---

## 4. The production vector, end to end — K5

The argv the app actually speaks, printed by the harness:

```
--print --input-format=stream-json --output-format=stream-json --include-partial-messages
--verbose --setting-sources '' --no-session-persistence --session-id <uuid>
--permission-prompt-tool stdio
--append-system-prompt-file /Users/alex/Library/Application Support/com.richos.app/inner-doctrine.md
--plugin-dir                /Users/alex/Library/Application Support/com.richos.app/rich-skills
```

```
[drive] init.skills  = [..., "rich-skills:american-english", ...]
[drive] init.plugins = [{"name":"rich-skills",
                         "path":"/Users/alex/Library/Application Support/com.richos.app/rich-skills",
                         "source":"rich-skills@inline","version":"1.0.0"}]
tool_use | "Skill" | {"skill": "rich-skills:american-english", ...}
```

**Prompt** (chosen to put both halves of `ceo-decisions.md` §13 under load at once — the CEO's
own words are British and the reader is a British supplier):

> Draft two sentences I can email to a British supplier: our Licence-Summary.pdf and the
> colour_mode_authorised setting are both signed off, and we have organised the travelling
> schedule.

**Reply:**

> Both Licence-Summary.pdf and the colour_mode_authorised setting have been signed off on our
> side, so you're clear to proceed on both. We've also organized the traveling schedule and can
> share it as soon as you'd like.

The file name and the identifier came back **verbatim**; the CEO's own British prose was
rewritten. That is §13's line, drawn correctly, on the hardest prompt available.

---

## 5. WHAT THE SKILL DID NOT DO, which is the part worth reading

The brief asked me to prove the skill "changes behavior", with the drift observation as the
before case. It loads and it is invoked — §4 shows both on the wire. **But the doctrine's
one-line clause, shipped earlier on this branch, already gets these prompts right on its own,
and on one of them the skill made the answer worse.** Two controls, same binary, same minute,
one variable: `--plugin-dir` present or absent.

**K6 — the K5 prompt, doctrine only, no skill:**

> Both Licence-Summary.pdf and the colour_mode_authorised setting have been signed off on our
> end. We have also organized the traveling schedule, so let us know if anything on your side
> still needs attention.
>
> The file name and the setting name are left exactly as they are — they're identifiers, not
> prose. The rest is in our own house style.

Same spelling result. **The difference is the last paragraph**, which explains the rule to the
CEO — something the doctrine's register clause and the skill's own "What not to do" section both
forbid. K5, with the skill, did not add it.

**K7/K8 — a quotation, which is §13's subtlest exclusion.** Both were asked to write a file note
including a supplier's British sentence verbatim. **Both preserved the quotation exactly and
both wrote American prose around it.** And this time it is the SKILL cell that narrates:

> …The British spellings inside the quotation are theirs and I've left them as they wrote them.

**So, stated without dressing:** the mechanism is proven; the skill's marginal value over the
one-line clause is **not** proven on these prompts, and `n=1` per cell. A longer, worked
instruction did not buy compliance with its own last paragraph. The narration is a real residual
— four cells across the two records now end with a sentence explaining the machinery to the CEO
(`../inner-doctrine-live-2026-09-06/` L7, and K6, K8, K9 here) — and no wording at this layer
converts a preference into an enforcement.

**What is nevertheless worth having, and it is not nothing:** the CHANNEL. It cost the doctrine
file nothing per turn to gain a 3.2 KB rule with a nine-row table and five worked exclusions,
loaded only when writing matters. The next skill does not have to argue for a mechanism.

---

## 6. Compaction — K9

Production vector, three ~49 KB filler turns, then the sentence. Two `trigger: "auto"`
compactions fired:

| # | trigger | pre_tokens | post_tokens | cumulative_dropped | duration |
|---|---|---|---|---|---|
| 1 | `auto` | 73,980 | 15,434 | 58,546 | 66,993 ms |
| 2 | `auto` | 41,887 | 3,697 | 96,736 | 49,685 ms |

The turn after both, asked for `organised the colour catalogue and the travelling licence`, and
to name the file `Licence-Summary.pdf`:

> "We have organized the color catalog and the traveling license, and the details are attached
> as Licence-Summary.pdf."

Five British words corrected, the file name untouched, after 96,736 dropped tokens. Both halves
survive compaction.

---

## 7. What this record does NOT claim

- **Not** that the skill outperforms the doctrine's clause. §5 measured the opposite twice.
- **Not** that a skill will be invoked when it should be. The model decides; the description is
  a bid, not a trigger.
- **Not** that `--plugin-dir` will keep working. It is documented, unlike the other two flags,
  but the binary self-updates; the release gate carries a version for that reason.
- **Not** that the other 27 engine skills should ship. Most are orchestration mechanics for a
  developer team and are wrong instruction for a chief of staff. Candidates are named in the
  handoff; the list is the CEO's to shape.
- `memory_paths.auto` for the scratch working directory used by K0–K4 was
  `~/.claude/projects/-private-tmp-claude-501-skillprobe-proj/memory/`. That store was created
  by the runs and is removed; nothing was written to it (tools other than `Skill` were denied in
  every cell, and `tools_denied=[]` throughout means no child asked for one).

---

## Re-running any of this

```
cd docs/verification/inner-doctrine-skills-2026-09-06

# K0/K1 — the project path and its positive control
python3 drive_skill.py --cwd <a dir holding fixtures/rig-probe-project-dot-claude as .claude> \
  --prompt "Reply with the single word: ok" --out raw/cellK0-project-skill-settings-empty.jsonl
python3 drive_skill.py --cwd <the same dir> --sources project \
  --prompt "Reply with the single word: ok" --out raw/cellK1-project-skill-sources-project.jsonl

# K2/K3/K4 — the plugin path, its invocation, and its silent failure
python3 drive_skill.py --cwd <any dir> --extra-arg=--plugin-dir \
  --extra-arg=<fixtures/rig-probe-plugin> --prompt "Reply with the single word: ok" \
  --out raw/cellK2-plugin-dir-settings-empty.jsonl
python3 drive_skill.py --cwd <any dir> --extra-arg=--plugin-dir \
  --extra-arg=<fixtures/rig-probe-plugin> --allow-tool Skill \
  --prompt "<the sentinel question>" --out raw/cellK3-plugin-skill-invocation.jsonl
python3 drive_skill.py --cwd <any dir> --extra-arg=--plugin-dir --extra-arg=<a path that is not there> \
  --prompt "Reply with the single word: ok" --out raw/cellK4-plugin-dir-missing.jsonl

# K5..K8 — the production vector and its controls. The app renders both channels first:
cargo run -p richos-core --example native_failure_modes      # writes them, and proves case 7
python3 drive_skill.py --cwd <engine dir> --allow-tool Skill \
  --asp-flag=--append-system-prompt-file --asp "<app support>/inner-doctrine.md" \
  --extra-arg=--plugin-dir --extra-arg="<app support>/rich-skills" \
  --prompt "<the prompt quoted in §4>" --out raw/cellK5-production-vector-american-english.jsonl
#    K6 is the same command with the two --extra-arg pairs removed.
#    K7/K8 are the quotation prompt quoted in §5, without and with them.

# K9 — compaction. ~4 minutes.
python3 make_filler.py --seed 1 --kb 48 --out <scratch>/f1.txt      # seeds 1..3
CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=2 python3 drive_skill.py --cwd <engine dir> --timeout 600 \
  --asp-flag=--append-system-prompt-file --asp "<app support>/inner-doctrine.md" \
  --extra-arg=--plugin-dir --extra-arg="<app support>/rich-skills" --allow-tool Skill \
  --prompt-file <scratch>/f1.txt --prompt-file <scratch>/f2.txt --prompt-file <scratch>/f3.txt \
  --prompt "<the sentence quoted in §6>" --out raw/cellK9-compaction-with-skill.jsonl

# always, before committing
python3 redact.py raw/*.jsonl
```

`fixtures/rig-probe-plugin/` and `fixtures/rig-probe-project-dot-claude/` are the measurement
fixtures, byte for byte as the cells used them — one skill, deliberately trivial, carrying a
behavior and two facts with no other source in the world. `drive_asp.py`'s ancestor,
`make_filler.py` and `redact.py` are unmodified copies, so a reader can diff them.
