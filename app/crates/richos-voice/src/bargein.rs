//! Barge-in: how the CEO interrupts Rich mid-sentence — and the AEC seam that is NOT filled.
//!
//! ## The debounce, and why it is this number
//!
//! With an open mic next to speakers and **no acoustic echo cancellation**, Rich's own voice
//! comes back into the mic and a naive "any speech-like sound stops playback" monitor cuts him
//! off after a word or two. The earlier voice pilot hit exactly this
//! (the pilot's notes: "Known issue: echo triggers barge-in").
//!
//! The field-proven workaround, CEO-directed at v3 of that patch, is a long **consecutive-frame**
//! debounce: echo arrives in short bursts with gaps between syllables, so any gap resets the run
//! and the counter never reaches the threshold — while a human deliberately talking over Rich
//! for a beat produces a continuous run and does get through.
//!
//! ```text
//!   BARGE_IN_DEBOUNCE_FRAMES = 313
//!   313 frames x 256 samples/frame = 80 128 samples
//!   80 128 samples / 16 000 samples/s = 5.008 s
//! ```
//!
//! Re-derived here rather than trusted: `frames_for_secs(5.0)` = ceil(5.0 x 16000 / 256)
//! = ceil(312.5) = 313, and `frames_to_secs(313)` = 5.008 s exactly. Both are asserted in
//! `vad.rs`'s tests and again below.
//!
//! **This is a workaround, not a fix.** It makes Rich effectively uninterruptible in casual
//! conversation (finish-your-thought behaviour). The instant override is the explicit "tap to
//! stop" control in the UI, which calls [`BargeInMonitor::force`] — the manual half of the
//! interim, exactly as the pilot's mute button was.
//!
//! ## The AEC seam ([`EchoGate`])
//!
//! Real echo cancellation is the still-open gap inherited from the pilot and is explicitly
//! NOT a v1 blocker (CEO, 2026-08-24). What v1 DOES ship is the seam already carrying live
//! data: the playout path feeds every rendered output frame to
//! [`EchoGate::observe_playback`], so a future reference-signal-gated suppressor (or WebRTC
//! AEC3) has the reference signal it needs the day it lands, with no plumbing work.
//! The v1 implementation, [`NoEchoCancellation`], cancels nothing and says so.

use crate::vad::{frames_for_secs, frames_to_secs};

/// Consecutive speech frames required to interrupt Rich while he is speaking.
/// 313 x 256 / 16000 = 5.008 s. See the module docs for why it is this long.
pub const BARGE_IN_DEBOUNCE_FRAMES: u32 = 313;

/// The exact debounce duration in seconds, derived from the frame count.
pub fn barge_in_debounce_secs() -> f32 {
    frames_to_secs(BARGE_IN_DEBOUNCE_FRAMES)
}

/// Watches the mic while Rich is speaking and reports the moment the CEO has been talking
/// over him for a continuous [`BARGE_IN_DEBOUNCE_FRAMES`].
///
/// Disarmed by default: the monitor only counts while Rich actually has audio playing, so a
/// CEO talking during silence is a normal utterance, not an interruption.
#[derive(Debug, Clone)]
pub struct BargeInMonitor {
    required: u32,
    run: u32,
    armed: bool,
    fired: bool,
}

impl Default for BargeInMonitor {
    fn default() -> Self {
        BargeInMonitor::with_frames(BARGE_IN_DEBOUNCE_FRAMES)
    }
}

impl BargeInMonitor {
    /// Build a monitor with an explicit frame threshold (tests, and the one-line retune the
    /// pilot's history shows this number will get).
    pub fn with_frames(required: u32) -> Self {
        BargeInMonitor { required, run: 0, armed: false, fired: false }
    }

    /// Build a monitor from a duration in seconds, rounded UP to whole frames.
    pub fn with_secs(secs: f32) -> Self {
        BargeInMonitor::with_frames(frames_for_secs(secs))
    }

    pub fn required_frames(&self) -> u32 {
        self.required
    }

    /// Consecutive speech frames observed in the current run — the diagnostic that makes
    /// "it didn't barge in" debuggable instead of mysterious.
    pub fn run_frames(&self) -> u32 {
        self.run
    }

    pub fn is_armed(&self) -> bool {
        self.armed
    }

