# A declared migration: the folder layout, the declaration, and the three retirement conditions

**Status: DESIGN. No code implements any of this, and nothing on anyone's disk is moved by the
commits that accompany this page.** It exists because the next slice — point 25's publisher gate
— consumes the declaration format defined here, and a format invented inside a gate is a format
only that gate understands.

**Source:** `richos-hq docs/plans/nightly-channel-spec-2026-09-17.md`, points 26 and 27,
approved by the CEO on 2026-09-17 (`ceo-decisions.md` §49, *"go with recommended"*). Where this
page and that one differ, that one wins; this page adds only the mechanical detail a build needs
and records what was measured rather than assumed.

**The sentence the whole thing is measured against, in his words:**

> shouldn't all the data be separate from the app so that a rollback or a manual re-install of
> the stable app version automatically always brings everything back to the working state no
> matter what?

---

## 1. What is already true, and what a migration is for

A migration is **not** how the data survives a rollback. The data survives a rollback because it
is not in the bundle and because the readers behave — spec points 17 through 21, which are built
and landed alongside this page:

| rule | what carries it today |
|---|---|
| 17 — the bundle holds no state | the update receipt's `tree_sha256`, plus `verify_bundle` check 6 |
| 18 — every record says which build wrote it | `skip::WRITER_SCHEMA_VERSION`, stamped by the ledger, the intake log and the correction desk |
| 19 — a reader that cannot understand leaves it alone | `LaunchStore`, `ConfigStore`, `NavStore`, and the per-record skip classification |
| 20 — append-only where it is the record of something a person did | unchanged; the survey's classification stands |
| 21 — a nightly never changes the data shape | `#[serde(other)]` on the closed enums, `schema_version` on `StoredConfig` |

**A migration is the exception those rules do not cover:** the case where a build genuinely
cannot hold the old shape, so leaving it alone is not enough on its own. That is rare by design,
and point 25 will make it a build failure to do it by accident.

---

## 2. The folder layout

```
~/Library/Application Support/
  com.richos.app/          <- shape v1. Written ONLY by builds whose data schema is 1.
    config.json
    conversation-ledger.jsonl
    launches.json
    navigation.json
    entities.json
    machinery/  runs/  requests/  rich-skills/  run-notices/  voice-scratch/
    inner-doctrine.md
    owned-work-baseline.json
  com.richos.app/v2/       <- shape v2. Created by COPY. Written ONLY by builds at schema 2.
    ...the same names, in the new shape
```

Four properties, and each is load-bearing:

1. **`v2/` is created by COPY.** The migrating build reads `com.richos.app/`, writes
   `com.richos.app/v2/`, and from that moment never writes to the parent again.
2. **The original is never touched.** Not rewritten, not truncated, not marked. An older build
   re-installed afterwards finds its folder exactly as it left it, which is the whole point of
   the CEO's *"no matter what"*.
3. **DUAL WRITE IS REJECTED OUTRIGHT.** Two builds writing two shapes of the same fact is the
   design that fails in the field and fails silently. What the spec builds is duplicate
   EXISTENCE, which is what he asked for: *"a duplicate of all data until that duplicate is no
   longer needed."*
