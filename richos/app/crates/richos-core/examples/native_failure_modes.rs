//! **THE LOUD-FAILURE PROOF.** `wiki/ceo-decisions.md` §16 accepted a dependency on one
//! UNDOCUMENTED flag of a SELF-UPDATING binary, on the condition that it fail loudly rather
//! than degrade quietly: *"A customer must never get a RichOS that looks fine and cannot
//! talk to Rich."*
//!
//! This is that condition, executed. It costs **no API turns** — every case fails before a
//! turn can start, which is the whole point — so it can be re-run on any machine at any
//! time.
//!
//! ```sh
//! cargo run -p richos-core --example native_failure_modes
//! ```
//!
//! Seven cases, in the order a failure would actually be met:
//!
//!   1. **The binary is not where we looked.** Refused BEFORE a process is spawned, naming
//!      the path — not an exit code.
//!   2. **The binary rejects our flag vector.** This is the §16 risk itself: a self-update
//!      that drops `--permission-prompt-tool`. Reproduced against a fake child that does
//!      exactly what the real one was MEASURED doing (`error: unknown option '<flag>'` on
//!      stderr, exit 1, zero bytes of stdout), and the error carries the child's own words.
//!   3. **THE REAL BINARY, given a flag it does not know.** Case 2 with the fake removed:
//!      the actual `claude` on this machine, driven through the actual `NativeCognition`.
//!      Nothing is stubbed and nothing is asserted about a fake's behaviour.
//!   4. **The binary starts, holds stdio open, and says nothing.** The hang case. Bounded,
//!      never indefinite.
//!   5. **A child that answers the handshake but refuses it.** A `subtype` that is not
//!      `success` is a refusal, not a success with a caveat.
//!   6. **RichOS's standing instruction is not on disk.** The newest of the six, and the
//!      reason `--append-system-prompt-file` was chosen over the alternatives: an absent
//!      instruction file under `--setting-sources project` would have been a clean
//!      handshake and a generic Claude. Here the binary is present, the working directory
//!      exists, and only the doctrine is missing — so the refusal names the doctrine.
//!   7. **A skill RichOS ships is not on disk.** The one where the loudness is entirely
//!      OURS. `claude` refuses a missing `--append-system-prompt-file`; it accepts a
//!      missing `--plugin-dir` in silence — exit 0, clean handshake, `plugins: []`, an
//!      ordinary turn (measured, `inner-doctrine-skills-2026-09-06/` cell K4). If this
//!      case ever passes for the wrong reason, deleting a skill file stops being an error
//!      and becomes a product that is quietly less than it says it is.
//!
//! And the negative control, without which the four above prove nothing: **the real binary,
//! with the real flags, completes the handshake.** If that fails too, the four failures
//! above would be failing for the wrong reason.
//!
//! **What this does NOT prove, and cannot.** If `--permission-prompt-tool` is one day still
//! ACCEPTED but silently stops arming the `can_use_tool` channel, nothing here detects it:
//! the handshake would pass and the failure would surface only as a tool that never runs.
//! The `initialize` reply carries 17 fields and none of them names the permission prompt
//! tool, so there is nothing to assert against. That is **unproven**, it is stated in
//! `native.rs`'s module doc too, and it is not fixable from this side.

use richos_core::native::{
    chat_child_args, resolve_claude_bin, NativeCognition, APPEND_SYSTEM_PROMPT_FILE,
    PERMISSION_PROMPT_TOOL, PLUGIN_DIR,
};
use std::path::{Path, PathBuf};

