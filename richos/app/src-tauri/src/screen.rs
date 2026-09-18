//! **READING THE MAC'S SCREEN LOCK** — the shell's half of the CEO's ruling §56.
//!
//! `richos-hq/wiki/ceo-decisions.md` §56 (2026-09-18): *"I like that "Watch for the Mac's
//! screen to unlock" feature that you had running here. Should be added to the RichOS app for
//! automatic use when Rich needs it."*
//!
//! The decision — what waits, what never waits, how long a poll costs — is
//! `richos_core::screen`, which links nothing and can be tested without a webview. **This
//! file is only the reading**, which is the split `work_gate.rs` already documents: the
//! syscall lives where the frameworks are, the rule lives where the test suite is.
//!
//! ## WHY NOT `ioreg`, WHICH IS WHAT THE WATCHER HE LIKED USED
//!
//! The watcher outside the app was `ioreg -n Root -d1 -a | grep CGSSessionScreenIsLocked`.
//! That is a child process, an XML property list and a `grep` per sample. This asks the same
//! question of the same window server through the C call the `ioreg` output is a rendering of:
//!
//!   - no child process, so nothing to reap, nothing to inherit an environment, and no
//!     `PATH` for an operator's shell to change — the standing rule `repositories.rs` keeps
//!     about the app's own Git applies with equal force to a status read;
//!   - **an answer whose meaning does not depend on parsing a subprocess's stdout**, which is
//!     the exact shape `richos-core`'s `Cargo.toml` already refuses for the SHA-256 check:
//!     *"an integrity check whose answer depends on parsing a subprocess's stdout is the exact
//!     shape of 'exit 0 while doing the wrong thing'"*.
//!
//! ## NO NEW CRATE, AND THE LOCK DIFF IS THE PROOF
//!
//! `CGDisplayIsAsleep` is already reachable through `core-graphics 0.25`'s
//! `CGDisplay::is_asleep`, which is in this binary's `Cargo.lock` today beneath `tao`/`wry`.
//! **`CGSessionCopyCurrentDictionary` is in no crate in the tree**, so it is declared here as
//! an `extern` against CoreGraphics — a framework this process already links — together with
//! the four CoreFoundation entry points needed to read one value out of the dictionary it
//! returns. That adds a linker flag and no download: the `Cargo.lock` diff for this commit is
//! empty, which is the same evidence `voice_provision.rs`'s `reqwest` line offers for itself.
//!
//! Declaring the externs by hand rather than adding `core-foundation` as a direct dependency
//! keeps the call site honest about the fact that two of these — the session dictionary and
//! its key string — are Apple APIs with thin documentation, and keeps this module's unsafety
//! to the seventeen lines below where it is visible.
//!
//! ## THE READING, MEASURED ON THIS MAC ON 2026-09-18
//!
//! ```text
//!   CGSessionCopyCurrentDictionary()   11 entries
//!   kCGSSessionOnConsoleKey            PRESENT
//!   CGSSessionScreenIsLocked           ABSENT          (screen unlocked at the time)
//!   CGDisplayIsAsleep(main)            false
//!   one full reading                   298.4 µs        (2000 consecutive readings)
//! ```
//!
//! **ABSENT IS THE UNLOCKED READING, AND IT IS ONLY TRUSTWORTHY BECAUSE OF THE LINE ABOVE
//! IT.** macOS does not write `CGSSessionScreenIsLocked = false`; it omits the key. So an
//! absent key and an unsupported key look identical, and a reader that treated absence as
//! "unlocked" on its own would report `Unlocked` forever on a future macOS that renamed it.
//! `kCGSSessionOnConsoleKey` is the corroboration: it is present whenever the dictionary is a
//! real GUI-session dictionary for this process, so
//!
//!   - dictionary is null, or the on-console key is missing → [`Screen::Unknown`]. Nothing was
//!     established, and `richos_core::screen`'s polarity rule makes that proceed rather than
//!     wait, so a bad reading can never strand work.
//!   - on-console key present, lock key absent → [`Screen::Unlocked`].
//!   - lock key present as a `CFBoolean` → its value.
//!   - lock key present as something else → [`Screen::Unknown`], never a guess.
//!
//! ## WHAT IS AND IS NOT ESTABLISHED ABOUT THE LOCKED READING
//!
//! Stated here rather than in a record nobody opens with the code. **The unlocked reading is
//! proven against a real GUI session on this Mac. The locked reading is not**, because the
//! CEO was at the desk and the screen was not taken for a forced lock (the lead's decision,
//! 2026-09-18) — and a forced one would not have proven it anyway: `sysadminctl -screenLock
//! status` reports a **300-second** delay on this Mac, so `pmset displaysleepnow` sleeps the
//! display and leaves the session unlocked for five minutes. The locked branch is driven in
//! tests through `richos_core::screen::FakeScreen`, and by observation of a natural lock if
//! one occurs. `docs/verification/screen-wait-2026-09-18/` is the record and says so plainly.
//!
//! ## WINDOWS
//!
//! A documented stub that reports [`Screen::Unknown`], which never blocks. The equivalent is
//! `WTSRegisterSessionNotification` plus `WTS_SESSION_LOCK`/`WTS_SESSION_UNLOCK`, and it needs
//! a window handle and a message pump — not cheap, and there is no Windows build of this app
//! to verify it against today (`app/README.md`'s open Windows code-signing gap is the same
//! story one level up). Reporting `Unknown` is the honest answer for a platform whose screen
//! this build cannot read, and because of the polarity rule it costs nothing but the feature.

