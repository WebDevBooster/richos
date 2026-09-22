import { encode } from './auth.mjs';
const utf8 = new TextEncoder();
// Firebase Cloud Messaging HTTP v1 for the native Android app, with the same contract as apns.mjs:
// send(binding, job) resolves to {outcome: 'sent'|'retry'|'invalid'|'configuration', code?}.
// The service-account key is the Worker secret FCM_SERVICE_ACCOUNT (the JSON file Google issues).
// It never leaves the Worker, is never logged, and no caller supplies a project, app or credential.
const OAUTH = 'https://oauth2.googleapis.com/token';
const SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';
const PROJECT = /^[a-z][a-z0-9-]{4,28}[a-z0-9]$/;
// Android application IDs: two or more dot-separated segments, each starting with a letter.
export const ANDROID_APP = /^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/;
// FCM registration tokens are opaque; observed tokens are URL-safe base64 with one colon. The
// bound keeps a token well inside the 8 KiB signed-body limit without assuming a fixed length.
export const FCM_TOKEN = /^[A-Za-z0-9_:-]{32,4096}$/;

let parsed = { source: null, value: null };
// Access tokens live for the isolate, not the request: the Worker builds a sender per request, and a
// per-request cache would cost one Google OAuth round trip per push. Keyed by the installed secret,
// so a rotated key never reuses the old key's token; bounded so rotations cannot grow it.
const accessTokens = new Map();
function account(env) {
  const source = env.FCM_SERVICE_ACCOUNT;
  if (typeof source !== 'string' || !source) return null;
  if (parsed.source !== source) {
    let value = null;
    try {
      const json = JSON.parse(source);
      if (json.type === 'service_account' && PROJECT.test(json.project_id || '') && typeof json.client_email === 'string'
        && /^[^\s@]+@[^\s@]+$/.test(json.client_email) && typeof json.private_key === 'string' && json.private_key.includes('PRIVATE KEY')
        && (json.private_key_id === undefined || /^[a-f0-9]{16,64}$/.test(json.private_key_id))) {
        value = { projectId: json.project_id, email: json.client_email, key: json.private_key, keyId: json.private_key_id };
      }
    } catch { /* A malformed secret is a configuration failure, never an exception with its content. */ }
    parsed = { source, value };
  }
  return parsed.value;
}

// Registration and delivery both require: a well-formed secret for the configured project, and an
// application ID on the operator's allowlist. A mismatch refuses registration instead of sending.
export function configuredFcm(env, registration) {
  const credential = account(env), apps = (env.FCM_APPS || '').split(',');
  return !!(credential && PROJECT.test(env.FCM_PROJECT_ID || '') && credential.projectId === env.FCM_PROJECT_ID
    && ANDROID_APP.test(registration.topic || '') && apps.includes(registration.topic));
}

// Google's INVALID_ARGUMENT covers both a bad token and a bad request. Only a violation naming the
// token deletes the registration; anything else is our fault and keeps the phone's token.
function tokenRejected(error) {
  return (error?.details || []).some(detail => detail?.['@type'] === 'type.googleapis.com/google.rpc.BadRequest'
    && (detail.fieldViolations || []).some(violation => violation?.field === 'message.token'));
}
function fcmCode(error) {
  const detail = (error?.details || []).find(d => d?.['@type'] === 'type.googleapis.com/google.firebase.fcm.v1.FcmError');
  return typeof detail?.errorCode === 'string' ? detail.errorCode : null;
}

