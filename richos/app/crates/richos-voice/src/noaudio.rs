//! Post-open silent-input detection — "the stream opened perfectly and delivers nothing".
//!
//! `capture.rs` already makes device *selection* safe: the default input is resolved fresh at
//! every stream open and a zero-input device fails loudly. This module covers the case that
//! survives all of that — the stream opens, CoreAudio is happy, and the samples arriving are
//! dead. A muted mic, the Elgato Wave:3's capacitive mute, input gain at zero, macOS input
//! volume at zero, a TCC-denied process (macOS hands a denied process an endless stream of
//! zeros, not an error — see `examples/device_probe.rs`).
//!
//! Without this, RichOS sits with a hot mic listening to nothing, forever, saying nothing.
//! That exact failure class cost weeks in the CEO's dictation app (diagnosed 2026-08-24,
//! the dictation troubleshooting runbook, 2026-08-24). Our product must not repeat it.
//!
//! ## What it detects — and the distinction the whole design turns on
//!
//! This detects **absence of SIGNAL, not absence of SPEECH.** That is not a nuance, it is the
//! reason the thing is safe to run in always-on voice mode:
//!
//! - A working microphone in a real room *always* delivers something — room tone, preamp
//!   self-noise, a fan. Measured on this machine's Elgato Wave:3, quiet room, macOS input
//!   volume 44: **RMS 0.000499 = -66.0 dBFS** per second of capture.
//! - A muted microphone delivers essentially nothing. Same device, same room, macOS input
//!   volume 0: **peak 0.000002 = -114.0 dBFS, RMS below the 1e-6 print floor (< -120 dBFS)**.
//!
//! There is roughly **50 dB of clear air** between those two states. So the detector never
//! has to guess whether the CEO is talking — a conversational pause, a long silence while he
//! reads something, a whole minute of nothing to say, all still carry room tone and all read
//! as LIVE. Nothing about "he stopped talking" can make this fire.
//!
//! ## The numbers, and why they are not the Swift ones
//!
//! The Swift reference (`tools/open-wispr-hud/`, the design lead's endorsed spec) uses a 0.03 threshold
//! on its smoothed meter over a -55..-12 dBFS window — that is **-53.7 dBFS = RMS 0.00206**,
//! with a 1.4 s grace. Ported literally, both numbers are wrong here:
//!
//! - **-53.7 dBFS is 12.3 dB ABOVE this room's measured live room tone (-66.0 dBFS).** It
//!   would raise "no audio" on a perfectly working Elgato in a quiet office. The CEO's stated
//!   failure preference is "too quiet, never annoying"; a false warning mid-sentence is the
//!   worst outcome available, so that number cannot ship here.
//! - **1.4 s is a push-to-talk grace.** Dictation knows the user pressed a key *intending to
//!   speak now*. Voice mode is always-on: there is no such instant, so there is no elapsed
//!   clock to measure against — the window here is a run of consecutive dead frames instead.
//!
//! The reason the Swift number works in its own context is that it is not really a silence
//! threshold there, it is a "did any speech happen in this push-to-talk recording" threshold.
//! Same name, different job. See the brief.
//!
//! ```text
//!   fire floor  SILENCE_RMS = 1.0e-4  = -80.00 dBFS   (14.0 dB below measured room tone)
//!   clear floor LIVE_RMS    = 2.0e-4  = -73.98 dBFS   (+6.02 dB hysteresis, 8.1 dB below room tone)
//!   window      NO_AUDIO_FRAMES = 188  ->  188 x 256 / 16000 = 3.008 s
//! ```
//!
//! Between the two floors the detector **freezes**: it neither counts toward a warning nor
//! clears one. That is the Schmitt trigger that stops a marginal input (a mic at very low
//! gain hovering around -77 dBFS) from blinking a warning on and off every three seconds.

use crate::vad::frames_to_secs;

