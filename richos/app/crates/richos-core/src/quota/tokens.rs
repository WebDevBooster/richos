//! **The weekly speed from live token use** (the CEO, 2026-10-07: *"the percentage for the
//! switch needs to be adjusted dynamically so that this doesn't happen"*, an account reaching
//! 100% before the switch; *"if we keep tracking Claude's current weekly percentage vs token
//! consumption for different models"*).
//!
//! The weekly percentage moves in whole points, so a burst is invisible to the percentage speed
//! (`Snapshot::measure`) until a whole point has gone. Token use is visible at once: every
//! assistant message's `usage` is in the stream the app reads from each of its own leases
//! ([`Sink`]: they write no transcript), and, for Claude Code used outside the app, in the
//! account's transcripts (`<folder>/projects/**/*.jsonl`), read exactly as
//! `engine/scripts/token-track.py` reads them (input + output + cache write + cache read, by
//! model; a message streamed in several copies counts once, its largest copy).
//!
//! - **Learning** (`Track::reading`): each weekly percentage value is an episode from the
//!   reading that first shows it (after a lower one, so the rise itself was seen) to the reading
//!   that first shows a higher one; its tokens are those stamped in between. That is
//!   `token-track.py report`'s episode, start to start.
//! - **Tokens per point, per model** (`figures`): episodes mix models, so each model's figure is
//!   the non-negative weighted least-squares fit of `points = sum(tokens_m / per_point_m)` over
//!   the kept episodes, each weighted by 1 / its tokens. With one model that is exactly
//!   `token-track.py`'s total tokens / total points. A model the episodes cannot tell apart from
//!   another has no figure yet.
//! - **The speed** (`Track::speed`): over the last minute, each measured model's tokens divided
//!   by its tokens per point, summed. The quota service takes the larger of it and the
//!   percentage speed (`Snapshot::reading_with`), so a model with no figure yet, or use this Mac
//!   cannot see (claude.ai, another computer), never makes the speed lower than the percentage
//!   speed.
use super::Window;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::{BTreeMap, HashMap},
    fs,
    io::{Read, Seek, SeekFrom},
    path::{Path, PathBuf},
};

/// The live window: tokens stamped in the last minute are the live tokens per minute.
pub const LIVE_MS: u64 = 60_000;
/// Episodes kept per account (newest last). 50 weekly points is half a week of steady use.
pub const KEEP_EPISODES: usize = 50;
/// The most models fitted at once; any others have no figure (2^6 subsets at most).
const MAX_MODELS: usize = 6;

/// One weekly percentage value from its start to the next value's start: the points it rose by
/// and the tokens each model used in between.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Episode {
    pub points: f64,
    pub tokens: BTreeMap<String, u64>,
}

/// One account's token reader and what it has learned.
#[derive(Debug, Default)]
pub struct Track {
    /// Each transcript's read position: the end of its last complete line.
    offsets: HashMap<PathBuf, u64>,
    scanned: bool,
    /// Message id -> (stamped at, model, tokens, output tokens). The largest copy wins.
    events: HashMap<String, (u64, String, u64, u64)>,
    /// The weekly value being watched: (used, its start if its rise was seen, its reset time).
    current: Option<(f64, Option<u64>, Option<u64>)>,
    last_reading: Option<u64>,
    pub episodes: Vec<Episode>,
}

fn stamp(text: &str) -> Option<u64> {
    let parsed = time::OffsetDateTime::parse(text, &time::format_description::well_known::Rfc3339).ok()?;
    u64::try_from(parsed.unix_timestamp_nanos() / 1_000_000).ok()
}

fn transcripts(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let Ok(kind) = entry.file_type() else { continue };
        let path = entry.path();
        if kind.is_dir() {
            transcripts(&path, out);
        } else if kind.is_file() && path.extension().is_some_and(|e| e == "jsonl") {
            out.push(path);
        }
    }
}

impl Track {
    /// A track that starts from episodes learned before (kept across launches).
    pub fn with_episodes(episodes: Vec<Episode>) -> Self {
        Self { episodes, ..Self::default() }
    }

