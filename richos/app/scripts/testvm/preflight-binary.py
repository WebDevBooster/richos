#!/usr/bin/env python3
"""preflight-binary.py — PROVE A BINARY CAN LAUNCH, WITHOUT LAUNCHING IT.

===========================================================================
THE DIALOG THIS EXISTS FOR
===========================================================================
2026-09-19, 19:20Z. Setting up the test VM host, `tart --version` was run to
check the install. The binary aborted in dyld before `main`, and macOS put
"tart cannot be opened because of a problem" ON THE CEO'S SCREEN — the exact
class of interruption this whole slice exists to end. He had to press Ignore.

The cause was benign and completely knowable in advance: tart 2.37.0 and
2.36.0 hard-link `@rpath/libswiftCompatibilitySpan.dylib`, a Swift 6.2
runtime that ships only with macOS 26 / Xcode 26. This host is macOS 15.6,
so the library does not exist, and dyld kills the process with SIGABRT.
Termination reason in both .ips reports: "DYLD Library missing".

A version check is the most innocent thing you can run, and it still reached
his screen. So the rule is not "be careful with GUI apps" — it is that
NOTHING gets executed until its dynamic dependencies are proven resolvable.

===========================================================================
HOW IT DECIDES, AND WHY NOT THE OBVIOUS WAY
===========================================================================
`otool -L` / `dyld_info -dependents` list what a binary needs, but listing is
not resolving: most Apple libraries (libswiftCore.dylib among them) exist ONLY
inside the dyld shared cache and are absent from the filesystem, so a
plain "does this file exist" test fails every modern binary. That check would
be worse than none — it would cry wolf until somebody turned it off.

Each NON-WEAK dependency must therefore resolve one of two ways:

  1. ON DISK, through the binary's own LC_RPATH entries, with @executable_path
     and @loader_path expanded the way dyld expands them; or
  2. IN THE SHARED CACHE, tested by actually asking the loader — ctypes.CDLL
     in THIS process. A miss raises OSError and is caught. Loading a library
     into a short-lived python process cannot put a dialog on anyone's screen;
     that is the whole point.

WEAK dependencies are skipped: dyld is entitled to find them missing and
carries on with a null symbol. This distinction is not a nicety, it is the
entire signal — the working tart 2.33.1 weak-links the very library the
crashing 2.36.0 hard-links. Both binaries "depend on" it; only one dies.

Signature and Gatekeeper status are checked in the same pass, because an
unsigned or un-notarized binary is the other way a launch turns into a dialog.

===========================================================================
USAGE
===========================================================================
  preflight-binary.py <path>            exit 0 = safe to execute
  preflight-binary.py <path> --quiet    print only on failure

Exit 1 with the reason on stdout when it is NOT safe. Say which check failed,
never just "failed" — the caller is usually a script that cannot look.
"""

import ctypes
import os
import subprocess
import sys


def sh(cmd):
    """Run a command, return (rc, stdout+stderr). Never raises."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except Exception as exc:  # noqa: BLE001 - a probe must not raise
        return 127, str(exc)


def rpaths_of(binary):
    """LC_RPATH entries, in load order. dyld tries them in exactly this order."""
    rc, out = sh(["otool", "-l", binary])
    if rc != 0:
        return []
    paths, want = [], False
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("cmd LC_RPATH"):
            want = True
        elif want and s.startswith("path "):
            # "path <value> (offset 12)"
            paths.append(s[5:].rsplit(" (offset", 1)[0].strip())
            want = False
    return paths


def dependencies(binary):
    """[(name, is_weak)] from dyld_info. The weak flag is the load-bearing bit."""
    rc, out = sh(["dyld_info", "-dependents", binary])
    if rc != 0:
        return None
    deps, started = [], False
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("attributes") and "load path" in s:
            started = True
            continue
        if not started or not s:
            continue
        # "        weak-link      @rpath/libFoo.dylib"  |  "   @rpath/libFoo.dylib"
        parts = s.split()
        if not parts:
            continue
        path = parts[-1]
        if "/" not in path and not path.startswith("@"):
            continue
        deps.append((path, "weak" in s.lower()))
    return deps


def resolves(dep, binary, rpaths):
    """True if dyld could load `dep`. Disk first, then the loader itself."""
    exe_dir = os.path.dirname(os.path.realpath(binary))

    def expand(p):
        return p.replace("@executable_path", exe_dir).replace("@loader_path", exe_dir)

    if dep.startswith("@rpath/"):
        tail = dep[len("@rpath/"):]
        for rp in rpaths:
            if os.path.exists(os.path.join(expand(rp), tail)):
                return True
        candidates = [tail]
    else:
        p = expand(dep)
        if os.path.exists(p):
            return True
        candidates = [p, os.path.basename(p)]

    # Not on disk. It may still live in the dyld shared cache — ask the loader.
    for name in candidates:
        try:
            ctypes.CDLL(name)
            return True
        except OSError:
            continue
    return False


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    quiet = "--quiet" in sys.argv
    if len(args) != 1:
        print("usage: preflight-binary.py <path-to-binary> [--quiet]")
        return 2

    binary = os.path.realpath(args[0])
    fails = []

    if not os.path.exists(binary):
        print("preflight FAIL: %s does not exist" % binary)
        return 1

    # 1. Code signature.
    rc, out = sh(["codesign", "-dv", binary])
    if rc != 0:
        fails.append("codesign: not validly signed (%s)" % out.strip().splitlines()[-1:])
    else:
        team = [l for l in out.splitlines() if l.startswith("TeamIdentifier=")]
        team = team[0].split("=", 1)[1] if team else "none"

    # 2. Gatekeeper. A rejection here is what produces the "cannot be opened,
    #    Apple could not verify it" dialog, which is just as much on his screen.
    rc, out = sh(["spctl", "-a", "-vv", binary])
    gate = "accepted" if rc == 0 else "REJECTED"
    if rc != 0:
        fails.append("spctl: %s — %s" % (gate, out.strip().replace("\n", " ")))

    # 3. Dynamic dependencies — the check that would have stopped the crash.
    deps = dependencies(binary)
    if deps is None:
        fails.append("dyld_info: could not read dependencies")
    else:
        rpaths = rpaths_of(binary)
        missing = [d for d, weak in deps if not weak and not resolves(d, binary, rpaths)]
        for m in missing:
            fails.append(
                "dyld: REQUIRED library %s cannot be resolved — launching this "
                "binary would abort in dyld and raise a crash dialog" % m
            )

    if fails:
        print("preflight FAIL: %s" % binary)
        for f in fails:
            print("  - %s" % f)
        return 1

    if not quiet:
        print(
            "preflight ok: %s (signed team %s, gatekeeper %s, %d dependencies resolve)"
            % (os.path.basename(binary), team, gate, len(deps))
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
