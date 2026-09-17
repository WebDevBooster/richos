# The two failing scorecard rows: what each one actually was — 2026-09-17

After `calfix2` (`a16b6d0a`) and `reingest1` (`df2063f8`), the calendar seed acceptance still read
`NOT ACCEPTED — 2 rows disagree with the pipeline's own prediction`. The question put to this work
was the CEO's standing one: a row that disagrees with the pipeline's own prediction is either a
defect or a state a real user could never reach, and the page must say which.

**Neither row had the cause it was believed to have.** One was a defect in the check; the other was
a defect in the product, but not the one that had been diagnosed. Both are now fixed, and a third
defect — real, reachable by any user, and invisible to this fixture set — was found while answering
the first row's question and is fixed too.

Everything below was measured read-only against the CEO's own zone at
`~/RichOS/corpus/ceo/evidence/unfiled/workspace`. No sync was run, no Google call was made, and
nothing under `~/RichOS` was written.

---

## Row 1 — `cross-calendar-dup`, `2 copies landed`: THE CHECK WAS WRONG, THE PIPELINE WAS RIGHT

**Verdict: not a product defect. A double-count in `calendar-seed-acceptance.mjs`. Fixed; the row
now PASSES against his live zone.**

The fixture writes two copies of one meeting, one per calendar, under one `iCalUID`. It was assumed
they became two source items that the merge had failed to collapse. They never were two items:

```
manifest.events, cross-calendar-dup:
  target=primary  calendarId=alex@leadersadapt.com                  eventId=_e9pjcdr2c4qj…  action=updated
  target=seed     calendarId=c_e489233c…@group.calendar.google.com  eventId=_e9pjcdr2c4qj…  action=created
```

Both writes came back under the SAME event id, because **Google derives an event id from a
caller-supplied `iCalUID`**: the id is `_` + base32hex of the uid. Re-derived from the fixture's own
uid, it reproduces his id character for character —

```
uid       rs67ba56d635cee9e4cc5895bae8@richos-seed.example.com
derived   _e9pjcdr2c4qjcp1m6cqm6pb575ij8or36ks3idb2c5ijgg3id5hmgrrj5lpmapb45pingobde1m6abj3dtmg
observed  _e9pjcdr2c4qjcp1m6cqm6pb575ij8or36ks3idb2c5ijgg3id5hmgrrj5lpmapb45pingobde1m6abj3dtmg   (identical)
```

One id means one `sourceItemId`, one evidence item, and one memory record whose later revision
supersedes the earlier one — which is exactly what his zone holds, and exactly right. The check,
however, observed the group member by member; both members named the same id, one evidence entry was
found twice, and the row reported two landings.

The mock now derives ids the way Google does, so it reproduced the live failure word for word before
the fix and is green after it. The zone is asked once per distinct source item; the copies still
label the row, because "1 of 2" is what the seed wrote.

## Row 2 — `Mateo Silva` learned: A REAL DEFECT, AND NOT THE ONE DIAGNOSED

**Verdict: product defect — corroboration counted evidence REVISIONS rather than meetings. Fixed.
One row of residue remains in his corpus and is his to retire (below).**

The diagnosis under review was that a stray duplicate gave him a second sighting and that the
duplicate's later withdrawal should have taken it back. The zone does not support it. Mateo Silva
appears on exactly ONE item, which has THREE revisions, all confirmed:

```
google:calendar:df6730a1…:rs7deb37be9369e1509be6d0f7ce  status=confirmed  fetched=2026-09-17T10:10:57Z
google:calendar:df6730a1…:rs7deb37be9369e1509be6d0f7ce  status=confirmed  fetched=2026-09-17T10:33:40Z
google:calendar:df6730a1…:rs7deb37be9369e1509be6d0f7ce  status=confirmed  fetched=2026-09-17T11:06:56Z
```

There is no stray item under any other id, no withdrawn revision of this fixture, and the only
withdrawn item anywhere in the zone (`Called-off partner standup`) was withdrawn in its first
revision, so it has no pre-withdrawal history to count. **The withdrawal question is not what made
this row fail.**

What made it fail is that `entityCandidatesFromEvidence` read the zone revision by revision. The zone
is immutable and cumulative, so three re-seeds of one meeting handed the same attendee to the tally
three times, and three clears the threshold of two. Run through the product's own counter, read-only,
before and after the fix:

| name | sightings before | sightings after | distinct items | verdict after |
|---|---|---|---|---|
| Mateo Silva | 3 | 1 | 1 | held |
| Rich Tester | 33 | 11 | 11 | learned |
| Dana Reyes | 18 | 7 | 7 | learned |

Mateo was the only name in his entire zone whose learned status rested on revisions rather than on
meetings. The other two now equal the numbers the acceptance table predicts (`Rich Tester 11`,
`Dana Reyes 7`) — which they never did before, and which is the independent corroboration that the
new count is the one the prediction was always asking for.

### The withdrawal question, answered because it was asked

**Did the count follow a withdrawal? No, and only half the rule was being applied.**
`synthesis.js:isMemoryCandidate` yields no candidates from a withdrawn REVISION, but the item's
earlier confirmed revisions stayed in the zone and kept counting — and that is the normal case, since
a meeting can only be called off if it once existed.

**Should it? Yes, and it now does.** The seed's own prediction (`calendar-fixtures.js:expectationsFor`)
derives its candidates from the CURRENT state of each event, so a withdrawn fixture contributes
nobody there; a product that kept counting the item's history would disagree with its own prediction
the first time the CEO called a meeting off. An item whose current revision is withdrawn now
contributes nobody at all. Revisions are still read across for people (an attendee dropped from a
meeting last week was still on it) — what is gated is the item, by its current state.

