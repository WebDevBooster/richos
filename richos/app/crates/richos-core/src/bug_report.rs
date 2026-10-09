//! **BUST A BUG** — the core half. The CEO's §115 (2026-10-09), and the acceptance criterion:
//!
//! > *"When the user has Claude set up in the app (which is the expected default), we should just
//! > let the user say what's wrong and where and let their Rich check and articulate everything
//! > properly and then submit a GitHub issue on their behalf."* On whose account: *"when they have
//! > a GitHub account, the issue submission should happen from their GitHub account. And if they
//! > don't, then we can use a RichOS reporting account."*
//!
//! The design is round 21 (`richos-hq/design/mockups/rounds/round-21/`, approved "go!"). This
//! file is everything about it that is not a window or a socket, so all of it is tested here:
//!
//!   - **What is private, and its stand-ins** ([`Scrubber`]). The issue is public, so names RichOS
//!     holds (conversations, companies, people, folders), file paths and email addresses are
//!     replaced by plain stand-ins such as `[a conversation]`. Each stand-in keeps what it replaced
//!     in [`Segment::was`] for the tooltip only the user sees; `was` is never part of the issue.
//!     This is enforced HERE, after Rich writes, so a model that slips cannot put a name on GitHub.
//!   - **Rich's write-up** ([`writer_prompt`], [`writer_args`], [`parse_written`], [`draft_from`]).
//!     One `claude --print` turn with no tools, under the account the conversation runs on. When
//!     that cannot be had (no Claude, an error, an answer that is not a report), the plain
//!     write-up round 21 specifies ([`plain_write_up`]) is used instead and the digest says so.
//!   - **The issue, word for word** ([`Sheet`], [`issue_body`], [`issue_request`]). What goes to
//!     GitHub is rendered from the sheet the user approved and nothing else: no label, no footer,
//!     no attachment (round 21 "Left out, on purpose": no screenshot).
//!   - **Send, and keep what could not go** ([`Outbox`]). The report is written to this Mac BEFORE
//!     the request is made, so a failure, a quit or a crash leaves it here exactly as approved. A
//!     waiting report is tried again by itself ([`Outbox::send_due`]) and at once on *Try now*.
//!
//! # Which account
//!
//! [`Credentials`] answers "who is this filed as" at send time. The app has no GitHub sign-in yet
//! (§20 is not built), so the shell's implementation answers [`Account::Reporting`] with the token
//! read from the login keychain ([`KEYCHAIN_SERVICE`] / [`KEYCHAIN_ACCOUNT`]), or nothing when it
//! is not there. A signed-in user's own account slots in as [`Account::User`] in that one place;
//! the request, the outbox and the card already carry the account rather than assume it.
//!
//! # What this file does not do
//!
//! It opens no connection and starts no process. The shell (`src-tauri/src/bug_report.rs`) runs
//! `claude` and makes the HTTPS request through the [`Transport`] seam, so nothing here can reach
//! GitHub and the tests below the shell cannot either.

use serde::{Deserialize, Serialize};
use std::io;
use std::path::{Path, PathBuf};

/// Where every report is filed: `github.com/WebDevBooster/richos` (round 21 "Premises checked",
/// `git remote -v` in richos).
pub const REPOSITORY: &str = "WebDevBooster/richos";

/// The GitHub REST API. [`API_OVERRIDE_ENV`] points it at a local stand-in for the test VM walk.
pub const API_BASE: &str = "https://api.github.com";

/// `RICHOS_BUG_REPORT_API=http://127.0.0.1:<port>` sends to a stand-in instead of GitHub. It is
/// how the VM walk proves sending without a real issue; whoever can set this app's environment
/// can already read its keychain, so it opens nothing new.
pub const API_OVERRIDE_ENV: &str = "RICHOS_BUG_REPORT_API";

/// **WHERE THE RICHOS REPORTING ACCOUNT'S TOKEN IS KEPT**: a generic password in the login
/// keychain, service [`KEYCHAIN_SERVICE`], account [`KEYCHAIN_ACCOUNT`], the token as its value
/// (as typed, not encoded). It is read at send time and never written by the app.
///
/// One fixed name rather than the phone channel's per-install name (`phone/secrets.rs`
/// `service_for`), on purpose: the phone's keys are minted by the app, this token is put there by
/// a person, and one name is one command for him whichever folder he runs a nightly from. A test
/// launch under a scratch `HOME` has no login keychain of his to read (that is what the phone
/// channel's defect 4 established), so it cannot pick his token up.
pub const KEYCHAIN_SERVICE: &str = "com.richos.app.bug-reports";
/// See [`KEYCHAIN_SERVICE`].
pub const KEYCHAIN_ACCOUNT: &str = "github-reporting-token";

// ---------------------------------------------------------------------------------------
// WHAT IS PRIVATE
// ---------------------------------------------------------------------------------------

/// The kinds of private detail round 21 leaves out, each with its stand-in.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    ConversationName,
    CompanyName,
    PersonName,
    FolderName,
    FilePath,
    EmailAddress,
    /// Anything else Rich names as private (a product, a client's project).
    PrivateWord,
}

impl Kind {
    /// The words that go on GitHub in its place.
    pub fn stand_in(self) -> &'static str {
        match self {
            Kind::ConversationName => "[a conversation]",
            Kind::CompanyName => "[a company]",
            Kind::PersonName => "[a person]",
            Kind::FolderName => "[a folder]",
            Kind::FilePath => "[a file on this Mac]",
            Kind::EmailAddress => "[an email address]",
            Kind::PrivateWord => "[a private word]",
        }
    }
    /// One of it, in a sentence: "a conversation name".
    pub fn singular(self) -> &'static str {
        match self {
            Kind::ConversationName => "conversation name",
            Kind::CompanyName => "company name",
            Kind::PersonName => "person's name",
            Kind::FolderName => "folder name",
            Kind::FilePath => "file path",
            Kind::EmailAddress => "email address",
            Kind::PrivateWord => "private word",
        }
    }
    /// More than one: "conversation names".
    pub fn plural(self) -> &'static str {
        match self {
            Kind::ConversationName => "conversation names",
            Kind::CompanyName => "company names",
            Kind::PersonName => "people's names",
            Kind::FolderName => "folder names",
            Kind::FilePath => "file paths",
            Kind::EmailAddress => "email addresses",
            Kind::PrivateWord => "private words",
        }
    }
    /// The word Rich uses for a kind in his answer's `private` list.
    fn from_rich(word: &str) -> Kind {
        match word.trim().to_ascii_lowercase().as_str() {
            "person" | "people" | "name" => Kind::PersonName,
            "company" | "business" | "organization" => Kind::CompanyName,
            "conversation" | "thread" => Kind::ConversationName,
            "folder" | "repository" => Kind::FolderName,
            "file" | "path" => Kind::FilePath,
            "email" => Kind::EmailAddress,
            _ => Kind::PrivateWord,
        }
    }
}

