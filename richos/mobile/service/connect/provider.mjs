// This adapter alone holds the operator's Cloudflare credential. Never return or log
// provider error bodies: tunnel creation/token responses contain connector secrets.
export class Provider {
  constructor(env, transport = fetch) { this.env = env; this.transport = transport; }
  async api(path, method = 'GET', value) {
    const response = await this.transport('https://api.cloudflare.com/client/v4' + path, {
      method, headers: { Authorization: `Bearer ${this.env.CF_API_TOKEN}`, 'Content-Type': 'application/json' },
      ...(value === undefined ? {} : { body: JSON.stringify(value) }),
      redirect: 'error', signal: AbortSignal.timeout(10_000),
    });
    if (response.status === 404) return null;
    if (!response.ok) throw Error('provider_unavailable');
    const body = await response.json();
    if (!body.success) throw Error('provider_unavailable');
    return body.result;
  }
  account(path) { return `/accounts/${this.env.CF_ACCOUNT_ID}${path}`; }
  zone(path) { return `/zones/${this.env.CF_ZONE_ID}${path}`; }
  name(host) { return `richos-${host.id}-g${host.generation}`; }
  async findTunnel(host) {
    const results = await this.api(this.account('/cfd_tunnel?is_deleted=false&name=' + this.name(host)));
    const matches = (results || []).filter(row => row.name === this.name(host));
    if (matches.length > 1) throw Error('resource_conflict');
    return matches[0] || null;
  }
  async createTunnel(host) {
    return await this.findTunnel(host) || await this.api(this.account('/cfd_tunnel'), 'POST', { name: this.name(host), config_src: 'cloudflare' });
  }
  async ownTunnel(host) {
    const tunnel = host.tunnel_id ? await this.api(this.account('/cfd_tunnel/' + host.tunnel_id)) : await this.findTunnel(host);
    if (tunnel && tunnel.name !== this.name(host)) throw Error('resource_conflict');
    return tunnel;
  }
  async configure(host) {
    const tunnel = await this.ownTunnel(host);
    if (!tunnel || tunnel.deleted_at) throw Error('tunnel_missing');
    await this.api(this.account(`/cfd_tunnel/${host.tunnel_id}/configurations`), 'PUT', {
      config: { ingress: [
        // One dedicated phone listener. It has no desktop admin/control routes.
        { hostname: host.hostname, service: 'http://127.0.0.1:18443', originRequest: { connectTimeout: 5 } },
        { service: 'http_status:404' },
      ] },
    });
  }
  async dns(host) {
    const records = await this.api(this.zone('/dns_records?name=' + host.hostname));
    const content = host.tunnel_id + '.cfargotunnel.com';
    if (records?.length) {
      if (records.length !== 1 || records[0].type !== 'CNAME' || records[0].content !== content || !records[0].proxied) throw Error('resource_conflict');
      return records[0];
    }
    return this.api(this.zone('/dns_records'), 'POST', { type: 'CNAME', name: host.hostname, content, proxied: true, ttl: 1, comment: this.name(host) });
  }
  async token(host) {
    const tunnel = await this.ownTunnel(host);
    if (!tunnel || tunnel.deleted_at) throw Error('tunnel_missing');
    const token = await this.api(this.account(`/cfd_tunnel/${host.tunnel_id}/token`));
    if (typeof token !== 'string' || token.length > 8192) throw Error('provider_unavailable');
    return token;
  }
  async remove(host) {
    // Recover resources created before their IDs could be committed to D1.
    const tunnel = await this.ownTunnel(host);
    const records = await this.api(this.zone('/dns_records?name=' + host.hostname));
    for (const record of records || []) {
      // Deliberately refuse unrelated records, including a replacement generation.
      if (record.type !== 'CNAME' || record.content !== (tunnel?.id || host.tunnel_id) + '.cfargotunnel.com') throw Error('resource_conflict');
      await this.api(this.zone('/dns_records/' + record.id), 'DELETE');
    }
    if (tunnel && !tunnel.deleted_at) {
      await this.api(this.account(`/cfd_tunnel/${tunnel.id}/connections`), 'DELETE');
      await this.api(this.account(`/cfd_tunnel/${tunnel.id}`), 'DELETE');
    }
  }
}
