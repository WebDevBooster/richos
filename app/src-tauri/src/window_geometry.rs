//! HOW BIG THE WINDOW OPENS, AND WHERE — ASKED OF THE DISPLAY, NOT OF A CONSTANT.
//!
//! ## The defect this replaces
//!
//! `docs/hardware-choices-2026-09-10.md` D2. `tauri.conf.json` declared `width: 1400`,
//! `height: 880` and nothing in `app/src-tauri/src/` had ever asked the host a question —
//! the audit's own sweep counted **0** sites in this tree that read anything about the
//! machine. The CEO has three displays and one of them, an HP E243, is mounted portrait:
//!
//! ```text
//!   1400 - 1080 = 320 points of the window past the edge
//!   1400 / 1080 = 1.296  ->  29.6 % wider than that display
//! ```
//!
//! `minWidth: 1024` did not help: it constrains dragging, not the size the window opens at.
//!
//! ## What this module is
//!
//! The whole decision, as arithmetic over plain numbers, with no Tauri type in it — so it
//! is unit-testable against fixtures and can be dry-run from `examples/window_placement.rs`
//! without a window ever being created. `main.rs` reads the real monitors, hands them here,
//! and applies the answer AT CONSTRUCTION.
//!
//! ## THE CONSTANTS ARE A CEILING AND A LAST RESORT, NEVER THE DECISION
//!
//! `PREFERRED_WIDTH`/`PREFERRED_HEIGHT` are the comfortable reading size. They cap the
//! window on a large display (a 4K screen does not want a 3840-point-wide line of text) and
//! they are what is left when no display can be read at all. On every display narrower or
//! shorter than they are, THE DISPLAY WINS — which is the entire point, and which is why
//! "make the constant smaller" is not the fix: a smaller constant is the same defect with a
//! friendlier number, wrong on the next display nobody measured.
//!
//! ## Units: LOGICAL POINTS, throughout, and why that is the only correct choice
//!
//! Everything in this module is logical points in the global top-left-origin space —
//! `CGDisplayBounds` coordinates on macOS. The conversions and their sources:
//!
//! * `tauri::Monitor::work_area()` returns PHYSICAL pixels
//!   (`tauri-2.11.5/src/window/mod.rs:96`), and on macOS is `NSScreen.visibleFrame`
//!   (`tauri-runtime-wry-2.11.4/src/monitor/macos.rs:6-34`) — the menu bar and the Dock are
//!   already subtracted by AppKit, so this module never guesses at either.
//! * A monitor's physical geometry is its POINTS multiplied by ITS OWN scale factor
//!   (`tao-0.35.3/src/platform_impl/macos/monitor.rs:216-231` — `CGDisplayBounds` and
//!   `CGDisplay::pixels_wide` are point values, multiplied by `backingScaleFactor`). Across
//!   a mixed-DPI arrangement tao's "physical" global space is therefore NOT consistent
//!   between displays — 1920 points at scale 2 and 1920 points at scale 1 are the same
//!   distance on the desk and different numbers here. Dividing each monitor's own physical
//!   values by its own scale factor recovers the one space that IS consistent, and that is
//!   what `Display::from_work_area` does.
//! * The builder speaks logical points: `WebviewWindowBuilder::position`, `inner_size` and
//!   `min_inner_size` all say "logical pixels"
//!   (`tauri-2.11.5/src/webview/webview_window.rs:797,804,811`) and reach tao as
//!   `TaoLogicalPosition`/`TaoLogicalSize` (`tauri-runtime-wry-2.11.4/src/lib.rs:1003-1019`).
//!
//! ## THE POSITION IS THE CONTENT TOP-LEFT, SO THE TITLE BAR IS ABOVE IT
//!
//! tao passes the requested position and size to `initWithContentRect:`
//! (`tao-0.35.3/src/platform_impl/macos/window.rs:202-212,249`). The title bar of a
//! `Titled` window is drawn OUTSIDE that rect, above it. A window sized exactly to the work
//! area therefore has its title bar off the top of the screen — which is why
//! `TITLE_BAR_RESERVE` is subtracted from the height budget AND added to the content's top
//! edge. The reserve is deliberately generous: too large only costs a few points of margin,
//! too small puts chrome off-screen.
//!
//! ## Nothing here renders text
//!
//! The only strings this module produces are one-line stderr boot records for an operator
//! log. No CEO-facing surface, so the WCAG AA contrast floor has nothing to bind here; the
//! window it sizes carries `app/ui/`, which is where that floor applies.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// The comfortable reading width. A CEILING on a big display and the LAST RESORT when no
/// display can be read — never, on any path, the answer on a display it does not fit.
pub const PREFERRED_WIDTH: f64 = 1400.0;
/// The comfortable reading height. Same role as `PREFERRED_WIDTH`.
pub const PREFERRED_HEIGHT: f64 = 880.0;
/// The smallest window the UI was designed for. A PREFERENCE: it is itself clamped down to
/// whatever the display can actually show, because `minWidth: 1024` on a 1080-point-wide
/// portrait display is a floor the screen cannot hold once margins are taken.
pub const PREFERRED_MIN_WIDTH: f64 = 1024.0;
/// See `PREFERRED_MIN_WIDTH`.
pub const PREFERRED_MIN_HEIGHT: f64 = 700.0;
/// Breathing room kept between the window and each edge of the work area, in points.
/// Applies per side: a display gives up `2 * EDGE_MARGIN` in each axis.
pub const EDGE_MARGIN: f64 = 24.0;
/// Points reserved above the content rect for the macOS title bar. The standard titled
/// window's title bar is 28 points; erring high costs margin, erring low costs chrome off
/// the top of the screen.
pub const TITLE_BAR_RESERVE: f64 = 28.0;
/// Slack allowed when testing whether a saved rect still sits inside a work area. Saved
/// coordinates make a round trip through i32 physical pixels and a scale factor, so an
/// exactly-maximized window can come back a fraction of a point outside itself.
const CONTAINMENT_TOLERANCE: f64 = 1.0;

