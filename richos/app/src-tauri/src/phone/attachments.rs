//! **PHOTOS AND FILES FROM THE PHONE** — native-apps build plan 2026-09-22 §5.1 stream M (1),
//! v1 scope CEO §75 ("photos and files to Rich, including Share to Rich").
//!
//! # The wire, in two steps
//!
//! 1. **Each file is its own signed upload**, on the existing message route so the surface keeps
//!    its ceiling of four routes (the same move voice made):
//!    `POST /api/messages?kind=attachment&client_id=<message client_id>&attachment_id=<id>&name=<percent-encoded name>`
//!    with the file's media type as `Content-Type` and the raw bytes as the body. One file per
//!    request is what makes a flaky connection survivable: a failed upload is retried alone,
//!    and a retry of bytes the Mac already holds is answered `duplicate: true` without
//!    rewriting anything.
//! 2. **The message commits them**, as ordinary JSON on the same route:
//!    `{"client_id","thread_id","kind":"attachments","text":"…","attachments":[{"id","sha256"}],"sent_at"}`.
//!    It goes through [`super::delivery::DeliveryDesk`] exactly like a text message, so it is
//!    replay-safe and deduplicated by `client_id` across Mac restarts, and the receipt's body
//!    hash binds the text, the thread and every file's SHA-256 together.
//!
//! An older Mac refuses both steps (`kind=attachment` has no JSON body; `kind:"attachments"`
//! is not `text`), so a client that ignored the `attachments` capability still cannot have its
//! files silently dropped while its words go through.
//!
//! # Where the file ends up, and how Rich is told (Rich's decision, recorded in the brief)
//!
//! Stored under `<app data>/attachments/<conversation>/<message client_id>/<sanitized name>`,
//! kept as long as that conversation's history. The message that reaches Rich is the CEO's
//! text followed by a block naming each file's absolute path, media type and size — see
//! [`describe`] — so Rich opens it with his normal file tools. **No parsing, conversion or
//! preview generation happens here in v1.**
//!
//! # What this does NOT do, said rather than left to be discovered
//!
//! - **No byte-range resume.** A file either arrives whole or is retried whole; the per-file
//!   limit and the five-minute upload window ([`UPLOAD_SECONDS`]) are sized so that is
//!   survivable on a weak uplink (below).
//! - **HEIC is accepted and stored as HEIC, and the model cannot look at it as-is.** Anthropic's
//!   vision documentation (platform.claude.com/docs/en/build-with-claude/vision, read 2026-09-22)
//!   lists JPEG, PNG, GIF and WebP only, at most 10 MB base64-encoded per image and 32 MB per
//!   request, and downscales anything past a 2576 px long edge. So a phone that wants a photo
//!   *seen* should send JPEG at or under 2576 px on its long edge — nothing the model would see is
//!   lost, and the upload is a fraction of the size. Rich can convert a HEIC with macOS's own
//!   `sips`, but that is a step, not a view.
//! - **Thread deletion does not reach these files yet**, because no delete-thread command
//!   exists (`richos-core/src/journal.rs`, `delete_thread` doc). [`AttachmentDesk::delete_thread`]
//!   is the primitive whoever adds one must call.

use super::{hex, now_millis, random_bytes, sha256, PhoneError};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// **25 MiB per file** (26,214,400 bytes), not the 100 MB the round-12 attachment mockup
/// proposes. The grounds, each checkable:
/// - **Memory.** The listener buffers a body before it can check the signature over it
///   (`listen.rs`, `Limited::new(..).collect()`), across 32 connection slots: 32 × 25 MiB is
///   800 MiB of worst-case unauthenticated buffering; 32 × 100 MB would be 3.2 GB.
/// - **Upload time.** 25 MiB over the 300 s window needs 0.70 Mbit/s ([`UPLOAD_SECONDS`]);
///   100 MB would need 2.67 Mbit/s sustained, which weak cellular does not give.
/// - **The public route.** Connect runs through Cloudflare, whose published Free/Pro request-body
///   limit is 100 MB (their documentation; not re-measured here), so a 100 MB file plus headers
///   would fail on exactly the route that is used away from home.
/// - **What Rich can read.** A PDF reaches the model inside a 32 MB request; an image at most
///   10 MB base64 (about 7.5 MB raw). Past 25 MiB nothing is gained for Rich.
pub const MAX_FILE_BYTES: usize = 25 * 1024 * 1024;
/// A message carries at most ten files, and at most 100 MiB across them.
pub const MAX_FILES_PER_MESSAGE: usize = 10;
pub const MAX_MESSAGE_BYTES: u64 = 100 * 1024 * 1024;
/// What one phone may leave uploaded-but-unsent on this Mac before the oldest unsent message's
/// files are evicted (they are still on the phone, which re-uploads what the commit says is
/// missing).
pub const MAX_STAGED_BYTES: u64 = 200 * 1024 * 1024;
/// Uploaded files whose message never arrived are swept after seven days.
pub const STAGING_TTL_MS: u64 = 7 * 24 * 60 * 60 * 1000;
/// An unsent message touched within 15 minutes is never evicted to make room (see `make_room`).
pub const EVICTION_GRACE_MS: u64 = 15 * 60 * 1000;
/// **How long one upload may take: 300 s.** Frame math, not a feeling: 25 MiB is
/// 26,214,400 × 8 = 209,715,200 bits; over 120 s (the voice window) that needs 1.75 Mbit/s of
/// uplink, over 300 s it needs 0.70 Mbit/s, which a weak LTE or hotel connection still carries.
pub const UPLOAD_SECONDS: u64 = 300;
/// The longest name a client may send before sanitizing, in bytes.
pub const MAX_RAW_NAME_BYTES: usize = 1024;

