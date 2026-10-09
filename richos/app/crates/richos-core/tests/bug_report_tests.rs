//! **BUST A BUG** — the CEO's §115 (2026-10-09), built to round 21: *"we should just let the
//! user say what's wrong and where and let their Rich check and articulate everything properly
//! and then submit a GitHub issue on their behalf."*
//!
//! What this file holds the core to, one test per promise the round makes on the card:
//!
//!   1. **Private details are left out.** Names RichOS holds (conversations, companies, people,
//!      folders), file paths and email addresses never reach the issue: each is replaced by a
//!      plain stand-in, and what it replaced is kept beside it for the user's eyes only.
//!   2. **The draft is shown before anything is sent.** Writing a report sends nothing; the
//!      issue is rendered from the sheet the user approved, word for word.
//!   3. **Send.** One POST to `WebDevBooster/richos`'s issues, with the token read at send time.
//!   4. **A failed send is kept and resent.** Offline, GitHub down, or no reporting account set
//!      up: the report stays on the Mac exactly as approved, survives a relaunch, and goes out by
//!      itself once it can.
//!
//! Everything here runs against a fake transport and fake credentials, so no test can file a
//! real issue and none reads the login keychain.

use richos_core::bug_report::*;
use std::cell::RefCell;
use std::path::PathBuf;

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("richos-bug-report-{name}-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn terms() -> Vec<PrivateTerm> {
    vec![
        PrivateTerm::new("Acme deal", Kind::ConversationName),
        PrivateTerm::new("Design RichOS memory strategy", Kind::ConversationName),
        // A one-word conversation name is left alone, as round 21 does: "Running" is also a word.
        PrivateTerm::new("Running", Kind::ConversationName),
        PrivateTerm::new("Northwind Traders", Kind::CompanyName),
        PrivateTerm::new("Acme", Kind::CompanyName),
        PrivateTerm::new("Deeply", Kind::CompanyName),
        PrivateTerm::new("Dana Whitfield", Kind::PersonName),
        PrivateTerm::new("femcboost", Kind::FolderName),
    ]
}

fn joined(segments: &[Segment]) -> String {
    segments.iter().map(|s| s.text.as_str()).collect()
}

fn screen() -> Screen {
    Screen {
        key: "conversation".into(),
        here: "the Acme deal conversation".into(),
        public: "a conversation, the main RichOS screen".into(),
        conversation: Some("Acme deal".into()),
        text_size: 135,
        theme: "dark".into(),
        technical_view: false,
    }
}

const VERSION: &str = "RichOS 1.2.0, nightly 45 · macOS 15.6 · Apple silicon";

// ---------------------------------------------------------------------------------------
// 1. PRIVATE DETAILS ARE LEFT OUT
// ---------------------------------------------------------------------------------------

#[test]
fn names_paths_and_addresses_are_replaced_by_stand_ins_and_what_they_replaced_is_kept() {
    let scrubber = Scrubber::new(terms());
    let said = "In the acme deal chat, Dana Whitfield's notes at /Users/alex/ab/femcboost/notes.txt \
                and ~/Desktop/plan.md went missing; mail dana@northwind.example about Northwind Traders \
                and Acme. FEMCBOOST is the folder.";
    let segments = scrubber.scrub(said);
    let text = joined(&segments);
    for private in ["acme deal", "Dana Whitfield", "/Users/alex", "femcboost", "FEMCBOOST", "~/Desktop", "dana@northwind.example", "Northwind Traders", "Acme."] {
        assert!(!text.contains(private), "{private:?} reached the report: {text}");
    }
    assert!(text.contains("[a conversation]"), "{text}");
    assert!(text.contains("[a person]"), "{text}");
    assert!(text.contains("[a file on this Mac]"), "{text}");
    assert!(text.contains("[an email address]"), "{text}");
    assert!(text.contains("[a company]"), "{text}");
    assert!(text.contains("[a folder]"), "{text}");
    // Each stand-in remembers what it replaced, for the tooltip only the user sees.
    let replaced: Vec<(&str, Kind)> = segments
        .iter()
        .filter_map(|s| s.was.as_deref().map(|w| (w, s.kind.unwrap())))
        .collect();
    assert!(replaced.contains(&("acme deal", Kind::ConversationName)), "{replaced:?}");
    assert!(replaced.contains(&("/Users/alex/ab/femcboost/notes.txt", Kind::FilePath)), "{replaced:?}");
    assert!(replaced.contains(&("dana@northwind.example", Kind::EmailAddress)), "{replaced:?}");
    // The path's sentence punctuation stays outside the stand-in.
    assert!(text.contains("[a file on this Mac] and"), "{text}");
}

