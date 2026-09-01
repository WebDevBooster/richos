# Vendored typefaces

Everything RichOS renders text with is in this directory. Nothing here is
fetched at runtime and nothing here is provided by the operating system:
`tauri-codegen` brotli-compresses every file under the staged frontend into the
executable, so these faces are part of the binary, hashed into its signature and
present before the first frame.

That is the whole point of the directory. `wiki/ceo-decisions.md` §22:

> For obvious reasons, there cannot be any reliance on any system fonts when
> implemented in the RichOS app later.

`fonts.css` is the only file in the product that names a typeface. `style.css`
composes those names into `--font` and `--mono` once; every rule in the app says
`var(--font)` or `var(--mono)`.

## What is here, and what it costs

| File | Face | Axes / instance | Bytes |
|---|---|---|---|
| `Inter-Variable.woff2` | Inter 4.1 | `wght` 100–900, `opsz` 14–32 | 168,248 |
| `Inter-Italic.woff2` | Inter 4.1 Italic | static 400 | 54,200 |
| `JetBrainsMono-Variable.woff2` | JetBrains Mono 2.304 | `wght` 100–800 | 75,048 |
| `NotoSansSymbols2-subset.woff2` | Noto Sans Symbols 2 v2.008 | static 400 | 984 |
| `NotoSansSymbols-subset.woff2` | Noto Sans Symbols v2.003 | `wght` 100–900 | 1,380 |
| `NotoSansMath-subset.woff2` | Noto Sans Math v3.000 | static 400 | 716 |
| | | **total woff2** | **300,576** |

The four `LICENSE-*.txt` files add 17,542 bytes, and they ship too — the OFL
requires the license to travel with the font, and these are embedded in the
binary exactly as the fonts are.

Against the 8.8 MB payload ruled in §19 that is **+3.6%**, and it is measured
rather than estimated: the byte counts above are `stat` output on the files in
this directory.

## Why three symbol faces

The interface draws its own controls out of Unicode — the settings gear is a
literal `⚙` in `index.html`, the navigation toggle is `☰`, every close button is
`✕`, the voice control is `◉`, the working state is `◐`.

Of the 30 non-ASCII characters the shipped UI renders, **Inter carries 23**.
The other seven — `⋯ ▾ ◉ ◐ ☰ ⚙ ✕` — it does not have, and a browser that cannot
find a character in the named family walks silently to the next one. Before this
change that meant a system font drew the gear, the hamburger and every close
button in the app, and no amount of reading the stylesheet would have shown it.

Each symbol face is subset to exactly the codepoints it answers for and declared
with a `unicode-range`, so the browser never consults it for anything else.
3,080 bytes for the seven glyphs.

## Coverage limits, stated rather than discovered later

The text faces are subset to Latin-1, Latin Extended-A, the combining marks, and
the punctuation/currency/arrow/math/symbol blocks an English-language interface
uses. Western European text is complete. **Latin Extended-B, the IPA extensions,
Latin Extended Additional (Vietnamese), and every non-Latin script are not
carried** — Inter has no CJK at all, so no subsetting choice could have covered
that. Text outside those ranges falls to the generic `sans-serif` / `monospace`
keyword, which is the browser's own last resort and the one thing the ruling
leaves permitted, so that text is never invisible.

Adding a range costs bytes and nothing else: change `TEXT` in `rebuild.sh` and
re-run it.

## Provenance

Downloaded from each project's own release page, not from a font CDN, so the
license file that governs each face arrived with it.

| Source | URL | sha256 of the archive |
|---|---|---|
| Inter 4.1 | `https://github.com/rsms/inter/releases/download/v4.1/Inter-4.1.zip` | `9883fdd4a49d4fb66bd8177ba6625ef9a64aa45899767dde3d36aa425756b11e` |
| JetBrains Mono 2.304 | `https://github.com/JetBrains/JetBrainsMono/releases/download/v2.304/JetBrainsMono-2.304.zip` | `6f6376c6ed2960ea8a963cd7387ec9d76e3f629125bc33d1fdcd7eb7012f7bbf` |
| Noto Sans Symbols 2 v2.008 | `https://github.com/notofonts/symbols/releases/download/NotoSansSymbols2-v2.008/NotoSansSymbols2-v2.008.zip` | `346c930bbe8eb946701a05c54e9c11a2094dee1d93c387bf1771c0a3e335688f` |
| Noto Sans Symbols v2.003 | `https://github.com/notofonts/symbols/releases/download/NotoSansSymbols-v2.003/NotoSansSymbols-v2.003.zip` | `0c113cdcf6c31d050b80dac39fba2d804a6985281012e76e9220c0a00da007f3` |
| Noto Sans Math v3.000 | `https://github.com/notofonts/math/releases/download/NotoSansMath-v3.000/NotoSansMath-v3.000.zip` | `ac351837b41f8a897f020b97fb0f075ad574c1e9669fb5839ada1f92fd748356` |