/// How the Mac recognizes a file is what it claims to be. Checked against the bytes, never
/// taken from the name or the header alone: a file Rich opens is stored under an extension
/// that matches both its declared type and its content.
#[derive(Clone, Copy, Debug, PartialEq)]
enum Sniff { Jpeg, Png, Gif, Webp, Heif, Pdf, Text, Zip }

/// One accepted kind of file.
#[derive(Debug)]
pub struct Kind {
    pub media_type: &'static str,
    /// The extension the Mac writes when the client's name does not already carry one of
    /// [`Kind::extensions`].
    pub extension: &'static str,
    pub extensions: &'static [&'static str],
    /// What the person is told the file is, in a refusal.
    pub label: &'static str,
    sniff: Sniff,
}

/// **THE ACCEPTED TYPES, AND WHY EACH IS HERE.**
///
/// - Photos: JPEG and PNG (what a phone camera and a screenshot produce), HEIC/HEIF (the iPhone
///   camera default, required by the brief), GIF and WebP (what other apps share).
/// - Documents: PDF; plain text, Markdown and CSV (validated as UTF-8 with no NUL bytes);
///   Word, Excel and PowerPoint in their current (Office Open XML) formats.
/// - **Refused in v1:** the legacy binary Office formats (`.doc`, `.xls`, `.ppt`, OLE compound
///   files that can carry macros), archives, executables, audio and video. Each can be added
///   as one row here when there is a reason; none is needed for "photos and files to Rich".
pub const ACCEPTED: &[Kind] = &[
    Kind { media_type: "image/jpeg", extension: "jpg", extensions: &["jpg", "jpeg"], label: "JPEG photo", sniff: Sniff::Jpeg },
    Kind { media_type: "image/png", extension: "png", extensions: &["png"], label: "PNG image", sniff: Sniff::Png },
    Kind { media_type: "image/heic", extension: "heic", extensions: &["heic", "heif"], label: "HEIC photo", sniff: Sniff::Heif },
    Kind { media_type: "image/heif", extension: "heif", extensions: &["heif", "heic"], label: "HEIF photo", sniff: Sniff::Heif },
    Kind { media_type: "image/gif", extension: "gif", extensions: &["gif"], label: "GIF image", sniff: Sniff::Gif },
    Kind { media_type: "image/webp", extension: "webp", extensions: &["webp"], label: "WebP image", sniff: Sniff::Webp },
    Kind { media_type: "application/pdf", extension: "pdf", extensions: &["pdf"], label: "PDF", sniff: Sniff::Pdf },
    Kind { media_type: "text/plain", extension: "txt", extensions: &["txt", "text", "log"], label: "text file", sniff: Sniff::Text },
    Kind { media_type: "text/markdown", extension: "md", extensions: &["md", "markdown"], label: "Markdown file", sniff: Sniff::Text },
    Kind { media_type: "text/csv", extension: "csv", extensions: &["csv"], label: "CSV file", sniff: Sniff::Text },
    Kind { media_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document", extension: "docx", extensions: &["docx"], label: "Word document", sniff: Sniff::Zip },
    Kind { media_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", extension: "xlsx", extensions: &["xlsx"], label: "Excel workbook", sniff: Sniff::Zip },
    Kind { media_type: "application/vnd.openxmlformats-officedocument.presentationml.presentation", extension: "pptx", extensions: &["pptx"], label: "PowerPoint presentation", sniff: Sniff::Zip },
];

/// The accepted kind for a `Content-Type` header, ignoring parameters (`; charset=utf-8`) and case.
pub fn kind_of(content_type: &str) -> Option<&'static Kind> {
    let bare = content_type.split(';').next().unwrap_or("").trim().to_ascii_lowercase();
    ACCEPTED.iter().find(|k| k.media_type == bare)
}

/// Do these bytes look like the declared kind? Signature checks for binary formats; UTF-8 with
/// no NUL for text. The Office formats are checked only as ZIP containers — deeper inspection is
/// parsing, which v1 does not do.
fn content_matches(kind: &Kind, bytes: &[u8]) -> bool {
    match kind.sniff {
        Sniff::Jpeg => bytes.starts_with(&[0xFF, 0xD8, 0xFF]),
        Sniff::Png => bytes.starts_with(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]),
        Sniff::Gif => bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a"),
        Sniff::Webp => bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP",
        // ISO base media file: a `ftyp` box whose major brand is one of the HEIF family.
        Sniff::Heif => {
            bytes.len() >= 12
                && &bytes[4..8] == b"ftyp"
                && [b"heic", b"heix", b"hevc", b"hevx", b"heim", b"heis", b"mif1", b"msf1", b"heif"]
                    .iter()
                    .any(|brand| &bytes[8..12] == *brand)
        }
        Sniff::Pdf => bytes.starts_with(b"%PDF-"),
        Sniff::Text => !bytes.contains(&0) && std::str::from_utf8(bytes).is_ok(),
        Sniff::Zip => bytes.starts_with(b"PK\x03\x04"),
    }
}