use richos_core::screen::{Screen, ScreenReading, ScreenSource};

/// The real reader. Stateless: every reading is a fresh question to the window server, so
/// there is nothing to invalidate and `Send + Sync` is free.
pub struct MacScreen;

#[cfg(target_os = "macos")]
mod apple {
    use std::ffi::c_void;

    pub type CFTypeRef = *const c_void;
    pub type CFDictionaryRef = *const c_void;
    pub type CFStringRef = *const c_void;
    pub type Boolean = u8;

    #[link(name = "CoreGraphics", kind = "framework")]
    extern "C" {
        /// The current GUI session's attributes. `NULL` for a process with no session.
        pub fn CGSessionCopyCurrentDictionary() -> CFDictionaryRef;
        pub fn CGDisplayIsAsleep(display: u32) -> i32;
        pub fn CGMainDisplayID() -> u32;
    }

    #[link(name = "CoreFoundation", kind = "framework")]
    extern "C" {
        pub fn CFRelease(cf: CFTypeRef);
        pub fn CFDictionaryGetValue(dict: CFDictionaryRef, key: *const c_void) -> *const c_void;
        pub fn CFStringCreateWithBytes(
            alloc: *const c_void,
            bytes: *const u8,
            num: isize,
            encoding: u32,
            external: Boolean,
        ) -> CFStringRef;
        pub fn CFBooleanGetValue(boolean: CFTypeRef) -> Boolean;
        pub fn CFGetTypeID(cf: CFTypeRef) -> usize;
        pub fn CFBooleanGetTypeID() -> usize;
    }

    pub const K_CF_STRING_ENCODING_UTF8: u32 = 0x0800_0100;

    /// The session dictionary's keys are literally these strings.
    pub const LOCK_KEY: &str = "CGSSessionScreenIsLocked";
    /// The corroboration that makes an ABSENT lock key readable as "unlocked" rather than as
    /// "this build cannot see the key" — see this module's own documentation.
    pub const ON_CONSOLE_KEY: &str = "kCGSSessionOnConsoleKey";
}

#[cfg(target_os = "macos")]
impl ScreenSource for MacScreen {
    fn read(&self) -> ScreenReading {
        use apple::*;
        // SAFETY: each call below is a documented C entry point in a framework this process
        // already links. The two CFStrings are created here and released here; the dictionary
        // comes from a `Copy` function so this owns it and releases it on every path; and
        // `CFDictionaryGetValue` returns a BORROWED value, which is read before the
        // dictionary is released and never kept.
        unsafe {
            let asleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0;
            let dictionary = CGSessionCopyCurrentDictionary();
            if dictionary.is_null() {
                // No GUI session for this process. Nothing established.
                return ScreenReading { screen: Screen::Unknown, display_asleep: Some(asleep) };
            }
            let lock_key = cfstring(LOCK_KEY);
            let console_key = cfstring(ON_CONSOLE_KEY);
            let screen = if lock_key.is_null() || console_key.is_null() {
                Screen::Unknown
            } else if CFDictionaryGetValue(dictionary, console_key).is_null() {
                // A dictionary that is not a GUI-session dictionary. An absent lock key in
                // here would mean nothing, so nothing is claimed.
                Screen::Unknown
            } else {
                let value = CFDictionaryGetValue(dictionary, lock_key);
                if value.is_null() {
                    // ABSENT, corroborated by the on-console key above: unlocked.
                    Screen::Unlocked
                } else if CFGetTypeID(value) == CFBooleanGetTypeID() {
                    if CFBooleanGetValue(value) != 0 {
                        Screen::Locked
                    } else {
                        Screen::Unlocked
                    }
                } else {
                    // Present but not a boolean. Never guessed.
                    Screen::Unknown
                }
            };
            if !lock_key.is_null() {
                CFRelease(lock_key);
            }
            if !console_key.is_null() {
                CFRelease(console_key);
            }
            CFRelease(dictionary);
            ScreenReading { screen, display_asleep: Some(asleep) }
        }
    }
}

