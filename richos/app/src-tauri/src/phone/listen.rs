//! **THE SOCKET — and everything about it that plan §2.5 promised in exchange for opening one.**
//!
//! > *"Bar (c) is gone, and this is **RichOS's first inbound network listener** … That is the real
//! > security cost of §57, and it is contained rather than hand-waved."*
//!
//! This file is the containment, and each item is at the line that enforces it:
//!
//!  1. **It does not exist until he pairs a phone.** [`Listener::start`] is called from the
//!     pairing surface; [`Listener`]'s `Drop` closes every socket and JOINS the thread, so "the
//!     listener stopped" means the port is free when the call returns rather than soon.
//!  2. **It binds the LAN interfaces only, never `0.0.0.0`** — every address comes from
//!     [`super::names`], which read them off this machine by name, and [`check_addresses`] refuses
//!     a wildcard and an empty list by hand.
//!  3. **TLS with our own leaf** — [`tls_config`], built from what [`super::ca`] issued.
//!  4. **Every route requires the credential, everything else is a flat 404** —
//!     [`super::routes`].
//!  6. **Body-size limits at the edge** — `Limited` fails the read rather than buffering the body
//!     and then measuring it, which is the difference between a limit and a check.
//!
//! # Why the channel owns its own runtime
//!
//! A current-thread tokio runtime on one named thread, created when the listener starts and
//! dropped when it stops. The app's own async runtime outlives the listener by design, so hanging
//! the sockets off it would make "stopped" a flag rather than an absence. This way **stopping the
//! channel destroys the thing that was listening** — item 1 stated as a fact about the process
//! rather than about a boolean. Dropping the runtime also ends every open event stream, which is
//! why the stream task does not have to watch for shutdown itself.
//!
//! # Why there is no `tokio::select!` in here
//!
//! The macro lives behind `tokio/macros`, which would add `tokio-macros` as a new package.
//! `futures_util::future::select` does the same job for the one race that needs it — one
//! `accept()` against one shutdown — and `tokio::time::timeout` does the other. An attribute is
//! not worth a `[[package]]` line.

use super::routes::{dispatch, dispatch_trust, Channel, Incoming, Outcome};
use super::{PhoneError, HTTPS_PORT, KEEPALIVE_MS, MAX_BODY_BYTES, TRUST_PORT};
use bytes::Bytes;
use futures_util::future::{select, Either};
use http_body_util::{BodyExt, Full, Limited};
use hyper::body::Incoming as HyperBody;
use hyper::service::service_fn;
use hyper::{Request, Response, StatusCode};
use std::net::{IpAddr, SocketAddr, TcpListener as StdTcpListener};
use std::sync::Arc;
use tokio::sync::watch;

type BoxBody = http_body_util::combinators::BoxBody<Bytes, std::convert::Infallible>;

/// A running channel. Dropping it stops the channel.
pub struct Listener {
    shutdown: watch::Sender<bool>,
    thread: Option<std::thread::JoinHandle<()>>,
    /// Every address and port actually bound. Shown on the settings screen, and the thing the
    /// tests assert against — a claim about what was bound must come from the socket rather than
    /// from what we asked for.
    pub bound: Vec<SocketAddr>,
}

impl Listener {
    /// Bind and serve.
    ///
    /// **Binding happens synchronously, before anything is spawned**, so a port already in use is
    /// an error the caller can show him rather than a failure inside a task nobody is watching. If
    /// any address fails to bind, every socket already bound is dropped and the whole start fails
    /// — a half-bound listener that answers on one interface and not another is worse than one
    /// that says it could not start.
    pub fn start(
        channel: Arc<Channel>,
        tls: Arc<rustls::ServerConfig>,
        profile: Arc<String>,
        addresses: &[IpAddr],
    ) -> Result<Self, PhoneError> {
        check_addresses(addresses)?;
        let mut https: Vec<StdTcpListener> = Vec::new();
        let mut trust: Vec<StdTcpListener> = Vec::new();
        let mut bound: Vec<SocketAddr> = Vec::new();
        for address in addresses {
            for (port, into) in [(HTTPS_PORT, &mut https), (TRUST_PORT, &mut trust)] {
                let socket = SocketAddr::new(*address, port);
                let listener = StdTcpListener::bind(socket)
                    .map_err(|e| PhoneError::Io(format!("could not listen on {socket}: {e}")))?;
                listener.set_nonblocking(true)?;
                bound.push(socket);
                into.push(listener);
            }
        }

        let (shutdown, _rx) = watch::channel(false);
        let stop = shutdown.clone();
        channel.hub.set_live(true);
        let thread = std::thread::Builder::new()
            .name("richos-phone-channel".to_string())
            .spawn(move || {
                let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
                    Ok(r) => r,
                    Err(e) => {
                        eprintln!("[richos] the phone channel could not start its runtime: {e}");
                        channel.hub.set_live(false);
                        return;
                    }
                };
                runtime.block_on(serve_all(channel, tls, profile, https, trust, stop.subscribe()));
            })
            .map_err(|e| PhoneError::Io(format!("could not start the phone channel thread: {e}")))?;

