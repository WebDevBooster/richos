//! **BUST A BUG** — the shell's half (CEO §115, round 21). Everything that decides what reaches
//! GitHub is `richos_core::bug_report` and is tested there; this file is the three things that
//! need the Mac: running Rich (`claude`) to write the report, reading the reporting account's
//! token from the login keychain, and the HTTPS request. Plus the eight commands the window
//! calls and the loop that sends a waiting report by itself.
//!
//! # Which account, today
//!
//! RichOS has no GitHub sign-in yet (§20 is not built), so [`KeychainCredentials`] answers the
//! RichOS reporting account, with the token at `KEYCHAIN_SERVICE` / `KEYCHAIN_ACCOUNT` in the
//! login keychain, read at send time. The user's own account slots in there, as
//! `Account::User`, when a sign-in exists; the window's From line and Rich's sentences already
//! read the account off the context and the delivery rather than assume it.
//!
//! # What is NOT here: a shipped token
//!
//! No token is in the source or the bundle. On a Mac where none has been put in the keychain the
//! report waits, saved, with Rich saying the reporting account is not set up on this Mac.

use richos_core::bug_report as bug;
use richos_core::read_view::SpineView;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager, State};

/// The event a report sent by itself arrives on: `{ delivery }`.
pub const EVENT: &str = "rich://bug-report";

/// How long Rich gets to write a report before the plain write-up is used instead.
const WRITE_DEADLINE: Duration = Duration::from_secs(90);
/// How often the loop looks for a waiting report whose rest is over.
const RETRY_EVERY: Duration = Duration::from_secs(15);
/// A keychain read on an unlocked keychain answers in milliseconds; this bounds a dialog nobody
/// answers (`phone/secrets.rs` measured that `security` can raise one).
const KEYCHAIN_DEADLINE: Duration = Duration::from_secs(20);

/// The app's one Bust a bug state.
pub struct BugReports {
    outbox: bug::Outbox,
    /// One attempt at a time, so the loop and *Try now* can never file one report twice.
    sending: Mutex<()>,
    /// While a report waits on the user's words, what they say goes to it (`holding_voice`).
    hold_voice: AtomicBool,
    /// Where `claude` writes from: an empty folder, so no project's CLAUDE.md is read.
    quiet_dir: PathBuf,
    version: String,
}

impl BugReports {
    pub fn for_app(data_dir: &Path, app_version: &str) -> Arc<Self> {
        let dir = data_dir.join("bug-reports");
        let quiet_dir = dir.join("writing");
        best_effort("the writing folder", std::fs::create_dir_all(&quiet_dir));
        Arc::new(BugReports {
            outbox: bug::Outbox::open(&dir),
            sending: Mutex::new(()),
            hold_voice: AtomicBool::new(false),
            quiet_dir,
            version: bug::version_line(app_version, macos_version().as_deref(), std::env::consts::ARCH),
        })
    }
}

/// Whether a spoken utterance belongs to a bug report rather than to Rich's conversation.
pub fn holding_voice(app: &AppHandle) -> bool {
    app.try_state::<Arc<BugReports>>().is_some_and(|b| b.hold_voice.load(Ordering::SeqCst))
}

/// A step whose failure changes nothing the user sees, written down rather than dropped.
fn best_effort<T, E: std::fmt::Display>(what: &str, result: Result<T, E>) {
    if let Err(e) = result {
        eprintln!("[richos] bug report: {what}: {e}");
    }
}

fn macos_version() -> Option<String> {
    let out = std::process::Command::new("/usr/bin/sw_vers").arg("-productVersion").output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
}

fn now_ms() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

// ---------------------------------------------------------------------------------------
// WHO IT GOES OUT AS
// ---------------------------------------------------------------------------------------

/// The RichOS reporting account's token, read from the login keychain at send time.
pub struct KeychainCredentials;

impl bug::Credentials for KeychainCredentials {
    fn credential(&self) -> Option<bug::Credential> {
        let token = read_keychain(bug::KEYCHAIN_SERVICE, bug::KEYCHAIN_ACCOUNT)?;
        Some(bug::Credential { account: bug::Account::Reporting, token })
    }
}

