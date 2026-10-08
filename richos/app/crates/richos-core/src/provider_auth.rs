//! Provider-owned browser login. Credentials and account details never enter app state.
use crate::owned_process::OwnedChild;
use serde::Serialize;
use std::io::Read;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum AuthState { Connected, SignedOut, Connecting, Cancelled, Unavailable, Failed, SameAccount }

#[derive(Clone, Debug, Serialize)]
pub struct AuthView { pub state: AuthState, pub message: &'static str }
impl AuthView {
    fn new(state: AuthState) -> Self {
        let message = match state {
            AuthState::Connected => "Your Anthropic account is connected.",
            AuthState::SignedOut => "Connect your Anthropic account to start working with Rich.",
            AuthState::Connecting => "Complete sign-in in your browser, then return here.",
            AuthState::Cancelled => "Sign-in was canceled. You can try again when you are ready.",
            AuthState::Unavailable => "Install Claude Code first, then connect your account.",
            AuthState::Failed => "Account connection could not be verified. Check your connection and try again.",
            AuthState::SameAccount => "That is the Claude account this Mac already uses. Sign in with your other one.",
        };
        Self { state, message }
    }
    /// The answer for an added account's sign-in that came back as an account already in use.
    pub fn same_account() -> Self { Self::new(AuthState::SameAccount) }
}

/// Read only the boolean needed for readiness. Never retain provider output,
/// account identifiers, subscription details or diagnostic stderr.
pub fn status(bin: &Path) -> AuthView {
    status_in(bin, None)
}

/// [`status`] for one Claude Code configuration folder (fill-first: an added account). `None`
/// is Account 1, the folder the app's own environment names.
pub fn status_in(bin: &Path, folder: Option<&Path>) -> AuthView {
    let mut command = Command::new(bin);
    command.args(["auth", "status", "--json"]).env_remove("CLAUDECODE")
        .stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
    if let Some(folder) = folder { command.env("CLAUDE_CONFIG_DIR", folder); }
    OwnedChild::configure(&mut command);
    let Ok(mut raw) = command.spawn() else { return AuthView::new(AuthState::Unavailable); };
    let mut stdout = raw.stdout.take().unwrap();
    let mut child = OwnedChild::new(raw);
    let reader = std::thread::spawn(move || {
        let mut output = Vec::new();
        let result = stdout.by_ref().take(64 * 1024 + 1).read_to_end(&mut output);
        (result, output)
    });
    let deadline = Instant::now() + Duration::from_secs(15);
    let exit = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(20)),
            _ => { let _ = child.kill(); let _ = child.wait(); break None; }
        }
    };
    let Ok((Ok(_), output)) = reader.join() else { return AuthView::new(AuthState::Failed); };
    if exit.is_none() || output.len() > 64 * 1024 { return AuthView::new(AuthState::Failed); }
    let answer = serde_json::from_slice::<serde_json::Value>(&output).ok()
        .and_then(|value| value.get("loggedIn").and_then(serde_json::Value::as_bool));
    AuthView::new(match answer { Some(true) if exit.is_some_and(|s| s.success()) => AuthState::Connected, Some(false) => AuthState::SignedOut, _ => AuthState::Failed })
}

/// **Is the account signed in under `a` the same Claude account as the one under `b`?** Round
/// 18's likeliest mistake for someone who is not technical: adding a second account and signing
/// in with the first one again. `claude auth status --json` names the account it is signed in
/// as (`email`, `orgId`; the plan's key list, richos-hq
/// `docs/plans/2026-10-04-multi-subscription-fill-first.md`). Both are compared HERE and
/// dropped: nothing is returned but the answer, and nothing is kept, so RichOS still holds no
/// account identifier (this file's rule, and the CEO's answer 4: rows show the user's label
/// only). `None` when either folder does not say who it is, which is never treated as the same.
pub fn same_account(bin: &Path, a: Option<&Path>, b: Option<&Path>) -> Option<bool> {
    let who = |folder: Option<&Path>| -> Option<(String, String)> {
        let value = status_json(bin, folder)?;
        let email = value.get("email")?.as_str()?.trim().to_lowercase();
        if email.is_empty() { return None; }
        let org = value.get("orgId").and_then(serde_json::Value::as_str).unwrap_or("").to_string();
        Some((email, org))
    };
    Some(who(a)? == who(b)?)
}

/// `claude auth status --json` under `folder`, bounded like [`status_in`], read and parsed in
/// memory only. `None` for anything but a finished, successful, parseable answer.
fn status_json(bin: &Path, folder: Option<&Path>) -> Option<serde_json::Value> {
    let mut command = Command::new(bin);
    command.args(["auth", "status", "--json"]).env_remove("CLAUDECODE")
        .stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
    if let Some(folder) = folder { command.env("CLAUDE_CONFIG_DIR", folder); }
    OwnedChild::configure(&mut command);
    let mut raw = command.spawn().ok()?;
    let mut stdout = raw.stdout.take()?;
    let mut child = OwnedChild::new(raw);
    let reader = std::thread::spawn(move || {
        let mut output = Vec::new();
        let result = stdout.by_ref().take(64 * 1024 + 1).read_to_end(&mut output);
        (result, output)
    });
    let deadline = Instant::now() + Duration::from_secs(15);
    let exit = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(20)),
            _ => { drop(child.kill()); drop(child.wait()); break None; }
        }
    };
    let Ok((Ok(_), output)) = reader.join() else { return None };
    if !exit.is_some_and(|s| s.success()) || output.len() > 64 * 1024 { return None; }
    serde_json::from_slice(&output).ok()
}

