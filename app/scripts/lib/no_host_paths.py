#!/usr/bin/env python3
"""Refuse a bundle that carries the building machine's home directory.

WHY THIS EXISTS. Rust bakes the compile-time path of every crate into the binary as
panic-location and debug metadata. For a registry dependency that path is
`$CARGO_HOME/registry/src/...`; for a path dependency outside the package directory it
is the absolute path of the source tree. MEASURED on the release build kept at
`~/.richos-signing/rebuild-survival/builds/build-1/RichOS.app`: 472 distinct
`/Users/<builder>/.cargo/...` paths and 23 distinct
`/Users/<builder>/ab/richos/.worktrees/<agent>/app/crates/...` paths, all readable with
`strings`. The bundle inspector saw none of it, because none of it is a file — it is
metadata inside the executable, exactly like the 19.89 MiB of embedded test screenshots
that `build.rs` now stages away.

That is a stranger reading the builder's account name, home-directory layout, repository
location and internal working-branch names out of an application they installed. It is
not cosmetic; the CEO's ruling that personal paths in the REPOSITORY are cosmetic says
nothing about the artifact, and nobody had ever checked the artifact.

WHAT FIXES IT. `--remap-path-prefix`, exported by `package-app.sh` before the release
build. Cargo's own `trim-paths` profile key would be the tidier route and is NOT
available: cargo 1.95.0 refuses it with "the package requires the Cargo feature called
`trim-paths`, but that feature is not stabilized in this version of Cargo". That was
established by running it, not by reading about it.

WHAT THIS SCRIPT IS FOR. The remap is the fix; this is the proof. A flag that silently
stops applying — a new dependency shape, a vendored C library baking in `__FILE__`, a
future toolchain — would put the paths straight back with nothing to notice it. So the
guarantee is checked on the built bundle, after it is produced and before it is signed,
in the same posture `build.rs` takes toward the staged frontend.

PLACEHOLDERS ARE NOT FINDINGS. `/Users/you/...` and `/Users/example/...` are invented
fixture paths that the product deliberately ships (`app/ui/mock.js`,
`EntityRegistry::FIXTURE_COMPANIES`). They name no machine and they are allowed by name,
so that the check refusing them would be a bug rather than a judgment call.

NEITHER ARE THE PRODUCT'S OWN ASSET KEYS. `app/ui/home/` holds four files, so the
embedded frontend carries the asset keys `/home/field-data.js`, `/home/field-engine.js`,
`/home/field-prep.js` and `/home/field-ref.js`. Those are URL paths inside the
application. The first version of this check read them as `/home/<user>` and refused a
correct release build over them — MEASURED at 9a7799e, where it reported five prefixes
and only one was real. A check that cries wolf four times out of five is a check people
learn to override, which is the failure this file exists to prevent.

So a finding now requires a CHILD COMPONENT: `<root>/<name>/`. That is what a leaked
home directory always looks like, because what leaks is a path INTO the home directory —
a registry source file, a crate root, a manifest directory. `/home/field-data.js` names a
file sitting directly in `/home`, which is not a home directory and never was one.
Narrowing a check is how checks quietly stop working, so the narrowing is paired with an
exact rule: the `--home` value itself is a finding wherever it appears, with a child
component or without one, so the plainest possible leak cannot slip through the gap the
narrowing opens.

The residual is deliberate and fails SAFE. If `app/ui/home/` ever grows a subdirectory,
its asset key gains a child component and this check will refuse the build. That is the
right direction to fail in: name it with `--allow`, and do not widen the rule.

Usage:
    no_host_paths.py <bundle-or-file> [--home DIR] [--allow NAME]... [--quiet]
    no_host_paths.py --self-test

Exit: 0 clean, 1 findings, 2 bad usage.
"""
from __future__ import annotations

import argparse
import os
import re
import sys

# Home-directory shapes on the platforms this project builds for. `/home/` is here even
# though RichOS ships macOS first, because the Windows companion and any future Linux
# build have the identical defect and a check that only knows one platform grows a hole
# the day the second one ships.
HOME_ROOTS = ("/Users/", "/home/", "/var/root/")

# Fixture user names that are deliberately shipped. Anything NOT on this list is a
# finding, so a new real name cannot be quietly absorbed.
DEFAULT_ALLOWED = frozenset({"you", "example", "x", "jordan", "user", "someone"})

# A printable run, the way `strings` defines one.
RUN = re.compile(rb"[\x20-\x7e]{6,}")

