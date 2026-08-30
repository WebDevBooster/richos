// THE RAW-RETENTION WINDOW AS A SETTING — techy-mode design §7.2, open-items 1.4.
//
// §7.2 IS THE CEO'S QUESTION AND NOTHING IN THIS SUITE ANSWERS IT. *"How long do raw
// payloads survive?"* stays open. What this branch changed is the COST of each of his
// answers: "14 days" was `RAW_RETENTION_DAYS` in `journal.rs` and "forever" was a
// developer's edit, and a question whose status quo is the only free answer is not really
// open. So the thing under test here is not a window — it is whether a person can change one.
//
// THE COMPLETION CRITERION IS OBSERVABLE, AND HALF OF IT IS NOT IN THIS FILE. "Set the window
// to three different values including forever, run eviction against a journal with entries of
// known ages, and show what survived" is a claim about eviction, and eviction is Rust. It is
// proven at `crates/richos-core/src/journal.rs`, by
// `the_survival_counts_at_four_windows` (6/6, 6/6, 3/6, 1/6 raw shards kept at forever,
// 90 days, 14 days and 0 days — and 6/6 RECORDS still rendering at every one of them) and by
// `the_shipping_default_is_exactly_the_two_constants_it_replaced`, which runs the old
// two-`u64` call and the new one over two identical journals and compares the survivors.
// Nothing here re-states those numbers: a browser suite asserting a count it got from a mock
// would prove the mock.
//
// WHAT IS HERE IS THE HALF A BROWSER CAN PROVE: that the control exists where a person would
// look, that the three choices on screen are exactly the three the Rust accepts, that the
// labels do not lie about the numbers behind them, that what is selected came from the store
// rather than from a local cache, and — the one that matters most —
//
//   THAT TIGHTENING THE WINDOW SAYS WHAT IT REMOVED.
//
// `evict_raw` is an `unlink`. Nothing else in this product would ever mention it. A CEO who
// tightens the window and is told nothing finds an empty row weeks later and cannot connect
// it to anything he did, and that is the failure this control is most likely to ship with,
// because it looks exactly like success. Check 4 is that sentence.
//
// EVERY CHECK WAS RUN RED ONCE by breaking the shipped source; the mutations are listed at
// the bottom of this file.
//
// Run: node retention.js   (or `npm test` for every suite in this directory)
//      RICHOS_PLAYWRIGHT=/path/to/node_modules/playwright node retention.js

"use strict";

const fs = require("fs");
const path = require("path");
const { loadPlaywright, shot, createRun, assert, assertEqual, UI_DIR } = require("./lib/harness");

const APP = "file://" + path.join(UI_DIR, "index.html");
const CORE = path.resolve(UI_DIR, "..", "crates", "richos-core", "src");
const CONFIG_RS = fs.readFileSync(path.join(CORE, "config.rs"), "utf8");
const JOURNAL_RS = fs.readFileSync(path.join(CORE, "journal.rs"), "utf8");
const MOCK_JS = fs.readFileSync(path.join(UI_DIR, "mock.js"), "utf8");
const SHOTS = "../shots-7-2";

/// The choices `RetentionChoice::parse` really accepts, read out of the Rust rather than
/// typed here. A choice added to the menu and not to the parser (or the reverse) reaches this
/// file as a failing check instead of as a radio that silently does nothing.
function rustChoices() {
  // Anchored on the IMPL, not on the signature: `Assertiveness::parse` in the same file has
  // a byte-identical signature and comes first, and the first version of this function read
  // that one and returned nothing — an EMPTY inventory, which the check below refuses.
  const impl = CONFIG_RS.indexOf("impl RetentionChoice {");
  assert(impl >= 0, "no `impl RetentionChoice` in config.rs");
  const body = CONFIG_RS.slice(impl);
  return [...body.matchAll(/"([a-z-]+)" => Some\(RetentionChoice::/g)].map((m) => m[1]).sort();
}

/// A `pub const NAME: u64 = <n>;` read off disk. The labels on screen say "two weeks" and
/// "three months"; these are the numbers those words are standing in for.
function rustConst(src, name) {
  const m = src.match(new RegExp("pub const " + name + ": u64 = ([0-9_]+)"));
  assert(m, "no such const: " + name);
  return Number(m[1].replace(/_/g, ""));
}

async function openApp(browser) {
  const page = await browser.newPage({ viewport: { width: 1400, height: 950 } });
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => {
    if (m.type() === "error") errors.push("console: " + m.text());
  });
  await page.goto(APP);
  await page.waitForSelector(".nav-thread", { state: "attached" });
  page.__errors = errors;
  return page;
}

