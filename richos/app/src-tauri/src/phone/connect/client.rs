use crate::phone::{b64url, hex, now_millis, random_bytes, sha256, PhoneError};
use crate::phone::secrets::SecretStore;
use ring::signature::{EcdsaKeyPair, KeyPair, ECDSA_P256_SHA256_FIXED_SIGNING};
use serde::{Deserialize, Serialize};
use std::time::Duration;

const IDENTITY_KEY: &str = "connect-host-identity-v1";
pub const TOKEN_KEY: &str = "connect-tunnel-token-v1";

pub struct Identity { key: EcdsaKeyPair }
impl Identity {
    pub fn open(secrets: &dyn SecretStore) -> Result<Self, PhoneError> {
        let rng = ring::rand::SystemRandom::new();
        let bytes = match secrets.get(IDENTITY_KEY)? {
            Some(bytes) => bytes,
            None => {
                let document = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng)
                    .map_err(|_| PhoneError::Crypto("Connect identity generation failed".into()))?;
                secrets.put(IDENTITY_KEY, document.as_ref())?;
                document.as_ref().to_vec()
            }
        };
        let key = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &bytes, &rng)
            .map_err(|_| PhoneError::Crypto("Connect identity is unreadable".into()))?;
        Ok(Self { key })
    }
    pub fn public_key(&self) -> String { b64url(self.key.public_key().as_ref()) }
    pub fn id(&self) -> String { hex(&sha256(self.key.public_key().as_ref()))[..32].into() }
    pub fn headers(&self, method: &str, path: &str, body: &str, time: u64, nonce: &str)
        -> Result<Vec<(&'static str, String)>, PhoneError> {
        let canonical = format!("RICHOS-CONNECT-V1\n{time}\n{nonce}\n{method}\n{path}\n{}", hex(&sha256(body.as_bytes())));
        let signature = self.key.sign(&ring::rand::SystemRandom::new(), canonical.as_bytes())
            .map_err(|_| PhoneError::Crypto("Connect signing failed".into()))?;
        Ok(vec![("x-richos-key", self.public_key()), ("x-richos-time", time.to_string()),
            ("x-richos-nonce", nonce.into()), ("x-richos-signature", b64url(signature.as_ref()))])
    }
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Allocation {
    pub id: String,
    pub generation: u64,
    pub enabled: bool,
    pub phase: String,
    pub endpoint: String,
    pub device_key_hash: Option<String>,
    pub error: Option<String>,
}
impl Allocation {
    pub fn validate(&self, identity: &Identity) -> Result<(), PhoneError> {
        if self.id != identity.id() || self.generation == 0 || self.generation > 1_000_000
            || self.endpoint != format!("https://c-{}-g{}.richos.ceo", self.id, self.generation)
            || !["pending", "active", "disabled"].contains(&self.phase.as_str()) {
            return Err(PhoneError::Malformed("RichOS Connect returned an invalid Mac address. Try again later.".into()));
        }
        Ok(())
    }
}

// Does not derive Debug: a successful token response contains a secret.
pub struct Reply { pub status: u16, pub value: serde_json::Value }
pub struct Client { origin: String, pub identity: Identity }
impl Client {
    pub fn new(identity: Identity) -> Self { Self { origin: super::ORIGIN.into(), identity } }
    pub fn call(&self, method: &str, path: &str, body: &str) -> Result<Reply, PhoneError> {
        if !matches!((method,path), ("POST","/v1/hosts") | ("GET","/v1/host") |
            ("DELETE","/v1/host") | ("POST","/v1/host/token") | ("PUT","/v1/host/device")) {
            return Err(PhoneError::Malformed("Unknown Connect action".into()));
        }
        let headers = self.identity.headers(method,path,body,now_millis(),&hex(&random_bytes(16)?))?;
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()?;
        runtime.block_on(async {
            let _ = rustls::crypto::ring::default_provider().install_default();
            let client = reqwest::Client::builder().timeout(Duration::from_secs(25))
                .connect_timeout(Duration::from_secs(8)).redirect(reqwest::redirect::Policy::none())
                .build().map_err(|_| unavailable())?;
            let mut request = client.request(method.parse().map_err(|_| unavailable())?, format!("{}{path}",self.origin))
                .header("Content-Type","application/json").body(body.to_string());
            for (name,value) in headers { request = request.header(name,value); }
            let mut response = request.send().await.map_err(|_| unavailable())?;
            let status = response.status().as_u16();
            let mut bytes = Vec::new();
            while let Some(chunk) = response.chunk().await.map_err(|_| unavailable())? {
                if bytes.len() + chunk.len() > 16_384 { return Err(unavailable()); }
                bytes.extend_from_slice(&chunk);
            }
            let value = serde_json::from_slice(&bytes).map_err(|_| unavailable())?;
            Ok(Reply { status, value })
        })
    }
    pub fn allocation(&self, reply: &Reply) -> Result<Allocation, PhoneError> {
        if reply.status == 403 {
            return Err(PhoneError::Malformed("RichOS Connect is in a private pilot. This Mac has not been admitted yet.".into()));
        }
        if reply.status != 200 { return Err(unavailable()); }
        let allocation: Allocation = serde_json::from_value(reply.value.clone()).map_err(|_| unavailable())?;
        allocation.validate(&self.identity)?;
        Ok(allocation)
    }
}
pub fn unavailable() -> PhoneError {
    PhoneError::Malformed("RichOS Connect could not be reached. Your conversations are kept on your devices. Try again shortly.".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::phone::{secrets::MemorySecrets, unb64url};
    #[test]
    fn identity_survives_reopen_and_signatures_bind_the_exact_request() {
        let secrets = MemorySecrets::default();
        let identity = Identity::open(&secrets).unwrap();
        assert_eq!(identity.id(), Identity::open(&secrets).unwrap().id());
        let headers = identity.headers("POST","/v1/hosts","{}",123,"abcd").unwrap();
        let canonical = format!("RICHOS-CONNECT-V1\n123\nabcd\nPOST\n/v1/hosts\n{}",hex(&sha256(b"{}")));
        let verifier = ring::signature::UnparsedPublicKey::new(&ring::signature::ECDSA_P256_SHA256_FIXED, identity.key.public_key().as_ref());
        let signature = unb64url(&headers[3].1).unwrap();
        verifier.verify(canonical.as_bytes(),&signature).unwrap();
        assert!(verifier.verify(canonical.replace("POST","DELETE").as_bytes(),&signature).is_err());
        assert_ne!(identity.id(),Identity::open(&MemorySecrets::default()).unwrap().id());
    }
    #[test]
    fn allocation_cannot_redirect_the_connector_to_another_host() {
        let identity = Identity::open(&MemorySecrets::default()).unwrap();
        let mut a = Allocation { id: identity.id(), generation: 1, enabled: true, phase: "active".into(),
            endpoint: format!("https://c-{}-g1.richos.ceo",identity.id()), ..Default::default() };
        a.validate(&identity).unwrap();
        a.endpoint += ".attacker.example";
        assert!(a.validate(&identity).is_err());
    }
}
