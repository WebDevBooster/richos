//! **THE SOCKET — and everything about it that plan §2.5 promised in exchange for opening one.**
//!
//! > *"Bar (c) is gone, and this is **RichOS's first inbound network listener** … That is the
//! > real security cost of §57, and it is contained rather than hand-waved."*
//!
//! This file is the containment, and each item is at the line that enforces it:
//!
//!  1. **It does not exist until he pairs a phone.** [`Listener::start`] is called from the
//!     pairing surface; [`Listener`]'s `Drop` closes every socket and joins the thread. Off
//!     means no socket, not a closed door — and there is a test that binds, stops, and proves
//!     the port is free again.
//!  2. **It binds the LAN interfaces only, never `0.0.0.0`.** Every address comes from
//!     [`super::names`], which read them off this machine by name. There is no code path in
//!     this file that can produce a wildcard bind, and a test asserts that of the bound set.
//!  3. **TLS with our own leaf.** [`tls_config`] is built from the leaf [`super::ca`] issued.
//!  4. **Every route requires the credential, everything else is a flat 404** — [`super::routes`].
//!  6. **Body-size limits at the edge**: `Limited` refuses an oversized body *before* it is
//!     read into memory, which is the difference between a limit and a check.
//!
//! # Why the channel owns its own runtime
//!
//! A current-thread tokio runtime on one named thread, created when the listener starts and
//! dropped when it stops. The app's own async runtime outlives the listener by design, so
//! hanging the sockets off it would mean "stopped" was a flag rather than an absence. This way
//! **stopping the channel really does destroy the thing that was listening**, which is item 1
//! above stated as a fact about the process rather than about a boolean.

use super::routes::{dispatch, dispatch_trust, Channel, Incoming, Outcome};
use super::stream::PhoneHub;
use super::{PhoneError, HTTPS_PORT, KEEPALIVE_MS, MAX_BODY_BYTES, TRUST_PORT};
use bytes::Bytes;
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
    /// Every address and port actually bound. Shown on the settings screen, and the thing a
    /// test asserts against — a claim about what was bound must come from the socket, not from
    /// what we asked for.
    pub bound: Vec<SocketAddr>,
}

