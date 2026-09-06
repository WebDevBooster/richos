# The central folder — how the rules follow the person, when the folders belong to different companies

> **CORRECTION, 2026-09-06, by Rich — every recommendation in this document about
> `claude-orchestration-kit` IS WRONG, AND THE ERROR IS MINE.**
>
> I briefed this design by asking "where do today's guards go?" and listing four folders that
> carry hooks, **including `claude-orchestration-kit`**. Sage answered the question I asked. The
> question was wrong.
>
> **The kit is a STANDALONE PRODUCT** — a drop-in starter-kit other people copy into their own
> repositories (`README.md`: *"Copy it into your repo, point it at your project"*). It is not one
> of the CEO's working folders, and its last commit is 2026-08-06, so it is a frozen release
> rather than live work. **Its hooks are not stale forks of the engine's; they are the thing being
> shipped.** On an adopter's machine the RichOS engine plugin does not exist at all, so deleting
> the kit's copies would not relocate protection — it would remove it, from a product, for
> everyone who ever adopts it.
>
> **So: nothing in the kit is to be retired, deleted, or consolidated.** Rows V6, 7 and the
> "delete the folder copies" line below are struck. The CEO caught this before anything was
> deleted; an agent had already been dispatched to do it and was stopped.
>
> **What survives is the same measurement pointed the other way.** The drift is real — the kit
> ships an isolation guard at 37% of the engine's current size — and that is a *product-quality*
> finding about the kit: whoever adopts it gets protections far behind what this project relies
> on. The answer to that is to bring the kit's hooks FORWARD, never to remove them, and it is a
> separate decision about a separate product.



Sage (architect) · 2026-09-06 · repo `richos`, branch `sage-opus-mr1`, from `9f433ae`

The CEO framed it in one sentence — **the rules follow the person, not the folder** — and then
asked the question that makes it hard: *"what about the fact that different repos/folders belong
to different companies/projects with their own set of workers?"*

This document answers that with three layers, names the delivery channel for each, and proves the
two channels that were open. It is design only. No application code is proposed as written here;
§6 says which parts can be built without touching `app/**` at all.

---

## Verification basis — read this before trusting anything below

Every claim about the current state carries the command that produced it, inline, so it can be
re-run rather than believed. Six things I measured tonight, and two of them corrected the premise
I was given.

| # | Claim | Command | Result |
|---|---|---|---|
| V1 | `myrichos` does not exist | `ls -d /Users/alex/ab/myrichos` | `No such file or directory`, exit 1 |
| V2 | `--settings` JSON delivers hooks even with `--setting-sources ''` | `claude -p --setting-sources '' --settings '{"hooks":{"SessionStart":[…]}}' 'Reply with the single word: pong'` | sentinel file written: `FIRED-FROM-SETTINGS-JSON`; exit 0 |
| V3 | A **blocking** guard delivered that way actually refuses | `claude -p --permission-mode acceptEdits --setting-sources '' --settings ./guard.json 'Run the bash command: echo hello…'` with a hook that prints to stderr and `exit 2` | the model reported *"The command didn't run — a PreToolUse hook … blocked it"* |
| V4 | `--append-system-prompt-file` binds | `claude -p --setting-sources '' --append-system-prompt-file ./doctrine.md 'What is the codeword? One word.'` | `BLUEHERON` |
| V5 | …and fails loudly when the file is absent | same, `--append-system-prompt-file ./no-such-file.md` | `EXIT=1`, `STDOUT BYTES=0`, `Error: Append system prompt file not found: …` |
| V6 | 13 of 13 hook scripts the kit carries have drifted from the plugin's | `shasum -a 256` of each pair, `engine/scripts/hooks/*` vs `~/ab/claude-orchestration-kit/scripts/hooks/*` | **13 DRIFTED, 0 SAME** |
| V7 | `--agents` delivers a company-scoped team under `--setting-sources ''` | `claude -p --setting-sources '' --agents '{"harbor-auditor": {…}}' 'List the subagent_type values available to your Task tool…'` | `claude, Explore, general-purpose, harbor-auditor, Plan, statusline-setup` |
| V8 | The five ECS adapters are safe to double-fire | `grep -n "dedup\|idempot\|already\|seen" femcboost/scripts/hooks/ecs-hook.sh` | `:28  # Every store write is idempotent (turn, fingerprint and scope keys)` |

**Two corrections to the numbers I was briefed with.** The brief said four folders carry hooks —
femcboost 5, `claude-orchestration-kit` 11, prospects 1, deeply 1. Measured, with
`grep -o '"command": "[^"]*"' <folder>/.claude/settings.local.json | sed 's/.*\///' | sort -u`:

