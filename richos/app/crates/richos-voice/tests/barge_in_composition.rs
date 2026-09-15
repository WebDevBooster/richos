//! Integration tests for the barge-in COMPOSITION — the wiring, not the parts.
//!
//! `vad.rs`, `bargein.rs` and `endpoint.rs` each test themselves. The bugs that actually
//! reach a CEO live in how they are combined: does 30 seconds of Rich's own voice coming
//! back through the speakers produce a phantom turn? Does a genuine interruption survive
//! the taint rule that stops the phantom? Does "tap to stop" rescue the words the CEO is
//! saying at that instant?
//!
//! These drive `CaptureBrain` — the EXACT struct the audio callback runs, not a copy of its
//! logic — one 16.000 ms frame at a time.

use richos_voice::aec::{EchoCanceller, ReferenceRing, AEC_BLOCK};
use richos_voice::bargein::{BargeInMode, BARGE_IN_DEBOUNCE_FRAMES};
use richos_voice::controller::{CapMsg, CaptureBrain};
use std::sync::Arc;
use richos_voice::endpoint::{MIN_SPEECH_FRAMES, SILENCE_HANGOVER_FRAMES, SPEECH_ONSET_FRAMES};
use richos_voice::vad::{frames_to_secs, SAMPLE_RATE, VAD_FRAME_SAMPLES};

/// One frame of "voice": a 220 Hz tone at a normal speaking level. Phase is continuous
/// across calls so the VAD sees a plausible signal rather than a click train.
struct Tone {
    phase: f32,
}
impl Tone {
    fn new() -> Self {
        Tone { phase: 0.0 }
    }
    fn frame(&mut self, amp: f32) -> Vec<f32> {
        let step = 2.0 * std::f32::consts::PI * 220.0 / SAMPLE_RATE as f32;
        (0..VAD_FRAME_SAMPLES)
            .map(|_| {
                let v = amp * self.phase.sin();
                self.phase += step;
                v
            })
            .collect()
    }
}

fn is_barge(m: &CapMsg) -> bool {
    matches!(m, CapMsg::BargeIn { .. })
}
fn is_utterance(m: &CapMsg) -> bool {
    matches!(m, CapMsg::Utterance(_))
}
fn is_tainted_discard(m: &CapMsg) -> bool {
    matches!(m, CapMsg::Discarded { tainted: true })
}

/// Settle the adaptive noise floor on a quiet room before each scenario, exactly as a real
/// session does in its first second.
fn settle(brain: &mut CaptureBrain, tone: &mut Tone) {
    for _ in 0..80 {
        brain.push_frame(&tone.frame(0.0005), false, false);
    }
}

/// THE ECHO SCENARIO — the one the whole design exists for.
///
/// Rich is speaking. With no AEC and open speakers, his own voice comes back into the mic in
/// bursts (syllables with gaps). Thirty seconds of it must produce: no interruption, and no
/// turn. If either leaks, Rich transcribes himself and answers himself.
#[test]
fn thirty_seconds_of_richs_own_voice_produces_no_interruption_and_no_turn() {
    let mut brain = CaptureBrain::new();
    let mut tone = Tone::new();
    settle(&mut brain, &mut tone);

    let mut barges = 0;
    let mut turns = 0;
    let mut tainted_discards = 0;

    // 30 s / (25 frames x 16.000 ms) = 75 bursts of 320 ms speech + 80 ms gap.
    for _ in 0..75 {
        for _ in 0..20 {
            for m in brain.push_frame(&tone.frame(0.25), true, false) {
                if is_barge(&m) {
                    barges += 1;
                }
                if is_utterance(&m) {
                    turns += 1;
                }
                if is_tainted_discard(&m) {
                    tainted_discards += 1;
                }
            }
        }
        for _ in 0..5 {
            for m in brain.push_frame(&tone.frame(0.0005), true, false) {
                if is_barge(&m) {
                    barges += 1;
                }
                if is_utterance(&m) {
                    turns += 1;
                }
                if is_tainted_discard(&m) {
                    tainted_discards += 1;
                }
            }
        }
    }
    assert_eq!(barges, 0, "echo interrupted Rich");
    assert_eq!(turns, 0, "Rich transcribed his own voice as a CEO turn");
    // The taint rule must actually be the thing doing the work here, not luck: the echo did
    // form utterances (its 320 ms bursts are longer than the 0.304 s minimum) and they were
    // discarded because they began while Rich was audible.
    assert!(tainted_discards > 0, "the taint rule never fired — this test proved nothing");
}