/// One thing RichOS knows is private, and what kind it is.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PrivateTerm {
    pub text: String,
    pub kind: Kind,
}

impl PrivateTerm {
    pub fn new(text: &str, kind: Kind) -> Self {
        PrivateTerm { text: text.trim().to_string(), kind }
    }
}

/// A run of report text: plain words, or a stand-in with what it replaced.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Segment {
    pub text: String,
    /// What the stand-in replaced. Shown to the user on the card; never part of the issue.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub was: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub kind: Option<Kind>,
}

impl Segment {
    fn plain(text: &str) -> Self {
        Segment { text: text.to_string(), was: None, kind: None }
    }
    fn stand_in(was: &str, kind: Kind) -> Self {
        Segment { text: kind.stand_in().to_string(), was: Some(was.to_string()), kind: Some(kind) }
    }
}

/// Replaces what is private with stand-ins.
///
/// THE MATCHING RULES, each one a trade stated rather than a default inherited:
///
///   - A name of **two or more words** is matched in any letter case ("acme deal").
///   - A **one-word conversation name** is not matched at all (round 21 `privateTerms` does the
///     same): "Running" is a conversation in the demo and an ordinary word everywhere else.
///   - Any other **one-word name written Capitalized** ("Acme", "Deeply") is matched only where it
///     is written with a capital, so "deeply" in a sentence is left alone. One written in lower case
///     ("femcboost", a folder) is matched in any case, because it is not an ordinary word.
///   - Every match is a whole word: "Acmes" and "subAcme" are not "Acme".
///   - **File paths** start a word with `/` and hold at least two slashes (`/Users/alex`), or start
///     with `~/`; "and/or" and "24/7" are not paths. Each is left out WHOLE, spaces included,
///     between backticks, quotes or brackets and written plainly alike ([`find_paths`]).
///     **Email addresses** are `local@host.tld`.
#[derive(Debug, Clone, Default)]
pub struct Scrubber {
    terms: Vec<PrivateTerm>,
}

impl Scrubber {
    pub fn new(terms: Vec<PrivateTerm>) -> Self {
        let mut kept: Vec<PrivateTerm> = Vec::new();
        for term in terms {
            let one_word = !term.text.contains(char::is_whitespace);
            if term.text.chars().count() < 2 || (one_word && term.kind == Kind::ConversationName) {
                continue;
            }
            if !kept.iter().any(|k| k.text.eq_ignore_ascii_case(&term.text)) {
                kept.push(term);
            }
        }
        // Longest first, so "Acme deal" wins over "Acme" where both match.
        kept.sort_by_key(|t| std::cmp::Reverse(t.text.len()));
        Scrubber { terms: kept }
    }

    /// The terms in force, after the rules above dropped what they drop.
    pub fn terms(&self) -> &[PrivateTerm] {
        &self.terms
    }

    /// Every private span in `text`, as (start, end, kind), non-overlapping and in order.
    fn spans(&self, text: &str) -> Vec<(usize, usize, Kind)> {
        let mut found: Vec<(usize, usize, Kind)> = Vec::new();
        for term in &self.terms {
            for (start, end) in find_term(text, &term.text) {
                found.push((start, end, term.kind));
            }
        }
        found.extend(find_paths(text).into_iter().map(|(s, e)| (s, e, Kind::FilePath)));
        found.extend(find_emails(text).into_iter().map(|(s, e)| (s, e, Kind::EmailAddress)));
        // Earliest first; at the same start, the longest.
        found.sort_by_key(|&(start, end, _)| (start, std::cmp::Reverse(end)));
        let mut out: Vec<(usize, usize, Kind)> = Vec::new();
        for span in found {
            if out.last().is_some_and(|last| span.0 < last.1) {
                continue;
            }
            out.push(span);
        }
        out
    }

    /// `text` as segments, with every private span replaced by its stand-in.
    pub fn scrub(&self, text: &str) -> Vec<Segment> {
        let mut out: Vec<Segment> = Vec::new();
        let mut at = 0;
        for (start, end, kind) in self.spans(text) {
            if start > at {
                out.push(Segment::plain(&text[at..start]));
            }
            out.push(Segment::stand_in(&text[start..end], kind));
            at = end;
        }
        if at < text.len() || out.is_empty() {
            out.push(Segment::plain(&text[at..]));
        }
        out
    }

    /// The private words still in `text`, as written: the card's heads-up after the user changes
    /// the report (*"Acme" looks private*).
    pub fn private_in(&self, text: &str) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        for (start, end, _) in self.spans(text) {
            let word = text[start..end].to_string();
            if !out.contains(&word) {
                out.push(word);
            }
        }
        out
    }
}

