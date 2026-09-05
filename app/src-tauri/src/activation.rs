//! WHETHER THIS LAUNCH IS ALLOWED TO TAKE THE SCREEN.
//!
//! =========================================================================================
//! THE RULE, AND IT IS THE WHOLE FILE
//! =========================================================================================
//!
//!     RichOS comes to the front, takes keyboard focus and appears in the Dock ONLY when it
//!     can positively establish that it is an installed launch performed by the person who
//!     installed it. Every other boot is ACCESSORY: no Dock icon, no window put on his
//!     screen, no activation, and nothing taken away from whatever he is typing into.
//!
//! WHAT "ACCESSORY" COSTS, so nobody has to find out: the window is built INVISIBLE. That
//! is not tidiness, it is the only lever that works — `main.rs`'s `set_activation_policy`
//! block carries the measurement and the tao citations. The window is fully constructed and
//! fully driveable; a harness that wants it on screen calls `show()`.
//!
//! Safe by default, loud by exception. A boot that cannot prove it is his is treated as one
//! that is not.
//!
//! =========================================================================================
//! WHY IT IS SHAPED THIS WAY AND NOT THE OBVIOUS WAY
//! =========================================================================================
//!
//! The obvious shape is the opposite one: detect a test boot and stand down for it. It was
//! written that way first and it is wrong, for a reason the CEO gave in one sentence on
//! 2026-09-06 — *"GENERAL issue if and when the same or similar tests are run by others in
//! the future"*. Detecting a test means enumerating the test shapes that exist today. The
//! author of the next harness has never read this file, will not set a variable he has never
//! heard of, and will not recognize himself in a list. A hand-maintained inventory of known
//! test shapes gets SHORTER relative to reality every time somebody invents a new one, and
//! it reports green the whole way down — which is the exact failure this repository spent
//! 2026-09-04 and 2026-09-05 removing from five other checks.
//!
//! Inverting it removes the enumeration entirely. There is no list of tests here, and adding
//! a new kind of test cannot defeat it, because a new kind of test is simply one more thing
//! that is not an installed launch.
//!
//! =========================================================================================
//! WHAT AN INSTALLED LAUNCH IS — THREE FACTS, ALL REQUIRED
//! =========================================================================================
//!
//! B  THE BUNDLE. The running executable sits at `<something>.app/Contents/MacOS/<file>`
//!    and `<something>.app/Contents/Info.plist` declares this build's own bundle identifier.
//!    A `cargo build` binary at `target/debug/richos-tauri` is not in a bundle at all, and a
//!    stray copy of the executable somewhere else is not the thing he installed.
//!
//! D  THE DATA DIRECTORY. The directory this boot will actually write to is the installed
//!    one for the current home — `$HOME/Library/Application Support/<identifier>`. This is
//!    the fact that covers "a fresh temporary directory" WITHOUT naming temporary
//!    directories: a harness that redirects the data directory, or runs under a scratch
//!    `HOME`, or overrides it with a variable this file has never heard of, fails D by
//!    construction, because whatever it redirected to is not the installed location.
//!
//!    It is computed from the data directory the caller is ABOUT TO USE, not from the
//!    resolver, so a later override that changes `data_dir` changes this answer too.
//!
//! P  THE PARENT. `getppid()` is 1. macOS launches an application by handing it to launchd,
//!    so a double-clicked app is launchd's child and nothing on the machine is holding it.
//!    A harness, by contrast, has to hold the process it boots — it needs the pid to wait on
//!    it, to read its output and to kill it — so it is the parent. Measured on this machine
//!    on 2026-09-06: `ps -axo pid,ppid,comm` reports ppid 1 for Finder (418) and for
//!    Terminal (1586), both LaunchServices launches.
//!
//!    P is the condition that holds for the hardest case, which B and D do not reach: a
//!    future harness that boots the REAL installed bundle against the REAL data directory.
//!    It cannot do that without being the parent.
//!
//! =========================================================================================
//! THE OVERRIDE, IN BOTH DIRECTIONS
//! =========================================================================================
//!
//! `RICHOS_ACTIVATION=regular` forces the front; `RICHOS_ACTIVATION=accessory` forces the
//! back. It is deliberately NOT what the guarantee rests on — a variable only ever helps
//! someone who already knows about the problem — but two callers need it:
//!
//!   * `updates.rs::update_relaunch` sets `regular` before `app.restart()`. Tauri's restart
//!     SPAWNS a replacement and exits (`tauri-2.11.5/src/process.rs:74-88`), so for a short
//!     window the replacement's parent is the dying original rather than launchd, and P
//!     would be read as false. Left to the race, an update would occasionally bring RichOS
//!     back with no Dock icon and no window in front — which reads as "the update deleted
//!     the app". The marker removes the race rather than narrowing it.
//!   * an operator who wants the other answer for one run, in either direction.
//!
//! =========================================================================================
//! WHAT THIS FILE DOES NOT COVER, NAMED RATHER THAN LEFT TO BE FOUND
//! =========================================================================================
//!
//! * NOT macOS. `Presentation` is decided the same way everywhere so the tests below run
//!   everywhere, but only the macOS call site applies an activation policy — that is the
//!   only platform RichOS ships on, and B is written in macOS bundle layout. A Windows or
//!   Linux port must decide its own equivalent of B rather than inheriting this one.
//! * A HARNESS THAT SETS `RICHOS_ACTIVATION=regular`. It asked for the front and it gets it.
//! * A SECOND WINDOW opened later by the running app. This decides the launch, once.

