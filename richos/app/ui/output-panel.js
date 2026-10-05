// THE OUTPUT PANEL — slice S4 of the Output side panel PRD
// (richos-hq `docs/prds/2026-10-05-output-side-panel.md` §6, §12.4; design: round 17's
// `output.html`, frozen).
//
// The CEO, 2026-10-05: "a button here … ideally, at the top and at the bottom, so that the user
// can easily just click a button. And the entire, this entire side panel would open … with a
// list of all the files … that were output by this entire thread. This is what we need."
//
// WHAT THIS FILE OWNS: the two Output buttons (`#out-top`, `#out-bottom`) and their count, the
// docked panel (`#outpanel`) with its list, its empty and loading and unreadable states, a file's
// own view inside the panel, and the hooks the conversation's links call (`links`). The list
// comes from `list_output` (S3, `src-tauri/src/output_files.rs`), which converges the thread's
// output record and re-stats every file; `rich://output` says when the record gained files.
//
// WHAT IT DOES NOT DO YET, said here so nobody reads a gap as a bug. Each is a later slice of
// the same PRD, and each has a named hook below rather than a half-built version:
//   * previews by kind (S5): the file view shows the file's facts and, for a missing file, the
//     §6.7 sentence; `hooks.viewer(entry, box)` is where S5 renders;
//   * the per-file actions — Open in <app>, Open with…, Show in Finder, Save a copy…, Copy path
//     (S6) and Add to chat (S7): `hooks.rowActions(entry, row)` and `hooks.fileTools(entry, box)`;
//   * the divider, the stop, the snap and the floating composer (S9): the panel's width is the
//     `--output-width` custom property, 400px, and nothing here drags it.
//
// NO STRING FROM THE RECORD EVER BECOMES MARKUP. File names, folders, worker names and his own
// words are text nodes; the only markup built here is this file's own, through `node()`.
"use strict";

