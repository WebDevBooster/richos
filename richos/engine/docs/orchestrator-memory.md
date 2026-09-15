# Orchestrator memory — the operational second brain, distinct from the CEO's

This document defines a convention: the orchestrator keeps its own
**persistent operational memory**, separate from `ceo-wiki/`. If you're
looking for how the CEO's judgment gets recorded, that's `ceo-wiki/` — this
document is about how the orchestrator remembers **how to run the machine
well**, so it doesn't re-learn the same operational lesson every sprint.

## The two-brain model — read this table before writing to either

Conflating these two substrates degrades both: dumping process lessons into
the CEO's wiki clutters it with operational minutiae the CEO never asked
for; dumping the CEO's actual decisions into orchestrator memory buries them
somewhere the "consult the wiki first" escalation-ladder step doesn't look.

| | `ceo-wiki/` | Orchestrator memory (this doc's convention) |
|---|---|---|
| **Whose knowledge** | The CEO's | The orchestrator's own |
| **What it holds** | Decisions, preferences, precedents, positions about the product/business | Lessons, corrections, process rules about *running the operation* |
| **Curated by** | The CEO (asks questions, guides analysis) | The orchestrator itself |
| **Written by** | The orchestrator (one writer, per `ceo-wiki/AGENTS.md`) | The orchestrator itself |
| **Read by** | Everyone (teammates cite it like a spec) | Primarily the orchestrator; teammates don't need to read another agent's operational notes |
| **Example entry** | "We launch UK-only for the first quarter." | "A completion notification with a stub result is not a handoff — resume once, then take over." |
| **Where it's documented** | `ceo-wiki/README.md`, `ceo-wiki/AGENTS.md` | This document |

If you're not sure which one something belongs in, ask: *is this a fact
about the product/business the CEO would recognize as their own call, or a
fact about how to operate the agent team well regardless of what product
it's building?* The first is `ceo-wiki/`; the second is orchestrator memory.

## The convention

- **One file per lesson**, plus an index the orchestrator loads at the start
  of every session — the same index-plus-files shape `ceo-wiki/` uses for its
  own pages, applied to a different substrate.
- **Frontmatter per file**: at minimum a short slug/title and a category (a
  free-form tag like "handoff," "recovery," "verification" — whatever
  groupings actually help you scan the index quickly). Body: the lesson
  itself, stated as a rule, with just enough context to know when it
  applies — not a full incident narrative.
- **The index is pointers, not a duplicate.** Each index line is one lesson
  title/slug and a one-line summary linking to its file — never the full
  lesson content copied into the index itself. Keep the index scannable in
  under a minute.
- **Durable findings land in `docs/` first, memory second.** If a lesson is
  substantial enough to be a real written finding (an incident writeup, a
  design decision), it belongs in `docs/` (or wherever this project's
  documentation lives) as the durable record — the memory entry is then a
  short pointer to it plus the one-line operational rule, not a second copy
  of the finding.

## Verify-before-trust on recall

A memory entry is a recorded lesson, not a currently-true fact about the
world. Before acting on one, especially an older one, sanity-check that it
still applies: has the underlying mechanism it describes changed since the
entry was written? If a memory entry's advice contradicts what you can
directly verify right now, the direct verification wins — update or delete
the stale entry (see below), don't act on the stale one out of habit.

## Update, don't duplicate

When a lesson recurs with a refinement or a correction, **update the
existing file** rather than adding a new, overlapping entry. A memory system
with three slightly-different entries about the same underlying lesson is
worse than one canonical one — the index should never accumulate near-
duplicates that force a reader to reconcile them.

## Delete when wrong

If a memory entry turns out to have been wrong, or the situation it
described no longer applies (the underlying mechanism changed, the tool
being warned about was fixed), **delete it** — don't leave it in place with
a note that it's outdated. A stale lesson sitting in the index is exactly
the kind of trap "current spec only, never a changelog of itself"
(`ceo-wiki/AGENTS.md`'s rule, applied here too) exists to prevent. Update the
index to match.

## How this relates to `docs/failures-playbook.md`

The relationship runs both directions:

- **The playbook seeds memory.** `docs/failures-playbook.md`'s generic
  failure-mode entries are exactly the kind of lesson worth having as a
  starting memory file each — read it when setting up orchestrator memory
  for a new adoption, and turn any entries that are relevant to your setup
  into memory files.
- **Memory graduates into the playbook.** A lesson that started as a
  project-specific memory entry, but turns out to generalize beyond this one
  project once you've hit it a few times, is a candidate to distill into a
  new, genericized entry in `docs/failures-playbook.md` — so the next
  adoption starts with it already known, instead of re-learning it from
  scratch.

## Setting this up for your project

This document describes the convention; it doesn't ship a populated memory
store (there's nothing generic to pre-fill — memory is inherently
project-specific from the day you start operating). To adopt it: create an
index file and a directory for individual lesson files, following the shape
above, and start writing an entry the first time you hit something worth
remembering. `docs/failures-playbook.md` is the natural seed set to start
from.
