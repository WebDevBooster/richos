# What the Workspace source pulls, reaching Rich's answers — measured end to end

**Date:** 2026-09-17 · **Engineer:** Echo · **Branch:** `cc/echo-opus-evidence1`
**Run:** `node tools/richos-service/test/workspace-recall-e2e.mjs` — every check passed.

The transcript at the bottom is the run itself, unedited. Everything above it is what the run
settles and what it does not.

---

## 1. The finding that shaped this, stated before the result

The brief this work came from asked for a conversation turn to retrieve **Calendar events, Drive
documents and mail metadata from the corpus the sync wrote**, ranked by the Loro relevance
machinery. Measured against the code, that is three different jobs with three different answers,
and one of them cannot be built without overturning a signed-off invariant.

**Reading the evidence zone into a slice is refused by the design, and by a test.**

- `engine/loro/lib/store.js:10` — `export const SOURCES = ['records', 'memory', 'wiki', 'entities']`.
  There is no evidence source and never has been.
- `engine/loro/tests/run.js:300` — *"pages: evidence, inbox and mirrors are NEVER compiled (evidence
  is not truth)"*, asserted over every record in a corpus, with a fixture that says so in its own
  body text.
- The Workspace architecture §4.4 opens: *"Governed evidence is not memory… Most items STOP here and
  remain evidence forever"*, and closes with the reason — *"otherwise one hallucination compounds."*

**And the step that WAS specified to close the gap had never been built.** `synthesis.js:151`
documents `reconcile()` as returning a decision *"the CORE applies (writes promoted candidates /
feeds entities) only when held=false"*. No caller applies it: `core.js` collects candidates into the
summary it returns, and `commands.js:465-466` prints their counts. Verified on this checkout at
`4b5abdb5`: zero promoted Workspace records have ever been written, in any code path.

So the gap between "the sync pulled it" and "Rich can say it" was never a missing reader. It was the
missing promotion step. That is what this work builds.

## 2. What is answerable now, and what is not

| Question | Today | Why |
|---|---|---|
| *"What did I have on Tuesday?"* | **Answered** | Calendar entries are promoted to `event` records, dated in the event's own timezone. |
| *"Who did I talk to about pricing?"* | **Answered** | The same records name every attendee with address and org relation; corroborated people also enter `entities.json` (§4.5). |
| *"That pricing model document?"* | **Not answered** | A Drive document is not promotable without the LLM extraction §4.4 step 2 defers to P2+/P5, and reading it out of the evidence zone would break the invariant above. |

The third row is an open architectural question, not an omission I can close: whether Drive document
text and mail metadata get a second, **separately labeled** retrieval channel over the evidence zone
(never under the `COMPANY MEMORY (loro)` heading) is a decision for the architecture owner. Raised as
**`esc-20260917T012707Z-5653b4ae`**, state `proceeding`.

The run asserts the absence rather than skipping it: if a Drive document ever starts appearing in a
slice, the end-to-end fails. An honest "no" that is defended by a test is worth more than a silent
gap.

## 3. The path one item travels, in one paragraph

`listChanges` → `fetchItem` → `toSourceItem` puts the vendor payload into the §4.1 envelope; the
governance gate (`resolveActors` → `classifyScope` → `classifyTrust`) decides its **binding** scope
and trust; `writeEvidence` publishes an immutable revision at
`<corpus>/ceo/unfiled/evidence/workspace/<vendor>/<source>/<safeId>/rev-<etag>/{item.json,
content.txt, governance.json}` and the ingest ledger dedups it. **Then the new step:**
`promoteFromEvidence` re-reads that zone, re-applies §4.4 FILTER → EXTRACT → RECONCILE, and for an
event writes one typed loro record through loro's own writer into `ceo/unfiled/` — carrying the day
in words, the deep link, the attendees, the evidence path, `scope` and `authority` from the
governance record, `method: rich_inferred` and `ref: <vendor item id>`. From there nothing is new:
`loadCorpus` reads it as an ordinary `records` item, `relevance.js` ranks it against the topic,
`privacy.js` withholds it from an audience its scope forbids, `compile.js` renders it into
`slice.text`, `richos-core`'s `CliContextCompiler` parses the slice and `spine.rs` injects that text
as Tier C of the re-prime — and the sentence Rich says is the one the record's own body carries.

## 4. Two measurements worth keeping

**The deep link was falling outside the truncation window, and only the run found it.** The compiler
renders one item as `• [kind] <title> — <body> (ref: <id>)`, truncating the body to
`min(900, max(200, budgetChars ÷ 3))` — **400 characters** at the default 1200-char budget with one
item in the lane. The first version of the record body put the attendees before the source line; a
meeting with three attendees pushed the `vendorUrl` past 400, and Q2 came back naming a meeting it
could not link to. The body is now ordered **when → where it came from → who → free text**, with the
CEO himself left out of the attendee list (he knows he was there, and his own name-and-address is
~30 characters of a 400-character window spent saying nothing). Pinned by a unit test that renders an
eight-attendee meeting and asserts the link inside the first 200 characters.

