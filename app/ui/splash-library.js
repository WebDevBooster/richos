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
        "surface": "#141E34",
        "plinthRadius": "8px",
        "plinthShadow": "0 60px 120px -40px rgba(0,0,0,.75), 0 20px 50px -30px rgba(0,0,0,.6)",
        "plinthOutline": "rgba(76,96,135,0.28)",
        "keylineInset": "12px",
        "keylineRadius": "4px",
        "keylineColor": "rgba(76,96,135,0.16)",
        "ink": "#DFE4EE",
        "signal": "#C2A35C",
        "gild": null,
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
        "surface": "#141E34",
        "plinthRadius": "8px",
        "plinthShadow": "0 60px 120px -40px rgba(0,0,0,.75), 0 20px 50px -30px rgba(0,0,0,.6)",
        "plinthOutline": "rgba(76,96,135,0.28)",
        "keylineInset": "12px",
        "keylineRadius": "4px",
        "keylineColor": "rgba(76,96,135,0.16)",
        "ink": "#DFE4EE",
        "signal": "#C2A35C",
        "gild": null,
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
        "surface": "#141E34",
        "plinthRadius": "8px",
        "plinthShadow": "0 60px 120px -40px rgba(0,0,0,.75), 0 20px 50px -30px rgba(0,0,0,.6)",
        "plinthOutline": "rgba(76,96,135,0.28)",
        "keylineInset": "12px",
        "keylineRadius": "4px",
        "keylineColor": "rgba(76,96,135,0.16)",
        "ink": "#DFE4EE",
        "signal": "#C2A35C",
        "gild": [
          "#DFC178",
          "#C2A35C",
          "#96793C"
        ],
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
        "surface": "#15203A",
        "plinthRadius": "6px",
        "plinthShadow": "inset 0 1px 0 rgba(255,255,255,0.06), inset 0 -20px 40px rgba(0,0,0,0.16), 0 2px 6px rgba(0,0,0,0.5), 0 34px 68px -26px rgba(0,0,0,0.72), 0 96px 160px -48px rgba(0,0,0,0.85)",
        "plinthOutline": "rgba(90,110,150,0.36)",
        "keylineInset": "13px",
        "keylineRadius": "3px",
        "keylineColor": "rgba(194,163,92,0.22)",
        "ink": "#DFE4EE",
        "signal": "#C2A35C",
        "gild": null,
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
        "surface": "#141E34",
        "plinthRadius": "8px",
        "plinthShadow": "0 60px 120px -40px rgba(0,0,0,.75), 0 20px 50px -30px rgba(0,0,0,.6)",
        "plinthOutline": "rgba(76,96,135,0.28)",
        "keylineInset": "12px",
        "keylineRadius": "4px",
        "keylineColor": "rgba(76,96,135,0.16)",
        "ink": "#DFE4EE",
        "signal": "#C2A35C",
        "gild": null,
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
        "surface": "#141E34",
        "plinthRadius": "8px",
        "plinthShadow": "0 60px 120px -40px rgba(0,0,0,.75), 0 20px 50px -30px rgba(0,0,0,.6)",
        "plinthOutline": "rgba(76,96,135,0.28)",
        "keylineInset": "12px",
        "keylineRadius": "4px",
        "keylineColor": "rgba(76,96,135,0.16)",
        "ink": "#DFE4EE",
        "signal": "#C2A35C",
        "gild": null,
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
        "surface": "#15203A",
        "plinthRadius": "6px",
        "plinthShadow": "inset 0 1px 0 rgba(255,255,255,0.06), inset 0 -20px 40px rgba(0,0,0,0.16), 0 2px 6px rgba(0,0,0,0.5), 0 34px 68px -26px rgba(0,0,0,0.72), 0 96px 160px -48px rgba(0,0,0,0.85)",
        "plinthOutline": "rgba(90,110,150,0.36)",
        "keylineInset": "13px",
        "keylineRadius": "3px",
        "keylineColor": "rgba(194,163,92,0.22)",
        "ink": "#DFE4EE",
        "signal": "#C2A35C",
        "gild": [
          "#DFC178",
          "#C2A35C",
          "#96793C"
        ],
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
