//! Password-free macOS application publication.
//!
//! Only pass bytes returned by the signature-verifying updater download. This module
//! never runs an installer, shell or authorization API. Its user-owned journal provides
//! crash recovery, not isolation from a hostile process with the same filesystem rights.
//! The workspace supervisor must deny agents access to this application namespace.

#![cfg(unix)]
use flate2::read::GzDecoder;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeSet,
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    os::unix::{
        fs::{symlink, MetadataExt, OpenOptionsExt, PermissionsExt},
        io::AsRawFd,
    },
    path::{Component, Path, PathBuf},
};

const APP: &str = "RichOS.app";
const ID: &str = "com.richos.app";
const MAX_BYTES: u64 = 8 * 1024 * 1024 * 1024;
const MAX_ENTRIES: usize = 200_000;
fn refuse(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}
fn uid() -> u32 {
    unsafe { libc::geteuid() }
}
fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
#[cfg(test)]
thread_local! { static SYNC_TRACE: std::cell::RefCell<Vec<PathBuf>> = const { std::cell::RefCell::new(Vec::new()) }; }
fn sync(path: &Path) -> io::Result<()> {
    File::open(path)?.sync_all()?;
    #[cfg(test)]
    SYNC_TRACE.with(|trace| trace.borrow_mut().push(path.to_owned()));
    Ok(())
}
fn metadata(path: &Path) -> io::Result<fs::Metadata> {
    fs::symlink_metadata(path)
}
#[cfg(target_os = "macos")]
fn no_write_acl(path: &Path) -> io::Result<()> {
    use std::ffi::c_void;
    extern "C" {
        fn acl_get_fd_np(fd: i32, kind: i32) -> *mut c_void;
        fn acl_valid(acl: *mut c_void) -> i32;
        fn acl_get_entry(acl: *mut c_void, which: i32, entry: *mut *mut c_void) -> i32;
        fn acl_get_tag_type(entry: *mut c_void, tag: *mut i32) -> i32;
        fn acl_get_permset_mask_np(entry: *mut c_void, mask: *mut u64) -> i32;
        fn acl_free(acl: *mut c_void) -> i32;
    }
    struct Acl(*mut c_void);
    impl Drop for Acl {
        fn drop(&mut self) {
            unsafe {
                acl_free(self.0);
            }
        }
    }
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    let raw = unsafe { acl_get_fd_np(file.as_raw_fd(), 0x100) };
    if raw.is_null() {
        let error = io::Error::last_os_error();
        // Darwin reports ENOENT for a valid object with no extended ACL.
        if error.raw_os_error() == Some(libc::ENOENT) {
            return Ok(());
        }
        return Err(error);
    }
    let acl = Acl(raw);
    if unsafe { acl_valid(acl.0) } != 0 {
        return Err(refuse("invalid application access control list"));
    }
    let mut which = 0;
    for _ in 0..1024 {
        let mut entry = std::ptr::null_mut();
        let rc = unsafe { acl_get_entry(acl.0, which, &mut entry) };
        if rc != 0 {
            if rc == -1 && io::Error::last_os_error().raw_os_error() == Some(libc::EINVAL) {
                return Ok(());
            }
            return Err(refuse("cannot inspect application access control list"));
        }
        which = -1;
        let mut tag = 0;
        let mut mask = 0;
        if unsafe { acl_get_tag_type(entry, &mut tag) } != 0
            || unsafe { acl_get_permset_mask_np(entry, &mut mask) } != 0
        {
            return Err(refuse("cannot inspect application ACL entry"));
        }
        let write_bits = (1 << 2)
            | (1 << 4)
            | (1 << 5)
            | (1 << 6)
            | (1 << 8)
            | (1 << 10)
            | (1 << 12)
            | (1 << 13);
        if !matches!(tag, 1 | 2) || (tag == 1 && mask & write_bits != 0) {
            return Err(refuse("application namespace has an ACL write grant"));
        }
    }
    Err(refuse("application access control list is too large"))
}
#[cfg(not(target_os = "macos"))]
fn no_write_acl(_path: &Path) -> io::Result<()> {
    Ok(())
}

fn owned_dir(path: &Path) -> io::Result<()> {
    let m = metadata(path)?;
    if !m.is_dir() || m.uid() != uid() || m.mode() & 0o022 != 0 {
        return Err(refuse("application directory is not private to its owner"));
    }
    no_write_acl(path)
}
fn ensure_dir(path: &Path, mode: u32) -> io::Result<()> {
    match fs::create_dir(path) {
        Ok(()) => fs::set_permissions(path, fs::Permissions::from_mode(mode))?,
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
        Err(e) => return Err(e),
    }
    owned_dir(path)
}
fn root(home: &Path) -> io::Result<PathBuf> {
    if uid() == 0 {
        return Err(refuse("RichOS user updates must not run as root"));
    }
    // A home supplied by the platform resolver must itself be an absolute real path.
    if !home.is_absolute() || home.canonicalize()? != home {
        return Err(refuse("home is not a canonical directory"));
    }
    for ancestor in home.ancestors().skip(1) {
        let m = metadata(ancestor)?;
        let root_sticky = m.uid() == 0 && m.mode() & 0o1000 != 0;
        if !m.is_dir()
            || (m.uid() != 0 && m.uid() != uid())
            || (m.mode() & 0o022 != 0 && !root_sticky)
        {
            return Err(refuse("home has an unsafe ancestor"));
        }
        no_write_acl(ancestor)?;
    }
    owned_dir(home)?;
    let applications = home.join("Applications");
    ensure_dir(&applications, 0o755)?;
    let root = applications.join(".richos-updater");
    ensure_dir(&root, 0o700)?;
    if metadata(&root)?.mode() & 0o077 != 0 {
        return Err(refuse("update journal directory is not private"));
    }
    Ok(root)
}
struct Lock(File);
impl Lock {
    fn acquire_startup(root: &Path) -> io::Result<Self> {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            match Self::acquire(root) {
                Err(e)
                    if e.kind() == io::ErrorKind::WouldBlock
                        && std::time::Instant::now() < deadline =>
                {
                    std::thread::sleep(std::time::Duration::from_millis(20))
                }
                result => return result,
            }
        }
    }
    fn acquire(root: &Path) -> io::Result<Self> {
        Self::named(root, "lock")
    }
    fn named(root: &Path, name: &str) -> io::Result<Self> {
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(root.join(name))?;
        let m = file.metadata()?;
        if !m.is_file() || m.uid() != uid() || m.nlink() != 1 || m.mode() & 0o077 != 0 {
            return Err(refuse("invalid update lock"));
        }
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self(file))
    }
}
impl Drop for Lock {
    fn drop(&mut self) {
        unsafe {
            libc::flock(self.0.as_raw_fd(), libc::LOCK_UN);
        }
    }
}

