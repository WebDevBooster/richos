// OBSERVATION WATCHER — the live half of the record, done without touching the screen.
//
// The lead's ruling (2026-09-18): the CEO is at the desk, the screen is not being freed for
// a forced lock, and `sysadminctl -screenLock status` reports a 300-second delay anyway, so
// a forced display sleep would not produce a locked session inside any test window. So the
// live evidence is gathered by WATCHING for a natural transition instead of causing one.
//
// It prints one line per SAMPLE only when the reading CHANGES, plus a heartbeat line every
// `HEARTBEAT` samples so a log with no transition still proves the watcher was alive and
// sampling rather than dead — an absence of transitions from a dead watcher and an absence
// from a screen nobody locked are different facts.
//
// Same externs, same key, same absence-means-unlocked rule as the shipped reader in
// `app/src-tauri/src/screen.rs`. Deliberately a separate standalone binary so it could be
// started before the shell had been built, and so it can be killed without touching the app.
use std::ffi::c_void;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

type CFTypeRef = *const c_void;
type CFDictionaryRef = *const c_void;
type CFStringRef = *const c_void;
type Boolean = u8;

#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGSessionCopyCurrentDictionary() -> CFDictionaryRef;
    fn CGDisplayIsAsleep(display: u32) -> i32;
    fn CGMainDisplayID() -> u32;
}

#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFRelease(cf: CFTypeRef);
    fn CFDictionaryGetValue(dict: CFDictionaryRef, key: *const c_void) -> *const c_void;
    fn CFStringCreateWithBytes(
        alloc: *const c_void,
        bytes: *const u8,
        num: isize,
        enc: u32,
        external: Boolean,
    ) -> CFStringRef;
    fn CFBooleanGetValue(b: CFTypeRef) -> Boolean;
    fn CFGetTypeID(cf: CFTypeRef) -> usize;
    fn CFBooleanGetTypeID() -> usize;
}

const K_CF_STRING_ENCODING_UTF8: u32 = 0x0800_0100;
/// 2 seconds — the shipped poll interval. See `screen.rs`'s own arithmetic.
const POLL: Duration = Duration::from_secs(2);
/// Every 150 samples = every 5 minutes at a 2-second poll.
const HEARTBEAT: u64 = 150;

unsafe fn cfstr(s: &str) -> CFStringRef {
    CFStringCreateWithBytes(
        std::ptr::null(),
        s.as_ptr(),
        s.len() as isize,
        K_CF_STRING_ENCODING_UTF8,
        0,
    )
}

/// (locked, on_console_key_present, display_asleep)
unsafe fn read(lock_key: CFStringRef, console_key: CFStringRef) -> (Option<bool>, bool, bool) {
    let dict = CGSessionCopyCurrentDictionary();
    let asleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0;
    if dict.is_null() {
        return (None, false, asleep);
    }
    let console = !CFDictionaryGetValue(dict, console_key as *const c_void).is_null();
    let v = CFDictionaryGetValue(dict, lock_key as *const c_void);
    let locked = if v.is_null() {
        // ABSENT is the unlocked reading, and it is only trustworthy because the
        // on-console key proves this is a real GUI-session dictionary.
        Some(false)
    } else if CFGetTypeID(v) == CFBooleanGetTypeID() {
        Some(CFBooleanGetValue(v) != 0)
    } else {
        None
    };
    CFRelease(dict);
    (locked, console, asleep)
}

fn stamp() -> String {
    let secs = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    // Minimal ISO-8601 UTC without a date crate.
    let days = secs / 86_400;
    let rem = secs % 86_400;
    let (h, m, s) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    let mut y = 1970i64;
    let mut d = days as i64;
    loop {
        let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
        let len = if leap { 366 } else { 365 };
        if d < len {
            break;
        }
        d -= len;
        y += 1;
    }
    let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    let months = [31, if leap { 29 } else { 28 }, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    let mut mo = 0usize;
    while d >= months[mo] {
        d -= months[mo];
        mo += 1;
    }
    format!("{y:04}-{:02}-{:02}T{h:02}:{m:02}:{s:02}Z", mo + 1, d + 1)
}

fn describe(r: (Option<bool>, bool, bool)) -> String {
    let lock = match r.0 {
        Some(true) => "locked",
        Some(false) => "unlocked",
        None => "unknown",
    };
    format!("screen={lock} on_console_key={} display_asleep={}", r.1, r.2)
}

fn main() {
    unsafe {
        let lock_key = cfstr("CGSSessionScreenIsLocked");
        let console_key = cfstr("kCGSSessionOnConsoleKey");
        let first = read(lock_key, console_key);
        println!("{} START  {}", stamp(), describe(first));
        let mut previous = first;
        let mut n: u64 = 0;
        loop {
            std::thread::sleep(POLL);
            n += 1;
            let now = read(lock_key, console_key);
            if now != previous {
                println!("{} CHANGE {}  (was: {})", stamp(), describe(now), describe(previous));
                previous = now;
            } else if n % HEARTBEAT == 0 {
                println!("{} alive  {}  ({n} samples, no change)", stamp(), describe(now));
            }
            use std::io::Write;
            let _ = std::io::stdout().flush();
        }
    }
}
