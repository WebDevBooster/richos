# Page Types

A reference for the kinds of pages this wiki tends to hold, generalized from
real-world use of this wiki pattern. Every page still follows the shared
skeleton in `PAGE-TEMPLATE.md` (Summary / Sources / Last updated / `---` /
body / Related pages) — the differences below are in body structure and
intent only. Use this as a checklist when starting a new page, not a form to
fill in mechanically; skip any type that doesn't apply to your project, and
don't force content into a type it doesn't fit.

| # | Page type | Example filename | What the page should capture |
|---|---|---|---|
| 1 | **Hub/overview** | `project-overview.md` | One paragraph on what this is, the core one-line promise, and a bullet map of every other page grouped by category (mirrors `000_index.md` but in prose). |
| 2 | **Vision & positioning** | `vision-and-positioning.md` | The category this creates vs. its narrower launch niche; the guiding one-liner/thesis; what NOT to over-broaden into yet. |
| 3 | **Target audience & niche** | `target-audience-and-niche.md` | Who this is for first, why that segment, any internal-vs-public messaging split, any long-term mix/ratio goal. |
| 4 | **Product/system architecture** | `product-architecture.md` | The core layers/flow end-to-end; the guiding design principle (what's optimized for vs. explicitly not); what's mandatory vs. optional. |
| 5 | **Feature/mechanic deep-dive** (repeatable, one per major feature) | `<feature-name>.md` | Format/rules of one feature or mechanic. Consider an inline "Build status" blockquote convention for tracking spec-vs-shipped reality as it's implemented. |
| 6 | **Differentiation / philosophy** | `why-we-are-different.md` | Why the incumbent/competitor approach falls short; the core "why we're different" thesis; ties back to vision. |
| 7 | **Competitor research** | `competitor-research.md` | Per-competitor notes: their model, the key lesson taken, what's deliberately NOT copied. |
| 8 | **Market data** | `market-data.md` | Sizing/usage/frustration figures **with an explicit staleness caveat up front** — cite a range, not a point estimate, and date every figure. |
| 9 | **Go-to-market** | `go-to-market.md` | Launch sequencing logic, recruiting/acquisition tactics, a "validate by actions not words" discipline. |
| 10 | **Monetization / business model** | `monetization.md` | Revenue model(s) **in explicit chronological/evolution order**, with an up-front "note on evolution & contradiction" and a closing unresolved-tension callout if one exists — never silently pick a winner among live options. |
| 11 | **Design system** | `design-system.md` | Visual identity basics (palette, mark, component direction), **explicitly framed as a starting point, not a locked spec**, with an up-front "Status & how to use this page" caveat if it's still provisional. |
| 12 | **Product principles / guardrails** | `product-principles.md` | Hard product rules and anti-patterns the team keeps re-deciding not to violate — capture the *rule*, the *reasoning*, and any recorded dissent, so trade-offs aren't silently re-litigated every time they come up. |
| 13 | **Brand & naming history** | `brand-and-naming-history.md` | Name evolution with dates, taglines tried, domain/trademark decisions, an explicit "old name is historical, current name is X" note if it's changed. |
| 14 | **CEO/founder worldview** | `ceo-worldview.md` | Recurring beliefs/instincts that shape tone and design calls — **explicitly disclaimed as context, not wiki-endorsed claims**, attributed faithfully to who actually said it. |
| 15 | **Themed content-pillar index** (index over a folder, not one page per document) | `<theme>-index.md` | For a themed folder of raw source material too voluminous for one page each: a single index page with sub-theme groupings, 1-line-per-source citations, and a closing "how this informs the product/decisions" synthesis section. |
| 16 | **Growth mechanics** | `growth-mechanics.md` | Concrete growth loops/hooks, what's shipped vs. still an idea. |
| 17 | **Marketing & copywriting** | `marketing-and-copywriting.md` | Brand voice rules, which channel gets which tone, locked copy vs. still-draft copy. |
| 18 | **Tech/onboarding reference** | `tech-onboarding.md` | Platform/stack basics relevant to product decisions — not a full architecture doc, just what a non-engineer teammate needs to know to follow a decision. |
| 19 | **Long-term/moonshot vision** (optional) | `long-term-vision.md` | The beyond-current-scope ambition, kept clearly separate from the currently-scoped pages so it doesn't leak into near-term positioning. |
| 20 | **Source summary** (repeatable, one per major raw ingest) | `source-<short-name>.md` | Provenance + priority-ranking note + a "key points" digest linking out to the concept pages that actually absorbed the content — never a duplicate of the raw file itself. See "Source-summary pages" below. |

Special files (not part of the numbered taxonomy, one each): the **Index**
(`wiki/000_index.md`) and the **Log** (`wiki/zzz_log.md`) — see `AGENTS.md`.

## Source-summary pages (`source-*.md`) — the provenance convention

A distinct shape from a concept page:

- Title: `# Source Summary: <Human Title>`.
- Summary line frames it as a specific conversation/document and states its
  role in the corpus, not just its topic (e.g. "the canonical planning
  conversation for X," not just "notes about X").
- An "## About this source" section: who/what produced it, when
  (`created`/`updated` dates spelled out), and — critically — a **priority
  note** stating how this source ranks against others under the recency rule
  when they conflict.
- A "## Key points" or "## What it resolves" bulleted digest, each bullet
  pointing to the concept page(s) that actually absorbed the content
  (`See [[x]]`) — the source page is a map/index into the concept pages, not
  a duplicate of their content.
- Closing "## Related pages".

Purpose: a source page lets a reader quickly learn *which* raw document to
trust and *why*, without re-reading the raw file — the provenance/trust layer
sits above the raw material, one hop below the concept pages.

## Two patterns worth stealing regardless of page type

- **State the epistemic status up front, not buried in the content.** If a
  page is provisional, disputed, or just the CEO's personal take rather than
  a settled team position, say so in the Summary line or a dedicated
  "Status" section before any content — never let a reader discover a page's
  caveat three paragraphs in.
- **Evolving/contradictory topics get an explicit "note on evolution &
  contradiction" up front**, presented in chronological order, closing with
  a named unresolved tension if one exists — never silently pick a winner
  among live, still-contested options.