/// Session exclusion is separate from short publication serialization. Every participating
/// app holds a shared lease for its whole runtime; startup activation requires exclusive.
pub struct StartupLease {
    file: File,
    home: PathBuf,
    exclusive: bool,
    valid: bool,
}
impl StartupLease {
    pub fn acquire(home: &Path) -> io::Result<Self> {
        let root = root(home)?;
        let _publication = Lock::acquire_startup(&root)?;
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(root.join("session.lock"))?;
        validate_lease_file(&file, &root)?;
        let exclusive =
            if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
                true
            } else {
                let error = io::Error::last_os_error();
                if error.kind() != io::ErrorKind::WouldBlock {
                    return Err(error);
                }
                if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_SH | libc::LOCK_NB) } != 0 {
                    return Err(io::Error::last_os_error());
                }
                false
            };
        Ok(Self {
            file,
            home: home.to_owned(),
            exclusive,
            valid: true,
        })
    }
    /// Adopt only the exact inherited session file and retain shared runtime exclusion.
    /// An environment descriptor number is a hint, never evidence of a held lease.
    pub fn adopt(home: &Path, fd: i32) -> io::Result<Self> {
        use std::os::unix::io::FromRawFd;
        if fd < 3 {
            return Err(refuse("invalid inherited session descriptor"));
        }
        // Set close-on-exec on the inherited descriptor immediately, before any child
        // could be launched. Duplicate it so validation failure does not take ownership
        // of an unrelated caller descriptor.
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
        if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC) } < 0 {
            return Err(io::Error::last_os_error());
        }
        let copy = unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, 3) };
        if copy < 0 {
            return Err(io::Error::last_os_error());
        }
        let file = unsafe { File::from_raw_fd(copy) };
        let root = root(home)?;
        validate_lease_file(&file, &root)?;
        let _publication = Lock::acquire_startup(&root)?;
        // Redirected children only retain SH. Never probe EX on an inherited SH
        // description: BSD conversion can drop protection while trying to upgrade.
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_SH | libc::LOCK_NB) } != 0 {
            return Err(io::Error::last_os_error());
        }
        let exclusive = false;
        unsafe {
            libc::close(fd);
        }
        Ok(Self {
            file,
            home: home.to_owned(),
            exclusive,
            valid: true,
        })
    }
    pub fn can_activate(&self) -> bool {
        self.valid && self.exclusive
    }
    pub fn session_fd(&self) -> i32 {
        self.file.as_raw_fd()
    }
    /// Call immediately before the normal app runtime. Keep this object alive until exit.
    /// Failure is a startup refusal, never permission to run without session exclusion.
    pub fn begin_session(&mut self) -> io::Result<()> {
        if !self.valid {
            return Err(refuse("session lease is no longer held"));
        }
        let root = root(&self.home)?;
        validate_lease_file(&self.file, &root)?;
        if !self.exclusive {
            return Ok(());
        }
        // BSD flock conversion is not assumed atomic. Publication exclusion prevents a
        // competing startup from changing the bundle during the EX-to-SH transition.
        let _publication = Lock::acquire_startup(&root)?;
        self.exclusive = false;
        if unsafe { libc::flock(self.session_fd(), libc::LOCK_SH | libc::LOCK_NB) } != 0 {
            self.valid = false;
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }
    /// Replace the startup image while carrying its session lease across exec. Call only
    /// before runtime threads or user input exist. The caller supplies the exact verified
    /// executable and exports session_fd() as the internal adoption hint.
    pub fn exec(&mut self, command: &mut std::process::Command) -> io::Error {
        use std::os::unix::process::CommandExt;
        if !self.valid {
            return refuse("cannot transfer a released session lease");
        }
        let fd = self.session_fd();
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
        if flags < 0 {
            return io::Error::last_os_error();
        }
        unsafe {
            command.pre_exec(move || {
                if libc::fcntl(fd, libc::F_SETFD, flags & !libc::FD_CLOEXEC) < 0 {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let error = command.exec();
        if unsafe { libc::fcntl(fd, libc::F_SETFD, flags) } < 0 {
            self.valid = false;
            return io::Error::last_os_error();
        }
        error
    }
}
// Dropping File releases the descriptor. Do not explicitly LOCK_UN: an exec-transfer
// duplicate may share this open-file description and must keep exclusion alive.
fn validate_lease_file(file: &File, root: &Path) -> io::Result<()> {
    let path = root.join("session.lock");
    let m = file.metadata()?;
    let named = metadata(&path)?;
    if !m.is_file()
        || !named.is_file()
        || m.uid() != uid()
        || m.nlink() != 1
        || m.mode() & 0o077 != 0
        || m.dev() != named.dev()
        || m.ino() != named.ino()
    {
        return Err(refuse(
            "session descriptor does not match the owner-private lease",
        ));
    }
    no_write_acl(&path)
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Published {
    pub version: String,
    pub archive_sha256: String,
    pub tree_sha256: String,
    pub executable_name: String,
}
impl Published {
    pub fn is_newer_than(&self, version: &str) -> io::Result<bool> {
        let this = semver::Version::parse(&self.version)
            .map_err(|_| refuse("invalid published version"))?;
        let other =
            semver::Version::parse(version).map_err(|_| refuse("invalid running version"))?;
        Ok(this > other)
    }
    pub fn executable(&self, home: &Path) -> PathBuf {
        home.join("Applications")
            .join(APP)
            .join("Contents/MacOS")
            .join(&self.executable_name)
    }
    fn valid(&self) -> io::Result<()> {
        for hash in [&self.archive_sha256, &self.tree_sha256] {
            if hash.len() != 64
                || !hash
                    .bytes()
                    .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
            {
                return Err(refuse("invalid update receipt hash"));
            }
        }
        if semver::Version::parse(&self.version).is_err() || !single_name(&self.executable_name) {
            return Err(refuse("invalid update receipt identity"));
        }
        Ok(())
    }
}
fn single_name(s: &str) -> bool {
    !s.is_empty()
        && Path::new(s).components().count() == 1
        && matches!(Path::new(s).components().next(), Some(Component::Normal(_)))
}
fn read_document<T: serde::de::DeserializeOwned>(path: &Path) -> io::Result<T> {
    let mut f = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    let m = f.metadata()?;
    if !m.is_file()
        || m.uid() != uid()
        || m.nlink() != 1
        || m.mode() & 0o077 != 0
        || m.len() > 16_384
    {
        return Err(refuse("invalid update receipt file"));
    }
    let mut bytes = Vec::new();
    f.read_to_end(&mut bytes)?;
    serde_json::from_slice(&bytes).map_err(|e| refuse(e.to_string()))
}
fn read_json(path: &Path) -> io::Result<Published> {
    let p: Published = read_document(path)?;
    p.valid()?;
    Ok(p)
}
fn write_json(root: &Path, name: &str, p: &Published) -> io::Result<()> {
    write_document(root, name, p)
}
fn write_document<T: Serialize>(root: &Path, name: &str, p: &T) -> io::Result<()> {
    let tmp = root.join(format!("{name}.new"));
    // This fixed temporary file is only reused under the lock after validating its shape.
    if let Ok(m) = metadata(&tmp) {
        if !m.is_file() || m.uid() != uid() || m.nlink() != 1 {
            return Err(refuse("invalid receipt temporary file"));
        }
        fs::remove_file(&tmp)?;
    }
    let mut f = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&tmp)?;
    f.write_all(&serde_json::to_vec(p).map_err(|e| refuse(e.to_string()))?)?;
    f.sync_all()?;
    fs::rename(tmp, root.join(name))?;
    sync(root)
}
fn relative(path: &Path) -> io::Result<PathBuf> {
    if path.components().count() > 128 {
        return Err(refuse("archive path is too deep"));
    }
    let mut parts = path.components();
    if parts.next() != Some(Component::Normal(APP.as_ref())) {
        return Err(refuse("archive must have exactly one RichOS.app root"));
    }
    let mut out = PathBuf::new();
    for part in parts {
        match part {
            Component::Normal(s) => out.push(s),
            _ => return Err(refuse("archive path escapes application")),
        }
    }
    Ok(out)
}
fn parents(base: &Path, rel: &Path) -> io::Result<()> {
    let mut path = base.to_owned();
    if let Some(parent) = rel.parent() {
        for component in parent.components() {
            path.push(component.as_os_str());
            ensure_dir(&path, 0o755)?;
        }
    }
    Ok(())
}
fn safe_link(rel: &Path, target: &Path) -> io::Result<()> {
    let mut depth = rel.parent().map_or(0, |p| p.components().count());
    for c in target.components() {
        match c {
            Component::Normal(_) => depth += 1,
            Component::CurDir => {}
            Component::ParentDir if depth > 0 => depth -= 1,
            _ => return Err(refuse("archive link escapes application")),
        }
    }
    Ok(())
}
fn extract(bytes: &[u8], app: &Path) -> io::Result<()> {
    ensure_dir(app, 0o755)?;
    let mut archive = tar::Archive::new(GzDecoder::new(bytes));
    let mut seen = BTreeSet::new();
    let mut links = Vec::new();
    let mut total = 0u64;
    for entry in archive.entries()? {
        let mut entry = entry?;
        let rel = relative(&entry.path()?)?;
        if !seen.insert(rel.clone()) || seen.len() > MAX_ENTRIES {
            return Err(refuse("duplicate or excessive archive entries"));
        }
        let kind = entry.header().entry_type();
        if rel.as_os_str().is_empty() {
            if !kind.is_dir() {
                return Err(refuse("invalid app root"));
            }
            continue;
        }
        parents(app, &rel)?;
        let dest = app.join(&rel);
        if kind.is_dir() {
            ensure_dir(&dest, 0o755)?;
        } else if kind.is_file() {
            total = total
                .checked_add(entry.size())
                .ok_or_else(|| refuse("archive size overflow"))?;
            if total > MAX_BYTES {
                return Err(refuse("archive is too large"));
            }
            let mode = if entry.header().mode()? & 0o111 != 0 {
                0o755
            } else {
                0o644
            };
            let mut out = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(mode)
                .custom_flags(libc::O_NOFOLLOW)
                .open(&dest)?;
            io::copy(&mut entry, &mut out)?;
            out.sync_all()?;
            fs::set_permissions(&dest, fs::Permissions::from_mode(mode))?;
        } else if kind.is_symlink() {
            let target = entry
                .link_name()?
                .ok_or_else(|| refuse("missing link target"))?
                .into_owned();
            safe_link(&rel, &target)?;
            links.push((rel, target));
        } else {
            return Err(refuse("unsupported archive entry (including hard links)"));
        }
    }
    // Links are created last so no payload write can traverse one, regardless of order.
    for (rel, target) in &links {
        parents(app, rel)?;
        symlink(target, app.join(rel))?;
    }
    let canonical = app.canonicalize()?;
    for (rel, _) in &links {
        if !app.join(rel).canonicalize()?.starts_with(&canonical) {
            return Err(refuse("application link resolves outside bundle"));
        }
    }
    sync_tree(app)?;
    Ok(())
}
fn sync_tree(path: &Path) -> io::Result<()> {
    for entry in fs::read_dir(path)? {
        let p = entry?.path();
        if metadata(&p)?.is_dir() {
            sync_tree(&p)?;
        }
    }
    sync(path)
}
fn bundle_plist(app: &Path) -> io::Result<plist::Value> {
    let path = app.join("Contents/Info.plist");
    let f = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&path)?;
    let m = f.metadata()?;
    if !m.is_file()
        || m.nlink() != 1
        || m.len() > 1024 * 1024
        || (m.uid() != 0 && m.uid() != uid())
        || m.mode() & 0o022 != 0
    {
        return Err(refuse("invalid Info.plist"));
    }
    no_write_acl(&path)?;
    plist::Value::from_reader(f).map_err(|e| refuse(e.to_string()))
}
/// Read a running source bundle's identity/version, including binary plists and
/// protected system copies. This does not authorize user application publication.
pub fn bundle_version(app: &Path) -> io::Result<String> {
    let value = bundle_plist(app)?;
    let dict = value
        .as_dictionary()
        .ok_or_else(|| refuse("invalid Info.plist dictionary"))?;
    if dict
        .get("CFBundleIdentifier")
        .and_then(plist::Value::as_string)
        != Some(ID)
    {
        return Err(refuse("bundle is not RichOS"));
    }
    let version = dict
        .get("CFBundleShortVersionString")
        .and_then(plist::Value::as_string)
        .ok_or_else(|| refuse("missing bundle version"))?;
    semver::Version::parse(version).map_err(|_| refuse("invalid bundle version"))?;
    Ok(version.to_owned())
}
fn bundle_identity(app: &Path, version: Option<&str>) -> io::Result<String> {
    owned_dir(app)?;
    owned_dir(&app.join("Contents"))?;
    owned_dir(&app.join("Contents/MacOS"))?;
    let value = bundle_plist(app)?;
    let dict = value
        .as_dictionary()
        .ok_or_else(|| refuse("invalid Info.plist dictionary"))?;
    let field = |key: &str| dict.get(key).and_then(plist::Value::as_string);
    if field("CFBundleIdentifier") != Some(ID)
        || version.is_some_and(|v| field("CFBundleShortVersionString") != Some(v))
    {
        return Err(refuse("application identity/version does not match update"));
    }
    let executable =
        field("CFBundleExecutable").ok_or_else(|| refuse("missing bundle executable"))?;
    if !single_name(executable) {
        return Err(refuse("invalid executable name"));
    }
    let m = metadata(&app.join("Contents/MacOS").join(executable))?;
    if !m.is_file() || m.uid() != uid() || m.nlink() != 1 || m.mode() & 0o111 == 0 {
        return Err(refuse("invalid bundle executable"));
    }
    Ok(executable.to_owned())
}
fn tree_hash(root: &Path) -> io::Result<String> {
    fn visit(root: &Path, path: &Path, h: &mut Sha256) -> io::Result<()> {
        let mut entries = fs::read_dir(path)?.collect::<Result<Vec<_>, _>>()?;
        entries.sort_by_key(|e| e.file_name());
        for entry in entries {
            let p = entry.path();
            let m = metadata(&p)?;
            if m.uid() != uid() || (!m.file_type().is_symlink() && m.mode() & 0o022 != 0) {
                return Err(refuse("bundle ownership or permissions changed"));
            }
            if !m.file_type().is_symlink() {
                no_write_acl(&p)?;
            }
            let rel = p
                .strip_prefix(root)
                .map_err(|_| refuse("invalid tree path"))?;
            use std::os::unix::ffi::OsStrExt;
            let name = rel.as_os_str().as_bytes();
            h.update((name.len() as u64).to_le_bytes());
            h.update(name);
            h.update((m.mode() & 0o7777).to_le_bytes());
            if m.is_dir() {
                h.update(b"d");
                visit(root, &p, h)?;
            } else if m.is_file() {
                if m.nlink() != 1 {
                    return Err(refuse("bundle file has external hard links"));
                }
                h.update(b"f");
                h.update(m.len().to_le_bytes());
                let mut f = OpenOptions::new()
                    .read(true)
                    .custom_flags(libc::O_NOFOLLOW)
                    .open(&p)?;
                let mut b = [0u8; 65536];
                loop {
                    let n = f.read(&mut b)?;
                    if n == 0 {
                        break;
                    }
                    h.update(&b[..n]);
                }
            } else if m.file_type().is_symlink() {
                h.update(b"l");
                let target = fs::read_link(&p)?;
                safe_link(rel, &target)?;
                if !p.canonicalize()?.starts_with(root.canonicalize()?) {
                    return Err(refuse("bundle symlink escapes"));
                }
                let bytes = target.as_os_str().as_bytes();
                h.update((bytes.len() as u64).to_le_bytes());
                h.update(bytes);
            } else {
                return Err(refuse("unsupported bundle object"));
            }
        }
        Ok(())
    }
    let mut h = Sha256::new();
    visit(root, root, &mut h)?;
    Ok(format!("{:x}", h.finalize()))
}
fn matches(app: &Path, p: &Published) -> io::Result<bool> {
    match metadata(app) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(false),
        Err(e) => return Err(e),
        Ok(_) => {}
    }
    // A different valid old version is expected during prepared-transaction recovery.
    let name = bundle_identity(app, None)?;
    if name != p.executable_name {
        return Ok(false);
    }
    Ok(tree_hash(app)? == p.tree_sha256)
}
#[cfg(target_os = "macos")]
fn exchange(a: &Path, b: &Path) -> io::Result<()> {
    use std::{ffi::CString, os::unix::ffi::OsStrExt};
    extern "C" {
        fn renameatx_np(
            afd: i32,
            a: *const libc::c_char,
            bfd: i32,
            b: *const libc::c_char,
            flags: u32,
        ) -> i32;
    }
    let a = CString::new(a.as_os_str().as_bytes()).map_err(|_| refuse("invalid app path"))?;
    let b = CString::new(b.as_os_str().as_bytes()).map_err(|_| refuse("invalid app path"))?;
    if unsafe { renameatx_np(libc::AT_FDCWD, a.as_ptr(), libc::AT_FDCWD, b.as_ptr(), 2) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}
#[cfg(not(target_os = "macos"))]
fn exchange(_a: &Path, _b: &Path) -> io::Result<()> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "application exchange requires macOS",
    ))
}
/// Probe only a verified staged executable, before publication. The sandbox denies
/// writes, networking, process creation and WindowServer access even if a broken build
/// ignores the internal flag. Only the startup identity response is accepted.
#[cfg(target_os = "macos")]
fn probe(app: &Path, p: &Published) -> io::Result<()> {
    use std::{
        process::{Command, Stdio},
        time::{Duration, Instant},
    };
    if !matches(app, p)? {
        return Err(refuse("staged executable changed before identity probe"));
    }
    let home = app
        .parent()
        .ok_or_else(|| refuse("missing transaction directory"))?
        .join("probe-home");
    ensure_dir(&home, 0o700)?;
    let profile =
        "(version 1)(deny default)(allow file-read*)(allow process-exec)(allow sysctl-read)";
    let mut command = Command::new("/usr/bin/sandbox-exec");
    command
        .args(["-p", profile])
        .arg(app.join("Contents/MacOS").join(&p.executable_name))
        .arg("--richos-internal-update-identity")
        .env_clear()
        .env("HOME", &home)
        .env("TMPDIR", &home)
        .env("RICHOS_TEST_DATA_DIR", home.join("data"))
        .env("LC_ALL", "C")
        .current_dir(&home)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    // Path restrictions cannot revoke already-open file or socket capabilities.
    // Mark rather than close so Rust's pre-exec error pipe remains usable until exec.
    use std::os::unix::process::CommandExt;
    #[repr(C)]
    #[derive(Clone, Copy)]
    struct ProcFd {
        fd: i32,
        kind: u32,
    }
    #[link(name = "proc")]
    extern "C" {
        fn proc_pidinfo(
            pid: i32,
            flavor: i32,
            arg: u64,
            buffer: *mut libc::c_void,
            size: i32,
        ) -> i32;
    }
    // Allocate before fork. RLIMIT_NOFILE can be lowered below already-open descriptors,
    // so only the actual child descriptor inventory is authoritative.
    let mut descriptors = vec![ProcFd { fd: 0, kind: 0 }; 65_536];
    unsafe {
        command.pre_exec(move || {
            let capacity = (descriptors.len() * std::mem::size_of::<ProcFd>()) as i32;
            let size = proc_pidinfo(
                libc::getpid(),
                1,
                0,
                descriptors.as_mut_ptr().cast(),
                capacity,
            );
            if size <= 0 || size >= capacity || size as usize % std::mem::size_of::<ProcFd>() != 0 {
                return Err(io::Error::from_raw_os_error(libc::EIO));
            }
            for entry in &descriptors[..size as usize / std::mem::size_of::<ProcFd>()] {
                if entry.fd < 3 {
                    continue;
                }
                let flags = libc::fcntl(entry.fd, libc::F_GETFD);
                if flags < 0 || libc::fcntl(entry.fd, libc::F_SETFD, flags | libc::FD_CLOEXEC) < 0 {
                    return Err(io::Error::last_os_error());
                }
            }
            Ok(())
        });
    }
    let mut child = command.spawn()?;
    let output = child
        .stdout
        .take()
        .ok_or_else(|| refuse("probe stdout unavailable"))?;
    let errors = child
        .stderr
        .take()
        .ok_or_else(|| refuse("probe stderr unavailable"))?;
    let reader = |stream: Box<dyn Read + Send>| {
        std::thread::spawn(move || {
            let mut bytes = Vec::new();
            stream.take(8193).read_to_end(&mut bytes).map(|_| bytes)
        })
    };
    let stdout = reader(Box::new(output));
    let stderr = reader(Box::new(errors));
    let deadline = Instant::now() + Duration::from_secs(15);
    let result = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Ok(status),
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(20)),
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                break Err(refuse("staged application identity probe timed out"));
            }
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                break Err(error);
            }
        }
    };
    let output = stdout
        .join()
        .map_err(|_| refuse("identity probe output failed"))??;
    let errors = stderr
        .join()
        .map_err(|_| refuse("identity probe diagnostics failed"))??;
    let status = result?;
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Identity {
        identifier: String,
        version: String,
        protocol: u64,
    }
    let identity: Identity = serde_json::from_slice(&output)
        .map_err(|_| refuse("staged application did not return its compiled identity"))?;
    if !status.success()
        || output.len() > 8192
        || errors.len() > 8192
        || identity.identifier != ID
        || identity.version != p.version
        || identity.protocol != 1
    {
        return Err(refuse(
            "staged executable identity does not match the verified release",
        ));
    }
    if !matches(app, p)? {
        return Err(refuse("staged executable changed during identity probe"));
    }
    write_json(app.parent().unwrap(), "probe.json", p)
}
#[cfg(not(target_os = "macos"))]
fn probe(_app: &Path, _p: &Published) -> io::Result<()> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "application identity probing requires macOS",
    ))
}
// Clear a damaged prepublication journal only when the current app still matches an
// independent exact old publication receipt (or the first destination never existed).
// Ambiguous post-exchange damage remains blocked and no payload bytes are deleted.
fn quarantine_invalid_pending(root: &Path, p: &Published) -> io::Result<bool> {
    let tx = root.join(&p.archive_sha256);
    owned_dir(&tx)?;
    let dest = root.parent().unwrap().join(APP);
    let previous = optional_json(&tx.join("previous.json"))?;
    let published = optional_json(&root.join("published.json"))?;
    let unchanged = previous
        .iter()
        .chain(published.iter())
        .any(|old| old.tree_sha256 != p.tree_sha256 && matches(&dest, old).unwrap_or(false));
    let absent_first = matches!(metadata(&dest), Err(e) if e.kind()==io::ErrorKind::NotFound)
        && previous.is_none()
        && published.is_none();
    if !unchanged && !absent_first {
        return Ok(false);
    }
    fs::rename(root.join("prepared.json"), tx.join("invalid.json"))?;
    sync(&tx)?;
    sync(root)?;
    Ok(true)
}
fn recover(root: &Path) -> io::Result<Option<Published>> {
    let journal = root.join("prepared.json");
    let p = match read_json(&journal) {
        Ok(p) => p,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e),
    };
    let dest = root.parent().unwrap().join(APP);
    let transaction = root.join(&p.archive_sha256);
    owned_dir(&transaction)?;
    let incoming = transaction.join("incoming.app");
    if !matches(&dest, &p)? {
        if !matches(&incoming, &p).unwrap_or(false) {
            quarantine_invalid_pending(root, &p)?;
            return Err(refuse("prepared update no longer matches its receipt"));
        }
        if let Err(error) = probe(&incoming, &p) {
            // A rejected payload cannot strand the next valid update behind its journal.
            fs::rename(&journal, transaction.join("rejected.json"))?;
            sync(&transaction)?;
            sync(root)?;
            return Err(error);
        }
        match metadata(&dest) {
            Ok(_) => {
                bundle_identity(&dest, None)?;
                if !p.is_newer_than(&bundle_version(&dest)?)? {
                    fs::rename(&journal, transaction.join("obsolete.json"))?;
                    sync(&transaction)?;
                    sync(root)?;
                    return Err(refuse(
                        "prepared update would replace an equal or newer destination",
                    ));
                }
                let previous = Published {
                    version: bundle_version(&dest)?,
                    archive_sha256: p.archive_sha256.clone(),
                    tree_sha256: tree_hash(&dest)?,
                    executable_name: bundle_identity(&dest, None)?,
                };
                write_json(&transaction, "previous.json", &previous)?;
                exchange(&incoming, &dest)?;
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => fs::rename(&incoming, &dest)?,
            Err(e) => return Err(e),
        }
    }
    // Replay may observe the exchanged destination after a crash before either fsync.
    // Always persist both rename directories before committing the publication receipt.
    sync(&transaction)?;
    sync(root.parent().unwrap())?;
    if !matches(&dest, &p)? || bundle_identity(&dest, Some(&p.version))? != p.executable_name {
        return Err(refuse("published update verification failed"));
    }
    write_json(root, "published.json", &p)?;
    fs::remove_file(journal)?;
    sync(root)?;
    // Keep the receipt-bound previous bundle until a later exclusive startup collects it.
    Ok(Some(p))
}

