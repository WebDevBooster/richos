//! **Start at login, quietly** (dictation plan revision 2, section 6 "Where the tool runs, and
//! who starts it", section 9 slice 5; the CEO's answer A, 2026-10-08: *"Yes, quietly. But still
//! show the splash screen etc as usual ... when the user actually starts the RichOS app as
//! opposed to just using the dictation tool."*).
//!
//! The login start is the dictation tool alone: a LaunchAgent inside the app's bundle,
//! `Contents/Library/LaunchAgents/com.richos.app.dictation.plist` (placed by `bundle.macOS.files`
//! in `tauri.conf.json`), registered with `SMAppService.agent(plistName:)` when he turns dictation
//! on and both permissions are allowed, and unregistered when he turns it off. launchd starts the
//! tool at once and at every login, and starts it again if it dies.
//!
//! **Only an installed copy registers** (Frank's B2). A `nightly-launch.sh` folder copy runs on a
//! folder HOME, and a LaunchAgent registered from it would boot that copy at the next login on
//! his real HOME, against his daily driver's data. So registration needs every fact in
//! [`Facts`] to hold, and anywhere else the app runs the tool as its own child, which ends with
//! the app (`dictation_app.rs`). The decision is pure ([`decide`]) so each refusal is a test.
//!
//! **The macOS edges** ([`mac`]): `SMAppService` through objc2's runtime with the
//! ServiceManagement framework linked (no new package; the plan's measured fact table), the
//! status it reports (shown as Iris's line 3, "Switched off in Login Items", when macOS has the
//! background item switched off), and `NSWorkspace openApplicationAtURL:` with a new instance,
//! which is how the tool starts the app for a Dock, Finder or `open -a` open that LaunchServices
//! handed to the tool (section 6, "Opening RichOS while only the tool runs").

use std::path::{Path, PathBuf};

/// The LaunchAgent's label, which is also its plist's name inside the bundle.
pub const AGENT_LABEL: &str = "com.richos.app.dictation";
/// The plist's file name, as `SMAppService.agent(plistName:)` wants it.
pub const AGENT_PLIST: &str = "com.richos.app.dictation.plist";
/// Where Tauri puts it: `bundle.macOS.files` in `tauri.conf.json`, relative to `Contents`.
pub const AGENT_PLIST_IN_BUNDLE: &str = "Library/LaunchAgents/com.richos.app.dictation.plist";
/// macOS 13 is where `SMAppService` begins; an older Mac gets dictation only while RichOS is open.
pub const LOGIN_START_MACOS: u32 = 13;

/// The facts the registration decision is made of, read by [`gather`] and passed in explicitly
/// so the decision touches no environment and can be tested.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Facts {
    /// `$HOME`, when set and not empty.
    pub home: Option<PathBuf>,
    /// The account's home as the passwd database reports it (`getpwuid_r`), when it could be read.
    pub passwd_home: Option<PathBuf>,
    /// `$CFFIXED_USER_HOME`, when set and not empty (a `nightly-launch.sh` copy sets it).
    pub fixed_home: Option<PathBuf>,
    /// The data folder this app writes to.
    pub data_dir: PathBuf,
    /// This build's bundle identifier.
    pub identifier: String,
    /// The bundle around the executable, when it is in one.
    pub bundle: Option<PathBuf>,
    /// The macOS major version, when it could be read.
    pub macos_major: Option<u32>,
}

/// Why a copy cannot register the login start: Iris's line 2 picks its wording from the kind.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    /// This Mac is older than macOS 13: *"To keep dictation on with RichOS closed, your Mac needs
    /// macOS 13 or later."*
    OldMacos(u32),
    /// Not the installed copy on the account's real home: *"When you close RichOS, dictation
    /// stops until you open it again."* Each entry is one failed fact, a sentence for the log.
    NotInstalled(Vec<String>),
}

impl Refusal {
    /// The sheet's `copy` word (`dictation_app::View::copy`).
    pub fn copy_word(&self) -> &'static str {
        match self {
            Refusal::OldMacos(_) => "old-macos",
            Refusal::NotInstalled(_) => "open-only",
        }
    }

    pub fn describe(&self) -> String {
        match self {
            Refusal::OldMacos(major) => format!("this Mac runs macOS {major}, and the login start needs macOS {LOGIN_START_MACOS} or later"),
            Refusal::NotInstalled(why) => why.join("; "),
        }
    }
}

