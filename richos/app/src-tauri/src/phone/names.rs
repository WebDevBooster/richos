//! **THE NAME AND THE ADDRESSES THE MAC ALREADY HAS** — plan §2.1, *"use the one macOS
//! already publishes, not one we invent"*.
//!
//! `scutil --get LocalHostName` returns the name mDNSResponder already publishes for free.
//! It follows the Mac across DHCP leases and Wi-Fi networks, and iOS resolves `.local` names
//! through Bonjour by construction (RFC 6762). Measured on this Mac while writing this:
//! `MM1`, resolving to `192.168.1.249`.
//!
//! **`richos.local` is deferred, with its price stated** (plan §2.1): publishing an extra
//! `.local` address record means either FFI to `DNSServiceRegisterRecord` or a new mDNS
//! crate, PLUS `NSLocalNetworkUsageDescription` and a local-network permission prompt on
//! macOS 15 and later. The Mac's own name needs none of that, because we are not the ones
//! publishing it. It buys exactly one thing: the origin surviving him renaming his Mac.
//!
//! # Why the addresses are read out of `ifconfig` rather than `getifaddrs`
//!
//! `getifaddrs` is the right call and it is `unsafe` FFI plus a `libc` direct dependency.
//! This module needs the list for two things — the leaf's SAN set and which sockets to bind
//! — and both are start-up work that runs once. **Parsing a stable text format at start-up
//! is a smaller risk than thirty lines of pointer walking in a process that also holds the
//! CEO's conversation.** If this ever moves into a hot path, that trade flips.
//!
//! The format, taken from the machine rather than from memory:
//!
//! ```text
//! en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
//! 	inet 192.168.1.249 netmask 0xffffff00 broadcast 192.168.1.255
//! ```

use super::PhoneError;
use std::net::{IpAddr, Ipv4Addr};
use std::process::Command;

/// What this Mac calls itself and where it can currently be reached.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalNames {
    /// `MM1` — the bare `LocalHostName`, used for the display name "RichOS on MM1".
    pub host: String,
    /// `mm1.local` — the Bonjour name, and the origin's host. Lowercase, because a
    /// certificate's DNS SAN is matched case-insensitively but an ORIGIN string is compared
    /// byte for byte by the browser, and two spellings would be two origins.
    pub bonjour: String,
    /// Every IPv4 address this Mac currently answers on, loopback first.
    ///
    /// **Loopback is deliberately included.** It is how a developer, or the verification
    /// record this slice ships, reaches the listener with `curl` without going near the
    /// LAN. It is not a shortcut to `0.0.0.0` — every address here is one the machine
    /// told us about by name.
    ///
    /// IPv6 is deliberately absent in this slice: it is a later provider behind the
    /// reachability seam (plan §10.3), and a SAN for an address nothing uses is a SAN that
    /// only widens the certificate.
    pub addresses: Vec<IpAddr>,
}

impl LocalNames {
    /// The certificate's display name: **"RichOS on MM1"** (plan §2.1). It used to be the
    /// name he read off his phone after installing a profile; nothing installs one now
    /// (CEO §61), so it is what a person sees if they ever inspect the certificate itself.
    pub fn display_name(&self) -> String {
        format!("RichOS on {}", self.host)
    }

    // THE LOCAL-NETWORK ORIGIN IS GONE — CEO §61, 2026-09-19. `origin()` built
    // `https://<bonjour>:8443`, the address the pairing code went out under before the Tailscale
    // path existed and the fallback `start` swapped in when the tailnet addresses would not
    // bind. The origin the phone holds is `tailnet::TailnetState::origin` and nothing else, so
    // this had no caller left but its own test — and a helper kept alive by its own test is the
    // shape a removed path comes back through.
    //
    // The name it was built from is still here, because the LEAF is: `bonjour` is the DNS name
    // in `san_list`, and that certificate is what this listener presents to anything that
    // reaches a bound socket without asking for the tailnet name.

    /// Everything the leaf certificate must cover, in the order the extension file wants
    /// them: the DNS name first, then each address.
    pub fn san_list(&self) -> Vec<String> {
        let mut out = vec![format!("DNS:{}", self.bonjour)];
        for a in &self.addresses {
            out.push(format!("IP:{a}"));
        }
        out
    }

}

/// Read the name and the addresses off this machine.
pub fn read() -> Result<LocalNames, PhoneError> {
    let host = scutil_local_host_name()?;
    let addresses = ipv4_addresses(&ifconfig()?);
    Ok(LocalNames { bonjour: format!("{}.local", host.to_lowercase()), host, addresses })
}