/// A DELIBERATE interruption: the CEO talks over Rich continuously. It must cut Rich at
/// exactly the 313th frame, and the words he is saying must still become a turn — barge-in
/// that eats the start of your sentence is worse than no barge-in.
#[test]
fn a_deliberate_interruption_cuts_rich_at_frame_313_and_still_becomes_a_turn() {
    let mut brain = CaptureBrain::new();
    let mut tone = Tone::new();
    settle(&mut brain, &mut tone);

    let mut barge_frame = None;
    for i in 1..=(BARGE_IN_DEBOUNCE_FRAMES + 50) {
        for m in brain.push_frame(&tone.frame(0.25), true, false) {
            if is_barge(&m) && barge_frame.is_none() {
                barge_frame = Some(i);
            }
        }
    }
    let at = barge_frame.expect("a continuous interruption never cut through");
    assert_eq!(at, BARGE_IN_DEBOUNCE_FRAMES, "cut at frame {at}, not {BARGE_IN_DEBOUNCE_FRAMES}");
    assert!(
        (frames_to_secs(at) - 5.008).abs() < 1e-6,
        "the interruption took {:.3} s, not 5.008 s",
        frames_to_secs(at)
    );

    // Rich's audio has been cut, so `speaking` goes false; the CEO carries on and stops.
    let mut utterance = None;
    for _ in 0..40 {
        brain.push_frame(&tone.frame(0.25), false, false);
    }
    for _ in 0..(SILENCE_HANGOVER_FRAMES + 4) {
        for m in brain.push_frame(&tone.frame(0.0005), false, false) {
            if let CapMsg::Utterance(u) = m {
                utterance = Some(u);
            }
        }
    }
    let u = utterance.expect("the interruption never became a turn");
    // It must contain the 5.008 s he spent interrupting, not just the tail.
    assert!(
        u.duration_secs() > 5.0,
        "barge-in ate the start of the sentence: only {:.3} s survived",
        u.duration_secs()
    );
}

/// "Tap to stop" — the instant override. It must cut immediately (no 5.008 s wait) AND
/// rescue the utterance already in flight, which is the whole reason it is routed through
/// the audio thread rather than only through the playout queue.
#[test]
fn tap_to_stop_cuts_instantly_and_rescues_the_utterance_in_flight() {
    let mut brain = CaptureBrain::new();
    let mut tone = Tone::new();
    settle(&mut brain, &mut tone);

    // The CEO starts talking while Rich is speaking — tainted so far.
    for _ in 0..(SPEECH_ONSET_FRAMES + 20) {
        let msgs = brain.push_frame(&tone.frame(0.25), true, false);
        assert!(!msgs.iter().any(is_barge), "the debounce fired far too early");
    }
    assert!(brain.barge_run_frames() < BARGE_IN_DEBOUNCE_FRAMES);

    // He taps stop. One frame, no debounce.
    let msgs = brain.push_frame(&tone.frame(0.25), true, true);
    assert!(msgs.iter().any(is_barge), "tap to stop did not interrupt");

    // He finishes the sentence he was already saying; it must survive the taint rule.
    for _ in 0..(MIN_SPEECH_FRAMES + 10) {
        brain.push_frame(&tone.frame(0.25), false, false);
    }
    let mut got = None;
    for _ in 0..(SILENCE_HANGOVER_FRAMES + 4) {
        for m in brain.push_frame(&tone.frame(0.0005), false, false) {
            assert!(!is_tainted_discard(&m), "tap to stop failed to clear the taint");
            if is_utterance(&m) {
                got = Some(m);
            }
        }
    }
    assert!(got.is_some(), "the words the CEO interrupted with were thrown away");
}

