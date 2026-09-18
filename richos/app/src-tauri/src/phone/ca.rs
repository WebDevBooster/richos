//! **THE CERTIFICATE AUTHORITY THE APP MAKES ON HIS OWN MAC** — plan §2.1 and §2.2, slice A1.
//!
//! On first pairing the app generates a P-256 certificate authority named "RichOS on <his
//! Mac>", valid ten years, and issues itself a leaf for the Mac's own Bonjour name plus the
//! current LAN addresses, valid 397 days, renewed silently when the address changes.
//!
//! # Why a certificate authority and not a self-signed server certificate
//!
//! Apple's Technical Note TN2326, quoted in plan §2.2: *"You may be tempted to use a
//! self-signed certificate for TLS testing. This is less than ideal because your program must
//! then work in two different modes … Forgetting to disable the code that allows for
//! self-signed certificates is a serious security vulnerability."*
//!
//! And the bigger reason for this design specifically: **the root is what he installs and the
//! leaf is what expires.** With an authority, re-issuing the leaf when his IP changes, when it
//! ages out, or when he renames the Mac costs him nothing — the trust he granted once still
//! covers it. A self-signed leaf would send him back into Settings every time. *That single
//! property is the difference between one bad afternoon and a recurring chore.*
//!
//! # Apple's rules, which are the test rather than the intention
//!
//! `support.apple.com/en-us/103769`: the DNS name must be in the Subject Alternative Name
//! extension, `ExtendedKeyUsage` must contain `id-kp-serverAuth`, the signature must be
//! SHA-2, and keys must be RSA >= 2048 or ECC P-256/P-384. The 398-day validity ceiling does
//! **not** bind us — `support.apple.com/en-us/102028`: *"This change will not affect
//! certificates issued from user-added or administrator-added Root CAs"* — so the ten-year
//! root is legitimate, and the 397-day leaf is a choice taken because a short-lived leaf with
//! silent renewal is a better habit than a long one.
//!
//! [`tests`] asserts all four of those against the real generated certificate, read back out
//! of `openssl x509 -text`. They are not asserted about the commands; they are asserted about
//! the bytes the commands produced.
//!
//! # Why `/usr/bin/openssl` and not `rcgen`
//!
//! Plan §3.5 assumption 3, taken as written: certificate generation shells out to the binary
//! macOS already ships (**LibreSSL 3.3.6**, confirmed on this Mac), for **zero new
//! dependencies**. `rcgen` is the one crate the plan would have accepted instead, and it is
//! not needed: every command below was run by hand before it was written down, and the
//! resulting certificate verifies with `openssl verify -CAfile`.
//!
//! # The one place a private key touches a disk, and for how long
//!
//! `openssl` reads and writes keys as files; it has no interface that keeps a key in memory
//! across two invocations. So generation happens inside a scratch directory in the app's own
//! data directory, created `0700`, and **removed by [`Scratch`]'s `Drop`, on every path
//! including a panic**. The key is then in the Keychain and the scratch directory is gone.
//! That is a real, if brief, exposure and it is named here rather than left implicit — CEO
//! decision §54's rule is that a scratch location is cleaned up however its maker ends, and
//! `Drop` is how that is guaranteed rather than remembered.

use super::names::LocalNames;
use super::secrets::{SecretStore, CA_KEY, LEAF_KEY};
use super::{hex, sha256, unb64std, PhoneError};
use std::path::{Path, PathBuf};
use std::process::Command;

/// Ten years, in days. The root is what he installs; making him do it again is the thing this
/// whole design exists to avoid.
const CA_DAYS: &str = "3650";

/// 397 days. Under Apple's 398-day ceiling with a day to spare, even though that ceiling does
/// not bind a user-added root — a leaf that would be refused if the rule ever changed is a
/// leaf waiting to break on somebody else's schedule.
const LEAF_DAYS: &str = "397";

/// Re-issue the leaf when it has less than thirty days left. Long enough that renewal is
/// never urgent, short enough that a Mac left off for a month still comes back working.
const RENEW_WITHIN_SECONDS: &str = "2592000";

/// The certificate authority and the leaf it has issued for where this Mac currently is.
pub struct PhoneCa {
    /// The root certificate, DER. What the `.mobileconfig` carries and what the six-word
    /// fingerprint is computed over.
    pub ca_der: Vec<u8>,
    /// The leaf certificate, DER — what the TLS listener presents.
    pub leaf_der: Vec<u8>,
    /// The leaf's private key as PKCS#8 DER, for rustls. Held in memory for the life of the
    /// listener and nowhere else.
    pub leaf_key_pkcs8: Vec<u8>,
    /// The names this leaf was issued for.
    pub names: LocalNames,
}

