//! **THE PHONE APP ITSELF, COMPILED INTO THIS EXECUTABLE.**
//!
//! `app/phone/` is a static app with no dependencies: an HTML file, a stylesheet, eight
//! small modules, a service worker, a manifest and four icons. [`super::routes`] serves it
//! over the phone channel's TLS socket. Until 2026-09-18 it was served *from the source
//! tree*, by way of a path `env!("CARGO_MANIFEST_DIR")` baked in at compile time — which
//! worked on the machine that compiled it and nowhere else. The shipped bundle of that day
//! carried no phone file at all (`Contents/Resources` held `icon.icns` and nothing more),
//! so every route below `/` was a 404 on any Mac but the builder's, and the builder's path
//! went to the customer inside the binary.
//!
//! So the bytes are here now, in the program, put there by `build.rs`'s `embed_phone`,
//! which is also where the reasoning for embedding rather than bundling a directory is
//! written down. What this module adds is the one thing the table cannot say for itself:
//! **a lookup that is an exact match against a fixed set of keys.** There is no directory
//! to escape from, no symbolic link to follow, and nothing a request can name that this
//! build did not compile in.

/// The generated table: `(url path without its leading slash, bytes)`, sorted by path.
///
/// Written by `build.rs` into `$OUT_DIR/phone_app.rs` on every build, from the contents of
/// `app/phone/`. It is `include!`d rather than committed because it IS the directory — a
/// committed copy would be a second, drifting statement of what the phone app contains.
mod generated {
    include!(concat!(env!("OUT_DIR"), "/phone_app.rs"));
}

/// The phone app: a set of named files, and nothing that can reach outside it.
///
/// `Copy`, because it is two words — a pointer and a length — and every holder wants its
/// own. There is no state here and nothing to synchronize.
#[derive(Clone, Copy)]
pub struct PhoneApp {
    files: &'static [(&'static str, &'static [u8])],
}

impl PhoneApp {
    /// The app this build embedded.
    ///
    /// **Not an `Option`, and that is the point of the change this module landed with.**
    /// The old `phone_assets()` returned `None` on "a build with no phone assets", a state
    /// that was described as an ordinary developer build and turned out to be every
    /// shipped build. A build now either embeds the app or does not compile:
    /// `embed_phone` refuses a source tree with no `index.html`, an empty staged set, or a
    /// set that is missing anything `app/phone/sw.js` pre-caches.
    pub fn embedded() -> Self {
        Self { files: generated::FILES }
    }

    /// An app made from an explicit table — the constructor the route tests use, including
    /// the empty one that proves a channel with no app serves 404s rather than a
    /// placeholder.
    pub const fn from_files(files: &'static [(&'static str, &'static [u8])]) -> Self {
        Self { files }
    }

    /// The bytes and content type for a URL path with its leading slash already stripped,
    /// or `None`.
    ///
    /// **Exact match, no normalization.** `../private.txt`, `./app.js`, `lib//api.js` and
    /// `/etc/passwd` are all simply names this build never compiled in, so each one misses
    /// and the caller 404s it. The refusals the old filesystem version had to make by
    /// inspection — `..` components, empty segments, absolute paths, null bytes, and a
    /// canonicalized-root containment check to catch symbolic links — are not performed
    /// here because there is nothing for them to protect: this lookup cannot reach a file,
    /// only an entry.
    pub fn file(&self, relative: &str) -> Option<(&'static str, &'static [u8])> {
        let (name, bytes) = self.files.iter().find(|(name, _)| *name == relative)?;
        Some((content_type_for(name), bytes))
    }

    /// How many files this build embedded.
    pub fn len(&self) -> usize {
        self.files.len()
    }

    pub fn is_empty(&self) -> bool {
        self.files.is_empty()
    }

    /// Every embedded path, for tests and diagnostics.
    pub fn paths(&self) -> impl Iterator<Item = &'static str> + '_ {
        self.files.iter().map(|(name, _)| *name)
    }
}

