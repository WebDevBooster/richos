# How Codex commits reached `main`: the provenance of every `codex/` branch

> **CORRECTED 2026-09-14 BY `reed-opus-cx2`, BEFORE ANY OF THIS IS QUOTED.** The arithmetic below is
> sound — summing the branch-side payload of the 36 reflog-named merges gives 165 commit for commit.
> **The METHOD is incomplete and one claim in it is false.**
>
> **The counts are 38 operations and 185 commits, not 36 and 165.** Reading reflog entries of the form
> `merge codex/<name>:` is structurally blind to entries git records as `commit (merge)` — the form git
> writes when a merge is finished by hand after conflicts, **which records no branch name at all**.
> `richos` holds 36 such entries; two carried `codex/` work: `727d8890` (16 commits, 2026-09-06) and
> `7714871a` ("Merge Codex 9/10", 6 commits, 2026-08-30). A further 7 Codex commits arrived on
> `sage-fable-r*` review branches.
>
> **The passenger claim in this document is FALSE.** `codex/durable-orchestration` did not arrive inside
> `codex/workspace-retirement-safety`'s merge; it arrived **44 minutes earlier through a dedicated merge
> of its own**. The evidence used here — `merge-base --is-ancestor 55728e67 f201e904` → 0 — is true of
> *every* merge that came afterwards and therefore cannot identify the introducing one. Tested against
> the value `main` held BEFORE each merge it is unambiguous: `--is-ancestor 55728e67 f2211148` exits 1.
> **The passenger list is empty.**
>
> **A third discriminator exists that this document does not name:** a back-merge commit message
> (`Merge branch 'main' into codex/<name>`) is an ordinary object on `main` that outlives the branch,
> the reflog and a clone.
>
> **UNDETERMINED: 1.** The branch behind `7714871a` is named nowhere — not the reflog, not the merge
> message, not the back-merge, which calls it only "the slice 9/10 branch". Its payload, date and both
> tips are determined; its `codex/` prefix is not, and no repository can settle it.
>
> Full inventory, one row per merge with the command beside every number:
> [`codex-merge-reflog-inventory-2026-09-14.md`](codex-merge-reflog-inventory-2026-09-14.md).
> Escalation `esc-20260914T070409Z-5622da32`.

**Author:** Sage (software architect). **Date:** 2026-09-14.
**Question put to me:** how did commits reachable only through `codex/` branches come to be reachable
from `main`, and was any of it authorized?

---

## The answer, in one sentence

**Yes — `codex/` branches were merged into `main`, 36 times, across all three repositories, between
2026-08-27 and 2026-09-09, bringing 165 commits onto `main`; every one of those merges was performed
from a `main` checkout by `git merge`, and I can find no CEO ruling anywhere in the record that
authorizes it.**

Whether he authorized it in conversation the repository cannot settle. **The one thing pointing the
other way, and it is not small: `RICH-TODOs.md` named two of these merges by SHA as being on
`origin/main`, in the row carrying his own instruction to send that work to Codex** (§4, point 4).
That makes those two visible to him. It does not cover the other 34. What the repository settles
beyond argument is that it happened, at scale, repeatedly, and that nothing in `git log` shows it.

**This is shape 1 from the brief, not shape 3.** There is no version of these facts in which
"nothing of Codex's is in `main`" is true. 135 commits in `richos` alone entered `main` from a
`codex/` branch, and I counted them one merge at a time.

**Correction to my own escalation.** `esc-20260914T063906Z-5cfaa64a` says femcboost had 9 distinct
branches. It is 10. The operation count (14) and the headline are unchanged. The corrected inventory
is §2.

---

## 0. Method, and the promise this record keeps

Read-only throughout. No branch deleted, no ref moved, no worktree removed, no garbage collection, no
checkout, no experiment needing a clone. Every number below is followed by the command that produced
it, run against the live repositories, so it can be re-derived by somebody who does not trust me.

The load-bearing source is the **branch reflog** (`git reflog show main`), which records what `main`
pointed at and why it moved. It is the only place in a repository where a fast-forward merge leaves a
trace.

**Reflog horizons, because a bounded window is not a clean bill of health:**

