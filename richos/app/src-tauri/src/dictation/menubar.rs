//! **RichOS in the menu bar** (plan section 6, "The menu bar item"; round 19 states 13, 14, 17).
//!
//! Tauri's tray icon (feature `tray-icon`; `tray-icon 0.24.2` was already in `Cargo.lock`): a
//! template microphone while dictation is on and idle, which macOS draws in the menu bar's own
//! ink; the gold microphone while listening. Present only while dictation is on, which in this
//! tool is its whole life: the item goes when the tool does. A click opens the menu window
//! (`bar.rs`), because a native macOS menu cannot carry round 19's type and colors.

use super::bar::{UiEvent, UiTx};
use super::log;
use richos_voice::dictation_bar::{listening_icon, template_icon, Rect, ICON_PX};
use tauri::image::Image;
use tauri::tray::{MouseButton, MouseButtonState, TrayIcon, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager};

pub const ID: &str = "richos-dictation";

/// **The item's picture and whether macOS draws it as a template**: the template microphone
/// while idle, the gold square (not a template: its colors are its own) while listening.
pub fn picture(listening: bool, dark_menu_bar: bool) -> (Image<'static>, bool) {
    if listening {
        (Image::new_owned(listening_icon(dark_menu_bar), ICON_PX, ICON_PX), false)
    } else {
        (Image::new_owned(template_icon(), ICON_PX, ICON_PX), true)
    }
}

/// The item, made in the tool's `setup`.
pub fn build(app: &AppHandle) -> Result<TrayIcon, String> {
    let (icon, template) = picture(false, true);
    TrayIconBuilder::with_id(ID)
        .icon(icon)
        .icon_as_template(template)
        .tooltip("Dictation")
        .show_menu_on_left_click(false)
        .on_tray_icon_event(|tray, event| {
            // On the press, as every menu in the macOS menu bar opens; the release is ignored.
            // walk-37076638c6dd: a click whose release never reached the item opened nothing.
            if let TrayIconEvent::Click { rect, button: MouseButton::Left, button_state: MouseButtonState::Down, .. } = event {
                let app = tray.app_handle();
                let scale = app.primary_monitor().ok().flatten().map(|m| m.scale_factor()).unwrap_or(2.0);
                let p = rect.position.to_logical::<f64>(scale);
                let s = rect.size.to_logical::<f64>(scale);
                let item = Rect { x: p.x, y: p.y, w: s.width, h: s.height };
                if let Some(tx) = app.try_state::<UiTx>() {
                    tx.0.lock().unwrap_or_else(|p| p.into_inner()).send(UiEvent::ItemClicked { item }).ok();
                }
            }
        })
        .build(app)
        .map_err(|e| format!("the menu bar item could not be made: {e}"))
}

/// Where the item sits, in top-left points: Tauri reports it in pixels of the primary screen.
pub fn item_rect(tray: &TrayIcon) -> Option<Rect> {
    let rect = tray.rect().ok().flatten()?;
    let scale = tray.app_handle().primary_monitor().ok().flatten().map(|m| m.scale_factor()).unwrap_or(2.0);
    let p = rect.position.to_logical::<f64>(scale);
    let s = rect.size.to_logical::<f64>(scale);
    Some(Rect { x: p.x, y: p.y, w: s.width, h: s.height })
}

/// Gold while listening, the template microphone otherwise. `dark` is the menu bar's appearance.
pub fn set_listening(tray: &TrayIcon, listening: bool, dark: bool) {
    let (icon, template) = picture(listening, dark);
    if let Err(e) = tray.set_icon(Some(icon)).and_then(|_| tray.set_icon_as_template(template)) {
        log::line(&format!("the menu bar item could not change its picture: {e}"));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// INVARIANT: the item is 18 points at 2x in both states; idle is a template (macOS inks it
    /// for the menu bar), listening is not (its gold is its own), and the bytes are whole RGBA.
    #[test]
    fn the_two_pictures() {
        for dark in [true, false] {
            let (idle, idle_template) = picture(false, dark);
            let (gold, gold_template) = picture(true, dark);
            assert!(idle_template);
            assert!(!gold_template);
            for image in [&idle, &gold] {
                assert_eq!((image.width(), image.height()), (36, 36));
                assert_eq!(image.rgba().len(), 36 * 36 * 4);
            }
            assert_ne!(idle.rgba(), gold.rgba());
        }
        assert_ne!(picture(true, true).0.rgba(), picture(true, false).0.rgba(), "the gold follows the menu bar");
    }
}