/// Characters that reorder how a name is displayed, which a name must never carry: a file
/// called `invoice<U+202E>fdp.exe` displays as `invoiceexe.pdf` in a listing.
fn is_bidi_control(c: char) -> bool {
    matches!(c, '\u{200E}' | '\u{200F}' | '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}')
}

/// Truncate to at most `max` bytes on a character boundary.
fn truncate_bytes(s: &str, max: usize) -> &str {
    if s.len() <= max {
        return s;
    }
    let mut end = max;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    &s[..end]
}

/// **THE NAME THE FILE IS STORED UNDER.** The client's name, kept recognizable, with everything
/// that could make it a path, a hidden file, a display trick or a type it is not removed:
///
/// - only the last path component survives (`/`, `\` and `:` are separators somewhere);
/// - control and direction-override characters are dropped;
/// - leading dots and surrounding whitespace go, so no name is hidden or `..`;
/// - the extension must be one this kind owns, otherwise the kind's own is appended —
///   `run.sh` declared as `text/plain` is stored as `run.sh.txt`;
/// - the stem is capped at 100 bytes; an empty stem becomes `attachment`.
pub fn sanitize_name(raw: &str, kind: &Kind) -> String {
    let last = raw.rsplit(['/', '\\', ':']).next().unwrap_or("");
    let cleaned: String = last.chars().filter(|c| !c.is_control() && !is_bidi_control(*c)).collect();
    let cleaned = cleaned.trim().trim_start_matches('.').trim();
    let (stem, extension) = match cleaned.rsplit_once('.') {
        Some((stem, ext)) if kind.extensions.contains(&ext.to_ascii_lowercase().as_str()) => {
            (stem.to_string(), ext.to_ascii_lowercase())
        }
        _ => (cleaned.to_string(), kind.extension.to_string()),
    };
    let stem = truncate_bytes(stem.trim().trim_end_matches('.').trim(), 100).trim().to_string();
    let stem = if stem.is_empty() { "attachment".to_string() } else { stem };
    format!("{stem}.{extension}")
}

/// An attachment id: 1–128 characters of `[A-Za-z0-9_-]` (a UUID fits). Strict because it
/// names a file on disk.
pub fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 128 && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// A directory name for an identifier that did not come from this Mac. Kept as-is when it is
/// plainly safe (`thr_…`, a UUID); otherwise replaced by `x.<hash>`, which can never collide
/// with a kept one because kept ones contain no `.`.
pub fn segment(id: &str) -> String {
    if !id.is_empty() && id.len() <= 64 && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-') {
        id.to_string()
    } else {
        format!("x.{}", &hex(&sha256(id.as_bytes()))[..32])
    }
}

/// What the Mac holds for one uploaded, not-yet-committed file.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Staged {
    pub id: String,
    pub name: String,
    pub media_type: String,
    pub size: u64,
    pub sha256: String,
    pub at: u64,
}

/// One file after its message committed.
#[derive(Clone, Debug, PartialEq)]
pub struct Stored {
    pub id: String,
    pub name: String,
    pub media_type: String,
    pub size: u64,
    pub path: PathBuf,
}

/// The answer to one upload.
#[derive(Debug, PartialEq)]
pub enum Upload {
    Stored(Staged),
    /// The same bytes under the same id were already here. Nothing was rewritten.
    Duplicate(Staged),
    /// The same id already holds different bytes.
    Conflict,
    /// Not a file this Mac takes, or not what it says it is. The sentence is for the person.
    Refused(String),
    /// A limit on count or total size. The sentence is for the person.
    Limit(String),
}

/// The files the message names that this Mac does not hold (or holds with other bytes).
#[derive(Debug, PartialEq)]
pub struct Missing(pub Vec<String>);

/// The four ceilings, as one value so the tests can shrink them rather than write 200 MiB.
#[derive(Clone, Copy, Debug)]
struct Limits { file: usize, files: usize, message: u64, staged: u64, grace: u64 }
const LIMITS: Limits = Limits { file: MAX_FILE_BYTES, files: MAX_FILES_PER_MESSAGE, message: MAX_MESSAGE_BYTES, staged: MAX_STAGED_BYTES, grace: EVICTION_GRACE_MS };

pub struct AttachmentDesk {
    staging: PathBuf,
    store: PathBuf,
    limits: Limits,
    /// Serializes the check-then-rename sequences so two uploads of one id, or an upload racing
    /// a commit, cannot interleave. Held across a file write: at the upload sizes above that is
    /// milliseconds on an SSD, against seconds on the network.
    lock: Mutex<()>,
}

fn io(e: std::io::Error) -> PhoneError {
    PhoneError::Io(e.to_string())
}