- femcboost — **5 scripts**, all `ecs-*.sh`. Correct as briefed.
- `claude-orchestration-kit` — **13 scripts**, not 11.
- prospects — **0 scripts.** Its single hook entry is an inline `echo '{"…'` notice, no file.
- deeply — **1 script**, `deeply-design-brief-gate.sh`. Correct as briefed.

Neither correction changes the recommendation; both change what has to be moved, which is §3's
whole subject, so they are stated rather than quietly absorbed.

**One thing I did not settle.** `unverified:` whether the CEO wants `myrichos` at `~/myrichos` or
at `~/ab/myrichos`. He said "central folder" and named it; he did not name a parent. `~/ab` is
where his repositories live, and `myrichos` is not a repository. I design for **`~/myrichos`** below
and the choice is one line to change. What would settle it: asking him, which is a one-line
question and not worth a document.

---

## The answer, in one paragraph

**`myrichos` is the person layer made visible: one folder the CEO can see, open, move and back up,
holding everything that is true about *him* regardless of which company he is working for, plus one
subfolder per company holding what is true about that company.** It is the seat of authority because
the app reads its rules from there and from nowhere a visited folder controls. A visited folder is
an **address**: it resolves, lexically, to exactly one company through a registry the CEO wrote, and
it contributes nothing else — no doctrine, no team, no hooks. The person layer is delivered by
`--append-system-prompt-file` (V4/V5) and by the engine plugin already registered at user scope. The
company layer is delivered by two channels, because it has two halves: **company doctrine** rides
the priming turn, which the spine already re-issues on every thread switch and therefore on every
company switch; **company enforcement** rides `--settings` JSON at worker spawn, which carries
hooks and can refuse a tool call even when every settings source is switched off (V2/V3). The folder
layer has no channel, which is the point.

---

## 1. What `myrichos` is, concretely

It does not exist (V1). Three RichOS locations do exist, and the first design job is to say how
`myrichos` relates to them rather than becoming a fourth.

```
ls -la "/Users/alex/Library/Application Support/com.richos.app"
ls -la "/Users/alex/Library/Application Support/RichOS"
ls -d /Users/alex/RichOS
```

| Location | What is in it today | Source |
|---|---|---|
| `~/Library/Application Support/com.richos.app/` | `entities.json`, `config.json`, `conversation-ledger.jsonl`, `launches.json`, `navigation.json`, `machinery/`, `voice-scratch/` | `entity.rs:531` `app_config_dir`, `tauri.conf.json` identifier |
| `~/Library/Application Support/RichOS/` | `loro-root -> ~/ab/richos-hq`, `ecs/`, four `corpus.*` symlinks, two `engine.*` directories | `provision.rs:105` `app_support_richos` |
| `~/RichOS/corpus` | **absent** — `ls -d /Users/alex/RichOS` → `No such file or directory` | `provision.rs:101` `offered_corpus_dir` |

That third row is not a footnote. Four symlinks in the second directory point at it:

```
readlink "~/Library/Application Support/RichOS/corpus.RAY-101-RUN-A"
  -> /Users/alex/RichOS/corpus          TARGET MISSING (dangling)
```

**So the machine already demonstrates the failure this design has to avoid**: a per-user directory
the CEO never opens, accumulating pointers to a place that is not there. Whatever `myrichos`
becomes, it must reduce the number of places, not add one.

### 1.1 The shape

```
~/myrichos/
  README.md                  what this folder is, addressed to him, in his words
  me/
    doctrine.md              the person layer, rendered by RichOS -> --append-system-prompt-file
    doctrine.source.md       the template it is rendered from, with its source SHA
    identity.config          his name, how he is addressed, how he wants to be spoken to
  companies/
    femcboost/
      company.md             what is true about this company -> priming turn
      team/                  the agent definitions this company's workers are drawn from
      guards/                hooks THIS company imposes -> --settings fragment
      guards/settings.json   the fragment itself, one file, machine-generated from guards/
      memory/                this company's memory lane
    deeply/  prospects/  richos/  gpt-exporter/  webinar-booster/
  registry/
    entities.json            THE folder -> company mapping (today at app_config_dir)
  corpus/                    the loro corpus (today the absent ~/RichOS/corpus)
  ledger/                    the ECS event store
  inbox/                     CEO input files, dropped and picked up
```

Six company folders, not an invented list — they are the six already in his registry:

```
cat "~/Library/Application Support/com.richos.app/entities.json"
femcboost, deeply, prospects, richos, gpt-exporter, webinar-booster
```

### 1.2 What each thing is for, and why it is there rather than somewhere else

