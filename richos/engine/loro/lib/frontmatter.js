// Loro public component. SPDX-License-Identifier: AGPL-3.0-only
const FENCE = '---';

const FENCE_SEARCH_LINES = 3;

const FENCE_LIKE = /^[-‐-―−]+$/;

const KEY_LINE = /^[A-Za-z_][A-Za-z0-9_-]*\s*:(\s|$)/;

function damagedFenceProblems(lines) {
  const LOST =
    'so every field below it was read as body text — the record kept its words but lost its kind, ' +
    'scope, tags, provenance and any supersededBy.';
  const limit = Math.min(FENCE_SEARCH_LINES, lines.length);
  for (let i = 0; i < limit; i += 1) {
    const raw = lines[i];
    const hasBom = i === 0 && raw.startsWith('﻿');
    const token = (hasBom ? raw.slice(1) : raw).trim();
    if (!token || !FENCE_LIKE.test(token)) continue;

    if (/^-+$/.test(token) && token.length < 3) continue;
    if (!KEY_LINE.test(lines[i + 1] || '')) continue;
    if (hasBom) {
      return [
        `front matter IGNORED: the file begins with an INVISIBLE byte-order mark before its \`---\` ` +
          `fence, ${LOST} Nothing looks wrong on screen. Fix: re-save the file as UTF-8 without a ` +
          'byte-order mark, so that `---` is the very first byte.',
      ];
    }
    if (i === 0 && raw === FENCE) {
      return [
        `front matter IGNORED: the opening \`---\` fence is never closed, ${LOST} ` +
          'Fix: close the front matter with a line that is exactly `---`.',
      ];
    }
    return [
      `front matter IGNORED: line ${i + 1} was meant to be the opening \`---\` fence but reads ` +
        `${JSON.stringify(raw)}, ${LOST} Fix: make the FIRST line of the file exactly three hyphens, ` +
        'with nothing before it and nothing after it.',
    ];
  }
  return [];
}

export function splitFrontMatter(text) {
  const src = String(text == null ? '' : text);
  const lines = src.split(/\r?\n/);
  const noFrontMatter = () => ({
    hasFrontMatter: false,
    rawLines: [],
    body: src,
    fenceProblems: damagedFenceProblems(lines),
  });
  if (lines[0] !== FENCE) return noFrontMatter();
  const end = lines.indexOf(FENCE, 1);
  if (end === -1) return noFrontMatter();
  return {
    hasFrontMatter: true,
    rawLines: lines.slice(1, end),
    body: lines.slice(end + 1).join('\n').replace(/^\n+/, ''),
    fenceProblems: [],
  };
}

