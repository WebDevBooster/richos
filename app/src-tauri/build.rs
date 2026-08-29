use std::collections::BTreeSet;
use std::fs;
use std::path::Path;

/// Gate on the app icons BEFORE Tauri's own build step, so a placeholder icon set is
/// caught with a clear, actionable message instead of quietly shipping a blank/wrong
/// icon (macOS: `.app` with no icon at any size; Windows: exe/installer with no icon at
/// all — both launch-blocking for a product the CEO installs on his own machine).
///
/// THE DEFECT THIS REPLACES: all four files under `icons/` were byte-identical 2200-byte
/// placeholders, each internally a 512x512 PNG regardless of what its filename claimed.
///
/// THE DEFECT *THIS REWRITE* REPLACES: the previous version of this gate hand-typed a
/// list of four filenames while `tauri.conf.json` declared six, so `icon.icns` and
/// `icon.ico` — the only two artefacts that actually carry the icon on macOS and Windows
/// — were never checked at all. A check that describes something narrower than it claims
/// to is worse than no check, because it buys false confidence. So this version derives
/// the required set from `tauri.conf.json`'s `bundle.icon` array: Tauri's own list of
/// what it bundles. Adding a size there cannot leave this check silently passing, and an
/// entry we cannot decode is a failure rather than a skip.
///
/// `app/scripts/lib/app_icons.py` derives the SAME requirements INDEPENDENTLY from the
/// SAME config. That duplication is deliberate — two independent readers agreeing is a
/// stronger guarantee than one shared helper, and if the generator's derivation ever
/// drifts from this one, the build says so.
fn main() {
    println!("cargo::rerun-if-changed=tauri.conf.json");
    println!("cargo::rerun-if-changed=icons");
    println!("cargo::rerun-if-env-changed=RICHOS_REQUIRE_REAL_ICONS");

    check_icons(Path::new("tauri.conf.json"), Path::new("icons"));
    tauri_build::build();
}

/// Windows `.ico` layers Tauri's icon guide specifies.
/// Ref: https://v1.tauri.app/v1/guides/features/icons/ (format unchanged in v2).
/// Verified against `cargo tauri icon` 2.11.4 output: exactly [16, 24, 32, 48, 64, 256].
const ICO_LAYERS: &[u32] = &[16, 24, 32, 48, 64, 256];

/// macOS `.icns` PIXEL sizes (not fourccs — see `icns_sizes` for why).
/// Verified against `cargo tauri icon` 2.11.4 AND Apple's `iconutil`: both cover exactly
/// this set, using different chunk types to do it.
const ICNS_SIZES: &[u32] = &[16, 32, 64, 128, 256, 512, 1024];

/// `tauri icon` emits the unsized `icon.png` at 512x512. The one filename whose required
/// size cannot be read off the name. Ref: https://v2.tauri.app/develop/icons/
const UNSIZED_PNG: &[(&str, u32)] = &[("icon.png", 512)];

enum Kind {
    Png(u32),
    Icns,
    Ico,
}

struct Requirement {
    rel: String,
    kind: Kind,
}

fn check_icons(conf_path: &Path, icons_dir: &Path) {
    let mut failures: Vec<String> = Vec::new();

    let reqs = match derive_requirements(conf_path) {
        Ok(r) => r,
        Err(e) => {
            report(vec![e]);
            return;
        }
    };

    let mut blobs: Vec<(String, Vec<u8>)> = Vec::new();

    for req in &reqs {
        let name = Path::new(&req.rel)
            .file_name()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_else(|| req.rel.clone());
        let path = icons_dir.join(&name);

        let bytes = match fs::read(&path) {
            Ok(b) => b,
            Err(_) => {
                failures.push(format!(
                    "{} is declared in tauri.conf.json bundle.icon but does not exist on disk",
                    req.rel
                ));
                continue;
            }
        };

        match req.kind {
            Kind::Png(want) => match png_dimensions(&bytes) {
                Some((w, h)) if w == want && h == want => {}
                Some((w, h)) => failures.push(format!(
                    "{} is named for {want}x{want} but is actually {w}x{h} — Tauri ships \
                     bundle icons as-is, it does not resize them to match their filename",
                    req.rel
                )),
                None => failures.push(format!("{} is not a readable PNG (bad IHDR)", req.rel)),
            },
            Kind::Icns => {
                let got = icns_sizes(&bytes);
                if got.is_empty() {
                    failures.push(format!("{} is not a readable .icns archive", req.rel));
                } else {
                    let missing: Vec<u32> = ICNS_SIZES
                        .iter()
                        .copied()
                        .filter(|s| !got.contains(s))
                        .collect();
                    if !missing.is_empty() {
                        failures.push(format!(
                            "{} is missing layer size(s) {missing:?}px (has {:?})",
                            req.rel,
                            got.iter().copied().collect::<Vec<_>>()
                        ));
                    }
                }
            }
            Kind::Ico => match ico_sizes(&bytes) {
                None => failures.push(format!("{} is not a readable .ico", req.rel)),
                Some(got) => {
                    let missing: Vec<u32> = ICO_LAYERS
                        .iter()
                        .copied()
                        .filter(|s| !got.contains(s))
                        .collect();
                    if !missing.is_empty() {
                        failures.push(format!(
                            "{} is missing layer size(s) {missing:?}px (has {:?})",
                            req.rel,
                            got.iter().copied().collect::<Vec<_>>()
                        ));
                    }
                }
            },
        }

        blobs.push((req.rel.clone(), bytes));
    }

    // The exact defect this gate was written against: every required file was the same
    // file. Independently rendered artefacts are never byte-identical.
    for i in 0..blobs.len() {
        for j in (i + 1)..blobs.len() {
            if blobs[i].1 == blobs[j].1 {
                failures.push(format!(
                    "{} is byte-identical to {} — these are supposed to be independently \
                     rendered artefacts, not copies of one placeholder",
                    blobs[j].0, blobs[i].0
                ));
            }
        }
    }

    report(failures);
}