# `<root>/<name>` followed by a `/`. The lookahead is load-bearing twice over: it demands
# the child component that makes this a home-directory path rather than a file that merely
# lives under `/home`, and it stays OUT of group(0) so the reported prefix is still the
# thing an operator greps for.
PATH = re.compile(
    r"(?:" + "|".join(re.escape(r) for r in HOME_ROOTS) + r")([A-Za-z0-9_.-]+)(?=/)"
)


def _exact_home(home: str | None):
    """The `--home` value on its own terms, child component or not.

    Paired with PATH's lookahead so that narrowing the heuristic cannot open a hole: a
    binary carrying nothing but the bare string `/Users/alex` is still refused.
    """
    if not home:
        return None
    return re.compile(re.escape(home.rstrip("/")) + r"(?![A-Za-z0-9_.-])")


def runs(data: bytes):
    for m in RUN.finditer(data):
        yield m.group(0).decode("ascii")


def scan_bytes(data: bytes, allowed, home: str | None = None):
    """Return {offending_prefix: count} for one blob."""
    hits: dict[str, int] = {}
    exact = _exact_home(home)
    for text in runs(data):
        reported: set[int] = set()
        for m in PATH.finditer(text):
            if m.group(1) in allowed:
                continue
            hits[m.group(0)] = hits.get(m.group(0), 0) + 1
            reported.add(m.start())
        if exact:
            for m in exact.finditer(text):
                # Same offset means the heuristic already counted it; counting it twice
                # would inflate a real finding, and an inflated number is a number nobody
                # can check.
                if m.start() in reported:
                    continue
                hits[m.group(0)] = hits.get(m.group(0), 0) + 1
    return hits


def files_under(target: str):
    if os.path.isfile(target):
        yield target
        return
    for root, _dirs, names in os.walk(target):
        for name in sorted(names):
            path = os.path.join(root, name)
            if os.path.isfile(path) and not os.path.islink(path):
                yield path


def scan(target: str, allowed, home: str | None):
    """Return a list of (file, prefix, count, is_this_machine)."""
    findings = []
    home = home.rstrip("/") if home else None
    for path in files_under(target):
        try:
            with open(path, "rb") as fh:
                data = fh.read()
        except OSError as exc:  # unreadable member is a finding about the check, not the app
            findings.append((path, f"<unreadable: {exc}>", 1, False))
            continue
        for prefix, count in sorted(scan_bytes(data, allowed, home).items()):
            findings.append((path, prefix, count, bool(home) and prefix == home))
    return findings


def report(findings, target, quiet=False):
    if not findings:
        if not quiet:
            print(f"no-host-paths: clean — no home-directory path in {target}")
        return 0

    by_prefix: dict[str, int] = {}
    for _path, prefix, count, _mine in findings:
        by_prefix[prefix] = by_prefix.get(prefix, 0) + count

    print("", file=sys.stderr)
    print(
        f"no-host-paths: {target} carries {len(by_prefix)} home-directory prefix(es) "
        f"across {len({f[0] for f in findings})} file(s). A stranger who installs this "
        "can read them with `strings`.",
        file=sys.stderr,
    )
    print("", file=sys.stderr)
    for prefix in sorted(by_prefix):
        print(f"  {prefix}   ({by_prefix[prefix]} occurrence(s))", file=sys.stderr)
    print("", file=sys.stderr)
    print(
        "Fix: build through app/scripts/package-app.sh, which exports\n"
        "--remap-path-prefix for $HOME, $CARGO_HOME and the source tree before\n"
        "`cargo tauri build`. If this fired on a build that DID go through it, the\n"
        "remap missed a new path shape — find it with:\n"
        f"\n    strings -n 8 <executable> | grep -o '{HOME_ROOTS[0]}[^\" ]*' | sort -u\n"
        "\nOverride, deliberately and on the record, with RICHOS_ALLOW_HOST_PATHS=1.",
        file=sys.stderr,
    )
    return 1


