// THE SPLASH SCREENS — DATA, NOT CODE.
//
// Adding a splash screen is adding an ENTRY. It is never editing `splash.js`, and the two
// things that make that true are checked rather than asserted: `tests/splash.js` check 1
// strips the assignment below and hands the remainder to `JSON.parse`, so this file cannot
// grow a function without failing; check 2 greps `splash.js` for a color literal, so the
// renderer cannot grow a variation-specific value without failing.
//
// ================================================================================
// THERE ARE EXACTLY TWO, AND THAT IS THE WHOLE APPROVED SET
// ================================================================================
//
// CEO, 2026-09-01, verbatim: *"I have never fucking approved more than 2 splash screens.
// The other MOCKUP DESIGNS ARE NOT FUCKING READY FOR USE IN SPLASH SCREENS YET."*
//
// So this file holds his two and nothing else:
//
//   round-11/v1   SPLASH SCREEN #1 — the ruled dark standard, with the loading bar drawn as
//                 the `.rule` at the width of the plinth, striking along its own unstruck
//                 22% ghost. Composition from round-8.1/v0, which is round-7/v9
//                 byte-identical, which is the Sovereign palette he chose.
//   round-11/v2   SPLASH SCREEN #2 — midnight suede, saddle-stitched, with the loading bar
//                 drawn as a leather strap of the same hide: the whole run of needle holes
//                 punched from the first frame, sewn live in gold thread at the plinth
//                 border's 10.5px pitch. Composition from round-8.1/v7.
//
// WHAT WAS REMOVED, AND WHY IT WAS NOT A DEMOTION. Until this commit this file shipped
// EIGHTEEN entries lifted from round 8.1. Round 8.1 was approved as a PALETTE and visual
// standard (`richos-hq/wiki/ceo-decisions.md` §14 — `the actual colour palette for dark
// mode in general as well as the overall design of the page elements`), and that approval
// was read here as an approval of eighteen splash screens. It was not one. The two entries
// above are the only compositions the CEO has ever approved AS splash screens, and they
// were commissioned as splash screens, with a loading bar, in round 11. The other sixteen
// remain exactly where they were approved: as studies in richos-hq, unchanged.
//
// IT IS STILL AN ARRAY, AND IT GROWS. His words: *"eventually, there will be many splash
// screens added to the array where the splash screen will be randomly picked for the user
// (and sometimes semi-randomly or deterministically picked for a user based on certain
// criteria)"*. Nothing here or in `splash.js` knows the number two: the selection rule in
// `splash.js` reads the array's length, and a third screen is a third object here.
//
// WHICH ONE IS SHOWN IS NOT DECIDED HERE. `splash.js`'s `choose()` holds the CEO's v1 rule
// (first start #1, second start #2, third and after #1) and names where the later criteria
// attach. This file is the set; that function is the policy.
//
// The mark's geometry is deliberately NOT here: it is verbatim in every version of every
// round, so it lives in the renderer where it cannot drift between entries.
//
// ================================================================================
// THE TOKEN SET
// ================================================================================
//
// Every entry carries every key the schema names — `splash.js` refuses an entry that is
// missing one rather than drawing it half-dressed. Beyond the ground/plinth/mark/rule
// tokens the compositions have always had:
//
//   surfaceImage    the mat's own paint when it is a gradient rather than one flat value
//   keylineWidth    the inner keyline's width, style, border-image and box-shadow
//   keylineStyle
//   keylineImage
//   keylineShadow
//   materials       THE MATERIAL ITSELF: an ordered stack of flat layers over the mat, each
//                   one a background, a blend mode, an opacity, an inset, a radius, a
//                   border, a mask. #2's suede nap and its saddle stitching live here.
//   markFilter      a CSS filter on the mark
//   signalFilter    the same, on the gold alone
//   relief          an SVG filter on the mark described as VALUES. Neither of the two
//                   approved screens uses one; the mechanism stays, and `tests/splash.js`
//                   check 16 drives it against a FIXTURE rather than against a shipped
//                   screen, so it is proved without an unapproved composition being kept
//                   alive to prove it.
//   seconds         how long THIS screen is on the glass, in seconds. Absent means the
//                   CEO's default of 3. Present is clamped to 5 — "3 seconds default, up
//                   to 5 for some". Neither of these two sets it, so both run at 3.
//   bar             THE LOADING BAR, added in round 11, described below.
//
// ================================================================================
// THE LOADING BAR IS A RENDERER CAPABILITY DRIVEN BY THESE TOKENS
// ================================================================================
//
// The CEO's definition: *"A splash screen is something that has a 'loading' progress bar
// under the `plinth` element."* His two bars are deliberately different objects — a struck
// rule and a sewn strap — so the renderer had to be given a mechanism general enough to
// draw both without knowing what either one is. It is this:
//
//   A TRACK, at the width of the plinth, carrying an ordered stack of paint LAYERS. Some of
//   those layers have a width that follows the progress. That is the whole mechanism.
//
// The track's own keys:
//
//   gap            its distance below the plinth
//   height         2px for a rule, 19px for a strap
//   radius, background, outline, shadow, clip     the track's own paint
//   enterDelay     when the empty track fades in, and over how long
//   enterDuration
//   pitch          OPTIONAL. When a bar has a repeating rhythm — #2's needle holes at the
//   pitchInset     plinth border's 10.5px — the renderer snaps the run to a whole number of
//                  pitches inside `pitchInset`, so the last hole is never cut in half by
//                  the strap's edge. Null on #1, which has no rhythm.
//   layers         the stack. Each layer takes the same vocabulary a `materials` layer
//                  takes, plus one `role`:
//
//     (absent)     a static layer across the whole track. #2's stitch channel.
//     "rhythm"     a static layer across the snapped run. #2's punched needle holes — the
//                  whole run of them, from the first frame, because the empty ones ARE the
//                  distance left to sew.
//     "progress"   its width IS the progress. #1's gold fill and the pool of light it
//                  casts; #2's gold thread, whose tile is anchored to the left so a stitch
//                  already sewn never moves.
//     "lead"       rides the leading edge and goes out when the bar lands. #1's strike
//                  heat; #2's needle warmth.
//     "flare"      invisible until the bar lands, then one sweep along its length.
//
// EVERY ONE OF THOSE IS STILL DATA. Check 1 still JSON-parses this file, so it still cannot
// hold a function; check 2 still greps the renderer for a color, so the renderer still
// cannot hold a value.
//
// ================================================================================
// WHAT CHANGED FROM THE APPROVED MOCKUPS, AND WHY — every item, named
// ================================================================================
//
//   THE TAGLINE'S PAINT. The round-8.1 sources set it in the ruled trim at 95% —
//   `rgba(76,96,135,0.95)` — which measures 2.65:1 on the mat. At 12px that was already
//   below §15's 16px floor for text meant to be read; at the CEO's instructed 18px it is a
//   plain AA failure. Both entries carry `#8FA3C6`: the same hue, lifted until it clears.
//   Measured on the COMPOSITED frame (the lamp, the vignette and the grain all sit above
//   the plinth, so the CSS value is not what the eye gets): 6.50:1 on #1, 6.32:1 on #2.
//
//   THE STRAP'S EDGE, on #2 only. `rgba(58,74,108,.6)` measured 2.52:1 against the ground,
//   and the strap's edge is what marks the bar's full extent — a non-text indicator with a
//   3:1 floor. `#56698E` measures 4.89:1.
//
//   THE NEEDLE HOLES AND THE THREAD ARE SVG, NOT CANVAS. The mockup draws #2's strap on a
//   `<canvas>`, per-hole, with a deterministic generator. Two reasons that could not ship
//   as-is: `tests/contrast.js` check 14 asserts ZERO `<canvas>` elements on any walked
//   surface, so that a green contrast run cannot be read as covering pixels no DOM checker
//   can see; and a canvas is code, and the renderer is not allowed a variation's values.
//   Both are instead a 126px x 19px SVG tile of twelve stitches, generated from the
//   mockup's OWN `mk(41)` generator with its own jitter, geometry and three-stroke thread,
//   so the hand of the stitching is the mockup's. The visible consequence, stated rather
//   than hidden: the jitter repeats every twelve stitches instead of never, and a stitch is
//   revealed by the fill's edge crossing it rather than being seated over its own ~28ms. At
//   10.5px and three seconds neither is distinguishable, and the plinth's own saddle
//   stitching has been a baked SVG since v7 landed for exactly the same reason.
//
// WHAT IS DELIBERATELY NOT HERE, and why, is in this round's own record:
// `docs/verification/opening-screen-2026-08-30/material-reduction.txt`.

