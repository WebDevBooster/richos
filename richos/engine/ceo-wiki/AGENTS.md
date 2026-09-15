# Wiki — Maintenance Doctrine

The evolving knowledge base maintained by Rich. Based on Andrej
Karpathy's LLM Wiki pattern (see `README.md`).

## Purpose

This wiki is a structured, interlinked knowledge base of the CEO's judgment —
decisions, preferences, precedents, positions (see `README.md`). Rich
maintains the wiki. The CEO curates sources, asks questions, and
guides the analysis.

This wiki is meant to be used as the source of authoritative information and
guiding judgment for how this project's operational and product decisions get
made — it is the second brain Rich consults before ever
interrupting the CEO with a question the record can already answer.

## Folder structure

```
raw/              -- source documents (immutable -- never modify these)
wiki/             -- markdown pages maintained by Rich
wiki/000_index.md -- table of contents for the entire wiki
wiki/zzz_log.md   -- append-only record of all operations
```

## Intake pipeline — from `ceo-inbox/` to `raw/`

Source material doesn't arrive in `raw/` directly — it arrives via
`ceo-inbox/for-wiki/` first (see the parent repo's `CLAUDE.md` for the full
`ceo-inbox/` semantics). When something is sitting in `ceo-inbox/for-wiki/`:

1. Move it into `raw/` here (into a sensibly-named subfolder for its source
   type — see "Priority ranking" below for the naming convention). This step
   alone empties `ceo-inbox/for-wiki/` of that item; `raw/` is now its
   permanent home.
2. Follow the Ingest workflow below on the newly-arrived `raw/` material.

**`ceo-inbox/for-wiki/` is transient. `raw/` is permanent.** A processed inbox
is an *empty* inbox — if a file is still sitting in `ceo-inbox/for-wiki/`, it
has not been ingested yet, full stop. Never leave a copy behind in the inbox
"just in case" — the whole point of `raw/` is to be the one durable archive
`source-*` pages can trust and cite.

## Ingest workflow — the bootstrap path

This is how a `raw/` source (once moved in via the intake pipeline above)
becomes wiki knowledge. Treat this as the **secondary/bootstrap** path — see
"Conversation workflow" below for the path this wiki is expected to grow from
most, day to day.

1. Read the full source document.
2. **Discuss key takeaways with the CEO before writing anything** — an
   explicit discuss-first gate, not a silent auto-ingest. Propose the
   structure/pages you're about to create and get a nod before writing them.
3. Create a summary page in `wiki/` named after the source (the `source-*`
   pattern — see "Page anatomy" in `PAGE-TYPES.md`).
4. Create or update concept pages for each major idea or entity the source
   contains.
5. Add wiki-links (`[[page-name]]`) to connect related pages.
6. Update `wiki/000_index.md` with new pages and one-line descriptions.
7. Append a timestamped entry to `wiki/zzz_log.md` — timestamp format
   `date "+%Y-%m-%dT%H:%M"` (e.g. `2026-06-19T10:56`) — naming the source and
   what changed.

A single source may touch 10-15 wiki pages. That is normal — ingest is a
fan-out operation, not a 1:1 file mapping. Every source that gets ingested
gets its own `source-*` page (or, if it only adds to pages that already
exist, an explicit update note on those pages) — never silently absorbed with
no trace of where it came from.

## Conversation workflow — the primary path

`raw/` is **not** the only path into this wiki, and for a wiki that's been
running for a while, it usually **isn't the main one**. Much durable
knowledge is created live — in a working conversation between the CEO and
Rich — and never lands in `raw/` as a document at all. A reasoning
the CEO hadn't spelled out before, a decision made mid-discussion, a
clarification, or a synthesized answer the CEO confirms is worth keeping: all
of these are valid, first-class wiki material. **Expect conversation-derived
pages and edits to be the primary way this wiki grows**, with file ingestion
mostly reserved for getting started or occasionally bootstrapping a large new
area at once.

When a conversation produces knowledge worth keeping (the CEO asks you to
save it, confirms an offer to save it, or makes a decision):

1. Capture the substance, not the chat transcript — write it as durable
   knowledge, the same way you would from a `raw/` source.
2. Create or update the relevant `wiki/` page(s) following the page format
   below.
3. Cite the conversation as the source (see Citation rules → conversation
   sources). Where a claim restates something already grounded in the
   existing wiki, link to that page with `[[wiki-links]]` instead of (or
   alongside) the conversation citation — conversation pages should be
   well-connected to the corpus, not islands.
4. Add wiki-links to connect related pages, and add inbound links from those
   related pages back to the new page (avoid orphans).
5. Update `wiki/000_index.md` if page coverage changed.
6. Append an entry to `wiki/zzz_log.md` with the timestamp, "conversation
   with the CEO" as the source, and what changed.

**Conversation-derived knowledge is exactly as authoritative as
`raw/`-derived knowledge once confirmed** — it is not a second-tier source.
`raw/` remains immutable; this workflow never modifies it.

### Write-back rule (ties into Rich's escalation ladder)

Every escalation outcome, every correction the CEO makes to something Rich
assumed, and every preference expressed in conversation gets
distilled back into this wiki via the workflow above — not just answered and
forgotten. This is how the same question class stops needing to be asked
twice, and how Rich's escalations shrink over time as this second
brain grows. See the parent repo's `CLAUDE.md` → COO doctrine for the full
escalation ladder this feeds.

## Priority ranking for conflicting sources

If two documents in `raw/` contain conflicting information, compare their
`created` and `updated` dates (whatever frontmatter format the source carries
— ChatGPT exports, web clippings, plain notes — the two fields this rule
actually reads are `created` and `updated`; an ingestion tool that doesn't
stamp both breaks this rule silently). The most recently created *and*
updated document wins.

