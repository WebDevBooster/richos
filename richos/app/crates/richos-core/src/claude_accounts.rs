//! **Several Claude subscriptions, used one at a time** ("fill-first", the CEO 2026-10-04:
//! *"when the weekly Claude quota in one subscription is exhausted auto-switch to the other
//! Claude subscription and so on"*).
//!
//! Plan: richos-hq `docs/plans/2026-10-04-multi-subscription-fill-first.md` (Sage), with
//! Frank's review beside it and the CEO's answers in its §15.
//!
//! - **One Claude Code configuration folder per subscription** (`CLAUDE_CONFIG_DIR`, the
//!   mechanism Anthropic documents as "Log in with multiple accounts"). Each folder is signed
//!   in with the stock `claude auth login`; RichOS never sees a credential.
//! - **Account 1 is the folder used today.** It has no folder of its own here (`folder: None`),
//!   so a lease on it inherits the app's environment exactly as before, and a user with one
//!   subscription sees no change.
//! - **Staying is fill-first:** the account in use stays in use until it must be left.
//! - **Left BEFORE the wall, never at it** (plan §15 answers 6-8; ruling §108). An account is
//!   left at a turn boundary, checked before EVERY turn from the freshest reading (the
//!   `rate_limit_event` the lease itself streamed when that is newer than the probe):
//!   - at normal speed, at **99% of its weekly window** (`resets::WEEKLY_THRESHOLD`), and at
//!     the pause threshold (**93%**) of its five-hour window when the setting is Switch (his
//!     answer 2; with Pause the five-hour window holds the workers exactly as before);
//!   - when usage speeds up a lot, EARLIER: whenever the measured speed would carry a window
//!     to 100% before the next check, which is then one minute away instead of 5
//!     (`quota::Reading`, plan answers 10 and 11; back to 99% and 93% once the speed is down).
//! - **Choosing the next** (his answer 1): the one whose weekly window resets soonest, among
//!   accounts with room. No list-order option and no setting for it.
//! - **All accounts gone:** work is held until the soonest reset among them (Frank's
//!   finding 2). A usage-limit refusal inside a turn (the backstop, for one turn that by itself
//!   uses up what remained) marks its account gone until its reset.
//!
//! This file decides and records; it spawns nothing. The quota service and the turn boundaries
//! call [`Accounts::evaluate`]; the lease factory reads [`Accounts::in_use`]; the spine and the
//! work host call [`Accounts::limit_reached`] when a lease is cut by a limit anyway.
use crate::quota::{Reading, Window};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::{fs, io};

/// The account that is the folder RichOS used before this file existed.
pub const ACCOUNT_ONE: &str = "1";

/// What a lease error says when the provider refused the turn for a usage limit. The spine and
/// the work host read it back with [`parse_usage_limit`]; nothing else depends on the wording.
pub const USAGE_LIMIT: &str = "Claude usage limit reached";

/// When a limit is hit and nothing says when it resets, the account is retried after this long.
/// Five hours: the longest a session window can still be running.
const UNKNOWN_RESET_MS: u64 = 5 * 3_600_000;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Account {
    pub id: String,
    /// The user's own label. Rows show this and nothing else (his answer 4: no email).
    pub label: String,
    /// `None` for Account 1: the folder used today, inherited from the app's environment.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub folder: Option<PathBuf>,
}

/// The one setting (his answer 2): what happens when the five-hour window reaches the pause
/// threshold. Pause is the default and is today's behavior, unchanged.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AtThreshold {
    #[default]
    Pause,
    Switch,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Stored {
    accounts: Vec<Account>,
    in_use: String,
    #[serde(default)]
    at_threshold: AtThreshold,
    /// Account id -> until when a usage limit refused it (epoch ms).
    #[serde(default)]
    limited_until: BTreeMap<String, u64>,
}
impl Default for Stored {
    fn default() -> Self {
        Self {
            accounts: vec![Account { id: ACCOUNT_ONE.into(), label: "Account 1".into(), folder: None }],
            in_use: ACCOUNT_ONE.into(),
            at_threshold: AtThreshold::Pause,
            limited_until: BTreeMap::new(),
        }
    }
}

/// One account's row as the settings panel shows it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountView {
    pub id: String,
    pub label: String,
    pub in_use: bool,
    pub windows: Vec<Window>,
    pub checked_at: Option<u64>,
    /// Set while this account is exhausted, with when it comes back.
    pub exhausted_until: Option<u64>,
    /// Shown instead of the figures when the account could not be read.
    pub message: Option<String>,
}

