sha: 789a0fbf584bf9141220f9ede231393257248036
impact: conflict
detail: Two of the three overlapping files are mine and rewritten: app/ui/style.css and app/ui/splash.css now carry no named platform face, and app/style.css (a stale orphan, loaded by nothing, 348 lines behind its twin) is corrected the same way. If pb1's base predates 443d0c0 his copies still name the removed typeface, so on those three files MINE MUST WIN or the whole point is undone. New directory app/ui/fonts/ (6 woff2 + 4 OFL license files + fonts.css, 300,576 bytes of font); index.html gains one <link> before style.css. Will run the new app/scripts/gui-boot.test.sh and re-run the 19 UI suites now that node_modules exists.
paths: app/ui/style.css app/ui/splash.css app/style.css app/ui/index.html app/ui/fonts/ app/scripts/fonts/ app/ui/tests/splash.js docs/verification/vendored-fonts-2026-09-01/
teammate: zach-opus-ft1
worktree: /Users/alex/ab/richos-wt/zach-opus-ft1
written: 2026-09-01T19:03:33Z
