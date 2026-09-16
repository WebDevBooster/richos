#![cfg(unix)]
use richos_core::provider_auth::{self, AuthState, ProviderAuth};
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::time::{Duration, Instant};
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let dir = std::env::temp_dir().join(format!("richos auth fixture {}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("claude"), r#"#!/bin/sh
cd "$(dirname "$0")" || exit 1
if [ "$2" = status ]; then
  if [ -f connected ]; then printf '{"loggedIn":true,"email":"fixture@example.invalid","orgId":"fictional"}'
  else printf '{"loggedIn":false}'; fi
elif [ "$2" = login ]; then
  printf '%s\n' "$3" >> calls
  if [ -f hold ]; then sleep 60; else touch connected; fi
else exit 3; fi
"#).unwrap();
        std::fs::set_permissions(dir.join("claude"), std::fs::Permissions::from_mode(0o755)).unwrap();
        Self(dir)
    }
}
impl Drop for Fixture { fn drop(&mut self) { let _ = std::fs::remove_dir_all(&self.0); } }
#[test]
fn login_return_is_verified_without_retaining_account_details() {
    let f = Fixture::new(); let bin = f.0.join("claude"); let mut login = ProviderAuth::default();
    assert_eq!(login.refresh(&bin).state, AuthState::SignedOut);
    assert_eq!(login.start(&bin, false).state, AuthState::Connecting);
    let deadline = Instant::now() + Duration::from_secs(3);
    while login.poll(&bin).state == AuthState::Connecting {
        assert!(Instant::now() < deadline); std::thread::sleep(Duration::from_millis(10));
    }
    let view = login.refresh(&bin);
    assert_eq!(view.state, AuthState::Connected);
    let serialized = serde_json::to_string(&view).unwrap();
    assert!(!serialized.contains("fixture@example.invalid")); assert!(!serialized.contains("orgId"));
    assert_eq!(std::fs::read_to_string(f.0.join("calls")).unwrap().trim(), "--claudeai");
}
#[test]
fn cancel_then_retry_does_not_sign_out_or_start_duplicate_logins() {
    let f = Fixture::new(); let bin = f.0.join("claude"); let mut login = ProviderAuth::default();
    std::fs::write(f.0.join("hold"), "").unwrap();
    login.start(&bin, false); login.start(&bin, false);
    assert_eq!(login.cancel().state, AuthState::Cancelled);
    assert_eq!(provider_auth::status(&bin).state, AuthState::SignedOut);
    std::fs::remove_file(f.0.join("hold")).unwrap();
    assert_eq!(login.start(&bin, true).state, AuthState::Connecting);
    let deadline = Instant::now() + Duration::from_secs(3);
    while login.poll(&bin).state == AuthState::Connecting {
        assert!(Instant::now() < deadline); std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(login.refresh(&bin).state, AuthState::Connected);
    login.cancel();
    assert_eq!(provider_auth::status(&bin).state, AuthState::Connected);
}
