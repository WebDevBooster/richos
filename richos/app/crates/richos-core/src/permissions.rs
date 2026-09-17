//! Native provider permission requests surfaced in the desktop. One exact action,
//! one visible turn — and, since the background-work spec's §5.2, one exact action that
//! can WAIT for him when there is no visible turn at all.
//!
//! # What changed, and why it is a change of IDENTITY rather than of a refusal
//!
//! The background-work spec (richos-hq `docs/plans/background-work-spec-2026-09-17.md`
//! revision 5) §5.1 states the position this file used to be in: *"a worker's permission
//! request with no open turn is denied, not queued"*. §5.2 decides the replacement —
//! *"a request raised with no turn open is queued for his next look, and never
//! auto-approved"* — and §5.3 names the part that is easy to miss: the grant is not a flag,
//! it is a whole [`Binding`], and **a request cannot outlive its `turn_id`**. So the work
//! lease's binding carries a stable identity that is not a turn id — the ASSIGNMENT — and
//! this desk compares against that.
//!
//! **The two audiences are therefore held to two different liveness tests, and the
//! difference is the whole of §5.3:**
//!
//! | Audience | Alive while… | Shown on |
//! |---|---|---|
//! | the conversation (`audience != "worker"`) | the grant file still equals the request's binding — a turn | the permission sheet ([`PermissionDesk::current`]) |
//! | background work (`audience == "worker"`) | the ASSIGNMENT is still open, which [`PermissionDesk::forget`] is told | the assignment surface ([`PermissionDesk::background_queue`]) |
//!
//! A background request deliberately survives its own grant file being closed, because the
//! work lease's turn ends while he is away and `revoke_work_assignment` closes the grant on
//! the way out (`native.rs`). Gating his queue on that file would have deleted the request
//! seconds after it was raised — the failure §5.7 is written against, wearing a different
//! hat.
//!
//! # The 300-second deadline stops the CALL, not the REQUEST (§5.7)
//!
//! *"a request raised while he is at lunch is denied long before he looks, and 7.6 fails."*
//! The provider call still ends at its deadline and still ends in **not approved** — nothing
//! holds a provider tool call open for hours. What is new is that the entry stays in the
//! queue with [`Queued::call_returned`] set, so when he answers, the answer applies to the
//! ASSIGNMENT: [`Answered::ToAssignment`] hands it to the work host, which resumes the
//! assignment, and [`Standing`] lets that resumed run take the one exact action he approved.
//!
//! **A standing decision is not an auto-approval and the difference is mechanical.** It
//! matches ONE assignment, ONE tool and ONE exact input, it is consumed on first use, and it
//! dies with the assignment ([`PermissionDesk::forget`]). Nothing here ever decides on his
//! behalf: with no answer from him there is no standing decision, and the refusal is a
//! refusal.
use crate::{ecs::Binding, native::PermissionDecision};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{path::{Path, PathBuf}, sync::{Arc, Condvar, Mutex}, time::{Duration, Instant}};

#[derive(Clone, Debug, Serialize)]
pub struct PermissionRequest {
    pub id: String,
    pub binding: Binding,
    pub tool: String,
    pub input: Value,
    pub description: String,
    pub reason: String,
    /// When it was raised. The surface uses it to keep his queue in the order the work
    /// asked, which is the order §5.5 shows it in.
    pub raised_at_ms: u64,
}

/// **The audience a work lease binds under** (`ecs.rs`'s `bind_work_seat`, spec §5.8c). The
/// one field that tells this desk whether a request belongs to a turn he is watching or to
/// an assignment he may be away from.
pub const WORK_AUDIENCE: &str = "worker";

/// Is this request background work's rather than the conversation's? The identity test
/// §5.3 turns on, in one place so no caller re-spells it.
pub fn is_background(binding: &Binding) -> bool {
    binding.audience == WORK_AUDIENCE
}

