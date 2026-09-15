//! LIVE hardware check for the post-open silent-input detector — the real microphone, the
//! real `VoiceController`, the real `rich://voice-state` payload the webview reads.
//!
//! ```sh
//! cargo run -p richos-voice --example noaudio_live
//! ```
//!
//! It runs one continuous voice-mode session and drives the input dead and back **through
//! CoreAudio**, by setting the macOS system input volume to 0 and then restoring it
//! (`osascript -e 'set volume input volume N'`). That is one of the exact failure cases this
//! detector exists for — the stream stays open and healthy the whole time; only the samples
//! go away. Nothing is mocked, nothing is injected: the frames come off the device.
//!
//! **What this does and does not stand in for.** It reproduces the *OS-level input mute* and
//! *gain-at-zero* cases exactly. It does not press the Elgato Wave:3's capacitive hardware
//! mute — that needs a finger. The detector cannot tell the two apart (both stop the samples
//! before this process sees them), but the honest statement is that the hardware button
//! itself is untested here.
//!
//! The session's original input volume is read first and restored on every exit path.

use richos_voice::capture::AudioSource;
use richos_voice::controller::{VoiceController, VoiceOptions};
use richos_voice::event::{VoiceEvent, VoiceObserver};
use richos_voice::noaudio::{no_audio_window_secs, NO_AUDIO_FRAMES};
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

struct Watch {
    started: Instant,
    /// (elapsed seconds, no_audio) for every transition, plus the state that came with it.
    transitions: Mutex<Vec<(f32, bool, String)>>,
    last: Mutex<Option<bool>>,
}

impl VoiceObserver for Watch {
    fn on_voice_event(&self, event: &VoiceEvent) {
        if let VoiceEvent::State { state, no_audio, level, .. } = event {
            let mut last = self.last.lock().unwrap();
            if *last != Some(*no_audio) {
                let t = self.started.elapsed().as_secs_f32();
                println!(
                    "  [{t:7.3} s] rich://voice-state  noAudio={no_audio}  state={}  level={level:.3}",
                    state.as_str()
                );
                self.transitions.lock().unwrap().push((t, *no_audio, state.as_str().to_string()));
                *last = Some(*no_audio);
            }
        }
    }
}

fn input_volume() -> i32 {
    let out = Command::new("/usr/bin/osascript")
        .args(["-e", "input volume of (get volume settings)"])
        .output()
        .expect("osascript");
    String::from_utf8_lossy(&out.stdout).trim().parse().unwrap_or(50)
}

fn set_input_volume(v: i32) {
    let _ = Command::new("/usr/bin/osascript")
        .args(["-e", &format!("set volume input volume {v}")])
        .status();
}

fn main() {
    let original = input_volume();
    println!("system input volume at start: {original}");
    if original == 0 {
        println!("ABORT: the input is already muted — start from a live microphone.");
        return;
    }

    let watch = Arc::new(Watch {
        started: Instant::now(),
        transitions: Mutex::new(Vec::new()),
        last: Mutex::new(None),
    });

    let ctl = match VoiceController::start(
        VoiceOptions { source: AudioSource::Device, ..VoiceOptions::default() },
        watch.clone(),
        Arc::new(|t: String| println!("  (utterance: {t:?})")),
    ) {
        Ok(c) => c,
        Err(e) => {
            println!("ABORT: voice mode did not start: {e}");
            return;
        }
    };
    println!("window = {NO_AUDIO_FRAMES} frames x 256 / 16000 = {:.3} s\n", no_audio_window_secs());

    // --- phase 1: live microphone, nobody talking -------------------------------------
    // `RICHOS_NOAUDIO_LIVE_SECS` lengthens this into a soak: the false-positive side is the
    // one the CEO cares about most ("too quiet, never annoying"), and the only way to test
    // it is to leave a real microphone open in a real room and watch nothing happen.
    let live_secs: u64 = std::env::var("RICHOS_NOAUDIO_LIVE_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(6);
    println!("phase 1: LIVE microphone, silence in the room, {live_secs}.0 s (must NOT warn)");
    for _ in 0..live_secs {
        std::thread::sleep(Duration::from_secs(1));
        if ctl.no_audio() {
            break;
        }
    }
    let warned_while_live = ctl.no_audio();

    // --- phase 2: kill the input through CoreAudio -------------------------------------
    println!("\nphase 2: system input volume -> 0 (the stream stays open)");
    let muted_at = Instant::now();
    set_input_volume(0);
    std::thread::sleep(Duration::from_secs(6));
    let warned_while_muted = ctl.no_audio();
    let warn_delay = watch
        .transitions
        .lock()
        .unwrap()
        .iter()
        .find(|(_, silent, _)| *silent)
        .map(|(t, _, _)| *t - muted_at.duration_since(watch.started).as_secs_f32());

    // --- phase 3: bring it back --------------------------------------------------------
    println!("\nphase 3: system input volume -> {original} (unmute)");
    let unmuted_at = Instant::now();
    set_input_volume(original);
    std::thread::sleep(Duration::from_secs(4));
    let cleared = !ctl.no_audio();
    let clear_delay = watch
        .transitions
        .lock()
        .unwrap()
        .iter()
        .rev()
        .find(|(_, silent, _)| !*silent)
        .map(|(t, _, _)| *t - unmuted_at.duration_since(watch.started).as_secs_f32());

    drop(ctl);
    set_input_volume(original);
    println!("\nsystem input volume restored to {}", input_volume());

    println!("\n--- result -------------------------------------------------------------");
    println!("  live, nobody talking, {live_secs}.0 s ...... warned: {warned_while_live}  (want false)");
    match warn_delay {
        Some(d) => println!(
            "  muted -> warning ................... {d:.3} s after the mute command (window {:.3} s)",
            no_audio_window_secs()
        ),
        None => println!("  muted -> warning ................... NEVER FIRED"),
    }
    println!("  warned while muted ................. {warned_while_muted}  (want true)");
    match clear_delay {
        Some(d) => println!("  unmuted -> cleared ................. {d:.3} s after the unmute command"),
        None => println!("  unmuted -> cleared ................. NEVER CLEARED"),
    }
    println!("  cleared after unmute ............... {cleared}  (want true)");

    let pass = !warned_while_live && warned_while_muted && cleared && warn_delay.is_some();
    println!("\n  VERDICT: {}", if pass { "PASS" } else { "FAIL" });
}