// Device numbers can change across macOS boots. Durable deletion authority uses the
// filesystem's native volume UUID plus inode, not st_dev persisted in JSON.
#[cfg(target_os = "macos")]
fn volume_uuid(path: &Path) -> io::Result<String> {
    #[repr(C)]
    struct AttrList {
        count: u16,
        reserved: u16,
        common: u32,
        volume: u32,
        directory: u32,
        file: u32,
        fork: u32,
    }
    extern "C" {
        fn fgetattrlist(
            fd: i32,
            attributes: *mut AttrList,
            buffer: *mut libc::c_void,
            size: usize,
            options: u32,
        ) -> i32;
    }
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_DIRECTORY)
        .open(path)?;
    let before = file.metadata()?;
    let mut attributes = AttrList {
        count: 5,
        reserved: 0,
        common: 0,
        volume: 0x8004_0000,
        directory: 0,
        file: 0,
        fork: 0,
    };
    let mut bytes = [0u8; 20];
    if unsafe {
        fgetattrlist(
            file.as_raw_fd(),
            &mut attributes,
            bytes.as_mut_ptr().cast(),
            bytes.len(),
            0,
        )
    } != 0
    {
        return Err(io::Error::last_os_error());
    }
    let after = file.metadata()?;
    if u32::from_ne_bytes(bytes[..4].try_into().unwrap()) != 20
        || bytes[4..].iter().all(|b| *b == 0)
        || (before.dev(), before.ino()) != (after.dev(), after.ino())
    {
        return Err(refuse("stable updater volume identity unavailable"));
    }
    Ok(bytes[4..].iter().map(|b| format!("{b:02x}")).collect())
}
#[cfg(not(target_os = "macos"))]
fn volume_uuid(_path: &Path) -> io::Result<String> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "stable updater volume identity requires macOS",
    ))
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Retirement {
    transaction_volume: String,
    transaction_ino: u64,
    payload_volume: String,
    payload_ino: u64,
}
impl Retirement {
    fn capture(transaction: &Path, payload: &Path) -> io::Result<Self> {
        let t = metadata(transaction)?;
        let p = metadata(payload)?;
        if !t.is_dir() || !p.is_dir() || t.uid() != uid() || p.uid() != uid() {
            return Err(refuse("invalid updater payload allocation"));
        }
        Ok(Self {
            transaction_volume: volume_uuid(transaction)?,
            transaction_ino: t.ino(),
            payload_volume: volume_uuid(payload)?,
            payload_ino: p.ino(),
        })
    }
    fn check(&self, transaction: &Path, payload: &Path) -> io::Result<()> {
        owned_dir(transaction)?;
        let t = metadata(transaction)?;
        let p = metadata(payload)?;
        if !p.is_dir()
            || p.uid() != uid()
            || (volume_uuid(transaction)?, t.ino())
                != (self.transaction_volume.clone(), self.transaction_ino)
            || (volume_uuid(payload)?, p.ino()) != (self.payload_volume.clone(), self.payload_ino)
        {
            return Err(refuse("updater retirement directory identity changed"));
        }
        Ok(())
    }
}
fn optional_json(path: &Path) -> io::Result<Option<Published>> {
    match read_json(path) {
        Ok(p) => Ok(Some(p)),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e),
    }
}
/// Reclaim proven updater payloads at a later exclusive startup. The caller must first
/// prove its loaded bundle still matches its startup inode/version. Errors retain bytes
/// and must not prevent the normal runtime. This never runs while any participating
/// session holds SH and never deletes the caller's own loaded bundle.
pub fn collect_retired(lease: &mut StartupLease, loaded_bundle: &Path) -> io::Result<usize> {
    if !lease.can_activate() {
        return Ok(0);
    }
    let root = root(&lease.home)?;
    validate_lease_file(&lease.file, &root)?;
    let _lock = Lock::acquire(&root)?;
    let loaded = metadata(loaded_bundle)?;
    if !loaded.is_dir() {
        return Err(refuse("loaded application directory unavailable"));
    }
    let loaded_volume = volume_uuid(loaded_bundle)?;
    let pending = optional_json(&root.join("prepared.json"))?;
    let mut reclaimed = 0;
    // Bound each startup. Small audit files stay; later startups continue other payloads.
    for entry in fs::read_dir(&root)? {
        let entry = entry?;
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        if name.len() != 64
            || !name
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            continue;
        }
        if pending.as_ref().is_some_and(|p| p.archive_sha256 == name) {
            continue;
        }
        let transaction = entry.path();
        owned_dir(&transaction)?;
        let incoming = transaction.join("incoming.app");
        let retired = transaction.join("retiring.app");
        let journal = transaction.join("retirement.json");
        let record: Retirement = match read_document(&journal) {
            Ok(record) => record,
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                if metadata(&retired).is_ok() {
                    return Err(refuse("unreceipted retirement payload"));
                }
                let m = match metadata(&incoming) {
                    Ok(m) => m,
                    Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
                    Err(e) => return Err(e),
                };
                if (m.dev(), m.ino()) == (loaded.dev(), loaded.ino()) {
                    continue;
                }
                let previous = optional_json(&transaction.join("previous.json"))?;
                let verified = optional_json(&transaction.join("verified.json"))?;
                if let Some(p) = previous.filter(|p| matches(&incoming, p).unwrap_or(false)) {
                    p.valid()?;
                    if p.archive_sha256 != name {
                        return Err(refuse("previous payload transaction mismatch"));
                    }
                } else if let Some(p) = verified {
                    if p.archive_sha256 != name || !matches(&incoming, &p)? {
                        return Err(refuse(
                            "retained updater payload no longer matches its receipt",
                        ));
                    }
                } else {
                    // A partial extraction is authorized only by its original allocation
                    // inode, never by a directory name or elapsed time.
                    let allocated: Retirement = read_document(&transaction.join("allocated.json"))?;
                    allocated.check(&transaction, &incoming)?;
                }
                let record = Retirement::capture(&transaction, &incoming)?;
                write_document(&transaction, "retirement.json", &record)?;
                record
            }
            Err(e) => return Err(e),
        };
        let payload = match metadata(&retired) {
            Ok(_) => retired.clone(),
            Err(e) if e.kind() == io::ErrorKind::NotFound => match metadata(&incoming) {
                Ok(_) => {
                    record.check(&transaction, &incoming)?;
                    if (record.payload_volume.as_str(), record.payload_ino)
                        == (loaded_volume.as_str(), loaded.ino())
                    {
                        continue;
                    }
                    fs::rename(&incoming, &retired)?;
                    sync(&transaction)?;
                    retired.clone()
                }
                Err(e) if e.kind() == io::ErrorKind::NotFound => {
                    sync(&transaction)?;
                    fs::rename(&journal, transaction.join("collected.json"))?;
                    sync(&transaction)?;
                    continue;
                }
                Err(e) => return Err(e),
            },
            Err(e) => return Err(e),
        };
        record.check(&transaction, &payload)?;
        if (record.payload_volume.as_str(), record.payload_ino)
            == (loaded_volume.as_str(), loaded.ino())
        {
            continue;
        }
        // remove_dir_all never follows directory symlinks. Replay is authorized by the
        // fixed payload inode and durable retirement receipt even after partial removal.
        fs::remove_dir_all(&payload)?;
        sync(&transaction)?;
        fs::rename(&journal, transaction.join("collected.json"))?;
        sync(&transaction)?;
        reclaimed += 1;
        if reclaimed == 8 {
            break;
        }
    }
    Ok(reclaimed)
}
/// Stage only bytes already accepted by `Update::download` signature verification.
/// Does not publish or modify the running app, including protected system installations.
pub fn stage_verified(home: &Path, bytes: &[u8], version: &str) -> io::Result<Published> {
    let root = root(home)?;
    // Independent staging serialization and SH exclusion keep expensive extraction and
    // probing off the publication lock. Other normal startups can join SH immediately.
    let _stage = Lock::named(&root, "stage.lock")?;
    let mut session = StartupLease::acquire(home)?;
    session.begin_session()?;
    let offered = semver::Version::parse(version).map_err(|_| refuse("invalid offered version"))?;
    let archive_sha256 = digest(bytes);
    let superseded = match read_json(&root.join("prepared.json")) {
        Ok(p) => {
            let incoming_matches =
                matches(&root.join(&p.archive_sha256).join("incoming.app"), &p).unwrap_or(false);
            let published_matches = matches(&home.join("Applications").join(APP), &p)?;
            if p.archive_sha256 == archive_sha256
                && p.version == version
                && (incoming_matches || published_matches)
            {
                return Ok(p);
            }
            if !incoming_matches && quarantine_invalid_pending(&root, &p)? {
                None
            } else {
                if !incoming_matches
                    || published_matches
                    || semver::Version::parse(&p.version)
                        .map_err(|_| refuse("invalid pending version"))?
                        >= offered
                {
                    return Err(refuse(
                        "pending update must finish recovery before it can be superseded",
                    ));
                }
                Some(p)
            }
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => None,
        Err(e) => return Err(e),
    };
    match read_json(&root.join("published.json")) {
        Ok(p) => {
            if p.archive_sha256 == archive_sha256
                && p.version == version
                && matches(&home.join("Applications").join(APP), &p)?
            {
                return Ok(p);
            }
            if semver::Version::parse(&p.version)
                .map_err(|_| refuse("invalid published version"))?
                >= offered
            {
                return Err(refuse(
                    "an equal or newer user application is already published",
                ));
            }
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => {}
        Err(e) => return Err(e),
    }
    let transaction = root.join(&archive_sha256);
    // An interrupted pre-journal extraction is inert. Delete only this digest-named,
    // owner-private transaction; never touch the current application to recover it.
    if let Ok(m) = metadata(&transaction) {
        if !m.is_dir() || m.uid() != uid() || m.mode() & 0o077 != 0 {
            return Err(refuse("invalid update transaction"));
        }
        match read_json(&transaction.join("verified.json")) {
            Ok(p) => {
                if p.archive_sha256 != archive_sha256
                    || p.version != version
                    || !matches(&transaction.join("incoming.app"), &p)?
                {
                    return Err(refuse(
                        "transaction retains a previous application; refusing to delete it",
                    ));
                }
                probe(&transaction.join("incoming.app"), &p)?;
                prepare_receipt(&root, &p, superseded.as_ref())?;
                return Ok(p);
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Err(e) => return Err(e),
        }
        fs::remove_dir_all(&transaction)?;
    }
    fs::create_dir(&transaction)?;
    fs::set_permissions(&transaction, fs::Permissions::from_mode(0o700))?;
    sync(&root)?;
    let app = transaction.join("incoming.app");
    ensure_dir(&app, 0o755)?;
    write_document(
        &transaction,
        "allocated.json",
        &Retirement::capture(&transaction, &app)?,
    )?;
    extract(bytes, &app)?;
    let executable_name = bundle_identity(&app, Some(version))?;
    let p = Published {
        version: version.to_owned(),
        archive_sha256,
        tree_sha256: tree_hash(&app)?,
        executable_name,
    };
    probe(&app, &p)?;
    write_json(&transaction, "verified.json", &p)?;
    prepare_receipt(&root, &p, superseded.as_ref())?;
    Ok(p)
}
fn prepare_receipt(root: &Path, p: &Published, superseded: Option<&Published>) -> io::Result<()> {
    let _publication = Lock::acquire_startup(root)?;
    if let Some(old) = superseded {
        write_json(
            root,
            &format!("superseded-{}.json", old.archive_sha256),
            old,
        )?;
    }
    write_json(root, "prepared.json", p)
}
/// Complete a prepared update only before runtime startup, while every participating
/// session is excluded. This never runs from the live update command.
pub fn activate_prepared_above(
    lease: &mut StartupLease,
    running_version: &str,
) -> io::Result<Option<Published>> {
    if !lease.can_activate() {
        return Err(io::Error::new(
            io::ErrorKind::WouldBlock,
            "another RichOS session is running",
        ));
    }
    let root = root(&lease.home)?;
    validate_lease_file(&lease.file, &root)?;
    let _lock = Lock::acquire_startup(&root)?;
    match read_json(&root.join("prepared.json")) {
        Ok(p) if !p.is_newer_than(running_version)? => {
            if matches(&lease.home.join("Applications").join(APP), &p)? {
                // The new image can be loaded after an exchange but before its receipt
                // is durable. Complete exactly that receipt without exchanging or exec.
                recover(&root)?;
                return Ok(None);
            }
            let transaction = root.join(&p.archive_sha256);
            owned_dir(&transaction)?;
            if !matches(&transaction.join("incoming.app"), &p)? {
                return Err(refuse(
                    "obsolete pending update has ambiguous publication state",
                ));
            }
            // A newer external build must be able to check for future releases. Keeping
            // this exact obsolete journal would make the live UI report readiness forever.
            fs::rename(
                root.join("prepared.json"),
                transaction.join("obsolete.json"),
            )?;
            sync(&transaction)?;
            sync(&root)?;
            return Ok(None);
        }
        Ok(_) => {}
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e),
    }
    recover(&root)
}
/// Read a verified pending update for the live UI without publishing it.
pub fn staged(home: &Path) -> io::Result<Option<Published>> {
    let root = root(home)?;
    let _lock = Lock::acquire(&root)?;
    let p = match read_json(&root.join("prepared.json")) {
        Ok(p) => p,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e),
    };
    if !matches(&root.join(&p.archive_sha256).join("incoming.app"), &p)?
        && !matches(&home.join("Applications").join(APP), &p)?
    {
        return Err(refuse(
            "pending update no longer matches its verified receipt",
        ));
    }
    Ok(Some(p))
}
#[cfg(test)]
fn install_verified(home: &Path, bytes: &[u8], version: &str) -> io::Result<Published> {
    let p = stage_verified(home, bytes, version)?;
    let mut lease = StartupLease::acquire(home)?;
    activate_prepared_above(&mut lease, "0.0.0")?;
    Ok(p)
}
/// Validate the recorded preferred user app, including its complete tree, before a
/// startup redirect or relaunch. Returns None when no user update has been installed.
/// This read does not complete a prepared update or replace a running app.
pub fn preferred(home: &Path) -> io::Result<Option<Published>> {
    with_preferred(home, |p| Ok(p.clone()))
}
/// Hold the publication lock from validation through the caller's executable spawn.
/// The callback must not call another updater API or wait for the new app to exit.
pub fn with_preferred<T>(
    home: &Path,
    action: impl FnOnce(&Published) -> io::Result<T>,
) -> io::Result<Option<T>> {
    let root = root(home)?;
    let _lock = Lock::acquire_startup(&root)?;
    let p = match read_json(&root.join("published.json")) {
        Ok(p) => p,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e),
    };
    let app = home.join("Applications").join(APP);
    if bundle_identity(&app, Some(&p.version))? != p.executable_name || !matches(&app, &p)? {
        return Err(refuse(
            "preferred application does not match publication receipt",
        ));
    }
    Ok(Some(action(&p)?))
}