fn is_word_char(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

fn char_before(text: &str, at: usize) -> Option<char> {
    text[..at].chars().next_back()
}

fn char_after(text: &str, at: usize) -> Option<char> {
    text[at..].chars().next()
}

/// Whole-word, letter-case-aware occurrences of `term` in `text` (see [`Scrubber`]'s rules).
fn find_term(text: &str, term: &str) -> Vec<(usize, usize)> {
    let one_word = !term.contains(char::is_whitespace);
    let capitalized = term.chars().next().is_some_and(char::is_uppercase);
    let needle = term.as_bytes();
    let hay = text.as_bytes();
    let mut out = Vec::new();
    if needle.is_empty() || needle.len() > hay.len() {
        return out;
    }
    let mut i = 0;
    while i + needle.len() <= hay.len() {
        if !text.is_char_boundary(i) || !text.is_char_boundary(i + needle.len()) {
            i += 1;
            continue;
        }
        let window = &hay[i..i + needle.len()];
        if window.eq_ignore_ascii_case(needle) {
            let end = i + needle.len();
            let bounded = !char_before(text, i).is_some_and(is_word_char) && !char_after(text, end).is_some_and(is_word_char);
            let case_ok = !(one_word && capitalized) || char_after(text, i).is_some_and(char::is_uppercase);
            if bounded && case_ok {
                out.push((i, end));
                i = end;
                continue;
            }
        }
        i += 1;
    }
    out
}

/// The marks a path is commonly written between, each with the mark that closes it: Markdown's
/// backticks, straight and curly quotes, and brackets.
const PATH_DELIMITERS: [(char, char); 9] =
    [('`', '`'), ('"', '"'), ('\'', '\''), ('“', '”'), ('‘', '’'), ('(', ')'), ('[', ']'), ('<', '>'), ('{', '}')];

/// Folders macOS itself names with a space in them. A plain path that reaches one of these takes
/// the whole name, so `~/Library/Application Support` is left out whole even where it ends.
const SPACED_FOLDERS: [&str; 6] =
    ["Application Support", "Application Scripts", "Mobile Documents", "Group Containers", "Saved Application State", "Address Book"];

/// Where a path that is not between delimiters stops being one word: at a space (unless it is
/// escaped, `Client\ Plans`) or at punctuation that closes a phrase.
fn path_word_end(text: &str, from: usize) -> usize {
    let mut escaped = false;
    for (i, c) in text[from..].char_indices() {
        if c.is_whitespace() && !escaped || ",;)\"'”’]>`}".contains(c) {
            return from + i;
        }
        escaped = c == '\\';
    }
    text.len()
}

/// A folder macOS names with a space, starting at the path's last segment: where it ends.
fn spaced_folder_end(text: &str, start: usize, end: usize) -> Option<usize> {
    let path = &text[start..end];
    SPACED_FOLDERS.iter().find_map(|name| {
        let first = name.split(' ').next().unwrap_or(name);
        let from = end - first.len();
        let fits = path.ends_with(&format!("/{first}")) && text[from..].starts_with(name);
        let after = from + name.len();
        (fits && !char_after(text, after).is_some_and(is_word_char)).then_some(after)
    })
}

/// **A path with spaces in it, written plainly** (`/Users/alex/Client Plans/budget.xlsx`): when
/// one of the next three words carries on with a `/` (and none before it ends a phrase), the path
/// goes on through it. A path whose last segment already names a file (`notes.txt`) stops there.
fn path_goes_on(text: &str, start: usize, end: usize) -> Option<usize> {
    let last = text[start..end].rsplit('/').next().unwrap_or("");
    if last.contains('.') || last.is_empty() {
        return None;
    }
    let mut at = end;
    for _ in 0..3 {
        // One space between the words of a name; anything else ends the path.
        if !text[at..].starts_with(' ') || text[at + 1..].starts_with(char::is_whitespace) {
            return None;
        }
        at += 1;
        let word_end = at + text[at..].find(char::is_whitespace).unwrap_or(text.len() - at);
        let word = &text[at..word_end];
        if let Some(slash) = word.find('/') {
            let before_slash = &word[..slash];
            let plain = !before_slash.is_empty() && !before_slash.contains(|c: char| ",;:.!?\"'`()[]<>{}“”‘’".contains(c));
            return plain.then(|| path_word_end(text, at));
        }
        if word.is_empty() || word.ends_with(|c: char| ",;:.!?\"'`)]>}”’".contains(c)) {
            return None;
        }
        at = word_end;
    }
    None
}

/// **File paths**, complete: a path starts a word with `~/`, or with `/` and holds two slashes.
///
///   - **Between delimiters** (`` `…` ``, quotes, brackets) it runs to the closing mark on the
///     same line, spaces and all: `"~/Documents/Secret Co/plan.pdf"`.
///   - **Written plainly** it runs to the end of the word, through escaped spaces, through a
///     folder macOS names with a space, and through later words that carry on with a `/`
///     ([`path_goes_on`]). Sentence punctuation at its end stays outside.
///
/// "and/or" and "24/7" are not paths (no leading `/`).
fn find_paths(text: &str) -> Vec<(usize, usize)> {
    let mut out = Vec::new();
    let mut skip_to = 0;
    for (i, _) in text.char_indices() {
        if i < skip_to {
            continue;
        }
        let rest = &text[i..];
        let opens = rest.starts_with("~/") || (rest.starts_with('/') && rest[1..].starts_with(|c: char| c.is_alphanumeric() || c == '.' || c == '_'));
        if !opens {
            continue;
        }
        let before = char_before(text, i);
        let delimiter = before.and_then(|b| PATH_DELIMITERS.iter().find(|(open, _)| *open == b).map(|&(_, close)| close));
        if before.is_some_and(|c| !c.is_whitespace() && delimiter.is_none()) {
            continue;
        }
        let line = &rest[..rest.find('\n').unwrap_or(rest.len())];
        let end = match delimiter.and_then(|close| line.find(close)) {
            Some(close_at) => i + close_at,
            None => {
                let mut end = path_word_end(text, i);
                loop {
                    if let Some(after) = spaced_folder_end(text, i, end) {
                        end = if text[after..].starts_with('/') { path_word_end(text, after) } else { after };
                        continue;
                    }
                    match path_goes_on(text, i, end) {
                        Some(further) => end = further,
                        None => break,
                    }
                }
                while end > i && text[..end].ends_with(['.', ':', '!', '?']) {
                    end -= 1;
                }
                end
            }
        };
        let candidate = &text[i..end];
        if candidate.starts_with("~/") && candidate.len() > 2 || candidate.matches('/').count() >= 2 {
            out.push((i, end));
            skip_to = end;
        }
    }
    out
}

/// Email addresses: `local@host.tld`. Every offset is a character boundary: the address may
/// follow an emoji or an accented letter.
fn find_emails(text: &str) -> Vec<(usize, usize)> {
    let mut out = Vec::new();
    let local = |c: char| c.is_alphanumeric() || "._%+-".contains(c);
    let host = |c: char| c.is_alphanumeric() || ".-".contains(c);
    for (at, _) in text.match_indices('@') {
        let start = text[..at].char_indices().rev().find(|&(_, c)| !local(c)).map(|(p, c)| p + c.len_utf8()).unwrap_or(0);
        let mut end = at + 1 + text[at + 1..].find(|c: char| !host(c)).unwrap_or(text.len() - at - 1);
        while end > at + 1 && text[..end].ends_with(['.', '-']) {
            end -= 1;
        }
        let domain = &text[at + 1..end];
        let dotted = domain.rfind('.').is_some_and(|d| d > 0 && d + 1 < domain.len());
        if start < at && dotted && out.last().is_none_or(|&(_, e)| start >= e) {
            out.push((start, end));
        }
    }
    out
}

/// The line under the sheet (round 21): what was left out, counted by kind, in the order first
/// met. One stand-in may stand for several names ("Acme deal and Partner book review") when Rich
/// wrote them together; each counts.
pub fn left_out_line(segments: &[Segment]) -> String {
    let mut order: Vec<Kind> = Vec::new();
    let mut counts: std::collections::HashMap<Kind, usize> = std::collections::HashMap::new();
    for segment in segments {
        let Some(kind) = segment.kind else { continue };
        if !counts.contains_key(&kind) {
            order.push(kind);
        }
        *counts.entry(kind).or_default() += 1;
    }
    if order.is_empty() {
        return "Nothing private was in it, so nothing was left out. Anyone can read GitHub issues.".into();
    }
    let parts: Vec<String> = order
        .iter()
        .map(|kind| {
            let n = counts[kind];
            format!("{} {}", number_word(n), if n == 1 { kind.singular() } else { kind.plural() })
        })
        .collect();
    let list = match parts.len() {
        1 => parts[0].clone(),
        _ => format!("{} and {}", parts[..parts.len() - 1].join(", "), parts[parts.len() - 1]),
    };
    let total: usize = counts.values().sum();
    let pronoun = if total == 1 { "it" } else { "them" };
    format!(
        "Left out, because anyone can read GitHub issues: {list}. The underlined words stand in for {pronoun}; point at one to see what it replaced."
    )
}

fn number_word(n: usize) -> String {
    const WORDS: [&str; 10] = ["no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"];
    WORDS.get(n).map(|w| w.to_string()).unwrap_or_else(|| n.to_string())
}

// ---------------------------------------------------------------------------------------
// WHERE THE USER WAS
// ---------------------------------------------------------------------------------------

/// The screen the user was on when they pressed Bust a bug, as the UI read it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Screen {
    /// `conversation`, `corrections`, `feedback`, `search`, `picker`, `unbound`, `company`,
    /// `home`, `output` or `other`.
    pub key: String,
    /// In the user's own terms, private names included: "the Acme deal conversation".
    pub here: String,
    /// The same place described for the public report, with no names: "a conversation, the
    /// main RichOS screen".
    pub public: String,
    /// The conversation on screen, when there is one.
    #[serde(default)]
    pub conversation: Option<String>,
    /// Text size, in percent (Settings → Text size).
    #[serde(default = "hundred")]
    pub text_size: u32,
    /// `light` or `dark`, as painted.
    #[serde(default)]
    pub theme: String,
    #[serde(default)]
    pub technical_view: bool,
}

