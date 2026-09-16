//! Real delivered Loro writer and ECS receipt projection using invented records.
use richos_core::{correction::{CliLoroWriter, CorrectionDesk, LoroWriteBackend, ProposedWrite}, ecs::EcsBridge, loro::{LoroRoot,LoroTools}, runtime::EngineRuntime};
use serde_json::json;
use std::path::PathBuf;
struct Scratch(PathBuf);
impl Drop for Scratch {fn drop(&mut self){let _=std::fs::remove_dir_all(&self.0);}}
fn main()->Result<(),Box<dyn std::error::Error>> {
 let args:Vec<_>=std::env::args_os().skip(1).collect();
 if args.len()!=2{return Err("usage: loro_ecs_roundtrip ENGINE DELIVERED_RUNTIME".into());}
 let engine=std::fs::canonicalize(&args[0])?;
 let runtime=EngineRuntime::load(&engine,Some(&PathBuf::from(&args[1])))?;
 let scratch=Scratch(std::env::temp_dir().join(format!("richos knowledge {}",uuid::Uuid::new_v4())));
 let corpus=scratch.0.join("corpus");std::fs::create_dir_all(corpus.join("ceo/records"))?;
 let mut tools=LoroTools::locate(engine.join("loro"))?;tools.set_node(runtime.node.to_string_lossy().into_owned());
 let writer=||CliLoroWriter::new(tools.clone(),LoroRoot::Corpus(corpus.clone()));
 let mut desk=CorrectionDesk::open(scratch.0.join("loro-corrections.jsonl"),Box::new(writer()))?;
 let proposed=desk.propose("depot","fictional-thread",ProposedWrite::Append {
   id:"fictional-colour".into(),kind:"decision".into(),scope:Some("ceo-private".into()),title:Some("Fictional marker colour".into()),
   body:"The fictional marker colour is blue.".into(),partition:Some("ceo".into())
 },"The fictional user explicitly requested this saved decision.")?;
 assert_eq!(std::fs::read_dir(corpus.join("ceo/records"))?.count(),0,"preview wrote a record");
 let first=desk.confirm("depot",&proposed.id)?.outcome.ok_or("missing writer outcome")?;
 assert!(!first.dry_run);assert!(writer().show(&first.r#ref)?.text.contains("blue"));
 let correction=desk.propose("depot","fictional-thread",ProposedWrite::Supersede {
   record_ref:first.r#ref.clone(),new_id:"fictional-colour-revised".into(),kind:"decision".into(),scope:Some("ceo-private".into()),body:"The fictional marker colour is green.".into()
 },"The fictional user corrected blue to green.")?;
 let second=desk.confirm("depot",&correction.id)?.outcome.ok_or("missing correction outcome")?;
 assert!(writer().show(&second.r#ref)?.text.contains("green"));
 assert!(writer().show(&first.r#ref)?.text.contains("blue"),"historical reference was lost");
 drop(desk);
 let bridge=EcsBridge::new(&runtime.python,&engine,&scratch.0.join("ecs"))?;
 let binding=bridge.request("bind",json!({"scope":{"entity_id":"depot","thread_id":"fictional-thread","session_id":"fictional-session","turn_id":"fictional-turn","audience":"ceo"},"request_id":"fictional-bind","source_ref":"ledger:fictional-thread:fictional-turn","expected_revision":null}))?["binding"].clone();
 let projected=bridge.request("sync-loro-receipts",json!({"binding":binding}))?;
 assert_eq!(projected["receipt_count"],2);assert_eq!(projected["writes_performed"],0);
 assert_eq!(bridge.request("sync-loro-receipts",json!({"binding":binding}))?,projected);
 let actions=bridge.request("inspect",json!({"binding":binding,"query":{"section":"actions","include_closed":true}}))?;
 assert_eq!(actions["records"].as_array().unwrap().len(),2);
 assert!(actions["records"].as_array().unwrap().iter().all(|row|row["state"]=="effect_verified"));
 let reopened=CorrectionDesk::open(scratch.0.join("loro-corrections.jsonl"),Box::new(writer()))?;
 assert!(reopened.desk_health().is_clean());
 println!("{}",json!({"actual_writer_append":true,"actual_writer_supersede":true,"historical_reference_readable":true,"ecs_confirmed_receipts":2,"ecs_writes_performed":0,"idempotent_projection":true,"installed_acceptance":false}));Ok(())
}