- **`me/doctrine.md`** is the file `--append-system-prompt-file` names. It is here rather than in
  `com.richos.app/` because it is the single most consequential piece of text in the product and it
  should be somewhere he can read it. It is *rendered by RichOS*, not hand-edited, for the reason
  the inner-doctrine document gives at its §3.1 — the app must not depend on a file a person edits
  and it then trusts. `doctrine.source.md` sits beside it so the rendered file's provenance is one
  `diff` away rather than a belief.
- **`me/identity.config`** is the honest destination for the two values
  `provision-claude-md.sh:107` refuses to run without — `COMPANY_NAME` and `CEO_NAME`
  (`richos-onboarding-2026-09-06.md` §1, link 4). Note that `COMPANY_NAME` is in the wrong file
  under this design and §2.3 says what happens to it.
- **`companies/<id>/company.md`** is the artifact that does not exist anywhere today. It is the
  company layer's content, and §4 proves the channel that carries it.
- **`companies/<id>/guards/`** is where a company's own enforcement lives — femcboost's five ECS
  adapters, deeply's design-brief gate. §3.
- **`registry/entities.json`** is the mapping. §2.
- **`corpus/`, `ledger/`, `inbox/`** are three things that already exist as concepts and are
  currently spread across two invisible directories and one absent one. Consolidating them is the
  part of this that is pure tidying, and it is the part I would do last.

### 1.3 The rule that keeps it from becoming the fourth place

**`myrichos` holds the ONLY copy of anything it holds. Every other location holds a POINTER to it,
never a copy.** `provision.rs` already established this pattern and already established why — the
corpus pointer is *"written on EVERY successful provision, including when the corpus went to the
offered default that the resolver would have found anyway. One mechanism covers both cases, so a
corpus the CEO put somewhere else is not a second, weaker path."*

And the dangling `corpus.RAY-*` links say what the pattern needs that it does not yet have: **a
pointer is checked at boot, and a pointer whose target is missing is a startup error, not a
fallback.** That is the same property `--append-system-prompt-file` gives for free (V5), and it
should be the house rule for every pointer RichOS writes.

---

## 2. How a folder maps to a company, and who writes the mapping

### 2.1 The mechanism exists and is already the right one

`entity.rs:440` `resolve_root` maps an absolute path to exactly one entity by **lexical path-component
containment** — not string prefix, so `/Projects/harbor-private` does not match root `/Projects/harbor`.
Zero matches is `UnknownRoot`. More than one is `AmbiguousRoot`. Neither falls back to anything:

> *"never defaults to the last entity, the first entity or all entities."* — `entity.rs:33`

`register` refuses overlapping roots at write time rather than discovering the ambiguity at
resolution time (`EntityError::OverlappingRoot`). A worktree is resolved by the caller through its
Git common directory before arriving, per ECS §10.2 — never by path-name guessing.

**Nothing about the mapping mechanism needs to change.** What needs to change is who is asked, and
when.

### 2.2 Who writes it: he does, in the interview, and then incrementally at the moment of doubt

The empty-registry case *is* the first-launch case, and `entity.rs:44` already rules on it:

> *"An empty registry is a legal state, not an error. It resolves nothing, it refuses every root,
> and it is what a first launch has. The app's job in that state is to ask … never to invent an
> answer."*

The onboarding document places the interview as the **fourth step of the app's existing first-run
chain** (`richos-onboarding-2026-09-06.md` §2), after setup → memory → company. So the connection
is already almost made, and it is off by one step in a way worth naming:

```
main.js:5365   setup sheet   -> installs Claude Code and the engine
main.js:3531   memory        -> "where should your memory live?"
main.js:5378   company       -> which company this copy works for   <- writes the FIRST registry row
               interview                                            <- fills in what that company IS
               home screen
```

**The company picker writes the row; the interview writes the company's contents.** They are two
different artifacts and they arrive in that order naturally: you cannot interview someone about a
company you have not named, and you should not ask a non-technical CEO to fill in a JSON registry.

That gives three writers, and no fourth:

| When | Who writes it | What is written |
|---|---|---|
| First launch, empty registry | the company sheet, then the interview | one entity: id, display name, one root |
| Later, a folder resolves to nothing | the app, on `UnknownRoot`, by **asking** | either a new root added to an existing company, or a new company |
| Later, deliberately | the CEO, in a companies screen | edits, retirements, extra roots |

Row 2 is the one that answers his actual question. When Rich is asked to work in a folder that is
not in the registry, `resolve_root` returns `UnknownRoot`, and the correct product behavior is a
single question in the register a chief of staff would use — *"I haven't worked in this folder
before. Is this FemcBoost, or something new?"* — with the answer written to the registry. Never a
guess, never a default, and never silent adoption of whatever that folder declares about itself.

### 2.3 One consequence worth stating plainly