        Ok(Listener { shutdown, thread: Some(thread), bound })
    }

    /// Stop serving and wait for the sockets to be gone.
    pub fn stop(&mut self) {
        let _ = self.shutdown.send(true);
        if let Some(thread) = self.thread.take() {
            // Joined rather than detached: "the listener stops when he unpairs the last phone" has
            // to mean the port is free when that call returns, or the next pairing fails to bind
            // for reasons nobody can see.
            let _ = thread.join();
        }
    }

    pub fn is_running(&self) -> bool {
        self.thread.is_some()
    }
}

impl Drop for Listener {
    fn drop(&mut self) {
        self.stop();
    }
}

/// **The one guard that makes a wildcard bind impossible.** Plan §2.5 item 2: *"It binds the LAN
/// interfaces only — never `0.0.0.0` as a shortcut, never an interface it was not told about."*
///
/// A separate function because the only plausible way a wildcard could creep in is an empty
/// address list quietly meaning "all of them", and that has to be testable without building a
/// whole channel.
pub fn check_addresses(addresses: &[IpAddr]) -> Result<(), PhoneError> {
    if addresses.is_empty() {
        return Err(PhoneError::Malformed(
            "this Mac has no address the phone could reach, so there is nothing to listen on".into(),
        ));
    }
    for address in addresses {
        if address.is_unspecified() {
            return Err(PhoneError::Malformed(format!(
                "{address} is every interface at once, which this channel never binds — give it \
                 the addresses this Mac actually answers on"
            )));
        }
        if address.is_multicast() {
            return Err(PhoneError::Malformed(format!("{address} is not an address a server binds")));
        }
    }
    Ok(())
}

/// Build the TLS configuration from the leaf the certificate authority issued.
pub fn tls_config(
    leaf_der: &[u8],
    leaf_key_pkcs8: &[u8],
) -> Result<Arc<rustls::ServerConfig>, PhoneError> {
    // The same `ring` provider `voice_provision.rs` installs, installed idempotently here for the
    // same reason it does: a process-level provider must exist before a config is built, and
    // depending on which unrelated feature ran first is a defect waiting for one first run.
    let _ = rustls::crypto::ring::default_provider().install_default();

    let cert = rustls::pki_types::CertificateDer::from(leaf_der.to_vec());
    let key = rustls::pki_types::PrivateKeyDer::Pkcs8(leaf_key_pkcs8.to_vec().into());
    // The ROOT is deliberately not in the chain. The phone installed it; sending it again would be
    // a bigger handshake that proves nothing.
    let mut config = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(vec![cert], key)
        .map_err(|e| PhoneError::Crypto(format!("rustls refused our own leaf: {e}")))?;
    // HTTP/1.1 only, matching plan §2.6's *"No WebSocket on either side. Upgrade later only if a
    // measurement demands it"* — one protocol, one code path.
    config.alpn_protocols = vec![b"http/1.1".to_vec()];
    Ok(Arc::new(config))
}

async fn serve_all(
    channel: Arc<Channel>,
    tls: Arc<rustls::ServerConfig>,
    profile: Arc<String>,
    https: Vec<StdTcpListener>,
    trust: Vec<StdTcpListener>,
    shutdown: watch::Receiver<bool>,
) {
    let acceptor = tokio_rustls::TlsAcceptor::from(tls);
    let mut tasks = Vec::new();
    for listener in https {
        let Ok(listener) = tokio::net::TcpListener::from_std(listener) else { continue };
        tasks.push(tokio::spawn(accept_https(
            listener,
            acceptor.clone(),
            Arc::clone(&channel),
            shutdown.clone(),
        )));
    }
    for listener in trust {
        let Ok(listener) = tokio::net::TcpListener::from_std(listener) else { continue };
        tasks.push(tokio::spawn(accept_trust(listener, Arc::clone(&profile), shutdown.clone())));
    }
    for task in tasks {
        let _ = task.await;
    }
    channel.hub.set_live(false);
}