/// The ordinary case: Rich is silent, the CEO says something, it becomes a turn. Nothing
/// about the echo defenses may interfere with the thing the feature is actually for.
#[test]
fn an_ordinary_utterance_while_rich_is_silent_becomes_a_turn_untouched() {
    let mut brain = CaptureBrain::new();
    let mut tone = Tone::new();
    settle(&mut brain, &mut tone);

    for _ in 0..120 {
        let msgs = brain.push_frame(&tone.frame(0.25), false, false);
        assert!(!msgs.iter().any(is_barge), "barge-in fired while Rich was silent");
    }
    let mut got = None;
    for _ in 0..(SILENCE_HANGOVER_FRAMES + 4) {
        for m in brain.push_frame(&tone.frame(0.0005), false, false) {
            if let CapMsg::Utterance(u) = m {
                got = Some(u);
            }
        }
    }
    let u = got.expect("an ordinary utterance was not delivered");
    // 120 speech frames = 1.920 s, plus pre-roll and hangover.
    assert!(u.speech_frames >= 120, "speech frames lost: {}", u.speech_frames);
    assert!((u.speech_secs() - 1.92).abs() < 0.05, "{}", u.speech_secs());
}

/// An utterance that BEGINS one frame before Rich falls silent is NOT echo — ordinary
/// conversational overlap at the end of a sentence has to keep working, or voice mode feels
/// like a walkie-talkie.
#[test]
fn speech_starting_just_before_rich_falls_silent_is_not_treated_as_echo() {
    let mut brain = CaptureBrain::new();
    let mut tone = Tone::new();
    settle(&mut brain, &mut tone);

    // Onset completes on the LAST frame where Rich is still audible.
    for _ in 0..(SPEECH_ONSET_FRAMES - 1) {
        brain.push_frame(&tone.frame(0.25), true, false);
    }
    let msgs = brain.push_frame(&tone.frame(0.25), true, false);
    let started_tainted = msgs.iter().any(|m| matches!(m, CapMsg::Started { tainted: true }));
    assert!(started_tainted, "premise: onset here IS inside Rich's playout");

    // Rich stops; the CEO keeps going and finishes.
    for _ in 0..(MIN_SPEECH_FRAMES + 30) {
        brain.push_frame(&tone.frame(0.25), false, false);
    }
    let mut tainted_discard = false;
    for _ in 0..(SILENCE_HANGOVER_FRAMES + 4) {
        for m in brain.push_frame(&tone.frame(0.0005), false, false) {
            if is_tainted_discard(&m) {
                tainted_discard = true;
            }
        }
    }
    // This is the DOCUMENTED cost of shipping without AEC, asserted so it is a known,
    // deliberate behavior rather than a surprise: speech that begins inside Rich's playout
    // and never reaches the debounce IS discarded. Real AEC removes this.
    assert!(
        tainted_discard,
        "the taint rule silently changed — the no-AEC interim is documented as discarding this"
    );
}

/// A cough while Rich is silent is not a turn, and does not leave the brain stuck.
#[test]
fn a_cough_is_not_a_turn_and_does_not_wedge_the_pipeline() {
    let mut brain = CaptureBrain::new();
    let mut tone = Tone::new();
    settle(&mut brain, &mut tone);

    for _ in 0..SPEECH_ONSET_FRAMES {
        brain.push_frame(&tone.frame(0.3), false, false);
    }
    let mut turns = 0;
    for _ in 0..(SILENCE_HANGOVER_FRAMES + 4) {
        for m in brain.push_frame(&tone.frame(0.0005), false, false) {
            if is_utterance(&m) {
                turns += 1;
            }
        }
    }
    assert_eq!(turns, 0, "a cough reached whisper");

    // …and a real sentence immediately afterwards still works.
    for _ in 0..120 {
        brain.push_frame(&tone.frame(0.25), false, false);
    }
    let mut got = false;
    for _ in 0..(SILENCE_HANGOVER_FRAMES + 4) {
        for m in brain.push_frame(&tone.frame(0.0005), false, false) {
            if is_utterance(&m) {
                got = true;
            }
        }
    }
    assert!(got, "the pipeline wedged after a cough");
}