/// A display flush against the left edge of the desk can arrive as `-0.0` — `f64`'s `Sum`
/// starts from `-0.0`, and so does more than one Core Graphics path. `{:.0}` renders that
/// as `-0`, which reads like a coordinate off the screen in the one line an operator has to
/// diagnose from. Only the printing is affected; no arithmetic here can tell the two apart.
fn unsign(value: f64) -> f64 {
    if value == 0.0 {
        0.0
    } else {
        value
    }
}

/// THE CONSTANT, DEMOTED. This is what the app would LIKE, and it is consulted only as a
/// ceiling on a display big enough to hold it and as the last resort when no display can be
/// read at all. The live values come from `tauri.conf.json`'s window declaration
/// (`WindowConfig::width/height/min_width/min_height`) so there is exactly one place they
/// are written down; the `Default` below repeats those numbers for tests and for the dry
/// run, and `the_config_still_declares_the_preference_this_module_defaults_to` fails if the
/// two ever drift apart.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Preference {
    pub width: f64,
    pub height: f64,
    pub min_width: f64,
    pub min_height: f64,
}

impl Default for Preference {
    fn default() -> Self {
        Self {
            width: PREFERRED_WIDTH,
            height: PREFERRED_HEIGHT,
            min_width: PREFERRED_MIN_WIDTH,
            min_height: PREFERRED_MIN_HEIGHT,
        }
    }
}

impl Preference {
    /// A preference read off the config is still a number someone typed. Anything that is
    /// not a usable size falls back to the documented default rather than propagating.
    pub fn sanitized(self) -> Self {
        let fallback = Self::default();
        let pick = |value: f64, default: f64| {
            if value.is_finite() && value >= 1.0 {
                value
            } else {
                default
            }
        };
        Self {
            width: pick(self.width, fallback.width),
            height: pick(self.height, fallback.height),
            min_width: pick(self.min_width, fallback.min_width),
            min_height: pick(self.min_height, fallback.min_height),
        }
    }
}

/// One display, as the placement decision sees it: its WORK AREA — what is left after the
/// menu bar and the Dock — in logical points, plus the scale factor it was derived with.
#[derive(Debug, Clone, PartialEq)]
pub struct Display {
    pub name: Option<String>,
    /// Work-area origin, logical points, global top-left-origin space.
    pub x: f64,
    pub y: f64,
    /// Work-area extent, logical points.
    pub width: f64,
    pub height: f64,
    pub scale: f64,
    pub primary: bool,
}

impl Display {
    /// Build from a `tauri::Monitor`'s work area, which arrives in PHYSICAL pixels together
    /// with THAT monitor's scale factor. See the module header for why the division is by
    /// each monitor's own scale and not by any global one.
    pub fn from_work_area(
        name: Option<String>,
        phys_x: i32,
        phys_y: i32,
        phys_width: u32,
        phys_height: u32,
        scale: f64,
        primary: bool,
    ) -> Self {
        // A scale factor of zero or a NaN would poison every number downstream. tao returns
        // 1.0 when it cannot find the screen (monitor.rs:233-239); match that rather than
        // propagate a value no arithmetic survives.
        let scale = if scale.is_finite() && scale > 0.0 { scale } else { 1.0 };
        Self {
            name,
            x: phys_x as f64 / scale,
            y: phys_y as f64 / scale,
            width: phys_width as f64 / scale,
            height: phys_height as f64 / scale,
            scale,
            primary,
        }
    }

    /// The largest CONTENT rect this display can hold: work area, less a margin on each
    /// side, less the title bar that will be drawn above the content.
    pub fn usable_content(&self) -> (f64, f64) {
        (
            (self.width - 2.0 * EDGE_MARGIN).max(1.0),
            (self.height - 2.0 * EDGE_MARGIN - TITLE_BAR_RESERVE).max(1.0),
        )
    }

