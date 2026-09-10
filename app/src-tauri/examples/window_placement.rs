//! THE SIZING DECISION, DRY-RUN — what the shipped code WOULD choose, without opening a
//! window.
//!
//! ## Why a dry run and not a screenshot
//!
//! The only complete proof that `docs/hardware-choices-2026-09-10.md` D2 is fixed is a real
//! window opening on each of the CEO's three displays. That means a GUI launch on the desk
//! he is working at, and this task was given with that explicitly forbidden. So this is the
//! largest honest fraction of it: the REAL panels, read from the machine, through the REAL
//! decision function (`src/window_geometry.rs`, included below by path — the same file
//! `main.rs` compiles), printing the size and position the window would open at.
//!
//! **IT OPENS NOTHING.** There is no Tauri runtime here, no event loop, no window, no Dock
//! icon and no focus taken. The only thing it touches outside this process is
//! `system_profiler`, a read-only command-line tool.
//!
//! ## What it can read, and what it cannot
//!
//! `system_profiler SPDisplaysDataType` reports each panel's resolution, what the UI is
//! scaled to (from which the scale factor follows exactly), which display is the main one,
//! and rotation. It does NOT report the work area — the menu bar and the Dock are not in it
//! — and it does not report the arrangement.
//!
//! The shipped code never needs either: it reads `Monitor::work_area()`, which on macOS is
//! `NSScreen.visibleFrame` and has both already subtracted by AppKit. Reading THAT without a
//! window server session is what a dry run cannot do. So this sweeps the inset instead of
//! guessing it once: every model from "nothing taken" — which is also the branch
//! `tauri-runtime-wry` falls back to when `ns_screen()` is unavailable — to a fat Dock, and
//! it fails loudly if any of them puts the window off the screen.
//!
//! Run, from `app/src-tauri`:
//!
//! ```text
//!   cargo run --example window_placement
//!   cargo run --example window_placement -- 1080x1920 1512x945@2   # hypothetical panels
//! ```
//!
//! Exit code 1 if any display in the sweep produces a window that does not fit.

// The module is compiled here in full; a dry run uses the decision half of it and not the
// persistence half, which `main.rs` uses.
#[allow(dead_code)]
#[path = "../src/window_geometry.rs"]
mod window_geometry;

use window_geometry::{decide, Display, Placement, Preference, SavedGeometry, Source};

/// A physical panel as the dry run knows it: points, and the scale factor behind them.
#[derive(Debug, Clone)]
struct Panel {
    name: String,
    /// Width and height in POINTS — what the UI is scaled to, not the pixel count.
    width: f64,
    height: f64,
    scale: f64,
    main: bool,
}

/// The inset models swept per panel. `(menu bar, Dock)` in points.
///
/// `(0, 0)` is not a straw man: it is exactly what `Monitor::work_area()` returns when
/// AppKit cannot hand back an `NSScreen` (`tauri-runtime-wry-2.11.4/src/monitor/macos.rs:28-33`).
const INSET_MODELS: [(f64, f64); 5] =
    [(0.0, 0.0), (24.0, 0.0), (24.0, 70.0), (24.0, 110.0), (38.0, 160.0)];