fn report(failures: Vec<String>) {
    if failures.is_empty() {
        return;
    }

    // Compilation must not be held hostage to a cosmetic bundling asset. A missing icon
    // cannot make the binary wrong, and the icons are blocked on artwork the CEO supplies
    // (open-items 3.12) — so a hard failure here would freeze all app development for an
    // indefinite wait. Warn on every build; fail hard only where the icon actually ships,
    // which callers signal with RICHOS_REQUIRE_REAL_ICONS=1 (bundling and CI set it).
    let strict = std::env::var("RICHOS_REQUIRE_REAL_ICONS").as_deref() == Ok("1");

    if !strict {
        for line in &failures {
            println!("cargo::warning={}", line);
        }
        println!(
            "cargo::warning=app icons are still placeholders — the binary builds, but a \
             bundle produced now would ship no real icon. Fix: \
             app/scripts/generate-app-icons.sh <artwork.png>. Set \
             RICHOS_REQUIRE_REAL_ICONS=1 to make this fatal (bundling and CI do)."
        );
        return;
    }

    panic!(
        "\n\nrichos-tauri: app icons are not shippable — refusing to build.\n\n{}\n\n\
         Fix: run\n\n    app/scripts/generate-app-icons.sh /path/to/artwork.png\n\n\
         which generates every artefact tauri.conf.json declares from ONE square PNG of \
         at least 1024x1024 with a transparent background. See app/README.md's \"App \
         icon\" section for the full source spec. This is not something to paper over \
         with new placeholder art.\n\n",
        failures
            .iter()
            .map(|f| format!("  - {f}"))
            .collect::<Vec<_>>()
            .join("\n")
    );
}

/// Read Tauri's OWN `bundle.icon` list and turn it into checkable requirements.
fn derive_requirements(conf_path: &Path) -> Result<Vec<Requirement>, String> {
    let text = fs::read_to_string(conf_path)
        .map_err(|e| format!("{} could not be read: {e}", conf_path.display()))?;
    let conf: serde_json::Value = serde_json::from_str(&text)
        .map_err(|e| format!("{} is not valid JSON: {e}", conf_path.display()))?;

    let entries = conf
        .get("bundle")
        .and_then(|b| b.get("icon"))
        .and_then(|i| i.as_array())
        .ok_or_else(|| {
            format!(
                "{}: bundle.icon is missing or not an array. Tauri bundles exactly what \
                 this array lists, so its absence means the app ships with no icon.",
                conf_path.display()
            )
        })?;

    if entries.is_empty() {
        return Err(format!(
            "{}: bundle.icon is empty — the app would ship with no icon.",
            conf_path.display()
        ));
    }

    let mut reqs = Vec::new();
    for entry in entries {
        let rel = entry
            .as_str()
            .ok_or_else(|| format!("bundle.icon entry is not a string: {entry}"))?;
        let name = Path::new(rel)
            .file_name()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_default();
        let lower = name.to_ascii_lowercase();

        if lower.ends_with(".png") {
            if let Some(size) = png_size_from_name(&name) {
                reqs.push(Requirement {
                    rel: rel.to_string(),
                    kind: Kind::Png(size),
                });
            } else if let Some((_, size)) = UNSIZED_PNG.iter().find(|(n, _)| *n == lower) {
                reqs.push(Requirement {
                    rel: rel.to_string(),
                    kind: Kind::Png(*size),
                });
            } else {
                return Err(format!(
                    "bundle.icon entry {rel:?}: cannot derive a required pixel size from \
                     this filename. Name it `<N>x<N>.png` or `<N>x<N>@<M>x.png`. This \
                     gate will not guess a size and let a wrong icon ship."
                ));
            }
        } else if lower.ends_with(".icns") {
            reqs.push(Requirement {
                rel: rel.to_string(),
                kind: Kind::Icns,
            });
        } else if lower.ends_with(".ico") {
            reqs.push(Requirement {
                rel: rel.to_string(),
                kind: Kind::Ico,
            });
        } else {
            return Err(format!(
                "bundle.icon entry {rel:?}: unsupported extension. This gate knows .png, \
                 .icns and .ico. An unknown type must stop the build rather than be skipped."
            ));
        }
    }
    Ok(reqs)
}