/// Where an installed copy keeps its data, for a home.
pub fn installed_data_dir(home: &Path, identifier: &str) -> PathBuf {
    crate::activation::installed_data_dir(home, identifier)
}

/// **THE DECISION.** `Ok(())` when this copy may register the login start: an installed copy on
/// the account's real home and the installed data folder, in a bundle, on macOS 13 or later.
pub fn decide(f: &Facts) -> Result<(), Refusal> {
    if let Some(major) = f.macos_major {
        if major < LOGIN_START_MACOS {
            return Err(Refusal::OldMacos(major));
        }
    }
    let mut unmet = Vec::new();
    match (&f.home, &f.passwd_home) {
        (None, _) => unmet.push("HOME is not set, so this cannot be shown to be the account's real home".to_string()),
        (_, None) => unmet.push("the account's home could not be read from the passwd database".to_string()),
        (Some(home), Some(real)) if home != real => {
            unmet.push(format!("this copy runs on HOME {}, and the account's home is {}", home.display(), real.display()))
        }
        _ => {}
    }
    if let (Some(fixed), Some(real)) = (&f.fixed_home, &f.passwd_home) {
        if fixed != real {
            unmet.push(format!("CFFIXED_USER_HOME is {}, and the account's home is {}", fixed.display(), real.display()));
        }
    }
    if let Some(real) = &f.passwd_home {
        let installed = installed_data_dir(real, &f.identifier);
        if f.data_dir != installed {
            unmet.push(format!("this copy writes to {}, and an install writes to {}", f.data_dir.display(), installed.display()));
        }
    }
    if f.bundle.is_none() {
        unmet.push("the executable is not inside a .app bundle, so there is no LaunchAgent to register".to_string());
    }
    if unmet.is_empty() {
        Ok(())
    } else {
        Err(Refusal::NotInstalled(unmet))
    }
}

/// What the switch does to the registration. Pure, so it is a test.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Follow {
    /// Dictation is on in an installed copy: register (idempotent; at every app start too).
    Register,
    /// Dictation is off in an installed copy: unregister, and launchd stops the tool.
    Unregister,
    /// Not an installed copy: the app runs the tool as its child, and launchd is never told.
    Nothing,
}

pub fn follow_switch(on: bool, installed: bool) -> Follow {
    match (installed, on) {
        (false, _) => Follow::Nothing,
        (true, true) => Follow::Register,
        (true, false) => Follow::Unregister,
    }
}

/// `SMAppServiceStatus`, by value.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    NotRegistered,
    Enabled,
    /// macOS has the background item switched off in Login Items (Iris's line 3).
    RequiresApproval,
    NotFound,
}

impl Status {
    pub fn from_raw(raw: isize) -> Status {
        match raw {
            1 => Status::Enabled,
            2 => Status::RequiresApproval,
            3 => Status::NotFound,
            _ => Status::NotRegistered,
        }
    }

    /// The sheet's `login` word (`dictation_app::View::login`).
    pub fn login_word(self) -> &'static str {
        match self {
            Status::Enabled => "approved",
            Status::RequiresApproval => "needs-approval",
            Status::NotRegistered | Status::NotFound => "none",
        }
    }
}

/// **Whether a running tool restarts for the app that just said hello** (section 6, "When an app
/// of a newer version says hello, the tool finishes any dictation in progress, then exits, and
/// launchd starts the new executable from the same bundle path"). Compared for difference, not
/// order: after the bundle's directory exchange the executable at the registered path IS the
/// app's version, whichever way the version moved (a rollback included), and a tool of any other
/// version is a tool from a bundle that no longer exists.
pub fn restart_for(tool_version: &str, app_version: &str) -> bool {
    !tool_version.is_empty() && !app_version.is_empty() && tool_version != app_version
}

/// The exit code a tool ends with when it restarts for a new version: launchd's `KeepAlive` with
/// `SuccessfulExit` false starts it again only after a non-zero exit, so this is not 0.
pub const RESTART_EXIT: i32 = 4;

