/* Assignment state comes from the durable controller, never a model's end_turn. */
(function () {
  "use strict";
  let bridge, root, thread, current, assignments = [], generation = 0, polling = false;
  let lastError = "", pickerOpen = false, decisionOpen = false, historyOpen = false, editor = null, working = false, archiveConfirm = false;
  const pausing = new Set();
  const labels = { shared_checks: "Completion checks for every step", retry_above: "Read more above (retry available)", retry_below: "Read more below (retry available)", agreed_delivery: "What Rich agreed to deliver", imported_checks: "Completion checks", review_closed: "Review decision", pausing: "Pausing…", needs_input: "need you", needs_one: "needs you", ready: "Queued", waiting: "Retrying automatically", needs_decision: "Waiting for your decision",
    running: "Working", paused: "Paused", needs_attention: "Needs attention", completed: "Completed",
    pending: "Not started", verifying: "Checking the result", passed: "Checks passed", canceled: "Ended without completion" };
  function node(tag, text, cls) { const e = document.createElement(tag); if (text) e.textContent = text; if (cls) e.className = cls; return e; }
  function button(text, fn, key) { const b = node("button", text); b.type = "button"; if (key) b.dataset[key] = ""; b.addEventListener("click", fn); return b; }
  function attention(element) {
    element.classList.add("run-attention");
    const mark = node("span", null, "run-attention-marker");
    mark.dataset.contrastRole = "indicator"; mark.setAttribute("aria-hidden", "true"); element.prepend(mark);
  }
  function fitReading() { if (root && !root.hidden) root.style.setProperty("--run-reading-room", Math.max(0, root.getBoundingClientRect().top - 8) + "px"); }
  function error(e) { lastError = String(e); render(); }
  function all() { const rows = assignments.filter(a => a.runId !== current?.runId); if (current) rows.push(current); return rows; }
  function needs(a) { return !["completed", "canceled"].includes(a.state) && (a.state === "needs_decision" || a.tasks.some(t => t.decision || t.permission)); }
  function title(a) { return a.goal.split("\n")[0]; }
  function date(a) { return a.createdAt ? new Date(a.createdAt).toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }) : ""; }
  function identity(a) {
    const duplicates = all().filter(b => title(b) === title(a));
    if (duplicates.length < 2) return title(a);
    const when = date(a), collision = !when || duplicates.some(b => b.runId !== a.runId && date(b) === when);
    const suffix = all().some(b => b.runId !== a.runId && b.runId.slice(0, 8) === a.runId.slice(0, 8)) ? a.runId : a.runId.slice(0, 8);
    return `${title(a)} (${when}${collision ? (when ? ", " : "") + suffix : ""})`;
  }
  // Scroll cues remain visible with macOS overlay scrollbars. Questions and answers
  // share ONE reading flow, so no answer is pinned under an unseen paragraph.
  function readingPanel(body, kind, close) {
    const panel = node("section", null, "run-reading " + kind);
    panel.setAttribute("aria-label", kind === "run-choices-panel" ? "Choose assignment" : "Assignment details");
    const toolbar = node("div", null, "run-reading-controls");
    toolbar.append(button("Back to conversation", close, "runDismiss"));
    const above = button("Read more above", () => { body.scrollTop -= Math.max(40, body.clientHeight * .8); cue(); }, "runPrevious");
    const below = button("Read more below", () => { body.scrollTop += Math.max(40, body.clientHeight * .8); cue(); }, "runMore");
    const next = node("div", null, "run-reading-next"), rule = node("span", null, "run-reading-rule");
    rule.dataset.contrastRole = "indicator"; rule.setAttribute("aria-hidden", "true"); next.append(rule, below);
    toolbar.append(above); body.classList.add("run-reading-body"); body.tabIndex = 0;
    function cue() {
      above.hidden = body.scrollTop < 1; below.hidden = body.scrollTop + body.clientHeight >= body.scrollHeight - 1; next.hidden = below.hidden;
      const edge = body.getBoundingClientRect(), retries = Array.from(body.querySelectorAll("[data-run-retry]")).map(e => e.getBoundingClientRect());
      const aboveLabel = retries.some(r => r.height > 0 && r.top < edge.top) ? labels.retry_above : "Read more above";
      const belowLabel = retries.some(r => r.height > 0 && r.bottom > edge.bottom) ? labels.retry_below : "Read more below";
      if (above.textContent !== aboveLabel) above.textContent = aboveLabel;
      if (below.textContent !== belowLabel) below.textContent = belowLabel;
    }
    body.addEventListener("scroll", cue);
    // A cue can wrap and resize the body. Defer that write until the next frame
    // rather than resizing an observed element inside its notification callback.
    let frame = 0;
    const resize = new ResizeObserver(() => {
      cancelAnimationFrame(frame);
      if (!panel.isConnected) { resize.disconnect(); return; }
      frame = requestAnimationFrame(cue);
    });
    resize.observe(body); frame = requestAnimationFrame(cue);
    panel.append(toolbar, body, next); panel.updateReadingCue = cue; return panel;
  }
  function target() { return { threadId: thread, runId: current.runId }; }
  async function mutate(command, args, after) {
    const stamp = generation, selected = current?.runId;
    working = true; lastError = ""; render();
    try {
      const result = await bridge.invoke(command, args);
      if (stamp !== generation) return;
      if (result?.runId && (!current || current.runId === selected)) current = result;
      if (after) await after();
      await refreshAssignments(stamp);
    } catch (e) { if (stamp === generation) { lastError = String(e); if (command === "pause_run") pausing.delete(args.runId); } }
    finally { if (stamp === generation) { working = false; render(); } }
  }
  function edit(kind, task) { pickerOpen = false; historyOpen = false; decisionOpen = false; editor = { kind, target: target(), name: identity(current), task, text: "" }; render(); root.querySelector("textarea")?.focus(); }
  function respond(task, action) { return mutate("respond_run_decision", { ...target(), taskId: task.id, decisionId: task.decision.id, action }, () => { editor = null; decisionOpen = false; }); }
  function render() {
    const focused = root.querySelector("textarea") === document.activeElement;
    const caret = focused ? [document.activeElement.selectionStart, document.activeElement.selectionEnd] : null;
    root.replaceChildren(); root.hidden = !thread; if (!thread) return;
    const rows = all(), waiting = rows.filter(needs).length;
    if (pausing.has(current?.runId) && ["paused", "completed", "canceled"].includes(current.state)) pausing.delete(current.runId);
    const progress = current?.state === "running" ? current.tasks.findIndex(t => ["running", "verifying"].includes(t.state)) : -1;
    const state = current ? (pausing.has(current.runId) ? labels.pausing : labels[current.state]) : "No assignment yet";
    const headline = progress >= 0 ? `${state} · task ${progress + 1} of ${current.tasks.length}` : state;
    const status = node("p", lastError ? "Rich couldn’t update this assignment. Refresh to try again. Your saved work is kept." : (waiting ? `${waiting} ${waiting === 1 ? labels.needs_one : labels.needs_input}${current?.state === "needs_decision" ? "" : " · " + headline}` : headline), "run-status");
    status.setAttribute("role", "status"); root.append(status);
    if (waiting || lastError) { attention(status); }
    if (lastError) root.append(button("Refresh assignments", () => window.RichRuns.show(thread), "runRefresh"));
    if (current) {
      const picker = node("div", null, "run-picker");
      const choose = button("", () => { pickerOpen = !pickerOpen; historyOpen = false; decisionOpen = false; editor = null; render(); if (pickerOpen) root.querySelector("[data-run-choice]")?.focus(); }, "runPicker");
      choose.append(node("span", identity(current), "run-title"), node("span", `${rows.length} ${rows.length === 1 ? "assignment" : "assignments"} ▾`));
      choose.setAttribute("aria-expanded", String(pickerOpen)); choose.setAttribute("aria-label", `Choose assignment: ${identity(current)} (${rows.length})`);
      picker.append(choose);
      if (pickerOpen) {
        const list = node("div", null, "run-choices"); list.setAttribute("aria-label", "Assignments");
        rows.sort((a, b) => Number(needs(b)) - Number(needs(a)) || (b.createdAt || 0) - (a.createdAt || 0) || a.runId.localeCompare(b.runId));
        for (const a of rows) {
          const row = button(`${identity(a)} · ${needs(a) ? "Needs your decision" : labels[a.state]}`, async () => {
            const stamp = generation;
            try {
              const result = await bridge.invoke("select_run", { threadId: thread, runId: a.runId });
              if (stamp === generation) { current = result; pickerOpen = false; decisionOpen = false; editor = null; render(); root.querySelector("[data-run-picker]")?.focus(); }
            } catch (e) { if (stamp === generation) error(e); }
          }); row.dataset.runChoice = a.runId; if (needs(a)) { attention(row); } list.append(row);
        } root.append(readingPanel(list, "run-choices-panel", () => { pickerOpen = false; render(); root.querySelector("[data-run-picker]")?.focus(); }));
      } root.append(picker);
      const tasks = current.tasks.filter(t => t.decision || t.permission), task = tasks[0];
      const review = task ? button(labels.review_closed, () => {
        decisionOpen = true; pickerOpen = false; historyOpen = false; editor = null; render();
        if (decisionOpen) root.querySelector(".run-reading-body")?.focus();
      }, "runReview") : null;
      if (review) review.setAttribute("aria-expanded", String(decisionOpen));
      if (task?.permission && !editor && decisionOpen) {
        const p = task.permission, decision = node("section", null, "run-decision");
        decision.setAttribute("aria-label", "Permission for one operation");
        decision.append(node("p", "Allow this operation once?", "run-question"),
          node("p", "Rich could not finish using the permissions available. This approval covers only the operation shown. It changes no standing permission or explicit denial."),
          node("p", `Tool: ${p.tool}`), node("p", `Workspace: ${p.workspace}`),
          node("pre", JSON.stringify(p.input, null, 2)));
        const actions = node("div", null, "run-actions");
        const respondPermission = action => mutate("respond_run_permission", { ...target(), taskId: task.id,
          operationId: p.id, action }, () => { decisionOpen = false; });
        actions.append(button("Allow this operation once", () => respondPermission("approve_once"), "runApprovePermission"),
          button("Decline and find another way", () => respondPermission("reject"), "runRejectPermission"));
        decision.append(actions); root.append(readingPanel(decision, "run-decision-panel", () => { decisionOpen = false; render(); root.querySelector("[data-run-review]")?.focus(); }));
      } else if (task && !editor && decisionOpen) {
        const d = task.decision, decision = node("section", null, "run-decision"); decision.setAttribute("aria-label", "Your decision");
        const question = node("div", null, "run-question-body");
        question.append(node("p", d.question, "run-question"), node("p", d.whyCeo));
        if (tasks.length > 1) question.append(node("p", `Decision 1 of ${tasks.length}`));
        decision.append(question);
        const actions = node("div", null, "run-actions");
        if (d.resource) actions.append(button("Keep going", () => respond(task, { kind: "continue" }), "runAnswer"));
        else for (const option of d.options) actions.append(button(option, () => edit("option", { ...task, option }), "runAnswer"));
        if (!d.resource) actions.append(button("Write an answer", () => edit("answer", task), "runAnswer"));
        if (current.autonomous) actions.append(button("Change instructions", () => edit("scope", task), "runScope"));
        decision.append(actions); root.append(readingPanel(decision, "run-decision-panel", () => { decisionOpen = false; render(); root.querySelector("[data-run-review]")?.focus(); }));
      } else if (!task && needs(current) && !editor) {
        root.append(node("p", "Rich needs your answer in the conversation. Refresh to load the question here."));
        if (!lastError) root.append(button("Refresh assignments", () => window.RichRuns.show(thread), "runRefresh"));
      }
      if (!["completed", "canceled"].includes(current.state)) {
        const controls = node("div", null, "run-actions");
        if (review) controls.append(review);
        if ((!current.autonomous || current.state === "paused") && !needs(current)) controls.append(button("Continue assignment", () => mutate("drive_run", target()), "runContinue"));
        if (current.state !== "paused") controls.append(button("Pause assignment", () => {
          const args = target(); pausing.add(args.runId);
          mutate("pause_run", args, async () => {
            const result = await bridge.invoke("get_run", { threadId: args.threadId });
            if (current?.runId === result?.runId) current = result;
          });
        }, "runPause"));
        controls.append(button("End assignment", () => edit("end", task), "runEnd")); root.append(controls);
      }
      if (editor) {
        const form = node("form", null, "run-editor"), ending = editor.kind === "end", option = editor.kind === "option";
        form.append(node("p", ending ? `End “${editor.name}” without completing it? Work already done will be kept.` : option ? `For “${editor.name}”, confirm: ${editor.task.option}` : editor.kind === "scope" ? "What should Rich do differently? Your other requirements still apply." : "What is your decision?"));
        if (!ending && !option) {
          const input = node("textarea"); input.value = editor.text; input.required = true; input.maxLength = 32000;
          input.setAttribute("aria-label", editor.kind === "scope" ? "New instructions" : "Your answer");
          input.addEventListener("input", () => { editor.text = input.value; }); form.append(input);
        }
        const cancel = button("Go back", () => { editor = null; decisionOpen = !!task; render(); }, "runDismiss");
        const submit = node("button", ending ? "Confirm end" : option ? "Confirm decision" : "Send decision"); submit.type = "submit"; if (ending) submit.dataset.runEnd = ""; form.append(cancel, submit);
        form.addEventListener("submit", e => {
          e.preventDefault(); const saved = editor;
          if (ending && (!saved.task || saved.task.permission)) mutate("end_run", saved.target, () => { editor = null; });
          else mutate("respond_run_decision", { ...saved.target, taskId: saved.task.id, decisionId: saved.task.decision.id,
            action: ending ? { kind: "end" } : { kind: saved.kind === "scope" ? "change_scope" : "answer", text: option ? saved.task.option : saved.text } }, () => { editor = null; });
        }); root.append(readingPanel(form, "run-editor-panel", () => { editor = null; render(); root.querySelector("[data-run-review], [data-run-end]")?.focus(); }));
      }
    }
    const history = node("details", null, "run-history"); history.open = historyOpen; history.append(node("summary", current || lastError ? "Show me what happened" : "Import an assignment"));
    history.addEventListener("toggle", () => { if (history.isConnected && historyOpen !== history.open) { historyOpen = history.open; if (historyOpen) { decisionOpen = false; pickerOpen = false; editor = null; } render(); } });
    const body = node("div", null, "run-history-body"); if (lastError) body.append(node("pre", lastError));
    if (current) {
      for (const text of current.instructionChanges || []) body.append(node("p", `Your updated instructions: ${text}`, "run-instruction-change"));
      const single = current.tasks.length === 1, list = node(single ? "div" : "ol");
      const checks = current.tasks[0]?.checks || [];
      const sharedChecks = !current.autonomous && !single && checks.length > 0 && current.tasks.every(t => JSON.stringify(t.checks) === JSON.stringify(checks));
      if (sharedChecks) body.append(node("p", `${labels.shared_checks}: ${checks.join("; ")}`, "run-checks"));
      for (const task of current.tasks) {
        const item = node(single ? "section" : "li", null, "run-history-task");
        if (!single || task.description !== current.goal) item.append(node("p", task.description, "run-task-description"));
        item.append(node("p", `Status: ${labels[task.state]}`, "run-task-status"));
        if (!sharedChecks && task.checks.length) item.append(node("p", `${current.autonomous ? labels.agreed_delivery : labels.imported_checks}: ${task.checks.join("; ")}`, "run-checks"));
        if (task.previous_instructions?.length) {
          item.append(node("p", "Earlier instructions still apply unless changed."));
          for (const previous of task.previous_instructions) {
            const section = node("section", null, "run-previous-instructions");
            section.append(node("p", `Your request: ${previous.request}`));
            if (previous.acceptedScope && previous.acceptedScope !== previous.request) section.append(node("p", `Rich agreed: ${previous.acceptedScope}`));
            item.append(section);
          }
        }
        if (task.decision?.recommendation) item.append(node("p", task.decision.recommendation));
        const evidence = (task.evidence || []).filter(e => !e.includes("CEO_DECISION:")); for (const receipt of evidence) item.append(node("p", receipt, "run-receipt"));
        if (!current.autonomous && task.commands?.length) {
          const technical = node("details"); technical.append(node("summary", "Technical details"), node("pre", task.commands.map(a => a.map(v => /^[a-zA-Z0-9_./=-]+$/.test(v) ? v : "'" + v.replaceAll("'", "'\\''") + "'").join(" ")).join("\n"))); item.append(technical);
        }
        if (!current.autonomous && task.state === "needs_attention") item.append(button("Retry after reviewing the result", () => mutate("retry_run_task", { ...target(), taskId: task.id }), "runRetry"));
        list.append(item);
      } body.append(list);
      if (!current.autonomous && current.workspace) body.append(node("p", `Workspace: ${current.workspace}. Up to ${current.maxAttempts} attempts per task, ${current.turnTimeoutSeconds} seconds per attempt.`));
    } else {
      root.append(node("p", "Tell Rich what needs doing in the conversation. He will carry out the assignment and check the result."));
      if (lastError) {
        if (archiveConfirm) {
          body.append(node("p", "Set aside this unreadable assignment? Its saved history will be kept."));
          body.append(button("Go back", () => { archiveConfirm = false; render(); }));
          body.append(button("Confirm set aside", () => mutate("archive_run", { threadId: thread }, () => { lastError = ""; archiveConfirm = false; })));
        } else body.append(button("Set aside unreadable assignment", () => { archiveConfirm = true; render(); }));
      }
    }
    if (!current || ["completed", "canceled"].includes(current.state)) {
      const label = node("label", "Import assignment from a file "), load = node("input"); load.type = "file"; load.accept = ".json,application/json";
      load.addEventListener("change", async () => {
        const stamp = generation, id = thread;
        try { const file = load.files[0]; if (!file) return;
          if (file.size > 1024 * 1024) throw new Error("This assignment file is too large.");
          const plan = JSON.parse(await file.text()); if (stamp === generation) await mutate("prepare_run", { threadId: id, plan });
        } catch (e) { if (stamp === generation) error(e); }
      }); label.append(load); body.append(label);
    }
    if (historyOpen) history.append(readingPanel(body, "run-history-panel", () => { historyOpen = false; render(); root.querySelector(".run-history > summary")?.focus(); })); root.append(history);
    fitReading();
    for (const panel of root.querySelectorAll(".run-reading")) panel.updateReadingCue();
    for (const b of root.querySelectorAll("button")) if (!b.hasAttribute("data-run-pause") && !b.hasAttribute("data-run-end") && !b.hasAttribute("data-run-dismiss")) b.disabled = working;
    if (focused && root.querySelector("textarea")) { const input = root.querySelector("textarea"); input.focus(); input.setSelectionRange(...caret); }
  }
  async function refreshAssignments(stamp) {
    const result = await bridge.invoke("list_runs", { threadId: thread }); if (stamp === generation && Array.isArray(result)) assignments = result;
  }
  window.RichRuns = {
    mount(b, element) {
      bridge = b; root = element; window.addEventListener("resize", fitReading);
      document.addEventListener("keydown", e => { if (e.key === "Escape" && (pickerOpen || decisionOpen || editor || historyOpen)) { const focus = pickerOpen ? "[data-run-picker]" : historyOpen ? ".run-history > summary" : "[data-run-review], [data-run-end]"; pickerOpen = false; decisionOpen = false; historyOpen = false; editor = null; render(); root.querySelector(focus)?.focus(); } });
      document.addEventListener("click", e => { if (pickerOpen && !e.composedPath().includes(root)) { pickerOpen = false; render(); } });
      setInterval(async () => {
        if (!thread || (!current?.preparing && !pausing.has(current?.runId)) || polling) return;
        const stamp = generation; polling = true;
        try { const result = await bridge.invoke("get_run", { threadId: thread }); if (stamp === generation) { current = result; render(); } }
        catch (e) { if (stamp === generation) error(e); } finally { polling = false; }
      }, 2000);
      bridge.listen("rich://run-updated", async ({ payload }) => {
        if (payload.threadId !== thread) return;
        const stamp = generation; try { await refreshAssignments(stamp); } catch (_) {} if (stamp !== generation) return;
        if (current && payload.runId !== current.runId) {
          try { const actual = await bridge.invoke("get_run", { threadId: thread }); if (stamp === generation && actual?.runId === payload.runId && !editor) current = actual; } catch (_) { /* Refresh retries the authoritative read. */ }
        } else if (!current || payload.revision >= current.revision) current = payload;
        if (stamp === generation) render();
      });
    },
    async show(id) {
      const stamp = ++generation; thread = id; current = null; assignments = []; lastError = ""; editor = null; pickerOpen = false; decisionOpen = false; historyOpen = false; working = false; archiveConfirm = false; render(); if (!id) return;
      try { const result = await bridge.invoke("get_run", { threadId: id }); await refreshAssignments(stamp); if (stamp === generation) { current = result; render(); } } catch (e) { if (stamp === generation) error(e); }
    }
  };
})();
