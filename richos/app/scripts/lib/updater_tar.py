#!/usr/bin/env python3
"""Build the macOS updater payload — `RichOS.app.tar.gz` — from a bundle that is ALREADY SIGNED.

WHY THIS EXISTS AT ALL, and it is not a preference.

`tauri-bundler` 2.9.4 creates this archive itself when `bundle.createUpdaterArtifacts` is
true (`src/bundle.rs:206-225` -> `bundle/updater_bundle.rs:bundle_update_macos`), and the
Tauri CLI then signs it (`tauri-cli-2.11.4/src/bundle.rs:sign_updaters`). Both of those run
INSIDE `cargo tauri build`, which is BEFORE `package-app.sh` ad-hoc signs the `.app`: the
bundler signs a macOS bundle only when it has a real identity, and with none it leaves the
`.app` unsigned around a linker-signed executable (measured, and asserted by
`package-app.sh`'s `verify_bundle`).

So the archive the vendor produces on the ad-hoc path is a tarball of an UNSIGNED
application, minisigned to say it is genuine. It would install, and it would install a
bundle `codesign --verify` rejects. `package-app.sh` therefore deletes that artifact and
re-creates it here, after the `.app` has been signed and verified.

WHY PYTHON AND NOT `tar`. macOS's bsdtar writes AppleDouble `._*` sidecar members for
extended attributes unless `COPYFILE_DISABLE` is set, and those members would be unpacked
into the installed bundle by the updater, which extracts every entry
(`tauri-plugin-updater-2.11.0/src/updater.rs:1305-1320`). Python's `tarfile` writes exactly
the members it is given, keeps symlinks as symlinks, and preserves the mode bits — including
the executable bit on `Contents/MacOS/<binary>`, without which the installed app cannot
launch at all.

THE LAYOUT IS NOT FREE — the updater's extractor does `entry.path()?.iter().skip(1)`, i.e.
it DROPS the first path component. So every member must be `RichOS.app/...` and not
`Contents/...`; an archive rooted one level in extracts into an empty bundle. That is the
same layout `append_dir_all(src_dir.file_name(), src_dir)` produces on the vendor's path,
and `--verify` below re-reads the finished archive and asserts it.

Members are emitted in sorted order and with uid/gid/uname/gname cleared, so two runs over
the same bundle differ only in mtimes. That is not full reproducibility and is not claimed
to be; it removes the differences that have nothing to do with the app.

    updater_tar.py build   <path/to/RichOS.app> <path/to/RichOS.app.tar.gz>
    updater_tar.py verify  <path/to/RichOS.app.tar.gz>
"""

import hashlib
import os
import sys
import tarfile


def _members(app_dir, top):
    """Every entry under the bundle, sorted, as `<top>/<relative path>`."""
    out = [(top, app_dir)]
    for root, dirs, files in os.walk(app_dir, followlinks=False):
        dirs.sort()
        files.sort()
        for name in dirs + files:
            full = os.path.join(root, name)
            rel = os.path.relpath(full, app_dir)
            out.append((os.path.join(top, rel), full))
    # os.walk does not yield symlinks-to-directories under `files`; it puts them in `dirs`
    # and would then DESCEND into them with followlinks=True. With followlinks=False it
    # does not descend, and the entry is added above and written as a symlink below.
    return sorted(set(out))


def build(app_path, out_path):
    app_path = os.path.abspath(app_path)
    if not os.path.isdir(app_path):
        sys.exit("updater_tar.py: not a bundle directory: %s" % app_path)
    top = os.path.basename(app_path)
    if not top.endswith(".app"):
        sys.exit("updater_tar.py: expected a .app bundle, got: %s" % top)

    count = 0
    with tarfile.open(out_path, "w:gz") as tar:
        for arcname, full in _members(app_path, top):
            info = tar.gettarinfo(full, arcname=arcname)
            info.uid = 0
            info.gid = 0
            info.uname = ""
            info.gname = ""
            if info.isreg():
                with open(full, "rb") as fh:
                    tar.addfile(info, fh)
            else:
                # Directories and symlinks carry no payload. `gettarinfo` already read the
                # link target for a symlink; adding it with no file object keeps it a
                # symlink rather than dereferencing it into a copy.
                tar.addfile(info)
            count += 1

    size = os.path.getsize(out_path)
    digest = hashlib.sha256(open(out_path, "rb").read()).hexdigest()
    print("  archive : %s" % out_path)
    print("  members : %d, all rooted at %s/" % (count, top))
    print("  bytes   : %d" % size)
    print("  sha256  : %s" % digest)
    return 0


def verify(archive):
    """Re-read the finished archive and assert the three things that make it installable."""
    failures = []
    tops = set()
    exec_bits = 0
    symlinks = 0
    with tarfile.open(archive, "r:gz") as tar:
        names = tar.getnames()
        for m in tar.getmembers():
            parts = m.name.split("/")
            tops.add(parts[0])
            if m.issym() or m.islnk():
                symlinks += 1
            if m.isreg() and (m.mode & 0o111):
                exec_bits += 1
            if m.name.startswith("/") or ".." in parts:
                failures.append("member escapes the archive root: %s" % m.name)

    if len(tops) != 1:
        failures.append(
            "members are rooted at %d different names (%s) — the updater drops the FIRST "
            "path component, so every member must share one root" % (len(tops), sorted(tops))
        )
    else:
        top = tops.pop()
        if not top.endswith(".app"):
            failures.append("the single root is %r, not a .app bundle" % top)
        if ("%s/Contents/Info.plist" % top) not in names:
            failures.append("no %s/Contents/Info.plist — this would extract into an empty bundle" % top)

    if any(os.path.basename(n).startswith("._") for n in names):
        failures.append(
            "AppleDouble `._*` members are present — bsdtar wrote xattr sidecars, and the "
            "updater unpacks every entry it finds"
        )
    if exec_bits == 0:
        failures.append("no member carries an executable bit — the installed app cannot launch")

    if failures:
        print("FAILED — this archive is not installable:")
        for f in failures:
            print("  - %s" % f)
        return 1

    print("  OK: %d member(s), one root, Info.plist present, %d executable, %d symlink(s)"
          % (len(names), exec_bits, symlinks))
    return 0


if __name__ == "__main__":
    if len(sys.argv) >= 4 and sys.argv[1] == "build":
        sys.exit(build(sys.argv[2], sys.argv[3]))
    if len(sys.argv) >= 3 and sys.argv[1] == "verify":
        sys.exit(verify(sys.argv[2]))
    sys.exit(__doc__)