    /// Read what the account's transcripts gained since the last scan. The first scan skips
    /// every transcript untouched for the live window: nothing older is needed yet.
    pub fn scan(&mut self, folder: &Path, now: u64) {
        let mut files = Vec::new();
        transcripts(&folder.join("projects"), &mut files);
        for path in files {
            let Ok(meta) = fs::metadata(&path) else { continue };
            let len = meta.len();
            if !self.scanned && !self.offsets.contains_key(&path) {
                let modified = meta.modified().ok()
                    .and_then(|m| m.duration_since(std::time::UNIX_EPOCH).ok())
                    .map_or(0, |d| d.as_millis() as u64);
                if modified + LIVE_MS < now {
                    self.offsets.insert(path, len);
                    continue;
                }
            }
            let mut offset = self.offsets.get(&path).copied().unwrap_or(0);
            if len < offset { offset = 0; } // rewritten
            if len == offset { continue; }
            let Ok(mut file) = fs::File::open(&path) else { continue };
            let mut bytes = Vec::new();
            if file.seek(SeekFrom::Start(offset)).is_err() || file.read_to_end(&mut bytes).is_err() { continue; }
            // Only complete lines; a line still being written is read next time.
            let Some(end) = bytes.iter().rposition(|b| *b == b'\n') else { continue };
            for line in bytes[..end].split(|b| *b == b'\n') {
                self.line(line);
            }
            self.offsets.insert(path, offset + end as u64 + 1);
        }
        self.scanned = true;
    }

    fn line(&mut self, line: &[u8]) {
        if !line.windows(7).any(|w| w == b"\"usage\"") { return; }
        let Ok(row) = serde_json::from_slice::<Value>(line) else { return };
        let Some(at) = row["timestamp"].as_str().and_then(stamp) else { return };
        if let Some(found) = message_use(&row["message"], row["uuid"].as_str(), at) { self.add_use(&found); }
    }

    /// One message's usage, from a transcript or from a lease's stream ([`Sink`]).
    pub fn add_use(&mut self, found: &Use) {
        self.add(&found.id, found.at, &found.model, found.tokens, found.output);
    }

    /// One assistant message's usage. A later, larger copy of the same message replaces it.
    pub fn add(&mut self, id: &str, at: u64, model: &str, tokens: u64, output: u64) {
        if self.events.get(id).is_some_and(|old| old.3 > output) { return; }
        self.events.insert(id.to_string(), (at, model.to_string(), tokens, output));
    }

    /// A reading of the weekly window, taken at `at`. Returns true when it closed an episode
    /// (the caller keeps the episodes across launches).
    pub fn reading(&mut self, window: &Window, at: u64, now: u64) -> bool {
        let mut closed = false;
        if self.last_reading != Some(at) {
            self.last_reading = Some(at);
            let used = window.used_percent;
            // The SAME window when the reset times agree within a minute (`Snapshot::measure`).
            let same = |a: Option<u64>, b: Option<u64>| match (a, b) {
                (Some(a), Some(b)) => a.abs_diff(b) < 60_000,
                (a, b) => a == b,
            };
            self.current = match self.current {
                Some((value, start, resets)) if same(resets, window.resets_at) => {
                    if used > value {
                        if let Some(start) = start {
                            let mut tokens = BTreeMap::new();
                            for (stamped, model, count, _) in self.events.values() {
                                if start < *stamped && *stamped <= at { *tokens.entry(model.clone()).or_insert(0) += count; }
                            }
                            self.episodes.push(Episode { points: used - value, tokens });
                            let extra = self.episodes.len().saturating_sub(KEEP_EPISODES);
                            self.episodes.drain(..extra);
                            closed = true;
                        }
                        Some((used, Some(at), window.resets_at))
                    } else if used < value {
                        Some((used, None, window.resets_at))
                    } else {
                        Some((value, start, resets))
                    }
                }
                _ => Some((used, None, window.resets_at)),
            };
        }
        // Keep only what an episode still open, the live window, or the tokens since the last
        // good reading (`points_since`) can use.
        let keep = [self.current.and_then(|c| c.1), Some(now.saturating_sub(LIVE_MS)), self.last_reading]
            .into_iter().flatten().min().unwrap_or(0);
        self.events.retain(|_, e| e.0 > keep);
        closed
    }

    /// **Weekly points spent since `since`** (the last good reading), each measured model's
    /// tokens divided by its tokens per point. A model with no figure adds nothing: its tokens
    /// cannot be turned into points honestly.
    pub fn points_since(&self, since: u64, now: u64) -> f64 {
        let per_point = figures(&self.episodes);
        self.events.values()
            .filter(|e| e.0 > since && e.0 <= now)
            .filter_map(|e| per_point.get(&e.1).map(|p| e.2 as f64 / p))
            .sum()
    }

