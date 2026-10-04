//! Claude subscription windows and an opt-in background-turn admission policy.
//! Only normalized quota data leaves the reader. No account identity or billing data is retained.
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::BTreeMap,
    fs, io,
    path::{Path, PathBuf},
    sync::Mutex,
};

pub mod gate;
pub mod holds;
pub mod probe;
pub mod resets;
pub mod terminal;
pub mod reset_transport;
pub mod reset_tools;

pub const REFRESH_INTERVAL_MS: u64 = 5 * 60_000;

/// **When usage speeds up a lot, or a big rise is expected, the quota is checked every MINUTE
/// instead of 5** (ruling §108: "every 2 minutes"; plan §15 answer 10: "use every minute
/// instead if that causes no problems", after measuring what one reading costs).
///
/// **The measurement, 2026-10-04, this Mac, Claude Code 2.1.288**, with
/// `cargo run -p richos-core --example claude_quota -- --measure <claude> N GAP`: a cold read
/// (spawn, initialize, `get_usage`) took 2.49-2.92 s; a warm read on the kept connection
/// 2.02-2.22 s; the child's CPU time grew 2.03-2.04 s per read with reads 6 s apart and
/// 2.29 s per read with reads 30 s apart — so the cost is the READ, not an idle child: about
/// 2.2 s of one core per read. The resident child is 390-430 MB. At one read a minute that is
/// about 3.7% of one core per account being read fast (2.2 / 60), only while usage is fast or
/// a rise is expected, and only for the account in use; at 2 minutes it would be 1.8%. Every
/// minute lets the act point sit closer to the normal one at the same speed (4 points a minute
/// projects 4 points ahead instead of 8), so it is the choice. The cost no measurement here can
/// show is Anthropic's side (a `get_usage` a minute per account); a failed read backs off
/// `BACKOFF_MS` as before.
pub const FAST_REFRESH_INTERVAL_MS: u64 = 60_000;

/// **An EXPECTED rise** (plan §15 answer 10): this many leases started, or agents dispatched,
/// within `EXPECTED_RISE_WINDOW_MS` switches checking to the fast interval before any jump is
/// measured, for `EXPECTED_RISE_MS`. Then it ends by itself unless a measured speed keeps it.
pub const EXPECTED_RISE_STARTS: usize = 3;
pub const EXPECTED_RISE_WINDOW_MS: u64 = 60_000;
pub const EXPECTED_RISE_MS: u64 = 10 * 60_000;

/// **"Speeds up a lot", as a number:** a window gaining 5 percentage points or more per
/// five-minute check, i.e. 1 point a minute. That is 3x the even pace of a five-hour window
/// (100 points / 300 minutes = 0.33 a minute) and it is the speed at which one ordinary check
/// interval eats most of the 7 points between the 93% rule and the wall. The episode §108
/// names went 93 -> 100 inside one check: at least 7 points in 5 minutes = 1.4 a minute.
pub const FAST_POINTS_PER_CHECK: f64 = 5.0;

/// The shortest gap two readings of one window must have before a speed is taken from them.
/// Turn-by-turn streamed readings can be seconds apart, and a speed from a 2-second gap is noise.
const SPEED_MIN_GAP_MS: u64 = 30_000;

/// One account's freshest reading: its windows and each window's measured speed.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Reading {
    pub windows: Vec<Window>,
    /// Window id -> percentage points per millisecond, from the last two readings of that
    /// same window (same reset time). Absent until two readings far enough apart exist.
    pub speeds: BTreeMap<String, f64>,
    /// A big rise is expected (many leases or agents started at once): check fast already.
    pub expected: bool,
}
impl Reading {
    /// Is usage measured fast enough to check every minute (§108)?
    pub fn fast(&self) -> bool {
        self.speeds.values().any(|s| s * REFRESH_INTERVAL_MS as f64 >= FAST_POINTS_PER_CHECK)
    }
    /// The gap to the next check: one minute when fast or a rise is expected, 5 otherwise.
    /// When the speed comes back down (and no rise is expected) it is 5 minutes again.
    pub fn interval(&self) -> u64 {
        if self.fast() || self.expected { FAST_REFRESH_INTERVAL_MS } else { REFRESH_INTERVAL_MS }
    }
    /// What this window will read at the next check, at its measured speed.
    pub fn projected(&self, window: &Window) -> f64 {
        window.used_percent + self.speeds.get(&window.id).copied().unwrap_or(0.) * self.interval() as f64
    }
    /// **The check point, recalculated from the measured speed** (plan §15 answer 10): the
    /// normal threshold (93% five-hour, 99% weekly), or lower when the speed would carry the
    /// window to 100% before the next check — `100 - speed x interval`. At normal speed it is
    /// the normal threshold again (answer 11).
    pub fn act_point(&self, window: &Window, threshold: f64) -> f64 {
        let reach = self.speeds.get(&window.id).copied().unwrap_or(0.) * self.interval() as f64;
        threshold.min(100. - reach)
    }
    /// **Act now?** At the check point (§108: never at 100%).
    pub fn reaches(&self, window: &Window, threshold: f64) -> bool {
        window.used_percent >= self.act_point(window, threshold)
    }
}
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
    #[serde(default)]
    pub resets: resets::View,
    pub state: State,
    pub windows: Vec<Window>,
    pub checked_at: Option<u64>,
    pub retry_at: Option<u64>,
    pub next_check_at: Option<u64>,
    pub refresh_interval_ms: u64,
    pub message: Option<String>,
    pub policy: Policy,
    pub admission: Admission,
    /// **Fill-first** (`claude_accounts.rs`). Every field below is additive and defaulted, so
    /// this file stays readable by its existing readers (`quota/gate.rs`, the desktop shell,
    /// `scripts/claude-quota.test.sh`), and every field above describes the account IN USE.
    /// One row per account; empty while there is only Account 1.
    #[serde(default)]
    pub accounts: Vec<crate::claude_accounts::AccountView>,
    /// Every account is exhausted: work is held until this moment, the soonest reset among
    /// them. The gate honors it (`gate.rs`). `None` with one account.
    #[serde(default)]
    pub held_until: Option<u64>,
    /// The setting for the five-hour threshold: Pause (default) or Switch.
    #[serde(default)]
    pub at_threshold: crate::claude_accounts::AtThreshold,
    /// Each window's measured speed, percentage points per millisecond (§108). Published so
    /// the separate-process gate projects exactly as this process does; `refreshIntervalMs`
    /// above reads 120000 while it is fast.
    #[serde(default)]
    pub speeds: BTreeMap<String, f64>,
    /// The check point of each window, percent used: 93 (five-hour) and 99 (weekly) at
    /// normal speed, lower while a measured speed would otherwise reach 100% between checks.
    #[serde(default)]
    pub act_at: BTreeMap<String, f64>,
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
    /// Each window's measured speed (§108), kept across readings of the same window.
    speeds: BTreeMap<String, f64>,
    /// Each window's speed base: the reading the next speed is measured from.
    bases: BTreeMap<String, SpeedBase>,
    /// A big rise is expected until this moment (plan §15 answer 10). It ends by itself.
    rise_until: Option<u64>,
}