    /// Rich started speaking: start watching. Resets the run so speech from before playout
    /// began can never count toward an interruption.
    pub fn arm(&mut self) {
        self.armed = true;
        self.run = 0;
        self.fired = false;
    }

    /// Rich stopped speaking: stop watching.
    pub fn disarm(&mut self) {
        self.armed = false;
        self.run = 0;
        self.fired = false;
    }

    /// Feed one VAD verdict. Returns true EXACTLY ONCE per armed period, on the frame that
    /// completes the debounce.
    pub fn push(&mut self, is_speech: bool) -> bool {
        if !self.armed || self.fired {
            return false;
        }
        if is_speech {
            self.run += 1;
            if self.run >= self.required {
                self.fired = true;
                return true;
            }
        } else {
            // The reset that makes the whole scheme work: echo is bursty, so any gap between
            // Rich's own syllables returns the run to zero.
            self.run = 0;
        }
        false
    }

    /// The manual override — the UI's "tap to stop". Fires immediately if armed, bypassing
    /// the debounce entirely. This is the CEO's instant interrupt while AEC is missing.
    pub fn force(&mut self) -> bool {
        if !self.armed || self.fired {
            return false;
        }
        self.fired = true;
        true
    }
}

/// The acoustic-echo-cancellation seam.
///
/// `observe_playback` receives every frame RichOS renders to the speakers (the reference
/// signal); `process_capture` may modify the mic frame in place before the VAD sees it.
/// A real implementation subtracts the (delayed, room-filtered) reference from the capture.
pub trait EchoGate: Send {
    /// One frame of what RichOS just sent to the output device, at the capture sample rate.
    fn observe_playback(&mut self, frame: &[f32]);
    /// One mic frame, mutable, immediately before VAD classification.
    fn process_capture(&mut self, frame: &mut [f32]);
    /// Honest identity for logs and the UI's "headphones recommended" note.
    fn name(&self) -> &'static str;
    /// Whether this gate actually cancels anything. `false` means the 5.008 s debounce +
    /// headphones are the whole story — the UI keeps showing the honest note.
    fn cancels(&self) -> bool;
}

/// **v1.** No cancellation whatsoever. The reference signal is observed and discarded, so
/// the plumbing is proven live and a real canceller is a drop-in replacement for this type.
///
/// This is the honest fallback the architecture doc's open question (§7) and the CEO's
/// "real AEC is NOT a v1 blocker" decision call for — not a fix wearing a fix's name.
#[derive(Debug, Default)]
pub struct NoEchoCancellation {
    /// Reference frames seen — proves the seam is actually wired at runtime.
    observed_frames: u64,
}

impl NoEchoCancellation {
    pub fn observed_frames(&self) -> u64 {
        self.observed_frames
    }
}