fn write_private(path: &Path, bytes: &[u8]) -> Result<(), PhoneError> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let mut file = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(path).map_err(io)?;
    file.write_all(bytes).map_err(io)?;
    file.sync_all().map_err(io)
}

/// Write `bytes` to `path` so that `path` either holds all of them or is untouched.
fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), PhoneError> {
    let pending = path.with_extension(format!("partial-{}", hex(&random_bytes(6)?)));
    if let Err(e) = write_private(&pending, bytes).and_then(|_| std::fs::rename(&pending, path).map_err(io)) {
        let _ = std::fs::remove_file(&pending);
        return Err(e);
    }
    Ok(())
}

fn sync_dir(dir: &Path) -> Result<(), PhoneError> {
    std::fs::File::open(dir).and_then(|f| f.sync_all()).map_err(io)
}

fn create_private_dir(dir: &Path) -> Result<(), PhoneError> {
    use std::os::unix::fs::DirBuilderExt;
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir).map_err(io)
}

fn modified_ms(path: &Path) -> u64 {
    std::fs::metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

impl AttachmentDesk {
    /// No I/O: `DeviceDesk::open` is called for small checks all over the runtime, and nothing
    /// here needs to exist until the first upload.
    pub fn open(dir: &Path) -> Self {
        AttachmentDesk {
            staging: dir.join("phone").join("attachment-staging"),
            store: dir.join("attachments"),
            limits: LIMITS,
            lock: Mutex::new(()),
        }
    }

    #[cfg(test)]
    fn with_limits(dir: &Path, file: usize, files: usize, message: u64, staged: u64, grace: u64) -> Self {
        AttachmentDesk { limits: Limits { file, files, message, staged, grace }, ..Self::open(dir) }
    }

    fn message_dir(&self, device: &str, client: &str) -> PathBuf {
        self.staging.join(segment(device)).join(segment(client))
    }

    fn read_meta(path: &Path) -> Option<Staged> {
        let bytes = std::fs::read(path).ok()?;
        serde_json::from_slice(&bytes).ok()
    }

    /// Every complete staged file in one message's staging directory.
    fn staged_in(dir: &Path) -> Vec<Staged> {
        let Ok(entries) = std::fs::read_dir(dir) else { return Vec::new() };
        entries
            .filter_map(Result::ok)
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|x| x == "json"))
            .filter_map(|p| Self::read_meta(&p))
            .collect()
    }

    /// Remove staged messages past their seven days, then — if this upload would push the
    /// phone past [`MAX_STAGED_BYTES`] — the oldest other unsent messages until it fits.
    /// Returns whether it fits.
    ///
    /// **A message touched in the last [`EVICTION_GRACE_MS`] is never evicted.** Its commit may
    /// be running on another thread right now, between checking its files and moving them; a file
    /// removed in that gap would turn the commit into a receipt reserved and never answered, which
    /// the delivery desk (rightly) never retries. Refusing the NEW upload is the recoverable side.
    fn make_room(&self, device: &str, keep: &Path, incoming: u64) -> bool {
        let device_dir = self.staging.join(segment(device));
        let Ok(entries) = std::fs::read_dir(&device_dir) else { return incoming <= self.limits.staged };
        let now = now_millis();
        let mut messages: Vec<(u64, PathBuf, u64)> = Vec::new();
        for path in entries.filter_map(Result::ok).map(|e| e.path()) {
            let at = modified_ms(&path);
            if path != keep && now.saturating_sub(at) > STAGING_TTL_MS {
                let _ = std::fs::remove_dir_all(&path);
                continue;
            }
            let bytes = Self::staged_in(&path).iter().map(|s| s.size).sum();
            messages.push((at, path, bytes));
        }
        let mut total: u64 = messages.iter().map(|m| m.2).sum::<u64>() + incoming;
        messages.sort_by_key(|m| m.0);
        for (at, path, bytes) in messages {
            if total <= self.limits.staged {
                break;
            }
            if path == keep || now.saturating_sub(at) < self.limits.grace {
                continue;
            }
            if std::fs::remove_dir_all(&path).is_ok() {
                total = total.saturating_sub(bytes);
            }
        }
        total <= self.limits.staged
    }

    /// **Take one uploaded file.** Idempotent on `(device, client, id)` and the bytes.
    pub fn stage(
        &self,
        device: &str,
        client: &str,
        id: &str,
        name: Option<&str>,
        content_type: &str,
        bytes: &[u8],
    ) -> Result<Upload, PhoneError> {
        let Some(kind) = kind_of(content_type) else {
            return Ok(Upload::Refused(
                "RichOS can't take this kind of file yet. Photos, PDFs, text and Office documents work. The file is still on your phone.".into(),
            ));
        };
        if bytes.is_empty() {
            return Ok(Upload::Refused("This file is empty. Nothing was sent.".into()));
        }
        if bytes.len() > self.limits.file {
            return Ok(Upload::Limit("This file is larger than 25 MB, the most RichOS takes from a phone. It is still on your phone.".into()));
        }
        if !content_matches(kind, bytes) {
            return Ok(Upload::Refused(format!(
                "This file does not look like a {}. Nothing was sent; it is still on your phone.",
                kind.label
            )));
        }
        let sha = hex(&sha256(bytes));
        let _guard = self.lock.lock().unwrap();
        let dir = self.message_dir(device, client);
        let meta_path = dir.join(format!("{id}.json"));
        if let Some(existing) = Self::read_meta(&meta_path) {
            return Ok(if existing.sha256 == sha { Upload::Duplicate(existing) } else { Upload::Conflict });
        }
        let already = Self::staged_in(&dir);
        if already.len() >= self.limits.files {
            return Ok(Upload::Limit(format!("A message can carry at most {} files.", self.limits.files)));
        }
        if already.iter().map(|s| s.size).sum::<u64>() + bytes.len() as u64 > self.limits.message {
            return Ok(Upload::Limit("The files in this message add up to more than 100 MB, the most RichOS takes in one message.".into()));
        }
        if !self.make_room(device, &dir, bytes.len() as u64) {
            return Ok(Upload::Limit("Your Mac is holding too many unsent files from this phone. Send or remove some, then try again.".into()));
        }
        create_private_dir(&dir)?;
        let staged = Staged {
            id: id.to_string(),
            name: sanitize_name(name.unwrap_or(""), kind),
            media_type: kind.media_type.to_string(),
            size: bytes.len() as u64,
            sha256: sha,
            at: now_millis(),
        };
        // Bytes first, then the record that says they are complete. A crash between the two
        // leaves bytes with no record, which the next upload of the same id simply replaces.
        write_atomic(&dir.join(format!("{id}.bin")), bytes)?;
        write_atomic(&meta_path, &serde_json::to_vec(&staged).map_err(|e| PhoneError::Malformed(e.to_string()))?)?;
        sync_dir(&dir)?;
        Ok(Upload::Stored(staged))
    }

    /// **The files a message names, if every one is here with the bytes it names.** No side
    /// effects: this is the preparation step, so a refusal leaves nothing reserved.
    pub fn staged(&self, device: &str, client: &str, wanted: &[(String, String)]) -> Result<Vec<Staged>, Missing> {
        let _guard = self.lock.lock().unwrap();
        let dir = self.message_dir(device, client);
        let mut found = Vec::new();
        let mut missing = Vec::new();
        for (id, sha) in wanted {
            match Self::read_meta(&dir.join(format!("{id}.json"))) {
                Some(meta)
                    if meta.sha256 == *sha
                        && std::fs::metadata(dir.join(format!("{id}.bin"))).is_ok_and(|m| m.len() == meta.size) =>
                {
                    found.push(meta)
                }
                _ => missing.push(id.clone()),
            }
        }
        if missing.is_empty() { Ok(found) } else { Err(Missing(missing)) }
    }

    /// **Move a committed message's files into the conversation's folder**, under their
    /// sanitized names, in the order the message listed them. A name already used in that folder
    /// becomes `name (2).ext`, `name (3).ext`, … — compared case-insensitively, because the Mac's
    /// file system is.
    pub fn commit(&self, device: &str, client: &str, thread: &str, files: &[Staged]) -> Result<Vec<Stored>, PhoneError> {
        let _guard = self.lock.lock().unwrap();
        let from = self.message_dir(device, client);
        let to = self.store.join(segment(thread)).join(segment(client));
        create_private_dir(&to)?;
        let mut taken: Vec<String> = std::fs::read_dir(&to)
            .map_err(io)?
            .filter_map(Result::ok)
            .map(|e| e.file_name().to_string_lossy().to_lowercase())
            .collect();
        let mut stored = Vec::new();
        for file in files {
            let (stem, ext) = file.name.rsplit_once('.').unwrap_or((file.name.as_str(), ""));
            let mut name = file.name.clone();
            let mut n = 2;
            while taken.contains(&name.to_lowercase()) {
                name = format!("{stem} ({n}).{ext}");
                n += 1;
            }
            taken.push(name.to_lowercase());
            let path = to.join(&name);
            std::fs::rename(from.join(format!("{}.bin", file.id)), &path).map_err(io)?;
            stored.push(Stored { id: file.id.clone(), name, media_type: file.media_type.clone(), size: file.size, path });
        }
        sync_dir(&to)?;
        if let Err(e) = std::fs::remove_dir_all(&from) {
            eprintln!("[richos] a sent message's upload folder could not be removed; the sweep will retry: {e}");
        }
        Ok(stored)
    }

    /// Delete everything stored for one conversation. **No caller yet** — see the module doc:
    /// no delete-thread command exists, and this is the primitive it must call when one does.
    #[allow(dead_code)]
    pub fn delete_thread(&self, thread: &str) -> std::io::Result<()> {
        let _guard = self.lock.lock().unwrap();
        match std::fs::remove_dir_all(self.store.join(segment(thread))) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e),
            _ => Ok(()),
        }
    }
}

