# The `codex/` merge inventory, extracted from `main`'s reflog before it can be lost

**Author:** Reed (source-reading and knowledge-extraction). **Date:** 2026-09-14.
**Repositories:** `richos`, `femcboost`, `richos-hq`.
**Primary source read in full:** `docs/verification/codex-branch-merge-provenance-2026-09-14.md`
(511 lines, landed at richos `9f624531`). **This document is not a copy of it.** Every number here
was re-derived from the live repositories, and the commands are printed beside the numbers.

**Extraction only. Nothing was mutated.** Attestation with before/after evidence is section 10.

---

## 1. Conclusions

1. **The landed record's 165 reproduces exactly — and it is not the whole number.** Summing the
   branch-side payload of all 36 reflog-named `codex/` merges gives **135 + 28 + 2 = 165**, commit
   for commit. The record's arithmetic is sound. What is incomplete is its *inventory*, because its
   method — reading reflog entries of the form `merge codex/<name>:` — is blind to a merge that git
   records as `commit (merge)`.

2. **Two further merge operations brought `codex/` work onto `richos` `main`, and neither appears in
   the landed record's tables.** Both are in the reflog; both are recorded as `commit (merge)`, which
   is what git writes when a merge is concluded by `git commit` (a conflicted merge) — and **that
   form does not record the branch name**. Together they carry **20 more commits** (17 of them
   non-merge). Corrected `richos` figure: **155 branch-side commits**, not 135. Corrected grand
   total: **185**, not 165.

3. **The passenger claim in the landed record is FALSE, and the truth is worse for the record, not
   better.** `codex/durable-orchestration` — the branch an architect recommended rejecting — did
   **not** arrive as a passenger inside `codex/workspace-retirement-safety`'s merge. It arrived
   **44 minutes earlier, through its own dedicated merge operation `727d8890`**
   (2026-09-06 03:51:10 +0100), carrying **16 commits**. The record reached its conclusion from an
   *ancestry* test (`merge-base --is-ancestor 55728e67 f201e904` exits 0), and ancestry cannot
   identify which merge introduced a commit — it is true of every merge that came afterward. The
   test that settles it is ancestry against the **pre-merge value of `main`**, and it is in 4.1.

4. **No `codex/` branch reached `main` as a passenger.** After a mechanical sweep of every commit
   message on `main` naming a `codex/` branch (section 5), exactly two such names exist —
   `codex/automatic-worktree-retirement` and `codex/durable-orchestration` — and each was merged by
   an operation of its own. The passenger class the brief expected to be undercounted is **empty**.
   The undercount is in a different class: the merge whose reflog entry carries no branch name.

5. **A separate, genuine undercount does exist: 7 Codex commits reached `richos` `main` on Sage's
   `sage-fable-r*` review branches, never touching a `codex/` branch.** The landed record names 4 of
   them. Six are named explicitly in a merge or review subject; the seventh is inferred from the
   commit chain and is marked as inference (section 6). These are outside the 185 and outside the 165.

6. **Nothing has expired, so this is a deadline met rather than missed.** `richos`'s oldest `main`
   reflog entry is still `2026-08-29 10:25:23 +0100` — identical to the horizon the landed record
   reported hours earlier, so no entry has been lost. `gc.reflogExpire` reads `never` in all three
   repositories, verified in section 9.

7. **One row is UNDETERMINED and no repository can resolve it.** The 2026-08-30 `richos` merge
   `7714871a` ("Merge Codex 9/10") brought Codex work whose **branch name was never recorded
   anywhere** — not in the reflog, not in the merge message, not in the back-merge message, which
   says only "the slice 9/10 branch". Whether that branch carried a `codex/` prefix is unknowable.
   **UNDETERMINED count: 1.**

8. **The brief's premise that branch name and reflog are "the only two discriminators" is not quite
   right — there is a third, and it is the durable one.** Back-merge commits of the form
   `Merge branch 'main' into codex/<name>` are ordinary commit objects on `main`: they survive branch
   deletion, reflog expiry and cloning. One of them is what let me date the durable-orchestration
   merge after both its branch and its reflog naming were gone. It is only a *partial* discriminator
   — it exists solely where somebody merged `main` into the branch — but unlike the other two it does
   not perish.

---

## 2. Method

Read-only throughout: `git reflog show`, `git log`, `git rev-list`, `git merge-base --is-ancestor`,
`git branch --list`, `git config --get`, and `grep` against `.git/logs/refs/heads/main`. No branch
deleted, no ref moved, no worktree touched, no `gc`, no checkout, no clone.

Two sources, used differently:

- **`.git/logs/refs/heads/main`, read as a file.** Each line is `<old> <new> <who> <when>` then a tab
  then the message, so the **before and after tip of every operation is on the line itself** — no
  reconstruction from neighboring entries, which is where an off-by-one would hide.
- **Commit messages on `main`**, swept with `git log --grep`, to recover branch names the reflog does
  not carry.

**Two payload figures are reported per row and they mean different things.** `total` is
`git rev-list --count <old>..<new>` — every commit that became reachable from `main` at that
operation, including the merge commit git created. `branch-side` excludes that merge commit: it is
the work that came from the branch. **The landed record's 165 is a branch-side figure**, so every
comparison below is branch-side and like-for-like.

**On the `richos` horizon.** The oldest `main` reflog entry is 2026-08-29 10:25:23 +0100
(`git -C /Users/alex/ab/richos reflog show main --date=iso | tail -1`; 451 entries in total). Any
`codex/` merge into `richos` `main` before that date is invisible to every method in this document.
`femcboost` covers its whole life (oldest entry `export from jj`, epoch 1782539790 = 2026-06-27);
`richos-hq` covers its whole life as a clone (2026-08-20 03:56:43 +0100).

---

## 3. Inventory: merges the reflog names by branch

### 3.1 `richos` — 20 named operations, 12 distinct branches, 135 branch-side commits

Source: `git -C /Users/alex/ab/richos reflog show main --date=iso | grep -i codex` returns **22**
lines, of which 20 are `merge codex/<name>:`. (Of the other two, one is an ordinary commit whose
message happens to mention Codex, `b6702faf`; the other is the unnamed merge in 4.2.) Before/after
tips read from `grep -i codex /Users/alex/ab/richos/.git/logs/refs/heads/main`.