fn main() {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let panels = if arguments.is_empty() {
        match read_panels_from_system_profiler() {
            Ok(panels) if !panels.is_empty() => panels,
            Ok(_) => {
                eprintln!("system_profiler reported no displays; nothing to dry-run.");
                std::process::exit(1);
            }
            Err(error) => {
                eprintln!("could not read displays: {error}");
                std::process::exit(1);
            }
        }
    } else {
        match arguments.iter().map(|a| parse_panel(a)).collect::<Result<Vec<_>, _>>() {
            Ok(panels) => panels,
            Err(error) => {
                eprintln!("{error}");
                eprintln!("expected panels like 1920x1080 or 3024x1890@2");
                std::process::exit(1);
            }
        }
    };

    println!("RichOS window placement — DRY RUN. No window is created by this program.");
    println!();
    println!("The preference, read from tauri.conf.json's own declaration and repeated by");
    println!("window_geometry::Preference::default():");
    let preference = Preference::default();
    println!(
        "  preferred {:.0}x{:.0} pt, minimum {:.0}x{:.0} pt, edge margin {:.0} pt per side, \
         title bar reserve {:.0} pt",
        preference.width,
        preference.height,
        preference.min_width,
        preference.min_height,
        window_geometry::EDGE_MARGIN,
        window_geometry::TITLE_BAR_RESERVE
    );
    println!();

    let mut failures = 0usize;

    for panel in &panels {
        println!(
            "{}  {:.0} x {:.0} pt  (scale {}){}",
            panel.name,
            panel.width,
            panel.height,
            panel.scale,
            if panel.main { "  [main display]" } else { "" }
        );
        println!(
            "  {:<22} {:<18} {:<16} {}",
            "work area (modeled)", "usable content", "window opens at", "fully on screen"
        );
        for (menu_bar, dock) in INSET_MODELS {
            let work_height = (panel.height - menu_bar - dock).max(1.0);
            let display = Display {
                name: Some(panel.name.clone()),
                x: 0.0,
                y: menu_bar,
                width: panel.width,
                height: work_height,
                scale: panel.scale,
                primary: true,
            };
            let placement = decide(std::slice::from_ref(&display), None);
            let (usable_width, usable_height) = display.usable_content();
            let fits = fits(&placement, &display);
            if !fits {
                failures += 1;
            }
            let position = match placement.position {
                Some((x, y)) => format!("{:.0}x{:.0} at ({x:.0},{y:.0})", placement.width, placement.height),
                None => format!("{:.0}x{:.0}, centered", placement.width, placement.height),
            };
            println!(
                "  {:<22} {:<18} {:<16} {}",
                format!("{:.0}x{:.0}", display.width, display.height),
                format!("{usable_width:.0}x{usable_height:.0}"),
                position,
                if fits { "yes" } else { "NO — OFF SCREEN" }
            );
        }
        // The shipped `minWidth` was itself wider than this panel's usable content on the
        // portrait display, so the floor is reported too rather than assumed harmless.
        let plain = Display {
            name: Some(panel.name.clone()),
            x: 0.0,
            y: 24.0,
            width: panel.width,
            height: (panel.height - 24.0).max(1.0),
            scale: panel.scale,
            primary: true,
        };
        let placement = decide(std::slice::from_ref(&plain), None);
        println!(
            "  floor on this panel: {:.0}x{:.0} pt (the declared {:.0}x{:.0} {})",
            placement.min_width,
            placement.min_height,
            preference.min_width,
            preference.min_height,
            if placement.min_width < preference.min_width
                || placement.min_height < preference.min_height
            {
                "does not fit and was clamped down"
            } else {
                "fits and stands"
            }
        );
        println!("  {}", placement.describe());
        println!();
    }

    // ------------------------------------------------------------------
    // The other half of the requirement: a saved geometry is never restored onto a display
    // that is not there. Shown against the panels actually attached right now.
    // ------------------------------------------------------------------
    println!("A saved geometry from a display that is no longer attached:");
    let attached: Vec<Display> = panels
        .iter()
        .enumerate()
        .map(|(index, panel)| Display {
            name: Some(panel.name.clone()),
            // Laid out left to right. The arrangement is not readable without a window
            // server, and it changes nothing about the SIZE — only the coordinates.
            x: panels.iter().take(index).map(|p| p.width).sum(),
            y: 24.0,
            width: panel.width,
            height: (panel.height - 24.0).max(1.0),
            scale: panel.scale,
            primary: panel.main,
        })
        .collect();
    let vanished = SavedGeometry {
        // Far off to the right of everything attached — a monitor that was unplugged.
        x: attached.iter().map(|d| d.x + d.width).fold(0.0, f64::max) + 400.0,
        y: 600.0,
        width: 1032.0,
        height: 880.0,
        display: Some("a display that was unplugged".into()),
        display_width: Some(1080.0),
        display_height: Some(1896.0),
    };
    let placement = decide(&attached, Some(&vanished));
    println!(
        "  saved: {:.0}x{:.0} at ({:.0},{:.0})",
        vanished.width, vanished.height, vanished.x, vanished.y
    );
    println!("  result: {}", placement.describe());
    if placement.source == Source::Restored {
        println!("  NO — the record was restored onto desk that does not exist.");
        failures += 1;
    } else {
        println!("  discarded, and the window derived on a display that is actually there.");
    }
    println!();

    if failures == 0 {
        println!("Every case above puts the whole window inside a work area.");
    } else {
        println!("{failures} case(s) FAILED.");
        std::process::exit(1);
    }

    println!();
    println!("NOT PROVEN BY THIS PROGRAM: that a real window opens where these numbers say.");
    println!("Only opening one on each display settles that, and it needs the CEO's screen.");
}

