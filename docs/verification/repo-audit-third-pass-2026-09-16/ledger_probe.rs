use richos_core::{entity::EntityId, ledger::{Ledger,Source}, steering::{TurnControl,ActiveTurn}};
use std::{fs,io::Write};
fn torn(path: &std::path::Path) {
    let mut f=fs::OpenOptions::new().create(true).append(true).open(path).unwrap();
    f.write_all(b"{\"record\":\"interrupted").unwrap();
    f.sync_all().unwrap();
}
fn main() {
    let dir = std::env::temp_dir().join(format!("richos-ledger-audit-{}",std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let path=dir.join("ledger.jsonl");
    let entity=EntityId::parse("acme").unwrap();
    let original;
    {
        let mut ledger=Ledger::open(&path).unwrap();
        original=ledger.create_thread("original",&entity).unwrap();
    }
    torn(&path);
    let turn;
    {
        let mut ledger=Ledger::open(&path).unwrap();
        println!("original_survived_tail_damage={}",ledger.threads().iter().any(|t|t.id==original));
        println!("skipped_before_write={}",ledger.skipped_records().len());
        let binding=ledger.thread_binding(&original).unwrap();
        turn=ledger.record_prompt_received(&binding,"Important message after reopening",Source::Text).unwrap();
        println!("record_prompt_received_returned_ok=true");
        println!("new_prompt_visible_in_process={}",ledger.turn(&turn).is_some());
    }
    let ledger=Ledger::open(&path).unwrap();
    println!("new_prompt_survives_restart={}",ledger.turn(&turn).is_some());
    println!("skipped_after_restart={}",ledger.skipped_records().len());
    let intake=dir.join("intake.jsonl");
    torn(&intake);
    {
        let ctl=TurnControl::open(&intake).unwrap();
        ctl.begin_turn(ActiveTurn{turn_id:"turn_1".into(),thread_id:original.clone(),entity_id:Some(entity.clone()),started_at:Some(1)});
        ctl.steer("Important steering after reopening").unwrap();
        println!("steer_returned_ok=true");
        println!("pending_steering_before_restart={}",ctl.pending_intake().len());
    }
    let reopened=TurnControl::open(&intake).unwrap();
    println!("pending_steering_after_restart={}",reopened.pending_intake().len());
    fs::remove_dir_all(dir).unwrap();
}
