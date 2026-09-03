# Publication readiness — what a stranger would have read, and what was done about it

**Author:** Reed (Source-Reading & Knowledge-Extraction Specialist). **Date:** 2026-09-03/04.
**Requested by:** Rich, on behalf of the CEO.
**Worktree:** `/Users/alex/ab/richos-wt/reed-opus-pub1` · **Branch:** `reed-opus-pub1` ·
**Base:** `richos` main `2e1bd9f`.
**Scope:** the whole `richos` tree read with a stranger's eyes, in four categories, with the
findings fixed in place.

---

## 0. THE THING TO READ FIRST — git history

**Yes. Private material is reachable in git history, and it is the single largest gap between
what this pass achieved and what publishing this repository would actually disclose.**

Everything section 3 removed from the working tree is one command away in the history of the
same repository. Two exhibits, both verified on disk rather than reasoned about — run either
one and it prints today:

```
git show 2e1bd9f:engine/scripts/lib/publication-boundary.py | grep 'Liz Harris'
   ->  002 Liz Harris podcast.mp3          <- the recording
       002 Liz Harris podcast transcript.txt   <- a rendering of it

git show 2e1bd9f:.publication-boundary | grep 'WHAT DEFEATS IT'
   ->  #   drop. WHAT DEFEATS IT: a rewrite AND a rename together, or a
```

Measured across all 1,163 commits reachable from every ref:

| String removed this pass | Commits that still contain it |
|---|---|
| the third-party podcast guest's real name | **712** |
| "I have never f---ing approved more than 2 splash screens" | **402** |
| "how should we price the coach product", with the record slice under it | **622** |
| "WHERE THE F--K IS FRANK THIS F---ING TIME" | **298** |

**What is NOT in history, checked and stated so the size of the problem is honest:**

- **No credentials, keys or tokens.** The only matches for live-secret patterns across all
  10,203 historical blobs are the secret scanner's own fixtures — `scan-secrets.sh`,
  `scan-secrets.test.sh`, `root-contract.test.sh`, `contract-integrity-probe.sh` — the same four
  files as in the working tree. `AKIAIOSFODNN7EXAMPLE` is AWS's published example key.
- **No media and no transcripts, ever.** Zero `.srt`, `.vtt`, `.mp3`, `.m4a`, `.wav`, `.mov` or
  `.mp4` paths have ever existed in this history. The 2026-08-29 leak predates the 2026-08-29
  rewrite; `f1bb459`, the removal commit the old files cite, is **not a valid object here**.
- **One category-2 item nobody has noticed:** 29 `.claude/inflight-acks/*.ack` files and one
  `BLOCKED.md` were committed and later gitignored. They carry agent names, session ids and
  absolute worktree paths — e.g. `worktree: /Users/alex/ab/richos-wt/zach-opus-prem1`. Cosmetic
  by the CEO's own ruling, listed for completeness.

**There is a contradiction in the record about whether this matters, and it needs resolving
before the first push.** `richos-hq/wiki/open-source-strategy.md` says, under "Mechanics when
the day comes": *"Fresh-start export at a pinned SHA, never a history-preserving one — internal
material is baked into this repo's git history and would leak with it."* If that is still the
plan, section 0 is moot and this pass is belt-and-braces. But that sentence was written about a
split that has already happened — `richos-hq` exists, `richos` history was rewritten on
2026-08-29 — and since then this repository has taken 1,163 commits, a root `LICENSE`
(`dbd7537`) and a `.github/README.md` home page committed by the CEO himself (`7c2052e`). Every
one of those is the behavior of a repository that publishes **as it stands, with its history**.

**Freshness rule applied:** the more recent artifact wins, so I am reporting on the assumption
that history ships. **This is a decision, not an engineering question, and it is the CEO's:**
publish with history and accept the above, or mint the public repository from a pinned SHA and
the above disappears entirely. It is out of scope to fix in this pass by your own instruction,
and I have not touched history.

---

## 1. Conclusions

