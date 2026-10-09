//! **A PICTURE OF RICHOS'S OWN WINDOW**, for Bust a bug: what the user was looking at when they
//! pressed it, so their Rich can check what they say against it (round 21's "Looked at the
//! screen you were on"; second review rv-20261009T102303Z-1c3dda1d-4c78, finding 6).
//!
//! # Why WebKit's snapshot and nothing else
//!
//! The window's content IS its webview, and `WKWebView takeSnapshotWithConfiguration:
//! completionHandler:` draws the app's own view into an image. It reads nothing outside this
//! app, so macOS asks for no permission: no Screen Recording prompt, no entry in Privacy &
//! Security. Every other way to picture a window (`screencapture`, `CGWindowListCreateImage`,
//! ScreenCaptureKit) goes through the screen-capture permission, which the CEO's brief rules out.
//!
//! The picture is JPEG at quality 0.6, held in memory only (never written to disk), given to
//! the user's own `claude` as an image block on standard input, and never put in the issue.

use std::time::Duration;

/// How long WebKit gets to draw the picture. It answers in tens of milliseconds on a window
/// that is on screen; a window that is not (minimized, another Space) may never answer.
const DEADLINE: Duration = Duration::from_secs(3);

/// The largest picture handed on. Claude takes an image of up to 5 MB once base64-encoded,
/// which is 3.75 MB of bytes; a full-screen Retina window at quality 0.6 measured far below.
pub const MAX_BYTES: usize = 3_500_000;