    /// Weekly points per millisecond from the last minute's tokens (`LIVE_MS`), each model's
    /// tokens divided by its tokens per point. A model with no figure adds nothing.
    pub fn speed(&self, now: u64) -> f64 {
        let per_point = figures(&self.episodes);
        let points: f64 = self.events.values()
            .filter(|e| e.0 + LIVE_MS > now && e.0 <= now)
            .filter_map(|e| per_point.get(&e.1).map(|p| e.2 as f64 / p))
            .sum();
        points / LIVE_MS as f64
    }
}

/// One assistant message's usage: input + output + cache write + cache read, by model, as
/// `token-track.py` counts it, and when it was stamped.
#[derive(Clone, Debug, PartialEq)]
pub struct Use { pub id: String, pub at: u64, pub model: String, pub tokens: u64, pub output: u64 }

/// The usage of one assistant `message` (a transcript row's or a stream frame's), stamped
/// `at`. `None` without usage, without tokens or without an id.
pub fn message_use(message: &Value, fallback_id: Option<&str>, at: u64) -> Option<Use> {
    let usage = message["usage"].as_object()?;
    let count = |field: &str| usage.get(field).and_then(Value::as_u64).unwrap_or(0);
    let output = count("output_tokens");
    let tokens = count("input_tokens") + output + count("cache_creation_input_tokens") + count("cache_read_input_tokens");
    if tokens == 0 { return None; }
    let id = message["id"].as_str().or(fallback_id)?.to_string();
    let model = message["model"].as_str().unwrap_or("unknown").to_string();
    Some(Use { id, at, model, tokens, output })
}

/// The most messages a sink holds before the quota service takes them (it takes them every
/// `TOKEN_SCAN_MS` and before every turn); past it the oldest go first.
const SINK_KEEP: usize = 20_000;

/// **Token use the app's own leases streamed** (the CEO, 2026-10-07; handoff round 2, run 10:
/// the leases run with `--no-session-persistence`, so they write no transcript and
/// `Track::scan` never saw the app's own teammates). Every lease's reader puts each
/// `assistant` frame's usage here under the account the lease runs on, its helpers' nested
/// frames included; the quota service takes them into that account's `Track`. A message
/// streamed in several frames counts once, at its largest copy, exactly as a transcript does.
#[derive(Debug, Default)]
pub struct Sink { pending: std::sync::Mutex<Vec<(String, Use)>> }

impl Sink {
    /// An `assistant` frame from a lease on `account`, received at `at`. Anything else, or an
    /// assistant frame with no usage, adds nothing.
    pub fn frame(&self, account: &str, frame: &Value, at: u64) {
        if frame["type"] != "assistant" { return; }
        let Some(found) = message_use(&frame["message"], frame["uuid"].as_str(), at) else { return };
        let mut pending = self.pending.lock().unwrap();
        if pending.len() >= SINK_KEEP { pending.remove(0); }
        pending.push((account.to_string(), found));
    }
    /// Everything put here since the last take, oldest first.
    pub fn take(&self) -> Vec<(String, Use)> {
        std::mem::take(&mut *self.pending.lock().unwrap())
    }
}

