//! Assemble the Mac's production credential code into this isolated test crate, UNCHANGED.
//!
//! The verifier the corpus is checked against is not a copy. `device.rs` (and every sibling
//! module it reaches: `delivery.rs`, and `attachments.rs` once it exists) are compiled straight
//! from `richos/app/src-tauri/src/phone/` through `#[path]`. What they reach in their PARENT
//! module (`phone/mod.rs`) — `PhoneError`, `hex`, `sha256`, `b64url`, `unb64url`,
//! `constant_time_eq`, constants — is cut out of `mod.rs` here, item by item, byte for byte.
//! Likewise `signed_path` and its query helpers from `routes.rs`, `percent_decode` from
//! `listen.rs`, and the two `Subscription` structs from `push.rs`.
//!
//! Exactly two parent items are NOT production code, on purpose: `now_millis` and
//! `random_bytes` (`src/lib.rs`). They are the test's clock and randomness, which is how the
//! test makes the real `DeviceDesk` issue the corpus's fixed challenges and then run its real
//! `verify` over the corpus's fixed signatures.
//!
//! If the Mac's source moves so that an item cannot be found, the build fails and names it.

use std::collections::BTreeSet;
use std::fmt::Write as _;
use std::path::PathBuf;

const DOUBLES: &[&str] = &["now_millis", "random_bytes"];

fn phone_dir() -> PathBuf {
    PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap())
        .join("../../../app/src-tauri/src/phone")
        .canonicalize()
        .expect("richos/app/src-tauri/src/phone must exist beside richos/mobile")
}