`engine/identity.config` holds `COMPANY_NAME` **and** `CEO_NAME` in one file
(`richos-onboarding-2026-09-06.md` §1, link 4). Under a three-layer model those two values belong
to different layers and different lifetimes: `CEO_NAME` is install-invariant and goes to
`me/identity.config`; `COMPANY_NAME` varies and goes to `companies/<id>/company.md`. Leaving them
in one file is how a single-company assumption survives a multi-company design, so the split is
part of this work rather than a later tidy.

### 2.4 The interim that needs no code

`EntityRegistry::load` is a plain `std::fs::read_to_string` on `config_dir.join("entities.json")`
(`entity.rs:647`, `entity.rs:515`), which follows symlinks. So the registry can live in `myrichos`
**today**, with a symlink at the path the app already reads, and no Rust change at all. §6 lists
this as buildable now — with the boot check from §1.3 attached to it, because an unchecked symlink
is exactly what produced the four dangling `corpus.*` links.

---

## 3. Where today's guards go

### 3.1 The finding that makes this smaller than it looks

The engine plugin is already registered at **user scope** — outside every repository:

```
cat ~/.claude/settings.json
  "enabledPlugins": { "richos-engine@richos-local": true }
  "extraKnownMarketplaces": { "richos-local": { "source": { "path": "/Users/alex/ab/richos" } } }
```

and it already ships the guards, resolved **install-relative** rather than folder-relative:

```
grep -o '"command": "[^"]*"' engine/hooks/hooks.json | sort -u
  bash ${CLAUDE_PLUGIN_ROOT}/scripts/hooks/guard-worktree-isolation.sh
  bash ${CLAUDE_PLUGIN_ROOT}/scripts/hooks/scan-secrets.sh
  … 58 more
```

`${CLAUDE_PLUGIN_ROOT}` is the difference between the two worlds in one variable. The kit's copies
resolve `$CLAUDE_PROJECT_DIR/scripts/hooks/…` — *the folder you are visiting*. The plugin's resolve
to the install. **The person layer's enforcement channel is already built, already registered, and
already correct.**

### 3.2 So the migration is mostly a deletion

Diffing every folder hook against the plugin by name:

```
for d in femcboost claude-orchestration-kit prospects deeply; do
  grep -o '"command": "[^"]*"' /Users/alex/ab/$d/.claude/settings.local.json \
    | sed 's/.*\///;s/"$//' | grep '\.sh$' | sort -u \
    | while read -r h; do grep -q "/$h" engine/hooks/hooks.json \
        && echo "DUPLICATE $h" || echo "NOT-IN-PLUGIN $h"; done
done
```

| Folder | Hooks | Verdict |
|---|---|---|
| `claude-orchestration-kit` | 13 | **13 of 13 are duplicates of plugin hooks by name** |
| femcboost | 5 (`ecs-*.sh`) | 0 in the plugin — genuinely company-specific |
| deeply | 1 (`deeply-design-brief-gate.sh`) | 0 in the plugin — genuinely company-specific |
| prospects | 0 scripts (one inline `echo` notice) | nothing to move |

And the duplicates are not duplicates, they are **stale forks**. By `shasum -a 256`, 13 of 13
differ from the plugin's copies (V6), and the drift is not cosmetic:

```
guard-worktree-isolation:  plugin 1090 lines,  kit 404 lines
scan-secrets:              plugin  414 lines,  kit 240 lines
```

The kit's copy of the isolation guard is 37% of the current one. **A folder-scoped guard that has
drifted this far is worse than no guard, because it looks like protection.** That is the same
failure mode as the whole "rules follow the folder" arrangement, in miniature, and it is why this
migration is a deletion rather than a move.

### 3.3 This migration has already been run once, successfully, and it left a method

I did not have to invent the classification step. `deeply` did exactly this, and its one surviving
hook explains why it survived — `head -25 /Users/alex/ab/deeply/scripts/hooks/deeply-design-brief-gate.sh`:

> *"deeply used to carry 26 hand-ported copies of the RichOS engine's mechanical layer. Those copies
> are gone: the engine is now loaded BY REFERENCE as a Claude Code plugin … Before deleting them,
> every one of the 26 was diffed against the engine's canonical version and classified. Exactly TWO
> checks turned out to be things deeply had and the engine did not, and both are PRODUCT LAW rather
> than orchestration mechanics — they encode deeply's own design rules, they name deeply's own wiki
> pages, and they should never appear in a vendor-neutral engine."*

That is the method, and it is the right one: **diff every folder hook against the canonical, and
keep only what is product law.** 26 hooks in, 1 hook out, 25 deletions. It also supplies the
distinction this document needs and had not named — *orchestration mechanics* is the person layer;
*product law* is the company layer. `deeply-design-brief-gate.sh` is a company-layer guard that
already exists, already works, and is currently delivered by the wrong channel.