## The third defect — found by taking row 1's question seriously

**Verdict: real, reachable by any user, and this fixture set can never exercise it. Fixed.**

Row 1 asked whether cross-run `iCalUID` dedup is a defect. The fixture could not answer it — its two
copies are one item before any merge rule is consulted. The underlying gap is real: the adapter's
cross-calendar merge used a `seen` set that lived for exactly one poll, so a meeting shared onto a
second calendar a month after the original was ingested landed a SECOND time, as a second evidence
item and a second memory record, neither superseding the other. A copy made by sharing or by
accepting an invitation keeps the uid and gets its OWN id, which is precisely the case.

The key the adapter already computes is now carried on the item, recorded in the ingest ledger, and
consulted by the core whenever a copy arrives. Three properties, each a way to get it wrong:

* the key is **account-scoped** — one zone holds every account's evidence, and the existing suite
  turned four tests red the moment an unscoped key let one of his accounts suppress the other's copy
  of the identical meeting;
* the **start stays in the key**, so a weekly series' eight instances, which share one `iCalUID`,
  stay eight meetings;
* **a twin that is gone stops suppressing** — the ledger records whether an item is withdrawn, so a
  copy withdrawn at the source while the other copy lives on does not leave memory reporting a
  meeting as called off while it is still on his other calendar.

A merged copy is reported on its own line, never folded into `deduped`.

---

## Run history these verdicts were read against

| when | what ran | outcome |
|---|---|---|
| 10:10Z | first seed (`calseed1`) + sync | `intro-single-external` ingested, revision 1 |
| 10:33Z | second seed (`calfix1`) + sync | revision 2 of the same item; `cross-calendar-dup` first ingested |
| 11:06Z | third seed (`calfix2`) + sync | revision 3; sync exited 2 on the re-ingest defect |
| 11:22Z | sync on `df2063f8` | exit 0: observed 119, ingested 0, deduped 119, promoted 0, held 245 |

The three fetch timestamps in the evidence match the first three rows exactly, and the 11:22Z sync
ingested nothing new — which is why the zone holds 142 items in 175 revisions, and why one meeting
could be counted three times.

## What is left in his corpus, and the exact commands — NOT run

The fixes stop this recurring. They cannot un-write what was already written, and his memory is his.

**The residue is exactly one row**, and this was checked rather than assumed: every other learned
name in his zone has at least as many distinct meetings as sightings, and no meeting has more than
one live promoted record (15 live records for 15 items, 28 properly superseded).

1. **`Mateo Silva` in `~/RichOS/corpus/ceo/entities.json`** — learned from three revisions of one
   meeting. There is no product command that retires a learned name (`learn-term` only adds), so this
   is the minimal one, written through the product's own serializer and version bump so the file
   keeps its format, and refusing to run at all unless it would remove exactly one row:

   ```
   cd /Users/alex/ab/richos/richos/tools/richos-service
   node --input-type=module -e '
     import fs from "node:fs";
     import { serializeEntitiesDoc, bumpVersion } from "./lib/capture.js";
     const file = `${process.env.HOME}/RichOS/corpus/ceo/entities.json`;
     const doc = JSON.parse(fs.readFileSync(file, "utf8"));
     const entities = doc.entities.filter((e) => !(e.aliases || []).includes("mateo.silva@lumen.example.com"));
     const removed = doc.entities.length - entities.length;
     if (removed !== 1) throw new Error(`refusing: would remove ${removed} rows, expected exactly 1`);
     const version = bumpVersion(doc.version, new Date().toISOString().slice(0, 10));
     fs.writeFileSync(file, serializeEntitiesDoc({ ...doc, entities, version }), { mode: 0o600 });
     console.log(`removed 1 row; entities.json is now version ${version}`);
   '
   ```

2. **Then the acceptance run, which is the check that it worked:**

   ```
   node test/calendar-seed-acceptance.mjs --zone "$HOME/RichOS/corpus/ceo/evidence/unfiled/workspace"
   ```

   Expected after step 1: `ACCEPTED — 18 landings and 3 names, all as predicted.` Today it reads 13
   of 14, with `Mateo Silva  1  held  learned  FAIL` as the only disagreement.

   **Both of these were run before being written down**, against a COPY of his `entities.json` in a
   scratch directory with `RICHOS_ENTITIES_FILE` pointed at it — his file was never opened for
   writing. The command printed `removed 1 row; entities.json is now version 2026-09-17.18`, the
   diff against the original is the version line and that one entity and nothing else, and the
   acceptance run against his real zone with the edited copy printed the `ACCEPTED` line above.

**Deliberately NOT recommended:** `workspace repair --since 2026-09-17T10:08:00Z --until
2026-09-17T11:08:00Z`. Its own dry run says it would leave 15 promoted records citing evidence that
is gone and would not remove the entities rows anyway, so it would trade one stale row for fifteen
dangling ones. Nothing in his corpus needs it.

## Suites

```
npm run -s test:workspace         401 passed, 0 failed   (398 before this work)
npm run -s test:promotion          45 passed, 0 failed   (40 before this work)
npm run -s test:calendar-seed      ACCEPTED — 18 landings and 3 names, all as predicted
npm run -s test:e2e                ALL E2E CHECKS PASSED (1 skipped)
test:migrate-evidence-zone 9 · test:evidence-lookup 19 · test:evidence-bin 13 ·
test:recall and test:evidence-lookup-e2e — every check passed
```

Every new test was run against the previous implementation first: four of the five corroboration
tests fail without the fix (the fifth is the positive control and passes both ways), both ingest
tests fail without the identity change, and the mocked acceptance fails with the live wording without
the check fix.
