# `shots-home/` — the home screen, as WebKit actually painted it

Written by `tests/home.js` on every run, out of WebKit's own compositor at 1440 x 900, through
the real shell (`index.html` + `home.js` + `home.css` + `home/field-*.js` + `main.js` + `mock.js`).
Every one is pixel-verified before it counts as evidence — a flat fill is reported as evidence of
nothing, never as a pass.

**Committed, unlike most of this directory's output**, for the same reason `shots-26/` and
`shots-5b/` are: the CEO asked to see two of these states side by side, and the numbered row is
the state everyone lands on rather than a failure mode. They are overwritten on every run and
are not byte-stable; read the suite's exit code, not a `git diff` over a PNG.

| File | What it is evidence of |
|---|---|
| `home-named.png` | The home screen as it ships, after the rulings of 2026-09-02: `round-11.1/v1` "Constellation"; the company row as `All 1 2 3 4 5 6` on one line, which is now the default for everyone; the first-run banner in the top right; and the door — `round-11.2/v1`'s sill, labeled "Talk to Rich" with `Enter` under it — in the left column under "of your attention saved". |
| `home-anonymized.png` | The numbered row measured: six discs, each as wide as it is tall, beside `All` as a capsule. The name is what a click reveals, so this frame IS the resting state rather than a mode somebody turns on. |
| `home-app-ui.png` | After the switch: the regular app UI, the picture stopped, focus on the composer. |
| `home-returned.png` | After clicking the wordmark in the upper left: back on the home screen, the picture resumed rather than rebuilt. |
| `home-settings-dark.png` | The company-button panel in dark mode — one line per company, the registry name, the label field (empty, with the NUMBER that button carries as its hint) and the Show switch. |
| `home-settings-light.png` | The same panel in light mode. It is the one part of this work that renders outside `#home`, so it is the one part with two lightings, and both are measured. |

The contrast numbers behind these frames are printed by the suite itself and are measured from
these pixels, not from tokens — see the method note at the top of `tests/home.js`.