fn read_keychain(service: &str, account: &str) -> Option<String> {
    let mut child = std::process::Command::new("/usr/bin/security")
        .args(["find-generic-password", "-s", service, "-a", account, "-w"])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .ok()?;
    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                if !status.success() {
                    return None;
                }
                let mut out = String::new();
                child.stdout.take()?.read_to_string(&mut out).ok()?;
                let token = out.trim().to_string();
                return (!token.is_empty()).then_some(token);
            }
            Ok(None) if started.elapsed() < KEYCHAIN_DEADLINE => std::thread::sleep(Duration::from_millis(25)),
            _ => {
                best_effort("stopping it", child.kill());
                best_effort("reaping it", child.wait());
                eprintln!("[richos] bug report: the keychain did not answer; the report waits");
                return None;
            }
        }
    }
}

// ---------------------------------------------------------------------------------------
// THE REQUEST
// ---------------------------------------------------------------------------------------

/// `POST /repos/WebDevBooster/richos/issues`, to GitHub or to the stand-in named by
/// `RICHOS_BUG_REPORT_API`.
pub struct GitHub {
    base: String,
}

impl GitHub {
    pub fn from_env() -> Self {
        let base = std::env::var(bug::API_OVERRIDE_ENV).ok().filter(|v| !v.trim().is_empty()).unwrap_or_else(|| bug::API_BASE.to_string());
        GitHub { base: base.trim_end_matches('/').to_string() }
    }
}

impl bug::Transport for GitHub {
    fn create_issue(&self, credential: &bug::Credential, path: &str, request: &serde_json::Value) -> bug::Outcome {
        crate::voice_provision::ensure_crypto_provider();
        let url = format!("{}{}", self.base, path);
        let body = request.to_string();
        let token = credential.token.clone();
        tauri::async_runtime::block_on(async move {
            let client = match reqwest::Client::builder()
                .timeout(Duration::from_secs(25))
                .connect_timeout(Duration::from_secs(8))
                .redirect(reqwest::redirect::Policy::none())
                .build()
            {
                Ok(c) => c,
                Err(_) => return bug::Outcome::Unreachable,
            };
            let sent = client
                .post(&url)
                .header(reqwest::header::AUTHORIZATION, format!("Bearer {token}"))
                .header(reqwest::header::ACCEPT, "application/vnd.github+json")
                .header("X-GitHub-Api-Version", "2022-11-28")
                .header(reqwest::header::USER_AGENT, "RichOS")
                .header(reqwest::header::CONTENT_TYPE, "application/json")
                .body(body)
                .send()
                .await;
            let response = match sent {
                Ok(r) => r,
                Err(e) if e.is_timeout() => return bug::Outcome::TimedOut,
                Err(_) => return bug::Outcome::Unreachable,
            };
            let code = response.status().as_u16();
            if code != 201 {
                return bug::Outcome::Status { code };
            }
            let text = response.text().await.unwrap_or_default();
            let value: serde_json::Value = serde_json::from_str(&text).unwrap_or_default();
            match value["number"].as_u64() {
                Some(number) => bug::Outcome::Created { number, url: value["html_url"].as_str().map(str::to_string).unwrap_or_else(|| bug::issue_page(number)) },
                // A 201 with no issue number is not an issue we can point at: treat it as GitHub
                // not answering properly, so the report waits rather than claiming it was filed.
                None => bug::Outcome::Status { code: 502 },
            }
        })
    }
}

// ---------------------------------------------------------------------------------------
// RICH WRITES IT
// ---------------------------------------------------------------------------------------

/// One printed answer from `claude`, or why not. Bounded by [`WRITE_DEADLINE`]; the child is
/// killed when it outlasts it (CEO §54: whatever this app starts, it ends).
fn ask_rich(bin: &Path, folder: Option<&Path>, cwd: &Path, prompt: &str) -> Result<String, String> {
    let mut command = std::process::Command::new(bin);
    command
        .args(bug::writer_args())
        .env_remove("CLAUDECODE")
        .current_dir(cwd)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null());
    if let Some(folder) = folder {
        command.env("CLAUDE_CONFIG_DIR", folder);
    }
    let mut child = command.spawn().map_err(|e| format!("claude did not start: {e}"))?;
    if let Some(mut stdin) = child.stdin.take() {
        best_effort("the prompt", stdin.write_all(prompt.as_bytes()));
    }
    let mut stdout = child.stdout.take().ok_or("no output")?;
    let reader = std::thread::spawn(move || {
        let mut out = String::new();
        best_effort("its answer", stdout.read_to_string(&mut out));
        out
    });
    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if started.elapsed() < WRITE_DEADLINE => std::thread::sleep(Duration::from_millis(50)),
            _ => {
                best_effort("stopping it", child.kill());
                best_effort("reaping it", child.wait());
                return Err("claude took too long".into());
            }
        }
    }
    let out = reader.join().map_err(|_| "the reader stopped")?;
    bug::result_text(&out)
}