/// The assignment a background binding belongs to: `(entity, thread, obligation)`.
///
/// `turn_id` is the OBLIGATION on a work seat and never a turn — `ecs.rs`'s `bind_work_seat`
/// says why in its own comment, and the engine's seat reconciler reads exactly that field
/// (`richos/engine/mega-lander/app.py:704`). This is the identity §5.3 requires and the key
/// [`PermissionDesk::forget`] is given.
pub fn assignment_key(binding: &Binding) -> (String, String, String) {
    (binding.entity_id.clone(), binding.thread_id.clone(), binding.turn_id.clone())
}

#[derive(Debug)]
struct Queued {
    request: PermissionRequest,
    scope: PathBuf,
    decision: Option<bool>,
    /// The provider call that raised this request has already ended at its 300 s deadline
    /// (§5.7). The REQUEST is still his to answer; there is simply nobody left holding the
    /// line for it, so his answer goes to the assignment instead of to a call.
    call_returned: bool,
}

/// A decision he gave after the call had already returned — §5.7's *"when he answers, the
/// answer applies to the assignment, not to a call that has long since returned"*.
///
/// Matched on the assignment, the tool AND the exact input, used once, and dropped with the
/// assignment. It is the mechanism by which an approval he gave at 9pm reaches the step that
/// asked for it at 2pm, and it is deliberately the narrowest thing that can do that.
#[derive(Debug)]
struct Standing {
    key: (String, String, String),
    tool: String,
    input: Value,
    allow: bool,
}

#[derive(Debug, Default)]
struct Desk {
    /// Ordered, oldest first. §5.5: *"its single `Option<Pending>` becomes an ordered queue
    /// whose head is the one shown"*. Both audiences share one queue and one desk — §2.7's
    /// one-desk argument — and each surface shows the head of the requests it owns.
    queue: Vec<Queued>,
    standing: Vec<Standing>,
}

#[derive(Debug, Default)]
pub struct PermissionDesk { inner: Mutex<Desk>, changed: Condvar }
#[derive(Clone, Debug)]
pub struct ScopedPermissions { pub desk: Arc<PermissionDesk>, pub scope: PathBuf }

/// What [`PermissionDesk::resolve`] did with his answer — and the second arm is the one
/// §5.7 exists for.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Answered {
    /// The call that raised it is still waiting and has taken the decision itself.
    Delivered,
    /// The call had already ended at its deadline. His answer now belongs to the assignment
    /// named by this binding: the work host resumes it (approved) or records that he
    /// declined the step (declined).
    ToAssignment { binding: Binding, allow: bool },
}

/// What a background call is told at its deadline. **It is written for the model, not for
/// him**, and it says the two things a model must not get wrong: this was NOT approved, and
/// do not try again — it is his and he still has it.
const NOT_APPROVED_YET: &str =
    "This is waiting for the CEO to approve it and has not been approved. Do not retry it \
     and do not work around it: the request is in his queue and he will answer it.";

/// What a background call is told when its assignment stopped underneath it.
const ASSIGNMENT_GONE: &str =
    "That assignment was stopped, so this action was not approved.";

#[derive(Deserialize)]
struct Grant { version: u32, actions_allowed: bool, binding: Binding }
fn grant(path: &Path) -> Option<Binding> {
    if std::fs::metadata(path).ok()?.len() > 16384 {return None;}
    let grant: Grant=serde_json::from_slice(&std::fs::read(path).ok()?).ok()?;
    (grant.version == 1 && grant.actions_allowed).then_some(grant.binding)
}
fn permission_reason(request: &Value) -> String {
    if let Some(reason)=request["decision_reason"].as_str().filter(|s|!s.is_empty()) {return reason.into();}
    match request["decision_reason_type"].as_str() {
        Some("safetyCheck") => "The provider requires manual approval for this command form.".into(),
        Some(kind) => format!("The provider requires approval ({kind})."),
        None => String::new(),
    }
}
fn now_ms() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}
impl PermissionDesk {
    /// **The head of the CONVERSATION's queue** — what the permission sheet shows.
    ///
    /// Background requests are deliberately NOT here. A modal that opened over his screen
    /// because something he is not watching reached a step would be an interruption, and
    /// the standing rule for background results is that he is told when he is next
    /// listening rather than mid-sentence (spec §0 row 6, §3.5). Their surface is the
    /// assignment they belong to — [`Self::background_queue`].
    pub fn current(&self) -> Option<PermissionRequest> {
        self.inner.lock().unwrap().queue.iter()
            .find(|q| !is_background(&q.request.binding)
                && grant(&q.scope).as_ref() == Some(&q.request.binding)
                && q.decision.is_none())
            .map(|q| q.request.clone())
    }

