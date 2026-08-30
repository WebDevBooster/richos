// THE VARIATION LIBRARY FOR THE OPENING SCREEN — DATA, NOT CODE.
//
// Adding a variation is adding an ENTRY. It is never editing `splash.js`, and the two
// things that make that true are checked rather than asserted: `tests/splash.js` check 1
// strips the assignment below and hands the remainder to `JSON.parse`, so this file cannot
// grow a function without failing; check 2 greps `splash.js` for a colour literal, so the
// renderer cannot grow a variation-specific value without failing.
//
// WHERE THESE COME FROM. The seven entries are the approved round-8.1 compositions
// (richos-hq `design/mockups/rounds/round-8.1/`), which the CEO chose in the Sovereign
// palette — v0 is that choice, byte-identical to round-7/v9, and v1-v6 move exactly one
// thing each with v6 folding all five together. The mockups are palette STUDIES: each one
// carries a rail of colour chips with role names and hex values, three corner labels, a
// pointer-tracked lamp and click-to-try-it-on interactions. NONE of that is here. What was
// extracted is the composition only — the mark on its ground, the plinth, the rule, the
// settle — and the extraction was mechanical rather than by eye: v1-v6 differ from v0 in a
// CLOSED set of CSS values (diff the <style> blocks and there is nothing else), and that
// closed set is exactly the token list below.
//
// The mark's geometry is deliberately NOT here: it is verbatim in every version of every
// round, so it lives in the renderer where it cannot drift between entries.
//
// v7-v18 were commissioned 2026-08-30 and more rounds will follow. Each one lands as one
// more object in `variations`, with `tokens` carrying every key the schema names —
// `splash.js` refuses an entry that is missing one rather than drawing it half-dressed.
//
// WHAT v7 ONWARDS COST, said plainly. v1-v6 vary a COLOUR. v7 onwards vary the MATERIAL —
// suede with a nap, bridle leather with a grain, buckram with a weave, urushi lacquer,
// honed slate, velvet, watered silk, enamel over guilloche, oil on canvas in a gold-leaf
// frame. None of those is "v0 with different values", and pretending otherwise would have
// shipped a flat navy rectangle under the CEO's own version's name. So the token set was
// WIDENED, and the widening is listed here rather than left to be discovered:
//
//   surfaceImage    the mat's own paint when it is a gradient rather than one colour
//   keylineWidth    the inner keyline's width, style, border-image and box-shadow, so an
//   keylineStyle      entry can make that line a gold thread, a dotted chase, a bright
//   keylineImage      milled edge, or the rabbet shadow of a picture frame — or remove it
//   keylineShadow     entirely, which two of these versions do
//   materials       THE MATERIAL ITSELF: an ordered stack of flat layers over the mat, each
//                   one a background, a blend mode, an opacity, an inset, a radius, a
//                   border, a mask. This is where the nap, the grain, the weave, the
//                   veining, the moire and the gold-leaf canvas live.
//   markFilter      a CSS filter on the mark, for the two versions that want a plain one
//   signalFilter    the same, on the gold alone
//   relief          an SVG filter on the mark described as VALUES — a noise field clipped
//                   inside the glyph, and bands of shadow or light laid inside or outside
//                   it. There is no CSS filter function for an inner shadow on an SVG
//                   shape, and an inner shadow is exactly what "blocked into leather" and
//                   "cut into slate" are made of. `splash.js` fixes the filter's SHAPE and
//                   this file supplies every number in it, which is the division the
//                   gilding gradient has always lived under.
//
// EVERY ONE OF THOSE IS STILL DATA. Check 1 still JSON-parses this file, so it still cannot
// hold a function; check 2 still greps the renderer for a colour, so the renderer still
// cannot hold a value; and check 14 refuses an entry whose material stack carries a key the
// renderer does not know, so a widening cannot happen by accident. The seven approved
// entries above were re-emitted with the new keys at their defaults and their photographs
// came back BYTE-IDENTICAL, which is the only form of "nothing changed" worth having.
//
// WHAT IS DELIBERATELY NOT HERE, and why, is in this round's own record:
// `docs/verification/opening-screen-2026-08-30/material-reduction.txt`.