SELF_TEST_CASES = [
    # (blob, allowed, home, expect_findings)
    (b"nothing to see here at all", DEFAULT_ALLOWED, None, False),
    (b"/Users/you/Projects/northwind is a fixture", DEFAULT_ALLOWED, None, False),
    (b"/Users/example/Projects/harbor is a fixture", DEFAULT_ALLOWED, None, False),
    (b"/Users/alex/.cargo/registry/src/anyhow/src/error.rs", DEFAULT_ALLOWED, None, True),
    (b"/home/builder/src/richos/app/crates/richos-core/src/loro.rs", DEFAULT_ALLOWED, None, True),
    (b"/var/root/secret/thing.rs", DEFAULT_ALLOWED, None, True),
    # Short runs are invisible to `strings` and must be invisible here too, so the
    # check describes the same surface an attacker actually reads.
    (b"\x00\x01/Us\x00", DEFAULT_ALLOWED, None, False),
    # A real name added to --allow is not a finding; that is what the flag is for.
    (b"/Users/ci-runner/work/x.rs", DEFAULT_ALLOWED | {"ci-runner"}, None, False),
    # THE PRODUCT'S OWN ASSET KEYS. All four files in app/ui/home/ are embedded in the
    # binary under these keys. This check refused a correct release build over them until
    # the child component became a requirement; if these cases ever fail again, the
    # release is blocked by a false positive.
    (b"/home/field-data.js", DEFAULT_ALLOWED, None, False),
    (b"/home/field-engine.js", DEFAULT_ALLOWED, None, False),
    (b"/home/field-prep.js", DEFAULT_ALLOWED, None, False),
    (b"/home/field-ref.js", DEFAULT_ALLOWED, None, False),
    # ...and the same shape one level down IS a finding, because that is the shape of a
    # leaked home directory. This is the cost of the narrowing, stated rather than hidden.
    (b"/home/field/data.js", DEFAULT_ALLOWED, None, True),
    # THE HOLE THE NARROWING WOULD OTHERWISE OPEN. A bare home directory has no child
    # component, so only the exact `--home` rule catches it.
    (b"built by someone at /Users/alex", DEFAULT_ALLOWED, "/Users/alex", True),
    (b"built by someone at /Users/alex", DEFAULT_ALLOWED, None, False),
    # A longer name that merely starts with the home directory is a different account,
    # and it is a finding on its own terms rather than as this machine's home.
    (b"/Users/alexandra/work/x.rs", DEFAULT_ALLOWED, "/Users/alex", True),
    # The two rules overlap on every ordinary leak; the count must not double.
    (b"/Users/alex/.cargo/x.rs", DEFAULT_ALLOWED, "/Users/alex", True),
]


def self_test() -> int:
    bad = 0
    for i, (blob, allowed, home, expect) in enumerate(SELF_TEST_CASES, 1):
        got = bool(scan_bytes(blob, allowed, home))
        ok = got == expect
        bad += not ok
        print(f"{'ok  ' if ok else 'FAIL'} case {i}: expected findings={expect}, got={got}")

    # Counted ONCE, not once by each rule. An inflated number is a number nobody can check.
    counts = scan_bytes(b"/Users/alex/.cargo/x.rs", DEFAULT_ALLOWED, "/Users/alex")
    ok = counts == {"/Users/alex": 1}
    bad += not ok
    print(f"{'ok  ' if ok else 'FAIL'} an overlapping finding is counted once: {counts}")

    # The bare-home rule must not fire on a DIFFERENT account whose name merely starts
    # with this one; that finding belongs to the heuristic and names the longer prefix.
    counts = scan_bytes(b"/Users/alexandra/work/x.rs", DEFAULT_ALLOWED, "/Users/alex")
    ok = counts == {"/Users/alexandra": 1}
    bad += not ok
    print(f"{'ok  ' if ok else 'FAIL'} a longer account name is reported as itself: {counts}")

    # The remap the fix installs must produce something this check calls clean.
    remapped = b"/cargo/registry/src/index.crates.io-1949cf8/anyhow-1.0.104/src/error.rs"
    ok = not scan_bytes(remapped, DEFAULT_ALLOWED)
    bad += not ok
    print(f"{'ok  ' if ok else 'FAIL'} remapped path is clean")

    return 1 if bad else 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(add_help=True, description=__doc__.splitlines()[0])
    ap.add_argument("target", nargs="?", help="a .app bundle, a directory, or a file")
    ap.add_argument("--home", default=os.environ.get("HOME"), help="this machine's home directory")
    ap.add_argument("--allow", action="append", default=[], metavar="NAME",
                    help="an additional user name to treat as a placeholder")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()
    if not args.target:
        ap.print_usage(sys.stderr)
        return 2
    if not os.path.exists(args.target):
        print(f"no-host-paths: {args.target} does not exist", file=sys.stderr)
        return 2

    allowed = DEFAULT_ALLOWED | set(args.allow)
    return report(scan(args.target, allowed, args.home), args.target, args.quiet)


if __name__ == "__main__":
    sys.exit(main())
