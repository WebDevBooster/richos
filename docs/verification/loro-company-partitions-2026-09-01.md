# BLOCKED — the corpus has no company partitions, so Rich's memory does not reach his companies

**Branch:** `echo-opus-lr1` · **Worktree:** `/Users/alex/ab/richos-wt/echo-opus-lr1` · 2026-09-01

Not a blocker on the code — everything in my brief is built, tested and committed, and the
branch is landable as it stands. This is the design question the brief told me to stop and
raise if wiring the seam surfaced one about **what memory reaches which conversation**. It
did, on the first real run.

---

## 1. What I am blocked on

**The CEO's loro corpus has zero company partitions, so five of his six companies have no
company memory at all — and the sixth's memory is what all six were being handed.**

Measured, not inferred. His only corpus is the in-repo dogfood corpus at `richos-hq`:

```
$ node loro/bin/loro-context.mjs corpus --root /Users/alex/ab/richos-hq --format text
  layout: repo (from --root)
  companies: (none)
  records: 573
  notes: compiling the RichOS PRODUCT checkout as the corpus (in-repo dogfood). This is
         RichOS's own company memory — if you are not RichOS, this is the wrong corpus.
```

His own ruling says the same thing in his own words (`wiki/ceo-decisions.md` §5):
*"**No corpus directory exists on disk yet**, so there is nothing to migrate and no data at
risk."* That was true and cheap when it was about a rename. It is the whole problem when the
question is whether memory reaches a company.

**What it looks like from a FemcBoost conversation.** Entity `femcboost`, topic *"how should
we price the coach product"*, run end to end through `Spine`'s own priming path:

```
COMPANY MEMORY (loro) — bearing on: "how should we price the coach product"
• [decision] The one audio-capture click is accepted as the price of ground truth…
• [passage?] Voice Market Signals — The signal: Wispr Flow pricing…
• [passage?] Packaging & signing — Route B — a traditional CA certificate (OV or EV)…
```

Three RichOS items, under a heading a fresh Rich reads as authoritative company memory for
FemcBoost.

**Nothing is broken, and that is why this needs a decision rather than a fix.** An in-repo
corpus has no partitions and `company: null` on every item, which is legitimately the CEO
layer. The lane map has nothing to narrow; the cross-entity guard has nothing to refuse.
Both work perfectly and neither can see it. There is no bug to close.

---

## 2. What I already tried

**Built the lane map for real** (Task 3, commit `e6ef5f9`). Default is now his six
companies, each mapped to a lane of the same name. Then measured what shipping only that
would do:

```
$ node loro/bin/loro-context.mjs compile --root /Users/alex/ab/richos-hq --company femcboost …
EXIT=2
loro --company: no such company partition "femcboost" in this corpus. Known: (none).
```

Exit 2 is `LoroTier::Unavailable`, on every rotation, for every mapped entity — the CEO's
890-char slice replaced by "loro could not be consulted". Proven end to end through the app
with reconciliation bypassed: payload 2,789 chars, no memory. So the map is reconciled
against the corpus before anything is sent, which makes it correct today AND correct the
moment partitions exist, with no configuration change.

**Labeled the provenance** (commit `077025d`). The payload now says whose record it is when
the corpus is one company's own and the reader is a different company — 265 characters,
using only measured facts, resolved through the registry rather than guessed. That makes
the state HONEST. It does not make it right.

**Checked whether partitioning would just work.** It would. Against a two-lane corpus I
provisioned (`ceo/` + `companies/femcboost/` + `companies/deeply/`), entity `femcboost`
compiled to the CEO layer plus FemcBoost and nothing else, and `richos` — whose lane does
not exist there — was refused by the cross-entity guard naming `deeply`'s record. The
machinery is ready. The corpus is not.

**What I did not do:** provision anything. His memory is his, the corpus is a private repo
outside the product repo by his own ruling, and deciding what goes in `ceo/` versus
`companies/richos/` is a judgment about his own record that nobody else gets to make.

---

## 3. The smallest question that unblocks it

**Should his loro corpus be provisioned into `ceo/` + `companies/<id>/` now — and when it
is, does RichOS's existing 573-record wiki go to `ceo/`, to `companies/richos/`, or split?**

That is one question with a small, concrete answer, and it is his because it is his memory.
Everything else follows from it mechanically: the lane map already narrows, the guard
already refuses, and the app already reads the answer off the corpus at boot.

A useful second sentence for him, if it helps him decide: **most of those 573 records are
about building RichOS, not about running his companies.** So "all of it to `ceo/`" would
make RichOS's engineering record reach a FemcBoost pricing conversation forever, and
"all of it to `companies/richos/`" would make his own principles stop reaching anything.
The split is the decision.

---

## 4. What I am proceeding on meanwhile

Everything. Nothing in my brief depended on the answer:

- **Task 1** — the registry is his six companies, `richos` multi-root, proven (`e7401e0`).
- **Task 2** — the seam was already wired at `def1787` before my worktree was cut; my
  brief's premise that `loro_slice` is always `None` was stale. Verified rather than
  re-built: a real 890-char slice inside a 3,176-char payload, the cross-entity guard
  proven by removing it (4 named tests fail), and the empty-corpus and no-corpus paths each
  proven live at exit 0.
- **Task 3** — the lane map is real and reconciled (`e6ef5f9`).
- **Beyond it** — the corpus-provenance line (`077025d`), because an unlabeled
  misattribution was worse than the gap it came from.

The branch is complete and landable. This file is the question, not a hold.