fn hundred() -> u32 {
    100
}

/// "RichOS 1.2.0, nightly 45 · macOS 15.6 · Apple silicon", from the bundle's own version.
pub fn version_line(app_version: &str, macos: Option<&str>, arch: &str) -> String {
    let (base, pre) = app_version.split_once('-').unwrap_or((app_version, ""));
    let mut parts = vec![if let Some(rest) = pre.strip_prefix("nightly.") {
        match rest.rsplit_once('.') {
            Some((_, n)) => format!("RichOS {base}, nightly {n}"),
            None => format!("RichOS {base}, nightly {rest}"),
        }
    } else if let Some(sha) = pre.strip_prefix("dev.") {
        format!("RichOS {base}, development build {sha}")
    } else if pre.is_empty() {
        format!("RichOS {base}")
    } else {
        format!("RichOS {app_version}")
    }];
    if let Some(v) = macos.map(str::trim).filter(|v| !v.is_empty()) {
        parts.push(format!("macOS {v}"));
    }
    parts.push(match arch {
        "aarch64" => "Apple silicon".to_string(),
        "x86_64" => "Intel".to_string(),
        other => other.to_string(),
    });
    parts.join(" · ")
}

// ---------------------------------------------------------------------------------------
// RICH'S WRITE-UP
// ---------------------------------------------------------------------------------------

/// What Rich wrote, before anything private is replaced.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Written {
    pub title: String,
    pub what_happened: String,
    pub where_: String,
    pub steps: Vec<String>,
    pub expected: String,
    /// Further private words Rich found in what he wrote, beyond the ones RichOS holds.
    pub private: Vec<PrivateTerm>,
}