fn scutil_local_host_name() -> Result<String, PhoneError> {
    let out = Command::new("/usr/sbin/scutil")
        .arg("--get")
        .arg("LocalHostName")
        .output()
        .map_err(|e| PhoneError::Tool { tool: "scutil".into(), detail: e.to_string() })?;
    if !out.status.success() {
        return Err(PhoneError::Tool {
            tool: "scutil".into(),
            detail: String::from_utf8_lossy(&out.stderr).trim().to_string(),
        });
    }
    let name = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if name.is_empty() {
        // A Mac with no LocalHostName has no Bonjour name, so there is no origin to offer
        // and the honest answer is to say so rather than to invent one.
        return Err(PhoneError::Malformed(
            "this Mac publishes no local host name, so there is no address the phone could use".into(),
        ));
    }
    Ok(name)
}

fn ifconfig() -> Result<String, PhoneError> {
    let out = Command::new("/sbin/ifconfig")
        .arg("-a")
        .output()
        .map_err(|e| PhoneError::Tool { tool: "ifconfig".into(), detail: e.to_string() })?;
    if !out.status.success() {
        return Err(PhoneError::Tool {
            tool: "ifconfig".into(),
            detail: String::from_utf8_lossy(&out.stderr).trim().to_string(),
        });
    }
    Ok(String::from_utf8_lossy(&out.stdout).to_string())
}

/// Pull every usable IPv4 address out of `ifconfig -a` output. Separated from the command
/// so the parser is testable against captured output rather than against whatever network
/// the test machine happens to be on.
pub fn ipv4_addresses(ifconfig_output: &str) -> Vec<IpAddr> {
    let mut loopback: Vec<IpAddr> = Vec::new();
    let mut lan: Vec<IpAddr> = Vec::new();
    for line in ifconfig_output.lines() {
        let line = line.trim();
        let Some(rest) = line.strip_prefix("inet ") else { continue };
        let Some(text) = rest.split_whitespace().next() else { continue };
        let Ok(addr) = text.parse::<Ipv4Addr>() else { continue };
        // A link-local address means "this interface never got a lease". Nothing reaches
        // the Mac there, so a SAN for it is a certificate that claims more than it serves.
        if addr.is_link_local() || addr.is_unspecified() || addr.is_broadcast() {
            continue;
        }
        let ip = IpAddr::V4(addr);
        if addr.is_loopback() {
            if !loopback.contains(&ip) {
                loopback.push(ip);
            }
        } else if !lan.contains(&ip) {
            lan.push(ip);
        }
    }
    loopback.extend(lan);
    loopback
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Captured from this Mac with `/sbin/ifconfig -a` while writing this module, trimmed to
    /// the lines the parser looks at plus enough noise to prove it ignores the rest.
    const CAPTURED: &str = "\
lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
\toptions=1203<RXCSUM,TXCSUM,TXSTATUS,SW_TIMESTAMP>
\tinet 127.0.0.1 netmask 0xff000000
\tinet6 ::1 prefixlen 128
gif0: flags=8010<POINTOPOINT,MULTICAST> mtu 1280
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
\tinet 192.168.1.249 netmask 0xffffff00 broadcast 192.168.1.255
\tinet6 fe80::1cb:4b1:1234:5678%en0 prefixlen 64 secured scopeid 0xc
en5: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
\tinet 169.254.191.22 netmask 0xffff0000 broadcast 169.254.255.255
awdl0: flags=8822<BROADCAST,SMART,SIMPLEX,MULTICAST> mtu 1500
";

    #[test]
    fn the_parser_finds_the_lan_address_and_puts_loopback_first() {
        let found = ipv4_addresses(CAPTURED);
        assert_eq!(
            found,
            vec![
                IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1)),
                IpAddr::V4(Ipv4Addr::new(192, 168, 1, 249)),
            ]
        );
    }

    #[test]
    fn a_link_local_address_is_not_a_place_the_phone_can_reach() {
        // POSITIVE CONTROL in the same assertion: 192.168.1.249 IS in the list above, and
        // 169.254.191.22 — an interface that never got a lease — is not. If the filter were
        // inverted, the first assertion would fail rather than this one passing quietly.
        let found = ipv4_addresses(CAPTURED);
        assert!(found.contains(&IpAddr::V4(Ipv4Addr::new(192, 168, 1, 249))));
        assert!(!found.iter().any(|a| a.to_string().starts_with("169.254.")));
    }

    #[test]
    fn inet6_lines_are_ignored_in_this_slice() {
        assert!(ipv4_addresses(CAPTURED).iter().all(|a| a.is_ipv4()));
    }

    #[test]
    fn the_names_the_phone_holds_are_built_once_and_spelled_one_way() {
        let names = LocalNames {
            host: "MM1".into(),
            bonjour: "mm1.local".into(),
            addresses: vec![IpAddr::V4(Ipv4Addr::new(192, 168, 1, 249))],
        };
        assert_eq!(names.display_name(), "RichOS on MM1");
        assert_eq!(names.san_list(), vec!["DNS:mm1.local", "IP:192.168.1.249"]);
    }

}