    /// Does the whole window — content rect plus the title bar above it — sit inside this
    /// display's work area?
    pub fn holds(&self, content_x: f64, content_y: f64, width: f64, height: f64) -> bool {
        let top = content_y - TITLE_BAR_RESERVE;
        content_x >= self.x - CONTAINMENT_TOLERANCE
            && top >= self.y - CONTAINMENT_TOLERANCE
            && content_x + width <= self.x + self.width + CONTAINMENT_TOLERANCE
            && content_y + height <= self.y + self.height + CONTAINMENT_TOLERANCE
    }

    pub fn label(&self) -> String {
        let name = self.name.clone().unwrap_or_else(|| "unnamed display".to_string());
        format!(
            "{name} work area {:.0}x{:.0} pt at ({:.0},{:.0}), scale {}",
            self.width,
            self.height,
            unsign(self.x),
            unsign(self.y),
            self.scale
        )
    }
}

/// Where the window was when it was last closed. Stored in LOGICAL POINTS and as the
/// CONTENT rect, because that is exactly the pair the builder takes back
/// (`position` = content top-left, `inner_size` = content size), so a save and a restore
/// are the same numbers rather than two conversions that can disagree.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SavedGeometry {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    /// The display it was saved on, and that display's work area at the time. Not used to
    /// decide — the containment test below decides — but it is what lets the boot line say
    /// WHY a record was dropped instead of dropping it silently.
    #[serde(default)]
    pub display: Option<String>,
    #[serde(default)]
    pub display_width: Option<f64>,
    #[serde(default)]
    pub display_height: Option<f64>,
}

impl SavedGeometry {
    fn is_sane(&self) -> bool {
        [self.x, self.y, self.width, self.height].iter().all(|v| v.is_finite())
            && self.width >= 1.0
            && self.height >= 1.0
    }
}

/// How the placement below was arrived at. Present in the boot log so a wrong window is a
/// diagnosable event and not a mystery.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    /// A saved geometry that still fits a display present right now, used verbatim.
    Restored,
    /// Derived from the target display's work area at launch.
    Derived,
    /// No display could be read at all. The constants are what is left.
    Fallback,
}

impl Source {
    pub fn as_str(self) -> &'static str {
        match self {
            Source::Restored => "restored",
            Source::Derived => "derived",
            Source::Fallback => "fallback",
        }
    }
}

/// The answer. Every field is logical points and goes straight into the builder.
#[derive(Debug, Clone, PartialEq)]
pub struct Placement {
    pub source: Source,
    pub display: Option<String>,
    /// Content size.
    pub width: f64,
    pub height: f64,
    /// Content top-left. `None` ONLY on `Source::Fallback`, where there is nothing to place
    /// against and the platform's own centering is a better answer than a number we made up
    /// (tao calls `ns_window.center()` when no position is requested —
    /// `tao-0.35.3/src/platform_impl/macos/window.rs:331-333`).
    pub position: Option<(f64, f64)>,
    pub min_width: f64,
    pub min_height: f64,
    /// One line, for stderr. Says what was chosen and what it was chosen from.
    pub note: String,
}

impl Placement {
    /// The whole decision on one line, for a dry run or a boot log.
    pub fn describe(&self) -> String {
        let position = match self.position {
            Some((x, y)) => format!("at ({:.0},{:.0})", unsign(x), unsign(y)),
            None => "centered by the platform".to_string(),
        };
        format!(
            "{} {:.0}x{:.0} pt {position}, min {:.0}x{:.0} — {}",
            self.source.as_str(),
            self.width,
            self.height,
            self.min_width,
            self.min_height,
            self.note
        )
    }
}

/// THE DECISION.
///
/// 1. A saved geometry is honored only if some display PRESENT RIGHT NOW holds the whole
///    window — title bar included — inside its work area. If the display it was saved on is
///    gone, or is still there but has shrunk, or the arrangement moved underneath it, no
///    work area holds it and the record is DISCARDED WHOLE. It is never clamped into view:
///    a half-honored record is a third state to reason about, and the failure it guards
///    against is a window the CEO cannot reach.
/// 2. Otherwise the size is derived from the target display's work area, capped by the
///    preferred size, and centered in that work area.
/// 3. Only if no display can be read at all do the constants stand alone.
///
/// This entry point takes the DEFAULT preference and exists for the tests and for
/// `examples/window_placement.rs`; the app itself calls `decide_with` so the preference it
/// uses is the one `tauri.conf.json` declares and not a second copy. Dead in the binary by
/// construction, which is why the allow is on this function alone rather than on the module.
#[allow(dead_code)]
pub fn decide(displays: &[Display], saved: Option<&SavedGeometry>) -> Placement {
    decide_with(displays, saved, Preference::default())
}

