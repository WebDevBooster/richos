//! Anthropic's internal reset interface. Secrets stay in memory and curl's stdin,
//! never command arguments, persisted snapshots, logs or model-visible responses.
use super::resets::{Account, Transport};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    io::{Read, Write},
    path::Path,
    process::{Command, Stdio},
    time::Duration,
};

const MAX_BYTES: u64 = 262_144;
const READ: &str = "/api/oauth/usage?cedar_ember=1&skip_spend=1";

pub struct System {
    token: String,
    version: String,
    organization: String,
}
impl System {
    pub fn connect(bin: &Path) -> Result<Self, String> {
        if [
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_AUTH_TOKEN",
            "ANTHROPIC_BASE_URL",
            "CLAUDE_CODE_OAUTH_TOKEN",
            "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR",
            "CCR_OAUTH_TOKEN_FILE",
            "CLAUDE_CODE_CUSTOM_OAUTH_URL",
            "CLAUDE_CODE_USE_BEDROCK",
            "CLAUDE_CODE_USE_VERTEX",
            "CLAUDE_CODE_USE_FOUNDRY",
        ]
        .iter()
        .any(|key| std::env::var_os(key).is_some_and(|v| !v.is_empty()))
        {
            return Err("Reset offers need the saved Claude account connection, without authentication overrides.".into());
        }
        // Use the installed version, never a guessed newer client or a web identity.
        let bytes = bounded(Command::new(bin).arg("--version"), None)?;
        let text = String::from_utf8(bytes).map_err(|_| "Claude Code version unavailable.")?;
        let version = text.split_whitespace().next().unwrap_or("");
        if !text.contains("Claude Code")
            || version.len() > 32
            || version.split('.').count() != 3
            || !version.chars().all(|c| c.is_ascii_digit() || c == '.')
        {
            return Err("Reset offers require a supported Claude Code installation.".into());
        }
        let credentials = credentials()?;
        let token = credentials
            .pointer("/claudeAiOauth/accessToken")
            .and_then(Value::as_str)
            .filter(|s| {
                !s.is_empty()
                    && s.len() <= 8192
                    && s.bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.')
            })
            .ok_or("Connect your Claude account to check reset offers.")?
            .to_owned();
        Ok(Self {
            token,
            version: version.into(),
            organization: String::new(),
        })
    }
    fn request(&self, path: &str, body: Option<Value>) -> Result<Value, String> {
        // Paths and the host are internal constants or validated UUIDs. No redirects,
        // retries, proxy credentials or curl config inherited from the user's shell.
        let mut config = format!("url = \"https://api.anthropic.com{path}\"\nheader = \"Authorization: Bearer {}\"\nheader = \"anthropic-beta: oauth-2025-04-20\"\nheader = \"User-Agent: claude-cli/{} (external, cli)\"\nheader = \"Content-Type: application/json\"\n", self.token, self.version);
        if let Some(body) = body {
            let escaped = body.to_string().replace('\\', "\\\\").replace('"', "\\\"");
            config.push_str(&format!("request = \"POST\"\ndata = \"{escaped}\"\n"));
        }
        let mut command = Command::new("/usr/bin/curl");
        command.args([
            "-q",
            "--silent",
            "--fail",
            "--proto",
            "=https",
            "--max-time",
            "15",
            "--connect-timeout",
            "5",
            "--max-filesize",
            "262144",
            "--config",
            "-",
        ]);
        let bytes = bounded(&mut command, Some(config.into_bytes()))?;
        serde_json::from_slice(&bytes)
            .map_err(|_| "Anthropic returned an unreadable reset response.".into())
    }
}
impl Transport for System {
    fn account(&mut self) -> Result<Account, String> {
        let profile = self.request("/api/oauth/profile", None)?;
        let account = profile
            .pointer("/account/uuid")
            .and_then(Value::as_str)
            .ok_or("Claude account identity unavailable.")?;
        let org = profile
            .pointer("/organization/uuid")
            .and_then(Value::as_str)
            .ok_or("Claude organization unavailable.")?;
        if uuid::Uuid::parse_str(account).is_err() || uuid::Uuid::parse_str(org).is_err() {
            return Err("Claude account identity is unreadable.".into());
        }
        self.organization = org.into();
        Ok(Account {
            key: format!("{:x}", Sha256::digest(format!("{account}:{org}"))),
        })
    }
    fn usage(&mut self) -> Result<Value, String> {
        self.request(READ, None)
    }
    fn redeem(&mut self, grant: &str, request: &str) -> Result<Value, String> {
        if uuid::Uuid::parse_str(&self.organization).is_err()
            || !super::resets::valid_id(grant)
            || uuid::Uuid::parse_str(request).is_err()
        {
            return Err("Reset request identity unavailable.".into());
        }
        self.request(
            &format!("/api/organizations/{}/reset_rate_limits", self.organization),
            Some(json!({"program":"cedar_ember", "grant_id":grant, "request_id":request})),
        )
    }
}

