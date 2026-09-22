const knownErrors = new Set(['provider_unavailable', 'resource_conflict', 'tunnel_missing', 'lease_lost', 'provider_transport_failed']);
import { Notifications } from './notifications.mjs';
export function view(host) {
  return { id: host.id, generation: host.generation, enabled: !!host.desired,
    phase: host.phase, endpoint: `https://${host.hostname}`, deviceKeyHash: host.device_key_hash,
    error: host.last_error, pollAfterSeconds: 60 };
}

export async function transition(store, provider, id, action, domain) {
  const lease = await store.lease(id);
  if (!lease) throw Error('busy');
  try {
    let host = await store.get(id);
    if (action === 'enable' && host.phase === 'disabled') {
      const generation = host.generation + 1;
      if (generation > 1_000_000) throw Error('generation_exhausted');
      await store.write(id, lease, { generation, hostname: `c-${id}-g${generation}.${domain}`,
        desired: 1, phase: 'pending', tunnel_id: null, dns_id: null, device_key_hash: null });
    } else if (action === 'disable') {
      await store.write(id, lease, { desired: 0, phase: 'pending', device_key_hash: null });
      await new Notifications(store).invalidate(id);
    }
    host = await store.get(id);
    if (!host.desired) {
      await provider.remove(host);
      await store.write(id, lease, { phase: 'disabled', tunnel_id: null, dns_id: null, last_error: null });
    } else {
      if (!host.tunnel_id) {
        const tunnel = await provider.createTunnel(host);
        if (!tunnel?.id) throw Error('provider_unavailable');
        await store.write(id, lease, { tunnel_id: tunnel.id });
        host = await store.get(id);
      }
      await provider.configure(host);
      const dns = await provider.dns(host);
      if (!dns?.id) throw Error('provider_unavailable');
      await store.write(id, lease, { dns_id: dns.id, phase: 'active', last_error: null });
    }
    return view(await store.get(id));
  } catch (error) {
    const code = knownErrors.has(error.message) ? error.message : error instanceof TypeError ? 'runtime_type_error' : error.name === 'TimeoutError' ? 'provider_timeout' : 'service_unavailable';
    try { await store.write(id, lease, { last_error: code }); } catch { /* A newer lease owns recovery. */ }
    throw Error(code);
  } finally { await store.release(id, lease); }
}