/// Why an account is being left, for the one-line notice, with the figure it was read at.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Gone {
    Weekly(f64),
    FiveHour(f64),
    Limit,
}

/// **Must this account be left (or, with no account left, held), and until when?**
/// - weekly at 99% at normal speed (§108), or EARLIER when its measured speed would carry it
///   to 100% before the next check (`Reading::reaches`);
/// - with the setting on Switch, the five-hour window at the pause threshold (93%), or
///   earlier by the same projection;
/// - a usage-limit refusal that has not reset (the backstop).
pub fn gone(reading: &Reading, at_threshold: AtThreshold, pause_percent: u8, limited_until: Option<u64>, now: u64) -> Option<(Gone, u64)> {
    if let Some(until) = limited_until.filter(|t| *t > now) {
        return Some((Gone::Limit, until));
    }
    if let Some(weekly) = reading.windows.iter().find(|w| w.id == "seven_day"
        && reading.reaches(w, crate::quota::resets::WEEKLY_THRESHOLD)) {
        match weekly.resets_at {
            Some(t) if t > now => return Some((Gone::Weekly(weekly.used_percent), t)),
            Some(_) => {}
            None => return Some((Gone::Weekly(weekly.used_percent), now + crate::quota::REFRESH_INTERVAL_MS)),
        }
    }
    if at_threshold == AtThreshold::Switch {
        if let Some(five) = reading.windows.iter().find(|w| w.id == "five_hour"
            && reading.reaches(w, f64::from(pause_percent))) {
            if let Some(t) = five.resets_at.filter(|t| *t > now) {
                return Some((Gone::FiveHour(five.used_percent), t));
            }
        }
    }
    None
}

/// The weekly reset of an account with room, for the "soonest first" order.
fn weekly_reset(reading: &Reading) -> u64 {
    reading.windows.iter().find(|w| w.id == "seven_day").and_then(|w| w.resets_at).unwrap_or(u64::MAX)
}

/// **His answer 1:** among the candidates (accounts with room), the one whose weekly window
/// resets soonest. Ties keep list order.
pub fn next_account<'a>(candidates: impl IntoIterator<Item = (&'a str, &'a Reading)>) -> Option<&'a str> {
    candidates.into_iter().enumerate()
        .min_by_key(|(order, (_, reading))| (weekly_reset(reading), *order))
        .map(|(_, (id, _))| id)
}

/// What [`Accounts::limit_reached`] decided for a lease a usage limit cut.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AfterLimit {
    /// Another account is in use now: start the work again on it.
    Continue,
    /// No account has room. The work stops as it would have with one account.
    NoRoom,
}

/// A usage-limit lease error, written by the lease and read by the spine and the work host.
pub fn usage_limit_error(resets_at: Option<u64>, detail: &str) -> String {
    match resets_at {
        Some(t) => format!("{USAGE_LIMIT} (resets_at={t}): {detail}"),
        None => format!("{USAGE_LIMIT}: {detail}"),
    }
}

/// `Some(resets_at)` when `error` is a usage-limit refusal; the inner `None` means it did not
/// say when the limit resets.
pub fn parse_usage_limit(error: &str) -> Option<Option<u64>> {
    let at = error.find(USAGE_LIMIT)?;
    let rest = &error[at + USAGE_LIMIT.len()..];
    Some(rest.strip_prefix(" (resets_at=")
        .and_then(|r| r.split(')').next())
        .and_then(|n| n.parse().ok()))
}

pub struct Accounts {
    path: PathBuf,
    root: PathBuf,
    state: Mutex<Stored>,
    notice: Mutex<Option<String>>,
}

