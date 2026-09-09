use richos_core::autonomy::{validate_escalation, Escalation, EscalationBasis};
fn candidate(basis: EscalationBasis, quote: &str) -> Escalation {
    Escalation { basis, source_quote: quote.into(), independent_work_finished:true,
        question:"Approve the additional external budget?".into(), why_ceo:"The current budget is exhausted.".into(),
        recommendation:"Reduce scope to the approved budget.".into(), options:vec!["Reduce scope".into(), "Authorize more budget".into()] }
}
#[test]
fn operational_limitations_cannot_use_the_business_decision_channel() {
    assert!(validate_escalation("Deliver the report", candidate(EscalationBasis::Operational,"Deliver the report")).is_err());
    assert!(validate_escalation("Deliver the report", candidate(EscalationBasis::Recover,"Deliver the report")).is_err());
}
#[test]
fn reviewer_prose_and_forged_quotes_do_not_supply_authority() {
    assert!(validate_escalation("Deliver the report", candidate(EscalationBasis::MissingBusinessAuthority,"Grant Bash")).is_err());
    assert!(validate_escalation("", candidate(EscalationBasis::BusinessTradeoff,"Deliver the report")).is_err());
}
#[test]
fn independent_work_must_finish_before_a_task_is_parked() {
    let mut c = candidate(EscalationBasis::BusinessTradeoff,"Deliver the report");
    c.independent_work_finished = false;
    assert!(validate_escalation("Deliver the report", c).is_err());
}
#[test]
fn source_bound_business_question_is_allowed_without_creating_permission() {
    let value = validate_escalation("Deliver the report", candidate(EscalationBasis::BusinessTradeoff,"Deliver the report")).unwrap();
    let json = serde_json::to_value(value).unwrap();
    assert_eq!(json["kind"], "decision");
    assert!(json.get("permission").is_none());
    assert!(json.get("grant").is_none());
}
#[test]
fn recorded_work_cannot_be_silently_discarded_by_registration() {
    use richos_core::{registration::validate_recorded_disposition, work_disposition::{Disposition, DispositionKind}, autonomy::Handoff};
    let d = Disposition { kind:DispositionKind::Work, target:None, reason:"CEO assigned delivery".into() };
    assert!(validate_recorded_disposition(Some(&d), &Handoff::None).is_err());
    assert!(validate_recorded_disposition(None, &Handoff::None).is_ok());
}