So `deeply` is not a folder to migrate. It is the worked example, one channel short: its guard is
correctly classified and incorrectly delivered, and §3.4's table moves the delivery without
touching the classification.

### 3.4 What moves where

| Guard | Layer | Destination | Delivery |
|---|---|---|---|
| The 13 in `claude-orchestration-kit` | person | **nowhere — delete the folder copies** | already in the plugin at user scope |
| The plugin's 58+ hooks | person | stays exactly where it is | `~/.claude/settings.json` `enabledPlugins` |
| femcboost's 5 `ecs-*.sh` | company | `~/myrichos/companies/femcboost/guards/` | `--settings` fragment at worker spawn (V2/V3) |
| deeply's `deeply-design-brief-gate.sh` | company | `~/myrichos/companies/deeply/guards/` | same |
| prospects' inline notice | company | `~/myrichos/companies/prospects/guards/settings.json` | same |
| femcboost's `env` + `worktree` keys | company | `~/myrichos/companies/femcboost/guards/settings.json` | same — `--settings` carries `env` today |
| Anything a visited folder declares | folder | **not adopted** | no channel, by design |

The deletion in row 1 is a change to a different repository (`claude-orchestration-kit`) and is not
mine to make on this branch. It is named here because it is a **precondition** for anything else:
while those 13 stale forks are live, a session in that folder gets the 404-line isolation guard.

### 3.5 What becomes of the user-scope plugin registration

**It stays, and it becomes the definition of the person layer.** One property of it should change,
and it is a real decision rather than a tidy.

The marketplace points at `/Users/alex/ab/richos` — a working checkout of the product, where five
teammates are editing branches tonight. For dogfooding that is deliberate and correct: the CEO's own
guards should be the ones being developed. For a shipped product it is wrong, because a customer's
enforcement would follow a source tree. So:

- **Dogfood install (this machine): keep the checkout source.** The cost is that a merge into
  `richos` main changes the CEO's live guards, which is exactly what dogfooding is for.
- **Shipped install: the marketplace points at the installed engine** — the directory `setup.rs`
  unpacks — never at a repository. `install_engine` verifies exactly two things about what it
  unpacked (`setup.rs:1052-1056`: `scripts/hooks/` is a directory, `VERSION` is a file), so the
  shipped path already has a verification seam to extend rather than a new one to invent.

These are two configurations of one mechanism, not two mechanisms, and the difference is one path
string. Conflating them is how a customer ends up running a developer's branch.

---

## 4. Person, company, folder — and the channel each is delivered by

| Layer | Varies with | What it holds | Channel | State |
|---|---|---|---|---|
| **Person** | nothing — one install, one CEO | who Rich is, how he speaks, what he never says, how absence is reported, the safety floor | `--append-system-prompt-file ~/myrichos/me/doctrine.md` | **settled** — chosen in `richos-inner-doctrine-2026-09-06.md` §3.1; re-verified here as V4/V5 |
| **Person** | nothing | the mechanical guards — isolation, secret scanning, dialect, model ceiling, handoff logging | the engine plugin at user scope, `${CLAUDE_PLUGIN_ROOT}`-relative | **built and live** — §3.1 |
| **Company** | per conversation | who this company is, what it makes, who it serves, its house rules, its vocabulary | **the priming turn**, re-issued on every thread switch | **channel exists, content does not** — §4.1 |
| **Company** | per worker spawn | this company's own guards, its `env`, its permission posture | **`--settings` JSON** at spawn, which survives `--setting-sources ''` | **proven, unwired** — §4.2 |
| **Company** | per company | the team this company draws workers from | `--agents <json>` at spawn, composed from `companies/<id>/team/` | **proven, unwired** — §4.3 |
| **Folder** | — | an address, and nothing else | `resolve_root`, lexical, fails closed | **built and correct** — §2.1 |

### 4.1 The company doctrine channel, and the proof it is per-company

The inner-doctrine document's §4.1 rule is mechanical: *"A system prompt is fixed at spawn.
Everything in the doctrine file must therefore be true for every turn of every conversation on this
install, or it will eventually be a lie."* And `entity.rs:50` fixes one CEO per install, so the
person goes in the file and the company cannot.

The reason the company cannot is more specific than "it varies", and it is worth writing down
because it is the fact the whole layer rests on: **one lease serves many companies.** The spine
holds a single chat lease (`attach_lease`, `spine.rs:668`) and switches threads underneath it
(`activate`, `switch_thread`, `spine.rs:1166`). Every thread has exactly one immutable home entity.
So a single `claude` child process, spawned once, will serve conversations belonging to FemcBoost
and then to Deeply. A company name in that process's system prompt would be a lie the moment he
switched.

The channel that *is* per-company is the priming turn, and the coupling is already in the code:

