export class Store {
  constructor(db, now = Date.now) { this.db = db; this.now = now; }
  statement(sql, ...args) { return this.db.prepare(sql).bind(...args); }
  get(id) { return this.statement('SELECT * FROM hosts WHERE id=?', id).first(); }
  async nonce(id, nonce) {
    const now = this.now();
    const results = await this.db.batch([
      this.statement('DELETE FROM nonces WHERE expires_at < ?', now),
      this.statement('INSERT OR IGNORE INTO nonces(host_id,nonce,expires_at) VALUES(?,?,?)', id, nonce, now + 120_000),
    ]);
    return results[1].meta.changes === 1;
  }
  async enroll(identity, domain, capacity, open) {
    const now = this.now();
    // A single SQL statement enforces capacity even across Worker isolates.
    await this.statement(`INSERT OR IGNORE INTO hosts(id,public_key,hostname,created_at,last_seen)
      SELECT ?,?,?,?,? WHERE (SELECT count(*) FROM hosts) < ?
      AND (? = 1 OR EXISTS(SELECT 1 FROM allowed_hosts WHERE id=?))`,
    identity.id, identity.key, `c-${identity.id}-g1.${domain}`, now, now, capacity, open ? 1 : 0, identity.id).run();
    return this.get(identity.id);
  }
  async lease(id) {
    const token = crypto.randomUUID(), now = this.now();
    const result = await this.statement('UPDATE hosts SET lease_id=?,lease_until=? WHERE id=? AND lease_until < ?', token, now + 120_000, id, now).run();
    return result.meta.changes === 1 ? token : null;
  }
  async write(id, lease, fields) {
    const allowed = ['desired','phase','generation','hostname','tunnel_id','dns_id','device_key_hash','last_seen','last_error'];
    if (!Object.keys(fields).length || Object.keys(fields).some(k => !allowed.includes(k))) throw Error('invalid_fields');
    const result = await this.statement(`UPDATE hosts SET ${Object.keys(fields).map(k => k+'=?').join(',')} WHERE id=? AND lease_id=? AND lease_until >= ?`,
      ...Object.values(fields), id, lease, this.now()).run();
    if (result.meta.changes !== 1) throw Error('lease_lost');
  }
  async release(id, lease) { await this.statement('UPDATE hosts SET lease_id=NULL,lease_until=0 WHERE id=? AND lease_id=?', id, lease).run(); }
  async pending() { return (await this.statement("SELECT id FROM hosts WHERE desired=1 OR phase!='disabled' LIMIT 10").all()).results; }
}