impl PhoneCa {
    /// Load the authority, minting it on a first run, and issue or re-issue the leaf if the
    /// one on disk no longer covers where the Mac is.
    ///
    /// `dir` is the app's data directory. Certificates are public and live there as files;
    /// private keys never do (see [`super::secrets`]).
    pub fn open(
        dir: &Path,
        secrets: &dyn SecretStore,
        names: LocalNames,
    ) -> Result<Self, PhoneError> {
        let home = dir.join("phone");
        std::fs::create_dir_all(&home)?;
        let ca_cert_path = home.join("ca.crt");
        let leaf_cert_path = home.join("leaf.crt");

        // --- the authority -------------------------------------------------------------
        let ca_key_pem = match secrets.get(CA_KEY)? {
            Some(bytes) => String::from_utf8(bytes)
                .map_err(|_| PhoneError::Malformed("the stored authority key is not text".into()))?,
            None => {
                let scratch = Scratch::new(&home)?;
                let key = generate_p256_key(&scratch)?;
                secrets.put(CA_KEY, key.as_bytes())?;
                // A new authority invalidates any leaf that was issued by the old one.
                let _ = std::fs::remove_file(&leaf_cert_path);
                let _ = std::fs::remove_file(&ca_cert_path);
                key
            }
        };
        if !ca_cert_path.exists() {
            let scratch = Scratch::new(&home)?;
            let key_file = scratch.write("ca.key", ca_key_pem.as_bytes())?;
            let cert = self_signed_root(&scratch, &key_file, &names.display_name())?;
            std::fs::write(&ca_cert_path, cert.as_bytes())?;
        }
        let ca_pem = std::fs::read_to_string(&ca_cert_path)?;
        let ca_der = pem_body(&ca_pem, "CERTIFICATE")?;

        // --- the leaf ------------------------------------------------------------------
        let leaf_key_pem = match secrets.get(LEAF_KEY)? {
            Some(bytes) => String::from_utf8(bytes)
                .map_err(|_| PhoneError::Malformed("the stored leaf key is not text".into()))?,
            None => {
                let scratch = Scratch::new(&home)?;
                let key = generate_p256_key(&scratch)?;
                secrets.put(LEAF_KEY, key.as_bytes())?;
                let _ = std::fs::remove_file(&leaf_cert_path);
                key
            }
        };
        if needs_reissue(&leaf_cert_path, &names) {
            let scratch = Scratch::new(&home)?;
            let ca_key_file = scratch.write("ca.key", ca_key_pem.as_bytes())?;
            let ca_cert_file = scratch.write("ca.crt", ca_pem.as_bytes())?;
            let leaf_key_file = scratch.write("leaf.key", leaf_key_pem.as_bytes())?;
            let cert = issue_leaf(&scratch, &ca_cert_file, &ca_key_file, &leaf_key_file, &names)?;
            std::fs::write(&leaf_cert_path, cert.as_bytes())?;
        }
        let leaf_pem = std::fs::read_to_string(&leaf_cert_path)?;
        let leaf_der = pem_body(&leaf_pem, "CERTIFICATE")?;

        // rustls wants PKCS#8. `openssl ecparam -genkey` writes SEC1, so the conversion
        // happens once here rather than at every handshake.
        let leaf_key_pkcs8 = {
            let scratch = Scratch::new(&home)?;
            let sec1 = scratch.write("leaf.key", leaf_key_pem.as_bytes())?;
            let pkcs8 = openssl(&scratch, &["pkcs8", "-topk8", "-nocrypt", "-in", path_str(&sec1)?])?;
            pem_body(&pkcs8, "PRIVATE KEY")?
        };

        Ok(PhoneCa { ca_der, leaf_der, leaf_key_pkcs8, names })
    }

    /// The root's SHA-256, as the colon-separated uppercase hex Apple's own UI shows.
    pub fn fingerprint_hex(&self) -> String {
        let digest = sha256(&self.ca_der);
        hex(&digest)
            .as_bytes()
            .chunks(2)
            .map(|pair| String::from_utf8_lossy(pair).to_uppercase())
            .collect::<Vec<_>>()
            .join(":")
    }

    /// **The six words both screens show** (plan §4.1).
    ///
    /// Six bytes of the root's SHA-256, each indexing [`WORDS`]. That is 48 bits of the
    /// fingerprint compared by a person — ample for what it defends, which is not a
    /// brute-force search but somebody getting the CEO to nod at a different Mac inside a
    /// sixty-second window.
    pub fn fingerprint_words(&self) -> Vec<&'static str> {
        let digest = sha256(&self.ca_der);
        digest.iter().take(6).map(|b| WORDS[*b as usize]).collect()
    }

    /// The `.mobileconfig` the trust endpoint serves, and the only thing that endpoint ever
    /// serves.
    pub fn mobileconfig(&self) -> String {
        mobileconfig(&self.ca_der, &self.names, &self.fingerprint_hex(), &self.fingerprint_words())
    }

    /// Everything "Forget this phone" and uninstall destroy on the Mac side (plan §4.1).
    /// The profile on the phone is his to remove, and the settings screen tells him where.
    pub fn forget(dir: &Path, secrets: &dyn SecretStore) -> Result<(), PhoneError> {
        secrets.forget_all()?;
        let home = dir.join("phone");
        for name in ["ca.crt", "leaf.crt"] {
            let _ = std::fs::remove_file(home.join(name));
        }
        Ok(())
    }
}

// -------------------------------------------------------------------------------------
// The scratch directory — created 0700, removed on EVERY path
// -------------------------------------------------------------------------------------

/// A private working directory for the one place a key touches a disk.
///
/// CEO decision §54: *"there now needs to be a ROCK-SOLID … mechanism that always guarantees
/// that garbage like this will be always cleaned up afterwards."* `Drop` is that mechanism —
/// it runs on the success path, on every `?`, and on an unwind. A `remove_dir_all` at the end
/// of the happy path would not.
pub struct Scratch {
    path: PathBuf,
}