/// The arguments `claude` is run with to write the report: one printed answer, no tools, none
/// of the operator's settings, no session left on disk, no MCP servers. The account comes from
/// `CLAUDE_CONFIG_DIR`, which the shell sets to the account the conversation runs on, and the
/// prompt arrives on standard input. No `--model`: Rich writes with the same model he talks with.
pub fn writer_args() -> Vec<String> {
    [
        "--print",
        "--output-format",
        "json",
        "--setting-sources",
        "",
        "--no-session-persistence",
        "--tools",
        "",
        "--strict-mcp-config",
        "--mcp-config",
        "{\"mcpServers\":{}}",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect()
}

fn terms_line(terms: &[PrivateTerm]) -> String {
    let mut words: Vec<&str> = terms.iter().map(|t| t.text.as_str()).collect();
    words.sort_unstable();
    words.dedup();
    if words.is_empty() {
        "none".into()
    } else {
        words.join("; ")
    }
}

fn screen_lines(screen: &Screen, version: &str) -> String {
    let mut lines = vec![
        format!("- The screen: {}", screen.here),
        format!("- The same place described with no names, for the public report: {}", screen.public),
        format!("- Text size: {}%", screen.text_size),
    ];
    if !screen.theme.is_empty() {
        lines.push(format!("- Theme: {}", screen.theme));
    }
    lines.push(format!("- Technical view: {}", if screen.technical_view { "on" } else { "off" }));
    lines.push(format!("- Version: {version}"));
    lines.join("\n")
}

/// The one prompt Rich writes the report from.
pub fn writer_prompt(answer: &str, screen: &Screen, version: &str, terms: &[PrivateTerm]) -> String {
    format!(
        "You are Rich, the user's assistant inside the RichOS desktop app. The user pressed \"Bust a bug\" \
and told you what went wrong. Write it up as a bug report for the RichOS developers. After the user reads \
and approves it, it is filed as a GitHub issue that anyone can read.\n\n\
What the user said, in their own words:\n<<<\n{answer}\n>>>\n\n\
Where they were when they pressed the button:\n{screen}\n\n\
Private words this user has: {terms}. Leave names out where you can; any that remain are replaced with \
plain stand-ins such as [a conversation] before the user sees the report.\n\n\
Write in plain American English that a non-technical reader follows. Say what the user saw and did, not \
guesses about the code. Give steps to see it only as far as the user's words and the screen support them.\n\n\
Answer with ONLY a JSON object, no other text, in exactly this shape:\n\
{{\"title\": \"...\", \"what_happened\": \"...\", \"where\": \"...\", \"steps\": [\"...\"], \"expected\": \"...\", \
\"private\": [{{\"text\": \"...\", \"kind\": \"person\"}}]}}\n\
- title: one line under 80 characters that says what is wrong.\n\
- what_happened: one or two short paragraphs; a blank line between paragraphs.\n\
- where: the place in RichOS, in words a reader of the public issue understands.\n\
- steps: the shortest steps to see it, or [] when the user's words do not support any.\n\
- expected: what the user expected instead, or \"\" when it is not clear.\n\
- private: every name of a person, company, conversation, product, client or folder, and anything else \
private, that is still in what you wrote, copied exactly, with kind one of person, company, conversation, \
folder, file, email, other. [] when there is none.",
        answer = answer.trim(),
        screen = screen_lines(screen, version),
        terms = terms_line(terms),
    )
}

/// The prompt for a change the user TELLS Rich (round 21: *"also say it happens in the light
/// theme too"*): he answers with the sentence to add and where it goes.
pub fn change_prompt(sheet: &Sheet, said: &str) -> String {
    let headings: Vec<&str> = sheet.sections.iter().map(|s| s.heading.as_str()).collect();
    format!(
        "You are Rich, inside the RichOS desktop app. You wrote this bug report and the user has not sent it \
yet. It is public once sent; words in square brackets stand in for private details and stay as they are.\n\n\
The report:\n<<<\n# {title}\n\n{body}>>>\n\n\
The user just told you what to change:\n<<<\n{said}\n>>>\n\n\
Answer with ONLY a JSON object, no other text: {{\"section\": \"...\", \"add\": \"...\", \"private\": []}}\n\
- section: the heading the change belongs under, exactly one of: {headings}.\n\
- add: the sentence or two to add there, in plain American English, written about \"the user\" the way \
the report is.\n\
- private: every name of a person, company, conversation, product, client or folder, and anything else \
private, that is in what you add, copied exactly, each as {{\"text\": \"...\", \"kind\": \"person\"}} with kind \
one of person, company, conversation, folder, file, email, other. [] when there is none.",
        title = sheet.title,
        body = issue_body(sheet),
        said = said.trim(),
        headings = headings.join(", "),
    )
}

/// The `result` text out of `claude --print --output-format json`'s one JSON object. An error
/// reply (not signed in, out of quota) is refused rather than read as a report.
pub fn result_text(stdout: &str) -> Result<String, String> {
    let value: serde_json::Value = serde_json::from_str(stdout.trim()).map_err(|e| format!("not a reply: {e}"))?;
    if value["is_error"].as_bool() == Some(true) {
        return Err(format!("Claude answered with an error: {}", value["result"].as_str().unwrap_or("")));
    }
    value["result"].as_str().map(str::to_string).ok_or_else(|| "the reply had no result".to_string())
}

/// The first `{` to the last `}`: a model asked for only JSON sometimes fences it or says a word
/// first, and neither changes what it wrote.
fn json_object(raw: &str) -> Result<serde_json::Value, String> {
    let start = raw.find('{').ok_or("no JSON object in the answer")?;
    let end = raw.rfind('}').ok_or("no JSON object in the answer")?;
    if end < start {
        return Err("no JSON object in the answer".into());
    }
    serde_json::from_str(&raw[start..=end]).map_err(|e| format!("the answer's JSON did not read: {e}"))
}

fn text_of(value: &serde_json::Value, key: &str) -> String {
    value[key].as_str().unwrap_or("").trim().to_string()
}

/// The `private` list of Rich's answer, each in the kind he named.
fn private_of(value: &serde_json::Value) -> Vec<PrivateTerm> {
    value["private"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|p| {
                    let text = p["text"].as_str()?.trim();
                    (!text.is_empty()).then(|| PrivateTerm::new(text, Kind::from_rich(p["kind"].as_str().unwrap_or(""))))
                })
                .collect()
        })
        .unwrap_or_default()
}

/// `terms` without repeats (the same words in any letter case are one term; the first kind wins).
fn distinct(terms: impl IntoIterator<Item = PrivateTerm>) -> Vec<PrivateTerm> {
    let mut out: Vec<PrivateTerm> = Vec::new();
    for term in terms {
        if !term.text.is_empty() && !out.iter().any(|t| t.text.eq_ignore_ascii_case(&term.text)) {
            out.push(term);
        }
    }
    out
}

/// Rich's answer, read. A report needs a title and something that happened; anything less is
/// refused so the plain write-up is used instead of a hollow one.
pub fn parse_written(raw: &str) -> Result<Written, String> {
    let value = json_object(raw)?;
    let written = Written {
        title: text_of(&value, "title"),
        what_happened: text_of(&value, "what_happened"),
        where_: text_of(&value, "where"),
        steps: value["steps"]
            .as_array()
            .map(|a| a.iter().filter_map(|s| s.as_str()).map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect())
            .unwrap_or_default(),
        expected: text_of(&value, "expected"),
        private: private_of(&value),
    };
    if written.title.is_empty() || written.what_happened.is_empty() {
        return Err("the answer had no title or no account of what happened".into());
    }
    Ok(written)
}

fn capitalized(text: &str) -> String {
    let text = text.trim();
    let mut chars = text.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
        None => String::new(),
    }
}

fn as_sentence(text: &str) -> String {
    let text = capitalized(text);
    if text.ends_with(['.', '!', '?', '…']) {
        text
    } else {
        text + "."
    }
}

/// THE PLAIN WRITE-UP (round 21 `reportFor`'s last branch), for when Rich cannot be asked: the
/// first sentence as the title, the answer as What happened, the screen as Where.
pub fn plain_write_up(answer: &str, screen: &Screen) -> Written {
    let answer = answer.trim();
    let mut first = answer;
    for (i, c) in answer.char_indices() {
        if ".!?".contains(c) && answer[i + 1..].starts_with(char::is_whitespace) {
            first = &answer[..i];
            break;
        }
    }
    let first = first.trim_end_matches(['.', '!', '?']);
    let title = if first.chars().count() > 76 {
        let cut: String = first.chars().take(76).collect();
        // A cut that lands between two words keeps the last whole word; one that lands inside a
        // word drops that word rather than half of it.
        let on_boundary = first.chars().nth(76).is_some_and(char::is_whitespace);
        match cut.rfind(char::is_whitespace) {
            Some(space) if !on_boundary => cut[..space].to_string(),
            _ => cut,
        }
    } else {
        first.to_string()
    };
    Written {
        title: capitalized(&title),
        what_happened: as_sentence(answer),
        where_: format!("{}. It was on screen when the report was started.", capitalized(&screen.public)),
        steps: vec![],
        expected: String::new(),
        private: vec![],
    }
}

