// Loro public component. SPDX-License-Identifier: AGPL-3.0-only
export const CEO_LANE = 'ceo';

export const PARTITION_TUNING = {

  CEO_BUDGET_FRACTION: 0.25,

  CEO_BUDGET_FLOOR_CHARS: 200,

  CEO_ITEM_FRACTION: 0.25,

  CEO_ITEM_FLOOR: 1,
};

export function laneOf(rec) {
  return rec && typeof rec.company === 'string' && rec.company ? rec.company : CEO_LANE;
}

export function partitionRecords(records, companyIds) {
  const lanes = new Map();
  lanes.set(CEO_LANE, { id: CEO_LANE, isCeo: true, records: [] });
  for (const id of companyIds) {
    if (!lanes.has(id)) lanes.set(id, { id, isCeo: false, records: [] });
  }
  for (const rec of records) {
    const lane = lanes.get(laneOf(rec));
    if (lane) lane.records.push(rec);
  }
  return [...lanes.values()];
}

export function splitEvenly(total, n) {
  if (n <= 0) return [];
  const safe = Math.max(0, Math.floor(total));
  const base = Math.floor(safe / n);
  const rem = safe % n;
  return Array.from({ length: n }, (_, i) => base + (i < rem ? 1 : 0));
}

export function ceoCharShare(available) {
  const avail = Math.max(0, Math.floor(available));
  const { CEO_BUDGET_FRACTION: f, CEO_BUDGET_FLOOR_CHARS: floor } = PARTITION_TUNING;
  return Math.min(avail, Math.max(floor, Math.round(f * avail)));
}

export function allocateChars(available, lanes) {
  const avail = Math.max(0, Math.floor(available));
  if (lanes.length === 0) return [];
  if (lanes.length === 1) return [avail];
  const ceoIdx = lanes.findIndex((l) => l.isCeo);
  if (ceoIdx < 0) return splitEvenly(avail, lanes.length);
  const ceoShare = ceoCharShare(avail);
  const companyShares = splitEvenly(avail - ceoShare, lanes.length - 1);
  const out = [];
  let c = 0;
  for (let i = 0; i < lanes.length; i += 1) out.push(i === ceoIdx ? ceoShare : companyShares[c++]);
  return out;
}

export function allocateItems(maxItems, lanes) {
  const max = Math.max(0, Math.floor(maxItems));
  if (lanes.length === 0) return [];
  if (lanes.length === 1) return [max];
  const ceoIdx = lanes.findIndex((l) => l.isCeo);
  if (ceoIdx < 0) return splitEvenly(max, lanes.length);
  const { CEO_ITEM_FRACTION: f, CEO_ITEM_FLOOR: floor } = PARTITION_TUNING;
  const ceoShare = Math.min(max, Math.max(max > 0 ? floor : 0, Math.round(f * max)));
  const companyShares = splitEvenly(max - ceoShare, lanes.length - 1);
  const out = [];
  let c = 0;
  for (let i = 0; i < lanes.length; i += 1) out.push(i === ceoIdx ? ceoShare : companyShares[c++]);
  return out;
}

export function resolveCompanies(opts) {
  const known = Array.isArray(opts.companies) ? opts.companies : [];
  const retired = new Set(Array.isArray(opts.retired) ? opts.retired : []);
  const active = known.filter((id) => !retired.has(id));
  const raw = opts.requested;
  if (raw === undefined || raw === null || raw === '' || raw === true) return active.slice();

  const asked = (Array.isArray(raw) ? raw : String(raw).split(','))
    .map((s) => String(s).trim())
    .filter(Boolean);
  if (!asked.length) return active.slice();
  if (asked.length === 1 && asked[0] === 'all') return active.slice();

  const unknown = asked.filter((id) => id !== 'all' && !known.includes(id));
  if (unknown.length) {
    throw new Error(
      `loro --company: no such company partition ${unknown.map((u) => `"${u}"`).join(', ')} in this corpus. ` +
        `Known: ${known.length ? known.join(', ') : '(none)'}. Refusing to compile an empty lane and ` +
        'call it an answer — a mistyped company id must not look like a company with nothing in it.',
    );
  }
  const out = [];
  for (const id of asked) {
    if (id === 'all') {
      for (const a of active) if (!out.includes(a)) out.push(a);
    } else if (!out.includes(id)) out.push(id);
  }
  return out;
}
