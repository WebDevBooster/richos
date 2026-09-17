# `workspace repair` on a synthetic corpus — the crossed-consent cleanup, proven

**What this is.** A run of `richos-service workspace repair` against a corpus built to have the exact
SHAPE of the CEO's on 2026-09-17: two Google accounts, one correct sync, then one crossed sync in
which each account held the other's grant. Nothing here touched `~/RichOS`, nothing here called
Google, and nothing here is a fixture the repair could not have been wrong about — every byte was
written by the same `ingestOnce` spine a real sync uses, against fake adapters.

**Reproduce it:**

```
cd richos/tools/richos-service && npm run demo:repair
```

(The script is `test/crossed-consent-repair-demo.mjs`. It builds its corpus in a fresh temp directory
and removes it at exit; the absolute paths below were shortened to `<corpus>` because a temp path
changes every run and says nothing.)

**The assertions are NOT in this file.** They are in `test/workspace.js`, under
"`workspace repair` — undoing ONE sync run": 8 tests, part of `npm run -s test:workspace`
(372 passed, 0 failed) and of `npm test` (every suite green). This transcript is the human-readable
companion, not the proof of record.

## What the run demonstrates

| | before the repair | after `--apply` |
|---|---|---|
| ingest-ledger rows | 7 | **3** — exactly the correct 02:46Z run |
| evidence files | 21 | **9** |
| cursors holding the other account's position | 3 | **0** (reset to null → bounded full sync next) |
| the correct run's cursors | 2 | **2, untouched** |
| promoted memory records | 2 | **2 — repair removes none, and names the orphan** |

Two things the run shows that are easy to miss:

- **`Morgan Lee: 2 → 1`.** Morgan is on ONE message. The crossed run ingested that one message a
  second time under the other account's source instance, and the second sighting is what carried the
  name over the §4.5 corroboration threshold. That is memory learned from evidence counted twice —
  the corruption the repair has to be able to report, computed with promotion's own reader and
  promotion's own threshold rather than a second implementation.
- **`NOT removed by repair`, twice.** The promoted record and the entity row are REPORTED and left
  exactly where they are. A loro record is create-only and superseded rather than deleted; whether
  one stops existing is the CEO's decision and the loro writer's write.

The dry run's listing afterwards is byte-identical to the one before it — the test asserts that on
the ledger bytes and the evidence directory names, and the transcript shows it.

## The run