impl EchoGate for NoEchoCancellation {
    fn observe_playback(&mut self, _frame: &[f32]) {
        self.observed_frames += 1;
    }
    fn process_capture(&mut self, _frame: &mut [f32]) {
        // Intentionally empty. See the type docs.
    }
    fn name(&self) -> &'static str {
        "none (5.008s debounce + headphones)"
    }
    fn cancels(&self) -> bool {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// INVARIANT: the shipped debounce is 313 frames = 5.008 s, re-derived from the frame
    /// math rather than copied from the pilot's comment.
    #[test]
    fn shipped_debounce_is_313_frames_which_is_5008_milliseconds() {
        assert_eq!(BARGE_IN_DEBOUNCE_FRAMES, frames_for_secs(5.0));
        assert_eq!(BARGE_IN_DEBOUNCE_FRAMES, 313);
        assert!((barge_in_debounce_secs() - 5.008).abs() < 1e-6, "{}", barge_in_debounce_secs());
    }

    /// INVARIANT: a disarmed monitor never fires, however much the CEO talks — speech while
    /// Rich is silent is an utterance, not an interruption.
    #[test]
    fn a_disarmed_monitor_never_fires() {
        let mut m = BargeInMonitor::default();
        for _ in 0..(BARGE_IN_DEBOUNCE_FRAMES * 3) {
            assert!(!m.push(true));
        }
        assert!(!m.force());
    }

    /// INVARIANT: continuous speech fires EXACTLY on the 313th frame — not the 312th.
    #[test]
    fn continuous_speech_fires_on_the_313th_frame_not_the_312th() {
        let mut m = BargeInMonitor::default();
        m.arm();
        for i in 1..BARGE_IN_DEBOUNCE_FRAMES {
            assert!(!m.push(true), "fired early at frame {i}");
        }
        assert_eq!(m.run_frames(), BARGE_IN_DEBOUNCE_FRAMES - 1);
        assert!(m.push(true), "should fire on frame {BARGE_IN_DEBOUNCE_FRAMES}");
    }

    /// INVARIANT: the debounce fires at most once per armed period, so one interruption can
    /// never be delivered twice.
    #[test]
    fn fires_at_most_once_per_armed_period() {
        let mut m = BargeInMonitor::default();
        m.arm();
        let mut fires = 0;
        for _ in 0..(BARGE_IN_DEBOUNCE_FRAMES * 2) {
            if m.push(true) {
                fires += 1;
            }
        }
        assert_eq!(fires, 1);
        m.arm(); // Rich speaks again -> a fresh interruption is possible
        let mut fires2 = 0;
        for _ in 0..BARGE_IN_DEBOUNCE_FRAMES {
            if m.push(true) {
                fires2 += 1;
            }
        }
        assert_eq!(fires2, 1);
    }

    /// THE ECHO CASE — the whole reason the debounce exists. Rich's own voice returning
    /// through the mic is bursty: syllables with gaps. Simulate 30 seconds of it (bursts of
    /// 20 speech frames = 320 ms separated by 5 silent frames = 80 ms) and assert it NEVER
    /// interrupts him, because every gap resets the run.
    #[test]
    fn bursty_echo_never_barges_in_because_gaps_reset_the_run() {
        let mut m = BargeInMonitor::default();
        m.arm();
        // 30 s / (25 frames x 16 ms) = 75 bursts.
        for _ in 0..75 {
            for _ in 0..20 {
                assert!(!m.push(true), "echo burst fired a barge-in");
            }
            for _ in 0..5 {
                assert!(!m.push(false));
            }
        }
        assert_eq!(m.run_frames(), 0);
    }

    /// INVARIANT: a run one frame short, then a gap, then a full run — only the full run
    /// fires. Guards against an off-by-one that would let echo accumulate across gaps.
    #[test]
    fn a_gap_one_frame_before_the_threshold_discards_the_whole_run() {
        let mut m = BargeInMonitor::default();
        m.arm();
        for _ in 0..(BARGE_IN_DEBOUNCE_FRAMES - 1) {
            assert!(!m.push(true));
        }
        assert!(!m.push(false));
        assert_eq!(m.run_frames(), 0);
        for i in 1..BARGE_IN_DEBOUNCE_FRAMES {
            assert!(!m.push(true), "fired early at {i} after the reset");
        }
        assert!(m.push(true));
    }

    /// INVARIANT: "tap to stop" is instant and bypasses the debounce — the CEO's override
    /// while AEC is missing.
    #[test]
    fn tap_to_stop_interrupts_instantly_without_the_debounce() {
        let mut m = BargeInMonitor::default();
        m.arm();
        assert!(m.force());
        assert!(!m.force(), "force must be single-shot per armed period");
    }

    /// INVARIANT: the retune the pilot's history says is coming is one argument, and the
    /// derived duration follows the frame count exactly.
    #[test]
    fn retuning_the_debounce_is_one_number_and_the_math_follows() {
        let m = BargeInMonitor::with_secs(1.2);
        // 1.2 s -> ceil(1.2 x 16000 / 256) = ceil(75.0) = 75 frames -> 1.200 s exactly.
        assert_eq!(m.required_frames(), 75);
        assert!((frames_to_secs(75) - 1.2).abs() < 1e-6);
    }

    /// INVARIANT: v1's gate is honest — it observes the reference signal (proving the seam
    /// is wired) and modifies nothing.
    #[test]
    fn v1_echo_gate_observes_the_reference_signal_and_cancels_nothing() {
        let mut gate = NoEchoCancellation::default();
        gate.observe_playback(&[0.5; 256]);
        gate.observe_playback(&[0.5; 256]);
        assert_eq!(gate.observed_frames(), 2);
        let mut capture = vec![0.25f32; 256];
        let before = capture.clone();
        gate.process_capture(&mut capture);
        assert_eq!(capture, before, "v1 gate must not pretend to cancel");
        assert!(!gate.cancels());
    }
}
