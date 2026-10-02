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

    def test_the_kept_lines_include_the_resolver_verdicts_and_not_other_resolver_noise(self):
        keep = phone_ios.TRUST_KEEP.search
        for line in (REFUSED, SENT, SERVER, UNANSWERED, STALL, TIMEOUT, VPN_OFF):
            self.assertTrue(keep(line), line)
        self.assertFalse(keep(T + "mDNSResponder[3] <Notice>: [Q(a, b)] Sent a previous IPv4 mDNS query over multicast"))


if __name__ == "__main__":
    unittest.main()
