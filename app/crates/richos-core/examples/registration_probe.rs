//! Tool-free native registration probe. No executor or reviewer is dispatched.
use richos_core::{autonomy, registration, run::{RunController, TaskState}};
use std::io::{self, Read};
fn main() {
    let mut input=String::new();io::stdin().read_to_string(&mut input).unwrap();
    let data:serde_json::Value=serde_json::from_str(&input).unwrap();
    let request=data["request"].as_str().unwrap();let reply=data["reply"].as_str().unwrap();
    let tail=data["tail"].as_str().unwrap_or("");
    let mut runs=vec![];
    let temporary=std::env::temp_dir().join(format!("richos-registration-probe-{}",uuid::Uuid::new_v4()));
    std::fs::create_dir(&temporary).unwrap();
    if data["has_run"]==true {
        let plan=autonomy::plan(&temporary,"Deliver the report","Deliver the report",vec![autonomy::WorkItem{id:"report".into(),description:"Deliver report.txt".into(),depends_on:vec![],criteria:"report.txt covers the approved figures".into()}]).unwrap();
        let ctl=RunController::create_named(&temporary.join("seed.jsonl"),plan,"00000000-0000-4000-8000-000000000001".into()).unwrap();
        let mut snapshot=ctl.snapshot().clone();drop(ctl);
        if data["pending_decision"]==true {
            snapshot.tasks[0].state=TaskState::NeedsDecision;
            snapshot.tasks[0].evidence=vec!["CEO_DECISION: Authorize ten more recovery cycles or end the assignment?".into()];
        }
        runs.push(snapshot);
    }
    let started=std::time::Instant::now();
    let result=registration::register(request,reply,tail,&runs,"");
    let output=match result {
        Ok((handoff,target))=>serde_json::json!({"handoff":handoff,"target":target,"seconds":started.elapsed().as_secs_f64()}),
        Err(error)=>serde_json::json!({"error":error,"seconds":started.elapsed().as_secs_f64()}),
    };
    println!("{output}");
    std::fs::remove_dir_all(temporary).unwrap();
}
