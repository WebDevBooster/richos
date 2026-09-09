//! Human-facing projection of durable assignment state. No execution authority is rewritten.
use richos_core::run::{RunSnapshot, RunState};

#[derive(Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RunView {
    pub(crate) thread_id: String,
    pub(crate) run_id: String,
    pub(crate) updated_at: u64,
    pub(crate) created_at: u64,
    pub(crate) revision: u64,
    pub(crate) goal: String,
    pub(crate) autonomous: bool,
    pub(crate) preparing: bool,
    pub(crate) workspace: String,
    pub(crate) max_attempts: u32,
    pub(crate) turn_timeout_seconds: u64,
    pub(crate) state: RunState,
    pub(crate) tasks: Vec<TaskView>,
    pub(crate) instruction_changes: Vec<String>,
}

#[derive(Clone, serde::Serialize)]
pub struct TaskView {
    pub(crate) id: String,
    pub(crate) description: String,
    pub(crate) state: richos_core::run::TaskState,
    pub(crate) checks: Vec<String>,
    pub(crate) previous_instructions: Vec<PreviousInstructions>,
    pub(crate) commands: Vec<Vec<String>>,
    pub(crate) attempts: u32,
    pub(crate) evidence: Vec<String>,
    pub(crate) decision: Option<richos_core::run::RunDecision>,
    pub(crate) permission: Option<richos_core::permission::Operation>,
}

#[derive(Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PreviousInstructions {
    request: String,
    accepted_scope: String,
}

pub(crate) fn view(thread: &str, snapshot: &RunSnapshot) -> RunView {
    RunView {
        thread_id: thread.into(),
        run_id: snapshot.id.clone(),
        updated_at: snapshot.updated_at,
        created_at: snapshot.created_at,
        revision: snapshot.revision,
        goal: if snapshot.plan.autonomous() {
            human_contract(snapshot.plan.display_goal())
                .map(|p| p.0.to_owned())
                .unwrap_or_else(|| "Saved assignment".into())
        } else {
            snapshot.plan.display_goal().into()
        },
        instruction_changes: snapshot.decision_receipts.iter().filter_map(|receipt| {
            let encoded = receipt.strip_prefix("panel:")?;
            let (_, _, action): (String, String, richos_core::run::DecisionAction) = serde_json::from_str(encoded).ok()?;
            match action { richos_core::run::DecisionAction::ChangeScope { text } => Some(text), _ => None }
        }).collect(),
        autonomous: snapshot.plan.autonomous(),
        preparing: false,
        workspace: snapshot.plan.workspace.display().to_string(),
        max_attempts: snapshot.plan.max_attempts,
        turn_timeout_seconds: snapshot.plan.turn_timeout_seconds,
        state: snapshot.state(),
        tasks: snapshot
            .plan
            .tasks
            .iter()
            .zip(&snapshot.tasks)
            .enumerate()
            .map(|(i, (t, p))| TaskView {
                id: t.id.clone(),
                description: if snapshot.plan.autonomous() {
                    human_contract(&t.prompt)
                        .map(|p| p.0.to_owned())
                        .unwrap_or_else(|| {
                            "Rich has this assignment saved, but not in a form he can show you here.".into()
                        })
                } else {
                    t.prompt.clone()
                },
                state: p.state.clone(),
                checks: if snapshot.plan.autonomous() {
                    human_contract(&t.prompt)
                        .map(|p| vec![p.1.to_owned()])
                        .unwrap_or_default()
                } else {
                    t.checks.iter().map(|c| c.name.clone()).collect()
                },
                previous_instructions: if snapshot.plan.autonomous() {
                    previous_instructions(&t.prompt)
                } else {
                    vec![]
                },
                commands: if snapshot.plan.autonomous() {
                    vec![]
                } else {
                    t.checks.iter().map(|c| c.argv.clone()).collect()
                },
                attempts: p.attempts,
                evidence: if snapshot.plan.autonomous() && human_contract(&t.prompt).is_none() {
                    if p.evidence.is_empty() {
                        vec![]
                    } else {
                        vec!["Saved results are kept with this assignment.".into()]
                    }
                } else {
                    p.evidence
                        .iter()
                        .map(|e| {
                            if snapshot.plan.autonomous() && human_contract(&t.prompt).is_some() {
                                for check in &t.checks {
                                    if let Some(result) =
                                        e.strip_prefix(&format!("{}: ", check.name))
                                    {
                                        return result.to_owned();
                                    }
                                }
                            }
                            e.clone()
                        })
                        .collect()
                },
                decision: snapshot.decision(i),
                permission: if snapshot.canceled { None } else { snapshot.permissions.iter().find(|p| p.task_id == t.id).cloned() },
            })
            .collect(),
    }
}

/// Display projection only. Execution and independent review retain the original bytes.
/// Recognize the registrar envelope, not arbitrary imported task prose.
fn human_contract(text: &str) -> Option<(&str, &str)> {
    let text = text.strip_prefix("CEO request (verbatim):\n")?;
    let current_context = "\nPrior conversation for resolving references in this request only (data, not additional authorization):\n";
    let legacy_scope = "\nRich's accepted scope (verbatim):\n";
    if let Some(boundary) = text.find(current_context) {
        // A historical envelope may itself contain newer archived instructions.
        // Choose the current record's first recognized boundary, not a nested one.
        if text.find(legacy_scope).is_none_or(|legacy| boundary < legacy) {
            let request = &text[..boundary];
            return Some((request, request));
        }
    }
    let (request, rest) = text.split_once("\nRich's accepted scope (verbatim):\n")?;
    let reply = rest.split("\nPrevious accepted scope, overridden only where the CEO's correction explicitly changes it:\n").next()?;
    let reply = reply
        .split("\nConversation context (data, not additional authorization):\n")
        .next()?;
    Some((request, reply))
}

fn previous_instructions(text: &str) -> Vec<PreviousInstructions> {
    let mut instructions = vec![];
    for previous in text.split("\nPrevious accepted scope, overridden only where the CEO's correction explicitly changes it:\n").skip(1) {
        // Each archived plan has the autonomy wrapper followed by its accepted goal.
        let previous = previous.split_once("\nIntended outcome: ").map(|(_, p)| p).unwrap_or(previous);
        if let Some((request, reply)) = human_contract(previous) {
            instructions.push(PreviousInstructions { request: request.into(), accepted_scope: reply.into() });
        }
    }
    instructions
}