// ---------------------------------------------------------------------------------------
// Post-open silent input — the "stream opened perfectly and delivers nothing" gap.
//
// noaudio.rs tests the detector in isolation. These drive the SAME `CaptureBrain` the audio
// callback runs, because the bug that reaches a CEO lives in the wiring: is the detector fed
// the frame the recorder actually buffers, does it respect Rich's playout, and does it stay
// out of the way of the barge-in/taint machinery next to it.
// ---------------------------------------------------------------------------------------

use richos_voice::noaudio::NO_AUDIO_FRAMES;

/// A muted device: exact digital silence, which is what macOS input volume 0 measurably
/// delivers on this machine's Elgato Wave:3 (peak 0.000002, rms below the 1e-6 print floor).
fn dead_frame() -> Vec<f32> {
    vec![0.0f32; VAD_FRAME_SAMPLES]
}

fn is_silent_msg(m: &CapMsg) -> bool {
    matches!(m, CapMsg::NoAudio { silent: true })
}
fn is_live_msg(m: &CapMsg) -> bool {
    matches!(m, CapMsg::NoAudio { silent: false })
}

/// THE FAILURE THIS EXISTS FOR: the mic is open, healthy, and delivering nothing. The CEO
/// must be told at 3.008 s — and, because a muted mic produces no utterance, nothing else in
/// the pipeline would ever have said a word about it.
#[test]
fn a_muted_microphone_on_an_open_stream_is_reported_at_3_008_seconds() {
    let mut brain = CaptureBrain::new();
    let mut tone = Tone::new();
    settle(&mut brain, &mut tone);
    assert!(!brain.no_audio(), "premise: a live quiet room is not a dead mic");

    // He hits mute. Nothing else about the session changes.
    let mut warned_at = None;
    let mut turns = 0;
    for i in 1..=(NO_AUDIO_FRAMES + 60) {
        for m in brain.push_frame(&dead_frame(), false, false) {
            if is_silent_msg(&m) && warned_at.is_none() {
                warned_at = Some(i);
            }
            if is_utterance(&m) {
                turns += 1;
            }
        }
    }
    let at = warned_at.expect("a muted microphone was never reported");
    assert_eq!(at, NO_AUDIO_FRAMES, "warned at frame {at}, not {NO_AUDIO_FRAMES}");
    assert!(
        (frames_to_secs(at) - 3.008).abs() < 1e-6,
        "the warning took {:.3} s, not 3.008 s",
        frames_to_secs(at)
    );
    assert_eq!(turns, 0, "a muted mic produced a turn");
    assert!(brain.no_audio());
}

/// INVARIANT: the CEO is not warned for being quiet. A live room during a long pause carries
/// room tone, and room tone is signal — 30 s of it, ten times longer than the window, must
/// not produce a single warning.
#[test]
fn thirty_seconds_of_a_live_room_with_nobody_talking_never_warns() {
    let mut brain = CaptureBrain::new();
    let mut tone = Tone::new();
    settle(&mut brain, &mut tone);

    // 30 s / 16.000 ms = 1875 frames of the same quiet room tone the other scenarios use.
    for i in 0..1875 {
        for m in brain.push_frame(&tone.frame(0.0005), false, false) {
            assert!(!is_silent_msg(&m), "warned on a LIVE microphone at frame {i}");
        }
    }
    assert!(!brain.no_audio());
    assert_eq!(brain.dead_run_frames(), 0);
}

