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

const fs = require("fs");
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
    const page2 = page;
    assertEqual(words.length, 6, "the fingerprint is not six words: " + JSON.stringify(words));
    assert(
      words.every((w) => /^[a-z]{3,7}$/.test(w)),
      "a fingerprint word is not three to seven plain lowercase letters: " + JSON.stringify(words)
    );
    assert(
      /have to be these six, in this order/i.test(said),
      "the screen shows six words without saying they have to match, which makes them decoration"
    );
    // AND THE CONTROL IT NAMES IS ON THE SCREEN. This used to read "tap Cancel and tell me"
    // and this check pinned that literal — but there has never been a Cancel button in this
    // sheet, so the assertion was holding a sentence that named a control nobody could press
    // (Ray's candidate-.12 defect B, the other half). The needle is now the ACTION plus the
    // existence of the button, so a future rewording cannot put a phantom control back.
    const named = /press ([A-Z][a-z]+) and tell me/.exec(said);
    assert(
      named,
      "he is not told what to do if they do NOT match, which is the only case the comparison exists for"
    );
    const buttons = await page2.$$eval(
      "#phone-sheet button",
      (els) => els.map((e) => e.textContent.trim())
    );
    assert(
      buttons.includes(named[1]),
      `the sentence tells him to press ${JSON.stringify(named[1])}, and this sheet's buttons are ` +
        JSON.stringify(buttons)
    );
    await page2.close();
    return `six words, each 3-7 lowercase letters, and "press ${named[1]}" names a button this sheet has`;
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
      // Minutes while there are minutes, seconds in the last one — the window is 300 s now and
      // "This code lasts 287 more seconds." is a number nobody converts.
      /lasts \d+ more (seconds?|minutes?)\./.test(countdown),
      "a live code does not say how long is left: " + JSON.stringify(countdown)
    );
    assert(pairVisible, "a live code is not on screen");

    // **DEFECT 3.3 — AN EXPIRED CODE IS ANNOUNCED WHERE IT EXPIRED, NEVER A SILENT RESET.**
    //
    // What Ray met: the code, the QR and the six words vanished with no message at all and the
    // dialog dropped back to "This Mac is ready". *"He comes back to a screen that looks like
    // he imagined the whole thing."*
    const expired = await openSheet(browser, "dark", { phonePairingExpired: true });
    const shown = await expired.evaluate(() => {
      const visible = (id) => {
        const node = document.getElementById(id);
        return !!node && node.offsetParent !== null;
      };
      return {
        pairingScreen: visible("phone-pairing"),
        expiredBlock: visible("phone-expired"),
        expiredHeading: (document.querySelector("#phone-expired h3") || {}).textContent || "",
        expiredNote: (document.getElementById("phone-expired-note") || {}).textContent || "",
        qrShown: visible("phone-qr-pair"),
        codeShown: (document.getElementById("phone-pair-url").textContent || "").trim(),
        wordsShown: (document.getElementById("phone-words").textContent || "").trim(),
        // The one control the screen is about, and it must be pressable where he is standing.
        newCode: visible("phone-refresh") && !document.getElementById("phone-refresh").disabled,
        newCodeLabel: document.getElementById("phone-refresh").textContent.trim(),
        // The screens he must NOT have been thrown back to.
        readyScreen: visible("phone-ts-ready"),
        routeScreen: visible("phone-route"),
        offScreen: visible("phone-off"),
      };
    });
    await expired.close();
    assert(
      !shown.qrShown && !shown.codeShown && !shown.wordsShown,
      "an expired window still shows a code, so he scans one that cannot work: " + JSON.stringify(shown)
    );
    assert(
      shown.pairingScreen && shown.expiredBlock,
      "the expiry is not announced on the screen it happened on — this is the silent reset: " +
        JSON.stringify(shown)
    );
    assert(
      !shown.readyScreen && !shown.routeScreen && !shown.offScreen,
      "an expired code threw him back to an earlier screen: " + JSON.stringify(shown)
    );
    assert(
      /ran out/i.test(shown.expiredHeading) && /Show me another code/.test(shown.expiredNote),
      "the expiry does not say what happened and point at the way on: " +
        JSON.stringify(shown.expiredHeading + " / " + shown.expiredNote)
    );
    assert(
      shown.newCode && /another code/i.test(shown.newCodeLabel),
      "a new code is not offered in its place: " + JSON.stringify(shown)
    );
    return (
      "a live code says " + JSON.stringify(countdown) + "; an expired one stays on the same " +
      "screen, shows no code, says " + JSON.stringify(shown.expiredHeading.trim()) + " and " +
      "offers " + JSON.stringify(shown.newCodeLabel)
    );
  });

  // ---- 8c. the harness's window is the Mac's window -----------------------------------------

  await run.check("8c  the window the harness models is the window the Mac serves", async () => {
    // `PAIRING_WINDOW_MS` went from 60 s to 300 s for defect 3.3. The mock models the countdown
    // itself, so a mock left at 60 s would draw a countdown the product never shows and every
    // check above it would be measuring a screen that does not ship. This is one grep against
    // the Rust rather than a second copy of the number.
    const modRs = fs.readFileSync(
      path.resolve(UI_DIR, "..", "src-tauri", "src", "phone", "mod.rs"),
      "utf8"
    );
    const rust = /pub const PAIRING_WINDOW_MS: u64 = ([\d_]+);/.exec(modRs);
    assert(rust, "PAIRING_WINDOW_MS is not declared in src-tauri/src/phone/mod.rs any more");
    const mockJs = fs.readFileSync(path.join(UI_DIR, "mock.js"), "utf8");
    const mock = /const PAIRING_WINDOW_MS = (\d+);/.exec(mockJs);
    assert(mock, "ui/mock.js no longer declares the window it models");
    const rustMs = Number(rust[1].replace(/_/g, ""));
    assertEqual(
      Number(mock[1]),
      rustMs,
      "the harness models a different pairing window than the Mac serves"
    );
    assert(
      rustMs >= 180000,
      "the window is " + rustMs / 1000 + " s. Defect 3.3 is that sixty seconds is not enough " +
        "time to read the screen, walk to the phone, unlock it and open the camera — a window " +
        "under three minutes puts that defect back"
    );
    return (
      "PAIRING_WINDOW_MS is " + rustMs / 1000 + " s in phone/mod.rs and " + Number(mock[1]) / 1000 +
      " s in ui/mock.js. One guess per window (complete_pairing takes the window before it " +
      "compares), 30^8 = 656,100,000,000 codes, so the chance per window is 1.5e-12 at either " +
      "length — the duration is not in that number."
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
      // "VPN & Device Management" — Apple's own screen name, and the spelling the sixteen
      // steps above already use. This one paragraph said "VPN and Device Management", which is
      // a screen name that does not exist on the phone he is holding.
      /VPN & Device Management/.test(text) && /Remove Profile/.test(text),
      "the screen does not say WHERE on the phone to remove it, which is the whole point: " + text
    );
    return "the paired state names the phone, offers the way out, and says what the Mac cannot undo for him";
  });

  // ---- 9d. DEFECT 4.5 — the Mac names the control the paired phone actually has -------------

  await run.check(
    "9d  the install instruction names the phone's own control, and is not given where it is wrong",
    async () => {
      // RAY'S CANDIDATE .11 DEFECT 4.5. The card said "Add Rich to your phone's Home Screen and
      // allow notifications when it asks." Chrome on his HONOR X6b offers "Install and create
      // shortcut" and has no item by the other name at all — the Mac named a control the device
      // does not have.
      //
      // AND ON ANDROID THE INSTRUCTION IS WRONG RATHER THAN MISNAMED: Chrome on Android
      // subscribes to push from a tab, so nothing has to be installed first. It is iOS Safari
      // that cannot take a push until the app is on the Home Screen. The phone page draws the
      // same division (web/web-app/app.js, installControlName / installSentence).
      const cases = [
        {
          platform: "ios",
          must: [/Share menu/, /Add to Home Screen/],
          mustNot: [/Install and create shortcut/],
        },
        {
          platform: "android",
          must: [/does not need Rich installed first/],
          // The defect, in one pattern: an Android phone must never be sent to look for this.
          mustNot: [/Add to Home Screen/, /Home Screen and allow/],
        },
        {
          // A phone this Mac cannot name gets what is true of both and names neither as the
          // one to use — the same "null means say nothing" rule the phone page follows.
          platform: "",
          must: [/Allow notifications on your phone/],
          mustNot: [/Install and create shortcut/],
        },
      ];

      const said = [];
      for (const one of cases) {
        const page = await openSheet(browser, "dark", {
          phonePaired: true,
          phonePlatform: one.platform,
          phonePairedVia: "tailnet",
        });
        const text = (await page.textContent("#phone-push-state")).replace(/\s+/g, " ").trim();
        await page.close();
        for (const pattern of one.must) {
          assert(
            pattern.test(text),
            (one.platform || "unknown") + " is missing " + pattern + ": " + JSON.stringify(text)
          );
        }
        for (const pattern of one.mustNot) {
          assert(
            !pattern.test(text),
            (one.platform || "unknown") + " names a control that phone does not have (" +
              pattern + "): " + JSON.stringify(text)
          );
        }
        said.push((one.platform || "unknown") + ": " + JSON.stringify(text.slice(0, 56) + "…"));
      }
      return said.length + " platform(s), each named in its own phone's words — " + said.join("; ");
    }
  );

  // ---- 9c. DEFECT 3.1 — the first sentence describes the option he chose --------------------

  await run.check(
    "9c  the lead paragraph follows the chosen option, and the flow has one word for the place",
    async () => {
      // RAY'S CANDIDATE .11 DEFECT 3.1. Every screen opened with "Your phone talks to this Mac
      // directly, over your own home network ... there is no account to make" — a description
      // of "At home only" — and it stayed there unchanged after he pressed "Anywhere", which is
      // not the home network and does involve making an account. Screenshots 13, 14, 15, 17.
      const page = await openSheet(browser, "dark", {
        phoneTailnet: {
          state: "ready",
          name: "mm1.tail770f6e.ts.net",
          origin: "https://mm1.tail770f6e.ts.net:8443",
          account: "Google as someone@gmail.com",
        },
      });
      // THE FIRST PARAGRAPH OF THE PANEL, by position rather than by id — the only direct
      // `p.overlay-note` child of `.overlay-panel`, on this build and on the one Ray walked. So
      // this check measures the SENTENCE, and a build where that sentence is a fixed literal
      // fails on what it says rather than on a missing element.
      const lead = async () =>
        (
          await page.textContent("#phone-sheet .overlay-panel > p.overlay-note")
        )
          .replace(/\s+/g, " ")
          .trim();

      const chooser = await lead();
      assert(
        !/home network/i.test(chooser),
        "before he has chosen anything the screen already describes one of the two options: " +
          JSON.stringify(chooser)
      );

      await page.click("#phone-route-anywhere");
      await page.waitForSelector("#phone-ts-ready:not([hidden])");
      const anywhere = await lead();
      assert(
        /Tailscale/.test(anywhere) && /account/.test(anywhere),
        "the Anywhere path's lead does not name the network or the account it costs: " +
          JSON.stringify(anywhere)
      );
      assert(
        !/own home network/i.test(anywhere) && !/no account to make/i.test(anywhere),
        "THE DEFECT: the Anywhere path still opens by describing the home-network option, which " +
          "is not the network he is on and is not true of the account he has to make: " +
          JSON.stringify(anywhere)
      );

      await page.click("#phone-ts-ready-back");
      await page.waitForSelector("#phone-route:not([hidden])");
      await page.click("#phone-route-home");
      await page.waitForSelector("#phone-off:not([hidden])");
      const atHome = await lead();
      assert(
        /own home network/i.test(atHome) && /no account to make/i.test(atHome),
        "the At-home path lost the sentence that is true of it: " + JSON.stringify(atHome)
      );

      // ONE WORD FOR THE PLACE. It was "the office", "the house" and "home" in three adjacent
      // sentences. The option is called "At home only" and the thing it describes is "your own
      // home network", so the other two were the odd ones out.
      const whole = (await page.textContent("#phone-sheet")).replace(/\s+/g, " ");
      await page.close();
      const strays = ["the office", "the house"].filter((word) => whole.includes(word));
      assertEqual(
        strays,
        [],
        "the flow uses more than one word for the same place, which is how he ends up wondering " +
          "whether they are three different places"
      );

      return (
        "three leads, one per state: no choice -> " + JSON.stringify(chooser.slice(0, 48) + "…") +
        "; Anywhere -> names Tailscale and the account; At home only -> keeps the sentence that " +
        'is true of it. And 0 stray words for the place ("the office", "the house") across the ' +
        "whole sheet, read with every screen's markup in the DOM."
      );
    }
  );

  // ---- 9b. DEFECT 3.2 — the card says the same thing on the second open as on the first ----

  await run.check(
    "9b  the paired card's copy comes from the record: four combinations, and identical on reopen",
    async () => {
      // RAY'S CANDIDATE .11 DEFECT 3.2, REPRODUCED AND THEN PINNED.
      //
      // What he did: paired his ANDROID phone over Tailscale, read "There is nothing to remove
      // from your phone", closed the card, reopened it, and was told to open "Settings, then
      // General, then VPN and Device Management, then the RichOS profile" — an iOS menu, on an
      // Android phone, for a certificate that path never installs. Reproduced twice.
      //
      // The cause is that the copy was keyed off the sheet's `route`, which `open()` resets to
      // null on every open by design. So the SECOND OPEN is the whole test: same status, same
      // phone, and the card must say the same words.
      const combinations = [
        {
          via: "tailnet",
          platform: "android",
          name: "Android phone",
          must: [/nothing to remove from your phone/i, /Tailscale name/],
          mustNot: [/VPN & Device Management/, /Remove Profile/, /Settings, then General/],
          limit: true,
        },
        {
          via: "tailnet",
          platform: "ios",
          name: "iPhone",
          must: [/nothing to remove from your phone/i],
          mustNot: [/VPN & Device Management/, /Remove Profile/],
          limit: true,
        },
        {
          via: "home",
          platform: "ios",
          name: "iPhone",
          must: [/VPN & Device Management/, /Remove Profile/],
          mustNot: [/nothing to remove from your phone/i],
          limit: false,
        },
        {
          via: "home",
          platform: "android",
          name: "Android phone",
          // An Android phone on the home path never took a profile: what this Mac serves at the
          // trust endpoint is an Apple `.mobileconfig` and nothing else. So it must not be sent
          // to an iOS menu, and it must not be told a menu path nobody here verified either.
          must: [/nothing RichOS put on your Android phone to remove/i],
          mustNot: [/VPN & Device Management/, /Remove Profile/, /Settings, then General/],
          limit: false,
        },
        {
          // THE FIFTH: a record written before either field existed. It must say it does not
          // know rather than fall back to one of the four — the defect was a default stated as
          // a fact, and a default in here would be the same defect one layer down.
          via: "",
          platform: "",
          name: "iPhone",
          must: [/did not record which way it connected/i, /Pair it again/],
          mustNot: [/VPN & Device Management/, /nothing to remove from your phone/i],
          limit: false,
        },
      ];

      const seen = [];
      for (const combination of combinations) {
        const page = await openSheet(browser, "dark", {
          phonePaired: true,
          phonePairedVia: combination.via,
          phonePlatform: combination.platform,
        });
        // WHAT IS ON THE SCREEN, NOT WHAT IS IN THE MARKUP. The forget note is read by
        // gathering every VISIBLE paragraph in the paired card that is about forgetting,
        // rather than by one element id — so this check measures the copy a person reads and
        // keeps measuring it whether that copy lives in one node or in two. Run against the
        // build Ray walked it fails on the words, which is the defect, rather than on a
        // missing id, which would only be a rename.
        const read = async () =>
          page.evaluate(() => {
            const visible = (node) => node.offsetParent !== null || !node.hidden;
            const notes = [...document.querySelectorAll("#phone-paired p")]
              .filter((n) => visible(n) && /Forgetting it here/.test(n.textContent || ""))
              .map((n) => (n.textContent || "").replace(/\s+/g, " ").trim());
            const limit = [...document.querySelectorAll("#phone-paired p")].filter(
              (n) => visible(n) && /signed in to Tailscale/.test(n.textContent || "")
            );
            return {
              heading: document
                .getElementById("phone-paired")
                .textContent.replace(/\s+/g, " ")
                .trim()
                .slice(0, 40),
              notes: notes,
              limitShown: limit.length > 0,
            };
          });
        const first = await read();
        // CLOSE AND REOPEN — the exact sequence that produced the defect on screen.
        await page.click("#phone-close");
        // `state: "hidden"` — the default waits for VISIBLE, and a hidden sheet never is.
        await page.waitForSelector("#phone-sheet", { state: "hidden" });
        await page.click("#set-btn");
        await page.click("#set-phone-open");
        await page.waitForSelector("#phone-sheet:not([hidden])");
        const second = await read();
        await page.close();

        const where = combination.via + ":" + combination.platform;
        assertEqual(
          second,
          first,
          "reopening the paired card for the SAME phone (" + where + ") changed what it says. " +
            "That is defect 3.2: the copy is being derived from something the sheet forgets on " +
            "open instead of from the device record."
        );
        // EXACTLY ONE forget paragraph may be on screen. Two visible paragraphs about the
        // same act is its own defect and the reason this is one node now.
        assertEqual(
          first.notes.length,
          1,
          where + " shows " + first.notes.length + " visible paragraph(s) about forgetting the " +
            "phone, and exactly one is the right number: " + JSON.stringify(first.notes)
        );
        const note = first.notes[0];
        for (const pattern of combination.must) {
          assert(
            pattern.test(note),
            where + " is missing " + pattern + " — it says: " + JSON.stringify(note)
          );
        }
        for (const pattern of combination.mustNot) {
          assert(
            !pattern.test(note),
            where + " shows copy that belongs to another combination (" + pattern + "): " +
              JSON.stringify(note)
          );
        }
        // The name comes last of the three, deliberately: it is the one assertion that
        // depends on the harness modeling the right phone, and a failure there would mask the
        // copy failures above, which are the defect.
        assert(
          first.heading.startsWith(combination.name + " is paired"),
          "the card does not name the phone it is talking about (" + where + "): " + first.heading
        );
        assertEqual(
          first.limitShown,
          combination.limit,
          "the Tailscale limit line is on the wrong combination (" + where + ")"
        );
        seen.push(where + (first.limitShown ? " +limit" : ""));
      }
      return (
        combinations.length + " path x platform combination(s) read off the device record and " +
        "identical on a second open: " + seen.join(", ") + ". The reopen is the measurement — " +
        "before this, every reopen drew the home path's iOS profile-removal steps whatever the " +
        "phone was."
      );
    }
  );

  // ---- 11-16. CEO §61.1: the identity trap, made crystal-clear -----------------------------
  //
  // His ruling, verbatim: *"this barrier or I would call it stupidity would need to be made
  // ABSOLUTELY UBER MEGA SUPER CRYSTAL-CLEAR to ever user of RichOS"*. What he hit on his own
  // devices: Tailscale has no email-and-password sign-in; the account IS the network; he signed in
  // with Apple on the Mac and Google on the Android, got two networks that cannot see each other,
  // and reinstalled Tailscale on the Android THREE TIMES looking for a "connect to Mac" step that
  // does not exist.
  //
  // None of the four checks below could have been written before this run: `mock.js` reported no
  // `tailnet` at all, so every Tailscale screen was unreachable in a browser.

  /// Open the sheet and take the Anywhere route, which is where §61.1's flow begins.
  ///
  /// It also reads the identity screen when one is up, because every screen after it is BEHIND
  /// it — which is the property check 11 is about, and the reason every other check has to pass
  /// through it to reach anything.
  async function takeTheTailscaleRoute(theme, tailnet) {
    const page = await openSheet(browser, theme, { phoneTailnet: tailnet });
    await page.waitForSelector("#phone-route:not([hidden])");
    await page.click("#phone-route-anywhere");
    if (await page.isVisible("#phone-identity")) await page.click("#phone-identity-ok");
    return page;
  }

  await run.check("11  the identity trap is stated BEFORE the download step, and it states all five things", async () => {
    const page = await openSheet(browser, "dark", { phoneTailnet: { state: "absent" } });
    await page.waitForSelector("#phone-route:not([hidden])");
    await page.click("#phone-route-anywhere");
    const shown = await page.evaluate(() => ({
      identity: !document.getElementById("phone-identity").hidden,
      wait: !document.getElementById("phone-ts-wait").hidden,
      text: document.getElementById("phone-identity").textContent.replace(/\s+/g, " "),
      heading: document.querySelector("#phone-identity .phone-step-title").textContent,
    }));
    // FIRST, and that is the whole point: by the time somebody is on the download screen the next
    // thing they do is create the account, inside somebody else's sign-in sheet.
    assert(shown.identity, "picking Anywhere went straight past the identity screen");
    assert(!shown.wait, "the download screen is up at the same time as the identity screen");
    assert(
      /no password/i.test(shown.heading),
      "the heading does not state the trap: " + JSON.stringify(shown.heading)
    );
    // The five things §61.1 requires, each one checked for the thing it actually says.
    const required = [
      [/no username and password/i, "that Tailscale has no username and password"],
      [/Google.*Apple.*Microsoft.*GitHub/i, "the four sign-in providers it offers instead"],
      [/identity <?is>? your private network|identity is your private network/i, "that the identity IS the network"],
      [/same/i, "that both devices must use the same one"],
      [/new Google account|only for this/i, "the dedicated-identity way out for somebody who keeps them apart"],
    ];
    for (const [pattern, what] of required) {
      assert(pattern.test(shown.text), "the identity screen never says " + what + ": " + shown.text);
    }
    // And his own loop, named: reinstalling is what he did three times, and it never helps.
    assert(
      /reinstalling tailscale will not help/i.test(shown.text),
      "the screen does not say that reinstalling will not help, which is the thing he did three times"
    );
    // AND THE DOWNLOAD SCREEN IS WHAT IS BEHIND IT — a warning that leads nowhere is a dead end.
    const after = await page.evaluate(() => {
      document.getElementById("phone-identity-ok").click();
      return new Promise((resolve) =>
        setTimeout(
          () =>
            resolve({
              identity: !document.getElementById("phone-identity").hidden,
              heading: document.getElementById("phone-ts-heading").textContent,
            }),
          200
        )
      );
    });
    await page.close();
    assert(!after.identity, "the identity screen does not go away when it has been read");
    assertEqual(
      after.heading,
      "Install Tailscale on this Mac",
      "reading the warning does not lead to the download step"
    );
    return "the identity screen precedes the download step and states all five things, plus the reinstall loop";
  });

  await run.check("12  once the Mac is signed in, the screen names the provider and the login name it used", async () => {
    const page = await takeTheTailscaleRoute("dark", {
      state: "ready",
      name: "mm1.tail9a3b2.ts.net",
      origin: "https://mm1.tail9a3b2.ts.net:8443",
      account: "Google as someone@gmail.com",
    });
    const shown = await page.evaluate(() => ({
      identity: !document.getElementById("phone-identity").hidden,
      ready: !document.getElementById("phone-ts-ready").hidden,
      name: document.getElementById("phone-ts-name").textContent.trim(),
      account: document.getElementById("phone-ts-account").textContent.trim(),
    }));
    await page.close();
    // The warning has done its job the moment detection can name the account, and it does not
    // come back: from here on the screens say WHICH one rather than warning about the choice.
    assert(!shown.identity, "the identity warning is still up after the account is known");
    assert(shown.ready, "the ready screen is not shown for a ready Mac");
    assertEqual(shown.name, "mm1.tail9a3b2.ts.net", "the tailnet name is not shown verbatim");
    assertEqual(
      shown.account,
      "You signed in with Google as someone@gmail.com. Use exactly this on your phone.",
      "the Mac does not name the provider and login name it signed in with"
    );
    return "the ready screen names the machine and " + JSON.stringify(shown.account);
  });

  await run.check("13  the phone step opens with the why, with that account filled in", async () => {
    // Reached the way a person reaches it: the route, the ready screen, then "Set my phone up".
    // A preset that starts mid-pairing would land on the HOME screen, because the route is not
    // remembered across an open — Urban's §1, and `phone.js`'s own `route = null` on open.
    const page = await takeTheTailscaleRoute("dark", {
      state: "ready",
      name: "mm1.tail9a3b2.ts.net",
      origin: "https://mm1.tail9a3b2.ts.net:8443",
      account: "Apple as someone@icloud.com",
    });
    await page.click("#phone-ts-start");
    await page.waitForSelector("#phone-ts-steps:not([hidden])");
    const shown = await page.evaluate(() => {
      const steps = document.getElementById("phone-ts-steps");
      const why = document.getElementById("phone-ts-why");
      const nodes = [...steps.querySelectorAll("p, ol")];
      return {
        why: why.textContent.replace(/\s+/g, " "),
        step2: document.getElementById("phone-ts-step2").textContent.replace(/\s+/g, " "),
        whyIsFirst: nodes.indexOf(why) === 0,
      };
    });
    await page.close();
    assert(shown.whyIsFirst, "the why does not come first on the phone step, so the instruction arrives bare");
    assert(
      /private network/i.test(shown.why),
      "the why does not say the account is the network: " + shown.why
    );
    assert(
      shown.why.includes("Apple as someone@icloud.com"),
      "the why does not name the provider and address the Mac used: " + shown.why
    );
    assert(
      shown.step2.includes("Apple as someone@icloud.com"),
      "step 2 does not name the account either: " + shown.step2
    );
    return "the phone step opens with the why and names " + JSON.stringify("Apple as someone@icloud.com");
  });

  await run.check("14  a phone that is registered and switched off is told to switch it on, not to sign in again", async () => {
    // MEASURED ON THIS MAC, 2026-09-19: the CEO's Android was in the daemon's Peer map TWICE, one
    // stale registration per reinstall, and both were `"Online": false` because Tailscale on the
    // phone was switched off. Read as "your phone is on this network", that state sends somebody
    // who has done everything right back to check their identity.
    const off = await takeTheTailscaleRoute("dark", {
      state: "ready",
      name: "mm1.tail9a3b2.ts.net",
      origin: "https://mm1.tail9a3b2.ts.net:8443",
      account: "Google as someone@gmail.com",
      phone: "HONOR X6b",
      phoneOnline: false,
    });
    const offLine = (await off.textContent("#phone-ts-peer-ready")).replace(/\s+/g, " ").trim();
    await off.close();
    assert(
      /switched off on it/i.test(offLine) && /Turn it on in the Tailscale app/i.test(offLine),
      "a registered, offline phone is not told to switch Tailscale on: " + JSON.stringify(offLine)
    );
    assert(
      !/sign in with/i.test(offLine),
      "an offline phone is told to sign in again, which is the wrong fix: " + JSON.stringify(offLine)
    );

    const on = await takeTheTailscaleRoute("dark", {
      state: "ready",
      name: "mm1.tail9a3b2.ts.net",
      origin: "https://mm1.tail9a3b2.ts.net:8443",
      account: "Google as someone@gmail.com",
      phone: "HONOR X6b",
      phoneOnline: true,
    });
    const onLine = (await on.textContent("#phone-ts-peer-ready")).replace(/\s+/g, " ").trim();
    await on.close();
    assert(
      /is on this network\.?$/i.test(onLine),
      "a live phone is not simply reported as present: " + JSON.stringify(onLine)
    );
    return "offline says " + JSON.stringify(offLine) + "; online says " + JSON.stringify(onLine);
  });

  await run.check("15  with no phone at all, the screen waits and then names the account to use", async () => {
    // The mismatch itself. A phone signed in to a DIFFERENT identity is in a different tailnet and
    // appears nowhere at all, so absence is the evidence — but only after a wait, because before
    // that "not here yet" and "still signing in" are the same thing.
    const page = await takeTheTailscaleRoute("dark", {
      state: "ready",
      name: "mm1.tail9a3b2.ts.net",
      origin: "https://mm1.tail9a3b2.ts.net:8443",
      account: "Google as someone@gmail.com",
    });
    const waiting = (await page.textContent("#phone-ts-peer-ready")).trim();
    assert(
      /waiting for your phone/i.test(waiting),
      "before the grace window the screen already calls it a mistake: " + JSON.stringify(waiting)
    );

    // THE CLOCK IS MOVED, NOT WAITED OUT. `setSystemTime` changes what `Date.now()` answers and
    // triggers no timers, so the sheet's own two-second poll is what redraws — the same path a
    // real minute would take, without spending one.
    await page.clock.setSystemTime(Date.now() + 61000);
    await page.waitForFunction(
      () => !/waiting/i.test(document.getElementById("phone-ts-peer-ready").textContent),
      { timeout: 15000 }
    );
    const said = (await page.textContent("#phone-ts-peer-ready")).replace(/\s+/g, " ").trim();
    await page.close();
    assert(
      /not on this network yet/i.test(said),
      "after the wait the screen does not say the phone is absent: " + JSON.stringify(said)
    );
    assert(
      said.includes("Google as someone@gmail.com"),
      "the mismatch line does not name the account to sign in with: " + JSON.stringify(said)
    );
    return "waits with " + JSON.stringify(waiting) + ", then says " + JSON.stringify(said);
  });

  await run.check("16  each link has a control AND its address in writing, and the control asks for that address", async () => {
    // Urban's §2: "a control that opens somewhere the user cannot see first is a control that asks
    // for trust it has not earned". So both, on every screen that names an address — and the
    // written-out form is also the fallback for a Mac where the opener does not work.
    const cases = [
      ["absent", "Get Tailscale", "tailscale.com/download/mac"],
      ["needs-sign-in", "Open Tailscale", "Tailscale.app"],
      ["certificates-off", "Open the Tailscale console", "console.tailscale.com/admin/dns"],
    ];
    const seen = [];
    for (const [state, label, target] of cases) {
      const page = await takeTheTailscaleRoute("dark", { state, name: "mm1.tail9a3b2.ts.net" });
      const shown = await page.evaluate(() => ({
        label: document.getElementById("phone-ts-open").textContent.trim(),
        visible: !document.getElementById("phone-ts-open").hidden,
        url: document.getElementById("phone-ts-url").textContent.trim(),
        urlVisible: !document.getElementById("phone-ts-url").hidden,
      }));
      assertEqual(shown.label, label, "wrong control label for " + state);
      assert(shown.visible, "the control is hidden on " + state);
      await page.click("#phone-ts-open");
      const asked = await page.evaluate(() => window.__RICHOS_OPENED__ || []);
      await page.close();
      assertEqual(asked, [target], "the control on " + state + " asked to open the wrong thing");
      // The sign-in screen names no address, because what it opens is an app the user already has.
      if (target !== "Tailscale.app") {
        assert(shown.urlVisible && shown.url === target, "the address is not written out on " + state);
      }
      seen.push(label + " -> " + target);
    }
    return seen.join("; ");
  });

  // ---- defect B: the expired card carries no instruction about things that are gone -------

  await run.check("18  an expired code takes its own instructions with it", async () => {
    // Ray's candidate-.12 defect B, frame 19: after the code ran out the card still read "Your
    // phone will show six words. They have to be THESE SIX, in this order ... tap Cancel and
    // tell me" — with no six words under it and no Cancel button anywhere in the sheet. Two
    // things a person is asked to do that are not there. The heading above it and the words
    // below it were already cleared with the code; this paragraph was missed.
    const live = await openSheet(browser, "dark", { phonePairing: true });
    await live.waitForSelector("#phone-pairing:not([hidden])");
    const onLive = await live.evaluate(() => {
      const el = document.getElementById("phone-words-note");
      return { present: !!el && !el.hidden, text: el ? el.textContent.replace(/\s+/g, " ").trim() : "" };
    });
    await live.close();

    const gone = await openSheet(browser, "dark", { phonePairingExpired: true });
    await gone.waitForSelector("#phone-expired:not([hidden])");
    const onExpired = await gone.evaluate(() => {
      const el = document.getElementById("phone-words-note");
      const panel = document.querySelector("#phone-sheet .overlay-panel");
      return {
        shown: !!el && !el.hidden && el.offsetParent !== null,
        words: (document.getElementById("phone-words") || {}).textContent || "",
        panel: panel ? panel.innerText : "",
      };
    });
    await gone.close();

    assert(onLive.present, "the sentence has to be there while there IS a code to check");
    assert(!onExpired.shown, "THE DEFECT: the six-words instruction survived the code it is about");
    assert(!/these six/i.test(onExpired.panel), "the expired card still says \"these six\"");
    // AND THE CONTROL IT NAMES EXISTS. The sheet has `Show me another code` and `Close`; there
    // has never been a Cancel button in it.
    assert(
      !/tap Cancel/i.test(onLive.text),
      `the sentence names a control this sheet does not have: ${JSON.stringify(onLive.text)}`
    );
    return `live: ${JSON.stringify(onLive.text.slice(0, 60))}…; expired: the sentence is gone and the words are ${JSON.stringify(onExpired.words)}`;
  });

  await run.check("10  nothing on the sheet threw, in either theme", async () => {
    const errors = [];
    let combinations = 0;
    for (const theme of ["dark", "light"]) {
      for (const preset of [{ phonePairing: true }, { phonePaired: true }]) {
        const page = await openSheet(browser, theme, preset);
        await page.close();
        errors.push(...page.__errors);
        combinations += 1;
      }
      // AND THE FOUR TAILSCALE SCREENS, which no theme sweep reached until this run because the
      // harness reported no tailnet at all.
      for (const tailnet of [
        { state: "absent" },
        { state: "needs-sign-in" },
        { state: "certificates-off", name: "mm1.tail9a3b2.ts.net" },
        {
          state: "ready",
          name: "mm1.tail9a3b2.ts.net",
          origin: "https://mm1.tail9a3b2.ts.net:8443",
          account: "Google as someone@gmail.com",
        },
      ]) {
        const page = await takeTheTailscaleRoute(theme, tailnet);
        await page.close();
        errors.push(...page.__errors);
        combinations += 1;
      }
    }
    assertEqual(errors, [], "the pairing screen raised a page error or logged to console.error");
    return combinations + " combination(s) of theme and state opened with no page error and nothing on console.error";
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