/// A process-wide counter, because a millisecond is not unique.
///
/// **This is not belt and braces; the first draft of this file was wrong without it.** The
/// name was `work-<pid>-<millis>`, and two scratch directories created in the same
/// millisecond by two threads are the same directory — so one `Drop` deletes the other's
/// working files, or worse, one reads the other's. It showed up as a test asserting Apple's
/// rules against a certificate a *different* test had just written, and the certificate it
/// was handed was perfectly valid, which is exactly why it took a while to see.
static SCRATCH_SEQUENCE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

impl Scratch {
    fn new(home: &Path) -> Result<Self, PhoneError> {
        let seq = SCRATCH_SEQUENCE.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let path = home.join(format!("work-{}-{}-{}", std::process::id(), super::now_millis(), seq));
        std::fs::create_dir_all(&path)?;
        set_private(&path)?;
        Ok(Scratch { path })
    }

    fn write(&self, name: &str, bytes: &[u8]) -> Result<PathBuf, PhoneError> {
        let p = self.path.join(name);
        std::fs::write(&p, bytes)?;
        set_private(&p)?;
        Ok(p)
    }

    fn join(&self, name: &str) -> PathBuf {
        self.path.join(name)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        // Best effort by necessity — there is nowhere to report a failure from a `Drop`.
        // What makes this safe rather than hopeful is that the only thing in here is a key
        // that is already in the Keychain by the time this runs, and the directory name
        // carries the pid so a leftover is identifiable rather than anonymous.
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

#[cfg(unix)]
fn set_private(path: &Path) -> Result<(), PhoneError> {
    use std::os::unix::fs::PermissionsExt as _;
    let meta = std::fs::metadata(path)?;
    let mode = if meta.is_dir() { 0o700 } else { 0o600 };
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode))?;
    Ok(())
}

#[cfg(not(unix))]
fn set_private(_path: &Path) -> Result<(), PhoneError> {
    Ok(())
}

// -------------------------------------------------------------------------------------
// openssl
// -------------------------------------------------------------------------------------

fn path_str(p: &Path) -> Result<&str, PhoneError> {
    p.to_str().ok_or_else(|| PhoneError::Malformed("a path is not valid UTF-8".into()))
}

/// Run `/usr/bin/openssl` with the scratch directory as its working directory, and return
/// stdout. A non-zero exit carries stderr, because "openssl failed" with no reason attached
/// is a support conversation that cannot start.
fn openssl(scratch: &Scratch, args: &[&str]) -> Result<String, PhoneError> {
    let out = Command::new("/usr/bin/openssl")
        .current_dir(&scratch.path)
        .args(args)
        .output()
        .map_err(|e| PhoneError::Tool { tool: "openssl".into(), detail: e.to_string() })?;
    if !out.status.success() {
        return Err(PhoneError::Tool {
            tool: "openssl".into(),
            detail: format!(
                "{} exited {}: {}",
                args.first().copied().unwrap_or("?"),
                out.status.code().unwrap_or(-1),
                String::from_utf8_lossy(&out.stderr).trim()
            ),
        });
    }
    Ok(String::from_utf8_lossy(&out.stdout).to_string())
}

fn generate_p256_key(scratch: &Scratch) -> Result<String, PhoneError> {
    // `-noout` suppresses the parameters block, so the output is the key and nothing else.
    openssl(scratch, &["ecparam", "-name", "prime256v1", "-genkey", "-noout"])
}

fn self_signed_root(scratch: &Scratch, key_file: &Path, display_name: &str) -> Result<String, PhoneError> {
    // `pathlen:0` means this root may sign leaves and may not sign another authority. It is
    // the narrowest thing that still works, and it is what the CEO's phone is being asked to
    // trust for ten years.
    openssl(
        scratch,
        &[
            "req",
            "-x509",
            "-new",
            "-key",
            path_str(key_file)?,
            "-sha256",
            "-days",
            CA_DAYS,
            "-subj",
            &format!("/CN={display_name}"),
            "-addext",
            "basicConstraints=critical,CA:TRUE,pathlen:0",
            "-addext",
            "keyUsage=critical,keyCertSign,cRLSign",
        ],
    )
}

fn issue_leaf(
    scratch: &Scratch,
    ca_cert: &Path,
    ca_key: &Path,
    leaf_key: &Path,
    names: &LocalNames,
) -> Result<String, PhoneError> {
    let csr = scratch.join("leaf.csr");
    openssl(
        scratch,
        &[
            "req",
            "-new",
            "-key",
            path_str(leaf_key)?,
            "-out",
            path_str(&csr)?,
            "-subj",
            &format!("/CN={}", names.bonjour),
        ],
    )?;

    // Exactly the four extensions Apple's rules ask for and nothing more. Every line here is
    // a claim the certificate makes, so an extension nobody needs is a claim nobody checked.
    let ext = format!(
        "subjectAltName={}\n\
         extendedKeyUsage=critical,serverAuth\n\
         keyUsage=critical,digitalSignature,keyEncipherment\n\
         basicConstraints=critical,CA:FALSE\n",
        names.san_list().join(",")
    );
    let ext_file = scratch.write("leaf.ext", ext.as_bytes())?;

    // A random serial rather than `-CAcreateserial`, which would leave a `.srl` file beside
    // the certificate and make two re-issues in the same second collide.
    let serial = format!("0x00{}", hex(&super::random_bytes(16)?));

    openssl(
        scratch,
        &[
            "x509",
            "-req",
            "-in",
            path_str(&csr)?,
            "-CA",
            path_str(ca_cert)?,
            "-CAkey",
            path_str(ca_key)?,
            "-set_serial",
            &serial,
            "-days",
            LEAF_DAYS,
            "-sha256",
            "-extfile",
            path_str(&ext_file)?,
        ],
    )
}

