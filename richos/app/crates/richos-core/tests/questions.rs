use richos_core::questions::*;
use std::path::PathBuf;
struct Fixture {
    root: PathBuf,
    scope: AskScope,
    store: Store,
}
impl Fixture {
    fn new() -> Self {
        let root =
            std::env::temp_dir().join(format!("richos-questions-test-{}", uuid::Uuid::new_v4()));
        let scope = AskScope {
            root: root.clone(),
            entity_id: "entity".into(),
            thread_id: "thread".into(),
            turn_id: "turn".into(),
            asker: "front_desk".into(),
            session_id: "original-session".into(),
            engine: None,
            entity_root: None,
        };
        Self {
            store: Store::new(&root),
            root,
            scope,
        }
    }
    fn ask(&self, n: usize) -> Vec<Question> {
        self.store
            .ask(
                &self.scope,
                (0..n)
                    .map(|_| QuestionInput {
                        text: "When should the release ship?".into(),
                        options: vec![
                            OptionInput {
                                label: "Ship today".into(),
                                description: "Users get the fixes sooner.".into(),
                            },
                            OptionInput {
                                label: "Ship tomorrow".into(),
                                description: "Allow another day for testing.".into(),
                            },
                        ],
                        multiple: false,
                        free_answer: true,
                        recommended: Some(1),
                    })
                    .collect(),
            )
            .unwrap()
    }
    fn answer(
        &self,
        q: &Question,
        key: &str,
        choice: usize,
        revision: Option<u64>,
    ) -> AnswerResult {
        self.store
            .answer(
                "entity",
                "thread",
                AnswerRequest {
                    question_id: q.id.clone(),
                    client_id: key.into(),
                    option_ids: vec![q.options[choice].id.clone()],
                    text: String::new(),
                    expected_revision: revision,
                },
                "click",
                "mac",
            )
            .unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        drop(std::fs::remove_dir_all(&self.root));
    }
}

