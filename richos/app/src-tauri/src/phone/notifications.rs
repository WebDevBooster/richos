//! Native alerts contain opaque references only. The hosted service owns APNs keys.
//! Durable registration intent and pending events survive Mac/process/network failures.
use super::{connect::client::{Client, Reply}, device::Device, hex, sha256, unb64url};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

#[derive(Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Registration {
    pub token: String, pub environment: String, pub topic: String,
    #[serde(default)] pub preview_key: Option<String>,
    #[serde(default = "preview_default")] pub previews: bool,
}
fn preview_default() -> bool { true }
impl Registration {
    pub fn validate(&self) -> bool {
        (32..=512).contains(&self.token.len()) && self.token.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
            && ["sandbox","production"].contains(&self.environment.as_str())
            && self.preview_key.as_ref().is_none_or(|key| unb64url(key).is_ok_and(|bytes| bytes.len()==32))
            && ["dev.richos.mobile.loop","dev.richos.mobile.integration"].contains(&self.topic.as_str())
    }
}
#[derive(Clone, Serialize, Deserialize)]
struct Target { device: String, hash: String, registration: Registration, route: String }
#[derive(Clone, Serialize, Deserialize)]
struct Event { event: String, thread: String, expires: u64, #[serde(default)] preview: Option<Value> }
#[derive(Default, Serialize, Deserialize)]
struct State {
    revision: u64, target: Option<Target>, dirty: bool, host: Option<String>, generation: u64,
    jobs: Vec<Event>, delivered: Vec<String>,
}
pub trait Control { fn call(&self, method: &str, path: &str, body: &str) -> Result<Reply, String>; }
impl Control for Client {
    fn call(&self, method:&str,path:&str,body:&str)->Result<Reply,String> {Client::call(self,method,path,body).map_err(|_| unavailable())}
}
pub fn unavailable() -> String { "Reply notifications could not reach the service. Your conversation still works. Retry notifications in settings.".into() }
pub struct Desk { path: PathBuf, state: State }
impl Desk {
    // The runtime's action mutex serializes this file with pairing and revocation.
    pub fn open(directory:&Path)->Result<Self,String> {
        let path=directory.join("phone/native-notifications.json");
        let state=match std::fs::read(&path) {
            Ok(bytes) if bytes.len()<=256_000=>serde_json::from_slice::<State>(&bytes).map_err(|_|unavailable())?,
            Err(e) if e.kind()==std::io::ErrorKind::NotFound=>State::default(),
            _=>return Err(unavailable()),
        };
        if state.jobs.len()>100 || state.delivered.len()>1000 {return Err(unavailable())}
        Ok(Self {path,state})
    }
    fn save(&self)->Result<(),String> {
        use std::{io::Write,os::unix::fs::OpenOptionsExt};
        std::fs::create_dir_all(self.path.parent().unwrap()).map_err(|_|unavailable())?;
        let pending=self.path.with_extension("pending");
        let mut file=std::fs::OpenOptions::new().create(true).truncate(true).write(true).mode(0o600).open(&pending).map_err(|_|unavailable())?;
        file.write_all(&serde_json::to_vec(&self.state).map_err(|_|unavailable())?).map_err(|_|unavailable())?;
        file.sync_all().map_err(|_|unavailable())?;
        std::fs::rename(pending,&self.path).map_err(|_|unavailable())?;
        std::fs::File::open(self.path.parent().unwrap()).and_then(|f|f.sync_all()).map_err(|_|unavailable())
    }
    pub fn set(&mut self,device:&Device,registration:Option<Registration>)->Result<(),String> {
        if registration.as_ref().is_some_and(|r|!r.validate()) {return Err("Invalid notification registration".into())}
        self.state.revision=self.state.revision.saturating_add(1).max(super::now_millis());
        self.state.target=match registration {Some(registration)=>Some(Target {device:device.id.clone(),hash:hex(&sha256(&unb64url(&device.public_key).map_err(|_|unavailable())?)),registration,
            route:if device.paired_via==super::device::PairedVia::CONNECT {"connect"} else {"tailnet"}.into()}),None=>None};
        self.state.dirty=true;self.state.jobs.clear();self.state.delivered.clear();self.save()
    }
    pub fn clear(&mut self)->Result<(),String> {
        if self.state.target.is_none() && self.state.jobs.is_empty() {return Ok(())}
        self.state.revision=self.state.revision.saturating_add(1).max(super::now_millis());
        self.state.target=None;self.state.jobs.clear();self.state.dirty=true;self.save()
    }
    pub fn enabled_for(&self,device:&Device)->bool {self.state.target.as_ref().is_some_and(|t|t.device==device.id)}
    pub fn enqueue(&mut self,device:&Device,thread:&str,event:&str)->Result<(),String> {
        if !self.enabled_for(device) {return Ok(())}
        let event=hex(&sha256(event.as_bytes()));
        if self.state.delivered.contains(&event) || self.state.jobs.iter().any(|j|j.event==event) {return Ok(())}
        self.state.jobs.retain(|j|j.expires>super::now_millis());
        if self.state.jobs.len()>=100 {return Err(unavailable())}
        self.state.jobs.push(Event {event,thread:hex(&sha256(thread.as_bytes())),expires:super::now_millis()+3600000,preview:None});self.save()
    }
    pub fn reconcile(&mut self,control:&dyn Control,current:Option<&Device>)->Result<(),String> {
        if self.state.target.as_ref().is_some_and(|t|!current.is_some_and(|d|d.id==t.device && d.fingerprint_confirmed)) {self.clear()?;}
        self.state.jobs.retain(|j|j.expires>super::now_millis());
        if !self.state.dirty && self.state.jobs.is_empty() {return Ok(())}
        let enrollment=control.call("POST","/v1/push/hosts","{}")?;
        if enrollment.status!=200 {return Err(unavailable())}
        let host=enrollment.value["hostId"].as_str().filter(|s|s.len()==32 && s.bytes().all(|b|b.is_ascii_hexdigit())).ok_or_else(unavailable)?;
        let generation=enrollment.value["generation"].as_u64().filter(|g|*g>0).ok_or_else(unavailable)?;
        if self.state.generation!=generation {self.state.dirty=true;self.state.revision=self.state.revision.saturating_add(1).max(super::now_millis());}
        self.state.host=Some(host.into());self.state.generation=generation;self.save()?;
        if self.state.dirty {
            if let Some(target)=&self.state.target {
                if target.route=="connect" {
                    let result=control.call("PUT","/v1/host/device",&json!({"generation":generation,"deviceKeyHash":target.hash}).to_string())?;
                    if result.status!=200 {return Err(unavailable())}
                }
            }
            let body=match &self.state.target {
                Some(t)=>json!({"revision":self.state.revision,"generation":generation,"deviceHash":t.hash,"token":t.registration.token,"environment":t.registration.environment,"topic":t.registration.topic,"route":t.route}),
                None=>json!({"revision":self.state.revision,"generation":generation,"deviceHash":null,"token":null,"route":"tailnet"}),
            };
            let result=control.call("PUT","/v1/push/device",&body.to_string())?;
            if result.status!=200 {return Err(unavailable())}
            self.state.dirty=false;self.save()?;
        }
        while let (Some(target),Some(job))=(&self.state.target,self.state.jobs.first()) {
            let result=control.call("POST","/v1/push/events",&json!({"deviceHash":target.hash,"revision":self.state.revision,"eventRef":job.event,"threadRef":job.thread,"preview":job.preview}).to_string())?;
            if result.status==409 {self.state.dirty=true;self.state.revision=self.state.revision.saturating_add(1).max(super::now_millis());self.save()?;return Err(unavailable())}
            if result.status!=202 {return Err(unavailable())}
            self.state.delivered.push(job.event.clone());if self.state.delivered.len()>1000 {self.state.delivered.remove(0);}
            self.state.jobs.remove(0);self.save()?;
        }
        Ok(())
    }
    pub fn needs_reconcile(&self,current:Option<&Device>)->bool {
        self.state.dirty || !self.state.jobs.is_empty() || self.state.target.as_ref().is_some_and(|t|!current.is_some_and(|d|d.id==t.device && d.fingerprint_confirmed))
    }
    pub fn response(&self)->Value {json!({"host_id":self.state.host,"registered":self.state.target.is_some() && !self.state.dirty})}
}

pub fn queue_reply(desk:&mut Desk,device:&Device,thread:&str,payload:&Value)->Result<(),String> {
    let rows=super::rows::rows_from_payload(payload);
    let Some(row)=rows.iter().rev().find(|r|r["role"]=="rich" && r["complete"]!=false) else {return Ok(())};
    if device.delivered_cursor>=row["cursor"].as_u64() {return Ok(())}
    let Some(event)=row["id"].as_str() else {return Ok(())};
    desk.enqueue(device,thread,event)?;
    let event=hex(&sha256(event.as_bytes()));
    if let (Some(target),Some(job))=(&desk.state.target,desk.state.jobs.iter_mut().find(|job|job.event==event)) {
        if target.registration.previews && job.preview.is_none() {
            if let Some(key)=&target.registration.preview_key {
                job.preview=Some(seal_preview(key,&job.thread,&job.event,row["text"].as_str().unwrap_or(""))?);
                desk.save()?;
            }
        }
    }
    Ok(())
}

fn seal_preview(key:&str,thread:&str,event:&str,text:&str)->Result<Value,String> {
    use ring::aead::{Aad,LessSafeKey,Nonce,UnboundKey,AES_256_GCM};
    let key=LessSafeKey::new(UnboundKey::new(&AES_256_GCM,&unb64url(key).map_err(|_|unavailable())?).map_err(|_|unavailable())?);
    let nonce: [u8;12]=super::random_bytes(12).map_err(|_|unavailable())?.try_into().map_err(|_|unavailable())?;
    let mut body=text.split_whitespace().collect::<Vec<_>>().join(" ").chars().take(240).collect::<String>().into_bytes();
    let aad=format!("richos-preview-v1\n{thread}\n{event}");
    key.seal_in_place_append_tag(Nonce::assume_unique_for_key(nonce),Aad::from(aad.as_bytes()),&mut body).map_err(|_|unavailable())?;
    Ok(json!({"v":1,"nonce":super::b64url(&nonce),"body":super::b64url(&body)}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    struct Scratch(PathBuf);
    // Said, not asserted: a panic inside Drop while a failing test unwinds would abort the run.
    impl Drop for Scratch {fn drop(&mut self){if let Err(e)=std::fs::remove_dir_all(&self.0){eprintln!("test scratch {} was not removed: {e}",self.0.display());}}}
    fn fixture()->(Scratch,Device,Registration) {
        let dir=Scratch(std::env::temp_dir().join(format!("native-push-{}",hex(&super::super::random_bytes(12).unwrap()))));
        std::fs::create_dir_all(&dir.0).unwrap();
        let device:Device=serde_json::from_value(json!({"id":"phone","name":"iPhone","public_key":super::super::b64url(&[4;65]),"paired_at":1,"push":null,"delivered_cursor":null,"fingerprint_confirmed":true,"paired_via":"connect"})).unwrap();
        (dir,device,Registration{token:"a".repeat(64),environment:"sandbox".into(),topic:"dev.richos.mobile.integration".into(),preview_key:None,previews:true})
    }
    #[derive(Default)] struct Fake {calls:Mutex<Vec<(String,Value)>>, fail:Mutex<bool>, fail_events:Mutex<bool>}
    impl Control for Fake {
        fn call(&self,_method:&str,path:&str,body:&str)->Result<Reply,String> {
            self.calls.lock().unwrap().push((path.into(),serde_json::from_str(body).unwrap()));
            if *self.fail.lock().unwrap() || (path.ends_with("events") && *self.fail_events.lock().unwrap()) {return Err("offline".into())}
            Ok(Reply {status:if path.ends_with("events"){202}else{200},value:json!({"hostId":"a".repeat(32),"generation":1})})
        }
    }
    #[test] fn registration_intent_and_event_retry_survive_restart_without_content() {
        let (dir,device,registration)=fixture();let fake=Fake::default();*fake.fail.lock().unwrap()=true;
        let mut desk=Desk::open(&dir.0).unwrap();desk.set(&device,Some(registration)).unwrap();
        assert!(desk.reconcile(&fake,Some(&device)).is_err());drop(desk);
        let mut desk=Desk::open(&dir.0).unwrap();*fake.fail.lock().unwrap()=false;desk.reconcile(&fake,Some(&device)).unwrap();
        desk.enqueue(&device,"private title","private reply").unwrap();desk.reconcile(&fake,Some(&device)).unwrap();
        desk.enqueue(&device,"private title","private reply").unwrap();desk.reconcile(&fake,Some(&device)).unwrap();
        let calls=fake.calls.lock().unwrap();assert_eq!(calls.iter().filter(|(path,_)|path.ends_with("events")).count(),1);
        assert!(!serde_json::to_string(&*calls).unwrap().contains("private"));
        assert!(!std::fs::read_to_string(&desk.path).unwrap().contains("private"));
    }
    #[test] fn revocation_clears_queued_events_before_contacting_provider() {
        let (dir,device,registration)=fixture();let fake=Fake::default();
        let mut desk=Desk::open(&dir.0).unwrap();desk.set(&device,Some(registration)).unwrap();desk.enqueue(&device,"thread","reply").unwrap();
        *fake.fail.lock().unwrap()=true;assert!(desk.reconcile(&fake,None).is_err());drop(desk);
        let mut desk=Desk::open(&dir.0).unwrap();assert!(!desk.enabled_for(&device));assert!(desk.state.jobs.is_empty());
        *fake.fail.lock().unwrap()=false;desk.reconcile(&fake,None).unwrap();
        let calls=fake.calls.lock().unwrap();assert!(calls.iter().all(|(path,_)|!path.ends_with("events")));
        assert_eq!(calls.last().unwrap().1["token"],Value::Null);
    }
    #[test] fn failed_reply_delivery_remains_pending_after_restart() {
        let (dir,device,registration)=fixture();let fake=Fake::default();
        let mut desk=Desk::open(&dir.0).unwrap();
        desk.set(&device,Some(registration)).unwrap();desk.reconcile(&fake,Some(&device)).unwrap();
        desk.enqueue(&device,"thread","reply").unwrap();
        *fake.fail_events.lock().unwrap()=true;
        assert!(desk.reconcile(&fake,Some(&device)).is_err());drop(desk);
        let mut desk=Desk::open(&dir.0).unwrap();
        assert!(desk.needs_reconcile(Some(&device)));
        assert_eq!(desk.state.jobs.len(),1);
        *fake.fail_events.lock().unwrap()=false;
        desk.reconcile(&fake,Some(&device)).unwrap();
        assert!(!desk.needs_reconcile(Some(&device)));
        drop(desk);
        let mut desk=Desk::open(&dir.0).unwrap();
        desk.reconcile(&fake,Some(&device)).unwrap();
        let calls=fake.calls.lock().unwrap();
        assert_eq!(calls.iter().filter(|(path,_)|path.ends_with("events")).count(),2);
    }
    #[test] fn previews_are_authenticated_ciphertext_and_registration_keys_stay_on_mac() {
        use ring::aead::{Aad,LessSafeKey,Nonce,UnboundKey,AES_256_GCM};
        let (dir,device,mut registration)=fixture();let fake=Fake::default();
        let raw=[7u8;32];registration.preview_key=Some(super::super::b64url(&raw));
        let mut desk=Desk::open(&dir.0).unwrap();desk.set(&device,Some(registration)).unwrap();desk.reconcile(&fake,Some(&device)).unwrap();
        assert!(!serde_json::to_string(&*fake.calls.lock().unwrap()).unwrap().contains("preview_key"));
        let thread="b".repeat(64);let event="c".repeat(64);
        let sealed=seal_preview(&super::super::b64url(&raw),&thread,&event,"The supplier accepted £42,000.").unwrap();
        let nonce: [u8;12]=unb64url(sealed["nonce"].as_str().unwrap()).unwrap().try_into().unwrap();
        let mut bytes=unb64url(sealed["body"].as_str().unwrap()).unwrap();
        assert!(!sealed.to_string().contains("supplier"));
        let key=LessSafeKey::new(UnboundKey::new(&AES_256_GCM,&raw).unwrap());
        let aad=format!("richos-preview-v1\n{thread}\n{event}");
        assert_eq!(key.open_in_place(Nonce::assume_unique_for_key(nonce),Aad::from(aad.as_bytes()),&mut bytes).unwrap(),"The supplier accepted £42,000.".as_bytes());
        let mut bytes=unb64url(sealed["body"].as_str().unwrap()).unwrap();
        assert!(key.open_in_place(Nonce::assume_unique_for_key(nonce),Aad::from(b"wrong reply"),&mut bytes).is_err());
    }
    #[test] fn malformed_native_registrations_are_rejected() {
        let (_,_,mut r)=fixture();assert!(r.validate());r.topic="unrelated.app".into();assert!(!r.validate());
        r.topic="dev.richos.mobile.loop".into();r.environment="test".into();assert!(!r.validate());
        r.environment="production".into();r.token="../somewhere".into();assert!(!r.validate());
    }
}