| Repository | Oldest `main` reflog entry | Coverage |
|---|---|---|
| `richos` | `2026-08-29 10:25:23` | **Partial.** Codex merges before 2026-08-29 would be invisible. |
| `femcboost` | `2026-06-27 06:56:30` (`export from jj`) | Complete for the life of the repository. |
| `richos-hq` | `2026-08-20 03:56:43` (`clone:`) | Complete for the life of the clone. |

`gc.reflogExpire` is unset in `richos`, so git's default of **90 days** applies. The evidence in this
record begins expiring around **2026-12-05**. That is not a footnote; see §6.

---

## 1. Why `git log` showed nothing, and why that was not a mistake by anybody

The check that came up empty was:

```
git log --merges --oneline main | head -40 | grep -i "branch 'codex"
```

It is structurally incapable of finding these merges, for two independent reasons.

**Reason one: 16 of the 20 `richos` merges were FAST-FORWARDS** (22 of 36 across all three
repositories: 16 in `richos`, 4 in `femcboost`, 2 in `richos-hq`). A fast-forward merge creates no
commit at all. `main` is simply repointed at the branch tip. There is nothing for `--merges` to list,
no merge commit, no second parent, no message. The commits arrive on `main` wearing exactly the same
clothes as commits made on `main`.

```
$ git -C /Users/alex/ab/richos reflog show main --date=iso | grep -i codex
90d7f774 main@{2026-09-09 22:55:08 +0100}: merge codex/rollback-owned-outcome: Fast-forward
8397c530 main@{2026-09-09 22:53:12 +0100}: merge codex/rollback-owned-outcome: Fast-forward
984f72e9 main@{2026-09-09 22:44:28 +0100}: merge codex/rollback-owned-outcome: Fast-forward
1bd9f688 main@{2026-09-09 19:54:11 +0100}: merge codex/resumable-outcome-verification: Fast-forward
ed88e290 main@{2026-09-09 19:50:26 +0100}: merge codex/resumable-outcome-verification: Fast-forward
8e7e521e main@{2026-09-09 18:50:26 +0100}: merge codex/owned-outcome-live-repair: Fast-forward
9e3d2edb main@{2026-09-09 18:46:58 +0100}: merge codex/owned-outcome-live-repair: Fast-forward
7598d7ef main@{2026-09-09 18:10:40 +0100}: merge codex/owned-outcome-completion: Fast-forward
28f07ab5 main@{2026-09-08 12:43:21 +0100}: merge codex/daily-idle-cleanup: Fast-forward
a279a587 main@{2026-09-07 18:07:28 +0100}: merge codex/automatic-worktree-retirement: Fast-forward
aec8ae7f main@{2026-09-07 17:39:11 +0100}: merge codex/automatic-worktree-retirement: Fast-forward
2af1accf main@{2026-09-07 17:33:17 +0100}: merge codex/automatic-worktree-retirement: Fast-forward
8c999b55 main@{2026-09-07 15:54:57 +0100}: merge codex/automatic-worktree-retirement: Fast-forward
ace48e5e main@{2026-09-07 14:41:44 +0100}: merge codex/automatic-worktree-retirement: Fast-forward
7f9077f0 main@{2026-09-07 09:16:51 +0100}: merge codex/andreas-client-audit: Fast-forward
8c777abc main@{2026-09-07 06:53:51 +0100}: merge codex/process-identity-safety: Fast-forward
978cd749 main@{2026-09-06 20:38:14 +0100}: merge codex/publication-attribution-recovery: Merge made by the 'ort' strategy.
542d070f main@{2026-09-06 20:04:16 +0100}: merge codex/orchestrator-dispatch-recovery: Merge made by the 'ort' strategy.
381907f4 main@{2026-09-06 16:13:02 +0100}: merge codex/session-evidence-reliability: Merge made by the 'ort' strategy.
f201e904 main@{2026-09-06 04:35:34 +0100}: merge codex/workspace-retirement-safety: Merge made by the 'ort' strategy.
```

**Reason two: the four that DID create a merge commit were given custom messages that never contain
the branch name.** Git's default would have been `Merge branch 'codex/...'`. Each was overridden:

