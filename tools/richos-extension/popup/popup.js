/**
 * RichOS — popup (health indicator detail view).
 *
 * The badge is the glanceable indicator; this is the "what exactly is wrong" view. Opening
 * the popup also counts as invoking the extension for the current tab, which is what lets
 * `Arm capture on this tab` succeed when Chrome refused the automatic attempt.
 */

const $ = (id) => document.getElementById(id);

/** @param {number} bytes */
const mb = (bytes) => `${(bytes / 1048576).toFixed(1)} MB`;

/** @param {number} ms */
function duration(ms) {
  const total = Math.max(0, Math.round(ms / 1000));
  const m = Math.floor(total / 60);
  const s = total % 60;
  return `${m}m ${String(s).padStart(2, '0')}s`;
}

async function ask(message) {
  try {
    return await chrome.runtime.sendMessage({ target: 'sw', ...message });
  } catch (err) {
    return { ok: false, error: String((err && err.message) || err) };
  }
}

function renderSignals(signals = {}) {
  const labels = {
    heartbeat: 'recorder',
    chunks: 'chunks',
    bytes: 'growth',
    recorder: 'state',
    micTrack: 'microphone',
    tabTrack: 'tab audio',
    micLevel: 'mic level',
    tabLevel: 'tab level',
    speech: 'speech',
  };
  return Object.entries(signals)
    .map(
      ([key, level]) =>
        `<span class="pill"><span class="dot ${level}"></span>${labels[key] || key}</span>`,
    )
    .join('');
}

function renderRecent(recent = []) {
  if (!recent.length) return '';
  const rows = recent
    .map((r) => {
      const when = new Date(r.startedAt).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
      const flag = r.ok ? '' : ' ⚠';
      return `<tr><td>${when}${flag}</td><td>${r.platform}</td><td>${mb(r.bytes || 0)}</td></tr>`;
    })
    .join('');
  return `<div class="muted">Recent sessions</div><table>${rows}</table>`;
}

async function refresh() {
  const response = await ask({ type: 'core:get-status' });
  const status = response?.modules?.callCapture;
  if (!status) {
    $('status').innerHTML = `<p class="muted">No status: ${response?.error || 'service worker not responding'}</p>`;
    return;
  }

  const level = status.active ? status.level || 'green' : status.callTabsOpen?.length ? 'red' : 'idle';
  $('dot').className = `dot ${level}`;

  if (status.active) {
    $('status').innerHTML = `
      <dl class="rows">
        <dt>Recording</dt><dd>${status.platform}</dd>
        <dt>Elapsed</dt><dd>${duration(Date.now() - status.startedAt)}</dd>
        <dt>Audio</dt><dd>${mb(status.bytesTotal)} · ${status.chunkCount} chunks${status.part ? ` · part ${status.part + 1}` : ''}</dd>
        <dt>Channels</dt><dd>${status.micOnlyFailover ? 'microphone only (tab audio lost)' : 'microphone + tab audio'}</dd>
        <dt>Saving to</dt><dd class="path">${status.saveLocation || ''}</dd>
      </dl>
      <div class="signals">${renderSignals(status.signals)}</div>`;
    $('problems').innerHTML = (status.reasons || []).length
      ? `<ul class="reasons">${status.reasons.map((r) => `<li class="${r.level}">${r.detail}</li>`).join('')}</ul>`
      : '';
    $('arm').hidden = true;
    $('stop').hidden = false;
    $('hint').textContent = 'Audio is written to disk continuously — a crash loses seconds, never the call.';
  } else {
    const open = status.callTabsOpen || [];
    const last = status.lastSession;
    const lastLine = last
      ? `<dl class="rows"><dt>Last call</dt><dd>${new Date(last.startedAt).toLocaleString([], {
          month: 'short',
          day: 'numeric',
          hour: '2-digit',
          minute: '2-digit',
        })} · ${mb(last.bytes || 0)} · ${last.ok ? 'saved OK' : `needs attention: ${(last.problems || []).join('; ')}`}</dd>
        <dt>Saving to</dt><dd class="path">${status.saveLocation || ''}</dd></dl>`
      : `<dl class="rows"><dt>Saving to</dt><dd class="path">${status.saveLocation || ''}</dd></dl>`;
    $('status').innerHTML =
      (open.length
        ? `<p><strong>${open.length} call tab${open.length > 1 ? 's' : ''} open and NOT being captured.</strong></p>
           <p class="muted">${open.map((t) => t.platform).join(', ')}</p>`
        : `<p class="muted">Idle. Capture arms itself when a call tab appears${status.armMode === 'manual' ? ' (currently set to manual)' : ''}.</p>`) +
      lastLine;
    $('problems').innerHTML = '';
    $('arm').hidden = false;
    $('stop').hidden = true;
    $('hint').textContent = 'Shortcut: Alt+Shift+L arms the current tab without opening this popup.';
  }
  $('recent').innerHTML = renderRecent(status.recent);
}

$('arm').addEventListener('click', async () => {
  $('arm').disabled = true;
  const result = await ask({ module: 'callCapture', type: 'cc:arm-active-tab', trigger: 'popup' });
  if (!result?.ok) $('problems').innerHTML = `<p class="muted">${result?.error || 'could not arm'}</p>`;
  $('arm').disabled = false;
  await refresh();
});

$('stop').addEventListener('click', async () => {
  $('stop').disabled = true;
  await ask({ module: 'callCapture', type: 'cc:stop', reason: 'manual' });
  $('stop').disabled = false;
  await refresh();
});

$('options-link').addEventListener('click', (event) => {
  event.preventDefault();
  chrome.runtime.openOptionsPage();
});

refresh();
setInterval(refresh, 1000);
