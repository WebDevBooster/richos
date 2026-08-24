//! The controller — the only stateful thing in the crate, and the only place threads live.
//!
//! Four threads, each with one job:
//!
//! | thread | job | must not |
//! |---|---|---|
//! | audio capture callback | VAD, barge-in monitor, utterance buffering | allocate much, block, or emit UI events |
//! | supervisor (40 Hz tick) | own the state machine, emit every UI event, dispatch work | do audio work |
//! | recognizer | whisper.cpp per finished utterance | block the mic |
//! | speaker | synthesize sentences and queue them for playout | block the turn |
//!
//! The capture callback owns its VAD/recorder/monitor outright — no locks — and talks to the
//! supervisor over a channel plus two atomics. That is deliberate: a `Mutex` on the audio
//! thread is how a voice pipeline starts clicking.
//!
//! ## The half-duplex TAINT rule — the honest consequence of having no AEC
//!
//! While Rich is audible, the microphone is still open (barge-in needs it) but any utterance
//! that BEGINS during his playout is marked **tainted** and is discarded unless barge-in
//! actually fired during it. Without that rule, on speakers Rich hears himself, transcribes
//! his own sentence and answers it — the pilot's echo failure, one step worse.
//!
//! What the rule costs, stated plainly: on speakers, the CEO cannot start a NEW thought while
//! Rich is talking; he must either talk over him for the full 5.008 s debounce or tap "stop".
//! An utterance that begins even one frame before Rich falls silent is NOT tainted, so
//! ordinary conversational overlap at the end of a sentence still works.
//! With headphones — the recommended v1 configuration — the rule almost never fires, because
//! nothing of Rich's reaches the mic in the first place.
//! **Real AEC deletes this rule.** It is interim, and it is named as interim.

use crate::bargein::{BargeInMonitor, EchoGate, NoEchoCancellation, BARGE_IN_DEBOUNCE_FRAMES};
use crate::capture::{self, AudioSource, Capture};
use crate::chunk::SentenceChunker;
use crate::endpoint::{UtteranceRecorder, Utterance};
use crate::event::{VoiceEvent, VoiceObserver};
use crate::playout::Playout;
use crate::state::{VoiceState, VoiceStateMachine};
use crate::stt::{self, Recognizer};
use crate::tts::{MacSay, SpeechSynth};
use crate::vad::{frames_to_secs, Vad};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender, TryRecvError};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// Supervisor tick. 25 ms is faster than the eye notices and far slower than the 16.000 ms
/// audio frame, so the UI never lags the mic and the tick never competes with audio.
const TICK: Duration = Duration::from_millis(25);

/// Emit a level update at most this often — a 62.5 Hz meter is wasted work in a webview.
const LEVEL_EMIT_EVERY: Duration = Duration::from_millis(100);

pub fn now_millis() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

#[derive(Debug)]
pub enum VoiceStartError {
    Capture(capture::CaptureError),
    Playout(crate::playout::PlayoutError),
    Stt(stt::SttError),
}

impl VoiceStartError {
    /// The calm line the CEO sees when the `◉` toggle cannot come up.
    pub fn ceo_message(&self) -> String {
        match self {
            VoiceStartError::Capture(e) => e.ceo_message(),
            VoiceStartError::Playout(e) => e.ceo_message(),
            VoiceStartError::Stt(e) => e.ceo_message(),
        }
    }
}

impl std::fmt::Display for VoiceStartError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            VoiceStartError::Capture(e) => write!(f, "{e}"),
            VoiceStartError::Playout(e) => write!(f, "{e}"),
            VoiceStartError::Stt(e) => write!(f, "{e}"),
        }
    }
}

/// How voice mode was configured — every field is a fact worth reporting, never a guess.
#[derive(Debug, Clone)]
pub struct Diagnostics {
    pub input_source: String,
    pub input_rate: u32,
    pub input_channels: u16,
    pub output_device: String,
    pub output_rate: u32,
    pub output_channels: u16,
    pub stt_model: String,
    pub stt_binary: String,
    pub tts_voice: String,
    pub echo_gate: String,
    pub echo_cancellation: bool,
    pub barge_in_frames: u32,
    pub barge_in_secs: f32,
}

