# Audit D7 — before/after evidence (2026-09-17)

Brief: the two `<select>`s take the app's own control styling in both themes, the "Home
screen" button label fits, and long paths/URLs break at their own joints. Source finding:
`docs/verification/2026-09-17-nightly-1.2.0-20260917.1-onscreen-audit.md` §D7 (line 397).

## What these screenshots are

Captured locally with the same Playwright/WebKit harness `richos/app/ui/tests/` already
uses (`file://` renderer, mocked bridge), not from a packaged `.app`. "Before" was rendered
from the pre-fix committed source (`git show HEAD` at the point this branch started);
"after" is the fixed source on this branch.

- `before-company-select-{dark,light}.png` / `after-company-select-{dark,light}.png` —
  the universal settings menu's "Company" row (`.set-select`), full menu crop.
- `before-account-type-select-{dark,light}.png` / `after-account-type-select-{dark,light}.png`
  — the first-run setup sheet's "Account type" row (`#provider-account-select`), panel crop.
- `before-home-screen-button-clipped-3x.png` / `after-home-screen-button-full-3x.png` —
  `#set-home-open`, 3x device scale factor, tight crop.

## An honest caveat about the "before" select screenshots

The Account-type select (`#provider-account-select`, zero CSS before this fix) reproduces
the audit's own screenshot almost exactly: a plain white box, black text, native up/down
arrow, in both themes — compare `before-account-type-select-dark.png` against
`docs/verification/2026-09-17-nightly-onscreen/19-setup-progress.png`.

The Company select (`.set-select`) does **not** reproduce as faithfully: it already had
`background`/`border`/`color` declared (see the commit message), and the Playwright-bundled
WebKit used to capture these screenshots renders those declarations through the native
control's fill and border even without `appearance: none` — showing a dark, bordered box
with a native double-headed spinner arrow — where the CEO's actual shipped WKWebView
(`16-settings.png`) painted the whole control plain white, arrow included, ignoring the
declared background/border entirely. Both engines agree that neither one applies
`appearance: none` before this fix, and both show a **native, non-custom arrow** as the
tell; the fill-color permissiveness is a version/engine difference between this sandbox's
WebKit and the CEO's system WebView, not something this fix depends on. After the fix
(`appearance: none` + the custom chevron `<span>`), both controls render identically to the
custom chevron in this harness, which is what `tests/contrast.js`'s new
`setup-account-connect` surface and the existing `updates-*` surfaces now measure.

## A genuine gap this audit surfaced in `tests/contrast.js` itself

The walker reads `getComputedStyle()` for a `<select>`'s background/border/color. Before
this fix, `.set-select` already had passing-looking declared values
(`--surface-sunk`/`--ink`/`--line-control`, all well above the WCAG floors — see the
previous commit's math), so `contrast.js` reported it as measured and passing on every run
that reached it, even though the browser was not painting those values because
`appearance: none` was never set. A computed-style contrast walker cannot see that gap —
it is a different failure mode from the canvas/SVG blind spots the suite already documents
in its own header, and it is not fixed here (out of scope for this brief); it is named so
it is a known limitation rather than a silent one.

## Numbers

Contrast math (WebAIM formula, both themes) is in the "Style the two native selects…"
commit message on this branch. `node contrast.js`, `node appearance.js` and `node
updates.js` all exit 0 on this branch; their tails are not reproduced here — re-run them
for current, live numbers rather than trusting a pasted log.
