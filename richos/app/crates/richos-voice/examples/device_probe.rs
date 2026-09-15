//! Device probe — what the audio hardware on THIS machine actually reports, and whether the
//! process is allowed to open the microphone at all.
//!
//! Run before trusting any latency or frame claim:
//! ```sh
//! cargo run -p richos-voice --example device_probe
//! ```
//! It prints the default input/output configs and captures 1 second, reporting peak and RMS.
//! **A silent capture means TCC denied the mic** (macOS hands a denied process an endless
//! stream of zeros rather than an error) — that is a positive signal, not an inference.

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

fn main() {
    let host = cpal::default_host();
    println!("host: {:?}", host.id());

    match host.default_output_device() {
        Some(d) => {
            println!("output device: {}", d.description().map(|d| format!("{d:?}")).unwrap_or_else(|_| "<unnamed>".into()));
            match d.default_output_config() {
                Ok(c) => println!(
                    "  default output config: {} Hz, {} ch, {:?}, buffer {:?}",
                    c.sample_rate(),
                    c.channels(),
                    c.sample_format(),
                    c.buffer_size()
                ),
                Err(e) => println!("  default output config error: {e}"),
            }
        }
        None => println!("output device: NONE"),
    }

    let Some(dev) = host.default_input_device() else {
        println!("input device: NONE — no microphone visible to this process");
        return;
    };
    println!("input device: {}", dev.description().map(|d| format!("{d:?}")).unwrap_or_else(|_| "<unnamed>".into()));
    let cfg = match dev.default_input_config() {
        Ok(c) => c,
        Err(e) => {
            println!("  default input config error: {e}");
            return;
        }
    };
    println!(
        "  default input config: {} Hz, {} ch, {:?}, buffer {:?}",
        cfg.sample_rate(),
        cfg.channels(),
        cfg.sample_format(),
        cfg.buffer_size()
    );

    let peak = Arc::new(AtomicU64::new(0));
    let energy = Arc::new(AtomicU64::new(0));
    let count = Arc::new(AtomicU64::new(0));
    let (p, e, n) = (peak.clone(), energy.clone(), count.clone());

    let stream = dev
        .build_input_stream(
            &cfg.config(),
            move |data: &[f32], _| {
                let mut mx = 0.0f32;
                let mut sum = 0.0f64;
                for s in data {
                    mx = mx.max(s.abs());
                    sum += (*s as f64) * (*s as f64);
                }
                p.fetch_max((mx * 1e9) as u64, Ordering::Relaxed);
                e.fetch_add((sum * 1e6) as u64, Ordering::Relaxed);
                n.fetch_add(data.len() as u64, Ordering::Relaxed);
            },
            |err| eprintln!("input stream error: {err}"),
            None,
        )
        .expect("build input stream");
    stream.play().expect("play");
    println!("capturing 1.0 s ...");
    std::thread::sleep(std::time::Duration::from_millis(1000));
    drop(stream);

    let n = count.load(Ordering::Relaxed).max(1);
    let peak = peak.load(Ordering::Relaxed) as f64 / 1e9;
    let rms = ((energy.load(Ordering::Relaxed) as f64 / 1e6) / n as f64).sqrt();
    println!("captured {n} samples  peak={peak:.6}  rms={rms:.6}");
    if peak == 0.0 {
        println!("VERDICT: SILENT — the process is not allowed to hear the microphone (TCC), or the device is muted.");
    } else {
        println!("VERDICT: the microphone is live and this process can hear it.");
    }
}