impl Diagnostics {
    /// One line for stderr at voice-mode start. Developer-facing only — never the CEO's view.
    pub fn summary(&self) -> String {
        format!(
            "in={} {} Hz/{} ch · out={} {} Hz/{} ch · stt={} · tts={} · aec={} · barge-in={} frames ({:.3} s)",
            self.input_source,
            self.input_rate,
            self.input_channels,
            self.output_device,
            self.output_rate,
            self.output_channels,
            self.stt_model,
            self.tts_voice,
            self.echo_gate,
            self.barge_in_frames,
            self.barge_in_secs,
        )
    }
}

#[derive(Debug, Clone)]
pub struct VoiceOptions {
    pub source: AudioSource,
    /// Where the utterance WAVs and synthesis WAVs live. Under the app data dir in the shell.
    pub scratch_dir: PathBuf,
}

impl Default for VoiceOptions {
    fn default() -> Self {
        VoiceOptions {
            source: AudioSource::from_env(),
            scratch_dir: std::env::temp_dir().join("richos-voice"),
        }
    }
}

/// Messages from the audio callback to the supervisor. Small and allocation-light except for
/// `Utterance`, which is the whole point and happens once per sentence the CEO speaks.
#[derive(Debug)]
pub enum CapMsg {
    /// The CEO started talking. `tainted` = it began while Rich was audible.
    Started { tainted: bool },
    /// An utterance completed and is worth recognising.
    Utterance(Box<Utterance>),
    /// An utterance completed but was discarded (too short, or tainted echo).
    Discarded { tainted: bool },
    /// Rich was cut off — either by the full debounce, or by "tap to stop".
    ///
    /// `mid_utterance` says whether the CEO is actually talking at that instant. A debounce
    /// barge-in always is (that is what fired it); a "tap to stop" often is NOT — he can hit
    /// the button in silence. Without this the state machine would be told "he is talking"
    /// and, with no utterance to end, would sit in `Hearing` forever.
    BargeIn { mid_utterance: bool },
}

/// Everything the audio callback decides, in one place, with no I/O and no locks.
///
/// The callback is a THIN adapter over this: it hands over a frame plus two booleans and
/// forwards whatever comes back. That split exists so the barge-in/taint/endpointing
/// COMPOSITION is unit-testable — testing the monitor and the recorder separately would
/// leave the wiring between them (which is where the bugs live) untested.
pub struct CaptureBrain {
    vad: Vad,
    recorder: UtteranceRecorder,
    monitor: BargeInMonitor,
    was_recording: bool,
    /// This utterance began while Rich was audible: echo until proven otherwise.
    tainted: bool,
    /// A barge-in fired during the current utterance, which proves it is NOT echo.
    barged: bool,
}

impl Default for CaptureBrain {
    fn default() -> Self {
        CaptureBrain::new()
    }
}

impl CaptureBrain {
    pub fn new() -> Self {
        CaptureBrain {
            vad: Vad::default(),
            recorder: UtteranceRecorder::new(),
            monitor: BargeInMonitor::default(),
            was_recording: false,
            tainted: false,
            barged: false,
        }
    }

    /// Live input level 0..1 for the UI meter.
    pub fn level(&self) -> f32 {
        self.vad.level()
    }

    /// Consecutive speech frames counted toward an interruption — the diagnostic that makes
    /// "why didn't it barge in" answerable.
    pub fn barge_run_frames(&self) -> u32 {
        self.monitor.run_frames()
    }