**Gotcha:** a document with an old `created` date but a recent `updated` date
has its most up-to-date information **at the bottom of the document**, not
distributed throughout. Don't assume the top of an old-looking file is stale
— check where in the file the actual edit happened before concluding a source
is out of date.

Name your `raw/` source subfolders after their source type, e.g.
`raw/ceo-chatgpt-exports/`, `raw/founder-notes/`, `raw/from-web/` — whatever
reads clearly for how you're actually sourcing material.

## Page format

Every wiki page follows this structure:

```markdown
# Page Title

**Summary**: One to two sentences describing this page.

**Sources**: List of raw source files this page draws from.

**Last updated**: Date of most recent update in this format: `2026-06-19T10:56` (`date "+%Y-%m-%dT%H:%M"`)

---

Main content goes here. Use clear headings and short paragraphs.

Link to related concepts using [[wiki-links]] throughout the text.

## Related pages

- [[related-concept-1]]
- [[related-concept-2]]
```

See `PAGE-TEMPLATE.md` for this same skeleton as a standalone, copy-pasteable
file, and `PAGE-TYPES.md` for the shapes different kinds of pages tend to take.

## Citation rules

- Every factual claim cites its source file.
- The word "source" (single-source) or each number (multi-source) is the
  hyperlink text, linking directly into `raw/`. Wiki pages live in `wiki/`,
  so source links are relative and start with `../raw/...` (this directory's
  own `README.md` is at `../README.md`).
- Single source: `([source](../raw/path/to/filename.md))` after the claim.
- Multiple sources: `(sources: [1](../raw/.../first.md), [2](../raw/.../second.md))`.
- The page's own `**Sources**:` header links every listed filename the same way.
- **Conversation citations** (no file to link): `(conversation with the CEO, 2026-06-28)`,
  plain text in the Sources header. **Never** mark a conversation-sourced
  claim "needs verification" — a CEO-confirmed conversation *is* the
  verification.
- Contradictions between sources are noted explicitly, never silently resolved.
- An unsourced claim is marked as needing verification, not asserted as fact.

## Question answering

When the CEO — or Rich, on the CEO's behalf, per the escalation
ladder — asks a question this wiki might answer:

1. Read `wiki/000_index.md` first to find relevant pages.
2. Read those pages and synthesize an answer.
3. Cite specific wiki pages in the response.
4. If the wiki doesn't have the answer, say so plainly — never guess and
   present it as recorded fact.
5. If the answer is valuable, offer to save it as a new page (or fold it into
   an existing one) per the Conversation workflow above.

Good answers get filed back into the wiki so they compound over time — this
is the write-back rule again, from the answering side.

## Lint

On request, audit the wiki:

- Check for contradictions between pages.
- Find orphan pages (no inbound links from other pages).
- Identify concepts mentioned in pages that lack their own page.
- Flag claims that may be outdated based on newer sources (apply the priority
  ranking rule above, including the created-vs-updated gotcha).
- Check that all pages follow the page format above.
- Report findings as a numbered list with suggested fixes.

## Rules

- Never modify anything already in `raw/` — it is immutable source-of-record.
  Adding a newly-ingested file to `raw/` (per the intake pipeline above) is
  not "modifying raw/"; changing or deleting something already there is.
- Always update `wiki/000_index.md` and `wiki/zzz_log.md` after changes.
- Keep page names lowercase with hyphens (e.g. `pricing-model.md`).
- Write in clear, plain language.
- When uncertain how to categorize something, ask the CEO rather than guess.
- **One writer.** Rich is the only one who edits this wiki.
  Teammates propose corrections in their own task handoffs; they never edit
  `wiki/` or `raw/` directly.
- **The wiki carries the CURRENT spec only — never a changelog of itself.**
  When something is superseded, delete the superseded material from the page;
  don't leave a "Superseded: ..." section in place. That history lives in
  git and in `wiki/zzz_log.md` (see "The append-only log" below), not
  scattered across the pages themselves.

## The append-only log (`wiki/zzz_log.md`)

`zzz_log.md` is a real, load-bearing part of this system — and a different
thing from "a page keeping its own history," which the rule above bans.
Every ingest and every conversation-derived edit gets one dated entry:
strictly append-only, newest entry at the bottom, never edited retroactively
to rewrite what actually happened. Each entry states what triggered it
(which source, or which conversation), exactly which pages changed and how,
and — when relevant — what's next. If something needs correcting, that's a
**new** entry that says explicitly it's a correction of a previous one, not a
silent edit of the old entry.

This is the one place "history" legitimately lives outside git — it does not
license history to also accumulate inside individual topic pages. Keep the
two separate: pages are always current; the log is the append-only record of
how they got that way.

## The three crown rules

If you remember nothing else from this doctrine, remember these three —
they are the ones that do the most real work:

1. **Discuss before you write, on ingest.** Never silently restructure the
   wiki from a new source. Propose the plan (which pages, roughly what
   changes) and get a nod before writing anything.
2. **Conversation-derived knowledge is first-class and, over time, primary.**
   The CEO's live word — a decision, a correction, a stated preference — is
   exactly as authoritative as anything ingested from a file, the moment it's
   confirmed. Don't treat it as a lesser source just because there's no file
   to point to.
3. **Current spec only — never a changelog of itself.** A page reflects what
   is true now. Superseded material is deleted from the page, not archived
   in place with a "Superseded" heading. Git history and `zzz_log.md` are the
   changelog; the pages are not.