fn credentials() -> Result<Value, String> {
    let config = std::env::var_os("CLAUDE_SECURESTORAGE_CONFIG_DIR")
        .or_else(|| std::env::var_os("CLAUDE_CONFIG_DIR"));
    #[cfg(target_os = "macos")]
    {
        // Claude Code normalizes custom configuration paths to NFC. Refuse non-ASCII
        // here rather than selecting a different keychain item for the same spelling.
        let suffix = match config.as_ref().filter(|c| !c.is_empty()) {
            Some(path) => {
                let path = path
                    .to_str()
                    .filter(|s| s.is_ascii())
                    .ok_or("Custom Claude credential path is unsupported.")?;
                format!(
                    "-{}",
                    &format!("{:x}", Sha256::digest(path.as_bytes()))[..8]
                )
            }
            None => String::new(),
        };
        let user = std::env::var("USER").map_err(|_| "Claude credential account unavailable.")?;
        let bytes = bounded(
            Command::new("/usr/bin/security").args([
                "find-generic-password",
                "-a",
                &user,
                "-w",
                "-s",
                &format!("Claude Code-credentials{suffix}"),
            ]),
            None,
        )?;
        serde_json::from_slice(&bytes).map_err(|_| "Claude credentials are unreadable.".into())
    }
    #[cfg(not(target_os = "macos"))]
    {
        let root = config
            .filter(|c| !c.is_empty())
            .map(std::path::PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|p| Path::new(&p).join(".claude")))
            .ok_or("Claude credential directory unavailable.")?;
        super::gate::read_json(&root.join(".credentials.json"))
            .map_err(|_| "Connect your Claude account to check reset offers.".into())
    }
}

/// Bound both output and wall time, including keychain prompts. Never include child
/// stderr or credentials in an error. The process group is reaped on every path.
fn bounded(command: &mut Command, input: Option<Vec<u8>>) -> Result<Vec<u8>, String> {
    use crate::owned_process::OwnedChild;
    command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    OwnedChild::configure(command);
    let mut raw = command
        .spawn()
        .map_err(|_| "Could not start the Claude account reader.")?;
    let mut stdin = raw.stdin.take().unwrap();
    let stdout = raw.stdout.take().unwrap();
    let mut child = OwnedChild::new(raw);
    let (tx, rx) = std::sync::mpsc::channel();
    let writer = std::thread::spawn(move || {
        if let Some(input) = input {
            let _best_effort = stdin.write_all(&input);
        }
    });
    let reader = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let result = stdout
            .take(MAX_BYTES + 1)
            .read_to_end(&mut bytes)
            .map(|_| bytes);
        let _best_effort = tx.send(result);
    });
    let received = rx.recv_timeout(Duration::from_secs(20));
    if received
        .as_ref()
        .ok()
        .and_then(|r| r.as_ref().ok())
        .is_none_or(|b| b.len() as u64 > MAX_BYTES)
    {
        let _best_effort = child.kill();
        let _best_effort = child.wait();
        let _best_effort = writer.join();
        let _best_effort = reader.join();
        return Err("Could not read reset offers. Try refreshing later.".into());
    }
    // EOF need not mean exit. Wait with a deadline rather than blocking on wait().
    let until = std::time::Instant::now() + Duration::from_secs(2);
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) if std::time::Instant::now() < until => {
                std::thread::sleep(Duration::from_millis(10))
            }
            _ => break None,
        }
    };
    let _best_effort = child.kill();
    let _best_effort = child.wait();
    let _best_effort = writer.join();
    let _best_effort = reader.join();
    if !status.is_some_and(|s| s.success()) {
        return Err(
            "Claude reset service unavailable. Check your account connection or try later.".into(),
        );
    }
    Ok(received.unwrap().unwrap())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn bounded_reader_keeps_stderr_private_and_rejects_failed_or_oversized_output() {
        assert_eq!(
            bounded(Command::new("/bin/sh").args(["-c", "printf ok"]), None).unwrap(),
            b"ok"
        );
        let error = bounded(
            Command::new("/bin/sh").args(["-c", "echo credential >&2; exit 1"]),
            None,
        )
        .unwrap_err();
        assert!(!error.contains("credential"));
        assert!(bounded(
            Command::new("/bin/sh").args(["-c", "dd if=/dev/zero bs=1024 count=257 2>/dev/null"]),
            None
        )
        .is_err());
    }
    #[test]
    fn invalid_installation_never_reads_credentials_or_contacts_anthropic() {
        assert!(System::connect(Path::new("/usr/bin/false")).is_err());
    }
}
