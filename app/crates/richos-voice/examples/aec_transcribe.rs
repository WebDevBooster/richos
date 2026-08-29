//! **Does the echo canceller damage transcription?** Measured against whisper, not asserted.
//!
//! ```text
//!   cargo run -p richos-voice --release --example aec_transcribe
//! ```
//!
//! The brief's constraint is exact: *"it must not degrade transcription accuracy — dictation
//! and call transcription both feed on this audio, and an AEC that eats consonants would trade
//! a barge-in bug for a fabrication bug. Measure that, do not assume it."*
//!
//! There are two separate claims to establish and they need different kinds of evidence.
//!
//! **Claim 1 — while Rich is silent, the audio is unchanged.** This is arithmetic, not
//! statistics: with a zero reference the filter's estimate is exactly zero and the residual is
//! the microphone signal bit-for-bit. `aec.rs` and the composition tests assert it directly.
//! Condition D below re-confirms it end to end by checking that whisper returns a byte-identical
//! transcript. Dictation and call transcription live entirely in this case — Rich is not
//! talking during them — so for those two flows the question is closed by construction.
//!
//! **Claim 2 — during double-talk, the audio is not degraded.** Here the canceller genuinely
//! does alter the signal, because it is subtracting Rich's voice out of it. That claim is
//! empirical and this rig measures it, with the comparison that matters:
//!
//! | condition | what the microphone contains | what it answers |
//! |---|---|---|
//! | **A** clean | the CEO + room noise | the ceiling: whisper's own error rate |
//! | **B** echo, no AEC | the CEO + Rich's echo | the damage the echo does today |
//! | **C** echo, AEC on | the same, cancelled | **does the canceller recover A?** |
//! | **D** no echo, AEC on | the CEO + room noise, cancelled | is it transparent? (must equal A) |
//!
//! The number that decides it is C versus A. If C is materially worse than A the canceller is
//! eating speech and must not ship. B is there so the comparison is fair: "does AEC hurt
//! transcription" is the wrong question in isolation, because the alternative is not clean
//! audio, it is B.
//!
//! Two different macOS voices are used so the CEO and Rich are acoustically distinct, as they
//! are in life.

use richos_voice::aec::{EchoCanceller, AEC_BLOCK};
use richos_voice::stt::Recognizer;
use richos_voice::vad::SAMPLE_RATE;
use richos_voice::wav;
use std::path::Path;
use std::process::Command;

/// The CEO's lines. Deliberately full of the consonants a spectral suppressor destroys first —
/// fricatives, plosives, sibilants — because "eats consonants" is the specific failure mode
/// the brief names.
const CEO_LINES: &[&str] = &[
    "Stop there. Which of the six staging fixes actually shipped this fifth of the month?",
    "The client's spreadsheet still shows thirty-six thousand, not thirty-five thousand.",
    "Push the specification back to Thursday and tell Chris the test suite stays.",
    "That statement about the cash position is precisely the thing I asked you to check first.",
    "Switch the whole export to fetch the fresh set, then send Steve the summary.",
    "Fix the crash first, ship the features second, and stop shifting the schedule.",
    "Send the sixth revision straight to Sarah and skip the staging step this Saturday.",
    "Sixteen of those accounts churned, which is not the number the deck claims.",
    "Check whether the fresh install still crashes when the cache is cold.",
    "Cut the scope, ship this Friday, and stop pretending the schedule is soft.",
    "The forecast spreadsheet shows fifty-five percent, but the source says forty-five.",
    "Show me the test that proves it, or the fix does not exist.",
];

/// Rich's lines — the far end, whose echo pollutes the microphone.
const RICH_LINES: &[&str] = &[
    "Right, let me take you through where the front end actually stands this morning.",
    "The session spine is landed and green, and the voice pipeline runs end to end.",
    "Packaging is the honest gap, and I would rather tell you that plainly now.",
];

fn say(voice: &str, text: &str, scratch: &Path, tag: &str) -> Option<Vec<f32>> {
    let txt = scratch.join(format!("{tag}.txt"));
    let wav_path = scratch.join(format!("{tag}.wav"));
    std::fs::write(&txt, text).ok()?;
    let out = Command::new("/usr/bin/say")
        .arg("-v")
        .arg(voice)
        .arg("-r")
        .arg("180")
        .arg("-f")
        .arg(&txt)
        .arg("-o")
        .arg(&wav_path)
        .arg(format!("--data-format=LEI16@{SAMPLE_RATE}"))
        .output()
        .ok()?;
    if !out.status.success() {
        eprintln!("say -v {voice} failed: {}", String::from_utf8_lossy(&out.stderr));
        return None;
    }
    let bytes = std::fs::read(&wav_path).ok()?;
    let pcm = wav::read_pcm16(&bytes).ok()?;
    let (mono, r) = pcm.into_mono();
    Some(wav::resample(&mono, r, SAMPLE_RATE))
}