/// The account's home from the passwd database, never from the environment.
#[cfg(unix)]
pub fn passwd_home() -> Option<PathBuf> {
    use std::ffi::CStr;
    let mut pw: libc::passwd = unsafe { std::mem::zeroed() };
    let mut buf = vec![0u8; 4096];
    let mut out: *mut libc::passwd = std::ptr::null_mut();
    // SAFETY: a zeroed passwd, a buffer we own with its length, and an out-pointer on our stack.
    let rc = unsafe { libc::getpwuid_r(libc::geteuid(), &mut pw, buf.as_mut_ptr().cast(), buf.len(), &mut out) };
    if rc != 0 || out.is_null() || pw.pw_dir.is_null() {
        return None;
    }
    // SAFETY: pw_dir points into `buf`, which outlives this read.
    let dir = unsafe { CStr::from_ptr(pw.pw_dir) }.to_str().ok()?;
    (!dir.is_empty()).then(|| PathBuf::from(dir))
}

fn env_path(name: &str) -> Option<PathBuf> {
    std::env::var_os(name).map(PathBuf::from).filter(|p| !p.as_os_str().is_empty())
}

/// Read the facts off this process. The only function here that touches the environment.
pub fn gather(data_dir: &Path, identifier: &str, macos_major: Option<u32>) -> Facts {
    Facts {
        home: env_path("HOME"),
        passwd_home: passwd_home(),
        fixed_home: env_path("CFFIXED_USER_HOME"),
        data_dir: data_dir.to_path_buf(),
        identifier: identifier.to_string(),
        bundle: std::env::current_exe().ok().as_deref().and_then(crate::activation::bundle_root),
        macos_major,
    }
}

/// **The data folder a launchd-started tool uses**: the installed one for the account's real
/// home. launchd expands nothing in a plist, so the tool is started with no `--data-dir` and
/// computes it here; the registration refusal above is what guarantees it is the same folder the
/// app that registered it writes to. Refused when `HOME` disagrees with the passwd home.
pub fn launchd_data_dir(identifier: &str) -> Result<PathBuf, String> {
    let real = passwd_home().ok_or("the account's home could not be read from the passwd database")?;
    if let Some(home) = env_path("HOME") {
        if home != real {
            return Err(format!("HOME is {}, and the account's home is {}", home.display(), real.display()));
        }
    }
    Ok(installed_data_dir(&real, identifier))
}

/// The ServiceManagement and AppKit calls. macOS only; each one is a documented method.
#[cfg(target_os = "macos")]
pub mod mac {
    use super::{Status, AGENT_PLIST};
    use objc2::msg_send;
    use objc2::runtime::{AnyClass, AnyObject, Bool};
    use std::ffi::CStr;
    use std::path::Path;

    #[link(name = "ServiceManagement", kind = "framework")]
    extern "C" {}

    /// An `NSString` from Rust text, autoreleased.
    unsafe fn ns_string(text: &str) -> *mut AnyObject {
        let class = AnyClass::get(c"NSString").expect("NSString");
        let bytes = text.as_ptr().cast::<std::ffi::c_void>();
        // NSUTF8StringEncoding is 4.
        let alloc: *mut AnyObject = msg_send![class, alloc];
        let s: *mut AnyObject = msg_send![alloc, initWithBytes: bytes, length: text.len(), encoding: 4usize];
        let _: () = msg_send![s, autorelease];
        s
    }

    unsafe fn describe_error(error: *mut AnyObject) -> String {
        if error.is_null() {
            return "no error reported".into();
        }
        let desc: *mut AnyObject = msg_send![error, localizedDescription];
        if desc.is_null() {
            return "an error with no description".into();
        }
        let p: *const std::ffi::c_char = msg_send![desc, UTF8String];
        if p.is_null() { "an error with no description".into() } else { CStr::from_ptr(p).to_string_lossy().into_owned() }
    }

    /// `SMAppService.agent(plistName:)` for the dictation tool, or `None` below macOS 13.
    unsafe fn service() -> Option<*mut AnyObject> {
        let class = AnyClass::get(c"SMAppService")?;
        let name = ns_string(AGENT_PLIST);
        let service: *mut AnyObject = msg_send![class, agentServiceWithPlistName: name];
        (!service.is_null()).then_some(service)
    }

