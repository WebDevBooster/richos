# `shots-splash/` — the opening screen, and the switch that removes it

Written by `../splash.js` out of WebKit's own compositor, every one decoded and
pixel-counted before it counted as evidence (`lib/harness.js`, rule 3). Overwritten on
every run and not byte-stable: read the suite's exit code, not a `git diff` over a PNG.

They exist because the completion criterion for this surface is observable, not internal —
*launch the app repeatedly and see different variations, then turn it off in the UI,
relaunch, and see it stay off.* One shot per clause.

**The two composition shots are taken with the surface HELD OPEN**, and that is stated here
rather than left for someone to discover: the real splash is gone about a quarter of a
second into a launch, so photographing it means muting the app-ready signal for the length
of the exposure. The suite's `holdOpen()` replaces only the exported `RichSplash.yieldNow`,
which is only what `main.js` calls — the compositions themselves are the shipped ones,
drawn by the shipped renderer from the shipped library, and every assertion about *when*
the surface leaves (checks 8 and 10) is made against the unmuted paths.

| Shot | What it is evidence of |
|---|---|
| `splash-01-round-8-1-v0.png` | `round-8.1/v0` — the CEO's chosen palette, Sovereign, as he chose it. The composition extracted from the study and nothing else: the mark on its ground, the plinth, the rule, the line. No palette rail, no colour chips, no role names, no hex values, no corner labels. Check 5 joins the mat's rendered colour back to that entry's own `surface` token, so this is a photograph of the data, not of a copy of it. |
| `splash-02-round-8-1-v6.png` | `round-8.1/v6` — "all five, tuned together", on a launch that drew a different entry. Deeper ground, gilded gold, machined edge with the keyline rewoven in gold thread, warmer lamp, and the ceremonial strike already landed. The two shots differ because the two library entries differ; nothing in the renderer knows which is which. |
| `splash-03-the-off-switch.png` | The switch, where a CEO would look for it: behind the same gear in the rail footer as the only other preference this product has, under its own heading, just switched off. It ships in the same commit as the surface — the failure mode here is silent, and this control is the only honest instrument for knowing whether the surface is wanted. |
| `splash-04-a-launch-with-it-off.png` | The next launch. No splash, no half-drawn frame, no trace — and the control still holding his answer. `RichSplash.state.declined` reads `"switched off"`. |
