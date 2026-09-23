#!/usr/bin/env python3
"""Release security policy for the two native RichConnect apps. Standard library only.

    release_policy.py android-manifest <aapt2-xmltree-dump | ->   the MERGED manifest of a release APK
    release_policy.py repo [<repository root>]                    tracked files and native sources
    release_policy.py self-test                                   every rule fires on its negative control

Prints one line per rule ("ok ..." / "FAIL ...") and exits 0 only when every rule passed, 1 on a
violation, 2 on a usage error or an unreadable input.

WHY THIS EXISTS (security review 2026-09-23, docs/verification/2026-09-23-native-security-review/).
Both apps already prove the development bridge is absent from Release (`randroid check-release`,
`native-ios/Release/check-release.sh` R8). Neither proves the rest of what a store build must not
carry: a debuggable or test-only Android package, backup or cleartext switched back on, a new
exported component, a deep link, custom TLS trust, a credential file or a Firebase key committed,
or a log call in production code. Each rule here is one of those, and `self-test` proves each one
fails on a mutated input before its pass on the real input is believed.

Getting the Android input:  aapt2 dump xmltree --file AndroidManifest.xml app-release.apk
(for a bundle: bundletool dump manifest --bundle app-release.aab prints XML; convert it first,
or dump the APK the bundle was built beside).
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ANDROID_PACKAGE = "dev.richos.connect"
ANDROID_NS = "http://schemas.android.com/apk/res/android:"

# The app's own components that may be exported, and the ONLY intent actions each may take.
APP_EXPORTED = {
    "dev.richos.android.app.MainActivity": {"android.intent.action.MAIN"},
    "dev.richos.android.platform.ShareActivity": {"android.intent.action.SEND", "android.intent.action.SEND_MULTIPLE"},
}
# A library component may be exported only behind a permission no ordinary app can hold.
PROTECTING_PERMISSIONS = {
    "com.google.android.c2dm.permission.SEND",  # signature|privileged: Google Play services only
    "android.permission.DUMP",                  # held by the adb shell, never grantable to an app
    "android.permission.BIND_JOB_SERVICE",      # the system's job scheduler only
}
COMPONENTS = ("activity", "activity-alias", "service", "receiver", "provider")
DEVELOPMENT_MARKERS = ("dev.richos.android.app.debug", "DevBridge", "devbridge")

CREDENTIAL_NAMES = re.compile(
    r"(^|/)(google-services\.json|GoogleService-Info\.plist|[^/]*service-account[^/]*\.json)$"
    r"|\.(jks|keystore|p12|pfx|p8|pepk|mobileprovision|provisionprofile)$", re.I)
GOOGLE_API_KEY = re.compile(rb"AIza[0-9A-Za-z_\-]{35}")
PEM_PRIVATE_KEY = re.compile(rb"-----BEGIN (?:EC |RSA |ENCRYPTED )?PRIVATE KEY-----")

NATIVE = ("richos/mobile/native-android/", "richos/mobile/native-ios/")
# Production code: what ships. Debug-only and test trees are not.
ANDROID_PRODUCTION = re.compile(r"^richos/mobile/native-android/(app|core)/src/main/.*\.(kt|java|xml)$")
IOS_PRODUCTION = re.compile(
    r"^richos/mobile/native-ios/(App/.*|Core/Sources/RichOSCore/.*|ShareExtension/Sources/.*|NotificationService/Sources/.*)\.swift$")
IOS_CONFIG = re.compile(r"^richos/mobile/native-ios/.*\.(plist|entitlements|yml)$")

CUSTOM_TRUST = [
    ("Android trust manager", re.compile(r"X509TrustManager|TrustManagerFactory|HostnameVerifier|setSSLSocketFactory|sslSocketFactory\(")),
    ("Android network security config", re.compile(r"networkSecurityConfig|<trust-anchors|<domain-config|usesCleartextTraffic=\"true\"")),
    ("iOS trust evaluation", re.compile(r"URLAuthenticationChallenge|serverTrust|SecTrustEvaluate|SecTrustSetAnchorCertificates")),
    ("iOS App Transport Security exception", re.compile(r"NSAllowsArbitraryLoads|NSExceptionDomains|NSAllowsLocalNetworking|NSAppTransportSecurity")),
]
ENTRY_POINTS = [
    ("iOS URL scheme or universal link", re.compile(r"CFBundleURLTypes|onOpenURL|associated-domains|continueUserActivity")),
    ("Android deep link", re.compile(r"android\.intent\.category\.BROWSABLE|android\.intent\.action\.VIEW\"")),
]
LOGGING = [
    ("Android log call", re.compile(r"\bLog\.[vdiwe]\(|\bprintln\(|\.printStackTrace\(\)")),
    ("iOS log call", re.compile(r"(^|[^A-Za-z_.])(print|debugPrint|NSLog|os_log)\(|\bLogger\(")),
]
IOS_ENTITLEMENTS_ALLOWED = {"aps-environment", "com.apple.security.application-groups", "keychain-access-groups"}


class Report:
    def __init__(self):
        self.failed = 0

    def check(self, name, problems):
        if problems:
            self.failed += 1
            print(f"  FAIL  {name}")
            for p in problems[:20]:
                print(f"        {p}")
        else:
            print(f"  ok    {name}")


# --- the merged Android manifest (aapt2 dump xmltree) -------------------------------------------

def parse_xmltree(text):
    """aapt2's indented dump -> nested dicts {tag, attrs, children}. Attribute names lose the
    android namespace prefix and the resource id; values lose quotes and the (Raw: ...) echo."""
    root = {"tag": "#root", "attrs": {}, "children": []}
    stack = [(-1, root)]
    for line in text.splitlines():
        m = re.match(r"^(\s*)([NEA]): (.*)$", line)
        if not m:
            continue
        depth, kind, rest = len(m.group(1)), m.group(2), m.group(3)
        if kind == "E":
            while stack and stack[-1][0] >= depth:
                stack.pop()
            node = {"tag": rest.split(" (line=")[0].strip(), "attrs": {}, "children": []}
            stack[-1][1]["children"].append(node)
            stack.append((depth, node))
        elif kind == "A":
            while stack and stack[-1][0] >= depth:
                stack.pop()
            a = re.match(r"^(?:" + re.escape(ANDROID_NS) + r")?([A-Za-z_]+)(?:\(0x[0-9a-f]+\))?=(.*)$", rest)
            if not a:
                continue
            value = a.group(2).strip()
            q = re.match(r'^"(.*?)"(?: \(Raw: .*\))?$', value)
            if q:
                value = q.group(1)
            elif value.startswith("(type 0x12)"):
                value = "false" if value.endswith("0x0") else "true"
            stack[-1][1]["attrs"][a.group(1)] = value
    return root


def walk(node):
    yield node
    for child in node["children"]:
        yield from walk(child)


def first(node, tag):
    return next((n for n in walk(node) if n["tag"] == tag), None)


def truthy(value):
    return value is not None and value.lower() not in ("false", "0x0", "0")


def android_manifest(text, report):
    tree = parse_xmltree(text)
    manifest, app = first(tree, "manifest"), first(tree, "application")
    if manifest is None or app is None:
        report.check("A0 the input is an aapt2 xmltree dump of a manifest with an <application>", ["no manifest/application element found"])
        return
    a = app["attrs"]
    report.check(f"A1 package is {ANDROID_PACKAGE}",
                 [] if manifest["attrs"].get("package") == ANDROID_PACKAGE else [f"package={manifest['attrs'].get('package')!r}"])
    report.check("A2 not debuggable", [f"android:debuggable={a['debuggable']}"] if truthy(a.get("debuggable")) else [])
    report.check("A3 not test-only", [f"android:testOnly={a['testOnly']}"] if truthy(a.get("testOnly")) else [])
    report.check("A4 backup is off (allowBackup=false)", [] if a.get("allowBackup") == "false" else [f"android:allowBackup={a.get('allowBackup')!r}"])
    report.check("A5 no cleartext traffic and no custom network security config (system trust only)",
                 ([f"android:usesCleartextTraffic={a['usesCleartextTraffic']}"] if truthy(a.get("usesCleartextTraffic")) else [])
                 + ([f"android:networkSecurityConfig={a['networkSecurityConfig']}"] if "networkSecurityConfig" in a else []))
    problems, links = [], []
    for c in app["children"]:
        if c["tag"] not in COMPONENTS:
            continue
        name, attrs = c["attrs"].get("name", "?"), c["attrs"]
        filters = [f for f in c["children"] if f["tag"] == "intent-filter"]
        actions = {n["attrs"].get("name") for f in filters for n in f["children"] if n["tag"] == "action"}
        categories = {n["attrs"].get("name") for f in filters for n in f["children"] if n["tag"] == "category"}
        if "android.intent.category.BROWSABLE" in categories or "android.intent.action.VIEW" in actions:
            links.append(f"{c['tag']} {name} takes VIEW/BROWSABLE")
        # Since API 31 an intent filter without an explicit android:exported fails to install, so
        # an absent value is read as not exported only when there is no filter.
        exported = truthy(attrs.get("exported")) if "exported" in attrs else bool(filters)
        if not exported:
            continue
        if name in APP_EXPORTED and c["tag"] in ("activity", "activity-alias"):
            extra = sorted(actions - APP_EXPORTED[name])
            if extra:
                problems.append(f"{name} is exported for unexpected actions {extra}")
        elif c["tag"] == "provider":
            problems.append(f"provider {name} is exported")
        elif attrs.get("permission") not in PROTECTING_PERMISSIONS:
            problems.append(f"{c['tag']} {name} is exported with permission {attrs.get('permission')!r}")
    report.check("A6 exported components are the launcher, the share target and permission-protected library receivers", problems)
    report.check("A7 no deep link (no VIEW or BROWSABLE intent filter)", links)
    report.check("A8 no development bridge in the manifest", [m for m in DEVELOPMENT_MARKERS if m in text])


# --- tracked files and native sources -------------------------------------------------------------

def tracked(root):
    out = subprocess.run(["git", "-C", str(root), "ls-files", "-z"], capture_output=True, check=True).stdout
    return [p for p in out.decode("utf-8", "surrogateescape").split("\0") if p]


def read(root, path):
    try:
        return (Path(root) / path).read_bytes()
    except OSError:
        return b""


def scan(root, paths, pattern_list, selector):
    problems = []
    for path in paths:
        if not selector(path):
            continue
        text = read(root, path).decode("utf-8", "replace")
        for number, line in enumerate(text.splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith(("//", "#", "*", "<!--", "///")):
                continue
            for label, pattern in pattern_list:
                if pattern.search(line):
                    problems.append(f"{path}:{number} {label}: {stripped[:120]}")
    return problems


def repo(root, paths, report):
    """`paths` is the tracked file list; None reads it from git."""
    root = Path(root)
    paths = tracked(root) if paths is None else paths
    native = [p for p in paths if p.startswith(NATIVE)]
    report.check("G1 no credential file is tracked (google-services.json, keystores, .p8, profiles)",
                 [p for p in paths if CREDENTIAL_NAMES.search(p)])
    report.check("G2 no Google API key literal in any tracked file (Firebase values come from protected storage)",
                 [p for p in paths if GOOGLE_API_KEY.search(read(root, p))])
    report.check("G3 no private key block in the native app trees",
                 [p for p in native if PEM_PRIVATE_KEY.search(read(root, p))])
    code = lambda p: bool(ANDROID_PRODUCTION.match(p) or IOS_PRODUCTION.match(p) or IOS_CONFIG.match(p))
    report.check("T1 no custom TLS trust or transport-security exception in either app (system trust, nothing pinned)",
                 scan(root, native, CUSTOM_TRUST, code))
    report.check("T2 no URL scheme, universal link or deep link entry point", scan(root, native, ENTRY_POINTS, code))
    report.check("L1 no log call in production code (nothing secret can reach a log)",
                 scan(root, native, LOGGING, lambda p: bool(ANDROID_PRODUCTION.match(p) or IOS_PRODUCTION.match(p))))
    problems = []
    for path in native:
        if path.endswith(".entitlements"):
            keys = set(re.findall(r"<key>([^<]+)</key>", read(root, path).decode("utf-8", "replace")))
            problems += [f"{path}: {k}" for k in sorted(keys - IOS_ENTITLEMENTS_ALLOWED)]
    report.check("E1 iOS entitlements are push, the App Group and the Keychain group only (no get-task-allow, no associated domains)", problems)


# --- self-test: every rule must fail on its negative control -------------------------------------

RELEASE_FIXTURE = Path(__file__).with_name("fixtures") / "release-manifest-4edbfce1.txt"
DEBUG_FIXTURE = Path(__file__).with_name("fixtures") / "debug-manifest-4edbfce1.txt"


def failing_rules(fn, *args):
    import contextlib
    import io
    report, buffer = Report(), io.StringIO()
    with contextlib.redirect_stdout(buffer):
        fn(*args, report)
    return {line.split()[1] for line in buffer.getvalue().splitlines() if line.strip().startswith("FAIL")}


def self_test():
    results = []

    def expect(label, got, want):
        ok = got == want
        results.append(ok)
        print(f"  {'ok  ' if ok else 'FAIL'}  {label}" + ("" if ok else f"\n        expected {sorted(want)}, got {sorted(got)}"))

    release = RELEASE_FIXTURE.read_text()
    expect("the 4edbfce1 release manifest passes every rule", failing_rules(android_manifest, release), set())
    expect("the 4edbfce1 debug manifest fails (debuggable, bridge receiver exported, bridge markers)",
           failing_rules(android_manifest, DEBUG_FIXTURE.read_text()), {"A2", "A6", "A8"})
    app_line = "        A: http://schemas.android.com/apk/res/android:allowBackup(0x01010280)=false\n"
    assert app_line in release, "fixture changed shape"

    def mutate(extra):
        return release.replace(app_line, app_line + extra, 1)

    expect("debuggable=true fails A2", failing_rules(android_manifest, mutate(
        "        A: http://schemas.android.com/apk/res/android:debuggable(0x0101000f)=true\n")), {"A2"})
    expect("testOnly=true fails A3", failing_rules(android_manifest, mutate(
        "        A: http://schemas.android.com/apk/res/android:testOnly(0x01010272)=true\n")), {"A3"})
    expect("allowBackup=true fails A4", failing_rules(android_manifest, release.replace("allowBackup(0x01010280)=false", "allowBackup(0x01010280)=true")), {"A4"})
    expect("cleartext and a network security config fail A5", failing_rules(android_manifest, mutate(
        "        A: http://schemas.android.com/apk/res/android:usesCleartextTraffic(0x010104ec)=true\n"
        "        A: http://schemas.android.com/apk/res/android:networkSecurityConfig(0x01010527)=@0x7f0f0001\n")), {"A5"})
    component = ("          E: {tag} (line=900)\n"
                 "            A: http://schemas.android.com/apk/res/android:name(0x01010003)=\"{name}\" (Raw: \"{name}\")\n"
                 "            A: http://schemas.android.com/apk/res/android:exported(0x01010010)=true\n")
    marker = "          E: meta-data (line=178)\n"
    assert marker in release, "fixture changed shape"
    add = lambda block: release.replace(marker, block + marker, 1)
    expect("an unprotected exported receiver fails A6", failing_rules(android_manifest, add(
        component.format(tag="receiver", name="dev.richos.android.platform.Stray"))), {"A6"})
    expect("an exported provider fails A6", failing_rules(android_manifest, add(
        component.format(tag="provider", name="androidx.core.content.FileProvider"))), {"A6"})
    expect("a VIEW/BROWSABLE filter fails A6 and A7", failing_rules(android_manifest, release.replace(
        '"android.intent.action.SEND_MULTIPLE" (Raw: "android.intent.action.SEND_MULTIPLE")',
        '"android.intent.action.VIEW" (Raw: "android.intent.action.VIEW")', 1)), {"A6", "A7"})
    expect("a different package fails A1", failing_rules(android_manifest, release.replace(
        'package="dev.richos.connect"', 'package="dev.richos.native.android"', 1)), {"A1"})

    with tempfile.TemporaryDirectory(prefix="release-policy-") as tmp:
        root = Path(tmp)
        files = {
            "richos/mobile/native-android/app/src/main/kotlin/A.kt": "package a\nclass A { fun f() = 1 }\n",
            "richos/mobile/native-ios/App/A.swift": "import Foundation\n// print(\"a comment is not a call\")\nstruct A {}\n",
            "richos/mobile/native-ios/Release/App.entitlements": "<plist><dict><key>aps-environment</key><string>x</string></dict></plist>\n",
        }
        for path, body in files.items():
            (root / path).parent.mkdir(parents=True, exist_ok=True)
            (root / path).write_text(body)
        clean = list(files)
        expect("a clean tree passes every repository rule", failing_rules(repo, root, clean), set())
        mutations = {
            "G1": ("richos/mobile/native-android/app/google-services.json", "{}"),
            "G2": ("docs/notes.md", "key: AIza" + "A" * 35 + "\n"),
            "G3": ("richos/mobile/native-ios/Core/key.pem", "-----BEGIN " + "PRIVATE KEY-----\nAAAA\n"),
            "T1": ("richos/mobile/native-android/app/src/main/kotlin/T.kt", "object T : javax.net.ssl.X509TrustManager\n"),
            "T2": ("richos/mobile/native-ios/App/Link.swift", "view.onOpenURL { url in }\n"),
            "L1": ("richos/mobile/native-android/core/src/main/kotlin/L.kt", "fun f(t: String) { android.util.Log.d(\"x\", t) }\n"),
            "E1": ("richos/mobile/native-ios/ShareExtension/X.entitlements", "<key>get-task-allow</key><true/>\n"),
        }
        for rule, (path, body) in mutations.items():
            (root / path).parent.mkdir(parents=True, exist_ok=True)
            (root / path).write_text(body)
            expect(f"{rule} fires on {path}", failing_rules(repo, root, clean + [path]), {rule})
            (root / path).unlink()
    return 0 if all(results) else 1


def main(argv):
    if len(argv) < 2 or argv[1] not in ("android-manifest", "repo", "self-test"):
        print(__doc__, file=sys.stderr)
        return 2
    if argv[1] == "self-test":
        return self_test()
    report = Report()
    if argv[1] == "android-manifest":
        if len(argv) != 3:
            print("usage: release_policy.py android-manifest <dump|->", file=sys.stderr)
            return 2
        try:
            text = sys.stdin.read() if argv[2] == "-" else Path(argv[2]).read_text()
        except OSError as error:
            print(f"release_policy: cannot read {argv[2]}: {error}", file=sys.stderr)
            return 2
        android_manifest(text, report)
    else:
        root = Path(argv[2]) if len(argv) > 2 else Path(__file__).resolve().parents[3]
        try:
            repo(root, None, report)
        except subprocess.CalledProcessError as error:
            print(f"release_policy: git ls-files failed in {root}: {error}", file=sys.stderr)
            return 2
    return 1 if report.failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