#[test]
fn plain_and_spoken_rendering_names_the_same_asker_as_the_card() {
    let mut f = Fixture::new();
    let front = f.ask(1).remove(0);
    assert!(front.render().contains("Rich recommends Ship tomorrow"));
    f.scope.asker = "assignment-1".into();
    let team = f.ask(1).remove(0);
    assert_eq!(team.public_value()["asker"], "Your team");
    assert!(team.render().starts_with("Your team, through Rich\n"));
    assert!(team.render().contains("Your team recommends Ship tomorrow"));
}
#[test]
fn partial_sets_wait_then_deliver_once_with_every_answer() {
    let f = Fixture::new();
    let qs = f.ask(2);
    f.answer(&qs[0], "first", 0, None);
    assert!(f.store.pending_threads().unwrap().is_empty());
    let second = AnswerRequest {
        question_id: qs[1].id.clone(),
        client_id: "phone".into(),
        option_ids: vec![],
        text: "Next Tuesday".into(),
        expected_revision: None,
    };
    f.store
        .answer("entity", "thread", second, "phone_voice", "phone")
        .unwrap();
    let mut texts = vec![];
    assert_eq!(
        f.store
            .deliver("entity", "thread", "front_desk", |d| {
                texts.push(d.text.clone());
                Ok("durable-turn".into())
            })
            .unwrap(),
        1
    );
    assert!(texts[0].contains("Ship today"));
    assert!(texts[0].contains("Next Tuesday"));
    assert!(texts[0].contains("phone_voice on phone"));
    assert_eq!(
        f.store
            .deliver("entity", "thread", "front_desk", |_| panic!("duplicate"))
            .unwrap(),
        0
    );
    assert!(f
        .store
        .list("entity", "thread")
        .unwrap()
        .iter()
        .all(|q| q.delivered));
}
#[test]
fn withdrawal_resolves_partial_set_but_all_withdrawn_starts_nothing() {
    let f = Fixture::new();
    let qs = f.ask(2);
    f.answer(&qs[0], "a", 0, None);
    f.store
        .withdraw(
            "entity",
            "thread",
            "front_desk",
            &qs[1].id,
            "The deadline changed",
        )
        .unwrap();
    f.store
        .deliver("entity", "thread", "front_desk", |d| {
            assert!(d.text.contains("The deadline changed"));
            Ok("turn".into())
        })
        .unwrap();
    let qs = f.ask(2);
    for q in qs {
        f.store
            .withdraw("entity", "thread", "front_desk", &q.id, "No longer needed")
            .unwrap();
    }
    assert!(f.store.pending_threads().unwrap().is_empty());
}
#[test]
fn first_answer_wins_conflicts_become_words_and_retries_do_not_duplicate() {
    let f = Fixture::new();
    let q = f.ask(1).remove(0);
    let accepted = f.answer(&q, "mac", 0, None);
    assert_eq!(accepted.outcome, "accepted");
    assert_eq!(f.answer(&q, "mac", 0, None).outcome, "accepted");
    assert_eq!(
        f.answer(&q, "other-phone", 0, None).outcome,
        "already_answered"
    );
    assert_eq!(f.answer(&q, "conflict", 1, None).outcome, "conflict");
    f.answer(&q, "conflict", 1, None);
    let mut n = 0;
    f.store
        .deliver("entity", "thread", "front_desk", |_| {
            n += 1;
            Ok("saved".into())
        })
        .unwrap();
    assert_eq!(n, 2);
    assert_eq!(
        f.store.list("entity", "thread").unwrap()[0]
            .answer
            .as_ref()
            .unwrap()
            .option_ids,
        vec![q.options[0].id.clone()]
    );
}
#[test]
fn explicit_revision_edit_only_before_handoff() {
    let f = Fixture::new();
    let q = f.ask(1).remove(0);
    f.answer(&q, "initial", 0, None);
    assert_eq!(f.answer(&q, "edit", 1, Some(1)).outcome, "accepted");
    let mut id = String::new();
    assert!(f
        .store
        .deliver("entity", "thread", "front_desk", |d| {
            id = d.id.clone();
            Err("receiver unavailable".into())
        })
        .is_err());
    assert_eq!(f.answer(&q, "late-edit", 0, Some(2)).outcome, "conflict");
    let reopened = Store::new(&f.root);
    let mut seen = vec![];
    reopened
        .deliver("entity", "thread", "front_desk", |d| {
            seen.push(d.id.clone());
            if d.id == id {
                assert!(d.text.contains("Ship tomorrow"));
            }
            Ok("durable".into())
        })
        .unwrap();
    assert!(seen.contains(&id));
    assert_eq!(seen.len(), 2);
}
#[test]
fn simultaneous_submissions_keep_exactly_one_answer() {
    let f = Fixture::new();
    let q = f.ask(1).remove(0);
    let barrier = std::sync::Arc::new(std::sync::Barrier::new(2));
    let handles: Vec<_> = (0..2)
        .map(|i| {
            let store = f.store.clone();
            let q = q.clone();
            let b = barrier.clone();
            std::thread::spawn(move || {
                b.wait();
                store
                    .answer(
                        "entity",
                        "thread",
                        AnswerRequest {
                            question_id: q.id,
                            client_id: format!("phone-{i}"),
                            option_ids: vec![q.options[i].id.clone()],
                            text: "".into(),
                            expected_revision: None,
                        },
                        "phone_tap",
                        "phone",
                    )
                    .unwrap()
                    .outcome
            })
        })
        .collect();
    let mut outcomes: Vec<_> = handles.into_iter().map(|h| h.join().unwrap()).collect();
    outcomes.sort();
    assert_eq!(outcomes, vec!["accepted", "conflict"]);
}
#[test]
fn deleted_conversation_cancels_delivery_and_keeps_late_words_on_sender() {
    let f = Fixture::new();
    let q = f.ask(1).remove(0);
    f.answer(&q, "first", 0, None);
    f.store
        .close("entity", "thread", None, "Conversation deleted", true)
        .unwrap();
    assert_eq!(
        f.answer(&q, "late", 1, None).outcome,
        "conversation_deleted"
    );
    assert!(f.store.pending_threads().unwrap().is_empty());
    assert_eq!(
        f.store
            .deliver("entity", "thread", "front_desk", |_| panic!(
                "deleted target restarted"
            ))
            .unwrap(),
        0
    );
}
#[test]
fn scope_and_voice_safe_validation_fail_before_persisting() {
    let f = Fixture::new();
    let q = f.ask(1).remove(0);
    let request = AnswerRequest {
        question_id: q.id.clone(),
        client_id: "x".into(),
        option_ids: vec![q.options[0].id.clone()],
        text: "".into(),
        expected_revision: None,
    };
    assert!(f
        .store
        .answer("other", "thread", request, "typed", "mac")
        .is_err());
    assert!(f
        .store
        .withdraw("entity", "thread", "other-asker", &q.id, "Reason")
        .is_err());
    let bad = QuestionInput {
        text: "When?".into(),
        options: vec![
            OptionInput {
                label: "I'll do it".into(),
                description: "Actor ambiguous".into(),
            },
            OptionInput {
                label: "Tomorrow".into(),
                description: "Wait".into(),
            },
        ],
        multiple: false,
        free_answer: true,
        recommended: None,
    };
    assert!(f.store.ask(&f.scope, vec![bad]).is_err());
    assert_eq!(f.store.all().unwrap().len(), 1);
    assert!(q.public_value().get("session_id").is_none());
}
#[test]
fn mixed_words_tool_result_is_durable_and_replayed_without_a_second_turn() {
    use richos_core::question_tools::{self, Scope};
    use serde_json::json;
    let f = Fixture::new();
    let qs = f.ask(2);
    f.answer(&qs[0], "tap", 0, None);
    let path = f.root.join("scope.json");
    std::fs::create_dir_all(&f.root).unwrap();
    question_tools::write_scope(
        &path,
        &Scope {
            context: f.scope.clone(),
            actions_allowed: true,
            answer_method: "phone_voice".into(),
            surface: "phone".into(),
        },
    )
    .unwrap();
    let args = json!({"question_id":qs[1].id,"client_id":"words","text":"Next Tuesday"});
    let answer = question_tools::call(&path, "answer", args.clone()).unwrap();
    let result = answer["complete_sets"][0].as_str().unwrap();
    assert!(result.contains("Ship today"));
    assert!(result.contains("Next Tuesday"));
    assert!(result.contains("phone_voice on phone"));
    assert_eq!(
        question_tools::call(&path, "answer", args).unwrap()["complete_sets"],
        answer["complete_sets"]
    );
    assert_eq!(
        Store::new(&f.root)
            .deliver("entity", "thread", "front_desk", |_| panic!("second turn"))
            .unwrap(),
        0
    );
}
#[test]
fn work_receiving_inbox_deduplicates_an_uncertain_handoff() {
    let f = Fixture::new();
    let q = f.ask(1).remove(0);
    f.answer(&q, "tap", 0, None);
    let deliver = |d: &Delivery| {
        richos_core::question_work::enqueue(&f.root, d).unwrap();
        Err("crash before sender receipt".into())
    };
    assert!(f
        .store
        .deliver("entity", "thread", "front_desk", deliver)
        .is_err());
    Store::new(&f.root)
        .deliver("entity", "thread", "front_desk", |d| {
            richos_core::question_work::enqueue(&f.root, d)?;
            Ok(d.id.clone())
        })
        .unwrap();
    assert_eq!(
        richos_core::question_work::pending(&f.root).unwrap().len(),
        1
    );
    let input =
        richos_core::question_work::take(&f.root, "entity", "thread", "front_desk").unwrap();
    assert_eq!(input.len(), 1);
    assert!(
        richos_core::question_work::take(&f.root, "entity", "thread", "front_desk")
            .unwrap()
            .is_empty()
    );
    assert!(!richos_core::question_work::enqueue(&f.root, &input[0]).unwrap());
}
#[test]
fn notifications_are_once_per_set_even_after_answer_changes() {
    let f = Fixture::new();
    let qs = f.ask(4);
    let mut sent = vec![];
    f.store
        .notify_sets(|q| {
            sent.push(q.id.clone());
            Ok(true)
        })
        .unwrap();
    assert_eq!(sent.len(), 1);
    f.answer(&qs[0], "a", 0, None);
    Store::new(&f.root)
        .notify_sets(|_| panic!("answer triggered another notification"))
        .unwrap();
}
#[test]
fn actual_engine_witness_requires_display_and_preserves_original_session() {
    let mut f = Fixture::new();
    let seat = f.root.join("seat");
    std::fs::create_dir_all(seat.join("wiki")).unwrap();
    std::fs::write(seat.join(".ceo-todos"),"TODO_RECORD=\"wiki/open-items.md\"\nTODO_VIEW=\"CEO-TODOs.md\"\nROOT_README=\"README.md\"\nCEO_SECTIONS=\"1 2\"\nPREPARER_SECTION=\"3\"\nARTIFACT_ROOTS=\"q=.\"\n").unwrap();
    std::fs::write(
        seat.join("orchestration.config"),
        "CEO_RULINGS_PATHS=\"wiki/ceo-decisions.md\"\n",
    )
    .unwrap();
    std::fs::write(seat.join("wiki/ceo-decisions.md"),"# Decisions\n\n## 1. Typeface (CEO, 2026-09-01)\n\n**His words:** Newsreader and Inter are approved for the product.\n").unwrap();
    std::fs::write(seat.join("README.md"), "# Test seat\n").unwrap();
    std::fs::write(seat.join("CEO-TODOs.md"), "# View\n").unwrap();
    std::fs::write(seat.join("wiki/open-items.md"),"# Open items\n\n## 1. Waiting on the CEO\n\n### 1.1 READY-FOR-CEO — Release shipping schedule\n\n- **Open:** `q/wiki/release.md`\n- **Time:** 5 minutes\n- **Done:** shipping day chosen\n- **Unblocks:** release shipping\n\n## 2. Waiting on the CEO\n\n## 3. Buildable\n").unwrap();
    let engine = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../engine")
        .canonicalize()
        .unwrap();
    f.scope.engine = Some(engine);
    f.scope.entity_root = Some(seat.clone());
    let input:QuestionInput=serde_json::from_value(serde_json::json!({"text":"When should the release ship?\npremise-unverified: This test fixture has no production deadline.","options":[{"label":"Today","description":"Earlier fixes"},{"label":"Tomorrow","description":"More tests"}]})).unwrap();
    let q = f.store.ask(&f.scope, vec![input]).unwrap().remove(0);
    let ledger = seat.join(".claude/state/ceo-asks.jsonl");
    assert!(!ledger.exists(), "persistence is not display");
    f.store
        .acknowledge("entity", "thread", &q.id, "phone")
        .unwrap();
    f.store.flush_witnesses().unwrap();
    let text = std::fs::read_to_string(&ledger).unwrap();
    let record: serde_json::Value = serde_json::from_str(text.trim()).unwrap();
    assert_eq!(record["session_id"], "original-session");
    assert_eq!(record["app_question_id"], q.id);
    f.store
        .acknowledge("entity", "thread", &q.id, "mac")
        .unwrap();
    assert_eq!(std::fs::read_to_string(&ledger).unwrap().lines().count(), 1);
    // Simulate a crash after the engine append but before the app saved its receipt.
    let path = f.root.join("questions/store.json");
    let mut data: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    data["questions"][0]["shown"]["witness_written"] = serde_json::json!(false);
    std::fs::write(path, serde_json::to_vec(&data).unwrap()).unwrap();
    Store::new(&f.root).flush_witnesses().unwrap();
    assert_eq!(std::fs::read_to_string(&ledger).unwrap().lines().count(), 1);
}
#[test]
fn witness_failure_keeps_display_ack_for_recovery() {
    let mut f = Fixture::new();
    std::fs::create_dir_all(f.root.join("engine/scripts/hooks")).unwrap();
    std::fs::write(
        f.root.join("engine/scripts/hooks/guard-ceo-ruled-ask.sh"),
        "exit 0\n",
    )
    .unwrap();
    std::fs::write(
        f.root.join("engine/scripts/hooks/notice-ceo-asks.sh"),
        "exit 0\n",
    )
    .unwrap();
    f.scope.engine = Some(f.root.join("engine"));
    f.scope.entity_root = Some(f.root.clone());
    let q = f.ask(1).remove(0);
    f.store
        .acknowledge("entity", "thread", &q.id, "mac")
        .unwrap();
    assert!(
        f.store.flush_witnesses().is_err(),
        "exit zero is not a witness"
    );
    assert!(
        !Store::new(&f.root).all().unwrap()[0]
            .shown
            .as_ref()
            .unwrap()
            .witness_written
    );
}

