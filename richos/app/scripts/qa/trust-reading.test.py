#!/usr/bin/env python3
"""No phone needed: `rios device trust` reads one launch's log lines into the right cause.

The lines are written here in the shape iOS 26 logs them (hand-made, no phone's log is copied)."""
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("phone_ios", Path(__file__).with_name("phone-ios.py"))
phone_ios = importlib.util.module_from_spec(spec)
spec.loader.exec_module(phone_ios)

T = "Oct  1 10:00:00.000000 "
REFUSED = T + "SpringBoard(FrontBoardServices)[1] <Notice>: [dev.example - signature state: Profile Needs Network Validation, reason: Requires Network Validation"
SENT = T + "online-auth-agent[2] <Notice>: Sending request for AAAA=, 0000"
SERVER = T + ("mDNSResponder[3] <Notice>: [R1->Q1] Question for <mask.hash: 'x'> (A) assigned DNS service -- id: 9, "
              "type: Do53, source: sc, scope: none, interface: en0/12, servers: {<IPv4:x>:53}")
UNANSWERED = T + "mDNSResponder[3] <Info>: [Q1] Penalizing unresponsive server <IPv4:x> for 60 seconds -- symptom report: reported"
STALL = T + "online-auth-agent(Network)[2] <Info>: nw_connection_report_symptom_on_nw_queue [C1] reported DNS stall symptom"
TIMEOUT = T + "online-auth-agent(CFNetwork)[2] <Error>: Task <A>.<1> finished with error [-1001] Error Domain=NSURLErrorDomain Code=-1001"
OFFLINE = T + "online-auth-agent(CFNetwork)[2] <Error>: Task <A>.<1> finished with error [-1009] Error Domain=NSURLErrorDomain Code=-1009"
VPN_OFF = T + ("nesessionmanager[4] <Notice>: NESMVPNSession[Primary Tunnel:Tailscale:0000:(null)]: "
               "handleChangeEventForRankedInterfaces - stopped 1 status disconnected includeAllNetworks 0")
VPN_ON = VPN_OFF.replace("status disconnected", "status connected")


class TrustReading(unittest.TestCase):
    def test_unanswered_dns_is_named_as_the_cause(self):
        r = phone_ios.trust_reading([REFUSED, SENT, SERVER, UNANSWERED, STALL, TIMEOUT, VPN_OFF])
        self.assertEqual(r["signatureState"], "Profile Needs Network Validation")
        self.assertEqual(r["dns"], {"type": "Do53", "source": "sc", "interface": "en0/12"})
        self.assertEqual(r["verifyErrors"], [-1001])
        self.assertEqual(r["vpn"], {"Tailscale": "disconnected"})
        self.assertIn("DNS server", r["cause"])
        self.assertIn("en0", r["cause"])

    def test_a_connected_vpn_is_named_before_dns(self):
        r = phone_ios.trust_reading([REFUSED, SENT, SERVER, UNANSWERED, STALL, TIMEOUT, VPN_ON])
        self.assertIn("VPN is up (Tailscale)", r["cause"])

    def test_no_connection(self):
        r = phone_ios.trust_reading([REFUSED, SENT, OFFLINE])
        self.assertIn("-1009", r["cause"])

    def test_refusal_without_a_request_names_the_signature_state(self):
        r = phone_ios.trust_reading([REFUSED])
        self.assertEqual(r["cause"], "iOS refused the launch: Profile Needs Network Validation")

    def test_no_measurement_is_never_a_claim_about_the_internet(self):
        none = phone_ios.net_reading([])
        self.assertEqual((none["tcpConnected"], none["tcpTimedOut"], none["reached"]), (0, 0, False))
        for path_ok in (False, True):
            v = phone_ios.net_verdict(path_ok, none)
            self.assertIn("not measured", v)
            self.assertNotIn("time out", v)
            self.assertNotIn("reaches the internet", v)
            self.assertNotIn("carries no traffic", v)

    def test_the_kept_lines_include_the_resolver_verdicts_and_not_other_resolver_noise(self):
        keep = phone_ios.TRUST_KEEP.search
        for line in (REFUSED, SENT, SERVER, UNANSWERED, STALL, TIMEOUT, VPN_OFF):
            self.assertTrue(keep(line), line)
        self.assertFalse(keep(T + "mDNSResponder[3] <Notice>: [Q(a, b)] Sent a previous IPv4 mDNS query over multicast"))


# `rios device net`: Safari's TCP outcomes and the phone's own Wi-Fi link report, in the shapes iOS 26 logs them.
CONNECT_TIMEOUT = T + ("MobileSafari(Network)[5] <Notice>: [C1.1.2.1 IPv4#a:443 failed channel-flow ] "
                       "event: flow:failed_connect @8.876s, error Operation timed out")
CONNECTED = T + "MobileSafari(Network)[5] <Notice>: [C2 IPv4#b:443 ready channel-flow ] event: flow:finish_connect @0.040s"
NO_ROUTE = T + ("MobileSafari(Network)[5] <Notice>: [C1 Hostname#c:443 in_progress parent-flow (unsatisfied "
                "(No network route))] event: flow:start_connect @0.001s")