/// A JPEG of the webview of `window` as it is now, or `None` (not macOS, no answer in
/// [`DEADLINE`], or WebKit could not draw it). Waits, so it is called off the IPC threads.
pub fn take(window: &tauri::WebviewWindow) -> Option<Vec<u8>> {
    #[cfg(target_os = "macos")]
    {
        let (tx, rx) = std::sync::mpsc::channel::<Option<Vec<u8>>>();
        // `with_webview` runs this on the main thread, where WebKit must be called.
        let asked = window.with_webview(move |webview| mac::snapshot(webview.inner(), tx));
        if let Err(e) = asked {
            eprintln!("[richos] bug report: the window's picture could not be asked for ({e})");
            return None;
        }
        match rx.recv_timeout(DEADLINE) {
            Ok(Some(bytes)) => within_cap(bytes),
            Ok(None) => None,
            Err(_) => {
                eprintln!("[richos] bug report: WebKit did not draw the window within {DEADLINE:?}; Rich gets the words only");
                None
            }
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = window;
        None
    }
}

/// A picture Claude will take, or none: over [`MAX_BYTES`] Rich gets the screen's words only.
fn within_cap(bytes: Vec<u8>) -> Option<Vec<u8>> {
    if bytes.len() <= MAX_BYTES {
        return Some(bytes);
    }
    eprintln!("[richos] bug report: the window's picture is {} bytes, over {MAX_BYTES}; Rich gets the words only", bytes.len());
    None
}

#[cfg(target_os = "macos")]
mod mac {
    use objc2::msg_send;
    use objc2::runtime::{AnyClass, AnyObject};
    use std::ffi::c_void;
    use std::sync::mpsc::Sender;
    use std::sync::Mutex;

    #[link(name = "AppKit", kind = "framework")]
    extern "C" {
        /// `NSBitmapImageRepPropertyKey`, the JPEG quality's key.
        static NSImageCompressionFactor: *mut AnyObject;
    }

    /// `NSBitmapImageFileTypeJPEG` (AppKit's `NSBitmapImageRep.h`: TIFF 0, BMP 1, GIF 2, JPEG 3).
    const JPEG: usize = 3;

    /// Ask `wkwebview` for its picture; `done` hears the JPEG, or `None`, once WebKit answers.
    /// Called on the main thread.
    pub fn snapshot(wkwebview: *mut c_void, done: Sender<Option<Vec<u8>>>) {
        let view = wkwebview as *mut AnyObject;
        if view.is_null() {
            report(done.send(None));
            return;
        }
        let once = Mutex::new(Some(done));
        let block = block2::RcBlock::new(move |image: *mut AnyObject, _error: *mut AnyObject| {
            let bytes = if image.is_null() { None } else { jpeg(image) };
            if let Some(done) = once.lock().unwrap_or_else(|p| p.into_inner()).take() {
                report(done.send(bytes));
            }
        });
        // SAFETY: the documented WKWebView method, on the main thread, with no configuration (the
        // whole visible view); WebKit copies the block it is given.
        unsafe {
            let () = msg_send![view, takeSnapshotWithConfiguration: std::ptr::null_mut::<AnyObject>(), completionHandler: &*block];
        }
    }

    /// A send whose receiver has already given up (past the deadline) changes nothing.
    fn report<T>(sent: Result<(), std::sync::mpsc::SendError<T>>) {
        if sent.is_err() {
            eprintln!("[richos] bug report: the window's picture came after it was no longer waited for");
        }
    }

    /// The image as JPEG bytes at quality 0.6: TIFF, then a bitmap, then JPEG, AppKit's own path.
    pub(super) fn jpeg(image: *mut AnyObject) -> Option<Vec<u8>> {
        objc2::rc::autoreleasepool(|_| {
            let bitmap_class = AnyClass::get(c"NSBitmapImageRep")?;
            let number_class = AnyClass::get(c"NSNumber")?;
            let dictionary_class = AnyClass::get(c"NSDictionary")?;
            // SAFETY: documented AppKit and Foundation methods on objects this block was handed or
            // just made; every object returned is checked for nil before it is used, and the bytes
            // are copied out before the pool that owns them drains.
            unsafe {
                let tiff: *mut AnyObject = msg_send![image, TIFFRepresentation];
                if tiff.is_null() {
                    return None;
                }
                let bitmap: *mut AnyObject = msg_send![bitmap_class, imageRepWithData: tiff];
                if bitmap.is_null() {
                    return None;
                }
                let quality: *mut AnyObject = msg_send![number_class, numberWithDouble: 0.6f64];
                let properties: *mut AnyObject = msg_send![dictionary_class, dictionaryWithObject: quality, forKey: NSImageCompressionFactor];
                let data: *mut AnyObject = msg_send![bitmap, representationUsingType: JPEG, properties: properties];
                if data.is_null() {
                    return None;
                }
                let length: usize = msg_send![data, length];
                let bytes: *const c_void = msg_send![data, bytes];
                if bytes.is_null() || length == 0 {
                    return None;
                }
                Some(std::slice::from_raw_parts(bytes as *const u8, length).to_vec())
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_picture_over_the_cap_is_not_handed_on() {
        assert_eq!(within_cap(vec![0; MAX_BYTES]).map(|b| b.len()), Some(MAX_BYTES));
        assert_eq!(within_cap(vec![0; MAX_BYTES + 1]), None);
        // Claude's 5 MB limit is on the base64 text: 4 characters for every 3 bytes.
        assert!(MAX_BYTES.div_ceil(3) * 4 < 5 * 1024 * 1024);
    }

    /// THE CONVERSION THE SNAPSHOT'S IMAGE GOES THROUGH, on a real NSImage: AppKit's TIFF, bitmap
    /// and JPEG path, with the message signatures objc2 checks in a debug build. The snapshot
    /// itself needs a window on screen, which the test VM walk (bug-report-walk.sh) provides.
    #[cfg(target_os = "macos")]
    #[test]
    fn an_nsimage_becomes_a_jpeg() {
        use objc2::msg_send;
        use objc2::runtime::{AnyClass, AnyObject};
        // A 2 by 2 BMP, the smallest image NSImage reads without a codec this test must build.
        let mut bmp = Vec::new();
        bmp.extend_from_slice(b"BM");
        bmp.extend_from_slice(&70u32.to_le_bytes());
        bmp.extend_from_slice(&[0, 0, 0, 0]);
        bmp.extend_from_slice(&54u32.to_le_bytes());
        for v in [40u32, 2, 2] {
            bmp.extend_from_slice(&v.to_le_bytes());
        }
        bmp.extend_from_slice(&1u16.to_le_bytes());
        bmp.extend_from_slice(&24u16.to_le_bytes());
        for v in [0u32, 16, 2835, 2835, 0, 0] {
            bmp.extend_from_slice(&v.to_le_bytes());
        }
        for _ in 0..2 {
            bmp.extend_from_slice(&[0, 0, 255, 0, 0, 255, 0, 0]); // two red pixels, padded to 8
        }
        assert_eq!(bmp.len(), 70);
        let jpeg = objc2::rc::autoreleasepool(|_| unsafe {
            let data_class = AnyClass::get(c"NSData").unwrap();
            let image_class = AnyClass::get(c"NSImage").unwrap();
            let data: *mut AnyObject = msg_send![data_class, dataWithBytes: bmp.as_ptr() as *const std::ffi::c_void, length: bmp.len()];
            let image: *mut AnyObject = msg_send![image_class, alloc];
            let image: *mut AnyObject = msg_send![image, initWithData: data];
            assert!(!image.is_null(), "NSImage did not read the BMP");
            let jpeg = mac::jpeg(image);
            let () = msg_send![image, release];
            jpeg
        });
        let jpeg = jpeg.expect("AppKit gave no JPEG");
        assert_eq!(&jpeg[..3], &[0xFF, 0xD8, 0xFF], "not a JPEG");
        assert_eq!(&jpeg[jpeg.len() - 2..], &[0xFF, 0xD9], "the JPEG does not end");
    }
}
