// BUST A BUG — the conversation, the report card and the Rich panel (round 21).
//
// The CEO's §115 (2026-10-09), the acceptance criterion: "When the user has Claude set up in the
// app (which is the expected default), we should just let the user say what's wrong and where and
// let their Rich check and articulate everything properly and then submit a GitHub issue on their
// behalf." Built exactly as richos-hq design/mockups/rounds/round-21/ shows it (approved "go!"):
//
//   ask -> checking -> draft <-> editing -> sending -> sent
//                        \-> canceled          \-> waiting (offline / GitHub down) -> sent
//
// Pressing Bust a bug opens nothing new: Rich asks in the conversation on screen, under a quiet
// "Bust a bug" divider. Where a window covers the conversation (Corrections, Feedback, Search, the
// company picker), or there is no conversation that can take messages, the same exchange happens
// in a Rich panel at the right and the window stays open beside it.
//
// WHAT IS NOT IN THIS FILE: what is private and its stand-ins, Rich's write-up, the issue's words,
// the send and the keeping of what could not go. All of that is `richos_core::bug_report`, reached
// through six commands (`bug_report_*`), so the rule that decides what reaches GitHub is in Rust
// and tested there. This file draws what those commands answer. Everything it puts on screen is
// built with textContent; nothing Rich or the user wrote is ever parsed as markup.
"use strict";

