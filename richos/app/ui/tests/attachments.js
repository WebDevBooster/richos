// SCREENSHOTS AND FILES ON THE MAC COMPOSER — CEO ruling §86, 2026-09-24.
//
// "To stop using this terminal he has to be able to hand Rich a screenshot or a file in the
// app" (the brief, from `richos-hq/docs/plans/2026-09-24-daily-driver-readiness.md` §4 X3 and
// §6 step 3). The phone could; the Mac window could not. This suite drives the REAL composer
// (`index.html`, `main.js`, `attachments.js`) under WebKit against `mock.js`, whose attachment
// commands mirror `src-tauri/src/mac_attachments.rs` and whose sentences are joined to the Rust
// in check 7, so the two cannot drift apart silently.
//
// What the browser cannot prove, and where it is proved instead: that the bytes land in the
// conversation's folder and that Rich reads and describes them. The folder half is the Rust
// suite (`mac_attachments::tests`); the Rich half is the VM walk in richos-hq
// `docs/verification/2026-09-24-mac-drop/`.
//
// Run: node attachments.js

"use strict";

const fs = require("fs");
const path = require("path");
const {
  loadPlaywright,
  leaveHome,
  bootSettled,
  openThread,
  createRun,
  assert,
  assertEqual,
  rustSentenceAfter,
  UI_DIR,
} = require("./lib/harness");
const C = require("./lib/contrast");

const APP = "file://" + path.join(UI_DIR, "index.html");
const SRC = path.resolve(UI_DIR, "..", "src-tauri", "src");

/// Real magic bytes, so the mock's sniffing (and a reader of this file) sees real kinds.
const PNG = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52];
const PDF = Array.from(Buffer.from("%PDF-1.7\n%\xE2\xE3\xCF\xD3\n1 0 obj\n", "latin1"));

async function openApp(browser) {
  const page = await browser.newPage({ viewport: { width: 1400, height: 900 } });
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => {
    if (m.type() === "error") errors.push("console: " + m.text());
  });
  page.__errors = errors;
  await page.goto(APP);
  await leaveHome(page);
  await bootSettled(page);
  const picker = await page.evaluate(() => !document.getElementById("entity-picker").hidden);
  if (picker) {
    await page.keyboard.press("Escape");
    await page.waitForSelector("#entity-picker", { state: "hidden" });
  }
  await page.waitForFunction(() => !!window.RichAttachments);
  return page;
}

/// Paste files onto the composer the way WebKit delivers a paste: a `ClipboardEvent` whose
/// `clipboardData.files` carries them. `files` is `[{ name, type, bytes: number[] }]` or
/// `[{ name, type, size }]` for a file too large to build byte by byte in the test.
async function paste(page, files) {
  await page.focus("#input");
  await page.evaluate((list) => {
    const dt = new DataTransfer();
    for (const f of list) {
      const body = f.bytes ? new Uint8Array(f.bytes) : new Uint8Array(f.size);
      dt.items.add(new File([body], f.name, { type: f.type }));
    }
    const event = new ClipboardEvent("paste", { clipboardData: dt, bubbles: true, cancelable: true });
    document.getElementById("input").dispatchEvent(event);
  }, files);
}

async function drop(page, files) {
  return page.evaluate((list) => window.__RICHOS_MOCK__.dropFiles(list), files);
}

/// The tray as he sees it: one row per chip.
async function readTray(page) {
  return page.evaluate(() => ({
    trayHidden: document.getElementById("attach-tray").hidden,
    chips: [...document.querySelectorAll("#attach-list .attach-chip")].map((c) => ({
      name: c.querySelector(".attach-name").textContent,
      meta: c.querySelector(".attach-meta").textContent,
      remove: c.querySelector(".attach-remove").getAttribute("aria-label"),
      adding: c.classList.contains("is-adding"),
      thumb: !!c.querySelector(".attach-tile img"),
    })),
    note: document.getElementById("attach-note").hidden ? null : document.getElementById("attach-note").textContent,
  }));
}

async function readyChips(page, n) {
  await page.waitForFunction(
    (want) => {
      const chips = document.querySelectorAll("#attach-list .attach-chip");
      return chips.length === want && ![...chips].some((c) => c.classList.contains("is-adding"));
    },
    n,
    { timeout: 5000 }
  );
}

async function lastUserText(page) {
  return page.evaluate(() => {
    const all = document.querySelectorAll("#messages .tl-user-text");
    return all.length ? all[all.length - 1].textContent : null;
  });
}