    /// **Everything background work is waiting on him for, oldest first** (§5.5).
    ///
    /// One entry per request, not per assignment: the surface picks the head for each
    /// assignment it renders, which is the same rule the sheet applies to the conversation.
    /// Nothing here is filtered by a grant file — see the module doc's table.
    pub fn background_queue(&self) -> Vec<PermissionRequest> {
        self.inner.lock().unwrap().queue.iter()
            .filter(|q| is_background(&q.request.binding) && q.decision.is_none())
            .map(|q| q.request.clone())
            .collect()
    }

    /// His answer to one exact request.
    ///
    /// The conversation's arm is unchanged: the request must still match a live grant, or
    /// the turn it belonged to has gone and the old request cannot be approved. The
    /// background arm is §5.7's: if the call is still waiting it takes the decision; if the
    /// call already ended at its deadline the decision goes to the assignment.
    pub fn resolve(&self, id: &str, allow: bool) -> Result<Answered, String> {
        let mut desk = self.inner.lock().unwrap();
        let index = desk.queue.iter().position(|q| q.request.id == id)
            .ok_or_else(|| "That action is no longer waiting for permission.".to_string())?;
        if desk.queue[index].decision.is_some() {
            return Err("That action's turn has stopped or changed. The old request cannot be approved.".into());
        }
        let background = is_background(&desk.queue[index].request.binding);
        if !background && grant(&desk.queue[index].scope).as_ref() != Some(&desk.queue[index].request.binding) {
            return Err("That action's turn has stopped or changed. The old request cannot be approved.".into());
        }
        if background && desk.queue[index].call_returned {
            let entry = desk.queue.remove(index);
            let binding = entry.request.binding.clone();
            desk.standing.push(Standing {
                key: assignment_key(&binding),
                tool: entry.request.tool.clone(),
                input: entry.request.input.clone(),
                allow,
            });
            self.changed.notify_all();
            return Ok(Answered::ToAssignment { binding, allow });
        }
        desk.queue[index].decision = Some(allow);
        self.changed.notify_all();
        Ok(Answered::Delivered)
    }

    /// **An assignment is over: its queue entries and its standing decision go with it**
    /// (§5.4's *"a grant and its seat are created together and revoked together, by name,
    /// per assignment"*, extended to the two things this desk holds on that assignment's
    /// behalf).
    ///
    /// Called when the assignment settles, when it is stopped, and at quit. Returns how many
    /// waiting requests were dropped, so a caller can say that a stop took a question off
    /// his screen rather than leaving one there pointing at nothing.
    pub fn forget(&self, entity: &str, thread: &str, obligation: &str) -> usize {
        let key = (entity.to_string(), thread.to_string(), obligation.to_string());
        let mut desk = self.inner.lock().unwrap();
        let before = desk.queue.len();
        desk.queue.retain(|q| !is_background(&q.request.binding) || assignment_key(&q.request.binding) != key);
        desk.standing.retain(|s| s.key != key);
        self.changed.notify_all();
        before - desk.queue.len()
    }

