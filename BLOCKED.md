# Two font questions that are the CEO's, not mine — `zach-opus-ft1`

**Neither blocks the branch.** The font cleanup is done and verified; these are
two decisions the work ran into that I am not entitled to make, and the position
I proceeded on meanwhile is stated for each. Both are one-line reversals if he
rules the other way.

The governing ruling is `wiki/ceo-decisions.md` §22 — *"there cannot be any
reliance on any system fonts"* — and the 2026-09-01 decision **"Typeface: GO":
serif is Newsreader, sans is Inter, and there is no third role.**

---

## 1. There is no monospace, and ten rules want one

**What I am blocked on.** Ten rules in `app/ui/style.css` use `var(--mono)`: the
memory location, the desk record and its suppressed id, the feedback entry key,
the technical view's title, path and raw output, the techy reason, and the update
detail. All are technical text where column alignment is the point of the type.

Neither approved face is monospaced, and I was told in terms that choosing a
third family is his decision and not an implementation detail.

**What I tried.** I had vendored JetBrains Mono (SIL OFL 1.1, 75,048 bytes) and
it worked. I removed it when the typeface decision landed, because keeping it
would have been exactly the third family the decision rules out.

**The smallest question that would unblock me.** *Do those ten diagnostic
surfaces get a vendored monospace, or do they keep the browser's generic one?*

Three options, cheapest first:

| | what happens | cost |
|---|---|---|
| **1. Leave it** (what I did) | `--mono` resolves to the generic `monospace` keyword. Permitted by the ruling — it is the browser's own last resort, not a named platform face — but it resolves to whatever monospace the machine has, so those ten rules look different on a different computer. | 0 bytes |
| **2. Vendor one** | JetBrains Mono, or IBM Plex Mono, or Newsreader's own sibling. Any is OFL and the work is a `rebuild.sh` edit. | ~40–75 KB |
| **3. Drop monospace entirely** | Set those ten rules in Inter with `font-variant-numeric: tabular-nums`. Columns still align for digits; they stop aligning for paths and identifiers, which is most of what these surfaces show. | 0 bytes, and a design change |

**What I proceeded on.** Option 1. It is within the letter of both rulings, and
these are diagnostic surfaces rather than the product's voice — the least costly
place to stop and wait. **But it is stopping, not finishing:** the ruling's spirit
is that RichOS ships what it renders, and for those ten rules it does not.

---

## 2. Seven glyphs are in neither approved face, and they are the controls he clicks

**What I am blocked on.** The interface draws its own controls out of Unicode.
The settings gear is a literal `⚙` in `index.html`; the navigation toggle is `☰`;
every close button is `✕`; the voice control he taps to stop talking is `◉`; the
"working" state is `◐`.

Measured against each face's own character map — not assumed — of the **30
non-ASCII characters the shipped UI renders, Inter carries 23 and Newsreader
carries 9, all nine of them inside Inter's. Seven are in neither:**

```
⋯ U+22EF   ▾ U+25BE   ◉ U+25C9   ◐ U+25D0   ☰ U+2630   ⚙ U+2699   ✕ U+2715
```

A browser that cannot find a character in the named family does not fail — it
walks silently to the next family. So with **only** the two approved faces
vendored, a system font draws the gear, the hamburger and every close button in
the app: the ruling broken in the most visible place there is, in a stylesheet
that looks perfect.

**What I tried.** I checked whether the approved pair could cover them and it
cannot; the numbers above are that check. I also checked the approved
`round-11.1` mockup's own files — they cover 9 of the 30, because that screen
renders 5 non-ASCII characters and this app renders 30.

**The smallest question that would unblock me.** *Are three tiny symbol subsets
acceptable, or should those seven controls stop being text characters?*

| | what happens | cost |
|---|---|---|
| **1. Keep the subsets** (what I did) | Three Noto faces (all SIL OFL 1.1), each cut to exactly the codepoints it answers for and declared with a `unicode-range` so the browser never consults them for anything else. **They set no text and hold no role in the type system** — they are glyph coverage, the way an icon file is. | **3,080 bytes** |
| **2. SVG icons** | Stop drawing controls with text characters. Cleaner, and the honest long-term answer — the gear was never really a letter. | A design change, and Urban's |
| **3. Drop them** | The seven controls are drawn by macOS, differently on Windows. | 0 bytes, and §22 is broken |

**What I proceeded on.** Option 1, because option 3 is the defect this whole task
exists to remove and option 2 is not mine to make. Removing them is deleting
three files and one token.

**Worth seeing before ruling:** taking these controls off Apple's artwork changed
how some of them look, and that is a consequence of complying rather than a
defect. `docs/verification/vendored-fonts-2026-09-01/raw/compare-sidebar.png` is
the side-by-side; `raw/glyph-ink.txt` has all 30 measured. The gear reads better
(140% of the height it had); the disclosure caret reads narrower (51% of the
width). Neither was tuned — reporting them is the job, changing them is not.