/// **WHAT RICH RECEIVES**: the CEO's text, then one line per file with its absolute path,
/// media type and size. Plain text on purpose — it is also what the conversation shows on the
/// Mac and on the phone, so it has to read as a sentence and not as a data structure.
///
/// ```text
/// Here is the contract.
///
/// Attached from the phone (2 files, saved on this Mac):
/// - /…/attachments/thr_1/c-1/contract.pdf (application/pdf, 812004 bytes)
/// - /…/attachments/thr_1/c-1/IMG_0001.jpg (image/jpeg, 2431112 bytes)
/// ```
pub fn describe(text: &str, stored: &[Stored]) -> String {
    let count = if stored.len() == 1 { "1 file".to_string() } else { format!("{} files", stored.len()) };
    let mut out = String::new();
    if !text.is_empty() {
        out.push_str(text);
        out.push_str("\n\n");
    }
    out.push_str(&format!("Attached from the phone ({count}, saved on this Mac):"));
    for file in stored {
        out.push_str(&format!("\n- {} ({}, {} bytes)", file.path.display(), file.media_type, file.size));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Scratch(PathBuf);
    impl Scratch {
        fn new() -> Self {
            let p = std::env::temp_dir().join(format!("phone-attachments-{}", hex(&random_bytes(8).unwrap())));
            std::fs::create_dir_all(&p).unwrap();
            Scratch(p)
        }
    }
    // Said, not asserted: a panic inside Drop while a failing test unwinds would abort the run.
    impl Drop for Scratch {
        fn drop(&mut self) {
            if let Err(e) = std::fs::remove_dir_all(&self.0) {
                eprintln!("test scratch {} was not removed: {e}", self.0.display());
            }
        }
    }

    const JPEG: &[u8] = &[0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, b'J', b'F', b'I', b'F', 0];
    const PDF: &[u8] = b"%PDF-1.7\n%\xE2\xE3\xCF\xD3\n1 0 obj\n";

    fn kind(media: &str) -> &'static Kind {
        kind_of(media).unwrap()
    }

    #[test]
    fn each_accepted_type_is_recognized_by_its_bytes_and_a_disguised_file_is_not() {
        let heic = [&[0, 0, 0, 0x18][..], b"ftypheic", &[0; 8]].concat();
        let webp = [&b"RIFF"[..], &[0; 4], b"WEBPVP8 "].concat();
        for (media, bytes) in [
            ("image/jpeg", JPEG.to_vec()),
            ("image/png", b"\x89PNG\r\n\x1a\n\0\0".to_vec()),
            ("image/heic", heic.clone()),
            ("image/heif", heic.clone()),
            ("image/gif", b"GIF89a..".to_vec()),
            ("image/webp", webp),
            ("application/pdf", PDF.to_vec()),
            ("text/plain; charset=utf-8", "Grüße, Rich".as_bytes().to_vec()),
            ("text/markdown", b"# Notes".to_vec()),
            ("text/csv", b"a,b\n1,2".to_vec()),
            ("application/vnd.openxmlformats-officedocument.wordprocessingml.document", b"PK\x03\x04rest".to_vec()),
            ("APPLICATION/PDF", PDF.to_vec()),
        ] {
            assert!(content_matches(kind(media), &bytes), "{media} was not recognized");
        }
        // A script declared as a photo, a PDF declared as text, binary declared as text.
        assert!(!content_matches(kind("image/jpeg"), b"#!/bin/sh\nrm -rf ~"));
        assert!(!content_matches(kind("application/pdf"), JPEG));
        assert!(!content_matches(kind("text/plain"), b"abc\0def"));
        assert!(!content_matches(kind("text/plain"), &[0xC3, 0x28]));
        for refused in ["application/msword", "application/zip", "application/x-sh", "audio/wav", "video/mp4", "", "image/svg+xml"] {
            assert!(kind_of(refused).is_none(), "{refused} should not be accepted in v1");
        }
    }

    #[test]
    fn names_keep_their_meaning_and_lose_every_way_out_of_their_folder() {
        let pdf = kind("application/pdf");
        let text = kind("text/plain");
        let jpeg = kind("image/jpeg");
        assert_eq!(sanitize_name("Q3 contract.pdf", pdf), "Q3 contract.pdf");
        assert_eq!(sanitize_name("Vertrag Müller.PDF", pdf), "Vertrag Müller.pdf");
        assert_eq!(sanitize_name("../../../etc/passwd", text), "passwd.txt");
        assert_eq!(sanitize_name("..\\..\\boot.ini", text), "boot.ini.txt");
        assert_eq!(sanitize_name("/Users/alex/.ssh/id_rsa", text), "id_rsa.txt");
        assert_eq!(sanitize_name(".hidden.pdf", pdf), "hidden.pdf");
        assert_eq!(sanitize_name("run.sh", text), "run.sh.txt");
        assert_eq!(sanitize_name("invoice\u{202E}fdp.exe", pdf), "invoicefdp.exe.pdf");
        assert_eq!(sanitize_name("line\nbreak\u{0}.pdf", pdf), "linebreak.pdf");
        assert_eq!(sanitize_name("", jpeg), "attachment.jpg");
        assert_eq!(sanitize_name("...", jpeg), "attachment.jpg");
        assert_eq!(sanitize_name("IMG_0001.jpeg", jpeg), "IMG_0001.jpeg");
        assert_eq!(sanitize_name("Mac HD:secret.pdf", pdf), "secret.pdf");
        let long = sanitize_name(&"é".repeat(300), pdf);
        assert!(long.len() <= 104 && long.ends_with(".pdf"), "{long}");
    }

    #[test]
    fn identifiers_become_safe_directory_names_without_collisions() {
        assert_eq!(segment("thr_5c1e"), "thr_5c1e");
        assert_eq!(segment("0f8e1c2a-9b1d-4c3e-8a7f-1234567890ab"), "0f8e1c2a-9b1d-4c3e-8a7f-1234567890ab");
        for hostile in ["..", "../x", "a/b", "", ".", "x.y", &"a".repeat(65)] {
            let s = segment(hostile);
            assert!(s.starts_with("x.") && s.len() == 34 && !s.contains('/'), "{hostile:?} -> {s}");
        }
        assert_ne!(segment("a/b"), segment("a/c"));
        assert!(valid_id("0f8e1c2a-9b1d_X") && !valid_id("") && !valid_id("a.b") && !valid_id("../a") && !valid_id(&"a".repeat(129)));
    }

    #[test]
    fn an_upload_is_idempotent_across_restarts_and_bound_to_its_bytes() {
        let dir = Scratch::new();
        let desk = AttachmentDesk::open(&dir.0);
        let first = desk.stage("dev_1", "msg-1", "a1", Some("photo.jpg"), "image/jpeg", JPEG).unwrap();
        let Upload::Stored(staged) = first else { panic!("{first:?}") };
        assert_eq!((staged.name.as_str(), staged.size, staged.media_type.as_str()), ("photo.jpg", JPEG.len() as u64, "image/jpeg"));
        drop(desk);
        // A retry after a lost answer and a Mac restart is recognized, not stored twice.
        let desk = AttachmentDesk::open(&dir.0);
        assert_eq!(desk.stage("dev_1", "msg-1", "a1", Some("photo.jpg"), "image/jpeg", JPEG).unwrap(), Upload::Duplicate(staged.clone()));
        let mut other = JPEG.to_vec();
        other.push(1);
        assert_eq!(desk.stage("dev_1", "msg-1", "a1", Some("photo.jpg"), "image/jpeg", &other).unwrap(), Upload::Conflict);
        // Staged files are private to this user.
        use std::os::unix::fs::PermissionsExt;
        let bin = desk.message_dir("dev_1", "msg-1").join("a1.bin");
        assert_eq!(std::fs::metadata(&bin).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(std::fs::read(&bin).unwrap(), JPEG);
    }

    #[test]
    fn limits_on_type_content_size_and_count_are_refusals_with_a_sentence() {
        let dir = Scratch::new();
        let desk = AttachmentDesk::open(&dir.0);
        assert!(matches!(desk.stage("d", "m", "a", None, "application/zip", b"PK\x03\x04").unwrap(), Upload::Refused(_)));
        assert!(matches!(desk.stage("d", "m", "a", None, "image/jpeg", b"not a photo").unwrap(), Upload::Refused(_)));
        assert!(matches!(desk.stage("d", "m", "a", None, "image/jpeg", b"").unwrap(), Upload::Refused(_)));
        let mut huge = JPEG.to_vec();
        huge.resize(MAX_FILE_BYTES + 1, 0);
        assert!(matches!(desk.stage("d", "m", "a", None, "image/jpeg", &huge).unwrap(), Upload::Limit(_)));
        for n in 0..MAX_FILES_PER_MESSAGE {
            assert!(matches!(desk.stage("d", "m", &format!("f{n}"), None, "image/jpeg", JPEG).unwrap(), Upload::Stored(_)));
        }
        let Upload::Limit(sentence) = desk.stage("d", "m", "one-more", None, "image/jpeg", JPEG).unwrap() else { panic!("an eleventh file was taken") };
        assert!(sentence.contains("10"), "{sentence}");
        // Nothing refused was written.
        assert_eq!(AttachmentDesk::staged_in(&desk.message_dir("d", "m")).len(), MAX_FILES_PER_MESSAGE);
    }

    #[test]
    fn a_message_total_over_its_ceiling_is_refused_at_the_file_that_crosses_it() {
        // Scaled down 1 MiB : 1 KiB so the test does not write 100 MiB; the arithmetic is the
        // production ratio (4 × 25 = 100).
        let dir = Scratch::new();
        let desk = AttachmentDesk::with_limits(&dir.0, 25 * 1024, 10, 100 * 1024, 200 * 1024, EVICTION_GRACE_MS);
        let mut big = JPEG.to_vec();
        big.resize(25 * 1024, 7);
        for n in 0..4 {
            // 4 × 25 KiB = 100 KiB exactly: allowed.
            assert!(matches!(desk.stage("d", "m", &format!("b{n}"), None, "image/jpeg", &big).unwrap(), Upload::Stored(_)), "{n}");
        }
        assert!(matches!(desk.stage("d", "m", "b4", None, "image/jpeg", JPEG).unwrap(), Upload::Limit(_)));
    }

    #[test]
    fn abandoned_uploads_are_evicted_oldest_first_rather_than_blocking_the_next_message() {
        let dir = Scratch::new();
        // Grace 0 here: "abandoned" is the case under test. The grace itself is the next test.
        let desk = AttachmentDesk::with_limits(&dir.0, 25 * 1024, 10, 100 * 1024, 200 * 1024, 0);
        let mut big = JPEG.to_vec();
        big.resize(25 * 1024, 7);
        // 8 unsent messages × 25 KiB = 200 KiB: exactly the (scaled) ceiling.
        for n in 0..8 {
            assert!(matches!(desk.stage("d", &format!("old{n}"), "a", None, "image/jpeg", &big).unwrap(), Upload::Stored(_)));
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        assert!(matches!(desk.stage("d", "new", "a", None, "image/jpeg", JPEG).unwrap(), Upload::Stored(_)));
        assert!(!desk.message_dir("d", "old0").exists(), "the oldest unsent message was not evicted");
        assert!(desk.message_dir("d", "old1").exists(), "more than needed was evicted");
        assert_eq!(desk.staged("d", "old0", &[("a".into(), hex(&sha256(&big)))]), Err(Missing(vec!["a".into()])));
    }

    #[test]
    fn a_message_touched_recently_is_never_evicted_and_the_new_upload_is_refused_instead() {
        let dir = Scratch::new();
        let desk = AttachmentDesk::with_limits(&dir.0, 25 * 1024, 10, 100 * 1024, 200 * 1024, EVICTION_GRACE_MS);
        let mut big = JPEG.to_vec();
        big.resize(25 * 1024, 7);
        for n in 0..8 {
            assert!(matches!(desk.stage("d", &format!("busy{n}"), "a", None, "image/jpeg", &big).unwrap(), Upload::Stored(_)));
        }
        assert!(matches!(desk.stage("d", "new", "a", None, "image/jpeg", JPEG).unwrap(), Upload::Limit(_)));
        for n in 0..8 {
            assert!(desk.message_dir("d", &format!("busy{n}")).exists(), "an in-progress message was evicted");
        }
    }

    #[test]
    fn a_commit_moves_files_into_the_conversation_under_unique_names_and_empties_staging() {
        let dir = Scratch::new();
        let desk = AttachmentDesk::open(&dir.0);
        for id in ["p1", "p2"] {
            desk.stage("dev_1", "msg-9", id, Some("IMG_0001.JPG"), "image/jpeg", JPEG).unwrap();
        }
        desk.stage("dev_1", "msg-9", "d1", Some("contract.pdf"), "application/pdf", PDF).unwrap();
        let sha_jpeg = hex(&sha256(JPEG));
        let wanted = vec![("p1".into(), sha_jpeg.clone()), ("p2".into(), sha_jpeg.clone()), ("d1".into(), hex(&sha256(PDF)))];
        // A wrong hash for one file is reported as that file missing, not as an error.
        let wrong = vec![("p1".into(), sha_jpeg.clone()), ("d1".into(), sha_jpeg.clone()), ("zz".into(), sha_jpeg.clone())];
        assert_eq!(desk.staged("dev_1", "msg-9", &wrong), Err(Missing(vec!["d1".into(), "zz".into()])));
        let files = desk.staged("dev_1", "msg-9", &wanted).unwrap();
        let stored = desk.commit("dev_1", "msg-9", "thr_5c1e", &files).unwrap();
        let names: Vec<&str> = stored.iter().map(|s| s.name.as_str()).collect();
        assert_eq!(names, ["IMG_0001.jpg", "IMG_0001 (2).jpg", "contract.pdf"]);
        for s in &stored {
            assert!(s.path.starts_with(dir.0.join("attachments").join("thr_5c1e").join("msg-9")), "{}", s.path.display());
            assert!(s.path.is_absolute());
        }
        assert_eq!(std::fs::read(&stored[2].path).unwrap(), PDF);
        assert!(!desk.message_dir("dev_1", "msg-9").exists(), "staging was not emptied");
        desk.delete_thread("thr_5c1e").unwrap();
        assert!(!stored[0].path.exists());
        desk.delete_thread("thr_never").unwrap();
    }

    #[test]
    fn what_rich_receives_names_every_file_by_absolute_path_type_and_size() {
        let stored = vec![
            Stored { id: "d1".into(), name: "contract.pdf".into(), media_type: "application/pdf".into(), size: 812004, path: "/data/attachments/thr_1/c-1/contract.pdf".into() },
            Stored { id: "p1".into(), name: "IMG_0001.jpg".into(), media_type: "image/jpeg".into(), size: 2431112, path: "/data/attachments/thr_1/c-1/IMG_0001.jpg".into() },
        ];
        assert_eq!(
            describe("Here is the contract.", &stored),
            "Here is the contract.\n\nAttached from the phone (2 files, saved on this Mac):\n\
             - /data/attachments/thr_1/c-1/contract.pdf (application/pdf, 812004 bytes)\n\
             - /data/attachments/thr_1/c-1/IMG_0001.jpg (image/jpeg, 2431112 bytes)"
        );
        assert_eq!(
            describe("", &stored[..1]),
            "Attached from the phone (1 file, saved on this Mac):\n- /data/attachments/thr_1/c-1/contract.pdf (application/pdf, 812004 bytes)"
        );
    }
}