fn read(file: &str) -> String {
    let path = phone_dir().join(file);
    println!("cargo:rerun-if-changed={}", path.display());
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

/// The production part of a module: everything before its `#[cfg(test)] mod tests`. (Earlier
/// `#[cfg(test)]` items, such as a test-only `use`, stay; they are inert in this crate.)
fn production(src: &str) -> &str {
    for (i, m) in src.match_indices("\n#[cfg(test)]\n") {
        let next = &src[i + m.len()..];
        let line = next.lines().next().unwrap_or("").trim();
        if line.ends_with("mod tests {") {
            return &src[..i];
        }
    }
    src
}

/// The source with comment lines and trailing `//` comments removed, for scanning only.
fn code_only(src: &str) -> String {
    src.lines()
        .filter(|l| !l.trim_start().starts_with("//"))
        .map(|l| l.split(" // ").next().unwrap_or(l))
        .collect::<Vec<_>>()
        .join("\n")
}

fn ident(s: &str) -> &str {
    let end = s.find(|c: char| !(c.is_alphanumeric() || c == '_')).unwrap_or(s.len());
    &s[..end]
}

/// Every `super::…` a module reaches: (sibling modules, parent items).
fn reaches(src: &str) -> (BTreeSet<String>, BTreeSet<String>) {
    let code = code_only(production(src));
    let (mut modules, mut items) = (BTreeSet::new(), BTreeSet::new());
    for (i, _) in code.match_indices("super::") {
        let rest = &code[i + 7..];
        if let Some(list) = rest.strip_prefix('{') {
            for name in list[..list.find('}').unwrap()].split(',') {
                let name = name.trim();
                if !name.is_empty() {
                    items.insert(ident(name).to_string());
                }
            }
            continue;
        }
        let name = ident(rest);
        if name.is_empty() || name == "super" {
            continue;
        }
        if rest[name.len()..].starts_with("::") {
            modules.insert(name.to_string());
        } else {
            items.insert(name.to_string());
        }
    }
    (modules, items)
}

/// Cut one item out of `src`: the attribute lines directly above `header`, then either up to
/// the first `;` or through the matching close brace.
fn item(src: &str, file: &str, header: &str) -> String {
    let start = src
        .find(header)
        .unwrap_or_else(|| panic!("phone/{file}: `{header}` not found; the Mac's source moved, update verifier/build.rs"));
    let mut begin = src[..start].rfind('\n').map(|i| i + 1).unwrap_or(0);
    while begin > 0 {
        let prev = src[..begin - 1].rfind('\n').map(|i| i + 1).unwrap_or(0);
        if src[prev..begin - 1].trim_start().starts_with("#[") {
            begin = prev;
        } else {
            break;
        }
    }
    let rest = &src[start..];
    let (semi, brace) = (rest.find(';'), rest.find('{'));
    let end = match (semi, brace) {
        (Some(s), Some(b)) if s < b => start + s + 1,
        (Some(s), None) => start + s + 1,
        (_, Some(b)) => {
            let mut depth = 0usize;
            let mut end = None;
            for (i, c) in rest[b..].char_indices() {
                match c {
                    '{' => depth += 1,
                    '}' => {
                        depth -= 1;
                        if depth == 0 {
                            end = Some(start + b + i + 1);
                            break;
                        }
                    }
                    _ => {}
                }
            }
            end.unwrap_or_else(|| panic!("phone/{file}: `{header}` has no matching brace"))
        }
        _ => panic!("phone/{file}: `{header}` has no body"),
    };
    format!("{}\n", &src[begin..end])
}

/// A parent (`mod.rs`) item by name, in whichever form it is declared.
fn parent_item(mod_rs: &str, name: &str) -> String {
    let src = production(mod_rs);
    if name == "PhoneError" {
        let mut out = item(src, "mod.rs", "pub enum PhoneError {");
        for (i, _) in src.match_indices("\nimpl") {
            let line = &src[i + 1..i + 1 + src[i + 1..].find('\n').unwrap()];
            if line.ends_with("for PhoneError {") || line.ends_with("for PhoneError {}") || line == "impl PhoneError {" {
                out.push_str(&item(src, "mod.rs", line));
            }
        }
        return out;
    }
    for header in [format!("pub fn {name}("), format!("pub const {name}:"), format!("pub static {name}:")] {
        if src.contains(&header) {
            return item(src, "mod.rs", &header);
        }
    }
    panic!("phone/mod.rs: `{name}` is reached by an included module but is not a pub fn/const/enum this build knows how to cut out; update verifier/build.rs")
}

fn main() {
    let out = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    let mod_rs = read("mod.rs");
    let mut generated = String::from("// GENERATED by verifier/build.rs from richos/app/src-tauri/src/phone. Do not edit.\n");
    generated.push_str("#[allow(unused_imports)] use std::fmt;\n#[allow(unused_imports)] use base64::Engine as _;\n");

    // Walk the sibling modules device.rs reaches, transitively, and the parent items they use.
    let mut queue = vec!["device".to_string()];
    let (mut modules, mut items) = (BTreeSet::new(), BTreeSet::new());
    while let Some(m) = queue.pop() {
        if !modules.insert(m.clone()) {
            continue;
        }
        let (ms, is) = reaches(&read(&format!("{m}.rs")));
        items.extend(is);
        for sibling in ms {
            // `push` is reached only for the `Subscription` record type; the module itself is
            // the Web Push sender and has nothing to do with verifying a phone.
            if sibling != "push" && !modules.contains(&sibling) {
                queue.push(sibling);
            }
        }
    }
    items.insert("PhoneError".into());
    for name in &items {
        if DOUBLES.contains(&name.as_str()) || name == "push" {
            continue;
        }
        generated.push_str(&parent_item(&mod_rs, name));
    }
    for m in &modules {
        let _ = writeln!(generated, "#[path = {:?}]\npub mod {m};", phone_dir().join(format!("{m}.rs")).display().to_string());
    }

    let push = read("push.rs");
    let _ = write!(
        generated,
        "pub mod push {{\n{}{}}}\n",
        item(production(&push), "push.rs", "pub struct Subscription {"),
        item(production(&push), "push.rs", "pub struct SubscriptionKeys {")
    );

    let routes = read("routes.rs");
    let listen = read("listen.rs");
    let routes_src = production(&routes);

    // THE NATIVE-APP ADDITIONS (protocol_version 1: attachments, FCM registration, thread_id on
    // delta). Present in the tree -> compiled and proven (`cfg(mac_native_v1)`); absent -> the
    // test says by name that those corpus expectations were not proven here. Half present is a
    // build failure, so a rename cannot quietly switch the proof off.
    println!("cargo::rustc-check-cfg=cfg(mac_native_v1)");
    let native = routes_src.contains("pub const PROTOCOL_VERSION");
    let mut native_routes = String::new();
    if native {
        println!("cargo::rustc-cfg=mac_native_v1");
        assert!(
            modules.contains("attachments"),
            "routes.rs has PROTOCOL_VERSION but device.rs no longer reaches phone/attachments.rs; update verifier/build.rs"
        );
        for header in ["pub const CAPABILITIES", "pub const PROTOCOL_VERSION", "pub fn capabilities("] {
            native_routes.push_str(&item(routes_src, "routes.rs", header));
        }
        let notifications = read("notifications.rs");
        let n = production(&notifications);
        let _ = write!(generated, "pub mod notifications {{\nuse super::*;\nuse serde::{{Deserialize, Serialize}};\n");
        for header in ["pub const APNS_TOPICS", "pub const FCM_APPS", "pub struct Registration {", "fn preview_default(", "fn fcm_token(", "impl Registration {"] {
            generated.push_str(&item(n, "notifications.rs", header));
        }
        generated.push_str("}\n");
    }

    let _ = write!(
        generated,
        "pub mod listen {{\n{}}}\npub mod routes {{\n{}{}{}{}{}{}}}\n",
        item(production(&listen), "listen.rs", "pub fn percent_decode("),
        item(routes_src, "routes.rs", "const CREDENTIAL_PARAM"),
        item(routes_src, "routes.rs", "pub fn signed_path("),
        item(routes_src, "routes.rs", "fn query_value<"),
        item(routes_src, "routes.rs", "fn percent_decode_component("),
        native_routes,
        // NOT production code: the one expression both `events()` (for `auth`) and
        // `attachment_upload()` (for `client_id`, `attachment_id`, `name`) use to read a query
        // value, exposed because `query_value` and `percent_decode_component` are private there.
        "/// `query_value` then `percent_decode_component`, as `routes.rs` reads a query value.\n\
         pub fn query_param(query: &str, name: &str) -> Option<String> {\n    \
         query_value(query, name).and_then(|v| percent_decode_component(v).ok())\n}\n\
         /// The first two lines of `routes.rs` `events()`: the `auth` value, percent-decoded.\n\
         pub fn events_credential(query: &str) -> Option<String> {\n    query_param(query, \"auth\")\n}\n"
    );
    // Where the production code was read from. A test binary reused from a shared target
    // directory by another checkout would otherwise pass while proving another tree.
    let _ = writeln!(generated, "pub const PHONE_DIR: &str = {:?};", phone_dir().display().to_string());
    let _ = writeln!(generated, "pub const INCLUDED_MODULES: &[&str] = &{:?};", modules.iter().collect::<Vec<_>>());
    let _ = writeln!(generated, "pub const PARENT_ITEMS: &[&str] = &{:?};", items.iter().collect::<Vec<_>>());
    std::fs::write(out.join("phone.rs"), generated).unwrap();
}