1. **The root cause is not sloppiness — it is this project's documentation doctrine working
   exactly as designed, in a repository it was never written for.** "Write the WHY into the
   file, including the incident that caused the rule" is correct and produced the best files in
   this tree. It has no concept of a reader who is a stranger. Left alone it would have kept
   generating `.publication-boundary`-shaped files forever. **Fixed as a MODE, not a patch**
   (section 2).
2. **The worst single finding is inside the privacy mechanism itself.** `publication-boundary.py`
   used a **real third-party podcast guest's name** as its worked example of media provenance,
   four times, in the file whose whole job is to stop private material reaching a public page.
3. **The most screenshot-able finding is the founder quoted verbatim at his angriest**, in
   twenty-four places across shipping product source and five engine guards — one of which
   *printed his profanity at whoever tripped it*. The private record had already edited the
   profanity out of its own copy. The public tree was carrying the rawer version.
4. **One finding is a publication blocker I could not fix and did not try to:** the shipped
   binary hardcodes the CEO's six real companies and their absolute paths as its default entity
   registry, and prints the list at boot to any customer who double-clicks it (section 5.1).
5. **Category 2 is exactly as cosmetic as the CEO said**, and it is large: **170 files, 633
   occurrences** of `/Users/alex`, plus 84 files carrying session-scratchpad paths. **77% of it
   sits in one directory** (`docs/verification/`, 120 files), which makes it a one-sweep job for
   somebody else, later, cheaply. I fixed it only where I was already in the file.
6. **The publication guards still work after the path change**, proven in both directions with
   the refusal and the allow recorded (section 4). The declaration files are intact; none was
   deleted.
7. **Nothing vanished.** Every removal either MOVED to `richos-hq` with a pointer left behind,
   or was restated in place with the rule and the reasoning kept whole.

---

## 2. The doctrine amendment — the root-cause fix

Stated once, in `engine/CLAUDE.md.template` § *"Writing for a Repository That PUBLISHES — the
same doctrine, in two modes"*. Pointers, never copies, from `engine/docs/failures-playbook.md`
§14, from the header of `.publication-boundary`, and from `richos-hq/wiki/open-source-strategy.md`.

**Why that file and not the wiki.** The CEO said *"probably more than one later"*. A rule in
`richos`'s wiki fixes one repository. `CLAUDE.md.template` is what every adopting repository
starts from, so the next public repo inherits it without anybody remembering — and the engine
is itself going public, so it is its own first customer.

**The rule, in short.** The mode signal is `.publication-boundary` at the repository root: it
already declares that a tree gets published, read by two guards, and now by a person. Private
mode is unchanged — write it all. Published mode: the file carries the rule and the general
reasoning **in full**; the incident that caused it lives in the private record with a **one-line
pointer**.

**The test is IDENTIFYING DETAIL, not "is it an incident".** This is my one improvement on the
framing I was given, and it is load-bearing in both directions:

- A dated failure with nobody in it — a guard that shipped with no switch, a claim derived from
  the wrong source — **stays public**. It is what a stranger deciding whether to trust this
  project is entitled to read, and it is what makes the rules survive contact with people who
  never heard them. `docs/verification/idle-land-standdown-2026-09-01.md` is the worked example
  of something that reads like an incident narrative and correctly stays.
- What moves is anything naming **a person who is not this project**; **private material by what
  it IS** rather than what it says; **private business content**; or **the operator personally**.

Two clauses I added because they are where this will next fail:

- **The pointer is part of the rule.** Deleting detail without saying where it went is how the
  reasoning dies — which is the thing the doctrine exists to prevent.
- **It is not only prose.** Test fixtures, example data, default configuration tables and refusal
  messages are governed too. Findings 3.1 and 5.1 are both fixture/table findings, and both were
  invisible to every reading that only looked at paragraphs.

**Prose, no hook**, per the standing order. My case for whether it should ever become machinery
is in section 7.

---

## 3. The enumeration, by category, with what changed

Commit SHAs are on branch `reed-opus-pub1`.

### 3.1 Category 4 — named third parties and private business content