/// Does the leaf on disk still cover where this Mac is, and is it still in date?
///
/// **It reads the certificate, not a note about the certificate.** An earlier draft cached
/// the names it had issued for in a sidecar file, which is a second claim that can drift
/// from the artifact. `openssl x509 -text` is the artifact.
fn needs_reissue(leaf_cert_path: &Path, names: &LocalNames) -> bool {
    if !leaf_cert_path.exists() {
        return true;
    }
    let Ok(path) = leaf_cert_path.to_str().ok_or(()) else { return true };

    // In date for at least another thirty days? `-checkend` exits non-zero when it is not.
    let checkend = Command::new("/usr/bin/openssl")
        .args(["x509", "-in", path, "-noout", "-checkend", RENEW_WITHIN_SECONDS])
        .output();
    match checkend {
        Ok(out) if out.status.success() => {}
        _ => return true,
    }

    let text = Command::new("/usr/bin/openssl").args(["x509", "-in", path, "-noout", "-text"]).output();
    let Ok(out) = text else { return true };
    if !out.status.success() {
        return true;
    }
    let rendered = String::from_utf8_lossy(&out.stdout);
    !san_line_covers(&rendered, names)
}

/// True when the certificate's `X509v3 Subject Alternative Name` line names exactly the
/// places this Mac currently answers on — no more and no fewer.
///
/// Exposed for the tests, which assert it against real `openssl x509 -text` output rather
/// than against a string somebody typed.
pub fn san_line_covers(x509_text: &str, names: &LocalNames) -> bool {
    let Some(line) = san_line(x509_text) else { return false };
    let mut have: Vec<String> = line
        .split(',')
        .map(|p| p.trim().replace("IP Address:", "IP:").replace("DNS:", "DNS:"))
        .collect();
    let mut want: Vec<String> = names.san_list();
    have.sort();
    want.sort();
    have == want
}

fn san_line(x509_text: &str) -> Option<&str> {
    let mut lines = x509_text.lines();
    while let Some(line) = lines.next() {
        if line.trim().starts_with("X509v3 Subject Alternative Name") {
            return lines.next().map(|l| l.trim());
        }
    }
    None
}

/// The bytes inside one PEM block, without a PEM-parsing crate.
///
/// Deliberately strict: it takes the FIRST block with the given label and refuses a file
/// with no such block. A silent fall-through to "no bytes" here would present an empty
/// certificate chain and fail at the handshake, a long way from the cause.
pub fn pem_body(text: &str, label: &str) -> Result<Vec<u8>, PhoneError> {
    let begin = format!("-----BEGIN {label}-----");
    let end = format!("-----END {label}-----");
    let start = text
        .find(&begin)
        .ok_or_else(|| PhoneError::Malformed(format!("no {label} block")))?
        + begin.len();
    let rest = &text[start..];
    let stop = rest.find(&end).ok_or_else(|| PhoneError::Malformed(format!("unterminated {label} block")))?;
    let body: String = rest[..stop].chars().filter(|c| !c.is_whitespace()).collect();
    unb64std(&body)
}

// -------------------------------------------------------------------------------------
// The configuration profile
// -------------------------------------------------------------------------------------

/// A UUID derived from the certificate rather than drawn at random, so installing the same
/// authority twice REPLACES the profile in place instead of stacking a second copy he then
/// has to tell apart. Version nibble 5 and the RFC 4122 variant bits, so it is a well-formed
/// name-based UUID and not something that merely looks like one. (The shape is the phone
/// probe's `lib/mobileconfig.js`, reused deliberately: it is working reference code that was
/// installed on his own iPhone today.)
fn derived_uuid(namespace: &str, bytes: &[u8]) -> String {
    let mut ctx = ring::digest::Context::new(&ring::digest::SHA256);
    ctx.update(namespace.as_bytes());
    ctx.update(bytes);
    let digest = ctx.finish();
    let mut b = [0u8; 16];
    b.copy_from_slice(&digest.as_ref()[..16]);
    b[6] = (b[6] & 0x0f) | 0x50;
    b[8] = (b[8] & 0x3f) | 0x80;
    let h = hex(&b).to_uppercase();
    format!("{}-{}-{}-{}-{}", &h[0..8], &h[8..12], &h[12..16], &h[16..20], &h[20..])
}