/// Open the gear. The popover re-reads the window on open, so this is also the trigger that
/// makes a config.json edited behind the app's back show up.
async function openSettings(page) {
  await page.click("#rail-settings");
  await page.waitForSelector("#assertiveness-popover", { state: "visible" });
  await page.waitForTimeout(120);
}

async function closeSettings(page) {
  await page.click("#rail-settings");
  await page.waitForTimeout(60);
}

/// Which retention radio is checked, or null when none is — which is a real state, not a bug.
async function selected(page) {
  return page.$eval("#assertiveness-popover", (pop) => {
    const on = pop.querySelector('input[name="raw-retention"]:checked');
    return on ? on.value : null;
  });
}

const hint = (page) => page.textContent("#retention-hint");

async function main() {
  const { webkit } = loadPlaywright();
  const browser = await webkit.launch();
  const run = createRun("the raw-retention window as a setting (§7.2) — through the real shell");

  // ---- 1. the control is where a person would look -------------------------------------
  await run.check("1. the window is a control behind the gear, not a constant in a source file", async () => {
    const page = await openApp(browser);
    // Nothing on the conversation surface: §7.3's rule for techy mode applies to its
    // retention too — the calm view gains no affordance, and this is one line in Settings.
    assertEqual(await page.isVisible("#retention-hint"), false, "nothing before the gear is pressed");
    await openSettings(page);
    const labels = await page.$$eval('#assertiveness-popover input[name="raw-retention"]', (els) =>
      els.map((e) => ({ value: e.value, label: e.parentElement.textContent.trim(), enabled: !e.disabled }))
    );
    assertEqual(labels.length, 3, "three choices");
    assert(labels.every((l) => l.enabled), "and every one of them settable");
    assertEqual(
      labels.map((l) => l.label),
      ["For two weeks", "For three months", "Forever"],
      "the two ends of §7.2 and one point between them"
    );
    assert(await page.isVisible("#retention-hint"), "with a sentence saying what the choice means");
    await shot(page, SHOTS + "/7-2-01-the-window-is-a-setting");
    assertEqual(page.__errors, [], "no page errors");
    await page.close();
    return labels.map((l) => l.value).join(" / ");
  });

  // ---- 2. the three on screen are the three the Rust accepts ----------------------------
  await run.check("2. every choice on screen is a choice the backend takes, and vice versa", async () => {
    // A radio whose value `RetentionChoice::parse` does not accept is a control that looks
    // like it works and silently does nothing — the command refuses it, `invokeQuiet`
    // swallows the refusal, and the surface re-reads the unchanged store. Nothing on screen
    // would say so. Both sides are read off disk.
    const page = await openApp(browser);
    await openSettings(page);
    const onScreen = (await page.$$eval('#assertiveness-popover input[name="raw-retention"]', (els) =>
      els.map((e) => e.value)
    )).sort();
    const inRust = rustChoices();
    assert(inRust.length > 0, "EMPTY INVENTORY: no choices parsed out of config.rs");
    assertEqual(onScreen, inRust, "the radio values and RetentionChoice::parse");
    // And the harness's own model, so the checks below are not testing a third vocabulary.
    const inMock = [...MOCK_JS.slice(MOCK_JS.indexOf("const RETENTION_WINDOWS")).matchAll(
      /^\s{4}"?([a-z-]+)"?: \{ ageDays/gm
    )].map((m) => m[1]).sort();
    assertEqual(inMock, inRust, "mock.js's window table");
    // `custom` is a DESCRIPTION of a hand-edited file and never an instruction, so it must
    // not be on the menu at either end.
    assert(!inRust.includes("custom"), "custom is not parseable");
    assert(!onScreen.includes("custom"), "and not offered");
    await page.close();
    return inRust.join(" / ");
  });

  // ---- 3. the labels do not lie about the numbers behind them ---------------------------
  await run.check("3. `two weeks` is 14 days and `three months` is 90, read off the Rust", async () => {
    // The labels hide the arithmetic on purpose — asking a CEO to predict "90 days OR 2 GB,
    // whichever binds first" is asking him to hold the implementation in his head. Hiding it
    // is only honest if the words are true, and the words are in a different file from the
    // numbers.
    const days = rustConst(JOURNAL_RS, "RAW_RETENTION_DAYS");
    const months = rustConst(CONFIG_RS, "THREE_MONTHS_DAYS");
    assertEqual(days, 14, "'two weeks'");
    assertEqual(months, 90, "'three months'");
    const page = await openApp(browser);
    await openSettings(page);
    await page.click('input[name="raw-retention"][value="two-weeks"]');
    await page.waitForTimeout(150);
    assert((await hint(page)).includes("Kept for " + days + " days"), "the sentence carries the real number");
    await page.click('input[name="raw-retention"][value="three-months"]');
    await page.waitForTimeout(150);
    assert((await hint(page)).includes("Kept for " + months + " days"), "and so does the other one");
    await page.close();
    return days + " days / " + months + " days, from journal.rs and config.rs";
  });

  // ---- 4. THE ONE THAT MATTERS: a delete that says what it deleted ----------------------
  await run.check("4. tightening the window says what it removed, in the same breath", async () => {
    // `evict_raw` is an `unlink` and nothing else in this product would ever mention it. A
    // CEO who tightens the window and is told nothing finds an empty row weeks later and
    // cannot connect it to anything he did. The harness's store holds five raw day-shards at
    // 120/60/20/9/0 days old under a `forever` window; two weeks takes the first three.
    const page = await openApp(browser);
    await openSettings(page);
    assertEqual(await selected(page), "forever", "the store's answer, before he touches anything");

    await page.click('input[name="raw-retention"][value="two-weeks"]');
    await page.waitForTimeout(200);
    const said = await hint(page);
    assert(said.includes("Removed the stored output from 3 earlier days"), "it counted, out loud: " + said);
    assert(
      said.includes("The records are still there; their output is not."),
      "and it said which half went — Tier A is never evicted at any setting: " + said
    );
    await shot(page, SHOTS + "/7-2-02-a-delete-that-says-what-it-deleted");

    // A second, LOOSER change must not claim a removal it did not make — and must not
    // pretend the bytes came back either.
    await page.click('input[name="raw-retention"][value="forever"]');
    await page.waitForTimeout(200);
    const after = await hint(page);
    assert(!after.includes("Removed"), "nothing removed, nothing claimed: " + after);
    assertEqual(after.includes("Nothing is ever removed."), true, "and the window reads as forever");
    assertEqual(page.__errors, [], "no page errors");
    await page.close();
    return "3 shards, counted on screen; the reverse change claims nothing";
  });

  // ---- 5. the cost of "forever" is on screen before he picks it -------------------------
  await run.check("5. the sentence states both limits and what the store costs today", async () => {
    // "Keep everything" is only a real choice if the person making it can see the bill.
    // `retainedBytes` comes off directory metadata — no payload is parsed to answer it.
    const page = await openApp(browser);
    await openSettings(page);
    const forever = await hint(page);
    assert(forever.startsWith("Nothing is ever removed."), "forever states itself plainly: " + forever);
    assert(/Using [\d.]+ MB now\./.test(forever), "and what it is costing: " + forever);

    await page.click('input[name="raw-retention"][value="three-months"]');
    await page.waitForTimeout(200);
    const bounded = await hint(page);
    // BOTH axes. A day window and a byte ceiling are different limits and either can bind
    // first; a sentence naming only the one he picked would be a promise the other can break.
    assert(bounded.includes("Kept for 90 days"), "the axis he chose: " + bounded);
    assert(bounded.includes("GB of output"), "the axis he did not: " + bounded);
    assert(bounded.includes("whichever comes first"), "and which one wins: " + bounded);
    await page.close();
    return bounded;
  });

  // ---- 6. what is selected came from the store, never from a local guess ----------------
  await run.check("6. the store is the only answer — a click never becomes a second one", async () => {
    // The dial and the splash switch keep a `localStorage` mirror so something can paint
    // before the round trip resolves. This control governs a DELETE, and a local cache of a
    // delete setting is a second answer that can disagree with the store — after which the
    // popover is showing him a window that is not the one his machine will evict against.
    //
    // So: nothing is written locally, and when the store's answer and the last click
    // disagree, the STORE wins on the next open. (The disagreement is manufactured by
    // substituting the reply, the same way check 7 does; the renderer is the shipped one.)
    const page = await openApp(browser);
    await openSettings(page);
    await page.click('input[name="raw-retention"][value="three-months"]');
    await page.waitForTimeout(200);
    assertEqual(await selected(page), "three-months", "the click landed");
    const keys = await page.evaluate(() => Object.keys(window.localStorage).filter((k) => /retention/i.test(k)));
    assertEqual(keys, [], "and wrote nothing about retention to localStorage");

    await page.evaluate(() => {
      const real = window.RichBridge.invoke.bind(window.RichBridge);
      window.RichBridge.invoke = (cmd, args) =>
        cmd === "raw_retention"
          ? Promise.resolve({ choice: "two-weeks", ageDays: 14, totalBytes: 2147483648, retainedBytes: 4200000, evicted: 0 })
          : real(cmd, args);
    });
    await closeSettings(page);
    await openSettings(page);
    assertEqual(await selected(page), "two-weeks", "the store wins over the click, every time the popover opens");
    assert((await hint(page)).includes("Kept for 14 days"), "and the sentence came with it");
    assertEqual(page.__errors, [], "no page errors");
    await page.close();
    return "no local mirror; the popover re-reads on open and the store wins";
  });

  // ---- 7. a window nobody put on the menu describes itself ------------------------------
  await run.check("7. a hand-edited window is reported as itself, with no radio rounded on", async () => {
    // `config.json` is a file, and someone will edit it. Rounding a 45-day window onto the
    // nearest button would misreport his setting on the one screen whose job is to state it,
    // and the next click on ANY other control would write the rounded value back over his.
    // The backend answer is substituted here (the renderer under test is still the shipped
    // `main.js`; only the store's reply changes, which is all `mock.js` ever was).
    const page = await openApp(browser);
    await page.evaluate(() => {
      const real = window.RichBridge.invoke.bind(window.RichBridge);
      window.RichBridge.invoke = (cmd, args) =>
        cmd === "raw_retention"
          ? Promise.resolve({
              choice: "custom",
              ageDays: 45,
              totalBytes: "forever",
              retainedBytes: 65_800_000,
              evicted: 0,
            })
          : real(cmd, args);
    });
    await openSettings(page);
    assertEqual(await selected(page), null, "no radio is checked over a window none of them means");
    const said = await hint(page);
    assert(said.includes("Kept for 45 days"), "the window it actually is: " + said);
    assert(said.includes("No size limit."), "including the axis with no limit: " + said);
    assert(said.includes("Set by hand in config.json"), "and why nothing is selected: " + said);
    await shot(page, SHOTS + "/7-2-03-a-window-that-is-on-no-menu");
    await page.close();
    return said;
  });

  // ---- 8. a refused change leaves the surface on the store's answer ---------------------
  await run.check("8. a choice the backend refuses never leaves the radio claiming it", async () => {
    // The refusal arm is real — `set_raw_retention` rejects anything `RetentionChoice::parse`
    // does not accept, and writes and evicts NOTHING, because the failure mode of a bad
    // argument to a command that deletes has to be "did nothing". No path in the shipped UI
    // reaches it (check 2 is why), so it is driven here by putting a value on the radio that
    // the product never puts there.
    const page = await openApp(browser);
    await openSettings(page);
    const before = await selected(page);
    const hintBefore = await hint(page);
    await page.evaluate(() => {
      const input = document.querySelector('input[name="raw-retention"][value="three-months"]');
      input.value = "custom";
      input.checked = true;
      input.dispatchEvent(new Event("change", { bubbles: true }));
    });
    await page.waitForTimeout(250);
    assertEqual(await selected(page), before, "the surface went back to what the store holds");
    assertEqual(await hint(page), hintBefore, "and claims no window it did not get");
    assertEqual(page.__errors, [], "a refusal is not a page error");
    await page.close();
    return "refused, re-read, nothing claimed";
  });

  await browser.close();
  const failed = run.report();
  process.exit(failed ? 1 : 0);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

// =========================================================================================
// THE MUTATIONS — every check above was run RED once, by breaking the SHIPPED source
// =========================================================================================
//
//  1  index.html: delete the three `input[name="raw-retention"]` labels -> check 1 fails on
//     "three choices" (0), and 2, 3, 4, 5, 6, 7 and 8 go with it. The setting stops being a
//     setting, which is the whole item.
//  2  config.rs `RetentionChoice::parse`: drop the `"three-months"` arm -> the radio is
//     still on screen and still does nothing visible; check 2 fails on the set comparison.
//     (This is the shape the check exists for: `invokeQuiet` swallows the refusal and the
//     surface re-reads the unchanged store, so a browser looking only at the DOM sees a
//     control that "worked".)
//  3  config.rs: `THREE_MONTHS_DAYS = 30` -> the label still says three months; check 3
//     fails on 90 and on the sentence. The label and the number live in different files,
//     which is exactly why this join is not optional.
//  4  main.js `renderRetention`: drop the `if (view.evicted > 0)` block -> the window still
//     tightens, three days of stored output still go, and NOTHING says so. Check 4 fails on
//     "Removed the stored output from 3 earlier days" and only check 4 — which is what makes
//     it the right mutation for this claim.
//  4b main.rs `set_raw_retention`: return `RetentionView::of(..., 0)` instead of the real
//     count (i.e. evict, then report nothing) -> same red, from the other side of the wire.
//  5  main.js `retentionWindowSentence`: return only the age clause for the two-axis case
//     -> check 5 fails on "GB of output". A sentence naming only the limit he picked is a
//     promise the other limit can break.
//  6  main.js: drop the `if (!open) syncRetentionFromBackend();` line from the gear's click
//     handler -> the popover keeps showing the last click and never notices the store
//     disagreeing (which is what a hand-edited config.json looks like); check 6 fails on
//     "two-weeks". Caching `view.choice` in localStorage and painting from it fails the
//     empty-keys half of the same check.
//  7  main.js `renderRetention`: `input.checked = input.value === (view.choice === "custom"
//     ? "two-weeks" : view.choice)` — i.e. round a custom window onto the nearest button ->
//     check 7 fails on `selected() === null`.
//  8  main.rs `set_raw_retention`: accept an unknown choice by falling back to
//     `RetentionChoice::TwoWeeks` instead of returning Err -> check 8 fails on both the
//     selection and the hint. A command that deletes must not guess at its argument.
//
// The Rust half of the criterion — the survival counts at four windows, and the proof that
// the default reproduces yesterday's behaviour — is in
// `crates/richos-core/src/journal.rs`; its mutations are recorded in the branch's commits.