4. **`v2/` nests INSIDE `com.richos.app/`**, rather than sitting beside it as a sibling
   directory. This is the spec's own layout and it is the right one for a reason worth stating:
   macOS's own per-app roots — `~/Library/Caches/com.richos.app`, `~/Library/WebKit/
   com.richos.app`, `~/Library/Preferences/com.richos.app.plist` — are keyed on the bundle
   identifier by the OS, not by this app, and a sibling would have to argue with that. Nesting
   also means one delete removes everything when the app is removed.

**The honest cost, stated because it is his sentence and not ours to soften:** a rollback across
a migration keeps everything up to the migration date and nothing after it. Point 3's warning
carries that sentence for as long as a dual period is live, and point 31's message names the
date.

---

## 3. The declaration a migrating commit carries

**The problem it solves.** Point 21 is correct as a statement of intent — a regular nightly
never changes the data shape — and it is not self-enforcing. Point 25's gate turns it into a
build failure, and a gate needs to be able to tell an INTENDED shape change from an accidental
one. The declaration is that distinction, made by a human, in the commit that makes the change.

**Where it lives:** `app/data-schema.json`, at one path, read by the gate and by nothing else.
A file rather than a commit-message convention, because a commit message cannot be read by a
build that is three merges downstream of it.

```json
{
  "schema": 2,
  "declared_at": "2026-10-01",
  "declared_in": "<the commit SHA that raised it>",
  "reads": [1, 2],
  "writes": 2,
  "migrates_from": 1,
  "why": "One sentence naming the fact that could not be held in shape 1.",
  "stores": ["conversation-ledger.jsonl", "config.json"]
}
```

| field | meaning |
|---|---|
| `schema` | the writer-schema number this build stamps. It must equal `skip::WRITER_SCHEMA_VERSION` in the same tree, and the gate checks that rather than trusting either. |
| `reads` | every shape this build can open. A build that has dropped a reader says so here, and that is the fact point 27's third condition is evaluated against. |
| `writes` | the one shape it writes. Exactly one, always — this is where dual write is refused structurally rather than by policy. |
| `migrates_from` | present only on the commit that introduces the shape; absent on every later commit at that shape. **A migration is an event, not a state.** |
| `stores` | which files change shape. The gate uses it to know what to compare and refuses a name that is not a store. |
| `why` | for the human reading this in a year. Not machine-checked, and required anyway. |

**Both directions fail, which is the half that makes it a gate rather than a rubber stamp**
(spec point 25 step 4): a shape change with no declaration FAILS, and a declaration with no
shape change FAILS. Either alone proves only the thing it was pointed at.

**A `schema` that goes up by more than one fails.** There is no such thing as skipping a shape:
each one had a writer and may still have a reader.

---

## 4. The three retirement conditions (point 27)

The old copy is deleted only when **all three** hold. They are numbered because each rules out
a different wrong answer, and the count is the spec's.

1. **The running build is a STABLE release.** Not a nightly, not a development build. A nightly
   is a build the user was warned about; it is not a build that gets to delete the copy that
   makes going back possible.
2. **It reads the new shape natively** — `writes == schema` and `schema` is in `reads`, with no
   compatibility path in between.
3. **No published build that reads ONLY the old shape is still reachable by a going-back
   operation from here** (point 11). This is the one that actually takes time to become true,
   and it is a question about what is *published*, not about how long ago the migration was.

Then, and only then, **the app says what it is about to delete and when, and deletes it.** Never
silently.

**Rejected, both named by the spec and repeated here so they are not re-proposed:**

- **Retiring on a timer.** A date is not evidence about which builds are reachable.
- **Retiring at the migration's "success".** Success is precisely when the old copy starts being
  useful. Deleting it then deletes the thing whose entire purpose is to exist while something
  might still need it.

---

## 5. What is deliberately NOT in this page

- **Any code.** Points 26-27 are design in this slice. The publisher gate (point 25) is the next
  one and is what first consumes section 3.
- **A migration of anyone's disk.** Nothing here has been run against `~/RichOS`, the CEO's
  installed app, or any real data directory.
- **The engine.** `~/Library/Application Support/RichOS/engine` is not versioned by this page;
  spec point 22 governs it, and point 23 (the versioned engine directory) was STRUCK by the CEO
  on 2026-09-17.

---

## 6. Open, and recorded rather than quietly decided

- **`written_by` is stamped by three stores, not all of them.** The ledger, the intake log and
  the correction desk carry it — they are exactly the stores whose readers CLASSIFY, via
  `skip::classify_line`, and so the only ones where the field changes an outcome today. The
  machinery journal, the staging desk, the dictation log and the feedback log are unstamped.
  That is a deliberate boundary, not an oversight: stamping them would change bytes on
  customers' disks for a reader that does not exist. When one of them grows a classifier, it
  gets the stamp in the same commit.
- **`navigation.json` has no `schema_version`.** `config.json` gained one (point 5); this one
  did not, so a genuine shape change to it is not declarable and point 25 cannot see it. It
  holds pins, archives and the CEO's own thread titles, so it is not the view state the survey
  calls it. **Smallest fix: the same four lines `StoredConfig` took.** Named here rather than
  taken, because the spec did not ask for it and inventing scope is how a slice stops being
  reviewable.
- **`entities.json` fails the whole registry CLOSED** (`entity.rs`) rather than leaving-and-
  degrading. That is a different answer from every other store here and it may well be the right
  one for a privacy boundary — it is listed so that the difference is a decision somebody made
  rather than one nobody noticed.