/// **Sign an added account's folder out** (fill-first's Remove): the stock
/// `claude auth logout` under that folder, bounded like [`status_in`]. RichOS never touches the
/// credential itself; the binary removes its own. Best effort: the folder is deleted next.
pub fn logout_in(bin: &Path, folder: &Path) {
    let mut command = Command::new(bin);
    command.args(["auth", "logout"]).env_remove("CLAUDECODE").env("CLAUDE_CONFIG_DIR", folder)
        .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    OwnedChild::configure(&mut command);
    let Ok(raw) = command.spawn() else { return };
    let mut child = OwnedChild::new(raw);
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        match child.try_wait() {
            Ok(Some(_)) => return,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(20)),
            _ => { drop(child.kill()); drop(child.wait()); return; }
        }
    }
}

pub struct ProviderAuth {
    login: Option<(OwnedChild, Instant)>,
    view: AuthView,
    /// `None`: Account 1 (unchanged). `Some`: an added account's folder (fill-first).
    folder: Option<std::path::PathBuf>,
}
impl Default for ProviderAuth {
    fn default() -> Self { Self { login: None, view: AuthView::new(AuthState::SignedOut), folder: None } }
}
impl ProviderAuth {
    /// The same sign-in, for an added account's own Claude Code folder.
    pub fn for_folder(folder: std::path::PathBuf) -> Self {
        Self { folder: Some(folder), ..Self::default() }
    }
    pub fn refresh(&mut self, bin: &Path) -> AuthView {
        if self.login.is_some() { return self.poll(bin); }
        self.view = status_in(bin, self.folder.as_deref());
        self.view.clone()
    }
    pub fn start(&mut self, bin: &Path) -> AuthView {
        if self.login.is_some() { return self.view.clone(); }
        let mut command = Command::new(bin);
        command.args(["auth", "login", "--claudeai"])
            .env_remove("CLAUDECODE").stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
        if let Some(folder) = &self.folder { command.env("CLAUDE_CONFIG_DIR", folder); }
        OwnedChild::configure(&mut command);
        match command.spawn() {
            Ok(child) => {
                self.login = Some((OwnedChild::new(child), Instant::now() + Duration::from_secs(600)));
                self.view = AuthView::new(AuthState::Connecting);
            }
            Err(_) => self.view = AuthView::new(AuthState::Unavailable),
        }
        self.view.clone()
    }
    pub fn poll(&mut self, bin: &Path) -> AuthView {
        let Some((child, deadline)) = &mut self.login else { return self.view.clone(); };
        let finished = match child.try_wait() {
            Ok(Some(_)) | Err(_) => true,
            Ok(None) => Instant::now() >= *deadline,
        };
        if finished {
            self.login = None; // Retire owned login processes before checking credentials.
            self.view = status_in(bin, self.folder.as_deref());
            if self.view.state == AuthState::SignedOut { self.view = AuthView::new(AuthState::Failed); }
        }
        self.view.clone()
    }
    pub fn cancel(&mut self) -> AuthView {
        self.login = None; // Does not sign out or remove provider-owned credentials.
        self.view = AuthView::new(AuthState::Cancelled);
        self.view.clone()
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use crate::quota::tests::Scratch;

    /// **Round 18's "That is the account you already use"**, decided from what Claude Code says
    /// each folder is signed in as. A fixture binary answers `auth status --json` from a file in
    /// each folder (Account 1 has no folder of its own: the fixture's `one`).
    #[test]
    fn the_same_claude_account_signed_in_twice_is_recognized_and_nothing_about_it_is_kept() {
        use std::os::unix::fs::PermissionsExt;
        let root = Scratch::new();
        let bin = root.path().join("claude-fixture");
        std::fs::write(&bin, format!("#!/bin/sh\nf=\"${{CLAUDE_CONFIG_DIR:-{}}}/status.json\"\n[ -f \"$f\" ] && cat \"$f\"\nexit 0\n",
            root.path().join("one").display())).unwrap();
        std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o700)).unwrap();
        let (one, work) = (root.path().join("one"), root.path().join("work"));
        for dir in [&one, &work] { std::fs::create_dir_all(dir).unwrap(); }
        let status = |dir: &Path, json: &str| std::fs::write(dir.join("status.json"), json).unwrap();
        status(&one, r#"{"loggedIn":true,"email":"Pat@Example.com","orgId":"org-home"}"#);
        status(&work, r#"{"loggedIn":true,"email":"pat@example.com","orgId":"org-home"}"#);
        assert_eq!(same_account(&bin, None, Some(&work)), Some(true), "the same address and organization, case aside");
        status(&work, r#"{"loggedIn":true,"email":"pat@example.com","orgId":"org-work"}"#);
        assert_eq!(same_account(&bin, None, Some(&work)), Some(false), "one person, two subscriptions: two accounts");
        status(&work, r#"{"loggedIn":true,"email":"sam@example.com","orgId":"org-home"}"#);
        assert_eq!(same_account(&bin, None, Some(&work)), Some(false));
        status(&work, r#"{"loggedIn":true}"#);
        assert_eq!(same_account(&bin, None, Some(&work)), None, "a folder that does not say who it is is never called the same");
    }
}
