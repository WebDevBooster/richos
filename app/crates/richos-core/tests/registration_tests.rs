use richos_core::{autonomy::Handoff, registration::*};
fn value(intent: Intent, committed: bool) -> Registration {
    Registration {
        intent,
        rich_committed: committed,
        request_quote: "CEO".into(),
        reply_quote: "Rich".into(),
        scope_complete: true,
        target_run_id: None,
    }
}

#[test]
fn neither_false_none_nor_unaccepted_work_crosses_the_consistency_floor() {
    assert!(validate(value(Intent::Discussion, true), "CEO", "Rich", "", &[]).is_err());
    assert!(validate(value(Intent::Work, false), "CEO", "Rich", "", &[]).is_err());
    assert!(matches!(
        validate(value(Intent::Discussion, false), "CEO", "Rich", "", &[])
            .unwrap()
            .0,
        Handoff::None
    ));
    assert!(validate(value(Intent::Unclear, false), "CEO", "Rich", "", &[]).is_err());
}
#[test]
fn registration_cannot_fabricate_quotes_or_missing_targets() {
    assert!(validate(
        value(Intent::Work, true),
        "not the message",
        "Rich",
        "",
        &[]
    )
    .is_err());
    for intent in [Intent::Amend, Intent::AnswerDecision, Intent::Cancel] {
        assert!(validate(value(intent, true), "CEO", "Rich", "", &[]).is_err());
    }
    let mut v = value(Intent::Work, true);
    v.target_run_id = Some("invented".into());
    assert!(validate(v, "CEO", "Rich", "", &[]).is_err());
}
#[test]
fn the_contract_preserves_every_byte_including_negative_constraints_and_tail() {
    let request = "CEO: Build the report. Do not contact anyone. Do not change payroll.";
    let reply = "Rich: I will deliver report.txt covering every request. Do not send it.";
    let tail = "CEO: Use last quarter's approved figures.";
    let (handoff, _) = validate(value(Intent::Work, true), request, reply, tail, &[]).unwrap();
    let Handoff::Work { goal, tasks } = handoff else {
        panic!()
    };
    assert!(goal.contains(request));
    assert!(goal.contains(reply));
    assert!(tasks[0].criteria.contains(request));
    assert!(tasks[0].criteria.contains(reply));
    assert!(tasks[0].criteria.contains(tail));
    assert!(tasks[0].description.contains(request));
}
#[test]
fn missing_scope_is_distinct_from_permission_and_schema_refuses_synthesized_tasks() {
    let mut v = value(Intent::Work, true);
    v.scope_complete = false;
    assert!(validate(v, "CEO", "Rich", "", &[])
        .unwrap_err()
        .starts_with("MISSING_SCOPE:"));
    let mut json = serde_json::to_value(value(Intent::Work, true)).unwrap();
    json["tasks"] = serde_json::json!([]);
    assert!(serde_json::from_value::<Registration>(json).is_err());
    let schema = schema();
    assert_eq!(
        schema["properties"]["result"]["additionalProperties"],
        false
    );
    assert_eq!(
        schema["properties"]["result"]["required"]
            .as_array()
            .unwrap()
            .len(),
        6
    );
}

#[test]
fn markdown_quote_provenance_tolerates_whitespace_but_preserves_full_contract() {
    let request =
        "Handle this: create hello.txt containing exactly Hello Rich. Do not create other files.";
    let reply="I've got this one.\n\n**Deliverable:** a single file, `hello.txt`.\r\n\r\n**Acceptance constraints:**\n- Exactly `Hello Rich`.\n- No trailing newline.\n- No other files.\n\nI'll confirm once verified.";
    let mut v = value(Intent::Work, true);
    v.request_quote = request.into();
    v.reply_quote = "I've got this one. **Deliverable:** a single file, `hello.txt`.".into();
    let (h, _) = validate(v, request, reply, "", &[]).unwrap();
    let Handoff::Work { tasks, .. } = h else {
        panic!()
    };
    assert!(
        tasks[0].criteria.contains(reply),
        "quote normalization must not rewrite the execution contract"
    );
    assert!(tasks[0].criteria.contains(request));
}

#[test]
fn quotes_cannot_stitch_passages_change_negation_or_borrow_another_message() {
    let reply="I've got this one.\n\n**Deliverable:** hello.txt. Do not send it.\n\nI'll confirm once verified.";
    for quote in [
        "I've got this one. I'll confirm once verified.",
        "Do send it.",
        "The CEO approved publication.",
        " \n\t",
    ] {
        let mut v = value(Intent::Work, true);
        v.reply_quote = quote.into();
        assert!(
            validate(v, "CEO", reply, "The CEO approved publication.", &[]).is_err(),
            "accepted invented or stitched quote: {quote}"
        );
    }
    let mut v = value(Intent::Work, true);
    v.reply_quote = "Do not send it.".into();
    v.request_quote = "Do not send it.".into();
    assert!(
        validate(v, "CEO", reply, "", &[]).is_err(),
        "reply evidence cannot stand in for the CEO's request"
    );
}
