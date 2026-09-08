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
fn discussion_cannot_discard_commitment_but_rich_cannot_veto_authorized_work() {
    assert!(validate(value(Intent::Discussion, true), "CEO", "Rich", "", &[]).is_err());
    assert!(matches!(validate(value(Intent::Work, false), "CEO", "Rich", "", &[]).unwrap().0, Handoff::Work { .. }));
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
fn discovery_is_owned_without_model_generated_acceptance_criteria() {
    let mut v = value(Intent::Work, true);
    v.scope_complete = false;
    let Handoff::Work { tasks, .. } = validate(v, "CEO", "Rich", "", &[]).unwrap().0 else { panic!() };
    assert!(tasks[0].criteria.contains("CEO"));
    assert!(tasks[0].criteria.contains("Rich"));
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

#[test]
fn onboarding_disposition_requires_host_tool_evidence_and_does_not_drop_other_work() {
    assert!(validate_with_onboarding(
        value(Intent::Onboarding, false),
        "CEO",
        "Rich",
        "",
        &[],
        false
    )
    .is_err());
    assert!(matches!(
        validate_with_onboarding(
            value(Intent::Onboarding, false),
            "CEO",
            "Rich",
            "",
            &[],
            true
        )
        .unwrap()
        .0,
        Handoff::None
    ));
    assert!(validate_with_onboarding(
        value(Intent::Onboarding, true),
        "CEO",
        "Rich",
        "",
        &[],
        true
    )
    .is_err());
    let mut targeted = value(Intent::Onboarding, false);
    targeted.target_run_id = Some("assignment".into());
    assert!(validate_with_onboarding(targeted, "CEO", "Rich", "", &[], true).is_err());
    assert!(matches!(
        validate_with_onboarding(value(Intent::Work, true), "CEO", "Rich", "", &[], true)
            .unwrap()
            .0,
        Handoff::Work { .. }
    ));
}

#[test]
fn production_work_contract_keeps_only_the_two_onboarding_operations_inline() {
    let contract = richos_core::spine::OWNED_WORK_CONTRACT;
    assert!(contract.contains("mcp__richos_onboarding__save_company_notes"));
    assert!(contract.contains("mcp__richos_onboarding__decline_onboarding"));
    assert!(contract.contains(
        "For every other action request, including a single file edit, do not execute it"
    ));
    assert!(contract.contains(
        "An unrelated action requested alongside the interview still follows the work rule"
    ));
    assert!(ONBOARDING_REGISTRATION_RULE.contains("DATA.onboarding_tool_result is true"));
}

#[test]
fn interrupted_empty_reply_cannot_veto_work_or_fabricate_commitment() {
    let mut v = value(Intent::Work, false);
    v.reply_quote.clear();
    assert!(matches!(validate(v, "CEO", "", "", &[]).unwrap().0, Handoff::Work { .. }));
    let mut v = value(Intent::Work, true);
    v.reply_quote.clear();
    assert!(validate(v, "CEO", "", "", &[]).is_err());
    let mut v = value(Intent::Work, false);
    v.reply_quote.clear();
    assert!(validate(v, "CEO", "Actual reply", "", &[]).is_err());
}

#[test]
fn repeated_corrections_keep_original_constraints_after_context_eviction() {
    use richos_core::{autonomy, run::RunController};
    let temp = std::env::temp_dir().join(format!("richos-registration-review-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir(&temp).unwrap();
    let goal = "Original CEO requirement: Do not publish. Preserve payroll.";
    let task = autonomy::WorkItem { id: "deliver".into(), description: goal.into(), criteria: goal.into(), depends_on: vec![] };
    let plan = autonomy::plan(temp.as_path(), goal, goal, vec![task]).unwrap();
    let mut ctl = RunController::create(&temp.as_path().join("run.jsonl"), plan).unwrap();
    for i in 0..3 {
        let mut v = value(Intent::Amend, false);
        v.target_run_id = Some(ctl.snapshot().id.clone());
        let Handoff::Amend { goal, tasks } = validate(v, "CEO: Change the format", "Rich: Recorded", "", &[ctl.snapshot().clone()]).unwrap().0 else { panic!() };
        assert!(goal.contains("Do not publish. Preserve payroll."));
        assert!(tasks[0].criteria.contains("Do not publish. Preserve payroll."));
        ctl.amend(&format!("correction-{i}"), autonomy::plan(temp.as_path(), "Change format", &goal, tasks).unwrap()).unwrap();
    }
    std::fs::remove_dir_all(temp).unwrap();
}
