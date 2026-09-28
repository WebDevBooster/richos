//! A child process group whose identity remains reserved until teardown.
//! Never reap the leader before stopping descendants: a reaped PID can be reused.
//!
//! **Two kinds of fence** (richos-hq `docs/plans/2026-09-27-product-reap-gap-design.md`, C1, C2).
//! [`OwnedChild::new`] is the original: every teardown is `kill(-pid, SIGKILL)` to the whole
//! group at once. It stays exactly that for every caller that is not a provider lease: the
//! `claude` login, the quota probe, the reset transport, the operator declaration and runtime
//! checks.
//!
//! [`OwnedChild::supervised`] is for a leader that is `provider-supervisor.py
//! --reap-descendants`, which reaps the provider's tool shells (their own sessions and groups,
//! out of this group's reach) when it gets SIGTERM. A SIGKILL cannot be caught, so the old
//! fence ended the supervisor before its reap began and every tool command a lease started
//! outlived Quit, Stop, rotation and a forced-down lease (C1). This fence sends SIGTERM to the
//! LEADER ONLY, which is safe because the leader is unreaped and its pid cannot have been
//! reused, and escalates to the old group SIGKILL only if the leader is still running after
//! [`SUPERVISED_BOUND`]. The escalation is decided under the fence's lock and only while it
//! still holds the pid, so once the leader has been reaped no signal can ever be sent again.
use std::io;
use std::process::{Child, Command, ExitStatus};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant};

/// How long a supervisor gets after SIGTERM before its whole group is SIGKILLed (design
/// 1.3(b), `estimate: 2 s`). Its reap at `--reap-grace=0` measured 0.058-0.080 s from SIGTERM
/// to a dead tree (engine R10, five runs), so the bound is only ever reached by a wedged one.
pub const SUPERVISED_BOUND: Duration = Duration::from_secs(2);

struct Identity {
    /// The unreaped leader. `None` once reaped: nothing may be signaled after that.
    pid: Option<u32>,
    /// `Some(bound)` for a leader that reaps its own tree on SIGTERM.
    supervised: Option<Duration>,
    /// Whether a SIGTERM has gone and its escalation is scheduled, so it is scheduled once.
    terminating: bool,
}

#[derive(Clone)]
pub struct ProcessFence(Arc<Mutex<Identity>>);

impl ProcessFence {
    pub fn kill(&self) {
        let mut identity = self.0.lock().unwrap();
        let Some(pid) = identity.pid else { return };
        let Some(bound) = identity.supervised else {
            group_kill(pid);
            return;
        };
        terminate_leader(pid);
        if !identity.terminating {
            identity.terminating = true;
            let fence = Arc::downgrade(&self.0);
            std::thread::spawn(move || {
                std::thread::sleep(bound);
                if let Some(fence) = fence.upgrade() {
                    escalate(&fence);
                }
            });
        }
    }
}

/// The group SIGKILL, decided under the lock: only while the leader is unreaped AND still
/// running. A leader that has exited has already ended its own group (the supervisor's
/// `finally`), and one that has been reaped no longer reserves the id.
fn escalate(fence: &Mutex<Identity>) -> bool {
    let identity = fence.lock().unwrap();
    match identity.pid {
        Some(pid) if leader_running(pid) => {
            group_kill(pid);
            true
        }
        _ => false,
    }
}

/// SIGTERM to the leader alone, never the group: the supervisor's cue to reap.
fn terminate_leader(pid: u32) {
    #[cfg(unix)]
    unsafe {
        libc::kill(pid as libc::pid_t, libc::SIGTERM);
    }
    #[cfg(not(unix))]
    {
        let _ = pid;
    }
}

fn group_kill(pid: u32) {
    #[cfg(unix)]
    unsafe {
        libc::kill(-(pid as libc::pid_t), libc::SIGKILL);
    }
    #[cfg(not(unix))]
    {
        let _ = pid;
    }
}

/// Whether our unreaped child `pid` has not exited yet — `waitid(WNOWAIT)`, which reads the
/// state without reaping it. An error answers "running", so the caller keeps today's group
/// kill rather than trusting a reading it could not take.
fn leader_running(pid: u32) -> bool {
    #[cfg(unix)]
    {
        let mut information: libc::siginfo_t = unsafe { std::mem::zeroed() };
        let result = unsafe {
            libc::waitid(libc::P_PID, pid as libc::id_t, &mut information, libc::WEXITED | libc::WNOHANG | libc::WNOWAIT)
        };
        result != 0 || unsafe { information.si_pid() } == 0
    }
    #[cfg(not(unix))]
    {
        let _ = pid;
        false
    }
}

