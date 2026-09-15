# Wiki

The CEO's evolving knowledge base — maintained by Rich. Based on
Andrej Karpathy's LLM Wiki pattern:

https://x.com/karpathy/status/2039805659525644595

https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f

## What this is — and isn't

This is the CEO's **second brain**, not documentation. It doesn't describe
what the product does — it externalizes the CEO's judgment: decisions made,
preferences expressed, precedents set, positions taken. It exists so Rich
can answer "what would the CEO decide here?" from the written
record instead of interrupting the CEO for something already decided once.

A well-maintained second brain is what makes Rich a genuine COO
instead of a relay — see `CLAUDE.md`'s COO doctrine section for the escalation
ladder this wiki exists to shrink over time.

## How this wiki grows — conversation first, ingestion to bootstrap

**The primary path is conversation.** Day to day, Rich distills
CEO↔Rich conversations into this wiki, continuously — a decision made
mid-discussion, a preference stated once, a correction to a prior assumption,
an answer worth keeping. This is not a fallback path — it is expected to
become where most of this wiki's growth comes from once the CEO and
Rich are working together regularly.

**File ingestion (`raw/`) is the bootstrap path — mostly to get started.**
Dropping existing material (ChatGPT exports, notes, planning docs) into
`ceo-inbox/for-wiki/` and having Rich ingest it is how you seed
this wiki quickly, before daily conversation has had time to build it up on
its own. Both paths produce equally authoritative pages once confirmed — see
`AGENTS.md`'s Conversation workflow section.

## The intake pipeline

1. The CEO drops material in `ceo-inbox/for-wiki/` — including ChatGPT
   exports from `tools/gpt-exporter/`, if you've adopted it, or any other raw
   source material.
2. Rich moves it into `raw/` here — the permanent, immutable
   provenance archive that `source-*` pages cite. `ceo-inbox/for-wiki/` is
   transient: **a processed inbox is an empty inbox.** If something is still
   sitting in `ceo-inbox/for-wiki/`, it hasn't been ingested yet.
3. Rich distills it: a `source-*` summary page for genuinely new
   material (or an explicit update note on whichever existing pages it
   touched), concept pages created or updated, `wiki/000_index.md` and
   `wiki/zzz_log.md` updated to match.

See `AGENTS.md` for the full maintenance doctrine this pipeline follows.

## Access

- **One writer: Rich.** Same pattern as single-writer-to-`main` —
  teammates never edit this wiki directly. If a teammate spots something
  wrong, missing, or stale, it goes in their handoff as a proposed correction;
  Rich reviews it and lands it here.
- **Everyone reads.** Every teammate treats this wiki as a decision
  reference, the same way they'd treat a locked spec — spawn prompts cite
  specific wiki pages by name when relevant, rather than re-explaining a
  decision that's already recorded.

## Folder structure

```
raw/              -- source documents (immutable -- never modify these)
wiki/             -- markdown pages maintained by Rich
wiki/000_index.md -- table of contents for the entire wiki
wiki/zzz_log.md   -- append-only record of all operations
```

## About the project

<!-- TODO (adopter): 2-4 paragraphs on what this product/company is, its core
     one-line promise, and the category it's creating. If you ran
     skills/bootstrap-interview/SKILL.md, its Stage 1 (Product & domain)
     answers already became wiki/vision-and-positioning.md (see
     PAGE-TYPES.md) — replace this whole section with a pointer to that page
     instead of duplicating it here, rather than filling this in separately. -->

## Obsidian-compatible

This wiki's `[[wiki-link]]` format and `.gitignore` (which excludes
`.obsidian/` folders) are Obsidian-compatible by design — open `wiki/` as an
Obsidian vault for a visual graph view of the whole corpus if that's useful to
you. Not required; plain Markdown reading/editing works fine without it.

## Setting up

This directory is ready to use as-is — nothing to rename, no placeholders to
fill before Rich can start using it. Read `AGENTS.md` (the
maintenance doctrine) and `PAGE-TYPES.md` (the kinds of pages this wiki holds)
first, then either drop your first source into `ceo-inbox/for-wiki/` or just
start talking to Rich — he will do the rest.