impl Accounts {
    /// `data_dir/claude-accounts.json` keeps the list; new folders go under
    /// `data_dir/claude-accounts/<id>/`.
    pub fn open(data_dir: &Path) -> io::Result<Self> {
        let path = data_dir.join("claude-accounts.json");
        let state = match fs::read(&path) {
            Ok(bytes) => {
                let stored: Stored = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
                if !stored.accounts.iter().any(|a| a.id == ACCOUNT_ONE) {
                    return Err(io::Error::other("the account list lost Account 1"));
                }
                stored
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => Stored::default(),
            Err(e) => return Err(e),
        };
        Ok(Self { path, root: data_dir.join("claude-accounts"), state: Mutex::new(state), notice: Mutex::new(None) })
    }

    fn save(&self, state: &Stored) -> io::Result<()> {
        crate::quota::atomic_write(&self.path, state)
    }

    pub fn list(&self) -> Vec<Account> { self.state.lock().unwrap().accounts.clone() }
    pub fn count(&self) -> usize { self.state.lock().unwrap().accounts.len() }
    pub fn in_use(&self) -> Account {
        let state = self.state.lock().unwrap();
        state.accounts.iter().find(|a| a.id == state.in_use).cloned()
            .unwrap_or_else(|| state.accounts[0].clone())
    }
    pub fn at_threshold(&self) -> AtThreshold { self.state.lock().unwrap().at_threshold }
    pub fn limited_until(&self, id: &str) -> Option<u64> { self.state.lock().unwrap().limited_until.get(id).copied() }
    pub fn folder(&self, id: &str) -> Option<PathBuf> {
        self.state.lock().unwrap().accounts.iter().find(|a| a.id == id).and_then(|a| a.folder.clone())
    }

    pub fn set_at_threshold(&self, value: AtThreshold) -> io::Result<()> {
        let mut state = self.state.lock().unwrap();
        let mut next = state.clone();
        next.at_threshold = value;
        self.save(&next)?;
        *state = next;
        Ok(())
    }

    /// Add an account: a new, empty Claude Code configuration folder. Signing it in is the
    /// stock `claude auth login` with `CLAUDE_CONFIG_DIR` set to it (`provider_auth.rs`).
    pub fn add(&self, label: &str) -> io::Result<Account> {
        let mut state = self.state.lock().unwrap();
        let id = (state.accounts.iter().filter_map(|a| a.id.parse::<u32>().ok()).max().unwrap_or(1) + 1).to_string();
        let folder = self.root.join(&id);
        // The Keychain item Claude Code writes is named from a hash of this path string, and
        // the reset reader refuses non-ASCII custom paths (`reset_transport.rs`).
        if !folder.to_string_lossy().is_ascii() {
            return Err(io::Error::other("RichOS cannot create an account folder in a location whose name has non-ASCII characters."));
        }
        fs::create_dir_all(&folder)?;
        let label = label.trim();
        let label = if label.is_empty() { format!("Account {id}") } else { label.chars().filter(|c| !c.is_control()).take(40).collect() };
        let account = Account { id, label, folder: Some(folder) };
        let mut next = state.clone();
        next.accounts.push(account.clone());
        self.save(&next)?;
        *state = next;
        Ok(account)
    }

    /// Remove an added account and its folder. Account 1 is the user's own Claude Code folder
    /// and is never removed. The caller signs the folder out first (`claude auth logout`).
    pub fn remove(&self, id: &str) -> io::Result<()> {
        if id == ACCOUNT_ONE {
            return Err(io::Error::other("Account 1 is your own Claude Code sign-in and cannot be removed here."));
        }
        let mut state = self.state.lock().unwrap();
        let Some(account) = state.accounts.iter().find(|a| a.id == id).cloned() else { return Ok(()) };
        let mut next = state.clone();
        next.accounts.retain(|a| a.id != id);
        next.limited_until.remove(id);
        if next.in_use == id { next.in_use = ACCOUNT_ONE.into(); }
        self.save(&next)?;
        *state = next;
        drop(state);
        // Only a folder this file created is ever deleted.
        if let Some(folder) = account.folder.filter(|f| f.starts_with(&self.root)) {
            let _best_effort = fs::remove_dir_all(folder);
        }
        Ok(())
    }

    fn switch_to(&self, state: &mut Stored, to: &str, why: Gone) -> io::Result<()> {
        let from = state.accounts.iter().find(|a| a.id == state.in_use).map(|a| a.label.clone()).unwrap_or_default();
        let to_label = state.accounts.iter().find(|a| a.id == to).map(|a| a.label.clone()).unwrap_or_default();
        let mut next = state.clone();
        next.in_use = to.into();
        self.save(&next)?;
        *state = next;
        let reason = match why {
            Gone::Weekly(used) => format!("is at {}% of its weekly limit", used.floor()),
            Gone::FiveHour(used) => format!("is at {}% of its five-hour limit", used.floor()),
            Gone::Limit => "reached a usage limit".to_string(),
        };
        *self.notice.lock().unwrap() = Some(format!("Switched to {to_label}: {from} {reason}."));
        Ok(())
    }

    /// **The switch decision, on the freshest readings.** `readings` holds every account that
    /// has a reading. Called before every turn (the spine and the work host) and after every
    /// probe. Returns whether the account in use changed. Running leases are NOT touched here:
    /// each one rotates at its own next turn boundary, because rotation never happens inside a
    /// turn (`spine.rs`).
    pub fn evaluate(&self, readings: &BTreeMap<String, Reading>, pause_percent: u8, now: u64) -> io::Result<bool> {
        let mut state = self.state.lock().unwrap();
        if state.accounts.len() < 2 { return Ok(false); }
        let current = state.in_use.clone();
        let at = state.at_threshold;
        let limited: BTreeMap<String, u64> = state.limited_until.clone();
        let limit = |id: &str| limited.get(id).copied();
        let empty = Reading::default();
        let mine = readings.get(&current).unwrap_or(&empty);
        let Some((why, _)) = gone(mine, at, pause_percent, limit(&current), now) else { return Ok(false) };
        let next = next_account(state.accounts.iter().filter(|a| a.id != current)
            .filter_map(|a| readings.get(&a.id).map(|r| (a.id.as_str(), r)))
            .filter(|(id, r)| gone(r, at, pause_percent, limit(id), now).is_none()));
        let Some(next) = next.map(str::to_string) else { return Ok(false) };
        self.switch_to(&mut state, &next, why)?;
        Ok(true)
    }

    /// **The backstop.** A lease on `account` was refused by a usage limit inside a turn. The
    /// account is marked gone until `resets_at` (or, when the refusal did not say, until the
    /// latest reset of its full windows), and the next account with room is put in use.
    pub fn limit_reached(&self, account: &str, resets_at: Option<u64>, readings: &BTreeMap<String, Reading>, pause_percent: u8, now: u64) -> io::Result<AfterLimit> {
        {
            let mut state = self.state.lock().unwrap();
            let until = resets_at.filter(|t| *t > now).or_else(|| readings.get(account).and_then(|r| r.windows.iter()
                .filter(|w| w.used_percent >= crate::quota::resets::WEEKLY_THRESHOLD)
                .filter_map(|w| w.resets_at).filter(|t| *t > now).max()))
                .unwrap_or(now + UNKNOWN_RESET_MS);
            let mut next = state.clone();
            next.limited_until.retain(|_, t| *t > now);
            next.limited_until.insert(account.into(), until);
            self.save(&next)?;
            *state = next;
            if state.in_use != account {
                return Ok(AfterLimit::Continue);
            }
        }
        Ok(if self.evaluate(readings, pause_percent, now)? { AfterLimit::Continue } else { AfterLimit::NoRoom })
    }

    /// **All accounts gone** (Frank's finding 2): held until the soonest reset across them.
    /// `None` with one account, so a user with one subscription sees no change.
    pub fn held_until(&self, readings: &BTreeMap<String, Reading>, pause_percent: u8, now: u64) -> Option<u64> {
        let state = self.state.lock().unwrap();
        if state.accounts.len() < 2 { return None; }
        let mut soonest: Option<u64> = None;
        let empty = Reading::default();
        for account in &state.accounts {
            let reading = readings.get(&account.id);
            match gone(reading.unwrap_or(&empty), state.at_threshold, pause_percent,
                state.limited_until.get(&account.id).copied(), now) {
                Some((_, until)) => soonest = Some(soonest.map_or(until, |s| s.min(until))),
                // An account with a reading and room: work can run.
                None if reading.is_some() => return None,
                // No reading: unknown, never counted as room.
                None => {}
            }
        }
        soonest
    }

    /// The one-line switch notice, taken once by whoever shows it.
    pub fn take_notice(&self) -> Option<String> { self.notice.lock().unwrap().take() }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::quota::tests::Scratch;

    pub const NOW: u64 = 1_000_000_000_000;
    const HOUR: u64 = 3_600_000;
    pub fn reading(five: f64, five_reset: u64, weekly: f64, weekly_reset: u64) -> Reading {
        Reading { windows: vec![
            Window { id: "five_hour".into(), label: "Five-hour".into(), used_percent: five, resets_at: Some(NOW + five_reset), duration_ms: 5 * HOUR },
            Window { id: "seven_day".into(), label: "Weekly".into(), used_percent: weekly, resets_at: Some(NOW + weekly_reset), duration_ms: 168 * HOUR },
        ], speeds: BTreeMap::new(), expected: false }
    }
    fn two_accounts() -> (Scratch, Accounts) {
        let dir = Scratch::new();
        let accounts = Accounts::open(dir.path()).unwrap();
        accounts.add("Work").unwrap();
        (dir, accounts)
    }
    fn readings(one: Reading, two: Reading) -> BTreeMap<String, Reading> {
        [("1".to_string(), one), ("2".to_string(), two)].into_iter().collect()
    }

    /// **His answer 1.** Account 1's weekly window is at 99%. Of the two with room, "Personal"
    /// (id 3) has its week end in one day and "Work" (id 2) in six, so Personal is next even
    /// though Work comes first in the list. "Spare" (id 4) has its week end soonest of all,
    /// but it is at 99.5%, so it has no room.
    #[test]
    fn the_next_account_is_the_one_whose_weekly_window_resets_soonest_among_those_with_room() {
        let dir = Scratch::new();
        let accounts = Accounts::open(dir.path()).unwrap();
        for label in ["Work", "Personal", "Spare"] { accounts.add(label).unwrap(); }
        let readings: BTreeMap<String, Reading> = [
            ("1", reading(40., HOUR, 99., 2 * 24 * HOUR)),
            ("2", reading(0., HOUR, 10., 6 * 24 * HOUR)),
            ("3", reading(0., HOUR, 50., 24 * HOUR)),
            ("4", reading(0., HOUR, 99.5, 3 * HOUR)),
        ].into_iter().map(|(id, r)| (id.to_string(), r)).collect();
        assert!(accounts.evaluate(&readings, 93, NOW).unwrap());
        assert_eq!(accounts.in_use().id, "3");
        assert_eq!(accounts.take_notice().as_deref(), Some("Switched to Personal: Account 1 is at 99% of its weekly limit."));
        // Staying is fill-first: Personal has room, so nothing moves, even though Work is
        // earlier in the list.
        assert!(!accounts.evaluate(&readings, 93, NOW).unwrap());
        assert_eq!(accounts.in_use().id, "3");
        // The choice survives a restart.
        assert_eq!(Accounts::open(dir.path()).unwrap().in_use().id, "3");
    }

    /// **§108, normal speed:** the weekly switch point is 99%. At 98.9% nothing moves; at 99%
    /// the next account takes over. A slow, steady speed (the weekly window's own even pace,
    /// 100 points a week) does not move it earlier.
    #[test]
    fn at_normal_speed_the_weekly_switch_happens_at_99_percent() {
        let (_dir, accounts) = two_accounts();
        let mut slow = reading(10., HOUR, 98.9, 24 * HOUR);
        slow.speeds.insert("seven_day".into(), 100. / (168. * HOUR as f64));
        assert!(!slow.fast());
        assert!(!accounts.evaluate(&readings(slow.clone(), reading(0., HOUR, 5., 48 * HOUR)), 93, NOW).unwrap());
        assert_eq!(accounts.in_use().id, "1", "98.9% at normal speed stays");
        slow.windows[1].used_percent = 99.;
        assert!(accounts.evaluate(&readings(slow, reading(0., HOUR, 5., 48 * HOUR)), 93, NOW).unwrap());
        assert_eq!(accounts.in_use().id, "2", "99% at normal speed switches");
    }

    /// **§108 addendum (plan answer 8), a fast burn on the WEEKLY window**, at the speed the
    /// 2026-09-29 run measured on its five-hour window (4 points a minute; richos-hq
    /// `docs/research/2026-10-04-fifteen-fable-workers-quota-burn.md`), used here as the worst
    /// case: no weekly figure was measured for that run. That is fast (20 points per
    /// five-minute check), so the next check is one minute away and the weekly check point
    /// moves from 99% to 100 - 4 = 96%. At 95.5% the next check would read 99.5%: under 100,
    /// so it stays. At 96% it switches NOW, before 99% and before the wall. The projected use
    /// at the next check after every decision to stay is under 100%.
    #[test]
    fn a_fast_weekly_burn_switches_before_99_percent_so_the_next_check_stays_under_100() {
        let (_dir, accounts) = two_accounts();
        let per_ms = 4.0 / 60_000.;
        let mut fast = reading(10., HOUR, 95.5, 24 * HOUR);
        fast.speeds.insert("seven_day".into(), per_ms);
        assert!(fast.fast());
        assert_eq!(fast.interval(), crate::quota::FAST_REFRESH_INTERVAL_MS);
        assert!((fast.act_point(&fast.windows[1], 99.) - 96.).abs() < 1e-9);
        assert!(!accounts.evaluate(&readings(fast.clone(), reading(0., HOUR, 5., 48 * HOUR)), 93, NOW).unwrap());
        assert!(fast.projected(&fast.windows[1]) < 100., "staying is safe only if the next check is under 100%");
        fast.windows[1].used_percent = 96.;
        assert!(accounts.evaluate(&readings(fast, reading(0., HOUR, 5., 48 * HOUR)), 93, NOW).unwrap());
        assert_eq!(accounts.in_use().id, "2", "switched at 96%, before 99%");
    }
}
