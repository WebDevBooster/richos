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
    },
    {
      "id": "round-8.1/v7",
      "name": "Midnight suede, saddle-stitched",
      "source": "richos-hq design/mockups/rounds/round-8.1/v7/index.html",
      "tokens": {
        "ground": "#0C1322",
        "atmosphere": "none",
        "vignette": "radial-gradient(120% 90% at 50% 38%, rgba(0,0,0,0) 46%, rgba(0,0,0,.42) 100%)",
        "grainOpacity": "0.07",
        "lamp": "rgba(255,230,182,.10)",
        "lampRadius": "1050px",
        "lampStop": "66%",
        "sheen": null,
        "materials": [
          {
            "background": "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='640' height='520'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.028 0.019' numOctaves='3' seed='7' stitchTiles='stitch'/%3E%3CfeColorMatrix type='saturate' values='0'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E\") 0 0 / 640px 520px",
            "blend": "soft-light",
            "opacity": ".34"
          },
          {
            "background": "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='220' height='220'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.7' numOctaves='2' seed='3' stitchTiles='stitch'/%3E%3CfeColorMatrix type='saturate' values='0'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E\") 0 0 / 220px 220px",
            "blend": "overlay",
            "opacity": ".42"
          },
          {
            "background": "linear-gradient(118deg,rgba(255,236,200,.11) 0%,rgba(255,236,200,.02) 38%,rgba(8,14,30,.32) 100%)",
            "blend": "soft-light"
          },
          {
            "background": "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink' width='602' height='496' viewBox='0 0 602 496' preserveAspectRatio='none'%3E%3Cdefs%3E%3Cpath id='s' d='M23.3 13.5L29.5 14.5M34.1 13.5L40.3 14.4M45.2 13.4L50.3 14.3M55.2 13.1L60.6 14.3M66.1 13.3L71.5 14.3M76.2 13.4L81.6 14.3M86.9 13.2L92.1 14M96.7 13.8L102.9 14.5M108.2 13.3L113.9 14.2M118.4 13.2L124.4 14.2M129.3 13.3L134.6 14.3M139.2 13L145.4 14.2M150.4 13.4L155.8 14M160.6 14L166.5 14.7M171.4 13.2L177.6 14.1M182.5 13.9L187.8 14.8M192.2 13.5L198 14.7M203 13.3L208.4 14.3M213.1 13.2L219.4 14.3M224.1 13.2L230.4 14.1M234.6 13.8L240.2 14.8M245.5 13.1L251.5 14.1M255.6 13.2L261.9 14M265.9 13.5L272.2 14.6M277.2 13.2L282.6 14.2M287.6 13L293 14.1M298.1 13.8L304.5 14.8M308.4 13.2L314.1 14.3M319.9 13.1L325.3 14.3M330.1 13.9L335.3 14.7M340.9 13.5L346.3 14.3M351 13.9L356.4 14.5M361.5 13.7L367.9 14.6M372.1 13L378 14.2M383.2 13.8L388.4 14.9M393.1 13.4L399.5 14.1M404.1 14L410 14.8M414.3 13.2L419.3 13.9M424.7 13.8L430.6 14.4M435.6 13.6L441.3 14.8M445.5 13.5L451.5 14.6M456.8 13.3L461.8 14.2M466.9 13.7L472.6 14.3M478.2 14L483.6 14.7M488.1 13.4L493.5 14.4M498.4 13.8L504.4 14.9M509.7 13.1L515.4 14.2M520.1 13.5L526 14.6M530.6 13.7L536.2 14.5M541.4 13.5L547.4 14.3M551.7 13.8L558.1 14.8M562.6 13.9L568.4 14.6M573.5 13.2L578.8 14.2M584 13.8L587.2 17.9M588.1 23.4L587.2 29.7M588.4 34.2L587.4 40M588.6 44.7L587.4 50M588.4 55.3L587.3 60.3M588.3 65.5L587.6 71.3M588.7 76.2L587.5 81.7M588.1 87L587.1 93.1M588.5 97.7L587.6 103.5M588.3 107.9L587 114.1M588.1 118.9L587.1 123.9M588.3 128.9L587.2 134.6M588.8 139.7L588 145.8M588.3 149.7L587.3 155.6M588.1 160.7L587.2 166.1M588.5 171.1L587.3 177.3M587.9 181.5L587.3 187M588.7 193L587.9 198M588.5 202.8L587.7 208.1M588 213.8L587.1 218.9M588.3 224.5L587.1 229.7M588.6 233.9L587.3 240.2M588.7 244.9L587.5 251.3M588.3 255.7L587.1 261.3M588.5 266.4L587.7 272.2M588.5 276.6L587.4 282.5M588.4 287L587.6 293.3M588.8 298.1L587.9 304M588.4 308.6L587.5 313.9M588.3 318.8L587.6 324.7M588.4 329L587.7 335.4M588.3 340.4L587.5 345.9M588.5 351L587.9 356.5M588.7 361.1L587.5 366.9M588.3 371.8L587.1 378.2M588.8 382.4L587.5 388.1M588.9 393L587.6 399.1M588.3 404L587.4 409.2M588.2 413.9L587.5 419.5M588.6 424.8L587.6 429.9M588.7 435.4L587.7 440.6M588.7 446.4L587.6 451.7M588.8 456.7L587.8 462.3M589 466.6L587.9 472.9M588.4 478.3L583.6 482.2M578.3 482.7L573 482.1M568 481.9L562.4 481.3M558 482.2L551.8 481.5M547.1 482.8L541.5 481.8M536.6 482.1L530.3 481.2M525.7 482.6L519.7 481.5M515.6 482.4L509.9 481.7M505.1 482.3L499.1 481.5M494.3 482.6L488 481.6M483.6 482.8L478.3 481.7M472.9 482.7L467.2 481.6M462.8 482.4L456.7 481.5M451.6 482.8L446 481.8M441.3 482.1L435 481.3M430.8 482.7L425.1 481.8M419.9 482.6L414.5 481.7M409.4 482.8L403.3 482.1M399.3 482.6L393.6 482M387.8 482.2L382.7 481.4M377.9 482.4L372.2 481.2M367.4 482.1L361.2 481.5M356.3 482.8L350.8 481.8M346.4 482.3L340.3 481.2M335.1 482.3L330 481.4M324.7 482L319.3 481.3M314.9 482.5L308.7 481.7M304.2 482.7L298.7 482M292.7 482.9L287.5 481.8M283 482.3L277.5 481.3M272.5 482.2L266.9 481.4M261.7 482.6L256.4 481.8M251.7 482.7L245.5 481.7M240.4 482L234.1 481.1M229.6 482.5L224.1 481.6M220.1 482.4L213.7 481.7M209.1 482.4L202.7 481.7M197.8 482.1L192.4 481.2M188.3 482.2L181.9 481.5M177.3 482.3L171.8 481.2M166.5 482.3L161 481.6M156.6 482.3L150.2 481.5M145 482.6L139.5 481.5M134.5 482.8L129.3 481.7M123.7 482.2L118.6 481.7M113.5 481.9L107.7 481.3M103.5 482.5L97.4 481.7M92.4 482.8L86.2 481.7M82.3 482.3L76.6 481.2M71 482.1L65.7 481.3M60.6 482.7L55.3 481.6M50 482.2L44.5 481.6M39.6 482.9L33.6 481.8M28.9 482.9L23.8 481.8M18 482.7L15 478.1M13.3 472.7L14.1 466.6M14 461.7L14.6 456.6M13.7 450.9L14.6 445.7M13.6 441.2L14.3 435.8M14.1 430.6L14.6 425.2M13.7 419.8L14.8 414.7M13.4 409.6L14.4 403.9M13.8 398.6L14.4 392.7M13.3 388.3L14 382.5M13.7 378L14.6 371.6M13.1 367.3L14.3 361.4M13 356.5L14.1 350.4M13.8 345.9L14.7 339.5M13.2 335.5L14.2 329.8M13.9 324.7L14.7 319.2M13.3 314.1L14.4 308.6M13.7 304.1L14.9 297.9M13.3 293.1L14 287.7M14 282.2L14.8 276.6M13.5 271.8L14.1 266.4M13.6 261.3L14.6 255.9M13.2 251.1L14.2 245.4M13.9 239.9L14.8 234.7M13.7 230.1L14.9 224.5M14 219.4L14.8 214.1M13.9 208.7L14.6 202.9M13.9 198.1L14.9 192.2M13.4 187L14.5 181.6M13.6 177L14.7 171.3M13.5 166.2L14.3 160.7M13.8 155.2L14.9 150.1M13.8 145.4L15.1 139.1M13.8 134.3L14.5 129.2M13.6 124.3L14.5 118M13.8 113.3L15 107.8M13.8 103.6L14.8 97.7M13.4 91.9L14.3 86.5M13.8 81.7L14.5 75.9M13.7 71L14.8 65.9M13.9 60.9L14.7 54.9M13.6 50.2L14.6 44.9M13.4 39.9L14.5 33.6M13.2 29.3L14.3 23.7M13.5 18.3L18.5 14.4'/%3E%3C/defs%3E%3Crect x='14' y='14' width='574' height='468' rx='7' fill='none' stroke='rgba(5,9,20,.5)' stroke-width='2.6'/%3E%3Cg fill='none' stroke-linecap='round'%3E%3Cuse href='%23s' xlink:href='%23s' transform='translate(0 .5)' stroke='rgba(84,64,26,.85)' stroke-width='2.5'/%3E%3Cuse href='%23s' xlink:href='%23s' transform='translate(0 0)' stroke='%23D2B266' stroke-width='1.7'/%3E%3Cuse href='%23s' xlink:href='%23s' transform='translate(-.2 -.45)' stroke='rgba(255,238,190,.55)' stroke-width='0.7'/%3E%3C/g%3E%3C/svg%3E\") 0 0 / 100% 100%"
          }
        ],
        "surface": "#151F38",
        "surfaceImage": "none",
        "plinthRadius": "10px",
        "plinthShadow": "0 2px 5px rgba(0,0,0,.45),0 40px 90px -30px rgba(0,0,0,.7),0 95px 165px -50px rgba(0,0,0,.8)",
        "plinthOutline": "rgba(58,74,108,.55)",
        "keylineInset": "13px",
        "keylineRadius": "4px",
        "keylineWidth": "0px",
        "keylineStyle": "solid",
        "keylineColor": "rgba(0,0,0,0)",
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
      "id": "round-8.1/v8",
      "name": "Bridle leather, the mark blocked in",
      "source": "richos-hq design/mockups/rounds/round-8.1/v8/index.html",
      "tokens": {
        "ground": "#0C1322",
        "atmosphere": "none",
        "vignette": "radial-gradient(120% 90% at 50% 38%, rgba(0,0,0,0) 46%, rgba(0,0,0,.42) 100%)",
        "grainOpacity": "0.07",
        "lamp": "rgba(255,232,190,.09)",
        "lampRadius": "1050px",
        "lampStop": "66%",
        "sheen": null,
        "materials": [
          {
            "background": "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='520' height='440'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.014 0.018' numOctaves='4' seed='57' stitchTiles='stitch'/%3E%3CfeColorMatrix type='saturate' values='0'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E\") 0 0 / 520px 440px",
            "blend": "soft-light",
            "opacity": ".4"
          },
          {
            "background": "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='720' height='600'%3E%3Cfilter id='n' x='0' y='0' width='100%25' height='100%25'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.045 0.055' numOctaves='3' seed='13' stitchTiles='stitch' result='t'/%3E%3CfeDiffuseLighting in='t' lighting-color='white' surfaceScale='2.6' diffuseConstant='1'%3E%3CfeDistantLight azimuth='235' elevation='58'/%3E%3C/feDiffuseLighting%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E\") 0 0 / 720px 600px",
            "blend": "soft-light",
            "opacity": ".5"
          },
          {
            "background": "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='180' height='180'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.45' numOctaves='2' seed='5' stitchTiles='stitch'/%3E%3CfeColorMatrix type='saturate' values='0'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E\") 0 0 / 180px 180px",
            "blend": "overlay",
            "opacity": ".16"
          },
          {
            "background": "linear-gradient(180deg,rgba(255,246,225,.05),transparent 32%)"
          },
          {
            "background": "none",
            "inset": "8px",
            "radius": "6px",
            "border": "1px solid rgba(0,0,0,.38)"
          },
          {
            "background": "none",
            "inset": "9px 8px 7px 8px",
            "radius": "6px",
            "border": "1px solid rgba(255,246,220,.045)"
          }
        ],
        "surface": "#111B33",
        "surfaceImage": "radial-gradient(120% 105% at 50% 40%,#182642 0%,#111B33 55%,#0C1428 100%)",
        "plinthRadius": "9px",
        "plinthShadow": "inset 0 1px 0 rgba(255,255,255,.05),inset 0 0 44px rgba(0,0,0,.38),0 2px 6px rgba(0,0,0,.5),0 40px 90px -30px rgba(0,0,0,.75),0 100px 170px -50px rgba(0,0,0,.85)",
        "plinthOutline": "rgba(70,88,126,.4)",
        "keylineInset": "13px",
        "keylineRadius": "4px",
        "keylineWidth": "1px",
        "keylineStyle": "solid",
        "keylineColor": "rgba(194,163,92,.30)",
        "keylineImage": "none",
        "keylineShadow": "none",
        "ink": "#DFE4EE",
        "signal": "#C2A35C",
        "gild": null,
        "markFilter": null,
        "signalFilter": null,
        "relief": {
          "target": "mark",
          "region": "-20% -20% 140% 140%",
          "noise": null,
          "matrix": null,
          "bands": [
            {
              "color": "#000008",
              "opacity": ".55",
              "dx": "0",
              "dy": "2.2",
              "blur": "1.4",
              "placement": "inner"
            },
            {
              "color": "#FFF3DA",
              "opacity": ".26",
              "dx": "0",
              "dy": "-1.6",
              "blur": "1.2",
              "placement": "inner"
            }
          ]
        },
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
      "id": "round-8.1/v9",
      "name": "Buckram bookcloth, stamped in gold foil",
      "source": "richos-hq design/mockups/rounds/round-8.1/v9/index.html",
      "tokens": {
        "ground": "#0C1322",
        "atmosphere": "none",
        "vignette": "radial-gradient(120% 90% at 50% 38%, rgba(0,0,0,0) 46%, rgba(0,0,0,.42) 100%)",
        "grainOpacity": "0.07",
        "lamp": "rgba(200,215,255,.12)",
        "lampRadius": "1050px",
        "lampStop": "66%",
        "sheen": null,
        "materials": [
          {
            "background": "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='300' height='90'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9 0.06' numOctaves='2' seed='9' stitchTiles='stitch'/%3E%3CfeColorMatrix type='saturate' values='0'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E\") 0 0 / 300px 90px",
            "blend": "soft-light",
            "opacity": ".4"
          },
          {
            "background": "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='90' height='300'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.06 0.9' numOctaves='2' seed='21' stitchTiles='stitch'/%3E%3CfeColorMatrix type='saturate' values='0'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E\") 0 0 / 90px 300px",
            "blend": "soft-light",
            "opacity": ".3"
          },
          {
            "background": "repeating-linear-gradient(0deg,rgba(255,255,255,.09) 0 1px,rgba(0,0,0,.12) 1px 2px,rgba(255,255,255,.02) 2px 3px,rgba(0,0,0,.05) 3px 4px), repeating-linear-gradient(90deg,rgba(255,255,255,.06) 0 1px,rgba(0,0,0,.10) 1px 2px,rgba(255,255,255,.02) 2px 3px,rgba(0,0,0,.06) 3px 4px)",
            "blend": "soft-light",
            "opacity": ".5"
          },
          {
            "background": "repeating-linear-gradient(0deg,rgba(255,255,255,.5) 0 1px,rgba(0,0,0,.55) 1px 2px), repeating-linear-gradient(90deg,rgba(255,255,255,.35) 0 1px,rgba(0,0,0,.4) 1px 2px)",
            "blend": "soft-light",
            "opacity": ".15",
            "z": "3"
          },
          {
            "background": "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='8' height='8'%3E%3Cpath d='M4 .46L7.54 4L4 7.54L.46 4Z' fill='rgba(194,163,92,.55)'/%3E%3C/svg%3E\") left 9px top 9px no-repeat, url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='8' height='8'%3E%3Cpath d='M4 .46L7.54 4L4 7.54L.46 4Z' fill='rgba(194,163,92,.55)'/%3E%3C/svg%3E\") right 9px top 9px no-repeat, url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='8' height='8'%3E%3Cpath d='M4 .46L7.54 4L4 7.54L.46 4Z' fill='rgba(194,163,92,.55)'/%3E%3C/svg%3E\") left 9px bottom 9px no-repeat, url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='8' height='8'%3E%3Cpath d='M4 .46L7.54 4L4 7.54L.46 4Z' fill='rgba(194,163,92,.55)'/%3E%3C/svg%3E\") right 9px bottom 9px no-repeat"
          }
        ],
        "surface": "#15203A",
        "surfaceImage": "none",
        "plinthRadius": "7px",
        "plinthShadow": "inset 0 1px 0 rgba(255,255,255,.045),0 2px 6px rgba(0,0,0,.5),0 36px 80px -28px rgba(0,0,0,.72),0 92px 155px -46px rgba(0,0,0,.82)",
        "plinthOutline": "rgba(76,96,135,.34)",
        "keylineInset": "13px",
        "keylineRadius": "4px",
        "keylineWidth": "1px",
        "keylineStyle": "solid",
        "keylineColor": "rgba(194,163,92,.34)",
        "keylineImage": "none",
        "keylineShadow": "none",
        "ink": "#DFE4EE",
        "signal": "#C2A35C",
        "gild": null,
        "markFilter": null,
        "signalFilter": null,
        "relief": {
          "target": "mark",
          "region": "-20% -20% 140% 140%",
          "noise": null,
          "matrix": null,
          "bands": [
            {
              "color": "#000008",
              "opacity": ".4",
              "dx": "0",
              "dy": "1.4",
              "blur": "1",
              "placement": "inner"
            }
          ]
        },
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
      "id": "round-8.1/v10",
      "name": "Urushi lacquer, dusted with maki-e gold",
      "source": "richos-hq design/mockups/rounds/round-8.1/v10/index.html",
      "tokens": {
        "ground": "#0C1322",
        "atmosphere": "none",
        "vignette": "radial-gradient(120% 90% at 50% 38%, rgba(0,0,0,0) 46%, rgba(0,0,0,.42) 100%)",
        "grainOpacity": "0.07",
        "lamp": "rgba(190,210,255,.10)",
        "lampRadius": "900px",
        "lampStop": "66%",
        "sheen": null,
        "materials": [
          {
            "background": "radial-gradient(140% 120% at 50% 0%,rgba(255,255,255,.035),transparent 42%)"
          },
          {
            "background": "linear-gradient(103deg,transparent 26%,rgba(170,190,235,.05) 40%,rgba(190,208,245,.10) 46%,rgba(170,190,235,.04) 53%,transparent 66%)",
            "blend": "screen"
          },
          {
            "background": "radial-gradient(90px circle at 29% 34%, rgba(215,228,255,.16), rgba(0,0,0,0) 60%),radial-gradient(430px circle at 29% 34%, rgba(150,180,240,.07), rgba(0,0,0,0) 70%)",
            "blend": "screen"
          }
        ],
        "surface": "#0A1226",
        "surfaceImage": "linear-gradient(165deg,#0F1934 0%,#0A1226 50%,#0D1730 100%)",
        "plinthRadius": "6px",
        "plinthShadow": "inset 0 0 0 1px rgba(150,170,210,.10),0 1px 2px rgba(0,0,0,.6),0 30px 70px -25px rgba(0,0,0,.8),0 90px 150px -45px rgba(0,0,0,.85)",
        "plinthOutline": "rgba(0,0,0,0)",
        "keylineInset": "13px",
        "keylineRadius": "4px",
        "keylineWidth": "1px",
        "keylineStyle": "solid",
        "keylineColor": "rgba(194,163,92,.34)",
        "keylineImage": "none",
        "keylineShadow": "none",
        "ink": "#DFE4EE",
        "signal": "#C2A35C",
        "gild": null,
        "markFilter": null,
        "signalFilter": null,
        "relief": {
          "target": "signal",
          "region": "-5% -5% 110% 110%",
          "noise": {
            "type": "fractalNoise",
            "baseFrequency": "0.9",
            "octaves": "2",
            "seed": "11"
          },
          "matrix": "0 0 0 0 1  0 0 0 0 0.92  0 0 0 0 0.62  1.5 1.5 0 0 -1.35",
          "bands": []
        },
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
      "id": "round-8.1/v11",
      "name": "Honed slate, the mark cut in and gilded",
      "source": "richos-hq design/mockups/rounds/round-8.1/v11/index.html",
      "tokens": {
        "ground": "#0C1322",
        "atmosphere": "none",
        "vignette": "radial-gradient(120% 90% at 50% 38%, rgba(0,0,0,0) 46%, rgba(0,0,0,.42) 100%)",
        "grainOpacity": "0.07",
        "lamp": "rgba(200,215,255,.12)",
        "lampRadius": "1050px",
        "lampStop": "66%",
        "sheen": null,
        "materials": [
          {
            "background": "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='900' height='600'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.004 0.02' numOctaves='4' seed='17' stitchTiles='stitch'/%3E%3CfeColorMatrix type='saturate' values='0'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E\") 0 0 / 900px 600px",
            "blend": "soft-light",
            "opacity": ".62"
          },
          {
            "background": "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='340' height='300'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.09 0.13' numOctaves='3' seed='23' stitchTiles='stitch'/%3E%3CfeColorMatrix type='saturate' values='0'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E\") 0 0 / 340px 300px",
            "blend": "overlay",
            "opacity": ".28"
          },
          {
            "background": "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='160' height='160'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.8' numOctaves='1' seed='29' stitchTiles='stitch'/%3E%3CfeColorMatrix type='saturate' values='0'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E\") 0 0 / 160px 160px",
            "blend": "screen",
            "opacity": ".3",
            "filter": "contrast(3) brightness(.6)"
          },
          {
            "background": "none",
            "inset": "14px 13px 12px 13px",
            "radius": "3px",
            "border": "1px solid rgba(223,228,238,.05)"
          }
        ],
        "surface": "#131C31",
        "surfaceImage": "none",
        "plinthRadius": "4px",
        "plinthShadow": "inset 0 1px 0 rgba(255,255,255,.05),0 3px 7px rgba(0,0,0,.55),0 44px 90px -28px rgba(0,0,0,.8),0 110px 180px -50px rgba(0,0,0,.88)",
        "plinthOutline": "rgba(90,106,140,.3)",
        "keylineInset": "13px",
        "keylineRadius": "4px",
        "keylineWidth": "1px",
        "keylineStyle": "solid",
        "keylineColor": "rgba(0,0,0,.5)",
        "keylineImage": "none",
        "keylineShadow": "none",
        "ink": "#DFE4EE",
        "signal": "#C2A35C",
        "gild": null,
        "markFilter": null,
        "signalFilter": null,
        "relief": {
          "target": "mark",
          "region": "-20% -20% 140% 140%",
          "noise": null,
          "matrix": null,
          "bands": [
            {
              "color": "#000006",
              "opacity": ".72",
              "dx": "0",
              "dy": "3.2",
              "blur": "2",
              "placement": "inner"
            },
            {
              "color": "#EDF2FF",
              "opacity": ".3",
              "dx": "0",
              "dy": "-1.8",
              "blur": "1.3",
              "placement": "inner"
            }
          ]
        },
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
      "id": "round-8.1/v12",
      "name": "Crushed velvet, couched in bullion thread",
      "source": "richos-hq design/mockups/rounds/round-8.1/v12/index.html",
      "tokens": {
        "ground": "#0C1322",
        "atmosphere": "none",
        "vignette": "radial-gradient(120% 90% at 50% 38%, rgba(0,0,0,0) 46%, rgba(0,0,0,.42) 100%)",
        "grainOpacity": "0.07",
        "lamp": "rgba(200,215,255,.12)",
        "lampRadius": "1050px",
        "lampStop": "66%",
        "sheen": null,
        "materials": [
          {
            "background": "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='700' height='560'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.012 0.016' numOctaves='4' seed='31' stitchTiles='stitch'/%3E%3CfeColorMatrix type='saturate' values='0'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E\") 0 0 / 700px 560px",
            "blend": "soft-light",
            "opacity": ".55"
          },
          {
            "background": "radial-gradient(420px 300px at 22% 30%,rgba(120,150,220,.16),transparent 70%), radial-gradient(500px 360px at 74% 62%,rgba(100,130,200,.13),transparent 70%), radial-gradient(340px 240px at 46% 84%,rgba(130,155,225,.11),transparent 70%)",
            "blend": "screen"
          },
          {
            "background": "repeating-linear-gradient(90deg,rgba(255,255,255,.025) 0 1px,transparent 1px 2px)",
            "opacity": ".3"
          }
        ],
        "surface": "#101A32",
        "surfaceImage": "none",
        "plinthRadius": "10px",
        "plinthShadow": "0 2px 6px rgba(0,0,0,.5),0 40px 90px -30px rgba(0,0,0,.75),0 100px 170px -50px rgba(0,0,0,.85)",
        "plinthOutline": "rgba(64,80,116,.5)",
        "keylineInset": "13px",
        "keylineRadius": "5px",
        "keylineWidth": "2px",
        "keylineStyle": "solid",
        "keylineColor": "rgba(0,0,0,0)",
        "keylineImage": "repeating-linear-gradient(45deg,#D9BC72 0 2.5px,#7a5f28 2.5px 5px) 2",
        "keylineShadow": "none",
        "ink": "#DFE4EE",
        "signal": "#C2A35C",
        "gild": null,
        "markFilter": null,
        "signalFilter": null,
        "relief": {
          "target": "mark",
          "region": "-20% -20% 140% 140%",
          "noise": {
            "type": "turbulence",
            "baseFrequency": "0.012 0.55",
            "octaves": "1",
            "seed": "5"
          },
          "matrix": "0 0 0 0 1  0 0 0 0 .95  0 0 0 0 .7  .9 .9 0 0 -.6",
          "bands": [
            {
              "color": "#000",
              "opacity": ".5",
              "dx": "0",
              "dy": "1.8",
              "blur": "1.3",
              "placement": "outer"
            }
          ]
        },
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
      "id": "round-8.1/v13",
      "name": "Blued steel, the mark inlaid in gold",
      "source": "richos-hq design/mockups/rounds/round-8.1/v13/index.html",
      "tokens": {
        "ground": "#0C1322",
        "atmosphere": "none",
        "vignette": "radial-gradient(120% 90% at 50% 38%, rgba(0,0,0,0) 46%, rgba(0,0,0,.42) 100%)",
        "grainOpacity": "0.07",
        "lamp": "rgba(205,222,255,.09)",
        "lampRadius": "1000px",
        "lampStop": "66%",
        "sheen": null,
        "materials": [
          {
            "background": "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='1200' height='160'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.002 0.5' numOctaves='2' seed='37' stitchTiles='stitch'/%3E%3CfeColorMatrix type='saturate' values='0'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E\") 0 0 / 1200px 160px",
            "blend": "overlay",
            "opacity": ".5"
          },
          {
            "background": "repeating-linear-gradient(180deg,rgba(255,255,255,.05) 0 1px,transparent 1px 3px)",
            "opacity": ".22"
          },
          {
            "background": "radial-gradient(820px 64px at 29% 34%, rgba(205,222,255,.11), rgba(0,0,0,0) 70%)",
            "blend": "screen"
          },
          {
            "background": "none",
            "inset": "17px",
            "radius": "2px",
            "border": "1px solid rgba(194,163,92,.18)"
          }
        ],
        "surface": "#101A31",
        "surfaceImage": "linear-gradient(180deg,#16213A 0%,#101A31 55%,#141F38 100%)",
        "plinthRadius": "5px",
        "plinthShadow": "inset 0 1px 0 rgba(255,255,255,.07),0 1px 3px rgba(0,0,0,.6),0 34px 76px -28px rgba(0,0,0,.78),0 90px 150px -46px rgba(0,0,0,.85)",
        "plinthOutline": "rgba(120,140,180,.22)",
        "keylineInset": "13px",
        "keylineRadius": "4px",
        "keylineWidth": "1px",
        "keylineStyle": "solid",
        "keylineColor": "rgba(194,163,92,.45)",
        "keylineImage": "none",
        "keylineShadow": "none",
        "ink": "#DFE4EE",
        "signal": "#C2A35C",
        "gild": null,
        "markFilter": null,
        "signalFilter": "drop-shadow(0 0 0.7px rgba(0,0,0,.85))",
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
      "id": "round-8.1/v14",
      "name": "Letterpress cotton, pressed deep",
      "source": "richos-hq design/mockups/rounds/round-8.1/v14/index.html",
      "tokens": {
        "ground": "#0C1322",
        "atmosphere": "none",
        "vignette": "radial-gradient(120% 90% at 50% 38%, rgba(0,0,0,0) 46%, rgba(0,0,0,.42) 100%)",
        "grainOpacity": "0.07",
        "lamp": "rgba(255,238,205,.10)",
        "lampRadius": "1050px",
        "lampStop": "66%",
        "sheen": null,
        "materials": [
          {
            "background": "none",
            "inset": "9.5px",
            "radius": "8.5px",
            "border": "7px solid #141D33",
            "relief": true
          },
          {
            "background": "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='520' height='460'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.05 0.06' numOctaves='3' seed='47' stitchTiles='stitch'/%3E%3CfeColorMatrix type='saturate' values='0'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E\") 0 0 / 520px 460px",
            "blend": "soft-light",
            "opacity": ".24"
          },
          {
            "background": "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='260' height='260'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.3' numOctaves='3' seed='43' stitchTiles='stitch'/%3E%3CfeColorMatrix type='saturate' values='0'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E\") 0 0 / 260px 260px",
            "blend": "soft-light",
            "opacity": ".32"
          }
        ],
        "surface": "#141D33",
        "surfaceImage": "none",
        "plinthRadius": "7px",
        "plinthShadow": "inset 0 1px 0 rgba(255,255,255,.04),0 2px 6px rgba(0,0,0,.5),0 36px 82px -28px rgba(0,0,0,.72),0 92px 155px -46px rgba(0,0,0,.82)",
        "plinthOutline": "rgba(76,96,135,.3)",
        "keylineInset": "13px",
        "keylineRadius": "4px",
        "keylineWidth": "0px",
        "keylineStyle": "solid",
        "keylineColor": "rgba(0,0,0,0)",
        "keylineImage": "none",
        "keylineShadow": "none",
        "ink": "#DFE4EE",
        "signal": "#C2A35C",
        "gild": null,
        "markFilter": null,
        "signalFilter": null,
        "relief": {
          "target": "mark",
          "region": "-20% -20% 140% 140%",
          "noise": null,
          "matrix": null,
          "bands": [
            {
              "color": "#000006",
              "opacity": ".7",
              "dx": "1.6",
              "dy": "2",
              "blur": "1.4",
              "placement": "inner"
            },
            {
              "color": "#FFF6E4",
              "opacity": ".42",
              "dx": "-1.6",
              "dy": "-2",
              "blur": "1.2",
              "placement": "inner"
            }
          ]
        },
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
      "id": "round-8.1/v15",
      "name": "Watered silk, woven with gold",
      "source": "richos-hq design/mockups/rounds/round-8.1/v15/index.html",
      "tokens": {
        "ground": "#0C1322",
        "atmosphere": "none",
        "vignette": "radial-gradient(120% 90% at 50% 38%, rgba(0,0,0,0) 46%, rgba(0,0,0,.42) 100%)",
        "grainOpacity": "0.07",
        "lamp": "rgba(200,215,255,.12)",
        "lampRadius": "1050px",
        "lampStop": "66%",
        "sheen": null,
        "materials": [
          {
            "background": "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='700' height='700'%3E%3Cdefs%3E%3Cpattern id='s' width='9' height='9' patternUnits='userSpaceOnUse'%3E%3Crect width='9' height='4.5' fill='%23B9CDF6' fill-opacity='.5'/%3E%3C/pattern%3E%3Cfilter id='m' x='-20%25' y='-20%25' width='140%25' height='140%25'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.006 0.035' numOctaves='3' seed='9' result='n'/%3E%3CfeDisplacementMap in='SourceGraphic' in2='n' scale='110' xChannelSelector='R' yChannelSelector='G'/%3E%3C/filter%3E%3C/defs%3E%3Crect x='-60' y='-60' width='820' height='820' fill='url(%23s)' filter='url(%23m)'/%3E%3C/svg%3E\") 0 0 / 700px 700px",
            "blend": "screen",
            "opacity": ".085"
          },
          {
            "background": "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='620' height='620'%3E%3Cdefs%3E%3Cpattern id='s' width='8' height='8' patternUnits='userSpaceOnUse'%3E%3Crect width='8' height='4' fill='%23AFC4F0' fill-opacity='.45'/%3E%3C/pattern%3E%3Cfilter id='m' x='-20%25' y='-20%25' width='140%25' height='140%25'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.007 0.03' numOctaves='3' seed='27' result='n'/%3E%3CfeDisplacementMap in='SourceGraphic' in2='n' scale='95' xChannelSelector='R' yChannelSelector='G'/%3E%3C/filter%3E%3C/defs%3E%3Crect x='-60' y='-60' width='740' height='740' fill='url(%23s)' filter='url(%23m)'/%3E%3C/svg%3E\") 0 0 / 620px 620px",
            "blend": "screen",
            "opacity": ".06"
          },
          {
            "background": "linear-gradient(100deg,transparent 18%,rgba(150,175,235,.06) 40%,rgba(175,196,240,.10) 50%,rgba(150,175,235,.05) 62%,transparent 82%)",
            "blend": "screen"
          },
          {
            "background": "radial-gradient(560px 300px at 29% 34%, rgba(185,205,250,.10), rgba(0,0,0,0) 70%)",
            "blend": "screen"
          },
          {
            "background": "none",
            "inset": "16px",
            "radius": "3px",
            "border": "1px solid rgba(76,96,135,.3)"
          }
        ],
        "surface": "#111B33",
        "surfaceImage": "linear-gradient(168deg,#15203A 0%,#111B33 55%,#141F38 100%)",
        "plinthRadius": "8px",
        "plinthShadow": "inset 0 1px 0 rgba(255,255,255,.05),0 2px 6px rgba(0,0,0,.5),0 38px 84px -28px rgba(0,0,0,.72),0 94px 158px -46px rgba(0,0,0,.82)",
        "plinthOutline": "rgba(76,96,135,.34)",
        "keylineInset": "13px",
        "keylineRadius": "4px",
        "keylineWidth": "1px",
        "keylineStyle": "solid",
        "keylineColor": "rgba(194,163,92,.4)",
        "keylineImage": "none",
        "keylineShadow": "none",
        "ink": "#DFE4EE",
        "signal": "#C2A35C",
        "gild": null,
        "markFilter": null,
        "signalFilter": null,
        "relief": {
          "target": "signal",
          "region": "-10% -10% 120% 120%",
          "noise": {
            "type": "turbulence",
            "baseFrequency": "0.01 0.4",
            "octaves": "1",
            "seed": "15"
          },
          "matrix": "0 0 0 0 1  0 0 0 0 .95  0 0 0 0 .72  .55 .55 0 0 -.4",
          "bands": []
        },
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
      "id": "round-8.1/v16",
      "name": "Guilloch\u00e9 under midnight enamel",
      "source": "richos-hq design/mockups/rounds/round-8.1/v16/index.html",
      "tokens": {
        "ground": "#0C1322",
        "atmosphere": "none",
        "vignette": "radial-gradient(120% 90% at 50% 38%, rgba(0,0,0,0) 46%, rgba(0,0,0,.42) 100%)",
        "grainOpacity": "0.07",
        "lamp": "rgba(190,210,255,.10)",
        "lampRadius": "950px",
        "lampStop": "66%",
        "sheen": null,
        "materials": [
          {
            "background": "repeating-radial-gradient(circle at 32% 40%,rgba(190,205,240,.04) 0 1px,transparent 1px 6px), repeating-radial-gradient(circle at 68% 60%,rgba(190,205,240,.04) 0 1px,transparent 1px 6px)",
            "opacity": ".9"
          },
          {
            "background": "linear-gradient(160deg,rgba(24,36,66,.36),rgba(8,14,30,.5))"
          },
          {
            "background": "repeating-radial-gradient(circle at 32% 40%,rgba(220,232,255,.16) 0 1px,transparent 1px 6px), repeating-radial-gradient(circle at 68% 60%,rgba(220,232,255,.16) 0 1px,transparent 1px 6px)",
            "mask": "radial-gradient(340px circle at 29% 34%, rgba(0,0,0,1) 0%, rgba(0,0,0,0) 70%)"
          },
          {
            "background": "linear-gradient(103deg,transparent 30%,rgba(170,190,235,.05) 43%,rgba(190,208,245,.08) 47%,transparent 60%)",
            "blend": "screen"
          }
        ],
        "surface": "#0C1428",
        "surfaceImage": "linear-gradient(160deg,#101B36 0%,#0C1428 55%,#0E1730 100%)",
        "plinthRadius": "6px",
        "plinthShadow": "inset 0 0 0 1px rgba(150,170,210,.08),inset 0 0 34px rgba(0,0,0,.4),0 1px 3px rgba(0,0,0,.6),0 32px 72px -26px rgba(0,0,0,.8),0 90px 150px -45px rgba(0,0,0,.85)",
        "plinthOutline": "rgba(0,0,0,0)",
        "keylineInset": "13px",
        "keylineRadius": "3px",
        "keylineWidth": "2px",
        "keylineStyle": "solid",
        "keylineColor": "rgba(0,0,0,0)",
        "keylineImage": "linear-gradient(180deg,#E2C87E,#8a6f35) 1",
        "keylineShadow": "none",
        "ink": "#DFE4EE",
        "signal": "#C2A35C",
        "gild": null,
        "markFilter": null,
        "signalFilter": "drop-shadow(0 1px 1px rgba(0,0,0,.55))",
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
      "id": "round-8.1/v17",
      "name": "Oil and gold leaf, under a picture light",
      "source": "richos-hq design/mockups/rounds/round-8.1/v17/index.html",
      "tokens": {
        "ground": "#070C17",
        "atmosphere": "none",
        "vignette": "radial-gradient(120% 90% at 50% 34%,rgba(0,0,0,0) 34%,rgba(0,0,0,.6) 100%)",
        "grainOpacity": "0.07",
        "lamp": "rgba(255,228,168,.06)",
        "lampRadius": "900px",
        "lampStop": "66%",
        "sheen": null,
        "materials": [
          {
            "background": "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='160' height='160'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.55' numOctaves='2' seed='53' stitchTiles='stitch'/%3E%3CfeColorMatrix type='saturate' values='0'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E\") 0 0 / 160px 160px, repeating-linear-gradient(0deg,rgba(255,255,255,.016) 0 1px,transparent 1px 3px) 0 0 / auto, linear-gradient(180deg,#131E37,#0E1730) 0 0 / cover",
            "imageBlend": "soft-light,normal,normal",
            "inset": "11px",
            "radius": "1px"
          },
          {
            "background": "radial-gradient(135% 100% at 50% -8%,rgba(255,224,158,.46),rgba(255,220,152,.14) 44%,transparent 72%)",
            "blend": "screen",
            "inset": "11px",
            "radius": "1px"
          },
          {
            "background": "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='160' height='160'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.55' numOctaves='2' seed='53' stitchTiles='stitch'/%3E%3CfeColorMatrix type='saturate' values='0'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E\") 0 0 / 160px 160px",
            "blend": "soft-light",
            "opacity": ".1",
            "inset": "11px",
            "radius": "1px",
            "z": "3"
          },
          {
            "background": "radial-gradient(50% 100% at 50% 0%,rgba(255,228,168,.28),transparent 78%)",
            "inset": "-8px 34.88% auto 34.88%",
            "height": "26px",
            "radius": "50%"
          },
          {
            "background": "linear-gradient(180deg,#5c4a20,#8a6f35)",
            "inset": "-25px calc(50% - 13px) auto calc(50% - 13px)",
            "height": "8px",
            "radius": "3px 3px 0 0"
          },
          {
            "background": "linear-gradient(180deg,#EAD394,#8a6f35)",
            "inset": "-17px 32% auto 32%",
            "height": "8px",
            "radius": "4px",
            "shadow": "0 2px 6px rgba(0,0,0,.55)"
          }
        ],
        "surface": "#A2854A",
        "surfaceImage": "linear-gradient(178deg,#D9BC72 0%,#A2854A 22%,#C8AA5F 50%,#6E5626 100%)",
        "plinthRadius": "3px",
        "plinthShadow": "inset 0 0 0 1px rgba(60,45,10,.6),inset 0 0 0 3px rgba(255,240,200,.22),inset 0 0 0 4px rgba(0,0,0,.25), 0 3px 8px rgba(0,0,0,.55),0 46px 95px -30px rgba(0,0,0,.85),0 110px 180px -50px rgba(0,0,0,.9)",
        "plinthOutline": "rgba(0,0,0,0)",
        "keylineInset": "11px",
        "keylineRadius": "1px",
        "keylineWidth": "0px",
        "keylineStyle": "solid",
        "keylineColor": "rgba(0,0,0,0)",
        "keylineImage": "none",
        "keylineShadow": "inset 0 5px 10px -3px rgba(0,0,0,.62),inset 0 -3px 8px -4px rgba(0,0,0,.42),inset 4px 0 8px -4px rgba(0,0,0,.4),inset -4px 0 8px -4px rgba(0,0,0,.4)",
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
    }
  ]
};