impl Listener {
    /// Bind and serve.
    ///
    /// **Binding happens synchronously, before anything is spawned**, so a port already in use
    /// is an error the caller can show him rather than a failure inside a task nobody is
    /// watching. If any address fails to bind, every socket already bound is dropped and the
    /// whole start fails — a half-bound listener that answers on one interface and not another
    /// is worse than one that says it could not start.
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
                let listener = StdTcpListener::bind(socket).map_err(|e| {
                    PhoneError::Io(format!("could not listen on {socket}: {e}"))
                })?;
                listener.set_nonblocking(true)?;
                bound.push(socket);
                into.push(listener);
            }
        }

        let (shutdown, _rx) = watch::channel(false);
        let stop = shutdown.clone();
        let hub = Arc::clone(&channel.hub);
        hub.set_live(true);
        let thread = std::thread::Builder::new()
            .name("richos-phone-channel".to_string())
            .spawn(move || {
                let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
                    Ok(r) => r,
                    Err(e) => {
                        eprintln!("[richos] the phone channel could not start its runtime: {e}");
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
            // Joined rather than detached: "the listener stops when he unpairs the last phone"
            // has to mean the port is free when that call returns, or the next pairing fails to
            // bind for reasons nobody can see.
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

/// **The one guard that makes a wildcard bind impossible.** Plan §2.5 item 2: *"It binds the
/// LAN interfaces only — never `0.0.0.0` as a shortcut, never an interface it was not told
/// about."*
///
/// A separate function because the only plausible way a wildcard could have crept in is an
/// empty address list quietly meaning "all of them", and that has to be testable without
/// building a whole channel.
pub fn check_addresses(addresses: &[IpAddr]) -> Result<(), PhoneError> {
    if addresses.is_empty() {
        return Err(PhoneError::Malformed(
            "this Mac has no address the phone could reach, so there is nothing to listen on".into(),
        ));
    }
    for address in addresses {
        if address.is_unspecified() {
            return Err(PhoneError::Malformed(format!(
                "{address} is every interface at once, which this channel never binds — \
                 give it the addresses this Mac actually answers on"
            )));
        }
        if address.is_multicast() {
            return Err(PhoneError::Malformed(format!("{address} is not an address a server binds")));
        }
    }
    Ok(())
}

/// Build the TLS configuration from the leaf the certificate authority issued.
pub fn tls_config(leaf_der: &[u8], leaf_key_pkcs8: &[u8]) -> Result<Arc<rustls::ServerConfig>, PhoneError> {
    // The same `ring` provider `voice_provision.rs` installs, installed idempotently here for
    // the same reason it does: a process-level provider must exist before a config is built,
    // and depending on which unrelated feature ran first is a defect waiting for one first run.
    let _ = rustls::crypto::ring::default_provider().install_default();

    let cert = rustls::pki_types::CertificateDer::from(leaf_der.to_vec());
    let key = rustls::pki_types::PrivateKeyDer::Pkcs8(leaf_key_pkcs8.to_vec().into());
    // The ROOT is deliberately not in the chain. The phone installed it; sending it again would
    // be a bigger handshake that proves nothing.
    let mut config = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(vec![cert], key)
        .map_err(|e| PhoneError::Crypto(format!("rustls refused our own leaf: {e}")))?;
    // HTTP/1.1 only, matching plan §2.6's "No WebSocket on either side. Upgrade later only if
    // a measurement demands it" — one protocol, one code path.
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

async fn accept_https(
    listener: tokio::net::TcpListener,
    acceptor: tokio_rustls::TlsAcceptor,
    channel: Arc<Channel>,
    mut shutdown: watch::Receiver<bool>,
) {
    loop {
        tokio::select! {
            _ = shutdown.changed() => return,
            accepted = listener.accept() => {
                let Ok((stream, _peer)) = accepted else { continue };
                let acceptor = acceptor.clone();
                let channel = Arc::clone(&channel);
                let shutdown = shutdown.clone();
                tokio::spawn(async move {
                    // A handshake that fails is a device on his Wi-Fi that does not hold the
                    // certificate authority. Nothing is logged per connection: a TV that probes
                    // the port every minute would otherwise fill his log with noise.
                    let Ok(tls_stream) = acceptor.accept(stream).await else { return };
                    let io = hyper_util::rt::TokioIo::new(tls_stream);
                    let service = service_fn(move |request| {
                        let channel = Arc::clone(&channel);
                        let shutdown = shutdown.clone();
                        async move { Ok::<_, std::convert::Infallible>(handle(channel, shutdown, request).await) }
                    });
                    let _ = hyper::server::conn::http1::Builder::new()
                        .serve_connection(io, service)
                        .await;
                });
            }
        }
    }
}

async fn accept_trust(
    listener: tokio::net::TcpListener,
    profile: Arc<String>,
    mut shutdown: watch::Receiver<bool>,
) {
    loop {
        tokio::select! {
            _ = shutdown.changed() => return,
            accepted = listener.accept() => {
                let Ok((stream, _peer)) = accepted else { continue };
                let profile = Arc::clone(&profile);
                tokio::spawn(async move {
                    let io = hyper_util::rt::TokioIo::new(stream);
                    let service = service_fn(move |request: Request<HyperBody>| {
                        let profile = Arc::clone(&profile);
                        async move {
                            let method = request.method().as_str().to_string();
                            let path = percent_decode(request.uri().path());
                            Ok::<_, std::convert::Infallible>(render(dispatch_trust(&profile, &method, &path)))
                        }
                    });
                    let _ = hyper::server::conn::http1::Builder::new()
                        .serve_connection(io, service)
                        .await;
                });
            }
        }
    }
}

async fn handle(
    channel: Arc<Channel>,
    shutdown: watch::Receiver<bool>,
    request: Request<HyperBody>,
) -> Response<BoxBody> {
    let method = request.method().as_str().to_string();
    let path = percent_decode(request.uri().path());
    let query = request.uri().query().unwrap_or("").to_string();
    let header = |name: &str| {
        request.headers().get(name).and_then(|v| v.to_str().ok()).map(|s| s.to_string())
    };
    let device_header = header("x-richos-device");
    let time_header = header("x-richos-time");
    let nonce_header = header("x-richos-nonce");
    let signature_header = header("x-richos-signature");
    let last_event_id = header("last-event-id");

    // THE LIMIT IS APPLIED BEFORE THE BODY IS READ, which is the difference between a limit and
    // a check. `Limited` fails the read rather than buffering 4 GB and then measuring it.
    let body = match Limited::new(request.into_body(), MAX_BODY_BYTES).collect().await {
        Ok(collected) => collected.to_bytes().to_vec(),
        Err(_) => return render(Outcome::PayloadTooLarge),
    };

    let incoming = Incoming {
        method,
        path,
        query,
        device_header,
        time_header,
        nonce_header,
        signature_header,
        last_event_id,
        body,
    };
    match dispatch(&channel, &incoming) {
        Outcome::Stream { opening } => open_stream(channel, shutdown, opening),
        other => render(other),
    }
}

/// Turn a described response into an HTTP one.
///
/// **Every response carries `X-RichOS-Time`, including a 404.** That is how the phone learns
/// the server time it signs with, and it is why the contract needs no challenge route.
fn render(outcome: Outcome) -> Response<BoxBody> {
    let mut builder = Response::builder()
        .status(StatusCode::from_u16(outcome.status()).unwrap_or(StatusCode::NOT_FOUND))
        .header("x-richos-time", super::now_millis().to_string())
        // The phone app is same-origin with the API today. The header is here because the
        // reachability seam (§8) means the API base can move to another origin later, and
        // `*` is refused even now: a credentialed request from any page on the internet is
        // exactly what this must not allow.
        .header("access-control-allow-origin", "null")
        .header("cache-control", "no-store")
        .header("x-content-type-options", "nosniff");
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
        // A refusal carries no body at all. Contract §9: one answer to every question.
        Outcome::NotFound | Outcome::PayloadTooLarge => Bytes::new(),
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

/// Open an event stream: write the opening frames, then follow the hub until the phone goes
/// away or the channel stops.
fn open_stream(
    channel: Arc<Channel>,
    mut shutdown: watch::Receiver<bool>,
    opening: Vec<String>,
) -> Response<BoxBody> {
    let slot = match channel.devices.claim_stream() {
        Ok(slot) => slot,
        Err(_) => return render(Outcome::RateLimited),
    };
    let (mut sender, body) = http_body_util::channel::Channel::<Bytes, std::convert::Infallible>::new(32);
    let hub: Arc<PhoneHub> = Arc::clone(&channel.hub);
    let mut live = hub.subscribe();

    tokio::spawn(async move {
        // The slot is MOVED into this task, so it is released by `Drop` however the stream
        // ends — the phone locking itself, walking out of range, or the channel stopping.
        let _slot = slot;
        for frame in opening {
            if sender.send_data(Bytes::from(frame)).await.is_err() {
                return;
            }
        }
        loop {
            tokio::select! {
                _ = shutdown.changed() => return,
                received = live.recv() => match received {
                    Ok(frame) => {
                        if sender.send_data(Bytes::from(frame.to_wire())).await.is_err() {
                            return;
                        }
                    }
                    // The phone fell far enough behind that frames were dropped. It is told to
                    // start again rather than handed a thinned stream: a gap it cannot see is
                    // the one failure this whole design refuses.
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(missed)) => {
                        let notice = format!(": re-snapshot {missed}\n\n");
                        if sender.send_data(Bytes::from(notice)).await.is_err() {
                            return;
                        }
                        return;
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => return,
                },
                _ = tokio::time::sleep(std::time::Duration::from_millis(KEEPALIVE_MS)) => {
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
        .header("x-richos-time", super::now_millis().to_string())
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
/// Written out rather than adding `percent-encoding` as a direct dependency: it is twelve lines,
/// and the only thing this needs is the path. **A malformed escape is left alone rather than
/// guessed at** — and it does not matter either way, because `routes::safe_join` refuses
/// anything with a `..` component *after* this ran, so a decode that produced one would still
/// be caught.
pub fn percent_decode(path: &str) -> String {
    let bytes = path.as_bytes();
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
        // Broken escapes: left as they are, and `safe_join` refuses them either way.
        assert_eq!(percent_decode("/a%2"), "/a%2");
        assert_eq!(percent_decode("/a%zz"), "/a%zz");
        assert_eq!(percent_decode("%"), "%");
    }

    #[test]
    fn decoding_happens_before_the_traversal_check_so_an_escaped_dot_dot_is_still_refused() {
        // The pair that matters: this function turns `%2e%2e` into `..`, and the route layer
        // then refuses it. Either half alone would let `/%2e%2e/private.txt` through.
        let decoded = percent_decode("/%2e%2e/private.txt");
        assert_eq!(decoded, "/../private.txt");
        assert!(decoded.split('/').any(|part| part == ".."));
        assert_eq!(super::super::routes::safe_join(std::path::Path::new("/tmp"), "../private.txt"), None);
    }

    #[test]
    fn the_two_ports_are_the_ones_the_plan_pinned() {
        // The port is part of the origin (plan §2.1), so changing either of these means the
        // phone app has to be re-installed. They are asserted so a change is a decision.
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
        assert!(check_addresses(&[IpAddr::V4(Ipv4Addr::UNSPECIFIED)]).is_err(), "0.0.0.0 was accepted");
        assert!(
            check_addresses(&[IpAddr::V6(std::net::Ipv6Addr::UNSPECIFIED)]).is_err(),
            ":: was accepted"
        );
        assert!(check_addresses(&[IpAddr::V4(Ipv4Addr::new(224, 0, 0, 1))]).is_err(), "multicast");
        // One bad address in an otherwise good list is still a refusal — a half-bound listener
        // is worse than one that says it could not start.
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
    fn the_response_headers_carry_the_server_time_on_every_answer_including_a_refusal() {
        // Contract §4.3: this is how the phone learns the clock it signs with, and it is why
        // there is no challenge route. A 404 that omitted it would leave a phone whose clock
        // has drifted with no way back.
        for outcome in [
            Outcome::NotFound,
            Outcome::RateLimited,
            Outcome::PayloadTooLarge,
            Outcome::Json { status: 200, body: "{}".into() },
        ] {
            let expected = outcome.status();
            let response = render(outcome);
            assert_eq!(response.status().as_u16(), expected);
            let time = response
                .headers()
                .get("x-richos-time")
                .and_then(|v| v.to_str().ok())
                .and_then(|v| v.parse::<u64>().ok());
            assert!(time.unwrap_or(0) > 0, "no server time on a {expected}");
            assert_eq!(
                response.headers().get("access-control-allow-origin").unwrap(),
                "null",
                "a wildcard origin would let any page on the internet make a credentialed request"
            );
            assert_eq!(response.headers().get("x-content-type-options").unwrap(), "nosniff");
        }
    }

    #[test]
    fn a_rate_limited_answer_says_when_to_come_back() {
        let response = render(Outcome::RateLimited);
        assert_eq!(response.status().as_u16(), 429);
        assert_eq!(response.headers().get("retry-after").unwrap(), "60");
    }

    #[test]
    fn the_profile_is_offered_as_a_download_with_apples_own_content_type() {
        let response = render(dispatch_trust("<plist/>", "GET", "/ca"));
        assert_eq!(response.status().as_u16(), 200);
        assert_eq!(
            response.headers().get("content-type").unwrap(),
            "application/x-apple-aspen-config"
        );
        assert!(response
            .headers()
            .get("content-disposition")
            .unwrap()
            .to_str()
            .unwrap()
            .contains("richos-local-ca.mobileconfig"));
    }

    #[test]
    fn the_tls_configuration_is_built_from_our_own_leaf_and_speaks_http_1_1_only() {
        // Built from a real certificate rather than a fixture, so "rustls accepts what our
        // certificate authority issues" is a fact about the two of them together. This is the
        // assertion that would have caught a SEC1-versus-PKCS#8 mismatch, which is the one
        // thing about this handshake that is easy to get wrong and impossible to see.
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