/// A change said to Rich: the heading it goes under, the words to add, and any private words
/// Rich names in them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Change {
    pub section: String,
    pub add: String,
    pub private: Vec<PrivateTerm>,
}

pub fn parse_change(raw: &str) -> Result<Change, String> {
    let value = json_object(raw)?;
    let change = Change { section: text_of(&value, "section"), add: text_of(&value, "add"), private: private_of(&value) };
    if change.section.is_empty() || change.add.is_empty() {
        return Err("the answer had no section or nothing to add".into());
    }
    Ok(change)
}

/// Without Rich: the user's own words, tidied the way round 21 tidies them ("Also say it
/// happens…" becomes "It happens…"), added to What happened.
pub fn plain_change(said: &str) -> Change {
    // `get` rather than an index: the first bytes of "ééé" are not a whole character, and a
    // prefix that is not one is simply not the lead.
    let leads = |text: &str, lead: &str| text.len() > lead.len() && text.get(..lead.len()).is_some_and(|p| p.eq_ignore_ascii_case(lead));
    let mut text = said.trim();
    for lead in ["also ", "and ", "please "] {
        if leads(text, lead) {
            text = text[lead.len()..].trim_start();
        }
    }
    for lead in ["say that ", "mention that ", "add that ", "say ", "mention ", "add "] {
        if leads(text, lead) {
            text = text[lead.len()..].trim_start();
            break;
        }
    }
    Change { section: "What happened".into(), add: as_sentence(text), private: vec![] }
}

/// **A CHANGE, SCRUBBED WITH EVERYTHING THE REPORT KNOWS IS PRIVATE**: the names RichOS holds
/// (`app`), the ones Rich found while writing the report and every change before this one
/// (`report`), and any he names in this change. Returns the words to add and the report's
/// private words from now on, so a name Rich found once stays left out on every later change
/// (second review finding 4: on 1c3dda1dc his names applied to the first draft only).
pub fn scrub_change(change: &Change, app: &[PrivateTerm], report: &[PrivateTerm]) -> (Vec<Segment>, Vec<PrivateTerm>) {
    let report = distinct(report.iter().chain(&change.private).cloned());
    let scrubber = Scrubber::new(app.iter().chain(&report).cloned().collect());
    (scrubber.scrub(&change.add), report)
}

/// One section of the draft card, with stand-ins in place.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DraftSection {
    pub heading: String,
    pub paragraphs: Vec<Vec<Segment>>,
    pub steps: Vec<Vec<Segment>>,
}

/// The report as the card first shows it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Draft {
    pub title: Vec<Segment>,
    pub sections: Vec<DraftSection>,
    /// The private words Rich found in this report beyond the ones RichOS holds. The card keeps
    /// them for every later change ([`scrub_change`]) and for its heads-up ("Jane Doe" looks private).
    #[serde(default)]
    pub private: Vec<PrivateTerm>,
}

/// Rich's write-up as a draft: every section scrubbed, the version line added as it is.
pub fn draft_from(written: &Written, version: &str, scrubber: &Scrubber) -> Draft {
    let mut terms = scrubber.terms().to_vec();
    terms.extend(written.private.iter().cloned());
    let scrubber = Scrubber::new(terms);
    let paragraphs = |text: &str| -> Vec<Vec<Segment>> {
        text.split("\n\n").map(str::trim).filter(|p| !p.is_empty()).map(|p| scrubber.scrub(&p.replace('\n', " "))).collect()
    };
    let mut sections = vec![DraftSection { heading: "What happened".into(), paragraphs: paragraphs(&written.what_happened), steps: vec![] }];
    if !written.where_.is_empty() {
        sections.push(DraftSection { heading: "Where".into(), paragraphs: paragraphs(&written.where_), steps: vec![] });
    }
    if !written.steps.is_empty() {
        sections.push(DraftSection {
            heading: "Steps to see it".into(),
            paragraphs: vec![],
            steps: written.steps.iter().map(|s| scrubber.scrub(s)).collect(),
        });
    }
    if !written.expected.is_empty() {
        sections.push(DraftSection { heading: "What the user expected".into(), paragraphs: paragraphs(&written.expected), steps: vec![] });
    }
    sections.push(DraftSection { heading: "Version".into(), paragraphs: vec![vec![Segment::plain(version)]], steps: vec![] });
    Draft { title: scrubber.scrub(&written.title), sections, private: distinct(written.private.iter().cloned()) }
}

// ---------------------------------------------------------------------------------------
// THE ISSUE, WORD FOR WORD
// ---------------------------------------------------------------------------------------

/// The sheet as the user approved it: plain words, stand-ins included as their words.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Sheet {
    pub title: String,
    pub sections: Vec<SheetSection>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SheetSection {
    pub heading: String,
    #[serde(default)]
    pub paragraphs: Vec<String>,
    #[serde(default)]
    pub steps: Vec<String>,
}

