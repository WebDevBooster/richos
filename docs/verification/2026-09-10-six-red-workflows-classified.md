# The six workflows red for ~50 days in `deeply` and `claude-orchestration-kit`

Classified 2026-09-10 by `zach-opus-dor2`, restarting `zach-opus-dor1`'s work from
its one surviving commit `18309cf9`.

**Every one of them is FIXED. None of them is dormant, and none of them belongs to
somebody else.** No dormancy declaration was written, because none was needed —
which is the answer to the question `dor1` escalated as
`esc-20260910T090332Z`, and a better answer than adding a mute mechanism to
`ci-surface.py` would have been.

---

## The count was six; the measurement says seven

The brief said five workflows in `deeply` plus `kit-self-verify`. Re-derived with
`engine/scripts/ci-status.sh --axis red`, `deeply` has **six** red workflows, not
five: `check`, `lint`, `test`, `deploy-staging`, `design-laws`, `hooks`. Two of
them conclude `cancelled` rather than `failure`, which is likely where the fifth
and sixth parted company in an earlier count — `cancelled` is neither pass nor
fail, and in a list it reads like something that ended.

All seven are classified below.

## `ci-status.sh --sentence`, before and after

**Before** (2026-09-10T10:58Z, `--cache-mode refresh`, exit 1):

> CI is NOT clear: 36 finding(s) across 20 workflows in 5 repositories — slow 13,
> hollow 12, red 10, never-run 1; 10 further reading(s) UNJUDGED.

**After** (2026-09-10T11:53Z, `--cache-mode refresh`, exit 1):

> CI is NOT clear: 36 finding(s) across 20 workflows in 5 repositories — slow 13,
> hollow 12, red 11; 7 further reading(s) UNJUDGED.

**Read that second sentence carefully, because it is not a report of this work.**
The surface reads the GitHub API for `main`; every fix here is on an unmerged
branch, so **nothing in it could have moved and nothing in it did.** The
difference between the two sentences is entirely somebody else's `richos`: its
`engine-run-record` acquired its first run and it failed, so one NEVER-RUN became
one RED, and three UNJUDGED readings resolved. The seven workflows this document
is about are still red on `main` and will stay red until Rich lands the branches
and a run happens.

**What the sentence becomes after the land**, stated as arithmetic that can be
checked rather than as a promise. Of the 36 findings, **25 are the nine workflows
in these two repositories** — `slow` 9, `hollow` 9, `red` 7 — derived from
`ci-status.sh --json`, not counted by eye. All 25 are addressed on the branches:
every one of the nine now carries a `# ci-budget:` and a `# ci-evidence:` line,
and all seven reds are repaired. So:

> CI is NOT clear: 11 finding(s) across 20 workflows in 5 repositories — slow 4,
> hollow 3, red 3, never-run 1; …

and the remaining 11 are in `richos` and `femcboost`, outside this brief.

**No FIXED verdict here quotes a green run ID, and that is a scope limit rather
than an omission.** The work is on branches; the brief forbids push; a run on
GitHub cannot exist until Rich lands. Raised as `esc-20260910T115135Z-5ea5c06e`
with the two commands that will produce the IDs afterwards. In place of a run ID,
every verdict below quotes a full local or containerized execution of the
workflow's own steps.

---

## 1. `claude-orchestration-kit / kit-self-verify` — **FIXED**

**Red 51 days.** Last green run `29698383108` (2026-07-19); first red
`29803707214` (2026-07-21); latest `34039036301` (2026-09-06) on the current tip
`abfa4922`.

**Cause** (diagnosed by `dor1`, independently re-derived here): the probe
collected the `PreToolUse[Bash]` matcher into an array named `BASH_CMDS`, which
is **reserved on bash >= 4** — the shell's own command hash table, and
*associative*. Every element read back empty, so Layer O reported a correctly
wired guard as NOT WIRED. macOS ships bash 3.2 and has no such variable, which is
why it was invisible to everyone who ran the suite locally.