| # | Where | What it disclosed | Done | SHA |
|---|---|---|---|---|
| 4.1 | `engine/scripts/lib/publication-boundary.py:212,213,254,263,264` | A **real podcast guest's full name** as the worked example of media provenance: `002 Liz Harris podcast.mp3` / `...transcript.txt`, and her name reduced into the stem constant's justification. She is not part of this project. | Replaced with an invented name of the **same 19-character stem length**, so the `MEDIA_STEM_MIN_CHARS` claim beside it stays true | `a1f0e13` |
| 4.2 | `docs/verification/loro-company-partitions-2026-09-01.md`, whole file | A **rendered slice of the CEO's private company memory** answering *"how should we price the coach product"*, with three of his private records printed under it; his six companies; the size and contents of his 573/615-record private wiki; a ruling of his quoted; an absolute path into the private repository | **MOVED** to `richos-hq/docs/verification/`; a pointer keeps the engineering finding, which needs none of it | `0f6bf94` |
| 4.3 | `app/ui/splash-library.js:13`, `app/ui/tests/shots-splash/README.md:7` | *"I have never f---ing approved more than 2 splash screens…"* — the founder, verbatim, in shipping source | Restated as the ruling; every requirement kept; wording already in `richos-hq/wiki/ceo-decisions.md` | `a4ed393` |
| 4.4 | `app/ui/home.js:611`, `app/ui/home.css:797`, `app/ui/tests/home.js:1211` | *"All of the doors are shit because they are covering the spectacle…"* — verbatim, three copies | Restated in three numbered parts; the later scoping clarification kept | `a4ed393` |
| 4.5 | `app/ui/splash-library.js:36` | A verbatim quotation about future splash selection | Restated as the ruling | `a4ed393` |
| 4.6 | `engine/scripts/hooks/guard-ceo-ruled-ask.sh:25` **and `:261`** | *"HOW MANY TIMES DO I HAVE TO DISCUSS AND ANSWER THE SAME IDENTICAL SHIT???"* — and `:261` is an `echo`: **the guard printed it at whoever tripped it** | Both rewritten in substance; the count (three in one evening) is the finding and it is kept | `b2f59ca` |
| 4.7 | `engine/scripts/lib/ceo-ruled.{sh,py}`, `ceo-ruled.corpus.md` | Same quotation, three more copies | Same treatment | `b2f59ca` |
| 4.8 | `guard-stated-actions.{sh,py}`, `stated-actions.corpus.md` | *"WHERE THE F--K IS FRANK THIS F---ING TIME"*, *"that f--kshit will never end, will it?"*, *"WHERE THE F--K IS THE NEXT SAGE?"* — seven copies | Rewritten in substance; both measured failures kept | `b2f59ca` |
| 4.9 | `guard-interactive-prompt.sh:17`, `inflight-notify.{sh,test.sh,mutation.sh}`, `CHANGELOG.md:142` | Four more verbatim quotations | Same treatment | `b2f59ca` |
| 4.10 | Six `*.corpus.md` provenance rows | The operator's **other ventures, by name** — `femcboost`, `richos-hq`, `prospects`, `deeply`, `li-profile-data-grabber` — and his transcript directories, which encode the same list plus a home path | "Five separate project repositories on one working machine" makes the identical anti-cherry-picking claim | `940d070` |
| 4.11 | `tools/richos-service` — 9 sites in `README.md`, `lib/repetition-guard.js`, `lib/deletion-guard.js`, `lib/config.js`, `test/run.js` | That the hallucination guards were measured on **the founder's own webinar and his own podcast**, and *"the one carrying the CEO's own words"* | Genericized to "private material" / "the six-track private measurement corpus"; **every number, threshold and rate untouched** | `c09e53b` |
| 4.12 | `docs/briefs/README-transcription-work.md` | *"the CEO's own webinar"*, *"a named third-party speaker"*, *"three recordings of the CEO's own podcast"*, *"three named third-party guests"* | Rewritten to the rule; **all three generalizable lessons kept verbatim** | `adc1299` |
| 4.13 | `engine/CHANGELOG.md` ×4 | *"a real private podcast transcript"*, *"three podcast transcripts of two named third-party guests"*, *"a rendering of the same webinar"*, the wordmark note described to its subject and line count | Genericized; all measurements kept | `adc1299` |
| 4.14 | `docs/ceo/developer-id-setup-2026-08-31.md` | The operator's **real name in a certificate identity**, an absolute path into his home directory, and a letter addressed to him personally (*"You bought the Apple Developer membership today"*, *"v1 is your Mac"*) | **Rewritten in place, not moved** — 8 live references point at it from four runtime scripts, and the Apple knowledge in it is genuinely reusable. Now addressed to "whoever owns the Apple Developer membership" | `f37cd2d` |
| 4.15 | `docs/briefs/norm-brief-repetition-residual-2026-08-30.md`, `...substitution-density...` | *"The 92-minute corpus is the CEO's own webinar"*; *"the two gitignored mp3s"* | One sentence each; the exemplary privacy paragraphs otherwise kept intact for the next author to copy | `adc1299` |
| 4.16 | `tools/richos-service/test/fixtures/captured-hallucinations.js` | **The opposite problem, and worth naming:** the fixture text reads exactly like a real customer call. It is not — the audio was macOS `say` TTS of an invented script — but nothing said so, so a reader would reasonably conclude real call transcripts are acceptable test fixtures | Added the missing sentence, verified against the source brief §3.2 | `c09e53b` |