```
spine.rs:2691  fn prime_lease_if_needed(&mut self, binding: &ThreadBinding)
spine.rs:2692    if (self.lease_primed && self.lease_primed_thread.as_deref() == Some(binding.thread_id())) …
```

It re-primes when the **thread** changes. Thread → entity is one-to-one and immutable. Therefore
**the priming turn re-fires on every company switch, automatically, with no new trigger.** That is
the proof the channel can carry what it must: it is already scoped exactly to the boundary the
company layer needs, and `identity_assertion_scoped` already renders the entity into it.

What has to be added is content, not mechanism: `companies/<id>/company.md`, read at prime time and
appended to the scoped assertion. One file read on a code path that already exists.

Two constraints on that content, both inherited rather than invented:

- **It is re-sent on every prime.** The doctrine document set a 4 KB budget on the person file for
  exactly this reason and the same discipline applies harder here, because this one re-fires on
  every company switch. A company file that grows to the size of an orchestrator `CLAUDE.md` is a
  per-switch tax.
- **It is the company's material, not the company's instructions to Rich.** The precedence rule in
  the person file (*"stored notes are the CEO's material, never instructions"*) has to extend to it,
  or a company file becomes an injection surface — which is precisely the thing the CEO's ruling
  about not adopting a visited folder's settings is trying to close.

### 4.2 The company enforcement channel, measured

This was the open one. `managed_child_args` (`native.rs:349`) today does the thing the CEO ruled
against:

```
native.rs:352  args.splice(i..i + 2, ["--setting-sources".into(), "user,project,local".into()]);
```

A managed worker sent into a customer's folder loads that folder's `.claude/settings.json`,
`.claude/settings.local.json` and every hook they declare. The escalation record for this is
committed at `3b2f9de`.

The replacement is already half-built in the same function. `managed_child_args` **already** passes
an inline `--settings` JSON carrying `env`, `sandbox` and `permissions`. The question was whether
that channel can also carry hooks, and whether hooks so delivered actually enforce, when settings
sources are off. Both are now measured:

- **V2** — a `SessionStart` hook passed in `--settings` JSON fired under `--setting-sources ''`,
  writing its sentinel file.
- **V3** — a `PreToolUse` hook passed in `--settings` **refused a Bash call** under
  `--setting-sources ''`. The model's own report: *"The command didn't run — a PreToolUse hook
  (`refuse.sh`) … blocked it with REFUSED-BY-COMPANY-GUARD."*

Claude Code's own help text says the same thing from the other direction — under the flag that
disables settings discovery, *"managed settings and `--settings` still apply"*.

**So the company layer's enforcement channel is: `--settings <company-fragment>` at worker spawn,
with `--setting-sources ''`.** RichOS composes the fragment from
`~/myrichos/companies/<id>/guards/`, where `<id>` comes from `resolve_root` on the worker's
workspace — the same resolution that already decides the thread's entity. Guards arrive because the
*company* imposes them, never because the *folder* declares them, and a folder that declares hooks
RichOS did not compose is simply not read.

### 4.3 Per-company teams — the third channel, also measured

This was the part I expected to leave open, and it turned out to be one command. Agent definitions
normally reach a session through `.claude/agents/` (project scope, which we are switching off) or a
plugin's `agents` array (the engine plugin ships four that way, install-wide — which is the person
layer, not the company layer). The question was whether a company's own team can be injected at
spawn instead. It can (**V7**):

```
claude -p --setting-sources '' \
  --agents '{"harbor-auditor": {"description": "Audits Harbor Analytics ledgers", …}}' \
  'List the subagent_type values available to your Task tool…'
-> claude, Explore, general-purpose, harbor-auditor, Plan, statusline-setup
```

The company-scoped definition is offered; the built-ins are still there; no settings source was
read. So **`companies/<id>/team/` is a directory of definitions and nothing more**, composed into
one `--agents` JSON object at spawn by the same `resolve_root` that picked the company. That
answers his question directly: *different companies with their own set of workers* is a per-spawn
argument, not an architecture.

One boundary worth stating now rather than discovering later. The engine plugin's four meta-roles
(`clark`, `dean`, `frank`, `reed`) are deliberately install-wide — its own manifest calls them
*"the four meta-roles every operator needs regardless of what they build."* They are the person
layer. A company adds to that set; it does not replace it. If a company ever needs to *remove* one,
that is a new requirement and not something to design for speculatively.

---

## 5. What breaks during the transition

He works in femcboost today with real guards. A migration that turns protections off between step 3
and step 7 is worse than not migrating, so the ordering below is chosen so that **no step removes
an enforcement before its replacement is live in the same step**.

### 5.1 What is genuinely at risk, and what only looks like it

The scary-sounding change — flipping `managed_child_args` from `user,project,local` to `''` — is
narrower than it reads, and the narrowness is measured rather than hoped:

