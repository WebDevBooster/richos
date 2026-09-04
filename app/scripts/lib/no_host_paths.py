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

PATH = re.compile(
    r"(?:" + "|".join(re.escape(r) for r in HOME_ROOTS) + r")([A-Za-z0-9_.-]+)"
)


def runs(data: bytes):
    for m in RUN.finditer(data):
        yield m.group(0).decode("ascii")


def scan_bytes(data: bytes, allowed):
    """Return {offending_prefix: count} for one blob."""
    hits: dict[str, int] = {}
    for text in runs(data):
        for m in PATH.finditer(text):
            if m.group(1) in allowed:
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
        for prefix, count in sorted(scan_bytes(data, allowed).items()):
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
    # (blob, allowed, expect_findings)
    (b"nothing to see here at all", DEFAULT_ALLOWED, False),
    (b"/Users/you/Projects/northwind is a fixture", DEFAULT_ALLOWED, False),
    (b"/Users/example/Projects/harbor is a fixture", DEFAULT_ALLOWED, False),
    (b"/Users/alex/.cargo/registry/src/anyhow/src/error.rs", DEFAULT_ALLOWED, True),
    (b"/home/builder/src/richos/app/crates/richos-core/src/loro.rs", DEFAULT_ALLOWED, True),
    (b"/var/root/secret/thing.rs", DEFAULT_ALLOWED, True),
    # Short runs are invisible to `strings` and must be invisible here too, so the
    # check describes the same surface an attacker actually reads.
    (b"\x00\x01/Us\x00", DEFAULT_ALLOWED, False),
    # A real name added to --allow is not a finding; that is what the flag is for.
    (b"/Users/ci-runner/work/x.rs", DEFAULT_ALLOWED | {"ci-runner"}, False),
]


def self_test() -> int:
    bad = 0
    for i, (blob, allowed, expect) in enumerate(SELF_TEST_CASES, 1):
        got = bool(scan_bytes(blob, allowed))
        ok = got == expect
        bad += not ok
        print(f"{'ok  ' if ok else 'FAIL'} case {i}: expected findings={expect}, got={got}")

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