fn claude_for(state: &crate::AppState) -> (PathBuf, Option<PathBuf>) {
    let bin = state.claude_bin.lock().map(|b| b.clone()).unwrap_or_else(|_| richos_core::native::resolve_claude_bin());
    (bin, state.quota.lease_account().folder)
}

/// Everything RichOS holds that is private: the conversations' names (as he renamed them too),
/// the companies, the folders connected to them, and his own name.
fn private_terms(state: &crate::AppState) -> Vec<bug::PrivateTerm> {
    use bug::{Kind, PrivateTerm};
    let mut terms = Vec::new();
    let renamed = state.nav.lock().map(|n| n.state().renamed_threads.clone()).unwrap_or_default();
    for thread in state.reader.snapshot().threads() {
        terms.push(PrivateTerm::new(&thread.title, Kind::ConversationName));
        if let Some(name) = renamed.get(&thread.id) {
            terms.push(PrivateTerm::new(name, Kind::ConversationName));
        }
    }
    if let Ok(registry) = state.registry.lock() {
        for entity in registry.entities() {
            terms.push(PrivateTerm::new(&entity.display_name, Kind::CompanyName));
            for repo in &entity.connected_repositories {
                if let Some(name) = repo.file_name().and_then(|n| n.to_str()) {
                    terms.push(PrivateTerm::new(name, Kind::FolderName));
                }
            }
        }
    }
    if let Some(name) = state.config.lock().ok().and_then(|c| c.user_name().map(str::to_string)) {
        terms.push(PrivateTerm::new(&name, Kind::PersonName));
        for part in name.split_whitespace().filter(|p| p.chars().count() >= 3) {
            terms.push(PrivateTerm::new(part, Kind::PersonName));
        }
    }
    if let Some(user) = std::env::var_os("HOME").and_then(|h| PathBuf::from(h).file_name().map(|n| n.to_string_lossy().to_string())) {
        if user.chars().count() >= 3 {
            terms.push(PrivateTerm::new(&user, Kind::PersonName));
        }
    }
    terms.retain(|t| !t.text.is_empty() && t.text != "New thread");
    terms
}

fn digest(screen: &bug::Screen, by_rich: bool) -> String {
    let mut first = "Noted the screen you were on".to_string();
    if screen.text_size != 100 {
        first.push_str(&format!(", at {}% text size", screen.text_size));
    }
    let mut parts = vec![first, "Checked the version".to_string()];
    if !by_rich {
        parts.push("Wrote it from your words".into());
    }
    parts.join(" · ")
}

// ---------------------------------------------------------------------------------------
// THE COMMANDS
// ---------------------------------------------------------------------------------------

/// Who the report goes out as, and what RichOS holds that is private (for the card's heads-up
/// while the user changes the report).
#[tauri::command(async)]
pub fn bug_report_context(state: State<crate::AppState>) -> serde_json::Value {
    let scrubber = bug::Scrubber::new(private_terms(&state));
    serde_json::json!({
        "account": bug::Account::Reporting,
        "privateTerms": scrubber.terms(),
        "repository": bug::REPOSITORY,
    })
}

/// **Rich writes it up.** Sends nothing.
#[tauri::command(async)]
pub fn bug_report_write(state: State<crate::AppState>, bugs: State<Arc<BugReports>>, answer: String, screen: bug::Screen) -> serde_json::Value {
    let started = Instant::now();
    let terms = private_terms(&state);
    let scrubber = bug::Scrubber::new(terms.clone());
    let (bin, folder) = claude_for(&state);
    let prompt = bug::writer_prompt(&answer, &screen, &bugs.version, scrubber.terms());
    let (written, by_rich) = match ask_rich(&bin, folder.as_deref(), &bugs.quiet_dir, &prompt).and_then(|raw| bug::parse_written(&raw)) {
        Ok(w) => (w, true),
        Err(why) => {
            eprintln!("[richos] bug report: Rich's write-up was not used ({why}); the plain write-up is");
            (bug::plain_write_up(&answer, &screen), false)
        }
    };
    let draft = bug::draft_from(&written, &bugs.version, &scrubber);
    serde_json::json!({
        "draft": draft,
        "digest": digest(&screen, by_rich),
        "workedMs": started.elapsed().as_millis() as u64,
        "byRich": by_rich,
    })
}

