//! Provider-owned browser login. Credentials and account details never enter app state.
use crate::owned_process::OwnedChild;
use serde::Serialize;
use std::io::Read;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum AuthState { Connected, SignedOut, Connecting, Cancelled, Unavailable, Failed }

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
        };
        Self { state, message }
    }
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
    pub fn start(&mut self, bin: &Path, console: bool) -> AuthView {
        if self.login.is_some() { return self.view.clone(); }
        let mut command = Command::new(bin);
        command.args(["auth", "login", if console { "--console" } else { "--claudeai" }])
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
