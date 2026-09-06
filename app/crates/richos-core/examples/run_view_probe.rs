//! Generates browser fixtures through the real registration, planner and desktop projection.
//! No hand-authored display payload can stand in for this boundary check.
#[path = "../../../src-tauri/src/run_view.rs"]
mod projection;
use richos_core::{
    autonomy::{self, Handoff},
    registration::{self, Intent, Registration},
    run::{RunController, RunSnapshot},
};

fn register(
    workspace: &std::path::Path,
    request: &str,
    reply: &str,
    previous: &[RunSnapshot],
) -> RunSnapshot {
    let value = Registration {
        intent: if previous.is_empty() {
            Intent::Work
        } else {
            Intent::Amend
        },
        rich_committed: true,
        request_quote: request.into(),
        reply_quote: reply.into(),
        scope_complete: true,
        target_run_id: previous.first().map(|p| p.id.clone()),
    };
    let (handoff, _) = registration::validate(
        value,
        request,
        reply,
        "Sensitive conversation context belongs in execution, not panel history.",
        previous,
    )
    .unwrap();
    let (goal, tasks) = match handoff {
        Handoff::Work { goal, tasks } | Handoff::Amend { goal, tasks } => (goal, tasks),
        _ => panic!("not accepted"),
    };
    let plan = autonomy::plan(workspace, request, &goal, tasks).unwrap();
    let mut controller = RunController::create(
        &workspace.join(format!("{}.jsonl", uuid::Uuid::new_v4())),
        plan,
    )
    .unwrap();
    struct Host;
    impl richos_core::run::RunHost for Host {
        fn execute(
            &mut self,
            _: &richos_core::run::RunPlan,
            task: &richos_core::run::TaskSpec,
            _: &[String],
        ) -> Result<(), String> {
            assert!(task.prompt.contains("CEO request (verbatim):"));
            Ok(())
        }
        fn verify(
            &mut self,
            _: &std::path::Path,
            check: &richos_core::run::Check,
        ) -> Result<String, String> {
            assert!(check.name.contains("Preserve prohibitions."));
            Ok("Checked draft.md against the approved figures. Nothing was sent.".into())
        }
    }
    controller.tick(&mut Host).unwrap();
    assert!(
        !controller.snapshot().tasks[0].evidence.is_empty(),
        "The projection probe must include real controller receipts"
    );
    controller.snapshot().clone()
}
fn probe() -> serde_json::Value {
    let workspace = std::env::temp_dir().join(format!("richos-display-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir(&workspace).unwrap();
    let request = "Draft the Q4 investor update. Do not send it or contact anyone.";
    let reply = "I'll deliver the complete draft with figures reconciled to Finance. It will remain private.";
    let original = register(&workspace, request, reply, &[]);
    let before = serde_json::to_vec(&original).unwrap();
    assert!(original.tasks[0].evidence[0].contains("Preserve prohibitions."));
    let first = serde_json::to_value(projection::view("hiring", &original)).unwrap();
    assert_eq!(first["goal"], request);
    assert_eq!(first["tasks"][0]["description"], request);
    assert_eq!(first["tasks"][0]["checks"][0], reply);
    assert_eq!(
        before,
        serde_json::to_vec(&original).unwrap(),
        "Display changed authority"
    );
    assert!(original.plan.tasks[0].checks[0]
        .name
        .contains("Preserve prohibitions."));
    assert!(original.plan.tasks[0].checks[0]
        .name
        .contains("Sensitive conversation context"));
    let amended = register(
        &workspace,
        "Use the approved figures only.",
        "I'll use the approved figures and retain all other requirements.",
        &[original.clone()],
    );
    let second = serde_json::to_value(projection::view("hiring", &amended)).unwrap();
    assert!(second["tasks"][0]["previous_instructions"][0]["request"]
        .as_str()
        .unwrap()
        .contains("Do not send it"));
    for view in [&first, &second] {
        // The desktop projection carries no autonomous command recipe.
        let task = &view["tasks"][0];
        let visible = format!(
            "{} {} {} {} {}",
            view["goal"],
            task["description"],
            task["checks"],
            task["previous_instructions"],
            task["evidence"]
        );
        for forbidden in [
            "verbatim",
            "acceptance constraint",
            "Preserve prohibitions",
            "certify partial",
            "Conversation context",
            "Sensitive conversation",
        ] {
            assert!(
                !visible.contains(forbidden),
                "Machine contract leaked: {forbidden}"
            );
        }
    }
    let mut imported = original.clone();
    imported.plan.goal = "Local checks".into();
    imported.plan.tasks[0].prompt = "Check the supplied report".into();
    imported.plan.tasks[0].checks[0].name = "Report has all four sections".into();
    imported.plan.tasks[0].checks[0].argv = vec!["check-report".into(), "report.txt".into()];
    imported.tasks[0].evidence = vec!["check-report succeeded".into()];
    let third = serde_json::to_value(projection::view("hiring", &imported)).unwrap();
    assert_eq!(
        third["tasks"][0]["checks"][0],
        "Report has all four sections"
    );
    assert_eq!(
        third["tasks"][0]["description"],
        "Check the supplied report"
    );
    // A durable older-format input is deliberately independent of today's registrar.
    let mut older = original.clone();
    older.plan.goal = "CEO request v0: private machine contract".into();
    older.plan.tasks[0].prompt =
        "Legacy machine scope: Preserve prohibitions. Conversation context: private".into();
    older.plan.tasks[0].checks[0].name = "Legacy verifier contract with private context".into();
    older.tasks[0].evidence =
        vec!["Legacy verifier contract with private context: old result".into()];
    let older_bytes = serde_json::to_vec(&older).unwrap();
    let fourth = serde_json::to_value(projection::view("hiring", &older)).unwrap();
    assert_eq!(
        fourth["goal"], "Saved assignment",
        "Unknown envelope leaked into the title"
    );
    assert_eq!(
        fourth["tasks"][0]["description"],
        "The saved assignment details are unavailable in this view.",
        "Unknown envelope leaked into history"
    );
    assert_eq!(fourth["tasks"][0]["checks"], serde_json::json!([]));
    assert_eq!(fourth["tasks"][0]["commands"], serde_json::json!([]));
    assert_eq!(
        fourth["tasks"][0]["evidence"][0],
        "Saved results are kept with this assignment."
    );
    assert_eq!(
        serde_json::to_vec(&older).unwrap(),
        older_bytes,
        "Fallback changed the journal"
    );
    assert!(!serde_json::to_string(&fourth).unwrap().contains("private"));
    std::fs::remove_dir_all(&workspace).unwrap();
    serde_json::json!([first, second, third, fourth])
}
fn main() {
    println!("{}", probe());
}
#[test]
fn human_display_preserves_execution_and_amendment_requirements() {
    probe();
}
