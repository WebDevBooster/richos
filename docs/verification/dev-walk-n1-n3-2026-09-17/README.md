# Before/after frames — N1, N2, N3 (dev-walk audit, 2026-09-17)

Captured with a throwaway Playwright/WebKit script against two source trees: `before` is
`richos` at `71ccad5f` (the commit the audit ran against, via `git archive`), `after` is this
branch's fixed `richos/app/ui`. Both driven the same way the shipped test suites drive the
real shell — no mock stubbing beyond what `mock.js` already provides.

- **N2** (`n2-*-settings-menu-dark.png`) — the clearest pair. `before` shows "Connected
  repositories" and "Account connection" as raw, unstyled, pure-white native buttons sitting
  flush left, exactly as the audit described. `after` shows them taking the menu's own
  `.bugbtn` styling, matching "Company buttons…" and "Check for updates".
- **N3** (`n3-*-header-badge-gear.png`) — `before` shows "Technical view · this conversat"
  cut off with the gear painted over the remainder. `after` shows the full sentence with the
  gear's own reserved lane clear of it.
- **N1** (`n1-*-composer-overflow-focused.png`) — **said plainly: this pair does NOT show a
  visual difference**, and that is a limitation of this harness rather than of the fix.
  Playwright's bundled WebKit does not render a visible native scrollbar track/thumb in
  either the `before` or `after` capture for this composer box, in this headless
  environment — the audit's screenshot was taken through a real, on-screen macOS WKWebView
  with the machine's own scrollbar preference in effect, which this harness cannot
  reproduce. What this pair DOES show, and is worth keeping for: the rounded corner and the
  gold focus ring are intact in both, and the structural half of the fix (the border/radius/
  focus-ring moved off the scrolling textarea onto a non-scrolling `#input-shell`, so any
  scrollbar the real app draws is clipped to the rounded corner rather than poking through
  it) is proven by `tests/composer-scroll.js` checks 2 and 3, which DID go red against the
  pre-fix shape and green against the fix — see that file's own mutation log for the
  verbatim FAIL output. Check 1 (no overflow on an empty box) is asserted as an invariant
  but could not be forced red in this engine either; that limitation is also documented in
  `composer-scroll.js`, in the same place, rather than left implicit here.