/// `decide`, with the preference taken from `tauri.conf.json` rather than from this
/// module's defaults. This is the one the app calls.
pub fn decide_with(
    displays: &[Display],
    saved: Option<&SavedGeometry>,
    preference: Preference,
) -> Placement {
    let preference = preference.sanitized();
    if displays.is_empty() {
        return Placement {
            source: Source::Fallback,
            display: None,
            width: preference.width,
            height: preference.height,
            position: None,
            min_width: preference.min_width,
            min_height: preference.min_height,
            note: "no display could be read; the preferred size is the last resort and the \
                   platform is left to center it"
                .to_string(),
        };
    }

    if let Some(saved) = saved.filter(|s| s.is_sane()) {
        if let Some(display) =
            displays.iter().find(|d| d.holds(saved.x, saved.y, saved.width, saved.height))
        {
            let (usable_w, usable_h) = display.usable_content();
            return Placement {
                source: Source::Restored,
                display: display.name.clone(),
                width: saved.width,
                height: saved.height,
                position: Some((saved.x, saved.y)),
                min_width: preference.min_width.min(usable_w).min(saved.width),
                min_height: preference.min_height.min(usable_h).min(saved.height),
                note: format!("where it was left, still inside {}", display.label()),
            };
        }
    }

    let discarded = saved.map(|saved| {
        let was = match (saved.display.as_deref(), saved.display_width, saved.display_height) {
            (Some(name), Some(w), Some(h)) => format!("{name} at {w:.0}x{h:.0} pt"),
            (Some(name), _, _) => name.to_string(),
            _ => "an unrecorded display".to_string(),
        };
        format!(
            "the saved {:.0}x{:.0} at ({:.0},{:.0}) on {was} fits no display attached now — \
             discarded; ",
            saved.width, saved.height, saved.x, saved.y
        )
    });

    let target = displays.iter().find(|d| d.primary).unwrap_or(&displays[0]);
    let (usable_w, usable_h) = target.usable_content();
    let width = preference.width.min(usable_w);
    let height = preference.height.min(usable_h);

    // Center the WHOLE window — content plus title bar — in the work area, then clamp the
    // content rect inside it. The clamp cannot bite after the arithmetic above; it is there
    // so that a future change to either half cannot quietly reintroduce an off-screen edge.
    let outer_height = height + TITLE_BAR_RESERVE;
    let outer_x = target.x + (target.width - width) / 2.0;
    let outer_y = target.y + (target.height - outer_height) / 2.0;
    let x = outer_x.clamp(target.x, (target.x + target.width - width).max(target.x));
    let y = (outer_y + TITLE_BAR_RESERVE).clamp(
        target.y + TITLE_BAR_RESERVE,
        (target.y + target.height - height).max(target.y + TITLE_BAR_RESERVE),
    );

    let capped = if width < preference.width || height < preference.height {
        "the display is smaller than the preferred size, so the display decided"
    } else {
        "the preferred size fits, so it caps the window"
    };
    Placement {
        source: Source::Derived,
        display: target.name.clone(),
        width,
        height,
        position: Some((x, y)),
        min_width: preference.min_width.min(width),
        min_height: preference.min_height.min(height),
        note: format!("{}{} — {capped}", discarded.unwrap_or_default(), target.label()),
    }
}

/// The saved-geometry file. Small, and never load-bearing: every read failure and every
/// unparseable byte degrades to "no saved geometry", which is a fully-derived window.
pub struct GeometryStore {
    path: PathBuf,
    last: Option<SavedGeometry>,
}

impl GeometryStore {
    pub fn new(path: impl AsRef<Path>) -> Self {
        Self { path: path.as_ref().to_path_buf(), last: None }
    }

    /// What was saved last time, or `None` — including when the file is missing, corrupt,
    /// unreadable or holds numbers that are not numbers.
    pub fn load(&self) -> Option<SavedGeometry> {
        let bytes = std::fs::read(&self.path).ok()?;
        let saved: SavedGeometry = serde_json::from_slice(&bytes).ok()?;
        saved.is_sane().then_some(saved)
    }

    /// Record a new geometry. Returns `Ok(false)` when the value is unchanged and nothing
    /// was written, so a stream of resize events costs one write and not hundreds.
    pub fn save(&mut self, geometry: SavedGeometry) -> std::io::Result<bool> {
        if !geometry.is_sane() || self.last.as_ref() == Some(&geometry) {
            return Ok(false);
        }
        let bytes = serde_json::to_vec_pretty(&geometry)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        // Write-then-rename: a window moved while the disk fills must not leave a truncated
        // record where a whole one was.
        let temporary = self.path.with_extension("json.tmp");
        std::fs::write(&temporary, &bytes)?;
        std::fs::rename(&temporary, &self.path)?;
        self.last = Some(geometry);
        Ok(true)
    }
}
#[cfg(test)]
mod tests {
    use super::*;