(function () {
  const SVG_NS = "http://www.w3.org/2000/svg";
  /// Nothing is said for the first 150 ms of a read — a local read is milliseconds (§6.7).
  const LOOKING_AFTER_MS = 150;
  /// The tile shows at most three letters; the name beside it carries the real extension (§4.5).
  const KIND_LABEL = { docx: "doc", xlsx: "xls", pptx: "ppt" };
  /// A family of formats rather than one: the tile shows the file's own extension instead.
  const FAMILY_KINDS = { png: true, mp4: true, audio: true, other: true };
  /// The facts line's word for a kind (§6.4). S5 replaces the facts with the preview's own.
  const KIND_WORD = {
    md: "Markdown",
    txt: "Text",
    csv: "Comma-separated",
    xlsx: "Spreadsheet",
    docx: "Document",
    pptx: "Presentation",
    pdf: "PDF",
    png: "Image",
    mp4: "Video",
    audio: "Audio",
  };
  /// VERBATIM from `MISSING` in `src-tauri/src/output_files.rs` (§6.7). The record says the
  /// file is gone; the sentence is the shell's, so the two can never say different things.
  const MISSING_SENTENCE =
    "This file is no longer where it was written. If it was moved, open it from its new place; if Rich writes it again, it will be listed here.";
  const MISSING_LINE = "No longer where it was written";

  const PATHS = {
    file: ["M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z", "M14 3v5h5"],
    left: ["m15 18-6-6 6-6"],
    right: ["m9 18 6-6-6-6"],
  };

  let bridge = null;
  let ctx = {};

  const state = {
    thread: null,
    /// The projected record as `list_output` answered it, or null before the first answer.
    list: null,
    /// The shell's own sentence when the record could not be read (§6.7), else null.
    error: null,
    loading: false,
    ticket: 0,
    open: false,
    view: "list", // "list" | "file"
    file: null, // the output id the file view shows
    /// The row kept selected when the file view steps back to the list (§6.4).
    selected: null,
    /// When the read in flight started, so *Looking…* waits its 150 ms whenever it is drawn.
    loadingSince: 0,
    /// Where focus goes when the panel closes: the button that opened it, or "conversation".
    returnTo: null,
    /// Bumped whenever the list changes, so the conversation re-renders its links (`links.rev`).
    rev: 0,
  };

  const el = (id) => document.getElementById(id);

  function node(tag, cls, text) {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  }

  function icon(name) {
    const svg = document.createElementNS(SVG_NS, "svg");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.setAttribute("fill", "none");
    svg.setAttribute("stroke", "currentColor");
    svg.setAttribute("stroke-width", "2");
    svg.setAttribute("stroke-linecap", "round");
    svg.setAttribute("stroke-linejoin", "round");
    svg.setAttribute("aria-hidden", "true");
    svg.setAttribute("focusable", "false");
    for (const d of PATHS[name]) {
      const p = document.createElementNS(SVG_NS, "path");
      p.setAttribute("d", d);
      svg.appendChild(p);
    }
    return svg;
  }

  function files() {
    return state.list ? state.list.files : [];
  }

  function entry(id) {
    return files().find((f) => f.id === id) || null;
  }

  function filesWord(n) {
    return n === 1 ? "1 file" : n + " files";
  }

  function extension(name) {
    const at = String(name || "").lastIndexOf(".");
    return at > 0 ? name.slice(at + 1).toLowerCase() : "";
  }

  function tileLabel(e) {
    if (FAMILY_KINDS[e.kind]) return extension(e.name).slice(0, 3);
    return KIND_LABEL[e.kind] || e.kind;
  }

  /// Decimal units, as Finder shows them — the same rule as `human_size` in output_files.rs.
  function humanSize(bytes) {
    if (typeof bytes !== "number") return "";
    if (bytes < 1000) return bytes + (bytes === 1 ? " byte" : " bytes");
    if (bytes < 1e6) return Math.round(bytes / 1e3) + " KB";
    if (bytes < 1e9) return (bytes / 1e6).toFixed(1) + " MB";
    return (bytes / 1e9).toFixed(1) + " GB";
  }

  function sameDay(a, b) {
    return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
  }

  /// *Today 9:12 AM*, *Yesterday 4:12 PM*, *Just now*, *Oct 3 4:12 PM* — the group's time.
  function whenLabel(ms) {
    if (typeof ms !== "number") return "";
    const nowMs = Date.now();
    if (nowMs - ms >= 0 && nowMs - ms < 60000) return "Just now";
    const d = new Date(ms);
    const n = new Date(nowMs);
    const clock = d.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
    if (sameDay(d, n)) return "Today " + clock;
    const y = new Date(nowMs);
    y.setDate(y.getDate() - 1);
    if (sameDay(d, y)) return "Yesterday " + clock;
    const opts = { month: "short", day: "numeric" };
    if (d.getFullYear() !== n.getFullYear()) opts.year = "numeric";
    return d.toLocaleDateString(undefined, opts) + " " + clock;
  }

  // ---- the buttons -----------------------------------------------------------------------

  function buttons() {
    return [el("out-top"), el("out-bottom")].filter(Boolean);
  }

  /// The count on both buttons, their names and `aria-pressed`. With no answer yet, or a record
  /// that could not be read, there is no count and the name says only "Output" — never a number
  /// nobody has read (§6.7: "the buttons show no count").
  function paintButtons() {
    const known = !!state.list && !state.error;
    const n = known ? state.list.count : 0;
    const name = !known
      ? "Output"
      : n === 0
        ? "Output — nothing produced yet in this thread"
        : "Output — " + filesWord(n) + " from this thread";
    for (const b of buttons()) {
      b.hidden = !state.thread;
      b.classList.toggle("is-empty", !known || n === 0);
      b.querySelector("[data-count]").textContent = known && n > 0 ? String(n) : "";
      b.setAttribute("aria-label", name);
      b.setAttribute("aria-pressed", state.open ? "true" : "false");
    }
  }

  /// One tick on both counts when files arrive (§6.2). `prefers-reduced-motion` removes the
  /// animation in the stylesheet; the number still changes.
  function tick() {
    for (const c of document.querySelectorAll(".out-btn .out-count")) {
      c.classList.remove("tick");
      void c.offsetWidth;
      c.classList.add("tick");
    }
  }

  // ---- reading the record ----------------------------------------------------------------

  /// Read the active thread's record. `opts.arrival` marks a read caused by `rich://output`:
  /// what is new arrives with the rise and the scroll position of the list is kept (§6.6).
  async function load(opts) {
    opts = opts || {};
    const thread = state.thread;
    if (!thread || !bridge) return;
    const ticket = ++state.ticket;
    const before = new Set(files().map((f) => f.id));
    const beforeGroups = new Set(groupsOf(files()).map((g) => g.key));
    state.loading = true;
    state.loadingSince = Date.now();
    const looking = window.setTimeout(() => {
      if (ticket === state.ticket && state.loading && state.open && state.view === "list" && !state.list) render();
    }, LOOKING_AFTER_MS);
    let list = null;
    let error = null;
    try {
      list = await bridge.invoke("list_output", { threadId: thread });
    } catch (e) {
      error = String(e && e.message ? e.message : e);
    }
    window.clearTimeout(looking);
    if (ticket !== state.ticket || thread !== state.thread) return;
    state.loading = false;
    const previousCount = state.list && !state.error ? state.list.count : null;
    if (error) {
      state.error = error;
      state.list = null;
    } else {
      state.error = null;
      state.list = normalize(list);
    }
    state.rev += 1;
    paintButtons();
    if (opts.arrival && state.list && previousCount !== null && state.list.count !== previousCount) {
      tick();
      if (ctx.announce) ctx.announce(filesWord(state.list.count) + " from this thread");
    }
    if (ctx.onLinksChanged) ctx.onLinksChanged();
    if (!state.open) return;
    if (state.view === "file") {
      if (entry(state.file)) renderFile(state.file, { keepFocus: true });
      else showList({ keepFocus: true });
      return;
    }
    const body = el("op-body");
    const top = body.scrollTop;
    render({ arrived: opts.arrival ? { files: before, groups: beforeGroups } : null });
    if (opts.arrival) body.scrollTop = top;
  }

  function normalize(list) {
    const out = list && typeof list === "object" ? list : {};
    const filesIn = Array.isArray(out.files) ? out.files : [];
    return {
      files: filesIn,
      count: typeof out.count === "number" ? out.count : filesIn.length,
      missing: typeof out.missing === "number" ? out.missing : filesIn.filter((f) => !f.exists).length,
    };
  }

  // ---- the list ----------------------------------------------------------------------------

  /// One group per turn, newest first, in the order the record lists its files (newest first by
  /// latest write); a write no turn could be named for sits in a last group (§6.3).
  function groupsOf(list) {
    const groups = [];
    const byKey = new Map();
    let between = null;
    for (const f of list) {
      if (!f.turnId) {
        if (!between) between = { key: "between", turnId: null, files: [] };
        between.files.push(f);
        continue;
      }
      let g = byKey.get(f.turnId);
      if (!g) {
        g = { key: "turn:" + f.turnId, turnId: f.turnId, files: [] };
        byKey.set(f.turnId, g);
        groups.push(g);
      }
      g.files.push(f);
    }
    if (between) groups.push(between);
    return groups;
  }

  /// His words and the time, read from the conversation the shell has loaded. A turn with no
  /// words of his is one Rich started (§6.3: *Rich reached out*); a turn the conversation does
  /// not hold says only when its files were written, rather than guessing who asked.
  function groupHead(g) {
    const head = node("div", "og-head");
    const latest = Math.max.apply(null, g.files.map((f) => f.writtenAt || 0));
    if (!g.turnId) {
      head.appendChild(node("span", "og-words", "Between turns"));
      const t = node("time", null, whenLabel(latest));
      head.appendChild(t);
      head.title = "Between turns · " + whenLabel(latest);
      return head;
    }
    const info = ctx.turnInfo ? ctx.turnInfo(g.turnId) : null;
    const at = info && typeof info.at === "number" ? info.at : latest;
    let titleParts = [];
    if (info && info.asked) {
      head.appendChild(node("q", "og-words", info.asked));
      titleParts.push("“" + info.asked + "”");
    } else if (info) {
      head.appendChild(node("span", "og-words", "Rich reached out"));
      titleParts.push("Rich reached out");
    } else {
      head.appendChild(node("span", "og-words"));
    }
    head.appendChild(node("time", null, whenLabel(at)));
    titleParts.push(whenLabel(at));
    if (info && typeof info.workedMs === "number" && window.RichTimeline && window.RichTimeline.formatDuration) {
      titleParts.push("worked for " + window.RichTimeline.formatDuration(info.workedMs));
    }
    head.title = titleParts.join(" · ");
    return head;
  }

  function renderRow(f) {
    const row = node("div", "orow");
    row.dataset.output = f.id;
    row.setAttribute("role", "button");
    row.tabIndex = 0;
    if (!f.exists) row.classList.add("is-missing");
    if (state.view === "list" && state.selected === f.id) row.classList.add("is-open");
    const tile = node("span", "okind", tileLabel(f));
    tile.setAttribute("aria-hidden", "true");
    row.appendChild(tile);
    const body = node("span", "obody");
    body.appendChild(node("span", "oname", f.name));
    body.appendChild(node("span", "opath", f.exists ? f.folder + "/" : MISSING_LINE));
    if (f.actor === "worker" && f.workerName) body.appendChild(node("span", "oby", "by " + f.workerName));
    row.appendChild(body);
    // S6's hover actions (Open in <app>, ⋯) and the row's context menu land here.
    if (hooks.rowActions) hooks.rowActions(f, row);
    row.addEventListener("click", (e) => {
      if (e.target.closest("[data-act]")) return;
      showFile(f.id);
    });
    row.addEventListener("keydown", (e) => {
      if (e.target !== row) return;
      if (e.key === "Enter" || e.key === " ") {
        e.preventDefault();
        showFile(f.id);
      }
    });
    return row;
  }

  function setHead(eyebrow, title, sub) {
    el("op-eyebrow").textContent = eyebrow;
    el("op-title").textContent = title;
    el("op-sub").textContent = sub || "";
    el("op-sub").hidden = !sub;
  }

  function render(opts) {
    opts = opts || {};
    const body = el("op-body");
    const view = node("div", "op-view");
    body.dataset.view = "list";
    const title = ctx.threadTitle ? ctx.threadTitle(state.thread) : "";
    if (state.error) {
      setHead("Output", "Output", null);
      const box = node("div", "op-state");
      box.appendChild(node("p", "op-state-line", state.error));
      const again = node("button", "op-again", "Try again");
      again.type = "button";
      again.addEventListener("click", () => load());
      box.appendChild(again);
      view.appendChild(box);
    } else if (!state.list) {
      setHead("Output", "Output", null);
      // Nothing for the first 150 ms; after that the body says it is looking (§6.7). Never a spinner.
      if (state.loading && Date.now() - state.loadingSince >= LOOKING_AFTER_MS) {
        view.appendChild(node("p", "op-state-line op-looking", "Looking…"));
      }
    } else if (!state.list.files.length) {
      setHead("Output", "Nothing produced yet", title);
      const empty = node("div", "op-empty");
      empty.tabIndex = -1;
      const glyph = node("div", "op-empty-glyph");
      glyph.appendChild(icon("file"));
      empty.appendChild(glyph);
      const p = node("p", "op-empty-line");
      p.appendChild(document.createTextNode("Nothing in "));
      p.appendChild(node("b", null, title));
      p.appendChild(
        document.createTextNode(
          " has produced a file yet. The moment Rich or the team writes one, it is listed here — and the count on the Output button says so."
        )
      );
      empty.appendChild(p);
      view.appendChild(empty);
    } else {
      const n = state.list.count;
      const missing = state.list.missing || 0;
      setHead(
        "Output",
        filesWord(n) + " from this thread" + (missing ? " · " + missing + " no longer where " + (missing === 1 ? "it was" : "they were") + " written" : ""),
        "Everything written here, newest first."
      );
      for (const g of groupsOf(state.list.files)) {
        const section = node("section", "og");
        section.dataset.group = g.key;
        if (g.turnId) section.dataset.turn = g.turnId;
        if (opts.arrived && !opts.arrived.groups.has(g.key)) section.classList.add("arrive-group");
        section.appendChild(groupHead(g));
        for (const f of g.files) section.appendChild(renderRow(f));
        view.appendChild(section);
      }
    }
    body.textContent = "";
    body.appendChild(view);
  }

  function showList(opts) {
    opts = opts || {};
    state.view = "list";
    state.file = null;
    render();
    const body = el("op-body");
    if (opts.focusFile) {
      const row = body.querySelector('.orow[data-output="' + cssEscape(opts.focusFile) + '"]');
      if (row) {
        row.classList.add("is-open");
        state.selected = opts.focusFile;
        if (!opts.keepFocus) row.focus({ preventScroll: true });
        row.scrollIntoView({ block: "nearest" });
        return;
      }
    }
    if (!opts.keepFocus) focusFirst();
  }

  function focusFirst() {
    const body = el("op-body");
    const target = body.querySelector(".orow") || body.querySelector(".op-empty") || body.querySelector(".op-again");
    if (target) target.focus({ preventScroll: true });
    else body.focus({ preventScroll: true });
  }

  // ---- one file ----------------------------------------------------------------------------

  function showFile(id, opts) {
    if (!entry(id)) return showList(opts);
    state.view = "file";
    state.file = id;
    state.selected = id;
    renderFile(id, opts);
  }

  /// The file's own view inside the panel (§6.4): the way back to the list, `‹ ›` and *k of N*,
  /// its path, and what S4 can say about it — its kind and size, or that it is no longer there.
  function renderFile(id, opts) {
    opts = opts || {};
    const f = entry(id);
    const list = files();
    const idx = list.indexOf(f);
    const body = el("op-body");
    body.dataset.view = "file";
    let sub = f.exists ? "Written " + whenLabel(f.writtenAt).replace(/^(Today|Yesterday|Just now)/, (m) => m.toLowerCase()) : MISSING_LINE;
    if (f.exists && typeof f.bytes === "number") sub += " · " + humanSize(f.bytes);
    if (f.firstTurnId && f.turnId && f.firstTurnId !== f.turnId) sub += " · also written earlier in this thread";
    setHead("Output", f.name, sub);

    const view = node("div", "op-view");
    const bar = node("div", "of-bar");
    const back = node("button", "of-back");
    back.type = "button";
    back.id = "of-back";
    back.appendChild(icon("left"));
    back.appendChild(node("span", null, "All output · " + list.length));
    back.addEventListener("click", () => showList({ focusFile: id }));
    bar.appendChild(back);
    const nav = node("span", "of-nav");
    const prev = node("button", "of-step");
    prev.type = "button";
    prev.setAttribute("aria-label", "Previous file");
    prev.title = "Previous file";
    prev.appendChild(icon("left"));
    const next = node("button", "of-step");
    next.type = "button";
    next.setAttribute("aria-label", "Next file");
    next.title = "Next file";
    next.appendChild(icon("right"));
    prev.addEventListener("click", () => showFile(list[(idx - 1 + list.length) % list.length].id, { focusStep: "prev" }));
    next.addEventListener("click", () => showFile(list[(idx + 1) % list.length].id, { focusStep: "next" }));
    nav.appendChild(prev);
    nav.appendChild(node("span", "of-k", idx + 1 + " of " + list.length));
    nav.appendChild(next);
    bar.appendChild(nav);
    view.appendChild(bar);

    // S6's Open in <app> / ▾ / Show in Finder / Save a copy… / ⋯ and S5's Preview | Source.
    if (hooks.fileTools) {
      const tools = node("div", "of-tools");
      hooks.fileTools(f, tools);
      if (tools.childNodes.length) view.appendChild(tools);
    }

    const pathLine = node("div", "of-path");
    const code = node("code");
    // Broken at its own joints (`/`, `.`, `-`, `_`), never mid-word: main.js's `wrapPathText`.
    if (window.RichWrapPath) code.appendChild(window.RichWrapPath(f.folder + "/" + f.name));
    else code.textContent = f.folder + "/" + f.name;
    code.title = f.path;
    pathLine.appendChild(code);
    view.appendChild(pathLine);

    const viewer = node("div", "of-view");
    viewer.id = "op-viewer";
    if (!f.exists) {
      viewer.appendChild(node("p", "of-missing", MISSING_SENTENCE));
    } else if (hooks.viewer) {
      hooks.viewer(f, viewer);
    } else {
      const facts = node("p", "of-meta");
      facts.appendChild(node("b", null, KIND_WORD[f.kind] || (extension(f.name) ? extension(f.name).toUpperCase() : "File")));
      if (typeof f.bytes === "number") {
        const dot = node("span", null, "·");
        dot.setAttribute("aria-hidden", "true");
        facts.appendChild(dot);
        facts.appendChild(node("span", null, humanSize(f.bytes)));
      }
      viewer.appendChild(facts);
    }
    view.appendChild(viewer);

    body.textContent = "";
    body.appendChild(view);
    body.scrollTop = 0;
    if (opts.keepFocus) return;
    if (opts.focusStep === "prev") prev.focus({ preventScroll: true });
    else if (opts.focusStep === "next") next.focus({ preventScroll: true });
    else back.focus({ preventScroll: true });
  }

  // ---- open, close, step back ----------------------------------------------------------------

  function isWide() {
    return ctx.isWide ? ctx.isWide() : true;
  }

  /// The scrim exists only where the panel overlays the conversation (below 1180px, §6.1).
  /// Called on open and whenever the window crosses a breakpoint.
  function syncScrim() {
    const scrim = el("outpanel-scrim");
    const panel = el("outpanel");
    if (!scrim || !panel) return;
    scrim.hidden = panel.hidden || isWide();
  }

  /// Open the panel. `opts.returnTo` is the element focus goes back to on close, or
  /// "conversation" when it was opened from a link in the conversation (§6.8).
  function open(opts) {
    opts = opts || {};
    if (!state.thread) return;
    const panel = el("outpanel");
    const already = state.open && !panel.hidden;
    // One right-hand pane at a time (§6.1): the worker inspector and the under-the-hood
    // slide-over close before this one opens.
    if (!already && ctx.onOpen) ctx.onOpen();
    state.open = true;
    state.returnTo = opts.returnTo || state.returnTo || null;
    panel.hidden = false;
    syncScrim();
    document.body.classList.add("output-open");
    if (!already) {
      panel.classList.remove("is-opening");
      void panel.offsetWidth;
      panel.classList.add("is-opening");
    }
    paintButtons();
    if (opts.file) return showFile(opts.file, opts);
    showList(opts);
  }

  function close(opts) {
    opts = opts || {};
    const panel = el("outpanel");
    const wasOpen = state.open || !panel.hidden;
    state.open = false;
    state.view = "list";
    state.file = null;
    state.selected = null;
    panel.hidden = true;
    panel.classList.remove("is-opening");
    el("outpanel-scrim").hidden = true;
    document.body.classList.remove("output-open");
    paintButtons();
    const back = state.returnTo;
    state.returnTo = null;
    if (!wasOpen || opts.keepFocus) return;
    if (back && back !== "conversation" && back.isConnected && back.getClientRects().length) back.focus({ preventScroll: true });
    else if (ctx.focusConversation) ctx.focusConversation();
  }

  function toggle(opts) {
    if (state.open && !el("outpanel").hidden) close();
    else open(opts);
  }

  /// Escape, one level at a time (§6.8): the file view to the list with the row kept selected,
  /// then the list to closed. Read off the DOM as well as the state, because the Escape rule's
  /// own suite opens a surface by un-hiding it.
  function escape() {
    if (state.open && state.view === "file" && state.file) {
      showList({ focusFile: state.file });
      return;
    }
    close();
  }

  // ---- the links in the conversation (§6.5) -------------------------------------------------

  function flash(n) {
    if (!n) return;
    n.classList.remove("flash");
    void n.offsetWidth;
    n.classList.add("flash");
  }

  /// A file named in Rich's message: the link pulses once and the panel opens on that file.
  function openFile(id, from) {
    flash(from);
    open({ file: id, returnTo: "conversation" });
  }

  /// The turn's *Wrote N files*: the panel opens at the list and that turn's group pulses once.
  function openGroup(turnId, from) {
    flash(from);
    open({ returnTo: "conversation", keepFocus: true });
    if (state.view !== "list") showList({ keepFocus: true });
    const g = el("op-body").querySelector('.og[data-turn="' + cssEscape(turnId) + '"]');
    if (!g) return focusFirst();
    g.scrollIntoView({ block: "start" });
    flash(g);
    const first = g.querySelector(".orow");
    if (first) first.focus({ preventScroll: true });
  }

  /// What `timeline.js` asks of the record. Only RECORDED files become links: a name nothing
  /// witnessed stays a code span. A name is matched only when it is unique in the thread.
  const links = {
    rev: () => state.rev,
    forText(text) {
      const t = String(text || "").trim();
      if (!t || !state.list) return null;
      let byName = null;
      let names = 0;
      for (const f of state.list.files) {
        if (t === f.path || t === f.folder + "/" + f.name) return f;
        if (t === f.name) {
          names += 1;
          byName = f;
        }
      }
      return names === 1 ? byName : null;
    },
    forTurn(turnId) {
      if (!turnId || !state.list) return [];
      return state.list.files.filter((f) => f.turnId === turnId);
    },
    openFile,
    openGroup,
  };

  /// The hooks the later slices fill (S5 previews, S6 actions). Empty in S4.
  const hooks = { viewer: null, rowActions: null, fileTools: null };

  function cssEscape(s) {
    return String(s).replace(/(["\\])/g, "\\$1");
  }

  // ---- the thread ------------------------------------------------------------------------------

  /// The thread the conversation shows, or null when none is (the home screen, a company's
  /// overview, the unbound screen). A different thread empties the list and reads its own; an
  /// open panel shows the new thread's list (§4.6, §6.7).
  function setThread(threadId) {
    const next = threadId || null;
    if (next === state.thread) {
      paintButtons();
      return;
    }
    state.thread = next;
    state.list = null;
    state.error = null;
    state.loading = false;
    state.ticket += 1;
    state.rev += 1;
    state.view = "list";
    state.file = null;
    state.selected = null;
    if (!next) {
      close({ keepFocus: true });
      paintButtons();
      return;
    }
    paintButtons();
    if (state.open) render();
    load();
  }

  /// THE TOP BUTTON IS NEVER UNDER THE SETTINGS CLUSTER. `#stage-header` reserves the settings
  /// button's 40px lane (`--chrome-lane`, 66px), and the cluster grows LEFTWARD when the update
  /// cue arrives beside the button (`.settings` is a fixed row, `.update-cue` up to 22rem) — which
  /// put the cue straight over `#out-top`, so the button could be neither seen nor pressed
  /// (found in `shots-updates`). The cluster's measured width is published as
  /// `--chrome-lane-live`, and the header reserves whichever lane is wider.
  function watchChromeLane() {
    const settings = document.querySelector(".settings");
    if (!settings || typeof ResizeObserver !== "function") return false;
    const publish = () => {
      const box = settings.getBoundingClientRect();
      const lane = box.width > 0 ? Math.ceil(window.innerWidth - box.left + 8) : 0;
      document.documentElement.style.setProperty("--chrome-lane-live", lane + "px");
    };
    new ResizeObserver(publish).observe(settings);
    window.addEventListener("resize", publish);
    publish();
    return true;
  }

  function init(options) {
    bridge = options.bridge;
    ctx = options;
    if (!watchChromeLane()) {
      // `settings-button.js` mounts the cluster on its own schedule; look again once it has.
      let tries = 0;
      const retry = () => {
        if (watchChromeLane() || ++tries > 120) return;
        window.requestAnimationFrame(retry);
      };
      window.requestAnimationFrame(retry);
    }
    for (const b of buttons()) {
      b.addEventListener("click", () => toggle({ returnTo: b }));
    }
    el("op-close").addEventListener("click", () => close());
    el("outpanel-scrim").addEventListener("click", () => close());
    bridge.listen("rich://output", ({ payload }) => {
      if (!payload || payload.threadId !== state.thread) return;
      load({ arrival: true });
    });
    paintButtons();
  }

  window.RichOutput = {
    init,
    setThread,
    open,
    close,
    toggle,
    escape,
    syncScrim,
    isOpen: () => state.open && !el("outpanel").hidden,
    links,
    hooks,
    reload: () => load(),
    /// Read-only, for the acceptance suite: what the panel believes, beside what it painted.
    snapshot: () => ({
      thread: state.thread,
      open: state.open,
      view: state.view,
      file: state.file,
      count: state.list && !state.error ? state.list.count : null,
      error: state.error,
      rev: state.rev,
    }),
  };
})();
