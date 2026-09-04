// §5.4 MARKDOWN IN RICH'S ANSWERS — the subset, the escaping, and the degradation.
//
// WHAT THIS SUITE EXISTS BECAUSE OF. On the published v1.0.1, the first message ever sent on
// a clean install came back reading, on screen, as literal characters:
//
//     **1. Tell me about Lakeside Advisory.**
//     **2. Authorize the connectors.**
//
// Three such lines in one answer (ray-opus-a2, 2026-09-04). Nothing was broken: the engine
// emits Markdown and `renderRichMessage` set `textContent`, so the asterisks are exactly
// what the model wrote. `timeline.js` now renders a deliberately small subset — bold,
// italic, code spans, ordered and unordered lists, headings, paragraph breaks — and this
// file is what says so.
//
// THREE THINGS IT HAS TO PROVE, and the third is the one that matters most:
//
//   1. THE SUBSET RENDERS. Real elements, and the markers gone from the text.
//   2. AN UNMATCHED MARKER IS LITERAL AND HARMLESS. `**` with no closer, a lone backtick, a
//      `*` used as punctuation — each falls through to its own characters, and NONE of them
//      may eat the rest of the message. A renderer that swallows the tail of an answer is a
//      worse defect than the asterisks it was written to remove.
//   3. MODEL OUTPUT NEVER BECOMES MARKUP. `<img src=x onerror=alert(1)>` and a `<script>`
//      tag are driven through the real renderer, and both the characters on screen AND the
//      absence of the elements are asserted — because either one alone can pass while the
//      other fails. There is no `innerHTML` anywhere on this path, which is checked here as
//      a property of the SOURCE too: an escaping step that does not exist cannot be
//      forgotten, reordered or regressed.
//
// Both write sites are covered: the structural path (`renderRichMessage`, which runs on
// every full render) and the streaming path (`updateProse`, which runs once per animation
// frame per live message). They must agree, or an answer would change shape at the moment
// it completed.
//
// Run: node markdown.js   (or `npm test` for every suite in this directory)

"use strict";

const { loadPlaywright, openFixture, createRun, assert, assertEqual } = require("./lib/harness");
const F = require("./lib/fixtures");

/// Render `text` through the SHIPPING renderer into a `.tl-prose` host and report what came
/// out — the element inventory, the visible text, and the raw markup for the escaping
/// checks. Never re-implements a rule; `renderMarkdownInto` is the exported function
/// `renderRichMessage` and `updateProse` both call.
async function md(page, text) {
  return page.evaluate((t) => {
    let host = document.getElementById("md-host");
    if (!host) {
      host = document.createElement("div");
      host.id = "md-host";
      host.className = "tl-prose";
      document.getElementById("messages").appendChild(host);
    }
    window.RichTimeline.renderMarkdownInto(host, t);
    return {
      text: host.innerText,
      html: host.innerHTML,
      strong: Array.from(host.querySelectorAll("strong")).map((n) => n.textContent),
      em: Array.from(host.querySelectorAll("em")).map((n) => n.textContent),
      code: Array.from(host.querySelectorAll("code")).map((n) => n.textContent),
      ul: Array.from(host.querySelectorAll("ul")).map((n) =>
        Array.from(n.querySelectorAll("li")).map((li) => li.textContent)
      ),
      ol: Array.from(host.querySelectorAll("ol")).map((n) =>
        Array.from(n.querySelectorAll("li")).map((li) => li.textContent)
      ),
      headings: Array.from(host.querySelectorAll('[role="heading"]')).map(
        (n) => n.getAttribute("aria-level") + ":" + n.textContent
      ),
      images: host.querySelectorAll("img").length,
      scripts: host.querySelectorAll("script").length,
      anyElement: host.querySelectorAll("*").length,
    };
  }, text);
}