#[test]
fn ordinary_words_that_happen_to_spell_a_name_are_left_alone() {
    let scrubber = Scrubber::new(terms());
    let text = joined(&scrubber.scrub("It keeps running deeply slowly, and and/or 24/7 is fine; Running is a word."));
    // "Running" is a one-word conversation name (skipped), "deeply" is not capitalized, and a
    // slash between words is not a path.
    assert_eq!(text, "It keeps running deeply slowly, and and/or 24/7 is fine; Running is a word.");
}

#[test]
fn rich_can_name_more_private_words_than_richos_holds() {
    let mut extra = terms();
    extra.push(PrivateTerm::new("Marta", Kind::PersonName));
    let text = joined(&Scrubber::new(extra).scrub("Marta saw it too."));
    assert_eq!(text, "[a person] saw it too.");
}

#[test]
fn the_left_out_line_counts_what_was_replaced() {
    let scrubber = Scrubber::new(terms());
    let mut all = scrubber.scrub("Acme deal and Design RichOS memory strategy, with Dana Whitfield.");
    all.extend(scrubber.scrub("Also /Users/alex/x/y.txt"));
    assert_eq!(
        left_out_line(&all),
        "Left out, because anyone can read GitHub issues: two conversation names, one person's name \
         and one file path. The underlined words stand in for them; point at one to see what it replaced."
    );
    assert_eq!(
        left_out_line(&scrubber.scrub("Nothing private here.")),
        "Nothing private was in it, so nothing was left out. Anyone can read GitHub issues."
    );
}

// ---------------------------------------------------------------------------------------
// 2. RICH WRITES IT UP; THE DRAFT IS SHOWN BEFORE ANYTHING IS SENT
// ---------------------------------------------------------------------------------------

#[test]
fn richs_write_up_is_read_out_of_his_answer_even_with_words_around_it() {
    let raw = "Here it is:\n```json\n{\"title\": \"Conversation names in the sidebar are cut off at larger text sizes\",\n\
               \"what_happened\": \"With Text size at 135%, the Acme deal name is cut off.\\n\\nAt 100% it fits.\",\n\
               \"where\": \"The list of conversations on the left, in the Acme deal conversation.\",\n\
               \"steps\": [\"Open any conversation.\", \"Raise Text size to 135%.\"],\n\
               \"expected\": \"Every name can still be read.\",\n\
               \"private\": [{\"text\": \"Marta\", \"kind\": \"person\"}]}\n```";
    let written = parse_written(raw).expect("a fenced answer is read");
    assert_eq!(written.title, "Conversation names in the sidebar are cut off at larger text sizes");
    assert_eq!(written.steps.len(), 2);
    assert_eq!(written.private, vec![PrivateTerm::new("Marta", Kind::PersonName)]);

    let draft = draft_from(&written, VERSION, &Scrubber::new(terms()));
    let headings: Vec<&str> = draft.sections.iter().map(|s| s.heading.as_str()).collect();
    assert_eq!(headings, ["What happened", "Where", "Steps to see it", "What the user expected", "Version"]);
    let what = &draft.sections[0];
    assert_eq!(what.paragraphs.len(), 2, "a blank line starts a new paragraph");
    assert!(joined(&what.paragraphs[0]).contains("[a conversation]"));
    assert!(!joined(&what.paragraphs[0]).contains("Acme"));
    // The version line is not scrubbed: it holds nothing private and must read as it is.
    assert_eq!(joined(&draft.sections[4].paragraphs[0]), VERSION);
}

#[test]
fn an_answer_that_is_not_a_report_is_refused_not_guessed_at() {
    assert!(parse_written("I can't help with that.").is_err());
    assert!(parse_written("{\"what_happened\": \"no title\"}").is_err());
    assert!(parse_written("{\"title\": \"   \", \"what_happened\": \"x\"}").is_err());
}

