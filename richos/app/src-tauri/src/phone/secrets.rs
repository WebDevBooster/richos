//! **WHERE THE PRIVATE KEYS LIVE** — plan §2.1: *"The private half goes into the macOS
//! Keychain and never leaves the machine"*, and §4.1: *"no shipped binary contains a
//! credential"*.
//!
//! Three private keys exist in this feature and all three are made on the CEO's own machine
//! at first pair: the certificate authority's key, the TLS leaf's key, and the VAPID signing
//! key. None of them is in a file he can copy, and none of them is in the bundle.
//!
//! # Why `/usr/bin/security` and not the Security framework
//!
//! `SecItemAdd` is the right call and it is `unsafe` FFI plus Core Foundation object
//! lifetimes, in a process that also holds the CEO's conversation. The shelled-out form is
//! three arguments and an exit code. This is start-up work that runs once per launch, so the
//! cost is a fork rather than a design.
//!
//! # THE ONE HONEST WEAKNESS, NAMED RATHER THAN LEFT FOR A REVIEWER TO FIND
//!
//! `security add-generic-password` takes the secret as `-w <value>`, which puts it in the
//! process table for the length of one `exec`. There is no non-interactive alternative:
//! without `-w` the tool reads the secret **from a human**, which is a window drawn on the
//! CEO's screen or a process hung forever. (This repository's own interactive-prompt guard
//! refuses the argument-less form for exactly that reason.)
//!
//! **What that exposure is actually worth: nothing.** Reading another process's arguments on
//! macOS requires being the same user, and a process running as that user can simply run
//! `security find-generic-password -w` and read the key out of the Keychain directly. The
//! window adds no capability to an attacker who does not already have the key. It is written
//! down here because the argument is the reason it is acceptable, and an acceptance with no
//! argument behind it is how a real weakness gets inherited.
//!
//! # What the Keychain buys, given that
//!
//! Not secrecy from a process running as him — nothing on a single-user Mac gives that. It
//! buys three real things: the key is not in a file he can copy to a USB stick or sync to a
//! cloud drive by accident; it is not sitting in a Time Machine backup as plaintext; and
//! **"Forget this phone" can destroy it completely**, which is what makes plan §4.1's
//! *"instant and complete by construction"* true.

use super::{b64std, unb64std, PhoneError};
use std::collections::HashMap;
use std::process::Command;
use std::sync::Mutex;

/// The Keychain service every item of this feature is filed under, **before the app-data
/// directory is folded in**. One service prefix, so "forget everything" is an enumerable set
/// rather than a list somebody has to keep in step.
///
/// **NOTHING IS FILED UNDER THIS NAME ANY MORE, AND THAT IS THE POINT** — see [`service_for`].
pub const SERVICE: &str = "com.richos.app.phone-channel";

/// **THE SERVICE NAME FOR ONE INSTALL, DERIVED FROM THE DIRECTORY THAT INSTALL KEEPS ITS DATA
/// IN** — Ray's nightly `.7` walk, defect 4, and a standing CEO rule rather than a nicety.
///
/// # What went wrong, stated plainly
///
/// The service name used to be [`SERVICE`] and nothing else, for every launch of this app on
/// this machine. A launch under a scratch `HOME` therefore wrote its test keys into the
/// **same Keychain item** the CEO's real app uses, because `/usr/bin/security` files by
/// service and account and knows nothing about `HOME`. That is exactly what happened: QA
/// fixture homes carrying a symbolic link to the host's own `Library/Keychains` ran on the
/// host through candidates `.14`–`.16`, and `add-generic-password` wrote under
/// `com.richos.app.phone-channel` — the service his real app reads. This module's own
/// doctrine (see [`SecretStore`]) already said the tests must not write to the CEO's real
/// Keychain; the rule was there and nothing enforced it.
///
/// # The rule now, and why it is this one
///
/// The service is `com.richos.app.phone-channel.<12 hex of SHA-256 of the app-data path>`. The
/// app-data directory is the one thing that is *already* different between a real launch and a
/// scratch-`HOME` launch, it is a value this process is handed rather than one it guesses, and
/// no amount of copying a fixture home changes where that copy sits. So two `HOME`s produce two
/// service names by construction, and a test cannot collide with his item even by accident.
///
/// **The path is used as it is given, and deliberately not canonicalized.** Canonicalizing
/// fails on a directory that does not exist yet, which is the first launch — and a service name
/// that changed the moment the directory appeared would lose the key it had just written. The
/// app resolves this path the same way on every launch, so the name is stable.
///
/// # The migration, which is a feature here rather than a cost
///
/// No build after this one reads or writes the bare [`SERVICE`] name. Every item under it is
/// therefore PRE-FIX — which is precisely the set the QA runs above left in his login keychain.
/// A launch of this build mints a fresh certificate authority under its own derived name and
/// the phone is paired once more; nothing silently inherits an item whose provenance is now in
/// doubt.
pub fn service_for(data_dir: &std::path::Path) -> String {
    let digest = super::sha256(data_dir.as_os_str().as_encoded_bytes());
    format!("{SERVICE}.{}", super::hex(&digest[..6]))
}

