//! Explicit opt-in proof. All account/offer reads are real. Redemption is
//! structurally replaced: this transport never forwards a redeem call to System.
use richos_core::quota::{reset_transport::System, resets::{Account, Service, Transport}};
use serde_json::{json, Value};
use std::path::Path;
struct NoRedemption { real: System, calls: usize }
impl Transport for NoRedemption {
    fn account(&mut self) -> Result<Account, String> { self.real.account() }
    fn usage(&mut self) -> Result<Value, String> { self.real.usage() }
    fn redeem(&mut self, _grant: &str, _request: &str) -> Result<Value, String> {
        self.calls += 1;
        Ok(json!({"result":"reset"}))
    }
}
fn main() -> Result<(), String> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() != 2 || args[0] != "--live-no-redemption" {
        return Err("Requires --live-no-redemption /absolute/path/to/claude".into());
    }
    let root = std::env::temp_dir().join(format!("terminal-quota-proof-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&root).map_err(|e| e.to_string())?;
    let result = (|| {
        let real = System::connect(Path::new(&args[1])).map_err(|e| format!("connect: {e}"))?;
        let mut transport = NoRedemption { real, calls: 0 };
        let service = Service::new(&root);
        let view = service.refresh_transport(&mut transport).map_err(|e| format!("read: {e}"))?;
        println!("{}", json!({"step":"read","result":"pass","weeklyUsed":view.weekly_used,
            "offers":view.offers.iter().map(|o| json!({"label":o.label,"remaining":o.remaining,"usableNow":o.usable_now,"clears":o.clears})).collect::<Vec<_>>() }));
        let offer = view.offers.iter().find(|o| o.remaining > 0 && o.clears.iter().any(|v| v == "seven_day"))
            .ok_or("No free weekly offer was returned; approval and trigger proof cannot proceed.")?;
        service.approve(offer)?;
        println!("{}",json!({"step":"approve","result":"pass","scope":"isolated proof record; explicitly requested by user"}));
        let peer = Service::new(&root);
        assert!(peer.view().approval.is_some());
        println!("{}",json!({"step":"arm","result":"pass","sharedApproval":true}));
        let result = peer.use_approved(&mut transport, || true);
        println!("{}",json!({"step":"trigger","result":if result.is_ok(){"pass"}else{"blocked"},"reason":result.err(),"fakeRedemptions":transport.calls,"realRedemptions":0}));
        service.revoke()?;
        assert!(peer.view().approval.is_none());
        println!("{}",json!({"step":"revoke","result":"pass"}));
        Ok(())
    })();
    let _cleanup = std::fs::remove_dir_all(root);
    result
}