#[test]
fn the_plain_write_up_is_what_the_user_said_with_the_screen_and_the_version() {
    let written = plain_write_up(
        "the names on the left get cut off when I make the text bigger in the Acme deal chat. Can't read them.",
        &screen(),
    );
    // 76 characters end inside "deal" ("…the Acme de|al chat"), so "deal" goes whole.
    assert_eq!(written.title, "The names on the left get cut off when I make the text bigger in the Acme");
    // A cut that lands between two words keeps the last one.
    let words = format!("{}w", "word ".repeat(15)); // 76 characters, ending on a whole word
    let boundary = plain_write_up(&format!("{words} and more words follow here."), &screen());
    assert_eq!(boundary.title, format!("W{}", &words[1..]));
    let draft = draft_from(&written, VERSION, &Scrubber::new(terms()));
    let title = joined(&draft.title);
    assert!(!title.contains("Acme"), "{title}");
    assert_eq!(draft.sections[1].heading, "Where");
    assert_eq!(
        joined(&draft.sections[1].paragraphs[0]),
        "A conversation, the main RichOS screen. It was on screen when the report was started."
    );
    assert_eq!(draft.sections.last().unwrap().heading, "Version");
}

#[test]
fn the_prompt_carries_the_users_words_the_screen_and_the_version_and_asks_for_json() {
    let prompt = writer_prompt("names get cut off", &screen(), VERSION, &terms());
    assert!(prompt.contains("names get cut off"));
    assert!(prompt.contains("the Acme deal conversation"));
    assert!(prompt.contains("135%"));
    assert!(prompt.contains(VERSION));
    assert!(prompt.contains("\"what_happened\""));
    assert!(prompt.contains("anyone can read"));
}

#[test]
fn rich_runs_with_no_tools_no_settings_and_no_saved_session() {
    let args = writer_args();
    let has = |flag: &str, value: &str| args.windows(2).any(|w| w[0] == flag && w[1] == value);
    assert!(args.iter().any(|a| a == "--print"));
    assert!(has("--output-format", "json"));
    assert!(has("--tools", ""), "{args:?}");
    assert!(has("--setting-sources", ""), "{args:?}");
    assert!(args.iter().any(|a| a == "--no-session-persistence"));
    assert!(args.iter().any(|a| a == "--strict-mcp-config"));
}