window.RichSplashLibrary =
{
  "schemaVersion": 1,
  "round": "11",
  "variations": [
    {
      "id": "round-11/v1",
      "name": "Splash screen #1 — the ruled standard, the rule struck along its own ghost",
      "source": "richos-hq design/mockups/rounds/round-11/v1/index.html",
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
        "tagline": "#8FA3C6",
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
        "strikeDuration": "0s",
        "seconds": null,
        "bar": {
          "gap": "clamp(30px, 4.6vh, 46px)",
          "height": "2px",
          "radius": "1px",
          "background": "rgba(194,163,92,0.22)",
          "outline": "none",
          "shadow": "none",
          "clip": "visible",
          "enterDelay": "0.62s",
          "enterDuration": "0.7s",
          "pitch": null,
          "pitchInset": "0px",
          "layers": [
            {
              "role": "progress",
              "background": "linear-gradient(to bottom, rgba(194,163,92,.10), rgba(194,163,92,0) 72%)",
              "inset": "2px auto auto 0",
              "height": "26px",
              "mask": "linear-gradient(to right, rgba(0,0,0,0) 0, #000 8%, #000 92%, rgba(0,0,0,0) 100%)"
            },
            {
              "role": "progress",
              "background": "#C2A35C",
              "inset": "-1px auto -1px 0",
              "radius": "2px",
              "shadow": "0 0 10px rgba(194,163,92,.34), 0 0 2px rgba(194,163,92,.85)"
            },
            {
              "role": "lead",
              "background": "radial-gradient(circle, rgba(214,182,110,.30) 0%, rgba(194,163,92,.13) 34%, rgba(194,163,92,0) 68%)",
              "inset": "50% -1px auto auto",
              "width": "74px",
              "height": "74px",
              "transform": "translate(50%, -50%)"
            },
            {
              "role": "flare",
              "background": "linear-gradient(100deg, rgba(255,240,205,0) 40%, rgba(255,240,205,.85) 50%, rgba(255,240,205,0) 60%) 130% 0 / 260% 100%",
              "inset": "-3px 0",
              "radius": "3px",
              "opacity": "0.9"
            }
          ]
        }
      }
    },
    {
      "id": "round-11/v2",
      "name": "Splash screen #2 — midnight suede, the strap sewn live in gold thread",
      "source": "richos-hq design/mockups/rounds/round-11/v2/index.html",
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
        "tagline": "#8FA3C6",
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
        "strikeDuration": "0s",
        "seconds": null,
        "bar": {
          "gap": "clamp(28px, 4.4vh, 44px)",
          "height": "19px",
          "radius": "9.5px",
          "background": "linear-gradient(180deg,#1B2645 0%, #16203A 52%, #111A2E 100%)",
          "outline": "1px solid #56698E",
          "shadow": "0 2px 4px rgba(0,0,0,.45), 0 16px 30px -16px rgba(0,0,0,.8), inset 0 1px 0 rgba(255,255,255,.07), inset 0 -2px 6px rgba(0,0,0,.4)",
          "clip": "hidden",
          "enterDelay": "0.62s",
          "enterDuration": "0.7s",
          "pitch": "10.5px",
          "pitchInset": "11px",
          "layers": [
            {
              "background": "linear-gradient(180deg, rgba(4,8,18,0) calc(50% - 3.5px), rgba(4,8,18,.30) calc(50% - 3.5px), rgba(4,8,18,.10) calc(50% + 0.35px), rgba(4,8,18,0) calc(50% + 3.5px))"
            },
            {
              "role": "rhythm",
              "background": "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='126' height='19'%3E%3Ccircle cx='2.27' cy='9.03' r='1.3' fill='rgba(2,5,13,.95)'/%3E%3Ccircle cx='2.42' cy='9.88' r='.72' fill='rgba(168,186,220,.26)'/%3E%3Ccircle cx='1.97' cy='8.18' r='.6' fill='rgba(168,186,220,.10)'/%3E%3Ccircle cx='8.48' cy='10.04' r='1.3' fill='rgba(2,5,13,.95)'/%3E%3Ccircle cx='8.63' cy='10.89' r='.72' fill='rgba(168,186,220,.26)'/%3E%3Ccircle cx='8.18' cy='9.19' r='.6' fill='rgba(168,186,220,.10)'/%3E%3Ccircle cx='13.02' cy='8.96' r='1.3' fill='rgba(2,5,13,.95)'/%3E%3Ccircle cx='13.17' cy='9.81' r='.72' fill='rgba(168,186,220,.26)'/%3E%3Ccircle cx='12.72' cy='8.11' r='.6' fill='rgba(168,186,220,.10)'/%3E%3Ccircle cx='19.23' cy='9.95' r='1.3' fill='rgba(2,5,13,.95)'/%3E%3Ccircle cx='19.38' cy='10.8' r='.72' fill='rgba(168,186,220,.26)'/%3E%3Ccircle cx='18.93' cy='9.1' r='.6' fill='rgba(168,186,220,.10)'/%3E%3Ccircle cx='24' cy='8.89' r='1.3' fill='rgba(2,5,13,.95)'/%3E%3Ccircle cx='24.15' cy='9.74' r='.72' fill='rgba(168,186,220,.26)'/%3E%3Ccircle cx='23.7' cy='8.04' r='.6' fill='rgba(168,186,220,.10)'/%3E%3Ccircle cx='29.09' cy='9.84' r='1.3' fill='rgba(2,5,13,.95)'/%3E%3Ccircle cx='29.24' cy='10.69' r='.72' fill='rgba(168,186,220,.26)'/%3E%3Ccircle cx='28.79' cy='8.99' r='.6' fill='rgba(168,186,220,.10)'/%3E%3Ccircle cx='33.94' cy='8.68' r='1.3' fill='rgba(2,5,13,.95)'/%3E%3Ccircle cx='34.09' cy='9.53' r='.72' fill='rgba(168,186,220,.26)'/%3E%3Ccircle cx='33.64' cy='7.83' r='.6' fill='rgba(168,186,220,.10)'/%3E%3Ccircle cx='39.39' cy='9.86' r='1.3' fill='rgba(2,5,13,.95)'/%3E%3Ccircle cx='39.54' cy='10.71' r='.72' fill='rgba(168,186,220,.26)'/%3E%3Ccircle cx='39.09' cy='9.01' r='.6' fill='rgba(168,186,220,.10)'/%3E%3Ccircle cx='44.84' cy='8.84' r='1.3' fill='rgba(2,5,13,.95)'/%3E%3Ccircle cx='44.99' cy='9.69' r='.72' fill='rgba(168,186,220,.26)'/%3E%3Ccircle cx='44.54' cy='7.99' r='.6' fill='rgba(168,186,220,.10)'/%3E%3Ccircle cx='50.22' cy='9.85' r='1.3' fill='rgba(2,5,13,.95)'/%3E%3Ccircle cx='50.37' cy='10.7' r='.72' fill='rgba(168,186,220,.26)'/%3E%3Ccircle cx='49.92' cy='9' r='.6' fill='rgba(168,186,220,.10)'/%3E%3Ccircle cx='54.8' cy='8.96' r='1.3' fill='rgba(2,5,13,.95)'/%3E%3Ccircle cx='54.95' cy='9.81' r='.72' fill='rgba(168,186,220,.26)'/%3E%3Ccircle cx='54.5' cy='8.11' r='.6' fill='rgba(168,186,220,.10)'/%3E%3Ccircle cx='60.19' cy='9.85' r='1.3' fill='rgba(2,5,13,.95)'/%3E%3Ccircle cx='60.34' cy='10.7' r='.72' fill='rgba(168,186,220,.26)'/%3E%3Ccircle cx='59.89' cy='9' r='.6' fill='rgba(168,186,220,.10)'/%3E%3Ccircle cx='65.45' cy='8.71' r='1.3' fill='rgba(2,5,13,.95)'/%3E%3Ccircle cx='65.6' cy='9.56' r='.72' fill='rgba(168,186,220,.26)'/%3E%3Ccircle cx='65.15' cy='7.86' r='.6' fill='rgba(168,186,220,.10)'/%3E%3Ccircle cx='70.7' cy='9.55' r='1.3' fill='rgba(2,5,13,.95)'/%3E%3Ccircle cx='70.85' cy='10.4' r='.72' fill='rgba(168,186,220,.26)'/%3E%3Ccircle cx='70.4' cy='8.7' r='.6' fill='rgba(168,186,220,.10)'/%3E%3Ccircle cx='75.21' cy='9.25' r='1.3' fill='rgba(2,5,13,.95)'/%3E%3Ccircle cx='75.36' cy='10.1' r='.72' fill='rgba(168,186,220,.26)'/%3E%3Ccircle cx='74.91' cy='8.4' r='.6' fill='rgba(168,186,220,.10)'/%3E%3Ccircle cx='81.45' cy='10.01' r='1.3' fill='rgba(2,5,13,.95)'/%3E%3Ccircle cx='81.6' cy='10.86' r='.72' fill='rgba(168,186,220,.26)'/%3E%3Ccircle cx='81.15' cy='9.16' r='.6' fill='rgba(168,186,220,.10)'/%3E%3Ccircle cx='86.63' cy='8.81' r='1.3' fill='rgba(2,5,13,.95)'/%3E%3Ccircle cx='86.78' cy='9.66' r='.72' fill='rgba(168,186,220,.26)'/%3E%3Ccircle cx='86.33' cy='7.96' r='.6' fill='rgba(168,186,220,.10)'/%3E%3Ccircle cx='92.33' cy='9.73' r='1.3' fill='rgba(2,5,13,.95)'/%3E%3Ccircle cx='92.48' cy='10.58' r='.72' fill='rgba(168,186,220,.26)'/%3E%3Ccircle cx='92.03' cy='8.88' r='.6' fill='rgba(168,186,220,.10)'/%3E%3Ccircle cx='96.78' cy='8.77' r='1.3' fill='rgba(2,5,13,.95)'/%3E%3Ccircle cx='96.93' cy='9.62' r='.72' fill='rgba(168,186,220,.26)'/%3E%3Ccircle cx='96.48' cy='7.92' r='.6' fill='rgba(168,186,220,.10)'/%3E%3Ccircle cx='102.82' cy='9.71' r='1.3' fill='rgba(2,5,13,.95)'/%3E%3Ccircle cx='102.97' cy='10.56' r='.72' fill='rgba(168,186,220,.26)'/%3E%3Ccircle cx='102.52' cy='8.86' r='.6' fill='rgba(168,186,220,.10)'/%3E%3Ccircle cx='107.65' cy='8.82' r='1.3' fill='rgba(2,5,13,.95)'/%3E%3Ccircle cx='107.8' cy='9.67' r='.72' fill='rgba(168,186,220,.26)'/%3E%3Ccircle cx='107.35' cy='7.97' r='.6' fill='rgba(168,186,220,.10)'/%3E%3Ccircle cx='112.93' cy='9.81' r='1.3' fill='rgba(2,5,13,.95)'/%3E%3Ccircle cx='113.08' cy='10.66' r='.72' fill='rgba(168,186,220,.26)'/%3E%3Ccircle cx='112.63' cy='8.96' r='.6' fill='rgba(168,186,220,.10)'/%3E%3Ccircle cx='117.4' cy='8.55' r='1.3' fill='rgba(2,5,13,.95)'/%3E%3Ccircle cx='117.55' cy='9.4' r='.72' fill='rgba(168,186,220,.26)'/%3E%3Ccircle cx='117.1' cy='7.7' r='.6' fill='rgba(168,186,220,.10)'/%3E%3Ccircle cx='123.62' cy='9.71' r='1.3' fill='rgba(2,5,13,.95)'/%3E%3Ccircle cx='123.77' cy='10.56' r='.72' fill='rgba(168,186,220,.26)'/%3E%3Ccircle cx='123.32' cy='8.86' r='.6' fill='rgba(168,186,220,.10)'/%3E%3C/svg%3E\") left center / 126px 19px repeat-x"
            },
            {
              "role": "progress",
              "background": "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='126' height='19'%3E%3Cg fill='none' stroke-linecap='round'%3E%3Cpath d='M2.27 9.03L8.48 10.04M13.02 8.96L19.23 9.95M24 8.89L29.09 9.84M33.94 8.68L39.39 9.86M44.84 8.84L50.22 9.85M54.8 8.96L60.19 9.85M65.45 8.71L70.7 9.55M75.21 9.25L81.45 10.01M86.63 8.81L92.33 9.73M96.78 8.77L102.82 9.71M107.65 8.82L112.93 9.81M117.4 8.55L123.62 9.71' transform='translate(0 .5)' stroke='rgba(84,64,26,.85)' stroke-width='2.5'/%3E%3Cpath d='M2.27 9.03L8.48 10.04M13.02 8.96L19.23 9.95M24 8.89L29.09 9.84M33.94 8.68L39.39 9.86M44.84 8.84L50.22 9.85M54.8 8.96L60.19 9.85M65.45 8.71L70.7 9.55M75.21 9.25L81.45 10.01M86.63 8.81L92.33 9.73M96.78 8.77L102.82 9.71M107.65 8.82L112.93 9.81M117.4 8.55L123.62 9.71' stroke='%23D2B266' stroke-width='1.7'/%3E%3Cpath d='M2.27 9.03L8.48 10.04M13.02 8.96L19.23 9.95M24 8.89L29.09 9.84M33.94 8.68L39.39 9.86M44.84 8.84L50.22 9.85M54.8 8.96L60.19 9.85M65.45 8.71L70.7 9.55M75.21 9.25L81.45 10.01M86.63 8.81L92.33 9.73M96.78 8.77L102.82 9.71M107.65 8.82L112.93 9.81M117.4 8.55L123.62 9.71' transform='translate(-.2 -.45)' stroke='rgba(255,238,190,.55)' stroke-width='.7'/%3E%3C/g%3E%3C/svg%3E\") left center / 126px 19px repeat-x",
              "inset": "0 auto 0 0"
            },
            {
              "role": "lead",
              "background": "radial-gradient(circle at 50% 50%, rgba(255,235,180,.34) 0%, rgba(214,182,110,.14) 45%, rgba(194,163,92,0) 100%)",
              "inset": "0 -14px auto auto",
              "width": "28px",
              "height": "100%"
            },
            {
              "role": "flare",
              "background": "linear-gradient(100deg, rgba(255,240,205,0) 42%, rgba(255,240,205,.42) 50%, rgba(255,240,205,0) 58%) 130% 0 / 260% 100%",
              "inset": "0",
              "blend": "screen",
              "opacity": "1"
            }
          ]
        }
      }
    }
  ]
};