#[test]
fn idle_delivery_and_duplicate_receipts_do_not_rewrite_history() {
    use std::os::unix::fs::MetadataExt;
    let f = Fixture::new();
    let q = f.ask(1).remove(0);
    f.store
        .acknowledge("entity", "thread", &q.id, "mac")
        .unwrap();
    let path = f.root.join("questions/store.json");
    let inode = std::fs::metadata(&path).unwrap().ino();
    f.store
        .acknowledge("entity", "thread", &q.id, "phone")
        .unwrap();
    f.store
        .deliver("entity", "thread", "front_desk", |_| {
            panic!("open question delivered")
        })
        .unwrap();
    assert_eq!(
        std::fs::metadata(&path).unwrap().ino(),
        inode,
        "no-op triggered a file watcher event"
    );
    f.answer(&q, "a", 0, None);
    assert!(f
        .store
        .deliver("entity", "thread", "front_desk", |_| Err("offline".into()))
        .is_err());
    let inode = std::fs::metadata(&path).unwrap().ino();
    assert!(f
        .store
        .deliver("entity", "thread", "front_desk", |_| Err("offline".into()))
        .is_err());
    assert_eq!(
        std::fs::metadata(&path).unwrap().ino(),
        inode,
        "failed retry triggered another retry"
    );
}
#[test]
fn waiting_at_reply_boundary_is_distinct_from_delivered() {
    let f = Fixture::new();
    let q = f.ask(1).remove(0);
    f.answer(&q, "a", 0, None);
    let queued = f
        .store
        .waiting_for_turn("entity", "thread", &q.id, true)
        .unwrap()
        .unwrap();
    assert!(queued.waiting_for_turn);
    assert!(!queued.delivered);
    assert!(!queued.handoff_started);
    f.store
        .deliver("entity", "thread", "front_desk", |_| Ok("received".into()))
        .unwrap();
    let delivered = f
        .store
        .waiting_for_turn("entity", "thread", &q.id, true)
        .unwrap()
        .unwrap();
    assert!(!delivered.waiting_for_turn);
    assert!(delivered.delivered);
}