fn escape_xml(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

/// Apple's plist `<data>` is base64. The wrapping is cosmetic; the line length is not,
/// because a single 1.2 KB line in a file a person may open in a text editor is a file
/// nobody reads.
fn data_block(bytes: &[u8], indent: &str) -> String {
    let b64 = super::b64std(bytes);
    b64.as_bytes()
        .chunks(60)
        .map(|c| format!("{indent}{}", String::from_utf8_lossy(c)))
        .collect::<Vec<_>>()
        .join("\n")
}

/// Build the profile. Separated from [`PhoneCa`] so the tests can render one from a fixed
/// certificate and assert on the bytes.
pub fn mobileconfig(
    ca_der: &[u8],
    names: &LocalNames,
    fingerprint_hex: &str,
    fingerprint_words: &[&str],
) -> String {
    let display = names.display_name();
    let profile_uuid = derived_uuid("richos.phone-channel.profile", ca_der);
    let cert_uuid = derived_uuid("richos.phone-channel.certificate", ca_der);
    let words = fingerprint_words.join(" ");
    // Written as plain text rather than assembled with a plist library, for the same reason
    // the rest of this has no new dependency, and because a profile is a file a person may
    // want to read before installing it.
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>PayloadContent</key>
	<array>
		<dict>
			<key>PayloadType</key>
			<string>com.apple.security.root</string>
			<key>PayloadVersion</key>
			<integer>1</integer>
			<key>PayloadIdentifier</key>
			<string>com.richos.app.phone-channel.ca</string>
			<key>PayloadUUID</key>
			<string>{cert_uuid}</string>
			<key>PayloadDisplayName</key>
			<string>{display_escaped}</string>
			<key>PayloadDescription</key>
			<string>The certificate that lets this phone open Rich on your own Mac over a private connection. It is valid only for {host} and for nothing on the internet.</string>
			<key>PayloadCertificateFileName</key>
			<string>richos-local-ca.crt</string>
			<key>PayloadContent</key>
			<data>
{cert_data}
			</data>
		</dict>
	</array>
	<key>PayloadType</key>
	<string>Configuration</string>
	<key>PayloadVersion</key>
	<integer>1</integer>
	<key>PayloadIdentifier</key>
	<string>com.richos.app.phone-channel</string>
	<key>PayloadUUID</key>
	<string>{profile_uuid}</string>
	<key>PayloadOrganization</key>
	<string>RichOS</string>
	<key>PayloadDisplayName</key>
	<string>{display_escaped}</string>
	<key>PayloadDescription</key>
	<string>Not signed, which is why your phone shows this in red: signing it would need a certificate from a company Apple already trusts, and the point of this one is that no such company is involved. Your own Mac made it a moment ago and it has never left your home network. The six words are {words}, and your Mac is showing you the same six. SHA-256: {fingerprint_hex}. After you install this, switch it on under Settings, General, About, Certificate Trust Settings. Delete this profile to undo all of it.</string>
	<key>PayloadRemovalDisallowed</key>
	<false/>
</dict>
</plist>
"#,
        display_escaped = escape_xml(&display),
        host = escape_xml(&names.bonjour),
        cert_data = data_block(ca_der, "\t\t\t"),
        words = escape_xml(&words),
    )
}

// -------------------------------------------------------------------------------------
// The word list
// -------------------------------------------------------------------------------------

/// **256 words, one per byte — and it is NOT this file's list.** It is
/// `richos/app/phone/lib/wordlist.js`, copied in order, because the whole point of the six
/// words is that the Mac's screen and the phone's screen show **the same six**, and two lists
/// that merely look similar is the one way this feature can be wrong in a way nobody notices.
///
/// The phone landed first (`dfa7ed27`), so the phone's list is the one. It also carries a
/// stronger property than an earlier draft of this file did: its own test computes the edit
/// distance between all 32,640 pairs and fails under two, so *"did you say cobalt or cobra?"*
/// cannot happen. That test lives with the list, on the phone side, and is not duplicated here.
///
/// What IS tested here is the only thing a second copy can usefully assert:
/// [`tests::the_word_list_is_the_phones_word_list_in_the_same_order`] reads
/// `app/phone/lib/wordlist.js` off disk and compares it entry by entry. A drift on either side
/// fails the Mac's own test suite.
///
/// **And the derivation runs on the PHONE, from the hex the Mac sends.** `lib/fingerprint.js`
/// is explicit about why: *"if the Mac sent pretty words, a Mac that wanted to could send words
/// that do not belong to the certificate it is actually serving."* So the Mac sends
/// `ca_fingerprint_sha256` and computes these words only for its OWN screen.
pub const WORDS: [&str; 256] = [
    "anchor", "apple", "april", "arrow", "artist", "aspen", "autumn", "avenue",
    "bacon", "badge", "basket", "beard", "beetle", "bench", "berry", "bishop",
    "blanket", "blossom", "bonus", "border", "bottle", "boulder", "branch", "bridge",
    "bronze", "brush", "bucket", "buffalo", "bundle", "butler", "cabin", "cactus",
    "camera", "candle", "canyon", "carbon", "cargo", "carpet", "castle", "cavern",
    "cedar", "cement", "census", "chapel", "cherry", "chimney", "circus", "clover",
    "cobalt", "cobra", "coffee", "collar", "column", "comet", "compass", "copper",
    "coral", "cotton", "cousin", "cowboy", "crayon", "cricket", "crystal", "cushion",
    "dagger", "dairy", "dancer", "decade", "denim", "desert", "diamond", "diesel",
    "dinner", "doctor", "dolphin", "domain", "donkey", "dragon", "drawer", "drummer",
    "eagle", "elbow", "elder", "ember", "engine", "estate", "expert", "fabric",
    "falcon", "farmer", "feather", "fiber", "fiddle", "figure", "filter", "finger",
    "flame", "flute", "forest", "fortune", "fossil", "freezer", "friend", "frozen",
    "gadget", "galaxy", "gallon", "garden", "garlic", "gazelle", "giant", "glacier",
    "glass", "glove", "granite", "grape", "gravel", "guitar", "gutter", "hammer",
    "harbor", "harvest", "helmet", "hermit", "hockey", "honey", "horizon", "hornet",
    "hotel", "hunter", "iceberg", "igloo", "indigo", "island", "ivory", "jacket",
    "jaguar", "jasmine", "jelly", "journal", "jungle", "junior", "kayak", "kernel",
    "kettle", "kitchen", "kitten", "koala", "ladder", "lagoon", "lantern", "laptop",
    "laser", "lawyer", "leader", "legend", "lemon", "leopard", "letter", "lettuce",
    "lily", "lizard", "lobster", "locker", "lotus", "lumber", "lunar", "magnet",
    "mammal", "mango", "manor", "maple", "marble", "margin", "marine", "market",
    "mason", "meadow", "medal", "melody", "mentor", "mermaid", "meteor", "mirror",
    "mixer", "model", "monarch", "monsoon", "moose", "morning", "mosaic", "motor",
    "muffin", "mural", "museum", "music", "mustang", "mustard", "napkin", "nectar",
    "needle", "neon", "nephew", "nickel", "noodle", "nugget", "nurse", "nutmeg",
    "oasis", "ocean", "octopus", "office", "olive", "onion", "orange", "orbit",
    "orchid", "organ", "otter", "outlaw", "oxygen", "oyster", "pajama", "palace",
    "pancake", "panda", "panther", "papaya", "parade", "parcel", "parlor", "parrot",
    "pasta", "pastry", "patio", "peanut", "pebble", "pelican", "pencil", "penguin",
    "pepper", "petal", "phantom", "pianist", "picnic", "pigeon", "pillow", "pilot",
    "pirate", "pistol", "planet", "plaza", "pocket", "poet", "polar", "pony",
];

