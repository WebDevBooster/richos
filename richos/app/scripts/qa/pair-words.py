#!/usr/bin/env python3
"""The six pairing words under pairing v2, on both sides, and whether they are the same six.

    pair-words.py compute --origin O --ca FP --key K   the v2 words for explicit values
    pair-words.py mac LAB_CACHE                        the words the ISOLATED lab Mac shows for the phone
                                                       that registered its key (the lab's own mac.json,
                                                       then <data>/phone/device.json and ca.crt)
    pair-words.py phone TEST.log                       the words the phone showed: the "Word n: w" labels
                                                       its PHONE_STEP lines carry (phone-ios.py wait steps)
    pair-words.py check LAB_CACHE TEST.log             exit 0 when they are the same six in order,
                                                       1 when any differs, 2 when either side is missing

Why this exists: under pairing v2 the Mac's words are SHA-256("RICHCONNECT-PAIR-V2\\n" + origin +
"\\n" + ca_fingerprint_sha256 + "\\n" + device_point_b64url), first six bytes into the word list
(`app/src-tauri/src/phone/words.rs`). They depend on the key the phone registers, so they exist only
after the phone has sent the link. The lab's ready.json and mac-test-config.json still print the v1
words (the CA's own hash), and a walker going by them sees a false mismatch. On 2026-09-28 two
walkers worked the v2 words out by hand from the lab's files; this is that job, once.

The comparison is the person's own check, done before "They match" is pressed: run the phone's
list with the words waited for by label and a hold before the press (`phone-ios.py pair-steps
CONFIG --v2-hold S`), run `check` during the hold, and stop your own run if it exits non-zero.

The word list is the phone's (`mobile/conformance/vectors/fingerprint.json`, `wordlist`), refused
unless it still hashes to the digest recorded beside it. `mac` reads only a directory that carries
the isolated lab's owner marker, so it can never read a real Mac's pairing. Prints one JSON document.
Exit 0 answer (or same words), 1 the words differ, 2 cannot answer, with the sentence in `error`.
"""
import argparse
import base64
import hashlib
import importlib.util
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]  # the richos repository root
CORPUS = ROOT / "richos/mobile/conformance/vectors/fingerprint.json"
OWNER = "richos-mobile-isolated-v1"
LABEL = "RICHCONNECT-PAIR-V2"
WORD_LABEL = re.compile(r"^Word ([1-6]): (\S+)$")


class CannotAnswer(Exception):
    pass


def emit(obj, code=0):
    print(json.dumps(obj, indent=2))
    return code