/// Frames of consecutive dead input before the CEO is told. 188 x 256 / 16000 = 3.008 s.
///
/// Chosen against what the warning is *for*: he taps `◉`, says a sentence into a muted mic,
/// and needs to find out inside the time it takes to say it — not after he has repeated
/// himself twice. A typical short command ("Rich, what's on today") is ~2 s, so 3.008 s puts
/// the line on screen as he finishes it.
///
/// It doubles as the start-up grace: the run counter starts at zero when voice mode opens, so
/// no warning is possible in the first 3.008 s of a session whatever the device is doing
/// while CoreAudio settles.
pub const NO_AUDIO_FRAMES: u32 = 188;

/// A frame at or below this RMS carries no signal at all. -80.00 dBFS.
///
/// 14.0 dB below the room tone measured on this machine's live Elgato Wave:3 (-66.0 dBFS) and
/// at least 34 dB above the same device muted (peak -114.0 dBFS). Analog self-noise alone
/// puts any live input path above this; only a dead one sits under it.
pub const SILENCE_RMS: f32 = 1.0e-4;

/// A frame at or above this RMS proves the input is live and clears the warning at once.
/// 2.0e-4 = -73.98 dBFS, exactly 6.02 dB of hysteresis above [`SILENCE_RMS`].
pub const LIVE_RMS: f32 = 2.0e-4;

/// RMS amplitude as dBFS. Diagnostics and tests — this is how every threshold above was
/// chosen, so it is derived here rather than quoted.
pub fn dbfs(rms: f32) -> f32 {
    20.0 * rms.max(1e-12).log10()
}

/// The exact duration [`NO_AUDIO_FRAMES`] represents. 3.008 s, not "about three seconds".
pub fn no_audio_window_secs() -> f32 {
    frames_to_secs(NO_AUDIO_FRAMES)
}

#[derive(Debug, Clone, Copy)]
pub struct NoAudioConfig {
    pub silence_rms: f32,
    pub live_rms: f32,
    pub dead_frames: u32,
}

impl Default for NoAudioConfig {
    fn default() -> Self {
        NoAudioConfig {
            silence_rms: SILENCE_RMS,
            live_rms: LIVE_RMS,
            dead_frames: NO_AUDIO_FRAMES,
        }
    }
}

/// Watches the samples the capture path actually delivers and decides whether the input is
/// dead. Pure: no clock, no device, no allocation. The caller feeds it the RMS of the SAME
/// frame the recorder buffers (collector-path parity — see [`NoAudioDetector::observe`]).
#[derive(Debug, Clone)]
pub struct NoAudioDetector {
    cfg: NoAudioConfig,
    dead_run: u32,
    warned: bool,
}

impl Default for NoAudioDetector {
    fn default() -> Self {
        NoAudioDetector::new(NoAudioConfig::default())
    }
}

impl NoAudioDetector {
    pub fn new(cfg: NoAudioConfig) -> Self {
        NoAudioDetector { cfg, dead_run: 0, warned: false }
    }

    /// One exact VAD frame's RMS, plus whether Rich currently has audio playing.
    ///
    /// `rich_is_speaking` FREEZES the detector — no counting, no clearing, no state change.
    /// Two reasons, both structural. (1) With no AEC and open speakers, Rich's own voice
    /// comes back into the mic and would falsely prove the input live; with headphones it
    /// would not, so evidence gathered during playout means different things on different
    /// hardware and is worth nothing either way. (2) The CEO must never be told "I can't hear
    /// you" while Rich is mid-sentence — that is the "annoying" failure mode he ruled out.
    ///
    /// Returns `true` if the warning state CHANGED, so the caller can emit exactly once per
    /// transition instead of once per 16 ms frame.
    pub fn observe(&mut self, rms: f32, rich_is_speaking: bool) -> bool {
        if rich_is_speaking {
            return false;
        }
        let was = self.warned;
        if rms >= self.cfg.live_rms {
            // Real signal. The input is alive; forget everything.
            self.dead_run = 0;
            self.warned = false;
        } else if rms < self.cfg.silence_rms {
            self.dead_run = self.dead_run.saturating_add(1);
            if self.dead_run >= self.cfg.dead_frames {
                self.warned = true;
            }
        }
        // Between the floors: hold. Neither evidence of life nor evidence of death.
        self.warned != was
    }