### 3.2 Category 1 — internal incident narratives

| # | Where | What it disclosed | Done | SHA |
|---|---|---|---|---|
| 1.1 | `.publication-boundary:11-21` | The 2026-08-29 leak in full: 137 asset files, a named third-party speaker, 28 verbatim quotes, three consecutive lands | **MOVED** to `richos-hq/wiki/publication-boundary-incidents.md`; one-line pointer left | `0551261` |
| 1.2 | `.publication-boundary:93-101` | The 2026-09-01 miss: which file, what it was about, its line count, that the instruction had been given twice | **MOVED**, same page; the `PRIVATE_FILES` rationale kept whole | `0551261` |
| 1.3 | `engine/scripts/lib/publication-boundary.sh:8-31` | The same 2026-08-29 narrative, again, in the engine adopters read | Replaced by the rule plus a pointer; the four-defect family paragraph kept, because it has nobody in it | `a1f0e13` |
| 1.4 | `publication-boundary.sh:76-160`, `publication-boundary.py:185-200,470-490` | Corpus-widening narratives naming whose recordings and how many | Genericized; every measured number kept | `a1f0e13` |
| 1.5 | `publication-boundary.sh:150-158` | **The operator's eleven repositories enumerated by name** as the precision claim's scope | "Eleven repositories on one working machine" | `a1f0e13` |
| 1.6 | `engine/CHANGELOG.md` ×2 | The 2026-08-29 / 2026-09-01 incidents dated and attributed | Genericized | `adc1299` |
| 1.7 | `tools/richos-service/test/run.js:1137` | *"the FIFTH instance of the leak the 2026-08-29 publication boundary was built for, and the second in this file"* — a leak tally, in a test | The operational lesson kept verbatim (hooks snapshot at session start, so "the hook did not block it" is evidence of nothing); the tally gone | `c09e53b` |
| 1.8 | `docs/verification/publication-identity-2026-09-01-SEED.md` | An internal blocker note: worktree path, agent name, the CEO's private file discussed by name | **MOVED**; pointer left | `f37cd2d` |

**Deliberately KEPT public, because the test is identifying detail and these have nobody in
them** — listed so the judgment is reviewable rather than silent:

- `engine/scripts/publication-completeness.sh`'s four founding defects (shipped-inert CEO-TODOs
  machinery; a renderer left in the private tree; a workflow unreachable because Actions only
  discovers at a root; a README citing a CI file that exists nowhere). Pure engineering
  rationale, and the best argument in the tree for why that check exists.
- `docs/verification/idle-land-standdown-2026-09-01.md` — a dated account of a blocking gate
  that did not fire, with the measurement of why. Nobody is in it.
- Every `WHAT THIS CANNOT CATCH` section. See 3.3.

### 3.3 Category 3 — bypass recipes, and the line against honest coverage limits

