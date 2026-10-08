//! **Post one key the way a keyboard would, in the test guest** (dictation plan section 9, slice 1).
//!
//!   post_key --brightness-down      the Apple top row's F1: a system-defined event, subtype 8,
//!                                   NX_KEYTYPE_BRIGHTNESS_DOWN (3), down then up
//!   post_key --code <kVK>           a plain key code, down then up
//!
//! System Events can post a key code but not a system-defined event, and the test VM has no
//! physical keyboard, so this is how the walk proves the tap matches and swallows the event a
//! physical Apple keyboard's F1 sends. Built the way MonitorControl posts it: an NSEvent of type
//! NSEventTypeSystemDefined whose data1 is (key type << 16) | (key state << 8), turned into a
//! CGEvent and posted at the HID tap. Run from the guest's ssh session, whose grants include
//! PostEvent (provision-guest.sh). Never run on the host.

#[cfg(target_os = "macos")]
fn main() {
    use objc2::encode::{Encode, Encoding, RefEncode};
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
    #[repr(C)]
    #[derive(Clone, Copy)]
    struct Point {
        x: f64,
        y: f64,
    }
    unsafe impl Encode for Point {
        const ENCODING: Encoding = Encoding::Struct("CGPoint", &[f64::ENCODING, f64::ENCODING]);
    }
    #[link(name = "ApplicationServices", kind = "framework")]
    extern "C" {
        fn CGEventSourceCreate(state: i32) -> *mut c_void;
        fn CGEventCreateKeyboardEvent(source: *mut c_void, code: u16, down: bool) -> *mut CGEvent;
        fn CGEventPost(tap: u32, event: *mut CGEvent);
        fn CFRelease(cf: *const c_void);
    }
    #[link(name = "AppKit", kind = "framework")]
    extern "C" {}

    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.iter().map(String::as_str).collect::<Vec<_>>().as_slice() {
        ["--brightness-down"] => {
            const BRIGHTNESS_DOWN: isize = 3;
            for state in [0x0Aisize, 0x0B] {
                objc2::rc::autoreleasepool(|_| unsafe {
                    let class = AnyClass::get(c"NSEvent").expect("AppKit is linked");
                    let ns: *mut AnyObject = msg_send![
                        class,
                        otherEventWithType: 14usize, // NSEventTypeSystemDefined
                        location: Point { x: 0.0, y: 0.0 },
                        modifierFlags: (state << 8) as usize,
                        timestamp: 0.0f64,
                        windowNumber: 0isize,
                        context: std::ptr::null_mut::<AnyObject>(),
                        subtype: 8i16, // NX_SUBTYPE_AUX_CONTROL_BUTTONS
                        data1: aux_data1(BRIGHTNESS_DOWN, state),
                        data2: -1isize
                    ];
                    assert!(!ns.is_null(), "NSEvent refused the system-defined event");
                    let cg: *mut CGEvent = msg_send![ns, CGEvent];
                    assert!(!cg.is_null(), "the NSEvent has no CGEvent");
                    CGEventPost(0, cg); // kCGHIDEventTap
                });
                std::thread::sleep(std::time::Duration::from_millis(60));
            }
            println!("posted brightness-down (system-defined, subtype 8, type 3), down and up");
        }
        ["--code", code] => {
            let code: u16 = code.parse().expect("--code takes a kVK number");
            unsafe {
                let source = CGEventSourceCreate(1); // kCGEventSourceStateHIDSystemState
                for down in [true, false] {
                    let event = CGEventCreateKeyboardEvent(source, code, down);
                    CGEventPost(0, event);
                    CFRelease(event as *const c_void);
                    std::thread::sleep(std::time::Duration::from_millis(60));
                }
                CFRelease(source);
            }
            println!("posted key code {code}, down and up");
        }
        _ => {
            eprintln!("usage: post_key --brightness-down | --code <kVK>");
            std::process::exit(2);
        }
    }
}

#[cfg(not(target_os = "macos"))]
fn main() {}

/// The system-defined event's data word: the key type in the high 16 bits, the key state (0x0A
/// down, 0x0B up) in bits 8 to 15, the repeat bit clear.
fn aux_data1(key_type: isize, state: isize) -> isize {
    (key_type << 16) | (state << 8)
}

#[cfg(test)]
mod tests {
    use richos_voice::dictation::{judge_key, KeyEvent, KeyVerdict};

    /// INVARIANT: what this posts is exactly what the tool's key match reads as F1 down and up,
    /// so the walk proves the event a physical Apple keyboard's F1 sends, not a look-alike.
    #[test]
    fn the_posted_brightness_down_is_what_the_tool_reads_as_f1() {
        for (state, down) in [(0x0A, true), (0x0B, false)] {
            let posted = KeyEvent::System { subtype: 8, data1: super::aux_data1(3, state) as i64 };
            assert_eq!(posted, KeyEvent::top_row(3, down, false));
        }
        let down = KeyEvent::System { subtype: 8, data1: super::aux_data1(3, 0x0A) as i64 };
        assert_eq!(judge_key(1, &down), KeyVerdict::Toggle);
        let up = KeyEvent::System { subtype: 8, data1: super::aux_data1(3, 0x0B) as i64 };
        assert_eq!(judge_key(1, &up), KeyVerdict::Swallow);
    }
}