/// One window's reading as a speed base: used percent, its reset time, and when it was read.
#[derive(Clone, Copy, Debug, PartialEq)]
struct SpeedBase { used: f64, resets_at: Option<u64>, at: u64 }

impl Snapshot {
    /// Measure each window's speed against its base, a reading of the SAME window (same reset
    /// time) at least `SPEED_MIN_GAP_MS` earlier. A new window starts again with no speed.
    fn measure(&mut self, windows: &[Window], observed: u64) {
        for window in windows {
            let fresh = SpeedBase { used: window.used_percent, resets_at: window.resets_at, at: observed };
            match self.bases.get(&window.id).copied() {
                Some(base) if base.resets_at == window.resets_at => {
                    if observed >= base.at + SPEED_MIN_GAP_MS {
                        let gained = (window.used_percent - base.used).max(0.);
                        self.speeds.insert(window.id.clone(), gained / (observed - base.at) as f64);
                        self.bases.insert(window.id.clone(), fresh);
                    }
                }
                _ => {
                    self.speeds.remove(&window.id);
                    self.bases.insert(window.id.clone(), fresh);
                }
            }
        }
    }
    fn reading(&self) -> Reading {
        self.reading_at(crate::util::now_millis())
    }
    fn reading_at(&self, now: u64) -> Reading {
        Reading { windows: self.windows.clone(), speeds: self.speeds.clone(),
            expected: self.rise_until.is_some_and(|t| t > now) }
    }
    fn accept(&mut self, mut windows: Vec<Window>, observed: u64) {
        self.measure(&windows, observed);
        // Missing weekly data is not evidence that a known weekly hold ended.
        let missing_held_weekly = (!windows.iter().any(|w| w.id == "seven_day"))
            .then(|| self.windows.iter().find(|w| w.id == "seven_day"
                && w.used_percent >= resets::WEEKLY_THRESHOLD).cloned()).flatten();
        let error = missing_held_weekly.as_ref().map(|_| ReadError::Malformed);
        if let Some(previous) = missing_held_weekly { windows.push(previous); }
        let speeds = std::mem::take(&mut self.speeds);
        let bases = std::mem::take(&mut self.bases);
        let rise_until = self.rise_until;
        *self = Self { windows, checked_at: Some(observed), retry_at: None, error, speeds, bases, rise_until };
    }
    /// **A reading the lease itself streamed** (`rate_limit_event`), merged window by window
    /// over the probe's. It never clears a probe error or its backoff; it only adds what it saw.
    fn observe(&mut self, windows: &[Window], observed: u64) {
        if self.checked_at.is_some_and(|t| observed <= t) { return; }
        self.measure(windows, observed);
        for window in windows {
            match self.windows.iter_mut().find(|w| w.id == window.id) {
                Some(existing) => *existing = window.clone(),
                None => self.windows.push(window.clone()),
            }
        }
        self.checked_at = Some(observed);
    }
    fn view(&self, policy: Policy, now: u64) -> View {
        let reading = self.reading_at(now);
        let interval = reading.interval();
        // The two check points, recalculated from the measured speed (answer 10), shown in
        // the panel; the normal 93% and 99% again once the speed is back down (answer 11).
        let act_at: BTreeMap<String, f64> = self.windows.iter().filter_map(|w| match w.id.as_str() {
            "five_hour" => Some((w.id.clone(), reading.act_point(w, f64::from(policy.pause_percent)))),
            "seven_day" => Some((w.id.clone(), reading.act_point(w, resets::WEEKLY_THRESHOLD))),
            _ => None,
        }).collect();
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
        } else if let Some(until) = self.windows.iter()
            .filter(|w| w.id == "seven_day" && reading.reaches(w, resets::WEEKLY_THRESHOLD))
            .filter_map(|w| w.resets_at.filter(|t| *t > now)).max() {
            // Weekly exhaustion never inherits the five-hour 20-minute exception.
            // An approval is not allowance: hold until a fresh post-reset reading.
            Admission::Held { resets_at: until }
        } else if self.windows.iter().any(|w| w.id == "seven_day"
            && reading.reaches(w, resets::WEEKLY_THRESHOLD)) {
            Admission::Unknown // Expired or unreadable weekly reset needs a new reading.
        } else {
            // §108: at normal speed the 93% rule exactly as before; at a measured fast speed
            // the pause comes EARLIER, when the next check would already find 100%. The
            // 20-minute exception still lets work continue near a reset, but only when the
            // measured speed would not carry the window to 100% before that reset.
            let speed = |w: &Window| reading.speeds.get(&w.id).copied().unwrap_or(0.);
            match self.windows.iter().find(|w| w.id == "five_hour") {
                Some(w)
                    if reading.reaches(w, f64::from(policy.pause_percent))
                        && w.resets_at
                            .is_some_and(|t| t > now && t - now < RESET_EXEMPTION_MS
                                && (speed(w) == 0.
                                    || w.used_percent + speed(w) * ((t - now) as f64) < 100.)) =>
                {
                    Admission::Ready
                }
                // Within the same window, a stale above-threshold value still proves a hold.
                Some(w)
                    if reading.reaches(w, f64::from(policy.pause_percent))
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
            resets: resets::View::default(),
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
            accounts: Vec::new(),
            held_until: None,
            at_threshold: Default::default(),
            speeds: self.speeds.clone(),
            act_at,
        }
    }
}