/// INVARIANT: no warning while Rich is talking, even into a genuinely dead microphone. This
/// is the half-duplex taint rule's neighbor: evidence gathered during playout is worthless
/// (on speakers his own voice proves the mic "live"; on headphones it does not), and a
/// warning interrupting his sentence is the "annoying" failure the CEO ruled out.
#[test]
fn a_dead_microphone_is_not_reported_while_rich_is_speaking() {
    let mut brain = CaptureBrain::new();
    let mut tone = Tone::new();
    settle(&mut brain, &mut tone);

    // Rich talks for 60 s into a muted mic — 12x longer than a barge-in debounce.
    for i in 0..3_750 {
        for m in brain.push_frame(&dead_frame(), true, false) {
            assert!(!is_silent_msg(&m), "warned mid-sentence at frame {i}");
        }
    }
    assert!(!brain.no_audio());

    // He finishes. NOW the window runs honestly, from zero.
    let mut warned_at = None;
    for i in 1..=NO_AUDIO_FRAMES {
        for m in brain.push_frame(&dead_frame(), false, false) {
            if is_silent_msg(&m) {
                warned_at = Some(i);
            }
        }
    }
    assert_eq!(warned_at, Some(NO_AUDIO_FRAMES), "the window did not restart after playout");
}

/// INVARIANT: mute, unmute, talk — one continuous voice-mode session, no restart. The
/// warning clears on the first live frame and the CEO's next sentence still becomes a turn,
/// which is what proves the detector never touched the collector path it reads from.
#[test]
fn a_mute_unmute_cycle_clears_the_warning_and_the_next_sentence_still_becomes_a_turn() {
    let mut brain = CaptureBrain::new();
    let mut tone = Tone::new();
    settle(&mut brain, &mut tone);

    for _ in 0..(NO_AUDIO_FRAMES + 10) {
        brain.push_frame(&dead_frame(), false, false);
    }
    assert!(brain.no_audio(), "premise: muted and reported");

    // Unmute. The room comes back.
    let cleared = brain
        .push_frame(&tone.frame(0.0005), false, false)
        .iter()
        .any(is_live_msg);
    assert!(cleared, "unmuting did not clear the warning");
    assert!(!brain.no_audio());

    // …and he says something, which still endpoints into a turn.
    for _ in 0..120 {
        brain.push_frame(&tone.frame(0.25), false, false);
    }
    let mut got = None;
    for _ in 0..(SILENCE_HANGOVER_FRAMES + 4) {
        for m in brain.push_frame(&tone.frame(0.0005), false, false) {
            if let CapMsg::Utterance(u) = m {
                got = Some(u);
            }
        }
    }
    let u = got.expect("the sentence after unmuting was lost");
    assert!(u.speech_frames >= 120, "speech frames lost: {}", u.speech_frames);
    assert!(!brain.no_audio(), "the warning came back on a live mic");
}

// =========================================================================================
// THE SAME SCENARIOS, WITH A REAL ECHO CANCELLER
//
// Everything above this line is the no-AEC pipeline and must keep passing forever: it is what
// runs whenever `EchoCanceller::confident()` is false, which is every session's first few
// seconds and any session on a machine where the canceller cannot converge.
//
// Below the line is the same wiring with the canceller in place. The interesting question is
// not "does the filter cancel" — `aec.rs` measures that — it is whether the COMPOSITION still
// refuses to let Rich interrupt himself once the debounce has been shortened 12.5x.
// =========================================================================================

/// A brain wired to a canceller, plus the reference ring the "speakers" write into.
fn brain_with_aec() -> (CaptureBrain, Arc<ReferenceRing>) {
    let (aec, ring) = EchoCanceller::new();
    (CaptureBrain::with_aec(aec), ring)
}

/// Speech-shaped, non-stationary, reproducible. A pure tone is too easy for an adaptive
/// filter (one bin) and too easy for the VAD; this is broadband and has an envelope.
fn speechish(n: usize, seed: u32) -> Vec<f32> {
    let mut s = seed.wrapping_mul(2_654_435_761).wrapping_add(1);
    let mut y1 = 0.0f32;
    let mut y2 = 0.0f32;
    (0..n)
        .map(|i| {
            s ^= s << 13;
            s ^= s >> 17;
            s ^= s << 5;
            let x = (s as f32 / u32::MAX as f32) * 2.0 - 1.0;
            let t = i as f32 / SAMPLE_RATE as f32;
            let env = (0.5 + 0.5 * (2.0 * std::f32::consts::PI * 2.7 * t).sin()).powf(1.5);
            y1 = 0.92 * y1 + 0.08 * x;
            y2 = 0.55 * y2 + 0.45 * (x - y1);
            (y1 * 1.6 + y2 * 0.5) * env * 0.35
        })
        .collect()
}