#[cfg(test)]
mod tests {
    use super::*;
    use crate::phone::secrets::MemorySecrets;
    use std::net::{IpAddr, Ipv4Addr};

    fn test_names() -> LocalNames {
        LocalNames {
            host: "MM1".into(),
            bonjour: "mm1.local".into(),
            addresses: vec![IpAddr::V4(Ipv4Addr::new(192, 168, 1, 249))],
        }
    }

    /// A scratch data directory, removed by the test on every path including a panic — the
    /// same §54 rule the product code follows, applied to the test that exercises it.
    struct TempDir(PathBuf);
    impl TempDir {
        fn new(tag: &str) -> Self {
            // The counter, again, and for the reason `SCRATCH_SEQUENCE` names: `cargo test`
            // runs these in parallel threads of ONE process, so `<pid>-<millis>` collides.
            // Two `x509_text` calls in the same millisecond used to share a directory and
            // read each other's certificate.
            let seq = SCRATCH_SEQUENCE.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let p = std::env::temp_dir().join(format!(
                "richos-phone-ca-{tag}-{}-{}-{seq}",
                std::process::id(),
                super::super::now_millis()
            ));
            std::fs::create_dir_all(&p).unwrap();
            TempDir(p)
        }
    }
    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn x509_text(der: &[u8]) -> String {
        let dir = TempDir::new("read");
        let p = dir.0.join("c.der");
        std::fs::write(&p, der).unwrap();
        let out = Command::new("/usr/bin/openssl")
            .args(["x509", "-inform", "DER", "-in", p.to_str().unwrap(), "-noout", "-text"])
            .output()
            .unwrap();
        assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8_lossy(&out.stdout).to_string()
    }

    // --- Apple's four rules, asserted against the BYTES ------------------------------

    #[test]
    fn the_leaf_meets_every_rule_apple_publishes_for_a_tls_server_certificate() {
        let dir = TempDir::new("apple-rules");
        let secrets = MemorySecrets::default();
        let ca = PhoneCa::open(&dir.0, &secrets, test_names()).unwrap();
        let text = x509_text(&ca.leaf_der);

        // 1. the DNS name is in the Subject Alternative Name extension
        assert!(text.contains("X509v3 Subject Alternative Name"), "{text}");
        assert!(text.contains("DNS:mm1.local"), "{text}");
        assert!(text.contains("192.168.1.249"), "{text}");
        // 2. ExtendedKeyUsage contains id-kp-serverAuth
        assert!(text.contains("TLS Web Server Authentication"), "{text}");
        // 3. the signature is SHA-2
        assert!(text.contains("ecdsa-with-SHA256"), "{text}");
        // 4. the key is P-256
        assert!(text.contains("prime256v1") || text.contains("P-256"), "{text}");
        // and it is a leaf, not another authority
        assert!(text.contains("CA:FALSE"), "{text}");
    }

    #[test]
    fn the_root_is_a_certificate_authority_that_may_not_sign_another_one() {
        let dir = TempDir::new("root-shape");
        let secrets = MemorySecrets::default();
        let ca = PhoneCa::open(&dir.0, &secrets, test_names()).unwrap();
        let text = x509_text(&ca.ca_der);
        assert!(text.contains("CA:TRUE"), "{text}");
        assert!(text.contains("pathlen:0"), "the root can sign another authority: {text}");
        assert!(text.contains("Certificate Sign"), "{text}");
        assert!(text.contains("CN=RichOS on MM1") || text.contains("CN = RichOS on MM1"), "{text}");
    }

