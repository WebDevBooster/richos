import { encode } from './auth.mjs';
const utf8 = new TextEncoder();
// Keys are server secrets, split by APNs environment. No caller supplies a topic,
// hostname, alert or signing credential outside the operator's allowlist.
export function configuredPush(env, registration) {
  const name = registration.environment === 'sandbox' ? 'SANDBOX' : registration.environment === 'production' ? 'PRODUCTION' : null;
  const topics = (env.APNS_TOPICS || '').split(',');
  return !!(name && topics.includes(registration.topic) && /^[A-Z0-9]{10}$/.test(env.APNS_TEAM_ID || '')
    && /^[A-Z0-9]{10}$/.test(env[`APNS_${name}_KEY_ID`] || '') && env[`APNS_${name}_KEY`]);
}
export class APNs {
  constructor(env, { fetchImpl = (url, options) => fetch(url, options), now = Date.now } = {}) { this.env = env; this.fetch = fetchImpl; this.now = now; this.tokens = new Map(); }
  async token(environment) {
    const name = environment === 'sandbox' ? 'SANDBOX' : 'PRODUCTION', now = Math.floor(this.now()/1000);
    const cached = this.tokens.get(environment);
    if (cached && now - cached.at < 2400) return cached.value;
    const pem = this.env[`APNS_${name}_KEY`].replace(/-----[^-]+-----/g,'').replace(/\s/g,'');
    const key = await crypto.subtle.importKey('pkcs8', Uint8Array.from(atob(pem),c=>c.charCodeAt(0)), {name:'ECDSA',namedCurve:'P-256'},false,['sign']);
    const content = encode(utf8.encode(JSON.stringify({alg:'ES256',kid:this.env[`APNS_${name}_KEY_ID`]}))) + '.'
      + encode(utf8.encode(JSON.stringify({iss:this.env.APNS_TEAM_ID,iat:now})));
    const value = content + '.' + encode(await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},key,utf8.encode(content)));
    this.tokens.set(environment,{value,at:now}); return value;
  }
  async send(binding, job) {
    if (!configuredPush(this.env,binding)) return { outcome:'configuration' };
    const host = binding.environment === 'sandbox' ? 'api.sandbox.push.apple.com' : 'api.push.apple.com';
    let bearer;
    try {bearer=await this.token(binding.environment);} catch {return {outcome:'configuration',code:'signing'};}
    try {
      const response = await this.fetch(`https://${host}/3/device/${binding.token}`, {
        method:'POST', redirect:'manual', signal:AbortSignal.timeout(10000), headers:{
          authorization:'bearer '+bearer, 'content-type':'application/json',
          'apns-topic':binding.topic, 'apns-push-type':'alert', 'apns-priority':'10',
          'apns-expiration':String(Math.floor(job.expires_at/1000)), 'apns-collapse-id':job.event_ref,
        }, body:JSON.stringify({aps:{alert:{title:'RichOS',body:'Rich has replied.'},sound:'default'},
          richos:{host:binding.host_id,thread:job.thread_ref,event:job.event_ref}}),
      });
      if (response.status === 200) return {outcome:'sent'};
      const reason = (await response.json().catch(()=>({}))).reason;
      if (response.status === 410 || ['BadDeviceToken','DeviceTokenNotForTopic','Unregistered'].includes(reason)) return {outcome:'invalid'};
      if (response.status === 429 || response.status >= 500) return {outcome:'retry',code:'http_'+response.status};
      return {outcome:'configuration',code:'http_'+response.status};
    } catch(error) { return {outcome:'retry',code:error.name==='TimeoutError'?'timeout':'transport'}; }
  }
}