| # | Before | After | When (+0100) | Branch | Kind | total | branch-side | Branch today |
|---|---|---|---|---|---|---|---|---|
| r01 | `727d8890` | `f201e904` | 2026-09-06 04:35:34 | `codex/workspace-retirement-safety` | ort | 2 | 1 | **deleted** |
| r02 | `486e982a` | `381907f4` | 2026-09-06 16:13:02 | `codex/session-evidence-reliability` | ort | 7 | 6 | **deleted** |
| r03 | `82c90f0c` | `542d070f` | 2026-09-06 20:04:16 | `codex/orchestrator-dispatch-recovery` | ort | 3 | 2 | **deleted** |
| r04 | `00326dd2` | `978cd749` | 2026-09-06 20:38:14 | `codex/publication-attribution-recovery` | ort | 2 | 1 | **deleted** |
| r05 | `eea938fd` | `8c777abc` | 2026-09-07 06:53:51 | `codex/process-identity-safety` | fast-forward | 18 | 18 | **deleted** |
| r06 | `8c777abc` | `7f9077f0` | 2026-09-07 09:16:51 | `codex/andreas-client-audit` | fast-forward | 22 | 22 | **deleted** |
| r07 | `7f9077f0` | `ace48e5e` | 2026-09-07 14:41:44 | `codex/automatic-worktree-retirement` | fast-forward | **67** | 67 | **deleted** |
| r08 | `ace48e5e` | `8c999b55` | 2026-09-07 15:54:57 | `codex/automatic-worktree-retirement` | fast-forward | 6 | 6 | **deleted** |
| r09 | `8c999b55` | `2af1accf` | 2026-09-07 17:33:17 | `codex/automatic-worktree-retirement` | fast-forward | 1 | 1 | **deleted** |
| r10 | `2af1accf` | `aec8ae7f` | 2026-09-07 17:39:11 | `codex/automatic-worktree-retirement` | fast-forward | 1 | 1 | **deleted** |
| r11 | `aec8ae7f` | `a279a587` | 2026-09-07 18:07:28 | `codex/automatic-worktree-retirement` | fast-forward | 1 | 1 | **deleted** |
| r12 | `53292e6a` | `28f07ab5` | 2026-09-08 12:43:21 | `codex/daily-idle-cleanup` | fast-forward | 1 | 1 | **deleted** |
| r13 | `f3f6a29b` | `7598d7ef` | 2026-09-09 18:10:40 | `codex/owned-outcome-completion` | fast-forward | 1 | 1 | exists |
| r14 | `7598d7ef` | `9e3d2edb` | 2026-09-09 18:46:58 | `codex/owned-outcome-live-repair` | fast-forward | 1 | 1 | exists |
| r15 | `9e3d2edb` | `8e7e521e` | 2026-09-09 18:50:26 | `codex/owned-outcome-live-repair` | fast-forward | 1 | 1 | exists |
| r16 | `8e7e521e` | `ed88e290` | 2026-09-09 19:50:26 | `codex/resumable-outcome-verification` | fast-forward | 1 | 1 | exists |
| r17 | `ed88e290` | `1bd9f688` | 2026-09-09 19:54:11 | `codex/resumable-outcome-verification` | fast-forward | 1 | 1 | exists |
| r18 | `0e865973` | `984f72e9` | 2026-09-09 22:44:28 | `codex/rollback-owned-outcome` | fast-forward | 1 | 1 | exists |
| r19 | `984f72e9` | `8397c530` | 2026-09-09 22:53:12 | `codex/rollback-owned-outcome` | fast-forward | 1 | 1 | exists |
| r20 | `8397c530` | `90d7f774` | 2026-09-09 22:55:08 | `codex/rollback-owned-outcome` | fast-forward | 1 | 1 | exists |

**Branch-side total: 135.** Merge commits created: 4 (r01 to r04). Total commits added: 139.

The commands behind the figures that carry the most weight:

```
$ git -C /Users/alex/ab/richos rev-list --count 7f9077f0..ace48e5e
67
$ git -C /Users/alex/ab/richos rev-list --count --merges 7f9077f0..ace48e5e
1
$ git -C /Users/alex/ab/richos rev-list --count eea938fd..8c777abc
18
$ git -C /Users/alex/ab/richos rev-list --count 8c777abc..7f9077f0
22
$ git -C /Users/alex/ab/richos rev-list --count 486e982a..381907f4
7
```