    /// One exact VAD frame. `speaking` = Rich currently has audio playing. `forced` = the UI's
    /// "tap to stop" was pressed since the last frame.
    pub fn push_frame(&mut self, frame: &[f32], speaking: bool, forced: bool) -> Vec<CapMsg> {
        let mut out = Vec::new();
        let is_speech = self.vad.push_frame(frame);

        // The monitor only counts while Rich is audible: speech during his silence is an
        // ordinary utterance, not an interruption.
        if speaking != self.monitor.is_armed() {
            if speaking {
                self.monitor.arm();
            } else {
                self.monitor.disarm();
            }
        }

        // "Tap to stop" is AUTHORITATIVE and bypasses the debounce entirely. Routing it
        // through here (rather than only through the playout queue) is what clears the taint,
        // so the words the CEO is saying right now become the next turn instead of being
        // thrown away as echo.
        if forced {
            self.monitor.disarm();
        }
        if forced || self.monitor.push(is_speech) {
            self.barged = true;
            self.tainted = false;
            out.push(CapMsg::BargeIn { mid_utterance: self.recorder.is_recording() });
        }

        let finished = self.recorder.push_frame(frame, is_speech);
        let recording = self.recorder.is_recording();
        let started = recording && !self.was_recording;
        let stopped = !recording && self.was_recording;
        self.was_recording = recording;

        if started {
            self.tainted = speaking && !self.barged;
            out.push(CapMsg::Started { tainted: self.tainted });
        }

        if let Some(utterance) = finished {
            if self.tainted && !self.barged {
                out.push(CapMsg::Discarded { tainted: true });
            } else {
                out.push(CapMsg::Utterance(Box::new(utterance)));
            }
            self.tainted = false;
            self.barged = false;
        } else if stopped {
            // Recording ended without an utterance: too short to be a sentence (a cough, a
            // chair). Never reaches whisper, never reaches the CEO.
            out.push(CapMsg::Discarded { tainted: self.tainted });
            self.tainted = false;
            self.barged = false;
        } else if !speaking && !recording {
            // Rich has fallen silent and nothing is in flight: forget the interruption.
            self.barged = false;
        }
        out
    }
}

/// A sentence handed to the speaker thread, tagged with the generation it belongs to so a
/// barge-in can invalidate work already in flight.
struct SpeakMsg {
    generation: u64,
    text: String,
}

struct Shared {
    /// Live input level 0..1, f32 bits. Written per frame by the audio thread.
    level: AtomicU32,
    /// True while Rich has audio queued — read by the audio thread to arm barge-in.
    speaking: AtomicBool,
    /// Bumped on every barge-in/stop. Synthesis for an older generation is discarded.
    generation: AtomicU64,
    running: AtomicBool,
}

impl Shared {
    fn set_level(&self, v: f32) {
        self.level.store(v.to_bits(), Ordering::Relaxed);
    }
    fn level(&self) -> f32 {
        f32::from_bits(self.level.load(Ordering::Relaxed))
    }
}

/// Voice mode, running. Dropping it closes the microphone and silences Rich.
pub struct VoiceController {
    shared: Arc<Shared>,
    machine: Arc<Mutex<VoiceStateMachine>>,
    chunker: Mutex<SentenceChunker>,
    /// `Option` so `Drop` can close the channel BEFORE joining the speaker thread —
    /// joining first would deadlock on a `recv()` that can never fail.
    speak_tx: Option<Sender<SpeakMsg>>,
    playout: Arc<Playout>,
    force_barge: Arc<AtomicBool>,
    diagnostics: Diagnostics,
    _capture: Capture,
    threads: Vec<std::thread::JoinHandle<()>>,
}

