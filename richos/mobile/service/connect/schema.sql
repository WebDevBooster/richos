-- Schema 1. Public identities and routing state only, never conversation content.
CREATE TABLE IF NOT EXISTS hosts (
  id TEXT PRIMARY KEY,
  public_key TEXT NOT NULL,
  generation INTEGER NOT NULL DEFAULT 1 CHECK (generation > 0),
  desired INTEGER NOT NULL DEFAULT 1 CHECK (desired IN (0,1)),
  phase TEXT NOT NULL DEFAULT 'pending' CHECK (phase IN ('pending','active','disabled')),
  tunnel_id TEXT,
  dns_id TEXT,
  hostname TEXT NOT NULL,
  lease_id TEXT,
  lease_until INTEGER NOT NULL DEFAULT 0,
  device_key_hash TEXT,
  created_at INTEGER NOT NULL,
  last_seen INTEGER NOT NULL,
  last_error TEXT
);
CREATE TABLE IF NOT EXISTS nonces (
  host_id TEXT NOT NULL,
  nonce TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  PRIMARY KEY (host_id, nonce)
);
CREATE INDEX IF NOT EXISTS nonces_expiry ON nonces(expires_at);
CREATE TABLE IF NOT EXISTS allowed_hosts (id TEXT PRIMARY KEY);
