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
use super::{PhoneError, KEEPALIVE_MS, MAX_BODY_BYTES};
#[cfg(test)]
use super::{HTTPS_PORT, TRUST_PORT};
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
    /// `https_port` and `trust_port` are parameters and not the constants, for one reason: the
    /// end-to-end test in this file stands a REAL listener up on an ephemeral pair so it can prove
    /// the handshake and the routes against a real TLS client, and a test that fought the shipped
    /// app for port 8443 would be a test that fails when he has the app open.
    /// **[`super::PhoneRuntime::start`] is the only production caller and it passes
    /// [`HTTPS_PORT`] and [`TRUST_PORT`].**
    pub fn start(
        channel: Arc<Channel>,
        tls: Arc<rustls::ServerConfig>,
        profile: Arc<String>,
        addresses: &[IpAddr],
        https_port: u16,
        trust_port: u16,
    ) -> Result<Self, PhoneError> {
        check_addresses(addresses)?;
        let mut https: Vec<StdTcpListener> = Vec::new();
        let mut trust: Vec<StdTcpListener> = Vec::new();
        let mut bound: Vec<SocketAddr> = Vec::new();
        for address in addresses {
            for (port, into) in [(https_port, &mut https), (trust_port, &mut trust)] {
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

/// **The key, in whichever of the two encodings it actually arrived in.**
///
/// MEASURED ON THIS MAC, 2026-09-19, and it is the reason this function exists rather than a
/// `PrivateKeyDer::Pkcs8` at the call site. Counting the PEM labels that
/// `tailscale cert --cert-file - --key-file -` printed for this Mac's real tailnet name:
/// **four `CERTIFICATE` blocks and one `EC PRIVATE KEY` block.**
///
/// `EC PRIVATE KEY` is **SEC1**, not PKCS#8. Wrapped as PKCS#8 — which is what this file did
/// until this line — `ring` refuses it and the whole tailnet configuration fails to build with
/// "rustls refused a private key". `tailnet::KeyDer` has carried the distinction since the parser
/// was written; the TLS side threw it away. Nothing caught it because every test fed it a PKCS#8
/// key minted by our own authority, and the one encoding a real `tailscale cert` produces is the
/// other one.
fn private_key_der(key: &super::tailnet::KeyDer) -> rustls::pki_types::PrivateKeyDer<'static> {
    match key {
        super::tailnet::KeyDer::Pkcs8(der) => {
            rustls::pki_types::PrivateKeyDer::Pkcs8(der.clone().into())
        }
        super::tailnet::KeyDer::Sec1(der) => {
            rustls::pki_types::PrivateKeyDer::Sec1(der.clone().into())
        }
    }
}

/// Turn a leaf (or a chain, leaf first) and its key into something rustls can present.
///
/// Separated from [`tls_config`] because the listener now holds **two** of these and the awkward
/// part — a key that is SEC1 where rustls wants PKCS#8 — is identical for both.
fn certified_key(
    chain_der: Vec<Vec<u8>>,
    key: &super::tailnet::KeyDer,
) -> Result<Arc<rustls::sign::CertifiedKey>, PhoneError> {
    let chain: Vec<rustls::pki_types::CertificateDer<'static>> =
        chain_der.into_iter().map(rustls::pki_types::CertificateDer::from).collect();
    if chain.is_empty() {
        return Err(PhoneError::Crypto("a certificate chain with nothing in it".into()));
    }
    let signing_key = rustls::crypto::ring::sign::any_supported_type(&private_key_der(key))
        .map_err(|e| PhoneError::Crypto(format!("rustls refused a private key: {e}")))?;
    Ok(Arc::new(rustls::sign::CertifiedKey::new(chain, signing_key)))
}

/// **Which certificate this Mac presents, decided by the name the phone asked for.**
///
/// The Tailscale path (CEO §61, reach document §2.3) gives this Mac a SECOND name —
/// `mm1.<tailnet>.ts.net` — with a **publicly trusted** certificate, which is what deletes the
/// sixteen taps. It does not replace `mm1.local`: a Mac can be reachable both ways at once, and
/// the brief is explicit that the home case keeps working unchanged.
///
/// # Home is the fallback for EVERY name, and that is the safety property
///
/// [`resolve`](CertDesk::resolve) returns the tailnet key **only** for an exact,
/// case-insensitive match on the tailnet name, and the Mac-CA leaf for everything else — another
/// name, a bare IP address (which carries no SNI at all), or a client too old to send one. So the
/// worst a wrong or missing SNI can do is produce exactly the behavior this listener had before
/// the tailnet existed. A resolver that returned `None` on no match would instead turn "connect by
/// IP" into a handshake failure, which is the home path breaking for a Tailscale user.
pub struct CertDesk {
    /// The Mac's own leaf, from [`super::ca`]. Always present: the listener does not start without
    /// it, and it is what every address and `mm1.local` are served with.
    home: Arc<rustls::sign::CertifiedKey>,
    /// The tailnet name, normalized, and the publicly trusted chain for it. `None` until Tailscale
    /// is signed in, certificates are enabled for the tailnet, and `tailscale cert` has answered.
    tailnet: Option<(String, Arc<rustls::sign::CertifiedKey>)>,
}

impl CertDesk {
    /// The name this desk will answer to with the tailnet certificate, if it has one.
    pub fn tailnet_name(&self) -> Option<&str> {
        self.tailnet.as_ref().map(|(name, _)| name.as_str())
    }
}

impl std::fmt::Debug for CertDesk {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // No key material, ever, in a formatter. The name is the only interesting part.
        f.debug_struct("CertDesk").field("tailnet", &self.tailnet_name()).finish()
    }
}

impl rustls::server::ResolvesServerCert for CertDesk {
    fn resolve(
        &self,
        client_hello: rustls::server::ClientHello<'_>,
    ) -> Option<Arc<rustls::sign::CertifiedKey>> {
        if let (Some(asked), Some((name, key))) = (client_hello.server_name(), &self.tailnet) {
            // ASCII-case-insensitive, because a DNS name is, and the phone is not the only thing
            // that will ever open this socket. `super::tailnet::normalize_name` already lowercased
            // our side.
            if asked.eq_ignore_ascii_case(name) {
                return Some(Arc::clone(key));
            }
        }
        Some(Arc::clone(&self.home))
    }
}

/// Build the TLS configuration from the leaf the certificate authority issued.
///
/// The home-only case, unchanged in behavior: one certificate, presented for every name.
pub fn tls_config(
    leaf_der: &[u8],
    leaf_key_pkcs8: &[u8],
) -> Result<Arc<rustls::ServerConfig>, PhoneError> {
    tls_config_with_tailnet(leaf_der, leaf_key_pkcs8, None)
}

/// [`tls_config`], plus the publicly trusted certificate for this Mac's tailnet name.
///
/// `tailnet` is `(name, chain leaf-first, PKCS#8 key)`. The chain has more than one member here
/// and exactly one in the home case: `tailscale cert` returns a leaf **and its issuing
/// intermediate**, and a public chain that omits the intermediate is the classic "works in curl,
/// fails on a phone" certificate — desktop trust stores often cache intermediates and a freshly
/// wiped phone does not.
pub fn tls_config_with_tailnet(
    leaf_der: &[u8],
    leaf_key_pkcs8: &[u8],
    tailnet: Option<(String, Vec<Vec<u8>>, super::tailnet::KeyDer)>,
) -> Result<Arc<rustls::ServerConfig>, PhoneError> {
    // The same `ring` provider `voice_provision.rs` installs, installed idempotently here for the
    // same reason it does: a process-level provider must exist before a config is built, and
    // depending on which unrelated feature ran first is a defect waiting for one first run.
    let _ = rustls::crypto::ring::default_provider().install_default();

    // The ROOT is deliberately not in the home chain. The phone installed it; sending it again
    // would be a bigger handshake that proves nothing.
    let home = certified_key(
        vec![leaf_der.to_vec()],
        &super::tailnet::KeyDer::Pkcs8(leaf_key_pkcs8.to_vec()),
    )
    .map_err(|e| PhoneError::Crypto(format!("rustls refused our own leaf: {e}")))?;

    let tailnet = match tailnet {
        Some((name, chain, key)) => {
            Some((super::tailnet::normalize_name(&name), certified_key(chain, &key)?))
        }
        None => None,
    };

    let mut config = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_cert_resolver(Arc::new(CertDesk { home, tailnet }));
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
/// phone gets the next thing to sign (`web/web-app/lib/api.js` reads the header on every response),
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
/// rather than guessed at** — and it does not matter either way, because the static route resolves
/// by exact match against the app embedded in this binary (`phone::assets`), so a decode that
/// produced a `..` component would name nothing and get the same flat 404.
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
        // Broken escapes: left as they are, and the lookup misses on them either way.
        assert_eq!(percent_decode("/a%2"), "/a%2");
        assert_eq!(percent_decode("/a%zz"), "/a%zz");
        assert_eq!(percent_decode("%"), "%");
    }

    #[test]
    fn decoding_happens_before_the_lookup_so_an_escaped_dot_dot_is_still_refused() {
        // The pair that matters: this function turns `%2e%2e` into `..`, and the route layer then
        // has nothing by that name. Either half alone would let `/%2e%2e/private.txt` through —
        // decoding after the lookup would let the escaped form reach a later consumer intact.
        let decoded = percent_decode("/%2e%2e/private.txt");
        assert_eq!(decoded, "/../private.txt");
        assert!(decoded.split('/').any(|part| part == ".."));
        // The app is a table compiled into this binary, so the decoded path is refused by not
        // existing rather than by inspection (`phone::assets`). Asserted against the REAL
        // embedded app, which is the one a request actually meets.
        let app = super::super::assets::PhoneApp::embedded();
        assert!(app.file("../private.txt").is_none());
        assert!(app.file(decoded.trim_start_matches('/')).is_none());
        // And a real one resolves, so the line above is not passing because everything fails.
        assert!(app.file("app.js").is_some());
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
        // `web/web-app/lib/api.js` looks for exactly `{"revoked":true}` and treats it as final.
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

    /// **ONE LISTENER, TWO NAMES, TWO AUTHORITIES — the whole of the Tailscale path's TLS half,
    /// proved without a tailnet.**
    ///
    /// CEO §61 and reach document §2.3: the Tailscale path gives this Mac a second name with a
    /// **publicly trusted** certificate, and the brief requires that `mm1.local` keep working
    /// unchanged beside it. Those are two claims about one socket, and this is where they are
    /// settled.
    ///
    /// **The stand-in is honest about what it stands in for.** There is no Tailscale on this Mac
    /// (see `phone/tailnet.rs`'s header for the eight checks), so the "publicly trusted" chain here
    /// is a SECOND `PhoneCa`, issued for the tailnet name under its own separate root. What matters
    /// for SNI selection is exactly the property that makes it a good stand-in: **it is signed by
    /// an authority the home root knows nothing about**, so a client that trusts only the home root
    /// cannot accept it, and the third case below turns that into the control.
    ///
    /// `unverified:` that a real Let's Encrypt chain from `tailscale cert` is accepted. That is a
    /// claim about certificate *contents*, which this test does not make; it makes a claim about
    /// *which* certificate the resolver hands out, which is the part we wrote.
    #[test]
    fn the_tailnet_name_gets_the_tailnet_certificate_and_every_other_name_still_gets_our_own() {
        use crate::phone::ca::PhoneCa;
        use crate::phone::names::LocalNames;
        use crate::phone::secrets::MemorySecrets;
        use std::net::Ipv4Addr;

        const TAILNET: &str = "mm1.tail1a2b3c.ts.net";

        /// **A temporary directory that goes away even when the test panics.**
        ///
        /// CEO §54: *"a ROCK-SOLID … mechanism that always guarantees that garbage like this will
        /// be always cleaned up afterwards."* A trailing `remove_dir_all` is not that mechanism —
        /// it is skipped by the very failure that makes somebody run the test in the first place.
        /// **Proved on 2026-09-18 by defeating it:** a deliberate mutation probe of this test left
        /// two authority directories behind in `$TMPDIR`, because the panic jumped over the
        /// cleanup at the bottom. `Drop` runs during unwinding; that line does not.
        struct Scratch(std::path::PathBuf);
        impl Drop for Scratch {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }

        fn authority(bonjour: &str, tag: &str) -> (PhoneCa, Scratch) {
            let dir = std::env::temp_dir().join(format!(
                "richos-phone-sni-{tag}-{}-{}",
                std::process::id(),
                super::super::now_millis()
            ));
            std::fs::create_dir_all(&dir).unwrap();
            let names = LocalNames {
                host: "MM1".into(),
                bonjour: bonjour.into(),
                // LOOPBACK, so case 4 below can connect to a bare address and have the leaf it is
                // served actually cover it. `names.rs` includes loopback in the real list for the
                // same kind of reason.
                addresses: vec![IpAddr::V4(Ipv4Addr::LOCALHOST)],
            };
            // A FRESH secret store per authority. Sharing one would hand the second `PhoneCa` the
            // first's key, and the two roots would silently be one root — which would make the
            // control below pass for the wrong reason.
            let ca = PhoneCa::open(&dir, &MemorySecrets::default(), names).unwrap();
            (ca, Scratch(dir))
        }

        let (home, _home_dir) = authority("mm1.local", "home");
        let (tailnet, _tailnet_dir) = authority(TAILNET, "tailnet");
        assert_ne!(home.ca_der, tailnet.ca_der, "the two authorities are the same authority");

        let config = tls_config_with_tailnet(
            &home.leaf_der,
            &home.leaf_key_pkcs8,
            Some((
            TAILNET.to_string(),
            vec![tailnet.leaf_der.clone()],
            crate::phone::tailnet::KeyDer::Pkcs8(tailnet.leaf_key_pkcs8.clone()),
        )),
        )
        .expect("rustls refused a two-certificate configuration");

        // A socket that accepts three connections and does nothing but the handshake.
        let listener = StdTcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        let server_config = Arc::clone(&config);
        let server = std::thread::spawn(move || {
            for _ in 0..4 {
                let Ok((mut socket, _)) = listener.accept() else { return };
                socket.set_read_timeout(Some(std::time::Duration::from_secs(10))).ok();
                let Ok(mut connection) = rustls::ServerConnection::new(Arc::clone(&server_config))
                else {
                    continue;
                };
                // Errors are expected on the refusal case: the client sends an alert and goes.
                let _ = connection.complete_io(&mut socket);
            }
        });

        /// Handshake only — no HTTP, because what is being proved is which certificate came back.
        fn handshake(port: u16, root_der: &[u8], sni: &str) -> Result<(), String> {
            let mut roots = rustls::RootCertStore::empty();
            roots.add(rustls::pki_types::CertificateDer::from(root_der.to_vec())).unwrap();
            let config = rustls::ClientConfig::builder()
                .with_root_certificates(roots)
                .with_no_client_auth();
            let name = rustls::pki_types::ServerName::try_from(sni).unwrap().to_owned();
            let mut connection =
                rustls::ClientConnection::new(Arc::new(config), name).map_err(|e| e.to_string())?;
            let mut socket =
                std::net::TcpStream::connect((Ipv4Addr::LOCALHOST, port)).map_err(|e| e.to_string())?;
            socket.set_read_timeout(Some(std::time::Duration::from_secs(10))).ok();
            while connection.is_handshaking() {
                connection.complete_io(&mut socket).map_err(|e| e.to_string())?;
            }
            Ok(())
        }

        // 1. THE HOME PATH IS UNTOUCHED. `mm1.local`, validated against the Mac's own root.
        assert!(
            handshake(port, &home.ca_der, "mm1.local").is_ok(),
            "the home name stopped working when the tailnet certificate was added"
        );

        // 2. THE TAILNET NAME GETS THE OTHER CERTIFICATE. Validated against the OTHER root, which
        //    is only possible if the resolver actually switched on the SNI name.
        assert!(
            handshake(port, &tailnet.ca_der, TAILNET).is_ok(),
            "the tailnet name was not served the tailnet certificate"
        );

        // 3. THE CONTROL, and the reason cases 1 and 2 mean anything. The SAME tailnet name,
        //    validated against the HOME root, must FAIL — because what came back was signed by an
        //    authority that root has never heard of. If the resolver had ignored SNI and served the
        //    home leaf for everything, this would have succeeded and case 2 would have failed; if
        //    it had served the tailnet leaf for everything, case 1 would have failed. Only the
        //    resolver actually working makes all three come out as asserted.
        assert!(
            handshake(port, &home.ca_der, TAILNET).is_err(),
            "the home root accepted the tailnet certificate, so the two authorities are not distinct"
        );

        // 4. A CONNECTION THAT NAMES NOTHING STILL GETS THE MAC'S OWN CERTIFICATE. An IP-literal
        //    `ServerName` sends NO SNI extension at all — which is what reaching the Mac by its
        //    address does, and what a client too old to send one does. This is why `resolve`
        //    falls back to home instead of returning `None`: `None` would turn "connect by
        //    address" into a handshake failure, breaking the home path for the one user who took
        //    the Tailscale path.
        assert!(
            handshake(port, &home.ca_der, "127.0.0.1").is_ok(),
            "a connection carrying no server name was not served the Mac's own certificate"
        );

        // The two authority directories need no line here: `Scratch` removes them on the way out,
        // including on the way out through a panic.
        let _ = server.join();
    }


    // -----------------------------------------------------------------------------------
    // THE WHOLE CHANNEL, END TO END, OVER REAL TLS
    // -----------------------------------------------------------------------------------
    //
    // Every layer this slice built, in one test, with nothing stubbed between them:
    //
    //   * a REAL certificate authority and leaf from `openssl`, and a REAL `rustls` client that
    //     validates the leaf against that root — so "the certificate is acceptable" is a fact
    //     about the two of them rather than about the fields we asked for;
    //   * the REAL `hyper` listener on a real socket, reached by writing HTTP/1.1 bytes;
    //   * the REAL route table, the REAL signature check, the REAL SSE stream;
    //   * a REAL `Spine` behind the bridge, with a mock lease standing in for `claude` and
    //     nothing else standing in for anything.
    //
    // What it does not cover, named so the coverage claim is honest: `claude` itself (a mock
    // lease), the browser (the client is `rustls` and hand-written HTTP), the macOS Keychain (an
    // in-memory secret store, because a test must not write to his login keychain), and Apple's
    // push service (nothing outbound happens here).

    use crate::phone::api_base::ApiBaseDesk;
    use crate::phone::ca::PhoneCa;
    use crate::phone::device::{signing_string, DeviceDesk};
    use crate::phone::names::LocalNames;
    use crate::phone::routes::{Accepted, Bridge, Channel};
    use crate::phone::secrets::MemorySecrets;
    use crate::phone::stream::PhoneHub;
    use richos_core::cognition::MockLeaseFactory;
    use richos_core::entity::{Entity, EntityId, EntityRegistry};
    use richos_core::ledger::Ledger;
    use richos_core::spine::Spine;
    use richos_core::steering::TurnControl;
    use serde_json::Value;
    use std::io::{Read, Write};
    use std::net::Ipv4Addr;
    use std::sync::Mutex as StdMutex;

    /// A bridge over a real spine, with the same two-part shape the Tauri one has: the words go to
    /// the durable intake log, and the drain runs on its own thread because it runs the turn.
    struct SpineBridge {
        spine: Arc<StdMutex<Spine>>,
        control: TurnControl,
        thread: String,
        entity: EntityId,
    }

    impl Bridge for SpineBridge {
        fn submit_text(&self, thread_id: Option<&str>, text: &str) -> Result<Accepted, String> {
            let thread = thread_id.unwrap_or(&self.thread).to_string();
            let record = self
                .control
                .submit_from_channel(&thread, Some(self.entity.clone()), text, "phone")
                .map_err(|e| e.to_string())?;
            let spine = Arc::clone(&self.spine);
            std::thread::spawn(move || {
                let _ = spine.lock().unwrap().poll_intake();
            });
            Ok(Accepted {
                message_id: format!("intake_{}", record.id()),
                thread_id: thread,
                at: super::super::now_millis(),
            })
        }
        fn snapshot(&self, thread_id: Option<&str>) -> Result<Value, String> {
            let thread = thread_id.unwrap_or(&self.thread).to_string();
            let spine = self.spine.lock().unwrap();
            crate::timeline_view::timeline_payload(&spine, &thread)
        }
        fn current_thread(&self) -> Option<(String, String)> {
            Some((self.thread.clone(), "the proposal".into()))
        }
        fn threads(&self) -> Vec<(String, String)> {
            vec![(self.thread.clone(), "the proposal".into())]
        }
    }

    /// A real TLS client that validates against our own root, and writes HTTP/1.1 by hand.
    struct TlsClient {
        config: Arc<rustls::ClientConfig>,
        port: u16,
    }

    impl TlsClient {
        fn new(ca_der: &[u8], port: u16) -> Self {
            let mut roots = rustls::RootCertStore::empty();
            roots
                .add(rustls::pki_types::CertificateDer::from(ca_der.to_vec()))
                .expect("our own root was refused by rustls as a root");
            let config = rustls::ClientConfig::builder()
                .with_root_certificates(roots)
                .with_no_client_auth();
            TlsClient { config: Arc::new(config), port }
        }

        /// One request, one response, one connection. Returns `(status, headers, body)`.
        ///
        /// **The handshake is the first assertion in this function**: the client validates our leaf
        /// against our root, for the server name `mm1.local`, with the connection made to
        /// 127.0.0.1. If the SAN, the extended key usage, the signature algorithm or the chain were
        /// wrong, this is where it would fail.
        fn request(
            &self,
            method: &str,
            path: &str,
            headers: &[(&str, &str)],
            body: &[u8],
        ) -> (u16, Vec<(String, String)>, Vec<u8>) {
            let server_name =
                rustls::pki_types::ServerName::try_from("mm1.local").unwrap().to_owned();
            let mut connection =
                rustls::ClientConnection::new(Arc::clone(&self.config), server_name).unwrap();
            let mut socket =
                std::net::TcpStream::connect((Ipv4Addr::LOCALHOST, self.port)).expect("connect");
            socket.set_read_timeout(Some(std::time::Duration::from_secs(20))).unwrap();
            let mut tls = rustls::Stream::new(&mut connection, &mut socket);

            let mut request = format!("{method} {path} HTTP/1.1\r\nHost: mm1.local\r\nConnection: close\r\n");
            for (name, value) in headers {
                request.push_str(&format!("{name}: {value}\r\n"));
            }
            request.push_str(&format!("Content-Length: {}\r\n\r\n", body.len()));
            tls.write_all(request.as_bytes()).expect("write request");
            tls.write_all(body).expect("write body");
            tls.flush().ok();

            let mut raw = Vec::new();
            // `Connection: close`, so the read ends when the server closes — no chunk parsing.
            let _ = tls.read_to_end(&mut raw);
            parse_response(&raw)
        }

        /// Open a stream and read whatever arrives within `wait`, then drop the connection.
        fn stream(&self, path: &str, wait: std::time::Duration) -> String {
            let server_name =
                rustls::pki_types::ServerName::try_from("mm1.local").unwrap().to_owned();
            let mut connection =
                rustls::ClientConnection::new(Arc::clone(&self.config), server_name).unwrap();
            let mut socket =
                std::net::TcpStream::connect((Ipv4Addr::LOCALHOST, self.port)).expect("connect");
            socket.set_read_timeout(Some(wait)).unwrap();
            let mut tls = rustls::Stream::new(&mut connection, &mut socket);
            let request = format!("GET {path} HTTP/1.1\r\nHost: mm1.local\r\nAccept: text/event-stream\r\n\r\n");
            tls.write_all(request.as_bytes()).expect("write request");
            tls.flush().ok();
            let mut raw = Vec::new();
            let deadline = std::time::Instant::now() + wait;
            let mut buffer = [0u8; 4096];
            while std::time::Instant::now() < deadline {
                match tls.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(n) => raw.extend_from_slice(&buffer[..n]),
                    Err(_) => break,
                }
            }
            String::from_utf8_lossy(&raw).to_string()
        }
    }

    fn parse_response(raw: &[u8]) -> (u16, Vec<(String, String)>, Vec<u8>) {
        let text = String::from_utf8_lossy(raw);
        let split = text.find("\r\n\r\n").unwrap_or(text.len());
        let head = &text[..split];
        let body = raw[(split + 4).min(raw.len())..].to_vec();
        let mut lines = head.lines();
        let status = lines
            .next()
            .and_then(|l| l.split_whitespace().nth(1))
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);
        let headers = lines
            .filter_map(|l| l.split_once(": "))
            .map(|(k, v)| (k.to_ascii_lowercase(), v.to_string()))
            .collect();
        (status, headers, body)
    }

    fn header_of<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
        headers.iter().find(|(k, _)| k == name).map(|(_, v)| v.as_str())
    }

    /// An ephemeral port pair, taken by binding and releasing — so the test never fights the
    /// shipped app for 8443.
    fn free_port_pair() -> (u16, u16) {
        let a = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let port = a.local_addr().unwrap().port();
        drop(a);
        let b = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let other = b.local_addr().unwrap().port();
        drop(b);
        (port, other)
    }

    /// **THE LIVE PROOF: this Mac, its real tailnet name, a publicly trusted certificate, and
    /// `curl` with no `-k` and no `--cacert`.**
    ///
    /// `#[ignore]` for the same reason the detection one is: its answer depends on somebody's
    /// Tailscale account, and a suite may not depend on that. Run it deliberately:
    ///
    /// ```text
    /// cargo test --bin richos-tauri phone::listen::tests::live -- --ignored --nocapture
    /// ```
    ///
    /// It SKIPS, loudly, on any state but `ready` — a proof that quietly passes on a Mac with no
    /// Tailscale would be worse than no proof. On a ready Mac it proves, in one run:
    ///
    /// 1. detection reports `ready` with the tailnet name;
    /// 2. `tailscale cert` hands over a chain and a key **through a pipe** — the key is never
    ///    written to disk, which is the whole reason `fetch_cert` asks for stdout;
    /// 3. the listener stands up on the tailnet address at the shipping port;
    /// 4. **curl, using the system trust store and nothing of ours, reaches it by NAME** — which
    ///    is the entire promise of this path, and the thing that deletes the sixteen taps;
    /// 5. the API layer answers over that origin, not just the static app;
    /// 6. the pairing URL a QR would carry is the tailnet origin.
    ///
    /// It binds the SHIPPING port, 8443, deliberately: an ephemeral port would prove a handshake
    /// and not the thing a phone will actually dial. So it refuses to run against a RichOS that is
    /// already serving, rather than fighting it for the socket.
    #[test]
    #[ignore = "depends on this machine's real Tailscale state; run with --ignored"]
    fn live_the_tailnet_name_is_served_with_a_publicly_trusted_certificate() {
        use crate::phone::tailnet;

        let (state, diagnostic) = tailnet::detect();
        println!("state      = {} {:?}", state.token(), diagnostic.map(|d| d.label()));
        let (Some(name), Some(origin)) = (state.name(), state.origin()) else {
            println!(
                "SKIPPED: this Mac is `{}`, not `ready`. Nothing to prove and nothing claimed.",
                state.token()
            );
            return;
        };
        println!("name       = {name}");
        println!("origin     = {origin}");
        println!("addresses  = {:?}", state.addresses());
        println!("account    = {:?}", state.account().map(|a| a.described()));
        println!("phone      = {:?}", state.phone());

        let cli = tailnet::find_cli().expect("ready with no command line is not a reachable state");
        let cert = tailnet::fetch_cert(&cli, name, super::super::TAILNET_MIN_VALIDITY)
            .expect("tailscale cert refused");
        println!(
            "cert       = {} certificate(s) in the chain, key is {}",
            cert.chain_der.len(),
            match cert.key {
                tailnet::KeyDer::Pkcs8(_) => "PKCS#8",
                tailnet::KeyDer::Sec1(_) => "SEC1 (`EC PRIVATE KEY`)",
            }
        );

        // --- the Mac, built the way `PhoneRuntime::start` builds it ---------------------------
        let dir = std::env::temp_dir().join(format!(
            "richos-phone-live-{}-{}",
            std::process::id(),
            super::super::now_millis()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let secrets = MemorySecrets::default();
        let names = LocalNames {
            host: "MM1".into(),
            bonjour: "mm1.local".into(),
            addresses: state.addresses().to_vec(),
        };
        let ca = PhoneCa::open(&dir, &secrets, names.clone()).unwrap();
        let profile = Arc::new(ca.mobileconfig());

        let mut spine = Spine::new(Ledger::open(dir.join("ledger.jsonl")).unwrap());
        spine.set_entity_registry(
            EntityRegistry::new(vec![
                Entity::new("femcboost", "FemcBoost", &["/fixture/femcboost"]).unwrap()
            ])
            .unwrap(),
        );
        let entity = EntityId::parse("femcboost").unwrap();
        let thread = spine.create_thread("the proposal", &entity).unwrap();
        spine.switch_thread(&thread).unwrap();
        spine.set_lease_factory(Box::new(MockLeaseFactory::new(vec!["On it!"])));
        let control = TurnControl::open(dir.join("intake.jsonl")).unwrap();
        spine.set_turn_control(control.clone());
        let hub = PhoneHub::new();
        spine.set_live_observer(Box::new(crate::phone::stream::PhoneLiveEmitter::new(
            Arc::clone(&hub),
        )));
        let spine = Arc::new(StdMutex::new(spine));

        let devices = Arc::new(DeviceDesk::open(&dir).unwrap());
        let vapid = crate::phone::push::VapidKey::generate().unwrap();
        let channel = Arc::new(Channel {
            devices: Arc::clone(&devices),
            api_base: Arc::new(ApiBaseDesk::home_only(origin.clone())),
            hub: Arc::clone(&hub),
            bridge: Arc::new(SpineBridge {
                spine: Arc::clone(&spine),
                control,
                thread: thread.clone(),
                entity,
            }) as Arc<dyn Bridge>,
            assets: crate::phone::assets::PhoneApp::embedded(),
            vapid_public: vapid.application_server_key(),
            fingerprint_hex: ca.fingerprint_hex(),
            pairing_path: std::sync::Mutex::new(crate::phone::device::PairedVia::HOME),
        });

        devices.open_pairing().unwrap();
        let code = devices.pairing_window().unwrap().code;
        let tls = tls_config_with_tailnet(
            &ca.leaf_der,
            &ca.leaf_key_pkcs8,
            Some((name.to_string(), cert.chain_der.clone(), cert.key.clone())),
        )
        .expect("rustls refused the tailnet certificate");

        let mut listener = match Listener::start(
            Arc::clone(&channel),
            tls,
            Arc::clone(&profile),
            state.addresses(),
            HTTPS_PORT,
            TRUST_PORT,
        ) {
            Ok(listener) => listener,
            Err(e) => {
                println!("SKIPPED: port {HTTPS_PORT} would not bind ({e}). Quit RichOS and retry.");
                let _ = std::fs::remove_dir_all(&dir);
                return;
            }
        };
        println!(
            "listening  = {}",
            listener.bound.iter().map(|a| a.to_string()).collect::<Vec<_>>().join(", ")
        );

        // --- curl, with NOTHING of ours in its trust store ------------------------------------
        //
        // No `--insecure`, no `--cacert`, no `--resolve`: the name is resolved by MagicDNS and the
        // certificate is validated against the system's own roots. If either half were missing
        // this would fail, which is exactly why it is the proof.
        let curl = |args: &[&str]| -> (String, String, bool) {
            let out = std::process::Command::new("/usr/bin/curl")
                .args(["--silent", "--show-error", "--max-time", "20"])
                .args(args)
                .output()
                .expect("curl did not run");
            (
                String::from_utf8_lossy(&out.stdout).to_string(),
                String::from_utf8_lossy(&out.stderr).to_string(),
                out.status.success(),
            )
        };

        let app_url = format!("{origin}/");
        let (body, stderr, ok) = curl(&[&app_url]);
        println!("GET {app_url} -> {} bytes, curl {}", body.len(), if ok { "ok" } else { "failed" });
        assert!(ok && stderr.is_empty(), "curl refused the public certificate or the name: {stderr}");
        assert!(
            body.contains("<script src=\"/app.js\""),
            "what was served over the tailnet name is not the phone app: {body}"
        );

        // AND THE API, not only the static app: an unsigned, unpaired POST is the one request the
        // channel answers without a credential, so it proves the route layer is reached.
        let phone = crate::phone::device::tests::Phone::new();
        let pair_body = serde_json::json!({
            "code": code,
            "public_key_jwk": phone.jwk(),
            "device_name": "the live proof",
        })
        .to_string();
        let pair_url = format!("{origin}/api/pair");
        let (body, stderr, ok) = curl(&[
            "-X",
            "POST",
            "-H",
            "Content-Type: application/json",
            "--data-binary",
            &pair_body,
            &pair_url,
        ]);
        println!("POST {pair_url} -> {body}");
        assert!(ok && stderr.is_empty(), "curl could not reach the API over the tailnet: {stderr}");
        let paired: Value = serde_json::from_str(&body).expect("the API did not answer JSON");
        assert!(paired.get("device_id").is_some(), "pairing over the tailnet was refused: {body}");

        // 6. AND THE CODE A QR WOULD CARRY IS THIS ORIGIN. Built the same way `status()` builds it.
        println!("pair url   = {origin}/#pair={code}");
        assert!(
            format!("{origin}/#pair={code}").starts_with(&format!("https://{name}:")),
            "the pairing URL is not the tailnet origin"
        );

        listener.stop();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_phone_pairs_posts_a_message_and_reads_richs_reply_over_real_tls() {
        // --- the Mac -------------------------------------------------------------------------
        let dir = std::env::temp_dir().join(format!(
            "richos-phone-e2e-{}-{}",
            std::process::id(),
            super::super::now_millis()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let secrets = MemorySecrets::default();
        let names = LocalNames {
            host: "MM1".into(),
            bonjour: "mm1.local".into(),
            addresses: vec![IpAddr::V4(Ipv4Addr::LOCALHOST)],
        };
        let ca = PhoneCa::open(&dir, &secrets, names.clone()).unwrap();
        let profile = Arc::new(ca.mobileconfig());

        let mut spine = Spine::new(Ledger::open(dir.join("ledger.jsonl")).unwrap());
        spine.set_entity_registry(
            EntityRegistry::new(vec![
                Entity::new("femcboost", "FemcBoost", &["/fixture/femcboost"]).unwrap()
            ])
            .unwrap(),
        );
        let entity = EntityId::parse("femcboost").unwrap();
        let thread = spine.create_thread("the proposal", &entity).unwrap();
        spine.switch_thread(&thread).unwrap();
        spine.set_lease_factory(Box::new(MockLeaseFactory::new(vec![
            "On it! The proposal is with legal.",
        ])));
        let control = TurnControl::open(dir.join("intake.jsonl")).unwrap();
        spine.set_turn_control(control.clone());

        let hub = PhoneHub::new();
        spine.set_live_observer(Box::new(crate::phone::stream::PhoneLiveEmitter::new(Arc::clone(&hub))));
        let spine = Arc::new(StdMutex::new(spine));

        let devices = Arc::new(DeviceDesk::open(&dir).unwrap());
        let vapid = crate::phone::push::VapidKey::generate().unwrap();
        let channel = Arc::new(Channel {
            devices: Arc::clone(&devices),
            api_base: Arc::new(ApiBaseDesk::home_only(names.origin())),
            hub: Arc::clone(&hub),
            bridge: Arc::new(SpineBridge {
                spine: Arc::clone(&spine),
                control,
                thread: thread.clone(),
                entity,
            }) as Arc<dyn Bridge>,
            assets: crate::phone::assets::PhoneApp::embedded(),
            vapid_public: vapid.application_server_key(),
            fingerprint_hex: ca.fingerprint_hex(),
            pairing_path: std::sync::Mutex::new(crate::phone::device::PairedVia::HOME),
        });

        devices.open_pairing().unwrap();
        let code = devices.pairing_window().unwrap().code;
        let tls = tls_config(&ca.leaf_der, &ca.leaf_key_pkcs8).unwrap();
        let (https_port, trust_port) = free_port_pair();
        let mut listener = Listener::start(
            Arc::clone(&channel),
            tls,
            Arc::clone(&profile),
            &[IpAddr::V4(Ipv4Addr::LOCALHOST)],
            https_port,
            trust_port,
        )
        .expect("the listener did not start");

        // --- the phone -----------------------------------------------------------------------
        let client = TlsClient::new(&ca.ca_der, https_port);
        let phone = crate::phone::device::tests::Phone::new();

        // 0. THE APP LOADS — and it is numbered zero because it happens before everything else
        //    below it: the phone fetches the app in order to have a pairing screen at all.
        //
        //    THIS IS THE STEP THE CHANNEL HAD NEVER HAD, and its absence is what let a bundle
        //    ship with no phone app in it for a day. The channel here is built with
        //    `PhoneApp::embedded()` — the real table this build compiled in, not a fixture — so
        //    a build that embedded nothing, or embedded the wrong bytes, fails right here over
        //    a real TLS socket.
        let (status, headers, body) = client.request("GET", "/", &[], b"");
        assert_eq!(status, 200, "the phone app did not load: {}", String::from_utf8_lossy(&body));
        assert_eq!(header_of(&headers, "content-type"), Some("text/html; charset=utf-8"));
        let shell = String::from_utf8_lossy(&body).into_owned();
        assert!(shell.contains("<script src=\"/app.js\""), "what loaded is not the phone app: {shell}");
        for (path, content_type) in [
            ("/app.js", "text/javascript; charset=utf-8"),
            ("/sw.js", "text/javascript; charset=utf-8"),
            ("/styles.css", "text/css; charset=utf-8"),
            ("/manifest.webmanifest", "application/manifest+json"),
            ("/icons/icon-192.png", "image/png"),
        ] {
            let (status, headers, body) = client.request("GET", path, &[], b"");
            assert_eq!(status, 200, "{path} is not served");
            assert_eq!(header_of(&headers, "content-type"), Some(content_type), "{path}");
            assert!(!body.is_empty(), "{path} was served empty");
        }
        // And nothing that is not the app, over the same socket.
        for path in ["/README.md", "/package.json", "/test/api.test.js", "/../private.txt"] {
            let (status, _h, _b) = client.request("GET", path, &[], b"");
            assert_eq!(status, 404, "{path} was served");
        }

        // 1. PAIR. No signature: this is the request that establishes the credential.
        let pair_body = serde_json::json!({
            "code": code,
            "public_key_jwk": phone.jwk(),
            "device_name": "iPhone",
        })
        .to_string();
        let (status, _headers, body) = client.request(
            "POST",
            "/api/pair",
            &[("Content-Type", "application/json")],
            pair_body.as_bytes(),
        );
        assert_eq!(status, 200, "pairing: {}", String::from_utf8_lossy(&body));
        let paired: Value = serde_json::from_slice(&body).unwrap();
        let device_id = paired["device_id"].as_str().unwrap().to_string();
        let mut challenge = paired["challenge"].as_str().unwrap().to_string();
        assert_eq!(paired["ca_fingerprint_sha256"], ca.fingerprint_hex());
        assert_eq!(paired["api_base"], names.origin());

        // 2. AN UNPAIRED CALLER STILL SEES NOTHING, over the same real socket. The positive
        //    control for every 404 in the unit tests, asserted against the wire this time.
        let (status, _h, body) = client.request("POST", "/api/messages", &[], b"{}");
        assert_eq!(status, 404, "an unsigned POST was answered");
        assert!(body.is_empty(), "a refusal carried a body: {}", String::from_utf8_lossy(&body));

        // 3. POST HIS WORDS, signed exactly as `web/web-app/lib/api.js` signs them.
        let words = "where are we on the proposal?";
        let message_body = serde_json::json!({
            "client_id": "01JE2E",
            "thread_id": thread,
            "kind": "text",
            "text": words,
            "sent_at": "2026-09-18T13:00:00.000Z",
        })
        .to_string();
        let signature = super::super::b64url(&phone.sign(&signing_string(
            &challenge,
            "POST",
            "/api/messages",
            message_body.as_bytes(),
        )));
        let authorization = format!("RichOS-Device {device_id}.{challenge}.{signature}");
        let (status, headers, body) = client.request(
            "POST",
            "/api/messages",
            &[("Content-Type", "application/json"), ("Authorization", &authorization)],
            message_body.as_bytes(),
        );
        assert_eq!(status, 200, "posting: {}", String::from_utf8_lossy(&body));
        let accepted: Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(accepted["duplicate"], false);
        assert!(accepted["message_id"].as_str().unwrap().starts_with("intake_"));
        // EVERY response carries the next challenge, which is why there is no challenge route.
        challenge = header_of(&headers, "x-richos-challenge").expect("no challenge header").to_string();

        // 4. THE WORDS REACH THE LEDGER AS HIS OWN, and the turn runs. The drain is on its own
        //    thread, so this waits for the ledger rather than for the response.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
        let mut seen = Vec::new();
        while std::time::Instant::now() < deadline {
            {
                let guard = spine.lock().unwrap();
                let binding = guard.ledger().thread_binding(&thread).unwrap();
                seen = guard
                    .ledger()
                    .thread_turns_scoped(&binding)
                    .unwrap()
                    .into_iter()
                    .filter(|t| t.source == richos_core::ledger::Source::Text)
                    .map(|t| t.user_text.clone())
                    .collect();
            }
            if !seen.is_empty() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(25));
        }
        assert_eq!(seen, vec![words.to_string()], "his words did not reach the ledger");

        // 5. THE STREAM CARRIES RICH'S REPLY. A fresh ticket, and a real SSE read.
        let stream_path = format!("/api/events?thread_id={thread}");
        let stream_sig = super::super::b64url(&phone.sign(&signing_string(
            &challenge,
            "GET",
            &stream_path,
            b"",
        )));
        let stream_auth = format!("RichOS-Device {device_id}.{challenge}.{stream_sig}")
            .replace(' ', "%20");
        let wire = client.stream(
            &format!("{stream_path}&auth={stream_auth}"),
            std::time::Duration::from_secs(3),
        );
        assert!(wire.contains("200 OK"), "the stream was refused: {wire}");
        assert!(wire.contains("text/event-stream"), "{wire}");
        assert!(wire.contains("event: hello"), "no hello on the stream: {wire}");
        assert!(
            wire.contains("On it! The proposal is with legal."),
            "Rich's reply is not on the stream: {wire}"
        );
        assert!(wire.contains(words), "his own words are not on the stream: {wire}");

        // 6. THE TRUST ENDPOINT serves exactly one file, in the clear, on the neighboring port.
        let mut plain = std::net::TcpStream::connect((Ipv4Addr::LOCALHOST, trust_port)).unwrap();
        plain.set_read_timeout(Some(std::time::Duration::from_secs(5))).unwrap();
        plain
            .write_all(b"GET /ca HTTP/1.1\r\nHost: mm1.local\r\nConnection: close\r\n\r\n")
            .unwrap();
        let mut raw = Vec::new();
        let _ = plain.read_to_end(&mut raw);
        let (status, headers, body) = parse_response(&raw);
        assert_eq!(status, 200);
        assert_eq!(header_of(&headers, "content-type"), Some("application/x-apple-aspen-config"));
        assert!(String::from_utf8_lossy(&body).contains("com.apple.security.root"));

        // 7. AND NOTHING ELSE ON THAT PORT.
        let mut plain = std::net::TcpStream::connect((Ipv4Addr::LOCALHOST, trust_port)).unwrap();
        plain.set_read_timeout(Some(std::time::Duration::from_secs(5))).unwrap();
        plain
            .write_all(b"GET /ca.crt HTTP/1.1\r\nHost: mm1.local\r\nConnection: close\r\n\r\n")
            .unwrap();
        let mut raw = Vec::new();
        let _ = plain.read_to_end(&mut raw);
        assert_eq!(parse_response(&raw).0, 404);

        // 8. STOPPING THE CHANNEL FREES THE PORT. "Off means no socket, not a closed door" — the
        //    proof is that the port can be bound again the instant `stop()` returns.
        listener.stop();
        assert!(
            std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, https_port)).is_ok(),
            "the port was still held after stop() returned"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }


    // -----------------------------------------------------------------------------------
    // THE SAME THING AGAIN, WITH AN OUTSIDE CLIENT
    // -----------------------------------------------------------------------------------
    //
    // The test above uses `rustls` as the client, which is the same TLS implementation the server
    // uses. That is a strong test of the routes and a WEAK test of the certificate: an
    // implementation agreeing with itself is the one class of certificate defect a self-test
    // cannot find.
    //
    // So this does it again with **`/usr/bin/curl`** — a different TLS stack (SecureTransport /
    // LibreSSL on this Mac), a different X.509 parser, and a different name-verification
    // implementation, validating our leaf against our root **by name** with `--resolve`. If our
    // certificate were acceptable only to rustls, this is where that shows up.
    //
    // `curl` is on every Mac, so this is not a fragile dependency and the test is not skipped.
    // `--resolve` points the real name at loopback, so nothing touches the LAN and nothing fights
    // the shipped app for port 8443.

    #[test]
    fn curl_a_different_tls_stack_entirely_accepts_our_certificate_and_our_routes() {
        let dir = std::env::temp_dir().join(format!(
            "richos-phone-curl-{}-{}",
            std::process::id(),
            super::super::now_millis()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let secrets = MemorySecrets::default();
        let names = LocalNames {
            host: "MM1".into(),
            bonjour: "mm1.local".into(),
            addresses: vec![IpAddr::V4(Ipv4Addr::LOCALHOST)],
        };
        let ca = PhoneCa::open(&dir, &secrets, names.clone()).unwrap();
        let ca_path = dir.join("phone/ca.crt");
        let profile = Arc::new(ca.mobileconfig());

        let mut spine = Spine::new(Ledger::open(dir.join("ledger.jsonl")).unwrap());
        spine.set_entity_registry(
            EntityRegistry::new(vec![
                Entity::new("femcboost", "FemcBoost", &["/fixture/femcboost"]).unwrap()
            ])
            .unwrap(),
        );
        let entity = EntityId::parse("femcboost").unwrap();
        let thread = spine.create_thread("the proposal", &entity).unwrap();
        spine.switch_thread(&thread).unwrap();
        spine.set_lease_factory(Box::new(MockLeaseFactory::new(vec!["Legal has it. Two days."])));
        let control = TurnControl::open(dir.join("intake.jsonl")).unwrap();
        spine.set_turn_control(control.clone());
        let hub = PhoneHub::new();
        spine.set_live_observer(Box::new(crate::phone::stream::PhoneLiveEmitter::new(Arc::clone(&hub))));
        let spine = Arc::new(StdMutex::new(spine));

        let devices = Arc::new(DeviceDesk::open(&dir).unwrap());
        let vapid = crate::phone::push::VapidKey::generate().unwrap();
        let channel = Arc::new(Channel {
            devices: Arc::clone(&devices),
            api_base: Arc::new(ApiBaseDesk::home_only(names.origin())),
            hub: Arc::clone(&hub),
            bridge: Arc::new(SpineBridge {
                spine: Arc::clone(&spine),
                control,
                thread: thread.clone(),
                entity,
            }) as Arc<dyn Bridge>,
            assets: crate::phone::assets::PhoneApp::embedded(),
            vapid_public: vapid.application_server_key(),
            fingerprint_hex: ca.fingerprint_hex(),
            pairing_path: std::sync::Mutex::new(crate::phone::device::PairedVia::HOME),
        });
        devices.open_pairing().unwrap();
        let code = devices.pairing_window().unwrap().code;
        let tls = tls_config(&ca.leaf_der, &ca.leaf_key_pkcs8).unwrap();
        let (https_port, trust_port) = free_port_pair();
        let mut listener = Listener::start(
            Arc::clone(&channel),
            tls,
            Arc::clone(&profile),
            &[IpAddr::V4(Ipv4Addr::LOCALHOST)],
            https_port,
            trust_port,
        )
        .unwrap();

        let base = format!("https://mm1.local:{https_port}");
        let resolve = format!("mm1.local:{https_port}:127.0.0.1");
        let curl = |args: &[&str]| -> (String, String) {
            let out = std::process::Command::new("/usr/bin/curl")
                .args(["--silent", "--show-error", "--cacert", ca_path.to_str().unwrap()])
                .args(args)
                .output()
                .expect("curl did not run");
            (
                String::from_utf8_lossy(&out.stdout).to_string(),
                String::from_utf8_lossy(&out.stderr).to_string(),
            )
        };

        // 1. PAIR. No `--insecure` anywhere in this test: curl is validating our leaf against our
        //    root, for the name `mm1.local`, with its own X.509 code.
        let phone = crate::phone::device::tests::Phone::new();
        let pair_body = serde_json::json!({
            "code": code,
            "public_key_jwk": phone.jwk(),
            "device_name": "curl",
        })
        .to_string();
        let (stdout, stderr) = curl(&[
            "--resolve",
            &resolve,
            "-X",
            "POST",
            "-H",
            "Content-Type: application/json",
            "--data-binary",
            &pair_body,
            &format!("{base}/api/pair"),
        ]);
        assert!(stderr.is_empty(), "curl refused our certificate or our server: {stderr}");
        let paired: Value = serde_json::from_str(&stdout)
            .unwrap_or_else(|e| panic!("pairing answered {stdout:?}: {e}"));
        let device_id = paired["device_id"].as_str().unwrap().to_string();
        let challenge = paired["challenge"].as_str().unwrap().to_string();

        // 2. POST HIS WORDS, signed.
        let words = "curl asking after the proposal";
        let body = serde_json::json!({
            "client_id": "01JCURL",
            "thread_id": thread,
            "kind": "text",
            "text": words,
            "sent_at": "2026-09-18T13:00:00.000Z",
        })
        .to_string();
        let signature = super::super::b64url(&phone.sign(&signing_string(
            &challenge,
            "POST",
            "/api/messages",
            body.as_bytes(),
        )));
        let authorization = format!("RichOS-Device {device_id}.{challenge}.{signature}");
        let (stdout, stderr) = curl(&[
            "--resolve",
            &resolve,
            "-X",
            "POST",
            "-H",
            "Content-Type: application/json",
            "-H",
            &format!("Authorization: {authorization}"),
            "--data-binary",
            &body,
            &format!("{base}/api/messages"),
        ]);
        assert!(stderr.is_empty(), "{stderr}");
        let accepted: Value =
            serde_json::from_str(&stdout).unwrap_or_else(|e| panic!("posting answered {stdout:?}: {e}"));
        assert_eq!(accepted["duplicate"], false, "{stdout}");

        // 3. HIS WORDS REACH THE LEDGER.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
        let mut landed = false;
        while std::time::Instant::now() < deadline && !landed {
            {
                let guard = spine.lock().unwrap();
                let binding = guard.ledger().thread_binding(&thread).unwrap();
                landed = guard
                    .ledger()
                    .thread_turns_scoped(&binding)
                    .unwrap()
                    .iter()
                    .any(|t| t.user_text == words);
            }
            if !landed {
                std::thread::sleep(std::time::Duration::from_millis(25));
            }
        }
        assert!(landed, "his words did not reach the ledger");

        // 4. AN UNSIGNED CALLER GETS 404 WITH NOTHING IN IT, as seen by an outside client.
        let (stdout, stderr) = curl(&[
            "--resolve",
            &resolve,
            "-o",
            "/dev/null",
            "-w",
            "%{http_code} %{size_download}",
            "-X",
            "POST",
            "--data-binary",
            "{}",
            &format!("{base}/api/messages"),
        ]);
        assert!(stderr.is_empty(), "{stderr}");
        assert_eq!(stdout.trim(), "404 0", "an unsigned POST was answered: {stdout}");

        // 5. THE PROFILE, off the plain-HTTP neighbor, with Apple's own content type.
        let (stdout, stderr) = curl(&[
            "--resolve",
            &format!("mm1.local:{trust_port}:127.0.0.1"),
            "-o",
            "/dev/null",
            "-w",
            "%{http_code} %{content_type}",
            &format!("http://mm1.local:{trust_port}/ca"),
        ]);
        assert!(stderr.is_empty(), "{stderr}");
        assert_eq!(stdout.trim(), "200 application/x-apple-aspen-config", "{stdout}");

        listener.stop();
        let _ = std::fs::remove_dir_all(&dir);
    }

}
