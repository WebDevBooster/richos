/* Durable work runs. Model turn events never decide this panel's completion. */
(function () {
  "use strict";
  let bridge, root, thread, current, assignments = [], generation = 0, busy = false, polling = false, lastError = "";
  const labels = { ready: "Queued", waiting: "Retrying automatically", needs_decision: "Waiting for your decision", running: "Working", paused: "Paused",
    needs_attention: "Needs attention", completed: "Completed", pending: "Not finished",
    verifying: "Checking the result", passed: "Checks passed", canceled: "Ended without completion" };

  function node(tag, text) { const e = document.createElement(tag); if (text) e.textContent = text; return e; }
  function error(e) {
    lastError = String(e);
    const out = root.querySelector('[role="status"]');
    if (out) out.textContent = String(e);
    render();
  }
  function render() {
    root.replaceChildren(); root.hidden = !thread;
    if (!thread) return;
    const details = node("details"); details.open = !!current || !!lastError;
    details.append(node("summary", current ? `Work plan: ${lastError ? "Needs attention" : (labels[current.state] || current.state)}` : "Work plan"));
    const status = node("p", lastError); status.setAttribute("role", "status");
    if (!current) {
      details.append(node("p", "Tell Rich what needs doing in the conversation. He will plan the work, carry it out and check the result."));
      const load = node("input"); load.type = "file"; load.accept = ".json,application/json";
      load.setAttribute("aria-label", "Load a work plan");
      load.addEventListener("change", async () => {
        const selected = thread, stamp = generation;
        try {
          const file = load.files[0]; if (!file) return;
          if (file.size > 1024 * 1024) throw new Error("This work plan is too large.");
          const plan = JSON.parse(await file.text());
          const result = await bridge.invoke("prepare_run", { threadId: selected, plan });
          if (stamp !== generation) return;
          current = result; render();
        } catch (e) { if (stamp === generation) error(e); }
      });
      const advanced = node("details"); advanced.append(node("summary", "Import an existing plan"), load); details.append(advanced);
    } else {
      if (assignments.length > 1) {
        const label = node("label", "Assignment ");
        const select = node("select"); select.setAttribute("aria-label", "Assignment");
        for (const assignment of assignments) {
          const option = node("option", `${labels[assignment.state] || assignment.state}: ${assignment.goal}`);
          option.value = assignment.runId; option.selected = assignment.runId === current.runId; select.append(option);
        }
        select.addEventListener("change", async () => {
          const stamp = generation;
          try { const result = await bridge.invoke("select_run", { threadId: thread, runId: select.value });
            if (stamp === generation) { current = result; render(); }
          } catch (e) { if (stamp === generation) error(e); }
        });
        label.append(select); details.append(label);
      }
      details.append(node("p", current.goal));
      if (current.workspace && !current.autonomous) details.append(node("p", `Workspace: ${current.workspace}. Up to ${current.maxAttempts} attempts per task, ${current.turnTimeoutSeconds} seconds per attempt.`));
      const list = node("ol");
      for (const task of current.tasks) {
        const item = node("li");
        item.append(node("p", `${task.description} (${labels[task.state] || task.state})`));
        if (task.checks.length) item.append(node("small", `Completion checks: ${task.checks.join("; ")}`));
        if (!current.autonomous && task.commands && task.commands.length) {
          const commands = node("details"); commands.append(node("summary", "Commands used to check completion"));
          commands.append(node("pre", task.commands.map(argv => JSON.stringify(argv)).join("\n"))); item.append(commands);
        }
        if (task.evidence && task.evidence.length) {
          const evidence = node("details"); evidence.append(node("summary", "Check results"));
          evidence.append(node("pre", task.evidence.join("\n"))); item.append(evidence);
        }
        if (task.state === "needs_attention" && !current.autonomous) {
          const retry = node("button", "Retry after inspecting the result"); retry.type = "button"; retry.disabled = busy;
          retry.addEventListener("click", async () => {
            const stamp = generation;
            try {
              const result = await bridge.invoke("retry_run_task", { threadId: thread, runId: current.runId, taskId: task.id });
              if (stamp === generation) { current = result; render(); }
            } catch (e) { if (stamp === generation) error(e); }
          }); item.append(retry);
        }
        list.append(item);
      }
      details.append(list);
      if (!["completed", "canceled"].includes(current.state)) {
        const start = node("button", busy ? "Run active" : "Start / continue"); start.type = "button"; start.disabled = busy;
        start.addEventListener("click", async () => {
          const selected = thread, stamp = generation; busy = true; lastError = ""; render();
          try {
            const result = await bridge.invoke("drive_run", { threadId: selected, runId: current.runId });
            if (stamp === generation) current = result;
          } catch (e) { if (stamp === generation) error(e); }
          finally { busy = false; if (stamp === generation) render(); }
        });
        const pause = node("button", "Pause run"); pause.type = "button";
        pause.addEventListener("click", async () => {
          const stamp = generation;
          try {
            await bridge.invoke("pause_run", { threadId: thread, runId: current.runId });
            if (stamp === generation) status.textContent = "Pause requested. The current attempt will stop before more work starts.";
          } catch (e) { if (stamp === generation) error(e); }
        });
        if (!current.autonomous || current.state === "paused") details.append(start);
        details.append(pause);
        const end = node("button", "End run without completing it"); end.type = "button"; end.disabled = busy;
        end.addEventListener("click", async () => {
          const stamp = generation;
          try {
            const result = await bridge.invoke("end_run", { threadId: thread, runId: current.runId });
            if (stamp === generation) { current = result; render(); }
          } catch (e) { if (stamp === generation) error(e); }
        }); details.append(end);
      } else {
        const next = node("button", "Load another work plan"); next.type = "button";
        next.addEventListener("click", () => { current = null; lastError = ""; render(); });
        details.append(next);
      }
    }
    if (lastError && !current) {
      const archive = node("button", "Archive the unreadable plan and preserve its journal"); archive.type = "button";
      archive.addEventListener("click", async () => {
        const stamp = generation;
        try {
          await bridge.invoke("archive_run", { threadId: thread });
          if (stamp === generation) { current = null; lastError = ""; render(); }
        } catch (e) { if (stamp === generation) error(e); }
      });
      details.append(archive);
    }
    if (lastError) {
      const refresh = node("button", "Refresh work plans"); refresh.type = "button"; refresh.dataset.runRefresh = "";
      refresh.addEventListener("click", () => window.RichRuns.show(thread)); details.append(refresh);
    }
    details.append(status); root.append(details);
  }

  async function refreshAssignments(stamp) {
    const result = await bridge.invoke("list_runs", { threadId: thread });
    if (stamp === generation && Array.isArray(result)) assignments = result;
  }

  window.RichRuns = {
    mount(b, element) {
      bridge = b; root = element;
      setInterval(async () => {
        if (!thread || !current?.preparing || polling) return;
        const stamp = generation; polling = true;
        try { const result = await bridge.invoke("get_run", { threadId: thread }); if (stamp === generation) { current = result; render(); } }
        catch (e) { if (stamp === generation) error(e); }
        finally { polling = false; }
      }, 2000);
      bridge.listen("rich://run-updated", async ({ payload }) => {
        if (payload.threadId !== thread) return;
        try { await refreshAssignments(generation); } catch (_) {}
        if (current && payload.runId !== current.runId) {
          const stamp = generation;
          try {
            const actual = await bridge.invoke("get_run", { threadId: thread });
            if (stamp === generation && actual?.runId === payload.runId) { current = actual; render(); }
          } catch (_) { /* A future update or reopening retries the authoritative read. */ }
          return;
        }
        if (current && payload.revision < current.revision) return;
        current = payload; render();
      });
    },
    async show(id) {
      const stamp = ++generation; thread = id; current = null; assignments = []; lastError = ""; render();
      if (!id) return;
      try {
        const result = await bridge.invoke("get_run", { threadId: id });
        await refreshAssignments(stamp);
        if (stamp === generation) { current = result; render(); }
      } catch (e) { if (stamp === generation) { error(e); render(); } }
    }
  };
})();