#[cfg(target_os = "macos")]
unsafe fn cfstring(value: &str) -> apple::CFStringRef {
    apple::CFStringCreateWithBytes(
        std::ptr::null(),
        value.as_ptr(),
        value.len() as isize,
        apple::K_CF_STRING_ENCODING_UTF8,
        0,
    )
}

/// **Every platform that is not macOS.** Reports [`Screen::Unknown`], which by
/// `richos_core::screen`'s polarity rule proceeds rather than waits — so a build for a screen
/// this app cannot read loses the feature and never loses the work.
///
/// Windows would be `WTSRegisterSessionNotification` with `WTS_SESSION_LOCK` /
/// `WTS_SESSION_UNLOCK`; it needs a window handle and a message pump, and there is no Windows
/// build of this app to verify it against today. Named rather than silently absent.
#[cfg(not(target_os = "macos"))]
impl ScreenSource for MacScreen {
    fn read(&self) -> ScreenReading {
        ScreenReading::unknown()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use richos_core::screen::ScreenWatch;
    use std::sync::Arc;

    /// **The live read.** On macOS this is the one assertion in the suite that talks to the
    /// real window server, and it is deliberately weak about WHICH answer it gets: a run on a
    /// locked screen, a run on an unlocked screen and a run with no GUI session are all
    /// correct outcomes, and pinning one would make the suite depend on the state of somebody's
    /// desk.
    ///
    /// What it does pin is the thing that can actually break: that the reader returns one of
    /// the three readings without crashing, leaking or hanging, and that `display_asleep` was
    /// established. On a CI host with no session it reads `Unknown`, which is the honest
    /// answer and not a failure.
    #[test]
    fn the_reader_answers_without_crashing_and_says_what_it_established() {
        let reading = MacScreen.read();
        assert!(matches!(
            reading.screen,
            Screen::Locked | Screen::Unlocked | Screen::Unknown
        ));
        #[cfg(target_os = "macos")]
        assert!(
            reading.display_asleep.is_some(),
            "CGDisplayIsAsleep always answers on macOS, so `None` here is a defect"
        );
        // Two readings in a row must not disagree about whether they could establish
        // anything: a reader that intermittently returns Unknown would make a wait flap.
        let again = MacScreen.read();
        assert_eq!(
            matches!(reading.screen, Screen::Unknown),
            matches!(again.screen, Screen::Unknown),
            "the reader must be stable about whether it can read this machine at all"
        );
    }

    /// Releasing on every path is not something a test can observe directly, so this drives
    /// the real reader hard enough that a leaked `CFDictionary` per reading would be visible
    /// as growth to anyone watching, and proves the call is cheap enough for the 2-second poll
    /// the decision half chose. 2000 readings is the same sample the 298.4 µs figure came from.
    #[test]
    fn two_thousand_real_readings_stay_cheap() {
        let started = std::time::Instant::now();
        for _ in 0..2000 {
            let _ = MacScreen.read();
        }
        let each = started.elapsed() / 2000;
        // Measured at 298.4 µs on this Mac. The ceiling is deliberately loose — this is a
        // guard against a reading that became milliseconds, not a re-measurement.
        assert!(
            each < std::time::Duration::from_millis(5),
            "one reading took {each:?}; at that cost the 2-second poll's arithmetic in \
             richos_core::screen no longer holds"
        );
        println!("one reading: {:.1} us", each.as_nanos() as f64 / 1000.0);
    }

    /// The reader plugs into the decision half, and on an unlocked desk a wait costs exactly
    /// one reading. Skipped in effect on a locked screen — which is why it asserts on the
    /// READING it got rather than on availability.
    #[test]
    fn the_reader_drives_the_core_wait() {
        let watch = ScreenWatch::new(Arc::new(MacScreen));
        assert_eq!(watch.samples(), 0, "constructing a watch must read nothing");
        let reading = watch.read();
        assert_eq!(watch.samples(), 1);
        // An unlocked or unreadable screen proceeds; a locked one is the only thing that waits.
        assert_eq!(reading.blocks(), matches!(reading.screen, Screen::Locked));
    }
}