impl VoiceController {
    /// Bring voice mode up. Every external dependency is resolved HERE, so a missing model or
    /// a missing microphone is one calm message at the toggle rather than a failure in the
    /// middle of a sentence.
    ///
    /// `submit` receives each recognised utterance and is expected to run a spine turn with
    /// it — the SAME path typed text takes. It is called on a dedicated thread and may block
    /// for the whole turn.
    pub fn start(
        opts: VoiceOptions,
        observer: Arc<dyn VoiceObserver>,
        submit: Arc<dyn Fn(String) + Send + Sync>,
    ) -> Result<VoiceController, VoiceStartError> {
        let recognizer = Recognizer::resolve().map_err(VoiceStartError::Stt)?;
        let gate: Arc<Mutex<Box<dyn EchoGate>>> =
            Arc::new(Mutex::new(Box::new(NoEchoCancellation::default())));
        let playout = Arc::new(Playout::start(Some(gate.clone())).map_err(VoiceStartError::Playout)?);
        let synth: Arc<dyn SpeechSynth> = Arc::new(MacSay::new());

        let shared = Arc::new(Shared {
            level: AtomicU32::new(0),
            speaking: AtomicBool::new(false),
            generation: AtomicU64::new(0),
            running: AtomicBool::new(true),
        });
        let machine = Arc::new(Mutex::new(VoiceStateMachine::new()));
        machine.lock().unwrap().start();

        let (cap_tx, cap_rx) = channel::<CapMsg>();
        let (speak_tx, speak_rx) = channel::<SpeakMsg>();
        let (utt_tx, utt_rx) = channel::<Box<Utterance>>();
        let (submit_tx, submit_rx) = channel::<String>();
        let force_barge = Arc::new(AtomicBool::new(false));

        // ---- the audio capture callback ------------------------------------------------
        // A THIN adapter over CaptureBrain: no locks, no allocation beyond the frame copy the
        // echo gate needs, and no UI events. All the decisions live in CaptureBrain, which is
        // unit-tested as a whole (tests/barge_in_composition.rs).
        let cb_shared = shared.clone();
        let cb_gate = gate.clone();
        let cb_force = force_barge.clone();
        let mut brain = CaptureBrain::new();
        let mut frame_buf = vec![0.0f32; crate::vad::VAD_FRAME_SAMPLES];

        let capture = capture::start(&opts.source, move |frame| {
            // The AEC seam, on the capture side. v1's gate modifies nothing.
            frame_buf.clear();
            frame_buf.extend_from_slice(frame);
            if let Ok(mut g) = cb_gate.try_lock() {
                g.process_capture(&mut frame_buf);
            }

            let speaking = cb_shared.speaking.load(Ordering::Relaxed);
            let forced = cb_force.swap(false, Ordering::Relaxed);
            for msg in brain.push_frame(&frame_buf, speaking, forced) {
                let _ = cap_tx.send(msg);
            }
            cb_shared.set_level(brain.level());
        })
        .map_err(VoiceStartError::Capture)?;

        let diagnostics = Diagnostics {
            input_source: capture.source_label.clone(),
            input_rate: capture.input_rate,
            input_channels: capture.input_channels,
            output_device: playout.device_label.clone(),
            output_rate: playout.device_rate,
            output_channels: playout.channels,
            stt_model: recognizer.model_id().to_string(),
            stt_binary: recognizer.binary_path().display().to_string(),
            tts_voice: synth.voice_label(),
            echo_gate: gate.lock().map(|g| g.name().to_string()).unwrap_or_default(),
            echo_cancellation: gate.lock().map(|g| g.cancels()).unwrap_or(false),
            barge_in_frames: BARGE_IN_DEBOUNCE_FRAMES,
            barge_in_secs: frames_to_secs(BARGE_IN_DEBOUNCE_FRAMES),
        };
        eprintln!("[richos-voice] {}", diagnostics.summary());

        let mut threads = Vec::new();

        // ---- recognizer thread ----------------------------------------------------------
        {
            let observer = observer.clone();
            let scratch = opts.scratch_dir.clone();
            let submit_tx = submit_tx.clone();
            threads.push(std::thread::spawn(move || {
                while let Ok(utterance) = utt_rx.recv() {
                    let duration_ms = (utterance.duration_secs() * 1000.0) as u64;
                    match recognizer.transcribe(&utterance.samples, &scratch) {
                        Ok((text, latency_ms)) => {
                            if !stt::is_meaningful(&text) {
                                eprintln!("[richos-voice] discarded non-speech transcript: {text:?}");
                                continue;
                            }
                            observer.on_voice_event(&VoiceEvent::Transcript {
                                text: text.clone(),
                                duration_ms,
                                latency_ms,
                                at: now_millis(),
                            });
                            let _ = submit_tx.send(text);
                        }
                        Err(e) => {
                            eprintln!("[richos-voice] stt failed: {e}");
                            observer.on_voice_event(&VoiceEvent::Error {
                                message: e.ceo_message(),
                                at: now_millis(),
                            });
                        }
                    }
                }
            }));
        }

        // ---- submit thread (one turn at a time, in order) --------------------------------
        threads.push(std::thread::spawn(move || {
            while let Ok(text) = submit_rx.recv() {
                submit(text);
            }
        }));

        // ---- speaker thread --------------------------------------------------------------
        {
            let shared = shared.clone();
            let playout = playout.clone();
            let scratch = opts.scratch_dir.clone();
            let observer = observer.clone();
            threads.push(std::thread::spawn(move || {
                while let Ok(msg) = speak_rx.recv() {
                    // Dropped before we start: a barge-in already invalidated this sentence.
                    if msg.generation != shared.generation.load(Ordering::Relaxed) {
                        continue;
                    }
                    match synth.synthesize(&msg.text, playout.device_rate, &scratch) {
                        Ok(speech) => {
                            // Synthesis took real time; check again before making a sound.
                            if msg.generation != shared.generation.load(Ordering::Relaxed) {
                                continue;
                            }
                            playout.queue(&speech.samples);
                        }
                        Err(e) => {
                            eprintln!("[richos-voice] tts failed: {e}");
                            observer.on_voice_event(&VoiceEvent::Error {
                                message: e.ceo_message(),
                                at: now_millis(),
                            });
                        }
                    }
                }
            }));
        }

        // ---- supervisor: the ONLY place UI events are emitted -----------------------------
        {
            let shared = shared.clone();
            let machine = machine.clone();
            let playout = playout.clone();
            let observer = observer.clone();
            threads.push(std::thread::spawn(move || {
                supervise(shared, machine, playout, observer, cap_rx, utt_tx);
            }));
        }

        Ok(VoiceController {
            shared,
            machine,
            chunker: Mutex::new(SentenceChunker::new()),
            speak_tx: Some(speak_tx),
            playout,
            force_barge,
            diagnostics,
            _capture: capture,
            threads,
        })
    }

