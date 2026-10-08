//! RICH'S ONE OFFER OF DICTATION, the app's half of it (round 19, state 4; dictation plan
//! revision 2, richos-hq `docs/plans/2026-10-08-dictation-anywhere.md`, section 2 row 4).
//!
//! The window shows the offer once, after Start on the setup sheet and once voice is ready
//! (`ui/main.js` `maybeOfferDictation`), and asks this file two things: may it be shown
//! (`dictation_offer`: dictation is there, it was never made, and which key to name), and
//! record that it was (`dictation_offer_shown`). The record is `offered` in
//! `<data dir>/dictation.json`, the one dictation settings file (plan section 1), so a relaunch
//! never shows it again.
//!
//! **Only the `offered` and `key` fields are read or written here, and every other field in the
//! file is kept as it is**: the file's full shape and its other fields belong to the dictation
//! settings store (slice 1). A write reads the file as a JSON object, sets `offered`, and
//! replaces the file atomically (a sibling renamed over it), so the tool never reads half a file.

use std::path::{Path, PathBuf};

use serde::Serialize;

/// `<data dir>/dictation.json` (plan section 1).
pub const FILE_NAME: &str = "dictation.json";

/// What the window needs to decide whether to offer, and what key to name.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct OfferView {
    /// Dictation is there (`richos_core::dictation_ready`). `false` means never offer.
    pub ready: bool,
    /// The offer was made already.
    pub offered: bool,
    /// The chosen key as an F-number, 1 to 19; F1 when the file says nothing usable.
    pub key: u8,
}

fn path(data_dir: &Path) -> PathBuf {
    data_dir.join(FILE_NAME)
}

/// The file as a JSON object: an empty one when there is no file, an error when it cannot be
/// read or is not an object (never a silent "not offered" over a broken file).
fn read_object(data_dir: &Path) -> Result<serde_json::Map<String, serde_json::Value>, String> {
    match std::fs::read(path(data_dir)) {
        Ok(bytes) => match serde_json::from_slice::<serde_json::Value>(&bytes) {
            Ok(serde_json::Value::Object(map)) => Ok(map),
            Ok(_) => Err(format!("{FILE_NAME} is not a JSON object")),
            Err(e) => Err(format!("{FILE_NAME} is not readable: {e}")),
        },
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(serde_json::Map::new()),
        Err(e) => Err(format!("{FILE_NAME} could not be read: {e}")),
    }
}

/// May the offer be shown? A file that cannot be read answers "offered", so a broken file never
/// makes Rich repeat himself; the reason goes to the log.
pub fn view(data_dir: &Path, ready: bool) -> OfferView {
    match read_object(data_dir) {
        Ok(map) => {
            let offered = map.get("offered").and_then(|v| v.as_bool()).unwrap_or(false);
            let key = map
                .get("key")
                .and_then(|v| v.as_u64())
                .filter(|k| (1..=19).contains(k))
                .map(|k| k as u8)
                .unwrap_or(1);
            OfferView { ready, offered, key }
        }
        Err(why) => {
            eprintln!("[richos] dictation offer: not offered, because {why}");
            OfferView { ready, offered: true, key: 1 }
        }
    }
}

/// Record that the offer was shown: `offered: true`, every other field kept.
pub fn mark_shown(data_dir: &Path) -> Result<(), String> {
    let mut map = read_object(data_dir)?;
    map.insert("offered".to_string(), serde_json::Value::Bool(true));
    std::fs::create_dir_all(data_dir).map_err(|e| format!("the data folder could not be created: {e}"))?;
    let partial = data_dir.join(format!(".{FILE_NAME}.offer.{}", std::process::id()));
    let body = serde_json::to_vec_pretty(&serde_json::Value::Object(map)).map_err(|e| e.to_string())?;
    std::fs::write(&partial, body).map_err(|e| format!("{FILE_NAME} could not be written: {e}"))?;
    std::fs::rename(&partial, path(data_dir)).map_err(|e| {
        if let Err(left) = std::fs::remove_file(&partial) {
            eprintln!("[richos] dictation offer: the partial file was left behind: {left}");
        }
        format!("{FILE_NAME} could not be replaced: {e}")
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dir(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("richos-dictation-offer-{name}-{}", std::process::id()));
        if d.exists() {
            std::fs::remove_dir_all(&d).expect("a leftover test folder is removable");
        }
        d
    }

    /// INVARIANT: no file is "never offered, F1"; once shown, the offer is never made again,
    /// relaunch or not, and the gate still decides whether it may be made at all.
    #[test]
    fn the_offer_is_made_once_and_remembered() {
        let d = dir("once");
        assert_eq!(view(&d, true), OfferView { ready: true, offered: false, key: 1 });
        assert_eq!(view(&d, false), OfferView { ready: false, offered: false, key: 1 });
        mark_shown(&d).unwrap();
        assert!(view(&d, true).offered, "a relaunch reads the same file");
        let leftovers: Vec<_> = std::fs::read_dir(&d).unwrap().map(|e| e.unwrap().file_name()).collect();
        assert_eq!(leftovers, vec![std::ffi::OsString::from(FILE_NAME)], "no partial file left");
        std::fs::remove_dir_all(&d).unwrap();
    }

    /// INVARIANT: the offer touches only `offered`; the dictation store's other fields survive,
    /// and the key it names is the chosen one.
    #[test]
    fn marking_the_offer_keeps_every_other_setting() {
        let d = dir("keep");
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(path(&d), br#"{"on":true,"key":5,"model":"small.en","micAsked":true,"axAsked":false,"offered":false}"#).unwrap();
        assert_eq!(view(&d, true).key, 5);
        mark_shown(&d).unwrap();
        let after: serde_json::Value = serde_json::from_slice(&std::fs::read(path(&d)).unwrap()).unwrap();
        assert_eq!(
            after,
            serde_json::json!({"on":true,"key":5,"model":"small.en","micAsked":true,"axAsked":false,"offered":true})
        );
        std::fs::remove_dir_all(&d).unwrap();
    }

    /// INVARIANT: a broken file is never read as "not offered", and is never overwritten.
    #[test]
    fn a_broken_file_offers_nothing_and_is_left_alone() {
        let d = dir("broken");
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(path(&d), b"{not json").unwrap();
        assert!(view(&d, true).offered);
        assert!(mark_shown(&d).is_err());
        assert_eq!(std::fs::read(path(&d)).unwrap(), b"{not json");
        // A key outside F1..F19 names F1.
        std::fs::write(path(&d), br#"{"key":42}"#).unwrap();
        assert_eq!(view(&d, true).key, 1);
        std::fs::remove_dir_all(&d).unwrap();
    }
}