/// The `Content-Type` for an embedded file, by extension.
///
/// Moved here from `routes.rs` with its behavior unchanged — it took a `&Path` when the
/// files were on disk and takes the table's key now. The final arm is deliberately
/// `application/octet-stream` and not `text/plain`: an unknown type served as text is a
/// type the browser may try to render.
pub fn content_type_for(name: &str) -> &'static str {
    match name.rsplit_once('.').map(|(_, ext)| ext).unwrap_or("") {
        "html" => "text/html; charset=utf-8",
        "js" => "text/javascript; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "json" => "application/json; charset=utf-8",
        "webmanifest" => "application/manifest+json",
        "png" => "image/png",
        "svg" => "image/svg+xml",
        "woff2" => "font/woff2",
        "wav" => "audio/wav",
        _ => "application/octet-stream",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn this_build_embedded_the_phone_app() {
        // The assertion that would have failed on every build shipped before 2026-09-18.
        let app = PhoneApp::embedded();
        assert!(!app.is_empty(), "this build embedded no phone app at all");
        for required in ["index.html", "app.js", "styles.css", "sw.js", "manifest.webmanifest"] {
            assert!(app.file(required).is_some(), "{required} is not in this build");
        }
        assert_eq!(app.file("index.html").unwrap().0, "text/html; charset=utf-8");
    }

    #[test]
    fn the_embedded_bytes_are_the_files_in_the_repository() {
        // `build.rs` copies `app/phone` into `$OUT_DIR` and the compiler includes it from
        // there, so "the same bytes" has one copy step in it. This is the assertion that
        // the step did what it says — read from the source tree, compared against what is
        // in the program. `CARGO_MANIFEST_DIR` is a test-only path here, exactly as
        // `ca.rs`'s word-list test uses it, and never reaches the shipped binary.
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../web/web-app");
        let app = PhoneApp::embedded();
        for name in ["index.html", "app.js", "sw.js", "lib/api.js", "icons/icon-192.png"] {
            let on_disk = std::fs::read(root.join(name))
                .unwrap_or_else(|e| panic!("could not read app/phone/{name}: {e}"));
            let (_, embedded) = app.file(name).unwrap_or_else(|| panic!("{name} is not embedded"));
            assert_eq!(
                embedded,
                on_disk.as_slice(),
                "app/phone/{name} is not what this build embedded"
            );
        }
    }

    #[test]
    fn the_workshop_is_not_in_the_product() {
        let app = PhoneApp::embedded();
        for name in ["package.json", "README.md", "CONTRACT-STUB.md", "bin/make-icons.js"] {
            assert!(app.file(name).is_none(), "{name} shipped");
        }
        for path in app.paths() {
            assert!(!path.starts_with("test/"), "{path} shipped");
            assert!(!path.contains("node_modules"), "{path} shipped");
        }
    }

    #[test]
    fn nothing_outside_the_table_can_be_named() {
        let app = PhoneApp::embedded();
        for probe in [
            "../private.txt",
            "../../etc/passwd",
            "./app.js",
            "/app.js",
            "lib//api.js",
            "",
            "app.js\0",
        ] {
            assert!(app.file(probe).is_none(), "{probe:?} resolved to something");
        }
        // And the one that must still work, so the probes above are not passing because
        // everything fails.
        assert!(app.file("app.js").is_some());
    }

    #[test]
    fn an_empty_app_is_representable_so_the_route_layer_can_be_tested_against_it() {
        let empty = PhoneApp::from_files(&[]);
        assert!(empty.is_empty());
        assert!(empty.file("index.html").is_none());
    }

    #[test]
    fn content_types_are_by_extension_and_an_unknown_one_is_never_text() {
        assert_eq!(content_type_for("index.html"), "text/html; charset=utf-8");
        assert_eq!(content_type_for("lib/api.js"), "text/javascript; charset=utf-8");
        assert_eq!(content_type_for("styles.css"), "text/css; charset=utf-8");
        assert_eq!(content_type_for("manifest.webmanifest"), "application/manifest+json");
        assert_eq!(content_type_for("icons/icon-192.png"), "image/png");
        assert_eq!(content_type_for("reply.wav"), "audio/wav");
        assert_eq!(content_type_for("LICENSE"), "application/octet-stream");
        assert_eq!(content_type_for("thing.unknown"), "application/octet-stream");
    }
}
