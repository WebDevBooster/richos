# ESCALATION — a fresh install can now provision a corpus, and has nothing to read it with

**Raised by:** echo-opus-pv1, 2026-09-01. **Branch:** `echo-opus-pv1`.
**Not a stop.** The provisioning work is done and committed; this names the one thing it
cannot decide, and what it does instead in the meantime.

## What I am blocked on

**Where the loro compiler's bytes come from on a machine that has never held them.**

First-run provisioning creates the corpus, the git repo, the partitions and the pointer.
The corpus then needs the program that reads it — `loro-context.mjs` (compile a slice) and
`loro-write.mjs` (write a record, and create a company partition). Three measured facts:

1. **The RichOS product repo ships no `loro/`.** `find` over `/Users/alex/ab/richos` returns
   no `loro-context.mjs`, no `loro-write.mjs`, no `loro/` directory. `loro.rs:118` says so in
   its own words: *"richos has no `loro/` directory and never has."*
2. **The signed bundle ships none either.** `RichOS.app/Contents/Resources` holds exactly
   `icon.icns`; `Contents/MacOS` holds exactly `richos-tauri`.
3. **The only copy on this machine is inside the CEO's private corpus repo**,
   `/Users/alex/ab/richos-hq/loro/` — which is also why loro treats `richos-hq` as "the
   product repo" and refuses `--corpus` for it (`layout.js:391` identifies a product checkout
   BY the compiler's source living in it).

So a customer's fresh install reaches a provisioned corpus and a boot line that says the
compiler is not installed. That is honest, and it is not working.

The record does not answer it. `wiki/open-source-strategy.md`'s mapping table covers
`engine/`, `assets/`, the root README, `wiki/`, `docs/`, `qa-audits/` — and predates the
split that created `richos-hq`, so `loro/` is not in it. The nearest thing to an answer is
`loro/lib/layout.js:389-391`, which calls the compiler's source *"the one thing every RichOS
clone has and no CEO's corpus ever should"* — a sentence that assumes the compiler ships
inside the product, and that is false today in both directions.

## What I already tried

- Installing the compiler INSIDE the provisioned corpus (`<root>/loro`). **Measured against
  the real `loro-context.mjs`: refused** — *"refusing a corpus inside the RichOS product
  repo (`<root>`)"*. The open-source boundary makes this structurally impossible, correctly.
- Installing it as a sibling named `loro/` (`<root>/../loro`). **Also refused**, naming the
  parent, because `productCheckoutContaining` walks up twelve levels.
- Installing it as `<root>/../loro-tools`. **Accepted** — `"layout": "corpus"`. That is why
  the install location is `~/Library/Application Support/RichOS/loro-tools` and why the name
  is not `loro`. This solves WHERE it goes. It does not solve where it comes FROM.
- Reading `open-source-strategy.md`, `loro-structure.md` §"The open-source boundary",
  `packaging-and-signing.md` and `ceo-decisions.md` §5 for a ruling on the compiler's home.
  §5 rules on the CORPUS (private git repo, outside the product repo) and says nothing about
  the compiler.

## The smallest question that would unblock me

**Does the loro compiler's source (`loro/bin`, `loro/lib`, `loro/writer` — 15 files, no
dependencies beyond node) live in the RichOS product repo and get bundled into the `.app` as
a resource, or does it stay in `richos-hq` and reach a customer some other way?**

It is a product/open-source-boundary decision, not an engineering one: the compiler is the
thing that reads his private record, and putting its source in the repo that ships publicly
is the call `open-source-strategy.md` exists to make. Whoever answers it also settles whether
`richos-hq` keeps a second copy (and therefore stays a "product checkout" that refuses
`--corpus`, which is load-bearing for his current dogfood arrangement).

## What I am proceeding on meanwhile

The honest fallback, built and committed rather than described:

- `resolve_compiler_source` looks in three named places, in order:
  `$RICHOS_LORO_SOURCE` (an installer input) → `<bundle>/Contents/Resources/loro` (**where
  the answer belongs, and where the bundle will carry it the day the question is answered**)
  → an install already at `~/Library/Application Support/RichOS/loro-tools`.
- When one answers, provisioning copies it in and stamps `INSTALLED-FROM` with the source
  path and that source's git HEAD, so a stale copy is detectable rather than silent — the
  freshness posture the femcboost repo's own freshness contract states (identity baked
  inside the artifact, verified by the consumer, never a timestamp).
- When none answers, **the corpus is still provisioned** — it is his record either way — and
  the outcome is `CompilerOutcome::NoSource` carrying the list of places looked in. The boot
  line names it, the first-run surface says it in his own words, and nothing anywhere reports
  success. No exit 0 while doing the wrong thing.
- The fresh-install proof in `docs/verification/first-run-provisioning-2026-09-01/` runs with
  `RICHOS_LORO_SOURCE` supplied, which is exactly the stand-in for the bundle resource that
  does not exist yet — and the app boot that follows it has an EMPTY environment, so what is
  proved end to end is everything except where the fifteen files came from.
