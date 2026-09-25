//! Claude subscription windows and an opt-in background-turn admission policy.
//! Only normalized quota data leaves the reader. No account identity or billing data is retained.
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    fs, io,
    path::{Path, PathBuf},
    sync::Mutex,
};

pub mod gate;
pub mod holds;
pub mod probe;

pub const REFRESH_INTERVAL_MS: u64 = 5 * 60_000;
pub const RESET_EXEMPTION_MS: u64 = 20 * 60_000;
pub const BACKOFF_MS: u64 = 600_000;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Window {
    pub id: String,
    pub label: String,
    pub used_percent: f64,
    pub resets_at: Option<u64>,
    pub duration_ms: u64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Policy {
    pub enabled: bool,
    pub pause_percent: u8,
}
impl Default for Policy {
    fn default() -> Self {
        Self {
            enabled: false,
            pause_percent: 93,
        }
    }
}
impl Policy {
    pub fn validate(&self) -> Result<(), &'static str> {
        if !(1..=99).contains(&self.pause_percent) {
            return Err("Choose a pause threshold from 1% to 99% used.");
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum State {
    Fresh,
    Stale,
    Unavailable,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "state"
)]
pub enum Admission {
    Disabled,
    Ready,
    Held { resets_at: u64 },
    Unknown,
}
impl Admission {
    pub fn allows_work(&self) -> bool {
        matches!(self, Self::Disabled | Self::Ready)
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct View {
    pub state: State,
    pub windows: Vec<Window>,
    pub checked_at: Option<u64>,
    pub retry_at: Option<u64>,
    pub next_check_at: Option<u64>,
    pub refresh_interval_ms: u64,
    pub message: Option<String>,
    pub policy: Policy,
    pub admission: Admission,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ReadError {
    Unsupported,
    Failed,
    Malformed,
}
impl ReadError {
    fn message(self) -> &'static str {
        match self {
            Self::Unsupported => "Claude Code did not report subscription limits for this account.",
            Self::Failed => "Could not refresh Claude Code quota. Check your connection or account connection settings.",
            Self::Malformed => "Claude Code returned quota data this version of RichOS could not read.",
        }
    }
}

fn reset(value: &Value) -> Option<u64> {
    let text = value.as_str()?;
    let parsed =
        time::OffsetDateTime::parse(text, &time::format_description::well_known::Rfc3339).ok()?;
    u64::try_from(parsed.unix_timestamp_nanos() / 1_000_000).ok()
}

/// Recognized account-wide windows plus provider-named model weeklies. Unknown
/// billing/experimental buckets are deliberately not guessed into quota rows.
pub fn normalize(response: &Value) -> Result<Vec<Window>, ReadError> {
    match response
        .get("rate_limits_available")
        .and_then(Value::as_bool)
    {
        Some(false) => return Err(ReadError::Unsupported),
        Some(true) => {}
        None => return Err(ReadError::Malformed),
    }
    let limits = response
        .get("rate_limits")
        .and_then(Value::as_object)
        .ok_or(ReadError::Malformed)?;
    let mut windows = Vec::new();
    let mut append = |id: String, label: String, duration_ms: u64, value: &Value| {
        if let Some(used) = value
            .get("utilization")
            .and_then(Value::as_f64)
            .filter(|v| v.is_finite() && *v >= 0.0 && *v <= 100.0)
        {
            windows.push(Window {
                id,
                label,
                used_percent: used,
                resets_at: value.get("resets_at").and_then(reset),
                duration_ms,
            });
        }
    };
    for (id, label, hours) in [("five_hour", "Five-hour", 5), ("seven_day", "Weekly", 168)] {
        if let Some(value) = limits.get(id) {
            append(id.into(), label.into(), hours * 3_600_000, value);
        }
    }
    if let Some(models) = limits.get("model_scoped").and_then(Value::as_array) {
        for model in models.iter().take(32) {
            if let Some(name) = model
                .get("display_name")
                .and_then(Value::as_str)
                .filter(|s| !s.trim().is_empty())
            {
                let name: String = name.chars().filter(|c| !c.is_control()).take(80).collect();
                append(
                    format!("model:{name}"),
                    format!("Weekly · {name}"),
                    168 * 3_600_000,
                    model,
                );
            }
        }
    }
    // Older Claude versions name model windows directly.
    if !windows.iter().any(|w| w.id.starts_with("model:")) {
        for (key, label) in [
            ("seven_day_opus", "Weekly · Opus"),
            ("seven_day_sonnet", "Weekly · Sonnet"),
        ] {
            if let Some(value) = limits.get(key) {
                if let Some(used) = value
                    .get("utilization")
                    .and_then(Value::as_f64)
                    .filter(|v| v.is_finite() && (0.0..=100.0).contains(v))
                {
                    windows.push(Window {
                        id: key.into(),
                        label: label.into(),
                        used_percent: used,
                        resets_at: value.get("resets_at").and_then(reset),
                        duration_ms: 168 * 3_600_000,
                    });
                }
            }
        }
    }
    if windows.is_empty() {
        Err(ReadError::Malformed)
    } else {
        Ok(windows)
    }
}

pub trait Source: Send {
    fn read(&mut self, bin: &Path, cwd: &Path) -> Result<Vec<Window>, ReadError>;
    fn disconnect(&mut self) {}
}

#[derive(Default)]
struct Snapshot {
    windows: Vec<Window>,
    checked_at: Option<u64>,
    retry_at: Option<u64>,
    error: Option<ReadError>,
}
impl Snapshot {
    fn view(&self, policy: Policy, now: u64) -> View {
        let interval = REFRESH_INTERVAL_MS;
        let expired = self
            .windows
            .iter()
            .any(|w| w.resets_at.is_some_and(|t| t <= now));
        let fresh = self
            .checked_at
            .is_some_and(|t| now >= t && now - t < interval)
            && self.error.is_none()
            && !expired;
        let state = if self.checked_at.is_none() {
            State::Unavailable
        } else if fresh {
            State::Fresh
        } else {
            State::Stale
        };
        let admission = if !policy.enabled {
            Admission::Disabled
        } else if self.checked_at.is_none_or(|t| t > now) {
            Admission::Unknown
        } else {
            match self.windows.iter().find(|w| w.id == "five_hour") {
                Some(w)
                    if w.used_percent >= f64::from(policy.pause_percent)
                        && w.resets_at
                            .is_some_and(|t| t > now && t - now < RESET_EXEMPTION_MS) =>
                {
                    Admission::Ready
                }
                // Within the same window, a stale above-threshold value still proves a hold.
                Some(w)
                    if w.used_percent >= f64::from(policy.pause_percent)
                        && w.resets_at.is_some_and(|t| t > now) =>
                {
                    Admission::Held {
                        resets_at: w.resets_at.unwrap(),
                    }
                }
                Some(w) if fresh && w.resets_at.is_some_and(|t| t > now) => Admission::Ready,
                _ => Admission::Unknown,
            }
        };
        View {
            state,
            windows: self.windows.clone(),
            checked_at: self.checked_at,
            next_check_at: self.checked_at.map(|t| {
                self.windows
                    .iter()
                    .filter_map(|w| w.resets_at)
                    .filter(|r| *r > t)
                    .fold(t.saturating_add(interval), u64::min)
            }),
            refresh_interval_ms: interval,
            retry_at: self.retry_at.filter(|t| *t > now),
            message: self.error.map(|e| e.message().into()),
            policy,
            admission,
        }
    }
}

/// Probe I/O and published state have separate locks: a slow control reply cannot
/// freeze a scheduler, a settings paint or shutdown. Concurrent refreshes coalesce.
pub struct Service {
    source: Mutex<Box<dyn Source>>,
    snapshot: Mutex<Snapshot>,
    policy: Mutex<Policy>,
    policy_path: PathBuf,
    cwd: PathBuf,
    control: std::sync::Arc<probe::Control>,
    publication: Mutex<()>,
    connecting: std::sync::atomic::AtomicBool,
    refresh_requested: Mutex<bool>,
    refresh_wake: std::sync::Condvar,
}
impl Service {
    pub fn open(data_dir: &Path) -> io::Result<Self> {
        let policy_path = data_dir.join("claude-quota-policy.json");
        let policy = match fs::read(&policy_path) {
            Ok(bytes) => {
                let p: Policy = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
                p.validate().map_err(io::Error::other)?;
                p
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => Policy::default(),
            Err(e) => return Err(e),
        };
        let control = std::sync::Arc::new(probe::Control::default());
        let service = Self {
            source: Mutex::new(Box::new(probe::ClaudeSource::controlled(control.clone()))),
            snapshot: Mutex::new(Snapshot::default()),
            policy: Mutex::new(policy),
            policy_path,
            cwd: data_dir.to_path_buf(),
            control,
            publication: Mutex::new(()),
            connecting: std::sync::atomic::AtomicBool::new(false),
            refresh_requested: Mutex::new(true),
            refresh_wake: std::sync::Condvar::new(),
        };
        service.publish()?;
        Ok(service)
    }
    fn publish(&self) -> io::Result<()> {
        let _serial = self.publication.lock().unwrap();
        atomic_write(
            &self.cwd.join("engine-state/claude-quota.json"),
            &self.view(),
        )
    }
    pub fn view(&self) -> View {
        self.view_at(crate::util::now_millis())
    }
    /// Wake the desktop reader at a new-session boundary without blocking the
    /// session's launch or Stop controls on provider I/O. Bursts coalesce.
    pub fn request_refresh(&self) {
        *self.refresh_requested.lock().unwrap() = true;
        self.refresh_wake.notify_one();
    }
    /// The desktop monitor consumes this signal before applying the normal TTL.
    /// Startup begins signaled, even when automatic pausing is disabled.
    pub fn wait_for_refresh(&self, timeout: std::time::Duration) -> bool {
        let (mut requested, _) = self.refresh_wake.wait_timeout_while(
            self.refresh_requested.lock().unwrap(), timeout, |requested| !*requested,
        ).unwrap();
        std::mem::take(&mut *requested)
    }
    fn view_at(&self, now: u64) -> View {
        self.snapshot
            .lock()
            .unwrap()
            .view(self.policy.lock().unwrap().clone(), now)
    }
    pub fn set_policy(&self, policy: Policy) -> io::Result<View> {
        policy.validate().map_err(io::Error::other)?;
        let mut current = self.policy.lock().unwrap();
        atomic_write(&self.policy_path, &policy)?;
        *current = policy;
        drop(current);
        if let Err(error) = self.publish() {
            eprintln!("[richos] quota snapshot: {error}");
        }
        Ok(self.view())
    }
    pub fn refresh(&self, bin: &Path, force: bool) -> View {
        if self.is_shutdown() {
            return self.view();
        }
        let Ok(mut source) = self.source.try_lock() else {
            return self.view();
        };
        if self.connecting.load(std::sync::atomic::Ordering::SeqCst) {
            return self.view();
        }
        let now = crate::util::now_millis();
        let current = self.view_at(now);
        // Even a manual refresh honors failure backoff. Fresh manual requests have a
        // short cooldown so double-clicks cannot repeatedly hit the provider.
        if current.retry_at.is_some()
            || (!force && current.next_check_at.is_some_and(|t| t > now))
            || (force
                && current
                    .checked_at
                    .is_some_and(|t| now.saturating_sub(t) < 5_000))
        {
            return current;
        }
        let result = source.read(bin, &self.cwd);
        let observed = crate::util::now_millis();
        let mut snapshot = self.snapshot.lock().unwrap();
        match result {
            Ok(windows) => {
                *snapshot = Snapshot {
                    windows,
                    checked_at: Some(observed),
                    retry_at: None,
                    error: None,
                }
            }
            Err(error) => {
                if error == ReadError::Unsupported {
                    snapshot.windows.clear();
                    snapshot.checked_at = None;
                }
                snapshot.error = Some(error);
                snapshot.retry_at = Some(observed + BACKOFF_MS);
            }
        }
        drop(snapshot);
        if let Err(error) = self.publish() {
            eprintln!("[richos] quota snapshot: {error}");
        }
        self.view()
    }
    pub fn set_connecting(&self, connecting: bool) {
        if self
            .connecting
            .swap(connecting, std::sync::atomic::Ordering::SeqCst)
            != connecting
        {
            self.disconnect();
        }
    }
    /// Called when the account connection changes. Old account readings cannot survive it.
    pub fn disconnect(&self) {
        self.source.lock().unwrap().disconnect();
        *self.snapshot.lock().unwrap() = Snapshot::default();
        let _ = self.publish();
        self.request_refresh();
    }
    pub fn is_shutdown(&self) -> bool {
        self.control.stopped()
    }
    pub fn shutdown(&self) {
        self.control.stop();
        self.disconnect();
    }
}

fn atomic_write(path: &Path, value: &impl Serialize) -> io::Result<()> {
    use io::Write;
    fs::create_dir_all(
        path.parent()
            .ok_or_else(|| io::Error::other("missing parent"))?,
    )?;
    let temporary = path.with_extension(format!("{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut options = fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary)?;
        file.write_all(&serde_json::to_vec(value).map_err(io::Error::other)?)?;
        file.sync_all()?;
        fs::rename(&temporary, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(temporary);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    pub(super) struct Scratch(pub PathBuf);
    impl Scratch {
        pub fn new() -> Self {
            let path = std::env::temp_dir().join(format!("richos-quota-{}", uuid::Uuid::new_v4()));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }
        pub fn path(&self) -> &Path {
            &self.0
        }
    }
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    const NOW: u64 = 1_000_000_000;
    fn snapshot(used: f64, left: u64) -> Snapshot {
        Snapshot {
            windows: vec![Window {
                id: "five_hour".into(),
                label: "Five-hour".into(),
                used_percent: used,
                resets_at: Some(NOW + left),
                duration_ms: 18_000_000,
            }],
            checked_at: Some(NOW),
            ..Default::default()
        }
    }
    fn policy() -> Policy {
        Policy {
            enabled: true,
            ..Default::default()
        }
    }
    #[test]
    fn threshold_and_twenty_minute_boundaries() {
        assert_eq!(
            snapshot(92.99, RESET_EXEMPTION_MS)
                .view(policy(), NOW)
                .admission,
            Admission::Ready
        );
        assert!(matches!(
            snapshot(93., RESET_EXEMPTION_MS)
                .view(policy(), NOW)
                .admission,
            Admission::Held { .. }
        ));
        assert_eq!(
            snapshot(100., RESET_EXEMPTION_MS - 1)
                .view(policy(), NOW)
                .admission,
            Admission::Ready
        );
        assert_eq!(
            snapshot(93., 0).view(policy(), NOW).admission,
            Admission::Unknown
        );
        assert_eq!(
            snapshot(100., 0).view(Policy::default(), NOW).admission,
            Admission::Disabled
        );
        assert_eq!(
            snapshot(100., 1).view(policy(), NOW - 1).admission,
            Admission::Unknown
        );
    }
    #[test]
    fn five_minute_polling_at_every_usage_level_and_reset_deadline() {
        for used in [0., 69.99, 70., 93., 100.] {
            let interval = 300_000;
            let s = snapshot(used, 18_000_000);
            assert_eq!(s.view(policy(), NOW).next_check_at, Some(NOW + interval));
            assert_eq!(s.view(policy(), NOW + interval - 1).state, State::Fresh);
            assert_eq!(
                s.view(policy(), NOW + interval).state,
                State::Stale
            );
        }
        assert_eq!(
            snapshot(20., 60_000).view(policy(), NOW).next_check_at,
            Some(NOW + 60_000)
        );
    }
    #[test]
    fn stale_high_reading_holds_then_exempts_without_inventing_a_reset() {
        let mut s = snapshot(94., 3_600_000);
        s.error = Some(ReadError::Failed);
        assert!(matches!(
            s.view(policy(), NOW).admission,
            Admission::Held { .. }
        ));
        assert_eq!(
            s.view(policy(), NOW + 2_400_001).admission,
            Admission::Ready
        );
        assert_eq!(
            s.view(policy(), NOW + 3_600_000).admission,
            Admission::Unknown
        );
        s.windows[0].resets_at = None;
        assert_eq!(s.view(policy(), NOW).admission, Admission::Unknown);
    }
    #[test]
    fn normalization_ignores_billing_and_rejects_invalid_percentages() {
        let response = json!({"rate_limits_available":true,"session":{"secret":"never retained"},"rate_limits":{
            "five_hour":{"utilization":93,"resets_at":"2026-09-25T12:00:00Z"},
            "seven_day":{"utilization":101}, "extra_usage":{"utilization":45,"spend":100},
            "model_scoped":[{"display_name":"Fable","utilization":25,"resets_at":"bad"}]}});
        let windows = normalize(&response).unwrap();
        assert_eq!(windows.len(), 2);
        assert!(windows[0].resets_at.is_some());
        assert_eq!(windows[1].resets_at, None);
        assert_eq!(windows[1].label, "Weekly · Fable");
        assert!(!serde_json::to_string(&windows).unwrap().contains("secret"));
        assert_eq!(
            normalize(&json!({"rate_limits_available":false})),
            Err(ReadError::Unsupported)
        );
        assert_eq!(
            normalize(&json!({"rate_limits_available":true,"rate_limits":{}})),
            Err(ReadError::Malformed)
        );
    }
    struct FakeSource {
        calls: std::sync::Arc<std::sync::atomic::AtomicUsize>,
        result: Result<Vec<Window>, ReadError>,
    }
    impl Source for FakeSource {
        fn read(&mut self, _: &Path, _: &Path) -> Result<Vec<Window>, ReadError> {
            self.calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            self.result.clone()
        }
    }
    #[test]
    fn startup_and_session_signals_refresh_without_waiting_for_the_interval() {
        use std::time::Duration;
        use std::sync::atomic::Ordering;
        let dir = Scratch::new();
        let service = std::sync::Arc::new(Service::open(dir.path()).unwrap());
        let calls = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let mut windows = snapshot(20., 3_600_000).windows;
        windows[0].resets_at = Some(crate::util::now_millis() + 3_600_000);
        *service.source.lock().unwrap() = Box::new(FakeSource { calls: calls.clone(), result: Ok(windows) });
        assert!(!service.view().policy.enabled);
        assert!(service.wait_for_refresh(Duration::ZERO), "startup requests a read even with pause off");
        service.refresh(Path::new("unused"), true);
        assert_eq!(calls.load(Ordering::SeqCst), 1);

        // The reading is fresh but outside the short duplicate-request cooldown.
        service.snapshot.lock().unwrap().checked_at = Some(crate::util::now_millis() - 10_000);
        service.refresh(Path::new("unused"), false);
        assert_eq!(calls.load(Ordering::SeqCst), 1, "ordinary polling still uses the cache");
        let (tx, rx) = std::sync::mpsc::channel();
        let reader = service.clone();
        let thread = std::thread::spawn(move || {
            let force = reader.wait_for_refresh(Duration::from_secs(30));
            reader.refresh(Path::new("unused"), force);
            tx.send(force).unwrap();
        });
        service.request_refresh();
        assert!(rx.recv_timeout(Duration::from_secs(2)).unwrap(), "session start wakes the sleeping monitor");
        thread.join().unwrap();
        assert_eq!(calls.load(Ordering::SeqCst), 2, "session start bypasses the five-minute cache");
        service.request_refresh(); service.request_refresh();
        let force = service.wait_for_refresh(Duration::ZERO);
        assert!(force);
        service.refresh(Path::new("unused"), force);
        assert_eq!(calls.load(Ordering::SeqCst), 2, "simultaneous sessions share the just-completed read");
        assert!(!service.wait_for_refresh(Duration::ZERO));
        service.set_connecting(true);
        service.wait_for_refresh(Duration::ZERO);
        service.set_connecting(false);
        assert!(service.wait_for_refresh(Duration::ZERO), "sign-in completion wakes the reader");
        service.refresh(Path::new("unused"), true);
        assert_eq!(calls.load(Ordering::SeqCst), 3);
    }
    #[test]
    fn cache_failure_backoff_policy_persistence_and_account_invalidation() {
        let dir = Scratch::new();
        let service = Service::open(dir.path()).unwrap();
        let calls = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let mut windows = snapshot(69., 3_600_000).windows;
        windows[0].resets_at = Some(crate::util::now_millis() + 3_600_000);
        *service.source.lock().unwrap() = Box::new(FakeSource {
            calls: calls.clone(),
            result: Ok(windows),
        });
        service.refresh(Path::new("unused"), false);
        service.refresh(Path::new("unused"), false);
        service.refresh(Path::new("unused"), true);
        assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 1);
        service.set_policy(policy()).unwrap();
        assert!(Service::open(dir.path()).unwrap().view().policy.enabled);
        service.disconnect();
        assert_eq!(service.view().admission, Admission::Unknown);
        *service.source.lock().unwrap() = Box::new(FakeSource {
            calls: calls.clone(),
            result: Err(ReadError::Failed),
        });
        assert!(service
            .refresh(Path::new("unused"), true)
            .retry_at
            .is_some());
        service.refresh(Path::new("unused"), true);
        assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 2);
        assert_eq!(service.view().state, State::Unavailable);
        service.set_connecting(true);
        service.refresh(Path::new("unused"), true);
        assert_eq!(
            calls.load(std::sync::atomic::Ordering::SeqCst),
            2,
            "sign-in suspends quota reads"
        );
        service.set_connecting(false);
        service.refresh(Path::new("unused"), true);
        assert_eq!(
            calls.load(std::sync::atomic::Ordering::SeqCst),
            3,
            "new connection clears old backoff"
        );
    }
}
