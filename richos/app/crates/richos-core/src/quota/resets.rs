//! Read-only offer polling and a separately authorized, one-use weekly reset action.
//! Neither polling nor approval redeems anything. Only the orchestrator's tool can
//! consume an approval, after fresh account, grant and weekly-usage checks.
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    fs, io,
    path::{Path, PathBuf},
};

pub const WEEKLY_THRESHOLD: f64 = 99.;
const FILE: &str = "claude-reset-offers.json";
const MAX_ATTEMPTS: usize = 128;

pub struct Account {
    pub key: String,
}
pub trait Transport {
    fn account(&mut self) -> Result<Account, String>;
    fn usage(&mut self) -> Result<Value, String>;
    fn redeem(&mut self, grant: &str, request: &str) -> Result<Value, String>;
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Offer {
    pub id: String,
    pub label: String,
    pub remaining: u32,
    pub starts_at: u64,
    pub expires_at: u64,
    pub clears: Vec<String>,
    pub usable_now: bool,
    pub requires_limit: bool,
}
impl Offer {
    fn weekly(&self, now: u64) -> bool {
        self.remaining > 0
            && self.starts_at <= now
            && self.expires_at > now
            && self.clears.iter().any(|s| s == "seven_day")
    }
    fn same_grant(&self, other: &Self) -> bool {
        self.id == other.id
            && self.starts_at == other.starts_at
            && self.expires_at == other.expires_at
            && self.clears == other.clears
            && self.remaining == other.remaining
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Approval {
    pub id: String,
    pub offer: Offer,
    pub approved_at: u64,
    pub weekly_threshold: u8,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Attempt {
    pub grant_id: String,
    pub request_id: String,
    pub at: u64,
    /// `uncertain` is durably written BEFORE the POST. A crash is never a fresh try.
    pub outcome: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    account: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct View {
    pub state: String,
    pub checked_at: Option<u64>,
    pub retry_at: Option<u64>,
    pub message: Option<String>,
    pub offers: Vec<Offer>,
    pub approval: Option<Approval>,
    pub last_attempt: Option<Attempt>,
    pub weekly_threshold: u8,
    #[serde(default)]
    pub weekly_used: Option<f64>,
    #[serde(default)]
    pub weekly_resets_at: Option<u64>,
}
impl Default for View {
    fn default() -> Self {
        Self {
            state: "unknown".into(),
            checked_at: None,
            retry_at: None,
            message: Some("Reset availability has not been checked.".into()),
            offers: vec![],
            approval: None,
            last_attempt: None,
            weekly_threshold: WEEKLY_THRESHOLD as u8,
            weekly_used: None,
            weekly_resets_at: None,
        }
    }
}
#[derive(Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Record {
    account: String,
    #[serde(default)]
    view: View,
    #[serde(default)]
    attempts: Vec<Attempt>,
}
struct Reading {
    offers: Vec<Offer>,
    eligible: bool,
    reason: Option<String>,
    next: Option<String>,
    weekly_used: Option<f64>,
    weekly_reset: Option<u64>,
    cooldown: Option<u64>,
}
pub(super) fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 40
        && id
            .bytes()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'_' || c == b'-')
}
fn parse(body: &Value) -> Result<Reading, String> {
    let b = body
        .get("cedar_ember")
        .filter(|v| v.is_object())
        .ok_or("Reset availability is unknown; Anthropic did not evaluate the offer.")?;
    let eligible = b
        .get("eligible")
        .and_then(Value::as_bool)
        .ok_or("Reset eligibility is unreadable.")?;
    let reason = b.get("ineligible_reason").and_then(Value::as_str).map(|s| match s {
        "surface" | "cli_version" => "This offer is not available through this Claude Code connection. Check Claude’s Usage page.",
        "no_grant" => "No reset offer is available for this account.",
        _ => "Anthropic is not offering a reset through this connection.",
    }.to_string());
    let grants = b
        .get("grants")
        .and_then(Value::as_array)
        .ok_or("Reset offers are unreadable.")?;
    if grants.len() > 64 {
        return Err("Too many reset offers to read safely.".into());
    }
    let mut offers = Vec::new();
    for g in grants {
        let id = g
            .get("id")
            .and_then(Value::as_str)
            .filter(|s| valid_id(s))
            .ok_or("Reset offer identity is unreadable.")?;
        let starts = g
            .get("starts_at")
            .and_then(super::reset)
            .ok_or("Reset start time is unreadable.")?;
        let expires = g
            .get("ends_at")
            .and_then(super::reset)
            .filter(|t| *t > starts)
            .ok_or("Reset expiry is unreadable.")?;
        let clears = g
            .get("clears")
            .and_then(Value::as_array)
            .ok_or("Reset limits are unreadable.")?;
        let mut limits: Vec<String> = clears
            .iter()
            .map(|v| {
                v.as_str()
                    .filter(|s| valid_id(s))
                    .map(String::from)
                    .ok_or_else(|| "Reset limits are unreadable.".to_string())
            })
            .collect::<Result<_, _>>()?;
        if limits.is_empty() || limits.len() > 32 {
            return Err("Reset limits are unreadable.".into());
        }
        limits.sort();
        limits.dedup();
        let remaining = g
            .get("resets_left")
            .and_then(Value::as_u64)
            .and_then(|v| u32::try_from(v).ok())
            .ok_or("Reset count is unreadable.")?;
        let paused = g
            .get("paused")
            .and_then(Value::as_bool)
            .ok_or("Reset availability is unreadable.")?;
        let usable = g
            .get("usable_now")
            .and_then(Value::as_bool)
            .ok_or("Reset availability is unreadable.")?;
        let requires = g
            .get("use_requires_limit")
            .and_then(Value::as_bool)
            .ok_or("Reset conditions are unreadable.")?;
        let blocking = g
            .get("blocking")
            .and_then(Value::as_array)
            .ok_or("Reset conditions are unreadable.")?;
        let label: String = g
            .get("label")
            .and_then(Value::as_str)
            .unwrap_or("Claude usage-limit reset")
            .chars()
            .filter(|c| !c.is_control())
            .take(160)
            .collect();
        if offers.iter().any(|o: &Offer| o.id == id) {
            return Err("Duplicate reset offer identity.".into());
        }
        offers.push(Offer {
            id: id.into(),
            label,
            remaining,
            starts_at: starts,
            expires_at: expires,
            clears: limits,
            usable_now: usable && !paused && blocking.is_empty(),
            requires_limit: requires,
        });
    }
    let weekly_used = body
        .pointer("/seven_day/utilization")
        .and_then(Value::as_f64)
        .filter(|n| n.is_finite() && (0. ..=100.).contains(n));
    Ok(Reading {
        offers,
        eligible,
        reason,
        next: b
            .get("next_grant_id")
            .and_then(Value::as_str)
            .map(String::from),
        weekly_used,
        weekly_reset: body.pointer("/seven_day/resets_at").and_then(super::reset),
        cooldown: b.get("cooldown_until").and_then(super::reset),
    })
}

pub struct Service {
    root: PathBuf,
}
impl Service {
    pub fn new(root: &Path) -> Self {
        Self { root: root.into() }
    }
    fn read(&self) -> Result<Record, String> {
        match super::gate::read_json(&self.root.join(FILE)) {
            Ok(v) => Ok(v),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(Record::default()),
            Err(_) => Err("The reset approval record is unreadable. No reset will be used.".into()),
        }
    }
    fn save(&self, record: &Record) -> Result<(), String> {
        super::atomic_write(&self.root.join(FILE), record)
            .and_then(|_| fs::File::open(&self.root)?.sync_all())
            .map_err(|_| "Could not save the reset record. No further action was taken.".into())
    }
    fn lock(&self) -> Result<fs::File, String> {
        fs::create_dir_all(&self.root).map_err(|_| "Reset storage unavailable.")?;
        let mut options = fs::OpenOptions::new();
        options.read(true).write(true).create(true).truncate(false);
        #[cfg(unix)]
        {
            use std::os::{fd::AsRawFd, unix::fs::OpenOptionsExt};
            options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
            let file = options
                .open(self.root.join("claude-reset-offers.lock"))
                .map_err(|_| "Reset lock unavailable.")?;
            if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
                return Err("A reset check or action is in progress. Try again shortly.".into());
            }
            Ok(file)
        }
        #[cfg(not(unix))]
        {
            Err("Reset approval is not supported on this platform yet.".into())
        }
    }
    pub fn prepared_action_due(&self, now: u64) -> bool {
        let Ok(record) = self.read() else {
            return false;
        };
        let v = Self::visible(record.view, now);
        v.state == "fresh"
            && v.approval.is_some()
            && v.weekly_used.is_some_and(|used| used >= WEEKLY_THRESHOLD)
            && v.weekly_resets_at.is_some_and(|until| until > now)
    }
    pub fn view(&self) -> View {
        let now = crate::util::now_millis();
        match self.read() {
            Ok(record) => Self::visible(record.view, now),
            Err(e) => View {
                message: Some(e),
                ..View::default()
            },
        }
    }
    fn visible(mut v: View, now: u64) -> View {
        if v.state == "fresh"
            && v.checked_at
                .is_none_or(|t| t > now || now - t >= super::REFRESH_INTERVAL_MS)
        {
            v.state = "stale".into();
            v.message = Some("Reset offers need a fresh check.".into());
        }
        v.offers.retain(|o| o.remaining > 0 && o.expires_at > now);
        if v.approval
            .as_ref()
            .is_some_and(|a| a.offer.expires_at <= now)
        {
            v.approval = None;
        }
        if let Some(a) = &mut v.last_attempt {
            a.account.clear();
        }
        v
    }
    fn update(record: &mut Record, account: Account, reading: Reading, now: u64) {
        if record.account != account.key {
            record.view.approval = None;
            record.view.last_attempt = None;
        }
        record.account = account.key;
        if record.view.approval.as_ref().is_some_and(|a| {
            !reading.eligible
                || !reading
                    .offers
                    .iter()
                    .any(|o| o.same_grant(&a.offer) && o.weekly(now))
        }) {
            record.view.approval = None;
        }
        record.view.weekly_used = reading.weekly_used;
        record.view.weekly_resets_at = reading.weekly_reset;
        record.view.offers = reading.offers;
        record.view.checked_at = Some(now);
        record.view.retry_at = None;
        record.view.state = if reading.eligible {
            "fresh"
        } else {
            "ineligible"
        }
        .into();
        record.view.message = reading.reason;
    }
    pub fn refresh(&self, bin: &Path, force: bool) -> View {
        let now = crate::util::now_millis();
        let Ok(_lock) = self.lock() else {
            return self.view();
        };
        let Ok(mut record) = self.read() else {
            return self.view();
        };
        let v = &record.view;
        if v.retry_at.is_some_and(|t| t > now)
            || v.checked_at.is_some_and(|t| {
                t <= now
                    && now - t
                        < if force {
                            5000
                        } else {
                            super::REFRESH_INTERVAL_MS
                        }
            })
        {
            return Self::visible(record.view, now);
        }
        // Tests supply a Transport explicitly. Unit tests must never touch real credentials.
        #[cfg(not(test))]
        let result = super::reset_transport::System::connect(bin)
            .and_then(|mut t| Self::read_transport(&mut t));
        #[cfg(test)]
        let result: Result<(Account, Reading), String> = {
            let _best_effort = bin;
            Err("Fixture has no reset connection.".into())
        };
        match result {
            Ok((account, reading)) => {
                Self::update(&mut record, account, reading, crate::util::now_millis())
            }
            Err(e) => {
                record.view.state = "unknown".into();
                record.view.message = Some(e);
                record.view.retry_at = Some(now + super::BACKOFF_MS);
            }
        }
        let _best_effort = self.save(&record);
        Self::visible(record.view, crate::util::now_millis())
    }
    fn read_transport(t: &mut dyn Transport) -> Result<(Account, Reading), String> {
        let account = t.account()?;
        if account.key.is_empty() {
            return Err("Claude account identity unavailable.".into());
        }
        Ok((account, parse(&t.usage()?)?))
    }
    pub fn clear_connection(&self) {
        if let Ok(_lock) = self.lock() {
            if let Ok(mut record) = self.read() {
                record.view = View::default();
                record.account.clear();
                let _best_effort = self.save(&record);
            }
        }
    }
    /// Called only by the desktop settings command. There is no MCP approval tool.
    pub fn approve(&self, offer: &Offer) -> Result<View, String> {
        let _lock = self.lock()?;
        let mut record = self.read()?;
        let now = crate::util::now_millis();
        let v = Self::visible(record.view.clone(), now);
        if v.state != "fresh"
            || record.account.is_empty()
            || !offer.weekly(now)
            || !v.offers.iter().any(|o| o.same_grant(offer))
        {
            return Err("Refresh reset offers before approving this offer.".into());
        }
        if Self::attempt_blocks(&record, &offer.id) || record.attempts.len() >= MAX_ATTEMPTS {
            return Err(
                "This reset already has a recorded attempt. Check its outcome in Claude.".into(),
            );
        }
        record.view.approval = Some(Approval {
            id: uuid::Uuid::new_v4().to_string(),
            offer: offer.clone(),
            approved_at: now,
            weekly_threshold: WEEKLY_THRESHOLD as u8,
        });
        self.save(&record)?;
        Ok(self.view())
    }
    pub fn revoke(&self) -> Result<View, String> {
        let _lock = self.lock()?;
        let mut record = self.read()?;
        record.view.approval = None;
        self.save(&record)?;
        Ok(self.view())
    }
    fn attempt_blocks(r: &Record, grant: &str) -> bool {
        r.attempts
            .iter()
            .any(|a| a.account == r.account && a.grant_id == grant && a.outcome != "notUsed")
    }
    pub fn use_approved(
        &self,
        t: &mut dyn Transport,
        still_authorized: impl Fn() -> bool,
    ) -> Result<View, String> {
        let lock = self.lock()?;
        let record = self.read()?;
        let approved = record
            .view
            .approval
            .clone()
            .ok_or("The user has not approved a weekly reset in Technical Settings.")?;
        let approval_account = record.account.clone();
        drop(lock); // A user can revoke approval while read-only preflight is in flight.
        if !still_authorized() {
            return Err("This work session is no longer authorized.".into());
        }
        let (account, reading) = Self::read_transport(t)?;
        let _lock = self.lock()?;
        let mut record = self.read()?;
        if record.account != approval_account
            || record
                .view
                .approval
                .as_ref()
                .is_none_or(|a| a.id != approved.id)
        {
            return Err(
                "Reset approval was revoked or replaced during the check. Nothing was used.".into(),
            );
        }
        let now = crate::util::now_millis();
        if account.key != record.account {
            Self::update(&mut record, account, reading, now);
            self.save(&record)?;
            return Err("The Claude account changed. Fresh user approval is required.".into());
        }
        let offer = reading
            .offers
            .iter()
            .find(|o| o.same_grant(&approved.offer) && o.weekly(now));
        let allowed = reading.eligible
            && offer.is_some_and(|o| o.usable_now)
            && reading.next.as_deref() == Some(approved.offer.id.as_str())
            && reading.cooldown.is_none_or(|until| until <= now)
            && reading
                .weekly_used
                .is_some_and(|used| used >= WEEKLY_THRESHOLD)
            && reading.weekly_reset.is_some_and(|reset| reset > now)
            && approved.weekly_threshold == WEEKLY_THRESHOLD as u8
            && !Self::attempt_blocks(&record, &approved.offer.id)
            && record.attempts.len() < MAX_ATTEMPTS;
        Self::update(&mut record, account, reading, now);
        self.save(&record)?;
        if !allowed {
            return Err("Reset not used: weekly usage must reach 99% and the approved weekly offer must still be usable.".into());
        }
        if !still_authorized() {
            return Err("This work session stopped before the reset. Nothing was used.".into());
        }
        let mut attempt = Attempt {
            grant_id: approved.offer.id.clone(),
            request_id: uuid::Uuid::new_v4().to_string(),
            at: now,
            outcome: "uncertain".into(),
            account: record.account.clone(),
        };
        record.view.approval = None;
        record.view.last_attempt = Some(attempt.clone());
        record.attempts.push(attempt.clone());
        self.save(&record)?; // durable one-use fence BEFORE any network write
        let result = t.redeem(&attempt.grant_id, &attempt.request_id);
        attempt.outcome = match result
            .as_ref()
            .ok()
            .and_then(|v| v.get("result"))
            .and_then(Value::as_str)
        {
            Some("reset") => "used",
            Some("already_used") => "alreadyUsed",
            Some("not_limited" | "cooldown" | "ineligible") => "notUsed",
            _ => "uncertain",
        }
        .into();
        record.view.last_attempt = Some(attempt.clone());
        *record.attempts.last_mut().unwrap() = attempt;
        record.view.state = "unknown".into();
        record.view.checked_at = None;
        record.view.retry_at = None;
        record.view.message =
            Some("A reset was attempted. Refresh quota to see the current allowance.".into());
        self.save(&record)?;
        // The desktop monitor will invalidate its cached quota reading at this marker.
        let _best_effort = super::atomic_write(
            &self.root.join("claude-reset-refresh.json"),
            &record.view.last_attempt,
        );
        Ok(self.view())
    }
}

#[cfg(test)]
mod tests {
    use super::super::tests::Scratch;
    use super::*;
    use serde_json::json;
    struct Fake {
        account: String,
        usage: Value,
        reply: Result<Value, String>,
        posts: usize,
    }
    impl Fake {
        fn new(weekly: f64) -> Self {
            Self {
                account: "account-a".into(),
                usage: json!({
                "five_hour":{"utilization":100},
                "seven_day":{"utilization":weekly,"resets_at":"2099-01-01T00:00:00Z"},
                "cedar_ember":{"eligible":true,"ineligible_reason":null,"next_grant_id":"launch","cooldown_until":null,
                    "grants":[{"id":"launch","label":"One weekly reset","resets_left":1,
                        "starts_at":"2020-01-01T00:00:00Z","ends_at":"2099-02-01T00:00:00Z",
                        "clears":["five_hour","seven_day"],"paused":false,"usable_now":true,"use_requires_limit":false,"blocking":[]}]}
                }),
                reply: Ok(json!({"result":"reset"})),
                posts: 0,
            }
        }
    }
    impl Transport for Fake {
        fn account(&mut self) -> Result<Account, String> {
            Ok(Account {
                key: self.account.clone(),
            })
        }
        fn usage(&mut self) -> Result<Value, String> {
            Ok(self.usage.clone())
        }
        fn redeem(&mut self, _: &str, request: &str) -> Result<Value, String> {
            assert!(uuid::Uuid::parse_str(request).is_ok());
            self.posts += 1;
            self.reply.clone()
        }
    }
    fn seeded(root: &Path, t: &mut Fake) -> Service {
        let s = Service::new(root);
        let mut record = Record::default();
        let (account, reading) = Service::read_transport(t).unwrap();
        Service::update(&mut record, account, reading, crate::util::now_millis());
        s.save(&record).unwrap();
        s
    }
    fn approve(s: &Service) {
        s.approve(&s.view().offers[0]).unwrap();
    }
    #[test]
    fn approval_can_be_given_early_and_armed_action_survives_restart() {
        let root = Scratch::new();
        let mut t = Fake::new(20.);
        let s = seeded(root.path(), &mut t);
        approve(&s);
        assert!(!s.prepared_action_due(crate::util::now_millis()));
        assert_eq!(t.posts, 0);
        assert_eq!(s.view().approval.unwrap().weekly_threshold, 99);
        let restarted = Service::new(root.path());
        assert!(restarted.use_approved(&mut t, || true).is_err());
        assert_eq!(t.posts, 0);
        t.usage["seven_day"]["utilization"] = json!(99.);
        let mut record = restarted.read().unwrap();
        let (account, reading) = Service::read_transport(&mut t).unwrap();
        Service::update(&mut record, account, reading, crate::util::now_millis());
        restarted.save(&record).unwrap();
        assert!(restarted.prepared_action_due(crate::util::now_millis()));
        let v = restarted.use_approved(&mut t, || true).unwrap();
        assert_eq!(v.last_attempt.unwrap().outcome, "used");
        assert!(v.approval.is_none());
        assert_eq!(t.posts, 1);
        assert!(restarted.use_approved(&mut t, || true).is_err());
        assert_eq!(t.posts, 1);
    }
    #[test]
    fn only_weekly_99_qualifies_never_the_five_hour_93_rule() {
        for weekly in [0., 93., 98.99, 99., 100.] {
            let root = Scratch::new();
            let mut t = Fake::new(weekly);
            let s = seeded(root.path(), &mut t);
            approve(&s);
            let result = s.use_approved(&mut t, || true);
            assert_eq!(result.is_ok(), weekly >= 99.);
            assert_eq!(t.posts, usize::from(weekly >= 99.));
        }
    }
    #[test]
    fn null_unknown_and_malformed_are_not_an_empty_inventory() {
        for value in [
            json!({}),
            json!({"cedar_ember":null}),
            json!({"cedar_ember":{"eligible":true}}),
        ] {
            assert!(parse(&value).is_err());
        }
        let mut t = Fake::new(99.);
        t.usage["cedar_ember"]["grants"][0]["ends_at"] = json!("bad");
        assert!(parse(&t.usage).is_err());
        t = Fake::new(99.);
        t.usage["cedar_ember"]["eligible"] = json!(false);
        t.usage["cedar_ember"]["ineligible_reason"] = json!("surface");
        assert!(parse(&t.usage)
            .unwrap()
            .reason
            .unwrap()
            .contains("Usage page"));
    }
    #[test]
    fn revocation_account_change_and_stopped_scope_never_post() {
        for case in ["revoke", "account", "stop"] {
            let root = Scratch::new();
            let mut t = Fake::new(99.);
            let s = seeded(root.path(), &mut t);
            approve(&s);
            match case {
                "revoke" => {
                    s.revoke().unwrap();
                }
                "account" => t.account = "account-b".into(),
                _ => {}
            }
            assert!(s.use_approved(&mut t, || case != "stop").is_err());
            assert_eq!(t.posts, 0);
            if case != "stop" {
                assert!(s.view().approval.is_none());
            }
        }
    }
    #[test]
    fn changed_grant_or_conditions_and_missing_weekly_reading_never_post() {
        for case in [
            "expiry", "count", "clears", "next", "paused", "usable", "cooldown", "weekly", "reset",
        ] {
            let root = Scratch::new();
            let mut t = Fake::new(99.);
            let s = seeded(root.path(), &mut t);
            approve(&s);
            match case {
                "expiry" => {
                    t.usage["cedar_ember"]["grants"][0]["ends_at"] = json!("2021-01-01T00:00:00Z")
                }
                "count" => t.usage["cedar_ember"]["grants"][0]["resets_left"] = json!(0),
                "clears" => t.usage["cedar_ember"]["grants"][0]["clears"] = json!(["five_hour"]),
                "next" => t.usage["cedar_ember"]["next_grant_id"] = json!("different"),
                "paused" => t.usage["cedar_ember"]["grants"][0]["paused"] = json!(true),
                "usable" => t.usage["cedar_ember"]["grants"][0]["usable_now"] = json!(false),
                "cooldown" => {
                    t.usage["cedar_ember"]["cooldown_until"] = json!("2099-01-01T00:00:00Z")
                }
                "weekly" => t.usage["seven_day"]["utilization"] = Value::Null,
                _ => t.usage["seven_day"]["resets_at"] = json!("2020-01-01T00:00:00Z"),
            }
            assert!(s.use_approved(&mut t, || true).is_err(), "{case}");
            assert_eq!(t.posts, 0, "{case}");
        }
    }
    #[test]
    fn no_approval_and_five_hour_only_offers_cannot_be_used() {
        let root = Scratch::new();
        let mut t = Fake::new(100.);
        let s = seeded(root.path(), &mut t);
        assert!(s.use_approved(&mut t, || true).is_err());
        assert_eq!(t.posts, 0);
        t.usage["cedar_ember"]["grants"][0]["clears"] = json!(["five_hour"]);
        let s = seeded(root.path(), &mut t);
        assert!(s.approve(&s.view().offers[0]).is_err());
    }
    #[test]
    fn timeout_and_crash_fence_survive_restart_and_prevent_duplicate_use() {
        for reply in [
            Err("timeout".into()),
            Ok(json!({"result":"unexpected"})),
            Ok(json!({"result":"already_used"})),
        ] {
            let root = Scratch::new();
            let mut t = Fake::new(99.);
            let s = seeded(root.path(), &mut t);
            approve(&s);
            t.reply = reply;
            let v = s.use_approved(&mut t, || true).unwrap();
            assert_ne!(v.last_attempt.unwrap().outcome, "used");
            let restarted = Service::new(root.path());
            assert!(restarted.use_approved(&mut t, || true).is_err());
            // Even refreshing a server response that still advertises the same grant
            // cannot remove the durable fence or let a stale Settings click reapprove it.
            let mut record = restarted.read().unwrap();
            let (account, reading) = Service::read_transport(&mut t).unwrap();
            Service::update(&mut record, account, reading, crate::util::now_millis());
            restarted.save(&record).unwrap();
            assert!(restarted.approve(&restarted.view().offers[0]).is_err());
            assert_eq!(t.posts, 1);
        }
    }
    #[test]
    fn disk_corruption_and_competing_process_lock_fail_closed() {
        let root = Scratch::new();
        let mut t = Fake::new(99.);
        let s = seeded(root.path(), &mut t);
        approve(&s);
        let lock = s.lock().unwrap();
        assert!(Service::new(root.path())
            .use_approved(&mut t, || true)
            .is_err());
        drop(lock);
        fs::write(root.path().join(FILE), "not-json").unwrap();
        assert!(s.use_approved(&mut t, || true).is_err());
        assert_eq!(t.posts, 0);
    }
    #[test]
    fn stopped_during_preflight_is_checked_again_before_post() {
        let root = Scratch::new();
        let mut t = Fake::new(99.);
        let s = seeded(root.path(), &mut t);
        approve(&s);
        let calls = std::cell::Cell::new(0);
        assert!(s
            .use_approved(&mut t, || {
                calls.set(calls.get() + 1);
                calls.get() == 1
            })
            .is_err());
        assert_eq!(t.posts, 0);
    }
    #[test]
    fn crash_after_durable_intent_never_reissues_a_post() {
        struct Crash(Fake);
        impl Transport for Crash {
            fn account(&mut self) -> Result<Account, String> {
                self.0.account()
            }
            fn usage(&mut self) -> Result<Value, String> {
                self.0.usage()
            }
            fn redeem(&mut self, _: &str, _: &str) -> Result<Value, String> {
                panic!("simulated process loss")
            }
        }
        let root = Scratch::new();
        let mut t = Fake::new(99.);
        let s = seeded(root.path(), &mut t);
        approve(&s);
        let _best_effort = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            s.use_approved(&mut Crash(Fake::new(99.)), || true)
        }));
        let restarted = Service::new(root.path());
        assert_eq!(restarted.view().last_attempt.unwrap().outcome, "uncertain");
        assert!(restarted.use_approved(&mut t, || true).is_err());
        assert_eq!(t.posts, 0);
    }
    #[test]
    fn revocation_during_network_preflight_prevents_the_post() {
        struct Revoking<'a> {
            service: &'a Service,
            fake: Fake,
        }
        impl Transport for Revoking<'_> {
            fn account(&mut self) -> Result<Account, String> {
                self.fake.account()
            }
            fn usage(&mut self) -> Result<Value, String> {
                self.service.revoke().unwrap();
                self.fake.usage()
            }
            fn redeem(&mut self, grant: &str, request: &str) -> Result<Value, String> {
                self.fake.redeem(grant, request)
            }
        }
        let root = Scratch::new();
        let mut fake = Fake::new(99.);
        let service = seeded(root.path(), &mut fake);
        approve(&service);
        let mut transport = Revoking {
            service: &service,
            fake,
        };
        assert!(service
            .use_approved(&mut transport, || true)
            .unwrap_err()
            .contains("revoked"));
        assert_eq!(transport.fake.posts, 0);
        assert!(service.view().approval.is_none());
    }
}
