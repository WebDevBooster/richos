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
//! - **Left BEFORE the wall, never at it** (the CEO's correction, 2026-10-04: preventing a
//!   cut-off is the whole job of this feature). An account is left at a turn boundary while it
//!   still has room: at the pause threshold (93% by default) of its weekly window, and at the
//!   same threshold of its five-hour window when the setting is Switch (his answer 2). The
//!   freshest reading is used: the `rate_limit_event` the lease itself streamed, when it is
//!   newer than the five-minute probe.
//! - **Choosing the next** (his answer 1): the one whose weekly window resets soonest, among
//!   accounts with room. No list-order option and no setting for it.
//! - **Exhausted** is the wall itself: weekly at 99% (`resets::WEEKLY_THRESHOLD`, the existing
//!   weekly hold), the five-hour threshold with Switch, or a refusal by a usage limit (the
//!   mid-turn backstop). When the account in use must be left and no other account is below
//!   the threshold, it stays in use until it is exhausted; only then does an account that is
//!   above the threshold but not exhausted take over; and only when every account is exhausted
//!   is work held, until the soonest reset among them (Frank's finding 2).
//!
//! This file decides and records; it spawns nothing. The quota service and the turn boundaries
//! call [`Accounts::evaluate`]; the lease factory reads [`Accounts::in_use`]; the spine and the
//! work host call [`Accounts::limit_reached`] when a lease is cut by a limit anyway.
use crate::quota::Window;
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

/// Why an account is being left, for the one-line notice.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Gone {
    Weekly,
    FiveHour,
    Limit,
}

/// Must the account in use be LEFT at this boundary, and until when? At `pause_percent` of
/// either window (five-hour only with Switch), or after a usage-limit refusal.
pub fn leave(windows: &[Window], at_threshold: AtThreshold, pause_percent: u8, limited_until: Option<u64>, now: u64) -> Option<(Gone, u64)> {
    reached(windows, at_threshold, pause_percent, f64::from(pause_percent), limited_until, now)
}

/// Is the account at the wall? Weekly at 99% (the existing weekly hold's threshold), the
/// five-hour threshold with Switch, or a usage-limit refusal that has not reset.
pub fn exhausted(windows: &[Window], at_threshold: AtThreshold, pause_percent: u8, limited_until: Option<u64>, now: u64) -> Option<(Gone, u64)> {
    reached(windows, at_threshold, pause_percent, crate::quota::resets::WEEKLY_THRESHOLD, limited_until, now)
}

fn reached(windows: &[Window], at_threshold: AtThreshold, pause_percent: u8, weekly_at: f64, limited_until: Option<u64>, now: u64) -> Option<(Gone, u64)> {
    if let Some(until) = limited_until.filter(|t| *t > now) {
        return Some((Gone::Limit, until));
    }
    if let Some(weekly) = windows.iter().find(|w| w.id == "seven_day" && w.used_percent >= weekly_at) {
        match weekly.resets_at {
            Some(t) if t > now => return Some((Gone::Weekly, t)),
            Some(_) => {}
            None => return Some((Gone::Weekly, now + crate::quota::REFRESH_INTERVAL_MS)),
        }
    }
    if at_threshold == AtThreshold::Switch {
        if let Some(five) = windows.iter().find(|w| w.id == "five_hour" && w.used_percent >= f64::from(pause_percent)) {
            if let Some(t) = five.resets_at.filter(|t| *t > now) {
                return Some((Gone::FiveHour, t));
            }
        }
    }
    None
}

/// The weekly reset of an account with room, for the "soonest first" order.
fn weekly_reset(windows: &[Window]) -> u64 {
    windows.iter().find(|w| w.id == "seven_day").and_then(|w| w.resets_at).unwrap_or(u64::MAX)
}