```
THE SHAPE, reproduced: two accounts, one correct sync, then one crossed sync.

  personal account:   a.b.booster@icloud.example   (Drive + Calendar, no Gmail mailbox)
  workspace account:  alex@leadersadapt.example  (its mail is the mail that exists)

--- AFTER THE CORRECT SYNC (02:46Z) -----------------------------------------------------------------
ingest ledger:   3 row(s)
  2026-09-17T02:46:00.000Z  google:mail  google:mail:bcb741007cd6f784:msg-1
  2026-09-17T02:46:00.000Z  google:mail  google:mail:bcb741007cd6f784:msg-2
  2026-09-17T02:46:00.000Z  google:calendar  google:calendar:b72a8a6f6c051e88:evt-1
evidence files:  9 file(s) under workspace/
cursors:         2
  ["google","mail","bcb741007cd6f784"]  cursor="hist-11846"  updatedAt=2026-09-17T02:46:00.000Z
  ["google","calendar","b72a8a6f6c051e88"]  cursor={"a.b.booster@icloud.example":"CAL-1"}  updatedAt=2026-09-17T02:46:00.000Z
promotion ledger: 1 row(s)
  rec:demo:ws-google-calendar-2026-09-17-leadership-sync-8331fedb  <- google:calendar:b72a8a6f6c051e88:evt-1

--- AFTER THE CROSSED SYNC (07:32Z) — what has to be undone -----------------------------------------------------------------
ingest ledger:   7 row(s)
  2026-09-17T02:46:00.000Z  google:mail  google:mail:bcb741007cd6f784:msg-1
  2026-09-17T02:46:00.000Z  google:mail  google:mail:bcb741007cd6f784:msg-2
  2026-09-17T02:46:00.000Z  google:calendar  google:calendar:b72a8a6f6c051e88:evt-1
  2026-09-17T07:32:41.000Z  google:mail  google:mail:755d5e0f7b9b59ff:msg-1
  2026-09-17T07:32:41.000Z  google:mail  google:mail:755d5e0f7b9b59ff:msg-2
  2026-09-17T07:32:41.000Z  google:drive  google:drive:9681e06689965eb0:file-1
  2026-09-17T07:32:41.000Z  google:calendar  google:calendar:a897b876a70cdfc8:evt-1
evidence files:  21 file(s) under workspace/
cursors:         5
  ["google","mail","bcb741007cd6f784"]  cursor="hist-11846"  updatedAt=2026-09-17T02:46:00.000Z
  ["google","calendar","b72a8a6f6c051e88"]  cursor={"a.b.booster@icloud.example":"CAL-1"}  updatedAt=2026-09-17T02:46:00.000Z
  ["google","mail","755d5e0f7b9b59ff"]  cursor="hist-11846"  updatedAt=2026-09-17T07:32:41.000Z
  ["google","drive","9681e06689965eb0"]  cursor="drive-1002"  updatedAt=2026-09-17T07:32:41.000Z
  ["google","calendar","a897b876a70cdfc8"]  cursor={"a.b.booster@icloud.example":"CAL-2"}  updatedAt=2026-09-17T07:32:41.000Z
promotion ledger: 2 row(s)
  rec:demo:ws-google-calendar-2026-09-17-leadership-sync-8331fedb  <- google:calendar:b72a8a6f6c051e88:evt-1
  rec:demo:ws-google-calendar-2026-09-17-leadership-sync-00ccdd45  <- google:calendar:a897b876a70cdfc8:evt-1

$ richos-service workspace repair --since 2026-09-17T07:32:00Z --until 2026-09-17T07:33:00Z

zone:       <corpus>/ceo/evidence/unfiled/workspace
window:     2026-09-17T07:32:00.000Z  ..  2026-09-17T07:33:00.000Z

ledger:     would remove 4 of 7 rows — <corpus>/ceo/evidence/unfiled/workspace/_workspace_ingest.jsonl
            2026-09-17T07:32:41.000Z  google:mail  google:mail:755d5e0f7b9b59ff:msg-1
            2026-09-17T07:32:41.000Z  google:mail  google:mail:755d5e0f7b9b59ff:msg-2
            2026-09-17T07:32:41.000Z  google:drive  google:drive:9681e06689965eb0:file-1
            2026-09-17T07:32:41.000Z  google:calendar  google:calendar:a897b876a70cdfc8:evt-1
evidence:   would delete 4 revision directories
            <corpus>/ceo/evidence/unfiled/workspace/google/mail/google_mail_755d5e0f7b9b59ff_msg-1--c2f6ecf81d569451cae6ab3fc7704df4d473a0218712d78753aa9cc7fab3bde6/rev-8b5cc4df7eec7d32a7814eca4af047ae33b2d52342667715682e19c25b0b9faa
            <corpus>/ceo/evidence/unfiled/workspace/google/mail/google_mail_755d5e0f7b9b59ff_msg-2--ff03c09a7440dcf7c76e09596a16bec284993dadafc13ec3bcbce6dffa020699/rev-ac0f09c0f8bf5e7a4b063d863255f16d8ce9abe600e288d934cf313bcbff63eb
            <corpus>/ceo/evidence/unfiled/workspace/google/drive/google_drive_9681e06689965eb0_file-1--9f96ccfb361e97b073974f651d80344fc9f3bf6aa207d724715db729b3a51efa/rev-8b53639f152c8fc6ef30802fde462ba0be9cf085f7580dc69efd72e002abbb35
            <corpus>/ceo/evidence/unfiled/workspace/google/calendar/google_calendar_a897b876a70cdfc8_evt-1--75973b00fdbfb5f4cf5522936ecf746b587408b9a4829140dcf0c94e1b8b9733/rev-d0f631ca1ddba8db3bcfcb9e057cdc98d0379f1bee00e75a545147a27dadd982
cursors:    would reset 3 — the next sync is a bounded full sync, deduped by the ledger
            google:mail  instance 755d5e0f7b9b59ff  written 2026-09-17T07:32:41.000Z  one delta token
            google:drive  instance 9681e06689965eb0  written 2026-09-17T07:32:41.000Z  one delta token
            google:calendar  instance a897b876a70cdfc8  written 2026-09-17T07:32:41.000Z  a cursor per calendar: 1 — a.b.booster@icloud.example
memory:     1 promoted record would be left citing evidence that is gone — NOT removed by repair
            rec:demo:ws-google-calendar-2026-09-17-leadership-sync-00ccdd45   (from google:calendar:a897b876a70cdfc8:evt-1)
            A loro record is create-only and superseded rather than deleted, so whether these
            stop existing is a decision for the CEO and a write for the loro writer, not this command.
people:     1 name would fall below the corroboration threshold (2) without this evidence — NOT removed by repair
            Morgan Lee: 2 → 1

(dry run — nothing was changed. Re-run with --apply.)

exit 0

--- AFTER THE DRY RUN — byte for byte what it was -----------------------------------------------------------------
ingest ledger:   7 row(s)
  2026-09-17T02:46:00.000Z  google:mail  google:mail:bcb741007cd6f784:msg-1
  2026-09-17T02:46:00.000Z  google:mail  google:mail:bcb741007cd6f784:msg-2
  2026-09-17T02:46:00.000Z  google:calendar  google:calendar:b72a8a6f6c051e88:evt-1
  2026-09-17T07:32:41.000Z  google:mail  google:mail:755d5e0f7b9b59ff:msg-1
  2026-09-17T07:32:41.000Z  google:mail  google:mail:755d5e0f7b9b59ff:msg-2
  2026-09-17T07:32:41.000Z  google:drive  google:drive:9681e06689965eb0:file-1
  2026-09-17T07:32:41.000Z  google:calendar  google:calendar:a897b876a70cdfc8:evt-1
evidence files:  21 file(s) under workspace/
cursors:         5
  ["google","mail","bcb741007cd6f784"]  cursor="hist-11846"  updatedAt=2026-09-17T02:46:00.000Z
  ["google","calendar","b72a8a6f6c051e88"]  cursor={"a.b.booster@icloud.example":"CAL-1"}  updatedAt=2026-09-17T02:46:00.000Z
  ["google","mail","755d5e0f7b9b59ff"]  cursor="hist-11846"  updatedAt=2026-09-17T07:32:41.000Z
  ["google","drive","9681e06689965eb0"]  cursor="drive-1002"  updatedAt=2026-09-17T07:32:41.000Z
  ["google","calendar","a897b876a70cdfc8"]  cursor={"a.b.booster@icloud.example":"CAL-2"}  updatedAt=2026-09-17T07:32:41.000Z
promotion ledger: 2 row(s)
  rec:demo:ws-google-calendar-2026-09-17-leadership-sync-8331fedb  <- google:calendar:b72a8a6f6c051e88:evt-1
  rec:demo:ws-google-calendar-2026-09-17-leadership-sync-00ccdd45  <- google:calendar:a897b876a70cdfc8:evt-1

$ richos-service workspace repair --since 2026-09-17T07:32:00Z --until 2026-09-17T07:33:00Z --apply

zone:       <corpus>/ceo/evidence/unfiled/workspace
window:     2026-09-17T07:32:00.000Z  ..  2026-09-17T07:33:00.000Z

ledger:     remove 4 of 7 rows — <corpus>/ceo/evidence/unfiled/workspace/_workspace_ingest.jsonl
            2026-09-17T07:32:41.000Z  google:mail  google:mail:755d5e0f7b9b59ff:msg-1
            2026-09-17T07:32:41.000Z  google:mail  google:mail:755d5e0f7b9b59ff:msg-2
            2026-09-17T07:32:41.000Z  google:drive  google:drive:9681e06689965eb0:file-1
            2026-09-17T07:32:41.000Z  google:calendar  google:calendar:a897b876a70cdfc8:evt-1
evidence:   delete 4 revision directories
            <corpus>/ceo/evidence/unfiled/workspace/google/mail/google_mail_755d5e0f7b9b59ff_msg-1--c2f6ecf81d569451cae6ab3fc7704df4d473a0218712d78753aa9cc7fab3bde6/rev-8b5cc4df7eec7d32a7814eca4af047ae33b2d52342667715682e19c25b0b9faa
            <corpus>/ceo/evidence/unfiled/workspace/google/mail/google_mail_755d5e0f7b9b59ff_msg-2--ff03c09a7440dcf7c76e09596a16bec284993dadafc13ec3bcbce6dffa020699/rev-ac0f09c0f8bf5e7a4b063d863255f16d8ce9abe600e288d934cf313bcbff63eb
            <corpus>/ceo/evidence/unfiled/workspace/google/drive/google_drive_9681e06689965eb0_file-1--9f96ccfb361e97b073974f651d80344fc9f3bf6aa207d724715db729b3a51efa/rev-8b53639f152c8fc6ef30802fde462ba0be9cf085f7580dc69efd72e002abbb35
            <corpus>/ceo/evidence/unfiled/workspace/google/calendar/google_calendar_a897b876a70cdfc8_evt-1--75973b00fdbfb5f4cf5522936ecf746b587408b9a4829140dcf0c94e1b8b9733/rev-d0f631ca1ddba8db3bcfcb9e057cdc98d0379f1bee00e75a545147a27dadd982
cursors:    reset 3 — the next sync is a bounded full sync, deduped by the ledger
            google:mail  instance 755d5e0f7b9b59ff  written 2026-09-17T07:32:41.000Z  one delta token
            google:drive  instance 9681e06689965eb0  written 2026-09-17T07:32:41.000Z  one delta token
            google:calendar  instance a897b876a70cdfc8  written 2026-09-17T07:32:41.000Z  a cursor per calendar: 1 — a.b.booster@icloud.example
memory:     1 promoted record are now left citing evidence that is gone — NOT removed by repair
            rec:demo:ws-google-calendar-2026-09-17-leadership-sync-00ccdd45   (from google:calendar:a897b876a70cdfc8:evt-1)
            A loro record is create-only and superseded rather than deleted, so whether these
            stop existing is a decision for the CEO and a write for the loro writer, not this command.
people:     1 name now fall below the corroboration threshold (2) without this evidence — NOT removed by repair
            Morgan Lee: 2 → 1

removed:    4 ledger rows, 4 revision directories, 3 cursors reset
audit:      <corpus>/ceo/evidence/unfiled/workspace/_workspace_repairs.jsonl

Next: richos-service workspace sync google --once   (a bounded full sync, deduped by the repaired ledger)

exit 0

--- AFTER --apply -----------------------------------------------------------------
ingest ledger:   3 row(s)
  2026-09-17T02:46:00.000Z  google:mail  google:mail:bcb741007cd6f784:msg-1
  2026-09-17T02:46:00.000Z  google:mail  google:mail:bcb741007cd6f784:msg-2
  2026-09-17T02:46:00.000Z  google:calendar  google:calendar:b72a8a6f6c051e88:evt-1
evidence files:  9 file(s) under workspace/
cursors:         5
  ["google","mail","bcb741007cd6f784"]  cursor="hist-11846"  updatedAt=2026-09-17T02:46:00.000Z
  ["google","calendar","b72a8a6f6c051e88"]  cursor={"a.b.booster@icloud.example":"CAL-1"}  updatedAt=2026-09-17T02:46:00.000Z
  ["google","mail","755d5e0f7b9b59ff"]  cursor=null (full sync next)  resetAt=2026-09-17T07:57:25.420Z
  ["google","drive","9681e06689965eb0"]  cursor=null (full sync next)  resetAt=2026-09-17T07:57:25.421Z
  ["google","calendar","a897b876a70cdfc8"]  cursor=null (full sync next)  resetAt=2026-09-17T07:57:25.421Z
promotion ledger: 2 row(s)
  rec:demo:ws-google-calendar-2026-09-17-leadership-sync-8331fedb  <- google:calendar:b72a8a6f6c051e88:evt-1
  rec:demo:ws-google-calendar-2026-09-17-leadership-sync-00ccdd45  <- google:calendar:a897b876a70cdfc8:evt-1

zone (removed at exit): <corpus>/ceo/evidence/unfiled/workspace
```