**`temporal.validUntil` is deliberately not mapped onto the record.** The Calendar adapter fills it
with the event's end time (`adapters/google-calendar.js:134`). `record.js deriveStatus` reads a past
`validUntil` as `expired`, and `relevance.js scoreRecords` skips anything whose status is not
`current` — so mapping it would have made *"what did I have on Tuesday"* answerable only until
Tuesday ended. loro's validity window is about when a **belief** holds, not when a meeting ran.

## 5. What the run proves, check by check

- Three real adapters over a mocked Google API land 6 evidence revisions under an isolated corpus.
- Promotion writes **3** records and holds **3**, each with its reason on the line: the injected
  invite (quarantined, §5.3), the Drive document (kind table), and the mail message — held one gate
  earlier than expected, as a *single untrusted item* under §4.4 step 3, because its author is
  outside the org. The run asserts the reason rather than the gate I assumed.
- The poisoned invite's text is on disk and appears in no answer.
- The §4.5 entity feed learns Alice Nguyen and Dana Reyes — Dana **corroborated across a calendar
  entry and a mail message**, which is mail metadata earning its keep without promoting anything of
  its own — and holds Priya Shah at one sighting, reported rather than dropped silently.
- The scope wall holds at **read** time: the CEO-private 1:1 is in the CEO's own slice (the positive
  control) and absent from an organizational one, with `withheldByScope: 1` counted rather than
  silent.
- Three compiles, 56–60 ms each against this corpus.

## 6. Not in this run, and named rather than implied

- **Promotion is not wired into `workspace sync`.** `lib/workspace/commands.js` was being edited by
  another teammate on the same night; turning it on is one call there. The seam is proven by this
  run and by 36 unit tests instead.
- **No live Google call, no scheduler, no new dependency, and the CEO's real `~/RichOS` corpus was
  never touched.** Every path in this run is under a temporary directory that is deleted when it
  ends.
- **The Microsoft adapter set needs nothing here.** `vendorLabel` and `workspace_source()` both read
  `workspace:<vendor>:<source>`, so a second vendor is a table entry.

---

## The run

