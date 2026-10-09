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
///   - A name of **two or more words** is matched in any letter case, in every alphabet ("acme
///     deal", "CAFÉ NORTH" for "Café North", [`fold_char`]).
///   - A **one-word conversation name** is not matched at all (round 21 `privateTerms` does the
///     same): "Running" is a conversation in the demo and an ordinary word everywhere else.
///   - Any other **one-word name written Capitalized** ("Acme", "Deeply") is matched only where it
///     is written with a capital, so "deeply" in a sentence is left alone. One written in lower case
///     ("femcboost", a folder) is matched in any case, because it is not an ordinary word.
///   - Every match is a whole word: "Acmes" and "subAcme" are not "Acme".
///   - **File paths**: any word with a `/` or a `\` in it, except a web address (`https://…`),
///     "and/or", "w/", "w/o", "n/a", "24/7", and an all-digit fraction or date ("1/2", 10/09/2026).
///     From the start of that word, a bracket or quote before it included, everything to the end
///     of its line is left out, so no space, comma, bracket, quote or ". " in a file's name leaves
///     a piece behind ([`find_paths`]).
///   - Where two of these overlap, both are left out as one.
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
            if !kept.iter().any(|k| folded(&k.text) == folded(&term.text)) {
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

    /// Every private span in `text`, as (start, end, kind), non-overlapping and in order. Spans
    /// that overlap are joined into one covering both, with the kind of the one that starts first:
    /// dropping the later one would leave its uncovered part public ("Mary Jane" and "Jane Smith"
    /// in "Mary Jane Smith", or a company name that runs past the end of a path it starts in).
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
            match out.last_mut() {
                Some(last) if span.0 < last.1 => last.1 = last.1.max(span.1),
                _ => out.push(span),
            }
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

/// One character with its letter case folded away, in every alphabet: lower case, then upper,
/// then lower again, so "É" and "é" are one letter, "Ë" and "ë", "Σ", "σ" and "ς", and "ß", "ẞ"
/// and "SS" ("STRASSE" is "Straße"). Unicode's full case folding, built from the standard
/// library's own case tables rather than a second table kept here (fourth review finding 1:
/// ASCII-only folding left "CAFÉ NORTH" in a public report for the private name "Café North").
fn fold_char(c: char) -> impl Iterator<Item = char> {
    c.to_lowercase().flat_map(char::to_uppercase).flat_map(char::to_lowercase)
}

/// `text` with its letter case folded away ([`fold_char`]): the same words in any capitals
/// fold to the same string.
fn folded(text: &str) -> String {
    text.chars().flat_map(fold_char).collect()
}

/// Where a match of the folded `needle` that starts at byte `start` of `text` ends, if one does:
/// `text` is folded one character at a time, so the end is always a character boundary of the
/// ORIGINAL text, whatever lengths the two spellings have ("ß" is one character and folds to two).
fn folded_match_end(text: &str, start: usize, needle: &[char]) -> Option<usize> {
    let mut matched = 0;
    for (i, c) in text[start..].char_indices() {
        for f in fold_char(c) {
            if needle.get(matched) != Some(&f) {
                return None;
            }
            matched += 1;
        }
        if matched == needle.len() {
            return Some(start + i + c.len_utf8());
        }
    }
    None
}

/// Whole-word, letter-case-aware occurrences of `term` in `text` (see [`Scrubber`]'s rules).
/// Letter case is compared in every alphabet ([`fold_char`]); every offset is a character
/// boundary of `text`, so the stand-in replaces exactly the words as the user wrote them.
fn find_term(text: &str, term: &str) -> Vec<(usize, usize)> {
    let one_word = !term.contains(char::is_whitespace);
    let capitalized = term.chars().next().is_some_and(char::is_uppercase);
    let needle: Vec<char> = folded(term).chars().collect();
    let mut out = Vec::new();
    if needle.is_empty() {
        return out;
    }
    let mut skip_to = 0;
    for (i, _) in text.char_indices() {
        if i < skip_to {
            continue;
        }
        let Some(end) = folded_match_end(text, i, &needle) else { continue };
        let bounded = !char_before(text, i).is_some_and(is_word_char) && !char_after(text, end).is_some_and(is_word_char);
        let case_ok = !(one_word && capitalized) || char_after(text, i).is_some_and(char::is_uppercase);
        if bounded && case_ok {
            out.push((i, end));
            skip_to = end;
        }
    }
    out
}

/// **The end of the line** a path starts at `from`: the first line break, or the end of the text.
/// A file's name can hold spaces, commas, semicolons, brackets, quotes and a full stop followed by
/// a space ("Smith, Jones Budget.xlsx", "Budget (draft) Client.xlsx", "Dr. SecretClient
/// Budget.xlsx"), so none of them says where it ends, and the words between the path and the end
/// of its line go with it (review rv-20261009T151254Z-84d1bdce-20df finding 1: a comma ended it;
/// review rv-20261009T154959Z-96dcc581-085b finding 1: a closing bracket did; cc/echo-opus-bug7
/// at 1e7b696cf: ". " did, so "Dr. SecretClient Budget.xlsx" left "SecretClient Budget.xlsx"
/// public).
fn line_end(text: &str, from: usize) -> usize {
    text[from..].find(['\n', '\r']).map_or(text.len(), |i| from + i)
}

/// The short fixed list of words with a slash that are not paths ("w/" is "with").
const SLASH_WORDS: [&str; 5] = ["and/or", "w/", "w/o", "n/a", "24/7"];

/// **A word with a slash that is not a path**, and nothing else is: a web address (`http://`,
/// `https://`), a word on [`SLASH_WORDS`] in any capitals, or all digits on each side of its
/// slashes, one to four of them: a fraction ("1/2") or a date ("10/09", "10/09/2026"). Two plain
/// words ("Clients/SecretCo") are a path (cc/echo-opus-bug7 at 1e7b696cf left them public as a
/// short form). Brackets, quotes and punctuation around the word are not part of the form
/// ("(and/or)", "24/7,"). A backslash never makes one: there is no common form written with it.
fn is_not_a_path(word: &str) -> bool {
    let core = word.trim_matches(|c: char| !(c.is_alphanumeric() || c == '/' || c == '\\'));
    let head = word.trim_start_matches(|c: char| !c.is_alphanumeric());
    let web = ["http://", "https://"].iter().any(|s| head.get(..s.len()).is_some_and(|h| h.eq_ignore_ascii_case(s)));
    if web {
        return true;
    }
    if core.contains('\\') {
        return false;
    }
    if SLASH_WORDS.iter().any(|w| core.eq_ignore_ascii_case(w)) {
        return true;
    }
    let parts: Vec<&str> = core.split('/').collect();
    let number = |p: &&str| (1..=4).contains(&p.len()) && p.chars().all(|c| c.is_ascii_digit());
    (2..=3).contains(&parts.len()) && parts.iter().all(number)
}

/// **File paths**: every word (a run of text between spaces) with a `/` or a `\` in it, except
/// the ones [`is_not_a_path`] names. Each is left out from the start of its word, so a bracket,
/// quote or backtick written before it goes with it, to the end of its line ([`line_end`]); the
/// line's own final full stop, colon, "!" or "?" stays outside.
///
/// The rule recognizes no shape of path (review rv-20261009T154959Z-96dcc581-085b: three rounds
/// in a row each found one more shape that leaked, the last nested brackets and relative paths).
/// `/Users/…`, `~/…`, `./…`, `../…`, `clients/x/y.xlsx`, `C:\…`, `file://…` and a path between
/// brackets that hold brackets are all a word with a slash in it. No closing mark ends one: a
/// file's name can hold every one of them. Hiding a few words after a path is safe; leaving part
/// of one in a public report is not.
fn find_paths(text: &str) -> Vec<(usize, usize)> {
    let mut out = Vec::new();
    let mut skip_to = 0;
    for word in text.split_whitespace() {
        // `split_whitespace` gives slices of `text` itself, so where the word sits in memory is
        // where it starts in `text`: a character boundary, since a word starts after a space.
        let start = word.as_ptr() as usize - text.as_ptr() as usize;
        if start < skip_to || !word.contains(['/', '\\']) || is_not_a_path(word) {
            continue;
        }
        let mut end = start + text[start..line_end(text, start)].trim_end().len();
        while end > start && text[..end].ends_with(['.', ':', '!', '?']) {
            end -= 1;
        }
        if end > start {
            out.push((start, end));
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
    /// **WHAT WAS ON IT**: the screen's visible words, top to bottom, as the window read them the
    /// moment Bust a bug was pressed, before the exchange covered anything. Private names
    /// included: it goes to the user's own Claude to check against, never into the issue.
    #[serde(default)]
    pub content: String,
}

/// The most of the screen's words Rich is given, in characters: enough for a full window of a
/// conversation, and a bound so a long one cannot crowd out the user's own words.
pub const SCREEN_CONTENT_MAX: usize = 12_000;

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
    /// What Rich saw on the screen that bears the user out, in a few words ("Saw the names cut
    /// off at 135% text size"), or empty. Shown to the user over his answer (round 21's
    /// digest), never in the issue.
    pub checked: String,
}

/// The arguments `claude` is run with to write the report: one printed answer, no tools, none
/// of the operator's settings, no session left on disk, no MCP servers. The account comes from
/// `CLAUDE_CONFIG_DIR`, which the shell sets to the account the conversation runs on. No
/// `--model`: Rich writes with the same model he talks with.
///
/// **The prompt arrives as one stream-json user message on standard input** ([`writer_input`]),
/// because that is how a picture reaches him: an image block beside the words. Measured with
/// claude 2.1.295 on 2026-10-09 with exactly these arguments: a 64 by 64 red picture and "What
/// single color fills the attached picture?" came back `{"color": "red"}` on the `result` line.
/// stream-json output needs `--verbose`; [`result_text`] reads the last `result` line.
pub fn writer_args() -> Vec<String> {
    [
        "--print",
        "--input-format",
        "stream-json",
        "--output-format",
        "stream-json",
        "--verbose",
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

/// The screen's words as Rich is given them: each line's whitespace folded, empty lines dropped,
/// at most [`SCREEN_CONTENT_MAX`] characters, cut on a character boundary.
pub fn screen_words(content: &str) -> String {
    let lines: Vec<String> = content.lines().map(|l| l.split_whitespace().collect::<Vec<_>>().join(" ")).filter(|l| !l.is_empty()).collect();
    let text = lines.join("\n");
    match text.char_indices().nth(SCREEN_CONTENT_MAX) {
        Some((cut, _)) => format!("{}\n[the rest of the screen is left off]", &text[..cut]),
        None => text,
    }
}

/// What Rich has to look at, and the order to check what the user said against it.
fn evidence(screen: &Screen, picture: bool) -> String {
    let words = screen_words(&screen.content);
    let mut out = String::new();
    if !words.is_empty() {
        out.push_str(&format!(
            "What was on that screen when they pressed the button, its visible words top to bottom. They are \
private: check against them, and do not copy names from them into the report.\n<<<\n{words}\n>>>\n\n"
        ));
    }
    if picture {
        out.push_str(
            "A picture of the RichOS window as it was when they pressed the button is attached. It is private \
too: describe what it shows only in words a stranger may read.\n\n",
        );
    }
    if !out.is_empty() {
        out.push_str(
            "CHECK what the user said against the screen before you write: say in the report what the screen \
shows that bears it out (what is cut off, missing or wrong, and what a control or a count reads), and do not \
claim anything the screen does not show.\n\n",
        );
    }
    out
}

/// The one prompt Rich writes the report from. `picture` says a picture of the window goes with
/// it ([`writer_input`]).
pub fn writer_prompt(answer: &str, screen: &Screen, version: &str, terms: &[PrivateTerm], picture: bool) -> String {
    format!(
        "You are Rich, the user's assistant inside the RichOS desktop app. The user pressed \"Bust a bug\" \
and told you what went wrong. Write it up as a bug report for the RichOS developers. After the user reads \
and approves it, it is filed as a GitHub issue that anyone can read.\n\n\
What the user said, in their own words:\n<<<\n{answer}\n>>>\n\n\
Where they were when they pressed the button:\n{screen}\n\n\
{evidence}\
Private words this user has: {terms}. Leave names out where you can; any that remain are replaced with \
plain stand-ins such as [a conversation] before the user sees the report.\n\n\
Write in plain American English that a non-technical reader follows. Say what the user saw and did, not \
guesses about the code. Give steps to see it only as far as the user's words and the screen support them.\n\n\
Answer with ONLY a JSON object, no other text, in exactly this shape:\n\
{{\"title\": \"...\", \"what_happened\": \"...\", \"where\": \"...\", \"steps\": [\"...\"], \"expected\": \"...\", \
\"checked\": \"...\", \"private\": [{{\"text\": \"...\", \"kind\": \"person\"}}]}}\n\
- title: one line under 80 characters that says what is wrong.\n\
- what_happened: one or two short paragraphs; a blank line between paragraphs.\n\
- where: the place in RichOS, in words a reader of the public issue understands.\n\
- steps: the shortest steps to see it, or [] when the user's words do not support any.\n\
- expected: what the user expected instead, or \"\" when it is not clear.\n\
- checked: under 60 characters, starting with a verb, what you saw on the screen that bears the user out \
(\"Saw the names cut off at 135% text size\"), or \"\" when the screen does not show it or you were not given it.\n\
- private: every name of a person, company, conversation, product, client or folder, and anything else \
private, that is still in what you wrote, copied exactly, with kind one of person, company, conversation, \
folder, file, email, other. [] when there is none.",
        answer = answer.trim(),
        screen = screen_lines(screen, version),
        evidence = evidence(screen, picture),
        terms = terms_line(terms),
    )
}

/// A picture for Rich: its media type (`image/jpeg`) and its bytes in standard base64.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Picture {
    pub media_type: String,
    pub base64: String,
}

/// **The one line `claude` reads on standard input** ([`writer_args`]): a stream-json user
/// message holding the picture, when there is one, and the prompt.
pub fn writer_input(prompt: &str, picture: Option<&Picture>) -> String {
    let mut content = Vec::new();
    if let Some(p) = picture {
        content.push(serde_json::json!({ "type": "image", "source": { "type": "base64", "media_type": p.media_type, "data": p.base64 } }));
    }
    content.push(serde_json::json!({ "type": "text", "text": prompt }));
    format!("{}\n", serde_json::json!({ "type": "user", "message": { "role": "user", "content": content } }))
}

/// **The line over Rich's answer** (round 21's digest): what he did. "Looked at the screen you
/// were on" (or at the window's name) only when he wrote the report AND was given what was on
/// the screen (`looked`); then what he saw that bears the user out, when he says; then the
/// version. Without Rich, it says the report was written from the user's words.
pub fn digest(screen: &Screen, by_rich: bool, looked: bool, checked: &str) -> String {
    let place = match screen.key.as_str() {
        "corrections" | "feedback" | "search" => screen.here.clone(),
        _ => "the screen you were on".to_string(),
    };
    let saw = by_rich && looked;
    let mut first = format!("{} {place}", if saw { "Looked at" } else { "Noted" });
    if screen.text_size != 100 {
        first.push_str(&format!(", at {}% text size", screen.text_size));
    }
    let mut parts = vec![first];
    let checked = checked.trim().trim_end_matches('.');
    if saw && !checked.is_empty() && checked.chars().count() <= 80 {
        parts.push(capitalized(checked));
    }
    parts.push("Checked the version".into());
    if !by_rich {
        parts.push("Wrote it from your words".into());
    }
    parts.join(" · ")
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

/// The `result` text out of `claude --print`'s answer: the last `"type": "result"` line of its
/// stream-json output (one JSON object per line), or the one object `--output-format json`
/// prints. An error reply (not signed in, out of quota) is refused rather than read as a report.
pub fn result_text(stdout: &str) -> Result<String, String> {
    let value: serde_json::Value = stdout
        .lines()
        .rev()
        .filter_map(|line| serde_json::from_str::<serde_json::Value>(line.trim()).ok())
        .find(|v| v["type"] == "result")
        .ok_or_else(|| "not a reply: no result line".to_string())?;
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
        if !term.text.is_empty() && !out.iter().any(|t| folded(&t.text) == folded(&term.text)) {
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
        checked: text_of(&value, "checked"),
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
        checked: String::new(),
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

/// **THE CARD'S HEADS-UP, ASKED OF THE SCRUBBER THAT CLEANS THE REPORT**: the private words in
/// `text`, the words of the report as the user has changed them, by exactly the rules and the
/// private words a change is scrubbed with ([`scrub_change`]): the names RichOS holds (`app`) and
/// the ones Rich found in this report (`report`). The window keeps no copy of these rules (fourth
/// review finding 2: its own ASCII-only email pattern missed `alice@büro.de`, which this catches).
/// It decides nothing: the user may send anyway, having been told.
pub fn private_in_edit(text: &str, app: &[PrivateTerm], report: &[PrivateTerm]) -> Vec<String> {
    Scrubber::new(app.iter().chain(report).cloned().collect()).private_in(text)
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
    fn a_path_takes_its_bracket_and_the_rest_of_its_sentence_and_keeps_the_full_stop_outside() {
        // Before review rv-20261009T154959Z-96dcc581-085b the closing bracket ended this path and
        // the quoted one was a second path; a bracket no longer ends one.
        let text = "see (/Users/a/b.txt): and \"~/x\"";
        let found: Vec<&str> = find_paths(text).into_iter().map(|(s, e)| &text[s..e]).collect();
        assert_eq!(found, ["(/Users/a/b.txt): and \"~/x\""]);
        // Since cc/echo-opus-bug7 left ". " ending a path inside a file's name, a sentence end
        // no longer ends one: the line's end does, and its final full stop stays outside.
        let text = "see /a. Then ~/x! And 10/09.";
        let found: Vec<&str> = find_paths(text).into_iter().map(|(s, e)| &text[s..e]).collect();
        assert_eq!(found, ["/a. Then ~/x! And 10/09"]);
        let text = "see /a.\nThen ~/x!\r\nAnd 10/09.";
        let found: Vec<&str> = find_paths(text).into_iter().map(|(s, e)| &text[s..e]).collect();
        assert_eq!(found, ["/a", "~/x"]);
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