export function parseScalar(token) {
  const t = String(token).trim();
  if (t === '') return '';
  if ((t.startsWith('"') && t.endsWith('"') && t.length > 1) || (t.startsWith("'") && t.endsWith("'") && t.length > 1)) {
    return t.slice(1, -1).replace(/\\"/g, '"');
  }
  if (t === 'null' || t === '~') return null;
  if (t === 'true') return true;
  if (t === 'false') return false;
  if (/^-?\d+(\.\d+)?$/.test(t)) return Number(t);
  return t;
}

function splitFlow(inner) {
  const out = [];
  let depth = 0;
  let quote = '';
  let cur = '';
  for (const ch of String(inner)) {
    if (quote) {
      cur += ch;
      if (ch === quote) quote = '';
      continue;
    }
    if (ch === '"' || ch === "'") { quote = ch; cur += ch; continue; }
    if (ch === '[' || ch === '{') depth += 1;
    if (ch === ']' || ch === '}') depth -= 1;
    if (ch === ',' && depth === 0) { out.push(cur); cur = ''; continue; }
    cur += ch;
  }
  if (cur.trim()) out.push(cur);
  return out.map((s) => s.trim()).filter((s) => s !== '');
}

export function parseValue(token) {
  const t = String(token).trim();
  if (t.startsWith('[') && t.endsWith(']')) return splitFlow(t.slice(1, -1)).map(parseScalar);
  if (t.startsWith('{') && t.endsWith('}')) {
    const map = {};
    for (const part of splitFlow(t.slice(1, -1))) {
      const i = part.indexOf(':');
      if (i === -1) continue;
      map[part.slice(0, i).trim()] = parseScalar(part.slice(i + 1));
    }
    return map;
  }
  return parseScalar(t);
}

export function parseFrontMatterLines(rawLines) {
  const data = {};
  const problems = [];
  let listKey = null;
  for (const line of rawLines) {
    if (!line.trim() || line.trim().startsWith('#')) continue;
    const item = line.match(/^\s+-\s*(.*)$/);
    if (item) {
      if (!listKey) {
        problems.push(`front matter: a list item with no key: ${line.trim()}`);
        continue;
      }
      data[listKey].push(parseScalar(item[1]));
      continue;
    }
    const kv = line.match(/^([A-Za-z_][A-Za-z0-9_-]*)\s*:\s*(.*)$/);
    if (!kv) {
      problems.push(`front matter: unparsable line, kept verbatim but ignored: ${line.trim()}`);
      listKey = null;
      continue;
    }
    const [, key, rest] = kv;
    if (rest.trim() === '') {
      data[key] = [];
      listKey = key;
      continue;
    }
    data[key] = parseValue(rest);
    listKey = null;
  }
  return { data, problems };
}

export function parseFrontMatter(text) {
  const split = splitFrontMatter(text);
  const { data, problems } = parseFrontMatterLines(split.rawLines);
  return { ...split, data, problems: [...split.fenceProblems, ...problems] };
}

export function formatValue(value) {
  if (value === null || value === undefined) return 'null';
  if (typeof value === 'boolean' || typeof value === 'number') return String(value);
  if (Array.isArray(value)) return `[${value.map((v) => formatScalar(v)).join(', ')}]`;
  if (typeof value === 'object') {
    const parts = Object.entries(value)
      .filter(([, v]) => v !== undefined)
      .map(([k, v]) => `${k}: ${formatScalar(v)}`);
    return `{ ${parts.join(', ')} }`;
  }
  return formatScalar(value);
}

export function formatScalar(value) {
  if (value === null || value === undefined) return 'null';
  if (typeof value === 'boolean' || typeof value === 'number') return String(value);
  const s = String(value);
  const ambiguous =
    s === '' ||
    /^(null|true|false|~)$/.test(s) ||
    /^-?\d+(\.\d+)?$/.test(s) ||
    /[:#{}[\],'"]/.test(s) ||
    s !== s.trim();
  return ambiguous ? `"${s.replace(/"/g, '\\"')}"` : s;
}

export function setFields(text, changes, opts = {}) {
  const { hasFrontMatter, rawLines, body } = splitFrontMatter(text);
  const lines = rawLines.slice();
  const pending = new Map(Object.entries(changes || {}).filter(([, v]) => v !== undefined));

  for (let i = 0; i < lines.length; i += 1) {
    const kv = lines[i].match(/^([A-Za-z_][A-Za-z0-9_-]*)\s*:\s*(.*)$/);
    if (!kv) continue;
    const key = kv[1];
    if (!pending.has(key)) continue;

    let j = i + 1;
    while (j < lines.length && /^\s+-\s*/.test(lines[j])) j += 1;
    lines.splice(i, j - i, `${key}: ${formatValue(pending.get(key))}`);
    pending.delete(key);
  }
  for (const [key, value] of pending) lines.push(`${key}: ${formatValue(value)}`);

  const newBody = opts.body === undefined ? body : String(opts.body);
  const head = hasFrontMatter || lines.length ? [FENCE, ...lines, FENCE] : [];
  return `${[...head, '', newBody.replace(/\s+$/, ''), ''].join('\n')}`;
}

export function renderRecordFile(fields, body) {
  const lines = Object.entries(fields)
    .filter(([, v]) => v !== undefined)
    .map(([k, v]) => `${k}: ${formatValue(v)}`);
  return `${[FENCE, ...lines, FENCE, '', String(body).trim(), ''].join('\n')}`;
}
