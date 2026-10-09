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
        content: String::new(),
    }
}

const VERSION: &str = "RichOS 1.2.0, nightly 45 · macOS 15.6 · Apple silicon";

// ---------------------------------------------------------------------------------------
// 1. PRIVATE DETAILS ARE LEFT OUT
// ---------------------------------------------------------------------------------------

#[test]
fn names_paths_and_addresses_are_replaced_by_stand_ins_and_what_they_replaced_is_kept() {
    let scrubber = Scrubber::new(terms());
    // A path hides the rest of its LINE (since cc/echo-opus-bug7), so the other private words
    // are on a line of their own.
    let said = "In the acme deal chat, Dana Whitfield's notes at /Users/alex/ab/femcboost/notes.txt \
                and ~/Desktop/plan.md went missing.\nMail dana@northwind.example about Northwind Traders \
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
    // A path takes the rest of its sentence with it (third review; a semicolon no longer ends it
    // since review rv-20261009T151254Z-84d1bdce-20df): the words up to the full stop.
    assert!(
        replaced.contains(&("/Users/alex/ab/femcboost/notes.txt and ~/Desktop/plan.md went missing", Kind::FilePath)),
        "{replaced:?}"
    );
    assert!(replaced.contains(&("dana@northwind.example", Kind::EmailAddress)), "{replaced:?}");
    // The sentence's own full stop stays outside the stand-in.
    assert!(text.contains("notes at [a file on this Mac].\nMail [an email address]"), "{text}");
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
    let prompt = writer_prompt("names get cut off", &screen(), VERSION, &terms(), false);
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
    // One stream-json message in, so a picture can go beside the words (finding 6).
    assert!(has("--input-format", "stream-json"), "{args:?}");
    assert!(has("--output-format", "stream-json"), "{args:?}");
    assert!(args.iter().any(|a| a == "--verbose"), "stream-json output needs --verbose: {args:?}");
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
    // Since review rv-20261009T154959Z-96dcc581-085b the backticks go with it, and so does the
    // rest of its sentence: no closing mark ends a path.
    let (text, was) = paths_left_out("The file `/Users/alex/Clients/SecretCo/budget.xlsx` disappeared.");
    assert_eq!(text, "The file [a file on this Mac].");
    assert_eq!(was, ["`/Users/alex/Clients/SecretCo/budget.xlsx` disappeared"]);
}

#[test]
fn a_path_with_spaces_is_left_out_whole() {
    // Finding 1: on the tip only "/Users/alex/Client" was replaced and "Plans/SecretCo.xlsx" went public.
    // Since the third review a plain path takes the rest of its clause ("disappeared") with it.
    let (text, was) = paths_left_out("The file /Users/alex/Client Plans/SecretCo.xlsx disappeared.");
    assert_eq!(text, "The file [a file on this Mac].");
    assert_eq!(was, ["/Users/alex/Client Plans/SecretCo.xlsx disappeared"]);
    // The common Mac shape: a folder with a space in it, written plainly, and one that ENDS on it.
    let (text, _) = paths_left_out("Logs are in ~/Library/Application Support/RichOS/logs/today.log now");
    assert_eq!(text, "Logs are in [a file on this Mac]");
    let (text, _) = paths_left_out("It wrote to ~/Library/Application Support and stopped.");
    assert_eq!(text, "It wrote to [a file on this Mac].");
}