/// **A change said to Rich**: the sentence to add and where it goes. Sends nothing.
#[tauri::command(async)]
pub fn bug_report_change(state: State<crate::AppState>, bugs: State<Arc<BugReports>>, said: String, sheet: bug::Sheet) -> serde_json::Value {
    let started = Instant::now();
    let scrubber = bug::Scrubber::new(private_terms(&state));
    let (bin, folder) = claude_for(&state);
    let headings: Vec<String> = sheet.sections.iter().map(|s| s.heading.clone()).collect();
    let (change, by_rich) = match ask_rich(&bin, folder.as_deref(), &bugs.quiet_dir, &bug::change_prompt(&sheet, &said))
        .and_then(|raw| bug::parse_change(&raw))
        .and_then(|c| if headings.contains(&c.section) { Ok(c) } else { Err(format!("no section {:?}", c.section)) })
    {
        Ok(c) => (c, true),
        Err(why) => {
            eprintln!("[richos] bug report: Rich's change was not used ({why}); the user's own words are");
            (bug::plain_change(&said), false)
        }
    };
    serde_json::json!({
        "section": change.section,
        "add": scrubber.scrub(&change.add),
        "workedMs": started.elapsed().as_millis() as u64,
        "byRich": by_rich,
    })
}

fn deliver(bugs: &BugReports, attempt: impl FnOnce(&bug::Outbox) -> std::io::Result<Option<bug::Delivery>>) -> Result<Option<bug::Delivery>, String> {
    let _one_at_a_time = bugs.sending.lock().map_err(|_| "the report store is unavailable".to_string())?;
    attempt(&bugs.outbox).map_err(|e| {
        eprintln!("[richos] bug report: the report could not be kept on this Mac ({e})");
        "I couldn't save the report on this Mac, so nothing was sent.".to_string()
    })
}

/// **SEND THE APPROVED SHEET.** Kept on this Mac first, then tried once.
#[tauri::command(async)]
pub fn bug_report_send(bugs: State<Arc<BugReports>>, sheet: bug::Sheet) -> Result<bug::Delivery, String> {
    let github = GitHub::from_env();
    deliver(&bugs, |o| o.send(&sheet, &KeychainCredentials, &github, now_ms()).map(Some))?.ok_or_else(|| "nothing was sent".into())
}

/// *Try now*. `None` when it is no longer waiting.
#[tauri::command(async)]
pub fn bug_report_try_now(bugs: State<Arc<BugReports>>, id: String) -> Result<Option<bug::Delivery>, String> {
    let github = GitHub::from_env();
    deliver(&bugs, |o| o.try_now(&id, &KeychainCredentials, &github, now_ms()))
}

/// *Cancel report*, and a waiting report that is being changed (a changed report is approved again).
#[tauri::command(async)]
pub fn bug_report_cancel(bugs: State<Arc<BugReports>>, id: String) -> Result<bool, String> {
    let _one_at_a_time = bugs.sending.lock().map_err(|_| "the report store is unavailable".to_string())?;
    bugs.outbox.cancel(&id).map_err(|e| e.to_string())
}

/// While a report waits on the user's words and voice is on, hold spoken words for it.
#[tauri::command(async)]
pub fn bug_report_voice(bugs: State<Arc<BugReports>>, on: bool) -> bool {
    bugs.hold_voice.store(on, Ordering::SeqCst);
    on
}