/// Tokens per weekly point for each model the episodes measure (see the module comment).
pub fn figures(episodes: &[Episode]) -> BTreeMap<String, f64> {
    let mut totals: BTreeMap<&str, u64> = BTreeMap::new();
    for episode in episodes {
        for (model, count) in &episode.tokens { *totals.entry(model).or_insert(0) += count; }
    }
    let mut models: Vec<(&str, u64)> = totals.into_iter().filter(|(_, t)| *t > 0).collect();
    models.sort_by_key(|m| std::cmp::Reverse(m.1));
    models.truncate(MAX_MODELS);
    // One row per episode with tokens: each model's tokens in millions, the points, the weight.
    let rows: Vec<(Vec<f64>, f64, f64)> = episodes.iter().filter_map(|e| {
        let all: u64 = e.tokens.values().sum();
        (all > 0 && e.points > 0.).then(|| (
            models.iter().map(|(m, _)| e.tokens.get(*m).copied().unwrap_or(0) as f64 / 1e6).collect(),
            e.points, 1e6 / all as f64))
    }).collect();
    // Non-negative least squares by trying every subset of models: the best fit whose every
    // coefficient is positive.
    let mut best: Option<(f64, Vec<usize>, Vec<f64>)> = None;
    for mask in 1u32..(1 << models.len()) {
        let pick: Vec<usize> = (0..models.len()).filter(|i| mask >> i & 1 == 1).collect();
        let k = pick.len();
        let mut system = vec![vec![0.; k + 1]; k];
        for (x, points, weight) in &rows {
            for (row, i) in system.iter_mut().zip(&pick) {
                for (cell, j) in row.iter_mut().zip(&pick) { *cell += weight * x[*i] * x[*j]; }
                row[k] += weight * x[*i] * points;
            }
        }
        let Some(per_million) = solve(system) else { continue };
        if per_million.iter().any(|c| c.is_nan() || *c <= 0.) { continue; }
        let residual: f64 = rows.iter().map(|(x, points, weight)| {
            let fit: f64 = pick.iter().zip(&per_million).map(|(i, c)| x[*i] * c).sum();
            weight * (points - fit).powi(2)
        }).sum();
        if best.as_ref().is_none_or(|(r, ..)| residual < *r) { best = Some((residual, pick, per_million)); }
    }
    let Some((_, pick, per_million)) = best else { return BTreeMap::new() };
    pick.into_iter().zip(per_million).map(|(i, c)| (models[i].0.to_string(), 1e6 / c)).collect()
}

/// Gaussian elimination with partial pivoting on an augmented `k x (k + 1)` system. `None` when
/// it is singular (the episodes cannot tell these models apart).
fn solve(mut a: Vec<Vec<f64>>) -> Option<Vec<f64>> {
    let k = a.len();
    let scale = (0..k).map(|i| a[i][i].abs()).fold(0., f64::max);
    if scale.is_nan() || scale <= 0. { return None; }
    for col in 0..k {
        let pivot = (col..k).max_by(|x, y| a[*x][col].abs().total_cmp(&a[*y][col].abs()))?;
        if a[pivot][col].abs() <= scale * 1e-9 { return None; }
        a.swap(col, pivot);
        let lead = a[col].clone();
        for (r, row) in a.iter_mut().enumerate() {
            if r != col {
                let factor = row[col] / lead[col];
                for (cell, l) in row.iter_mut().zip(&lead).skip(col) { *cell -= factor * l; }
            }
        }
    }
    Some((0..k).map(|i| a[i][k] / a[i][i]).collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn episode(points: f64, tokens: &[(&str, u64)]) -> Episode {
        Episode { points, tokens: tokens.iter().map(|(m, t)| (m.to_string(), *t)).collect() }
    }
    #[test]
    fn one_model_is_total_tokens_over_total_points_as_token_track_reports_it() {
        let f = figures(&[episode(1., &[("opus", 3_000_000)]), episode(2., &[("opus", 5_000_000)])]);
        assert!((f["opus"] - 8_000_000. / 3.).abs() < 1.);
    }
    #[test]
    fn mixed_episodes_separate_the_models() {
        // Opus 2M tokens a point, Sonnet 10M a point, in changing mixes.
        let eps = [
            episode(1., &[("opus", 1_000_000), ("sonnet", 5_000_000)]),
            episode(1., &[("opus", 1_500_000), ("sonnet", 2_500_000)]),
            episode(2., &[("opus", 3_000_000), ("sonnet", 5_000_000)]),
        ];
        let f = figures(&eps);
        assert!((f["opus"] - 2e6).abs() < 1e3, "{f:?}");
        assert!((f["sonnet"] - 1e7).abs() < 1e4, "{f:?}");
    }
    #[test]
    fn a_model_the_episodes_cannot_separate_has_no_figure() {
        // Always the same mix: only one of the two can be given a figure.
        let f = figures(&[episode(1., &[("opus", 1_000_000), ("sonnet", 1_000_000)]),
            episode(2., &[("opus", 2_000_000), ("sonnet", 2_000_000)])]);
        assert_eq!(f.len(), 1, "{f:?}");
    }
    #[test]
    fn a_streamed_message_counts_once_at_its_largest_copy() {
        let mut t = Track::default();
        t.add("m1", 1_000, "opus", 100, 1);
        t.add("m1", 1_000, "opus", 500, 9);
        t.add("m1", 1_000, "opus", 100, 1);
        assert_eq!(t.events["m1"].2, 500);
    }
}
