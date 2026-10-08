//! **A passive listener standing in for open-wispr, in the test guest** (dictation plan section 3,
//! "His Mac, at cutover", and section 9, slice 1).
//!
//!   key_probe --seconds N
//!
//! A LISTEN-ONLY event tap at the annotated session location, appended at the tail: downstream of
//! every session tap, where a passive observer such as open-wispr's NSEvent global monitor sees
//! keys. It prints one JSON line for each F1 (kVK 122), F13 (kVK 105) or brightness-down
//! (system-defined, subtype 8, type 3) event that reaches it, and nothing for any other key. With
//! dictation on, the tool's active tap swallows those events first, so this prints none of them;
//! with dictation off it prints each. It prints `{"ready":true}` once its tap exists and exits
//! after N seconds. Run from the guest's ssh session, whose grants include ListenEvent
//! (provision-guest.sh). Never run on the host.

#[cfg(target_os = "macos")]
fn main() {
    use objc2::encode::{Encoding, RefEncode};
    use objc2::msg_send;
    use objc2::runtime::{AnyClass, AnyObject};
    use std::ffi::c_void;

    #[repr(C)]
    struct CGEvent {
        _p: [u8; 0],
    }
    unsafe impl RefEncode for CGEvent {
        const ENCODING_REF: Encoding = Encoding::Pointer(&Encoding::Struct("__CGEvent", &[]));
    }
    type Callback = extern "C" fn(*mut c_void, u32, *mut CGEvent, *mut c_void) -> *mut CGEvent;
    #[link(name = "ApplicationServices", kind = "framework")]
    extern "C" {
        fn CGEventTapCreate(tap: u32, place: u32, options: u32, mask: u64, callback: Callback, user: *mut c_void) -> *mut c_void;
        fn CGEventGetIntegerValueField(event: *mut CGEvent, field: u32) -> i64;
    }
    #[link(name = "CoreFoundation", kind = "framework")]
    extern "C" {
        static kCFRunLoopCommonModes: *const c_void;
        fn CFMachPortCreateRunLoopSource(a: *const c_void, port: *mut c_void, order: isize) -> *mut c_void;
        fn CFRunLoopGetCurrent() -> *mut c_void;
        fn CFRunLoopAddSource(rl: *mut c_void, source: *mut c_void, mode: *const c_void);
        fn CFRunLoopRunInMode(mode: *const c_void, seconds: f64, return_after_source: bool) -> i32;
        static kCFRunLoopDefaultMode: *const c_void;
    }
    #[link(name = "AppKit", kind = "framework")]
    extern "C" {}

    extern "C" fn seen(_p: *mut c_void, etype: u32, event: *mut CGEvent, _u: *mut c_void) -> *mut CGEvent {
        std::panic::catch_unwind(|| unsafe {
            match etype {
                10 | 11 => {
                    if let Some(line) = key_line(CGEventGetIntegerValueField(event, 9), etype == 10) {
                        println!("{line}");
                    }
                }
                14 => objc2::rc::autoreleasepool(|_| {
                    let Some(class) = AnyClass::get(c"NSEvent") else { return };
                    let ns: *mut AnyObject = msg_send![class, eventWithCGEvent: event];
                    if ns.is_null() {
                        return;
                    }
                    let subtype: i16 = msg_send![ns, subtype];
                    let data1: isize = msg_send![ns, data1];
                    let key_type = (data1 >> 16) & 0xFFFF;
                    if subtype == 8 && key_type == 3 {
                        println!("{{\"type\":\"system\",\"subtype\":8,\"keyType\":3,\"state\":{}}}", (data1 >> 8) & 0xFF);
                    }
                }),
                _ => {}
            }
            use std::io::Write;
            std::io::stdout().flush().ok();
        })
        .ok();
        event
    }

    let args: Vec<String> = std::env::args().skip(1).collect();
    let seconds: f64 = match args.as_slice() {
        [flag, n] if flag == "--seconds" => n.parse().expect("--seconds takes a number"),
        _ => {
            eprintln!("usage: key_probe --seconds N");
            std::process::exit(2);
        }
    };
    unsafe {
        let mask: u64 = (1 << 10) | (1 << 11) | (1 << 14);
        // kCGAnnotatedSessionEventTap (2), kCGTailAppendEventTap (1), kCGEventTapOptionListenOnly (1)
        let port = CGEventTapCreate(2, 1, 1, mask, seen, std::ptr::null_mut());
        if port.is_null() {
            println!("{{\"ready\":false}}");
            std::process::exit(1);
        }
        let source = CFMachPortCreateRunLoopSource(std::ptr::null(), port, 0);
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
        println!("{{\"ready\":true}}");
        use std::io::Write;
        std::io::stdout().flush().ok();
        let end = std::time::Instant::now() + std::time::Duration::from_secs_f64(seconds);
        while std::time::Instant::now() < end {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, false);
        }
    }
}

#[cfg(not(target_os = "macos"))]
fn main() {}

/// The line printed for a plain key, or `None` for any key that is not F1 (122) or F13 (105):
/// the probe reports the dictation key's shapes and nothing anybody else types.
fn key_line(code: i64, down: bool) -> Option<String> {
    (code == 122 || code == 105).then(|| format!("{{\"type\":\"key\",\"code\":{code},\"down\":{down}}}"))
}

#[cfg(test)]
mod tests {
    /// INVARIANT: only F1 and F13 are ever printed; every other key is not.
    #[test]
    fn only_the_dictation_keys_are_reported() {
        assert_eq!(super::key_line(122, true).as_deref(), Some(r#"{"type":"key","code":122,"down":true}"#));
        assert_eq!(super::key_line(105, false).as_deref(), Some(r#"{"type":"key","code":105,"down":false}"#));
        for other in [0, 9, 36, 49, 120, 999] {
            assert_eq!(super::key_line(other, true), None, "key {other}");
        }
    }
}