    /// The agent's status as macOS reports it; `None` when `SMAppService` is not on this Mac.
    pub fn status() -> Option<Status> {
        objc2::rc::autoreleasepool(|_| {
            // SAFETY: documented class and instance methods.
            unsafe {
                let service = service()?;
                let raw: isize = msg_send![service, status];
                Some(Status::from_raw(raw))
            }
        })
    }

    /// Register the agent. Already registered is success (the app re-registers at each start).
    pub fn register() -> Result<Status, String> {
        objc2::rc::autoreleasepool(|_| {
            // SAFETY: documented methods; `error` is an out-pointer on our stack.
            unsafe {
                let service = service().ok_or("SMAppService is not on this Mac (macOS 13 or later)")?;
                let before: isize = msg_send![service, status];
                if Status::from_raw(before) == Status::Enabled {
                    return Ok(Status::Enabled);
                }
                let mut error: *mut AnyObject = std::ptr::null_mut();
                let ok: Bool = msg_send![service, registerAndReturnError: &mut error];
                let after: isize = msg_send![service, status];
                if ok.as_bool() || Status::from_raw(after) == Status::Enabled {
                    return Ok(Status::from_raw(after));
                }
                Err(format!("{} (status {after})", describe_error(error)))
            }
        })
    }

    /// Unregister the agent; launchd stops the tool. Not registered is success.
    pub fn unregister() -> Result<(), String> {
        objc2::rc::autoreleasepool(|_| {
            // SAFETY: as above.
            unsafe {
                let Some(service) = service() else { return Ok(()) };
                let before: isize = msg_send![service, status];
                if matches!(Status::from_raw(before), Status::NotRegistered | Status::NotFound) {
                    return Ok(());
                }
                let mut error: *mut AnyObject = std::ptr::null_mut();
                let ok: Bool = msg_send![service, unregisterAndReturnError: &mut error];
                if ok.as_bool() {
                    return Ok(());
                }
                let after: isize = msg_send![service, status];
                if matches!(Status::from_raw(after), Status::NotRegistered | Status::NotFound) {
                    return Ok(());
                }
                Err(format!("{} (status {after})", describe_error(error)))
            }
        })
    }

    /// System Settings on General, Login Items & Extensions (`+[SMAppService
    /// openSystemSettingsLoginItems]`), where RichOS's switch under Allow in the Background is.
    pub fn open_login_items() -> bool {
        objc2::rc::autoreleasepool(|_| {
            // SAFETY: a documented class method with no arguments.
            unsafe {
                let Some(class) = AnyClass::get(c"SMAppService") else { return false };
                let _: () = msg_send![class, openSystemSettingsLoginItems];
                true
            }
        })
    }