use std::path::{Path, PathBuf};

/// How this launch presents itself.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Presentation {
    /// Dock icon, activation, keyboard focus — the installed launch.
    Regular,
    /// No Dock icon, no activation, no focus, and nothing put on his screen. A real,
    /// driveable window all the same — it is built invisible, not omitted.
    Accessory,
}

/// Why the answer is what it is. Every variant is a SENTENCE a harness author reads in the
/// boot log, because the log is where he will meet this rule.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Reason {
    /// `RICHOS_ACTIVATION` named the answer.
    Override(String),
    /// B, D and P all held.
    InstalledLaunch,
    /// One or more of B, D, P did not hold. Each entry is one failed condition.
    NotEstablished(Vec<String>),
}

/// The facts this decision is made of. Gathered by [`gather`]; passed in explicitly so the
/// decision itself touches no environment, no clock and no file system and can be tested.
#[derive(Debug, Clone)]
pub struct LaunchFacts {
    /// `std::env::current_exe()`, or `None` when it could not be read.
    pub exe: Option<PathBuf>,
    /// The bundle identifier declared by the `Info.plist` of the bundle around `exe`, if the
    /// executable is in a bundle at all and the file could be read and parsed.
    pub bundle_identifier: Option<String>,
    /// This build's own configured identifier (`tauri.conf.json` -> `identifier`).
    pub own_identifier: String,
    /// The directory this boot will actually write to.
    pub data_dir: PathBuf,
    /// `$HOME`, or `None` when it is not set.
    pub home: Option<PathBuf>,
    /// `getppid()`.
    pub parent_pid: u32,
    /// `RICHOS_ACTIVATION`, trimmed and lower-cased, when it is set to something non-empty.
    pub override_request: Option<String>,
}

/// The answer plus the reason for it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Decision {
    pub presentation: Presentation,
    pub reason: Reason,
}

impl Decision {
    /// The boot line, WITHOUT the `[richos] ` prefix — the CALL SITE supplies that as a
    /// string literal, and it has to. `gui-boot.test.sh`'s S1 case reads the first string
    /// literal of every `eprintln!` in this crate and fails any that does not begin
    /// `[richos]`, because a line the accounting cannot see is a line the accounting cannot
    /// hold to account. Printing this through a bare positional format string would pass the
    /// prefix at run time and fail S1 at read time, so the prefix lives where S1 looks.
    ///
    /// It is the ONLY place a future harness author is guaranteed to meet this rule, so it
    /// says what happened, why, and how to ask for the other answer.
    pub fn log_message(&self) -> String {
        match (&self.presentation, &self.reason) {
            (Presentation::Regular, Reason::InstalledLaunch) => {
                "activation: regular — an installed launch by the person who installed it, so \
                 RichOS comes to the front and takes the keyboard"
                    .to_string()
            }
            (Presentation::Regular, Reason::Override(v)) => format!(
                "activation: regular — RICHOS_ACTIVATION={v} asked for the front. \
                 Without it this boot would have been judged on its own facts."
            ),
            (Presentation::Accessory, Reason::Override(v)) => format!(
                "activation: accessory — RICHOS_ACTIVATION={v} asked for the back. \
                 No Dock icon, no window on screen, no focus taken."
            ),
            (Presentation::Accessory, Reason::NotEstablished(why)) => format!(
                "activation: accessory — no Dock icon, no window on screen, no focus \
                 taken, because this is not an installed launch: {}. The window is still real \
                 and still driveable; call show() on it, or set RICHOS_ACTIVATION=regular for \
                 the whole normal treatment.",
                why.join("; ")
            ),
            // Unreachable by construction (`decide` never pairs these), and answered rather
            // than `unreachable!()`: a panic here would turn a presentation question into a
            // dead app, which is strictly worse than the defect it would be reporting.
            (p, r) => format!("activation: {p:?} — {r:?}"),
        }
    }
}