```
$ git -C /Users/alex/ab/richos show -s --format='%h %ci %s' f201e904
f201e904 2026-09-06 04:35:34 +0100 Merge workspace retirement safety fixes
$ git -C /Users/alex/ab/richos show -s --format='%h %ci %s' 381907f4
381907f4 2026-09-06 16:13:02 +0100 Merge session evidence reliability fixes
$ git -C /Users/alex/ab/richos show -s --format='%h %ci %s' 542d070f
542d070f 2026-09-06 20:04:16 +0100 Merge the orchestrator dispatch recovery — the spawn contract the helper was mis-stating
$ git -C /Users/alex/ab/richos show -s --format='%h %ci %s' 978cd749
978cd749 2026-09-06 20:38:14 +0100 Merge the publication-attribution recovery — the guard stops inventing history
```

Not one says `codex`. So the grep would have missed all four at any depth, and `head -40` put them
out of reach anyway — they are 2026-09-06 and the last 40 merges on `main` do not reach that far back.

**The consequence worth stating plainly: `git log` is not an audit trail for this class of change.
The reflog is, and the reflog is local, unpushed, and expires.**

---

## 2. Every merge, every repository — the full inventory

### 2.1 `richos` — 20 merge operations, 12 distinct branches, 135 commits onto `main`

| `main` became | When | Branch merged | Kind | Commits added |
|---|---|---|---|---|
| `f201e904` | 2026-09-06 04:35 | `codex/workspace-retirement-safety` | ort | 1 |
| `381907f4` | 2026-09-06 16:13 | `codex/session-evidence-reliability` | ort | 6 |
| `542d070f` | 2026-09-06 20:04 | `codex/orchestrator-dispatch-recovery` | ort | 2 |
| `978cd749` | 2026-09-06 20:38 | `codex/publication-attribution-recovery` | ort | 1 |
| `8c777abc` | 2026-09-07 06:53 | `codex/process-identity-safety` | **fast-forward** | 18 |
| `7f9077f0` | 2026-09-07 09:16 | `codex/andreas-client-audit` | **fast-forward** | 22 |
| `ace48e5e` | 2026-09-07 14:41 | `codex/automatic-worktree-retirement` | **fast-forward** | **67** |
| `8c999b55` | 2026-09-07 15:54 | `codex/automatic-worktree-retirement` | **fast-forward** | 6 |
| `2af1accf` | 2026-09-07 17:33 | `codex/automatic-worktree-retirement` | **fast-forward** | 1 |
| `aec8ae7f` | 2026-09-07 17:39 | `codex/automatic-worktree-retirement` | **fast-forward** | 1 |
| `a279a587` | 2026-09-07 18:07 | `codex/automatic-worktree-retirement` | **fast-forward** | 1 |
| `28f07ab5` | 2026-09-08 12:43 | `codex/daily-idle-cleanup` | **fast-forward** | 1 |
| `7598d7ef` | 2026-09-09 18:10 | `codex/owned-outcome-completion` | **fast-forward** | 1 |
| `9e3d2edb` | 2026-09-09 18:46 | `codex/owned-outcome-live-repair` | **fast-forward** | 1 |
| `8e7e521e` | 2026-09-09 18:50 | `codex/owned-outcome-live-repair` | **fast-forward** | 1 |
| `ed88e290` | 2026-09-09 19:50 | `codex/resumable-outcome-verification` | **fast-forward** | 1 |
| `1bd9f688` | 2026-09-09 19:54 | `codex/resumable-outcome-verification` | **fast-forward** | 1 |
| `984f72e9` | 2026-09-09 22:44 | `codex/rollback-owned-outcome` | **fast-forward** | 1 |
| `8397c530` | 2026-09-09 22:53 | `codex/rollback-owned-outcome` | **fast-forward** | 1 |
| `90d7f774` | 2026-09-09 22:55 | `codex/rollback-owned-outcome` | **fast-forward** | 1 |

Fast-forward payloads are `git rev-list --count <previous reflog value>..<new value>`; ort payloads
are `git rev-list --count <merge>^1..<merge>^2`. Worked examples:

```
$ git -C /Users/alex/ab/richos rev-list --count 7f9077f0..ace48e5e
67
$ git -C /Users/alex/ab/richos rev-list --count --no-merges 7f9077f0..ace48e5e
66
$ git -C /Users/alex/ab/richos rev-list --count --merges 7f9077f0..ace48e5e
1
$ git -C /Users/alex/ab/richos rev-list --count 381907f4^1..381907f4^2
6
```

