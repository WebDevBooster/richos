import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
export function configuration(path = process.env.RICHOS_MOBILE_RELEASE_CONFIG || fileURLToPath(new URL('../release-config.json', import.meta.url)), distribution = false) {
  const value = JSON.parse(readFileSync(path, 'utf8'));
  for (const key of ['version', 'build']) if (typeof value[key] !== 'string' || !/^\d+(\.\d+){0,2}$/.test(value[key])) throw Error(`Invalid ${key}`);
  if (value.appId !== null && (typeof value.appId !== 'string' || !/^\d{6,15}$/.test(value.appId))) throw Error('Invalid numeric Apple app ID');
  for (const key of ['policyURL', 'supportURL']) {
    if (value[key] === null && !distribution) continue;
    let url; try { url = new URL(value[key]); } catch { throw Error(`Configure ${key} before distribution`); }
    if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash || /[\s\\]/.test(value[key])) throw Error(`Invalid ${key}`);
    if (key === 'policyURL' && url.pathname !== '/v1/policy') throw Error('policyURL must use /v1/policy');
  }
  if (distribution && !value.appId) throw Error('Configure the verified RichOS Apple app ID before distribution');
  if (value.metrics !== undefined && typeof value.metrics !== 'boolean') throw Error('metrics must be boolean');
  value.universalHosts ||= [];
  if (!Array.isArray(value.universalHosts) || value.universalHosts.some(x => typeof x !== 'string' || !/^[a-z0-9-]+(\.[a-z0-9-]+)+$/.test(x))) throw Error('Invalid universal link hosts');
  return value;
}