    #[test]
    fn the_leaf_verifies_against_the_root_that_issued_it() {
        // The end-to-end claim `openssl verify -CAfile ca.crt leaf.crt -> OK` makes, run
        // here against what the product code actually produced rather than against the
        // plan's transcript.
        let dir = TempDir::new("verify");
        let secrets = MemorySecrets::default();
        let ca = PhoneCa::open(&dir.0, &secrets, test_names()).unwrap();
        let out = Command::new("/usr/bin/openssl")
            .args([
                "verify",
                "-CAfile",
                dir.0.join("phone/ca.crt").to_str().unwrap(),
                dir.0.join("phone/leaf.crt").to_str().unwrap(),
            ])
            .output()
            .unwrap();
        assert!(out.status.success(), "{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
        assert!(!ca.leaf_key_pkcs8.is_empty());
    }

    // --- the authority survives, and the leaf is what moves --------------------------

    #[test]
    fn a_second_open_reuses_the_same_authority_rather_than_minting_a_second_one() {
        // The property the whole design rests on: the CEO installs the root ONCE. If a
        // relaunch minted a new authority, every launch would send him back into Settings.
        let dir = TempDir::new("stable-root");
        let secrets = MemorySecrets::default();
        let first = PhoneCa::open(&dir.0, &secrets, test_names()).unwrap();
        let second = PhoneCa::open(&dir.0, &secrets, test_names()).unwrap();
        assert_eq!(first.ca_der, second.ca_der, "the authority changed between launches");
        assert_eq!(first.fingerprint_words(), second.fingerprint_words());
        assert_eq!(first.leaf_der, second.leaf_der, "an unchanged network re-issued the leaf");
    }

    #[test]
    fn a_new_address_re_issues_the_leaf_and_leaves_the_authority_alone() {
        // Plan §2.1's "renewed silently when the address changes", and its positive control
        // is the test above: same names, same leaf; new names, new leaf, same root.
        let dir = TempDir::new("moved");
        let secrets = MemorySecrets::default();
        let before = PhoneCa::open(&dir.0, &secrets, test_names()).unwrap();

        let moved = LocalNames {
            addresses: vec![IpAddr::V4(Ipv4Addr::new(192, 168, 1, 77))],
            ..test_names()
        };
        let after = PhoneCa::open(&dir.0, &secrets, moved).unwrap();

        assert_eq!(before.ca_der, after.ca_der, "a new lease replaced the root he installed");
        assert_ne!(before.leaf_der, after.leaf_der, "the leaf did not follow the Mac");
        let text = x509_text(&after.leaf_der);
        assert!(text.contains("192.168.1.77"), "{text}");
        assert!(!text.contains("192.168.1.249"), "the old address is still claimed: {text}");
    }

    #[test]
    fn forgetting_the_phone_destroys_the_authority_completely() {
        // Plan §4.1: "instant and complete by construction, because there is nowhere else
        // the credential exists". The positive control is that a fresh open afterwards
        // produces a DIFFERENT root — proof the first one is gone rather than hidden.
        let dir = TempDir::new("forget");
        let secrets = MemorySecrets::default();
        let before = PhoneCa::open(&dir.0, &secrets, test_names()).unwrap();
        PhoneCa::forget(&dir.0, &secrets).unwrap();
        assert!(!dir.0.join("phone/ca.crt").exists());
        assert!(secrets.get(CA_KEY).unwrap().is_none());
        let after = PhoneCa::open(&dir.0, &secrets, test_names()).unwrap();
        assert_ne!(before.ca_der, after.ca_der, "the old authority came back");
    }

    #[test]
    fn no_scratch_directory_survives_the_work_that_needed_it() {
        // CEO §54, tested by defeat rather than asserted: after a full open plus a re-issue,
        // the only things left in the phone directory are the two public certificates.
        let dir = TempDir::new("no-garbage");
        let secrets = MemorySecrets::default();
        PhoneCa::open(&dir.0, &secrets, test_names()).unwrap();
        let moved = LocalNames { addresses: vec![IpAddr::V4(Ipv4Addr::new(10, 0, 0, 5))], ..test_names() };
        PhoneCa::open(&dir.0, &secrets, moved).unwrap();

        let mut left: Vec<String> = std::fs::read_dir(dir.0.join("phone"))
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().to_string())
            .collect();
        left.sort();
        assert_eq!(left, vec!["ca.crt".to_string(), "leaf.crt".to_string()], "scratch was left behind");
    }

    // --- the profile -----------------------------------------------------------------

    #[test]
    fn the_profile_carries_the_root_and_says_the_two_things_he_must_know_first() {
        let dir = TempDir::new("profile");
        let secrets = MemorySecrets::default();
        let ca = PhoneCa::open(&dir.0, &secrets, test_names()).unwrap();
        let profile = ca.mobileconfig();

        assert!(profile.starts_with("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"));
        assert!(profile.contains("<string>com.apple.security.root</string>"));
        assert!(profile.contains("RichOS on MM1"));
        // The red word, explained BEFORE he meets it — plan §2.1.
        assert!(profile.contains("Not signed"), "the profile does not explain the red word");
        // Apple's documented extra step, in the file itself as well as on the Mac's screen.
        assert!(profile.contains("Certificate Trust Settings"));
        // The fingerprint, both ways.
        assert!(profile.contains(&ca.fingerprint_hex()));
        for word in ca.fingerprint_words() {
            assert!(profile.contains(word), "the six words are not in the profile");
        }
        // The certificate really is in there: the base64 body decodes to the root's DER.
        let body: String = profile
            .split("<data>")
            .nth(1)
            .unwrap()
            .split("</data>")
            .next()
            .unwrap()
            .chars()
            .filter(|c| !c.is_whitespace())
            .collect();
        assert_eq!(unb64std(&body).unwrap(), ca.ca_der);
    }