/// **His answer 1:** among the candidates (accounts with room), the one whose weekly window
/// resets soonest. Ties keep list order.
pub fn next_account<'a>(candidates: impl IntoIterator<Item = (&'a str, &'a [Window])>) -> Option<&'a str> {
    candidates.into_iter().enumerate()
        .min_by_key(|(order, (_, windows))| (weekly_reset(windows), *order))
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

    fn switch_to(&self, state: &mut Stored, to: &str, why: Gone, pause_percent: u8) -> io::Result<()> {
        let from = state.accounts.iter().find(|a| a.id == state.in_use).map(|a| a.label.clone()).unwrap_or_default();
        let to_label = state.accounts.iter().find(|a| a.id == to).map(|a| a.label.clone()).unwrap_or_default();
        let mut next = state.clone();
        next.in_use = to.into();
        self.save(&next)?;
        *state = next;
        let reason = match why {
            Gone::Weekly => format!("reached {pause_percent}% of its weekly limit"),
            Gone::FiveHour => format!("reached {pause_percent}% of its five-hour limit"),
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
    pub fn evaluate(&self, readings: &BTreeMap<String, Vec<Window>>, pause_percent: u8, now: u64) -> io::Result<bool> {
        let mut state = self.state.lock().unwrap();
        if state.accounts.len() < 2 { return Ok(false); }
        let current = state.in_use.clone();
        let at = state.at_threshold;
        let limited: BTreeMap<String, u64> = state.limited_until.clone();
        let limit = |id: &str| limited.get(id).copied();
        let empty = Vec::new();
        let mine = readings.get(&current).unwrap_or(&empty);
        let Some((why, _)) = leave(mine, at, pause_percent, limit(&current), now) else { return Ok(false) };
        let others: Vec<(&str, &[Window])> = state.accounts.iter().filter(|a| a.id != current)
            .filter_map(|a| readings.get(&a.id).map(|w| (a.id.as_str(), w.as_slice()))).collect();
        let mut next = next_account(others.iter().copied()
            .filter(|(id, w)| leave(w, at, pause_percent, limit(id), now).is_none()));
        // Nobody below the threshold: stay until the wall, then take anyone not at it.
        if next.is_none() && exhausted(mine, at, pause_percent, limit(&current), now).is_some() {
            next = next_account(others.iter().copied()
                .filter(|(id, w)| exhausted(w, at, pause_percent, limit(id), now).is_none()));
        }
        let Some(next) = next.map(str::to_string) else { return Ok(false) };
        self.switch_to(&mut state, &next, why, pause_percent)?;
        Ok(true)
    }

    /// **The backstop.** A lease on `account` was refused by a usage limit inside a turn. The
    /// account is marked exhausted until `resets_at` (or, when the refusal did not say, until
    /// the latest reset of its full windows), and the next account with room is put in use.
    pub fn limit_reached(&self, account: &str, resets_at: Option<u64>, readings: &BTreeMap<String, Vec<Window>>, pause_percent: u8, now: u64) -> io::Result<AfterLimit> {
        {
            let mut state = self.state.lock().unwrap();
            let until = resets_at.filter(|t| *t > now).or_else(|| readings.get(account).and_then(|w| w.iter()
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

    /// **All accounts exhausted** (Frank's finding 2): held until the soonest reset across
    /// them. `None` with one account, so a user with one subscription sees no change.
    pub fn held_until(&self, readings: &BTreeMap<String, Vec<Window>>, pause_percent: u8, now: u64) -> Option<u64> {
        let state = self.state.lock().unwrap();
        if state.accounts.len() < 2 { return None; }
        let mut soonest: Option<u64> = None;
        for account in &state.accounts {
            let windows = readings.get(&account.id);
            match exhausted(windows.map(Vec::as_slice).unwrap_or(&[]), state.at_threshold, pause_percent,
                state.limited_until.get(&account.id).copied(), now) {
                Some((_, until)) => soonest = Some(soonest.map_or(until, |s| s.min(until))),
                // An account with a reading that is not at the wall: work can run.
                None if windows.is_some() => return None,
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
    pub fn windows(five: f64, five_reset: u64, weekly: f64, weekly_reset: u64) -> Vec<Window> {
        vec![
            Window { id: "five_hour".into(), label: "Five-hour".into(), used_percent: five, resets_at: Some(NOW + five_reset), duration_ms: 5 * HOUR },
            Window { id: "seven_day".into(), label: "Weekly".into(), used_percent: weekly, resets_at: Some(NOW + weekly_reset), duration_ms: 168 * HOUR },
        ]
    }

    /// **His answer 1.** Account 1's weekly window is at 93%. Of the two with room, "Personal"
    /// (id 3) has its week end in one day and "Work" (id 2) in six, so Personal is next even
    /// though Work comes first in the list. "Spare" (id 4) has its week end soonest of all,
    /// but it is at 95%, so it has no room.
    #[test]
    fn the_next_account_is_the_one_whose_weekly_window_resets_soonest_among_those_with_room() {
        let dir = Scratch::new();
        let accounts = Accounts::open(dir.path()).unwrap();
        for label in ["Work", "Personal", "Spare"] { accounts.add(label).unwrap(); }
        let readings: BTreeMap<String, Vec<Window>> = [
            ("1", windows(40., HOUR, 93., 2 * 24 * HOUR)),
            ("2", windows(0., HOUR, 10., 6 * 24 * HOUR)),
            ("3", windows(0., HOUR, 50., 24 * HOUR)),
            ("4", windows(0., HOUR, 95., 3 * HOUR)),
        ].into_iter().map(|(id, w)| (id.to_string(), w)).collect();
        assert!(accounts.evaluate(&readings, 93, NOW).unwrap());
        assert_eq!(accounts.in_use().id, "3");
        assert_eq!(accounts.take_notice().as_deref(), Some("Switched to Personal: Account 1 reached 93% of its weekly limit."));
        // Staying is fill-first: Personal has room, so nothing moves, even though Work is
        // earlier in the list.
        assert!(!accounts.evaluate(&readings, 93, NOW).unwrap());
        assert_eq!(accounts.in_use().id, "3");
        // The choice survives a restart.
        assert_eq!(Accounts::open(dir.path()).unwrap().in_use().id, "3");
    }
}
