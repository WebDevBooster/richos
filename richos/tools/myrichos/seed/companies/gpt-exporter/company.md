# GPT Exporter

Written 2026-09-06 from the sources named at the bottom. **Not yet confirmed by him.**

## What it is

GPT Exporter is a Chrome extension that saves ChatGPT conversations out to Markdown files that
open properly in Obsidian.

The point is that a conversation stops being locked inside ChatGPT and becomes a note in his own
library, with the tags and links that make it findable later alongside everything else he keeps.

## What it has to get right

Everything valuable here is in the details of the saved file, not in the extension's screens:

- Each saved conversation carries its own details at the top, in the shape Obsidian expects.
- Each one has a stable identifier, so re-saving a conversation updates the note rather than
  creating a second one.
- Conversations that branch off other conversations keep the link between parent and child.
- Tags are cleaned up so characters that would break a note never reach the file.

## House rules

- **The exported file is the product.** The extension is only how it is produced. A change is
  judged by what the note looks like in Obsidian.
- **Nobody can run a Chrome extension in a test harness**, so correctness is proven by running
  real saved conversation data through the export and comparing the result against known-good
  files, rather than by clicking through the extension.

## Words used here

- **Export** — one conversation saved as a note.
- **Frontmatter** — the details at the top of the note that Obsidian reads.
- **Vault** — the Obsidian library the notes land in.
- **Branch** — a conversation started from a point inside another one.

---

## Where these lines came from

| Claim | Source |
|---|---|
| Chrome extension exporting ChatGPT conversations to Obsidian-compatible Markdown | the project specification in that folder |
| Frontmatter format, unique identifiers, parent-child relationships, tag sanitization | same — the four things the current work is about |
| Tested with real captured conversation data against expected files, not by running the extension | same |

**Not from him, and still open:** whether this is something he sells, something he gives away, or
something he built for himself; and whether anyone other than him uses it. That answer changes
what "finished" means, so it is left blank rather than guessed.
