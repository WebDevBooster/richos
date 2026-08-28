use std::fs;
use std::path::Path;

/// Gate on the app icons BEFORE Tauri's own build step, so a placeholder icon set fails
/// fast with a clear, actionable message instead of quietly shipping a blank/wrong icon
/// (macOS: `.app` with no icon at any size; Windows: exe/installer with no icon at all —
/// both launch-blocking for a product the CEO installs on his own machine).
///
/// This is a REPLACEMENT for the six-month-old defect it caught: all four files under
/// `icons/` (`32x32.png`, `128x128.png`, `128x128@2x.png`, `icon.png`) were byte-identical
/// 2200-byte placeholders (same MD5 `baecac415e7b60b17ff33cdd4d98df53`), each internally a
/// 512x512 PNG regardless of what its filename claimed. Real, distinct renders at those
/// sizes will never collide on both "same bytes" and "same declared vs. actual dimensions"
/// simultaneously, so both checks below are true placeholder detectors, not just a literal
/// hash-equals-the-one-we-saw-once check.
fn main() {
    check_icons_are_not_placeholders();
    tauri_build::build();
}

const ICONS_DIR: &str = "icons";

/// (filename, required width, required height) per the Tauri v2 bundle-icon convention:
/// https://v2.tauri.app/develop/icons/ — "we recommend to at least match the output of
/// `tauri icon`: 32x32.png, 128x128.png, 128x128@2x.png, and icon.png", where `tauri icon`
/// (https://v2.tauri.app/reference/cli/, `icon` subcommand) generates 128x128@2x.png at
/// literal 256x256px (the "@2x" of 128) and icon.png at 512x512px.
const REQUIRED_PNGS: &[(&str, u32, u32)] = &[
    ("32x32.png", 32, 32),
    ("128x128.png", 128, 128),
    ("[email protected]", 256, 256),
    ("icon.png", 512, 512),
];

fn check_icons_are_not_placeholders() {
    let dir = Path::new(ICONS_DIR);
    let mut bytes_by_file: Vec<(String, Vec<u8>)> = Vec::new();
    let mut failures: Vec<String> = Vec::new();

    for (name, want_w, want_h) in REQUIRED_PNGS {
        let path = dir.join(name);
        let bytes = match fs::read(&path) {
            Ok(b) => b,
            Err(e) => {
                failures.push(format!("  - {} is missing or unreadable: {e}", path.display()));
                continue;
            }
        };
        match png_dimensions(&bytes) {
            Some((w, h)) if w == *want_w && h == *want_h => {}
            Some((w, h)) => failures.push(format!(
                "  - {} is named for {}x{} but is actually {}x{} pixels \
                 (Tauri does not resize bundle icons to fit their filename — \
                 a mis-sized file ships exactly as-is)",
                path.display(),
                want_w,
                want_h,
                w,
                h
            )),
            None => failures.push(format!("  - {} is not a readable PNG (bad IHDR)", path.display())),
        }
        bytes_by_file.push((name.to_string(), bytes));
    }

    // The specific defect this build shipped with: every required PNG was the exact same
    // file. Real icons rendered at four different sizes are never byte-identical.
    for i in 1..bytes_by_file.len() {
        if bytes_by_file[i].1 == bytes_by_file[0].1 {
            failures.push(format!(
                "  - {} is byte-identical to {} — these are supposed to be independently \
                 rendered sizes, not copies of one placeholder file",
                bytes_by_file[i].0, bytes_by_file[0].0
            ));
            break;
        }
    }

    if !failures.is_empty() {
        panic!(
            "\n\nrichos-tauri: app icons are still placeholders — refusing to build.\n\n{}\n\n\
             Fix: generate the full icon set from a single >=1024x1024 square PNG/SVG source \
             with transparency, once a real source image is available (see app/README.md's \
             \"App icon\" section for the exact `cargo tauri icon` invocation and required \
             output list, including icon.icns for macOS and icon.ico for Windows). This is \
             not something to paper over with new placeholder art.\n\n",
            failures.join("\n")
        );
    }
}

/// Minimal PNG width/height reader: no `image` crate dependency needed for a build-time
/// sanity check. PNG layout: 8-byte signature, then the first chunk is always IHDR
/// (length:4, "IHDR":4, width:4 (big-endian u32), height:4 (big-endian u32), ...).
/// Ref: PNG spec section 11.2.2 (https://www.w3.org/TR/png/#11IHDR).
fn png_dimensions(bytes: &[u8]) -> Option<(u32, u32)> {
    const SIG: [u8; 8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    if bytes.len() < 8 + 8 + 8 || bytes[0..8] != SIG {
        return None;
    }
    if &bytes[12..16] != b"IHDR" {
        return None;
    }
    let w = u32::from_be_bytes(bytes[16..20].try_into().ok()?);
    let h = u32::from_be_bytes(bytes[20..24].try_into().ok()?);
    Some((w, h))
}