TUNNEL = T + ("mobile_storage_proxy(Network)[7] <Notice>: [C54 IPv6#a.1 ready socket-flow (satisfied (Path is "
              "satisfied), viable, interface: utun4, scoped, ipv6)] event: flow:finish_connect @0.002s")
CABLE_TIMEOUT = T + ("MobileSafari(Network)[5] <Notice>: [C3.1.1 IPv4#d:443 failed channel-flow (satisfied (Path is "
                     "satisfied), viable, interface: en2, ipv4, dns)] event: flow:failed_connect @8.684s, error Operation timed out")
RANK_CABLE = T + "configd[8] <Info>: 0. en2 serviceID=SVC-CABLE addr=192.168.2.2 rank=0x1000001"
RANK_WIFI = T + "configd[8] <Info>: 1. en0 serviceID=SVC-WIFI addr=192.168.1.9 rank=0x1000002"
ELECTED = T + "configd[8] <Info>: SVC-CABLE is still primary IPv4"
LINK = T + ("wifid[6]<Notice>: __WiFiLQAMgrLogStats(<redacted>:Stationary): InfraUptime:1926.4secs Channel: 44 "
            "Bandwidth: 80Mhz Rssi: -60 {-60 -67} Cca: 56 (S:0 O:2 I:53) Snr: 12 BcnPer: 26.5% (49, 60.9%) TxFrameCnt: 41")


class NetReading(unittest.TestCase):
    def test_timed_out_connects_are_not_reached(self):
        r = phone_ios.net_reading([CONNECT_TIMEOUT, UNANSWERED, LINK])
        self.assertFalse(r["reached"])
        self.assertEqual((r["tcpTimedOut"], r["dnsServerUnanswered"]), (1, 1))
        self.assertEqual(r["wifiLink"], {"joinedSeconds": 1926.4, "channel": 44, "rssi": -60, "snr": 12,
                                         "beaconLossPercent": 26.5})

    def test_a_completed_connect_is_reached(self):
        self.assertTrue(phone_ios.net_reading([CONNECT_TIMEOUT, CONNECTED])["reached"])

    def test_no_route_is_counted(self):
        r = phone_ios.net_reading([NO_ROUTE, NO_ROUTE])
        self.assertEqual((r["noNetworkRoute"], r["reached"], r["wifiLink"]), (2, False, None))

    def test_verdicts(self):
        dead = phone_ios.net_reading([CONNECT_TIMEOUT])
        live = phone_ios.net_reading([CONNECTED])
        self.assertIn("carries no traffic", phone_ios.net_verdict(False, dead))
        self.assertIn("carries traffic", phone_ios.net_verdict(True, live))
        self.assertIn("did not complete", phone_ios.net_verdict(True, dead))
        self.assertIn("not joined to Wi-Fi", phone_ios.net_verdict(False, phone_ios.net_reading([NO_ROUTE])))

    def test_the_kept_lines(self):
        keep = phone_ios.NET_KEEP.search
        for line in (CONNECT_TIMEOUT, CONNECTED, NO_ROUTE, LINK, UNANSWERED, RANK_CABLE, RANK_WIFI, ELECTED):
            self.assertTrue(keep(line), line)
        self.assertFalse(keep(T + "wifid[6] <Notice>: WiFiManagerGetUserAutoJoinState: user auto join state 1"))

    def test_the_developer_tunnel_is_not_the_internet(self):
        # 2026-10-03: devicectl's own services connected to this Mac over the developer tunnel while every
        # internet connect timed out, and the old count called that "reached".
        r = phone_ios.net_reading([TUNNEL, TUNNEL, CABLE_TIMEOUT])
        self.assertFalse(r["reached"])
        self.assertEqual(r["tcpConnected"], 0)
        self.assertEqual(r["notInternet"], {"mobile_storage_proxy via utun4": 2})
        self.assertEqual(r["timedOutVia"], {"en2": 1})

    def test_the_primary_route_over_the_cable_is_named(self):
        leases = "{\n\tname=phone\n\tip_address=192.168.2.2\n\tlease=0x1\n}\n"
        r = phone_ios.net_reading([RANK_CABLE, RANK_WIFI, ELECTED, CABLE_TIMEOUT], leases)
        self.assertEqual(r["primary"], {"interface": "en2", "address": "192.168.2.2", "wifi": False,
                                        "leasedByThisMac": True})
        v = phone_ios.net_verdict(False, r)
        self.assertIn("over en2 (192.168.2.2), the cable to this Mac", v)
        self.assertIn("timed out", v)
        self.assertNotIn("Wi-Fi carries no traffic", v)

    def test_a_wifi_primary_keeps_the_wifi_verdicts(self):
        elected_wifi = ELECTED.replace("SVC-CABLE", "SVC-WIFI")
        r = phone_ios.net_reading([RANK_CABLE, RANK_WIFI, elected_wifi, CONNECTED])
        self.assertEqual(r["primary"]["interface"], "en0")
        self.assertIn("carries traffic", phone_ios.net_verdict(True, r))


if __name__ == "__main__":
    unittest.main()