/// The room: Rich's voice delayed 50.0 ms, four reflections, plus a -54 dBFS noise floor.
fn through_the_room(reference: &[f32]) -> Vec<f32> {
    let taps: [(usize, f32); 5] = [(0, 0.50), (37, -0.22), (101, 0.13), (238, -0.07), (601, 0.04)];
    let delay = 800usize; // 800 / 16000 = 50.0 ms
    let mut out = vec![0.0f32; reference.len()];
    for (offset, g) in taps {
        for i in (delay + offset)..reference.len() {
            out[i] += reference[i - delay - offset] * g;
        }
    }
    let mut s: u32 = 0xC0FF_EE01;
    for v in out.iter_mut() {
        s ^= s << 13;
        s ^= s >> 17;
        s ^= s << 5;
        *v += ((s as f32 / u32::MAX as f32) * 2.0 - 1.0) * 0.002;
    }
    out
}

/// Drive `blocks` frames of Rich talking through the speakers and back into the mic.
/// Returns (barge-ins, turns, tainted discards, frame index at which the canceller first
/// declared itself confident).
fn play_and_capture(
    brain: &mut CaptureBrain,
    ring: &ReferenceRing,
    reference: &[f32],
    mic: &[f32],
    speaking: bool,
) -> (usize, usize, usize, Option<usize>) {
    let blocks = reference.len().min(mic.len()) / AEC_BLOCK;
    let (mut barges, mut turns, mut tainted) = (0, 0, 0);
    let mut confident_at = None;
    for b in 0..blocks {
        ring.push(&reference[b * AEC_BLOCK..(b + 1) * AEC_BLOCK]);
        for m in brain.push_frame(&mic[b * AEC_BLOCK..(b + 1) * AEC_BLOCK], speaking, false) {
            if is_barge(&m) {
                barges += 1;
            }
            if is_utterance(&m) {
                turns += 1;
            }
            if is_tainted_discard(&m) {
                tainted += 1;
            }
        }
        if confident_at.is_none() && brain.aec_confident() {
            confident_at = Some(b);
        }
    }
    (barges, turns, tainted, confident_at)
}

/// **THE ECHO SCENARIO, WITH THE CANCELLER AND THE SHORT DEBOUNCE.**
///
/// This is the regression the CEO's brief warns about in as many words: *"Do not remove the
/// 5-second window until you can show it is no longer load-bearing. A regression here makes
/// Rich interrupt himself mid-sentence, which is worse than the current cost."*
///
/// Thirty seconds of Rich's own voice, through a real 50.0 ms room, into an open mic, with the
/// debounce free to drop to 0.400 s the moment the canceller earns it. Zero interruptions and
/// zero turns, or this whole change is a net loss.
#[test]
fn thirty_seconds_of_richs_own_voice_still_produces_nothing_with_the_canceller_and_the_short_debounce() {
    let (mut brain, ring) = brain_with_aec();
    let n = SAMPLE_RATE as usize * 30;
    let reference = speechish(n, 11);
    let mic = through_the_room(&reference);

    let (barges, turns, _tainted, confident_at) =
        play_and_capture(&mut brain, &ring, &reference, &mic, true);

    let at = confident_at.expect("the canceller should reach confidence within 30 s of speech");
    assert!(
        frames_to_secs(at as u32) < 8.0,
        "took {:.2} s to earn the short debounce",
        frames_to_secs(at as u32)
    );
    // And it really did shorten: this is not passing because nothing changed.
    assert_eq!(brain.barge_in_mode(), BargeInMode::Windowed);

    assert_eq!(barges, 0, "Rich interrupted HIMSELF {barges} times — the exact regression the brief forbids");
    assert_eq!(turns, 0, "Rich transcribed himself into {turns} turn(s)");
}