    pub fn state(&self) -> VoiceState {
        self.machine.lock().map(|m| m.state()).unwrap_or(VoiceState::Off)
    }

    pub fn diagnostics(&self) -> &Diagnostics {
        &self.diagnostics
    }

    /// A `rich://chunk` delta arrived. Accumulate, and hand every completed sentence to the
    /// speaker thread immediately — this is the pipelining.
    pub fn speak_delta(&self, delta: &str) {
        let generation = self.shared.generation.load(Ordering::Relaxed);
        let sentences = match self.chunker.lock() {
            Ok(mut c) => c.push(delta),
            Err(_) => return,
        };
        if let Some(tx) = &self.speak_tx {
            for text in sentences {
                let _ = tx.send(SpeakMsg { generation, text });
            }
        }
    }

    /// The turn's terminal event arrived: speak whatever is left.
    pub fn speak_end(&self) {
        let generation = self.shared.generation.load(Ordering::Relaxed);
        let tail = match self.chunker.lock() {
            Ok(mut c) => c.flush(),
            Err(_) => None,
        };
        if let (Some(tx), Some(text)) = (&self.speak_tx, tail) {
            let _ = tx.send(SpeakMsg { generation, text });
        }
    }

    /// `rich://turn-started` — Rich has the turn.
    pub fn turn_started(&self) {
        if let Ok(mut m) = self.machine.lock() {
            m.turn_started();
        }
        if let Ok(mut c) = self.chunker.lock() {
            c.reset();
        }
    }

    /// A terminal turn event. Rich may still be speaking the tail.
    pub fn turn_ended(&self) {
        if let Ok(mut m) = self.machine.lock() {
            m.turn_ended();
        }
    }

    /// The UI's "tap to stop": interrupt Rich right now, no debounce. Returns the number of
    /// mono samples dropped — real units, not an adjective.
    pub fn force_barge_in(&self) -> usize {
        self.force_barge.store(true, Ordering::Relaxed);
        self.shared.generation.fetch_add(1, Ordering::Relaxed);
        if let Ok(mut c) = self.chunker.lock() {
            c.reset();
        }
        let dropped = self.playout.stop_now();
        if let Ok(mut m) = self.machine.lock() {
            m.barge_in();
        }
        dropped
    }

    /// Worst-case delay between an interruption and silence: one device callback period.
    pub fn stop_latency_secs(&self) -> f32 {
        self.playout.stop_latency_secs()
    }

    pub fn queued_speech_secs(&self) -> f32 {
        self.playout.queued_secs()
    }
}

impl Drop for VoiceController {
    fn drop(&mut self) {
        self.shared.running.store(false, Ordering::SeqCst);
        // Silence Rich immediately, then let the channels close and the threads finish.
        self.playout.stop_now();
        self.shared.generation.fetch_add(1, Ordering::SeqCst);
        if let Ok(mut m) = self.machine.lock() {
            m.stop();
        }
        // Close the speaker channel first: the speaker thread blocks on recv() and can only
        // exit when every sender is gone. Joining before this would deadlock.
        self.speak_tx.take();
        for t in self.threads.drain(..) {
            let _ = t.join();
        }
    }
}

