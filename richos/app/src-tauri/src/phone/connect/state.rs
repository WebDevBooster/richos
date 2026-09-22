use super::client::{Allocation, Client, Identity, TOKEN_KEY};
use crate::phone::{secrets::SecretStore, PhoneError};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::io::Write;

#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    pub desired: bool,
    pub host_id: Option<String>,
    pub cleanup_pending: bool,
    pub allocation: Option<Allocation>,
}
fn path(data: &Path) -> PathBuf { data.join("phone/connect.json") }
pub fn load(data: &Path) -> Result<Config, PhoneError> {
    let p = path(data);
    match std::fs::read(&p) {
        Ok(bytes) => serde_json::from_slice(&bytes).map_err(|_| PhoneError::Malformed("RichOS Connect's saved setup is unreadable. Whoever set RichOS up needs to recover it.".into())),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Config::default()),
        Err(e) => Err(e.into()),
    }
}
pub fn save(data: &Path, config: &Config) -> Result<(), PhoneError> {
    use std::os::unix::fs::OpenOptionsExt;
    let p = path(data); std::fs::create_dir_all(p.parent().unwrap())?;
    let pending = p.with_extension("pending");
    let mut file = std::fs::OpenOptions::new().create(true).truncate(true).write(true).mode(0o600).open(&pending)?;
    file.write_all(&serde_json::to_vec(config).map_err(|e| PhoneError::Io(e.to_string()))?)?;
    file.sync_all()?; std::fs::rename(pending,&p)?;
    std::fs::File::open(p.parent().unwrap())?.sync_all()?;
    Ok(())
}
/// Persist intent first. Interrupted allocation is resumed under the same public identity.
pub fn enable(data: &Path, secrets: &dyn SecretStore) -> Result<Allocation, PhoneError> {
    let mut config = load(data)?;
    let client = Client::new(Identity::open(secrets)?);
    config.host_id = Some(client.identity.id());
    config.desired = true;
    save(data,&config)?;
    if config.cleanup_pending {
        let reply = client.call("DELETE","/v1/host","{}")?;
        if reply.status != 200 && reply.status != 404 { return Err(super::client::unavailable()); }
        config.cleanup_pending = false; save(data,&config)?;
    }
    let reply = client.call("POST","/v1/hosts","{}")?;
    let allocation = client.allocation(&reply)?;
    if !allocation.enabled || allocation.phase != "active" { return Err(super::client::unavailable()); }
    config.allocation = Some(allocation.clone()); save(data,&config)?;
    let token_reply = client.call("POST","/v1/host/token","{}")?;
    let token_allocation = client.allocation(&token_reply)?;
    if token_allocation.generation != allocation.generation { return Err(super::client::unavailable()); }
    let token = token_reply.value["token"].as_str().filter(|s| !s.is_empty() && s.len() <= 8192)
        .ok_or_else(super::client::unavailable)?;
    secrets.put(TOKEN_KEY,serde_json::json!({"generation": allocation.generation, "token": token}).to_string().as_bytes())?;
    Ok(allocation)
}
/// Caller stops its local listener/connector regardless of whether this write succeeds.
pub fn mark_disabled(data: &Path) -> Result<(), PhoneError> {
    let mut config = load(data)?; config.desired = false; config.cleanup_pending = true; save(data,&config)
}
pub fn cleanup(data: &Path, secrets: &dyn SecretStore) -> Result<(), PhoneError> {
    let mut config = load(data)?;
    if !config.cleanup_pending { return Ok(()); }
    let client = Client::new(Identity::open(secrets)?);
    let reply = client.call("DELETE","/v1/host","{}")?;
    if reply.status != 200 && reply.status != 404 { return Err(super::client::unavailable()); }
    config.cleanup_pending = false; config.allocation = None;
    secrets.delete(TOKEN_KEY)?; save(data,&config)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn disabled_intent_survives_reopen_without_discarding_cleanup_work() {
        let dir = std::env::temp_dir().join(format!("connect-state-{}-{}",std::process::id(),crate::phone::now_millis()));
        save(&dir,&Config { desired:true,..Default::default() }).unwrap();
        mark_disabled(&dir).unwrap();
        let config = load(&dir).unwrap(); assert!(!config.desired); assert!(config.cleanup_pending);
        std::fs::write(path(&dir),b"broken").unwrap(); assert!(load(&dir).is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
