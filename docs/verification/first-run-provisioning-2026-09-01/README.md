# First-run provisioning — measured 2026-09-01

Machine: macOS 15.6, Apple M4. Every number and every line below is a reading taken from a
running process, a signed artifact, or a directory on disk. Nothing is inferred from an exit
code.

**The gap this closes, in the words of the engineer who found it and refused to call it a
feature** (`docs/verification/installed-app-2026-09-01/README.md` §6): RichOS reaches the
CEO's memory only because `~/Library/Application Support/RichOS/loro-root` was created by
hand. No installer, no first-run flow, nothing in the product creates it.

## 1. The gap, proved by removing it — `raw/boot-1-no-pointer.log`

`scripts/gap-proof.sh` copies his app data out, records the pointer's target, removes the
pointer, boots the installed bundle under launchd's own environment, and restores everything
on every exit path. With the pointer gone, the app he has installed says:

```
[richos] loro Tier C: no corpus configured — re-primes carry no company memory
[richos] loro Tier C: tried .../Application Support/RichOS/corpus — not present
[richos] loro Tier C: tried .../Application Support/RichOS/loro-root — not present
[richos] loro Tier C: tried /Users/alex/RichOS/corpus — not present
```

Three candidates, three "not present". `resolve_corpus` is a good resolver over locations
nothing creates.

**Restored the same minute.** `readlink` reads back `/Users/alex/ab/richos-hq`, and all six
files under `com.richos.app/` are byte-identical before and after —
`raw/appdata-before.sha256` against `raw/appdata-after.sha256`, diff empty. Re-verified at
the end of the whole pass:

```
38f1df58…  config.json
c7e6a3d6…  conversation-ledger.jsonl
db78c9f9…  launches.json
6487f72e…  machinery/thr_dbaacd43…/2026-09-01.jsonl
afb0f403…  machinery/thr_dbaacd43…/2026-09-01.raw.jsonl
19099651…  navigation.json
```

`~/ab/richos-hq` itself: `git status` clean at `d5bece7`, untouched.

## 2. A fresh install, provisioned — `raw/fresh-install.log`

`scripts/fresh-install.sh` against a `HOME` that has never seen RichOS. It runs the SAME
`provision::provision` the `provision_memory` command runs and the SAME
`CliContextCompiler::locate` the boot runs (`examples/first_run_demo.rs`).

```
before: no corpus configured — three candidates, all "not present"
the location offered: <HOME>/RichOS/corpus
provisioned: 9 paths — ceo/{pages,pages/private,records,unfiled}, companies/, state/,
             ceo/entities.json, .gitignore, README.md
pointer: <HOME>/Library/Application Support/RichOS/corpus -> <HOME>/RichOS/corpus
git: main @ <40-char sha>, no remote
compiler: 37 files -> <HOME>/Library/Application Support/RichOS/loro-tools
company partition: richos … (one per company in the registry, via loro-write create-company)
after: compiling from <HOME>/.../RichOS/corpus (via the corpus pointer in Application
       Support), tools .../loro-tools, node /opt/homebrew/bin/node
```

Then `loro_reprime_demo`, same empty environment, compiles a real re-prime against the new
corpus and prints the payload.

`RICHOS_LORO_SOURCE` is set for the PROVISION step only. It is an installer input standing in
for the bundle resource that does not exist yet (see `BLOCKED.md` at the branch root). The
resolution afterwards reads **no environment at all** beyond `HOME` and `PATH`.

## 3. The same thing, through the signed bundle — `raw/signed-bundle-first-run.log`

`scripts/app-first-run.sh`, against a Developer-ID-signed `RichOS.app` built from this branch
(`identifier com.richos.app`, `TeamIdentifier TZ33A4QCZJ`, `flags=0x10000(runtime)`), booted
three times against a throwaway `HOME`.