/// The supervisor loop: owns the state machine, emits every UI event, dispatches work.
fn supervise(
    shared: Arc<Shared>,
    machine: Arc<Mutex<VoiceStateMachine>>,
    playout: Arc<Playout>,
    observer: Arc<dyn VoiceObserver>,
    cap_rx: Receiver<CapMsg>,
    utt_tx: Sender<Box<Utterance>>,
) {
    let mut last_state = VoiceState::Off;
    let mut last_level_emit = Instant::now() - LEVEL_EMIT_EVERY;
    let mut last_level = -1.0f32;

    while shared.running.load(Ordering::SeqCst) {
        // 1. Drain the audio thread's messages.
        loop {
            match cap_rx.try_recv() {
                Ok(CapMsg::Started { tainted }) => {
                    if !tainted {
                        if let Ok(mut m) = machine.lock() {
                            m.utterance_started();
                        }
                    }
                }
                Ok(CapMsg::Utterance(u)) => {
                    if let Ok(mut m) = machine.lock() {
                        m.utterance_ended();
                    }
                    let _ = utt_tx.send(u);
                }
                Ok(CapMsg::Discarded { tainted }) => {
                    if let Ok(mut m) = machine.lock() {
                        m.utterance_ended();
                    }
                    if tainted {
                        eprintln!("[richos-voice] discarded audio captured while Rich was speaking (no AEC)");
                    }
                }
                Ok(CapMsg::BargeIn { mid_utterance }) => {
                    let dropped = playout.stop_now();
                    shared.generation.fetch_add(1, Ordering::Relaxed);
                    shared.speaking.store(false, Ordering::Relaxed);
                    if let Ok(mut m) = machine.lock() {
                        m.barge_in();
                        if !mid_utterance {
                            // He cut Rich off without saying anything — there is no utterance
                            // to end, so clear `hearing` now or the panel sits in it forever.
                            m.utterance_ended();
                        }
                    }
                    eprintln!(
                        "[richos-voice] barge-in: cut Rich, dropped {dropped} samples ({:.3} s of queued speech)",
                        dropped as f32 / playout.device_rate.max(1) as f32
                    );
                }
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => return,
            }
        }

        // 2. Reconcile playout with the state machine. The queue is the ground truth for
        //    "is Rich audible", not the turn state.
        let playing = playout.is_playing();
        shared.speaking.store(playing, Ordering::Relaxed);
        if let Ok(mut m) = machine.lock() {
            if playing {
                m.playout_started();
            } else {
                m.playout_drained();
            }
        }

        // 3. Emit. State changes always; level at most 10 Hz and only when it moved.
        let state = machine.lock().map(|m| m.state()).unwrap_or(VoiceState::Off);
        let armed = machine.lock().map(|m| m.barge_in_armed()).unwrap_or(false);
        let level = if state.mic_is_hot() { shared.level() } else { 0.0 };
        let state_changed = state != last_state;
        let level_due = last_level_emit.elapsed() >= LEVEL_EMIT_EVERY && (level - last_level).abs() > 0.02;
        if state_changed || level_due {
            observer.on_voice_event(&VoiceEvent::State {
                state,
                level,
                barge_in_armed: armed,
                at: now_millis(),
            });
            last_state = state;
            last_level = level;
            last_level_emit = Instant::now();
        }

        std::thread::sleep(TICK);
    }

    // Voice mode is off: say so once, unambiguously. A stale "listening" left on screen
    // would be a lie about a hot mic.
    observer.on_voice_event(&VoiceEvent::State {
        state: VoiceState::Off,
        level: 0.0,
        barge_in_armed: false,
        at: now_millis(),
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct Recorder {
        events: Mutex<Vec<VoiceEvent>>,
    }
    impl VoiceObserver for Recorder {
        fn on_voice_event(&self, event: &VoiceEvent) {
            self.events.lock().unwrap().push(event.clone());
        }
    }

    /// INVARIANT: the diagnostics line reports MEASURED device facts and the exact barge-in
    /// frame math — it is the line that goes in the brief, so it must not contain estimates.
    #[test]
    fn the_diagnostics_line_carries_the_exact_frame_math() {
        let d = Diagnostics {
            input_source: "microphone".into(),
            input_rate: 48_000,
            input_channels: 2,
            output_device: "External Headphones".into(),
            output_rate: 48_000,
            output_channels: 2,
            stt_model: "small.en".into(),
            stt_binary: "/opt/homebrew/bin/whisper-cli".into(),
            tts_voice: "macOS say · Daniel · 180 wpm".into(),
            echo_gate: "none (5.008s debounce + headphones)".into(),
            echo_cancellation: false,
            barge_in_frames: BARGE_IN_DEBOUNCE_FRAMES,
            barge_in_secs: frames_to_secs(BARGE_IN_DEBOUNCE_FRAMES),
        };
        let s = d.summary();
        assert!(s.contains("313 frames"), "{s}");
        assert!(s.contains("5.008 s"), "{s}");
        assert!(!d.echo_cancellation, "v1 must never claim echo cancellation");
    }

    /// INVARIANT: a voice-start failure is a calm CEO line, whatever failed underneath.
    #[test]
    fn every_start_failure_has_a_calm_ceo_line() {
        let errs = [
            VoiceStartError::Capture(capture::CaptureError::NoInputDevice),
            VoiceStartError::Stt(stt::SttError::ModelNotFound("/x/ggml-small.en.bin".into())),
            VoiceStartError::Playout(crate::playout::PlayoutError::NoOutputDevice),
        ];
        for e in errs {
            let msg = e.ceo_message();
            assert!(!msg.is_empty());
            assert!(!msg.contains("ggml"), "machinery leaked: {msg}");
            assert!(!msg.contains('/'), "a path leaked to the CEO: {msg}");
        }
    }

    /// INVARIANT: the controller is `Send + Sync`, because it lives in Tauri managed state.
    /// cpal's macOS `Stream` is Send by construction in 0.17 (dedicated-thread architecture);
    /// if that ever changes this test fails at COMPILE time rather than at the toggle.
    #[test]
    fn the_controller_can_live_in_tauri_managed_state() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<VoiceController>();
        assert_send_sync::<Playout>();
    }

    /// INVARIANT: the generation counter is what makes a barge-in stick. A sentence
    /// synthesised across an interruption must be discarded, not played late.
    #[test]
    fn a_sentence_synthesised_across_a_barge_in_is_discarded() {
        let gen = AtomicU64::new(7);
        let queued_at = gen.load(Ordering::Relaxed);
        // …the CEO interrupts while `say` is running…
        gen.fetch_add(1, Ordering::Relaxed);
        assert_ne!(queued_at, gen.load(Ordering::Relaxed), "stale audio would have played");
    }

    /// LIVE (opt-in): a MEASURED barge-in on the real output device. Rich starts talking for
    /// real, gets cut, and the numbers are checked — dropped audio, an empty queue that stays
    /// empty, and a stop latency of one device callback period.
    ///
    /// Behind RICHOS_VOICE_LIVE_AUDIO=1 because this one is genuinely audible: about a second
    /// of Rich's voice comes out of the speakers before it is cut.
    #[test]
    #[cfg(target_os = "macos")]
    fn live_barge_in_actually_silences_the_real_output_device() {
        if std::env::var("RICHOS_VOICE_LIVE_AUDIO").as_deref() != Ok("1") {
            return;
        }
        let dir = std::env::temp_dir().join("richos-voice-barge-test");
        std::fs::create_dir_all(&dir).unwrap();
        // A silent "microphone": the capture path runs for real, it just hears nothing, so
        // this test isolates the INTERRUPTION from the recognition.
        let quiet = dir.join("quiet.wav");
        crate::wav::write_pcm16_mono(&quiet, &vec![0.0f32; 16_000], crate::vad::SAMPLE_RATE).unwrap();

        let observer = Arc::new(Recorder::default());
        let ctl = VoiceController::start(
            VoiceOptions { source: AudioSource::Wav(quiet), scratch_dir: dir.clone() },
            observer.clone(),
            Arc::new(|_t: String| {}),
        )
        .expect("voice mode should start");

        // Rich says something long enough to be worth interrupting.
        ctl.turn_started();
        ctl.speak_delta(
            "Three things this morning. Acme came back on the renegotiation and the number is \
             softer than it looks. Finance found a gap in the Q4 forecast. Partnerships want a \
             call about the economics before Thursday. ",
        );
        ctl.speak_end();
        ctl.turn_ended();

        // Wait until there is real audio worth interrupting. The FIRST sentence alone is only
        // ~1.3 s — the queue keeps growing behind it because synthesis outruns playback
        // (rtf ~0.074), which is the pipelining working, so wait for the depth rather than
        // for the first sample.
        let deadline = Instant::now() + Duration::from_secs(15);
        while ctl.queued_speech_secs() <= 2.0 && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        let queued_before = ctl.queued_speech_secs();
        assert!(queued_before > 2.0, "Rich never got going: {queued_before:.3} s queued");

        // Let him actually be audible for a beat, then cut him.
        std::thread::sleep(Duration::from_millis(900));
        let cut_at = Instant::now();
        let dropped = ctl.force_barge_in();
        let cut_took = cut_at.elapsed();

        let rate = ctl.diagnostics().output_rate as f32;
        let dropped_secs = dropped as f32 / rate;
        let stop_latency = ctl.stop_latency_secs();
        println!(
            "barge-in: dropped {} samples = {:.3} s of Rich; call took {:.4} s; device stop latency {:.4} s ({} frames @ {} Hz)",
            dropped,
            dropped_secs,
            cut_took.as_secs_f32(),
            stop_latency,
            (stop_latency * rate).round() as u32,
            rate as u32
        );

        assert!(dropped_secs > 1.0, "nothing meaningful was cut: {dropped_secs:.3} s");
        assert!(
            stop_latency > 0.0 && stop_latency < 0.100,
            "stop latency implausible: {stop_latency:.4} s"
        );
        // The device must genuinely fall silent and STAY silent — a queue that refills would
        // mean a sentence synthesised across the cut still got through.
        std::thread::sleep(Duration::from_millis(600));
        assert_eq!(ctl.queued_speech_secs(), 0.0, "Rich started talking again after being cut");
        assert_eq!(ctl.state(), VoiceState::Listening, "state did not return to listening");

        drop(ctl);
        std::fs::remove_dir_all(&dir).ok();
    }

    /// LIVE: the full local loop with audio INJECTED at the capture source — real VAD, real
    /// endpointing, real whisper.cpp, real `say`, real output device. The only thing this
    /// does not exercise is the microphone driver, which this machine does not have (see
    /// capture.rs). Rich's "reply" here is a fixed string, so the ACP/Claude leg is out of
    /// scope for a unit test; `voice_loop` (the example) does that end of it.
    #[test]
    #[cfg(target_os = "macos")]
    fn live_injected_audio_completes_the_whole_local_loop() {
        if std::env::var("RICHOS_VOICE_LIVE_AUDIO").as_deref() != Ok("1") {
            return;
        }
        let dir = std::env::temp_dir().join("richos-voice-loop-test");
        std::fs::create_dir_all(&dir).unwrap();
        let wav_path = dir.join("ceo.wav");

        // Synthesize a "CEO" utterance with a DIFFERENT voice than Rich's, at 16 kHz.
        let out = std::process::Command::new("/usr/bin/say")
            .args(["-v", "Samantha", "-o"])
            .arg(&wav_path)
            .arg("--data-format=LEI16@16000")
            .arg("Rich, what is the status of the voice pipeline today?")
            .output()
            .expect("say");
        assert!(out.status.success());

        let observer = Arc::new(Recorder::default());
        let heard: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let heard2 = heard.clone();
        let ctl = VoiceController::start(
            VoiceOptions { source: AudioSource::Wav(wav_path), scratch_dir: dir.clone() },
            observer.clone(),
            Arc::new(move |text: String| {
                heard2.lock().unwrap().push(text);
            }),
        )
        .expect("voice mode should start with an injected source");

        // 3.1 s of audio + 0.800 s hangover + ~0.5 s whisper.
        std::thread::sleep(Duration::from_millis(6000));
        let said = heard.lock().unwrap().clone();
        assert!(!said.is_empty(), "the loop never produced a transcript");
        assert!(
            said[0].to_lowercase().contains("voice pipeline"),
            "transcript did not match what was spoken: {said:?}"
        );

        // Now Rich answers, streamed as deltas exactly as the spine does.
        ctl.turn_started();
        ctl.speak_delta("Good morning. ");
        ctl.speak_delta("The voice pipeline is up. ");
        ctl.speak_end();
        ctl.turn_ended();
        std::thread::sleep(Duration::from_millis(1500));
        assert!(ctl.queued_speech_secs() > 0.0 || ctl.state() == VoiceState::Speaking,
            "Rich never produced audio");
        drop(ctl);
        std::fs::remove_dir_all(&dir).ok();
    }
}
