// RichOS web UI — deliberately minimal (design sets the UX bar, this builds the pixels).
// It renders ONLY Rich's clean chat: user + assistant messages, no machinery.
const invoke = window.__TAURI__.core.invoke;

let activeThread = null;

const el = (id) => document.getElementById(id);

async function refreshThreads() {
  const threads = await invoke("list_threads");
  activeThread = await invoke("active_thread");
  const list = el("thread-list");
  list.innerHTML = "";
  for (const t of threads) {
    const li = document.createElement("li");
    li.textContent = t.title;
    li.className = "thread" + (t.id === activeThread ? " active" : "");
    li.onclick = async () => {
      await invoke("switch_thread", { threadId: t.id });
      activeThread = t.id;
      await refreshThreads();
      await refreshMessages();
    };
    list.appendChild(li);
  }
}

async function refreshMessages() {
  if (!activeThread) return;
  const messages = await invoke("get_messages", { threadId: activeThread });
  renderMessages(messages);
}

function renderMessages(messages) {
  const box = el("messages");
  box.innerHTML = "";
  for (const m of messages) {
    const div = document.createElement("div");
    div.className = "msg " + (m.role === "user" ? "user" : "rich");
    const who = document.createElement("div");
    who.className = "who";
    who.textContent = m.role === "user" ? "You" : "Rich";
    const text = document.createElement("div");
    text.className = "text";
    text.textContent = m.text; // textContent = no HTML injection, clean output
    div.appendChild(who);
    div.appendChild(text);
    box.appendChild(div);
  }
  box.scrollTop = box.scrollHeight;
}

function setWorking(on) {
  el("send").disabled = on;
  el("send").textContent = on ? "…" : "Send";
}

async function send() {
  const input = el("input");
  const text = input.value.trim();
  if (!text) return;
  input.value = "";
  // Optimistic: show the user's message immediately.
  const box = el("messages");
  const div = document.createElement("div");
  div.className = "msg user";
  div.innerHTML = '<div class="who">You</div>';
  const t = document.createElement("div");
  t.className = "text";
  t.textContent = text;
  div.appendChild(t);
  box.appendChild(div);
  box.scrollTop = box.scrollHeight;

  setWorking(true);
  try {
    const messages = await invoke("send_message", { text });
    renderMessages(messages);
  } catch (e) {
    // A calm, Rich-voiced failure — never a stack trace in the CEO's view.
    const err = document.createElement("div");
    err.className = "msg rich";
    err.innerHTML = '<div class="who">Rich</div>';
    const et = document.createElement("div");
    et.className = "text";
    et.textContent = typeof e === "string" ? e : "Something went sideways on my end — one moment.";
    err.appendChild(et);
    box.appendChild(err);
  } finally {
    setWorking(false);
  }
}

el("composer").addEventListener("submit", (e) => {
  e.preventDefault();
  send();
});
el("input").addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey) {
    e.preventDefault();
    send();
  }
});
el("new-thread").addEventListener("click", async () => {
  const title = prompt("Thread topic?", "New thread");
  if (title === null) return;
  const id = await invoke("create_thread", { title });
  await invoke("switch_thread", { threadId: id });
  activeThread = id;
  await refreshThreads();
  await refreshMessages();
});

(async function init() {
  await refreshThreads();
  await refreshMessages();
})();
