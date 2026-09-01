# loro capitalization — the measurement that decided what may block

`guard-loro-capitalization.sh` blocks two shapes and refuses to block a third. This page is why,
and it is a page rather than a paragraph in the guard because a false-positive rate nobody can read
is a rate nobody can dispute.

Measured **2026-09-01**, against the record as it stood at `richos-hq` `c332992` and `richos`
`4a16e60`, over **1,732 occurrences** of the word: 1,322 in `richos-hq` markdown, 410 in `richos`.
The ground truth is the sweep landed the same day, in which every site was adjudicated
individually — 82 changed and roughly 2,200 deliberately left alone.

## The rule being enforced

CEO, 2026-09-01, verbatim:

> "When used as a generic term within a sentence like 'Add this to loro.' the term loro should be
> spelled lowercase. But when used at the beginning of a sentence or when it functions as a proper
> noun, it should be spelled as 'Loro' with an uppercase 'L'. The same applies when loro is within a
> heading or title where each word is capitalized."

Canonical page, with the decision table: `wiki/loro-concept.md` in `richos-hq`.

## The three shapes, scored

| Shape | Flagged | Correct | False | FP rate | Verdict |
|---|---|---|---|---|---|
| `HEADING` — the word opens an ATX heading | 9 | 9 | 0 | **0.0%** | **BLOCKS** |
| `SENTENCE` — the word follows sentence-ending punctuation on the same line, in prose | 29 | 29 | 0 | **0.0%** | **BLOCKS** |
| `LIST` — the word opens a bullet, an ordered item or a table cell | 30 | 12 | 18 | **60.0%** | **reports only** |

## How SENTENCE got to 0.0%, honestly

It did not start there. The first run flagged 23 and missed 8, and the corrections were these, each
one measured rather than guessed:

1. **A sentence can end inside a bold run.** `9. **Push, not just pull.** loro feeds …` — the
   closer is `**`, not whitespace. Allowing markdown emphasis characters in the closer class
   recovered **8 true positives** in one change.
2. **`*` is not a bullet.** ` * loro context compiler — …` is the continuation line of a C-style
   block comment far more often than it is a markdown bullet. Treating it as one produced **35 of
   53** false positives on the LIST shape.
3. **A hyphen means a compound, not a word.** `loro-context`, `loro-correction`, `loro-vs-RAG` are
   command names and labels. The hyphen rule removed **3** false positives and cost nothing.
4. **An ordered-list marker is not a sentence end.** `5. loro-CORRECTION` was reaching SENTENCE
   through its `5.`.
5. **A blockquote can sit behind a comment lead.** `loro/lib/privacy.js:8` quotes
   `wiki/loro-architecture.md` as ` * > Company memory is sensitive. loro keeps memory SCOPES…`.
   Quoted material is never ours to re-case, and the plain `^\s*>` test did not see it.
6. **In a source file, only comment lines are prose.** `loro/test/run.js:113` is a page body inside
   a test fixture — `['Pointer', 'A mirror is a POINTER … . loro indexes it.']` — and a code line
   carrying a string literal is not a sentence.
7. **`.txt` is captured output here.** The last residual was a precision-output capture under the
   row-currency replay directory of the PRIVATE `richos-hq` record — not a file in this repository —
   which is a captured run of the row-currency sweep rather than prose. See the stated hole below.

Four of the five "false positives" in the first scored run turned out to be **true positives the
markdown-only sweep had never looked at** — the module headers under `loro/`, where
`* loro WRITER — how a belief gets recorded` sat against the wiki's own `# Loro writer`. They were
fixed rather than exempted, which is the outcome a measurement is supposed to produce.

## Why LIST does not block, in its own words

Eighteen false positives, and none of them is exotic:

- **16** are table rows in `design/mockups/rounds/round-3/v2/NOTES.md` whose first cell quotes the
  literal string the mockup renders — `| loro · 14 months · 7,500 memories | 11px | … |` — inside a
  landed append-only round snapshot, with the screenshot named in the last cell. Changing the text
  would desynchronize the record from the artifact it measures.
- **2** are bullets in lists whose every other item is also a lowercase fragment:
  `- files and URLs used` / `- loro references` / `- ECS objects referenced`, and
  `- filesystem and Git authority adapters` / `- loro compiler/writer invocation`. Capitalizing one
  word there would be the inconsistency, not the fix.

A blocking guard with a false-positive class gets waived, and habitual waiving is how a defense
decays into a formality. So this shape names itself, prints the rule of thumb — capitalize it only
if the sibling items do — and gets out of the way.

## The two shapes not attempted at all

**Title-case headings.** "The Loro Architecture" takes a capital; "## What loro is" does not.
Separating them needs a stop-word model *and*, in this record, the sibling headings of the same
file. `### 1.6 — loro structure` changed because every other `### 1.n —` heading in
`CEO-TODOs.md` capitalizes its first word. `## Defect 4 — loro had no writer` did **not** change,
because Defects 1 through 3 are lowercase after the dash. No line-local rule gets both right.

**Paragraph starts across a line break.** Of 48 line-initial sites in `richos-hq`, **37 were
mid-sentence wraps** — the previous line ends "where the", "another company's" — and 11 were real
paragraph starts. The guard sees the new content of one tool call, which may itself begin
mid-paragraph, so it often has no previous line to read. At 77% wrap this shape is worse than LIST,
and it is unflagged.

Under-flagging is the policy. A wrong capital reads as a branding claim the CEO has not made, so
lowercase is the safe direction and the guard takes it.

## The stated hole

`*.txt` is exempt as a captured file type. In this record prose is written in `.md` and the only
`.txt` files carrying the word are captured command output, which is the measured basis for the
exemption — but a `.txt` file that really is prose is **not checked**. That is the cost, it is
written here rather than discovered later, and the fix for it is to write prose in `.md`.

## Reproducing the numbers

The guard's detector is the same code in both directions — there is no second implementation to
drift. To re-score after the record changes, run the guard over each candidate site as a `Write`
payload and compare against `git log -S` for the sweep commits on the `zach-opus-lo1` branches of
`richos-hq` and `richos`.