/// The bundle directory around an executable, when the executable is laid out the way macOS
/// lays one out: `<name>.app/Contents/MacOS/<file>`. Pure path shape; touches no disk.
pub fn bundle_root(exe: &Path) -> Option<PathBuf> {
    let macos_dir = exe.parent()?;
    if macos_dir.file_name()? != "MacOS" {
        return None;
    }
    let contents = macos_dir.parent()?;
    if contents.file_name()? != "Contents" {
        return None;
    }
    let bundle = contents.parent()?;
    if bundle.extension()? != "app" {
        return None;
    }
    Some(bundle.to_path_buf())
}

/// `CFBundleIdentifier` out of an XML `Info.plist`.
///
/// A short reader rather than a plist crate, and that is a deliberate trade: it is asked ONE
/// question, on a file this repository produces itself (`package-app.sh` writes it, and
/// `/Users/alex/Applications/RichOS.app/Contents/Info.plist` was measured as
/// `XML 1.0 document text` on 2026-09-06). A binary plist returns `None`, which fails
/// condition B — the SAFE direction, because failing B costs a Dock icon and never costs the
/// CEO his keystrokes.
pub fn parse_bundle_identifier(plist: &str) -> Option<String> {
    let after_key = plist.split("<key>CFBundleIdentifier</key>").nth(1)?;
    let after_open = after_key.split("<string>").nth(1)?;
    let value = after_open.split("</string>").next()?;
    let value = value.trim();
    if value.is_empty() {
        None
    } else {
        Some(value.to_string())
    }
}

/// Where an install writes, for a given home and identifier. macOS layout.
pub fn installed_data_dir(home: &Path, identifier: &str) -> PathBuf {
    home.join("Library").join("Application Support").join(identifier)
}

/// THE DECISION. Pure: every fact it uses arrives in `facts`.
pub fn decide(facts: &LaunchFacts) -> Decision {
    if let Some(request) = facts.override_request.as_deref() {
        match request {
            "regular" | "activate" | "front" => {
                return Decision {
                    presentation: Presentation::Regular,
                    reason: Reason::Override(request.to_string()),
                }
            }
            "accessory" | "background" | "back" => {
                return Decision {
                    presentation: Presentation::Accessory,
                    reason: Reason::Override(request.to_string()),
                }
            }
            // A value nobody defined is NOT a third answer. It falls through to the facts,
            // so a typo cannot silently hand the screen to a test run.
            _ => {}
        }
    }

    let mut unmet: Vec<String> = Vec::new();

    // -- B, the bundle -------------------------------------------------------------------
    match facts.exe.as_deref() {
        None => unmet.push(
            "the running executable's own path could not be read, so it cannot be shown to be \
             an installed bundle"
                .to_string(),
        ),
        Some(exe) => match bundle_root(exe) {
            None => unmet.push(format!("{} is not inside a .app bundle", exe.display())),
            Some(bundle) => match facts.bundle_identifier.as_deref() {
                None => unmet.push(format!(
                    "{} carries no readable CFBundleIdentifier",
                    bundle.join("Contents").join("Info.plist").display()
                )),
                Some(found) if found != facts.own_identifier => unmet.push(format!(
                    "{} declares {found}, and this build is {}",
                    bundle.display(),
                    facts.own_identifier
                )),
                Some(_) => {}
            },
        },
    }

    // -- D, the data directory -----------------------------------------------------------
    match facts.home.as_deref() {
        None => unmet.push(
            "HOME is not set, so the installed data directory has no address to be compared \
             against"
                .to_string(),
        ),
        Some(home) => {
            let installed = installed_data_dir(home, &facts.own_identifier);
            if facts.data_dir != installed {
                unmet.push(format!(
                    "this boot writes to {}, and an install writes to {}",
                    facts.data_dir.display(),
                    installed.display()
                ));
            }
        }
    }

    // -- P, the parent -------------------------------------------------------------------
    if facts.parent_pid != 1 {
        unmet.push(format!(
            "a program is holding this process (parent pid {}), and macOS hands a launch to \
             launchd (pid 1)",
            facts.parent_pid
        ));
    }

    if unmet.is_empty() {
        Decision {
            presentation: Presentation::Regular,
            reason: Reason::InstalledLaunch,
        }
    } else {
        Decision {
            presentation: Presentation::Accessory,
            reason: Reason::NotEstablished(unmet),
        }
    }
}