#[test]
fn the_reply_envelope_is_read_and_an_error_reply_is_refused() {
    let ok = r#"{"type":"result","is_error":false,"result":"{\"title\":\"T\",\"what_happened\":\"W\"}"}"#;
    assert_eq!(result_text(ok).unwrap(), "{\"title\":\"T\",\"what_happened\":\"W\"}");
    assert!(result_text(r#"{"type":"result","is_error":true,"result":"Not logged in"}"#).is_err());
    assert!(result_text("not json").is_err());
}

#[test]
fn a_change_said_to_rich_is_one_sentence_added_where_he_says() {
    let raw = r#"{"section": "What happened", "add": "It happens in the light theme too."}"#;
    let change = parse_change(raw).unwrap();
    assert_eq!(change.section, "What happened");
    assert_eq!(change.add, "It happens in the light theme too.");
    // Without Rich: the user's own words, tidied the way round 21 tidies them.
    let plain = plain_change("Also say it happens in the light theme too");
    assert_eq!(plain.section, "What happened");
    assert_eq!(plain.add, "It happens in the light theme too.");
}

#[test]
fn the_issue_is_the_sheet_word_for_word() {
    let sheet = Sheet {
        title: "Names are cut off at 135%".into(),
        sections: vec![
            SheetSection { heading: "What happened".into(), paragraphs: vec!["They are cut off with \"…\".".into(), "At 100% they fit.".into()], steps: vec![] },
            SheetSection { heading: "Steps to see it".into(), paragraphs: vec![], steps: vec!["Open any conversation.".into(), "Raise *Text size*.".into()] },
            SheetSection { heading: "Version".into(), paragraphs: vec![VERSION.into()], steps: vec![] },
        ],
    };
    let body = issue_body(&sheet);
    assert_eq!(
        body,
        "### What happened\n\nThey are cut off with \"…\".\n\nAt 100% they fit.\n\n\
         ### Steps to see it\n\n1. Open any conversation.\n2. Raise \\*Text size\\*.\n\n\
         ### Version\n\nRichOS 1.2.0, nightly 45 · macOS 15.6 · Apple silicon\n"
    );
    // The request is the title and that body, and nothing else.
    let (path, json) = issue_request(&sheet);
    assert_eq!(path, "/repos/WebDevBooster/richos/issues");
    assert_eq!(json, serde_json::json!({ "title": "Names are cut off at 135%", "body": body }));
    // The card's link is built from the number, never from a URL the page passes.
    assert_eq!(issue_page(412), "https://github.com/WebDevBooster/richos/issues/412");
}

#[test]
fn the_version_line_says_which_build_in_words() {
    assert_eq!(version_line("1.2.0-nightly.20261007.45", Some("15.6"), "aarch64"), VERSION);
    assert_eq!(version_line("1.2.0-dev.a8a232c0e", Some("15.6"), "x86_64"), "RichOS 1.2.0, development build a8a232c0e · macOS 15.6 · Intel");
    assert_eq!(version_line("1.2.0", None, "aarch64"), "RichOS 1.2.0 · Apple silicon");
}

// ---------------------------------------------------------------------------------------
// 3 AND 4. SEND; A FAILED SEND IS KEPT AND RESENT
// ---------------------------------------------------------------------------------------

struct FakeGitHub {
    answers: RefCell<Vec<Outcome>>,
    seen: RefCell<Vec<(String, String, String, String)>>,
}
impl FakeGitHub {
    fn answering(answers: Vec<Outcome>) -> Self {
        FakeGitHub { answers: RefCell::new(answers), seen: RefCell::new(vec![]) }
    }
}
impl Transport for FakeGitHub {
    fn create_issue(&self, credential: &Credential, path: &str, request: &serde_json::Value) -> Outcome {
        self.seen.borrow_mut().push((
            credential.token.clone(),
            path.to_string(),
            request["title"].as_str().unwrap().to_string(),
            request["body"].as_str().unwrap().to_string(),
        ));
        self.answers.borrow_mut().remove(0)
    }
}

struct Token(Option<&'static str>);
impl Credentials for Token {
    fn credential(&self) -> Option<Credential> {
        self.0.map(|t| Credential { account: Account::Reporting, token: t.to_string() })
    }
}

fn sheet(title: &str) -> Sheet {
    Sheet {
        title: title.into(),
        sections: vec![SheetSection { heading: "What happened".into(), paragraphs: vec!["It broke.".into()], steps: vec![] }],
    }
}

#[test]
fn send_files_one_issue_from_the_reporting_account_and_keeps_a_record_of_it() {
    let dir = scratch("send");
    let outbox = Outbox::open(&dir);
    let github = FakeGitHub::answering(vec![Outcome::Created { number: 412, url: "https://github.com/WebDevBooster/richos/issues/412".into() }]);
    let delivery = outbox.send(&sheet("Names are cut off"), &Token(Some("tok-1")), &github, 1_000).unwrap();
    match delivery {
        Delivery::Sent(sent) => {
            assert_eq!(sent.number, 412);
            assert_eq!(sent.account, Account::Reporting);
            assert_eq!(sent.url, "https://github.com/WebDevBooster/richos/issues/412");
        }
        other => panic!("not sent: {other:?}"),
    }
    let seen = github.seen.borrow();
    assert_eq!(seen.len(), 1);
    assert_eq!(seen[0].0, "tok-1", "the token read at send time is the one used");
    assert_eq!(seen[0].1, "/repos/WebDevBooster/richos/issues");
    assert_eq!(seen[0].2, "Names are cut off");
    assert_eq!(seen[0].3, issue_body(&sheet("Names are cut off")));
    assert!(outbox.pending().unwrap().is_empty(), "a sent report is not waiting");
    assert_eq!(outbox.sent().unwrap().len(), 1);
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn a_failed_send_is_kept_on_the_mac_exactly_as_approved_and_resent_when_it_can_go() {
    let dir = scratch("kept");
    let approved = sheet("Not now leaves the suggestion");
    {
        let outbox = Outbox::open(&dir);
        let offline = FakeGitHub::answering(vec![Outcome::Unreachable]);
        match outbox.send(&approved, &Token(Some("tok")), &offline, 10_000).unwrap() {
            Delivery::Waiting { reason, .. } => assert_eq!(reason, Reason::Offline),
            other => panic!("{other:?}"),
        }
    }
    // A RELAUNCH: a fresh store over the same folder still holds it, word for word.
    let outbox = Outbox::open(&dir);
    let waiting = outbox.pending().unwrap();
    assert_eq!(waiting.len(), 1);
    assert_eq!(waiting[0].title, approved.title);
    assert_eq!(waiting[0].body, issue_body(&approved));
    assert_eq!(waiting[0].reason, Some(Reason::Offline));

    // Not yet due: nothing is tried, so an offline Mac is not hammered.
    let none = FakeGitHub::answering(vec![]);
    assert!(outbox.send_due(&Token(Some("tok")), &none, 10_000 + 1_000).unwrap().is_empty());
    assert!(none.seen.borrow().is_empty());

    // Back online and due: it goes out by itself, with the body it was approved with.
    let online = FakeGitHub::answering(vec![Outcome::Created { number: 413, url: "u".into() }]);
    let due = waiting[0].next_try_at_ms;
    let sent = outbox.send_due(&Token(Some("tok")), &online, due).unwrap();
    assert_eq!(sent.len(), 1);
    assert!(matches!(&sent[0], Delivery::Sent(s) if s.number == 413));
    assert_eq!(online.seen.borrow()[0].3, issue_body(&approved));
    assert!(outbox.pending().unwrap().is_empty());
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn try_now_sends_a_waiting_report_at_once() {
    let dir = scratch("trynow");
    let outbox = Outbox::open(&dir);
    let id = match outbox.send(&sheet("x"), &Token(Some("t")), &FakeGitHub::answering(vec![Outcome::Status { code: 503 }]), 0).unwrap() {
        Delivery::Waiting { id, reason } => {
            assert_eq!(reason, Reason::GithubDown);
            id
        }
        other => panic!("{other:?}"),
    };
    let github = FakeGitHub::answering(vec![Outcome::Created { number: 9, url: "u".into() }]);
    assert!(matches!(outbox.try_now(&id, &Token(Some("t")), &github, 1).unwrap(), Some(Delivery::Sent(_))));
    assert_eq!(outbox.try_now(&id, &Token(Some("t")), &github, 2).unwrap(), None, "it is no longer waiting");
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn with_no_reporting_account_set_up_nothing_is_tried_and_the_report_waits() {
    let dir = scratch("notoken");
    let outbox = Outbox::open(&dir);
    let github = FakeGitHub::answering(vec![]);
    match outbox.send(&sheet("x"), &Token(None), &github, 0).unwrap() {
        Delivery::Waiting { reason, .. } => assert_eq!(reason, Reason::NotSetUp),
        other => panic!("{other:?}"),
    }
    assert!(github.seen.borrow().is_empty(), "no request without a token");
    assert_eq!(outbox.pending().unwrap().len(), 1);
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn a_canceled_report_is_gone_and_is_never_sent() {
    let dir = scratch("cancel");
    let outbox = Outbox::open(&dir);
    let id = match outbox.send(&sheet("x"), &Token(Some("t")), &FakeGitHub::answering(vec![Outcome::Unreachable]), 0).unwrap() {
        Delivery::Waiting { id, .. } => id,
        other => panic!("{other:?}"),
    };
    assert!(outbox.cancel(&id).unwrap());
    assert!(outbox.pending().unwrap().is_empty());
    let github = FakeGitHub::answering(vec![]);
    assert!(outbox.send_due(&Token(Some("t")), &github, u64::MAX).unwrap().is_empty());
    assert!(github.seen.borrow().is_empty());
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn what_github_answered_decides_what_the_user_is_told() {
    assert_eq!(classify(&Outcome::Unreachable), Err(Reason::Offline));
    assert_eq!(classify(&Outcome::TimedOut), Err(Reason::GithubDown));
    assert_eq!(classify(&Outcome::Status { code: 502 }), Err(Reason::GithubDown));
    assert_eq!(classify(&Outcome::Status { code: 429 }), Err(Reason::GithubDown));
    assert_eq!(classify(&Outcome::Status { code: 401 }), Err(Reason::Refused));
    assert_eq!(classify(&Outcome::Status { code: 404 }), Err(Reason::Refused));
    assert_eq!(classify(&Outcome::Created { number: 1, url: "u".into() }), Ok((1, "u".to_string())));
    // An offline Mac is asked again sooner than a GitHub that is down, which is asked every few minutes.
    assert!(Reason::Offline.retry_after_ms() < Reason::GithubDown.retry_after_ms());
    assert!(Reason::GithubDown.retry_after_ms() >= 120_000);
}

// ---------------------------------------------------------------------------------------
// THE SECOND REVIEW'S CASES (rv-20261009T102303Z-1c3dda1d-4c78, on 1c3dda1dc): one test per
// fixture case, each a thing a user hits in normal use.
// ---------------------------------------------------------------------------------------

/// The scrubbed text, and what each file-path stand-in replaced.
fn paths_left_out(text: &str) -> (String, Vec<String>) {
    let segments = Scrubber::default().scrub(text);
    let was = segments.iter().filter(|s| s.kind == Some(Kind::FilePath)).filter_map(|s| s.was.clone()).collect();
    (joined(&segments), was)
}

#[test]
fn a_path_in_backticks_is_left_out_whole() {
    // Finding 1, fixture `core-edge-cases.py`: on the tip the backtick kept the path out of the
    // detector and the whole path reached the public report.
    let (text, was) = paths_left_out("The file `/Users/alex/Clients/SecretCo/budget.xlsx` disappeared.");
    assert_eq!(text, "The file `[a file on this Mac]` disappeared.");
    assert_eq!(was, ["/Users/alex/Clients/SecretCo/budget.xlsx"]);
}

#[test]
fn a_path_with_spaces_is_left_out_whole() {
    // Finding 1: on the tip only "/Users/alex/Client" was replaced and "Plans/SecretCo.xlsx" went public.
    let (text, was) = paths_left_out("The file /Users/alex/Client Plans/SecretCo.xlsx disappeared.");
    assert_eq!(text, "The file [a file on this Mac] disappeared.");
    assert_eq!(was, ["/Users/alex/Client Plans/SecretCo.xlsx"]);
    // The common Mac shape: a folder with a space in it, written plainly, and one that ENDS on it.
    let (text, _) = paths_left_out("Logs are in ~/Library/Application Support/RichOS/logs/today.log now");
    assert_eq!(text, "Logs are in [a file on this Mac] now");
    let (text, _) = paths_left_out("It wrote to ~/Library/Application Support and stopped.");
    assert_eq!(text, "It wrote to [a file on this Mac] and stopped.");
}

#[test]
fn a_quoted_or_escaped_path_with_spaces_is_left_out_whole() {
    for (said, path) in [
        ("Open \"/Users/alex/My Clients/Secret Co/plan.pdf\" please", "/Users/alex/My Clients/Secret Co/plan.pdf"),
        ("Open '~/Documents/Secret Co/plan.pdf' please", "~/Documents/Secret Co/plan.pdf"),
        ("Open “~/Documents/Secret Co/plan.pdf” please", "~/Documents/Secret Co/plan.pdf"),
        ("Open `~/Library/Application Support/RichOS` please", "~/Library/Application Support/RichOS"),
        ("Open (/Users/alex/Secret Co/plan.pdf) please", "/Users/alex/Secret Co/plan.pdf"),
        ("Open /Users/alex/Secret\\ Co/plan.pdf please", "/Users/alex/Secret\\ Co/plan.pdf"),
    ] {
        let (text, was) = paths_left_out(said);
        assert_eq!(was, [path], "{said}");
        assert!(!text.contains("Secret") && !text.contains("alex"), "{said} => {text}");
    }
    // Words after a plain path are not taken with it when nothing says the path goes on.
    let (text, _) = paths_left_out("Open /Users/alex/notes.txt and then quit.");
    assert_eq!(text, "Open [a file on this Mac] and then quit.");
}

#[test]
fn an_address_after_an_emoji_is_found_on_character_boundaries() {
    // Finding 5: on the tip this panicked slicing inside the emoji's four bytes.
    let text = joined(&Scrubber::default().scrub("Mail 🐛alice@example.com"));
    assert_eq!(text, "Mail 🐛[an email address]");
    let text = joined(&Scrubber::default().scrub("Écrivez à josé.ñ@example.com — merci"));
    assert!(!text.contains("example.com"), "{text}");
}

#[test]
fn a_change_in_accented_words_is_read_on_character_boundaries() {
    // Finding 5: on the tip this panicked slicing "ééé " at byte 4, inside the second "é".
    assert_eq!(plain_change("ééé also happens in light mode").add, "Ééé also happens in light mode.");
    assert_eq!(plain_change("Ändern: it happens in light mode").add, "Ändern: it happens in light mode.");
    assert_eq!(plain_change("Also say it happens in light mode").add, "It happens in light mode.");
}