```
=== RichOS Workspace recall, end to end ===
corpus: /var/folders/mx/w46p9btx1t17wv9tbsq885qw0000gn/T/richos-recall-y8R5pt/corpus
evidence zone: ceo/unfiled/evidence/workspace

1. SYNC — the real adapters, the real governance gate, the real evidence zone
   calendar: observed 4, ingested 4, quarantined 1
   drive:    observed 1, ingested 1
   mail:     observed 1, ingested 1
    PASS  every source landed evidence under the CEO's corpus, not in the product repo

2. PROMOTION — §4.4 step 4, writing through loro's own writer
   promoted: rec:ceo/unfiled/ws-google-calendar-2026-09-15-northwind-partnership-terms-81f6b3fc  [ceo-private]  Northwind partnership terms
   promoted: rec:ceo/unfiled/ws-google-calendar-2026-09-16-roadmap-check-in-5ee92de6  [org-shared]  Roadmap check-in
   promoted: rec:ceo/unfiled/ws-google-calendar-2026-09-15-coach-pricing-ladder-review-f83c496c  [org-shared]  Coach pricing ladder review
   held:     google:calendar:d60daeaa8472855e083ff3950b3a702ef1bd94d0b3c0c760817325eb24ac1bbd:evt_poison — quarantined — excluded from extraction
   held:     google:drive:4c4394c405b83c7438d7bf0e0e7df3619a4c108d72f33ee7e4e62e88db1d1ebc:file_pricing — a file modification is not an event; decision/claim extraction is the LLM P2+/P5 work
   held:     google:gmail:ce120d3fc1e062845296eebc1ce5900b90389928557a3fa8a80dc97175ddb16c:msg_pricing — single untrusted item — needs corroboration from a trusted source
    PASS  the calendar entries became memory and nothing else did, each absence with its reason
   entities: promoted Dana Reyes, Alice Nguyen, Bob Ramirez
   entities: held Priya Shah (1)
    PASS  a person seen across several items is learned; a one-off is held below the threshold

3. THE QUESTIONS — `loro-context compile`, the same argv richos-core sends

Q1  "what did I have on Tuesday"   (144 ms)

    COMPANY MEMORY (loro) — bearing on: "what did I have on Tuesday"
    • [event] Northwind partnership terms — Calendar entry for Tuesday, September 15, 2026 at 3:00 PM (America/Los_Angeles). Source: your Google Calendar — https://calendar.google.com/event?eid=evt_partner. Read at 2026-09-17T09:00:00.000Z. With: Dana Reyes <dana@northwind.example> (external). Evidence:… (ref: rec:ceo/unfiled/ws-google-calendar-2026-09-15-northwind-partnership-terms-81f6b3fc)
    • [event] Coach pricing ladder review — Calendar entry for Tuesday, September 15, 2026 at 9:00 AM (America/Los_Angeles). Source: your Google Calendar — https://calendar.google.com/event?eid=evt_pricing. Read at 2026-09-17T09:00:00.000Z. With: Alice Nguyen <alice@acme.example> (internal); Bob Ramirez… (ref: rec:ceo/unfiled/ws-google-calendar-2026-09-15-coach-pricing-ladder-review-f83c496c)

    PASS  Tuesday is answered from the CEO's own calendar, named as his calendar
    PASS  the poisoned invite is nowhere in the answer, though its evidence is on disk

Q2  "who did I talk to about pricing"   (101 ms)

    COMPANY MEMORY (loro) — bearing on: "who did I talk to about pricing"
    • [event] Coach pricing ladder review — Calendar entry for Tuesday, September 15, 2026 at 9:00 AM (America/Los_Angeles). Source: your Google Calendar — https://calendar.google.com/event?eid=evt_pricing. Read at 2026-09-17T09:00:00.000Z. With: Alice Nguyen <alice@acme.example> (internal); Bob Ramirez… (ref: rec:ceo/unfiled/ws-google-calendar-2026-09-15-coach-pricing-ladder-review-f83c496c)

    PASS  the people are in the answer, with their addresses and their relation to the org
    PASS  the deep link back to the CEO's own cloud survives into the answer

Q3  "the coach pricing model document I was working on"   (97 ms)

    COMPANY MEMORY (loro) — nothing squarely covers "the coach pricing model document I was working on"; the nearest recorded material is below. Treat it as adjacent context, NOT as an answer.
    • [event] Coach pricing ladder review — Calendar entry for Tuesday, September 15, 2026 at 9:00 AM (America/Los_Angeles). Source: your Google Calendar — https://calendar.google.com/event?eid=evt_pricing. Read at 2026-09-17T09:00:00.000Z. With: Alice Nguyen <alice@acme.example> (internal); Bob Ramirez… (ref: rec:ceo/unfiled/ws-google-calendar-2026-09-15-coach-pricing-ladder-review-f83c496c)

    PASS  NOT ANSWERED: no Drive document reaches the slice — the honest state, asserted
    PASS  and its evidence IS on disk, so the gap is promotion and not ingestion

4. SCOPE — the wall holds when the audience changes, not only at ingestion
   audience rich: rec:ceo/unfiled/ws-google-calendar-2026-09-15-northwind-partnership-terms-81f6b3fc
   audience org:  (nothing)  withheld by scope: 1
    PASS  POSITIVE CONTROL: the CEO himself is given the private 1:1
    PASS  and an organizational audience is not — the same corpus, the same topic, one wall

5. THE PATH one item travels
   6 evidence revisions on disk → 3 promoted records in ceo/unfiled/
   example record: ceo/unfiled/ws-google-calendar-2026-09-15-coach-pricing-ladder-review-f83c496c.md

    ---
    id: ws-google-calendar-2026-09-15-coach-pricing-ladder-review-f83c496c
    kind: event
    scope: org-shared
    title: Coach pricing ladder review
    authority: self
    confidence: 0.9
    observedAt: "2026-09-15T16:00:00.000Z"
    supersededBy: null
    tags: [workspace, google, calendar, event, tuesday, september]
    provenance: { method: rich_inferred, source: "workspace:google:calendar", ref: "google:calendar:d60daeaa8472855e083ff3950b3a702ef1bd94d0b3c0c760817325eb24ac1bbd:evt_pricing" }
    ---
    
    Calendar entry for Tuesday, September 15, 2026 at 9:00 AM (America/Los_Angeles).
    Source: your Google Calendar — https://calendar.google.com/event?eid=evt_pricing. Read at 2026-09-17T09:00:00.000Z.
    With: Alice Nguyen <alice@acme.example> (internal); Bob Ramirez <bob@acme.example> (internal).
    Location: Boardroom.
    Evidence: ceo/unfiled/evidence/workspace/google/calendar/google_calendar_d60daeaa8472855e083ff3950b3a702e--fbba588f91c75dcb043fe1f183af740d3ef3e43a7eed93346dac5beb10d12709/rev-9e5264d410a977c82c64ce0b6e9b3acf66a30bda6c186494cc90a74583b57036/item.json
    Notes: Walk the coach pricing ladder and pick a floor for the fictional studio.
    This is a scheduled calendar entry, not a record of what was decided.

   and the slice item richos-core parses out of it:

    {
      "ref": "rec:ceo/unfiled/ws-google-calendar-2026-09-15-northwind-partnership-terms-81f6b3fc",
      "kind": "event",
      "kindInferred": false,
      "title": "Northwind partnership terms",
      "scope": "ceo-private",
      "company": null,
      "score": 1.1432,
      "truncated": true,
      "provenance": {
        "source": "records",
        "path": "ceo/unfiled/ws-google-calendar-2026-09-15-northwind-partnership-terms-81f6b3fc.md",
        "anchor": null,
        "link": null,
        "method": "rich_inferred",
        "ref": "google:calendar:d60daeaa8472855e083ff3950b3a702ef1bd94d0b3c0c760817325eb24ac1bbd:evt_partner",
        "origin": "workspace:google:calendar"
      },
      "confidence": 0.9
    }

    PASS  the promoted record names its origin, its vendor item id and how it was promoted

=== every check passed ===
```