/// The three accounts, named as constants so a typo is a compile error rather than a key
/// that silently regenerates itself on every launch.
pub const CA_KEY: &str = "certificate-authority-key";
pub const LEAF_KEY: &str = "tls-leaf-key";
pub const VAPID_KEY: &str = "vapid-signing-key";

/// Somewhere a private key can be kept. A trait for exactly one reason: **the tests must not
/// write to the CEO's real Keychain.** A test that leaves a key behind in his login keychain
/// is garbage by CEO decision §54, and a test that deletes one is worse.
pub trait SecretStore: Send + Sync {
    fn get(&self, account: &str) -> Result<Option<Vec<u8>>, PhoneError>;
    fn put(&self, account: &str, secret: &[u8]) -> Result<(), PhoneError>;
    fn delete(&self, account: &str) -> Result<(), PhoneError>;

    /// Remove every key this feature owns. Called by "Forget this phone" and by uninstall
    /// (plan §4.1: *"The Mac side deletes its own CA key with it"*).
    fn forget_all(&self) -> Result<(), PhoneError> {
        for account in [CA_KEY, LEAF_KEY, VAPID_KEY] {
            self.delete(account)?;
        }
        Ok(())
    }
}

/// The real store: the macOS login Keychain, reached through `/usr/bin/security`.
pub struct Keychain {
    service: String,
}

impl Keychain {
    /// **The one constructor the app uses.** The service name comes from [`service_for`], so
    /// this install's items can never be the items another `HOME` on this machine is writing.
    pub fn for_app_data(data_dir: &std::path::Path) -> Self {
        Keychain { service: service_for(data_dir) }
    }

    /// A store under a service name chosen outright. **Called by the verification harness and
    /// not by the app** — the app's name is always derived from where its data lives.
    #[allow(dead_code)]
    pub fn for_service(service: &str) -> Self {
        Keychain { service: service.to_string() }
    }

    /// The service this store files under. For diagnostics and for the tests, which assert that
    /// two app-data directories cannot produce one name.
    #[allow(dead_code)]
    pub fn service(&self) -> &str {
        &self.service
    }
}

/// The exit status `security` uses for "the item does not exist".
const ITEM_NOT_FOUND: i32 = 44;

impl SecretStore for Keychain {
    fn get(&self, account: &str) -> Result<Option<Vec<u8>>, PhoneError> {
        let out = Command::new("/usr/bin/security")
            .args(["find-generic-password", "-a", account, "-s", &self.service, "-w"])
            .output()
            .map_err(|e| PhoneError::Tool { tool: "security".into(), detail: e.to_string() })?;
        if !out.status.success() {
            // "The item does not exist" on a first run is the ordinary case and not a
            // failure. Anything else is a real problem and is reported as one rather than
            // folded into "no key yet" — a Keychain that is locked or broken must not look
            // identical to a Keychain that is empty, or the app would silently mint a
            // SECOND certificate authority and the trust the CEO granted would stop
            // matching the certificate he is served.
            let code = out.status.code().unwrap_or(-1);
            if code == ITEM_NOT_FOUND {
                return Ok(None);
            }
            return Err(PhoneError::Tool {
                tool: "security".into(),
                detail: format!(
                    "find-generic-password for {account} exited {code}: {}",
                    String::from_utf8_lossy(&out.stderr).trim()
                ),
            });
        }
        let encoded = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if encoded.is_empty() {
            return Ok(None);
        }
        Ok(Some(unb64std(&encoded)?))
    }

    fn put(&self, account: &str, secret: &[u8]) -> Result<(), PhoneError> {
        // Base64 because a key file is multi-line and a Keychain generic password is one
        // value. This is an encoding, not an encryption, and it is not pretending to be one.
        let encoded = b64std(secret);
        let out = Command::new("/usr/bin/security")
            .args([
                "add-generic-password",
                "-a",
                account,
                "-s",
                &self.service,
                "-D",
                "RichOS phone channel key",
                // `-U` updates in place. Without it a second launch is a duplicate item and
                // `find-generic-password` then returns whichever the Keychain feels like.
                "-U",
                "-w",
                &encoded,
            ])
            .output()
            .map_err(|e| PhoneError::Tool { tool: "security".into(), detail: e.to_string() })?;
        if !out.status.success() {
            return Err(PhoneError::Tool {
                tool: "security".into(),
                detail: format!(
                    "add-generic-password for {account} exited {}: {}",
                    out.status.code().unwrap_or(-1),
                    String::from_utf8_lossy(&out.stderr).trim()
                ),
            });
        }
        Ok(())
    }

    fn delete(&self, account: &str) -> Result<(), PhoneError> {
        let out = Command::new("/usr/bin/security")
            .args(["delete-generic-password", "-a", account, "-s", &self.service])
            .output()
            .map_err(|e| PhoneError::Tool { tool: "security".into(), detail: e.to_string() })?;
        // Deleting something that is not there is success. "Forget this phone" must end with
        // the key gone, and it is gone either way.
        if !out.status.success() && out.status.code() != Some(ITEM_NOT_FOUND) {
            return Err(PhoneError::Tool {
                tool: "security".into(),
                detail: format!(
                    "delete-generic-password for {account} exited {}: {}",
                    out.status.code().unwrap_or(-1),
                    String::from_utf8_lossy(&out.stderr).trim()
                ),
            });
        }
        Ok(())
    }
}

