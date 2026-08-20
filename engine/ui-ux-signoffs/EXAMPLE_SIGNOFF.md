<!-- EXAMPLE — delete after your first real signoff. This is a worked model
     showing the shape a committed signoff file should have: a verification-mode
     disclosure, a first-glance verdict, what-was-verified detail, a documented
     GAPS section (this is the part most adopters skip and shouldn't), a scored
     table, and an explicit release decision. The feature signed off below is
     entirely fictional — a generic "bulk CSV export" button, the same
     illustrative feature as qa-audits/EXAMPLE_AUDIT.md — genericized so it
     teaches the SIGNOFF SHAPE, not any particular product's design. Replace
     the fictional subject with your own feature/screen/flow on your first
     real design-gatekeeper pass. -->

# EXAMPLE SIGNOFF — "Bulk CSV Export" (fictional example feature) — Design Gatekeeper Review

- **Author:** {Teammate} (design gatekeeper role — replace with your real teammate's name)
- **Date:** YYYY-MM-DD
- **SHA under signoff:** `<12-char-sha>` (`main`)
- **Decision:** **GO — 9/10.** Meets the ≥9 bar with documented, non-blocking gaps.
- **Scope note:** this signoff covers a fictional example feature illustrating
  the required shape — every real signoff must disclose its own verification
  mode and scope exactly this explicitly, not just assert a score.

---

## Verification mode (required disclosure)

- **Environment:** real headed browser against staging (or your real target
  surface — emulator/simulator for native). One window, one flow at a time. No
  overlapping sessions.
- **Two-user:** No (single-operator export flow; nothing to compare side by side
  for this feature).
- **Viewport:** the feature's real primary workflow context (e.g. desktop for an
  admin/back-office export control, mobile-first if the equivalent flow is
  client-facing).
- **Freshness basis:** the signoff SHA was verified live-serving before any
  finding below was recorded — never sign off against a build you have not
  confirmed is the one actually running on the surface you're looking at.
- **Verification tags per claim below:** [live-verified] / [committed-evidence-reviewed] / [source-reviewed] — every claim in "What I verified" carries one of these tags. An audit trail without a verification basis is incomplete, not merely informal.

---

## First-glance verdict

The export control feels like a natural, low-friction part of the Orders list —
it doesn't interrupt the existing triage flow, and the resulting file behaves
the way an operator would expect (correct columns, correct row count after the
fix, an unambiguous file name). Nothing about it looks bolted-on or under-
designed. The one thing worth a documented gap (below) is a silent success
state that gives no visible confirmation once the file has started downloading
— a small trust gap, not a functional one.

---

## What I verified

- **Entry point** [live-verified]: the export control is visible only when at
  least one row is selectable, and is clearly labeled — no ambiguous icon-only
  affordance.
- **Progress/completion feedback** [live-verified]: for a large export the
  control shows a brief in-progress state; for a fast export it completes with
  no visible acknowledgment at all — this is the documented gap below.
- **Empty and error states** [live-verified]: a zero-row filtered export
  produces a clear "nothing to export" state rather than a blank/broken
  download; a simulated network failure surfaces an explicit retry affordance
  rather than a silent failure.
- **Automated evidence corroboration** [committed-evidence-reviewed]: this
  role's automated counterpart's audit (`qa-audits/EXAMPLE_AUDIT.md`) confirms
  the underlying data-correctness defects (row-count truncation, file-name
  collision) are fixed as of this SHA — this signoff does not re-litigate that
  layer, only the UX layer built on top of it.
- **Navigation recovery** [live-verified]: triggering an export never
  traps the user — the Orders list remains fully interactive during and after
  the export completes.

---

## Documented gaps / nits (none blocking)

1. **[UX nit — costs the 10th point]** A fast export (small result set)
   completes with **no visible success acknowledgment** — the file simply
   appears in the browser's downloads. A brief, dismissable "Export ready —
   `<filename>`" confirmation would close this gap. Not blocking: the export
   itself is correct and discoverable in the downloads location; this is a
   trust/confidence polish item, not a functional defect.
2. **[Follow-up, not a defect]** The in-progress state for a large export uses
   a generic spinner with no row-count or percentage — sufficient for now, but
   a determinate progress indicator would read as more premium for very large
   exports (30,000+ rows).

---

## Score: 9/10 — GO

| Dimension | Verdict |
|---|---|
| Entry point discoverable, correctly gated on selection state | PASS |
| Underlying data correctness (row count, file naming) — automated-QA corroborated | PASS |
| Empty-state and error-state handling | PASS |
| Navigation never trapped during/after export | PASS |
| Success acknowledgment for a fast export | NIT — held back the 10th point |

**Held back the 10th point** for the missing success acknowledgment on fast
exports — a real, if minor, trust gap. It does not block release: the feature
is correct, discoverable, and recoverable in every state that matters.

**Recommendation: ship this feature.** The documented gap above should be
scheduled as a small follow-up, not looped back to the engineer as a blocking
fix — this is the distinction a GO-with-documented-gaps signoff exists to make
explicit, instead of either silently accepting a flaw or blocking a shippable
feature over a polish item.

---

## Required follow-ups (independent scheduling, not blockers)

- Add a brief success acknowledgment/toast for fast (sub-1s) exports.
- Consider a determinate progress indicator for very large exports.

---

*QA can propose a fix for either follow-up above; only the design gatekeeper
(or the CEO) decides whether and when to act on it — QA does not have
authority to require a UX change, per this kit's QA doctrine.*