/// Read the facts off this process. The ONLY function here that touches the world.
///
/// `data_dir` is a parameter and not a resolution, deliberately: the caller has already
/// decided where this boot writes — including through any override that lands later — and a
/// second, independent resolution here would be a copy that can disagree with it.
pub fn gather(data_dir: &Path, own_identifier: &str) -> LaunchFacts {
    let exe = std::env::current_exe().ok();
    let plist = exe
        .as_deref()
        .and_then(bundle_root)
        .and_then(|bundle| std::fs::read_to_string(bundle.join("Contents").join("Info.plist")).ok());
    LaunchFacts {
        exe,
        bundle_identifier: plist.as_deref().and_then(parse_bundle_identifier),
        own_identifier: own_identifier.to_string(),
        data_dir: data_dir.to_path_buf(),
        home: std::env::var_os("HOME")
            .map(PathBuf::from)
            .filter(|p| !p.as_os_str().is_empty()),
        parent_pid: parent_pid(),
        override_request: std::env::var("RICHOS_ACTIVATION")
            .ok()
            .map(|v| v.trim().to_ascii_lowercase())
            .filter(|v| !v.is_empty()),
    }
}

/// The value `RICHOS_ACTIVATION` is set to across `app.restart()`. Named once, here, so the
/// updater and the reader cannot drift apart on the spelling.
pub const OVERRIDE_ENV: &str = "RICHOS_ACTIVATION";
/// The value that asks for the front.
pub const OVERRIDE_REGULAR: &str = "regular";

#[cfg(unix)]
fn parent_pid() -> u32 {
    std::os::unix::process::parent_id()
}

/// Off unix there is no `getppid`, and 1 is the value that makes P hold. Condition P is
/// named as NOT COVERED off unix rather than silently answered — B and D still apply.
#[cfg(not(unix))]
fn parent_pid() -> u32 {
    1
}

#[cfg(test)]
mod tests {
    use super::*;

    fn installed(home: &str) -> LaunchFacts {
        LaunchFacts {
            exe: Some(PathBuf::from(format!(
                "{home}/Applications/RichOS.app/Contents/MacOS/richos-tauri"
            ))),
            bundle_identifier: Some("com.richos.app".to_string()),
            own_identifier: "com.richos.app".to_string(),
            data_dir: PathBuf::from(format!("{home}/Library/Application Support/com.richos.app")),
            home: Some(PathBuf::from(home)),
            parent_pid: 1,
            override_request: None,
        }
    }

    /// THE PROPERTY TO PROTECT ABOVE ALL. Everything else in this file is allowed to be
    /// wrong before this is.
    #[test]
    fn his_own_double_click_still_comes_to_the_front() {
        let d = decide(&installed("/Users/alex"));
        assert_eq!(d.presentation, Presentation::Regular, "{d:?}");
        assert_eq!(d.reason, Reason::InstalledLaunch);
    }

    #[test]
    fn a_cargo_built_binary_never_takes_the_screen() {
        let mut f = installed("/Users/alex");
        f.exe = Some(PathBuf::from("/repo/app/src-tauri/target/debug/richos-tauri"));
        f.bundle_identifier = None;
        // Even with the parent and the data directory of a real launch.
        assert_eq!(decide(&f).presentation, Presentation::Accessory);
    }

    /// The `tempfile.mkdtemp` shape, WITHOUT this test naming temporary directories: a
    /// redirected data directory is simply not the installed one.
    #[test]
    fn a_redirected_data_directory_never_takes_the_screen() {
        let mut f = installed("/Users/alex");
        f.data_dir = PathBuf::from("/var/folders/xx/T/richos-owned-desktop-abc123/data");
        assert_eq!(decide(&f).presentation, Presentation::Accessory);
    }

    /// A scratch `HOME` under a temporary directory: B holds (a copied bundle), P can hold,
    /// and D is what catches it, because `$HOME` moved with it.
    #[test]
    fn a_scratch_home_takes_the_screen_only_if_it_is_the_real_one() {
        let scratch = installed("/var/folders/xx/T/gui-boot-test.AbCdEf/home");
        // Consistent within itself, which is why D alone is not the whole rule…
        assert_eq!(decide(&scratch).presentation, Presentation::Regular);
        // …and why P is: a harness has to hold the process it boots.
        let mut held = scratch.clone();
        held.parent_pid = 60123;
        assert_eq!(decide(&held).presentation, Presentation::Accessory);
    }