/// Markdown's punctuation, escaped so GitHub shows the words the user read rather than
/// formatting they never saw.
fn escaped(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        if "\\`*_[]<>#|".contains(c) {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

/// The issue's body: each section as a heading and its words, nothing added.
pub fn issue_body(sheet: &Sheet) -> String {
    let mut parts: Vec<String> = Vec::new();
    for section in &sheet.sections {
        let mut block = format!("### {}\n", escaped(section.heading.trim()));
        for p in section.paragraphs.iter().map(|p| p.trim()).filter(|p| !p.is_empty()) {
            block.push('\n');
            block.push_str(&escaped(p));
            block.push('\n');
        }
        let steps: Vec<&str> = section.steps.iter().map(|s| s.trim()).filter(|s| !s.is_empty()).collect();
        if !steps.is_empty() {
            block.push('\n');
            for (i, step) in steps.iter().enumerate() {
                block.push_str(&format!("{}. {}\n", i + 1, escaped(step)));
            }
        }
        parts.push(block);
    }
    parts.join("\n")
}

/// The page of issue `number` on [`REPOSITORY`]. Built from a number, so the card's link can only
/// ever open an issue of this repository, whatever the webview asks for.
pub fn issue_page(number: u64) -> String {
    format!("https://github.com/{REPOSITORY}/issues/{number}")
}

/// The API path and JSON body that file `sheet` on [`REPOSITORY`]: its title and its body, and
/// nothing else (no labels, no assignees).
pub fn issue_request(sheet: &Sheet) -> (String, serde_json::Value) {
    (format!("/repos/{REPOSITORY}/issues"), serde_json::json!({ "title": sheet.title.trim(), "body": issue_body(sheet) }))
}

// ---------------------------------------------------------------------------------------
// SEND, AND KEEP WHAT COULD NOT GO
// ---------------------------------------------------------------------------------------

/// Whose GitHub account an issue is filed from.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Account {
    /// The user's own account, once RichOS can be signed in to GitHub (§20; not built yet).
    User { login: String },
    /// The RichOS reporting account, when RichOS is not signed in to one of theirs.
    Reporting,
}

/// A token and whose it is, read at send time and never stored by this module.
#[derive(Clone)]
pub struct Credential {
    pub account: Account,
    pub token: String,
}

impl std::fmt::Debug for Credential {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Credential").field("account", &self.account).field("token", &"<hidden>").finish()
    }
}

/// Who a report goes out as, asked at the moment of sending.
pub trait Credentials {
    /// `None` when there is no account to send from: the report waits ([`Reason::NotSetUp`]).
    fn credential(&self) -> Option<Credential>;
}

/// What came back from one attempt to create an issue.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// `201 Created`, with the issue's number and its page.
    Created { number: u64, url: String },
    /// Any other HTTP status.
    Status { code: u16 },
    /// No connection could be made: this Mac is offline, or cannot find GitHub.
    Unreachable,
    /// A connection was made and nothing came back in time.
    TimedOut,
}

/// The one network call, made by the shell.
pub trait Transport {
    fn create_issue(&self, credential: &Credential, path: &str, request: &serde_json::Value) -> Outcome;
}

/// Why a report is waiting.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Reason {
    /// This Mac could not reach GitHub at all.
    Offline,
    /// GitHub did not answer, or answered that it is unavailable or busy.
    GithubDown,
    /// No account to send from: the reporting account's token is not on this Mac.
    NotSetUp,
    /// GitHub refused the account (a token it does not accept, or a repository it will not file in).
    Refused,
}

impl Reason {
    /// How long a waiting report rests before it is tried again by itself. "Every few minutes"
    /// for GitHub (round 21); sooner for an offline Mac, whose attempt fails fast and costs nothing.
    pub fn retry_after_ms(self) -> u64 {
        match self {
            Reason::Offline => 30_000,
            Reason::GithubDown => 180_000,
            Reason::NotSetUp => 300_000,
            Reason::Refused => 600_000,
        }
    }
}

/// What GitHub's answer means: the new issue, or why the report waits.
pub fn classify(outcome: &Outcome) -> Result<(u64, String), Reason> {
    match outcome {
        Outcome::Created { number, url } => Ok((*number, url.clone())),
        Outcome::Unreachable => Err(Reason::Offline),
        Outcome::TimedOut => Err(Reason::GithubDown),
        Outcome::Status { code } if *code >= 500 || *code == 429 || (300..400).contains(code) => Err(Reason::GithubDown),
        Outcome::Status { .. } => Err(Reason::Refused),
    }
}

/// A report on this Mac that has not gone out yet, exactly as it was approved.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Pending {
    pub id: String,
    pub created_at_ms: u64,
    pub title: String,
    pub body: String,
    pub attempts: u32,
    pub reason: Option<Reason>,
    pub next_try_at_ms: u64,
}

/// A report that went out.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Sent {
    pub id: String,
    pub number: u64,
    pub url: String,
    pub account: Account,
    pub title: String,
    pub sent_at_ms: u64,
}

/// What one attempt came to.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum Delivery {
    Sent(Sent),
    Waiting { id: String, reason: Reason },
}

/// What canceling a waiting report came to ([`Outbox::withdraw`]).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum Withdrawn {
    /// It is off this Mac and will never be sent.
    Canceled,
    /// It had already gone out: the issue it became.
    #[serde(rename = "sent")]
    AlreadySent(Sent),
}

/// The reports on this Mac: one file per waiting report in `<dir>/waiting/`, and one line per
/// sent report in `<dir>/sent.jsonl`.
///
/// **Callers serialize.** Two attempts at the same waiting report at once would file it twice,
/// so the shell holds one lock across every call into this store.
#[derive(Debug, Clone)]
pub struct Outbox {
    dir: PathBuf,
}

impl Outbox {
    pub fn open(dir: &Path) -> Self {
        Outbox { dir: dir.to_path_buf() }
    }

    fn waiting_dir(&self) -> PathBuf {
        self.dir.join("waiting")
    }

    fn path_of(&self, id: &str) -> Option<PathBuf> {
        // An id is ours (a uuid); anything else is refused rather than joined into a path.
        uuid::Uuid::parse_str(id).ok().map(|u| self.waiting_dir().join(format!("{u}.json")))
    }

    fn write(&self, pending: &Pending) -> io::Result<()> {
        let path = self.path_of(&pending.id).ok_or_else(|| io::Error::other("not a report id"))?;
        crate::quota::atomic_write(&path, pending)
    }

    /// Every waiting report, oldest first. A file this build cannot read is skipped, never deleted.
    pub fn pending(&self) -> io::Result<Vec<Pending>> {
        let entries = match std::fs::read_dir(self.waiting_dir()) {
            Ok(entries) => entries,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(vec![]),
            Err(e) => return Err(e),
        };
        let mut out: Vec<Pending> = Vec::new();
        for entry in entries {
            let path = entry?.path();
            if path.extension().and_then(|e| e.to_str()) != Some("json") {
                continue;
            }
            match std::fs::read(&path).map_err(|e| e.to_string()).and_then(|b| serde_json::from_slice::<Pending>(&b).map_err(|e| e.to_string())) {
                Ok(p) => out.push(p),
                Err(e) => eprintln!("[richos] bug report: {} could not be read ({e}); left in place", path.display()),
            }
        }
        out.sort_by_key(|p| (p.created_at_ms, p.id.clone()));
        Ok(out)
    }