- **The CEO's own chat lease is unaffected.** `child_args` already passes `--setting-sources ''`
  (`native.rs:332`). The `managed` boolean at `native.rs:694` is the only fork. His conversation
  already ignores every folder's settings.
- **His terminal sessions in femcboost are unaffected.** They are not the app's children at all.
  This is the reassurance that matters most and it is easy to lose: nothing in this document changes
  what happens when he runs `claude` in `~/ab/femcboost` himself.
- **`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` is already forced off for managed workers.**
  `managed_child_args` sets it to `"0"` in its inline `--settings`. So losing femcboost's
  `settings.local.json` value of `"1"` costs a managed worker nothing it has today.
- **`worktree.baseRef` matters to a session that creates native worktrees.** Managed workers run
  `acceptEdits` in a sandbox against a workspace; they are not the lander. Worth confirming before
  the flip rather than assuming — but it is not the same class of loss as a guard disappearing.

**What genuinely breaks at the flip:** femcboost's five ECS adapters and deeply's design-brief gate
stop firing for managed workers, because they arrive only through project/local settings. That is
the whole of the real exposure, and it is six scripts across two companies.

### 5.2 The order

Each step is safe to stop after. That is the property being bought.

| Step | Action | What is protected while it runs |
|---|---|---|
| 1 | Create `~/myrichos` with its shape and a `README.md`. Nothing reads it yet | everything, unchanged |
| 2 | Copy — not move — the six company-specific hooks into `companies/<id>/guards/`, and generate each `guards/settings.json` fragment | everything; the originals still fire |
| 3 | Wire `--settings <fragment>` into `managed_child_args`, **leaving `--setting-sources` as it is** | everything, plus the fragment. Hooks fire **twice** here, deliberately |
| 4 | Verify at step 3's doubling: each of the six fires from the fragment. This is the positive probe, and it is the step the whole ordering exists for | everything |
| 5 | Flip `--setting-sources` to `''` in `managed_child_args` | the person layer (plugin, unchanged) + the company layer (fragment, proven at step 4) |
| 6 | Delete the originals from `femcboost/.claude/settings.local.json` and `deeply/.claude/settings.local.json` | as step 5 |
| 7 | Separately, in `claude-orchestration-kit`: delete its 13 stale forks and rely on the plugin | that folder gains 686 lines of isolation guard it does not currently have |
| 8 | Move the registry into `myrichos` behind a checked pointer (§2.4) | as step 5 |
| 9 | Consolidate `corpus/`, `ledger/`, `inbox/`; remove the four dangling `corpus.*` symlinks | as step 5 |

Step 3's deliberate double-firing is the one design choice here I would defend hardest. A hook that
fires twice is a nuisance; a window in which it fires zero times is the thing we are migrating
*away* from.

Steps 7, 8 and 9 are independent of 1–6 and of each other. Step 7 is in another repository. That
independence is deliberate: §6.

**Step 3's overlap is now measured rather than assumed.** All six hooks are safe to double-fire
(V8): the five ECS adapters state their own idempotence at `ecs-hook.sh:28` — *"Every store write is
idempotent (turn, fingerprint and scope keys)"* — and `deeply-design-brief-gate.sh` is a
`PreToolUse[Agent]` gate, so firing it twice refuses twice and does nothing else. The overlap window
therefore costs a duplicate log line and no correctness.

### 5.3 The two things that must not happen

- **Never step 5 before step 4.** The flip is the only irreversible-feeling step, and its
  precondition is a positive observation that the replacement fired, not a reading of the code that
  says it should. This project has a standing rule for exactly this — a negative test needs a
  positive probe.
- **Never delete a folder's hooks in the same change that adds their replacement.** Step 2 copies.
  Step 6 deletes, three steps later, after step 4 observed the replacement working.

---

## 6. What is buildable now, and what waits on the app

Several threads are blocked on this document, so the split matters more than the plan. **Everything
in the left column requires no change to `app/**` and no new app capability.**