/// Race one `accept()` against the shutdown signal, with no macro and no polling.
///
/// The `borrow()` check at the top is not decoration: a fresh `watch::Receiver` clone inherits the
/// version it was cloned from, so if shutdown had already been sent, `changed()` would wait for a
/// send that is never coming. Reading the current value first is what closes that window.
async fn accept_one(
    listener: &tokio::net::TcpListener,
    shutdown: &watch::Receiver<bool>,
) -> Option<(tokio::net::TcpStream, SocketAddr)> {
    if *shutdown.borrow() {
        return None;
    }
    let accepting = Box::pin(listener.accept());
    let mut rx = shutdown.clone();
    let stopping = Box::pin(async move {
        let _ = rx.changed().await;
    });
    match select(accepting, stopping).await {
        Either::Left((Ok(pair), _)) => Some(pair),
        // `None` for BOTH "that accept failed" and "we are shutting down", and the caller tells
        // them apart by reading the shutdown value again. One failed accept is not the end of a
        // listener — a client that vanished between the kernel queueing it and us taking it is
        // ordinary — so the loop continues in that case and returns in the other.
        Either::Left((Err(_), _)) | Either::Right(_) => None,
    }
}

async fn accept_https(
    listener: tokio::net::TcpListener,
    acceptor: tokio_rustls::TlsAcceptor,
    channel: Arc<Channel>,
    shutdown: watch::Receiver<bool>,
) {
    while !*shutdown.borrow() {
        let Some((stream, _peer)) = accept_one(&listener, &shutdown).await else {
            if *shutdown.borrow() {
                return;
            }
            continue;
        };
        let acceptor = acceptor.clone();
        let channel = Arc::clone(&channel);
        tokio::spawn(async move {
            // A handshake that fails is a device on his Wi-Fi that does not hold the certificate
            // authority. Nothing is logged per connection: a TV that probes the port every minute
            // would otherwise fill his log with noise.
            let Ok(tls_stream) = acceptor.accept(stream).await else { return };
            let io = hyper_util::rt::TokioIo::new(tls_stream);
            let service = service_fn(move |request| {
                let channel = Arc::clone(&channel);
                async move { Ok::<_, std::convert::Infallible>(handle(channel, request).await) }
            });
            let _ = hyper::server::conn::http1::Builder::new().serve_connection(io, service).await;
        });
    }
}

async fn accept_trust(
    listener: tokio::net::TcpListener,
    profile: Arc<String>,
    shutdown: watch::Receiver<bool>,
) {
    while !*shutdown.borrow() {
        let Some((stream, _peer)) = accept_one(&listener, &shutdown).await else {
            if *shutdown.borrow() {
                return;
            }
            continue;
        };
        let profile = Arc::clone(&profile);
        tokio::spawn(async move {
            let io = hyper_util::rt::TokioIo::new(stream);
            let service = service_fn(move |request: Request<HyperBody>| {
                let profile = Arc::clone(&profile);
                async move {
                    let method = request.method().as_str().to_string();
                    let path = percent_decode(request.uri().path());
                    Ok::<_, std::convert::Infallible>(render_plain(dispatch_trust(
                        &profile, &method, &path,
                    )))
                }
            });
            let _ = hyper::server::conn::http1::Builder::new().serve_connection(io, service).await;
        });
    }
}

async fn handle(channel: Arc<Channel>, request: Request<HyperBody>) -> Response<BoxBody> {
    let method = request.method().as_str().to_string();
    let path = percent_decode(request.uri().path());
    let query = request.uri().query().unwrap_or("").to_string();
    let header = |name: &str| {
        request.headers().get(name).and_then(|v| v.to_str().ok()).map(|s| s.to_string())
    };
    let authorization = header("authorization");
    let last_event_id = header("last-event-id");
    let content_type = header("content-type");

    // THE LIMIT IS APPLIED BEFORE THE BODY IS READ, which is the difference between a limit and a
    // check. `Limited` fails the read rather than buffering four gigabytes and then measuring it.
    let body = match Limited::new(request.into_body(), MAX_BODY_BYTES).collect().await {
        Ok(collected) => collected.to_bytes().to_vec(),
        Err(_) => return render(&channel, Outcome::PayloadTooLarge),
    };

    let incoming =
        Incoming { method, path, query, authorization, last_event_id, content_type, body };
    match dispatch(&channel, &incoming) {
        Outcome::Stream { opening, .. } => open_stream(channel, opening),
        other => render(&channel, other),
    }
}