/// Every supervised fence in this process, weakly, so the quit path can end them all within
/// ONE bound ([`SupervisedSet::settle`], design 1.3(c)). A set rather than a bare static so a
/// test holds its own and never signals another test's children.
pub struct SupervisedSet(Mutex<Vec<Weak<Mutex<Identity>>>>);

static PROCESS_SUPERVISED: SupervisedSet = SupervisedSet(Mutex::new(Vec::new()));

/// What [`SupervisedSet::settle`] did, for the quit path's log line.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct Settled {
    /// Supervisors that were still unreaped when the quit began.
    pub leases: usize,
    /// Of those, the ones still running at the deadline, whose group was SIGKILLed.
    pub escalated: usize,
}

impl SupervisedSet {
    pub const fn new() -> Self {
        SupervisedSet(Mutex::new(Vec::new()))
    }

    /// The set every [`OwnedChild::supervised`] in this process joins.
    pub fn process() -> &'static SupervisedSet {
        &PROCESS_SUPERVISED
    }

    fn join(&self, fence: &Arc<Mutex<Identity>>) {
        let mut all = self.0.lock().unwrap();
        all.retain(|weak| weak.strong_count() > 0);
        all.push(Arc::downgrade(fence));
    }

    /// **The quit path's bound.** SIGTERM to every supervisor still unreaped, then wait until
    /// each has exited or `deadline` passes, then the group SIGKILL for any still running.
    /// Nothing here outlives the call, so it does not depend on an escalation thread
    /// surviving a process that is ending (`main.rs`'s Exit arm, where destructors are not
    /// guaranteed). If the process ends first, each supervisor's owner-death trigger reaps.
    pub fn settle(&self, deadline: Instant) -> Settled {
        let fences: Vec<Arc<Mutex<Identity>>> = self.0.lock().unwrap().iter().filter_map(Weak::upgrade).collect();
        let mut live = Vec::new();
        for fence in &fences {
            let mut identity = fence.lock().unwrap();
            if let Some(pid) = identity.pid {
                terminate_leader(pid);
                identity.terminating = true;
                live.push(Arc::clone(fence));
            }
        }
        let mut settled = Settled { leases: live.len(), escalated: 0 };
        loop {
            live.retain(|fence| matches!(fence.lock().unwrap().pid, Some(pid) if leader_running(pid)));
            if live.is_empty() {
                return settled;
            }
            if Instant::now() >= deadline {
                settled.escalated = live.iter().filter(|fence| escalate(fence)).count();
                return settled;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}

impl Default for SupervisedSet {
    fn default() -> Self {
        Self::new()
    }
}

pub struct OwnedChild {
    child: Child,
    fence: ProcessFence,
    status: Option<ExitStatus>,
}

impl OwnedChild {
    pub fn configure(command: &mut Command) {
        #[cfg(unix)] {
            use std::os::unix::process::CommandExt;
            command.process_group(0);
        }
    }
    /// The caller must use `configure` before spawning and must not reap `child`.
    pub fn new(child: Child) -> Self {
        Self::with(child, None)
    }
    /// **A provider lease whose leader is `provider-supervisor.py --reap-descendants`**: SIGTERM
    /// to the leader first, the group SIGKILL only after [`SUPERVISED_BOUND`] (module doc). The
    /// caller must use `configure` before spawning and must not reap `child`.
    pub fn supervised(child: Child) -> Self {
        Self::supervised_in(child, SUPERVISED_BOUND, SupervisedSet::process())
    }
    /// [`Self::supervised`] with its bound and its set named, for a test that must not wait two
    /// seconds or share the process's set.
    pub fn supervised_in(child: Child, bound: Duration, set: &SupervisedSet) -> Self {
        let owned = Self::with(child, Some(bound));
        set.join(&owned.fence.0);
        owned
    }
    fn with(child: Child, supervised: Option<Duration>) -> Self {
        let identity = Identity { pid: Some(child.id()), supervised, terminating: false };
        Self { fence: ProcessFence(Arc::new(Mutex::new(identity))), child, status: None }
    }
    pub fn fence(&self) -> ProcessFence { self.fence.clone() }
    pub fn kill(&mut self) -> io::Result<()> {
        self.fence.kill();
        #[cfg(not(unix))] { return self.child.kill(); }
        #[cfg(unix)] { Ok(()) }
    }
    pub fn wait(&mut self) -> io::Result<ExitStatus> {
        if let Some(status) = self.status { return Ok(status); }
        // Fence all descendants while the unreaped leader still reserves the PID.
        let supervised = {
            let mut identity = self.fence.0.lock().unwrap();
            match (identity.pid, identity.supervised) {
                (Some(pid), None) => { group_kill(pid); None }
                (Some(pid), Some(bound)) => {
                    terminate_leader(pid);
                    identity.terminating = true;
                    Some((pid, bound))
                }
                (None, _) => None,
            }
        };
        // The lock is not held while the supervisor reaps, so a Stop pressed meanwhile is not
        // made to wait. Only this `&mut self` can reap, so the pid stays reserved throughout.
        if let Some((pid, bound)) = supervised {
            let deadline = Instant::now() + bound;
            while leader_running(pid) {
                if Instant::now() >= deadline {
                    escalate(&self.fence.0);
                    break;
                }
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        let mut identity = self.fence.0.lock().unwrap();
        let status = self.child.wait()?;
        identity.pid = None;
        self.status = Some(status);
        Ok(status)
    }
    pub fn try_wait(&mut self) -> io::Result<Option<ExitStatus>> {
        if self.status.is_some() { return Ok(self.status); }
        #[cfg(unix)] {
            let mut information: libc::siginfo_t = unsafe { std::mem::zeroed() };
            let result = unsafe { libc::waitid(libc::P_PID, self.child.id(), &mut information,
                libc::WEXITED | libc::WNOHANG | libc::WNOWAIT) };
            if result != 0 { return Err(io::Error::last_os_error()); }
            if unsafe { information.si_pid() } == 0 { return Ok(None); }
            return self.wait().map(Some);
        }
        #[cfg(not(unix))] {
            let result = self.child.try_wait()?;
            if result.is_some() { self.fence.0.lock().unwrap().pid = None; self.status = result; }
            Ok(result)
        }
    }
}
impl Drop for OwnedChild {
    fn drop(&mut self) { let _ = self.kill(); let _ = self.wait(); }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::path::{Path, PathBuf};

    /// A fake leader in its own group with one same-group child (`sleep 30`) whose pid it
    /// writes to `receipt`. `honors`: SIGTERM ends the leader, as the supervisor's reap does,
    /// and leaves the child for the group kill to find, which is how a test SEES whether one
    /// was sent. Otherwise SIGTERM is ignored, as by a wedged supervisor.
    fn leader(receipt: &Path, honors: bool) -> Child {
        let script = if honors {
            "sleep 30 & echo $! > \"$0\"; trap 'exit 0' TERM; while :; do sleep 0.02; done"
        } else {
            "trap '' TERM; sleep 30 & echo $! > \"$0\"; while :; do sleep 0.02; done"
        };
        let mut command = Command::new("/bin/sh");
        command.arg("-c").arg(script).arg(receipt);
        OwnedChild::configure(&mut command);
        let mut child = command.spawn().unwrap();
        for _ in 0..200 {
            if std::fs::read_to_string(receipt).map(|s| s.trim().parse::<i32>().is_ok()).unwrap_or(false) {
                return child;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        // The fixture failed: end the group it started (captured at spawn) and reap its leader,
        // so a failed test leaves nothing running.
        group_kill(child.id());
        child.wait().ok();
        panic!("fixture: the fake leader never wrote its child's pid");
    }

    fn child_pid(receipt: &Path) -> libc::pid_t {
        std::fs::read_to_string(receipt).unwrap().trim().parse().unwrap()
    }

    fn alive(pid: libc::pid_t) -> bool {
        unsafe { libc::kill(pid, 0) == 0 }
    }

    /// Dead within `within`. A killed child is briefly a zombie that `kill(pid, 0)` still
    /// answers for, until launchd reaps it, so this polls.
    fn dies_within(pid: libc::pid_t, within: Duration) -> bool {
        let deadline = Instant::now() + within;
        while Instant::now() < deadline {
            if !alive(pid) {
                return true;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        false
    }

    /// The test's own `sleep 30`, pid captured from the receipt it wrote.
    fn clean_up(pid: libc::pid_t) {
        unsafe { libc::kill(pid, libc::SIGKILL); }
    }

    fn receipt(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("richos-owned-process-{}-{name}", std::process::id()));
        std::fs::remove_dir_all(&dir).ok();
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("child.pid")
    }

    const BOUND: Duration = Duration::from_millis(400);

    #[test]
    fn a_supervised_fence_sends_sigterm_first_and_an_honoring_leader_ends_with_no_group_kill() {
        let path = receipt("honors");
        let set = SupervisedSet::new();
        let mut owned = OwnedChild::supervised_in(leader(&path, true), BOUND, &set);
        let sleeper = child_pid(&path);
        let started = Instant::now();
        owned.kill().unwrap();
        owned.wait().unwrap();
        let took = started.elapsed();
        assert!(took < BOUND, "the honoring leader was held to the bound: {took:?}");
        assert!(alive(sleeper), "a group SIGKILL was sent to a leader that ended on SIGTERM");
        // NO SIGNAL AFTER THE REAP: the escalation `kill()` scheduled runs after the bound
        // and must find the fence empty.
        std::thread::sleep(BOUND + Duration::from_millis(200));
        assert!(alive(sleeper), "the escalation fired after the leader had been reaped");
        owned.fence().kill();
        assert!(alive(sleeper), "the fence signaled after the reap");
        clean_up(sleeper);
        std::fs::remove_dir_all(path.parent().unwrap()).ok();
    }

    #[test]
    fn a_supervised_leader_that_ignores_sigterm_has_its_group_killed_after_the_bound() {
        let path = receipt("ignores");
        let set = SupervisedSet::new();
        let mut owned = OwnedChild::supervised_in(leader(&path, false), BOUND, &set);
        let sleeper = child_pid(&path);
        let started = Instant::now();
        owned.kill().unwrap();
        owned.wait().unwrap();
        let took = started.elapsed();
        assert!(took >= BOUND, "the group was killed before the bound: {took:?}");
        assert!(took < BOUND + Duration::from_secs(1), "the wait overran its bound: {took:?}");
        assert!(dies_within(sleeper, Duration::from_secs(1)), "the group outlived the escalation");
        std::fs::remove_dir_all(path.parent().unwrap()).ok();
    }

    #[test]
    fn the_escalation_fires_from_kill_alone_when_nobody_waits() {
        // The Stop path: `NativeCancelHandle::cancel` calls the fence and returns.
        let path = receipt("escalates");
        let set = SupervisedSet::new();
        let mut owned = OwnedChild::supervised_in(leader(&path, false), BOUND, &set);
        let sleeper = child_pid(&path);
        owned.fence().kill();
        std::thread::sleep(BOUND / 2);
        assert!(alive(sleeper), "the group was killed before the bound");
        assert!(dies_within(sleeper, BOUND + Duration::from_secs(1)), "no escalation followed the bound");
        owned.wait().unwrap();
        std::fs::remove_dir_all(path.parent().unwrap()).ok();
    }

    #[test]
    fn every_other_owned_child_still_kills_its_group_at_once() {
        // C2, the negative control: login, quota probe, reset transport, operator checks.
        let path = receipt("unsupervised");
        let mut owned = OwnedChild::new(leader(&path, true));
        let sleeper = child_pid(&path);
        let started = Instant::now();
        owned.kill().unwrap();
        assert!(dies_within(sleeper, Duration::from_millis(300)), "the unsupervised fence no longer kills the group");
        owned.wait().unwrap();
        assert!(started.elapsed() < Duration::from_secs(1));
        std::fs::remove_dir_all(path.parent().unwrap()).ok();
    }

    #[test]
    fn settling_the_set_ends_every_supervisor_within_one_deadline() {
        let (honors, ignores) = (receipt("settle-honors"), receipt("settle-ignores"));
        let set = SupervisedSet::new();
        // A long bound on the fences themselves: only the settle's deadline may escalate.
        let mut first = OwnedChild::supervised_in(leader(&honors, true), Duration::from_secs(60), &set);
        let mut second = OwnedChild::supervised_in(leader(&ignores, false), Duration::from_secs(60), &set);
        let (kept, killed) = (child_pid(&honors), child_pid(&ignores));
        let started = Instant::now();
        let settled = set.settle(Instant::now() + BOUND);
        assert!(started.elapsed() < BOUND + Duration::from_millis(500), "the settle overran its deadline");
        assert_eq!(settled, Settled { leases: 2, escalated: 1 });
        assert!(alive(kept), "the honoring supervisor's group was killed");
        assert!(dies_within(killed, Duration::from_secs(1)), "the wedged supervisor's group outlived the deadline");
        first.wait().unwrap();
        second.wait().unwrap();
        // Reaped fences are skipped by a later settle, so nothing is signaled twice.
        assert_eq!(set.settle(Instant::now()), Settled { leases: 0, escalated: 0 });
        clean_up(kept);
        std::fs::remove_dir_all(honors.parent().unwrap()).ok();
        std::fs::remove_dir_all(ignores.parent().unwrap()).ok();
    }
}
