//! The native turn loop asks `has_asked` every 40 ms while waiting for a reply. An unchanged
//! question history must not be reloaded on each ask; a new question must still be seen.
//! Own test binary: `STORE_READS` is process-wide, so no other test may run beside it.
use richos_core::question_tools::{has_asked, write_scope, Scope};
use richos_core::questions::*;
use std::sync::atomic::Ordering;

fn input() -> QuestionInput {
    QuestionInput {
        text: "When should the release ship?".into(),
        options: vec![
            OptionInput { label: "Ship today".into(), description: "Users get the fixes sooner.".into() },
            OptionInput { label: "Ship tomorrow".into(), description: "Allow another day for testing.".into() },
        ],
        multiple: false,
        free_answer: true,
        recommended: Some(1),
    }
}

#[test]
fn polling_an_unchanged_question_history_does_not_reload_it() {
    let root = std::env::temp_dir().join(format!("richos-question-poll-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&root).unwrap();
    let scope = AskScope {
        root: root.clone(),
        entity_id: "entity".into(),
        thread_id: "thread".into(),
        turn_id: "turn".into(),
        asker: "front_desk".into(),
        session_id: "s".into(),
        engine: None,
        entity_root: None,
    };
    let store = Store::new(&root);
    // History from an earlier turn, so the store file exists and has content.
    let mut earlier = scope.clone();
    earlier.turn_id = "earlier".into();
    store.ask(&earlier, vec![input()]).unwrap();
    let scope_file = root.join("turn.questions.json");
    write_scope(
        &scope_file,
        &Scope { context: scope.clone(), actions_allowed: true, answer_method: "tool".into(), surface: "test".into() },
    )
    .unwrap();

    assert!(!has_asked(&scope_file), "no question raised by this turn yet");
    let before = STORE_READS.load(Ordering::Relaxed);
    for _ in 0..50 {
        assert!(!has_asked(&scope_file));
    }
    let reloads = STORE_READS.load(Ordering::Relaxed) - before;
    assert_eq!(reloads, 0, "50 polls of an unchanged history reloaded it {reloads} times");

    // A question raised by this turn changes the file and must be seen at the next poll.
    store.ask(&scope, vec![input()]).unwrap();
    assert!(has_asked(&scope_file), "a newly raised question was not noticed");
    std::fs::remove_dir_all(&root).unwrap();
}
