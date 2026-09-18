// USE RICH FROM YOUR PHONE — the pairing screen, and the QR codes measured FROM THE PIXELS.
//
// TWO JOBS, AND THE FIRST ONE IS A DEBT THIS FILE EXISTS TO PAY.
//
// `contrast.js` check 14 refuses a `<canvas>` on any walked surface, because a computed-style walk
// cannot read a pixel one painted — *"a green run here must not be read as covering it. If it
// belongs to a surface that IS measured from the pixels somewhere, exclude it here BY NAME and say
// where — never by raising a threshold."* The pairing screen has two canvases, so the exclusion
// names this file, and check 3 below is what makes that name worth something: it reads the rendered
// QR back with `getImageData` in the same WebKit and asserts what is actually painted.
//
// THE SECOND JOB IS THE PORT. `ui/qr.js` is `tools/phone-probe/lib/qr.js` with three changes and
// no more — the source of record is the probe's, which is checked against ISO/IEC 18004's own
// Annex I example and, end to end, by decoding a rendered PNG with Apple's Vision framework.
// Check 1 runs both modules over the same strings and asserts the matrices are identical, module
// for module. That is the only thing a second copy of anything can usefully promise, and without
// it the copy would be a second implementation to be wrong in a second way.
//
// AND THE THIRD IS THE PROSE, which is not decoration on this screen. Plan §2.1 names two things
// the CEO must be told BEFORE he starts — the red "Unverified", and Apple's own iOS 18.0/18.1 bug
// that hides the switch at step 15 — because *"we want to know that on day one rather than three
// days into slice A."* A person who meets a red warning he was not warned about stops. Checks 4, 5
// and 6 assert the warnings are there, that they come BEFORE the codes in reading order, and that
// the sixteen steps are sixteen and name both hazards where they fall.
//
// Run: node phone.js   (or `npm test` for every suite in this directory)

"use strict";

const path = require("path");
const {
  bootSettled,
  leaveHome,
  loadPlaywright,
  shot,
  publishShotFile,
  createRun,
  assert,
  assertEqual,
  UI_DIR,
} = require("./lib/harness");

const APP = "file://" + path.join(UI_DIR, "index.html");
const SHOTS = path.join(__dirname, "shots-phone");

/// The two modules whose agreement check 1 is about. `ui/qr.js` ships; the probe's does not.
const SHIPPED_QR = require(path.join(UI_DIR, "qr.js"));
const PROBE_QR = require(path.resolve(UI_DIR, "..", "..", "tools", "phone-probe", "lib", "qr.js"));

/// The strings the pairing screen actually encodes, plus the two edges of the version table. A
/// cross-check over one happy string would not notice a version boundary handled differently.
const ENCODED = [
  "http://mm1.local:8444/ca",
  "https://mm1.local:8443/#pair=K7QF2M9X",
  "https://a-much-longer-hostname-than-his.local:8443/#pair=ZZZZZZZZ",
  "x",
];

async function openSheet(browser, theme, preset) {
  const page = await browser.newPage({ viewport: { width: 1400, height: 950 } });
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => {
    if (m.type() === "error") errors.push("console: " + m.text());
  });
  // THE PRESET HAS TO BE IN PLACE BEFORE ANY OF THE PAGE'S OWN SCRIPTS RUN, because `mock.js`
  // reads it while building its state — `contrast.js` says the same thing from its side.
  await page.addInitScript((v) => {
    window.__RICHOS_MOCK_PRESET__ = v;
  }, preset || { phonePairing: true });
  // BOTH THE MIRROR AND THE STORE, for the reason `contrast.js` spells out at length: the
  // mirror is a cache, `syncAppearanceFromBackend` reconciles it against the backend at init,
  // and THE BACKEND WINS. Seeding the mirror alone measures the store's theme while claiming
  // the seed's.
  await page.addInitScript((t) => {
    try {
      window.localStorage.setItem("richos-theme", t);
      window.localStorage.setItem("richos-font-scale", "100");
      window.localStorage.setItem(
        "richos-mock-config",
        JSON.stringify({ theme: t, font_scale: 100, user_name: null })
      );
    } catch (e) {
      /* storage unavailable: theme-boot falls back to the shipped default, which is dark */
    }
  }, theme || "dark");
  await page.goto(APP);
  await leaveHome(page);
  await page.waitForSelector(".nav-thread", { state: "attached" });
  await bootSettled(page);
  await page.click("#set-btn");
  await page.waitForSelector("#set-phone-open");
  await page.click("#set-phone-open");
  await page.waitForSelector("#phone-sheet:not([hidden])");
  page.__errors = errors;
  return page;
}

