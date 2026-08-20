<!-- EXAMPLE — delete after your first real audit. This is a worked model showing
     the shape and rigor a committed audit in this directory should have: a
     per-item PASS/FAIL table with evidence, an X/10 score, an explicit
     SHIP/FIX-FIRST verdict, and (when FIX-FIRST) a re-verification pass that
     closes the loop back to SHIP. The feature audited below is entirely
     fictional — a generic "bulk CSV export" button — genericized so it teaches
     the AUDIT SHAPE, not any particular product's UI. Replace the fictional
     subject with your own feature/screen/flow on your first real QA pass. -->

# {Teammate} — Verification Audit: "Bulk CSV Export" (fictional example feature)

**Date:** YYYY-MM-DD
**Subject:** `<your-repo>` @ `<12-char-sha>` (`main`)
**Feature:** Bulk CSV export button on a fictional "Orders" list screen — used here purely to illustrate audit shape, not a real feature in this kit.
**Method:** Automated + scripted verification (this role's lane) — no UX judgment claimed; boundary respected per this kit's QA doctrine (automation QA is not UX authority).
**Tester:** automation QA role (replace with your real teammate's name)

---

## Score: 8/10 — Verdict: **FIX-FIRST**

Two required fixes below (items 3 and 6). See "Re-verification" at the end of
this file for the closed loop back to **SHIP** after the fixes landed — this is
the shape every FIX-FIRST audit should take: it does not just report the
defect, it re-verifies after the fix and only then reports SHIP.

---

## Per-item results

| # | Item | Verdict | Evidence summary |
|---|---|---|---|
| 1 | Export control renders on the Orders list, enabled only when ≥1 row is selectable | PASS | full-page screenshot at `qa-audits/evidence/example-01-button.png`, covers full scroll depth not just the first viewport |
| 2 | CSV includes every visible column, in the documented column order | PASS | downloaded file diffed against the documented column spec — exact match |
| 3 | CSV contains every row matching the active filter, not just the current page (no silent pagination truncation) | **FAIL** | filtered result set = 1,240 rows across 25 pages; exported CSV contained only 50 rows (page 1) — see defect list |
| 4 | Empty-result export (zero matching orders) does not crash and produces a valid, header-only CSV | PASS | export attempted against a zero-row filter; valid CSV with header row only, no error thrown |
| 5 | Large export (10,000+ rows) completes without a client-side timeout | PASS | 12,000-row synthetic dataset exported in 4.1s, no timeout, no dropped rows |
| 6 | Exported file name is collision-safe (unambiguous timestamp; two exports in the same minute never overwrite each other) | **FAIL** | two exports triggered 10s apart both produced `orders-export.csv` with no differentiator — see defect list |
| 7 | Permission-denied path is tested, paired with a positive-shape probe (not a negative-only test) | PASS | `export_denied_for_unauthorized_role` (expects 403) is paired with `export_succeeds_for_authorized_role` (expects 200 + valid CSV) in the same suite — a negative-only gate test would pass for the wrong reason if the endpoint were simply broken; the positive probe rules that out |
| 8 | Audit evidence covers full scroll depth for every captured screen, not just the above-the-fold viewport | PASS | confirmed for item 1's screenshot; no findings relied on an unscrolled capture |
| 9 | Test names encode the invariant they assert, not a generic counter | PASS | e.g. `export_includes_all_filtered_rows_not_just_current_page`, not `test_export_2` — the failing test in item 3 was findable by name alone before opening the file |
| 10 | Any deviation from the documented spec is surfaced in this audit, not left only in a code comment | PASS | no undocumented deviations found this cycle; had one existed, it would be listed here, not merely noted inline in source |

---

## Evidence detail

### Item 3 — pagination truncation (FAIL)

```
Filter: status=shipped, date_range=last_90_days  ->  1,240 matching rows (25 pages @ 50/page)
Export button clicked from page 1  ->  downloaded orders-export.csv
$ wc -l orders-export.csv
51   (1 header + 50 data rows)
```
Expected 1,241 lines (1 header + 1,240 data rows). The export handler is
reading only the currently-rendered page's in-memory row set instead of
re-querying the full filtered result server-side.

### Item 6 — file name collision (FAIL)

```
$ curl -s .../export?filter=... -o run1.csv; sleep 10; curl -s .../export?filter=... -o run2.csv
$ ls -la orders-export*.csv
orders-export.csv   (only one file — browser silently suffixed/overwrote on the second save)
```
The file name has no timestamp or run-identifier component, so two exports in
close succession are indistinguishable and the second silently overwrites the
first in the default download location.

---

## Defect list (for FIX-FIRST)

1. **[Required fix]** Export handler must query and stream the FULL filtered
   result set server-side, not the client's currently-rendered page. Add a
   regression test asserting `exported_row_count == filtered_total_count` for
   a multi-page result set (this is exactly the "pair the positive-shape
   probe" rule applied to a count, not just a permission check).
2. **[Required fix]** File name must include an unambiguous timestamp (e.g.
   `orders-export-<ISO8601-with-seconds>.csv`) so back-to-back exports never
   collide.

Nothing else blocks shipping — items 1, 2, 4, 5, 7, 8, 9, 10 all passed with
direct evidence.

---

## Re-verification @ `<next-sha>` (same day, second pass)

Both defects fixed and independently re-verified against a fresh export:

```
$ wc -l orders-export-2026-07-20T14-32-07.csv
1241   (1 header + 1,240 data rows — matches filtered_total_count exactly)

$ curl ... -o a.csv; sleep 10; curl ... -o b.csv
$ ls orders-export-*.csv
orders-export-2026-07-20T14-40-01.csv
orders-export-2026-07-20T14-40-11.csv   (distinct file names, no collision)
```

| # | Item | First pass | Re-verified |
|---|---|---|---|
| 3 | Full filtered result set exported, not just current page | **FAIL** | **PASS** — row count matches exactly |
| 6 | Collision-safe file name | **FAIL** | **PASS** — distinct names on back-to-back exports |
| 1,2,4,5,7,8,9,10 | (unchanged) | PASS | PASS (no regressions) |

**Final score: 10/10 — verdict: SHIP.** No open defects. This is the shape a
loop back to step 1 (per this kit's QA Pipeline) should take: FAIL closes the
loop to the engineer, the engineer fixes and commits, and this same audit role
re-verifies against the new commit before SHIP is reported — never against
the original failing commit, and never taking the engineer's word for it.

---

*This audit is automation-QA-lane verification — no design/UX judgment is
claimed here; that authority belongs to the design gatekeeper, per this kit's
QA-pipeline boundary rules.*