**Honest qualification on the 67.** One of those 67 is a merge commit — `3f8189d8`,
`Merge branch 'main' into codex/automatic-worktree-retirement` — so the branch had taken `main` in
before `main` took it back. **66 are Codex-side commits.** I read the list; they are uniformly Codex
work (`Recover exact terminal orphan and locked registrations behind offline gate`,
`feat: plan terminal branch cleanup from exact recorded ownership`, and 64 siblings, all dated
2026-09-07).

**A thirteenth branch has content in `main` without ever having been merged by name:
`codex/durable-orchestration`.** Its own back-merge commit `55728e67` is an ancestor of `f201e904`,
which means `codex/workspace-retirement-safety` carried it in.

```
$ git -C /Users/alex/ab/richos merge-base --is-ancestor 55728e67 f201e904 ; echo $?
0
$ git -C /Users/alex/ab/richos merge-base --is-ancestor d083a2e main ; echo $?
0
$ git -C /Users/alex/ab/richos merge-base --is-ancestor 63e93ac main ; echo $?
0
```

`d083a2e` and `63e93ac` are the two `codex/durable-orchestration` heads named in Sage's round-2 and
round-6 verdicts (`richos-hq/docs/briefs/sage-durable-orchestration-verdict-r2-2026-09-05.md`;
round-6 subject `Round 6 verdict on codex/durable-orchestration at 63e93ac: adopt whole`). **Both are
in `main`.** The branch itself no longer exists:

```
$ git -C /Users/alex/ab/richos rev-parse --verify codex/durable-orchestration
fatal: Needed a single revision
```

### 2.2 `femcboost` — 14 merge operations, 10 distinct branches, 28 commits onto `main`

| `main` became | When | Branch merged | Kind | Commits added |
|---|---|---|---|---|
| `ea3af3c10` | 2026-08-27 19:23 | `codex/ecs-dogfood` | ort | 9 |
| `9ce806242` | 2026-09-06 14:41 | `codex/ecs-terminal-continuity` | ort | 3 |
| `ae66229ba` | 2026-09-06 15:22 | `codex/ecs-followup-reliability` | ort | 1 |
| `305758a54` | 2026-09-06 15:28 | `codex/ecs-followup-reliability` | ort | 1 |
| `fc9c6854a` | 2026-09-06 15:58 | `codex/ecs-followup-reliability` | ort | 1 |
| `34b560897` | 2026-09-06 16:38 | `codex/ecs-followup-reliability` | ort | 1 |
| `e6439e12e` | 2026-09-06 20:02 | `codex/ecs-session-start-recovery` | ort | 2 |
| `316f90ab1` | 2026-09-06 20:39 | `codex/publication-attribution-recovery` | ort | 1 |
| `6dfb39628` | 2026-09-07 06:54 | `codex/orchestration-system-acceptance` | **fast-forward** | 4 |
| `2f68d0d21` | 2026-09-07 07:00 | `codex/orchestration-system-acceptance` | **fast-forward** | 1 |
| `da2dad066` | 2026-09-08 11:59 | `codex/ecs-completion-delivery` | **fast-forward** | 1 |
| `4e6bc5695` | 2026-09-09 11:34 | `codex/structural-failure-report` | ort | 1 |
| `415cf3791` | 2026-09-09 17:51 | `codex/inherited-publication-failure-report` | ort | 1 |
| `91a23fa28` | 2026-09-09 22:47 | `codex/rollback-owned-outcome` | **fast-forward** | 1 |

The earliest is **2026-08-27**, and femcboost's reflog covers the whole life of the repository, so
that is the true start of the practice in this repository, not a window artifact.

### 2.3 `richos-hq` — 2 merge operations, 2 distinct branches, 2 commits onto `main`

| `main` became | When | Branch merged | Kind | Commits added |
|---|---|---|---|---|
| `2c507072` | 2026-08-27 17:14 | `codex/ecs-architecture` | **fast-forward** | 1 |
| `d11a8fe7` | 2026-09-09 22:54 | `codex/rollback-owned-outcome` | **fast-forward** | 1 |

