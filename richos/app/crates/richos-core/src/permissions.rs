//! Native provider permission requests surfaced in the desktop. One exact action,
//! one visible turn. Decisions never become host-wide provider settings.
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
}
#[derive(Debug)]
struct Pending { request: PermissionRequest, scope: PathBuf, decision: Option<bool> }
#[derive(Debug, Default)]
pub struct PermissionDesk { pending: Mutex<Option<Pending>>, changed: Condvar }
#[derive(Clone, Debug)]
pub struct ScopedPermissions { pub desk: Arc<PermissionDesk>, pub scope: PathBuf }
#[derive(Deserialize)]
struct Grant { version: u32, actions_allowed: bool, binding: Binding }
fn grant(path: &Path) -> Option<Binding> {
    if std::fs::metadata(path).ok()?.len() > 16384 {return None;}
    let grant: Grant=serde_json::from_slice(&std::fs::read(path).ok()?).ok()?;
    (grant.version == 1 && grant.actions_allowed).then_some(grant.binding)
}
impl PermissionDesk {
    pub fn current(&self) -> Option<PermissionRequest> {
        self.pending.lock().unwrap().as_ref().filter(|p| grant(&p.scope).as_ref() == Some(&p.request.binding) && p.decision.is_none()).map(|p|p.request.clone())
    }
    pub fn resolve(&self, id: &str, allow: bool) -> Result<(), String> {
        let mut pending=self.pending.lock().unwrap();
        let item=pending.as_mut().ok_or_else(|| "That action is no longer waiting for permission.".to_string())?;
        if item.request.id != id || item.decision.is_some() || grant(&item.scope).as_ref() != Some(&item.request.binding) {
            return Err("That action's turn has stopped or changed. The old request cannot be approved.".into());
        }
        item.decision=Some(allow);self.changed.notify_all();Ok(())
    }
}
impl ScopedPermissions {
    pub fn decide(&self, request: &Value) -> PermissionDecision { self.wait(request,Duration::from_secs(300)) }
    fn wait(&self, request: &Value, limit: Duration) -> PermissionDecision {
        let deny=|message:&str|PermissionDecision::Deny{message:message.into()};
        let Some(binding)=grant(&self.scope) else {return deny("This app turn is stopped or is supplying context. New actions are unavailable.")};
        let tool=request["tool_name"].as_str().unwrap_or("");
        // These tools implement their own explicit host scope and write contracts.
        if matches!(tool,"mcp__richos_work__repositories"|"mcp__richos_work__prepare"|"mcp__richos_work__inspect"|"mcp__richos_continuity__checkpoint"|"mcp__richos_continuity__inspect"|
            "mcp__richos_onboarding__save_company_notes"|"mcp__richos_onboarding__decline_onboarding") {
            return PermissionDecision::Allow{updated_input:request.get("input").cloned().unwrap_or(json!({}))};
        }
        if tool.is_empty() || request.to_string().len()>65536 {return deny("The requested action could not be safely displayed.");}
        let id=uuid::Uuid::new_v4().to_string();
        let mut pending=self.desk.pending.lock().unwrap();
        if pending.is_some() {return deny("Another action is already waiting for permission. Reconcile it first.");}
        *pending=Some(Pending{request:PermissionRequest{id:id.clone(),binding:binding.clone(),tool:tool.into(),
            input:request.get("input").cloned().unwrap_or(json!({})),description:request["description"].as_str().unwrap_or("").into()},
            scope:self.scope.clone(),decision:None});
        let deadline=Instant::now()+limit;
        let decision=loop {
            if grant(&self.scope).as_ref()!=Some(&binding) {break deny("The app turn was stopped or changed before approval.");}
            if let Some(allow)=pending.as_ref().and_then(|p|p.decision) {
                break if allow {PermissionDecision::Allow{updated_input:request.get("input").cloned().unwrap_or(json!({}))}}
                    else {deny("The user declined this action. Do not retry it through another tool.")};
            }
            if Instant::now()>=deadline {break deny("No permission decision was received. The action was not approved.");}
            pending=self.desk.changed.wait_timeout(pending,Duration::from_millis(100)).unwrap().0;
        };
        *pending=None;decision
    }
}
#[cfg(test)] mod tests {
    use super::*;
    fn scope()->(PathBuf,ScopedPermissions) {
        let p=std::env::temp_dir().join(format!("permission-{}.json",uuid::Uuid::new_v4()));
        std::fs::write(&p,json!({"version":1,"actions_allowed":true,"binding":{"entity_id":"alpha","thread_id":"thread","session_id":"session","turn_id":"turn","audience":"ceo","revision":1}}).to_string()).unwrap();
        let policy=ScopedPermissions{desk:Arc::new(PermissionDesk::default()),scope:p.clone()};(p,policy)
    }
    #[test] fn allow_and_deny_apply_to_one_exact_request_and_never_persist_a_rule(){
        for allow in [true,false] {let (p,policy)=scope();let child=policy.clone();
            let work=std::thread::spawn(move||child.wait(&json!({"tool_name":"Bash","input":{"command":"fictional action"}}),Duration::from_secs(2)));
            let mut request=None;for _ in 0..100 {request=policy.desk.current();if request.is_some(){break;}std::thread::sleep(Duration::from_millis(5));}
            let request=request.unwrap();assert!(policy.desk.resolve("obsolete",true).is_err());policy.desk.resolve(&request.id,allow).unwrap();
            assert_eq!(work.join().unwrap().behavior(),if allow {"allow"}else{"deny"});assert!(policy.desk.current().is_none());assert!(policy.desk.resolve(&request.id,true).is_err());std::fs::remove_file(p).unwrap();
        }
    }
    #[test] fn stop_and_expiry_never_approve_an_action(){
        let (p,policy)=scope();assert_eq!(policy.wait(&json!({"tool_name":"Bash"}),Duration::from_millis(1)).behavior(),"deny");
        let child=policy.clone();let work=std::thread::spawn(move||child.wait(&json!({"tool_name":"Bash"}),Duration::from_secs(2)));
        for _ in 0..100 {if policy.desk.current().is_some(){break;}std::thread::sleep(Duration::from_millis(5));}
        std::fs::remove_file(&p).unwrap();assert_eq!(work.join().unwrap().behavior(),"deny");assert!(policy.desk.current().is_none());
    }
}
