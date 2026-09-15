/**
 * RichOS — settings page (shared core UI).
 *
 * Renders every registered module's settings from its declarative schema, so a new module
 * (chatgpt-export next) gets a settings UI for free by exporting `settingsSchema`.
 */

import { KEYS } from '../core/constants.js';

const $ = (id) => document.getElementById(id);

async function ask(message) {
  try {
    return await chrome.runtime.sendMessage({ target: 'sw', ...message });
  } catch (err) {
    return { ok: false, error: String((err && err.message) || err) };
  }
}

/**
 * @param {{moduleId: string, title: string, fields: any[]}} schema
 * @param {Record<string, any>} values
 */
function renderModule(schema, values) {
  const section = document.createElement('section');
  section.className = 'card';
  section.innerHTML = `<h2>${schema.title}</h2>`;

  for (const field of schema.fields) {
    const wrap = document.createElement('div');
    wrap.className = 'field';

    const label = document.createElement('label');
    label.textContent = field.label;
    label.htmlFor = `${schema.moduleId}.${field.key}`;

    let input;
    if (field.type === 'boolean') {
      input = document.createElement('input');
      input.type = 'checkbox';
      input.checked = Boolean(values[field.key]);
    } else if (field.type === 'number') {
      input = document.createElement('input');
      input.type = 'number';
      if (field.min != null) input.min = String(field.min);
      if (field.max != null) input.max = String(field.max);
      input.value = String(values[field.key] ?? '');
    } else if (field.type === 'select') {
      input = document.createElement('select');
      for (const option of field.options || []) {
        const el = document.createElement('option');
        el.value = option.value;
        el.textContent = option.label;
        el.selected = values[field.key] === option.value;
        input.appendChild(el);
      }
    } else {
      input = document.createElement('input');
      input.type = 'text';
      input.value = String(values[field.key] ?? '');
    }
    input.id = `${schema.moduleId}.${field.key}`;

    const saved = document.createElement('span');
    saved.className = 'saved';

    input.addEventListener('change', async () => {
      let value;
      if (field.type === 'boolean') value = input.checked;
      else if (field.type === 'number') value = Number(input.value);
      else value = input.value;
      await ask({ type: 'core:update-settings', moduleId: schema.moduleId, patch: { [field.key]: value } });
      saved.textContent = 'saved';
      setTimeout(() => {
        saved.textContent = '';
      }, 1200);
      if (field.key === 'disclosureBanner' && value === true) await requestHostPermission();
    });

    wrap.appendChild(label);
    const control = document.createElement('div');
    control.appendChild(input);
    control.appendChild(saved);
    wrap.appendChild(control);
    if (field.help) {
      const help = document.createElement('p');
      help.className = 'help';
      help.textContent = field.help;
      wrap.appendChild(help);
    }
    section.appendChild(wrap);
  }
  return section;
}

async function loadSettings() {
  const response = await ask({ type: 'core:get-settings' });
  if (!response?.ok) {
    $('modules').innerHTML = `<p class="muted">Could not load settings: ${response?.error || 'unknown'}</p>`;
    return;
  }
  const container = $('modules');
  container.innerHTML = '';
  for (const schema of response.schemas) {
    container.appendChild(renderModule(schema, response.settings[schema.moduleId] || {}));
  }
}

// --- permissions -------------------------------------------------------------------------

async function refreshMicState() {
  const badge = $('mic-state');
  try {
    const status = await navigator.permissions.query({ name: 'microphone' });
    const granted = status.state === 'granted';
    badge.textContent = granted ? 'granted' : status.state;
    badge.className = `badge ${granted ? 'ok' : 'no'}`;
    $('mic-grant').hidden = granted;
  } catch {
    badge.textContent = 'unknown';
    badge.className = 'badge';
  }
}

$('mic-grant').addEventListener('click', async () => {
  try {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    stream.getTracks().forEach((t) => t.stop());
  } catch (err) {
    $('mic-state').textContent = String((err && err.name) || 'denied');
    $('mic-state').className = 'badge no';
  }
  await refreshMicState();
});

async function refreshHostState() {
  const granted = await chrome.permissions.contains({ origins: ['<all_urls>'] });
  $('host-state').textContent = granted ? 'granted' : 'not granted';
  $('host-state').className = `badge ${granted ? 'ok' : ''}`;
  $('host-grant').hidden = granted;
}

async function requestHostPermission() {
  await chrome.permissions.request({ origins: ['<all_urls>'] });
  await refreshHostState();
}

$('host-grant').addEventListener('click', requestHostPermission);

// --- alerts ------------------------------------------------------------------------------

async function loadAlerts() {
  const stored = (await chrome.storage.local.get(KEYS.alertLog))[KEYS.alertLog] || [];
  if (!stored.length) return;
  const rows = stored
    .slice(-25)
    .reverse()
    .map(
      (a) =>
        `<tr class="${a.level}"><td>${new Date(a.t).toLocaleString()}</td><td>${a.code}</td><td>${a.message}</td></tr>`,
    )
    .join('');
  $('alerts').innerHTML = `<table class="alerts">${rows}</table>`;
}

loadSettings();
refreshMicState();
refreshHostState();
loadAlerts();
