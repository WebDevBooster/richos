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

use richos_voice::controller::{CapMsg, CaptureBrain};
use richos_voice::bargein::BARGE_IN_DEBOUNCE_FRAMES;
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
/// about the echo defences may interfere with the thing the feature is actually for.
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
    // deliberate behaviour rather than a surprise: speech that begins inside Rich's playout
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
/// is the half-duplex taint rule's neighbour: evidence gathered during playout is worthless
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