    /// Take the standing decision matching this exact action, if he left one. Consumed.
    fn take_standing(desk: &mut Desk, binding: &Binding, tool: &str, input: &Value) -> Option<bool> {
        let key = assignment_key(binding);
        let at = desk.standing.iter().position(|s| s.key == key && s.tool == tool && &s.input == input)?;
        Some(desk.standing.remove(at).allow)
    }
}
impl ScopedPermissions {
    pub fn decide(&self, request: &Value) -> PermissionDecision { self.wait(request,Duration::from_secs(300)) }
    /// The same decision with a caller-supplied deadline. **Test scaffolding**, and it is
    /// here rather than in a test module because `work_host`'s tests need to raise a real
    /// request against the real desk — a second implementation of this path would be a test
    /// asserting about itself. The shipping caller is [`Self::decide`], at 300 s.
    #[doc(hidden)]
    pub fn decide_within(&self, request: &Value, limit: Duration) -> PermissionDecision { self.wait(request,limit) }
    fn wait(&self, request: &Value, limit: Duration) -> PermissionDecision {
        let deny=|message:&str|PermissionDecision::Deny{message:message.into()};
        let allow=||PermissionDecision::Allow{updated_input:request.get("input").cloned().unwrap_or(json!({}))};
        let Some(binding)=grant(&self.scope) else {return deny("This app turn is stopped or is supplying context. New actions are unavailable.")};
        let tool=request["tool_name"].as_str().unwrap_or("");
        // These tools implement their own explicit host scope and write contracts.
        if matches!(tool,"mcp__richos_work__repositories"|"mcp__richos_work__prepare"|"mcp__richos_work__inspect"|"mcp__richos_work__complete"|"mcp__richos_continuity__checkpoint"|"mcp__richos_continuity__inspect"|
            "mcp__richos_onboarding__save_company_notes"|"mcp__richos_onboarding__decline_onboarding"|
            // The assignment register (`assignment_tools.rs`). App-owned, with its own host
            // scope and write contract, exactly like the two onboarding tools beside it: the
            // model supplies what the assignment IS, and the company, conversation, state
            // root and attested instruction all come from a scope the app wrote. It records
            // an intent and changes nothing else — what it cannot do is the thing worth
            // saying out loud, which is finish the work. The step that would change his
            // repository is `mcp__richos_work__integrate`, which is NOT on this list and is
            // not meant to be (background-work spec §0 row 7, §5.4, §7.8).
            "mcp__richos_assignments__record") {
            return allow();
        }
        if tool.is_empty() || request.to_string().len()>65536 {return deny("The requested action could not be safely displayed.");}
        let input=request.get("input").cloned().unwrap_or(json!({}));
        let id=uuid::Uuid::new_v4().to_string();
        let mut desk=self.desk.inner.lock().unwrap();
        // **His answer from before this call existed** (§5.7). Only ever present for a
        // background binding, only ever for this exact tool and this exact input, and gone
        // the moment it is read.
        if let Some(allowed)=PermissionDesk::take_standing(&mut desk,&binding,tool,&input) {
            return if allowed {allow()} else {deny("The CEO declined this step. Do not retry it and do not work around it.")};
        }
        desk.queue.push(Queued{request:PermissionRequest{id:id.clone(),binding:binding.clone(),tool:tool.into(),
            input:input.clone(),description:request["description"].as_str().unwrap_or("").into(),reason:permission_reason(request),
            raised_at_ms:now_ms()},
            scope:self.scope.clone(),decision:None,call_returned:false});
        self.desk.changed.notify_all();
        let background=is_background(&binding);
        let deadline=Instant::now()+limit;
        loop {
            let Some(index)=desk.queue.iter().position(|q|q.request.id==id) else {
                // Only [`PermissionDesk::forget`] removes an entry somebody is waiting on,
                // and it does that when the assignment stops.
                break deny(ASSIGNMENT_GONE);
            };
            // **The conversation's liveness test, and it stays exactly as it was.** A
            // background binding is deliberately not held to it: its grant closes when the
            // work lease's turn ends, which is the ordinary case rather than a stop.
            if !background && grant(&self.scope).as_ref()!=Some(&binding) {
                desk.queue.remove(index);
                break deny("The app turn was stopped or changed before approval.");
            }
            if background && !self.scope.exists() {
                // The work lease itself is gone — its scope file is removed when the lease
                // drops (`native.rs`'s `Drop`). Nothing can carry out what he approves, so
                // the call ends rather than waiting for an answer that could not be used.
                desk.queue.remove(index);
                break deny(ASSIGNMENT_GONE);
            }
            if let Some(allowed)=desk.queue[index].decision {
                desk.queue.remove(index);
                break if allowed {allow()}
                    else {deny("The user declined this action. Do not retry it through another tool.")};
            }
            if Instant::now()>=deadline {
                if background {
                    // §5.7. The call ends; the request stays exactly where he will find it.
                    desk.queue[index].call_returned=true;
                    break deny(NOT_APPROVED_YET);
                }
                desk.queue.remove(index);
                break deny("No permission decision was received. The action was not approved.");
            }
            desk=self.desk.changed.wait_timeout(desk,Duration::from_millis(100)).unwrap().0;
        }
    }
}
#[cfg(test)] mod tests {
    use super::*;

    fn binding(audience: &str, turn: &str) -> Value {
        json!({"entity_id":"alpha","thread_id":"thread","session_id":"session","turn_id":turn,"audience":audience,"revision":1})
    }
    fn scope_with(audience: &str, turn: &str)->(PathBuf,ScopedPermissions) {
        let p=std::env::temp_dir().join(format!("permission-{}.json",uuid::Uuid::new_v4()));
        std::fs::write(&p,json!({"version":1,"actions_allowed":true,"binding":binding(audience,turn)}).to_string()).unwrap();
        let policy=ScopedPermissions{desk:Arc::new(PermissionDesk::default()),scope:p.clone()};(p,policy)
    }
    fn scope()->(PathBuf,ScopedPermissions) { scope_with("ceo","turn") }
    /// A second lease sharing ONE desk — the shape the app actually runs (§2.7: the desk is
    /// one `Arc<PermissionDesk>` on the engine profile, serving both leases).
    fn joined(desk: &Arc<PermissionDesk>, audience: &str, turn: &str)->(PathBuf,ScopedPermissions) {
        let p=std::env::temp_dir().join(format!("permission-{}.json",uuid::Uuid::new_v4()));
        std::fs::write(&p,json!({"version":1,"actions_allowed":true,"binding":binding(audience,turn)}).to_string()).unwrap();
        (p.clone(),ScopedPermissions{desk:Arc::clone(desk),scope:p})
    }
    fn ask(policy: &ScopedPermissions, tool: &str, limit: Duration) -> std::thread::JoinHandle<PermissionDecision> {
        let child=policy.clone();let tool=tool.to_string();
        std::thread::spawn(move||child.wait(&json!({"tool_name":tool,"input":{"command":"fictional action"}}),limit))
    }
    fn wait_for(f: impl Fn()->bool) -> bool {
        for _ in 0..200 { if f() {return true;} std::thread::sleep(Duration::from_millis(5)); }
        false
    }

    #[test] fn provider_reason_survives_missing_human_explanation() {
        assert_eq!(permission_reason(&json!({"decision_reason_type":"safetyCheck","classifier_approvable":false})),"The provider requires manual approval for this command form.");
        assert_eq!(permission_reason(&json!({"decision_reason":"Exact provider reason","decision_reason_type":"safetyCheck"})),"Exact provider reason");
        assert_eq!(permission_reason(&json!({})),"");
    }
    #[test] fn allow_and_deny_apply_to_one_exact_request_and_never_persist_a_rule(){
        for allow in [true,false] {let (p,policy)=scope();
            let work=ask(&policy,"Bash",Duration::from_secs(2));
            assert!(wait_for(||policy.desk.current().is_some()));
            let request=policy.desk.current().unwrap();
            assert!(policy.desk.resolve("obsolete",true).is_err());
            assert_eq!(policy.desk.resolve(&request.id,allow).unwrap(),Answered::Delivered);
            assert_eq!(work.join().unwrap().behavior(),if allow {"allow"}else{"deny"});
            assert!(policy.desk.current().is_none());assert!(policy.desk.resolve(&request.id,true).is_err());std::fs::remove_file(p).unwrap();
        }
    }
    #[test] fn stop_and_expiry_never_approve_an_action(){
        let (p,policy)=scope();assert_eq!(policy.wait(&json!({"tool_name":"Bash"}),Duration::from_millis(1)).behavior(),"deny");
        let work=ask(&policy,"Bash",Duration::from_secs(2));
        assert!(wait_for(||policy.desk.current().is_some()));
        std::fs::remove_file(&p).unwrap();assert_eq!(work.join().unwrap().behavior(),"deny");assert!(policy.desk.current().is_none());
    }

    // ---- §5.2/§5.5: the queue ------------------------------------------------------------

    /// **§5.2's whole sentence.** A background request raised with no visible turn is NOT
    /// denied on the spot: it waits, it is visible where he will find it, and the answer he
    /// gives is the one that decides it.
    ///
    /// The positive control is the first assertion: the same code path with the SAME desk
    /// and a conversation binding whose grant has gone still denies at once
    /// (`stop_and_expiry_never_approve_an_action` above), so "it waited" is a fact about the
    /// background arm rather than about a desk that never refuses anything.
    #[test] fn a_background_request_with_no_visible_turn_waits_instead_of_being_denied(){
        let desk=Arc::new(PermissionDesk::default());
        let (p,work_lease)=joined(&desk,WORK_AUDIENCE,"obligation-7");
        let call=ask(&work_lease,"mcp__richos_work__integrate",Duration::from_secs(3));
        assert!(wait_for(||!desk.background_queue().is_empty()),"the request was refused rather than queued");
        // It is NOT on the conversation's sheet: a modal for background work would be an
        // interruption (§0 row 6).
        assert!(desk.current().is_none(),"a background request opened the permission sheet");
        let request=desk.background_queue().remove(0);
        assert_eq!(request.tool,"mcp__richos_work__integrate");
        assert_eq!(desk.resolve(&request.id,true).unwrap(),Answered::Delivered);
        assert_eq!(call.join().unwrap().behavior(),"allow");
        assert!(desk.background_queue().is_empty());
        std::fs::remove_file(p).unwrap();
    }

    /// **§5.5 and §5.6 in one shape.** Two workers ask at once. Neither refuses the other —
    /// the old desk answered the second with *"Another action is already waiting"* — the
    /// queue keeps his order, and answering the SECOND one releases only that worker while
    /// the first is still waiting.
    #[test] fn a_second_request_queues_behind_the_first_and_blocks_only_its_own_worker(){
        let desk=Arc::new(PermissionDesk::default());
        let (p1,one)=joined(&desk,WORK_AUDIENCE,"obligation-1");
        let (p2,two)=joined(&desk,WORK_AUDIENCE,"obligation-2");
        let first=ask(&one,"mcp__richos_work__integrate",Duration::from_secs(5));
        assert!(wait_for(||desk.background_queue().len()==1));
        let second=ask(&two,"Bash",Duration::from_secs(5));
        assert!(wait_for(||desk.background_queue().len()==2),"the second request was refused rather than queued");
        let queue=desk.background_queue();
        assert_eq!(queue[0].binding.turn_id,"obligation-1","the queue is not in the order they asked");
        assert_eq!(queue[1].binding.turn_id,"obligation-2");
        desk.resolve(&queue[1].id,true).unwrap();
        assert_eq!(second.join().unwrap().behavior(),"allow");
        // The first worker is STILL waiting: answering one assignment released one worker.
        assert_eq!(desk.background_queue().len(),1);
        assert!(!first.is_finished(),"answering the second request released the first worker too");
        desk.resolve(&desk.background_queue()[0].id,false).unwrap();
        assert_eq!(first.join().unwrap().behavior(),"deny");
        std::fs::remove_file(p1).unwrap();std::fs::remove_file(p2).unwrap();
    }

    // ---- §5.7: the deadline stops the CALL, not the REQUEST -------------------------------

    /// **§5.7, and it is the test the acceptance step 7.6 rests on.** The call ends at its
    /// deadline in *not approved* — never in approval — and the request is still there
    /// afterwards. His later answer goes to the ASSIGNMENT, and the standing decision it
    /// leaves lets the resumed run take that one exact action.
    #[test] fn the_deadline_ends_the_call_and_never_the_request(){
        let desk=Arc::new(PermissionDesk::default());
        let (p,work_lease)=joined(&desk,WORK_AUDIENCE,"obligation-7");
        let call=work_lease.wait(&json!({"tool_name":"mcp__richos_work__integrate","input":{"branch":"cc/x"}}),Duration::from_millis(30));
        assert_eq!(call.behavior(),"deny","the deadline approved something on his behalf");
        match &call { PermissionDecision::Deny{message}=>assert!(message.contains("has not been approved"),"{message}"), _=>unreachable!() }
        let waiting=desk.background_queue();
        assert_eq!(waiting.len(),1,"the request died with its call, so he could never answer it");
        // He answers an hour later. There is no call left to take it, so it goes to the
        // assignment — which is what the work host resumes.
        let answered=desk.resolve(&waiting[0].id,true).unwrap();
        match answered {
            Answered::ToAssignment{binding,allow}=>{
                assert!(allow);
                assert_eq!(assignment_key(&binding),("alpha".into(),"thread".into(),"obligation-7".into()));
            }
            other=>panic!("his late answer went nowhere: {other:?}"),
        }
        assert!(desk.background_queue().is_empty());
        // The resumed run asks for the SAME action and is allowed exactly once.
        let again=||work_lease.wait(&json!({"tool_name":"mcp__richos_work__integrate","input":{"branch":"cc/x"}}),Duration::from_millis(30));
        assert_eq!(again().behavior(),"allow","his approval never reached the step he approved");
        assert_eq!(again().behavior(),"deny","a standing decision was reused — that is an auto-approval");
        std::fs::remove_file(p).unwrap();
    }

    /// A standing decision is the narrowest thing that can carry his answer forward: same
    /// assignment, same tool, **same exact input**. A different action on the same
    /// assignment still has to ask.
    #[test] fn a_standing_decision_never_covers_a_different_action(){
        let desk=Arc::new(PermissionDesk::default());
        let (p,work_lease)=joined(&desk,WORK_AUDIENCE,"obligation-7");
        work_lease.wait(&json!({"tool_name":"mcp__richos_work__integrate","input":{"branch":"cc/x"}}),Duration::from_millis(20));
        let waiting=desk.background_queue();
        desk.resolve(&waiting[0].id,true).unwrap();
        // Same tool, different input.
        let other=work_lease.wait(&json!({"tool_name":"mcp__richos_work__integrate","input":{"branch":"cc/other"}}),Duration::from_millis(20));
        assert_eq!(other.behavior(),"deny","an approval for one branch approved another");
        // And it is still HIS: the different action is waiting for him, not thrown away.
        assert_eq!(desk.background_queue().len(),1);
        std::fs::remove_file(p).unwrap();
    }

    /// His DECLINE, given after the call ended, is carried to the assignment the same way —
    /// and the step he declined is refused if it is ever asked for again.
    #[test] fn a_decline_after_the_deadline_reaches_the_assignment_and_refuses_the_step(){
        let desk=Arc::new(PermissionDesk::default());
        let (p,work_lease)=joined(&desk,WORK_AUDIENCE,"obligation-7");
        work_lease.wait(&json!({"tool_name":"mcp__richos_work__integrate","input":{}}),Duration::from_millis(20));
        let waiting=desk.background_queue();
        match desk.resolve(&waiting[0].id,false).unwrap() {
            Answered::ToAssignment{allow,..}=>assert!(!allow),
            other=>panic!("{other:?}"),
        }
        assert_eq!(work_lease.wait(&json!({"tool_name":"mcp__richos_work__integrate","input":{}}),Duration::from_millis(20)).behavior(),"deny");
        std::fs::remove_file(p).unwrap();
    }

    /// **§5.4's unit of revocation, at this desk.** Stopping one assignment takes ITS
    /// question off his screen and leaves every other assignment's alone — and the worker
    /// waiting on the stopped one is released with a refusal rather than left hanging.
    #[test] fn forgetting_one_assignment_leaves_every_other_assignments_request_alone(){
        let desk=Arc::new(PermissionDesk::default());
        let (p1,one)=joined(&desk,WORK_AUDIENCE,"obligation-1");
        let (p2,two)=joined(&desk,WORK_AUDIENCE,"obligation-2");
        let first=ask(&one,"Bash",Duration::from_secs(5));
        let second=ask(&two,"Bash",Duration::from_secs(5));
        assert!(wait_for(||desk.background_queue().len()==2));
        assert_eq!(desk.forget("alpha","thread","obligation-1"),1);
        assert_eq!(first.join().unwrap().behavior(),"deny");
        assert_eq!(desk.background_queue().len(),1,"stopping one assignment took another's question away");
        assert_eq!(desk.background_queue()[0].binding.turn_id,"obligation-2");
        desk.resolve(&desk.background_queue()[0].id,false).unwrap();
        assert_eq!(second.join().unwrap().behavior(),"deny");
        std::fs::remove_file(p1).unwrap();std::fs::remove_file(p2).unwrap();
    }

    /// And a standing decision does not outlive its assignment either: forgetting the
    /// assignment drops it, so a later request cannot inherit an answer he gave about work
    /// that has since been stopped.
    #[test] fn forgetting_an_assignment_drops_the_standing_decision_too(){
        let desk=Arc::new(PermissionDesk::default());
        let (p,work_lease)=joined(&desk,WORK_AUDIENCE,"obligation-7");
        work_lease.wait(&json!({"tool_name":"mcp__richos_work__integrate","input":{}}),Duration::from_millis(20));
        let waiting=desk.background_queue();
        desk.resolve(&waiting[0].id,true).unwrap();
        desk.forget("alpha","thread","obligation-7");
        assert_eq!(work_lease.wait(&json!({"tool_name":"mcp__richos_work__integrate","input":{}}),Duration::from_millis(20)).behavior(),"deny");
        std::fs::remove_file(p).unwrap();
    }

    /// **`integrate` is not on the allow-list and this is the assertion of that absence**
    /// (§0 row 7). The four that are allowed are allowed; the fifth work tool reaches the
    /// desk and waits for him. A test naming only the four would stay green the day
    /// somebody adds a fifth.
    #[test] fn the_step_that_changes_his_repository_is_the_one_that_has_to_ask(){
        let desk=Arc::new(PermissionDesk::default());
        let (p,work_lease)=joined(&desk,WORK_AUDIENCE,"obligation-7");
        for tool in ["mcp__richos_work__repositories","mcp__richos_work__prepare","mcp__richos_work__inspect","mcp__richos_work__complete"] {
            assert_eq!(work_lease.wait(&json!({"tool_name":tool,"input":{}}),Duration::from_millis(20)).behavior(),"allow","{tool}");
        }
        assert!(desk.background_queue().is_empty(),"an allow-listed tool reached his queue");
        assert_eq!(work_lease.wait(&json!({"tool_name":"mcp__richos_work__integrate","input":{}}),Duration::from_millis(20)).behavior(),"deny");
        assert_eq!(desk.background_queue().len(),1,"integrate did not reach his queue");
        std::fs::remove_file(p).unwrap();
    }

    /// The conversation's own requests still die with their turn. §5.7's survival is for
    /// background work alone — a request tied to a turn he was watching, kept alive after
    /// that turn ended, is the *"one exact action, one visible turn"* rule broken.
    #[test] fn a_conversation_request_still_dies_with_its_turn(){
        let (p,policy)=scope();
        let call=policy.wait(&json!({"tool_name":"Bash","input":{}}),Duration::from_millis(20));
        assert_eq!(call.behavior(),"deny");
        assert!(policy.desk.current().is_none(),"the conversation's expired request is still on the sheet");
        assert!(policy.desk.background_queue().is_empty());
        std::fs::remove_file(p).unwrap();
    }
}