**Boot 1**, nothing in place, environment read back off the running process with `ps eww`
(`HOME`, `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, `USER` — and nothing else), working directory
read with `lsof -d cwd` (`n/`):

```
[richos] loro Tier C: no corpus configured — re-primes carry no company memory
[richos] loro Tier C: tried …/RichOS/corpus — not present            (three of these)
[richos] loro Tier C: RichOS will offer to set one up in the window, and will not pick a
                      location on its own.
```

That last line is new on this branch, and it is what the candidate list was missing: a reader
who got that far had a list and no next step.

**Boot 2**, after provisioning, same bundle, environment holding nothing but `HOME`, `USER`
and launchd's `PATH`:

```
[richos] loro Tier C: compiling from …/Library/Application Support/RichOS/corpus
                      (via the corpus pointer in Application Support), node /opt/homebrew/bin/node
```

No lane warnings, because every company in the registry has a partition — reconciliation
dropped nothing.

## 4. WHAT IS NOT PROVEN HERE, and it is the same limit the last note hit

**No hand, and no accessibility click.** `scripts/click-button.applescript` is written, is
called, and failed: `System Events` reports **zero windows** for the RichOS process. It is not
this build — the same probe against the CEO's own installed bundle at
`/Users/alex/Applications/RichOS.app` also reports zero. The accessibility API cannot reach a
window in a locked session, which is the limit `installed-app-2026-09-01/README.md` §8 hit for
the same reason. When that happens the script SAYS SO in its output and provisions through the
same core function the button calls, so what boot 2 proves is the resolution, which is
identical either way.

What covers the click instead, and what it does and does not reach:

- `app/ui/tests/memory.js` — 8 checks, 25 assertions, the REAL `index.html` + `main.js` under
  WebKit: the dialog opens on a fresh install and ahead of the company question, the location
  shown is byte-identical to the argument `provision_memory` receives (driven from a path the
  surface could not have guessed), one press makes exactly one call, a refusal renders as it
  stands, and an install that is already set up is never asked. **It does not cross the Tauri
  IPC boundary** — `mock.js` answers there.
- `cargo run -p richos-core --example first_run_demo` — everything on the Rust side of that
  boundary, on a clean `HOME`, with no mock anywhere.

The seam neither reaches is the command dispatch itself: a real hand on a real button in an
unlocked session. That is one click away and is not claimed here.

**And the compiler still ships from nowhere.** `BLOCKED.md` at the root of this branch.

## 5. The refusals, attempted — `raw/refusals.log`

`scripts/refusals.sh` + `examples/provision_refusals.rs`, run from outside the crate with a
clean `HOME`. Eight attempts, eight refusals:

| attempted | refused with |
|---|---|
| unset / blank target | "There is no default: a corpus root nobody named would compile the wrong memory, or none, and report success either way." **And the clean HOME is still empty afterwards** — the property, not the message. |
| a relative target | "A launched app's working directory is \"/\", so this would put the record at the root of the disk." |
| inside a loro checkout | names the checkout and loro's own marker (`loro/lib/store.js` + `loro/bin/loro-context.mjs`) |
| inside the richos product repo | names `app/crates/richos-core/Cargo.toml` — **the marker loro's own detector cannot see**, because richos ships no `loro/`, so `isProductCheckout("/Users/alex/ab/richos")` is FALSE today |
| four levels down inside it | the same; "inside" is the walk up, not the directory |
| a directory that is already a corpus | "Nothing was created, nothing was moved, and nothing in it was read" — and the record in it reads back byte-identical, with no `companies/` created by the attempt |
| a directory with unrelated files | "Refusing to write a record into somebody else's folder." |

And the placement question the design turns on, against the real `loro-context.mjs`:

| tools at | result |
|---|---|
| `<root>/loro` | **refused** — "refusing a corpus inside the RichOS product repo (`<root>`)" |
| `<root>/../loro` | **refused** — the same, naming the parent; the walk-up finds it |
| `<root>/../loro-tools` | accepted, `"layout": "corpus"` |

That measurement is why the install location is
`~/Library/Application Support/RichOS/loro-tools` and why the name is not `loro`.

## 6. His step count

**One click.** The window shows the question, the location it will use, and a button. He
types nothing, sees no terminal, and is asked nothing about git. On a genuinely fresh install
he answers two questions in sequence — this one, then the company question that already
existed — so **two clicks in total**, one dialog at a time.