    #[test]
    fn the_profile_identifier_is_derived_so_installing_twice_replaces_rather_than_stacks() {
        let a = derived_uuid("ns", b"the same certificate");
        let b = derived_uuid("ns", b"the same certificate");
        let c = derived_uuid("ns", b"a different certificate");
        assert_eq!(a, b);
        assert_ne!(a, c);
        assert_eq!(a.len(), 36);
        assert_eq!(&a[14..15], "5", "not a version-5 UUID: {a}");
        assert!(matches!(&a[19..20], "8" | "9" | "A" | "B"), "wrong variant bits: {a}");
    }

    // --- the word list ----------------------------------------------------------------

    #[test]
    fn the_word_list_is_exactly_one_word_per_byte_and_every_word_is_distinct() {
        assert_eq!(WORDS.len(), 256);
        let mut sorted = WORDS.to_vec();
        sorted.sort_unstable();
        let before = sorted.len();
        sorted.dedup();
        assert_eq!(sorted.len(), before, "the word list repeats a word");
    }

    #[test]
    fn every_word_survives_being_spoken() {
        // Three to seven ordinary lowercase letters, so there is nothing to spell out and
        // nothing that changes shape when a phone capitalizes it. The stronger property —
        // no two words within one edit of each other, over all 32,640 pairs — is tested on
        // the phone side where the list lives, and is not re-implemented here.
        for w in WORDS {
            assert!((3..=7).contains(&w.len()), "{w} is {} letters", w.len());
            assert!(w.chars().all(|c| c.is_ascii_lowercase()), "{w} is not plain lowercase letters");
        }
    }

    #[test]
    fn the_word_list_is_the_phones_word_list_in_the_same_order() {
        // **THE TEST THAT MAKES THE SIX WORDS MEAN ANYTHING.** The Mac's screen and the
        // phone's screen must show the same six words; two lists that merely look similar
        // would show different words for the same certificate, and the CEO would refuse a
        // pairing that was fine — or, far worse, get used to them not matching.
        //
        // So this does not test a property of the list. It reads the phone's own file and
        // compares. A word changed on either side fails here.
        let phone = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../phone/lib/wordlist.js");
        let source = std::fs::read_to_string(&phone)
            .unwrap_or_else(|e| panic!("could not read {}: {e}", phone.display()));
        // The list is the quoted words inside the `const WORDS = [ … ];` array. Taking every
        // single-quoted token after that marker is enough: nothing else in the file is quoted
        // that way, and the count assertion below catches it if that ever stops being true.
        let array = source
            .split_once("const WORDS = [")
            .unwrap_or_else(|| panic!("{} no longer declares `const WORDS = [`", phone.display()))
            .1
            .split_once("];")
            .expect("unterminated WORDS array")
            .0;
        let from_phone: Vec<&str> = array
            .split('\'')
            .skip(1)
            .step_by(2)
            .collect();
        assert_eq!(from_phone.len(), 256, "the phone's list is not 256 words any more");
        assert_eq!(
            from_phone,
            WORDS.to_vec(),
            "the Mac's word list and the phone's have drifted — the six words would not match"
        );
    }

    #[test]
    fn the_six_words_are_derived_from_the_root_and_not_from_anything_else() {
        let dir = TempDir::new("words");
        let secrets = MemorySecrets::default();
        let ca = PhoneCa::open(&dir.0, &secrets, test_names()).unwrap();
        let words = ca.fingerprint_words();
        assert_eq!(words.len(), 6);
        // Reproduce the derivation independently of the method under test.
        let digest = sha256(&ca.ca_der);
        let expected: Vec<&str> = digest.iter().take(6).map(|b| WORDS[*b as usize]).collect();
        assert_eq!(words, expected);
        // And it moves when the root moves.
        PhoneCa::forget(&dir.0, &secrets).unwrap();
        let other = PhoneCa::open(&dir.0, &secrets, test_names()).unwrap();
        assert_ne!(other.fingerprint_words(), words, "two different roots showed the same words");
    }

    // --- the small parts ---------------------------------------------------------------

    #[test]
    fn a_pem_block_with_no_matching_label_is_an_error_rather_than_empty_bytes() {
        let text = "-----BEGIN CERTIFICATE-----\nAQID\n-----END CERTIFICATE-----\n";
        assert_eq!(pem_body(text, "CERTIFICATE").unwrap(), vec![1, 2, 3]);
        assert!(pem_body(text, "PRIVATE KEY").is_err());
        assert!(pem_body("-----BEGIN CERTIFICATE-----\nAQID\n", "CERTIFICATE").is_err());
    }

    #[test]
    fn the_san_check_is_exact_in_both_directions() {
        let names = test_names();
        let exact = "        X509v3 Subject Alternative Name: \n            DNS:mm1.local, IP Address:192.168.1.249\n";
        assert!(san_line_covers(exact, &names));

        let missing = "        X509v3 Subject Alternative Name: \n            DNS:mm1.local\n";
        assert!(!san_line_covers(missing, &names), "a leaf missing an address was accepted");

        let extra = "        X509v3 Subject Alternative Name: \n            DNS:mm1.local, IP Address:192.168.1.249, IP Address:10.0.0.9\n";
        assert!(!san_line_covers(extra, &names), "a leaf claiming an address we do not serve was accepted");

        assert!(!san_line_covers("no extension here", &names));
    }
}