    // ============================================================================
    // THE FIXTURES ARE THE CEO'S ACTUAL DESK
    // ============================================================================
    //
    // Measured, not remembered — `system_profiler SPDisplaysDataType` on this machine,
    // 2026-09-10, the same command `docs/hardware-choices-2026-09-10.md` D2 quotes:
    //
    //   BenQ GC2870      Resolution 1920 x 1080   UI Looks like 1920 x 1080   Main Display: Yes
    //   HP E243          Resolution 1080 x 1920   UI Looks like 1080 x 1920   Rotation: 270
    //   VA2246 SERIES    Resolution 1920 x 1080   UI Looks like 1920 x 1080
    //
    // `Resolution == UI Looks like` on all three, so every scale factor here is 1.0 and a
    // point is a pixel on this desk.
    //
    // WHAT IS MODELED RATHER THAN MEASURED, and it is exactly two things: the menu bar and
    // the Dock. `system_profiler` does not report either, and reading the real
    // `NSScreen.visibleFrame` needs a window server connection this test is forbidden to
    // make. So the SHIPPED code never models them — it reads `Monitor::work_area()`, which
    // is `NSScreen.visibleFrame` and has both already subtracted — and these fixtures model
    // them only to produce numbers a reader can check. `every_inset_model_still_fits` below
    // sweeps the model from zero to absurd so that no conclusion here rests on the guess.
    const MENU_BAR: f64 = 24.0;
    const DOCK: f64 = 70.0;

    fn display(name: &str, x: f64, y: f64, w: f64, h: f64, primary: bool) -> Display {
        Display { name: Some(name.to_string()), x, y, width: w, height: h, scale: 1.0, primary }
    }

    /// The three displays with a plain menu bar on each and the Dock on the main one.
    fn ceo_desk(primary_name: &str) -> Vec<Display> {
        vec![
            display(
                "BenQ GC2870",
                0.0,
                MENU_BAR,
                1920.0,
                1080.0 - MENU_BAR - DOCK,
                primary_name == "BenQ GC2870",
            ),
            display(
                "HP E243",
                1920.0,
                MENU_BAR,
                1080.0,
                1920.0 - MENU_BAR,
                primary_name == "HP E243",
            ),
            display(
                "VA2246 SERIES",
                3000.0,
                MENU_BAR,
                1920.0,
                1080.0 - MENU_BAR,
                primary_name == "VA2246 SERIES",
            ),
        ]
    }

    fn fits(placement: &Placement, display: &Display) -> bool {
        let (x, y) = placement.position.expect("a derived placement always carries a position");
        display.holds(x, y, placement.width, placement.height)
    }

    // ============================================================================
    // THE DEFECT, ON THE DISPLAY THAT HAS IT
    // ============================================================================

    /// The portrait HP E243 is the display D2 measured 320 points of window hanging off.
    ///
    ///   work area          1080 x (1920 - 24)      = 1080 x 1896
    ///   usable content     (1080 - 2*24) x (1896 - 2*24 - 28)
    ///                    = 1032 x 1820
    ///   width              min(1400, 1032)         = 1032   <- the display decided
    ///   height             min( 880, 1820)         =  880   <- the preference decided
    #[test]
    fn the_portrait_display_gets_a_window_that_fits_it() {
        let desk = ceo_desk("HP E243");
        let hp = desk.iter().find(|d| d.name.as_deref() == Some("HP E243")).unwrap().clone();

        assert_eq!(hp.usable_content(), (1032.0, 1820.0));

        let placement = decide(&desk, None);
        assert_eq!(placement.source, Source::Derived);
        assert_eq!(placement.display.as_deref(), Some("HP E243"));
        assert_eq!(placement.width, 1032.0);
        assert_eq!(placement.height, 880.0);
        // 1400 would have been 320 points past the right edge. 1032 is 48 inside it.
        assert!(placement.width < PREFERRED_WIDTH);
        assert!(placement.width + 2.0 * EDGE_MARGIN <= hp.width);
        assert!(fits(&placement, &hp), "{}", placement.describe());
    }

    /// And `minWidth: 1024` is a preference too: it survives here (1024 <= 1032) but it is
    /// clamped rather than trusted, because a narrower display would make it a floor the
    /// screen cannot hold — which is precisely how the shipped `minWidth` failed.
    #[test]
    fn the_minimum_never_exceeds_what_the_display_can_show() {
        let placement = decide(&ceo_desk("HP E243"), None);
        assert_eq!(placement.min_width, 1024.0);
        assert!(placement.min_width <= placement.width);

        // A 900-point-wide display: the shipped minWidth of 1024 is itself off-screen.
        let narrow = vec![display("Narrow", 0.0, 0.0, 900.0, 700.0, true)];
        let placement = decide(&narrow, None);
        assert_eq!(placement.width, 852.0); // 900 - 2*24
        assert_eq!(placement.min_width, 852.0); // NOT 1024
        assert!(placement.min_height <= placement.height);
        assert!(fits(&placement, &narrow[0]), "{}", placement.describe());
    }

    // ============================================================================
    // THE DISPLAYS WHERE THE CONSTANT WAS ALREADY RIGHT — IT MUST STAY RIGHT
    // ============================================================================