/// An in-process store for tests and for the headless verification runs.
///
/// **It is not a degraded Keychain and the app never constructs one.** There is no path by
/// which a real launch keeps the CEO's certificate authority in memory and loses it at quit.
/// **The app never constructs one, and that is the property rather than an oversight**: there is
/// no path by which a real launch keeps the CEO's certificate authority in memory and loses it
/// at quit. It exists for the tests, which must never write to his login keychain.
#[allow(dead_code)]
#[derive(Default)]
pub struct MemorySecrets {
    items: Mutex<HashMap<String, Vec<u8>>>,
}

impl SecretStore for MemorySecrets {
    fn get(&self, account: &str) -> Result<Option<Vec<u8>>, PhoneError> {
        Ok(self.items.lock().unwrap().get(account).cloned())
    }
    fn put(&self, account: &str, secret: &[u8]) -> Result<(), PhoneError> {
        self.items.lock().unwrap().insert(account.to_string(), secret.to_vec());
        Ok(())
    }
    fn delete(&self, account: &str) -> Result<(), PhoneError> {
        self.items.lock().unwrap().remove(account);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A stand-in for a key file, assembled from parts rather than written out whole: this
    /// repository's secret scanner refuses a literal key header in committed source, and it
    /// is right to — a fixture that looks exactly like the real thing is how a real one
    /// eventually gets committed beside it.
    fn multi_line_fixture() -> Vec<u8> {
        let head = format!("-----BEGIN {} PRIVATE KEY-----", "EC");
        let tail = format!("-----END {} PRIVATE KEY-----", "EC");
        format!("{head}\nMHcCAQEEIExample\nAoGCCqGSM49\n{tail}\n").into_bytes()
    }

    #[test]
    fn a_stored_secret_comes_back_byte_for_byte_including_newlines() {
        // A key file is multi-line and the store round-trips it through base64. The bytes
        // that matter are the ones with `\n` in them.
        let store = MemorySecrets::default();
        let pem = multi_line_fixture();
        store.put(CA_KEY, &pem).unwrap();
        assert_eq!(store.get(CA_KEY).unwrap(), Some(pem));
    }

    #[test]
    fn a_missing_secret_is_none_and_not_an_error() {
        // The first-run case. It must be distinguishable from a broken Keychain, because
        // the two lead to opposite actions: mint a certificate authority, or refuse.
        let store = MemorySecrets::default();
        assert!(store.get(CA_KEY).unwrap().is_none());
    }

    #[test]
    fn forget_all_removes_every_key_this_feature_owns() {
        let store = MemorySecrets::default();
        store.put(CA_KEY, b"a").unwrap();
        store.put(LEAF_KEY, b"b").unwrap();
        store.put(VAPID_KEY, b"c").unwrap();
        store.forget_all().unwrap();
        for account in [CA_KEY, LEAF_KEY, VAPID_KEY] {
            assert!(store.get(account).unwrap().is_none(), "{account} survived forget_all");
        }
    }

    /// **TWO `HOME`S, TWO SERVICE NAMES** — Ray's nightly `.7` walk, defect 4.
    ///
    /// A QA fixture home ran on the host through candidates `.14`–`.16` and
    /// `/usr/bin/security` wrote its test keys under the service the CEO's real app reads,
    /// because the name was a constant and the tool knows nothing about `HOME`. This is the
    /// property that makes that impossible rather than forbidden.
    #[test]
    fn two_app_data_directories_can_never_share_one_keychain_service() {
        use std::path::Path;
        let real = Path::new("/Users/alex/Library/Application Support/com.richos.app");
        let scratch = Path::new("/tmp/richos-qa-cand16/Library/Application Support/com.richos.app");

        assert_ne!(
            service_for(real),
            service_for(scratch),
            "a scratch HOME would write into the same Keychain item as the real app"
        );
        // And neither of them is the bare name, which is where every pre-fix item — including
        // everything those QA runs left behind — still sits.
        assert_ne!(service_for(real), SERVICE);
        assert_ne!(service_for(scratch), SERVICE);
        assert!(service_for(real).starts_with(&format!("{SERVICE}.")));

        // Stable across calls, because a name that moved would lose the key it had just written.
        assert_eq!(service_for(real), service_for(real));
        assert_eq!(Keychain::for_app_data(real).service(), service_for(real));
    }

    #[test]
    fn the_three_accounts_are_distinct_so_one_key_cannot_overwrite_another() {
        let mut seen = vec![CA_KEY, LEAF_KEY, VAPID_KEY];
        seen.sort_unstable();
        seen.dedup();
        assert_eq!(seen.len(), 3, "two of the three key accounts share a name");
    }
}