/// Probe I/O and published state have separate locks: a slow control reply cannot
/// freeze a scheduler, a settings paint or shutdown. Concurrent refreshes coalesce.
pub struct Service {
    pub resets: resets::Service,
    last_reset_marker: Mutex<Option<String>>,
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
    /// The account list and the switch decision (fill-first). `source` and `snapshot` above
    /// are Account 1's, exactly as before; every added account has its own pair here.
    pub accounts: std::sync::Arc<crate::claude_accounts::Accounts>,
    extra: Mutex<BTreeMap<String, AccountReader>>,
    /// **The high-speed alert** (plan §15 answer 9): written once when the account in use is
    /// first seen fast, taken once by whoever says it in the conversation.
    alert: Mutex<Option<String>>,
    was_fast: std::sync::atomic::AtomicBool,
    /// When leases and agent dispatches started, for the EXPECTED rise (answer 10).
    starts: Mutex<std::collections::VecDeque<u64>>,
}

/// The gate appends one line per agent dispatch here (`gate.rs`); the service counts them.
pub const DISPATCH_LOG: &str = "agent-dispatches.log";

/// An added account's own probe and its last reading.
type AccountReader = (Box<dyn Source>, Snapshot);
/// Windows a lease streamed, and when they were observed (epoch ms).
pub type StreamedReading = (Vec<Window>, u64);

/// Is a read due? The same rule Account 1's reader has always used: a manual refresh waits
/// only for the five-second double-click cooldown; the monitor's tick waits for the backoff
/// and the five-minute cache.
fn due(current: &View, force: bool, now: u64) -> bool {
    let last_attempt = [current.checked_at, current.retry_at.map(|t| t.saturating_sub(BACKOFF_MS))]
        .into_iter()
        .flatten()
        .filter(|t| *t <= now + 5_000)
        .max();
    let cooling = last_attempt.is_some_and(|t| now.saturating_sub(t) < 5_000);
    !if force {
        cooling
    } else {
        current.retry_at.is_some() || current.next_check_at.is_some_and(|t| t > now)
    }
}