/// INVARIANT: the debounce is not shortened until it is earned, and it is earned only by
/// measurement. A brain that has heard nothing is in `Consecutive` mode, full stop.
#[test]
fn the_debounce_starts_long_and_is_only_shortened_by_measurement() {
    let (brain, _ring) = brain_with_aec();
    assert_eq!(brain.barge_in_mode(), BargeInMode::Consecutive);
    assert!(!brain.aec_confident());

    // And a brain with NO canceller can never leave that mode, however long it runs.
    let mut plain = CaptureBrain::new();
    let mut tone = Tone::new();
    settle(&mut plain, &mut tone);
    for _ in 0..2000 {
        plain.push_frame(&tone.frame(0.25), true, false);
    }
    assert_eq!(plain.barge_in_mode(), BargeInMode::Consecutive);
    assert!(!plain.aec_confident());
    assert!(plain.aec_metrics().is_none());
}

/// **THE PAYOFF, END TO END.** Rich is talking; the CEO says something short over the top of
/// him. Once the canceller is confident, a 0.400 s interruption must actually cut Rich off —
/// and the words the CEO was saying must survive as a turn rather than being discarded as echo.
///
/// Under the old rule this same input produced nothing at all: 0.400 s cannot complete a
/// 5.008 s debounce, and the utterance began during playout so the taint rule threw it away.
#[test]
fn a_four_hundred_millisecond_interruption_cuts_rich_off_and_becomes_a_turn() {
    let (mut brain, ring) = brain_with_aec();
    let n = SAMPLE_RATE as usize * 24;
    let reference = speechish(n, 11);
    let mut mic = through_the_room(&reference);

    // Let it converge on echo alone first.
    let converge = SAMPLE_RATE as usize * 14;
    play_and_capture(&mut brain, &ring, &reference[..converge], &mic[..converge], true);
    assert!(brain.aec_confident(), "premise: the canceller must have earned the short window");

    // The CEO speaks over him for 0.400 s, then Rich keeps going and the CEO stops.
    let start = converge;
    let dur = (SAMPLE_RATE as f32 * 0.400) as usize;
    assert_eq!(dur, 6400, "0.400 s at 16 kHz");
    let ceo = speechish(dur, 42);
    for i in 0..dur {
        mic[start + i] += ceo[i] * 1.4;
    }

    let (barges, turns, tainted, _) = play_and_capture(
        &mut brain,
        &ring,
        &reference[start..],
        &mic[start..],
        true,
    );

    assert!(barges >= 1, "0.400 s of the CEO talking over Rich did not interrupt him");
    assert_eq!(tainted, 0, "the CEO's words were thrown away as echo — the taint rule did not relax");
    assert!(turns >= 1, "the interruption cut Rich off but never became a turn");
}