    /// **Start the app** from `bundle` as a LaunchServices launch of its own: `NSWorkspace
    /// openApplicationAtURL:configuration:completionHandler:` with `createsNewApplicationInstance`,
    /// so the app is launchd's child (ppid 1) with an ordinary start, a fresh launch record, the
    /// splash as the switch says, and a counted start. The tool, being the same bundle, would
    /// otherwise be what LaunchServices "opens". `false` when the call could not be made.
    pub fn open_app(bundle: &Path) -> bool {
        objc2::rc::autoreleasepool(|_| {
            // SAFETY: documented AppKit and Foundation methods; a nil completion handler is allowed.
            unsafe {
                let (Some(url_class), Some(ws_class), Some(cfg_class)) =
                    (AnyClass::get(c"NSURL"), AnyClass::get(c"NSWorkspace"), AnyClass::get(c"NSWorkspaceOpenConfiguration"))
                else {
                    return false;
                };
                let path = ns_string(&bundle.display().to_string());
                let url: *mut AnyObject = msg_send![url_class, fileURLWithPath: path];
                if url.is_null() {
                    return false;
                }
                let cfg: *mut AnyObject = msg_send![cfg_class, configuration];
                let _: () = msg_send![cfg, setCreatesNewApplicationInstance: true];
                let _: () = msg_send![cfg, setActivates: true];
                let ws: *mut AnyObject = msg_send![ws_class, sharedWorkspace];
                let handler: *const AnyObject = std::ptr::null();
                let _: () = msg_send![ws, openApplicationAtURL: url, configuration: cfg, completionHandler: handler];
                true
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn installed() -> Facts {
        Facts {
            home: Some("/Users/alex".into()),
            passwd_home: Some("/Users/alex".into()),
            fixed_home: None,
            data_dir: "/Users/alex/Library/Application Support/com.richos.app".into(),
            identifier: "com.richos.app".into(),
            bundle: Some("/Users/alex/Applications/RichOS.app".into()),
            macos_major: Some(15),
        }
    }

    /// INVARIANT (B2): the installed copy on the real home registers; nothing else does.
    #[test]
    fn an_installed_copy_on_the_real_home_registers() {
        assert_eq!(decide(&installed()), Ok(()));
        let mut fixed_same = installed();
        fixed_same.fixed_home = Some("/Users/alex".into());
        assert_eq!(decide(&fixed_same), Ok(()), "CFFIXED_USER_HOME equal to the real home is fine");
    }

    /// INVARIANT (B2): a nightly-launch.sh folder copy (HOME and CFFIXED_USER_HOME under the
    /// folder, data under that HOME) never registers, and each failed fact is named.
    #[test]
    fn a_folder_copy_never_registers() {
        let mut f = installed();
        f.home = Some("/Users/alex/myrichos-nightly-a/home.noindex".into());
        f.fixed_home = Some("/Users/alex/myrichos-nightly-a/home.noindex".into());
        f.data_dir = "/Users/alex/myrichos-nightly-a/home.noindex/Library/Application Support/com.richos.app".into();
        match decide(&f) {
            Err(Refusal::NotInstalled(why)) => {
                assert_eq!(why.len(), 3, "{why:?}");
                assert!(why[0].contains("HOME"), "{why:?}");
                assert!(why[1].contains("CFFIXED_USER_HOME"), "{why:?}");
                assert!(why[2].contains("an install writes to"), "{why:?}");
                assert_eq!(Refusal::NotInstalled(why).copy_word(), "open-only");
            }
            other => panic!("{other:?}"),
        }
    }

    /// INVARIANT (B2): a redirected data folder alone is enough to refuse, as is a copy outside a
    /// bundle, a missing HOME, and an unreadable passwd home.
    #[test]
    fn each_fact_alone_refuses() {
        let mut data = installed();
        data.data_dir = "/var/folders/xx/T/richos-test/data".into();
        assert!(matches!(decide(&data), Err(Refusal::NotInstalled(ref w)) if w.len() == 1 && w[0].contains("an install writes to")));
        let mut no_bundle = installed();
        no_bundle.bundle = None;
        assert!(matches!(decide(&no_bundle), Err(Refusal::NotInstalled(ref w)) if w.len() == 1 && w[0].contains("bundle")));
        let mut no_home = installed();
        no_home.home = None;
        assert!(matches!(decide(&no_home), Err(Refusal::NotInstalled(ref w)) if w.len() == 1 && w[0].contains("HOME is not set")));
        let mut no_passwd = installed();
        no_passwd.passwd_home = None;
        assert!(matches!(decide(&no_passwd), Err(Refusal::NotInstalled(ref w)) if w.len() == 1 && w[0].contains("passwd")));
    }

    /// INVARIANT: a Mac older than macOS 13 is refused with its own wording, before anything else.
    #[test]
    fn an_older_mac_is_refused_with_its_own_wording() {
        let mut f = installed();
        f.macos_major = Some(12);
        let r = decide(&f).unwrap_err();
        assert_eq!(r, Refusal::OldMacos(12));
        assert_eq!(r.copy_word(), "old-macos");
        assert!(r.describe().contains("macOS 13"), "{}", r.describe());
        let mut unknown = installed();
        unknown.macos_major = None;
        assert_eq!(decide(&unknown), Ok(()), "an unreadable version is not an old Mac");
    }

    /// INVARIANT: the switch registers on, unregisters off, and leaves launchd alone anywhere
    /// but an installed copy.
    #[test]
    fn the_switch_follows_the_copy() {
        assert_eq!(follow_switch(true, true), Follow::Register);
        assert_eq!(follow_switch(false, true), Follow::Unregister);
        assert_eq!(follow_switch(true, false), Follow::Nothing);
        assert_eq!(follow_switch(false, false), Follow::Nothing);
    }

    /// INVARIANT: SMAppServiceStatus by value, and Iris's line 3 only for requiresApproval.
    #[test]
    fn the_status_values_and_words() {
        assert_eq!(Status::from_raw(0), Status::NotRegistered);
        assert_eq!(Status::from_raw(1), Status::Enabled);
        assert_eq!(Status::from_raw(2), Status::RequiresApproval);
        assert_eq!(Status::from_raw(3), Status::NotFound);
        assert_eq!(Status::from_raw(99), Status::NotRegistered);
        assert_eq!(Status::Enabled.login_word(), "approved");
        assert_eq!(Status::RequiresApproval.login_word(), "needs-approval");
        assert_eq!(Status::NotRegistered.login_word(), "none");
        assert_eq!(Status::NotFound.login_word(), "none");
    }

    /// INVARIANT (section 6): the tool restarts for an app of any other version, never for its
    /// own, and never on an empty version; the exit code is non-zero so launchd starts it again.
    #[test]
    fn the_restart_decision() {
        assert!(restart_for("1.2.0-nightly.20261008.46", "1.2.0-nightly.20261008.47"));
        assert!(restart_for("1.2.0-nightly.20261008.47", "1.2.0-nightly.20261008.46"), "a rollback restarts too");
        assert!(!restart_for("1.2.0", "1.2.0"));
        assert!(!restart_for("", "1.2.0"));
        assert!(!restart_for("1.2.0", ""));
        assert_ne!(RESTART_EXIT, 0);
        assert_ne!(RESTART_EXIT, 3, "3 is another copy holding the key");
    }

    /// INVARIANT: the LaunchAgent plist in the source tree says what section 6 and M9 require,
    /// and the bundle puts it where SMAppService.agent looks.
    #[test]
    fn the_launch_agent_plist() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR"));
        let plist = std::fs::read_to_string(root.join("launchd").join(AGENT_PLIST)).expect("the plist is in src-tauri/launchd");
        for (key, value) in [
            ("Label", AGENT_LABEL),
            ("BundleProgram", "Contents/MacOS/richos-tauri"),
            ("LimitLoadToSessionType", "Aqua"),
            ("ProcessType", "Interactive"),
            ("AssociatedBundleIdentifiers", "com.richos.app"),
        ] {
            assert!(plist.contains(&format!("<key>{key}</key>")), "{key}");
            assert!(plist.contains(&format!("<string>{value}</string>")), "{key} = {value}");
        }
        assert!(plist.contains("<string>--richos-dictation</string>"), "the tool's argument");
        assert!(!plist.contains("--data-dir"), "launchd expands nothing: the tool computes its data folder");
        assert!(plist.contains("<key>RunAtLoad</key>\n\t<true/>"), "starts at login");
        assert!(plist.contains("<key>SuccessfulExit</key>\n\t\t<false/>"), "restarted only after a non-zero exit: off (0) stays off");
        let conf: serde_json::Value = serde_json::from_slice(&std::fs::read(root.join("tauri.conf.json")).unwrap()).unwrap();
        let files = &conf["bundle"]["macOS"]["files"];
        assert_eq!(files[AGENT_PLIST_IN_BUNDLE], serde_json::json!(format!("launchd/{AGENT_PLIST}")), "{files}");
    }

    /// INVARIANT: the launchd tool's data folder is the installed one for the passwd home, and
    /// a HOME that disagrees is refused rather than used.
    #[test]
    fn the_launchd_data_folder_is_the_installed_one() {
        let real = passwd_home().expect("a passwd home in a test process");
        assert_eq!(installed_data_dir(&real, "com.richos.app"), real.join("Library/Application Support/com.richos.app"));
        let answer = launchd_data_dir("com.richos.app");
        match std::env::var_os("HOME").map(PathBuf::from) {
            Some(home) if home != real => assert!(answer.is_err(), "{answer:?}"),
            _ => assert_eq!(answer.unwrap(), installed_data_dir(&real, "com.richos.app")),
        }
    }
}