(async () => {
  const run = createRun("phone", "the pairing screen, its two QR codes and the warnings that come first");
  const playwright = await loadPlaywright();
  const browser = await playwright.webkit.launch();

  // ---- 1. the port is the probe's encoder, not a second one -------------------------------

  await run.check("1  the shipped QR encoder and the probe's produce identical matrices", async () => {
    for (const text of ENCODED) {
      const mine = SHIPPED_QR.encode(text);
      const theirs = PROBE_QR.encode(text);
      assertEqual(
        { version: mine.version, size: mine.size, mask: mine.mask, modules: mine.modules },
        { version: theirs.version, size: theirs.size, mask: theirs.mask, modules: theirs.modules },
        "app/ui/qr.js and tools/phone-probe/lib/qr.js disagree on " + JSON.stringify(text) +
          " — the shipped copy has drifted from the implementation that is checked against the " +
          "standard and against Apple's own decoder, and the shipped one is the one his phone reads"
      );
    }
    return (
      ENCODED.length + " string(s) encoded identically by both modules, including the two the " +
      "pairing screen actually draws. The probe's is the source of record: it is checked against " +
      "ISO/IEC 18004 Annex I and against Apple's Vision decoder, and neither of those checks is " +
      "re-implemented here."
    );
  });

  await run.check("1b  a URL too long to encode throws rather than drawing something unscannable", async () => {
    let threw = null;
    try {
      SHIPPED_QR.encode("https://" + "x".repeat(200) + ".local:8443/");
    } catch (error) {
      threw = String(error.message || error);
    }
    assert(threw !== null, "a 200-byte URL was encoded — the version table stops at 106 bytes");
    assert(
      /106/.test(threw),
      "the refusal does not name the ceiling it hit, so whoever meets it cannot act on it: " + threw
    );
    return "a URL past the version-6 ceiling throws and names the ceiling: " + threw.slice(0, 90) + "…";
  });

  // ---- 2. both codes are drawn ------------------------------------------------------------

  await run.check("2  the pairing screen draws both codes, at the sizes their content needs", async () => {
    const page = await openSheet(browser, "dark");
    const drawn = await page.evaluate(() => {
      const one = document.getElementById("phone-qr-trust");
      const two = document.getElementById("phone-qr-pair");
      return {
        trust: { hidden: one.hidden, width: one.width, height: one.height },
        pair: { hidden: two.hidden, width: two.width, height: two.height },
        trustUrl: document.getElementById("phone-trust-url").textContent,
        pairUrl: document.getElementById("phone-pair-url").textContent,
      };
    });
    await page.close();
    assert(!drawn.trust.hidden && !drawn.pair.hidden, "a code is hidden: " + JSON.stringify(drawn));
    // (25 + 8) * 5 = 165 for the trust URL's version-2 symbol; (29 + 8) * 5 = 185 for the
    // pairing URL's version 3. Derived rather than remembered: the encoder decides the version
    // from the byte length and this asserts the canvas followed it.
    const expect = (text) => (SHIPPED_QR.encode(text).size + 8) * 5;
    assertEqual(drawn.trust.width, expect(drawn.trustUrl), "the trust code's canvas is the wrong size");
    assertEqual(drawn.pair.width, expect(drawn.pairUrl), "the pairing code's canvas is the wrong size");
    assert(drawn.trust.width === drawn.trust.height, "the trust code is not square");
    assert(drawn.pair.width === drawn.pair.height, "the pairing code is not square");
    // THE ADDRESS IS WRITTEN OUT BESIDE EVERY CODE. A code and nothing else is a screen that
    // cannot be used by anyone whose camera will not focus, and it is the only way to tell what
    // the code points at without scanning it.
    assert(/^http:\/\/[a-z0-9.-]+\.local:8444\/ca$/.test(drawn.trustUrl), drawn.trustUrl);
    assert(/^https:\/\/[a-z0-9.-]+\.local:8443\/#pair=[A-Z0-9]{8}$/.test(drawn.pairUrl), drawn.pairUrl);
    return (
      "both codes drawn and square, " + drawn.trust.width + "px and " + drawn.pair.width +
      "px, each at (size + 8 quiet modules) x 5 for the version its own URL needs, with the " +
      "address written out beside it"
    );
  });

  // ---- 3. THE PIXELS — the debt check 14's exclusion is paid with ------------------------

  await run.check("3  the QR codes are measured FROM THE PIXELS: 21:1, and a white quiet zone on all four edges", async () => {
    // WHY FROM THE PIXELS AND NOT FROM THE SOURCE. `phone.js` sets `fillStyle` twice and a
    // reader can see both values, which proves what the code SAYS. It does not prove what WebKit
    // painted — a canvas with a transparent background over a dark page reads as dark modules on
    // dark, and the source looks identical either way. So this reads the surface back.
    const results = [];
    for (const theme of ["dark", "light"]) {
      const page = await openSheet(browser, theme);
      const measured = await page.evaluate(() => {
        function look(id) {
          const canvas = document.getElementById(id);
          const paper = canvas.getContext("2d");
          const { data, width, height } = paper.getImageData(0, 0, canvas.width, canvas.height);
          const seen = new Map();
          for (let i = 0; i < data.length; i += 4) {
            const key = data[i] + "," + data[i + 1] + "," + data[i + 2] + "," + data[i + 3];
            seen.set(key, (seen.get(key) || 0) + 1);
          }
          // The quiet zone: four modules at five pixels each is twenty pixels of margin, and it
          // has to be white on ALL FOUR edges or the code does not scan against a dark page.
          const at = (x, y) => {
            const i = (y * width + x) * 4;
            return [data[i], data[i + 1], data[i + 2], data[i + 3]].join(",");
          };
          const mid = Math.floor(width / 2);
          const edges = {
            top: at(mid, 2),
            bottom: at(mid, height - 3),
            left: at(2, mid),
            right: at(width - 3, mid),
            corner: at(1, 1),
          };
          return { colors: [...seen.keys()].sort(), edges, width, height };
        }
        return { trust: look("phone-qr-trust"), pair: look("phone-qr-pair") };
      });
      await page.close();

      for (const [which, m] of Object.entries(measured)) {
        assertEqual(
          m.colors,
          ["0,0,0,255", "255,255,255,255"],
          which + " in " + theme + " painted something other than opaque black and opaque white. " +
            "A transparent pixel here is a module that takes the page's color, and on a dark page " +
            "that is a code that does not scan"
        );
        for (const [edge, color] of Object.entries(m.edges)) {
          assertEqual(
            color,
            "255,255,255,255",
            which + " in " + theme + ": the quiet zone is not white at the " + edge +
              " edge. The quiet zone is part of the symbol, not decoration — a code drawn flush " +
              "to the page background does not scan"
          );
        }
        results.push(which + "/" + theme);
      }

      const page2 = await openSheet(browser, theme);
      const s = await shot(page2, "phone-" + theme, { fullPage: false });
      publishShotFile(s.file, path.join(SHOTS, "phone-" + theme + ".png"));
      await page2.close();
    }

    // The ratio, computed here rather than asserted as a number somebody remembers.
    const lin = (c) => (c / 255 <= 0.03928 ? c / 255 / 12.92 : Math.pow((c / 255 + 0.055) / 1.055, 2.4));
    const lum = (r, g, b) => 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
    const ratio = (1.0 + 0.05) / (lum(0, 0, 0) + 0.05);
    assert(ratio >= 4.5, "black on white is not clearing the floor, which cannot happen: " + ratio);
    return (
      results.length + " canvas/theme combination(s) read back with getImageData: exactly two " +
      "colors present, opaque #000000 and opaque #ffffff, at " + ratio.toFixed(2) + ":1 — and the " +
      "quiet zone white on all four edges plus the corner, in BOTH themes. This is the measurement " +
      "`contrast.js` check 14's exclusion names."
    );
  });

  // ---- 4, 5, 6. the prose, which is the feature -------------------------------------------

  await run.check("4  both warnings are on the screen, in his words", async () => {
    const page = await openSheet(browser, "dark");
    const text = await page.textContent("#phone-pairing");
    await page.close();
    const flat = text.replace(/\s+/g, " ");
    assert(/Unverified/.test(flat), "the red word is never named, so he meets it cold");
    assert(
      /nobody vouched for the file except your own Mac/i.test(flat),
      "the red word is named but not explained — naming a warning without saying why it is there " +
        "is a screen that worries him and tells him nothing"
    );
    assert(/iOS 18\.0 and 18\.1/.test(flat), "Apple's own missing-switch bug is not named");
    assert(
      /stop and tell me/i.test(flat),
      "he is told the switch may be missing and not what to do about it. Plan §2.1: if his phone " +
        "shows that, the home-network design is BLOCKED and we want to know on day one"
    );
    return "both warnings present and both explained, including what to do if the switch is missing";
  });

  await run.check("5  the warnings come BEFORE the codes in reading order", async () => {
    // The whole value of a warning is that it arrives first. A screen with the same sentences
    // below the codes is a screen he reads after he has already met the red word.
    const page = await openSheet(browser, "dark");
    const order = await page.evaluate(() => {
      const nodes = [...document.querySelectorAll("#phone-pairing *")];
      const find = (test) => nodes.findIndex((n) => test(n.textContent || ""));
      return {
        unverified: find((t) => /Unverified/.test(t) && t.length < 600),
        appleBug: find((t) => /iOS 18\.0 and 18\.1/.test(t) && t.length < 600),
        firstQr: nodes.findIndex((n) => n.tagName === "CANVAS"),
      };
    });
    await page.close();
    assert(order.unverified >= 0 && order.appleBug >= 0 && order.firstQr >= 0, JSON.stringify(order));
    assert(
      order.unverified < order.firstQr,
      "the Unverified warning comes after the first code in the document, so he meets the red " +
        "word before he is told about it"
    );
    assert(
      order.appleBug < order.firstQr,
      "the missing-switch warning comes after the first code, which is too late to be a warning"
    );
    return "both warnings precede the first code in document order";
  });

  await run.check("6  the sixteen taps are sixteen, and the two hazards are named where they fall", async () => {
    const page = await openSheet(browser, "dark");
    const steps = await page.evaluate(() =>
      [...document.querySelectorAll("#phone-steps li")].map((n) => n.textContent.trim())
    );
    await page.close();
    // SIXTEEN, because the plan counted them: "'a one-time setup step' is how a plan hides a bad
    // afternoon". A screen that says "follow the prompts" over sixteen taps lies about the cost.
    assertEqual(steps.length, 16, "the step list is not sixteen steps long");
    assert(/Unverified/.test(steps[8]), "step 9 does not warn about the red word: " + steps[8]);
    assert(
      /Certificate Trust Settings/.test(steps[14]),
      "step 15 does not name Apple's own screen: " + steps[14]
    );
    assert(
      /18\.0 and 18\.1/.test(steps[14]),
      "step 15 is where the switch is missing and it does not say so: " + steps[14]
    );
    assert(
      steps.every((s) => s.length > 0 && !/^TODO/i.test(s)),
      "a step is empty or unwritten"
    );
    return "sixteen steps; step 9 names the red word and step 15 names the switch that can be absent";
  });

  // ---- 7. the six words, and the countdown -------------------------------------------------

  await run.check("7  the six words are six, and he is told they have to match", async () => {
    const page = await openSheet(browser, "dark");
    const words = (await page.textContent("#phone-words")).trim().split(/\s+/);
    const said = (await page.textContent("#phone-pairing")).replace(/\s+/g, " ");
    await page.close();
    assertEqual(words.length, 6, "the fingerprint is not six words: " + JSON.stringify(words));
    assert(
      words.every((w) => /^[a-z]{3,7}$/.test(w)),
      "a fingerprint word is not three to seven plain lowercase letters: " + JSON.stringify(words)
    );
    assert(
      /have to be these six, in this order/i.test(said),
      "the screen shows six words without saying they have to match, which makes them decoration"
    );
    assert(
      /tap Cancel and tell me/i.test(said),
      "he is not told what to do if they do NOT match, which is the only case the comparison exists for"
    );
    return "six words, each 3-7 lowercase letters, with what to do when they do not match";
  });

  await run.check("8  a live code says how long is left, and an expired one does not look live", async () => {
    // The state a real person meets most often: he opens the screen, goes to find his phone, and
    // comes back after the sixty seconds are up. A code that has run out and still looks usable is
    // a code he scans and is only then told about.
    const live = await openSheet(browser, "dark", { phonePairing: true });
    const countdown = (await live.textContent("#phone-countdown")).trim();
    const pairVisible = await live.isVisible("#phone-qr-pair");
    await live.close();
    assert(
      /lasts \d+ more seconds?\./.test(countdown),
      "a live code does not say how long is left: " + JSON.stringify(countdown)
    );
    assert(pairVisible, "a live code is not on screen");

    const expired = await openSheet(browser, "dark", { phonePairingExpired: true });
    const shown = await expired.evaluate(() => ({
      pairingVisible: !document.getElementById("phone-pairing").hidden,
      offVisible: !document.getElementById("phone-off").hidden,
      offMessage: document.getElementById("phone-off-message").textContent.trim(),
      canAskAgain: !document.getElementById("phone-start").disabled,
    }));
    await expired.close();
    assert(
      !shown.pairingVisible,
      "an expired window still shows a code, so he scans one that cannot work"
    );
    assert(shown.offVisible && shown.canAskAgain, JSON.stringify(shown));
    assert(
      /ask for a code/i.test(shown.offMessage),
      "he is not told how to get another code: " + JSON.stringify(shown.offMessage)
    );
    return (
      "a live code says " + JSON.stringify(countdown) + "; an expired one shows no code at all and " +
      "says " + JSON.stringify(shown.offMessage)
    );
  });

  // ---- 9. the paired state, and the cleanup he has to know about -------------------------

  await run.check("9  once paired, the screen says what he must do on the phone to undo it", async () => {
    // Plan §4.1: "A cleanup the user has to know to do is a cleanup that does not happen" — so the
    // app says it at the moment it becomes true rather than putting it in a README.
    const page = await openSheet(browser, "dark", { phonePaired: true });
    const text = (await page.textContent("#phone-paired")).replace(/\s+/g, " ");
    const forget = await page.isVisible("#phone-forget");
    await page.close();
    assert(forget, "there is no way to forget the phone");
    assert(/iPhone is paired/.test(text), "the paired phone is not named: " + text);
    assert(
      /does .{0,4}not.{0,4} remove the certificate from your phone/i.test(text),
      "the screen does not say that forgetting here leaves the profile on his phone: " + text
    );
    assert(
      /VPN and Device Management/.test(text) && /Remove Profile/.test(text),
      "the screen does not say WHERE on the phone to remove it, which is the whole point: " + text
    );
    return "the paired state names the phone, offers the way out, and says what the Mac cannot undo for him";
  });

  await run.check("10  nothing on the sheet threw, in either theme", async () => {
    const errors = [];
    for (const theme of ["dark", "light"]) {
      for (const preset of [{ phonePairing: true }, { phonePaired: true }]) {
        const page = await openSheet(browser, theme, preset);
        await page.close();
        errors.push(...page.__errors);
      }
    }
    assertEqual(errors, [], "the pairing screen raised a page error or logged to console.error");
    return "4 combination(s) of theme and state opened with no page error and nothing on console.error";
  });

  await browser.close();
  const failed = run.report();
  console.log("\nScreenshots: " + SHOTS + " — both themes, both states.");
  console.log(
    failed
      ? "\n" + failed + " check(s) FAILED"
      : "\nhe is warned before he meets the red word, the sixteen taps are sixteen, and the two " +
        "codes are black on white with a white quiet zone — measured from the pixels, in both themes."
  );
  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.error(e);
  process.exit(1);
});

// ---------------------------------------------------------------------------------------
// MUTATIONS RUN RED, so the checks above are known to be able to fail
// ---------------------------------------------------------------------------------------
//
//  1   ui/qr.js: change one entry of the version table (`dataPerBlock: 28` -> 27)
//        -> check 1 red on every string; the shipped copy and the probe's disagree
//  3   phone.js `paint`: delete the `paper.fillStyle = "#ffffff"; paper.fillRect(...)` pair
//        -> check 3 red with three colors present, one of them transparent — which is exactly
//           the defect that only shows up as "the code will not scan" on his phone in dark mode
//  5   phone.js: move the two warning paragraphs below the first `<canvas>`
//        -> check 5 red; check 4 stays green, which is the point of having both
//  6   phone.js `STEPS`: drop the last entry
//        -> check 6 red at fifteen
//  8   phone.js `render`: treat `pairUrl: null` as still pairing
//        -> check 8 red; an expired window shows a code he can scan and nothing that works
//  9   phone.js: delete the sentence naming VPN and Device Management
//        -> check 9 red