fn fits(placement: &Placement, display: &Display) -> bool {
    match placement.position {
        Some((x, y)) => display.holds(x, y, placement.width, placement.height),
        // No position means "let the platform center it", which is only reached when no
        // display could be read at all — not a case this dry run can construct.
        None => false,
    }
}

fn parse_panel(argument: &str) -> Result<Panel, String> {
    let (size, scale) = match argument.split_once('@') {
        Some((size, scale)) => (
            size,
            scale.parse::<f64>().map_err(|_| format!("bad scale factor in {argument:?}"))?,
        ),
        None => (argument, 1.0),
    };
    let (width, height) = size
        .split_once(['x', 'X'])
        .ok_or_else(|| format!("bad panel {argument:?}"))?;
    Ok(Panel {
        name: format!("panel {argument}"),
        width: width.trim().parse().map_err(|_| format!("bad width in {argument:?}"))?,
        height: height.trim().parse().map_err(|_| format!("bad height in {argument:?}"))?,
        scale,
        main: true,
    })
}

/// The panels attached to THIS machine, read from `system_profiler` — a read-only tool that
/// creates no window and takes no focus.
///
/// The scale factor is not guessed: `Resolution` is the mode in pixels and `UI Looks like`
/// is the same mode in points, so their ratio IS `backingScaleFactor`. On a display that
/// reports them equal — which all three of the CEO's do — the ratio is exactly 1.
fn read_panels_from_system_profiler() -> Result<Vec<Panel>, String> {
    let output = std::process::Command::new("system_profiler")
        .arg("SPDisplaysDataType")
        .output()
        .map_err(|e| format!("system_profiler could not be run: {e}"))?;
    if !output.status.success() {
        return Err(format!("system_profiler exited {}", output.status));
    }
    let text = String::from_utf8_lossy(&output.stdout);

    let mut panels: Vec<Panel> = Vec::new();
    let mut name: Option<String> = None;
    let mut pixels: Option<(f64, f64)> = None;
    let mut points: Option<(f64, f64)> = None;
    let mut main = false;

    let flush = |panels: &mut Vec<Panel>,
                 name: &mut Option<String>,
                 pixels: &mut Option<(f64, f64)>,
                 points: &mut Option<(f64, f64)>,
                 main: &mut bool| {
        if let (Some(name), Some((pixel_width, pixel_height))) = (name.take(), *pixels) {
            let (width, height) = points.unwrap_or((pixel_width, pixel_height));
            let scale = if width > 0.0 { pixel_width / width } else { 1.0 };
            panels.push(Panel { name, width, height, scale, main: *main });
        }
        *pixels = None;
        *points = None;
        *main = false;
    };

    for line in text.lines() {
        let trimmed = line.trim();
        if let Some(value) = trimmed.strip_prefix("Resolution:") {
            pixels = parse_dimensions(value);
        } else if let Some(value) = trimmed.strip_prefix("UI Looks like:") {
            points = parse_dimensions(value);
        } else if let Some(value) = trimmed.strip_prefix("Main Display:") {
            main = value.trim().eq_ignore_ascii_case("Yes");
        } else if is_display_heading(line) {
            flush(&mut panels, &mut name, &mut pixels, &mut points, &mut main);
            name = Some(trimmed.trim_end_matches(':').to_string());
        }
    }
    flush(&mut panels, &mut name, &mut pixels, &mut points, &mut main);
    Ok(panels)
}

/// A display heading in `system_profiler`'s plain output is a line ending in `:` indented
/// exactly eight spaces, under `Displays:`. Anything shallower is a chipset or a section.
fn is_display_heading(line: &str) -> bool {
    let indent = line.len() - line.trim_start().len();
    indent == 8 && line.trim_end().ends_with(':')
}

/// `"1920 x 1080 @ 60.00Hz"` -> `(1920.0, 1080.0)`, and so does
/// `"1920 x 1080 (1080p FHD - Full High Definition)"` — the trailing prose after the height
/// is why this takes the leading number of each half rather than parsing the half whole.
fn parse_dimensions(value: &str) -> Option<(f64, f64)> {
    let value = value.split('@').next()?.trim();
    let (width, height) = value.split_once('x')?;
    Some((leading_number(width)?, leading_number(height)?))
}

fn leading_number(value: &str) -> Option<f64> {
    let value = value.trim();
    let end = value
        .find(|c: char| !c.is_ascii_digit() && c != '.')
        .unwrap_or(value.len());
    value[..end].parse().ok()
}
