# A double-clicked RichOS can be talked to — measured 2026-09-01

Machine: macOS 15.6 (24G84), Apple M4. Bundles built with `app/scripts/package-app.sh`
(ad-hoc, exit 0) and copied to `~/Applications/` — **outside the repository tree**, so no
resolution can fall back on being run from a checkout. Every launch below is
`/usr/bin/open`, which hands the process to launchd exactly as a Finder double-click does:
working directory `/`, launchd's environment, none of the calling shell's.
`scripts/launch.sh` is the harness; it reads the running process's working directory back
with `lsof -d cwd` rather than assuming it.

## What was wrong, end to end

`raw/dclick-before-f44f89a.log` — the bundle built from `f44f89a`, cdhash
`a6963c7fcc0c8cde4cfa098fc44aeb64460b4b89`:

```
[richos] entity not resolved from /: unknown root /: no registered entity owns this path — refusing to guess
[richos] I can't tell which company this work belongs to, so I won't guess — ...
[richos] operator: set RICHOS_ENTITY to one of femcboost, deeply, prospects or richos, or launch from that entity's repository root.
[richos] compute lease attached over /Users/alex/.local/bin/claude
```

The lease attaches. The window opens. **And the first sentence typed into it comes back as
machinery.** Driven through the accessibility API against the running process — the picker
answered, then a sentence typed, then Return — the window read back:

```
TEXT: Rich said
TEXT: Rich
TEXT: no active thread, and no entity was named — Rich will not guess which entity area
      this belongs to. Choose an entity, or activate an existing thread. Your words are
      back in the box below, word for word — press Send when you want me to try again.
TEXT: Echo probe one
TEXT: Which entity is this work in?
```

`conversation-ledger.jsonl` went from 10 lines to 10. Nothing was filed, and the sentence on
screen is `SpineError::NoActiveThread` — a different refusal from the one
`ENTITY-BLOCKER.md` predicted, and a worse one, because it is implementation language.

**The picker was already on screen and could not help.** `AXFocusedUIElement` at that moment
was the composer's text area, holding `Echo probe one`, with `#entity-picker` not hidden:

```
TEXTAREA=[Echo probe one]
FOCUS role=AXTextArea desc= val=Echo probe one
```

`init()` ends with an unconditional `inputEl.focus()`. `startNewThreadFlow()` opens the
dialog and focuses its first row; four lines later that focus is taken straight back. So the
CEO types into a box that cannot send, underneath a dialog he never gets to use. Return went
to the composer, not to the picker — which is why answering it never happened.

## What is right now

`raw/dclick-fixed-unchosen.log` — the fixed bundle, cdhash
`6283989dc15eb378b9147464543b4f0a29d43fac`, nothing chosen yet:

```
[richos] no company resolved — RichOS will ask in the window and remember the answer.
[richos] operator: RICHOS_ENTITY (one of femcboost, deeply, prospects or richos) still overrides, as does launching from that entity's repository root.
[richos] compute lease attached over /Users/alex/.local/bin/claude
```

`raw/dclick-fixed-saved-choice.log` — the same bundle, same `cwd = /`, same empty
environment, after the company has been answered once:

```
[richos] company: richos (via the saved choice)
[richos] compute lease attached over /Users/alex/.local/bin/claude
```

That line is the whole fix in one string: a working directory that owns no entity, and an
entity anyway, because he said so and it was written down.

## The first successful send

`raw/company-choice-roundtrip.log`, from
`cargo run -p richos-core --example company_choice_roundtrip -- ~/.claude/richos-engine richos`
— the full sequence against a real `claude` lease and the customer's own login:

```
1. fresh install: no company chosen, no thread active
2. send refused, as it must be: no active thread, and no entity was named — Rich will not
   guess which entity area this belongs to. Choose an entity, or activate an existing thread.
3. answered: richos written to /var/folders/.../richos-company-roundtrip-...json
4. next boot reads it back: richos
5. active: ceo-default+richos+thr_0182c6ba573343ae9ba355dc9d6c3f68+r3+-

CEO> In one sentence: are you there?

Rich> Yes — I'm here and ready to pick up wherever you'd like.

[roundtrip] turn state = Completed, stop = Some("end_turn")
```

Steps 3 and 4 write and read through `ConfigStore::set_entity`, which is the same call
`choose_entity` makes, so the bytes are the picker's own and not a fixture's.

## WHAT IS NOT PROVEN HERE, AND SAYING SO IS THE POINT

**Nobody has clicked the picker in the fixed build.** Partway through this session this
machine's accessibility bridge stopped answering: `System Events` reports **zero** windows
for every process on the machine, including ones that certainly have them —

```
osascript -e 'tell application "Google Chrome" to return count of windows'                      -> 1
osascript -e 'tell application "System Events" to return count of windows of ...Google Chrome'  -> 0
```

— and a freshly launched TextEdit reports zero as well, so it is not RichOS and it is not
this branch. `killall "System Events"` did not clear it. The earlier baseline drive above ran
before it broke, which is why that half is complete and this half is not.

So the fixed build's evidence is: the real boot line on a real double-click (both states),
plus the full refuse-answer-remember-send sequence against real compute, plus 30 headless
browser checks driving the REAL renderer through the picker, the composer's block and the
settings control under WebKit (`app/ui/tests/affordances.js`, `contrast.js`). What is
missing is a human hand — or an accessibility API — on the button, in the shipping bundle.
`scripts/launch.sh` plus the two AppleScripts here reproduce the baseline drive verbatim the
moment that bridge answers again; run them and this section can be deleted rather than
argued with.