    /// THE HARDEST CASE, and the reason P exists: a future harness that boots the REAL
    /// installed bundle against the REAL data directory. B and D both hold for it.
    #[test]
    fn a_harness_booting_the_real_install_is_still_accessory() {
        let mut f = installed("/Users/alex");
        f.parent_pid = 94414;
        let d = decide(&f);
        assert_eq!(d.presentation, Presentation::Accessory);
        match d.reason {
            Reason::NotEstablished(why) => {
                assert_eq!(why.len(), 1, "B and D held; only P failed: {why:?}");
                assert!(why[0].contains("parent pid 94414"), "{why:?}");
            }
            other => panic!("expected the parent to be the single unmet condition: {other:?}"),
        }
    }

    #[test]
    fn a_bundle_belonging_to_some_other_app_is_not_this_one() {
        let mut f = installed("/Users/alex");
        f.exe = Some(PathBuf::from("/Applications/Impostor.app/Contents/MacOS/richos-tauri"));
        f.bundle_identifier = Some("com.example.impostor".to_string());
        assert_eq!(decide(&f).presentation, Presentation::Accessory);
    }

    #[test]
    fn the_override_answers_in_both_directions() {
        let mut front = installed("/repo/nowhere");
        front.exe = Some(PathBuf::from("/repo/target/debug/richos-tauri"));
        front.bundle_identifier = None;
        front.parent_pid = 4242;
        front.override_request = Some("regular".to_string());
        assert_eq!(decide(&front).presentation, Presentation::Regular);

        let mut back = installed("/Users/alex");
        back.override_request = Some("accessory".to_string());
        assert_eq!(decide(&back).presentation, Presentation::Accessory);
    }

    /// A typo is not a third answer. `RICHOS_ACTIVATION=yes` on a harness boot must not hand
    /// it the screen — it falls through to the facts, which say accessory.
    #[test]
    fn an_unrecognized_override_value_decides_nothing() {
        let mut f = installed("/Users/alex");
        f.parent_pid = 777;
        f.override_request = Some("yes".to_string());
        assert_eq!(decide(&f).presentation, Presentation::Accessory);
        let mut real = installed("/Users/alex");
        real.override_request = Some("yes".to_string());
        assert_eq!(decide(&real).presentation, Presentation::Regular);
    }

    #[test]
    fn no_home_is_not_an_installed_launch() {
        let mut f = installed("/Users/alex");
        f.home = None;
        assert_eq!(decide(&f).presentation, Presentation::Accessory);
    }

    #[test]
    fn bundle_root_reads_the_macos_layout_and_nothing_else() {
        assert_eq!(
            bundle_root(Path::new("/A/RichOS.app/Contents/MacOS/richos-tauri")),
            Some(PathBuf::from("/A/RichOS.app"))
        );
        assert_eq!(bundle_root(Path::new("/A/RichOS.app/Contents/richos-tauri")), None);
        assert_eq!(bundle_root(Path::new("/A/RichOS/Contents/MacOS/richos-tauri")), None);
        assert_eq!(bundle_root(Path::new("/A/target/debug/richos-tauri")), None);
        assert_eq!(bundle_root(Path::new("richos-tauri")), None);
    }

    #[test]
    fn the_identifier_is_read_out_of_a_real_info_plist() {
        let plist = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\">\n<dict>\n\t<key>CFBundleExecutable</key>\n\t<string>richos-tauri</string>\n\t<key>CFBundleIdentifier</key>\n\t<string>com.richos.app</string>\n</dict>\n</plist>";
        assert_eq!(parse_bundle_identifier(plist), Some("com.richos.app".to_string()));
        assert_eq!(parse_bundle_identifier("<plist></plist>"), None);
        // A binary plist is bytes this reader does not understand. `None` fails B, which is
        // the safe direction.
        assert_eq!(parse_bundle_identifier("bplist00\u{0}\u{1}"), None);
    }

    /// The sentence a harness author reads. It has to name the rule and the way out, or the
    /// rule lives only in a file he has no reason to open.
    #[test]
    fn the_accessory_line_tells_its_reader_what_happened_and_what_to_do() {
        let mut f = installed("/Users/alex");
        f.parent_pid = 5150;
        let line = decide(&f).log_message();
        assert!(line.starts_with("activation: accessory — "), "{line}");
        assert!(line.contains("parent pid 5150"), "{line}");
        assert!(line.contains("RICHOS_ACTIVATION=regular"), "{line}");
        assert!(line.contains("still driveable"), "{line}");
        assert!(line.contains("no window on screen"), "{line}");
        assert!(!line.contains('\n'), "one line, so one log line: {line}");
    }

    #[test]
    fn the_regular_line_says_so_on_one_line() {
        let line = decide(&installed("/Users/alex")).log_message();
        assert!(line.starts_with("activation: regular — "), "{line}");
        assert!(!line.contains('\n'), "{line}");
    }
}
