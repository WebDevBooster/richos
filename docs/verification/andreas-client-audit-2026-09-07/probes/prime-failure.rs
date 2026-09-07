use richos_core::{cognition::{Cognition,CognitionError,TurnItem},entity::{Entity,EntityId,EntityRegistry},ledger::{Ledger,Source,TurnState},live::{LiveEvent,LiveObserver},spine::Spine,steering::{TurnCancel,TurnControl,StopOutcome}};
use std::sync::{Arc,Mutex,mpsc,atomic::{AtomicUsize,Ordering}};
#[derive(Clone,Default)] struct Recorder(Arc<Mutex<Vec<String>>>);
impl LiveObserver for Recorder {fn on_live_event(&self,e:&LiveEvent){self.0.lock().unwrap().push(format!("{} {}",e.event_name(),e.payload()));}}
struct Cancel(Arc<AtomicUsize>);
impl TurnCancel for Cancel {fn cancel(&self)->bool{self.0.fetch_add(1,Ordering::SeqCst);true}}
struct BlockedPrime{entered:mpsc::Sender<()>,release:mpsc::Receiver<()>,cancels:Arc<AtomicUsize>,fail:bool}
impl Cognition for BlockedPrime {
 fn session_id(&self)->&str{"prime-probe"}
 fn reprime(&mut self,_:&str,_:&mut dyn FnMut(TurnItem))->Result<(),CognitionError>{self.entered.send(()).unwrap();self.release.recv().unwrap();if self.fail{Err(CognitionError::Io("synthetic upstream disconnect during first prime".into()))}else{Ok(())}}
 fn prompt(&mut self,_:&str,_:&mut dyn FnMut(TurnItem))->Result<String,CognitionError>{Ok("end_turn".into())}
 fn cancel_handle(&self)->Option<Arc<dyn TurnCancel>>{Some(Arc::new(Cancel(self.cancels.clone())))}
}
fn main(){
 let root=std::path::PathBuf::from(format!("/tmp/richos-audit-20260907/frank/prime-{}",std::process::id()));std::fs::create_dir_all(&root).unwrap();
 let path=root.join("ledger.jsonl"); let mut spine=Spine::new(Ledger::open(&path).unwrap());
 spine.set_entity_registry(EntityRegistry::new(vec![Entity::new("alpha","Alpha",&["/fixture/alpha"]).unwrap()]).unwrap());
 spine.ensure_active_thread_in(&EntityId::parse("alpha").unwrap()).unwrap();
 let control=TurnControl::open(root.join("intake.jsonl")).unwrap();spine.set_turn_control(control.clone());
 let recorder=Recorder::default();spine.set_live_observer(Box::new(recorder.clone()));
 let (entered_tx,entered_rx)=mpsc::channel();let (release_tx,release_rx)=mpsc::channel();let cancels=Arc::new(AtomicUsize::new(0));
 spine.attach_lease(Box::new(BlockedPrime{entered:entered_tx,release:release_rx,cancels:cancels.clone(),fail:true}));
 let worker=std::thread::spawn(move ||{let err=spine.submit_prompt("Let's do the twenty minutes of questions about my business.",Source::Text).unwrap_err();(spine,err.to_string())});
 entered_rx.recv_timeout(std::time::Duration::from_secs(10)).unwrap();
 assert!(control.active_turn().is_none());let stop=control.request_stop().unwrap();assert!(matches!(stop,StopOutcome::NothingRunning));assert_eq!(cancels.load(Ordering::SeqCst),0);
 println!("CONFIRMED: while first prime is actively running, Stop returns NothingRunning and never reaches attached cancel handler");
 release_tx.send(()).unwrap();let (spine,error)=worker.join().unwrap();
 let ceo=spine.ledger().turns().iter().find(|t|t.source==Source::Text).unwrap();
 assert_eq!(ceo.state,TurnState::Received);assert!(ceo.ended_at.is_none());assert!(ceo.started_at.is_none());
 let events=recorder.0.lock().unwrap();assert_eq!(events.len(),2);assert!(events.iter().all(|e|e.contains("queued")));
 println!("CONFIRMED: prime failure leaves CEO turn Received, no started_at or ended_at, queued-only live events");
 println!("invoke_error={error}");for event in events.iter(){println!("event={event}");}
 println!("CONFIRMED: actual in-memory queue depth={}, turn_in_progress={}, control_active={:?}",spine.queue_depth(),spine.is_turn_in_progress(),control.active_turn());
 drop(events);drop(spine);let reopened=Ledger::open(&path).unwrap();let recovered=reopened.turns().iter().find(|t|t.source==Source::Text).unwrap();println!("after_reopen_state={:?}",recovered.state);
 println!("evidence={}",root.display());
}