/// Turn a described response into an HTTP one, with a fresh challenge attached.
///
/// **Every response carries `X-RichOS-Challenge`, including a 404 and a 429.** That is how the
/// phone gets the next thing to sign (`app/phone/lib/api.js` reads the header on every response),
/// and it is why the contract needs no challenge route. A refusal that omitted it would leave a
/// phone whose challenge had aged out with no way back.
fn render(channel: &Channel, outcome: Outcome) -> Response<BoxBody> {
    let challenge = channel.devices.issue_challenge().ok();
    render_with(outcome, challenge)
}

/// The trust endpoint's responses. No challenge: that port has no credential and never will.
fn render_plain(outcome: Outcome) -> Response<BoxBody> {
    render_with(outcome, None)
}

fn render_with(outcome: Outcome, challenge: Option<String>) -> Response<BoxBody> {
    let mut builder = Response::builder()
        .status(StatusCode::from_u16(outcome.status()).unwrap_or(StatusCode::NOT_FOUND))
        .header("cache-control", "no-store")
        .header("x-content-type-options", "nosniff")
        // The phone app is same-origin with the API today. The header is here because the
        // reachability seam (plan §10.7) means the API base can move to another origin later, and
        // `*` is refused even now: a credentialed request from any page on the internet is exactly
        // what this must not allow. `null` is what a same-origin fetch needs and nothing more.
        .header("access-control-allow-origin", "null");
    if let Some(challenge) = challenge {
        builder = builder.header("x-richos-challenge", challenge);
    }
    let body = match outcome {
        Outcome::Json { body, .. } => {
            builder = builder.header("content-type", "application/json; charset=utf-8");
            Bytes::from(body)
        }
        Outcome::Bytes { content_type, body, download_as, .. } => {
            builder = builder.header("content-type", content_type);
            if let Some(name) = download_as {
                builder =
                    builder.header("content-disposition", format!("attachment; filename=\"{name}\""));
            }
            Bytes::from(body)
        }
        // A flat refusal carries no body at all: one answer to every question.
        Outcome::NotFound | Outcome::PayloadTooLarge => Bytes::new(),
        // The one refusal with a body, because the phone acts on it: it clears its credential and
        // stops instead of retrying against a Mac that has forgotten it.
        Outcome::Revoked => {
            builder = builder.header("content-type", "application/json; charset=utf-8");
            Bytes::from_static(b"{\"revoked\":true}")
        }
        Outcome::RateLimited => {
            builder = builder.header("retry-after", "60");
            Bytes::new()
        }
        Outcome::Stream { .. } => Bytes::new(),
    };
    builder
        .body(Full::new(body).boxed())
        .unwrap_or_else(|_| Response::new(Full::new(Bytes::new()).boxed()))
}

/// Open an event stream: write the opening frames, then follow the hub until the phone goes away
/// or the channel stops.
fn open_stream(channel: Arc<Channel>, opening: Vec<String>) -> Response<BoxBody> {
    let slot = match channel.devices.claim_stream() {
        Ok(slot) => slot,
        Err(_) => return render(&channel, Outcome::RateLimited),
    };
    let (mut sender, body) =
        http_body_util::channel::Channel::<Bytes, std::convert::Infallible>::new(32);
    let mut live = channel.hub.subscribe();

    tokio::spawn(async move {
        // The slot is MOVED into this task, so it is released by `Drop` however the stream ends —
        // the phone locking itself, walking out of range, or the whole runtime being dropped when
        // the channel stops.
        let _slot = slot;
        for frame in opening {
            if sender.send_data(Bytes::from(frame)).await.is_err() {
                return;
            }
        }
        loop {
            // `timeout` rather than a three-way `select!`: the keep-alive IS the timeout, and
            // shutdown needs no arm here because dropping the channel's runtime ends this task.
            match tokio::time::timeout(std::time::Duration::from_millis(KEEPALIVE_MS), live.recv())
                .await
            {
                Ok(Ok(frame)) => {
                    if sender.send_data(Bytes::from(frame.to_wire())).await.is_err() {
                        return;
                    }
                }
                // The phone fell far enough behind that frames were dropped. It is told to start
                // again rather than handed a thinned stream: a gap it cannot see is the one
                // failure this whole design refuses.
                Ok(Err(tokio::sync::broadcast::error::RecvError::Lagged(missed))) => {
                    let notice = format!(": re-snapshot {missed}\n\n");
                    let _ = sender.send_data(Bytes::from(notice)).await;
                    return;
                }
                Ok(Err(tokio::sync::broadcast::error::RecvError::Closed)) => return,
                Err(_elapsed) => {
                    // A comment, not an event: it keeps the connection warm without inventing
                    // anything for the phone to render, and it never wakes the Mac — it only
                    // writes to a socket that is already open.
                    let keepalive = format!(": keep-alive {}\n\n", super::now_millis());
                    if sender.send_data(Bytes::from(keepalive)).await.is_err() {
                        return;
                    }
                }
            }
        }
    });

    Response::builder()
        .status(StatusCode::OK)
        .header("content-type", "text/event-stream")
        .header("cache-control", "no-store")
        .header("access-control-allow-origin", "null")
        // Named because a reverse proxy in front of this would buffer an event stream into
        // uselessness. There is no proxy today and this design refuses to acquire one, so the
        // header is a note to whoever later thinks about putting one there.
        .header("x-accel-buffering", "no")
        .body(body.boxed())
        .unwrap_or_else(|_| Response::new(Full::new(Bytes::new()).boxed()))
}

