//! Opt-in real provider dispatch through the desktop work tools, with synthetic repos.
use richos_core::{Cognition, EntityId, EntityRegistry, Ledger, Source, Spine};
use richos_core::{ecs::EcsBridge, native::{resolve_claude_bin, NativeCognition}};
use std::{path::PathBuf, sync::{Arc,atomic::{AtomicBool,Ordering}}, time::{Duration,Instant}};
struct Scratch(PathBuf);
impl Drop for Scratch{fn drop(&mut self){let _=std::fs::remove_dir_all(&self.0);}}
fn main()->Result<(),Box<dyn std::error::Error>>{
 let args:Vec<_>=std::env::args_os().skip(1).collect();
 if args.first().is_some_and(|a|a=="--onboarding-mcp"){richos_core::onboarding_tools::run_stdio(&PathBuf::from(&args[1]))?;return Ok(());}
 if args.len()!=2{return Err("usage: work_roundtrip ENGINE DELIVERED_RUNTIME".into());}
 let engine=std::fs::canonicalize(&args[0])?;
 let root=Scratch(std::env::temp_dir().join(format!("richos work {}",uuid::Uuid::new_v4())));
 let data=root.0.join("app data");std::fs::create_dir_all(data.join("corpus/ceo/records"))?;
 let runtime=richos_core::runtime::EngineRuntime::load(&engine,Some(&PathBuf::from(&args[1])))?;
 let mut profile=richos_core::engine_profile::EngineProfile::prepare(&engine,&data,runtime.clone())?;
 let desk=profile.permissions.clone();
 let mut registry=EntityRegistry::from_existing_ids(&[EntityId::parse("depot")?]);
 for name in ["first project","second project"]{
  let repo=root.0.join(name);std::fs::create_dir(&repo)?;
  registry=richos_core::repositories::connect(&registry,&EntityId::parse("depot")?,&repo,true,&runtime,&[&engine,&data])?.0;
 }
 registry.save(&data.join("entities.json"))?;
 let doctrine=richos_core::doctrine::ensure_rendered(&data,&Default::default())?;
 let skills=richos_core::skills::ensure_rendered(&data)?;
 let bridge=EcsBridge::new(&runtime.python,&engine,&data.join("ecs"))?;
 let mut spine=Spine::new(Ledger::open(&data.join("ledger.jsonl"))?);spine.set_entity_registry(registry);
 let thread=spine.create_thread("Fictional dispatch probe",&EntityId::parse("depot")?)?;
 profile.scope_to(&spine.ledger().thread_binding(&thread)?);
 let cognition=NativeCognition::start_with_engine(&resolve_claude_bin(),&doctrine,&skills,&std::env::current_exe()?,bridge.clone(),profile,None)?;
 let session=cognition.session_id().to_string();
 spine.set_central_root(data.join("corpus"));spine.set_onboarding_record(data.join("onboarding.json"));spine.attach_lease(Box::new(cognition));
 let finished=Arc::new(AtomicBool::new(false));
 let responder={let done=finished.clone();let desk=desk.clone();let expected_thread=thread.clone();std::thread::spawn(move||{
  let deadline=Instant::now()+Duration::from_secs(900);
  while !done.load(Ordering::SeqCst)&&Instant::now()<deadline{
   if let Some(request)=desk.current(){assert_eq!(request.binding.entity_id,"depot");assert_eq!(request.binding.thread_id,expected_thread);desk.resolve(&request.id,true).expect("synthetic fixture permission");}
   std::thread::sleep(Duration::from_millis(20));
  }
 })};
 let repo=std::fs::canonicalize(root.0.join("first project"))?;
 let prompt=format!("This is a disposable product integration test. Do exactly these operations. First use the continuity checkpoint tool to accept one commitment id marker-task, title Create the fictional marker. Then use richos_work.repositories to confirm the two connected repositories. Use richos_work.prepare with request_id marker-worker, obligation_id marker-task, repo {}, integration main, role worker and title Create fictional marker. Its brief must explicitly name the returned cross-repository target as the implementation directory (the native coordination worktree is not the target) and require the worker to create marker.txt containing exactly FICTIONAL in its assigned target worktree, read it, then commit only marker.txt using git -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgSign=false commit. No publication or other changes are authorized. Submit the returned agent_payload to Agent exactly, without reconstructing it or changing any field, and use TaskOutput with block:true to wait for that actual worker result. Call richos_work.inspect and report what actually happened. Do not implement the file yourself, integrate it or mark the assignment complete. Use only the described MCP tools, Agent and TaskOutput. Do not end by promising an action you have not taken.",repo.display());
 let turn=spine.submit_prompt(&prompt,Source::Text)?;
 let mut receipts=Vec::new();
 for partition in std::fs::read_dir(data.join("engine-state/work-receipts"))?{
  for file in std::fs::read_dir(partition?.path())?{
   let path=file?.path();if path.extension().is_some_and(|e|e=="json"){receipts.push(serde_json::from_slice::<serde_json::Value>(&std::fs::read(path)?)?);}
  }
 }
 assert_eq!(receipts.len(),1,"expected one actual prepared worker");let receipt=&receipts[0];
 if receipt["status"]!="run-ended"{eprintln!("receipt state: {}\nlast response: {}",receipt,spine.ledger().turn(&turn).unwrap().assistant_text);}
 assert_eq!(receipt["status"],"run-ended","provider run did not end");assert!(receipt["agent_id"].is_string());
 let target=data.join("engine-state/target-worktrees").join(receipt["name"].as_str().unwrap());
 assert_eq!(std::fs::read_to_string(target.join("marker.txt"))?.trim(),"FICTIONAL");assert!(!repo.join("marker.txt").exists());
 let head=std::process::Command::new(&runtime.git).arg("-C").arg(&target).args(["show","HEAD:marker.txt"]).output()?;
 if !head.status.success(){eprintln!("Git verification failed: {}\nProvider report: {}",String::from_utf8_lossy(&head.stderr),spine.ledger().turn(&turn).unwrap().assistant_text);}
 assert!(head.status.success());assert_eq!(String::from_utf8(head.stdout)?.trim(),"FICTIONAL");
 let binding=bridge.request("current",serde_json::json!({}))?["binding"].clone();
 let records=bridge.request("inspect",serde_json::json!({"binding":binding,"query":{"section":"work"}}))?;
 assert_eq!(records["records"].as_array().unwrap().len(),1);assert_ne!(records["records"][0]["status"],"completed");
 let transcript=std::fs::read_to_string(data.join("engine-state/evidence").join(receipt["binding"]["session_id"].as_str().unwrap()).join("guard-transcript.jsonl"))?;
 assert!(transcript.lines().filter_map(|line|serde_json::from_str::<serde_json::Value>(line).ok()).any(|row|row["evidenceSource"]=="richos-ledger-attested-hook-v1"),"visible user instruction was not attested from the ledger");
 // Replace the reasoning process while retaining the scoped obligation and work receipt.
 let mut replacement=richos_core::engine_profile::EngineProfile::prepare(&engine,&data,runtime.clone())?;
 replacement.scope_to(&spine.ledger().thread_binding(&thread)?);replacement.permissions=desk.clone();
 let fresh=NativeCognition::start_with_engine(&resolve_claude_bin(),&doctrine,&skills,&std::env::current_exe()?,bridge.clone(),replacement,None)?;
 assert_ne!(fresh.session_id(),session);spine.attach_lease(Box::new(fresh));
 let review_prompt=format!("The fictional worker's commit is ready. Its worker receipt is {}. Prepare an independent reviewer using richos_work.prepare: request_id marker-review, obligation_id marker-task, repo {}, integration main, role reviewer, review_of that worker receipt, title Review fictional marker. Require checking the exact prepared commit and confirming marker.txt contains exactly FICTIONAL with no other changes, without editing or creating commits. Submit the exact returned agent_payload to Agent once and wait through TaskOutput block:true. Then use richos_work.inspect. If the host captured a passing review, I authorize richos_work.integrate with this worker_id and the actual reviewer_id to fast-forward local main and perform canonical workspace cleanup. No publication. Report only verified results. Do not use Bash or write files yourself; use the work MCP tools, Agent and TaskOutput.",receipt["id"].as_str().unwrap(),repo.display());
 let reviewed=spine.submit_prompt(&review_prompt,Source::Text)?;
 finished.store(true,Ordering::SeqCst);responder.join().unwrap();
 let updated:serde_json::Value=serde_json::from_slice(&std::fs::read(data.join("engine-state/work-receipts").join(std::fs::read_dir(data.join("engine-state/work-receipts"))?.next().unwrap()?.file_name()).join(format!("{}.json",receipt["id"].as_str().unwrap())))?)?;
 if updated["integration"]["verified"]!=true {eprintln!("Review/integration report: {}\nReceipt: {}",spine.ledger().turn(&reviewed).unwrap().assistant_text,updated);}
 assert_eq!(updated["integration"]["verified"],true,"actual review/integration did not finish");
 assert_eq!(updated["integration"]["cleanup_pending"],serde_json::json!([]));
 assert_eq!(std::fs::read_to_string(repo.join("marker.txt"))?.trim(),"FICTIONAL");assert!(!target.exists());
 println!("{}",serde_json::json!({"real_worker_dispatched":true,"worker_commit_verified":true,"target_main_untouched_before_integration":true,"ecs_completion_not_inferred_from_exit":true,"fresh_provider_recovered_work":true,"real_reviewer_observed":true,"reviewed_commit_integrated":true,"canonical_cleanup_verified":true,"host_user_instruction_attested":true,"installed_acceptance":false}));drop(spine);Ok(())
}
