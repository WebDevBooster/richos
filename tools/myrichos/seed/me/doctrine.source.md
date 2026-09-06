<!-- A POINTER, NOT A COPY. The two fields below are read by check-myrichos.sh. -->
canonical: @RICHOS@/app/crates/richos-core/doctrine/inner-doctrine.md
canonical-sha256: @DOCTRINE_SHA@

# The standing instruction — where it actually lives

This file is a **pointer**. The person layer's template is not stored here, and it must not be
copied here.

The central-folder design put `me/doctrine.source.md` in this folder as the template the standing
instruction is rendered from. Between that design being written and this folder being built, the
template **was built**, and it landed somewhere else, deliberately and with reasons that are
better than the ones for putting it here.

```
the template   app/crates/richos-core/doctrine/inner-doctrine.md   (in the richos repository)
renders to     ~/Library/Application Support/com.richos.app/inner-doctrine.md
by             app/crates/richos-core/src/doctrine.rs, ensure_rendered()
delivered by   --append-system-prompt-file
```

## Why a copy here would be wrong

**§1.3 of the design is the whole argument, applied to itself:** *"`myrichos` holds the ONLY copy
of anything it holds. Every other location holds a POINTER to it, never a copy."* The template
already exists, under version control, with tests. A second copy in this folder would be a second
copy of the most consequential piece of text in the product — and §7 already conceded that
staleness is a property of **copies**, not of centrality. The design's own strongest evidence is
that thirteen guard scripts drifted from their upstream because someone made copies.

**And `doctrine.rs` decided the location on the merits, not by accident.** It renders the file
into Application Support rather than into any human-editable directory, and its reasoning is
recorded in the module: the engine's `CLAUDE.md` is an adopter-owned file the provisioner is
written never to overwrite, which is right for an adopter's orchestration doctrine and exactly
wrong for the product's own governing instruction. A file the app trusts must not be a file a
person edits.

The rendered file carries the identity of what produced it on its first line — the template's
digest and the identity's — and `ensure_rendered` recomputes the whole expected render and
compares it byte for byte. A stale template, a changed name, an edit, a truncated write: all
replaced, none honored. That is this project's freshness contract applied to a prompt, and it is
strictly stronger than anything a folder copy could offer.

## What this folder contributes instead

The check the design asked for and the code does not have: **the pointer above is verified.**
`check-myrichos.sh` resolves `canonical:` and compares the template's live digest against
`canonical-sha256:`. If the template changes, that is not silent — it is a named failure, with
both digests printed.

That matters because the alternative is already on this machine. Four symlinks in
`~/Library/Application Support/RichOS/` have pointed at a directory that does not exist since
2026-09-04, and nothing has ever mentioned it.

## If you want to read it

Read the rendered file — it is the one that is actually in force:

```
cat "$HOME/Library/Application Support/com.richos.app/inner-doctrine.md"
```

To change it, change the template in the repository and let the app re-render. Editing the
rendered file does nothing: it stops matching, and it is replaced at the next start.

## What it contains

Six things and nothing else, which is the inner-doctrine design's §4.2 spec: who he is and that
he is durable; who he is talking to and in what register; how absence is reported; the precedence
of his own instructions over stored notes; what he does not do; and the safety floor. Plus the
dialect clause, which is load-bearing rather than decorative — measured on 2026-09-06, the
doctrine without it answered the first product-shaped question with a British spelling.

Under 4 KB, on purpose: it is re-sent on every request of every turn, so length there is a
permanent tax rather than a one-time cost.

**What it must never contain is a company name.** A system prompt is fixed at spawn, one chat
lease serves every company, and the thread switches underneath it — so a company name in that
file would be a lie the moment he switched companies. That is what `companies/<id>/company.md`
in this folder is for, and it rides a different channel.