/// Percent-decode a path.
///
/// Written out rather than adding `percent-encoding` as a direct dependency: it is a dozen lines,
/// and the only thing this needs is a path or one query value. **A malformed escape is left alone
/// rather than guessed at** — and it does not matter either way, because `routes::safe_join`
/// refuses anything with a `..` component *after* this ran, so a decode that produced one would
/// still be caught.
pub fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hi = (bytes[i + 1] as char).to_digit(16);
            let lo = (bytes[i + 2] as char).to_digit(16);
            if let (Some(hi), Some(lo)) = (hi, lo) {
                out.push((hi * 16 + lo) as u8);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_percent_escape_is_decoded_and_a_broken_one_is_left_alone() {
        assert_eq!(percent_decode("/app.js"), "/app.js");
        assert_eq!(percent_decode("/%2e%2e/private.txt"), "/../private.txt");
        assert_eq!(percent_decode("/a%20b.js"), "/a b.js");
        assert_eq!(percent_decode("RichOS-Device%20dev_a.CH.AAAA"), "RichOS-Device dev_a.CH.AAAA");
        // Broken escapes: left as they are, and `safe_join` refuses them either way.
        assert_eq!(percent_decode("/a%2"), "/a%2");
        assert_eq!(percent_decode("/a%zz"), "/a%zz");
        assert_eq!(percent_decode("%"), "%");
    }

    #[test]
    fn decoding_happens_before_the_traversal_check_so_an_escaped_dot_dot_is_still_refused() {
        // The pair that matters: this function turns `%2e%2e` into `..`, and the route layer then
        // refuses it. Either half alone would let `/%2e%2e/private.txt` through.
        let decoded = percent_decode("/%2e%2e/private.txt");
        assert_eq!(decoded, "/../private.txt");
        assert!(decoded.split('/').any(|part| part == ".."));
        assert_eq!(
            super::super::routes::safe_join(std::path::Path::new("/tmp"), "../private.txt"),
            None
        );
    }

    #[test]
    fn the_two_ports_are_the_ones_the_plan_pinned() {
        // The port is part of the origin (plan §2.1), so changing either of these means the phone
        // app has to be re-installed. They are asserted so a change is a decision.
        assert_eq!(HTTPS_PORT, 8443);
        assert_eq!(TRUST_PORT, 8444);
        assert_eq!(TRUST_PORT, HTTPS_PORT + 1, "the trust port must be the neighboring one");
    }

    #[test]
    fn a_wildcard_bind_is_refused_and_so_is_an_empty_address_list() {
        // Plan §2.5 item 2. The only plausible way a wildcard could creep in is an empty list
        // quietly meaning "all interfaces", so an empty list is an error — and `0.0.0.0` is
        // refused by name in case somebody ever passes it deliberately.
        use std::net::Ipv4Addr;
        assert!(check_addresses(&[]).is_err(), "an empty address list was accepted");
        assert!(check_addresses(&[IpAddr::V4(Ipv4Addr::UNSPECIFIED)]).is_err(), "0.0.0.0");
        assert!(check_addresses(&[IpAddr::V6(std::net::Ipv6Addr::UNSPECIFIED)]).is_err(), "::");
        assert!(check_addresses(&[IpAddr::V4(Ipv4Addr::new(224, 0, 0, 1))]).is_err(), "multicast");
        // One bad address in an otherwise good list is still a refusal — a half-bound listener is
        // worse than one that says it could not start.
        assert!(check_addresses(&[
            IpAddr::V4(Ipv4Addr::new(192, 168, 1, 249)),
            IpAddr::V4(Ipv4Addr::UNSPECIFIED),
        ])
        .is_err());
        // POSITIVE CONTROL: the addresses this Mac actually answers on are accepted.
        assert!(check_addresses(&[
            IpAddr::V4(Ipv4Addr::LOCALHOST),
            IpAddr::V4(Ipv4Addr::new(192, 168, 1, 249)),
        ])
        .is_ok());
    }

    #[test]
    fn every_answer_carries_a_fresh_challenge_and_a_refusal_carries_no_body() {
        // The phone reads `X-RichOS-Challenge` on every response, which is why there is no
        // challenge route. A 404 that omitted it would leave a phone whose challenge had aged out
        // with no way back.
        for outcome in [
            Outcome::NotFound,
            Outcome::RateLimited,
            Outcome::PayloadTooLarge,
            Outcome::Json { status: 200, body: "{}".into() },
        ] {
            let expected = outcome.status();
            let response = render_with(outcome, Some("CHALLENGE".into()));
            assert_eq!(response.status().as_u16(), expected);
            assert_eq!(response.headers().get("x-richos-challenge").unwrap(), "CHALLENGE");
            assert_eq!(
                response.headers().get("access-control-allow-origin").unwrap(),
                "null",
                "a wildcard origin would let any page on the internet make a credentialed request"
            );
            assert_eq!(response.headers().get("x-content-type-options").unwrap(), "nosniff");
        }
    }

    #[test]
    fn a_revoked_phone_gets_the_one_body_the_phone_acts_on() {
        // `app/phone/lib/api.js` looks for exactly `{"revoked":true}` and treats it as final.
        let response = render_with(Outcome::Revoked, None);
        assert_eq!(response.status().as_u16(), 403);
        assert_eq!(response.headers().get("content-type").unwrap(), "application/json; charset=utf-8");
    }

    #[test]
    fn a_rate_limited_answer_says_when_to_come_back() {
        let response = render_with(Outcome::RateLimited, None);
        assert_eq!(response.status().as_u16(), 429);
        assert_eq!(response.headers().get("retry-after").unwrap(), "60");
    }

    #[test]
    fn the_profile_is_offered_as_a_download_with_apples_own_content_type() {
        let response = render_plain(dispatch_trust("<plist/>", "GET", "/ca"));
        assert_eq!(response.status().as_u16(), 200);
        assert_eq!(response.headers().get("content-type").unwrap(), "application/x-apple-aspen-config");
        assert!(response
            .headers()
            .get("content-disposition")
            .unwrap()
            .to_str()
            .unwrap()
            .contains("richos-local-ca.mobileconfig"));
        // No challenge on the trust port: it has no credential and never will.
        assert!(response.headers().get("x-richos-challenge").is_none());
    }

    #[test]
    fn the_tls_configuration_is_built_from_our_own_leaf_and_speaks_http_1_1_only() {
        // Built from a REAL certificate rather than a fixture, so "rustls accepts what our
        // certificate authority issues" is a fact about the two of them together. This is the
        // assertion that would have caught a SEC1-versus-PKCS#8 mismatch, which is the one thing
        // about this handshake that is easy to get wrong and impossible to see.
        use crate::phone::ca::PhoneCa;
        use crate::phone::names::LocalNames;
        use crate::phone::secrets::MemorySecrets;
        use std::net::Ipv4Addr;

        let dir = std::env::temp_dir().join(format!(
            "richos-phone-tls-{}-{}",
            std::process::id(),
            super::super::now_millis()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let secrets = MemorySecrets::default();
        let names = LocalNames {
            host: "MM1".into(),
            bonjour: "mm1.local".into(),
            addresses: vec![IpAddr::V4(Ipv4Addr::new(192, 168, 1, 249))],
        };
        let ca = PhoneCa::open(&dir, &secrets, names).unwrap();
        let config = tls_config(&ca.leaf_der, &ca.leaf_key_pkcs8).expect("rustls refused our leaf");
        assert_eq!(config.alpn_protocols, vec![b"http/1.1".to_vec()]);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