| # | Where | What it disclosed | Done | SHA |
|---|---|---|---|---|
| 3.1 | `.publication-boundary:118` | *"WHAT DEFEATS IT: a rewrite AND a rename together, or a partial excerpt under a new name."* The CEO's own worked example | Replaced by what an identity check does and does not cover, with the specific evasions in the private record | `0551261` |
| 3.2 | `engine/scripts/lib/publication-boundary.sh:100-107` | The same recipe, longer | Same | `a1f0e13` |
| 3.3 | `engine/CHANGELOG.md:623` | The same recipe, a third copy | Same | `adc1299` |
| 3.4 | `docs/verification/publication-identity-2026-09-01-SEED.md:41-46` | **A working evasion of the commit guard, confirmed to work**: *"Staging the new declaration while leaving the old content in the working tree… It works."* It was correctly rejected at the time — publishing the steps is a separate act | **MOVED** to the private record; the pointer says what it was and why it went | `f37cd2d` |

**KEPT, and the distinction is now written into the doctrine:** every `WHAT THIS CANNOT CATCH`
section — paraphrase, a quote under `MIN_QUOTE_WORDS`, a corpus that is not on the machine, a
drip feed, deletion of the declaration. **A published file may state what a control does not
cover.** A guard nobody trusts gets switched off, and an honest measured limit is why anyone
trusts this one. The line: *does a reader finish the sentence knowing the limits, or knowing the
steps?*

### 3.4 Category 2 — absolute paths and personal identifiers (COUNTED, not swept)

Demoted to cosmetic by the CEO's ruling. **Measured, not estimated:**

| Shape | Files | Occurrences |
|---|---|---|
| `/Users/alex...` | **170** | **633** |
| `claude-501` session-scratchpad paths (with session UUIDs) | 84 | 337 |
| `richos-wt/<branch>` worktree paths | 62 | — |
| `~/ab/...` | 16 | 20 |

**Where it clusters** (files containing `/Users/alex`, by directory):

| Directory | Files | Note |
|---|---|---|
| `docs/verification/` | **120** | **71% of the total.** Overwhelmingly captured raw logs and one-off run scripts |
| `docs/briefs/*-assets/tools/` | 22 | Measurement tools |
| `engine/scripts/` | 7 | Comments only — the ones adopters read |
| `app/crates/`, `app/ui/`, `app/src-tauri/`, `app/scripts/` | 13 | Includes the registry of 5.1 |
| `engine/docs/`, root declarations, `tools/native-claude-stdio/` | 5 | |

**Fixed opportunistically, in files I was already editing for a category-1/3/4 reason:**
`.publication-boundary` (`PRIVATE_RECORD` no longer carries a home path — see section 4),
`engine/scripts/lib/publication-boundary.sh:483` (rewritten as the worktree convention it
describes), `docs/ceo/developer-id-setup-2026-08-31.md` (CSR path now read from where the tooling
prints it), and the six corpus provenance rows in 4.10.

**Deliberately not swept.** A mechanical `s|/Users/alex|/Users/<operator>|` would be one command,
but 71% of the targets are **captured evidence**, and rewriting captured evidence is a worse
failure than the disclosure: this project's own dialect guard exempts `raw/`, transcripts,
fixtures and logs *by construction* for exactly that reason. If it is swept, it should be a
declared redaction with a note in each evidence README, not a silent rewrite — and that is a
decision, not a chore.

---

## 4. Guard-still-works evidence for the `.publication-boundary` path change

**The change:** `PRIVATE_RECORD` no longer carries an absolute home path. It went from
`"richos-hq (/Users/alex/ab/richos-hq) — the private HQ repository"` to
`"richos-hq — the private HQ repository, a sibling checkout of this one"`. `PRIVATE_SOURCES`,
which is the machine-readable location, was already relative and is untouched.

**Both directions proven from this worktree, against the edited declaration.** Re-run after the
later `publication-boundary.{sh,py}` edits and identical both times.

**(a) THE REFUSAL I PROVOKED.** A `Write` payload carrying the exact bytes of the declared
`PRIVATE_FILES` file, aimed at `docs/probe-refuse.md`:

```
=== Publication boundary BLOCKED ===
  Refusing to write '.../docs/probe-refuse.md'.
    -> DECLARED PRIVATE BY IDENTITY: content is the declared private file
       'RichOS-logo-wordmark_v3.5_font-info.md' (identity by digest; a rename does not change it)
  THIS FILE HAS ONE HOME, AND IT IS NOT THIS REPOSITORY.
    It is declared in PRIVATE_FILES in .publication-boundary, which says
    the material belongs in richos-hq — the private HQ repository, a sibling checkout of this one
EXIT=2
```

Three things this proves at once: the guard still parses the declaration (no `BROKEN`); the
identity detector still fires; and **the refusal still names where the content belongs**, now
reading the new label — so the path change removed a disclosure without costing the refusal its
teaching value, which was the whole reason that key exists.

**(b) THE ALLOW I CONFIRMED.** A `Write` of ordinary invented prose to `docs/probe-allow.md`:
`EXIT=0`, no output. Silent, as it should be.

**(c) THE CORPUS WAS LIVE, NOT VACUOUS.** The refusal's own footer named only
`docs/reference/local` as skipped — so `../richos-hq` resolved and the corpus was non-empty. With
`CORPUS_MAY_BE_EMPTY=0` an empty corpus would have been `BROKEN`, not a pass.

**(d) SUITE.** `engine/scripts/hooks/publication-boundary.test.sh` — **121/121 cases passed**,
run twice: after the declaration edit and again after the scanner edits.

---

## 5. What I did NOT change, and why

### 5.1 A PUBLICATION BLOCKER I could not fix — the shipped entity registry

**`app/crates/richos-core/src/entity.rs:226-240` ships the CEO's six real companies and their
absolute paths on his Mac as a `const` table in the product binary:**

```rust
pub const CEOS_COMPANIES: &'static [(&'static str, &'static str, &'static [&'static str])] = &[
    ("femcboost", "FemcBoost", &["/Users/alex/ab/femcboost"]),
    ("deeply", "Deeply", &["/Users/alex/ab/deeply"]),
    ...
```

It is not a fixture. **`app/src-tauri/src/main.rs:841-851` prints the list at boot** — derived
from that table, so it cannot drift — whenever no company resolves, which is *exactly* the case
a customer hits by double-clicking:

```
[richos] operator: RICHOS_ENTITY (one of femcboost, deeply, prospects, richos,
         gpt-exporter, webinar-booster) still overrides...
```

**Scale: 38 files and 380 occurrences in `app/` alone**, across the registry, the loro lane map,
the UI mock, and twenty test suites. Already captured in eight committed evidence logs.

**Why I did not touch it.** It is a product change, not a text edit, and the code argues against
itself in its own doc comment: *"a registry is a privacy boundary, and a file that can be
missing, empty, stale or edited is a boundary that can move without anybody deciding to move
it… When a second CEO exists, the loader is a small change against a shape that is already a
list."* **Publishing this repository is the event that makes a second CEO exist.** The condition
the code names has arrived; acting on it is an engineering decision with a behavioral blast
radius, and it is not a reader's to make silently.

**This is the largest remaining category-4 surface in the tree, and `7c2052e` raised its urgency**
— the repository now has a home-page README, so a stranger arrives at a front door rather than a
file listing.

### 5.2 Captured raw evidence — `docs/verification/**/raw/`, `*.log`, `*.jsonl`

120 files carrying `/Users/alex` and 84 carrying session-scratchpad paths with UUIDs. Cosmetic
per the ruling, and rewriting captured evidence to make it prettier is a worse failure than the
disclosure — this project exempts evidence from its own dialect guard for that reason. Counted
in 3.4, left alone. If they are ever swept, it should be a declared redaction.

### 5.3 The engine's own voice, which is a tone decision and not mine

`engine/scripts/hooks/detect-nonnative-worktree.sh:28,492` — the header asks *"how do I know I
f---ed up"* and the detector **prints `WORKTREE FUCK-UP DETECTED` at the operator**. This is the
engine speaking, not a quotation of anybody, so it discloses nothing. It is also the sort of
thing a stranger screenshots. **Product tone belongs to whoever owns the engine's voice, and I
am not changing an operator-facing refusal string on my own judgment.** Flagged, not fixed.