    /// 1920 x 1080 with the menu bar and the Dock taken: work area 1920 x 986, usable
    /// content 1872 x 910, so `min(1400, 1872) x min(880, 910)` = the shipped 1400 x 880.
    /// The fix must not cost anything on the display the value was chosen for.
    #[test]
    fn the_main_landscape_display_still_gets_the_preferred_size() {
        let desk = ceo_desk("BenQ GC2870");
        let benq = desk[0].clone();
        assert_eq!(benq.usable_content(), (1872.0, 910.0));

        let placement = decide(&desk, None);
        assert_eq!(placement.display.as_deref(), Some("BenQ GC2870"));
        assert_eq!((placement.width, placement.height), (1400.0, 880.0));
        assert!(fits(&placement, &benq), "{}", placement.describe());
    }

    #[test]
    fn the_second_landscape_display_also_gets_the_preferred_size() {
        let desk = ceo_desk("VA2246 SERIES");
        let va = desk[2].clone();
        let placement = decide(&desk, None);
        assert_eq!(placement.display.as_deref(), Some("VA2246 SERIES"));
        assert_eq!((placement.width, placement.height), (1400.0, 880.0));
        assert!(fits(&placement, &va), "{}", placement.describe());
    }

    /// A big display does not get a 3840-point line of text: the preference is a ceiling.
    #[test]
    fn a_large_display_is_capped_by_the_preference_not_filled() {
        let big = vec![display("Pro Display XDR", 0.0, 0.0, 3008.0, 1670.0, true)];
        let placement = decide(&big, None);
        assert_eq!((placement.width, placement.height), (1400.0, 880.0));
        assert!(placement.note.contains("caps the window"));
    }

    // ============================================================================
    // THE MODEL IS NOT LOAD-BEARING
    // ============================================================================

    /// Whatever the menu bar and the Dock actually take — including nothing at all, which
    /// is the branch `tauri-runtime-wry` falls back to when `ns_screen()` is unavailable —
    /// the window still fits on every one of the three real displays.
    #[test]
    fn every_inset_model_still_fits() {
        let panels = [(1920.0_f64, 1080.0_f64), (1080.0, 1920.0), (1920.0, 1080.0)];
        for menu_bar in [0.0_f64, 22.0, 24.0, 25.0, 38.0] {
            for dock in [0.0_f64, 53.0, 70.0, 110.0, 160.0] {
                for (panel_w, panel_h) in panels {
                    let work_h = (panel_h - menu_bar - dock).max(1.0);
                    let one = vec![display("under test", 0.0, menu_bar, panel_w, work_h, true)];
                    let placement = decide(&one, None);
                    assert!(
                        fits(&placement, &one[0]),
                        "menu bar {menu_bar}, dock {dock}, panel {panel_w}x{panel_h}: {}",
                        placement.describe()
                    );
                    assert!(placement.width <= PREFERRED_WIDTH);
                    assert!(placement.height <= PREFERRED_HEIGHT);
                }
            }
        }
    }

    /// A sweep well past any real panel, in both orientations, including sizes far smaller
    /// than the shipped minimum. Nothing may ever land outside the work area.
    #[test]
    fn no_display_size_produces_an_off_screen_window() {
        let mut width = 320.0_f64;
        while width <= 6016.0 {
            let mut height = 240.0_f64;
            while height <= 3384.0 {
                let one = vec![display("sweep", -400.0, 137.0, width, height, true)];
                let placement = decide(&one, None);
                assert!(
                    fits(&placement, &one[0]),
                    "{width}x{height}: {}",
                    placement.describe()
                );
                height *= 1.37;
            }
            width *= 1.37;
        }
    }

    // ============================================================================
    // MIXED SCALE FACTORS
    // ============================================================================

    /// `Monitor::work_area()` hands back PHYSICAL pixels; a Retina panel reports twice the
    /// points. Both displays here are 1512 x 945 points of usable desk, and the decision
    /// must be identical — if the scale factor leaked into the arithmetic, the Retina one
    /// would be sized for a 3024-point screen that does not exist.
    #[test]
    fn a_retina_display_is_measured_in_points_not_pixels() {
        let retina = Display::from_work_area(
            Some("Built-in Retina".into()),
            0,
            0,
            3024,
            1890,
            2.0,
            true,
        );
        let plain =
            Display::from_work_area(Some("Plain".into()), 0, 0, 1512, 945, 1.0, true);

        assert_eq!((retina.width, retina.height), (1512.0, 945.0));
        assert_eq!(retina.usable_content(), plain.usable_content());

        let a = decide(std::slice::from_ref(&retina), None);
        let b = decide(std::slice::from_ref(&plain), None);
        assert_eq!((a.width, a.height), (b.width, b.height));
        assert!(fits(&a, &retina), "{}", a.describe());
    }