### 2.4 Totals

**36 merge operations. 24 distinct `codex/` branches. 165 commits onto `main`.** Plus
`codex/durable-orchestration`, which arrived as a passenger and is counted in `richos`'s 135.

---

## 3. Shape verdicts for every surviving branch

The brief offered four shapes. **None of them names the one that actually dominates**, so I add it:

- **Shape 1b — merged by fast-forward.** A deliberate `git merge`, but leaving no merge commit, no
  second parent and no trace outside the reflog. **22 of the 36 operations.** This is the shape.

```
$ git -C /Users/alex/ab/richos reflog show main | grep -c 'merge codex/.*Fast-forward'
16
$ git -C /Users/alex/ab/richos reflog show main | grep -c 'merge codex/.*ort'
4
```

The brief also said "three in femcboost/richos-hq". It is four: three in `femcboost`, one in
`richos-hq`.

| Repository | Branch | Ahead of `main` | Behind | Ancestor of `main` | **Shape** | Evidence |
|---|---|---|---|---|---|---|
| `richos` | `codex/owned-outcome-completion` | 0 | 640 | YES | **1b** | `merge codex/owned-outcome-completion: Fast-forward` @ 2026-09-09 18:10:40 |
| `richos` | `codex/owned-outcome-live-repair` | 0 | 638 | YES | **1b** | two Fast-forward entries @ 18:46:58, 18:50:26 |
| `richos` | `codex/resumable-outcome-verification` | 0 | 636 | YES | **1b** | two Fast-forward entries @ 19:50:26, 19:54:11 |
| `richos` | `codex/rollback-owned-outcome` | 0 | 631 | YES | **1b** | three Fast-forward entries @ 22:44:28, 22:53:12, 22:55:08 |
| `richos` | `codex/owned-outcome-prd` | **1** | 631 | **NO** | **not merged** | only branch returned by `--no-merged main` |

Behind counts measured 2026-09-14 against `main` at `0f4eb62c`; the brief's 623-632 was measured
earlier and `main` has moved since. Ahead counts and ancestry are the load-bearing columns and both
reproduce exactly.
| `femcboost` | `codex/inherited-publication-failure-report` | 0 | 29 | YES | **1** (ort) | merge commit `415cf3791` |
| `femcboost` | `codex/structural-failure-report` | 0 | 30 | YES | **1** (ort) | merge commit `4e6bc5695` |
| `femcboost` | `codex/rollback-owned-outcome` | 0 | 22 | YES | **1b** | `Fast-forward` @ 2026-09-09 22:47:54 |
| `richos-hq` | `codex/rollback-owned-outcome` | 0 | 156 | YES | **1b** | `Fast-forward` @ 2026-09-09 22:54:20 |

```
$ git -C /Users/alex/ab/richos branch --no-merged main --list 'codex/*'
+ codex/owned-outcome-prd
$ git -C /Users/alex/ab/richos branch --merged main --list 'codex/*'
+ codex/owned-outcome-completion
+ codex/owned-outcome-live-repair
+ codex/resumable-outcome-verification
+ codex/rollback-owned-outcome
```

**Shape 2 (cherry-pick or rebase) is ruled out** and the brief predicted how: a copied commit gets a
new hash, so the original tip could not be an ancestor of `main`. Every tip is an ancestor of `main`
by `git merge-base --is-ancestor`, exit 0. These are the same objects, not copies.

**Shape 3 (never diverged) is ruled out.** Each tip is a distinct commit carrying Codex's own work —
`7598d7ef docs: record R7 stable installation and workspace activation`, and so on — and each one
entered `main` at a datable moment recorded in the reflog. There is no reading of this in which the
branches contained nothing of their own.

**Shape 4 is real and it is now explained.** The `Merge branch 'main' into codex/…` commits reachable
from `main` got there because `main` was later fast-forwarded onto that same branch:

```
$ git -C /Users/alex/ab/richos merge-base --is-ancestor 3f8189d8 ace48e5e ; echo $?
0
```

`3f8189d8` is `Merge branch 'main' into codex/automatic-worktree-retirement` (2026-09-07 09:18).
`ace48e5e` is what `main` became at 14:41 the same day. `main` went into the branch and came back
out, and the round trip is invisible in `git log`.