/// Open issue `number` of RichOS's repository in the browser. A number, never an address.
#[tauri::command(async)]
pub fn bug_report_open_issue(number: u64) -> Result<(), String> {
    let page = bug::issue_page(number);
    let status = std::process::Command::new("/usr/bin/open").arg(&page).status().map_err(|e| format!("this Mac would not open it: {e}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("This Mac wouldn't open the issue. It's at {}.", page.trim_start_matches("https://")))
    }
}

/// **SENT BY ITSELF.** Every [`RETRY_EVERY`], each waiting report whose rest is over is tried
/// once, and one that goes out is said on [`EVENT`] so the card, Rich and a notice say so.
/// Runs from launch, so a report kept before a quit goes out after the next launch.
pub fn spawn_retry(app: AppHandle) {
    std::thread::Builder::new()
        .name("bug-report-retry".into())
        .spawn(move || loop {
            std::thread::sleep(RETRY_EVERY);
            let Some(bugs) = app.try_state::<Arc<BugReports>>() else { continue };
            let bugs = bugs.inner().clone();
            let github = GitHub::from_env();
            let Ok(guard) = bugs.sending.lock() else { continue };
            let due = bugs.outbox.send_due(&KeychainCredentials, &github, now_ms());
            drop(guard);
            match due {
                Ok(deliveries) => {
                    for delivery in deliveries.into_iter().filter(|d| matches!(d, bug::Delivery::Sent(_))) {
                        if let Err(e) = app.emit(EVENT, serde_json::json!({ "delivery": delivery })) {
                            eprintln!("[richos] bug report: the window could not be told it went out: {e}");
                        }
                    }
                }
                Err(e) => eprintln!("[richos] bug report: the waiting reports could not be read ({e})"),
            }
        })
        .map(|_| ())
        .unwrap_or_else(|e| eprintln!("[richos] bug report: the retry loop did not start ({e}); a waiting report goes out on Try now"));
}

#[cfg(test)]
mod tests {
    use super::*;
    use bug::Transport;
    use std::io::{BufRead, BufReader};
    use std::net::TcpListener;

    /// A stand-in for GitHub's issues endpoint on this machine: answers one request with
    /// `status` and `body`, and hands back what it was sent (the request line, the headers and
    /// the body) so the test can read exactly what would have gone to GitHub.
    fn stand_in(status: &'static str, body: &'static str) -> (String, std::thread::JoinHandle<(String, Vec<String>, String)>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let handle = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let mut headers = Vec::new();
            let mut length = 0usize;
            loop {
                let mut h = String::new();
                reader.read_line(&mut h).unwrap();
                let h = h.trim_end().to_string();
                if h.is_empty() {
                    break;
                }
                if let Some(v) = h.to_ascii_lowercase().strip_prefix("content-length:") {
                    length = v.trim().parse().unwrap();
                }
                headers.push(h);
            }
            let mut buf = vec![0u8; length];
            reader.read_exact(&mut buf).unwrap();
            let reply = format!("HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
            stream.write_all(reply.as_bytes()).unwrap();
            (line.trim_end().to_string(), headers, String::from_utf8(buf).unwrap())
        });
        (base, handle)
    }

    fn credential() -> bug::Credential {
        bug::Credential { account: bug::Account::Reporting, token: "stand-in-token".into() }
    }

    #[test]
    fn the_request_is_one_post_to_the_issues_endpoint_with_the_token_and_the_sheet() {
        let (base, server) = stand_in("201 Created", r#"{"number": 412, "html_url": "https://github.com/WebDevBooster/richos/issues/412"}"#);
        let sheet = bug::Sheet {
            title: "Names are cut off".into(),
            sections: vec![bug::SheetSection { heading: "What happened".into(), paragraphs: vec!["It broke.".into()], steps: vec![] }],
        };
        let (path, request) = bug::issue_request(&sheet);
        let outcome = GitHub { base }.create_issue(&credential(), &path, &request);
        assert_eq!(outcome, bug::Outcome::Created { number: 412, url: "https://github.com/WebDevBooster/richos/issues/412".into() });
        let (line, headers, body) = server.join().unwrap();
        assert_eq!(line, "POST /repos/WebDevBooster/richos/issues HTTP/1.1");
        assert!(headers.iter().any(|h| h.eq_ignore_ascii_case("authorization: Bearer stand-in-token")), "{headers:?}");
        assert!(headers.iter().any(|h| h.eq_ignore_ascii_case("accept: application/vnd.github+json")), "{headers:?}");
        assert_eq!(serde_json::from_str::<serde_json::Value>(&body).unwrap(), request, "the body is the sheet's request, nothing added");
    }

    #[test]
    fn a_github_that_answers_503_is_a_status_and_a_closed_port_is_unreachable() {
        let (base, server) = stand_in("503 Service Unavailable", "{}");
        let outcome = GitHub { base }.create_issue(&credential(), "/repos/WebDevBooster/richos/issues", &serde_json::json!({"title": "t", "body": "b"}));
        assert_eq!(outcome, bug::Outcome::Status { code: 503 });
        server.join().unwrap();
        // A port nothing listens on: bind one, learn it, close it.
        let port = TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
        let outcome = GitHub { base: format!("http://127.0.0.1:{port}") }.create_issue(&credential(), "/x", &serde_json::json!({}));
        assert_eq!(outcome, bug::Outcome::Unreachable);
    }

    #[test]
    fn no_token_is_in_the_source() {
        // The reporting account's token is read from the keychain at send time, never shipped.
        let src = include_str!("bug_report.rs");
        for prefix in [concat!("gh", "p_"), concat!("github", "_pat_"), concat!("gh", "o_")] {
            assert!(!src.contains(prefix), "a GitHub token prefix is in the source: {prefix}");
        }
    }
}