    /// Is the CEO currently being told the mic is delivering nothing?
    pub fn no_audio(&self) -> bool {
        self.warned
    }

    /// Consecutive dead frames counted so far — the diagnostic that makes "why did/didn't it
    /// warn" answerable without guessing.
    pub fn dead_run_frames(&self) -> u32 {
        self.dead_run
    }

    /// That run as seconds, via the one frame-math helper. Never estimated.
    pub fn dead_run_secs(&self) -> f32 {
        frames_to_secs(self.dead_run)
    }

    /// Voice mode restarted, or the device was re-opened. Nothing carries over.
    pub fn reset(&mut self) {
        self.dead_run = 0;
        self.warned = false;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// RMS of a sine at a given amplitude — the fixture the rest of the crate's tests use,
    /// so "room tone" here means the same thing it means in barge_in_composition.rs.
    fn sine_rms(amp: f32) -> f32 {
        amp / std::f32::consts::SQRT_2
    }

    /// Digital silence, exactly what a muted device delivers.
    const DEAD: f32 = 0.0;
    /// The measured live room tone on this machine's Elgato Wave:3: -66.04 dBFS.
    const ROOM_TONE: f32 = 0.000499;

    /// INVARIANT: the window is exactly 3.008 s — 188 x 256 / 16000 — re-derived, not quoted.
    #[test]
    fn the_no_audio_window_is_exactly_three_point_zero_zero_eight_seconds() {
        assert_eq!(NO_AUDIO_FRAMES, crate::vad::frames_for_secs(3.0));
        assert_eq!(
            NO_AUDIO_FRAMES as usize * crate::vad::VAD_FRAME_SAMPLES,
            48_128,
            "188 frames x 256 samples"
        );
        assert!(
            (no_audio_window_secs() - 3.008).abs() < 1e-6,
            "window is {:.4} s",
            no_audio_window_secs()
        );
    }

    /// INVARIANT: the two floors are the measured ones, in dBFS, and they sit BELOW the live
    /// room tone this machine actually produces. If someone retunes them upward past that
    /// measurement, a working microphone starts raising "no audio" — fail here instead.
    #[test]
    fn both_floors_sit_below_the_measured_live_room_tone() {
        assert!((dbfs(SILENCE_RMS) + 80.0).abs() < 0.01, "{}", dbfs(SILENCE_RMS));
        assert!((dbfs(LIVE_RMS) + 73.98).abs() < 0.01, "{}", dbfs(LIVE_RMS));
        // Measured 2026-08-24, Elgato Wave:3, macOS input volume 44, quiet room.
        let room = dbfs(ROOM_TONE);
        assert!((room + 66.04).abs() < 0.02, "room tone drifted: {room}");
        assert!(dbfs(LIVE_RMS) < room - 6.0, "clear floor is too close to real room tone");
        assert!(dbfs(SILENCE_RMS) < room - 12.0, "fire floor is too close to real room tone");
        // …and comfortably above the same device muted (peak -113.98 dBFS).
        assert!(dbfs(SILENCE_RMS) > dbfs(0.000002) + 30.0);
    }

    /// INVARIANT: true silence raises the warning, and does so at frame 188 — not at 187, not
    /// at 500. The CEO finds out inside the time it takes to say one sentence.
    #[test]
    fn true_silence_fires_at_frame_188_and_not_before() {
        let mut d = NoAudioDetector::default();
        for i in 1..NO_AUDIO_FRAMES {
            let changed = d.observe(DEAD, false);
            assert!(!changed && !d.no_audio(), "fired early at frame {i}");
        }
        assert!(d.observe(DEAD, false), "frame 188 should be the transition");
        assert!(d.no_audio());
        assert!((d.dead_run_secs() - 3.008).abs() < 1e-6, "{}", d.dead_run_secs());
    }

    /// INVARIANT: the transition is reported ONCE. A detector that returns `changed` on every
    /// silent frame would emit a UI event at 62.5 Hz forever.
    #[test]
    fn the_warning_transition_is_reported_exactly_once() {
        let mut d = NoAudioDetector::default();
        let mut changes = 0;
        for _ in 0..(NO_AUDIO_FRAMES * 4) {
            if d.observe(DEAD, false) {
                changes += 1;
            }
        }
        assert_eq!(changes, 1, "the warning re-announced itself");
    }

    /// INVARIANT — the one that makes this safe in always-on voice mode: a CEO who simply
    /// says nothing is NEVER warned. A live mic in a quiet room carries room tone, and room
    /// tone is signal. Ten minutes of it must not produce a single warning.
    #[test]
    fn ten_minutes_of_a_silent_ceo_in_a_live_quiet_room_never_warns() {
        let mut d = NoAudioDetector::default();
        // 10 minutes / 16.000 ms = 37 500 frames.
        for i in 0..37_500u32 {
            assert!(!d.observe(ROOM_TONE, false), "warned at frame {i} on a LIVE mic");
        }
        assert!(!d.no_audio());
        assert_eq!(d.dead_run_frames(), 0);
    }

    /// INVARIANT: an ordinary conversational pause — speech, a beat of room tone, speech —
    /// is not a silent input. This is the "does NOT fire on conversational pauses" case, and
    /// it holds structurally: the pause still carries signal.
    #[test]
    fn a_conversational_pause_between_sentences_never_warns() {
        let mut d = NoAudioDetector::default();
        for _ in 0..12 {
            // ~1.6 s of speech
            for _ in 0..100 {
                assert!(!d.observe(sine_rms(0.25), false));
            }
            // ~4.8 s of thinking — LONGER than the 3.008 s window, deliberately.
            for _ in 0..300 {
                assert!(!d.observe(ROOM_TONE, false), "a pause was mistaken for a dead mic");
            }
        }
        assert!(!d.no_audio());
    }

    /// INVARIANT: the CEO is never told "I can't hear you" while Rich is talking. Playout
    /// freezes the detector outright — even an already-dead input gathers no new evidence and
    /// raises nothing mid-sentence.
    #[test]
    fn rich_speaking_never_produces_a_no_audio_warning() {
        let mut d = NoAudioDetector::default();
        // A full minute of Rich talking into a genuinely dead microphone.
        for i in 0..3_750u32 {
            assert!(!d.observe(DEAD, true), "warned during Rich's speech at frame {i}");
            assert!(!d.no_audio());
        }
        assert_eq!(d.dead_run_frames(), 0, "playout frames were counted as evidence");
        // The moment he stops, the window starts honestly from zero.
        for _ in 0..(NO_AUDIO_FRAMES - 1) {
            assert!(!d.observe(DEAD, false));
        }
        assert!(d.observe(DEAD, false));
    }

    /// INVARIANT: a warning already on screen is not cleared by Rich starting to speak — the
    /// flag stays truthful; it is the UI that stops showing the listening row. A detector
    /// that silently un-warned here would lie the moment he finished.
    #[test]
    fn playout_freezes_the_detector_rather_than_clearing_a_live_warning() {
        let mut d = NoAudioDetector::default();
        for _ in 0..NO_AUDIO_FRAMES {
            d.observe(DEAD, false);
        }
        assert!(d.no_audio());
        for _ in 0..1_000 {
            assert!(!d.observe(DEAD, true), "state changed while Rich was speaking");
        }
        assert!(d.no_audio(), "the warning was silently dropped during playout");
    }

    /// INVARIANT: unmuting clears the warning immediately and the detector RE-ARMS — a
    /// mute/unmute cycle must never need a restart of voice mode.
    #[test]
    fn a_mute_unmute_cycle_clears_and_re_arms_without_a_restart() {
        let mut d = NoAudioDetector::default();
        for _ in 0..NO_AUDIO_FRAMES {
            d.observe(DEAD, false);
        }
        assert!(d.no_audio(), "premise: muted");

        // He hits the mute button again. One live frame is enough — 16.000 ms.
        assert!(d.observe(ROOM_TONE, false), "unmuting did not clear the warning");
        assert!(!d.no_audio());
        assert_eq!(d.dead_run_frames(), 0);

        // …and it can fire again on the next mute, from scratch.
        for i in 1..NO_AUDIO_FRAMES {
            assert!(!d.observe(DEAD, false), "re-armed window fired early at frame {i}");
        }
        assert!(d.observe(DEAD, false), "the detector did not re-arm");
        assert!(d.no_audio());
    }

    /// INVARIANT: the hysteresis band holds. An input hovering between the floors neither
    /// warns nor clears — no three-second blink on a marginal microphone.
    #[test]
    fn an_input_hovering_between_the_floors_neither_warns_nor_blinks() {
        let between = (SILENCE_RMS + LIVE_RMS) / 2.0; // -76.5 dBFS
        assert!(between >= SILENCE_RMS && between < LIVE_RMS, "premise");

        let mut d = NoAudioDetector::default();
        for _ in 0..10_000 {
            assert!(!d.observe(between, false), "a marginal input toggled the warning");
        }
        assert!(!d.no_audio(), "a marginal input is quiet, not dead");

        // And it cannot rescue an input that has already been proven dead…
        let mut d2 = NoAudioDetector::default();
        for _ in 0..NO_AUDIO_FRAMES {
            d2.observe(DEAD, false);
        }
        assert!(d2.no_audio());
        for _ in 0..10_000 {
            assert!(!d2.observe(between, false));
        }
        assert!(d2.no_audio(), "a marginal frame cleared a proven-dead input");
    }

    /// INVARIANT: an intermittent input — one live frame every couple of seconds — never
    /// warns. Rare, but it is the shape a failing USB cable makes, and a warning that
    /// strobes is exactly the "annoying" failure the CEO ruled out.
    #[test]
    fn an_intermittent_input_does_not_strobe_the_warning() {
        let mut d = NoAudioDetector::default();
        let mut changes = 0;
        for _ in 0..200 {
            for _ in 0..120 {
                // 1.920 s dead — under the window
                if d.observe(DEAD, false) {
                    changes += 1;
                }
            }
            if d.observe(ROOM_TONE, false) {
                changes += 1;
            }
        }
        assert_eq!(changes, 0, "the warning flickered {changes} times");
    }

    /// INVARIANT: reset returns the detector to its opening state, so re-entering voice mode
    /// cannot inherit a stale warning about a device that is no longer even open.
    #[test]
    fn reset_leaves_no_stale_warning_for_the_next_session() {
        let mut d = NoAudioDetector::default();
        for _ in 0..(NO_AUDIO_FRAMES + 50) {
            d.observe(DEAD, false);
        }
        assert!(d.no_audio());
        d.reset();
        assert!(!d.no_audio());
        assert_eq!(d.dead_run_frames(), 0);
    }

    /// INVARIANT: the Swift reference's threshold is documented as NOT portable here, and the
    /// reason is arithmetic, not opinion — -53.7 dBFS sits ABOVE this room's live room tone,
    /// so porting it would warn on a working microphone. Asserted so the number cannot quietly
    /// creep back in during a "let's match the HUD" tidy-up.
    #[test]
    fn the_swift_huds_threshold_would_false_fire_on_this_live_microphone() {
        // tools/open-wispr-hud: meter 0.03 across a -55..-12 dBFS window.
        let swift_dbfs = -55.0 + 0.03 * (-12.0 - -55.0);
        let swift_rms = 10f32.powf(swift_dbfs / 20.0);
        assert!((swift_dbfs + 53.71).abs() < 0.01, "{swift_dbfs}");
        assert!(
            swift_rms > ROOM_TONE,
            "premise changed: the Swift floor {swift_rms:.6} no longer exceeds room tone"
        );

        let mut ported = NoAudioDetector::new(NoAudioConfig {
            silence_rms: swift_rms,
            live_rms: swift_rms * 2.0,
            dead_frames: NO_AUDIO_FRAMES,
        });
        for _ in 0..NO_AUDIO_FRAMES {
            ported.observe(ROOM_TONE, false);
        }
        assert!(ported.no_audio(), "premise: the ported number warns on a live mic");

        // Ours does not, on the identical input.
        let mut ours = NoAudioDetector::default();
        for _ in 0..NO_AUDIO_FRAMES {
            ours.observe(ROOM_TONE, false);
        }
        assert!(!ours.no_audio());
    }
}