/// **THE DICTATION-SAFETY GUARANTEE, at the level of the composition rather than the filter.**
///
/// The frames the recorder buffers are the exact samples that become the WAV whisper reads.
/// While Rich is silent they must be bit-identical to what the microphone delivered — not
/// "close", not "within 1e-6". `aec.rs` proves the filter itself is transparent; this proves
/// nothing downstream of it re-introduces a difference.
///
/// **How long after Rich stops, exactly.** The residual is only bit-identical once every
/// reference partition is zero, which takes the bulk delay plus the filter tail — and the
/// endpointer hands whisper `PRE_ROLL_FRAMES` of audio from BEFORE speech onset, so the
/// pre-roll must also lie in the transparent region:
///
/// ```text
///   MAX_DELAY_BLOCKS   32  (the widest delay the estimator will search: 0.512 s)
///   AEC_PARTITIONS      8  (the 128.000 ms filter tail)
///   PRE_ROLL_FRAMES    19  (endpoint.rs: audio handed over from before onset)
///   + 1                 1  (the overlap-save lookback block)
///   = 60 frames x 256 / 16000 = 0.960 s, worst case
/// ```
///
/// Measured in THIS configuration (bulk delay 2 blocks, not the 32-block worst case) the
/// boundary is 23 frames = 0.368 s: at 20 frames 768 samples still differ, at 23 none do, and
/// the count falls by exactly 256 — one frame — per extra frame of silence, which is the
/// signature of the pre-roll walking out of the tail.
///
/// **None of this touches dictation or call transcription.** In those flows Rich never speaks,
/// so the reference is zero for the whole session and the residual is the microphone signal
/// from the first sample. The 0.368 s only describes the moment just after Rich finishes a
/// sentence — and in that window the "alteration" is the correct removal of the echo of his
/// voice, which is still arriving.
#[test]
fn with_rich_silent_the_frames_that_reach_whisper_are_bit_identical_to_the_microphone() {
    let (mut brain, ring) = brain_with_aec();

    // Converge on a real echo path first, so the filter is emphatically non-trivial.
    let conv = speechish(SAMPLE_RATE as usize * 14, 11);
    let conv_mic = through_the_room(&conv);
    play_and_capture(&mut brain, &ring, &conv, &conv_mic, true);
    assert!(brain.aec_confident(), "premise: a converged, non-zero filter");

    // Rich stops. Flush a full filter tail of silent reference.
    // Derived, not chosen — see the doc comment above.
    let flush = richos_voice::aec::MAX_DELAY_BLOCKS
        + richos_voice::aec::AEC_PARTITIONS
        + richos_voice::endpoint::PRE_ROLL_FRAMES
        + 1;
    assert_eq!(flush, 60, "the transparency bound moved: recheck the derivation");
    assert!(
        (frames_to_secs(flush as u32) - 0.960).abs() < 1e-6,
        "{} s",
        frames_to_secs(flush as u32)
    );
    for _ in 0..flush {
        ring.push(&[0.0f32; AEC_BLOCK]);
        brain.push_frame(&[0.0f32; AEC_BLOCK], false, false);
    }

    // Now the CEO dictates. Every recorded sample must survive untouched.
    // Trailing silence so the endpointer's hangover fires and the utterance actually closes —
    // without it the recorder is still mid-sentence when the loop ends and there is nothing
    // to inspect.
    let mut voice = speechish(SAMPLE_RATE as usize * 6, 91);
    voice.extend(std::iter::repeat(0.0).take(SAMPLE_RATE as usize * 2));
    let blocks = voice.len() / AEC_BLOCK;
    let mut captured: Vec<f32> = Vec::new();
    for b in 0..blocks {
        let src = &voice[b * AEC_BLOCK..(b + 1) * AEC_BLOCK];
        ring.push(&[0.0f32; AEC_BLOCK]);
        for m in brain.push_frame(src, false, false) {
            if let CapMsg::Utterance(u) = m {
                captured.extend_from_slice(&u.samples);
            }
        }
    }
    assert!(!captured.is_empty(), "premise: dictation produced an utterance to check");

    // Every captured sample must appear, bit-exact, in the source.
    let src_bits: std::collections::HashSet<u32> = voice.iter().map(|s| s.to_bits()).collect();
    let foreign = captured.iter().filter(|s| !src_bits.contains(&s.to_bits())).count();
    assert_eq!(
        foreign, 0,
        "{foreign} sample(s) reaching whisper were altered by the canceller while Rich was silent"
    );
}

/// INVARIANT: "tap to stop" remains instant and remains authoritative under the short rule
/// too. It is the CEO's override and it must never depend on the canceller's opinion.
#[test]
fn tap_to_stop_is_still_instant_once_the_canceller_is_confident() {
    let (mut brain, ring) = brain_with_aec();
    let reference = speechish(SAMPLE_RATE as usize * 14, 11);
    let mic = through_the_room(&reference);
    play_and_capture(&mut brain, &ring, &reference, &mic, true);
    assert!(brain.aec_confident());

    ring.push(&[0.0f32; AEC_BLOCK]);
    let msgs = brain.push_frame(&[0.0f32; AEC_BLOCK], true, true);
    assert!(msgs.iter().any(is_barge), "tap to stop did not fire");
}