#[cfg(test)]
mod tests {
    use super::*;
    use flate2::{write::GzEncoder, Compression};
    fn home() -> tempfile::TempDir {
        tempfile::tempdir().unwrap()
    }
    fn canonical(t: &tempfile::TempDir) -> PathBuf {
        t.path().canonicalize().unwrap()
    }
    fn add(t: &mut tar::Builder<GzEncoder<Vec<u8>>>, name: &str, body: &[u8], mode: u32) {
        let mut h = tar::Header::new_gnu();
        h.set_size(body.len() as u64);
        h.set_mode(mode);
        h.set_cksum();
        t.append_data(&mut h, name, body).unwrap();
    }
    fn fixture_binary(version: &str) -> Vec<u8> {
        static BINARIES: std::sync::OnceLock<
            std::sync::Mutex<std::collections::HashMap<String, Vec<u8>>>,
        > = std::sync::OnceLock::new();
        let mut binaries = BINARIES.get_or_init(Default::default).lock().unwrap();
        if let Some(bytes) = binaries.get(version) {
            return bytes.clone();
        }
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("identity.c");
        let executable = temp.path().join("identity");
        let response =
            serde_json::json!({"identifier":ID,"version":version,"protocol":1}).to_string();
        fs::write(&source, format!("#include <stdio.h>\n#include <string.h>\nint main(int n,char**v){{if(n!=2||strcmp(v[1],\"--richos-internal-update-identity\"))return 73;puts({:?});return 0;}}\n", response)).unwrap();
        let result = std::process::Command::new("/usr/bin/cc")
            .arg(&source)
            .arg("-o")
            .arg(&executable)
            .output()
            .unwrap();
        assert!(
            result.status.success(),
            "native fixture compiler: {}",
            String::from_utf8_lossy(&result.stderr)
        );
        let bytes = fs::read(executable).unwrap();
        binaries.insert(version.to_owned(), bytes.clone());
        bytes
    }
    fn fixture_version(executable: PathBuf) -> PathBuf {
        executable
            .parent()
            .unwrap()
            .parent()
            .unwrap()
            .join("Resources/fixture-version")
    }
    fn archive(
        version: &str,
        extra: impl FnOnce(&mut tar::Builder<GzEncoder<Vec<u8>>>),
    ) -> Vec<u8> {
        archive_with_binary(version, &fixture_binary(version), extra)
    }
    fn archive_with_binary(
        version: &str,
        binary: &[u8],
        extra: impl FnOnce(&mut tar::Builder<GzEncoder<Vec<u8>>>),
    ) -> Vec<u8> {
        let mut t = tar::Builder::new(GzEncoder::new(Vec::new(), Compression::default()));
        let info = format!(
            r#"<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.richos.app</string><key>CFBundleShortVersionString</key><string>{version}</string><key>CFBundleExecutable</key><string>richos-tauri</string></dict></plist>"#
        );
        add(
            &mut t,
            "RichOS.app/Contents/Info.plist",
            info.as_bytes(),
            0o644,
        );
        add(
            &mut t,
            "RichOS.app/Contents/MacOS/richos-tauri",
            binary,
            0o755,
        );
        add(
            &mut t,
            "RichOS.app/Contents/Resources/fixture-version",
            version.as_bytes(),
            0o644,
        );
        extra(&mut t);
        t.into_inner().unwrap().finish().unwrap()
    }
    fn link(
        t: &mut tar::Builder<GzEncoder<Vec<u8>>>,
        name: &str,
        target: &str,
        kind: tar::EntryType,
    ) {
        let mut h = tar::Header::new_gnu();
        h.set_size(0);
        h.set_mode(0o777);
        h.set_entry_type(kind);
        h.set_link_name(target).unwrap();
        h.set_cksum();
        t.append_data(&mut h, name, io::empty()).unwrap();
    }
    #[test]
    fn installs_as_actual_owner_and_replays_exact_receipt() {
        let t = home();
        let h = canonical(&t);
        let bytes = archive("2.0.0", |_| {});
        let p = install_verified(&h, &bytes, "2.0.0").unwrap();
        assert_eq!(
            fs::read(fixture_version(p.executable(&h))).unwrap(),
            b"2.0.0"
        );
        assert_eq!(metadata(&p.executable(&h)).unwrap().uid(), uid());
        assert_eq!(
            install_verified(&h, &bytes, "2.0.0").unwrap().tree_sha256,
            p.tree_sha256
        );
        assert_eq!(preferred(&h).unwrap().unwrap().tree_sha256, p.tree_sha256);
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn atomic_exchange_retains_old_application() {
        let t = home();
        let h = canonical(&t);
        install_verified(&h, &archive("1.0.0", |_| {}), "1.0.0").unwrap();
        let bytes = archive("2.0.0", |_| {});
        let p = install_verified(&h, &bytes, "2.0.0").unwrap();
        assert_eq!(
            fs::read(fixture_version(p.executable(&h))).unwrap(),
            b"2.0.0"
        );
        let backup = root(&h)
            .unwrap()
            .join(digest(&bytes))
            .join("incoming.app/Contents/Resources/fixture-version");
        assert_eq!(fs::read(backup).unwrap(), b"1.0.0");
    }
    #[test]
    fn wrong_version_cannot_publish() {
        let t = home();
        let h = canonical(&t);
        assert!(install_verified(&h, &archive("1.0.0", |_| {}), "2.0.0").is_err());
        assert!(!h.join("Applications/RichOS.app").exists());
    }
    #[test]
    fn symlinked_user_destination_is_not_followed() {
        let t = home();
        let h = canonical(&t);
        let outside = home();
        symlink(outside.path(), h.join("Applications")).unwrap();
        assert!(install_verified(&h, &archive("1.0.0", |_| {}), "1.0.0").is_err());
        assert_eq!(fs::read_dir(outside.path()).unwrap().count(), 0);
    }
    #[test]
    fn destination_permission_denial_is_plain_io_failure() {
        let t = home();
        let h = canonical(&t);
        let a = h.join("Applications");
        fs::create_dir(&a).unwrap();
        fs::set_permissions(&a, fs::Permissions::from_mode(0o555)).unwrap();
        let result = install_verified(&h, &archive("1.0.0", |_| {}), "1.0.0");
        fs::set_permissions(&a, fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(result.unwrap_err().kind(), io::ErrorKind::PermissionDenied);
        assert!(!a.join(APP).exists());
    }
    #[test]
    fn safe_framework_links_preserve_topology() {
        let t = home();
        let h = canonical(&t);
        let bytes = archive("1.0.0", |t| {
            add(
                t,
                "RichOS.app/Contents/Frameworks/F.framework/Versions/A/F",
                b"framework",
                0o755,
            );
            link(
                t,
                "RichOS.app/Contents/Frameworks/F.framework/Versions/Current",
                "A",
                tar::EntryType::Symlink,
            );
            link(
                t,
                "RichOS.app/Contents/Frameworks/F.framework/F",
                "Versions/Current/F",
                tar::EntryType::Symlink,
            );
        });
        install_verified(&h, &bytes, "1.0.0").unwrap();
        assert_eq!(
            fs::read(h.join("Applications/RichOS.app/Contents/Frameworks/F.framework/F")).unwrap(),
            b"framework"
        );
    }
    #[test]
    fn escaping_links_and_hard_links_are_refused() {
        for (target, kind) in [
            ("../../../escape", tar::EntryType::Symlink),
            ("/tmp/escape", tar::EntryType::Symlink),
            (
                "RichOS.app/Contents/MacOS/richos-tauri",
                tar::EntryType::Link,
            ),
        ] {
            let t = home();
            let h = canonical(&t);
            let bytes = archive("1.0.0", |t| {
                link(t, "RichOS.app/Contents/link", target, kind)
            });
            assert!(install_verified(&h, &bytes, "1.0.0").is_err());
            assert!(!h.join("Applications/RichOS.app").exists());
        }
    }
    #[test]
    fn symlink_cannot_become_a_write_parent() {
        let t = home();
        let h = canonical(&t);
        let bytes = archive("1.0.0", |t| {
            link(
                t,
                "RichOS.app/Contents/alias",
                "MacOS",
                tar::EntryType::Symlink,
            );
            add(t, "RichOS.app/Contents/alias/extra", b"no", 0o644);
        });
        assert!(install_verified(&h, &bytes, "1.0.0").is_err());
        assert!(!h.join("Applications/RichOS.app").exists());
    }
    #[test]
    fn duplicate_entries_and_second_archive_root_are_refused() {
        for name in [
            "Other.app/Contents/file",
            "RichOS.app/Contents/MacOS/richos-tauri",
        ] {
            let t = home();
            let h = canonical(&t);
            assert!(install_verified(
                &h,
                &archive("1.0.0", |t| add(t, name, b"no", 0o644)),
                "1.0.0"
            )
            .is_err());
        }
    }
    #[test]
    fn changed_published_tree_cannot_relaunch() {
        let t = home();
        let h = canonical(&t);
        let p = install_verified(&h, &archive("1.0.0", |_| {}), "1.0.0").unwrap();
        fs::write(p.executable(&h), b"tampered").unwrap();
        assert!(preferred(&h).is_err());
    }
    #[test]
    fn interrupted_extraction_is_rebuilt_without_touching_current_app() {
        let t = home();
        let h = canonical(&t);
        let bytes = archive("1.0.0", |_| {});
        let r = root(&h).unwrap();
        let tx = r.join(digest(&bytes));
        fs::create_dir(&tx).unwrap();
        fs::set_permissions(&tx, fs::Permissions::from_mode(0o700)).unwrap();
        fs::write(tx.join("incomplete"), b"partial").unwrap();
        install_verified(&h, &bytes, "1.0.0").unwrap();
        assert!(!tx.join("incomplete").exists());
    }
    fn prepare(h: &Path, bytes: &[u8], version: &str) -> (PathBuf, Published) {
        let r = root(h).unwrap();
        let tx = r.join(digest(bytes));
        ensure_dir(&tx, 0o700).unwrap();
        let incoming = tx.join("incoming.app");
        extract(bytes, &incoming).unwrap();
        let p = Published {
            version: version.into(),
            archive_sha256: digest(bytes),
            tree_sha256: tree_hash(&incoming).unwrap(),
            executable_name: bundle_identity(&incoming, Some(version)).unwrap(),
        };
        write_json(&tx, "verified.json", &p).unwrap();
        write_json(&r, "prepared.json", &p).unwrap();
        (r, p)
    }
    #[test]
    fn prepared_first_install_recovers_after_journal_crash() {
        let t = home();
        let h = canonical(&t);
        let bytes = archive("1.0.0", |_| {});
        let (_r, p) = prepare(&h, &bytes, "1.0.0");
        assert_eq!(
            install_verified(&h, &bytes, "1.0.0").unwrap().tree_sha256,
            p.tree_sha256
        );
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn exchange_before_receipt_crash_recovers_without_swapping_back() {
        let t = home();
        let h = canonical(&t);
        install_verified(&h, &archive("1.0.0", |_| {}), "1.0.0").unwrap();
        let bytes = archive("2.0.0", |_| {});
        let (r, p) = prepare(&h, &bytes, "2.0.0");
        let incoming = r.join(&p.archive_sha256).join("incoming.app");
        exchange(&incoming, &h.join("Applications/RichOS.app")).unwrap();
        SYNC_TRACE.with(|trace| trace.borrow_mut().clear());
        install_verified(&h, &bytes, "2.0.0").unwrap();
        SYNC_TRACE.with(|trace| {
            let trace = trace.borrow();
            assert_eq!(trace[0], incoming.parent().unwrap());
            assert_eq!(trace[1], h.join("Applications"));
            // The root receipt sync happens only after both rename directories.
            assert_eq!(trace[2], r);
        });
        assert_eq!(
            fs::read(fixture_version(p.executable(&h))).unwrap(),
            b"2.0.0"
        );
        assert_eq!(
            fs::read(incoming.join("Contents/Resources/fixture-version")).unwrap(),
            b"1.0.0"
        );
    }
    #[test]
    fn stale_old_instance_cannot_downgrade_preferred_app() {
        let t = home();
        let h = canonical(&t);
        let latest = install_verified(&h, &archive("3.0.0", |_| {}), "3.0.0").unwrap();
        assert!(install_verified(&h, &archive("2.0.0", |_| {}), "2.0.0").is_err());
        assert_eq!(
            fs::read(fixture_version(latest.executable(&h))).unwrap(),
            b"3.0.0"
        );
    }
    #[test]
    fn exact_preferred_callback_holds_publication_exclusion() {
        let t = home();
        let h = canonical(&t);
        install_verified(&h, &archive("1.0.0", |_| {}), "1.0.0").unwrap();
        with_preferred(&h, |p| {
            assert_eq!(
                p.executable(&h),
                h.join("Applications/RichOS.app/Contents/MacOS/richos-tauri")
            );
            assert!(install_verified(&h, &archive("2.0.0", |_| {}), "2.0.0").is_err());
            Ok(())
        })
        .unwrap()
        .unwrap();
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn harmless_deny_acl_works_but_write_grant_refuses() {
        let t = home();
        let h = canonical(&t);
        let chmod = |rule: &str| {
            assert!(std::process::Command::new("/bin/chmod")
                .args(["+a", rule])
                .arg(&h)
                .status()
                .unwrap()
                .success())
        };
        chmod("everyone deny delete");
        assert!(install_verified(&h, &archive("1.0.0", |_| {}), "1.0.0").is_ok());
        chmod("everyone allow add_file");
        assert!(install_verified(&h, &archive("2.0.0", |_| {}), "2.0.0").is_err());
        assert!(std::process::Command::new("/bin/chmod")
            .arg("-N")
            .arg(&h)
            .status()
            .unwrap()
            .success());
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn write_acl_on_published_executable_prevents_launch() {
        let t = home();
        let h = canonical(&t);
        let p = install_verified(&h, &archive("1.0.0", |_| {}), "1.0.0").unwrap();
        let executable = p.executable(&h);
        assert!(std::process::Command::new("/bin/chmod")
            .args(["+a", "everyone allow write"])
            .arg(&executable)
            .status()
            .unwrap()
            .success());
        assert!(preferred(&h).is_err());
    }
    #[test]
    fn concurrent_install_cannot_modify_existing_journal() {
        let t = home();
        let h = canonical(&t);
        let r = root(&h).unwrap();
        let _lock = Lock::acquire(&r).unwrap();
        assert!(install_verified(&h, &archive("1.0.0", |_| {}), "1.0.0").is_err());
        assert!(!r.join("prepared.json").exists());
    }
    #[test]
    fn malformed_receipt_and_external_receipt_links_refuse() {
        let t = home();
        let h = canonical(&t);
        let r = root(&h).unwrap();
        fs::write(r.join("published.json"), b"{}").unwrap();
        assert!(install_verified(&h, &archive("1.0.0", |_| {}), "1.0.0").is_err());
        fs::remove_file(r.join("published.json")).unwrap();
        let outside = h.join("outside");
        fs::write(&outside, b"never modified").unwrap();
        symlink(&outside, r.join("published.json")).unwrap();
        assert!(install_verified(&h, &archive("1.0.0", |_| {}), "1.0.0").is_err());
        assert_eq!(fs::read(&outside).unwrap(), b"never modified");
    }
    #[test]
    fn stage_does_not_replace_live_bundle_and_shared_sessions_veto_activation() {
        let t = home();
        let h = canonical(&t);
        let old = install_verified(&h, &archive("1.0.0", |_| {}), "1.0.0").unwrap();
        let mut live = StartupLease::acquire(&h).unwrap();
        live.begin_session().unwrap();
        stage_verified(&h, &archive("2.0.0", |_| {}), "2.0.0").unwrap();
        assert_eq!(
            fs::read(fixture_version(old.executable(&h))).unwrap(),
            b"1.0.0"
        );
        let mut another = StartupLease::acquire(&h).unwrap();
        assert!(!another.can_activate());
        assert_eq!(
            activate_prepared_above(&mut another, "0.0.0")
                .unwrap_err()
                .kind(),
            io::ErrorKind::WouldBlock
        );
        assert_eq!(staged(&h).unwrap().unwrap().version, "2.0.0");
        drop(another);
        drop(live);
        let mut startup = StartupLease::acquire(&h).unwrap();
        activate_prepared_above(&mut startup, "0.0.0")
            .unwrap()
            .unwrap();
        assert_eq!(
            fs::read(fixture_version(old.executable(&h))).unwrap(),
            b"2.0.0"
        );
    }
    #[test]
    fn lease_adoption_rejects_unrelated_descriptor_without_closing_it() {
        let t = home();
        let h = canonical(&t);
        let _lease = StartupLease::acquire(&h).unwrap();
        let other = File::create(h.join("unrelated")).unwrap();
        assert!(StartupLease::adopt(&h, other.as_raw_fd()).is_err());
        assert!(other.metadata().is_ok());
    }
    #[test]
    fn replaced_lease_path_vetoes_activation() {
        let t = home();
        let h = canonical(&t);
        stage_verified(&h, &archive("1.0.0", |_| {}), "1.0.0").unwrap();
        let mut lease = StartupLease::acquire(&h).unwrap();
        let r = root(&h).unwrap();
        fs::rename(r.join("session.lock"), r.join("old-session.lock")).unwrap();
        File::create(r.join("session.lock")).unwrap();
        assert!(activate_prepared_above(&mut lease, "0.0.0").is_err());
        assert!(!h.join("Applications/RichOS.app").exists());
    }
    #[test]
    fn failed_exec_restores_cloexec_and_keeps_exclusion() {
        let t = home();
        let h = canonical(&t);
        let mut lease = StartupLease::acquire(&h).unwrap();
        let before = unsafe { libc::fcntl(lease.session_fd(), libc::F_GETFD) };
        let error = lease.exec(&mut std::process::Command::new(h.join("absent-executable")));
        assert_eq!(error.kind(), io::ErrorKind::NotFound);
        assert_eq!(
            unsafe { libc::fcntl(lease.session_fd(), libc::F_GETFD) },
            before
        );
        assert!(StartupLease::acquire(&h).is_err());
    }
    #[test]
    fn lease_exec_child() {
        let Some(home) = std::env::var_os("RICHOS_TEST_UPDATE_EXEC_HOME") else {
            return;
        };
        let h = PathBuf::from(home);
        if let Ok(raw) = std::env::var("RICHOS_TEST_UPDATE_EXEC_FD") {
            let mut lease = StartupLease::adopt(&h, raw.parse().unwrap()).unwrap();
            assert!(!lease.can_activate());
            assert_ne!(
                unsafe { libc::fcntl(lease.session_fd(), libc::F_GETFD) } & libc::FD_CLOEXEC,
                0
            );
            fs::write(h.join("ready"), b"held").unwrap();
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
            while !h.join("release").exists() {
                assert!(
                    std::time::Instant::now() < deadline,
                    "parent did not release fixture"
                );
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            lease.begin_session().unwrap();
            return;
        }
        let mut lease = StartupLease::acquire(&h).unwrap();
        let mut command = std::process::Command::new(std::env::current_exe().unwrap());
        command
            .args(["--exact", "tests::lease_exec_child", "--nocapture"])
            .env("RICHOS_TEST_UPDATE_EXEC_HOME", &h)
            .env("RICHOS_TEST_UPDATE_EXEC_FD", lease.session_fd().to_string());
        panic!("fixture exec failed: {}", lease.exec(&mut command));
    }
    #[test]
    fn actual_exec_preserves_session_exclusion_until_replacement_exits() {
        let t = home();
        let h = canonical(&t);
        let mut child = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "tests::lease_exec_child", "--nocapture"])
            .env("RICHOS_TEST_UPDATE_EXEC_HOME", &h)
            .env_remove("RICHOS_TEST_UPDATE_EXEC_FD")
            .stdout(std::process::Stdio::null())
            .spawn()
            .unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while !h.join("ready").exists() {
            assert!(
                child.try_wait().unwrap().is_none(),
                "fixture exited before transfer proof"
            );
            assert!(
                std::time::Instant::now() < deadline,
                "fixture never transferred lease"
            );
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        let observer = StartupLease::acquire(&h).unwrap();
        assert!(!observer.can_activate());
        drop(observer);
        fs::write(h.join("release"), b"finish").unwrap();
        assert!(child.wait().unwrap().success());
        assert!(StartupLease::acquire(&h).unwrap().can_activate());
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn already_exchanged_current_version_finishes_receipt_without_swap() {
        let t = home();
        let h = canonical(&t);
        install_verified(&h, &archive("1.0.0", |_| {}), "1.0.0").unwrap();
        let bytes = archive("2.0.0", |_| {});
        let (r, p) = prepare(&h, &bytes, "2.0.0");
        let incoming = r.join(&p.archive_sha256).join("incoming.app");
        exchange(&incoming, &h.join("Applications/RichOS.app")).unwrap();
        let mut lease = StartupLease::acquire(&h).unwrap();
        assert!(activate_prepared_above(&mut lease, "2.0.0")
            .unwrap()
            .is_none());
        assert_eq!(preferred(&h).unwrap().unwrap().version, "2.0.0");
        assert!(!r.join("prepared.json").exists());
        assert_eq!(
            fs::read(incoming.join("Contents/Resources/fixture-version")).unwrap(),
            b"1.0.0"
        );
    }
    #[test]
    fn newer_running_build_retires_obsolete_pending_without_mutating_app() {
        let t = home();
        let h = canonical(&t);
        let old = stage_verified(&h, &archive("2.0.0", |_| {}), "2.0.0").unwrap();
        let mut lease = StartupLease::acquire(&h).unwrap();
        assert!(activate_prepared_above(&mut lease, "4.0.0")
            .unwrap()
            .is_none());
        assert!(staged(&h).unwrap().is_none());
        drop(lease);
        stage_verified(&h, &archive("5.0.0", |_| {}), "5.0.0").unwrap();
        assert_eq!(staged(&h).unwrap().unwrap().version, "5.0.0");
        assert!(!h.join("Applications/RichOS.app").exists());
        assert!(root(&h)
            .unwrap()
            .join(old.archive_sha256)
            .join("incoming.app")
            .exists());
    }
    #[test]
    fn compiled_version_mismatch_is_rejected_before_publication_and_does_not_block_next_update() {
        let t = home();
        let h = canonical(&t);
        let original = install_verified(&h, &archive("1.0.0", |_| {}), "1.0.0").unwrap();
        let malformed = archive_with_binary("3.0.0", &fixture_binary("2.0.0"), |_| {});
        assert!(stage_verified(&h, &malformed, "3.0.0").is_err());
        assert_eq!(
            fs::read(fixture_version(original.executable(&h))).unwrap(),
            b"1.0.0"
        );
        assert!(staged(&h).unwrap().is_none());
        stage_verified(&h, &archive("4.0.0", |_| {}), "4.0.0").unwrap();
        assert_eq!(staged(&h).unwrap().unwrap().version, "4.0.0");
    }
    #[test]
    fn probe_does_not_inherit_writable_files_or_sockets() {
        use std::os::unix::net::UnixStream;
        let t = home();
        let h = canonical(&t);
        let file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(h.join("host-file"))
            .unwrap();
        let (socket, mut peer) = UnixStream::pair().unwrap();
        peer.set_nonblocking(true).unwrap();
        for fd in [file.as_raw_fd(), socket.as_raw_fd()] {
            assert_eq!(unsafe { libc::fcntl(fd, libc::F_SETFD, 0) }, 0);
        }
        let source = h.join("fd-probe.c");
        let exe = h.join("fd-probe");
        let response =
            serde_json::json!({"identifier":ID,"version":"2.0.0","protocol":1}).to_string();
        fs::write(&source, format!("#include <unistd.h>\n#include <errno.h>\n#include <stdio.h>\nint main(void){{if(write({},\"X\",1)!=-1||errno!=EBADF)return 61;if(write({},\"Y\",1)!=-1||errno!=EBADF)return 62;puts({:?});return 0;}}",file.as_raw_fd(),socket.as_raw_fd(),response)).unwrap();
        assert!(std::process::Command::new("/usr/bin/cc")
            .arg(source)
            .arg("-o")
            .arg(&exe)
            .status()
            .unwrap()
            .success());
        let bytes = archive_with_binary("2.0.0", &fs::read(exe).unwrap(), |_| {});
        stage_verified(&h, &bytes, "2.0.0").unwrap();
        assert!(fs::read(h.join("host-file")).unwrap().is_empty());
        let mut byte = [0];
        assert_eq!(
            peer.read(&mut byte).unwrap_err().kind(),
            io::ErrorKind::WouldBlock
        );
    }
    #[test]
    fn external_newer_destination_is_not_replaced_by_older_pending() {
        let t = home();
        let h = canonical(&t);
        let staged = stage_verified(&h, &archive("2.0.0", |_| {}), "2.0.0").unwrap();
        extract(
            &archive("4.0.0", |_| {}),
            &h.join("Applications/RichOS.app"),
        )
        .unwrap();
        let mut lease = StartupLease::acquire(&h).unwrap();
        assert!(activate_prepared_above(&mut lease, "1.0.0").is_err());
        assert_eq!(
            bundle_version(&h.join("Applications/RichOS.app")).unwrap(),
            "4.0.0"
        );
        let r = root(&h).unwrap();
        assert!(!r.join("prepared.json").exists());
        assert!(r.join(staged.archive_sha256).join("obsolete.json").exists());
        drop(lease);
        stage_verified(&h, &archive("5.0.0", |_| {}), "5.0.0").unwrap();
    }
    #[test]
    fn collector_reclaims_verified_backup_and_superseded_payload_but_keeps_active_and_pending() {
        let t = home();
        let h = canonical(&t);
        install_verified(&h, &archive("1.0.0", |_| {}), "1.0.0").unwrap();
        let p2 = install_verified(&h, &archive("2.0.0", |_| {}), "2.0.0").unwrap();
        let p3 = stage_verified(&h, &archive("3.0.0", |_| {}), "3.0.0").unwrap();
        let p4 = stage_verified(&h, &archive("4.0.0", |_| {}), "4.0.0").unwrap();
        let r = root(&h).unwrap();
        let mut lease = StartupLease::acquire(&h).unwrap();
        let loaded = h.join("Applications/RichOS.app");
        assert_eq!(collect_retired(&mut lease, &loaded).unwrap(), 2);
        assert_eq!(bundle_version(&loaded).unwrap(), "2.0.0");
        assert!(!r.join(p2.archive_sha256).join("incoming.app").exists());
        assert!(!r.join(p3.archive_sha256).join("incoming.app").exists());
        assert!(r.join(p4.archive_sha256).join("incoming.app").exists());
        assert_eq!(collect_retired(&mut lease, &loaded).unwrap(), 0);
    }
    #[test]
    fn collector_replays_partial_deletion_but_refuses_replaced_inode() {
        let t = home();
        let h = canonical(&t);
        install_verified(&h, &archive("1.0.0", |_| {}), "1.0.0").unwrap();
        let p = install_verified(&h, &archive("2.0.0", |_| {}), "2.0.0").unwrap();
        let r = root(&h).unwrap();
        let tx = r.join(&p.archive_sha256);
        let incoming = tx.join("incoming.app");
        let retiring = tx.join("retiring.app");
        let record = Retirement::capture(&tx, &incoming).unwrap();
        write_document(&tx, "retirement.json", &record).unwrap();
        fs::rename(&incoming, &retiring).unwrap();
        fs::remove_file(retiring.join("Contents/Info.plist")).unwrap();
        let mut lease = StartupLease::acquire(&h).unwrap();
        assert_eq!(
            collect_retired(&mut lease, &h.join("Applications/RichOS.app")).unwrap(),
            1
        );
        assert!(!retiring.exists());
        fs::create_dir(&retiring).unwrap();
        write_document(&tx, "retirement.json", &record).unwrap();
        assert!(collect_retired(&mut lease, &h.join("Applications/RichOS.app")).is_err());
        assert!(retiring.exists());
    }
    #[test]
    fn collector_vetoes_shared_session_and_loaded_backup_and_cleans_partial_allocation() {
        let t = home();
        let h = canonical(&t);
        install_verified(&h, &archive("1.0.0", |_| {}), "1.0.0").unwrap();
        let p = install_verified(&h, &archive("2.0.0", |_| {}), "2.0.0").unwrap();
        let r = root(&h).unwrap();
        let backup = r.join(p.archive_sha256).join("incoming.app");
        let mut lease = StartupLease::acquire(&h).unwrap();
        assert_eq!(collect_retired(&mut lease, &backup).unwrap(), 0);
        lease.begin_session().unwrap();
        let mut observer = StartupLease::acquire(&h).unwrap();
        assert_eq!(
            collect_retired(&mut observer, &h.join("Applications/RichOS.app")).unwrap(),
            0
        );
        drop(observer);
        drop(lease);
        let tx = r.join("b".repeat(64));
        fs::create_dir(&tx).unwrap();
        fs::set_permissions(&tx, fs::Permissions::from_mode(0o700)).unwrap();
        let payload = tx.join("incoming.app");
        fs::create_dir(&payload).unwrap();
        write_document(
            &tx,
            "allocated.json",
            &Retirement::capture(&tx, &payload).unwrap(),
        )
        .unwrap();
        fs::write(payload.join("partial"), b"incomplete extraction").unwrap();
        let mut lease = StartupLease::acquire(&h).unwrap();
        assert_eq!(
            collect_retired(&mut lease, &h.join("Applications/RichOS.app")).unwrap(),
            2
        );
        assert!(!payload.exists());
    }
    #[test]
    fn damaged_pending_cannot_strand_a_newer_update_when_old_publication_is_intact() {
        let t = home();
        let h = canonical(&t);
        install_verified(&h, &archive("1.0.0", |_| {}), "1.0.0").unwrap();
        let p = stage_verified(&h, &archive("2.0.0", |_| {}), "2.0.0").unwrap();
        let tx = root(&h).unwrap().join(p.archive_sha256);
        fs::write(tx.join("incoming.app/Contents/Info.plist"), b"truncated").unwrap();
        stage_verified(&h, &archive("3.0.0", |_| {}), "3.0.0").unwrap();
        assert_eq!(
            bundle_version(&h.join("Applications/RichOS.app")).unwrap(),
            "1.0.0"
        );
        assert!(tx.join("invalid.json").exists());
    }
    #[test]
    fn probe_scrubs_descriptor_above_lowered_soft_and_hard_limits() {
        const MARKER: &str = "RICHOS_PROBE_HIGH_FD_TEST";
        if std::env::var_os(MARKER).is_none() {
            let status = std::process::Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "tests::probe_scrubs_descriptor_above_lowered_soft_and_hard_limits",
                    "--nocapture",
                ])
                .env(MARKER, "1")
                .status()
                .unwrap();
            assert!(status.success());
            return;
        }
        let t = home();
        let h = canonical(&t);
        let file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(h.join("protected-file"))
            .unwrap();
        let fd = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_DUPFD, 1024) };
        assert!(fd >= 1024);
        let source = h.join("high-fd.c");
        let exe = h.join("high-fd");
        let response =
            serde_json::json!({"identifier":ID,"version":"2.0.0","protocol":1}).to_string();
        fs::write(&source,format!("#include <unistd.h>\n#include <errno.h>\n#include <stdio.h>\nint main(void){{if(write({},\"X\",1)!=-1||errno!=EBADF)return 61;puts({:?});return 0;}}",fd,response)).unwrap();
        assert!(std::process::Command::new("/usr/bin/cc")
            .arg(source)
            .arg("-o")
            .arg(&exe)
            .status()
            .unwrap()
            .success());
        let bytes = archive_with_binary("2.0.0", &fs::read(exe).unwrap(), |_| {});
        let limits = libc::rlimit {
            rlim_cur: 256,
            rlim_max: 256,
        };
        assert_eq!(unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &limits) }, 0);
        assert!(unsafe { libc::fcntl(fd, libc::F_GETFD) } >= 0);
        stage_verified(&h, &bytes, "2.0.0").unwrap();
        assert!(fs::read(h.join("protected-file")).unwrap().is_empty());
        unsafe {
            libc::close(fd);
        }
    }
    #[test]
    fn slow_staging_probe_does_not_block_another_normal_startup() {
        let t = home();
        let h = canonical(&t);
        install_verified(&h, &archive("1.0.0", |_| {}), "1.0.0").unwrap();
        let source = h.join("slow.c");
        let exe = h.join("slow");
        let response =
            serde_json::json!({"identifier":ID,"version":"2.0.0","protocol":1}).to_string();
        fs::write(&source,format!("#include <unistd.h>\n#include <stdio.h>\nint main(void){{usleep(1500000);puts({:?});return 0;}}",response)).unwrap();
        assert!(std::process::Command::new("/usr/bin/cc")
            .arg(source)
            .arg("-o")
            .arg(&exe)
            .status()
            .unwrap()
            .success());
        let bytes = archive_with_binary("2.0.0", &fs::read(exe).unwrap(), |_| {});
        let worker_home = h.clone();
        let worker = std::thread::spawn(move || stage_verified(&worker_home, &bytes, "2.0.0"));
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            let mut observer = StartupLease::acquire(&h).unwrap();
            if !observer.can_activate() {
                assert!(
                    !worker.is_finished(),
                    "slow stage unexpectedly finished before observation"
                );
                let publication = with_preferred(&h, |p| Ok(p.version.clone()))
                    .unwrap()
                    .unwrap();
                assert_eq!(publication, "1.0.0");
                observer.begin_session().unwrap();
                break;
            }
            drop(observer);
            assert!(std::time::Instant::now() < deadline);
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        assert_eq!(worker.join().unwrap().unwrap().version, "2.0.0");
    }
    #[test]
    fn retirement_uses_native_volume_uuid_and_rejects_changed_volume_or_legacy_device_pins() {
        let t = home();
        let h = canonical(&t);
        let tx = h.join("transaction");
        let payload = tx.join("incoming.app");
        ensure_dir(&tx, 0o700).unwrap();
        ensure_dir(&payload, 0o755).unwrap();
        let mut record = Retirement::capture(&tx, &payload).unwrap();
        let native = volume_uuid(&payload).unwrap();
        assert_eq!(record.payload_volume, native);
        record.check(&tx, &payload).unwrap();
        let bytes = serde_json::to_vec(&record).unwrap();
        assert!(!String::from_utf8(bytes.clone()).unwrap().contains("_dev"));
        let reread: Retirement = serde_json::from_slice(&bytes).unwrap();
        reread.check(&tx, &payload).unwrap();
        record.payload_volume = "0".repeat(32);
        assert!(record.check(&tx, &payload).is_err());
        let legacy = serde_json::json!({"transaction_dev":metadata(&tx).unwrap().dev(),"transaction_ino":metadata(&tx).unwrap().ino(),"payload_dev":metadata(&payload).unwrap().dev(),"payload_ino":metadata(&payload).unwrap().ino()});
        assert!(serde_json::from_value::<Retirement>(legacy).is_err());
    }
}