export class FCM {
  constructor(env, { fetchImpl = (url, options) => fetch(url, options), now = Date.now } = {}) { this.env = env; this.fetch = fetchImpl; this.now = now; }
  // A one-hour OAuth access token from a self-signed RS256 assertion (RFC 7523), cached until five
  // minutes before Google's stated expiry. Throws {retry} for transient failures.
  async token() {
    const now = Math.floor(this.now()/1000);
    const cached = accessTokens.get(this.env.FCM_SERVICE_ACCOUNT);
    if (cached && now < cached.expires - 300) return cached.value;
    const credential = account(this.env);
    let assertion;
    try {
      const pem = credential.key.replace(/-----[^-]+-----/g,'').replace(/\s/g,'');
      const key = await crypto.subtle.importKey('pkcs8', Uint8Array.from(atob(pem),c=>c.charCodeAt(0)), {name:'RSASSA-PKCS1-v1_5',hash:'SHA-256'},false,['sign']);
      const content = encode(utf8.encode(JSON.stringify({alg:'RS256',typ:'JWT',...(credential.keyId?{kid:credential.keyId}:{})}))) + '.'
        + encode(utf8.encode(JSON.stringify({iss:credential.email,scope:SCOPE,aud:OAUTH,iat:now,exp:now+3600})));
      assertion = content + '.' + encode(await crypto.subtle.sign({name:'RSASSA-PKCS1-v1_5'},key,utf8.encode(content)));
    } catch { throw Object.assign(Error('signing'), {retry:false}); }
    let response;
    try {
      response = await this.fetch(OAUTH, { method:'POST', redirect:'manual', signal:AbortSignal.timeout(10000),
        headers:{'content-type':'application/x-www-form-urlencoded'},
        body:new URLSearchParams({grant_type:'urn:ietf:params:oauth:grant-type:jwt-bearer',assertion}).toString() });
    } catch(error) { throw Object.assign(Error(error.name==='TimeoutError'?'oauth_timeout':'oauth_transport'), {retry:true}); }
    if (response.status === 429 || response.status >= 500) throw Object.assign(Error('oauth_http_'+response.status), {retry:true});
    const body = await response.json().catch(()=>null);
    if (response.status !== 200 || typeof body?.access_token !== 'string' || !body.access_token || !Number.isFinite(body.expires_in))
      throw Object.assign(Error('oauth_http_'+response.status), {retry:false});
    if (accessTokens.size >= 4) accessTokens.clear();
    accessTokens.set(this.env.FCM_SERVICE_ACCOUNT, { value:body.access_token, expires:now+Math.min(body.expires_in,3600) });
    return body.access_token;
  }
  async send(binding, job) {
    if (!configuredFcm(this.env,binding)) return { outcome:'configuration' };
    let bearer;
    try {bearer=await this.token();}
    catch(error) {return error.retry ? {outcome:'retry',code:error.message} : {outcome:'configuration',code:error.message};}
    // Data-only and high priority: the app decrypts the optional preview itself and always posts a
    // visible notification (Android deprioritizes high-priority messages that show nothing). Only
    // opaque references and the Mac's ciphertext cross Google; values must be strings.
    const ttl = Math.max(0, Math.floor((job.expires_at - this.now())/1000));
    const message = { token:binding.token,
      data:{ v:'1', host:binding.host_id, thread:job.thread_ref, event:job.event_ref, ...(job.preview?{preview:job.preview}:{}) },
      android:{ priority:'HIGH', ttl:ttl+'s', collapse_key:job.event_ref, restricted_package_name:binding.topic } };
    try {
      const response = await this.fetch(`https://fcm.googleapis.com/v1/projects/${this.env.FCM_PROJECT_ID}/messages:send`, {
        method:'POST', redirect:'manual', signal:AbortSignal.timeout(10000),
        headers:{ authorization:'Bearer '+bearer, 'content-type':'application/json' }, body:JSON.stringify({message}),
      });
      if (response.status === 200) return {outcome:'sent'};
      const error = (await response.json().catch(()=>({})))?.error, code = fcmCode(error);
      if (response.status === 404 || code === 'UNREGISTERED' || code === 'SENDER_ID_MISMATCH' || (response.status === 400 && tokenRejected(error))) return {outcome:'invalid'};
      // A rejected access token is dropped so the next attempt signs a fresh assertion.
      if (response.status === 401) { accessTokens.delete(this.env.FCM_SERVICE_ACCOUNT); return {outcome:'retry',code:'http_401'}; }
      if (response.status === 429 || response.status >= 500) return {outcome:'retry',code:'http_'+response.status};
      return {outcome:'configuration',code:'http_'+response.status};
    } catch(error) { return {outcome:'retry',code:error.name==='TimeoutError'?'timeout':'transport'}; }
  }
}
