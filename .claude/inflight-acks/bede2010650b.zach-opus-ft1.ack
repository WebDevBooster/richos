sha: bede2010650bf16227436653d499eff9bb09a0a5
impact: conflict
detail: app/ui/index.html overlaps: my change adds ONE line plus a comment in <head> — a <link rel=stylesheet href=fonts/fonts.css> that must sit BEFORE style.css so the @font-face rules exist before the render-blocking splash needs them. It touches no logo markup, no SVG, no fill, and nothing in <body>; lg2's painted swoosh is untouched by me and must be kept. Not merging main myself per the standing instruction; the resolution is take-both-hunks and they are in different parts of the file. I have changed no color value anywhere and will not touch the 8F7030 light-rail swoosh. app/ui/splash.css: I replaced its three-platform-face stack with var(--font); I did NOT touch splash-library.js or splash.js, so sp1's removal of the seven unapproved compositions is unaffected — no splash ENTRY names a face, only the .splash rule did. appearance.js check 15 passed on my tree (19/19) on the pre-lg2 version; it should be re-run after the merge since my change re-renders every glyph in it.
paths: app/ui/index.html app/ui/splash.css app/ui/style.css app/style.css app/ui/fonts/ app/scripts/fonts/ app/ui/tests/techy.js app/ui/tests/contrast-debt.json app/ui/tests/splash.js docs/verification/vendored-fonts-2026-09-01/
teammate: zach-opus-ft1
worktree: /Users/alex/ab/richos-wt/zach-opus-ft1
written: 2026-09-01T19:48:12Z
