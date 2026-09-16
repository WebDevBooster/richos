//! A child process group whose identity remains reserved until teardown.
//! Never reap the leader before stopping descendants: a reaped PID can be reused.
use std::io;
use std::process::{Child, Command, ExitStatus};
use std::sync::{Arc, Mutex};

#[derive(Clone)]
pub struct ProcessFence(Arc<Mutex<Option<u32>>>);
impl ProcessFence {
    pub fn kill(&self) {
        if let Some(pid) = *self.0.lock().unwrap() {
            #[cfg(unix)] unsafe { libc::kill(-(pid as libc::pid_t), libc::SIGKILL); }
            #[cfg(not(unix))] { let _ = pid; }
        }
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
        Self { fence: ProcessFence(Arc::new(Mutex::new(Some(child.id())))), child, status: None }
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
        let mut identity = self.fence.0.lock().unwrap();
        if let Some(pid) = *identity {
            #[cfg(unix)] unsafe { libc::kill(-(pid as libc::pid_t), libc::SIGKILL); }
            #[cfg(not(unix))] { let _ = pid; }
        }
        let status = self.child.wait()?;
        *identity = None;
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
            if result.is_some() { *self.fence.0.lock().unwrap() = None; self.status = result; }
            Ok(result)
        }
    }
}
impl Drop for OwnedChild {
    fn drop(&mut self) { let _ = self.kill(); let _ = self.wait(); }
}