def wordlist():
    try:
        corpus = json.loads(CORPUS.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise CannotAnswer(f"cannot read the phone's word list at {CORPUS}: {error}")
    words = corpus.get("wordlist")
    recorded = corpus.get("wordlist_sha256_of_newline_joined")
    if not isinstance(words, list) or len(words) != 256:
        raise CannotAnswer("the word list is not 256 words")
    if hashlib.sha256("\n".join(words).encode()).hexdigest() != recorded:
        raise CannotAnswer("the word list no longer hashes to the digest recorded beside it")
    return words


def normalize_origin(origin):
    """`words.rs` normalize_origin: trimmed, no trailing slash, lowercase, default port dropped."""
    out = origin.strip().rstrip("/").lower()
    if out.startswith("https://") and out.endswith(":443"):
        out = out[: -len(":443")]
    return out


def v2(origin, ca_fingerprint, key):
    digest = hashlib.sha256(f"{LABEL}\n{normalize_origin(origin)}\n{ca_fingerprint}\n{key}".encode()).digest()
    words = wordlist()
    return [words[b] for b in digest[:6]]


def ca_fingerprint(pem_path):
    """The CA's SHA-256 as the Mac sends it: colon-separated uppercase hex of the DER bytes."""
    try:
        text = Path(pem_path).read_text()
    except OSError as error:
        raise CannotAnswer(f"cannot read the lab's CA at {pem_path}: {error}")
    body = re.search(r"-----BEGIN CERTIFICATE-----(.+?)-----END CERTIFICATE-----", text, re.S)
    if not body:
        raise CannotAnswer(f"{pem_path} holds no PEM certificate")
    der = base64.b64decode("".join(body.group(1).split()))
    return ":".join(f"{b:02X}" for b in hashlib.sha256(der).digest())


def mac_side(cache):
    cache = Path(cache)
    try:
        state = json.loads((cache / "mac.json").read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise CannotAnswer(f"no running lab's mac.json in {cache}: {error}")
    origin, data = state.get("origin"), state.get("data")
    if not (isinstance(origin, str) and origin.startswith("https://") and isinstance(data, str)):
        raise CannotAnswer("the lab's mac.json names no HTTPS origin and data directory")
    data = Path(data)
    owner = data / "lab-owner"
    if not owner.is_file() or owner.read_text().strip() != OWNER:
        raise CannotAnswer(f"no isolated-lab owner marker ({OWNER}) in {data}; this reads only the isolated test Mac")
    try:
        device = json.loads((data / "phone/device.json").read_text())
    except FileNotFoundError:
        raise CannotAnswer("no phone has registered a key with this lab yet (no phone/device.json): send the link first")
    except (OSError, json.JSONDecodeError) as error:
        raise CannotAnswer(f"cannot read the lab's phone/device.json: {error}")
    if device.get("pairing_version") != 2:
        raise CannotAnswer(f"the registered phone paired with version {device.get('pairing_version')!r}, not 2: its words are the lab's ready.json words")
    key = device.get("public_key")
    if not isinstance(key, str) or not key:
        raise CannotAnswer("the registered phone has no public_key")
    fingerprint = ca_fingerprint(state.get("ca") or data / "phone/ca.crt")
    return {"origin": normalize_origin(origin), "words": v2(origin, fingerprint, key)}


def phone_side(log_path):
    here = Path(__file__).resolve().parent / "phone-ios.py"
    spec = importlib.util.spec_from_file_location("phone_ios", here)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    try:
        rows = module.parse_log(Path(log_path).read_text(errors="replace"))
    except OSError as error:
        raise CannotAnswer(f"cannot read the phone's test log {log_path}: {error}")
    seen = {}
    for row in rows:
        found = WORD_LABEL.match(str((row.get("detail") or {}).get("label", "")))
        if found:
            seen[int(found.group(1))] = found.group(2)
    missing = [n for n in range(1, 7) if n not in seen]
    if missing:
        raise CannotAnswer(f"the phone's log has not shown word(s) {missing} yet")
    return [seen[n] for n in range(1, 7)]


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    c = sub.add_parser("compute")
    c.add_argument("--origin", required=True)
    c.add_argument("--ca", required=True, help="colon-separated uppercase SHA-256, as the Mac sends it")
    c.add_argument("--key", required=True, help="the 65-byte P-256 point, base64url without padding")
    sub.add_parser("mac").add_argument("lab_cache")
    sub.add_parser("phone").add_argument("log")
    k = sub.add_parser("check")
    k.add_argument("lab_cache")
    k.add_argument("log")
    args = parser.parse_args(argv)
    try:
        if args.command == "compute":
            return emit({"origin": normalize_origin(args.origin), "words": v2(args.origin, args.ca, args.key)})
        if args.command == "mac":
            return emit(mac_side(args.lab_cache))
        if args.command == "phone":
            return emit({"words": phone_side(args.log)})
        mac, phone = mac_side(args.lab_cache), phone_side(args.log)
        same = mac["words"] == phone
        return emit({"same": same, "mac": mac["words"], "phone": phone, "origin": mac["origin"]}, 0 if same else 1)
    except CannotAnswer as error:
        return emit({"error": str(error)}, 2)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