    /// Every report that went out, oldest first.
    pub fn sent(&self) -> io::Result<Vec<Sent>> {
        let text = match std::fs::read_to_string(self.dir.join("sent.jsonl")) {
            Ok(t) => t,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(vec![]),
            Err(e) => return Err(e),
        };
        Ok(text.lines().filter_map(|l| serde_json::from_str(l).ok()).collect())
    }

    /// **CANCEL, CONFIRMED.** Take a waiting report off this Mac and say what became of it:
    /// [`Withdrawn::Canceled`] once its copy is gone (or there was none: nothing by that id will
    /// ever be sent), or [`Withdrawn::AlreadySent`] with the issue when it went out first. A copy
    /// that cannot be removed is an error, and the report still waits; the user is told so
    /// rather than that nothing was sent (second review finding 2).
    ///
    /// The shell calls this under the same one-at-a-time lock as every send, so a retry already
    /// in flight finishes first, and its record of going out is what this finds.
    pub fn withdraw(&self, id: &str) -> io::Result<Withdrawn> {
        if self.cancel(id)? {
            return Ok(Withdrawn::Canceled);
        }
        Ok(match self.sent()?.into_iter().find(|s| s.id == id) {
            Some(sent) => Withdrawn::AlreadySent(sent),
            None => Withdrawn::Canceled,
        })
    }

    /// Remove a waiting report. `false` when there was none by that id.
    pub fn cancel(&self, id: &str) -> io::Result<bool> {
        let Some(path) = self.path_of(id) else { return Ok(false) };
        match std::fs::remove_file(path) {
            Ok(()) => Ok(true),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(false),
            Err(e) => Err(e),
        }
    }

    /// **SEND AN APPROVED SHEET.** It is written to this Mac first, then tried once. Sent, or
    /// waiting with the reason; either way nothing approved is lost.
    pub fn send(&self, sheet: &Sheet, credentials: &dyn Credentials, transport: &dyn Transport, now_ms: u64) -> io::Result<Delivery> {
        let (_, request) = issue_request(sheet);
        let pending = Pending {
            id: uuid::Uuid::new_v4().to_string(),
            created_at_ms: now_ms,
            title: request["title"].as_str().unwrap_or_default().to_string(),
            body: request["body"].as_str().unwrap_or_default().to_string(),
            attempts: 0,
            reason: None,
            next_try_at_ms: now_ms,
        };
        self.write(&pending)?;
        self.attempt(pending, credentials, transport, now_ms)
    }

    /// *Try now*: one attempt at a waiting report, whenever it was due. `None` when it is not
    /// waiting (already sent, or canceled).
    pub fn try_now(&self, id: &str, credentials: &dyn Credentials, transport: &dyn Transport, now_ms: u64) -> io::Result<Option<Delivery>> {
        let Some(pending) = self.pending()?.into_iter().find(|p| p.id == id) else { return Ok(None) };
        self.attempt(pending, credentials, transport, now_ms).map(Some)
    }

    /// Every waiting report whose rest is over, tried once each, oldest first.
    pub fn send_due(&self, credentials: &dyn Credentials, transport: &dyn Transport, now_ms: u64) -> io::Result<Vec<Delivery>> {
        let mut out = Vec::new();
        for pending in self.pending()? {
            if pending.next_try_at_ms <= now_ms {
                out.push(self.attempt(pending, credentials, transport, now_ms)?);
            }
        }
        Ok(out)
    }

    fn attempt(&self, mut pending: Pending, credentials: &dyn Credentials, transport: &dyn Transport, now_ms: u64) -> io::Result<Delivery> {
        let outcome = match credentials.credential() {
            None => Err((Reason::NotSetUp, None)),
            Some(credential) => {
                let request = serde_json::json!({ "title": pending.title, "body": pending.body });
                let answer = transport.create_issue(&credential, &format!("/repos/{REPOSITORY}/issues"), &request);
                classify(&answer).map(|ok| (ok, credential.account)).map_err(|r| (r, Some(answer)))
            }
        };
        match outcome {
            Ok(((number, url), account)) => {
                let sent = Sent { id: pending.id.clone(), number, url, account, title: pending.title.clone(), sent_at_ms: now_ms };
                self.record_sent(&sent)?;
                Ok(Delivery::Sent(sent))
            }
            Err((reason, answer)) => {
                if let Some(answer) = answer {
                    eprintln!("[richos] bug report {}: not sent ({answer:?}); it waits on this Mac", pending.id);
                }
                pending.attempts += 1;
                pending.reason = Some(reason);
                pending.next_try_at_ms = now_ms.saturating_add(reason.retry_after_ms());
                self.write(&pending)?;
                Ok(Delivery::Waiting { id: pending.id, reason })
            }
        }
    }

    fn record_sent(&self, sent: &Sent) -> io::Result<()> {
        use io::Write;
        std::fs::create_dir_all(&self.dir)?;
        let mut file = std::fs::OpenOptions::new().create(true).append(true).open(self.dir.join("sent.jsonl"))?;
        file.write_all(format!("{}\n", serde_json::to_string(sent).map_err(io::Error::other)?).as_bytes())?;
        file.sync_all()?;
        // The record of it going out is on disk before the waiting copy goes, so a crash between
        // the two leaves a report both sent and waiting (filed twice at worst), never neither.
        self.cancel(&sent.id).map(|_| ())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_path_inside_brackets_and_a_trailing_colon_are_found_exactly() {
        let text = "see (/Users/a/b.txt): and \"~/x\"";
        let found: Vec<&str> = find_paths(text).into_iter().map(|(s, e)| &text[s..e]).collect();
        assert_eq!(found, ["/Users/a/b.txt", "~/x"]);
    }

    #[test]
    fn an_address_at_the_end_of_a_sentence_keeps_its_period_outside() {
        let text = "write to a.b+c@mail.example.com.";
        let found: Vec<&str> = find_emails(text).into_iter().map(|(s, e)| &text[s..e]).collect();
        assert_eq!(found, ["a.b+c@mail.example.com"]);
        assert!(find_emails("@home and x@y").is_empty());
    }

    #[test]
    fn non_ascii_text_around_a_name_is_handled_on_character_boundaries() {
        let scrubber = Scrubber::new(vec![PrivateTerm::new("Zoë Kim", Kind::PersonName)]);
        let segments = scrubber.scrub("“Zoë Kim” — café");
        let text: String = segments.iter().map(|s| s.text.as_str()).collect();
        assert_eq!(text, "“[a person]” — café");
    }
}