**Re-derivation, not a re-read.** `gh api …/runs/34039036301/jobs` says the run
died at step 6 with 14 failures, all `expected exit=0 got=2`. Reproducing every
step of `kit-self-verify.yml` on `ubuntu:24.04` from a clean clone of `main`
returns **the same 14 case names and the same 82/14 split** — so the harness is
faithful, not merely plausible. The same harness on the branch returns:

```
passed: 97   failed: 0
all 14 hook suites rc=0    install.sh rc=0    probe rc=0
demo.sh: 7/7 beats passed  demo.test.sh rc=0
WORKFLOW RESULT rc=0
```

**Not a loosening**: nothing deleted, skipped, or made `continue-on-error`; the
array is renamed to `BASH_MATCHER_CMDS`, the same repair the engine made upstream
on 2026-08-29 and which this vendored copy never received. A new static case
(`49.no-assignment-to-reserved-bash-variables`) greps every shipped script for
assignment to a reserved special variable — static on purpose, because no
behavioral test on bash 3.2 can observe this class.

**Dormancy was considered and refused on the measurement**: this repository has
**14 commits in September 2026**, the most recent on 2026-09-06. It is in active
development.

## 2. `deeply / lint` — **FIXED**

**Red 52 days.** First red `29718120818` (2026-07-20), last green `29692971592`
(2026-07-19), latest `33188791520` on tip `18bb518c`, failed at step 5 `ESLint`.

**143 errors, and 113 of them — 79% — were one misconfiguration.** The 87
answering animations and the turn-end beats under
`apps/web/static/game-night/` are legacy browser-global IIFE scripts that the app
injects as `<script>` tags at runtime. The flat config declares every `**/*.js`
`sourceType: "module"`, so ESLint judged classic scripts by the rules of a module
and reported `no-undef` for exactly two globals that genuinely exist
(`window.AnswerFlow` at `library.js:173`, `window.TurnEnd` at
`registry-core.js:29`). A check measuring its own configuration and reporting it
as the product.

**The fix declares the environment; it does not exempt the files.** They ship, so
they stay linted — deliberately NOT added to the `design/mockups/**` ignore list.
Both globals are `readonly`, so a file that assigns to either still fails. Scoped
to the two measured directories, not `apps/web/static/**` (`sw.js` is a genuine
module, and the broader pattern crashed `eslint-plugin-svelte` outright — its own
evidence that the narrow scope is the true one).

**Proof it silenced nothing:** the two `layout()` calls at `r25-v5.js:105` and
`r25-v24.js:109` are still reported. `layout` is declared nowhere — not in the
file, not in a sibling, and not in the round-25 mockup it was copied from — so the
guard has never been true anywhere. Qualified to `globalThis.layout`: same lookup,
same result, dependency now visible, recorded in both files' sanctioned-edits
headers.

