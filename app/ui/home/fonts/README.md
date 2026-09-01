# Vendored type — round-11.1/v1

Two faces, both **SIL Open Font License 1.1**, vendored so the screen renders identically everywhere
and asks nothing of the machine it runs on ([`ceo-decisions.md` §22](../../../../../../wiki/ceo-decisions.md)).

| file | face | style | sha-256 |
|---|---|---|---|
| `Newsreader-Regular-latin.woff2` | Newsreader | roman 400 | `e71a3bea5993009ab159b89d52d88ba515efd57e8d9324a94c681bfc72c9ac0f` |
| `Newsreader-Italic-latin.woff2` | Newsreader | italic 400 | `e384e31812c1d580b5ae2217ade8ca5fe9e5135ea9c27423359d00a954c28488` |
| `Inter-Regular-latin.woff2` | Inter | roman 400 | `48a0c2503a9c8ec4153302693fff56b3281aba5ce5afd7cf2bd51a03b098cd22` |
| `Inter-Medium-latin.woff2` | Inter | roman 500 | `a1eab7f4970e8a2f70137b1b7379ccad15fd227f2c9c0e65412f280ae9aad73c` |

**Total 168 KB** for all four, against the 100–300 KB §22 anticipated and the 8.8 MB payload of §19.

## Provenance

Downloaded 2026-09-01 from the Google Fonts `css2` API, taking the **`latin`** subset file that the
API serves (`unicode-range: U+0000-00FF, …, U+2000-206F, …`) rather than the full family — that is
the subsetting §22 asks for, done by the upstream rather than by a tool this machine does not have.

- Newsreader — Production Type, `https://fonts.googleapis.com/css2?family=Newsreader:opsz,wght@6..72,400`
  and the `ital,` counterpart. Variable on the optical-size axis (6–72), which is why the 31 px numbers
  and the 14 px lines get different drawings of the same face for free.
- Inter — Rasmus Andersson, `https://fonts.googleapis.com/css2?family=Inter:wght@400;500`.

License texts as published in `google/fonts`: `OFL-Newsreader.txt`, `OFL-Inter.txt`.

## Coverage, checked rather than assumed

The five non-ASCII characters this screen can render — `→` `·` `—` `…` `§` — were **measured** present
in both subsets (advance width in the vendored face compared against the same character in a generic
family, after `document.fonts.ready`). Nothing on this screen falls through to a system face.

## Why these two

**Newsreader** carries the numbers, the owner line and the prose. Round 6.4 used `Iowan Old Style`,
an Apple-bundled Venetian that made the screen read as an instrument rather than a dashboard; that
quality is the thing worth keeping and Newsreader is the open face closest to it — screen-first,
generous x-height, sturdy enough at 400 not to shimmer on a dark ground, and with an italic good
enough to carry *for Alex Booster* at 18 px. Four candidates were rendered side by side at the real
sizes on the real ground before choosing: EB Garamond went too fine on midnight, Spectral too narrow,
Source Serif 4 held up but read cold.

**Inter** carries the letterspaced caps. The RichOS wordmark's own letters are a neo-grotesque, so the
corner and the labels beneath it should rhyme; Inter is the open grotesque that holds even color in
small letterspaced uppercase, and it is the one that can grow into the rest of the app's chrome.
Archivo was the other candidate and read narrower and more newspaper-like at label size.

`Söhne` is referenced nowhere. It was the tool used to draw the wordmark, the wordmark is outlines,
and per §22 the product never asks for it.