/// The room: Rich's voice delayed 50.0 ms with four reflections, plus a -54 dBFS noise floor.
fn through_the_room(reference: &[f32], len: usize) -> Vec<f32> {
    let taps: [(usize, f32); 5] = [(0, 0.50), (37, -0.22), (101, 0.13), (238, -0.07), (601, 0.04)];
    let delay = 800usize;
    let mut out = vec![0.0f32; len];
    for (offset, g) in taps {
        for i in (delay + offset)..len {
            if i - delay - offset < reference.len() {
                out[i] += reference[i - delay - offset] * g;
            }
        }
    }
    out
}

fn room_noise(len: usize, amp: f32) -> Vec<f32> {
    let mut s: u32 = 0xBEEF_0007;
    (0..len)
        .map(|_| {
            s ^= s << 13;
            s ^= s >> 17;
            s ^= s << 5;
            ((s as f32 / u32::MAX as f32) * 2.0 - 1.0) * amp
        })
        .collect()
}

/// Run a mic signal through the canceller with the given reference. Returns the residual.
fn cancel(reference: &[f32], mic: &[f32]) -> Vec<f32> {
    let (mut aec, ring) = EchoCanceller::new();
    let blocks = mic.len() / AEC_BLOCK;
    let mut out = Vec::with_capacity(blocks * AEC_BLOCK);
    let mut frame = [0.0f32; AEC_BLOCK];
    let zeros = [0.0f32; AEC_BLOCK];
    for b in 0..blocks {
        let lo = b * AEC_BLOCK;
        let hi = lo + AEC_BLOCK;
        ring.push(if hi <= reference.len() { &reference[lo..hi] } else { &zeros });
        frame.copy_from_slice(&mic[lo..hi]);
        aec.process_block(&mut frame);
        out.extend_from_slice(&frame);
    }
    out
}

/// Lower-case, strip everything that is not a letter, digit or space. Whisper's punctuation
/// and capitalisation are not what we are measuring.
fn normalise(s: &str) -> Vec<String> {
    s.to_lowercase()
        .chars()
        .map(|c| if c.is_alphanumeric() || c.is_whitespace() { c } else { ' ' })
        .collect::<String>()
        .split_whitespace()
        .map(|w| w.to_string())
        .collect()
}

/// Word error rate: Levenshtein distance over words, divided by the reference length.
fn wer(reference: &str, hypothesis: &str) -> (f32, usize, usize) {
    let r = normalise(reference);
    let h = normalise(hypothesis);
    if r.is_empty() {
        return (0.0, 0, 0);
    }
    let mut prev: Vec<usize> = (0..=h.len()).collect();
    let mut cur = vec![0usize; h.len() + 1];
    for i in 1..=r.len() {
        cur[0] = i;
        for j in 1..=h.len() {
            let sub = prev[j - 1] + usize::from(r[i - 1] != h[j - 1]);
            cur[j] = sub.min(prev[j] + 1).min(cur[j - 1] + 1);
        }
        std::mem::swap(&mut prev, &mut cur);
    }
    let d = prev[h.len()];
    (d as f32 / r.len() as f32, d, r.len())
}

struct Case {
    label: &'static str,
    detail: &'static str,
    audio: Vec<f32>,
}