#[test]
fn a_guard_that_never_reads_large_input_cannot_hold_the_vendor_fallback() {
    let mut f = Fixture::new();
    std::fs::create_dir_all(f.root.join("engine/scripts/hooks")).unwrap();
    std::fs::write(
        f.root.join("engine/scripts/hooks/guard-ceo-ruled-ask.sh"),
        "sleep 3\n",
    )
    .unwrap();
    f.scope.engine = Some(f.root.join("engine"));
    f.scope.entity_root = Some(f.root.clone());
    let input:QuestionInput=serde_json::from_value(serde_json::json!({"text":"x".repeat(4096),"options":[{"label":"Today","description":"x".repeat(2048)},{"label":"Tomorrow","description":"y".repeat(2048)},{"label":"Tuesday","description":"z".repeat(2048)},{"label":"Wednesday","description":"z".repeat(2048)}]})).unwrap();
    let start = std::time::Instant::now();
    assert!(f
        .store
        .ask_bounded(
            &f.scope,
            vec![input; 4],
            std::time::Duration::from_millis(100)
        )
        .is_err());
    assert!(start.elapsed() < std::time::Duration::from_secs(1));
    assert!(f.store.all().unwrap().is_empty());
}

#[test]
fn residency_snapshot_keeps_open_and_pending_answers_without_waiting_on_store_lock() {
    let f = Fixture::new();
    assert!(!f.store.pending_for_residency().unwrap());
    let q = f.ask(1).remove(0);
    let lock = std::fs::OpenOptions::new().read(true).write(true)
        .open(f.root.join("questions/lock")).unwrap();
    lock.lock().unwrap();
    assert!(f.store.pending_for_residency().unwrap());
    lock.unlock().unwrap();
    f.answer(&q, "phone-offline-answer", 0, None);
    assert!(f.store.pending_for_residency().unwrap());
    f.store.deliver("entity", "thread", "front_desk", |_| Ok("receipt".into())).unwrap();
    assert!(!f.store.pending_for_residency().unwrap());
    let withdrawn = f.ask(1).remove(0);
    f.store.withdraw("entity", "thread", "front_desk", &withdrawn.id, "No longer needed").unwrap();
    assert!(!f.store.pending_for_residency().unwrap());
    std::fs::write(f.root.join("questions/store.json"), b"broken").unwrap();
    assert!(f.store.pending_for_residency().is_err());
}