window.RichBug = (function () {
  var host = null; // main.js's hooks (init)
  var bridge = null;
  var context = null; // bug_report_context: account, private terms
  var flows = [];
  var seq = 0;
  var dockVoice = false;

  var GLYPH_BUG = [
    "m8 2 1.88 1.88", "M14.12 3.88 16 2", "M9 7.13v-1a3.003 3.003 0 1 1 6 0v1",
    "M12 20c-3.3 0-6-2.7-6-6v-3a4 4 0 0 1 4-4h4a4 4 0 0 1 4 4v3c0 3.3-2.7 6-6 6", "M12 20v-9",
    "M6.53 9C4.6 8.8 3 7.1 3 5", "M6 13H2", "M3 21c0-2.1 1.7-3.8 3.8-4", "M20.97 5c0 2.1-1.6 3.8-3.5 4",
    "M22 13h-4", "M17.2 17c2.1.2 3.8 1.9 3.8 4",
  ];
  var GLYPH_EYEOFF = [
    "M10.733 5.076a10.744 10.744 0 0 1 11.205 6.575 1 1 0 0 1 0 .696 10.747 10.747 0 0 1-1.444 2.49",
    "M14.084 14.158a3 3 0 0 1-4.242-4.242",
    "M17.479 17.499a10.75 10.75 0 0 1-15.417-5.151 1 1 0 0 1 0-.696 10.75 10.75 0 0 1 4.446-5.143",
    "m2 2 20 20",
  ];
  var GLYPH_MIC = ["M19 10v1a7 7 0 0 1-14 0v-1", "M12 18v4"];

  function svg(paths, cls, label) {
    var ns = "http://www.w3.org/2000/svg";
    var s = document.createElementNS(ns, "svg");
    s.setAttribute("viewBox", "0 0 24 24");
    s.setAttribute("fill", "none");
    s.setAttribute("stroke", "currentColor");
    s.setAttribute("stroke-width", "2");
    s.setAttribute("stroke-linecap", "round");
    s.setAttribute("stroke-linejoin", "round");
    if (cls) s.setAttribute("class", cls);
    if (label) {
      s.setAttribute("role", "img");
      s.setAttribute("aria-label", label);
    } else s.setAttribute("aria-hidden", "true");
    if (paths === GLYPH_MIC) {
      var r = document.createElementNS(ns, "rect");
      r.setAttribute("x", "9"); r.setAttribute("y", "2"); r.setAttribute("width", "6"); r.setAttribute("height", "12"); r.setAttribute("rx", "3");
      s.appendChild(r);
    }
    for (var i = 0; i < paths.length; i++) {
      var p = document.createElementNS(ns, "path");
      p.setAttribute("d", paths[i]);
      s.appendChild(p);
    }
    return s;
  }

  function node(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  }
  function $(id) { return document.getElementById(id); }

  // ---- what is private, client side: only for the card's heads-up after a change --------------
  // The authority is Rust (`Scrubber`); this mirrors its rules so the card can say "Acme looks
  // private" while the user types. It never decides what is sent: the user may send anyway.
  // `f.private` is what Rich found private in this report (the draft's and every change's), so
  // a name he left out once is named here too when the user types it back in.
  function privateIn(text, f) {
    var found = [];
    var terms = ((context && context.privateTerms) || []).concat((f && f.private) || []);
    for (var i = 0; i < terms.length; i++) {
      var t = terms[i].text;
      var oneWord = !/\s/.test(t);
      var cap = /^[A-Z]/.test(t);
      var re = new RegExp("(^|[^\\p{L}\\p{N}_])(" + t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + ")(?![\\p{L}\\p{N}_])", "giu");
      var m;
      while ((m = re.exec(text))) {
        var hit = m[2];
        if (oneWord && cap && !/^\p{Lu}/u.test(hit)) continue;
        if (found.indexOf(hit) === -1) found.push(hit);
      }
    }
    // A path between backticks, quotes or brackets is taken whole, spaces and all; a plain one
    // to the end of its word (Rust's `find_paths` also follows a plain path through spaces).
    var paths = [];
    var quoted = /([`"'“‘(\[<{])((?:~\/|\/[\w.])[^\n]*?)(?=[`"'”’)\]>}])/g, q;
    while ((q = quoted.exec(text))) paths.push(q[2]);
    (text.match(/(?:^|\s)((?:~\/|\/[\w.])[^\s,;)"'\]>`}]*)/g) || []).forEach(function (p) { paths.push(p.trim().replace(/[.:!?]+$/, "")); });
    paths.forEach(function (p) {
      if (paths.some(function (o) { return o !== p && o.indexOf(p) === 0; })) return; // part of a longer one
      if ((p.indexOf("~/") === 0 && p.length > 2) || (p.match(/\//g) || []).length >= 2) if (found.indexOf(p) === -1) found.push(p);
    });
    (text.match(/[\w.%+-]+@[\w-]+(?:\.[\w-]+)+/g) || []).forEach(function (e) { if (found.indexOf(e) === -1) found.push(e); });
    return found;
  }

  // ---- where the user was -------------------------------------------------------------------
  // [element, key, what the user calls it (the panel's header and Rich's sentence), the same
  // place for the public report]. The three windows round 21 names first, then the other sheets
  // that cover the conversation.
  var WINDOWS = [
    ["corrections-overlay", "corrections", "Corrections", "the Corrections window"],
    ["feedback-overlay", "feedback", "Feedback", "the Feedback window"],
    ["search-overlay", "search", "Search", "the Search window"],
    ["entity-picker", "picker", "the company picker", "the window that asks which company a new conversation belongs to"],
    ["setup-sheet", "setup", "the setup window", "the window that sets RichOS up"],
    ["memory-setup", "setup", "the memory folder window", "the window that asks where RichOS keeps what it is told"],
  ];
  function openWindow() {
    for (var i = 0; i < WINDOWS.length; i++) {
      var n = $(WINDOWS[i][0]);
      if (n && !n.hidden) return WINDOWS[i];
    }
    return null;
  }
  function screenNow() {
    var scale = window.RichTheme && window.RichTheme.scale ? window.RichTheme.scale() : 100;
    var theme = document.documentElement.dataset.theme || "";
    var techy = !!document.querySelector("#techy-chip:not([hidden])");
    var base = { textSize: scale, theme: theme, technicalView: techy, conversation: null };
    var w = openWindow();
    if (w) return Object.assign(base, { key: w[1], dock: true, label: w[2], here: w[2], public: w[3] });
    var view = host ? host.view() : "conversation";
    var thread = host ? host.activeThread() : null;
    var title = thread && host ? host.threadTitle(thread) : "";
    if (window.RichHome && window.RichHome.isOpen && window.RichHome.isOpen())
      return Object.assign(base, { key: "home", dock: true, label: "the home screen", here: "the home screen", public: "the home screen, with a button for each company" });
    if (view === "unbound")
      return Object.assign(base, { key: "unbound", dock: true, label: title || "this conversation", here: title ? "the " + title + " conversation" : "a conversation", conversation: title || null, public: "a conversation that isn't filed under a company yet, where sending is off" });
    if (view === "entity")
      return Object.assign(base, { key: "company", dock: true, label: "this company's page", here: "a company's page", public: "a company's page, with its conversations" });
    if (view !== "conversation" || !thread || (host && host.blocked()))
      return Object.assign(base, { key: "other", dock: true, label: "this screen", here: "this screen", public: "a RichOS screen" });
    return Object.assign(base, { key: "conversation", dock: false, label: title, here: "the " + (title || "current") + " conversation", conversation: title || null, public: "a conversation, the main RichOS screen" });
  }

  // ---- flows --------------------------------------------------------------------------------
  var LIVE = ["ask", "checking", "draft", "editing", "sending", "queued"];
  var TAKES_WORDS = ["ask", "draft", "queued", "editing"];
  function live(f) { return LIVE.indexOf(f.step) !== -1; }
  function liveFlow() { return flows.filter(live)[0] || null; }
  function dockFlow() { return flows.filter(function (f) { return f.dock; }).slice(-1)[0] || null; }

  function box(f) { return f.dock ? $("bugdock-msgs") : f.el; }
  function scroller(f) { return f.dock ? $("bugdock-msgs") : $("conversation"); }
  function inputOf(f) { return f.dock ? $("bugdock-input") : $("input"); }

  function scrollDown(f) {
    window.setTimeout(paintStuck, 450);
    var sc = scroller(f);
    if (!sc) return;
    window.requestAnimationFrame(function () { sc.scrollTop = sc.scrollHeight; });
  }

  /// One of Rich's lines, drawn the way the conversation draws his messages.
  function richSays(f, lines, opts) {
    opts = opts || {};
    var wrap = node("div", "bug-turn");
    if (opts.worked) {
      var row = node("div", "tl-duration bug-worked");
      row.dataset.tone = "done";
      row.appendChild(node("span", "tl-duration-label", "Worked for " + opts.worked));
      row.appendChild(node("span", "tl-rule"));
      wrap.appendChild(row);
    }
    if (opts.digest) wrap.appendChild(node("p", "bug-digest", opts.digest));
    var art = node("article", "tl-rich bug-rich");
    art.appendChild(node("span", "sr-only", "Rich said"));
    var meta = node("div", "tl-rich-meta");
    meta.appendChild(node("span", "tl-who", "Rich"));
    art.appendChild(meta);
    lines.forEach(function (line) {
      var p = node("p", "tl-prose bug-prose");
      if (typeof line === "string") p.textContent = line;
      else p.appendChild(line);
      art.appendChild(p);
    });
    wrap.appendChild(art);
    box(f).appendChild(wrap);
    scrollDown(f);
    if (host) host.announce(lines.filter(function (l) { return typeof l === "string"; }).join(" "));
    return art;
  }

  function userSays(f, text, spoken) {
    var art = node("article", "tl-user bug-user");
    art.appendChild(node("span", "sr-only", spoken ? "You said aloud" : "You said"));
    var bubble = node("div", "tl-user-bubble");
    var t = node("div", "tl-user-text");
    if (spoken) t.appendChild(svg(GLYPH_MIC, "bug-said", "Said aloud"));
    t.appendChild(document.createTextNode(text));
    bubble.appendChild(t);
    art.appendChild(bubble);
    box(f).appendChild(art);
    scrollDown(f);
  }

  function working(f, words) {
    var w = node("p", "bug-working");
    w.setAttribute("role", "status");
    w.appendChild(node("span", "bug-working-dot"));
    w.appendChild(document.createTextNode(words));
    box(f).appendChild(w);
    scrollDown(f);
    return w;
  }

  function placeholderFor(f) {
    if (!f) return null;
    if (f.step === "ask") return "Tell Rich what went wrong…";
    if (f.step === "draft" || f.step === "queued" || f.step === "editing") return "Tell Rich what to change, or press Send…";
    return null;
  }

  function paintComposers() {
    var f = liveFlow();
    var dockInput = $("bugdock-input");
    if (dockInput) dockInput.placeholder = (f && f.dock && placeholderFor(f)) || "Talk to Rich…";
    if (host) host.syncComposer();
    paintDock();
    syncVoiceHold();
  }

  /// **START.** One report at a time: pressing it while one is in progress takes the user back to
  /// it and pulses its card.
  function start() {
    var cur = liveFlow();
    if (cur) {
      if (cur.dock) showDock();
      else if (host && cur.threadId !== host.activeThread()) host.openThread(cur.threadId);
      if (cur.card) {
        cur.card.classList.remove("is-flash");
        void cur.card.offsetWidth;
        cur.card.classList.add("is-flash");
        cur.card.scrollIntoView({ block: "center" });
      } else scrollDown(cur);
      window.setTimeout(function () { var i = inputOf(cur); if (i) i.focus(); }, 0);
      return cur;
    }
    var scr = screenNow();
    var f = { id: ++seq, dock: scr.dock, threadId: host ? host.activeThread() : null, screen: scr, step: "ask", el: node("section", "bugflow") };
    f.el.dataset.flow = String(f.id);
    f.el.setAttribute("aria-label", "Bust a bug");
    flows.push(f);
    if (f.dock) {
      $("bugdock-msgs").textContent = "";
      $("bugdock-where").textContent = "· " + scr.label;
      showDock();
    } else {
      $("bug-flows").appendChild(f.el);
      var dv = node("div", "bug-divider");
      dv.appendChild(svg(GLYPH_BUG));
      dv.appendChild(node("span", null, "Bust a bug"));
      f.el.appendChild(dv);
      sync();
    }
    var where =
      scr.key === "conversation" ? "I've noted that you were on " + scr.here + "."
      : scr.key === "unbound" ? "I've noted that you were on " + scr.here + ", which can't take messages yet, so we're talking here."
      : openWindow() ? "I've noted that you were in " + scr.here + ", and it stays open beside us."
      : "I've noted that you were on " + scr.here + ".";
    var art = richSays(f, ["What went wrong? Tell me in your own words, typed or out loud, and where it happened if it wasn't here. " + where]);
    var acts = node("div", "bug-actions-inline");
    var nm = node("button", "desk-btn", "Never mind");
    nm.type = "button";
    nm.id = "bug-never-mind";
    nm.addEventListener("click", function () { neverMind(f); });
    acts.appendChild(nm);
    art.appendChild(acts);
    f.neverMind = acts;
    paintComposers();
    window.setTimeout(function () { var i = inputOf(f); if (i) i.focus(); }, 0);
    return f;
  }

  function neverMind(f, quiet) {
    if (f.neverMind) { f.neverMind.remove(); f.neverMind = null; }
    f.step = "closed";
    if (!quiet) richSays(f, ["No problem. Nothing was written up or sent."]);
    paintComposers();
  }

  function sheetOf(f) {
    var c = f.card;
    return {
      title: c.querySelector(".bug-title").textContent.trim(),
      sections: Array.prototype.map.call(c.querySelectorAll(".bug-sec"), function (s) {
        return {
          heading: s.querySelector("h4").textContent.trim(),
          paragraphs: Array.prototype.map.call(s.querySelectorAll("p"), function (p) { return p.textContent.trim(); }).filter(Boolean),
          steps: Array.prototype.map.call(s.querySelectorAll("li"), function (li) { return li.textContent.trim(); }).filter(Boolean),
        };
      }),
    };
  }

  function worked(ms) {
    var t = window.RichTimeline && window.RichTimeline.formatDuration ? window.RichTimeline.formatDuration(ms) : null;
    return t || "1s";
  }

  /// **THE USER'S WORDS**: the answer to Rich's question, or a change to the report.
  function say(f, text, spoken) {
    if (f.step === "ask") {
      if (f.neverMind) { f.neverMind.remove(); f.neverMind = null; }
      userSays(f, text, spoken);
      f.step = "checking";
      paintComposers();
      var w = working(f, "Rich is checking…");
      bridge.invoke("bug_report_write", { answer: text, screen: publicScreen(f.screen) }).then(function (answer) {
        w.remove();
        f.draft = answer.draft;
        f.private = (answer.draft && answer.draft.private) || [];
        richSays(f, ["Here's the report as I'd file it. Nothing goes out until you press Send. Anyone can read GitHub issues, so I left out names, company details and file paths."], { worked: worked(answer.workedMs), digest: answer.digest });
        f.card = buildCard(f);
        box(f).appendChild(f.card);
        f.step = "draft";
        paintCard(f);
        paintComposers();
        scrollDown(f);
        window.setTimeout(function () { if (f.card) f.card.classList.remove("is-new"); }, 2600);
      }).catch(function (e) {
        w.remove();
        f.step = "ask";
        richSays(f, [typeof e === "string" && e ? e : "I couldn't write that up just now. Tell me again and I'll try once more."]);
        paintComposers();
      });
      return;
    }
    // A change, said to Rich: he folds it into the report, which waits for approval again.
    if (f.step === "editing") finishEdit(f);
    var wasQueued = f.step === "queued";
    if (wasQueued && f.pendingId) {
      // A changed report is approved again, so the copy waiting on this Mac must not go out first.
      bridge.invoke("bug_report_cancel", { id: f.pendingId }).catch(function () {});
      f.pendingId = null;
      f.step = "draft";
      paintCard(f);
    }
    userSays(f, text, spoken);
    var w2 = working(f, "Rich is changing the report…");
    bridge.invoke("bug_report_change", { said: text, sheet: sheetOf(f), private: f.private || [] }).then(function (answer) {
      w2.remove();
      if (answer.private) f.private = answer.private;
      var secs = f.card.querySelectorAll(".bug-sec");
      var sec = null;
      for (var i = 0; i < secs.length; i++) if (secs[i].querySelector("h4").textContent === answer.section) sec = secs[i];
      if (!sec) sec = secs[0];
      var p = node("p", "is-added");
      appendSegments(p, answer.add);
      var ol = sec.querySelector("ol");
      sec.insertBefore(p, ol);
      f.edited = true;
      f.step = "draft";
      paintCard(f);
      paintComposers();
      richSays(f, ["Added that to " + sec.querySelector("h4").textContent + ", above." + (wasQueued ? " The report changed, so it waits for you to send it again." : " It still waits for you to send it.")]);
      flash(f);
    }).catch(function () {
      w2.remove();
      richSays(f, ["I couldn't change the report just now. Press Change it and change the words yourself, or tell me again."]);
    });
  }

  function publicScreen(s) {
    return { key: s.key, here: s.here, public: s.public, conversation: s.conversation, textSize: s.textSize, theme: s.theme, technicalView: s.technicalView };
  }

  function flash(f) {
    if (!f.card) return;
    f.card.classList.remove("is-flash");
    void f.card.offsetWidth;
    f.card.classList.add("is-flash");
  }

  // ---- the report card: the send-before-approve step ------------------------------------------
  function appendSegments(parent, segments) {
    (segments || []).forEach(function (s) {
      if (s.was == null) {
        parent.appendChild(document.createTextNode(s.text));
        return;
      }
      var sub = node("span", "bug-sub", s.text);
      sub.tabIndex = 0;
      sub.dataset.was = s.was;
      sub.dataset.kind = s.kind || "";
      parent.appendChild(sub);
    });
  }

  function buildCard(f) {
    var d = f.draft;
    var c = node("article", "bugcard is-new");
    c.setAttribute("aria-label", "Bug report");
    var head = node("header", "bug-head");
    head.appendChild(svg(GLYPH_BUG, "bug-glyph"));
    head.appendChild(node("span", "bug-kind", "Bug report"));
    var pill = node("span", "bug-pill");
    pill.setAttribute("role", "status");
    head.appendChild(pill);
    c.appendChild(head);
    c.appendChild(node("p", "bug-ctitle"));
    var route = node("dl", "bug-route");
    route.appendChild(node("dt", null, "From"));
    route.appendChild(node("dd", "r-from"));
    route.appendChild(node("dt", null, "To"));
    route.appendChild(node("dd", null, "RichOS on GitHub, as an issue anyone can read"));
    c.appendChild(route);
    var doc = node("div", "bug-doc");
    var title = node("h3", "bug-title");
    appendSegments(title, d.title);
    doc.appendChild(title);
    d.sections.forEach(function (s) {
      var sec = node("section", "bug-sec");
      sec.appendChild(node("h4", null, s.heading));
      (s.paragraphs || []).forEach(function (p) {
        var para = node("p");
        appendSegments(para, p);
        sec.appendChild(para);
      });
      if (s.steps && s.steps.length) {
        var ol = node("ol");
        s.steps.forEach(function (st) {
          var li = node("li");
          appendSegments(li, st);
          ol.appendChild(li);
        });
        sec.appendChild(ol);
      }
      doc.appendChild(sec);
    });
    c.appendChild(doc);
    var lo = node("p", "bug-leftout");
    lo.appendChild(svg(GLYPH_EYEOFF));
    lo.appendChild(node("span", "lo-text"));
    c.appendChild(lo);
    var warn = node("p", "bug-warn");
    warn.hidden = true;
    c.appendChild(warn);
    var hint = node("p", "bug-edithint", "Change any of the words above, or tell Rich what to change.");
    hint.hidden = true;
    c.appendChild(hint);
    c.appendChild(node("div", "bug-actions"));
    var sentRow = node("div", "bug-sentrow");
    sentRow.hidden = true;
    c.appendChild(sentRow);
    doc.addEventListener("input", function () { paintWarn(f); });
    title.addEventListener("keydown", function (e) { if (e.key === "Enter") e.preventDefault(); });
    return c;
  }

  function accountIsUser() {
    return !!(context && context.account && context.account.kind === "user");
  }
  function paintFrom(dd) {
    dd.textContent = "";
    if (accountIsUser()) {
      dd.appendChild(document.createTextNode("your GitHub account, "));
      dd.appendChild(node("b", null, "@" + context.account.login));
    } else {
      dd.appendChild(node("b", null, "the RichOS reporting account"));
      dd.appendChild(document.createTextNode(", because RichOS isn't signed in to a GitHub account of yours"));
    }
  }

  var KIND_WORDS = {
    conversation_name: ["conversation name", "conversation names"],
    company_name: ["company name", "company names"],
    person_name: ["person's name", "people's names"],
    folder_name: ["folder name", "folder names"],
    file_path: ["file path", "file paths"],
    email_address: ["email address", "email addresses"],
    private_word: ["private word", "private words"],
  };
  var NUM = ["no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"];
  /// The line under the sheet, counted from the stand-ins on it now, in Rust's words
  /// (`left_out_line`): a stand-in the user deleted is no longer counted.
  function leftOutText(f) {
    var subs = f.card.querySelectorAll(".bug-doc .bug-sub");
    var counts = {}, order = [];
    subs.forEach(function (s) {
      var k = s.dataset.kind;
      if (!counts[k]) { counts[k] = 0; order.push(k); }
      counts[k] += 1;
    });
    if (!order.length) return "Nothing private was in it, so nothing was left out. Anyone can read GitHub issues.";
    var parts = order.map(function (k) {
      var n = counts[k], w = KIND_WORDS[k] || ["private word", "private words"];
      return (NUM[n] || n) + " " + (n === 1 ? w[0] : w[1]);
    });
    var list = parts.length === 1 ? parts[0] : parts.slice(0, -1).join(", ") + " and " + parts[parts.length - 1];
    return "Left out, because anyone can read GitHub issues: " + list + ". The underlined words stand in for " + (subs.length === 1 ? "it" : "them") + "; point at one to see what it replaced.";
  }

  function paintWarn(f) {
    var w = f.card.querySelector(".bug-warn");
    var doc = f.card.querySelector(".bug-doc").cloneNode(true);
    doc.querySelectorAll(".bug-sub").forEach(function (s) { s.remove(); });
    var text = Array.prototype.map.call(doc.querySelectorAll(".bug-title,.bug-sec p,.bug-sec li"), function (n) { return n.textContent; }).join("\n");
    var found = privateIn(text, f).slice(0, 3);
    var show = found.length > 0 && (f.step === "editing" || f.step === "draft" || f.step === "queued");
    w.hidden = !show;
    w.textContent = "";
    if (show) {
      w.appendChild(node("strong", null, found.map(function (x) { return "“" + x + "”"; }).join(", ") + (found.length === 1 ? " looks" : " look") + " private."));
      w.appendChild(document.createTextNode(" Anyone can read this report on GitHub."));
    }
  }

  function button(label, primary, fn, id) {
    var b = node("button", "desk-btn" + (primary ? " desk-btn--confirm" : ""), label);
    b.type = "button";
    if (id) b.id = id;
    b.addEventListener("click", fn);
    return b;
  }

  function paintCard(f) {
    var c = f.card;
    if (!c) return;
    ["is-sending", "is-queued", "is-sent", "is-editing", "is-canceled"].forEach(function (k) { c.classList.remove(k); });
    var pill = c.querySelector(".bug-pill"), acts = c.querySelector(".bug-actions"), row = c.querySelector(".bug-sentrow");
    acts.textContent = "";
    row.hidden = true;
    acts.hidden = false;
    c.querySelector(".bug-edithint").hidden = f.step !== "editing";
    if (f.step !== "sent" && f.step !== "sending") paintFrom(c.querySelector(".r-from"));
    c.querySelector(".lo-text").textContent = leftOutText(f);
    var editable = f.step === "editing";
    c.querySelectorAll(".bug-title,.bug-sec p,.bug-sec li").forEach(function (n) {
      if (editable) n.setAttribute("contenteditable", "true");
      else n.removeAttribute("contenteditable");
    });
    switch (f.step) {
      case "draft":
        pill.textContent = f.edited ? "Not sent yet · changed" : "Not sent yet";
        acts.appendChild(button("Send report", true, function () { send(f); }, "bug-send"));
        acts.appendChild(button("Change it", false, function () { edit(f); }, "bug-change"));
        acts.appendChild(button("Cancel", false, function () { cancel(f); }, "bug-cancel"));
        break;
      case "editing":
        c.classList.add("is-editing");
        pill.textContent = "Changing it";
        acts.appendChild(button("Done", true, function () { finishEdit(f); }, "bug-done"));
        break;
      case "sending":
        c.classList.add("is-sending");
        pill.textContent = "Sending…";
        acts.hidden = true;
        break;
      case "queued":
        c.classList.add("is-queued");
        pill.textContent = "Waiting to send · saved on this Mac";
        acts.appendChild(button("Try now", true, function () { tryNow(f); }, "bug-try-now"));
        acts.appendChild(button("Change it", false, function () { edit(f); }, "bug-change"));
        acts.appendChild(button("Cancel report", false, function () { cancel(f); }, "bug-cancel"));
        break;
      case "sent":
        c.classList.add("is-sent");
        pill.textContent = "Sent · #" + f.issue.number;
        acts.hidden = true;
        row.hidden = false;
        row.textContent = "";
        var a = node("a", "bug-link", "Open issue #" + f.issue.number + " on GitHub");
        a.href = "#";
        a.dataset.issue = String(f.issue.number);
        row.appendChild(a);
        row.appendChild(node("span", null, "filed from " + (f.issue.account && f.issue.account.kind === "user" ? "@" + f.issue.account.login : "the RichOS reporting account")));
        break;
      case "canceled":
        c.classList.add("is-canceled");
        pill.textContent = "Canceled · nothing sent";
        c.querySelector(".bug-ctitle").textContent = c.querySelector(".bug-title").textContent;
        break;
    }
    paintWarn(f);
    window.requestAnimationFrame(paintStuck);
  }

  function edit(f) {
    if (f.step === "queued" && f.pendingId) {
      // Changing a waiting report takes it out of the queue: a changed report is approved again.
      bridge.invoke("bug_report_cancel", { id: f.pendingId }).catch(function () {});
      f.pendingId = null;
    }
    f.step = "editing";
    paintCard(f);
    paintComposers();
    var t = f.card.querySelector(".bug-title");
    t.focus();
    var r = document.createRange();
    r.selectNodeContents(t);
    r.collapse(false);
    var sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(r);
  }
  function finishEdit(f) {
    if (f.step !== "editing") return;
    f.edited = true;
    f.step = "draft";
    paintCard(f);
    paintComposers();
  }

  // ---- send, and what happens when it can't go ----------------------------------------------
  var WAITING_FIRST = {
    offline: "This Mac is offline, so the report didn't go out. Nothing is lost: it's saved on this Mac exactly as you approved it. I'll send it by myself as soon as you're back online, and tell you here when it's gone.",
    "github-down": "GitHub isn't answering right now, so the report didn't go out. Nothing is lost: it's saved on this Mac exactly as you approved it. I'll keep trying every few minutes and tell you here when it's filed.",
    "not-set-up": "The RichOS reporting account isn't set up on this Mac yet, so the report didn't go out. Nothing is lost: it's saved on this Mac exactly as you approved it. I'll send it by myself once the account is set up, and tell you here when it's filed.",
    refused: "GitHub didn't accept the report from the RichOS reporting account, so it didn't go out. Nothing is lost: it's saved on this Mac exactly as you approved it. I'll try again in a few minutes and tell you here when it's filed.",
  };
  var WAITING_AGAIN = {
    offline: "Still offline. It stays saved here and goes out by itself when you're back online.",
    "github-down": "GitHub still isn't answering. It stays saved here, and I'll keep trying.",
  };
  var CAME_BACK = {
    offline: "You're back online, so I sent your bug report.",
    "github-down": "GitHub is answering again, so I sent your bug report.",
  };

  function send(f) {
    f.step = "sending";
    paintCard(f);
    paintComposers();
    bridge.invoke("bug_report_send", { sheet: sheetOf(f) }).then(function (d) { delivered(f, d, null); }).catch(function () {
      f.step = "draft";
      paintCard(f);
      paintComposers();
      richSays(f, ["I couldn't save the report on this Mac, so nothing was sent. Press Send report to try again."]);
    });
  }

  function tryNow(f) {
    if (!f.pendingId) return send(f);
    var id = f.pendingId;
    f.step = "sending";
    paintCard(f);
    paintComposers();
    bridge.invoke("bug_report_try_now", { id: id }).then(function (d) {
      if (!d) return; // it went out by itself a moment ago; the event says so
      delivered(f, d, null);
    }).catch(function () {
      f.step = "queued";
      paintCard(f);
      paintComposers();
    });
  }

  function delivered(f, d, why) {
    if (d.state === "sent") return markSent(f, d, why);
    var again = f.queuedOnce;
    f.pendingId = d.id;
    f.reason = d.reason;
    f.queuedOnce = true;
    f.step = "queued";
    paintCard(f);
    paintComposers();
    if (why) return; // a retry by itself that failed again says nothing new
    richSays(f, [(again && (WAITING_AGAIN[d.reason] || "It still didn't go out. It stays saved here, and I'll keep trying.")) || WAITING_FIRST[d.reason] || WAITING_FIRST["github-down"]]);
  }

  function markSent(f, d, why) {
    f.issue = { number: d.number, account: d.account };
    f.pendingId = null;
    f.step = "sent";
    paintCard(f);
    paintComposers();
    var pill = f.card.querySelector(".bug-pill");
    pill.classList.remove("pop");
    void pill.offsetWidth;
    pill.classList.add("pop");
    var acct = d.account && d.account.kind === "user" ? "filed from your GitHub account, @" + d.account.login + "."
      : "filed from the RichOS reporting account, because RichOS isn't signed in to a GitHub account of yours.";
    var lead = why ? (CAME_BACK[why] || "I sent your bug report.") + " It's issue #" + d.number + " on GitHub, " : "Sent. It's issue #" + d.number + " on GitHub, ";
    var link = node("a", "bug-link", "github.com/WebDevBooster/richos/issues/" + d.number);
    link.href = "#";
    link.dataset.issue = String(d.number);
    richSays(f, [lead + acct, link]);
    if (why && host) host.toast("Your bug report went out: issue #" + d.number + " on GitHub.");
  }

  function cancel(f) {
    var id = f.pendingId;
    f.pendingId = null;
    f.step = "canceled";
    paintCard(f);
    paintComposers();
    if (id) bridge.invoke("bug_report_cancel", { id: id }).catch(function () {});
    richSays(f, ["Canceled. Nothing was sent."]);
  }

  /// A waiting report went out by itself (the shell's retry): the card and Rich say so, and a
  /// notice says the same wherever the user is. After a relaunch there is no card to update, so
  /// the notice is the whole of it.
  function onDelivered(payload) {
    if (!payload || !payload.delivery || payload.delivery.state !== "sent") return;
    var d = payload.delivery;
    var f = flows.filter(function (x) { return x.pendingId === d.id; })[0];
    if (f) markSent(f, d, f.reason || "github-down");
    else if (host) host.toast("Your bug report went out: issue #" + d.number + " on GitHub.");
  }

  // ---- the Rich panel ------------------------------------------------------------------------
  /// The panel's words are written when it is first shown rather than shipped in index.html:
  /// a hidden panel's text is still text on the page, and the contrast gate's floors count every
  /// text node of the bare shell (tests/contrast.js check 9z).
  function fillDock() {
    var dock = $("bugdock");
    if (dock.dataset.filled) return;
    dock.dataset.filled = "1";
    dock.querySelector(".bugdock-title").textContent = "Bust a bug";
    $("bugdock-x").textContent = "✕";
    $("bugdock-send").firstElementChild.textContent = "▷";
    $("bugdock-voice-label").textContent = "listening…";
  }
  function showDock() {
    fillDock();
    $("bugdock").hidden = false;
    document.body.classList.add("bug-dock-open");
    paintDock();
  }
  function hideDock() {
    $("bugdock").hidden = true;
    document.body.classList.remove("bug-dock-open");
    setDockVoice(false);
  }
  function paintDock() {
    var f = dockFlow();
    var busy = f && ["checking", "draft", "editing", "sending"].indexOf(f.step) !== -1;
    var x = $("bugdock-x");
    if (x) x.hidden = !!busy; // while a report waits on a decision, Send or Cancel is the way out
  }

  // ---- paint the sticky actions' edge only while they float over the report -----------------
  function paintStuck() {
    document.querySelectorAll(".bug-actions").forEach(function (a) {
      if (a.hidden) return;
      var sc = a.closest(".bugdock-msgs") || $("conversation");
      var card = a.closest(".bugcard");
      if (!sc || !card) return;
      a.classList.toggle("is-stuck", card.getBoundingClientRect().bottom > sc.getBoundingClientRect().bottom + 2);
    });
  }

  // ---- voice ---------------------------------------------------------------------------------
  /// While a report waits on the user's words, what they SAY goes to it rather than to Rich's
  /// conversation. The shell holds the spoken words back from the spine while this is on.
  var voiceHeld = false;
  function syncVoiceHold() {
    var f = liveFlow();
    var want = !!(f && TAKES_WORDS.indexOf(f.step) !== -1 && (f.dock ? dockVoice : host && host.voiceOn()));
    if (want === voiceHeld || !bridge) return;
    voiceHeld = want;
    bridge.invoke("bug_report_voice", { on: want }).catch(function () {});
  }
  function setDockVoice(on) {
    if (dockVoice === on) return;
    dockVoice = on;
    var t = $("bugdock-talk");
    if (t) t.setAttribute("aria-pressed", String(on));
    $("bugdock-form").hidden = on;
    $("bugdock-voice").hidden = !on;
    syncVoiceHold();
    if (!bridge) return;
    bridge.invoke(on ? "start_voice_capture" : "stop_voice_capture", { threadId: host ? host.activeThread() : null }).catch(function (e) {
      if (!on) return;
      dockVoice = false;
      if (t) t.setAttribute("aria-pressed", "false");
      $("bugdock-form").hidden = false;
      $("bugdock-voice").hidden = true;
      syncVoiceHold();
      var f = dockFlow();
      if (f) richSays(f, [typeof e === "string" && e ? e : "I couldn't open the microphone. Type it instead."]);
    });
  }

  /// A recognized utterance. True when it was the bug report's.
  function takeSpoken(text) {
    var f = liveFlow();
    if (!f || TAKES_WORDS.indexOf(f.step) === -1) return false;
    if (f.dock ? !dockVoice : !(host && host.voiceOn() && f.threadId === host.activeThread())) return false;
    say(f, text, true);
    return true;
  }

  /// Typed words from the conversation's composer. True when they were the bug report's.
  function takeWords(text, threadId) {
    var f = liveFlow();
    if (!f || f.dock || f.threadId !== threadId || TAKES_WORDS.indexOf(f.step) === -1) return false;
    say(f, text, false);
    return true;
  }

  // ---- what a stand-in replaced: seen only here --------------------------------------------
  function showSubTip(s) {
    var tip = $("bug-subtip");
    var k = KIND_WORDS[s.dataset.kind] || ["private word", "private words"];
    tip.textContent = "";
    tip.appendChild(node("b", null, "Stands in for “" + s.dataset.was + "”"));
    tip.appendChild(document.createTextNode(", " + (/^[aeiou]/.test(k[0]) ? "an " : "a ") + k[0] + ". Only you see this; it isn't in the report."));
    tip.hidden = false;
    var r = s.getBoundingClientRect(), w = tip.offsetWidth;
    tip.style.left = Math.max(12, Math.min(window.innerWidth - w - 12, r.left + r.width / 2 - w / 2)) + "px";
    tip.style.top = r.bottom + 10 + "px";
    void tip.offsetWidth;
    tip.classList.add("is-shown");
  }
  function hideSubTip() {
    var t = $("bug-subtip");
    if (!t) return;
    t.classList.remove("is-shown");
    t.hidden = true;
  }

  /// Show this thread's flows and only them (the conversation is redrawn for every thread).
  function sync() {
    var thread = host ? host.activeThread() : null;
    var shown = host ? host.view() === "conversation" : true;
    flows.forEach(function (f) {
      if (!f.dock) f.el.hidden = !(shown && f.threadId === thread);
    });
  }

  function wire() {
    var conv = $("conversation");
    if (conv) conv.addEventListener("scroll", paintStuck);
    window.addEventListener("resize", paintStuck);
    $("bugdock-msgs").addEventListener("scroll", paintStuck);
    $("bugdock-x").addEventListener("click", function () {
      var f = dockFlow();
      if (f && f.step === "ask") neverMind(f, true);
      if (f && f.step === "queued" && host) host.toast("Your bug report is saved on this Mac and goes out by itself when it can.");
      hideDock();
    });
    function dockSubmit() {
      var input = $("bugdock-input");
      var v = input.value.trim();
      if (!v) return;
      var f = dockFlow();
      if (!f || TAKES_WORDS.indexOf(f.step) === -1) return;
      input.value = "";
      paintDockSend();
      say(f, v, false);
    }
    $("bugdock-send").addEventListener("click", dockSubmit);
    $("bugdock-input").addEventListener("keydown", function (e) {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        dockSubmit();
      }
    });
    $("bugdock-input").addEventListener("input", paintDockSend);
    $("bugdock-talk").addEventListener("click", function () { setDockVoice(!dockVoice); });
    document.addEventListener("mouseover", function (e) { var s = e.target.closest && e.target.closest(".bug-sub"); if (s) showSubTip(s); });
    document.addEventListener("mouseout", function (e) { if (e.target.closest && e.target.closest(".bug-sub")) hideSubTip(); });
    document.addEventListener("focusin", function (e) { if (e.target.classList && e.target.classList.contains("bug-sub")) showSubTip(e.target); });
    document.addEventListener("focusout", function (e) { if (e.target.classList && e.target.classList.contains("bug-sub")) hideSubTip(); });
    document.addEventListener("scroll", hideSubTip, true);
    document.addEventListener("click", function (e) {
      var a = e.target.closest && e.target.closest(".bug-link");
      if (!a) return;
      e.preventDefault();
      bridge.invoke("bug_report_open_issue", { number: Number(a.dataset.issue) }).catch(function (err) {
        if (host) host.toast(typeof err === "string" && err ? err : "This Mac wouldn't open the issue. It's at github.com/WebDevBooster/richos/issues/" + a.dataset.issue + ".");
      });
    });
  }
  function paintDockSend() {
    var i = $("bugdock-input");
    $("bugdock-send").classList.toggle("is-live", i.value.trim().length > 0);
    i.style.height = "auto";
    i.style.height = Math.min(i.scrollHeight, 120) + "px";
  }

  function refreshContext() {
    return bridge.invoke("bug_report_context").then(function (c) {
      context = c;
      flows.forEach(function (f) { if (f.card && f.step !== "sent" && f.step !== "canceled") paintCard(f); });
    }).catch(function () {});
  }

  return {
    /// Called by main.js once the shell is up. `h` carries the conversation's own facts and
    /// controls, so this file never reaches into main.js's variables.
    init: function (h) {
      host = h;
      bridge = h.bridge;
      wire();
      refreshContext();
      // A webview reload must not leave the shell holding spoken words back for a report that
      // is no longer on screen.
      bridge.invoke("bug_report_voice", { on: false }).catch(function () {});
      bridge.listen("rich://bug-report", function (e) { onDelivered(e.payload); });
      bridge.listen("rich://voice-state", function (e) {
        if (!dockVoice || !e.payload) return;
        var label = $("bugdock-voice-label");
        if (label) label.textContent = e.payload.state === "hearing" ? "hearing you…" : e.payload.state === "thinking" ? "got it…" : "listening…";
        if (e.payload.state === "off") setDockVoice(false);
      });
      // The panel's own talk button: main.js's voice mode is off then, so its listener does not
      // take the words and this one does. (With the composer's voice mode on, main.js asks
      // `takeSpoken` itself, before it draws anything.)
      bridge.listen("rich://voice-transcript", function (e) {
        if (dockVoice && e.payload && e.payload.text) takeSpoken(e.payload.text);
      });
      if (window.RichSettings && window.RichSettings.registerBugReport) {
        window.RichSettings.registerBugReport({ open: function () { refreshContext(); start(); } });
      }
    },
    start: start,
    sync: sync,
    takeWords: takeWords,
    takeSpoken: takeSpoken,
    placeholder: function (threadId) {
      var f = liveFlow();
      return f && !f.dock && f.threadId === threadId ? placeholderFor(f) : null;
    },
    /// The voice hold follows main.js's voice mode, which only main.js sees change.
    voiceChanged: syncVoiceHold,
    /// READ-ONLY, for the acceptance harness.
    state: function () {
      return flows.map(function (f) { return { step: f.step, dock: f.dock, threadId: f.threadId, pendingId: f.pendingId || null, issue: f.issue || null, screen: f.screen.key }; });
    },
  };
})();
