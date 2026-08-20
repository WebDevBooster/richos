# License — NOT YET CHOSEN

**The RichOS engine does not yet have a license.** No `LICENSE` file exists at
the engine root or at the repository root, and none should be added by an AI worker
or teammate — the choice of license (or a commercial EULA, if sold rather than
open-sourced) is a business/legal decision reserved for the owner, not an
engineering decision.

## Current status: all rights reserved by default

In the absence of an explicit license grant, standard copyright default
applies: **all rights reserved.** Nobody outside the owner has any granted
permission to copy, modify, distribute, or sublicense this directory's
contents. That is true however you obtained it — including from a public
repository: publishing source is not a license grant. Do not assume any
permissions beyond what you were explicitly granted in writing, until a
`LICENSE` file lands here or the owner states otherwise in writing.

## One documented exception

`tools/gpt-exporter/LICENSE` is scoped **only** to the vendored GPT Exporter
Chrome extension in that subdirectory (MIT) — that grant does not extend to
the rest of the engine. Every other file here is covered by the
all-rights-reserved default above until the owner picks a license for the engine
as a whole.

## What needs to happen

The owner needs to decide:

1. **Is the engine open-sourced, or sold under a commercial EULA?** These are
   different documents with different obligations.
2. **If open-source:** which license (MIT, Apache-2.0, BSD, etc.)? Each has
   different implications for redistribution, patent grants, and attribution.
3. **If commercial:** what does the EULA permit — internal use only? Per-seat?
   Redistribution rights? Support/warranty terms?

Once decided, replace this file with a proper `LICENSE` (and/or `EULA.md`)
at the engine root, and delete this placeholder.

**No AI worker, teammate, or automated process should ever choose a license on
the owner's behalf.** This file exists so a reader isn't left
guessing about their rights — see `README.md`'s license section for the
pointer to this file.