fn main() {
    let scratch = std::env::temp_dir().join("richos-aec-transcribe");
    std::fs::create_dir_all(&scratch).ok();

    let recognizer = match Recognizer::resolve() {
        Ok(r) => r,
        Err(e) => {
            eprintln!("whisper is not available on this machine: {e}");
            eprintln!("({})", e.ceo_message());
            std::process::exit(2);
        }
    };
    println!("=== richos-voice: does the canceller damage transcription? ===");
    println!("recognizer : {} · {}", recognizer.model_id(), recognizer.binary_path().display());

    // Two acoustically distinct voices, as in life.
    let ceo_voice = std::env::var("RICHOS_AEC_CEO_VOICE").unwrap_or_else(|_| "Samantha".into());
    let rich_voice = std::env::var("RICHOS_TTS_VOICE").unwrap_or_else(|_| "Daniel".into());
    println!("CEO voice  : {ceo_voice}\nRich voice : {rich_voice}\n");

    // Rich talks continuously; his echo is what pollutes the mic.
    let mut rich = Vec::new();
    for (i, line) in RICH_LINES.iter().enumerate() {
        match say(&rich_voice, line, &scratch, &format!("rich-{i}")) {
            Some(a) => rich.extend_from_slice(&a),
            None => {
                eprintln!("could not synthesise Rich's voice — is `say -v {rich_voice}` installed?");
                std::process::exit(1);
            }
        }
    }

    let mut totals = [(0usize, 0usize); 4];
    let mut printed_d_mismatch = 0usize;

    println!("{:<4} {:<36} {:>7} {:>7} {:>7} {:>7}", "#", "line", "A", "B", "C", "D");
    println!("{}", "-".repeat(74));

    for (i, line) in CEO_LINES.iter().enumerate() {
        let Some(ceo) = say(&ceo_voice, line, &scratch, &format!("ceo-{i}")) else {
            eprintln!("could not synthesise the CEO's voice — is `say -v {ceo_voice}` installed?");
            std::process::exit(1);
        };
        // Pad so the canceller has time to converge before the CEO starts talking: 8 s of
        // Rich alone, then the double-talk.
        let lead = SAMPLE_RATE as usize * 8;
        let len = lead + ceo.len() + SAMPLE_RATE as usize;

        // Rich's reference, looped to fill the whole window.
        let mut reference = Vec::with_capacity(len);
        while reference.len() < len {
            reference.extend_from_slice(&rich);
        }
        reference.truncate(len);

        let echo = through_the_room(&reference, len);
        let noise = room_noise(len, 0.002);

        let mut near = vec![0.0f32; len];
        near[lead..lead + ceo.len()].copy_from_slice(&ceo);

        // A: clean — the CEO and the room, no echo at all.
        let a: Vec<f32> = near.iter().zip(noise.iter()).map(|(x, y)| x + y).collect();
        // B: the echo is there and nothing removes it.
        let b: Vec<f32> = a.iter().zip(echo.iter()).map(|(x, y)| x + y).collect();
        // C: the same, cancelled.
        let c = cancel(&reference, &b);
        // D: no echo, but the canceller is running against a SILENT reference.
        let d = cancel(&vec![0.0f32; len], &a);

        let cases = [
            Case { label: "A", detail: "clean", audio: a[lead..].to_vec() },
            Case { label: "B", detail: "echo, no AEC", audio: b[lead..].to_vec() },
            Case { label: "C", detail: "echo, AEC on", audio: c[lead.min(c.len())..].to_vec() },
            Case { label: "D", detail: "no echo, AEC on", audio: d[lead.min(d.len())..].to_vec() },
        ];

        let mut rates = [0.0f32; 4];
        let mut texts: Vec<String> = Vec::new();
        for (k, case) in cases.iter().enumerate() {
            let text = match recognizer.transcribe(&case.audio, &scratch) {
                Ok((t, _)) => t,
                Err(e) => {
                    eprintln!("stt failed on {}: {e}", case.label);
                    String::new()
                }
            };
            let (rate, d_err, n_words) = wer(line, &text);
            rates[k] = rate;
            totals[k].0 += d_err;
            totals[k].1 += n_words;
            texts.push(text);
            let _ = case.detail;
        }
        if normalise(&texts[0]) != normalise(&texts[3]) {
            printed_d_mismatch += 1;
        }

        let short: String = line.chars().take(34).collect();
        println!(
            "{:<4} {:<36} {:>6.1}% {:>6.1}% {:>6.1}% {:>6.1}%",
            i + 1,
            short,
            rates[0] * 100.0,
            rates[1] * 100.0,
            rates[2] * 100.0,
            rates[3] * 100.0
        );
        if rates[2] > rates[0] + 0.01 {
            println!("     ref : {line}");
            println!("     A   : {}", texts[0]);
            println!("     C   : {}", texts[2]);
        }
    }

    println!("{}", "-".repeat(74));
    let pct = |t: (usize, usize)| 100.0 * t.0 as f32 / t.1.max(1) as f32;
    println!(
        "{:<41} {:>6.1}% {:>6.1}% {:>6.1}% {:>6.1}%",
        "AGGREGATE WER",
        pct(totals[0]),
        pct(totals[1]),
        pct(totals[2]),
        pct(totals[3])
    );
    println!();
    println!("  A  clean               — whisper's own error rate, the ceiling");
    println!("  B  echo, no AEC        — what shipping without a canceller costs");
    println!("  C  echo, AEC on        — THE ANSWER");
    println!("  D  no echo, AEC on     — transparency; must equal A exactly");
    println!();
    println!("  C - A = {:+.1} points   (the canceller's cost during double-talk)", pct(totals[2]) - pct(totals[0]));
    println!("  B - C = {:+.1} points   (what the canceller recovers)", pct(totals[1]) - pct(totals[2]));
    println!(
        "  D vs A: {} of {} transcripts differ{}",
        printed_d_mismatch,
        CEO_LINES.len(),
        if printed_d_mismatch == 0 { " — TRANSPARENT, as the arithmetic requires" } else { " *** NOT TRANSPARENT ***" }
    );
    std::fs::remove_dir_all(&scratch).ok();
}