### 3.1 The shape of the 2026-09-09 sequence, which is the one to look at twice

Eight of the nine `richos` fast-forwards on 2026-09-09 moved `main` by **exactly one commit**:

```
$ git -C /Users/alex/ab/richos rev-list --count f3f6a29b..7598d7ef
1
$ git -C /Users/alex/ab/richos rev-list --count 7598d7ef..9e3d2edb
1
... (six more, all 1)
```

That is not a feature branch being landed. That is **one Codex commit at a time going straight onto
`main` through a branch name that existed for a few minutes**, with `main`'s own commits
(`7d77e3bd`, `0e865973`) interleaved between them. Functionally it is committing to `main`. The
`codex/` prefix was a staging pointer, not a review boundary.

---

## 4. Authorization: what the record says, in both directions

**I am not going to round this one off.** The brief asked whether any of it was authorized, and the
repository cannot answer that; the record can only say what was written down. Both halves follow.

**Against authorization:**

1. **`richos-hq/wiki/ceo-decisions.md` contains exactly one Codex ruling — §31 — and it authorizes
   nothing about merging.** It is a refusal about removal: *"no sweep, reaper, reconciler or land
   sequence removes a `codex/` workspace or deletes a `codex/` branch… merged-and-clean is not
   permission."* Searching the whole decisions record for a Codex ruling touching merge, land, main,
   accept, authorize or approve returns three lines, all inside §31, none of them permission.
2. **The merge decisions on the record are agent verdicts, not his words.** The merge commits carry
   them verbatim: `Merge sage-fable-r5: … merge, do not activate the Claude Code surface until
   C7-C8`. The round-6 subject in `richos-hq` is `Round 6 verdict on codex/durable-orchestration at
   63e93ac: adopt whole`. A Sage verdict is a recommendation. It is not consent.
3. **The 2026-09-09 pattern in §3.1 had no review gate at all** — one commit, one fast-forward, no
   merge commit to hang a verdict on.

**For authorization, and it is substantial:**

4. **He commissioned Codex work directly, and the record he reads named two of these exact merges as
   being on `main`.** `richos-hq/RICH-TODOs.md:436`, his words: *"This shit came from Codex. So, I'll
   have that bastard fix that"* — and the very next sentence of that row reads **"Fix commit
   `ed88e290`, record commit `1bd9f688`, both on `origin/main`, tree clean."** Those two SHAs are
   rows 16 and 17 of the table in §2.1: the two fast-forward merges of
   `codex/resumable-outcome-verification` at 19:50:26 and 19:54:11 on 2026-09-09. **This is the
   strongest single item on either side of the question**, because it is not an inference about a
   process — it is his own record telling him, by SHA, that a Codex commit he personally
   commissioned was on `origin/main`.
5. **The same is true of a femcboost merge.** Row `sf1` describes `4e6bc5695` — row 12 of §2.2 — as
   written by *"Codex, on the CEO's order"*.
6. **He was told the work was landing.** `RICH-TODOs.md` row 3: *"Codex slices 9 and 10 — BUILT,
   landing now"*, status `done`.
7. **He overruled a verdict that would have kept Codex's work out.** Row `hold1`: Sage recommended
   rejecting the third-party branch; *"The CEO declined and is having Codex redo the work"*, quoting
   his own brief. That is engagement with the adoption process, not ignorance of it.

**So the honest verdict is two-part, and neither part is soft.** Codex work is in `main` — that is
settled, measured, and not in dispute. Whether merging it was authorized **cannot be determined from
the repository**, because the repositories record no authorization for anything, only outcomes.

**My reading of the balance, offered as a reading and not as a finding.** Point 4 is hard to get
around: a row in the list he reads named two of these merges by SHA and said they were on
`origin/main`, next to his own instruction that produced them. What that establishes is that Codex
work reaching `main` was **visible** to him and, in at least that one case, wanted. What it does not
establish is a decision covering the class — and the class is 36 merges across three repositories,
including 16 fast-forwards in `richos` that no verdict, no merge commit and no row ever described.
**Visible in one instance is not authorized as a practice, and I will not present it as one.**