/// `32x32.png` -> 32, `128x128@2x.png` -> 256. Returns None if the name does not encode
/// a square size, so the caller can refuse to guess rather than invent one.
fn png_size_from_name(name: &str) -> Option<u32> {
    let stem = name.strip_suffix(".png").or_else(|| name.strip_suffix(".PNG"))?;
    let (dims, mult) = match stem.split_once('@') {
        Some((d, m)) => (d, m.strip_suffix('x').or_else(|| m.strip_suffix('X'))?),
        None => (stem, "1"),
    };
    let (w, h) = dims.split_once('x')?;
    let w: u32 = w.parse().ok()?;
    let h: u32 = h.parse().ok()?;
    let mult: u32 = mult.parse().ok()?;
    if w != h || w == 0 || mult == 0 {
        return None;
    }
    w.checked_mul(mult)
}

/// Minimal PNG width/height reader: no `image` crate needed for a build-time check.
/// PNG layout: 8-byte signature, then the first chunk is always IHDR (length:4,
/// "IHDR":4, width:4 big-endian, height:4 big-endian, ...).
/// Ref: PNG spec section 11.2.2 (https://www.w3.org/TR/png/#11IHDR).
fn png_dimensions(bytes: &[u8]) -> Option<(u32, u32)> {
    const SIG: [u8; 8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    if bytes.len() < 24 || bytes[0..8] != SIG || &bytes[12..16] != b"IHDR" {
        return None;
    }
    let w = u32::from_be_bytes(bytes[16..20].try_into().ok()?);
    let h = u32::from_be_bytes(bytes[20..24].try_into().ok()?);
    Some((w, h))
}

/// Pixel sizes present in an `.icns`, keyed by chunk fourcc.
///
/// We deliberately check PIXEL SIZES, not fourccs. Several fourccs encode the same size,
/// and encoders legitimately differ on which they pick: `cargo tauri icon` writes
/// `is32`/`il32` (the legacy 24-bit RLE variants) for 16/32px, while Apple's own
/// `iconutil` writes the ARGB `ic04`/`ic05` instead. Both cover 16 and 32px. Requiring a
/// literal fourcc list would reject output from Apple's own tool — a checker bug, not an
/// artwork bug. Layout: "icns", total length, then [fourcc:4][length:4][data] chunks.
fn icns_sizes(bytes: &[u8]) -> BTreeSet<u32> {
    let mut found = BTreeSet::new();
    if bytes.len() < 8 || &bytes[0..4] != b"icns" {
        return found;
    }
    let mut off = 8usize;
    while off + 8 <= bytes.len() {
        let fourcc = &bytes[off..off + 4];
        let len = u32::from_be_bytes(bytes[off + 4..off + 8].try_into().unwrap()) as usize;
        if len < 8 {
            break;
        }
        let size = match fourcc {
            b"is32" | b"s8mk" | b"ic04" | b"icp4" => Some(16),
            b"il32" | b"l8mk" | b"ic05" | b"ic11" | b"icp5" => Some(32),
            b"ic12" | b"icp6" => Some(64),
            b"ih32" | b"h8mk" => Some(48),
            b"ic07" | b"it32" | b"t8mk" => Some(128),
            b"ic08" | b"ic13" => Some(256),
            b"ic09" | b"ic14" => Some(512),
            b"ic10" => Some(1024),
            _ => None,
        };
        if let Some(s) = size {
            found.insert(s);
        }
        off += len;
    }
    found
}

/// Layer widths in a Windows `.ico` directory.
/// Layout: reserved:2 (0), type:2 (1 = icon), count:2, then `count` 16-byte entries whose
/// first byte is the width — 0 meaning 256, since the field is a single byte.
/// Ref: https://learn.microsoft.com/en-us/previous-versions/ms997538(v=msdn.10)
fn ico_sizes(bytes: &[u8]) -> Option<BTreeSet<u32>> {
    if bytes.len() < 6 {
        return None;
    }
    let reserved = u16::from_le_bytes(bytes[0..2].try_into().ok()?);
    let kind = u16::from_le_bytes(bytes[2..4].try_into().ok()?);
    let count = u16::from_le_bytes(bytes[4..6].try_into().ok()?) as usize;
    if reserved != 0 || kind != 1 || count == 0 {
        return None;
    }
    if bytes.len() < 6 + count * 16 {
        return None;
    }
    let mut sizes = BTreeSet::new();
    for i in 0..count {
        let w = bytes[6 + i * 16];
        sizes.insert(if w == 0 { 256 } else { w as u32 });
    }
    Some(sizes)
}
