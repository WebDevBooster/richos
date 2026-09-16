#![cfg(unix)]
use richos_core::owned_process::OwnedChild;
use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

fn fixture(exit_leader: bool) -> (OwnedChild, i32) {
    let mut command = Command::new("/bin/sh");
    command.arg("-c").arg(if exit_leader { "sleep 60 & echo $!; exit 0" } else { "sleep 60 & echo $!; wait" })
        .stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
    OwnedChild::configure(&mut command);
    let mut child = command.spawn().unwrap();
    let mut pid = String::new();
    BufReader::new(child.stdout.take().unwrap()).read_line(&mut pid).unwrap();
    (OwnedChild::new(child), pid.trim().parse().unwrap())
}
fn assert_gone(pid: i32) {
    let deadline = Instant::now() + Duration::from_secs(3);
    while unsafe { libc::kill(pid, 0) } == 0 {
        assert!(Instant::now() < deadline, "owned descendant survived teardown");
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn dropping_a_lease_stops_its_descendants_and_preserves_an_unrelated_process() {
    let (child, descendant) = fixture(false);
    let (mut unrelated, _) = fixture(false);
    let retained_handle = child.fence();
    drop(child);
    assert_gone(descendant);
    retained_handle.kill(); // An obsolete Stop handle is disarmed after reaping.
    assert!(unrelated.try_wait().unwrap().is_none());
}

#[test]
fn a_leader_exit_still_retires_descendants_before_releasing_its_identity() {
    let (mut child, descendant) = fixture(true);
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        if let Some(status) = child.try_wait().unwrap() { assert!(status.success()); break; }
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_gone(descendant);
}