    /// The origin of a monitor to the right of a 2x one is also points x its OWN scale, so
    /// the division has to be per display. A single global scale factor would put this
    /// display's work area at x = 3024 and center the window on empty desk.
    #[test]
    fn each_display_is_divided_by_its_own_scale_factor() {
        let external =
            Display::from_work_area(Some("External".into()), 1512, 0, 1920, 1080, 1.0, true);
        assert_eq!(external.x, 1512.0);
        let placement = decide(&[external.clone()], None);
        assert!(fits(&placement, &external), "{}", placement.describe());
        let (x, _) = placement.position.unwrap();
        assert!(x >= 1512.0);
    }

    /// A monitor that reports a nonsense scale factor must not produce nonsense geometry.
    #[test]
    fn an_impossible_scale_factor_degrades_to_one() {
        for bad in [0.0, -2.0, f64::NAN, f64::INFINITY] {
            let d = Display::from_work_area(None, 0, 0, 1600, 900, bad, true);
            assert_eq!(d.scale, 1.0);
            assert_eq!((d.width, d.height), (1600.0, 900.0));
        }
    }

    // ============================================================================
    // A SAVED GEOMETRY IS NEVER RESTORED ONTO A DISPLAY THAT IS NOT THERE
    // ============================================================================

    fn saved_on_the_portrait_display() -> SavedGeometry {
        // Where the window would sit after being derived on the HP: 1032 x 880 at
        // x = 1920 + (1080 - 1032)/2 = 1944.
        SavedGeometry {
            x: 1944.0,
            y: 546.0,
            width: 1032.0,
            height: 880.0,
            display: Some("HP E243".into()),
            display_width: Some(1080.0),
            display_height: Some(1896.0),
        }
    }

    #[test]
    fn a_geometry_that_still_fits_is_restored_verbatim() {
        let saved = saved_on_the_portrait_display();
        let placement = decide(&ceo_desk("BenQ GC2870"), Some(&saved));
        assert_eq!(placement.source, Source::Restored);
        assert_eq!(placement.display.as_deref(), Some("HP E243"));
        assert_eq!(placement.position, Some((1944.0, 546.0)));
        assert_eq!((placement.width, placement.height), (1032.0, 880.0));
    }

    /// HE UNPLUGS THE PORTRAIT MONITOR. The saved rect lives at x = 1944..2976, which is
    /// desk that no longer exists. It must not be restored there, and it must not be
    /// dragged to the nearest edge either — the record is dropped and the window is derived
    /// on the display that IS there.
    #[test]
    fn a_geometry_on_a_vanished_display_is_discarded_not_clamped() {
        let saved = saved_on_the_portrait_display();
        let remaining: Vec<Display> = ceo_desk("BenQ GC2870")
            .into_iter()
            .filter(|d| d.name.as_deref() != Some("HP E243"))
            .collect();
        assert!(remaining.iter().all(|d| !d.holds(saved.x, saved.y, saved.width, saved.height)));

        let placement = decide(&remaining, Some(&saved));
        assert_eq!(placement.source, Source::Derived);
        assert_eq!(placement.display.as_deref(), Some("BenQ GC2870"));
        assert_eq!((placement.width, placement.height), (1400.0, 880.0));
        assert!(fits(&placement, &remaining[0]), "{}", placement.describe());
        // The boot line has to SAY it dropped the record, naming what it dropped.
        assert!(placement.note.contains("discarded"), "{}", placement.note);
        assert!(placement.note.contains("HP E243"), "{}", placement.note);
        // And nothing of the old rect survives into the new one.
        assert_ne!(placement.position, Some((saved.x, saved.y)));
    }

    /// THE DISPLAY IS STILL THERE AND HAS SHRUNK — a resolution change, or a Dock that got
    /// bigger. Same rule: no work area holds the whole window, so the record goes.
    #[test]
    fn a_geometry_on_a_display_that_shrank_is_discarded() {
        let saved = SavedGeometry {
            x: 260.0,
            y: 128.0,
            width: 1400.0,
            height: 880.0,
            display: Some("BenQ GC2870".into()),
            display_width: Some(1920.0),
            display_height: Some(986.0),
        };
        let shrunk = vec![display("BenQ GC2870", 0.0, 24.0, 1280.0, 776.0, true)];
        let placement = decide(&shrunk, Some(&saved));
        assert_eq!(placement.source, Source::Derived);
        assert_eq!(placement.width, 1232.0); // 1280 - 2*24
        assert_eq!(placement.height, 700.0); // 776 - 2*24 - 28
        assert!(fits(&placement, &shrunk[0]), "{}", placement.describe());
        assert!(placement.note.contains("discarded"), "{}", placement.note);
    }

    /// The arrangement moved: same displays, different origins. A saved rect that is now
    /// over a gap between them is not on any work area.
    #[test]
    fn a_geometry_stranded_by_a_rearranged_desk_is_discarded() {
        let saved = saved_on_the_portrait_display();
        let moved = vec![
            display("BenQ GC2870", 0.0, 24.0, 1920.0, 986.0, true),
            display("HP E243", -1080.0, 24.0, 1080.0, 1896.0, false),
        ];
        let placement = decide(&moved, Some(&saved));
        assert_eq!(placement.source, Source::Derived);
    }