sha256 of the vendored output, so a rebuild can be checked against what shipped:

```
8a36a86b221521382420e76795c2c88352c2f801cdb3d266eac9a21794415f30  Inter-Variable.woff2
10edcedb342227017db57ed4d8c11eadbb9004680f12717a85abf8acfa3fbc0b  Inter-Italic.woff2
8eac0999f08aa610b80ba19662e41bc2bed7e9d070d8be0d8e0246de9a976b1e  JetBrainsMono-Variable.woff2
c373cdef52ba7189ca28ce9d62baf8bcabb48b7efd3de802b8d3b1fc6d99f652  NotoSansSymbols2-subset.woff2
e53d10dea569a6851b02ea7670132f36e3f4e7564197f8004e6c5d064fd874f7  NotoSansSymbols-subset.woff2
f808b8b8cf94a7237b764311418978c27b3c95dc1119e9c6ff51824ae44b1544  NotoSansMath-subset.woff2
```

## Licensing

All four projects are **SIL Open Font License 1.1**, confirmed by reading each
project's own license file rather than a summary of it, and each of those files
is committed here verbatim:

| Face | Copyright statement, verbatim from its license file | File |
|---|---|---|
| Inter | `Copyright (c) 2016 The Inter Project Authors (https://github.com/rsms/inter)` | `LICENSE-Inter.txt` |
| JetBrains Mono | `Copyright 2020 The JetBrains Mono Project Authors (https://github.com/JetBrains/JetBrainsMono)` | `LICENSE-JetBrainsMono.txt` |
| Noto Sans Symbols, Noto Sans Symbols 2 | `Copyright 2022 The Noto Project Authors (https://github.com/notofonts/symbols)` | `LICENSE-NotoSansSymbols.txt` |
| Noto Sans Math | `Copyright 2022 The Noto Project Authors (https://github.com/notofonts/math)` | `LICENSE-NotoSansMath.txt` |

**None of the four declares a Reserved Font Name** in its copyright statement,
which is what makes the subsetting here permitted — OFL §3 restricts only names
reserved that way, and no copyright line above carries the "with Reserved Font
Name" clause. The families are still declared under their own names in
`fonts.css`, so nothing is passed off as something it is not.

Three faces are deliberately absent and should stay absent. They are named in
`wiki/ceo-decisions.md` §22 and deliberately **not** named here:

* the commercial face the wordmark was drawn with — never authorized, and not
  needed, because the wordmark ships as outlines;
* the two Apple-supplied serif faces the mockups are set in — the mockups may
  use them, the app cannot, for exactly the same reason it cannot use the
  platform interface faces.

Writing them out here would put the names back in the tree for the next person
to find and ask about, which is the conversation this whole change exists to
end. §22 is one click away and is the authority; this file does not need to be a
second copy of it.

## Rebuilding

`./rebuild.sh` (in this directory) downloads the five upstream archives, verifies them against the
hashes above, and regenerates every `.woff2` here. It needs `python3` and the
network, and it builds its own throwaway virtual environment for `fonttools` —
nothing is added to the repository's dependencies.

## Adopting a different face

`round-11.1` is choosing type for the start screen, and that screen becomes this
app's. If its choice differs from what is vendored here, **its choice
supersedes this** — these faces were picked to satisfy the ruling on a schedule,
not to settle a design question that belongs to the design round.

Adopting one is:

1. drop the `.woff2` and its license file into this directory;
2. change the `src:` line in the matching `@font-face` block in `fonts.css`;
3. change the family name in `--font-text` (or `--font-mono`) in `style.css`,
   if it differs.

Nothing else in the app names a face, so nothing else has to move.