**The single merge commit inside r07's 67** is `3f8189d8 Merge branch 'main' into
codex/automatic-worktree-retirement` — `main` went into the branch and came back out. So r07 is 66
Codex-side commits plus one round trip. Per-commit lists are in the appendix, section 11.

**Branch survival:** `git -C /Users/alex/ab/richos branch --list 'codex/*'` returns 5 —
`owned-outcome-completion`, `owned-outcome-live-repair`, `owned-outcome-prd`,
`resumable-outcome-verification`, `rollback-owned-outcome`. Of the 12 branches in the table above,
**8 are gone**; adding `codex/durable-orchestration` (4.1, also gone) makes **9 deleted out of 14
distinct names ever seen**, which reproduces the count relayed in the brief.

### 3.2 `femcboost` — 14 named operations, 10 distinct branches, 28 branch-side commits

Source: `git reflog show main --date=iso | grep -i codex`, run from the femcboost worktree, returns
14 lines, **all 14** of the form `merge codex/<name>:`. And
`grep -c 'commit (merge)' /Users/alex/ab/femcboost/.git/logs/refs/heads/main` returns **0**, so this
repository has no merge of any kind whose branch name the reflog failed to record.

| # | Before | After | When (+0100) | Branch | Kind | total | branch-side | Branch today |
|---|---|---|---|---|---|---|---|---|
| f01 | `a1da63489` | `ea3af3c10` | 2026-08-27 19:23:07 | `codex/ecs-dogfood` | ort | 10 | 9 | **deleted** |
| f02 | `0b5df5dc4` | `9ce806242` | 2026-09-06 14:41:12 | `codex/ecs-terminal-continuity` | ort | 4 | 3 | **deleted** |
| f03 | `9ce806242` | `ae66229ba` | 2026-09-06 15:22:48 | `codex/ecs-followup-reliability` | ort | 2 | 1 | **deleted** |
| f04 | `ae66229ba` | `305758a54` | 2026-09-06 15:28:12 | `codex/ecs-followup-reliability` | ort | 2 | 1 | **deleted** |
| f05 | `305758a54` | `fc9c6854a` | 2026-09-06 15:58:02 | `codex/ecs-followup-reliability` | ort | 2 | 1 | **deleted** |
| f06 | `fc9c6854a` | `34b560897` | 2026-09-06 16:38:10 | `codex/ecs-followup-reliability` | ort | 2 | 1 | **deleted** |
| f07 | `55ddb72a8` | `e6439e12e` | 2026-09-06 20:02:02 | `codex/ecs-session-start-recovery` | ort | 3 | 2 | **deleted** |
| f08 | `e6439e12e` | `316f90ab1` | 2026-09-06 20:39:05 | `codex/publication-attribution-recovery` | ort | 2 | 1 | **deleted** |
| f09 | `a536982cc` | `6dfb39628` | 2026-09-07 06:54:04 | `codex/orchestration-system-acceptance` | fast-forward | 4 | 4 | **deleted** |
| f10 | `6dfb39628` | `2f68d0d21` | 2026-09-07 07:00:00 | `codex/orchestration-system-acceptance` | fast-forward | 1 | 1 | **deleted** |
| f11 | `2f68d0d21` | `da2dad066` | 2026-09-08 11:59:04 | `codex/ecs-completion-delivery` | fast-forward | 1 | 1 | **deleted** |
| f12 | `1ec7f6dba` | `4e6bc5695` | 2026-09-09 11:34:41 | `codex/structural-failure-report` | ort | 2 | 1 | exists |
| f13 | `4e6bc5695` | `415cf3791` | 2026-09-09 17:51:07 | `codex/inherited-publication-failure-report` | ort | 2 | 1 | exists |
| f14 | `34d23cf6d` | `91a23fa28` | 2026-09-09 22:47:54 | `codex/rollback-owned-outcome` | fast-forward | 1 | 1 | exists |

**Branch-side total: 28.** Merge commits created: 9. Total commits added: 37.

```
$ git rev-list --count a1da63489..ea3af3c10        # run from the femcboost worktree
10
$ git rev-list --count --merges a1da63489..ea3af3c10
1
$ git rev-list --count a536982cc..6dfb39628
4
```

**Branch survival:** `git branch -a` shows 3 `codex/*` refs — `structural-failure-report`,
`inherited-publication-failure-report`, `rollback-owned-outcome`. **7 of 10 deleted.**

### 3.3 `richos-hq` — 2 named operations, 2 distinct branches, 2 branch-side commits

| # | Before | After | When (+0100) | Branch | Kind | total | branch-side | Branch today |
|---|---|---|---|---|---|---|---|---|
| h01 | `6b1943006` | `2c507072` | 2026-08-27 17:14:05 | `codex/ecs-architecture` | fast-forward | 1 | 1 | **deleted** |
| h02 | `32adc6256` | `d11a8fe7` | 2026-09-09 22:54:20 | `codex/rollback-owned-outcome` | fast-forward | 1 | 1 | exists |

`2c507072 docs: define Executive Continuity System architecture`;
`d11a8fe7 Record the orchestration rollback in affected dependency rows`.

**1 of 2 deleted.** `richos-hq` has 6 `commit (merge)` reflog entries; all six were read and none
involves Codex — they are `feat/voice-pipeline-2026-08-24`, `fix/action-ledger-writers-2026-08-24`,
`docs/obsidian-graph-detail-shots-2026-08-25`, `iris/baseline-b-r1`, `zach/cold-open-2026-08-29` and
`zach-opus-prem1`.

---

## 4. The two operations the landed record's method cannot see

Both are in `richos`. Both are recorded by git as `commit (merge)` rather than `merge <branch>:`,
which is what the reflog writes when a merge stops for conflicts and is finished with `git commit`.
**In that form the branch name is not written to the reflog at all.** `richos` has 36 such entries in
`main`'s reflog (`grep -c 'commit (merge)' /Users/alex/ab/richos/.git/logs/refs/heads/main` returns
36); all 36 were read, and these two are the only ones carrying Codex work.

### 4.1 `727d8890` — `codex/durable-orchestration`, merged in its own right, 16 commits

Reflog line, read from the file:

```
$ grep -i 'durable orchestration' /Users/alex/ab/richos/.git/logs/refs/heads/main
f221114862787d7757c6dcf0c8eb944ad1770a8b 727d8890184ce31f44cdaacc75ffcd1dde6ad406 \
  Alex Booster <webdevbooster@gmail.com> 1788663070 +0100	commit (merge): Merge verified \
  durable orchestration into main
```

```
$ git -C /Users/alex/ab/richos show -s --format='%H %ci %P%n%s' 727d8890
727d8890184ce31f44cdaacc75ffcd1dde6ad406 2026-09-06 03:51:10 +0100 \
  f221114862787d7757c6dcf0c8eb944ad1770a8b a3a55d9506e17c6bfda590eb5c228842d9f15691
Merge verified durable orchestration into main
$ git -C /Users/alex/ab/richos rev-list --count f2211148..727d8890
16
```

**The branch is named in a commit object, not in the reflog.** The second commit inside the payload
is `55728e67 Merge branch 'main' into codex/durable-orchestration` (2026-09-06 03:45:52 +0100). That
message is the only surviving artifact that ties this merge to the branch, and it will outlive both
the branch ref (already deleted) and the reflog.

**The test that disproves the passenger claim.** The landed record argued that
`codex/workspace-retirement-safety`'s merge `f201e904` carried durable-orchestration in, because
`55728e67` is an ancestor of `f201e904`. It is — but `727d8890` is `f201e904`'s own first parent, so
that would be true no matter which merge introduced it. The discriminating test is against the value
`main` held **before** each merge:

```
$ git -C /Users/alex/ab/richos merge-base --is-ancestor 55728e67 f2211148 ; echo $?
1        # NOT in main before 727d8890
$ git -C /Users/alex/ab/richos merge-base --is-ancestor 63e93acb f2211148 ; echo $?
1        # NOT in main before 727d8890
$ git -C /Users/alex/ab/richos merge-base --is-ancestor 63e93acb 727d8890 ; echo $?
0        # in main as of 727d8890
$ git -C /Users/alex/ab/richos merge-base --is-ancestor d083a2e6 727d8890 ; echo $?
0        # in main as of 727d8890
```

`d083a2e6` and `63e93acb` are the two `codex/durable-orchestration` heads named in Sage's round-2 and
round-6 verdicts. **Both entered `main` at `727d8890` on 2026-09-06 at 03:51:10 — through a merge of
their own branch, 44 minutes before `f201e904`, not as a passenger inside anything.**

Independent corroboration from a third commit object: `9d1c07e7` (2026-09-06 05:23:55), a Land commit
on `main`, whose body contains the line `codex/durable-orchestration landed.`

```
$ git -C /Users/alex/ab/richos show -s --format='%B' 9d1c07e7 | grep -i -n codex
4:codex/durable-orchestration landed.
```

The 16 commits (15 branch-side; 3 of the 16 are merge commits — `727d8890`, `55728e67`, `b524536d`):

```
727d8890 | Merge verified durable orchestration into main            (the merge commit)
a3a55d95 | Record verified main integration and rollback evidence
55728e67 | Merge branch 'main' into codex/durable-orchestration
b524536d | Integrate main with durable orchestration and preserve updater and correction behavior
88fad92c | Clarify assignment history and measure cut-edge indicators
9b6c74dc | Finish assignment history controls and preserve text contrast checks
e276ba3b | Make long decisions readable and project human assignment history
b45145f8 | Make assignment decisions actionable and repair panel review gates
63e93acb | Fix registrar reliability on ordinary Markdown replies
1852ba68 | Detach work registration and bound orchestration recovery
a6b41218 | Keep Rich in front of durable work and repair correction and review recovery
55ea60f7 | Own Rich requests through planning, retries and verified completion
d083a2e6 | Fix managed run governance, visible output and journal recovery
748dd1e0 | Add persistent managed work controller with desktop and terminal hosts
0e484d6c | Revert "Add persistent managed work controller with desktop and terminal hosts"
e1f27c03 | Add persistent managed work controller with desktop and terminal hosts
```

### 4.2 `7714871a` — "Merge Codex 9/10", 6 commits, branch name UNDETERMINED

```
$ grep 'commit (merge)' /Users/alex/ab/richos/.git/logs/refs/heads/main   # one line of 36
a8045403... 7714871a... Alex Booster <webdevbooster@gmail.com> 1788062249 +0100	\
  commit (merge): Merge Codex 9/10 (design in the parent)
$ git -C /Users/alex/ab/richos show -s --format='%H %ci %P' 7714871a
7714871a077d26a667adc2f4d0e5eea302a0e3dd 2026-08-30 04:57:29 +0100 \
  a80454031b2099a39535a7ac619461a67e9c1edf 7aed5fc2ebc93eb9bf0737bb299e4202f97ae6de
$ git -C /Users/alex/ab/richos rev-list --count a8045403..7714871a
6
```

The 6 commits (5 branch-side; 2 of the 6 are merge commits):

```
7714871a | Merge Codex 9/10 (design in the parent)                    (the merge commit)
7aed5fc2 | Merge main into the slice 9/10 branch, and fix the three claims the merge made false
f045afa3 | docs(tests): the header of docs-claims.js miscounted the drift it was written about
c65b2829 | docs(app): slice 10 — the documents corrected, and the join that keeps them correct
aa7d34ef | test(ui): slice 9 — restart, multi-thread and scope, and the ten runs that prove it can fail
bfcc5d59 | fix(ui): a thread's scroll position was restored against the previous thread's DOM
```

**That the content is Codex's is supported, from two independent places.** The merge subject says so
("Merge Codex 9/10"), and `richos-hq`'s own reflog records a commit on the same day,
`RICH-TODOs: Codex 9/10 built; three gaps it exposed are rows` (epoch 1788061452, about 13 minutes
before this merge). A row in `richos-hq/RICH-TODOs.md:1021` later cites `bfcc5d5` — one of these six
— by SHA.

**That the branch was a `codex/` branch is NOT established, and cannot be.** The reflog entry has no
branch name. The merge message has none. The back-merge commit `7aed5fc2` calls it only "the slice
9/10 branch":

```
$ git -C /Users/alex/ab/richos show -s --format='%B' 7aed5fc2 | head -1
Merge main into the slice 9/10 branch, and fix the three claims the merge made false
```

**This row is UNDETERMINED for branch name and branch-prefix. It is determined for payload (6
commits), date, before tip and after tip.** It is counted in the corrected `richos` figure below as
Codex work, and excluded from any count of `codex/`-prefixed branches. I did not look for the name in
any agent transcript or state file outside the repositories; that is the one place it might still
exist, and it is named in section 8 as the open lead.

---

## 5. Passengers: the sweep, and why the list is empty

A passenger is a branch whose commits reached `main` inside another branch's merge, so that it never
appears in a merge inventory. With a single author identity across all 2,679 commits on `richos`
`main`, a passenger branch can only be detected where **its name is written into a commit object** —
in practice a `Merge branch 'main' into <branch>` back-merge, or a `Merge branch '<branch>'` subject.
That sweep is mechanical and exhaustive over `main`:

```
$ git -C /Users/alex/ab/richos log main --format='%h %ci | %s' --grep='codex/' -i
```

Across all of `richos` `main` this returns **two** commits that name a `codex/` branch as a branch
(the remaining hits are recent prose about Codex in documentation commits, none of them a merge):

| Commit | Date | Names | Reached `main` how |
|---|---|---|---|
| `3f8189d8` | 2026-09-07 09:18:09 | `codex/automatic-worktree-retirement` | inside r07, **its own branch's fast-forward** |
| `55728e67` | 2026-09-06 03:45:52 | `codex/durable-orchestration` | inside `727d8890`, **its own branch's merge** (4.1) |

The same sweep on the other two repositories returns no merge commit naming a `codex/` branch:

```
$ git log main --format='%h %ci | %s' --grep='codex/' -i        # femcboost worktree
415cf3791 ... | Merge codex/inherited-publication-failure-report: ...   (merge f13, named in reflog)
4e6bc5695 ... | Merge codex/structural-failure-report: ...              (merge f12, named in reflog)
2c9406206 ... | Review scaffold: codex/ecs-terminal-continuity scope and plan   (not a merge)
d2d85a91e ... | docs(reviews): Sage verdict on the two Codex startup-recovery branches
$ git -C /Users/alex/ab/richos-hq log main --format='%h %ci | %s' --grep='codex/' -i
# nine hits, all Sage verdict documents about codex/durable-orchestration; no merge commit
```

**Conclusion: the passenger list is empty.** Every `codex/` branch whose name survives anywhere on
`main` was merged by an operation dedicated to it. The landed record's single passenger claim was the
result of an ancestry test that cannot support the conclusion drawn from it, and it is disproved in
4.1.

**The honest limit of this result, stated rather than rounded away.** A passenger branch that was
never back-merged and whose name was never written into a commit message leaves *no* trace once its
ref is deleted. I cannot rule that class out; I can only say that no evidence of any member of it
exists. That is a weaker statement than "there were none", and I am not making the stronger one.

---

## 6. Codex commits that arrived on review branches (not `codex/` branches)

This is a real undercount, and it is not the passenger class — the carrying branches are Sage's
review branches, which were merged by name in the ordinary way. The Codex content inside them is what
goes unnamed.

```
$ grep -i 'sage-fable-r' /Users/alex/ab/richos/.git/logs/refs/heads/main
86906b95 -> 0c931279 | merge sage-fable-r1: Merge made by the 'ort' strategy.
b6702faf -> 8af9365f | merge sage-fable-r2: Merge made by the 'ort' strategy.
a1d92c4c -> e9e02441 | merge sage-fable-r3: Merge made by the 'ort' strategy.
e9e02441 -> 533633cb | merge sage-fable-r4: Merge made by the 'ort' strategy.
4a6746a5 -> 3be0364a | merge sage-fable-r5: Merge made by the 'ort' strategy.
3be0364a -> 6d32916d | merge sage-fable-r6: Merge made by the 'ort' strategy.
6d32916d -> f3f6a29b | commit (merge): Merge sage-fable-r7: owned-outcome revision 7 ...
```

r1, r2 and r3 carried review documents only. r4 through r7 carried Codex's owned-outcome revisions:

| Codex commit | Subject | Named as Codex's by |
|---|---|---|
| `b80f9978` | Retain authorized outcomes across RichOS intake and native Claude stops | `4e4608c0` "Review b80f9978: the CEO-ask gate was switched off, not reconciled" |
| `2b9d7122` | Restore dependency guards and verify native continuation with execution receipts | **not named anywhere — inference only** |
| `5f519822` | Repair native continuation boundaries and reuse registrar for dispatch decisions | `e9e02441` "Merge sage-fable-r3: the third review — merge 5f519822" |
| `e0679a55` | Complete owned work with recorded authority and exact permission recovery | `533633cb` "Merge sage-fable-r4: **Codex's** owned-outcome revision 4 ... merge e0679a55" |
| `d8afbc1f` | Preserve native delegation and recover owned work across restarts | `8646f407` "Review **Codex's** owned-outcome revision 5 (d8afbc1f)" |
| `125906f5` | Reconcile restarted ownership immediately and surface withheld recovery | `ba91a881` "Review **Codex's** owned-outcome revision 6 (125906f5)" |
| `0c0d2b43` | Fence native audit ownership and finish crash recovery | `f3f6a29b` "Merge sage-fable-r7: owned-outcome revision 7" |

**Six named, one inferred, seven in total.** The landed record's section 9 names four
(`e0679a55`, `d8afbc1f`, `125906f5`, `0c0d2b43`) — the head of each revision — and misses the three
earlier commits of revision 4's chain, two of which are named by their own review subjects.

**Labeled as inference:** `2b9d7122` sits in the contiguous chain
`b80f9978 -> 2b9d7122 -> 5f519822 -> e0679a55`, between two commits that reviews name as Codex's
owned-outcome work, and shares their subject style. I treat it as Codex's on that basis and nothing
stronger. If only explicitly named commits are counted, this class is **6**, not 7.

**Excluded after checking, so the exclusion is on the record.** Three other merges on `richos` `main`
match a case-insensitive grep for "Codex" and are **not** Codex work: `5eb6d1e2` and `262519e2` are
`echo/*` branches describing a "Codex-inspired" and "Codex-UX" design influence on RichOS's own UI,
and `e95af786`/`9d1c07e7` are Land commits whose bodies mention the durable-orchestration landing
already counted in 4.1.

---

## 7. The counts, next to the landed record's 165

| Class | `richos` | `femcboost` | `richos-hq` | Total |
|---|---|---|---|---|
| **A.** Branch-side commits from reflog-named `codex/` merges | 135 | 28 | 2 | **165** |
| Merge commits created by those operations | 4 | 9 | 0 | 13 |
| **B.** Branch-side commits from unnamed (`commit (merge)`) codex merges | 20 | 0 | 0 | **20** |
| **A + B — commits on `main` that came from a `codex/` branch** | **155** | **28** | **2** | **185** |
| **C.** Codex commits arriving on `sage-fable-r*` review branches | 7 | 0 | 0 | **7** |
| **A + B + C — Codex-originated commits on `main`, all routes** | **162** | **28** | **2** | **192** |
| Merge operations (named) | 20 | 14 | 2 | **36** |
| Merge operations (named + unnamed) | 22 | 14 | 2 | **38** |
| Distinct `codex/` branch names seen | 14 | 10 | 2 | 26 |
| Distinct `codex/` branches deleted | 9 | 7 | 1 | 17 |
| **UNDETERMINED rows** | **1** | 0 | 0 | **1** |

**Where B's 20 comes from:** 15 branch-side from `727d8890` (4.1) plus 5 branch-side from `7714871a`
(4.2). Row B for `richos` is 20 branch-side out of 22 commits added in total; the difference is the
two merge commits git created.

**The difference from the landed record, stated plainly.** Its 165 is right for the class it
measured — branch-side commits from merges the reflog names. It is **20 short** of the commits that
came from a `codex/` branch, and **27 short** of Codex-originated commits on `main` by any route. Its
own section 9 says "the 165 is therefore a floor, not a total", which is correct; this document
measures how far above the floor the ceiling sits, for every route that leaves evidence.

**Double counting was checked, not assumed.** All ranges in class A are contiguous and
non-overlapping by construction (each row's `before` is a value `main` actually held). `727d8890`
ends at `f2211148..727d8890`, immediately before r01's range begins at `727d8890`; `7714871a` is
2026-08-30, before every other operation; the `sage-fable-r*` ranges (2026-09-09 10:47 to 17:24) sit
between r12 (2026-09-08) and r13 (2026-09-09 18:10). No commit is counted twice.

---

## 8. Inference and synthesis — my reading, kept separate from the citations above

Everything in sections 3 to 7 is a command output or a quoted commit message. The following is not.

- **The blind spot is structural, and it will recur.** A merge that hits a conflict is finished with
  `git commit`, and git then writes `commit (merge)` with no branch name. So the *harder* a merge was
  — the more the branch had diverged, the more review it plausibly got — the *less* the reflog
  records about it. Both of the merges the landed record missed were conflicted merges of
  substantial branches. Any future inventory that greps for `merge codex/` will miss exactly the
  merges that mattered most.
- **A third discriminator exists and nobody is relying on it.** A back-merge commit message is a
  permanent object on `main`. It named `codex/durable-orchestration` for me after the branch and the
  reflog naming were both gone. It is partial — it exists only where `main` was merged into the
  branch — but it is the only evidence in this class that does not expire, and it is free. Making
  `Merge branch 'main' into <branch>` messages non-optional would give future audits a durable
  index that costs nothing.
- **The one-commit fast-forward sequence on 2026-09-09 is functionally committing to `main`.** Eight
  operations, each moving `main` by exactly one commit, through branch names that existed briefly.
  I agree with the landed record's reading of this and re-derived the payloads independently
  (r13 to r20, all 1).
- **The remaining lead on the UNDETERMINED row.** The slice 9/10 branch name is absent from all three
  repositories. If it exists anywhere it is in an agent transcript, a session state file or the
  worktree ledger under `~/.claude/`. The landed record already reports that
  `~/.claude/state/worktree-ledger.jsonl` contains no row matching `codex`, so the ledger will not
  answer it; transcripts were outside my scope and I did not read them.

---

## 9. Conflicts, gaps, and what expires when

**Conflict with the landed record, resolved by re-derivation rather than recency.** Both documents
are dated 2026-09-14 and read the same repositories, so the freshness rule does not separate them.
They are separated by evidence: the record's passenger claim rests on an ancestry test that is true
of every subsequent merge, while 4.1 tests ancestry against the pre-merge value of `main` and the
answer is unambiguous. **The passenger claim in
`codex-branch-merge-provenance-2026-09-14.md` is superseded by section 4.1 of this document.** The
rest of that record — the 36 operations, the 165, the fast-forward analysis, the single-identity
authorship survey — reproduces and stands.

**Nothing has expired.** The `richos` horizon is unchanged from the landed record's reading hours
earlier:

```
$ git -C /Users/alex/ab/richos reflog show main --date=iso | tail -1
0ebc099f main@{2026-08-29 10:25:23 +0100}: merge echo/fixture-2026-08-29: Merge made by the 'ort' strategy.
$ git -C /Users/alex/ab/richos-hq reflog show main --date=iso | tail -1
4763067c main@{2026-08-20 03:56:43 +0100}: clone: from github.com:WebDevBooster/richos.git
$ head -1 /Users/alex/ab/femcboost/.git/logs/refs/heads/main
0000000000000000000000000000000000000000 87ff3d0a... 1782539790 +0100	export from jj
```

**The clock is stopped in all three:**

```
$ git -C /Users/alex/ab/richos config --get gc.reflogExpire            -> never
$ git -C /Users/alex/ab/richos config --get gc.reflogExpireUnreachable -> never
$ git -C /Users/alex/ab/richos-hq config --get gc.reflogExpire         -> never
$ git config --get gc.reflogExpire        # femcboost worktree         -> never
```

**Gaps I did not close.**

- **`richos` before 2026-08-29 10:25:23.** Outside the reflog horizon; no method here can see it.
  `femcboost` and `richos-hq` both begin their Codex activity on 2026-08-27, so if the practice
  started together, `richos` has up to two days of unobservable history — and the 2026-08-30
  "Codex 9/10" merge shows the practice was already running there by then.
- **The branch name behind `7714871a`.** UNDETERMINED, section 4.2.
- **When the 17 deleted branches were deleted.** No trace: git removes a branch's reflog with the
  branch, and `git branch -d` writes nothing to `HEAD`'s reflog. Unchanged from the landed record.
- **Whether any of it was authorized.** Not re-examined here; the landed record's section 4 covers
  both sides and its conclusion — that the repository cannot settle it — is not affected by anything
  in this document. The corrected counts do make the class larger than the record described: 38
  operations rather than 36, and 185 commits rather than 165.
- **Codex work that never touched a branch with a recoverable name.** Unbounded and undetectable,
  section 5.

---

## 10. Non-mutation attestation

**CEO constraint: nothing may be mutated.** No branch deleted, no ref moved, no worktree added,
removed or entered for writing, no `git gc`, no checkout, no clone, no `codex/` workspace or branch
touched. Every command run against the three repositories was a read: `reflog show`, `log`,
`rev-list`, `merge-base --is-ancestor`, `show -s`, `branch --list`, `branch -a`, `worktree list`,
`config --get`, and `grep`/`head`/`tail` against reflog files. The only writes in this task were to
this file, inside the isolated worktree `/Users/alex/ab/richos-wt/reed-opus-cx2`.

### 10.1 `richos` — before and after

`git -C /Users/alex/ab/richos worktree list`

```
BEFORE                                                                   AFTER (identical)
/Users/alex/ab/richos                                          9f624531 [main]
/Users/alex/.codex/worktrees/c611/richos                       dcabcbd9 (detached HEAD)
/Users/alex/ab/richos-wt/codex-owned-outcome-completion        7598d7ef [codex/owned-outcome-completion]
/Users/alex/ab/richos-wt/codex-owned-outcome-live-repair       8e7e521e [codex/owned-outcome-live-repair]
/Users/alex/ab/richos-wt/codex-owned-outcome-prd               def2af2b [codex/owned-outcome-prd]
/Users/alex/ab/richos-wt/codex-resumable-outcome-verification  1bd9f688 [codex/resumable-outcome-verification]
/Users/alex/ab/richos-wt/codex-rollback-owned-outcome          90d7f774 [codex/rollback-owned-outcome]
/Users/alex/ab/richos-wt/reed-opus-cx2                         9f624531 [cc/reed-opus-cx2]
/Users/alex/ab/richos-wt/zach-opus-n9                          f5babcb7 [cc/zach-opus-n9]
```

`git -C /Users/alex/ab/richos branch -a`

```
+ cc/reed-opus-cx2
+ cc/zach-opus-n9
+ codex/owned-outcome-completion
+ codex/owned-outcome-live-repair
+ codex/owned-outcome-prd
+ codex/resumable-outcome-verification
+ codex/rollback-owned-outcome
* main
  remotes/origin/HEAD -> origin/main
  remotes/origin/main
```

`git -C /Users/alex/ab/richos reflog show main -n 5`

```
9f624531 main@{0}: merge cc/sage-opus-cx1: Merge made by the 'ort' strategy.
f5babcb7 main@{1}: merge cc/zach-opus-n8: Fast-forward
0f4eb62c main@{2}: merge cc/zach-opus-n7: Merge made by the 'ort' strategy.
49432df8 main@{3}: merge cc/sage-opus-z1: Merge made by the 'ort' strategy.
dcc4ba5f main@{4}: merge cc/zach-opus-n5: Merge made by the 'ort' strategy.
```

### 10.2 `femcboost` — before and after

Run from the worktree `/Users/alex/ab/femcboost/.claude/worktrees/agent-ad35aee56f0a9d489`, which
shares one ref store and one `main` reflog with the shared checkout, so the values are the same
objects. (The isolation guard refuses `-C` against the shared checkout; this is the equivalent read
it permits.)

`git worktree list`

```
/Users/alex/ab/femcboost                                            778ad79ef [main]
/Users/alex/.codex/worktrees/06e6/femcboost                         db84346a2 [codex/structural-failure-report]
/Users/alex/.codex/worktrees/67ec/femcboost                         5586dada4 [codex/inherited-publication-failure-report]
/Users/alex/ab/femcboost-wt/codex-rollback-owned-outcome            91a23fa28 [codex/rollback-owned-outcome]
/Users/alex/ab/femcboost/.claude/worktrees/agent-abe738373a8e136a7  778ad79ef [worktree-agent-abe738373a8e136a7] locked
/Users/alex/ab/femcboost/.claude/worktrees/agent-ad35aee56f0a9d489  778ad79ef [worktree-agent-ad35aee56f0a9d489] locked
```

`git branch -a`

```
+ codex/inherited-publication-failure-report
+ codex/rollback-owned-outcome
+ codex/structural-failure-report
+ main
+ worktree-agent-abe738373a8e136a7
* worktree-agent-ad35aee56f0a9d489
  remotes/origin/HEAD -> origin/main
  remotes/origin/main
```

`git reflog show main -n 5`

```
778ad79ef main@{0}: commit: The cross-repository spawn clause names the one command, not the four steps
53fae74c1 main@{1}: merge worktree-agent-ac8fe23713198e1ca: Fast-forward
51d7f6f78 main@{2}: merge worktree-agent-a7a66a0d1bc3b1d12: Merge made by the 'ort' strategy.
156316c41 main@{3}: commit: A spawn is checked against every Agent guard before it is dispatched, not after it is refused
3afae3d6e main@{4}: merge worktree-agent-a8922391964bc8c3b: Merge made by the 'ort' strategy.
```

### 10.3 `richos-hq` — before and after

`git -C /Users/alex/ab/richos-hq worktree list`

```
/Users/alex/ab/richos-hq                                  2b9822f2 [main]
/Users/alex/ab/richos-hq-wt/codex-rollback-owned-outcome  d11a8fe7 [codex/rollback-owned-outcome]
```

`git -C /Users/alex/ab/richos-hq branch -a`

```
+ codex/rollback-owned-outcome
* main
  remotes/origin/HEAD -> origin/main
  remotes/origin/main
```

`git -C /Users/alex/ab/richos-hq reflog show main -n 5`

```
2b9822f2 main@{0}: commit: Record failure type Y: the measurement is right and the word for it is false
87301a42 main@{1}: commit: Record failure type X: one registration, many inventories, nothing names them all
1f5e2bfb main@{2}: commit: Row 3.20 re-pinned: the blob moved, the finding did not
d3935340 main@{3}: commit: Row 3.29 says what its harness is now, and why it moved
6a666a2f main@{4}: commit: The correction to type U was itself an instance of type U
```

### 10.4 The after-capture

All nine commands above — three per repository — were run twice: once before any reading began, and
once after the last read and after this file was written. **All nine outputs are identical, line for
line, to the before-captures printed in 10.1 to 10.3.** The values that would have moved if anything
had been mutated, and did not:

| Repository | `main` tip, before and after | Worktrees, before and after | `codex/*` refs, before and after |
|---|---|---|---|
| `richos` | `9f624531` / `9f624531` | 9 / 9 | 5 / 5 |
| `femcboost` | `778ad79ef` / `778ad79ef` | 6 / 6 | 3 / 3 |
| `richos-hq` | `2b9822f2` / `2b9822f2` | 2 / 2 | 1 / 1 |

In particular: the six `codex/` worktrees across the three repositories
(`richos-wt/codex-*` x5, `femcboost-wt/codex-rollback-owned-outcome`,
`richos-hq-wt/codex-rollback-owned-outcome`) and the three `~/.codex/worktrees/` registrations were
never entered, never checked out and never unregistered. `main@{0}` is the same entry in all three
repositories before and after, so no reflog entry was added, consumed or expired during this task.

---

## 11. Appendix — every commit, by operation

Format: `<short SHA> | <subject>`. Ranges are `before..after` from the tables above.

### 11.1 `richos` r01 to r04 (the four merge commits)

```
r01  f201e904..  (f201e904 727d8890 a6c076c3 | Merge workspace retirement safety fixes)
     a6c076c3 | Preserve staged recovery objects and disable unsafe worktree erasure

r02  381907f4..  (381907f4 486e982a 36749abb | Merge session evidence reliability fixes)
     36749abb | fix(engine): keep the plugin hook inventory complete
     7de5996f | test(engine): stabilize claim fixtures and retain failure diagnostics
     edcab789 | test(engine): run session evidence negative controls in the normal suite
     a8959da9 | Merge current compaction work and retain its verified test inventory   [merge]
     3fecec77 | fix(engine): exclude operational resources from document handovers
     56f63f32 | fix(engine): preserve shell failures and remove false handover notices

r03  542d070f..  (542d070f 82c90f0c b64d77d4 | Merge the orchestrator dispatch recovery)
     b64d77d4 | fix(engine): preserve CEO ask imperative after startup review
     276e4db7 | fix(engine): align startup deferral and prepare complete isolated spawns

r04  978cd749..  (978cd749 00326dd2 cf57410c | Merge the publication-attribution recovery)
     cf57410c | Stop inferring publication finding history from uncommitted changes
```

### 11.2 `richos` r05 — `codex/process-identity-safety`, 18 commits

```
8c777abc | Preserve bulk work records and report failed claim encoding
e152e4bf | fix: inspect large command bodies without environment truncation
0d7ee816 | Preserve lifecycle binding and terminal policy for large event payloads
2d0f9f22 | Stream guard payloads and preserve decisions beyond process string limits
651f6840 | fix: preserve large row payloads and fail closed on resolver errors
9d1c2c81 | Stream lifecycle and CEO notice payloads outside exec argument limits
5462bf16 | Drain row currency verdict streams before classifying their results
70ecf249 | test: make dialect controls portable across shallow and adopted checkouts
93335106 | test: preserve retirement incident control without Git history
5345c88a | Distinguish canonical PID reuse from unknown legacy identity in reaper tests
aaba62ed | Honor each write-barrier test wait budget in an isolated entity
75679c38 | Keep the write-barrier mutation anchored to its full-consuming predicate
20f0feec | Track staging deployments independently for each product tree
fbf97f23 | Keep large hook payloads from reversing guard verdicts through SIGPIPE
35024600 | Exercise long multiline payloads through real ownership and acknowledgement hooks
521f4665 | Preserve session-owned worktrees when another path records a resumed owner
34178345 | Retain ambiguous worktree owners across incomplete ledger identities
083f8d70 | Preserve live worktree owners across locales and resumed sessions
```

### 11.3 `richos` r06 — `codex/andreas-client-audit`, 22 commits

```
7f9077f0 | docs(verification): record Andreas fixes and final macOS evidence
fc656e92 | fix(setup): connect only inside the next cancellable request
fca3d67b | Verify deferred compute startup without dropping executable readiness checks
0ef393d3 | test(native): verify onboarding grants against a real child
ff421f66 | test(release): require visible onboarding receipts and explicit deferred startup
6097af25 | fix(memory): retrieve for pending question without hidden delivery
efa21f52 | fix(onboarding): deny hidden priming side effects and defer accepted requests
cbcf5305 | fix(shell): target Stop to displayed work and protect other assignments
2c3a5068 | fix(core): bind delayed stop requests to the observed turn
6730f9fd | Describe unmeasured stopped work without inventing its start
221d18d4 | Show pending conversation navigation and scope Stop to displayed work
1ea1fe8d | test(onboarding): verify production interview and registrar routing
46b287b4 | Defer session rotation until a cancellable request and preserve unknown restart timing
f38483ed | fix(onboarding): keep verified interview actions in conversation
7bd1e727 | fix(integration): verify onboarding tools and prepare version 1.0.3
84bd59d0 | Fix waiting lifecycle feedback and preserve onboarding intent across races
a465c4d0 | fix(onboarding): verify tool discovery and report storage failures accurately
ecf8735c | Track request preparation through cancellation, failure and recovery
cb31a11b | test(onboarding): add live interview restart verification and bind sends
f19e1cd6 | fix(onboarding): persist verified company answers through scoped tools
df9d8d83 | fix(shell): keep IPC responsive and wire scoped onboarding persistence
374dd86b | Audit Andreas onboarding and waiting regressions
```

### 11.4 `richos` r07 — `codex/automatic-worktree-retirement`, 67 commits

```
ace48e5e | Record final installed cleanup acceptance and merge readiness
e49e902d | Document native cleanup proof separately from hook observation
debeee44 | Verify native canary cleanup independently of hook event observation
9f56f105 | Record installed metadata passes and native cleanup event mismatch
c655ac35 | Record orphan recovery review and pending installed acceptance
8a77aaff | Recover exact terminal orphan and locked registrations behind offline gate
10ee712c | Add isolated installed orphan registration acceptance controller
071c3d4d | Clarify cleanup metadata retention and acceptance scope
f2a2520a | Retain recovery images with ACLs flags or link topology
55005ba5 | Block direct worktree prune and mixed-helper bypasses
6472bb60 | Preserve Claude-owned native cleanup and prohibit bulk registration pruning
16d36b26 | Schedule exact clean recovery expiry and verify installed metadata boundaries
74065614 | Preserve compact metadata before clean recovery expiry
13067f27 | fix(canary): distinguish blocked spawn retries and await durable delivery
bfff51bd | Record actual native cleanup conflict and canary timing findings
b6b7e2a8 | Document engine rollout prerequisites before managed activation
e1d0cdf9 | test: launch Claude canary in owner login context
a6fdecd4 | Record actual Claude canary authentication boundary failure
4a1ea770 | test: add isolated real Claude lifecycle canary
39f35cb0 | Record passing installed delivery and interrupted creation acceptance
539bf7f1 | Retain ordinary branch candidates for coordinated frozen cleanup
4fa95cab | Deliver managed worker commits through exact UUID refs
f3edafd4 | test: exercise installed interrupted workspace creation
afaa0ae0 | Verify legacy retirement across actual macOS device renumbering
6c222a0c | Record passing UUID installed acceptance and fresh reboot continuation
14da8df1 | Record reviewed reboot correction and pending installed acceptance
1e3e4990 | Preserve cleanup identities across macOS reboot and refuse failed verification
d3766284 | Verify recovery consumers survive filesystem renumbering
9e9aafa9 | Use durable filesystem identities throughout legacy maintenance
127b78c5 | Use native volume UUIDs for durable filesystem identity
0adc5b80 | Update cleanup readiness after installed preboot validation
0a00330d | Record successful installed legacy preboot checks and exact continuation
e24368fe | Package the reviewed isolated legacy reboot acceptance driver
c64915ad | Add isolated installed legacy reboot acceptance driver
c1465d2b | Record verified removal of deferred boot activation
f91b6376 | Keep pending service installation outside launchd boot discovery
9ec69f07 | Record successful installed lifecycle and automatic cleanup acceptance
cd6205cc | Verify installed socket lifecycle and unattended preparation reclamation
94de5dd4 | Handle inherited signal masks and keep shutdown handlers lock free
5e477ffe | Cover inherited blocked shutdown signals and signal handler reentrancy
f30b79a0 | Update gate and package documentation for completed executors
56a2805f | Run armed legacy maintenance in an independent broker worker
975f526a | Automatically advance explicitly armed legacy cleanup jobs after reboot
b70ab288 | feat: reclaim frozen worktrees after verified recovery handoff
7fa5e99c | Prepare additive frozen recovery refs from validated workspace captures
803fabd8 | Allow one journaled partial registration during retirement replay
e03c4676 | Preserve verified frozen worktree recovery archives and object dependencies
abb53e0e | feat: publish frozen branch cleanup with crash recovery
00ff2014 | Add frozen terminal branch ref preparation with strict inventory
4005432e | docs: record installed workspace boundary acceptance
56d87fdc | Run legacy maintenance inspection as the approved owner
c7580b3c | Pin privileged execution to protected Command Line Tools Python
51a0c9b2 | Use protected macOS runtime paths outside var run
3f8189d8 | Merge branch 'main' into codex/automatic-worktree-retirement   [merge, the round trip]
41782a17 | Recover abandoned and interrupted workspace preparations
e0446210 | Add explicitly authorized legacy maintenance gate prototype
f3bafcc2 | Plan consolidated native gates and explicit shared-parent downtime
14a9c4a5 | fix(workspaces): preserve and reclaim interrupted creation storage
d48da924 | Add managed workspace lifecycle and exact hook integration
ee0bc940 | Plan complete offline gates for legacy workspace maintenance
07869566 | Refuse incomplete managed volume attachment inventories
bca1635b | feat(workspaces): package authenticated managed workspace broker
ebe8117e | Recover managed volumes after verified reboot and reject ACL grants
e9c66e19 | Expose frozen workspace reads for unprivileged Git handoff
213f0399 | feat: plan terminal branch cleanup from exact recorded ownership
a097f09a | Add protected macOS workspace volume provider prototype
61a7c935 | fix: preserve branch recovery atomically and reject unreadable registries
```

### 11.5 `richos` r08 to r20

```
r08 (6)  8c999b55 | Make historical recovery probes execute and fail closed on fixture errors
         9e16d135 | Add isolated installed operator-authority acceptance controller
         534c1a14 | Publish approved legacy branch backlogs in bounded replayable batches
         2d8007e5 | Bind operator maintenance authorization to protected exact owner reports
         a4491b95 | Bind operator maintenance authority to exact complete inventory
         d762116c | Recognize exact recorded terminal quarantine ownership in maintenance plans
r09 (1)  2af1accf | Support closed legacy hardlinks and reclaim completed replay snapshots
r10 (1)  aec8ae7f | Refuse new hardlink groups in historical partial gates
r11 (1)  a279a587 | Preserve managed handoff traversal under daemon umask
r12 (1)  28f07ab5 | Run workspace cleanup daily during user inactivity
r13 (1)  7598d7ef | docs: record R7 stable installation and workspace activation
r14 (1)  9e3d2edb | Fix installed inspector failures blocking native exit and portable adoption
r15 (1)  8e7e521e | docs: record installed native exit repair and validation limits
r16 (1)  ed88e290 | fix: resume native outcome inspection across bounded leases
r17 (1)  1bd9f688 | docs: record installed resumable inspection validation
r18 (1)  984f72e9 | Disable retired owned-outcome hooks for cached native sessions
r19 (1)  8397c530 | Remove experimental orchestration integration and preserve ordinary workflows
r20 (1)  90d7f774 | Record completed native integration uninstall
```

**`ed88e290` and `1bd9f688` (r16, r17) are the two SHAs `richos-hq/RICH-TODOs.md:436` names as being
on `origin/main`** — the single strongest item on the authorization question in the landed record's
section 4, and both re-derived here as fast-forward merges of `codex/resumable-outcome-verification`.

### 11.6 `femcboost` f01 to f14

```
f01 (9)   1eef40417 | fix(ecs): keep lifecycle replay observation-only
          983456180 | fix(ecs): retain dead-letter turn boundaries
          4c02f5fe1 | fix(ecs): bind stop and migration boundaries
          bdd5ae70c | fix(ecs): preserve turn and replay boundaries
          9b794d856 | fix(ecs): close shadow-mode trust gaps
          5ac14dc60 | fix(ecs): enforce continuity integrity boundaries
          39e53afbb | fix(ecs): make entity manifest portable
          1fdc31555 | chore(hooks): wire ECS shadow lifecycle capture
          b0314a62d | feat(ecs): add shadow-mode continuity core
          (merge commit ea3af3c10 | Merge ECS shadow-mode dogfood adapter)
f02 (3)   2b9fe723d | fix(ecs): require turn checkpoints with bounded repair and durable gaps
          e45d302fc | fix(ecs): address continuity review and defer integration enforcement to engine
          9c8f9c79a | fix(ecs): preserve terminal continuity and check pending integrations
          (merge commit 9ce806242 | Merge ECS terminal continuity and durable checkpoint repairs)
f03 (1)   2c41f4aa3 | fix(ecs): preserve receipt diagnostics and reconcile stale evidence
f04 (1)   dd9e91532 | fix(ecs): retain audience restrictions when reading saved receipts
f05 (1)   fdb10916e | fix(ecs): enforce receipt visibility on checkpoint retries
f06 (1)   70e67752b | test(ecs): exercise the final checkpoint retry path in negative controls
f07 (2)   a6a991eb6 | fix(ecs): address Sage startup review and propose owner state repairs
          0acfe0963 | fix(ecs): recover bounded startup context and prepare fenced checkpoints
f08 (1)   6ba08de38 | Prepare verified publication attribution and outstanding ECS owner repairs
f09 (4)   6dfb39628 | Record reviewed orchestration acceptance and final CI evidence
          47f235eb5 | Enforce staging evidence before product work resumes
          d0b609290 | Record reviewed orchestration fixes and pending system acceptance evidence
          2c9d161d1 | Verify the engine and ECS delivery lifecycle against an explicit candidate
f10 (1)   2f68d0d21 | Record merged orchestration installation and pre-restart verification
f11 (1)   da2dad066 | Verify committed delivery before ECS records task completion
f12 (1)   db84346a2 | Document failure to challenge premises and reject unacceptable results
f13 (1)   5586dada4 | Document inherited publication findings blocking review commits
f14 (1)   91a23fa28 | Remove the installed owned-outcome hooks
```

### 11.7 `richos-hq` h01 to h02

```
h01 (1)   2c507072 | docs: define Executive Continuity System architecture
h02 (1)   d11a8fe7 | Record the orchestration rollback in affected dependency rows
```

---

## 12. Suggested next step — for the requester, not for me

1. **Correct the passenger paragraph in `codex-branch-merge-provenance-2026-09-14.md`.** Its section
   2.1 states that `codex/workspace-retirement-safety` carried `codex/durable-orchestration` in. That
   is wrong; 4.1 here has the merge, the date and the disproving command. The record is landed on
   `main`, so the correction belongs in place, in the way the project corrects a landed document
   rather than leaving it quotable without the correction.
2. **If a ruling is written about whether `codex/` branches may reach `main`,** the number in front of
   the CEO should be **38 operations and 185 commits**, not 36 and 165 — and it should carry the
   sentence that a conflicted merge records no branch name, because that is why the first number was
   short.
3. **The UNDETERMINED row (4.2) is the only open lead**, and it is only answerable from agent
   transcripts or session state under `~/.claude/`, not from any repository. It is a bounded search;
   it is not mine to run.
4. **This document is an extraction brief, not a destination page.** Whoever curates it should decide
   whether its corrected counts belong in the landed record, in `ceo-decisions.md`, or both.
