# Modifications to the bundled frontend-design skill

Apache License 2.0, section 4(b): *"You must cause any modified files to carry
prominent notices stating that You changed the files."* This file is that
notice. It exists because the bundled `SKILL.md` is **not** byte-identical to
the upstream revision it came from, and a reader deserves to know that before
they treat it as Anthropic's text.

## Provenance

| | |
|---|---|
| Upstream | <https://github.com/anthropics/skills>, `skills/frontend-design` |
| Revision | `00756142ab04c82a447693cf373c4e0c554d1005` (2025-12-04) |
| License | Apache-2.0, text in `LICENSE.txt` beside this file |
| Copyright | Anthropic |

## The change

One difference from that revision, on line 15, in the `Tone` bullet: the word
`retro-futuristic,` is absent from the bundled copy and present upstream.
Nothing else differs — not the frontmatter, not the headings, not the guidance.

## What is not known, and is not guessed

Whether that word was removed deliberately or arrived missing through the
distribution channel the skill was vendored from is **not recorded anywhere in
this repository's history**, so it is not asserted here either. The word was
left as it is rather than restored, because silently editing third-party
content to make a provenance claim come true is the failure this notice exists
to prevent. Restoring it is a one-word change for whoever owns the skill
library; this file is here so that decision is made with the fact in hand.

`engine/skills/README.md` lists this skill as "ship-as-is". That classification
is about the engine's own export pass — whether project-specific content was
stripped — and not a claim of byte-identity with upstream. Read alongside this
file, the two do not contradict each other.

Verified 2026-09-04 against the upstream revision named above.