async function main() {
  const run = createRun("§5.4 Markdown — the subset, the escaping, the degradation");
  const { webkit } = loadPlaywright();
  const browser = await webkit.launch();
  const page = await openFixture(browser);

  await run.check("1  the field report's own three lines: bold renders, asterisks gone", async () => {
    const r = await md(page, "**1. Tell me about Lakeside Advisory.**\n\n**2. Authorize the connectors.**");
    assertEqual(
      r.strong,
      ["1. Tell me about Lakeside Advisory.", "2. Authorize the connectors."],
      "both lines must be `strong` elements"
    );
    assert(r.text.indexOf("**") === -1, "the asterisks are still on screen: " + JSON.stringify(r.text));
    assert(/^1\. Tell me about Lakeside Advisory\./.test(r.text), "the words themselves changed: " + r.text);
    return "two `strong` elements, zero asterisks — " + JSON.stringify(r.text.split("\n")[0]);
  });

  await run.check("2  italic and code spans, and a code span keeps its own characters", async () => {
    const r = await md(page, "Scoped to the *advisory* label, under `/Lakeside/contacts.csv`.");
    assertEqual(r.em, ["advisory"], "one `em`");
    assertEqual(r.code, ["/Lakeside/contacts.csv"], "one `code`, with its slashes and dot intact");
    assertEqual(
      r.text,
      "Scoped to the advisory label, under /Lakeside/contacts.csv.",
      "the sentence must read as prose once the markers are gone"
    );
    return "em=advisory, code=/Lakeside/contacts.csv";
  });

  await run.check("3  both list kinds, as real lists, with the markers gone from the text", async () => {
    const r = await md(
      page,
      ["Three connectors:", "", "- Calendar", "- Mail", "", "Then, in order:", "", "1. Read the letter", "2. Reconcile", "3. Draft"].join("\n")
    );
    assertEqual(r.ul, [["Calendar", "Mail"]], "one unordered list of two");
    assertEqual(r.ol, [["Read the letter", "Reconcile", "Draft"]], "one ordered list of three");
    assert(r.text.indexOf("- Calendar") === -1, "the hyphen markers are still in the text: " + r.text);
    return "ul(2) + ol(3), markers drawn by the list rather than typed in the text";
  });

  await run.check("4  a heading is a heading, and it is announced as one", async () => {
    const r = await md(page, "## Lakeside Advisory\n\nHere is where things stand.");
    assertEqual(r.headings, ["4:Lakeside Advisory"], "`##` is aria-level 4 and carries the words");
    assert(r.text.indexOf("#") === -1, "the hashes are still on screen: " + r.text);
    return "role=heading aria-level=4, no hashes";
  });

  await run.check("5  ESCAPING: model output never becomes markup", async () => {
    const hostile = '<img src=x onerror=alert(1)> and <script>alert(2)</script> and <b>not bold</b>';
    const r = await md(page, hostile);
    assertEqual(r.images, 0, "an `img` element was created from model text");
    assertEqual(r.scripts, 0, "a `script` element was created from model text");
    assert(
      r.text.indexOf("<img src=x onerror=alert(1)>") !== -1,
      "the characters must be ON SCREEN, verbatim: " + JSON.stringify(r.text)
    );
    assert(r.text.indexOf("<script>alert(2)</script>") !== -1, "the script tag must read as characters: " + r.text);
    assert(r.text.indexOf("<b>not bold</b>") !== -1, "the bold tag must read as characters: " + r.text);
    // The serialized markup is the second half of the proof: the angle brackets have to be
    // ENTITIES in the DOM's own output, which is what proves they are text nodes rather
    // than elements that merely failed to load.
    assert(r.html.indexOf("&lt;img src=x onerror=alert(1)&gt;") !== -1, "not stored as text: " + r.html);
    assertEqual(page.__errors, [], "a page error means something executed");
    return "0 img, 0 script, all three tags on screen as characters, angle brackets escaped in the DOM";
  });

  await run.check("5b escaping holds INSIDE every span the subset can build", async () => {
    const r = await md(
      page,
      ["**<img src=x onerror=alert(1)>**", "", "- `<script>alert(2)</script>`", "", "# <b>heading</b>"].join("\n")
    );
    assertEqual(r.images, 0, "an `img` was created inside a bold span");
    assertEqual(r.scripts, 0, "a `script` was created inside a code span");
    assertEqual(r.strong, ["<img src=x onerror=alert(1)>"], "the bold span holds the characters");
    assertEqual(r.code, ["<script>alert(2)</script>"], "the code span holds the characters");
    assertEqual(r.headings, ["3:<b>heading</b>"], "the heading holds the characters");
    assertEqual(page.__errors, [], "a page error means something executed");
    return "hostile text inside bold, code and a heading — still 0 elements from it";
  });

  await run.check("5c there is no `innerHTML` on the prose path, in the SOURCE", async () => {
    const fs = require("fs");
    const path = require("path");
    const { UI_DIR } = require("./lib/harness");
    const src = fs.readFileSync(path.join(UI_DIR, "timeline.js"), "utf8");
    // Comments say the word; code must not. Strip line comments and block comments first,
    // so the prose above this check cannot make it pass or fail.
    const code = src.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "").replace(/^\s*\/\/\/.*$/gm, "");
    const hits = code.split("\n").filter((l) => /innerHTML|insertAdjacentHTML|outerHTML/.test(l));
    assertEqual(hits, [], "an HTML-string sink appeared in timeline.js: " + hits.join(" | "));
    return "timeline.js has no innerHTML / outerHTML / insertAdjacentHTML in code";
  });

  await run.check("6  an unmatched marker is literal, and never eats the rest of the message", async () => {
    const tail = "and the rest of this sentence must still be here.";
    for (const [name, text] of [
      ["unclosed bold", "**never closed " + tail],
      ["unclosed italic", "*never closed " + tail],
      ["unclosed code", "`never closed " + tail],
      ["empty bold", "**** " + tail],
      ["asterisk as punctuation", "3 * 4 * 5 " + tail],
      ["stray hash", "#nothashtag " + tail],
    ]) {
      const r = await md(page, text);
      assert(r.text.indexOf(tail) !== -1, name + " ate the tail: " + JSON.stringify(r.text));
      assertEqual(r.text, text, name + " changed the characters: " + JSON.stringify(r.text));
    }
    return "six malformed inputs, all rendered character-for-character, none truncated";
  });

  await run.check("7  plain prose is untouched, and its own newlines survive", async () => {
    const plain = "They are a twelve-person firm in Bristol.\nI have their filings.\n\nSay the word.";
    const r = await md(page, plain);
    assertEqual(r.strong, [], "no spans invented");
    // THE ONE DELIBERATE CHANGE THIS RENDERER MAKES TO PLAIN TEXT, stated rather than
    // hidden: a blank line between two paragraphs used to be drawn as an empty line by
    // `pre-wrap`, and is now the 0.7em margin between two `.tl-md-p` blocks. So the gap
    // survives as SPACE and not as a newline character. Every OTHER newline is untouched —
    // the single break inside the first paragraph is still a character, which is what the
    // first assertion below measures.
    assert(
      r.text.indexOf("in Bristol.\nI have their filings.") !== -1,
      "a single newline inside a paragraph must still be a line break: " + JSON.stringify(r.text)
    );
    assertEqual(
      r.text.replace(/\s+/g, " "),
      plain.replace(/\s+/g, " "),
      "every word must survive, in order: " + JSON.stringify(r.text)
    );
    const gap = await page.evaluate(() => {
      const ps = document.getElementById("md-host").querySelectorAll(".tl-md-p");
      return { count: ps.length, marginTop: ps.length > 1 ? getComputedStyle(ps[1]).marginTop : null };
    });
    assertEqual(gap.count, 2, "the blank line must produce two paragraph blocks");
    assert(parseFloat(gap.marginTop) > 8, "and the gap must be real space, not nothing: " + gap.marginTop);
    return "words preserved verbatim; the in-paragraph newline is a character, the blank line is a " + gap.marginTop + " margin";
  });

  await run.check("8  the two write sites agree — streaming and structural build the same DOM", async () => {
    const text = "## Next\n\n**1. Read the letter.**\n\n- one\n- two\n\nDone with `contacts.csv`.";
    const r = await page.evaluate((t) => {
      // The STRUCTURAL path: a real snapshot through the real renderer.
      window.__render(
        {
          entityId: "northwind",
          threadId: "thr_fem",
          mode: "ceo",
          bindingRevision: 1,
          items: [
            {
              bindingRevision: 1,
              createdAt: 1787948500000,
              entityId: "northwind",
              id: "turn_ok:text:0",
              kind: "rich_message",
              phase: "unknown",
              sequence: 0,
              slot: "stream",
              text: t,
              threadId: "thr_fem",
              turnId: "turn_ok",
              visibility: "ceo",
            },
          ],
        },
        {}
      );
      const structural = document.querySelector('[id="prose:turn_ok:text:0"]').innerHTML;
      // The STREAMING path: the same text through `updateProse`, which is what runs while
      // the answer is arriving.
      window.RichTimeline.updateProse(document.getElementById("messages"), "turn_ok:text:0", t, false);
      const streaming = document.querySelector('[id="prose:turn_ok:text:0"]').innerHTML;
      return { structural, streaming, strong: document.querySelectorAll('[id="prose:turn_ok:text:0"] strong').length };
    }, text);
    assertEqual(r.streaming, r.structural, "an answer would change shape at the moment it completed");
    assertEqual(r.strong, 1, "the bold span must survive the streaming path too");
    assert(r.structural.indexOf("**") === -1, "asterisks reached the real render path: " + r.structural);
    return "identical markup from both write sites, " + r.structural.length + " bytes";
  });

  await run.check("9  no new color, and the 18px prose scale is untouched", async () => {
    // Check 8 renders a real snapshot, and a full render clears `#messages` — so the host is
    // re-made through the same helper every other check uses rather than assumed present.
    await md(page, "# H\n\n**b** *i* `c`\n\n- item");
    const r = await page.evaluate(() => {
      const host = document.getElementById("md-host");
      const cs = (sel) => {
        const n = host.querySelector(sel);
        return n ? getComputedStyle(n).color : null;
      };
      return {
        prose: getComputedStyle(host).color,
        proseSize: parseFloat(getComputedStyle(host).fontSize),
        strong: cs("strong"),
        em: cs("em"),
        code: cs("code"),
        heading: cs('[role="heading"]'),
        item: cs("li"),
        codeFamily: getComputedStyle(host.querySelector("code")).fontFamily,
      };
    });
    for (const k of ["strong", "em", "code", "heading", "item"]) {
      assertEqual(r[k], r.prose, k + " introduced a color of its own — it must inherit `--ink`");
    }
    assertEqual(r.proseSize, 18, "§17.2: Rich's prose is 18px, and Markdown must not move it");
    assert(/mono/i.test(r.codeFamily), "a code span is distinguished by its face: " + r.codeFamily);
    return "every Markdown node inherits the prose ink (" + r.prose + ") at 18px; code differs by face only";
  });

  await run.check("10 no page errors anywhere in this suite", async () => {
    assertEqual(page.__errors, [], "the renderer logged errors");
    return "0 uncaught errors, 0 console errors";
  });

  await page.close();
  await browser.close();
  return run.report();
}

main().then(
  (failed) => process.exit(failed ? 1 : 0),
  (e) => {
    console.error(e);
    process.exit(1);
  }
);
