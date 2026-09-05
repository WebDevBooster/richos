//! Terminal host for the same run controller used by RichOS.
use richos_core::cognition::TurnItem;
use richos_core::native::{resolve_claude_bin, NativeCognition};
use richos_core::run::{read_snapshot, RunController, RunPlan, RunState};
use richos_core::run_host::CognitionRunHost;
use std::path::PathBuf;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};

fn main() {
    match run() {
        Ok(code) => std::process::exit(code),
        Err(e) => {
            eprintln!("Run did not complete: {e}");
            std::process::exit(2);
        }
    }
}

fn run() -> Result<i32, Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() < 2 {
        return Err("Usage: richos-run create JOURNAL PLAN.json | drive JOURNAL | status JOURNAL | pause JOURNAL | resume JOURNAL | retry JOURNAL TASK_ID | end JOURNAL".into());
    }
    let path = PathBuf::from(&args[1]);
    let pause_path = path.with_extension("pause");
    match args[0].as_str() {
        "create" if args.len() == 3 => {
            let plan: RunPlan = serde_json::from_slice(&std::fs::read(&args[2])?)?;
            let ctl = RunController::create(&path, plan)?;
            println!("{}", serde_json::to_string_pretty(ctl.snapshot())?);
        }
        "status" if args.len() == 2 => {
            let snapshot = read_snapshot(&path)?;
            println!("{}", serde_json::to_string_pretty(&snapshot)?);
            println!("State: {:?}", snapshot.state());
            return Ok(if snapshot.state() == RunState::Completed {
                0
            } else {
                3
            });
        }
        "pause" if args.len() == 2 => {
            read_snapshot(&path)?;
            let f = std::fs::File::create(&pause_path)?;
            f.sync_all()?;
            println!("Pause requested. Status remains separate from completion.");
        }
        "resume" if args.len() == 2 => {
            let mut ctl = RunController::open(&path)?;
            if pause_path.exists() {
                std::fs::remove_file(&pause_path)?;
            }
            ctl.pause(false)?;
            println!(
                "Run unpaused. Use drive to continue; interrupted tasks require explicit retry."
            );
        }
        "retry" if args.len() == 3 => RunController::open(&path)?.retry(&args[2])?,
        "end" if args.len() == 2 => RunController::open(&path)?.cancel()?,
        "drive" if args.len() == 2 => {
            let mut ctl = RunController::open(&path)?;
            if pause_path.exists() {
                ctl.pause(true)?;
            }
            if ctl.snapshot().state() != RunState::Ready {
                println!("State: {:?}", ctl.snapshot().state());
                return Ok(if ctl.snapshot().state() == RunState::Completed {
                    0
                } else {
                    3
                });
            }
            let pause = Arc::new(AtomicBool::new(pause_path.exists()));
            let done = Arc::new(AtomicBool::new(false));
            let (watch_pause, watch_done) = (pause.clone(), done.clone());
            let watch = std::thread::spawn(move || {
                while !watch_done.load(Ordering::SeqCst) {
                    if pause_path.exists() {
                        watch_pause.store(true, Ordering::SeqCst);
                    }
                    std::thread::sleep(std::time::Duration::from_millis(100));
                }
            });
            let result = (|| -> Result<RunState, Box<dyn std::error::Error>> {
                // A fresh lease per drive. State and acceptance belong to the
                // controller, so resuming never relies on a model's memory.
                let mut cognition =
                    NativeCognition::start(&resolve_claude_bin(), &ctl.snapshot().plan.workspace)?;
                let mut output = |item: TurnItem<'_>| {
                    if let TurnItem::Text { text, .. } = item {
                        print!("{text}");
                    }
                };
                let mut host = CognitionRunHost {
                    cognition: &mut cognition,
                    on_item: &mut output,
                    pause,
                };
                while ctl.snapshot().state() == RunState::Ready {
                    let state = ctl.tick(&mut host)?;
                    eprintln!("\nRun state: {state:?}");
                }
                Ok(ctl.snapshot().state())
            })();
            done.store(true, Ordering::SeqCst);
            let _ = watch.join();
            let state = result?;
            return Ok(if state == RunState::Completed { 0 } else { 3 });
        }
        _ => return Err("Unknown command or wrong number of arguments.".into()),
    }
    Ok(0)
}
