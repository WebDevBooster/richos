# Escalation: The openssl correction rests on a false premise: Node CAN issue the certificate, and it already does

- id: `esc-20260918T110419Z-a27e1115`
- raised: 2026-09-18T11:04:20Z
- from: norm-opus-probe2
- worktree: `/Users/alex/ab/richos-wt/norm-opus-probe2` (branch `cc/norm-opus-probe2`)
- head: `549d58390ad588acda6a5abe8b290a5b137b5e02`
- state: **proceeding**
- for: lead

## The question

Plan §2.2 says Node cannot issue an X.509 certificate at all, so shell to /usr/bin/openssl. It can and it has — do you want me to throw away a working, externally-verified implementation to match the plan's command block, or should the plan's §2.2 correction be withdrawn?

## What was already tried

Built it and verified it from outside Node twice, on the tightened extension set, at richos commits b8a3c044 and 549d5839. Reproduce in this worktree: cd richos/tools/phone-probe && PROBE_STATE_DIR=/tmp/p node bin/make-local-ca.js && cd /tmp/p/tls && openssl verify -CAfile richos-local-ca.crt server.crt  -> server.crt: OK; security verify-cert -c server.crt -r richos-local-ca.crt -p ssl -s mm1.local  -> ...certificate verification successful (Apple's own trust evaluator, the one the iPhone uses); and the negative control, -s wrong.local -> Host name mismatch. 41 unit tests. What is true in the premise: there is no certificate-ISSUING API. What does not follow: a certificate is DER plus a signature, and crypto.sign signs arbitrary bytes, so the TBSCertificate is assembled by hand (lib/der.js) and signed (lib/x509.js). I HAVE adopted everything else from the plan: mm1.local, port 8443, richos.local deferred, pathlen:0, and one deviation named in code and tests - keyUsage omits keyEncipherment, which RFC 5480 section 3 says is not appropriate for an EC key.

## Proceeding meanwhile

Keeping the Node implementation and finishing the brief on it. Reasons it is the safer of the two, beyond being done: on THIS Mac  in PATH is OpenSSL 3.6.4 while /usr/bin/openssl is LibreSSL 3.3.6, so a bare  call in a script is a flag-drift trap the plan avoids only by every call site remembering the absolute path; the shell path writes a CSR, a .srl and two keys into a working directory that then needs its own cleanup discipline under CEO ruling section 54, where the Node path writes exactly two keys at mode 0600 and nothing else; and the DER encoder is unit-testable against published byte values, which a shell pipeline is not. If you rule for openssl it is one file, lib/x509.js, and the tests stay.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T110419Z-a27e1115`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T110419Z-a27e1115 --disposition "<what you decided or did>"
