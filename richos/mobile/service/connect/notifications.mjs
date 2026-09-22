import { configuredPush } from './apns.mjs';
const hex = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
const revision = value => Number.isSafeInteger(value) && value > 0;
const exact = (data, keys) => data && typeof data === 'object' && !Array.isArray(data) && Object.keys(data).every(k=>keys.includes(k));
export class Notifications {
  constructor(store, apns, env) { this.store=store; this.apns=apns; this.env=env; }
  binding(id) { return this.store.statement('SELECT * FROM push_bindings WHERE host_id=?',id).first(); }
  async register(host, data) {
    if (!exact(data,['revision','generation','deviceHash','token','environment','topic','route']) || !revision(data.revision)
      || data.generation !== host.generation || !['connect','tailnet'].includes(data.route)
      || (data.token !== null && (!hex(data.deviceHash) || !/^[a-f0-9]{32,512}$/.test(data.token || '')
        || !['sandbox','production'].includes(data.environment) || !configuredPush(this.env,data)))) return {status:400,error:'invalid_registration'};
    if (data.token !== null && data.route === 'connect' && (!host.desired || host.phase !== 'active' || host.device_key_hash !== data.deviceHash)) return {status:409,error:'pairing_changed'};
    const old=await this.binding(host.id);
    if (old && data.revision < old.revision) return {status:409,error:'registration_changed'};
    if (old && data.revision === old.revision) {
      const same = old.token === data.token && old.device_hash === (data.token ? data.deviceHash : null)
        && old.generation === data.generation && (data.token === null || (old.environment === data.environment && old.topic === data.topic && old.route === data.route));
      return same ? {status:200,hostId:host.id,revision:old.revision} : {status:409,error:'registration_changed'};
    }
    await this.store.db.batch([
      this.store.statement('DELETE FROM push_jobs WHERE host_id=?',host.id),
      this.store.statement(`INSERT INTO push_bindings(host_id,revision,device_hash,token,environment,topic,route,generation,updated_at) VALUES(?,?,?,?,?,?,?,?,?)
        ON CONFLICT(host_id) DO UPDATE SET revision=excluded.revision,device_hash=excluded.device_hash,token=excluded.token,environment=excluded.environment,topic=excluded.topic,route=excluded.route,generation=excluded.generation,updated_at=excluded.updated_at`,
      host.id,data.revision,data.token ? data.deviceHash : null,data.token,data.token ? data.environment : null,data.token ? data.topic : null,data.route,data.generation,this.store.now()),
    ]);
    return {status:200,hostId:host.id,revision:data.revision};
  }
  async invalidate(id) {
    await this.store.db.batch([
      this.store.statement('UPDATE push_bindings SET token=NULL,device_hash=NULL,updated_at=? WHERE host_id=?',this.store.now(),id),
      this.store.statement('DELETE FROM push_jobs WHERE host_id=?',id),
    ]);
  }
  valid(host,binding) {
    return binding?.token && binding.generation===host.generation && (binding.route==='tailnet' ||
      (host.desired && host.phase==='active' && binding.device_hash===host.device_key_hash));
  }
  async enqueue(host,data) {
    if (!exact(data,['eventRef','threadRef','revision','deviceHash']) || !hex(data.eventRef) || !hex(data.threadRef) || !hex(data.deviceHash) || !revision(data.revision)) return {status:400,error:'invalid_event'};
    const binding=await this.binding(host.id);
    if (!this.valid(host,binding) || binding.revision!==data.revision || binding.device_hash!==data.deviceHash) return {status:409,error:'pairing_changed'};
    const now=this.store.now();
    await this.store.statement('DELETE FROM push_jobs WHERE expires_at<=?',now).run();
    await this.store.statement(`INSERT OR IGNORE INTO push_jobs(host_id,event_ref,thread_ref,revision,expires_at,next_at)
      SELECT ?,?,?,?,?,? WHERE (SELECT count(*) FROM push_jobs WHERE host_id=?) < 100`,host.id,data.eventRef,data.threadRef,data.revision,now+3600000,now,host.id).run();
    const job=await this.store.statement('SELECT * FROM push_jobs WHERE host_id=? AND event_ref=?',host.id,data.eventRef).first();
    if (!job) return {status:429,error:'queue_full'};
    if (job.thread_ref!==data.threadRef || job.revision!==data.revision) return {status:409,error:'event_conflict'};
    const result=await this.deliver(host,binding,job);
    return {status:202,accepted:true,delivery:result || {outcome:job.state}};
  }
  // Caller holds the same host lease used for revocation and token rotation.
  async deliver(host,binding,job) {
    const now=this.store.now();
    if (job.state!=='pending' || job.next_at>now || job.expires_at<=now) return;
    if (!this.valid(host,binding) || job.revision!==binding.revision) { await this.invalidate(host.id); return; }
    const result=await this.apns.send(binding,job), {outcome}=result;
    if (outcome==='invalid') { await this.invalidate(host.id); return result; }
    const attempts=job.attempts+1;
    const state=outcome==='sent' ? 'sent' : outcome==='retry' && attempts<5 ? 'pending' : 'failed';
    await this.store.statement('UPDATE push_jobs SET state=?,attempts=?,next_at=? WHERE host_id=? AND event_ref=?',state,attempts,now+Math.min(900000,60000*2**attempts),host.id,job.event_ref).run();
    return result;
  }
  async reconcile() {
    const now=this.store.now();
    await this.store.statement('DELETE FROM push_jobs WHERE expires_at<=?',now).run();
    const jobs=(await this.store.statement("SELECT * FROM push_jobs WHERE state='pending' AND next_at<=? LIMIT 20",now).all()).results;
    for (const job of jobs) {
      const lease=await this.store.lease(job.host_id); if (!lease) continue;
      try {
        const host=await this.store.get(job.host_id), binding=await this.binding(job.host_id);
        const current=await this.store.statement('SELECT * FROM push_jobs WHERE host_id=? AND event_ref=?',job.host_id,job.event_ref).first();
        if (host && current) await this.deliver(host,binding,current);
      } finally {await this.store.release(job.host_id,lease);}
    }
  }
}