window.RichSplashLibrary =
{
  "schemaVersion": 1,
  "round": "8.1",
  "variations": [
    {
      "id": "round-8.1/v0",
      "name": "Sovereign \u2014 as chosen",
      "source": "richos-hq design/mockups/rounds/round-8.1/v0/index.html (round-7/v9, byte-identical)",
      "tokens": {
        "ground": "#0C1322",
        "atmosphere": "none",
        "vignette": "radial-gradient(120% 90% at 50% 38%, rgba(0,0,0,0) 46%, rgba(0,0,0,.42) 100%)",
        "grainOpacity": "0.07",
        "lamp": "rgba(200,215,255,.12)",
        "lampRadius": "1050px",
        "lampStop": "66%",
        "sheen": null,
        "materials": [],
        "surface": "#141E34",
        "surfaceImage": "none",
        "plinthRadius": "8px",
        "plinthShadow": "0 60px 120px -40px rgba(0,0,0,.75), 0 20px 50px -30px rgba(0,0,0,.6)",
        "plinthOutline": "rgba(76,96,135,0.28)",
        "keylineInset": "12px",
        "keylineRadius": "4px",
        "keylineWidth": "1px",
        "keylineStyle": "solid",
        "keylineColor": "rgba(76,96,135,0.16)",
        "keylineImage": "none",
        "keylineShadow": "none",
        "ink": "#DFE4EE",
        "signal": "#C2A35C",
        "gild": null,
        "markFilter": null,
        "signalFilter": null,
        "relief": null,
        "rule": "#C2A35C",
        "ruleWidth": "58px",
        "tagline": "rgba(76,96,135,0.95)",
        "riseDuration": "0.9s",
        "riseShift": "16px",
        "riseDelays": [
          "0.05s",
          "0.18s",
          "0.32s",
          "0.48s"
        ],
        "strike": "none",
        "strikeFrom": null,
        "strikePeak": null,
        "strikeDelay": "0s",
        "strikeDuration": "0s"
      }
    },
    {
      "id": "round-8.1/v1",
      "name": "The ground deepened",
      "source": "richos-hq design/mockups/rounds/round-8.1/v1/index.html",
      "tokens": {
        "ground": "#080D19",
        "atmosphere": "radial-gradient(115% 95% at 41% 46%, rgba(22,33,58,.9) 0%, rgba(12,19,36,.38) 46%, rgba(8,13,25,0) 72%)",
        "vignette": "radial-gradient(120% 90% at 50% 38%, rgba(0,0,0,0) 42%, rgba(0,0,0,.52) 100%)",
        "grainOpacity": "0.07",
        "lamp": "rgba(200,215,255,.12)",
        "lampRadius": "1050px",
        "lampStop": "66%",
        "sheen": null,
        "materials": [],
        "surface": "#141E34",
        "surfaceImage": "none",
        "plinthRadius": "8px",
        "plinthShadow": "0 60px 120px -40px rgba(0,0,0,.75), 0 20px 50px -30px rgba(0,0,0,.6)",
        "plinthOutline": "rgba(76,96,135,0.28)",
        "keylineInset": "12px",
        "keylineRadius": "4px",
        "keylineWidth": "1px",
        "keylineStyle": "solid",
        "keylineColor": "rgba(76,96,135,0.16)",
        "keylineImage": "none",
        "keylineShadow": "none",
        "ink": "#DFE4EE",
        "signal": "#C2A35C",
        "gild": null,
        "markFilter": null,
        "signalFilter": null,
        "relief": null,
        "rule": "#C2A35C",
        "ruleWidth": "58px",
        "tagline": "rgba(76,96,135,0.95)",
        "riseDuration": "0.9s",
        "riseShift": "16px",
        "riseDelays": [
          "0.05s",
          "0.18s",
          "0.32s",
          "0.48s"
        ],
        "strike": "none",
        "strikeFrom": null,
        "strikePeak": null,
        "strikeDelay": "0s",
        "strikeDuration": "0s"
      }
    },
    {
      "id": "round-8.1/v2",
      "name": "The gold given weight",
      "source": "richos-hq design/mockups/rounds/round-8.1/v2/index.html",
      "tokens": {
        "ground": "#0C1322",
        "atmosphere": "none",
        "vignette": "radial-gradient(120% 90% at 50% 38%, rgba(0,0,0,0) 46%, rgba(0,0,0,.42) 100%)",
        "grainOpacity": "0.07",
        "lamp": "rgba(200,215,255,.12)",
        "lampRadius": "1050px",
        "lampStop": "66%",
        "sheen": null,
        "materials": [],
        "surface": "#141E34",
        "surfaceImage": "none",
        "plinthRadius": "8px",
        "plinthShadow": "0 60px 120px -40px rgba(0,0,0,.75), 0 20px 50px -30px rgba(0,0,0,.6)",
        "plinthOutline": "rgba(76,96,135,0.28)",
        "keylineInset": "12px",
        "keylineRadius": "4px",
        "keylineWidth": "1px",
        "keylineStyle": "solid",
        "keylineColor": "rgba(76,96,135,0.16)",
        "keylineImage": "none",
        "keylineShadow": "none",
        "ink": "#DFE4EE",
        "signal": "#C2A35C",
        "gild": [
          "#DFC178",
          "#C2A35C",
          "#96793C"
        ],
        "markFilter": null,
        "signalFilter": null,
        "relief": null,
        "rule": "linear-gradient(100deg,#DFC178,#C2A35C 45%,#96793C)",
        "ruleWidth": "58px",
        "tagline": "rgba(76,96,135,0.95)",
        "riseDuration": "0.9s",
        "riseShift": "16px",
        "riseDelays": [
          "0.05s",
          "0.18s",
          "0.32s",
          "0.48s"
        ],
        "strike": "none",
        "strikeFrom": null,
        "strikePeak": null,
        "strikeDelay": "0s",
        "strikeDuration": "0s"
      }
    },
    {
      "id": "round-8.1/v3",
      "name": "The edge, machined",
      "source": "richos-hq design/mockups/rounds/round-8.1/v3/index.html",
      "tokens": {
        "ground": "#0C1322",
        "atmosphere": "none",
        "vignette": "radial-gradient(120% 90% at 50% 38%, rgba(0,0,0,0) 46%, rgba(0,0,0,.42) 100%)",
        "grainOpacity": "0.07",
        "lamp": "rgba(200,215,255,.12)",
        "lampRadius": "1050px",
        "lampStop": "66%",
        "sheen": null,
        "materials": [],
        "surface": "#15203A",
        "surfaceImage": "none",
        "plinthRadius": "6px",
        "plinthShadow": "inset 0 1px 0 rgba(255,255,255,0.06), inset 0 -20px 40px rgba(0,0,0,0.16), 0 2px 6px rgba(0,0,0,0.5), 0 34px 68px -26px rgba(0,0,0,0.72), 0 96px 160px -48px rgba(0,0,0,0.85)",
        "plinthOutline": "rgba(90,110,150,0.36)",
        "keylineInset": "13px",
        "keylineRadius": "3px",
        "keylineWidth": "1px",
        "keylineStyle": "solid",
        "keylineColor": "rgba(194,163,92,0.22)",
        "keylineImage": "none",
        "keylineShadow": "none",
        "ink": "#DFE4EE",
        "signal": "#C2A35C",
        "gild": null,
        "markFilter": null,
        "signalFilter": null,
        "relief": null,
        "rule": "#C2A35C",
        "ruleWidth": "58px",
        "tagline": "rgba(76,96,135,0.95)",
        "riseDuration": "0.9s",
        "riseShift": "16px",
        "riseDelays": [
          "0.05s",
          "0.18s",
          "0.32s",
          "0.48s"
        ],
        "strike": "none",
        "strikeFrom": null,
        "strikePeak": null,
        "strikeDelay": "0s",
        "strikeDuration": "0s"
      }
    },
    {
      "id": "round-8.1/v4",
      "name": "Lit by a warmer lamp",
      "source": "richos-hq design/mockups/rounds/round-8.1/v4/index.html",
      "tokens": {
        "ground": "#0C1322",
        "atmosphere": "none",
        "vignette": "radial-gradient(120% 90% at 50% 38%, rgba(0,0,0,0) 46%, rgba(0,0,0,.42) 100%)",
        "grainOpacity": "0.07",
        "lamp": "rgba(255,225,168,.10)",
        "lampRadius": "1150px",
        "lampStop": "70%",
        "sheen": "radial-gradient(480px circle at 34% 26%, rgba(255,232,188,.08), rgba(0,0,0,0) 70%)",
        "materials": [],
        "surface": "#141E34",
        "surfaceImage": "none",
        "plinthRadius": "8px",
        "plinthShadow": "0 60px 120px -40px rgba(0,0,0,.75), 0 20px 50px -30px rgba(0,0,0,.6)",
        "plinthOutline": "rgba(76,96,135,0.28)",
        "keylineInset": "12px",
        "keylineRadius": "4px",
        "keylineWidth": "1px",
        "keylineStyle": "solid",
        "keylineColor": "rgba(76,96,135,0.16)",
        "keylineImage": "none",
        "keylineShadow": "none",
        "ink": "#DFE4EE",
        "signal": "#C2A35C",
        "gild": null,
        "markFilter": null,
        "signalFilter": null,
        "relief": null,
        "rule": "#C2A35C",
        "ruleWidth": "58px",
        "tagline": "rgba(76,96,135,0.95)",
        "riseDuration": "0.9s",
        "riseShift": "16px",
        "riseDelays": [
          "0.05s",
          "0.18s",
          "0.32s",
          "0.48s"
        ],
        "strike": "none",
        "strikeFrom": null,
        "strikePeak": null,
        "strikeDelay": "0s",
        "strikeDuration": "0s"
      }
    },
    {
      "id": "round-8.1/v5",
      "name": "The strike, ceremonial",
      "source": "richos-hq design/mockups/rounds/round-8.1/v5/index.html",
      "tokens": {
        "ground": "#0C1322",
        "atmosphere": "none",
        "vignette": "radial-gradient(120% 90% at 50% 38%, rgba(0,0,0,0) 46%, rgba(0,0,0,.42) 100%)",
        "grainOpacity": "0.07",
        "lamp": "rgba(200,215,255,.12)",
        "lampRadius": "1050px",
        "lampStop": "66%",
        "sheen": null,
        "materials": [],
        "surface": "#141E34",
        "surfaceImage": "none",
        "plinthRadius": "8px",
        "plinthShadow": "0 60px 120px -40px rgba(0,0,0,.75), 0 20px 50px -30px rgba(0,0,0,.6)",
        "plinthOutline": "rgba(76,96,135,0.28)",
        "keylineInset": "12px",
        "keylineRadius": "4px",
        "keylineWidth": "1px",
        "keylineStyle": "solid",
        "keylineColor": "rgba(76,96,135,0.16)",
        "keylineImage": "none",
        "keylineShadow": "none",
        "ink": "#DFE4EE",
        "signal": "#C2A35C",
        "gild": null,
        "markFilter": null,
        "signalFilter": null,
        "relief": null,
        "rule": "#C2A35C",
        "ruleWidth": "58px",
        "tagline": "rgba(76,96,135,0.95)",
        "riseDuration": "1.15s",
        "riseShift": "12px",
        "riseDelays": [
          "0.1s",
          "0.38s",
          "0.6s",
          "0.85s"
        ],
        "strike": "fill",
        "strikeFrom": "#333F58",
        "strikePeak": "#E7CB82",
        "strikeDelay": "1.75s",
        "strikeDuration": "0.95s"
      }
    },
    {
      "id": "round-8.1/v6",
      "name": "All five, tuned together",
      "source": "richos-hq design/mockups/rounds/round-8.1/v6/index.html",
      "tokens": {
        "ground": "#080D19",
        "atmosphere": "radial-gradient(115% 95% at 41% 46%, rgba(22,33,58,.8) 0%, rgba(12,19,36,.38) 46%, rgba(8,13,25,0) 72%)",
        "vignette": "radial-gradient(120% 90% at 50% 38%, rgba(0,0,0,0) 42%, rgba(0,0,0,.52) 100%)",
        "grainOpacity": "0.07",
        "lamp": "rgba(255,225,168,.09)",
        "lampRadius": "1050px",
        "lampStop": "66%",
        "sheen": "radial-gradient(480px circle at 34% 26%, rgba(255,232,188,.08), rgba(0,0,0,0) 70%)",
        "materials": [],
        "surface": "#15203A",
        "surfaceImage": "none",
        "plinthRadius": "6px",
        "plinthShadow": "inset 0 1px 0 rgba(255,255,255,0.06), inset 0 -20px 40px rgba(0,0,0,0.16), 0 2px 6px rgba(0,0,0,0.5), 0 34px 68px -26px rgba(0,0,0,0.72), 0 96px 160px -48px rgba(0,0,0,0.85)",
        "plinthOutline": "rgba(90,110,150,0.36)",
        "keylineInset": "13px",
        "keylineRadius": "3px",
        "keylineWidth": "1px",
        "keylineStyle": "solid",
        "keylineColor": "rgba(194,163,92,0.22)",
        "keylineImage": "none",
        "keylineShadow": "none",
        "ink": "#DFE4EE",
        "signal": "#C2A35C",
        "gild": [
          "#DFC178",
          "#C2A35C",
          "#96793C"
        ],
        "markFilter": null,
        "signalFilter": null,
        "relief": null,
        "rule": "linear-gradient(100deg,#DFC178,#C2A35C 45%,#96793C)",
        "ruleWidth": "58px",
        "tagline": "rgba(76,96,135,0.95)",
        "riseDuration": "1.15s",
        "riseShift": "12px",
        "riseDelays": [
          "0.1s",
          "0.38s",
          "0.6s",
          "0.85s"
        ],
        "strike": "bloom",
        "strikeFrom": null,
        "strikePeak": null,
        "strikeDelay": "1.75s",
        "strikeDuration": "0.95s"
      }
    }
  ]
};