### 5.4 `zach-opus-v1`'s files — untouched, and one finding that landed in his area

`engine/scripts/hooks/contract-integrity.test.sh` and the suite harness: **not opened, not
edited.** I ran only the per-guard suites listed in section 6, never the 42-minute probe.

**The finding, recorded and left alone:** several files I edited are hooks whose `.sha256`
sidecars are minted by `scripts/hooks/install.sh`. Those sidecars are gitignored, so nothing is
committed wrong — but the integrity probe may report drift on Rich's machine until `install.sh`
is re-run after this branch lands. **That is a landing step, not a defect**, and it belongs to
whoever runs the land.

### 5.5 Two stale-record findings surfaced by main moving under me, neither mine to fix

- **`engine/README.md:82-84` still says *"No license has been chosen yet… the current
  all-rights-reserved default"*.** False as of `dbd7537`: `LICENSE` at the root is the unmodified
  AGPL v3 and `LICENSE-TODO.md` records the ruling. This is on the engine's front page, so it is
  the first thing a stranger reads about licensing and it contradicts the file beside it.
- **`richos-hq/wiki/open-source-strategy.md`** still lists the license as the gate on the first
  public push, and still recommends permissive licensing on open-core grounds. The AGPL commit
  message says it already carried the opposite recommendation.

Both are one-line edits owned by whoever landed the license, not by a publication reader.

### 5.6 Also declined, deliberately

- **`docs/briefs/what-is-bundled-2026-09-01.md`** is an internal decision memo addressed to the
  CEO (*"your idea"*, *"a recommendation, not a decision"*) and says plainly *"we have no right
  to redistribute their program"* about a third party's software. It is **honest and correct**,
  and I would rather it were read than not — but it is an internal memo in tone and it discusses
  a licensing exposure. **A judgment call I am escalating rather than making.**
- **`docs/verification/ceo-state-2026-09-01.md`** prints the contents of the CEO's own
  `launches.json` and confirms the state of his home directory. Marginal; category 2 by the
  ruling; left.
- **Test fixtures using the operator's real name** — `app/ui/tests/appearance.js:716-747` and
  `app/crates/richos-core/src/config.rs:191-1449` use `"Alex Booster"` / `"Alexander James
  Booster"` as initials fixtures. Trivially replaceable and I nearly did it, but it is his own
  name on his own commits and it is not a third party's; the doctrine's fixture clause is aimed
  at *other people*. Listed so the decision is visible. Related: `app/scripts/rebuild-survival.test.sh:182`
  hardcodes the Apple Team ID `TZ33A4QCZJ` in a stub, which makes that test instance-specific for
  an adopter — a portability defect more than a privacy one, since a Team ID is public in every
  signed binary.

---

## 6. Verification actually run

Every claim below was read off a command's output, not inferred.

| Suite | Result |
|---|---|
| `engine/scripts/hooks/publication-boundary.test.sh` | **121/121**, twice |
| `guard-publication-writes.sh`, declared-private payload | **exit 2**, refusal text captured (section 4a) |
| `guard-publication-writes.sh`, benign payload | **exit 0**, silent |
| `tools/richos-service` — `node test/run.js` | **292 passed, 0 failed** |
| `engine/scripts/hooks/guard-stated-actions.test.sh` | **45/45** |
| `engine/scripts/hooks/guard-interactive-prompt.test.sh` | **113/113** |
| `engine/scripts/hooks/inflight-notify.test.sh` | **76/76** |
| `engine/scripts/hooks/unasked-deferral.test.sh` | **34/34** |
| `engine/scripts/hooks/guard-unresolved-claims.test.sh` | **55/55** |
| `engine/scripts/hooks/ceo-ruled.test.sh` | 40 passed, **1 FAILED — pre-existing**, reproduced identically with my changes stashed (case `8a`, which reads the live private record) |
| `app/ui/tests/docs-claims.js` | **6/6** |
| `bash -n` / `python3 -m ast` on every edited script | clean |

