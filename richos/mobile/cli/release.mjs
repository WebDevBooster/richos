import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
// `build` is the Xcode configuration being packaged. Release carries the hosted policy address
// from release-config.json. A Debug build without an explicit external configuration has no
// policy authority, so development keeps its local override (RICHOS_MOBILE_RELEASE_CONFIG) and
// a development phone never reads production policy by accident.
export function configuration(path, distribution = false, build = 'Release') {
  if (!['Debug', 'Release'].includes(build)) throw Error('Build configuration must be Debug or Release');
  const external = path || process.env.RICHOS_MOBILE_RELEASE_CONFIG;
  const value = JSON.parse(readFileSync(external || fileURLToPath(new URL('../release-config.json', import.meta.url)), 'utf8'));
  if (build === 'Debug' && !external) value.policyURL = null;
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