async function sendAndWaitForBubble(page, marker) {
  await page.focus("#input");
  await page.keyboard.press("Enter");
  await page.waitForFunction(
    (m) => [...document.querySelectorAll("#messages .tl-user-text")].some((n) => n.textContent.includes(m)),
    marker,
    { timeout: 8000 }
  );
}

async function main() {
  const run = createRun("screenshots and files on the Mac composer (CEO §86)");
  const browser = await loadPlaywright().webkit.launch();

  await run.check("1. a pasted screenshot shows on the composer, and Send hands Rich the phone's block with his words", async () => {
    const page = await openApp(browser);
    const bubblesBefore = await page.locator("#messages .tl-user-text").count();
    await paste(page, [{ name: "Screenshot 2026-09-24 at 10.02.11.png", type: "image/png", bytes: PNG }]);
    await readyChips(page, 1);
    const tray = await readTray(page);
    assertEqual(tray.trayHidden, false, "the tray did not appear");
    assertEqual(tray.chips[0].name, "Screenshot 2026-09-24 at 10.02.11.png", "the chip's name");
    assertEqual(tray.chips[0].meta, "PNG image · 16 bytes", "the chip's type and size");
    assertEqual(tray.chips[0].remove, "Remove Screenshot 2026-09-24 at 10.02.11.png", "the remove control's name");
    assert(tray.chips[0].thumb, "a pasted image carries no preview");

    await page.fill("#input", "What is wrong on this screen?");
    await sendAndWaitForBubble(page, "Attached on this Mac");
    const text = await lastUserText(page);
    const calls = await page.evaluate(() => window.__RICHOS_MOCK__.attachCalls());
    const commit = calls.find((c) => c.cmd === "commit_attachments");
    assert(commit, "Send never committed the file");
    assertEqual(commit.text, "What is wrong on this screen?", "the words that went with the file");
    assertEqual(commit.attachments.length, 1, "files committed");
    assert(
      text.startsWith("What is wrong on this screen?\n\nAttached on this Mac (1 file, saved by RichOS):\n- /mock/"),
      "what Rich receives does not open with his words and the phone's block: " + JSON.stringify(text)
    );
    assert(text.endsWith("Screenshot 2026-09-24 at 10.02.11.png (image/png, 16 bytes)"), "the file line: " + JSON.stringify(text));
    assertEqual(await page.locator("#messages .tl-user-text").count(), bubblesBefore + 1, "his message was drawn more than once");
    const after = await readTray(page);
    assertEqual([after.trayHidden, after.chips.length, await page.inputValue("#input")], [true, 0, ""], "the composer after Send");
    assertEqual(page.__errors, [], "the page logged errors");
    await page.close();
    return "chip: name, PNG image · 16 bytes, preview; Rich receives his words then 'Attached on this Mac (1 file, saved by RichOS):' and the file's line";
  });

  await run.check("2. a dropped PNG and PDF: one removed by keyboard, and only what stays is sent — with no words at all", async () => {
    const page = await openApp(browser);
    await drop(page, [
      { name: "diagram.png", bytes: PNG },
      { name: "brief.pdf", bytes: PDF },
    ]);
    await readyChips(page, 2);
    let tray = await readTray(page);
    assertEqual(tray.chips.map((c) => [c.name, c.meta]), [["diagram.png", "PNG image · 16 bytes"], ["brief.pdf", "PDF · " + PDF.length + " bytes"]], "the two chips");
    assertEqual(tray.chips.map((c) => c.thumb), [false, false], "a dropped file claims a preview the page never had the bytes for");
    // Send is offered for files alone: the box is empty and there is still something to send.
    const send = await page.evaluate(() => ({ hidden: document.getElementById("send").hidden, disabled: document.getElementById("send").disabled }));
    assertEqual(send, { hidden: false, disabled: false }, "Send with files and no words");

    // BY KEYBOARD: focus the PDF's remove control and press Enter.
    await page.focus('button[aria-label="Remove brief.pdf"]');
    await page.keyboard.press("Enter");
    await page.waitForFunction(() => document.querySelectorAll("#attach-list .attach-chip").length === 1);
    const focus = await page.evaluate(() => document.activeElement.getAttribute("aria-label"));
    assertEqual(focus, "Remove diagram.png", "focus fell out of the tray after a removal");
    const calls = await page.evaluate(() => window.__RICHOS_MOCK__.attachCalls());
    assert(calls.some((c) => c.cmd === "discard_attachment"), "the removed file was never discarded on the Mac");
    assertEqual(await page.evaluate(() => window.__RICHOS_MOCK__.attachStagedCount()), 1, "files the desk still holds");

    await sendAndWaitForBubble(page, "diagram.png");
    const text = await lastUserText(page);
    assert(text.startsWith("Attached on this Mac (1 file, saved by RichOS):\n- "), "a files-only message: " + JSON.stringify(text));
    assert(!text.includes("brief.pdf"), "the removed PDF was sent anyway: " + JSON.stringify(text));
    tray = await readTray(page);
    assertEqual(tray.trayHidden, true, "the tray after Send");
    assertEqual(page.__errors, [], "the page logged errors");
    await page.close();
    return "two chips, the PDF removed by Enter, focus kept in the tray, only the PNG sent";
  });

  await run.check("3. every refusal is a sentence under the composer, with the file's name, and nothing is attached", async () => {
    const page = await openApp(browser);
    await drop(page, [
      { name: "archive.zip", bytes: [0x50, 0x4b, 3, 4] },
      { name: "Receipts", folder: true },
      { name: "not-really.pdf", bytes: PNG },
      { name: "empty.txt", bytes: [] },
    ]);
    // The LAST refusal's line is the end state; three lines exist once already, mid-drop.
    await page.waitForFunction(
      () => document.getElementById("attach-note").textContent.includes("empty.txt") && document.querySelectorAll("#attach-list .attach-chip").length === 0
    );
    let tray = await readTray(page);
    // At most three lines are kept, newest last: the zip's line has scrolled off.
    assertEqual(
      tray.note.split("\n"),
      [
        "Receipts: This is a folder, not a file. Drop the files inside it instead. Nothing was attached.",
        "not-really.pdf: This file does not look like a PDF. Nothing was attached.",
        "empty.txt: This file is empty. Nothing was attached.",
      ],
      "the refusal lines"
    );
    const role = await page.getAttribute("#attach-note", "role");
    assertEqual(role, "status", "the refusal line is not announced");

    // TOO LARGE is refused BEFORE 25 MB crosses the bridge.
    const before = (await page.evaluate(() => window.__RICHOS_MOCK__.attachCalls())).length;
    await paste(page, [{ name: "huge.png", type: "image/png", size: 25 * 1024 * 1024 + 1 }]);
    await page.waitForFunction(() => document.getElementById("attach-note").textContent.startsWith("huge.png: "));
    tray = await readTray(page);
    assertEqual(tray.note, "huge.png: This file is larger than 25 MB, the most RichOS takes in one file. Nothing was attached.", "the size refusal");
    assertEqual((await page.evaluate(() => window.__RICHOS_MOCK__.attachCalls())).length, before, "a refused 25 MB file still crossed the bridge");

    // TEN FILES, AND AN ELEVENTH.
    await drop(page, Array.from({ length: 11 }, (_, i) => ({ name: "shot-" + (i + 1) + ".png", bytes: PNG })));
    await readyChips(page, 10);
    await page.waitForFunction(() => document.getElementById("attach-note").textContent.includes("shot-11.png"));
    tray = await readTray(page);
    assertEqual(tray.note, "shot-11.png: A message can carry at most 10 files.", "the count refusal");
    assertEqual(page.__errors, [], "the page logged errors");
    await page.close();
    return "zip, folder, disguised PDF, empty file, 25 MB + 1 byte and the 11th file each refused by name; the oversize paste never crossed the bridge";
  });

  await run.check("4. the files belong to the thread they were dropped on, like the words", async () => {
    const page = await openApp(browser);
    // Two threads WITH history, so arriving on each is a painted conversation the harness can
    // wait for (`settleOnThread`), not an empty one it would wait out.
    const first = "acme";
    const other = "hiring";
    await openThread(page, first);
    await drop(page, [{ name: "for-" + first + ".png", bytes: PNG }]);
    await readyChips(page, 1);
    await openThread(page, other);
    let tray = await readTray(page);
    assertEqual([tray.trayHidden, tray.chips.length], [true, 0], "thread " + other + " shows thread " + first + "'s file");
    await openThread(page, first);
    await page.waitForFunction(() => document.querySelectorAll("#attach-list .attach-chip").length === 1);
    tray = await readTray(page);
    assertEqual(tray.chips.map((c) => c.name), ["for-" + first + ".png"], "the file came back with its thread");
    await page.close();
    return `dropped on ${first}, absent on ${other}, back on ${first}`;
  });

  await run.check("5. a file the Mac no longer holds leaves the tray by name, and nothing is sent", async () => {
    const page = await openApp(browser);
    await drop(page, [{ name: "old.png", bytes: PNG }, { name: "kept.pdf", bytes: PDF }]);
    await readyChips(page, 2);
    const gone = await page.evaluate(() => window.RichAttachments.forSend().attachments[0].id);
    await page.evaluate((id) => window.__RICHOS_MOCK__.attachMissingNext([id]), gone);
    const bubbles = await page.locator("#messages .tl-user-text").count();
    await page.fill("#input", "Here you go.");
    await page.keyboard.press("Enter");
    await page.waitForFunction(() => document.getElementById("attach-note").textContent.includes("old.png"));
    const tray = await readTray(page);
    assertEqual(tray.note, "old.png is no longer waiting to be sent. Attach it again; your words are still in the box.", "the sentence");
    assertEqual(tray.chips.map((c) => c.name), ["kept.pdf"], "what is left on the composer");
    assertEqual(await page.inputValue("#input"), "Here you go.", "his words were taken out of the box");
    assertEqual(await page.locator("#messages .tl-user-text").count(), bubbles, "a message was drawn although nothing was sent");
    await page.close();
    return "missing file named and removed; words kept; no bubble";
  });

  await run.check("6. a new thread's first message carries its files", async () => {
    const page = await openApp(browser);
    await page.click("#rail-new-thread");
    await page.waitForFunction(() => !document.getElementById("entity-picker").hidden || !document.getElementById("entity-view").hidden);
    if (await page.evaluate(() => !document.getElementById("entity-picker").hidden)) {
      await page.click("#entity-picker .picker-item");
    }
    await page.waitForSelector("#entity-view:not([hidden])");
    await drop(page, [{ name: "kickoff.pdf", bytes: PDF }]);
    await readyChips(page, 1);
    await page.fill("#input", "Start from this.");
    await page.keyboard.press("Enter");
    await page.waitForFunction(
      () => [...document.querySelectorAll("#messages .tl-user-text")].some((n) => n.textContent.includes("kickoff.pdf (application/pdf")),
      undefined,
      { timeout: 8000 }
    );
    const calls = await page.evaluate(() => window.__RICHOS_MOCK__.attachCalls());
    const commit = calls.find((c) => c.cmd === "commit_attachments");
    const bound = await page.evaluate(() => window.__RICHOS_TIMELINE__().threadId);
    assertEqual(commit.threadId, bound, "the files were filed under a thread other than the one created");
    assertEqual(await readTray(page).then((t) => t.trayHidden), true, "the tray after Send");
    assertEqual(page.__errors, [], "the page logged errors");
    await page.close();
    return "files committed into the thread the first send created (" + bound + ")";
  });

  await run.check("7. the preview says what the product says: sentences, kinds and the block's heading, read from the Rust", async () => {
    const desk = fs.readFileSync(path.join(SRC, "phone", "attachments.rs"), "utf8");
    const mac = fs.readFileSync(path.join(SRC, "mac_attachments.rs"), "utf8");
    const mock = fs.readFileSync(path.join(UI_DIR, "mock.js"), "utf8");
    const tray = fs.readFileSync(path.join(UI_DIR, "attachments.js"), "utf8");
    const macArm = (marker) => {
      // The `Origin::Mac =>` arm that holds `marker`, not the phone's arm above it.
      const at = desk.indexOf("Origin::Mac => ", desk.indexOf(marker) - 400);
      return rustSentenceAfter(desk.slice(at), marker);
    };
    const pairs = [
      [macArm("documents work. Nothing was attached."), "RichOS can't take this kind of file yet. Photos, PDFs, text and Office documents work. Nothing was attached."],
      [macArm("This file is empty. Nothing was attached."), "This file is empty. Nothing was attached."],
      [macArm("the most RichOS takes in one file"), "This file is larger than 25 MB, the most RichOS takes in one file. Nothing was attached."],
      [macArm("look like a {label}. Nothing was attached."), "This file does not look like a {label}. Nothing was attached."],
      [rustSentenceAfter(desk, "A message can carry at most"), "A message can carry at most {} files."],
      [rustSentenceAfter(mac, "This is a folder, not a file."), "This is a folder, not a file. Drop the files inside it instead. Nothing was attached."],
      [rustSentenceAfter(mac, "That drop is no longer available."), "That drop is no longer available. Drop the file again."],
      [macArm("Attached on this Mac ("), "Attached on this Mac ({count}, saved by RichOS):"],
    ];
    for (const [rust, expected] of pairs) assertEqual(rust, expected, "the Rust sentence moved; update the preview with it");
    for (const s of pairs.slice(0, 3).map((p) => p[1])) assert(mock.includes(JSON.stringify(s)), "mock.js does not carry: " + s);
    assert(mock.includes('"This file does not look like a " + label + ". Nothing was attached."'), "mock.js's disguised-file sentence");
    assert(mock.includes('"A message can carry at most 10 files."'), "mock.js's count sentence");
    assert(mock.includes("This is a folder, not a file. Drop the files inside it instead. Nothing was attached."), "mock.js's folder sentence");
    assert(mock.includes("That drop is no longer available. Drop the file again."), "mock.js's drop sentence");
    assert(mock.includes("Attached on this Mac (${count}, saved by RichOS):"), "mock.js's heading");
    assert(tray.includes(JSON.stringify(pairs[2][1])), "attachments.js's size refusal is not the desk's");
    assert(tray.includes('"A message can carry at most 10 files."'), "attachments.js's count refusal is not the desk's");
    assert(desk.includes("pub const MAX_FILE_BYTES: usize = 25 * 1024 * 1024;") && tray.includes("MAX_FILE_BYTES = 25 * 1024 * 1024"), "the 25 MiB ceiling differs");
    assert(desk.includes("pub const MAX_FILES_PER_MESSAGE: usize = 10;") && tray.includes("MAX_FILES = 10"), "the ten-file ceiling differs");

    // THE KINDS, row for row: media type, extension and the label a refusal names.
    const rows = [...desk.matchAll(/Kind \{ media_type: "([^"]+)", extension: "([^"]+)", extensions: &\[[^\]]*\], label: "([^"]+)"/g)].map((m) => [m[1], m[2], m[3]]);
    assertEqual(rows.length, 13, "accepted kinds in the Rust");
    const mockRows = [...mock.matchAll(/\{ mediaType: "([^"]+)", extension: "([^"]+)", extensions: \[[^\]]*\], label: "([^"]+)"/g)].map((m) => [m[1], m[2], m[3]]);
    assertEqual(mockRows, rows, "mock.js's accepted kinds");
    return pairs.length + " sentences and " + rows.length + " kinds identical in Rust, mock.js and attachments.js";
  });

  await run.check("8. the drop target shows while a drag is over the window and leaves with it", async () => {
    const page = await openApp(browser);
    await page.evaluate(() => window.__RICHOS_MOCK__.dragOver(true));
    let hint = await page.evaluate(() => ({ tray: document.getElementById("attach-tray").hidden, hint: document.getElementById("attach-drop").hidden, text: document.getElementById("attach-drop").textContent }));
    assertEqual(hint, { tray: false, hint: false, text: "Drop to attach to your message" }, "while dragging");
    await page.evaluate(() => window.__RICHOS_MOCK__.dragOver(false));
    hint = await page.evaluate(() => ({ tray: document.getElementById("attach-tray").hidden, hint: document.getElementById("attach-drop").hidden }));
    assertEqual(hint, { tray: true, hint: true }, "after the drag left");
    await page.close();
    return "shown on enter, gone on leave";
  });

  await run.check("9. WCAG AA in both themes, computed from WebKit's resolved colors", async () => {
    const page = await openApp(browser);
    await paste(page, [{ name: "Screenshot.png", type: "image/png", bytes: PNG }]);
    await drop(page, [{ name: "Quarterly board pack, final version for Thursday.pdf", bytes: PDF }, { name: "bad.zip", bytes: [0x50, 0x4b, 3, 4] }]);
    await readyChips(page, 2);
    await page.evaluate(() => window.__RICHOS_MOCK__.dragOver(true));
    const out = [];
    for (const theme of ["dark", "light"]) {
      await page.evaluate((t) => document.documentElement.setAttribute("data-theme", t), theme);
      await page.waitForTimeout(80);
      await page.evaluate(C.pageScript());
      const probe = await page.evaluate((t) => window.__contrastProbe({ surface: "composer-attachments", theme: t }), theme);
      const mine = (s) => /attach/.test(s);
      const failures = Object.entries(probe.failures).filter(([k, v]) => mine(k) || mine(JSON.stringify(v)));
      const unresolvable = Object.entries(probe.unresolvable).filter(([k, v]) => mine(k) || mine(JSON.stringify(v)));
      assertEqual(failures, [], theme + ": contrast failures on the attachment surface");
      assertEqual(unresolvable, [], theme + ": unresolvable colors on the attachment surface");
      const measured = probe.measuredPaths.filter(mine);
      for (const part of ["attach-name", "attach-meta", "attach-tile", "attach-note", "attach-drop"]) {
        assert(measured.some((p) => p.includes(part)), theme + ": the walk never measured ." + part + " — a pass over nothing");
      }
      // THE NON-TEXT INDICATORS, measured the way `composer-off.js` measures the placeholder:
      // the paint stack under the element, composited, against the shipped arithmetic.
      const ind = await page.evaluate(() => {
        const M = window.__contrastMath;
        const groundAt = (node) => {
          const b = node.getBoundingClientRect();
          const stack = document.elementsFromPoint(b.left - 2, b.top + b.height / 2).filter((e) => !node.contains(e));
          const layers = [];
          for (const e of stack) {
            const c = M.parseCssColor(getComputedStyle(e).backgroundColor);
            if (!c || c.a === 0) continue;
            layers.push(c);
            if (c.a >= 1) break;
          }
          let g = layers[layers.length - 1];
          for (let k = layers.length - 2; k >= 0; k--) g = M.compositeOver(layers[k], g);
          return g;
        };
        const ratio = (fgCss, bg) => {
          const fg = M.parseCssColor(fgCss);
          return M.round2(M.contrastRatio(fg.a < 1 ? M.compositeOver(fg, bg) : fg, bg));
        };
        const chip = document.querySelector(".attach-chip");
        const drop = document.getElementById("attach-drop");
        const remove = document.querySelector(".attach-remove");
        const card = M.parseCssColor(getComputedStyle(chip).backgroundColor);
        // The text, against what is painted directly behind it (the stack at its own center).
        const behind = (node) => {
          const b = node.getBoundingClientRect();
          const layers = [];
          for (const e of document.elementsFromPoint(b.left + 2, b.top + b.height / 2)) {
            const c = M.parseCssColor(getComputedStyle(e).backgroundColor);
            if (!c || c.a === 0) continue;
            layers.push(c);
            if (c.a >= 1) break;
          }
          let g = layers[layers.length - 1];
          for (let k = layers.length - 2; k >= 0; k--) g = M.compositeOver(layers[k], g);
          return g;
        };
        const text = (sel) => {
          const node = document.querySelector(sel);
          return { ratio: ratio(getComputedStyle(node).color, behind(node)), px: parseFloat(getComputedStyle(node).fontSize) };
        };
        return {
          indicators: {
            chipEdge: ratio(getComputedStyle(chip).borderTopColor, groundAt(chip)),
            dropEdge: ratio(getComputedStyle(drop).borderTopColor, groundAt(drop)),
            removeGlyph: ratio(getComputedStyle(remove).color, card),
          },
          text: {
            name: text(".attach-name"),
            meta: text(".attach-meta"),
            tile: text(".attach-chip:not(:has(img)) .attach-tile"),
            note: text("#attach-note"),
            drop: text("#attach-drop"),
          },
        };
      });
      for (const [k, v] of Object.entries(ind.indicators)) assert(v >= 3, `${theme}: ${k} is ${v}:1, under the 3:1 non-text floor`);
      for (const [k, v] of Object.entries(ind.text)) {
        assert(v.ratio >= 4.5, `${theme}: .${k} text is ${v.ratio}:1, under 4.5:1`);
        // §15: 16px for text meant to be read; the tile's 14px is the declared skippable tier.
        assert(v.px >= (k === "tile" ? 14 : 16), `${theme}: .${k} is ${v.px}px`);
      }
      const t = ind.text;
      out.push(
        `${theme}: ${measured.length} nodes walked, 0 failures; text name ${t.name.ratio} meta ${t.meta.ratio} tile ${t.tile.ratio} note ${t.note.ratio} drop ${t.drop.ratio}; ` +
          `indicators chip edge ${ind.indicators.chipEdge}, drop edge ${ind.indicators.dropEdge}, remove × ${ind.indicators.removeGlyph}`
      );
    }
    await page.close();
    return out.join(" | ");
  });

  const failed = run.report();
  await browser.close();
  process.exit(failed ? 1 : 0);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