**One honest gap.** The 20 browser-driven UI suites **could not run in this worktree** —
Playwright is not installed here, which is pre-existing and unrelated. So the one invariant my
`splash-library.js` edit could plausibly have broken was checked directly instead, by replicating
`tests/splash.js` check 1: strip the assignment, `JSON.parse` the remainder. **It parses — 2
variations, round 11, ids `round-11/v1` and `round-11/v2`.** The other app edits are comments and
CSS comments. **Those 20 suites should be run once on a machine that has Playwright before this
branch is trusted**, and that is a real residual risk, not a formality.

---

## 7. Inference and judgment, labeled as mine

Everything above is sourced. This section is not.

1. **The doctrine is the whole finding.** Individually these are twenty-odd sloppy sentences. As
   a class they are one habit, applied faithfully, in a repository the habit was not written for.
   Fixing the sentences without fixing the habit would have bought weeks.
2. **The private record was already ahead of the public tree, which is diagnostic.**
   `ceo-decisions.md` had *edited the profanity out* of a quote that shipped raw in
   `app/ui/splash-library.js`. The public repo was not the careful copy. Nobody was ever asked to
   make it one.
3. **The case for eventually making the mode a machine check — written, per instruction, and not
   acted on.** It would check one thing at write time: *does this file's new content name a
   person, a private artifact, or a home directory, in a repository that carries a
   `.publication-boundary`?* Prose is insufficient for the same reason the dialect rule was —
   that one was swept across 654 sites and took ~20 fresh violations within hours, **including
   into the page carrying the ruling.** I expect the same decay here, because the doctrine's
   pull is toward writing MORE detail and this rule asks for less. **But I do not recommend
   building it now, and not only because of the standing order:** the honest detector is a named
   entity recognizer over prose, its false-positive class is every legitimate mention of a person
   in a public document, and a guard that fires on the CONTRIBUTING file is one somebody deletes.
   The cheap 80% is narrower and worth costing separately: refuse a write that adds a
   home-directory absolute path to a publication-bound tree. That is a regex, its false-positive
   class is nearly empty, and it closes category 2 permanently — after the suite is fixed.
4. **My best guess at what is still unread, and I would rather say so than imply completeness.**
   I read every root declaration, every file in `docs/briefs`, `docs/measurements`, `docs/ceo`,
   `docs/plans`, the publication and CEO-facing engine machinery, the six guard corpora, the
   `ceo-wiki` template, and every hit from ~30 targeted sweeps across all 1,279 tracked files.
   What I sampled rather than read line by line: the 244 files under `docs/verification/`
   (surveyed by grep plus full reads of the 8 highest-risk), the vendored third-party skill
   references under `engine/skills/` (resend, playwright, svelte — external documentation), and
   the bulk of `app/ui/*.js` and `app/crates/**` beyond the sweeps. **If a fifth category-4 item
   is hiding anywhere, my money is on `app/ui/tests/**/README.md`**, which are narrated
   screenshot indexes written in the same voice as the ones that turned out to be quoting him.

---

## 8. Suggested next step

**For the CEO — one decision, and it is the only one here that is his:**
does the public repository ship **with this history** (section 0 stands, and my fixes are the
working tree only), or is it **minted fresh from a pinned SHA** as
`richos-hq/wiki/open-source-strategy.md` still says (section 0 disappears entirely)? Everything
else below follows from it.

**For Rich, in order:**

1. **Land this branch**, then re-run `engine/scripts/hooks/install.sh` so the hook `.sha256`
   sidecars re-mint (section 5.4).
2. **Run the 20 browser UI suites once** on a machine with Playwright (section 6).
3. **Put 5.1 to an engineer** — the entity registry is a publication blocker and needs the config
   loader the code itself already scopes as "a small change".
4. **Fix the two stale-record lines in 5.5** at the same time as anything else touching those
   files.
5. **Queue the category-2 sweep** (section 3.4) behind the suite fix, as a declared redaction
   rather than a silent rewrite.
6. **Put 5.6's first item to the CEO** when he next has the file open — the bundling memo is a
   tone-and-exposure judgment, not a privacy one.

**Documents this touches that are not mine to write:** `engine/README.md`'s License section;
`richos-hq/wiki/open-source-strategy.md`'s license paragraph; a row for the entity registry.
