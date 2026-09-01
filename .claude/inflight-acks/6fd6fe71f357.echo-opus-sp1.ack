sha: 6fd6fe71f35752581ecc690c169cd1abe556e9af
impact: stale-record
detail: My contrast evidence was measured against a stale copy of splash.css and index.html: I photograph the composited splash frame and compute AA ratios from the pixels, and the tagline's rendered glyph weight depends on the face. ft1's vendored Inter now arrives via fonts/fonts.css and splash.css's font-family is var(--font), so every ratio I had was taken against the old system stack. Merged main at e5a0097 and I am re-measuring on the merged tree; I edit neither splash.css nor index.html. My two screens carry no glyph at all, only the 18px tagline, so the seven-glyph Noto trap does not reach them. Neither rail-bg nor either swoosh value appears anywhere in my files: the splash draws its own palette from splash-library.js and 9C7C34 / 8F7030 / e4dfd3 are absent from splash.js and splash-library.js.
paths: app/ui/splash.css app/ui/index.html app/ui/fonts/fonts.css app/ui/splash.js app/ui/splash-library.js
teammate: echo-opus-sp1
worktree: /Users/alex/ab/richos-wt/echo-opus-sp1
written: 2026-09-01T20:37:32Z