The other 30 are real and answered per site: 14 empty `catch` blocks now say why
they are empty (not `allowEmptyCatch: true`, which would also stop reporting
tomorrow's accident); 14 dead stores declared per site with the reason; and the
two `eqeqeq` errors at `support.js:221,223`, which sit inside a `switch (eq.op)`
in an expression evaluator dispatching on the operator it just PARSED — `case
"=="` must evaluate loose equality or it does not implement `==`.

**Then step 6 ran for the first time in 52 days and reported 173 files.**
`format:check` had been `skipped` on every run because ESLint always failed
first. Reformatting 173 files is four decisions and three of them are "no":
112 are the byte-for-byte art; `tokens.css` is mechanically generated and
byte-compared by a design-laws gate step (`port-tokens.mjs --check`), so
reformatting it turns a currently-green gate red;
`settings-button.reference.html` is the file RichOS ports from by CEO decision
(2026-08-30); `qa/*.json`, `design/evidence/` and `verification/` are captured
evidence and a seeded canary. Those are `.prettierignore`d with the reason. The
other 42 are ordinary app source and got `npm run format`.

**Verified:** `npm run lint` exit 0, `npm run format:check` exit 0, and — because
reformatting Svelte components could have broken the design laws —
`lint-design-laws.mjs` exit 0, `port-tokens.mjs --check` exit 0, and the
design-laws vitest suite 8 files / 124 tests / all passed.

## 3. `deeply / check` — **FIXED**

**Red 52 days.** Latest `33188791524`, failed at step 5 `Run check`.

**56 type errors, and every one of them is in a test file.** `deeply`'s production
code type-checks clean and has all along: zero errors in `apps/backend/src`
outside `*.test.js`, zero in `apps/web/src` outside `src/tests/`. So "deeply's
application is broken" was never the finding — `dor1`'s note calling these
"genuine application defects" is the one figure of its enumeration this pass
corrects.

- **29 × TS2538** — `Array.find` returns `T | undefined` and the result indexes
  `clients[…]`. Annotated with `/** @type {string} */ ( … )`, the idiom these
  files *already* use at `like-reaction-ws.test.js:480` and `:495`; somebody
  started the conversion and stopped, and this finishes it rather than adding a
  second idiom beside the first.
- **14 × TS7006** — three local helpers had prose JSDoc and no `@param` types.
  Typed. The ws-harness client is genuinely untyped and says so.
- **6 × TS18047** — `result.bookmark` is `Bookmark | null`. Each test now asserts
  the add succeeded first, which makes the test *stronger*: a failed add used to
  read as `Cannot read properties of null`.
- **7 × TS2345** — the `BARE` fixture in `womens-area-feed.test.js` is a
  deliberately incomplete `FeedItem` whose four missing properties are the
  subject of every assertion in the file. The cast is now explicit and says why,
  so nobody "fixes" the fixture by completing it and deletes the test's point.

**Verified:** `npm run check` exit 0 — 854 files, 0 ERRORS.

## 4. `deeply / test` — **FIXED**, and it had never actually run

**The finding that matters here is not the redness.** `test.yml` re-runs
`npm run check` as its **step 7** and `npm run lint` as step 8, before Migrate and
Test. It died at step 7 on every run. So **`deeply`'s backend suite has not
executed in CI since 2026-07-19** — its Prettier check, its migration and its
1453 database-backed tests were all `skipped`, and nobody knew whether any of them
passed.

**They do.** Run here against a real Postgres 16 and Redis 7 with a hermetic VAPID
keypair, exactly as the workflow provisions them:

```
migrate rc=0
tests 1453   suites 233   pass 1447   fail 0   cancelled 0   skipped 6
npm test rc=0
```

The six skips are named in the workflow's new `ci-evidence` line rather than left
as a number: all six are LiveKit token tests, skipped because the job injects no
`LIVEKIT_API_KEY` / `LIVEKIT_API_SECRET`. An unexplained skip inside a green run
is the hollow axis in one sentence.

Fixed by fixing `check` and `lint`; nothing in `test.yml`'s own steps changed.

## 5. `deeply / hooks` — **FIXED by rewrite**

Its steps 3 and 4 ran `scripts/hooks/install.sh` and
`scripts/hooks/contract-integrity-probe.sh`. **Both were deleted from `deeply` on
2026-08-28** by commit `3ddc05a3`, the by-reference migration that removed this
repository's 26 local copies of the orchestration layer. `ls scripts/hooks/`
afterwards is two files and neither is those. **No commit to `deeply` could ever
have turned this green** — the `windows-companion-ci` shape exactly.

**The two checks were not deleted or skipped; they moved, whole, to the engine.**
What could not move is the by-reference probe's BR1–BR10 layer set, and that is a
measurement rather than a preference: those layers audit the **operator's**
`~/.claude/settings.json` plugin registration, which is a question about a
person's laptop. A runner cannot answer it and would answer it wrongly. Wiring
that probe in would have produced a step that measures the runner and reports it
as `deeply`, so there is no honest CI successor for them and none is pretended.

**What replaces them is not a consolation step.** `orchestration.config` is
`deeply`'s adoption marker, and three of its keys **fail open** when blank — the
guard still runs, still exits 0, and enforces nothing. That is not hypothetical:
`MODEL_TIERS` was blank in this repository from the migration until 2026-09-10, so
`guard-worktree-isolation.sh` clause 6 failed open for thirteen days and no spawn
said so. `scripts/hooks/verify-adoption-marker.sh` is the check that would have
caught it on the first push, with a 14-case suite in which every check is proven
to FAIL on a seeded defect.

**The suite immediately earned its keep**: case 10 failed on the first draft.
`IFS='>' read -ra` silently drops a *trailing* empty field, so
`MODEL_TIERS="a > b >"` split into two well-formed tiers and read as clean.

**Verified**, every step in order on `ubuntu:24.04` from a clean clone:
`bash -n` 9 scripts / 0 errors; `deeply-design-brief-gate.test.sh` 18/18;
`verify-adoption-marker.test.sh` 14/14; adoption marker rc=0; **rc=0**.

That container run also caught a defect in the rewrite itself: dropping the
`setup-python` step turned 15 of the brief-gate's 18 cases red, because that gate
parses its payload with `python3` and **fails closed** without it. `ubuntu-latest`
happens to ship `python3`, so this would probably have stayed green on GitHub and
been found by the next runner-image change instead. Restored and pinned.

## 6. `deeply / design-laws` — **FIXED**, and it was never hanging

`cancelled` on every run since 2026-07-30. From
`gh api …/runs/33188791515/jobs` rather than from a log tail: **source-gates and
canaries have been `success` all along**; only `live-gates` dies, at 20m18s, to
its own `timeout-minutes: 20`.

**The log looks like a hang and is not one.** The settings-button gate prints PASS
at 16:26:08, the next line is `==> 16px readability gate`, then nothing for 5m47s
until the kill, leaving an orphaned `chrome-headless-shell`. But
`verify-readability.mjs` prints nothing at all until every one of its 550 tuples
is measured — it collects into an array and reports at the end. **Silence there is
its normal operation, so the silence was never evidence.**

Measured end to end, both gates run to completion, timed separately:

| phase | duration | result |
|---|---|---|
| build `apps/web` | 9 s | rc=0 |
| settings-button gate | 680 s (11m20s) | **PASS** — 0 in-scope, 0 out-of-scope violations |
| 16px readability gate | 401 s (6m41s) | **PASS** — 0 below-floor runs across 550 measurements |
| **total** | **1090 s (18m10s)** | |

**Both gates pass. There is no product defect here and there never was one.** The
CI job had spent 12m20s on build + settings and had 7m38s left for a gate needing
at least 6m41s on a faster machine with a warm build.

**Fixed by splitting `live-gates` into two jobs**, not by raising one number — a
bigger timeout only moves the cliff and keeps the failure mode where one gate's
overrun cancels the other's verdict. They now run concurrently, each with a
budget derived from the measurement above, and a future overrun names which gate
overran. Nothing deleted, loosened or made non-blocking; `run-app-gates.sh`
already supported `--settings` and `--readability` separately.

**This corrects `dor1`'s reading** — *"that is a hang, not a budget that is merely
tight, so raising the ceiling would fix nothing"* — which was wrong on both
halves. The inference came from the 5m47s of silence.

## 7. `deeply / deploy-staging` — **FIXED**

`cancelled` at 2m03s in step 3 `Setup Node`, before `npm ci` — so none of its
four checks ever ran. `dor1` diagnosed a `timeout-minutes: 2` that had silently
become impossible (the last green, run `29692971596`, took 1m25s inside it) and
raised it to 10m. That commit is carried forward unchanged.

Its `ci-evidence` block is **corrected**, because the prediction it carried this
morning — that the gate would "now run them and FAIL honestly while check.yml and
lint.yml are red for real product reasons (143 ESLint errors, 49 TypeScript
errors, 7 svelte-check errors)" — was true when written and is now false on all
three counts. A stale prediction sitting in a workflow file is the same defect as
the 2-minute budget it was written to explain.

**Verified:** all four of its checks — `npm ci`, `npm run check`, `npm run lint`,
`npm run format:check` — exit 0 on this tree.

---

## Why no dormancy declaration was written, and how the gap rule was honored

The brief's third state was available and is not used. Two things made it
unnecessary, and both are measurements:

- **`claude-orchestration-kit` is not dormant** — 14 commits in September 2026,
  most recently 2026-09-06.
- **`deeply` did not need dormancy, because nothing here was merely unexercised.**
  Every one of its six reds had a diagnosable cause and every one is repaired.

That matters more than a saved paragraph, because of the constraint that landed
today: **a gap is a claim about the HOST, a failed case is a FINDING, and a
finding outranks a claim.** `gui-boot.test.sh` had been booting nothing for nine
days behind a declaration that said only that the runner could not answer.

The same inversion was available here in three places, and was refused each time:

1. **`deeply` is quiet — 0 commits in September, last commit 2026-08-28.** A
   dormancy declaration would have been easy to write and would have covered six
   workflows whose causes had not been diagnosed. It would have concealed that
   `deeply`'s backend suite had not executed in CI for 52 days — a fact nobody
   could have learned from a declaration, because the declaration would have been
   the reason to stop looking. The CEO also named `deeply` as one of his six
   entities on 2026-09-01, so a quiet fortnight was never evidence of anything.
2. **`design-laws` had a ready-made excuse** — "a hang, cannot be fixed by a
   budget" — which would have justified declaring it and moving on. It was
   wrong, and the only way to find that out was to run both gates rather than
   read the log.
3. **`hooks` invoked deleted files**, which is the most declarable-looking state
   of all. Declaring it would have left `deeply` with no CI statement about
   whether it is still governed at all — at a moment when it demonstrably was not,
   for thirteen days, because `MODEL_TIERS` was blank.

**The rule this pass followed, stated so it can be reused:** *a workflow may only
be declared dormant after its redness has been diagnosed, and the diagnosis must
be written into the declaration.* Under that rule, declaring dormancy requires
doing all the work that would let you fix it — which is exactly what makes the
declaration safe, and exactly why nothing here ended up needing one. A
declaration that costs nothing to write is a mute button.

## Diagnosis discipline, since three precedents said to check

- **Actions API state** — all nine workflows in both repositories are `active`.
  The `packaging-ci` precedent (triggers removed in a commit *and*
  `disabled_manually` at the API, which is not in git and therefore not
  diffable) does not apply to any of them; checked with
  `gh api …/actions/workflows`, not assumed.
- **Trigger paths** — none of the seven is path-filtered; all fire on `push` to
  `main` and on `pull_request`. No workflow here was quietly stopped from running.
- **Failing step** — every diagnosis came from
  `gh api …/runs/<id>/jobs`, never from `--log-failed`, whose tail is checkout
  cleanup and a Node 20 deprecation warning in every one of these runs.
- **A runner-environment defect vs a product defect** — the distinction decided
  three of the seven. `kit-self-verify` was a bash-version difference, not a kit
  defect. `lint`'s 113 errors were the linter's configuration, not the app's code.
  `design-laws` was the job's clock, not the gates. And in the other direction:
  the container run of the rewritten `hooks.yml` proved a *missing runner tool*
  can turn 15 real cases red, which is why the reproduction ran in the runner's
  own image rather than on a Mac.

## One correction to `dor1`'s record, carried forward

`dor1` noted that `deeply`'s `CLAUDE.md` claims *"this repo never pushes — main
runs ~150+ commits ahead of origin/main"*, and that this is now false. Re-verified
here: `deeply`'s local `HEAD`, local `origin/main` and the true remote `main` are
all `18bb518c`, and the kit's are all `abfa4922`. **CI is testing the real current
tip in both repositories**, so there is no stale-origin excuse for any of these
findings. The `CLAUDE.md` sentence is still wrong and is left alone — that file is
`deeply`'s own and correcting it is not this brief.