#[test]
fn a_quoted_or_escaped_path_with_spaces_is_left_out_whole() {
    // Since review rv-20261009T154959Z-96dcc581-085b the quote or bracket before a path goes with
    // it, to the end of its line (here, of the text), whatever it is written between.
    for said in [
        "Open \"/Users/alex/My Clients/Secret Co/plan.pdf\" please",
        "Open '~/Documents/Secret Co/plan.pdf' please",
        "Open “~/Documents/Secret Co/plan.pdf” please",
        "Open `~/Library/Application Support/RichOS` please",
        "Open (/Users/alex/Secret Co/plan.pdf) please",
        "Open /Users/alex/Secret\\ Co/plan.pdf please",
    ] {
        let (text, was) = paths_left_out(said);
        assert_eq!(text, "Open [a file on this Mac]", "{said}");
        assert_eq!(was, [&said[5..]], "{said}");
        assert!(!text.contains("Secret") && !text.contains("alex"), "{said} => {text}");
    }
    // Words after a plain path go with it to the end of the sentence (the third review replaced
    // the rule that kept them public): nothing in the words says where a name with spaces ends,
    // and since review rv-20261009T151254Z-84d1bdce-20df a comma does not either.
    let (text, _) = paths_left_out("Open /Users/alex/notes.txt and then quit.");
    assert_eq!(text, "Open [a file on this Mac].");
    let (text, _) = paths_left_out("Open /Users/alex/notes.txt, then quit.");
    assert_eq!(text, "Open [a file on this Mac].");
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

#[test]
fn rich_is_given_what_was_on_the_screen_and_a_picture_of_the_window_to_check_against() {
    // Finding 6: on the tip Rich had the user's words, the screen's name, settings and version,
    // and nothing that was ON the screen, so "Looked at the screen you were on" was not true.
    let mut on_screen = screen();
    on_screen.content = "Acme deal\n  what's   the status on Acme?\nNames cut off: Design RichOS memo…".into();
    let prompt = writer_prompt("the names get cut off", &on_screen, VERSION, &terms(), true);
    assert!(prompt.contains("visible words top to bottom"), "{prompt}");
    assert!(prompt.contains("what's the status on Acme?"), "the screen's words are not in the prompt: {prompt}");
    assert!(prompt.contains("Names cut off: Design RichOS memo…"));
    assert!(prompt.contains("A picture of the RichOS window"), "{prompt}");
    assert!(prompt.contains("CHECK what the user said against the screen"), "{prompt}");
    assert!(prompt.contains("\"checked\""), "{prompt}");
    // Without either, nothing claims there is something to look at.
    let blind = writer_prompt("the names get cut off", &screen(), VERSION, &terms(), false);
    assert!(!blind.contains("visible words") && !blind.contains("picture") && !blind.contains("CHECK"), "{blind}");

    // The one line on standard input: the picture as an image block, then the prompt.
    let picture = Picture { media_type: "image/jpeg".into(), base64: "/9j/4AAQ".into() };
    let line = writer_input(&prompt, Some(&picture));
    assert!(line.ends_with('\n') && line.trim_end().lines().count() == 1, "{line}");
    let message: serde_json::Value = serde_json::from_str(line.trim()).unwrap();
    assert_eq!(message["type"], "user");
    assert_eq!(message["message"]["role"], "user");
    let content = message["message"]["content"].as_array().unwrap();
    assert_eq!(content[0], serde_json::json!({ "type": "image", "source": { "type": "base64", "media_type": "image/jpeg", "data": "/9j/4AAQ" } }));
    assert_eq!(content[1], serde_json::json!({ "type": "text", "text": prompt }));
    assert_eq!(serde_json::from_str::<serde_json::Value>(writer_input("hi", None).trim()).unwrap()["message"]["content"].as_array().unwrap().len(), 1);

    // stream-json's answer: its last `result` line, as claude 2.1.295 printed it on 2026-10-09.
    let streamed = "{\"type\":\"system\",\"subtype\":\"init\"}\n{\"type\":\"assistant\",\"message\":{}}\n\
                    {\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"{\\\"color\\\": \\\"red\\\"}\"}\n";
    assert_eq!(result_text(streamed).unwrap(), "{\"color\": \"red\"}");
    assert!(result_text("{\"type\":\"system\"}\n").is_err(), "a reply with no result line is not a report");

    // The screen's words are bounded, cut on a character boundary.
    let long = "é".repeat(SCREEN_CONTENT_MAX + 50);
    let kept = screen_words(&long);
    assert!(kept.starts_with(&"é".repeat(SCREEN_CONTENT_MAX)) && kept.ends_with("[the rest of the screen is left off]"));

    // What the digest over his answer says: he looked only when he wrote it and had the screen.
    let checked = parse_written("{\"title\": \"T\", \"what_happened\": \"W\", \"checked\": \"saw the names cut off at 135%.\"}").unwrap().checked;
    assert_eq!(digest(&on_screen, true, true, &checked), "Looked at the screen you were on, at 135% text size · Saw the names cut off at 135% · Checked the version");
    assert_eq!(digest(&on_screen, false, true, &checked), "Noted the screen you were on, at 135% text size · Checked the version · Wrote it from your words");
    assert_eq!(digest(&screen(), true, false, ""), "Noted the screen you were on, at 135% text size · Checked the version");
    let mut corrections = screen();
    corrections.key = "corrections".into();
    corrections.here = "Corrections".into();
    corrections.text_size = 100;
    assert_eq!(digest(&corrections, true, true, ""), "Looked at Corrections · Checked the version");
}

#[test]
fn cancel_says_canceled_only_once_the_copy_is_gone_and_names_the_issue_when_it_went_out_first() {
    // Finding 2, fixture `change-races.js`: on the tip Cancel said "Canceled. Nothing was sent."
    // whatever the shell answered, and the shell only answered whether a file was removed.
    let dir = scratch("withdraw");
    let outbox = Outbox::open(&dir);
    let waiting = |answer: Outcome| match outbox.send(&sheet("x"), &Token(Some("t")), &FakeGitHub::answering(vec![answer]), 0).unwrap() {
        Delivery::Waiting { id, .. } => id,
        other => panic!("{other:?}"),
    };

    // Taken off this Mac: canceled, and nothing is ever tried.
    let id = waiting(Outcome::Unreachable);
    assert_eq!(outbox.withdraw(&id).unwrap(), Withdrawn::Canceled);
    assert!(outbox.pending().unwrap().is_empty());

    // A retry already sending finishes first (the shell holds one lock across both) and files
    // it: canceling then finds the issue, not "nothing was sent".
    let id = waiting(Outcome::Unreachable);
    let retry = FakeGitHub::answering(vec![Outcome::Created { number: 412, url: "u".into() }]);
    assert!(matches!(outbox.try_now(&id, &Token(Some("t")), &retry, 1).unwrap(), Some(Delivery::Sent(_))));
    match outbox.withdraw(&id).unwrap() {
        Withdrawn::AlreadySent(sent) => assert_eq!(sent.number, 412),
        other => panic!("canceled a report that went out: {other:?}"),
    }
    let said = serde_json::to_value(outbox.withdraw(&id).unwrap()).unwrap();
    assert_eq!((said["state"].as_str(), said["number"].as_u64()), (Some("sent"), Some(412)), "{said}");
    assert_eq!(serde_json::to_value(Withdrawn::Canceled).unwrap(), serde_json::json!({ "state": "canceled" }));

    // The copy cannot be removed (a folder this app may not write): an error, and it still waits.
    let id = waiting(Outcome::Unreachable);
    let folder = dir.join("waiting");
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&folder, std::fs::Permissions::from_mode(0o555)).unwrap();
    let refused = outbox.withdraw(&id);
    std::fs::set_permissions(&folder, std::fs::Permissions::from_mode(0o755)).unwrap();
    assert!(refused.is_err(), "a copy that is still on disk was reported canceled: {refused:?}");
    assert_eq!(outbox.pending().unwrap().len(), 1, "the report no longer waits");
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn a_private_name_rich_found_stays_left_out_on_every_later_change() {
    // Finding 4, fixture `core-edge-cases.py`: on the tip "Jane Doe", whom Rich named private in
    // his write-up, was left out of the draft and then went public on the first change.
    let written = Written {
        title: "Names are cut off".into(),
        what_happened: "Jane Doe saw it.".into(),
        private: vec![PrivateTerm::new("Jane Doe", Kind::PersonName)],
        ..Written::default()
    };
    let draft = draft_from(&written, VERSION, &Scrubber::default());
    assert_eq!(joined(&draft.sections[0].paragraphs[0]), "[a person] saw it.");
    assert_eq!(draft.private, vec![PrivateTerm::new("Jane Doe", Kind::PersonName)], "the card is not given the report's private words");

    // A change with none of its own private words: the report's still apply.
    let change = plain_change("Also say Jane Doe saw it in light mode too");
    let (add, kept) = scrub_change(&change, &[], &draft.private);
    assert_eq!(joined(&add), "[a person] saw it in light mode too.");
    assert_eq!(kept, draft.private);

    // Rich names another one while changing it: it is left out, and kept from then on.
    let change = parse_change(r#"{"section": "What happened", "add": "Marta and Jane Doe saw it.", "private": [{"text": "Marta", "kind": "person"}]}"#).unwrap();
    let (add, kept) = scrub_change(&change, &[], &draft.private);
    assert_eq!(joined(&add), "[a person] and [a person] saw it.");
    let (add, _) = scrub_change(&plain_change("Marta saw it again"), &[], &kept);
    assert_eq!(joined(&add), "[a person] saw it again.");
}

// ---------------------------------------------------------------------------------------
// THE THIRD REVIEW'S CASES (rv-20261009T135204Z-9f4d77d4-1892, on 9f4d77d44), fixture
// `path-cases.py`: one test per case. The rule changed here instead of growing another shape:
// from where a path starts, everything up to the end of its clause is left out.
// ---------------------------------------------------------------------------------------

#[test]
fn a_file_name_with_spaces_is_left_out_to_the_end_of_its_clause() {
    // On the tip: "The file [a file on this Mac] Budget.xlsx disappeared."
    let (text, was) = paths_left_out("The file /Users/alex/Documents/Client Budget.xlsx disappeared.");
    assert_eq!(text, "The file [a file on this Mac].");
    assert_eq!(was, ["/Users/alex/Documents/Client Budget.xlsx disappeared"]);
    let (text, _) = paths_left_out("Open ~/Documents/Client Plans please.");
    assert_eq!(text, "Open [a file on this Mac].");
    let (text, _) = paths_left_out("The file /Users/alex/Client Plans/budget.xlsx disappeared, twice.");
    assert_eq!(text, "The file [a file on this Mac].");
    // Between delimiters too, since review rv-20261009T154959Z-96dcc581-085b: the opening mark
    // goes with it and no closing mark ends it.
    let (text, was) = paths_left_out("The file `/Users/alex/Documents/Client Budget.xlsx` disappeared.");
    assert_eq!(text, "The file [a file on this Mac].");
    assert_eq!(was, ["`/Users/alex/Documents/Client Budget.xlsx` disappeared"]);
    let (text, _) = paths_left_out("Open \"/Users/alex/Smith, Jones/plan.pdf\" please.");
    assert_eq!(text, "Open [a file on this Mac].");
}

#[test]
fn a_file_url_is_left_out() {
    // On the tip it reached the report unchanged.
    let (text, was) = paths_left_out("Open file:///Users/alex/Documents/budget.xlsx please.");
    assert_eq!(text, "Open [a file on this Mac].");
    assert_eq!(was, ["file:///Users/alex/Documents/budget.xlsx please"]);
    let (text, _) = paths_left_out("It linked FILE:///Volumes/Work/Secret Co/plan.pdf; nothing opened.");
    assert_eq!(text, "It linked [a file on this Mac].");
}

#[test]
fn every_named_path_start_hides_its_clause_whatever_comes_before_it() {
    // A comma or a semicolon no longer ends what is left out (review
    // rv-20261009T151254Z-84d1bdce-20df): only a sentence end or a line break does.
    for (said, left) in [
        ("Saved to /Volumes/Backup Disk/Clients/x.xlsx, then it froze.", "Saved to [a file on this Mac]."),
        ("Temp files in /private/var/folders/ab/Secret Co stay.", "Temp files in [a file on this Mac]."),
        ("Look at /var/log/Secret Co.log: it is empty.", "Look at [a file on this Mac]."),
        ("It wrote /tmp/Secret Co notes and stopped!", "It wrote [a file on this Mac]!"),
        // The whole word with the slash in it goes, "path=" included (review
        // rv-20261009T154959Z-96dcc581-085b), as does the curly quote before a path below.
        ("The path=/Users/alex/Secret Co/x.txt; that is all.", "The [a file on this Mac]."),
        ("Windows saved C:\\Users\\alex\\Client Plans\\budget.xlsx, then closed.", "Windows saved [a file on this Mac]."),
        // "? " no longer ends it (since cc/echo-opus-bug7): the line's end does.
        ("Windows saved D:/Clients/Secret Co/budget.xlsx? Yes.", "Windows saved [a file on this Mac]."),
        ("Line one /Users/alex/Secret Co\nline two stays.", "Line one [a file on this Mac]\nline two stays."),
        ("It said “/Users/alex/Rich’s notes.txt” twice.", "It said [a file on this Mac]."),
        ("It opened /Users/alex/Rich's notes.txt, then froze.", "It opened [a file on this Mac]."),
    ] {
        let (text, _) = paths_left_out(said);
        assert_eq!(text, left, "{said}");
    }
    // A web address, "and/or" and "24/7" are not paths. "Note:/x" is one since review
    // rv-20261009T154959Z-96dcc581-085b: a word with a slash is a path unless it is a short form.
    let said = "See https://example.com/a/b and/or 24/7, or Note:/x.";
    assert_eq!(paths_left_out(said).0, "See https://example.com/a/b and/or 24/7, or [a file on this Mac].");
}

#[test]
fn a_short_home_path_does_not_panic() {
    // Finding 4: on the tip both panicked in debug builds (an unsigned subtraction underflowed).
    let (text, _) = paths_left_out("~/a disappeared.");
    assert_eq!(text, "[a file on this Mac].");
    let (text, _) = paths_left_out("~/foo won't open.");
    assert_eq!(text, "[a file on this Mac].");
    let (text, _) = paths_left_out("~/a");
    assert_eq!(text, "[a file on this Mac]");
}

// ---- the fourth review's cases (rv-20261009T142223Z-3d74fe4c-3b6d, on 3d74fe4cb) ----

/// `text` scrubbed with `terms`: the public words, and what each stand-in replaced.
fn scrubbed_with(terms: Vec<PrivateTerm>, text: &str) -> (String, Vec<String>) {
    let segments = Scrubber::new(terms).scrub(text);
    let public = segments.iter().map(|s| s.text.as_str()).collect();
    (public, segments.iter().filter_map(|s| s.was.clone()).collect())
}

#[test]
fn a_private_name_in_other_capitals_is_left_out_in_every_alphabet() {
    // Finding 1, fixture `privacy-probe.py`: on the tip the case folding was ASCII-only, so each
    // of these stayed in the public report word for word.
    let company = |t: &str| vec![PrivateTerm::new(t, Kind::CompanyName)];
    let person = |t: &str| vec![PrivateTerm::new(t, Kind::PersonName)];
    let a_company = Kind::CompanyName.stand_in();
    let a_person = Kind::PersonName.stand_in();
    for (terms, said, public, was) in [
        (company("Café North"), "The CAFÉ NORTH window froze.", format!("The {a_company} window froze."), "CAFÉ NORTH"),
        (person("Zoë Kim"), "ZOË KIM saw it too.", format!("{a_person} saw it too."), "ZOË KIM"),
        (company("CAFÉ NORTH"), "The café north window froze.", format!("The {a_company} window froze."), "café north"),
        // A capital-only spelling that is longer than the name: "ß" is written "SS" in capitals.
        (company("Straße Partners"), "Ask STRASSE PARTNERS, then retry.", format!("Ask {a_company}, then retry."), "STRASSE PARTNERS"),
        (company("Ωmega Σystems"), "The ωmega σystems sync stopped.", format!("The {a_company} sync stopped."), "ωmega σystems"),
        // A one-word Capitalized name is still matched only where it is written with a capital.
        (person("Zoë"), "ZOË saw it; zoë is also a word here.", format!("{a_person} saw it; zoë is also a word here."), "ZOË"),
    ] {
        let (text, left) = scrubbed_with(terms, said);
        assert_eq!(text, public, "{said}");
        assert_eq!(left, vec![was.to_string()], "{said}: the stand-in does not replace the words as written");
    }
    // Accents are letters, not case: "Cafe North" is not "Café North".
    assert_eq!(scrubbed_with(company("Café North"), "The Cafe North menu.").0, "The Cafe North menu.");
    // A name in other capitals is one term, not two.
    let both = vec![PrivateTerm::new("Café North", Kind::CompanyName), PrivateTerm::new("CAFÉ NORTH", Kind::CompanyName)];
    assert_eq!(Scrubber::new(both).terms().len(), 1);
}

#[test]
fn the_heads_up_on_the_users_own_words_is_the_scrubbers_answer() {
    // Finding 2, fixture `email-warning.js`: on the tip the window's own ASCII-only copy of the
    // rules gave no heads-up for an address the scrubber leaves out. The window now asks this.
    let app = terms();
    let report = vec![PrivateTerm::new("Jane Doe", Kind::PersonName)];
    // One line per path: a path hides the rest of its line (since cc/echo-opus-bug7), so each
    // other private word is on a line of its own.
    let said = "Write to alice@büro.de or 用户@例子.中国 about the NORTHWIND TRADERS file file:///Users/you/Secret.xlsx.\nThen C:\\Users\\you\\notes.txt.\nFrom JANE DOE.";
    let found = private_in_edit(said, &app, &report);
    for private in ["alice@büro.de", "用户@例子.中国", "NORTHWIND TRADERS", "file:///Users/you/Secret.xlsx", "C:\\Users\\you\\notes.txt", "JANE DOE"] {
        assert!(found.iter().any(|f| f == private), "{private:?} gets no heads-up: {found:?}");
    }
    // Every word the heads-up names is one the report would leave out, and nothing else.
    let scrubbed = Scrubber::new(app.iter().chain(&report).cloned().collect()).scrub(said);
    let left_out: Vec<String> = scrubbed.iter().filter_map(|s| s.was.clone()).collect();
    assert_eq!(found, left_out);
    assert!(private_in_edit("The names on the left get cut off.", &app, &report).is_empty());
}

// ---- the review of 84d1bdced (rv-20261009T151254Z-84d1bdce-20df), fixture `privacy-probe.py` ----

#[test]
fn a_comma_semicolon_or_bracket_in_a_file_name_does_not_end_what_is_left_out() {
    // Finding 1: on the tip a comma or a semicolon ended the path, so the rest of the file's name
    // went public: "Open [a file on this Mac], Jones Budget.xlsx please." Now only a sentence end
    // (outside the file's own extension) or a line break ends it.
    for (said, was) in [
        ("Open /Users/alex/Documents/Smith, Jones Budget.xlsx please.", "/Users/alex/Documents/Smith, Jones Budget.xlsx please"),
        ("Open ~/Documents/Client;Secret Budget.xlsx please.", "~/Documents/Client;Secret Budget.xlsx please"),
        ("Open /Users/alex/Documents/Budget (SecretClient).xlsx please.", "/Users/alex/Documents/Budget (SecretClient).xlsx please"),
        ("Open /Users/alex/Documents/SecretClient.xlsx please.", "/Users/alex/Documents/SecretClient.xlsx please"),
    ] {
        let (text, left) = paths_left_out(said);
        assert_eq!(text, "Open [a file on this Mac].", "{said}");
        assert_eq!(left, [was], "{said}");
    }
    // A sentence end no longer ends it (since cc/echo-opus-bug7: ". " can be inside a file's
    // name); a line break does.
    let (text, _) = paths_left_out("Open /Users/alex/Smith, Jones.xlsx. Then it froze.");
    assert_eq!(text, "Open [a file on this Mac].");
    let (text, _) = paths_left_out("Open ~/Smith; Jones.xlsx\nThen it froze.");
    assert_eq!(text, "Open [a file on this Mac]\nThen it froze.");
}

#[test]
fn private_details_that_overlap_are_left_out_together() {
    // Finding 1: on the tip a span that started inside an earlier one was dropped whole, so its
    // part past the earlier one's end stayed public.
    let person = |t: &str| PrivateTerm::new(t, Kind::PersonName);
    let (text, left) = scrubbed_with(vec![person("Mary Jane"), person("Jane Smith")], "Mary Jane Smith saw it.");
    assert_eq!(text, "[a person] saw it.");
    assert_eq!(left, ["Mary Jane Smith"]);
    // A company name that starts inside a path and runs past where the path ends. Since
    // cc/echo-opus-bug7 a path runs to the end of its line, so the one place left to run past is
    // the line's final full stop, which the path keeps outside.
    let company = vec![PrivateTerm::new("Acme Inc. Partners", Kind::CompanyName)];
    let (text, left) = scrubbed_with(company, "Open ~/Clients/Acme Inc. Partners plan now.");
    assert_eq!(text, "Open [a file on this Mac].");
    assert_eq!(left, ["~/Clients/Acme Inc. Partners plan now"]);
    let company = vec![PrivateTerm::new("Acme Inc.", Kind::CompanyName)];
    let (text, left) = scrubbed_with(company, "Open ~/Clients/Acme Inc.");
    assert_eq!(text, "Open [a file on this Mac]");
    assert_eq!(left, ["~/Clients/Acme Inc."]);
    // The fixture's registered company inside a path: all of it is left out, and the heads-up
    // on what is left finds nothing (on the tip it found nothing on a draft that still leaked).
    let known = Scrubber::new(vec![PrivateTerm::new("Smith, Jones", Kind::CompanyName)]);
    let said = "Open /Users/alex/Documents/Smith, Jones Budget.xlsx please.";
    let public = joined(&known.scrub(said));
    assert_eq!(public, "Open [a file on this Mac].");
    assert_eq!(known.private_in(said), ["/Users/alex/Documents/Smith, Jones Budget.xlsx please"]);
    assert!(known.private_in(&public).is_empty(), "{public}");
}

// ---- the fifth review of cc/echo-opus-bug6 (rv-20261009T154959Z-96dcc581-085b, on 96dcc5813),
// fixture `path-delimiters.py`. Rounds kept finding one more shape a path could take, so the rule
// no longer recognizes shapes: any word with a slash or a backslash in it is a path, except a web
// address and a short common form ("and/or", "24/7", a date), and it is left out from the start of
// that word, bracket or quote included, to the end of its sentence or line.

#[test]
fn a_bracketed_file_name_with_brackets_inside_is_left_out_whole() {
    // Finding 1: on the tip the first closing bracket ended the path, so the public report read
    // "Open ([a file on this Mac]) SecretClient.xlsx) please." with no heads-up.
    for said in [
        "Open (/Users/alex/Documents/Budget (draft) SecretClient.xlsx) please.",
        "Open [/Users/alex/Documents/Budget [draft] SecretClient.xlsx] please.",
        "Open (/Users/alex/Documents/Budget [draft (v2)] SecretClient.xlsx) please.",
    ] {
        let (text, was) = paths_left_out(said);
        assert_eq!(text, "Open [a file on this Mac].", "{said}");
        assert_eq!(was, [&said[5..said.len() - 1]], "{said}");
        assert!(Scrubber::default().private_in(&text).is_empty(), "{text}");
    }
}

#[test]
fn a_relative_file_path_is_left_out_and_gets_a_heads_up() {
    // Finding 2: on the tip both reached the public report unchanged, with no heads-up.
    let (text, was) = paths_left_out("Open `./clients/SecretClient/budget.xlsx` please.");
    assert_eq!(text, "Open [a file on this Mac].");
    assert_eq!(was, ["`./clients/SecretClient/budget.xlsx` please"]);
    let (text, was) = paths_left_out("The file clients/SecretClient/budget.xlsx disappeared.");
    assert_eq!(text, "The file [a file on this Mac].");
    assert_eq!(was, ["clients/SecretClient/budget.xlsx disappeared"]);
    // Every other way a path is written: up a folder, the home folder, a Windows drive or folder.
    for said in ["Open ../SecretClient/plan.pdf now.", "Open ~/SecretClient now.", "Open C:\\SecretClient now.", "Open SecretClient\\plan.pdf now."] {
        let (text, _) = paths_left_out(said);
        assert_eq!(text, "Open [a file on this Mac].", "{said}");
    }
    // The heads-up on the user's own words is the same scrubber's answer, so it names them too.
    let found = private_in_edit("The file clients/SecretClient/budget.xlsx disappeared.", &[], &[]);
    assert_eq!(found, ["clients/SecretClient/budget.xlsx disappeared"]);
}

#[test]
fn short_common_slash_forms_and_web_addresses_stay_public() {
    let said = "Use it and/or the menu 24/7 since 10/09 and on 10/09/2026, (and/or) see https://example.com/a/b please.";
    assert_eq!(paths_left_out(said).0, said);
    assert!(Scrubber::default().private_in(said).is_empty(), "{said}");
}

// ---- the two leaks cc/echo-opus-bug7 left open (on 1e7b696cf) ----
// A path is left out to the end of its LINE: ". " inside a file's name ("Dr. SecretClient") does
// not end it. And a word with a slash is a path unless it is on a short fixed list.

#[test]
fn a_full_stop_inside_a_file_name_does_not_end_what_is_left_out() {
    // On 1e7b696cf: "Open [a file on this Mac]. SecretClient Budget.xlsx please."
    let said = "Open /Users/alex/Documents/Dr. SecretClient Budget.xlsx please.";
    let (text, was) = paths_left_out(said);
    assert_eq!(text, "Open [a file on this Mac].");
    assert_eq!(was, ["/Users/alex/Documents/Dr. SecretClient Budget.xlsx please"]);
    assert!(Scrubber::default().private_in(&text).is_empty(), "{text}");
    // The same with "!" or "?" in the name, and the line's own "!" or "?" kept outside.
    let (text, _) = paths_left_out("Open ~/Clients/Wow! SecretCo plan.pdf now!");
    assert_eq!(text, "Open [a file on this Mac]!");
    let (text, _) = paths_left_out("Where is ~/Clients/Why? SecretCo plan.pdf now?");
    assert_eq!(text, "Where is [a file on this Mac]?");
    // A line break still ends it, so the next line stays public.
    let (text, _) = paths_left_out("Open ~/Dr. SecretClient.xlsx please.\nThen it froze.");
    assert_eq!(text, "Open [a file on this Mac].\nThen it froze.");
    let (text, _) = paths_left_out("Open ~/Dr. SecretClient.xlsx please.\r\nThen it froze.");
    assert_eq!(text, "Open [a file on this Mac].\r\nThen it froze.");
}

#[test]
fn two_plain_words_with_a_slash_are_a_path() {
    // On 1e7b696cf: "Clients/SecretCo" was read as a short form like "and/or" and stayed public.
    let (text, was) = paths_left_out("The folder Clients/SecretCo is gone.");
    assert_eq!(text, "The folder [a file on this Mac].");
    assert_eq!(was, ["Clients/SecretCo is gone"]);
    for said in ["Open SecretCo/plan now.", "Open (Clients/SecretCo) now.", "Open AND/OR/SecretCo now.", "Open w/SecretCo now.", "Open 10/SecretCo now."] {
        assert_eq!(paths_left_out(said).0, "Open [a file on this Mac].", "{said}");
    }
}

#[test]
fn the_fixed_list_of_slash_forms_stays_public() {
    let said = "Use it and/or the menu w/ a key, w/o a mouse, n/a here, 24/7, 1/2 of it, since 10/09 \
                and on 10/09/2026; AND/OR N/A W/O (and/or) see https://example.com/a/b or HTTP://x.org/y please.";
    assert_eq!(paths_left_out(said).0, said);
    assert!(Scrubber::default().private_in(said).is_empty(), "{said}");
}