**What would settle it:** his own answer, and nothing else on this machine. There is no artifact to
consult. If a durable answer is wanted, the place it belongs is a numbered ruling in
`ceo-decisions.md` saying whether `codex/` branches may reach `main` and under whose authority —
which is exactly the artifact whose absence made tonight's question unanswerable.

---

## 5. Authorship: nothing in the history distinguishes Codex from anyone

The brief flagged that all four sampled tips showed `Alex Booster` and asked for a survey rather than
a sample. Here is the survey, across every commit, not four:

```
$ git -C /Users/alex/ab/richos log --format='%an|%ae|%cn|%ce' \
    codex/owned-outcome-completion codex/owned-outcome-live-repair codex/owned-outcome-prd \
    codex/resumable-outcome-verification codex/rollback-owned-outcome | sort | uniq -c
2053 Alex Booster|webdevbooster@gmail.com|Alex Booster|webdevbooster@gmail.com

$ git -C /Users/alex/ab/richos log --format='%an <%ae>' main | sort | uniq -c
2679 Alex Booster <webdevbooster@gmail.com>
```

**One identity. Every commit. Author and committer both.** All 2679 commits on `richos` `main` — his
own, every Claude teammate's, and every Codex commit — are signed the same way.

**Stated plainly, because it changes what any future audit can conclude:** Codex commits are authored
under his name, and so is everything else. Authorship can never be used to identify Codex work in
this history, now or later. The only surviving discriminators are (a) the branch name, if the branch
still exists, and (b) the reflog, which expires in about 90 days. **When those go, the question asked
tonight becomes permanently unanswerable.** It is already partly unanswerable: see §7.

---

## 6. `codex/owned-outcome-prd` — the one commit not in `main`

```
$ git -C /Users/alex/ab/richos log main..codex/owned-outcome-prd --format='%H %ci A=%an <%ae> %s'
def2af2b238d7e4f130a75048d8e5b63f4c78559 2026-09-09 23:15:03 +0100 A=Alex Booster <webdevbooster@gmail.com> Document unattended outcome requirements and release gates

$ git -C /Users/alex/ab/richos show --stat --format='' def2af2b
 docs/plans/owned-outcome/ACCEPTANCE.md | 122 +++++++++
 docs/plans/owned-outcome/DEFERRED.md   |  22 ++
 docs/plans/owned-outcome/PRD.md        | 448 +++++++++++++++++++++++++++++++++
 3 files changed, 592 insertions(+)
```

**One line: it is documentation only — a 448-line product requirements document for unattended
outcome completion, plus its acceptance criteria and a deferred list. It adds three new files and
changes nothing that exists.** It is also the last Codex commit in the repository, 20 minutes after
the final rollback merge, and the only one nobody merged.

---

## 7. Nine `richos` `codex/` branches no longer exist

Thirteen distinct `codex/` branches have content in `richos` `main` — the 12 merged by name, plus
`durable-orchestration`, which arrived as a passenger. A fourteenth, `owned-outcome-prd`, exists and
was never merged. Five branch refs survive:

```
$ ls /Users/alex/ab/richos/.git/logs/refs/heads/codex/
owned-outcome-completion  owned-outcome-live-repair  owned-outcome-prd
resumable-outcome-verification  rollback-owned-outcome
```

Missing: `workspace-retirement-safety`, `session-evidence-reliability`,
`orchestrator-dispatch-recovery`, `publication-attribution-recovery`, `process-identity-safety`,
`andreas-client-audit`, `automatic-worktree-retirement`, `daily-idle-cleanup`,
`durable-orchestration`. The same is true elsewhere: `femcboost` retains 3 of 10,
`richos-hq` retains 1 of 2 (`codex/ecs-architecture` is gone).

**When they were deleted cannot be determined from the repository**, and I want to be exact about why
rather than imply something I did not measure: git removes a branch's reflog file along with the
branch, and `git branch -d` writes nothing to `HEAD`'s reflog. There is no trace left to date. The
`~/.claude/state/worktree-ledger.jsonl` ledger (16,988 rows) contains **no** row matching `codex`, so
it does not date them either.

**No content was lost** — every deleted branch's commits are in `main`. What was lost is the record
of *which* commits were Codex's, and §5 explains why that record had no backup: authorship could
never have told you.