impl Service {
    /// Production desktop entrypoint. Tests and simulations keep `open` isolated.
    pub fn open_account_wide(data_dir: &Path) -> io::Result<Self> {
        let reset_dir = terminal::data_dir().map_err(io::Error::other)?;
        Self::open_with_reset_dir(data_dir, &reset_dir)
    }
    fn open_with_reset_dir(data_dir: &Path, reset_dir: &Path) -> io::Result<Self> {
        let mut service = Self::open(data_dir)?;
        service.resets = resets::Service::new(reset_dir);
        service.resets.import_legacy(data_dir).map_err(io::Error::other)?;
        service.publish()?;
        Ok(service)
    }
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
            resets: resets::Service::new(data_dir),
            last_reset_marker: Mutex::new(None),
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
            accounts: std::sync::Arc::new(crate::claude_accounts::Accounts::open(data_dir)?),
            extra: Mutex::new(BTreeMap::new()),
            alert: Mutex::new(None),
            was_fast: std::sync::atomic::AtomicBool::new(false),
            starts: Mutex::new(std::collections::VecDeque::new()),
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
        let policy = self.policy.lock().unwrap().clone();
        let in_use = self.accounts.in_use();
        // The top-level reading is the account IN USE, so the pause gate and every existing
        // reader keep describing the subscription the work is actually running on.
        let mut view = if in_use.id == crate::claude_accounts::ACCOUNT_ONE {
            self.snapshot.lock().unwrap().view(policy.clone(), now)
        } else {
            match self.extra.lock().unwrap().get(&in_use.id) {
                Some((_, snapshot)) => snapshot.view(policy.clone(), now),
                None => Snapshot::default().view(policy.clone(), now),
            }
        };
        view.resets = self.resets.view();
        view.at_threshold = self.accounts.at_threshold();
        if self.accounts.count() > 1 {
            let readings = self.readings();
            view.accounts = self.accounts.list().into_iter().map(|account| {
                let account_view = if account.id == crate::claude_accounts::ACCOUNT_ONE {
                    self.snapshot.lock().unwrap().view(policy.clone(), now)
                } else {
                    self.extra.lock().unwrap().get(&account.id).map(|(_, s)| s.view(policy.clone(), now))
                        .unwrap_or_else(|| Snapshot::default().view(policy.clone(), now))
                };
                let exhausted = crate::claude_accounts::gone(
                    readings.get(&account.id).unwrap_or(&Reading::default()), view.at_threshold,
                    policy.pause_percent, self.accounts.limited_until(&account.id), now);
                crate::claude_accounts::AccountView {
                    in_use: account.id == in_use.id,
                    id: account.id,
                    label: account.label,
                    windows: account_view.windows,
                    checked_at: account_view.checked_at,
                    exhausted_until: exhausted.map(|(_, until)| until),
                    message: account_view.message,
                }
            }).collect();
            view.held_until = self.accounts.held_until(&readings, policy.pause_percent, now);
            if let Some(until) = view.held_until {
                view.admission = Admission::Held { resets_at: until };
            }
        }
        view
    }

    /// Every account's freshest reading (probe and streamed, merged in its snapshot), with
    /// each window's measured speed. Only accounts that have been read appear.
    fn readings(&self) -> BTreeMap<String, Reading> {
        let mut readings = BTreeMap::new();
        {
            let one = self.snapshot.lock().unwrap();
            if one.checked_at.is_some() {
                readings.insert(crate::claude_accounts::ACCOUNT_ONE.to_string(), one.reading());
            }
        }
        for (id, (_, snapshot)) in self.extra.lock().unwrap().iter() {
            if snapshot.checked_at.is_some() {
                readings.insert(id.clone(), snapshot.reading());
            }
        }
        readings
    }

    /// **Before EVERY turn** (the CEO's correction, 2026-10-04): merge the reading the lease
    /// on `account` streamed, if any (it is fresher than the five-minute probe), decide on the
    /// freshest readings whether the account in use must be left, and return the account that
    /// is in use now. The caller rotates its lease when that is not `account`; this is a turn
    /// boundary, so rotating is legal.
    pub fn before_turn(&self, account: &str, streamed: Option<StreamedReading>) -> String {
        if let Some((windows, observed)) = streamed {
            if account == crate::claude_accounts::ACCOUNT_ONE {
                self.snapshot.lock().unwrap().observe(&windows, observed);
            } else if let Some((_, snapshot)) = self.extra.lock().unwrap().get_mut(account) {
                snapshot.observe(&windows, observed);
            }
        }
        self.decide();
        self.note_speed();
        let _best_effort = self.publish();
        self.accounts.in_use().id
    }

    /// **Detect very high speed once** (plan §15 answer 9, the same detection that moves the
    /// switch and the pause earlier, `Reading::fast`). The alert is written on the first
    /// reading that finds the account in use fast, and not again until a reading finds it back
    /// at normal speed — so one burst is one alert.
    fn note_speed(&self) {
        let in_use = self.accounts.in_use();
        let Some(reading) = self.readings().remove(&in_use.id) else { return };
        let fast = reading.fast();
        let was = self.was_fast.swap(fast, std::sync::atomic::Ordering::SeqCst);
        if !fast || was { return; }
        let Some((window, per_ms)) = reading.windows.iter()
            .filter_map(|w| reading.speeds.get(&w.id).map(|s| (w, *s)))
            .max_by(|a, b| a.1.total_cmp(&b.1)) else { return };
        let name = if window.id == "five_hour" { "five-hour" } else if window.id == "seven_day" { "weekly" } else { window.label.as_str() };
        let whose = if self.accounts.count() > 1 { format!("{}'s {name}", in_use.label) } else { format!("the {name}") };
        // Said only when something will act: another account to switch to, or the pause on.
        let acts = self.accounts.count() > 1 || self.policy.lock().unwrap().enabled;
        let then = if acts { "and acts before it reaches 100%" } else { "Automatic pause is off in Settings" };
        *self.alert.lock().unwrap() = Some(format!(
            "Claude usage is very fast right now: {whose} limit is filling about {:.0}% a minute and is at {:.0}%. RichOS now checks every minute{}{then}.",
            per_ms * 60_000.0, window.used_percent, if acts { " " } else { ". " }));
    }

    /// **A lease was started** (the shell's lease factory, conversation or work). Several
    /// within a minute is an EXPECTED rise (plan §15 answer 10): checking goes to the fast
    /// interval now, before any jump is measured.
    pub fn lease_started(&self) {
        self.started(&[crate::util::now_millis()]);
    }

    fn started(&self, at: &[u64]) {
        let now = crate::util::now_millis();
        let expected = {
            let mut starts = self.starts.lock().unwrap();
            starts.extend(at.iter().copied());
            while starts.front().is_some_and(|t| *t + EXPECTED_RISE_WINDOW_MS < now) { starts.pop_front(); }
            starts.len() >= EXPECTED_RISE_STARTS
        };
        if expected {
            self.starts.lock().unwrap().clear();
            let until = Some(now + EXPECTED_RISE_MS);
            let in_use = self.accounts.in_use().id;
            if in_use == crate::claude_accounts::ACCOUNT_ONE {
                self.snapshot.lock().unwrap().rise_until = until;
            } else if let Some((_, snapshot)) = self.extra.lock().unwrap().get_mut(&in_use) {
                snapshot.rise_until = until;
            }
            self.request_refresh();
            let _best_effort = self.publish();
        }
    }

    /// The agent dispatches the gate wrote since the last look (a large parallel job is an
    /// expected rise too). The file is emptied after each look, so it stays small.
    fn take_dispatches(&self) {
        let path = self.cwd.join("engine-state").join(DISPATCH_LOG);
        let Ok(text) = fs::read_to_string(&path) else { return };
        if text.is_empty() { return; }
        let _best_effort = fs::write(&path, b"");
        let at: Vec<u64> = text.lines().filter_map(|l| l.trim().parse().ok()).collect();
        self.started(&at);
    }

    /// The high-speed alert, taken once by whoever says it in the conversation.
    pub fn take_alert(&self) -> Option<String> {
        self.alert.lock().unwrap().take()
    }

    fn decide(&self) {
        let pause = self.policy.lock().unwrap().pause_percent;
        match self.accounts.evaluate(&self.readings(), pause, crate::util::now_millis()) {
            Ok(true) => {
                if let Err(error) = self.publish() { eprintln!("[richos] quota snapshot: {error}"); }
            }
            Ok(false) => {}
            Err(error) => eprintln!("[richos] claude accounts: the switch could not be saved ({error})"),
        }
    }

    /// **The backstop**: a turn on `account` was refused by a usage limit anyway.
    pub fn limit_reached(&self, account: &str, resets_at: Option<u64>) -> crate::claude_accounts::AfterLimit {
        let pause = self.policy.lock().unwrap().pause_percent;
        let outcome = self.accounts.limit_reached(account, resets_at, &self.readings(), pause, crate::util::now_millis())
            .unwrap_or(crate::claude_accounts::AfterLimit::NoRoom);
        if let Err(error) = self.publish() { eprintln!("[richos] quota snapshot: {error}"); }
        outcome
    }

    /// The folder a lease on the account in use runs under, and that account's id.
    pub fn lease_account(&self) -> crate::claude_accounts::Account {
        self.accounts.in_use()
    }

    pub fn add_account(&self, label: &str) -> io::Result<View> {
        self.accounts.add(label)?;
        self.request_refresh();
        let _best_effort = self.publish();
        Ok(self.view())
    }

    pub fn remove_account(&self, id: &str) -> io::Result<View> {
        self.accounts.remove(id)?;
        self.extra.lock().unwrap().remove(id);
        let _best_effort = self.publish();
        Ok(self.view())
    }

    pub fn set_at_threshold(&self, value: crate::claude_accounts::AtThreshold) -> io::Result<View> {
        self.accounts.set_at_threshold(value)?;
        self.decide();
        let _best_effort = self.publish();
        Ok(self.view())
    }

    /// Read every added account on the same schedule as Account 1, one control-only child
    /// each, under its own folder.
    fn refresh_accounts(&self, bin: &Path, force: bool) {
        let policy = self.policy.lock().unwrap().clone();
        for account in self.accounts.list() {
            if account.id == crate::claude_accounts::ACCOUNT_ONE || self.is_shutdown() { continue; }
            let Some(folder) = account.folder.clone() else { continue };
            let now = crate::util::now_millis();
            let current = {
                let mut extra = self.extra.lock().unwrap();
                let (_, snapshot) = extra.entry(account.id.clone()).or_insert_with(|| (
                    Box::new(probe::ClaudeSource::for_folder(self.control.clone(), folder)) as Box<dyn Source>,
                    Snapshot::default()));
                snapshot.view(policy.clone(), now)
            };
            if !due(&current, force, now) { continue; }
            // Taken out of the map for the read, so a slow provider never holds the lock a
            // settings paint needs.
            let Some((mut source, _)) = self.extra.lock().unwrap().get_mut(&account.id)
                .map(|(s, snap)| (std::mem::replace(s, Box::new(probe::ClaudeSource::default())), snap.checked_at)) else { continue };
            let result = source.read(bin, &self.cwd);
            let observed = crate::util::now_millis();
            let mut extra = self.extra.lock().unwrap();
            let Some((slot, snapshot)) = extra.get_mut(&account.id) else { continue };
            *slot = source;
            match result {
                Ok(windows) => snapshot.accept(windows, observed),
                Err(error) => {
                    if error == ReadError::Unsupported {
                        snapshot.windows.clear();
                        snapshot.checked_at = None;
                    }
                    snapshot.error = Some(error);
                    snapshot.retry_at = Some(observed + BACKOFF_MS);
                }
            }
        }
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
        if self.is_shutdown() || self.connecting.load(std::sync::atomic::Ordering::SeqCst) { return self.view(); }
        self.take_dispatches();
        let marker = self.resets.marker();
        let changed = {
            let mut last = self.last_reset_marker.lock().unwrap();
            if marker != *last { *last = marker; true } else { false }
        };
        if changed {
            self.source.lock().unwrap().disconnect();
            *self.snapshot.lock().unwrap() = Snapshot::default();
        }
        self.refresh_windows(bin, force || changed);
        if self.accounts.count() > 1 {
            self.refresh_accounts(bin, force);
            self.decide();
            if let Err(error) = self.publish() { eprintln!("[richos] quota snapshot: {error}"); }
        }
        self.note_speed();
        self.resets.refresh(bin, force || changed);
        self.view()
    }
    /// Run the user's prepared weekly action without depending on another model turn.
    /// Only the desktop monitor calls this; settings reads and approval never redeem.
    pub fn run_approved_weekly_reset(&self, bin: &Path) {
        if self.is_shutdown() || self.connecting.load(std::sync::atomic::Ordering::SeqCst) { return; }
        #[cfg(not(test))]
        self.resets.tick(bin, || !self.is_shutdown()
            && !self.connecting.load(std::sync::atomic::Ordering::SeqCst));
        #[cfg(test)] let _unused = bin;
    }
    fn refresh_windows(&self, bin: &Path, force: bool) -> View {
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
        // Account 1's own reading (the account in use may be another one).
        let current = self.snapshot.lock().unwrap().view(self.policy.lock().unwrap().clone(), now);
        // **A manual refresh does not wait out the automatic failure backoff.** The backoff
        // protects the provider from the monitor's ticks; a person who fixed the problem and
        // asked again is owed a real check. What still protects the provider from him is the
        // short cooldown against double-clicks, measured from the last attempt of any kind —
        // a failure's `retry_at` is set `BACKOFF_MS` past the attempt that caused it.
        if !due(&current, force, now) {
            return self.view();
        }
        let result = source.read(bin, &self.cwd);
        let observed = crate::util::now_millis();
        let mut snapshot = self.snapshot.lock().unwrap();
        match result {
            Ok(windows) => {
                snapshot.accept(windows, observed);
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
        self.resets.clear_connection();
        *self.snapshot.lock().unwrap() = Snapshot::default();
        let _best_effort = self.publish();
        self.request_refresh();
    }
    pub fn is_shutdown(&self) -> bool {
        self.control.stopped()
    }
    pub fn shutdown(&self) {
        self.control.stop();
        self.source.lock().unwrap().disconnect();
        // Approval survives app restarts; a fresh authenticated account check fences use.
        self.request_refresh();
    }
}

pub(crate) fn atomic_write(path: &Path, value: &impl Serialize) -> io::Result<()> {
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
        let _best_effort = fs::remove_file(temporary);
    }
    result
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    #[test]
    fn desktop_boot_keeps_app_data_isolated_but_reads_the_shared_reset_store() {
        let root = Scratch::new();
        let shared = root.path().join("account");
        let nightly = root.path().join("nightly");
        fs::create_dir_all(&shared).unwrap();
        atomic_write(&shared.join("claude-reset-offers.json"), &serde_json::json!({
            "account":"fixture", "view":resets::View::default(), "attempts":[]
        })).unwrap();
        atomic_write(&shared.join("claude-reset-refresh.json"), &"shared-marker").unwrap();
        let app = Service::open_with_reset_dir(&nightly, &shared).unwrap();
        assert_eq!(app.resets.marker(), resets::Service::new(&shared).marker());
        assert!(nightly.join("engine-state/claude-quota.json").exists());
        assert!(!shared.join("engine-state").exists());
        assert!(!nightly.join("claude-reset-offers.json").exists());
    }

    use serde_json::json;
    pub(crate) struct Scratch(pub PathBuf);
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
            let _best_effort = fs::remove_dir_all(&self.0);
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
    fn weekly_99_holds_until_fresh_allowance_even_near_five_hour_reset() {
        let mut state = snapshot(100., RESET_EXEMPTION_MS - 1);
        state.windows.push(Window { id: "seven_day".into(), label: "Weekly".into(),
            used_percent: 99., resets_at: Some(NOW + 600_000), duration_ms: 604_800_000 });
        assert_eq!(state.view(policy(), NOW).admission, Admission::Held { resets_at: NOW + 600_000 });
        // An old high reading also holds; time passing alone cannot invent allowance.
        assert!(matches!(state.view(policy(), NOW + 300_000).admission, Admission::Held { .. }));
        assert_eq!(state.view(policy(), NOW + 600_000).admission, Admission::Unknown);
        state.windows[1].resets_at = None;
        assert_eq!(state.view(policy(), NOW).admission, Admission::Unknown);
        let fresh_five = snapshot(10., 3_600_000).windows;
        state.accept(fresh_five, NOW);
        assert_eq!(state.view(policy(), NOW).admission, Admission::Unknown);
        assert_eq!(state.view(policy(), NOW).state, State::Stale);
        // A fresh, explicit weekly reading is required to clear that hold.
        state.windows[1].resets_at = Some(NOW + 600_000);
        state.windows[0] = snapshot(100., RESET_EXEMPTION_MS - 1).windows.remove(0);
        state.error = None;
        state.windows[1].used_percent = 98.99;
        assert_eq!(state.view(policy(), NOW).admission, Admission::Ready);
        state.windows[0].resets_at = Some(NOW + 3_600_000);
        assert!(matches!(state.view(policy(), NOW).admission, Admission::Held { .. }));
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
    // ---- §108 and plan §15 answers 10-11: the speed of use --------------------------------

    fn five_hour_at(used: f64) -> Vec<Window> {
        snapshot(used, 3 * 3_600_000).windows
    }
    /// Both windows: five-hour at `five`%, weekly at `weekly`% (reset in two days).
    fn both_at(five: f64, weekly: f64) -> Vec<Window> {
        let mut windows = five_hour_at(five);
        windows.push(Window { id: "seven_day".into(), label: "Weekly".into(), used_percent: weekly,
            resets_at: Some(NOW + 48 * 3_600_000), duration_ms: 168 * 3_600_000 });
        windows
    }

    /// **§108: when usage speeds up a lot, the quota is checked every minute instead of 5**
    /// (answer 10 allows a minute; `FAST_REFRESH_INTERVAL_MS` carries the read-cost
    /// measurement). "A lot" is 5 points or more per five-minute check (1 point a minute, 3x a
    /// five-hour window's even pace). The 2026-09-29 run measured 3.7 to 4 a minute: 7% -> 11%
    /// in one minute here. Ordinary use measured about 0.33 a minute: 50% -> 50.33% is not fast.
    #[test]
    fn fast_usage_is_checked_every_minute_and_normal_usage_every_five() {
        let mut fast = Snapshot::default();
        fast.accept(five_hour_at(7.), NOW);
        fast.accept(five_hour_at(11.), NOW + 60_000);
        let view = fast.view(policy(), NOW + 60_000);
        assert_eq!(view.refresh_interval_ms, FAST_REFRESH_INTERVAL_MS);
        assert_eq!(view.next_check_at, Some(NOW + 60_000 + 60_000));
        assert_eq!(view.state, State::Fresh);

        let mut normal = Snapshot::default();
        normal.accept(five_hour_at(50.), NOW);
        normal.accept(five_hour_at(50.33), NOW + 60_000);
        let view = normal.view(policy(), NOW + 60_000);
        assert_eq!(view.refresh_interval_ms, REFRESH_INTERVAL_MS);
        assert_eq!(view.next_check_at, Some(NOW + 60_000 + 5 * 60_000));
        // A reading of a NEW window (another reset time) starts again with no speed.
        normal.accept(snapshot(1., 5 * 3_600_000).windows, NOW + 120_000);
        assert!(normal.speeds.is_empty());
    }

    /// **§108's case, at its MEASURED speed: 15 parallel Fable workers.** Reed's reading of the
    /// 2026-09-29 run (richos-hq `docs/research/2026-10-04-fifteen-fable-workers-quota-burn.md`):
    /// the five-hour window went 7% -> 100% in about 25 minutes, 3.7 to 4 points a minute,
    /// about 11x ordinary use (0.33 a minute); 93% was crossed between two five-minute checks
    /// and the first alarm came at 98%. At 4 a minute, checked every minute, the 93% point
    /// already lands before the wall: the last check under it (92.9%) is followed one minute
    /// later by one that reads at most 96.9% and holds. At twice that speed (8 a minute) the
    /// point moves to 100 - 8 = 92%, so the hold comes at 92.5%, before 93% — and the
    /// separate-process gate, reading the published file, agrees.
    #[test]
    fn a_fast_five_hour_burn_holds_before_100_and_before_93_when_the_speed_demands_it() {
        let mut s = Snapshot::default();
        s.accept(five_hour_at(88.9), NOW);
        s.accept(five_hour_at(92.9), NOW + 60_000);
        assert!(s.reading().fast());
        assert_eq!(s.view(policy(), NOW + 60_000).act_at["five_hour"], 93.);
        assert_eq!(s.view(policy(), NOW + 60_000).admission, Admission::Ready);
        assert!(s.reading().projected(&s.windows[0]) < 100., "the next check comes before the wall");
        s.accept(five_hour_at(96.9), NOW + 120_000);
        assert!(matches!(s.view(policy(), NOW + 120_000).admission, Admission::Held { .. }), "held at 96.9%, never at 100%");

        let mut double = Snapshot::default();
        double.accept(five_hour_at(84.5), NOW);
        double.accept(five_hour_at(92.5), NOW + 60_000);
        let view = double.view(policy(), NOW + 60_000);
        assert!((view.act_at["five_hour"] - 92.).abs() < 1e-9, "{:?}", view.act_at);
        assert!(matches!(view.admission, Admission::Held { .. }), "held at 92.5%, before 93%");
        let dir = Scratch::new();
        let state = dir.path().join("engine-state");
        atomic_write(&state.join("claude-quota.json"), &view).unwrap();
        atomic_write(&dir.path().join("claude-quota-policy.json"), &policy()).unwrap();
        assert!(matches!(gate::admission(&state, NOW + 60_000), Admission::Held { .. }));
    }

    /// **Plan §15 answer 10, point 3: a measured jump moves BOTH check points at once**, and the
    /// published view (the panel's) carries them. Five-hour gaining 8 a minute: 100 - 8 = 92
    /// (from 93). Weekly gaining 2 a minute: 100 - 2 = 98 (from 99).
    #[test]
    fn a_measured_jump_moves_both_check_points_and_the_view_shows_them() {
        let mut s = Snapshot::default();
        s.accept(both_at(40., 60.), NOW);
        assert_eq!(s.view(policy(), NOW).act_at, [("five_hour".to_string(), 93.), ("seven_day".to_string(), 99.)].into());
        s.accept(both_at(48., 62.), NOW + 60_000);
        let act = s.view(policy(), NOW + 60_000).act_at;
        assert!((act["five_hour"] - 92.).abs() < 1e-9 && (act["seven_day"] - 98.).abs() < 1e-9, "{act:?}");
    }

    /// **Plan §15 answer 11: when the speed comes back down, everything resets.** After the
    /// burn above, a reading a minute later that gained 0.3 points: checking is every 5 minutes
    /// again and both check points are 93% and 99% again. A way in needs its way out.
    #[test]
    fn a_return_to_normal_speed_restores_the_five_minute_interval_and_both_normal_check_points() {
        let mut s = Snapshot::default();
        s.accept(both_at(40., 60.), NOW);
        s.accept(both_at(48., 62.), NOW + 60_000);
        assert_eq!(s.view(policy(), NOW + 60_000).refresh_interval_ms, FAST_REFRESH_INTERVAL_MS);
        s.accept(both_at(48.3, 62.02), NOW + 120_000);
        let view = s.view(policy(), NOW + 120_000);
        assert_eq!(view.refresh_interval_ms, REFRESH_INTERVAL_MS);
        assert_eq!(view.next_check_at, Some(NOW + 120_000 + REFRESH_INTERVAL_MS));
        let act = view.act_at;
        assert_eq!((act["five_hour"], act["seven_day"]), (93., 99.), "{act:?}");
    }

    /// **Plan §15 answer 10, point 2: an EXPECTED rise.** Three leases started within a minute
    /// switch checking to every minute before any speed is measured (no speed exists: one
    /// reading only). Three agent dispatches written by the gate do the same on a fresh
    /// service. Ten minutes later, with no measured speed, it is every 5 minutes again.
    #[test]
    fn an_expected_rise_checks_every_minute_before_any_jump_is_measured() {
        for by_dispatch in [false, true] {
            let dir = Scratch::new();
            let service = Service::open(dir.path()).unwrap();
            let calls = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
            let mut windows = snapshot(20., 3_600_000).windows;
            windows[0].resets_at = Some(crate::util::now_millis() + 3_600_000);
            *service.source.lock().unwrap() = Box::new(FakeSource { calls, result: Ok(windows) });
            service.refresh(Path::new("unused"), true);
            assert_eq!(service.view().refresh_interval_ms, REFRESH_INTERVAL_MS);
            if by_dispatch {
                let now = crate::util::now_millis();
                fs::write(dir.path().join("engine-state").join(DISPATCH_LOG), format!("{now}\n{now}\n{now}\n")).unwrap();
                service.refresh(Path::new("unused"), false);
            } else {
                for _ in 0..3 { service.lease_started(); }
            }
            let view = service.view();
            assert!(view.speeds.is_empty(), "nothing was measured yet");
            assert_eq!(view.refresh_interval_ms, FAST_REFRESH_INTERVAL_MS, "dispatch={by_dispatch}");
            assert_eq!(view.next_check_at, view.checked_at.map(|t| t + FAST_REFRESH_INTERVAL_MS));
            let later = crate::util::now_millis() + EXPECTED_RISE_MS + 1;
            assert_eq!(service.snapshot.lock().unwrap().view(policy(), later).refresh_interval_ms, REFRESH_INTERVAL_MS,
                "the expected rise ends by itself");
        }
    }

    // ---- fill-first: several accounts, read by fake `claude` scripts -------------------

    /// A fake `claude` that answers `get_usage` with the figures in `usage.json` of the
    /// folder it was started under (`CLAUDE_CONFIG_DIR`), or `usage-1.json` beside it for
    /// Account 1, which runs with the app's own environment.
    #[cfg(unix)]
    pub(crate) fn fake_claude(root: &Path) -> PathBuf {
        use std::os::unix::fs::PermissionsExt;
        let path = root.join("claude-fixture");
        fs::write(&path, format!(r#"#!/usr/bin/env python3
import json, os, sys
folder = os.environ.get("CLAUDE_CONFIG_DIR", "")
usage = os.path.join(folder, "usage.json") if "claude-accounts" in folder else "{}"
for line in sys.stdin:
    v = json.loads(line)
    kind = v["request"]["subtype"]
    five, weekly, weekly_reset = json.load(open(usage))
    payload = {{}} if kind == "initialize" else {{"rate_limits_available": True, "rate_limits": {{
        "five_hour": {{"utilization": five, "resets_at": "2099-01-01T00:00:00Z"}},
        "seven_day": {{"utilization": weekly, "resets_at": weekly_reset}}}}}}
    print(json.dumps({{"type": "control_response", "response": {{"subtype": "success", "request_id": v["request_id"], "response": payload}}}}), flush=True)
"#, root.join("usage-1.json").display())).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        path
    }
    pub(crate) fn usage(path: &Path, five: f64, weekly: f64, weekly_reset: &str) {
        fs::write(path, serde_json::to_vec(&json!([five, weekly, weekly_reset])).unwrap()).unwrap();
    }

    /// **His answer 2, both settings, on readings taken by the real probe under each folder.**
    /// Account 1's five-hour window is at 93%; Account 2 ("Work") is at 10%. With Pause (the
    /// default) nothing moves: the 93% rule pauses exactly as before. With Switch, Account 2
    /// is put in use, the one-line notice is written, and the top-level reading every existing
    /// reader uses now describes Account 2.
    #[test]
    #[cfg(unix)]
    fn at_93_percent_of_the_five_hour_window_pause_stays_and_switch_moves_to_the_next_account() {
        let root = Scratch::new();
        let bin = fake_claude(root.path());
        let service = Service::open(root.path()).unwrap();
        let work = service.accounts.add("Work").unwrap();
        usage(&root.path().join("usage-1.json"), 93., 40., "2099-01-05T00:00:00Z");
        usage(&work.folder.clone().unwrap().join("usage.json"), 10., 20., "2099-01-06T00:00:00Z");
        let view = service.refresh(&bin, true);
        assert_eq!(view.at_threshold, crate::claude_accounts::AtThreshold::Pause, "Pause is the default");
        assert_eq!(service.accounts.in_use().id, "1", "Pause never switches");
        assert_eq!(view.accounts.len(), 2);
        assert_eq!(view.accounts[1].windows[0].used_percent, 10., "Account 2 was read under its own folder");
        assert_eq!(view.windows[0].used_percent, 93.);

        let view = service.set_at_threshold(crate::claude_accounts::AtThreshold::Switch).unwrap();
        assert_eq!(service.accounts.in_use().id, work.id, "Switch moves to the account with room");
        assert_eq!(view.windows[0].used_percent, 10., "the published reading is the account in use");
        assert!(view.accounts[1].in_use && !view.accounts[0].in_use);
        assert_eq!(service.accounts.take_notice().as_deref(),
            Some("Switched to Work: Account 1 is at 93% of its five-hour limit."));
        let published: View = gate::read_json(&root.path().join("engine-state/claude-quota.json")).unwrap();
        assert_eq!(published.windows[0].used_percent, 10.);
    }

    /// **All accounts exhausted** (Frank's finding 2): held until the soonest reset among
    /// them, in the view and in the separate-process gate, even with the pause switch off.
    /// With one account nothing changes: no hold appears.
    #[test]
    #[cfg(unix)]
    fn when_every_account_is_exhausted_work_is_held_until_the_soonest_reset() {
        let root = Scratch::new();
        let bin = fake_claude(root.path());
        let service = Service::open(root.path()).unwrap();
        let work = service.accounts.add("Work").unwrap();
        usage(&root.path().join("usage-1.json"), 20., 99.5, "2099-01-05T00:00:00Z");
        usage(&work.folder.clone().unwrap().join("usage.json"), 20., 100., "2099-01-03T00:00:00Z");
        let view = service.refresh(&bin, true);
        assert!(!view.policy.enabled, "the pause switch is off");
        let soonest = reset(&json!("2099-01-03T00:00:00Z")).unwrap();
        assert_eq!(view.held_until, Some(soonest));
        assert_eq!(view.admission, Admission::Held { resets_at: soonest });
        let state = root.path().join("engine-state");
        assert_eq!(gate::admission(&state, crate::util::now_millis()), Admission::Held { resets_at: soonest });
        // One account left: today's behavior, no hold.
        service.remove_account(&work.id).unwrap();
        assert_eq!(service.view().held_until, None);
        assert_eq!(gate::admission(&state, crate::util::now_millis()), Admission::Disabled);
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
        // The monitor's answer is the verdict: `true` only if the request woke it, `false` if
        // its own 30 s interval ran out first. So the wait for that answer is a hang guard
        // beyond the interval, not a clock on the wake; it was 2 s, which failed on a busy Mac
        // while the monitor was right (audit R9).
        assert!(rx.recv_timeout(Duration::from_secs(120)).expect("the monitor never answered"),
            "session start wakes the sleeping monitor");
        thread.join().unwrap();
        assert_eq!(calls.load(Ordering::SeqCst), 2, "session start bypasses the five-minute cache");
        // "Just completed" is the product's 5 s duplicate-request cooldown, measured on the wall
        // clock from the read above. A test thread descheduled for 5 s between that read and
        // the next line saw the cooldown over and a third read, and failed while the service
        // was right (seen under `scripts/qa/stall-run.py`). So the reading is stamped as
        // completed at the moment these two requests arrive, 4 s ahead (the cooldown tolerates a
        // stamp up to 5 s in the future, a small clock step backward, so the margin is 4 s + 5 s): the
        // question is whether simultaneous requests share a just-completed read, not how fast
        // this thread gets from one line to the next.
        service.snapshot.lock().unwrap().checked_at = Some(crate::util::now_millis() + 4_000);
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
    /// Hunt part 1 finding 23: a manual refresh is owed a real check even inside the automatic
    /// ten-minute failure backoff, while the automatic one still waits and a double-click
    /// straight after a failure still does not reach the provider.
    #[test]
    fn a_manual_refresh_is_not_held_by_the_automatic_failure_backoff() {
        use std::sync::atomic::Ordering;
        let dir = Scratch::new();
        let service = Service::open(dir.path()).unwrap();
        let calls = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        *service.source.lock().unwrap() =
            Box::new(FakeSource { calls: calls.clone(), result: Err(ReadError::Failed) });
        assert!(service.refresh(Path::new("unused"), true).retry_at.is_some());
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        service.refresh(Path::new("unused"), true);
        assert_eq!(calls.load(Ordering::SeqCst), 1, "a double-click right after a failure is still absorbed");
        // The failure was 10 s ago (its wait is set BACKOFF_MS past the attempt) and he fixed it.
        service.snapshot.lock().unwrap().retry_at = Some(crate::util::now_millis() + BACKOFF_MS - 10_000);
        let mut windows = snapshot(20., 3_600_000).windows;
        windows[0].resets_at = Some(crate::util::now_millis() + 3_600_000);
        *service.source.lock().unwrap() = Box::new(FakeSource { calls: calls.clone(), result: Ok(windows) });
        service.refresh(Path::new("unused"), false);
        assert_eq!(calls.load(Ordering::SeqCst), 1, "the automatic check still waits out the backoff");
        let view = service.refresh(Path::new("unused"), true);
        assert_eq!(calls.load(Ordering::SeqCst), 2, "his manual check is a real one");
        assert!(view.retry_at.is_none(), "and its answer replaces the old failure");
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
