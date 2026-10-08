//! `<data dir>/dictation.json`: the one settings file dictation has (plan section 1).
//!
//! **The app is its only writer**; the tool reads it at start and again when the app says it
//! changed (`settings-changed`). The accuracy label is derived from `model`, never stored beside
//! it, so the label cannot claim a model the next dictation will not use.

use richos_voice::dictation::{DEFAULT_KEY, MORE_ACCURATE};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

pub const FILE_NAME: &str = "dictation.json";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    /// Dictation is on.
    pub on: bool,
    /// The key, as an F-number, 1 to 19.
    pub key: u8,
    /// The model id: More accurate (`large-v3-turbo-q5_0`, the default) or Faster (`small.en`).
    pub model: String,
    /// RichOS asked macOS for the microphone once.
    pub mic_asked: bool,
    /// RichOS asked macOS for Accessibility once, so "never asked" and "refused" differ.
    pub ax_asked: bool,
    /// Rich made his one offer.
    pub offered: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            on: false,
            key: DEFAULT_KEY,
            model: MORE_ACCURATE.to_string(),
            mic_asked: false,
            ax_asked: false,
            offered: false,
        }
    }
}

impl Settings {
    /// A key outside F1..F19 is not a key: the default stands in, so a hand-edited file can
    /// never leave the tool matching nothing.
    pub fn key(&self) -> u8 {
        if (1..=19).contains(&self.key) { self.key } else { DEFAULT_KEY }
    }
}

pub fn path(data_dir: &Path) -> PathBuf {
    data_dir.join(FILE_NAME)
}

/// The settings on disk. A missing file is the defaults (dictation off); an unreadable one is
/// an error the caller logs, never a silent "off" that hides a broken file.
pub fn read(data_dir: &Path) -> Result<Settings, String> {
    match std::fs::read(path(data_dir)) {
        Ok(bytes) => serde_json::from_slice(&bytes).map_err(|e| format!("{FILE_NAME} is not readable: {e}")),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Settings::default()),
        Err(e) => Err(format!("{FILE_NAME} could not be read: {e}")),
    }
}

/// Write the settings atomically (a sibling file renamed over the old one), so the tool never
/// reads half a file. The app's alone.
pub fn write(data_dir: &Path, settings: &Settings) -> Result<(), String> {
    std::fs::create_dir_all(data_dir).map_err(|e| format!("the data folder could not be created: {e}"))?;
    let target = path(data_dir);
    let partial = data_dir.join(format!(".{FILE_NAME}.{}", std::process::id()));
    let body = serde_json::to_vec_pretty(settings).map_err(|e| e.to_string())?;
    std::fs::write(&partial, body).map_err(|e| format!("{FILE_NAME} could not be written: {e}"))?;
    std::fs::rename(&partial, &target).map_err(|e| {
        std::fs::remove_file(&partial).ok();
        format!("{FILE_NAME} could not be replaced: {e}")
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dir(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("richos-dictation-store-{name}-{}", std::process::id()));
        std::fs::remove_dir_all(&d).ok();
        d
    }

    /// INVARIANT: no file is dictation off, F1, More accurate.
    #[test]
    fn no_file_is_off_on_f1_more_accurate() {
        let d = dir("none");
        let s = read(&d).unwrap();
        assert_eq!(s, Settings::default());
        assert!(!s.on);
        assert_eq!(s.key(), 1);
        assert_eq!(s.model, "large-v3-turbo-q5_0");
    }

    /// INVARIANT: what the app writes is what the tool reads, under the names the plan gives.
    #[test]
    fn a_write_reads_back_with_the_plans_field_names() {
        let d = dir("roundtrip");
        let s = Settings { on: true, key: 5, model: "small.en".into(), mic_asked: true, ax_asked: true, offered: true };
        write(&d, &s).unwrap();
        assert_eq!(read(&d).unwrap(), s);
        let raw = std::fs::read_to_string(path(&d)).unwrap();
        for field in ["\"on\"", "\"key\"", "\"model\"", "\"micAsked\"", "\"axAsked\"", "\"offered\""] {
            assert!(raw.contains(field), "{field} in {raw}");
        }
        let leftovers: Vec<_> = std::fs::read_dir(&d).unwrap().map(|e| e.unwrap().file_name()).collect();
        assert_eq!(leftovers, vec![std::ffi::OsString::from(FILE_NAME)], "no partial file left");
        std::fs::remove_dir_all(&d).unwrap();
    }

    /// INVARIANT: a broken file is an error, never a silent off; a key out of range is F1.
    #[test]
    fn a_broken_file_is_said_and_a_bad_key_is_f1() {
        let d = dir("broken");
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(path(&d), b"{not json").unwrap();
        assert!(read(&d).is_err());
        std::fs::write(path(&d), br#"{"on":true,"key":42}"#).unwrap();
        let s = read(&d).unwrap();
        assert!(s.on);
        assert_eq!(s.key(), 1);
        assert_eq!(s.model, "large-v3-turbo-q5_0", "a missing field takes its default");
        std::fs::remove_dir_all(&d).unwrap();
    }
}