    /// A window sitting flush against the work area on all four sides survives the round
    /// trip through i32 physical pixels — this is what `CONTAINMENT_TOLERANCE` is for.
    #[test]
    fn a_flush_window_is_not_thrown_away_by_rounding() {
        let d = display("Flush", 0.0, 24.0, 1920.0, 986.0, true);
        let saved = SavedGeometry {
            x: 0.0,
            y: 24.0 + TITLE_BAR_RESERVE,
            width: 1920.0,
            height: 986.0 - TITLE_BAR_RESERVE,
            display: Some("Flush".into()),
            display_width: Some(1920.0),
            display_height: Some(986.0),
        };
        let placement = decide(&[d], Some(&saved));
        assert_eq!(placement.source, Source::Restored);
    }

    /// A record whose numbers are not numbers is not a record.
    #[test]
    fn a_corrupt_saved_record_is_ignored() {
        for (x, w) in [(f64::NAN, 1400.0), (0.0, 0.0), (f64::INFINITY, 1400.0)] {
            let saved = SavedGeometry {
                x,
                y: 100.0,
                width: w,
                height: 880.0,
                display: None,
                display_width: None,
                display_height: None,
            };
            let placement = decide(&ceo_desk("BenQ GC2870"), Some(&saved));
            assert_eq!(placement.source, Source::Derived);
        }
    }

    // ============================================================================
    // NOTHING READABLE AT ALL
    // ============================================================================

    /// The ONLY path on which the constants stand alone, and it says so out loud. No
    /// position is offered, because a coordinate invented against no display is worse than
    /// letting the platform center the window on the main screen.
    #[test]
    fn with_no_readable_display_the_constant_is_the_last_resort() {
        let placement = decide(&[], None);
        assert_eq!(placement.source, Source::Fallback);
        assert_eq!((placement.width, placement.height), (PREFERRED_WIDTH, PREFERRED_HEIGHT));
        assert_eq!(placement.position, None);
        assert!(placement.note.contains("last resort"));
    }

    // ============================================================================
    // THE STORE
    // ============================================================================

    /// THE PREFERENCE LIVES IN `tauri.conf.json` AND THIS MODULE ONLY REPEATS IT. Two
    /// copies of a number are one copy and one lie, so this reads the shipped config and
    /// fails the moment they disagree.
    ///
    /// It also pins `center` OFF, and that is not housekeeping: with `center: true` the
    /// runtime recomputes the position from `calculate_window_center_position` and
    /// OVERWRITES whatever this module decided (`tauri-runtime-wry-2.11.4/src/lib.rs:4595-4599`),
    /// which would silently destroy a restored geometry.
    #[test]
    fn the_config_still_declares_the_preference_this_module_defaults_to() {
        let config: serde_json::Value = serde_json::from_str(include_str!("../tauri.conf.json"))
            .expect("tauri.conf.json parses");
        let window = &config["app"]["windows"][0];
        let preference = Preference::default();
        assert_eq!(window["width"].as_f64(), Some(preference.width));
        assert_eq!(window["height"].as_f64(), Some(preference.height));
        assert_eq!(window["minWidth"].as_f64(), Some(preference.min_width));
        assert_eq!(window["minHeight"].as_f64(), Some(preference.min_height));
        assert!(
            window.get("center").is_none(),
            "`center` in the config overwrites the position decided here"
        );
    }

    /// A preference someone typed wrongly must not become a window nobody can use.
    #[test]
    fn an_unusable_preference_falls_back_to_the_documented_default() {
        let broken = Preference { width: 0.0, height: f64::NAN, min_width: -3.0, min_height: 700.0 };
        assert_eq!(broken.sanitized(), Preference::default());
    }

    #[test]
    fn the_store_round_trips_and_writes_only_on_a_change() {
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let dir = std::env::temp_dir()
            .join(format!("richos-window-geometry-{}-{stamp}", std::process::id()));
        let path = dir.join("window.json");
        let mut store = GeometryStore::new(&path);
        assert_eq!(store.load(), None, "nothing saved yet");

        let saved = saved_on_the_portrait_display();
        assert!(store.save(saved.clone()).expect("first write"));
        assert!(!store.save(saved.clone()).expect("second, identical"), "no repeat write");
        assert_eq!(store.load().as_ref(), Some(&saved));

        let mut moved = saved.clone();
        moved.x += 40.0;
        assert!(store.save(moved.clone()).expect("a real move"));
        assert_eq!(store.load().as_ref(), Some(&moved));

        std::fs::write(&path, b"{ not json").expect("corrupt it");
        assert_eq!(GeometryStore::new(&path).load(), None, "corrupt reads as absent");

        std::fs::remove_dir_all(&dir).ok();
    }
}
