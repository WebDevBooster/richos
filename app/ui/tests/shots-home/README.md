# `shots-home/` — the home screen, as WebKit actually painted it

Written by `tests/home.js` on every run, out of WebKit's own compositor at 1440 x 900, through
the real shell (`index.html` + `home.js` + `home.css` + `home/field-*.js` + `main.js` + `mock.js`).
Every one is pixel-verified before it counts as evidence — a flat fill is reported as evidence of
nothing, never as a pass.

**Committed, unlike most of this directory's output**, for the same reason `shots-26/` and
`shots-5b/` are: the CEO asked to see two of these states side by side, and the anonymized one is
a state he intends to publish rather than a failure mode. They are overwritten on every run and
are not byte-stable; read the suite's exit code, not a `git diff` over a PNG.

| File | What it is evidence of |
|---|---|
| `home-named.png` | The home screen as it ships: `round-11.1/v1` "Constellation" with the company row carrying his six real names, two wrapped rows, `All companies` selected. |
| `home-anonymized.png` | The same screen with the six labels set to `1`-`6` — the CEO's own example, *"if the user wanted to anonymize their home screen (for sharing on social media)"*. One row, seven pills, 46px each. This is the state he would post. |
| `home-app-ui.png` | After the switch: the regular app UI, the picture stopped, focus on the composer. |
| `home-returned.png` | After clicking the wordmark in the upper left: back on the home screen, the picture resumed rather than rebuilt. |
| `home-settings-dark.png` | The company-button panel in dark mode — one line per company, the registry name, the label field (empty, with the real name as its hint) and the Show switch. |
| `home-settings-light.png` | The same panel in light mode. It is the one part of this work that renders outside `#home`, so it is the one part with two lightings, and both are measured. |

The contrast numbers behind these frames are printed by the suite itself and are measured from
these pixels, not from tokens — see the method note at the top of `tests/home.js`.
