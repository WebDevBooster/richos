# Escalation: A bare `node --test` in richos/web/web-app rewrites six COMMITTED verification screenshots

- id: `esc-20260918T202229Z-4f1ae312`
- raised: 2026-09-18T20:22:29Z
- from: echo-opus-pwaslice3
- worktree: `/Users/alex/ab/richos-wt/echo-opus-pwaslice3` (branch `cc/echo-opus-pwaslice3`)
- head: `11c262648ae8f0469e69e4e2635cd4a9454fe713`
- state: **work-complete**
- for: lead

## The question

Should desktop-verify.js be excluded from Node's default test-file discovery (rename, move out of test/, or default PHONE_SHOTS_DIR to a scratch path), so a brief can safely say 'node --test'?

## What was already tried

Reproduced deterministically three times at 4cee7dd7 and on my branch. Node's default test-file matcher includes every .js under test/, so a bare 'node --test' RUNS test/desktop-verify.js; with PHONE_SHOTS_DIR unset its SHOTS_DIR (desktop-verify.js:72-73) is the COMMITTED docs/verification/phone-app-2026-09-18/, and six of its ten PNGs come back byte-different -> six modified tracked files. Control: 'node test/desktop-verify.js --chromium' WITH PHONE_SHOTS_DIR set leaves docs/ untouched (git status clean, mtimes unchanged). The package's own script is already correct: npm test = node --test "test/*.test.js" (132 pass) and never touches docs/. Also worth a look: under 'node --test' the harness reported a green tick in 9.6s and wrote both engines' shots 6s apart, which is far too fast for the real two-engine run it takes ~150s to do standalone - so that tick may be green over a run that checked very little.

## Proceeding meanwhile

My three commits are done and my worktree is clean; I restored the six PNGs every time and committed none of them. I used PHONE_SHOTS_DIR for every deliberate harness run.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T202229Z-4f1ae312`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T202229Z-4f1ae312 --disposition "<what you decided or did>"