| Buildable now, today, with no app change | Waits on the app |
|---|---|
| Create `~/myrichos` and its directory shape; write its `README.md` | `--append-system-prompt-file` wiring into `child_args` (`native.rs`) |
| Write `me/doctrine.source.md` — the person-layer template, to the inner-doctrine document's §4.2 six-item spec and 4 KB budget | Rendering it to `me/doctrine.md` at launch |
| Write `companies/<id>/company.md` for all six registered companies | Reading it at prime time and appending it to the scoped assertion (`spine.rs` `prime_lease_if_needed`) |
| Copy the six company hooks into `companies/<id>/guards/` and hand-write each `guards/settings.json` fragment | Composing and passing the fragment in `managed_child_args` |
| Split `identity.config` into `me/identity.config` + the six `company.md` files (§2.3) | The flip of `--setting-sources` to `''` |
| Symlink `registry/entities.json` into `app_config_dir` (§2.4) — reads through today | A real pointer file plus the boot check that makes a missing target an error (§1.3) |
| Delete the 13 stale forks in `claude-orchestration-kit` (different repo, no app involvement) | The first-run interview step and the `UnknownRoot` "is this a new company?" question |
| Write the six `companies/<id>/team/` definition sets (§4.3) | Composing them into `--agents` at spawn |
| Point the shipped marketplace at the installed engine rather than a checkout (§3.5) — a config change | The `UnknownRoot` "is this a new company?" question, and the companies screen behind it |

The left column is most of the content and none of the risk. It is also the column that unblocks the
other threads: a `company.md` that exists and is read by nothing is still the artifact everyone else
is waiting to be told the shape of.

**The smallest useful first commit** is the folder plus the six `company.md` files plus the six
copied guard fragments. It changes no behavior, so it needs no verification beyond "the files are
there", and after it every remaining step is a wiring change with a target that already exists.

---

## 7. The argument against this document

**The objection.** A central folder is a second place for things to go stale. This project spent
2026-09-06 finding sixteen stale rows in one record file; the machine I measured has four symlinks
pointing at a directory that does not exist; and the honest history of "one place for everything"
is that it becomes one more place, with the old places still live and now silently disagreeing. On
that record, adding `~/myrichos` to a machine that already has `com.richos.app/`, `RichOS/` and a
phantom `~/RichOS/` is not consolidation. It is a fourth location with a nicer name.

**What I concede, without qualification.** The objection is right about the mechanism and right
about this machine. And it lands hardest on the one genuinely new artifact: `companies/<id>/company.md`
has **no upstream**. Every other thing in `myrichos` is a move or a pointer, with an original that
would notice if it disagreed. A company file is written once from an interview, describes a business
that changes, is read into every prime, and nothing on earth will tell anyone it has gone wrong. It
will go stale. I am not going to argue it will not; I am going to say it needs the same discipline
the record needs — a date, and the interview turn that produced each claim — and that a company file
which cannot say where a line came from should be treated as a claim, not as fact. That is a
mitigation, not a fix, and it should be read as one.

**Where the objection is wrong.** It treats staleness as a property of centrality. It is a property
of **copies**, and the direction of the effect is the opposite of what the objection assumes. The
measurement is in §3.2 and it is not close: in the decentralized arrangement we have today, 13 of 13
guard scripts have drifted from their upstream, and the most important one is 404 lines against
1090. That is not a hypothetical future staleness — it is live tonight, in the folder whose whole
purpose is to carry the guards, and it happened *because* the rules followed the folder. Meanwhile
the engine plugin, which is the most centralized thing on the machine, has drifted from nothing,
because there is nothing for it to drift from.

So the objection converts cleanly into a design constraint rather than a refutation, and it is the
constraint §1.3 already states: **`myrichos` holds the only copy; everything else holds a checked
pointer.** A central folder that adds a copy earns the objection. One that removes twelve does not.

**And the last part of the concession.** The four dangling `corpus.*` symlinks prove that pointers
rot too, silently, unless something checks them. That is why §1.3 is a rule about *checked* pointers
and why the boot check is not optional garnish. If this design ships with unchecked pointers, the
objection wins on the facts and I will have earned it.

---

## 8. Open questions, collected

Two remain. Two others were open when I drafted this and I settled them rather than shipping them
as questions, because both cost one command:

- ~~Does `--agents` deliver a company-scoped team under `--setting-sources ''`?~~ **Yes** — V7, §4.3.
- ~~Are the six company hooks safe to double-fire at step 3?~~ **Yes** — V8. The five ECS adapters
  are explicitly idempotent (*"Every store write is idempotent (turn, fingerprint and scope keys)"*,
  `ecs-hook.sh:28`) and `deeply-design-brief-gate.sh` is a `PreToolUse[Agent]` gate, whose
  double-firing is a repeated refusal rather than a repeated effect.

The two that are left:

1. **`~/myrichos` or `~/ab/myrichos`?** His call, one line to change. Blocks step 1 of §5.2 and
   nothing else. It is a naming preference, not a technical decision — which is why I have not
   picked it for him.
2. **Does `worktree.baseRef` matter to a managed worker?** Read `run_host.rs` and the managed
   worker's actual workspace handling. Blocks step 5, and is the one place I would want a second
   pair of eyes before the flip — not because I think it breaks, but because step 5 is the step
   whose precondition is an observation rather than an argument, and I have not made the
   observation.

Neither blocks the left column of §6, which is nine of the document's items and none of its risk.