fn main() {
    let mut failures = 0usize;
    let mut cases = 0usize;

    // RichOS's standing instruction, rendered for THIS install exactly as the app renders it
    // (`doctrine.rs`). Every case below drives the production argument vector, doctrine
    // included, rather than a simplified one.
    let doctrine = match richos_core::doctrine::ensure_for_install() {
        Ok(p) => p,
        Err(e) => {
            println!("\n  the standing instruction could not be rendered: {e}");
            println!("  NOTHING WAS VERIFIED — a check that did not happen must not report ok.");
            std::process::exit(2);
        }
    };
    let skills = match richos_core::skills::ensure_for_install() {
        Ok(p) => p,
        Err(e) => {
            println!("\n  the skills could not be rendered: {e}");
            println!("  NOTHING WAS VERIFIED — a check that did not happen must not report ok.");
            std::process::exit(2);
        }
    };
    println!("\n=== THE STANDING INSTRUCTION ===");
    println!("  {}", doctrine.display());
    println!("  {} bytes", std::fs::metadata(&doctrine).map(|m| m.len()).unwrap_or(0));
    println!("\n=== THE SKILLS ===");
    println!("  {}", skills.display());
    for name in richos_core::skills::qualified_names() {
        println!("  {name}");
    }

    println!("\n=== THE FLAG VECTOR ===");
    let args = chat_child_args("00000000-0000-0000-0000-000000000000", &doctrine, &skills);
    println!("  {}", args.join(" "));
    let armed = args
        .iter()
        .position(|a| a == PERMISSION_PROMPT_TOOL)
        .map(|i| args.get(i + 1).map(String::as_str) == Some("stdio"))
        .unwrap_or(false);
    check(&mut cases, &mut failures, armed, "the undocumented flag is present and armed", "there is no code path that drops it");
    let carries = args
        .iter()
        .position(|a| a == APPEND_SYSTEM_PROMPT_FILE)
        .map(|i| args.get(i + 1).map(String::as_str) == Some(doctrine.display().to_string().as_str()))
        .unwrap_or(false);
    check(&mut cases, &mut failures, carries, "the standing instruction is named in the vector", "the second semi-documented flag, pinned the same way");
    let skilled = args
        .iter()
        .position(|a| a == PLUGIN_DIR)
        .map(|i| args.get(i + 1).map(String::as_str) == Some(skills.display().to_string().as_str()))
        .unwrap_or(false);
    check(&mut cases, &mut failures, skilled, "RichOS's own skills are named in the vector", "a directory the app wrote, never the operator's ~/.claude");

    // ---- 1. no binary ------------------------------------------------------------------
    println!("\n=== 1. THE BINARY IS NOT THERE ===");
    let err = NativeCognition::start(Path::new("/nonexistent/definitely/not/claude"), Path::new("/tmp"), &doctrine, &skills)
        .err()
        .map(|e| e.to_string())
        .unwrap_or_else(|| "IT STARTED — which is impossible".into());
    println!("  {err}");
    check(&mut cases, &mut failures, err.contains("was not found"), "refused before a process was spawned", "the error names a path, not an exit code");
    check(&mut cases, &mut failures, err.contains("cannot run without it"), "and says why it matters", "a customer-facing consequence, not a stack trace");

    // ---- 2. a child that rejects the flag ----------------------------------------------
    println!("\n=== 2. A CHILD THAT REJECTS THE FLAG (the §16 risk, reproduced) ===");
    let script = fake("flag-reject", "echo \"error: unknown option '--permission-prompt-tool'\" >&2\nexit 1\n");
    let err = NativeCognition::start(&script, Path::new("/tmp"), &doctrine, &skills)
        .err()
        .map(|e| e.to_string())
        .unwrap_or_else(|| "IT STARTED — a rejected flag was treated as success".into());
    println!("  {err}");
    check(&mut cases, &mut failures, err.contains("failed to start"), "loud, and not a degraded success", "lease_ready goes false and every send is refused");
    check(&mut cases, &mut failures, err.contains("unknown option '--permission-prompt-tool'"), "the child's own words, verbatim", "on this failure that ONE line is the whole diagnosis");
    let _ = std::fs::remove_dir_all(script.parent().unwrap());

    // ---- 3. THE REAL BINARY, given a flag it does not know ------------------------------
    println!("\n=== 3. THE REAL BINARY, GIVEN A FLAG IT DOES NOT KNOW ===");
    let real = resolve_claude_bin();
    println!("  binary: {}", real.display());
    // A launcher that execs the real binary with one extra, certainly-unknown flag. This is
    // the honest stand-in for "a future release stopped accepting one of ours": we cannot
    // make today's binary reject `--permission-prompt-tool`, so we make it reject something,
    // through the same code path, and read what comes back.
    let probe = fake(
        "real-bad-flag",
        &format!("exec \"{}\" --richos-flag-that-cannot-exist \"$@\"\n", real.display()),
    );
    let err = NativeCognition::start(&probe, Path::new("/tmp"), &doctrine, &skills)
        .err()
        .map(|e| e.to_string())
        .unwrap_or_else(|| "IT STARTED — the real binary accepted a flag that cannot exist".into());
    println!("  {err}");
    check(&mut cases, &mut failures, err.contains("failed to start"), "the REAL binary's rejection is caught", "not a fake's — this is the actual claude on this machine");
    check(&mut cases, &mut failures, err.contains("unknown option"), "and its own error reaches the operator", "so a flag that moves announces itself");
    let _ = std::fs::remove_dir_all(probe.parent().unwrap());

    // ---- 4. silence --------------------------------------------------------------------
    println!("\n=== 4. A CHILD THAT STARTS AND SAYS NOTHING ===");
    let script = fake("silent", "sleep 0.4\nexit 0\n");
    let began = std::time::Instant::now();
    let err = NativeCognition::start(&script, Path::new("/tmp"), &doctrine, &skills)
        .err()
        .map(|e| e.to_string())
        .unwrap_or_else(|| "IT STARTED — silence was treated as success".into());
    let took = began.elapsed();
    println!("  {err}");
    println!("  returned after {:.0} ms", took.as_secs_f64() * 1000.0);
    check(&mut cases, &mut failures, err.contains("failed to start"), "silence is a failure, not a pass", "a boot that hangs forever is the one thing worse than a refusal");
    check(&mut cases, &mut failures, took.as_secs() < 30, "and it RETURNED — bounded, never indefinite", "HANDSHAKE_TIMEOUT is the ceiling; the child died first");
    let _ = std::fs::remove_dir_all(script.parent().unwrap());

    // ---- 5. a refused handshake --------------------------------------------------------
    println!("\n=== 5. A CHILD THAT ANSWERS THE HANDSHAKE AND REFUSES IT ===");
    let script = fake(
        "refuse",
        "read -r line\n\
         printf '%s\\n' '{\"type\":\"control_response\",\"response\":{\"subtype\":\"error\",\"request_id\":\"req_init\",\"error\":\"nope\"}}'\n\
         sleep 5\n",
    );
    let err = NativeCognition::start(&script, Path::new("/tmp"), &doctrine, &skills)
        .err()
        .map(|e| e.to_string())
        .unwrap_or_else(|| "IT STARTED — a refusal was read as a success".into());
    println!("  {err}");
    check(&mut cases, &mut failures, err.contains("refused"), "a non-success subtype is a refusal", "never a success with a caveat");
    let _ = std::fs::remove_dir_all(script.parent().unwrap());

    // ---- 6. the standing instruction is not on disk -------------------------------------
    println!("\n=== 6. RICHOS'S STANDING INSTRUCTION IS NOT THERE ===");
    // The binary is PRESENT and executable and the working directory EXISTS. The only fault
    // is the doctrine, which is what makes this case mean anything at all.
    let absent = std::env::temp_dir().join("richos-no-such-doctrine-please-do-not-create-me.md");
    let _ = std::fs::remove_file(&absent);
    let err = NativeCognition::start(&real, Path::new("/tmp"), &absent, &skills)
        .err()
        .map(|e| e.to_string())
        .unwrap_or_else(|| "IT STARTED — a Claude with no standing instruction is not Rich".into());
    println!("  {err}");
    check(&mut cases, &mut failures, err.contains(&absent.display().to_string()), "refused, naming the instruction file", "not an exit code, and not the wrong fault");
    check(&mut cases, &mut failures, err.contains("not Rich"), "and says what is at stake", "a generic Claude behind the product's window is the failure this prevents");
    check(&mut cases, &mut failures, !err.contains("binary was not found"), "and it is not reported as a missing binary", "reporting one fault as another sends the reader to the wrong place");

    // ---- 7. a skill RichOS ships is not on disk -----------------------------------------
    println!("\n=== 7. A SKILL RICHOS SHIPS IS NOT THERE ===");
    // The binary would say NOTHING about this: `--plugin-dir` naming a path that is not there
    // exits 0 with a clean handshake and `plugins: []` (cell K4). Everything else about this
    // launch is correct, so the refusal is entirely ours.
    let no_skills = std::env::temp_dir().join("richos-no-such-skills-please-do-not-create-me");
    let _ = std::fs::remove_dir_all(&no_skills);
    let err = NativeCognition::start(&real, Path::new("/tmp"), &doctrine, &no_skills)
        .err()
        .map(|e| e.to_string())
        .unwrap_or_else(|| "IT STARTED — a missing skill was accepted in silence".into());
    println!("  {err}");
    check(&mut cases, &mut failures, err.contains("plugin.json"), "refused, naming the file it looked for", "the binary accepts a missing plugin dir without a word, so this check is the whole of it");
    check(&mut cases, &mut failures, err.contains("without saying so"), "and says why we check rather than the binary", "a fact about the flag, recorded where somebody removing the check will read it");

    // ---- the negative control ----------------------------------------------------------
    println!("\n=== THE NEGATIVE CONTROL: the real binary, the real flags ===");
    let began = std::time::Instant::now();
    match NativeCognition::start(&real, Path::new("/tmp"), &doctrine, &skills) {
        Ok(cog) => {
            let ms = began.elapsed().as_secs_f64() * 1000.0;
            println!("  handshake OK in {ms:.1} ms, session = {}", richos_core::Cognition::session_id(&cog));
            check(&mut cases, &mut failures, true, "the five failures above fail for the RIGHT reason", "this machine's claude answers the handshake with our real arg vector");
        }
        Err(e) => {
            println!("  {e}");
            check(&mut cases, &mut failures, false, "the five failures above fail for the RIGHT reason", "the control did not pass, so nothing above is evidence");
        }
    }

    println!("\n{cases} checks, {failures} failed.");
    if failures > 0 {
        eprintln!("[failure-modes] SOMETHING FAILED");
        std::process::exit(1);
    }
    println!("[failure-modes] ALL CHECKS PASS — every failure is loud, named and bounded.");
}

fn check(cases: &mut usize, failures: &mut usize, ok: bool, claim: &str, why: &str) {
    *cases += 1;
    if !ok {
        *failures += 1;
    }
    println!("  {} {claim:<52} {why}", if ok { "PASS" } else { "FAIL" });
}

/// A fake `claude` on disk, executable, with its own shebang — `NativeClient::spawn` takes a
/// binary and a cwd, not an argv, so it must be runnable on its own.
fn fake(name: &str, body: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("richos-failmode-{name}-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("claude");
    std::fs::write(&path, format!("#!/bin/sh\n{body}")).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    path
}