§31 forbids deleting a `codex/` branch and is dated 2026-09-10; these merges are 2026-08-27 to
2026-09-09, and a landing sequence that deletes a merged branch was normal practice then. **I am
therefore not calling these deletions a violation. I am recording that they happened, that they
cannot be dated, and that `richos-hq` `5cd156c2` (2026-09-13) says the protection is still broken
today:** *"Point 2 is BROKEN: an agent deletes a `codex/` branch today, reproduced."*

---

## 8. `~/.codex/worktrees/c611/richos` — same class, no work of its own

```
$ cat /Users/alex/.codex/worktrees/c611/richos/.git
gitdir: /Users/alex/ab/richos/.git/worktrees/richos
$ cd /Users/alex/.codex/worktrees/c611/richos && git symbolic-ref -q HEAD || echo DETACHED
DETACHED HEAD
$ git rev-parse HEAD
dcabcbd99056928a9872cd94c1f3a385f8b21069
$ git -C /Users/alex/ab/richos show -s --format='%h %ci %s' dcabcbd9
dcabcbd9 2026-09-11 05:34:17 +0100 Merge branch 'cc/sage-fable-cert5'
$ git -C /Users/alex/ab/richos merge-base --is-ancestor dcabcbd9 main ; echo $?
0
$ cat /Users/alex/ab/richos/.git/worktrees/richos/codex-thread.json
{ "version": 1, "ownerThreadId": "01a099c8-b73f-7ba2-8df4-3d9301543eaf" }
```

**It is a Codex workspace, so §31's "two shapes" cover it — but it holds none of Codex's work.** It
is a linked worktree of `richos`, detached at a merge commit that is already on `main`, clean, with
no branch of its own and no refs of its own. It is a checkout, not a line of development. Nothing
merged from it and nothing can be lost by leaving it exactly where it is, which is what §31 requires
anyway.

**One detail that matters for enforcement and is easy to miss: it is registered under the worktree
name `richos`, not `codex-…`.**

```
$ git -C /Users/alex/ab/richos worktree list
/Users/alex/ab/richos                                          0f4eb62c [main]
/Users/alex/.codex/worktrees/c611/richos                       dcabcbd9 (detached HEAD)
/Users/alex/ab/richos-wt/codex-owned-outcome-completion        7598d7ef [codex/owned-outcome-completion]
...
```

A name-prefix or branch-prefix test sees `richos`, a detached HEAD and no branch, and concludes it is
not a Codex workspace. §31 anticipated exactly this and said so — *"two of the nine live outside any
`-wt/` directory, so a branch-only test misses them"* — and this one defeats a path test too, because
the only thing identifying it is the `~/.codex/` prefix of its working directory and the
`codex-thread.json` file beside its registration. **Any future exclusion must test the worktree's
path and that marker file, never the registration name and never the branch.**

---

## 9. What I did not establish, marked rather than rounded away

- **Whether the merges were authorized.** §4. The repository cannot answer it; only he can.
- **Codex merges in `richos` before 2026-08-29.** Outside the reflog horizon. `femcboost` and
  `richos-hq` are covered for their full lives and both start at 2026-08-27, so if the practice
  started together, 2026-08-27 is the true start — but I did not prove that for `richos`.
- **When the nine `richos` branches were deleted, and by what.** §7. No trace survives.
- **Codex commits that entered `main` on `cc/sage-fable-r*` review branches rather than through a
  `codex/` branch.** They exist — `e0679a55`, `d8afbc1f`, `125906f5`, `0c0d2b43` are Codex revisions
  carried in by the `sage-fable-r4` … `r7` merges — and they are not in the 165. I did not count them
  because with one author identity there is no mechanical test for "Codex wrote this"; I identified
  those four by reading the merge messages that name them. **The 165 is therefore a floor, not a
  total.**

---

## 10. Non-mutation attestation

No branch deleted, no ref moved, no worktree added or removed, no checkout, no `gc`, no clone, no
`fsck --lost-found`. Every command in this record is a read. The working trees of all five `richos`
`codex/` worktrees, the three in `femcboost`, the one in `richos-hq` and `~/.codex/worktrees/c611`
were not entered for anything but `rev-parse`, `status` and `cat`, and `c611` was clean before and
after.
