#!/usr/bin/env python3
"""foreign_app_data.py — RichOS never reads another app's data. The rule, in one place.

WHAT HAPPENED. On 2026-09-24 and 2026-09-25 the CEO kept getting a macOS dialog:
"python3.14" would like to access data from other apps. Don't Allow / Allow. The unified log
names the cause exactly (private record:
richos-hq/docs/verification/2026-09-25-app-data-prompts/README.md). The disk watchdog's
launchd job (com.richos.disk-watchdog) runs Homebrew's python3.14. When an alert was
firing, it ran `du -sk` over every path in DISK_CONSUMER_CANDIDATES to name the biggest
consumers. One of those paths was the per-user folder where macOS keeps other apps' sandboxed
data. The kernel's System Policy stopped `du` at Voice Memos, Mail, Messages, Notes,
Safari, Maps, Home, Stocks and News. tccd then put up the "App Data" prompt, attributed to
the responsible process, python3.14.

WHY CLICKING "ALLOW" NEVER FIXED IT. The same log shows the CEO allowed it at 05:01:42.
The next run prompted again at 05:17:57, with tccd logging "Session scoped auth is invalid
for client". Homebrew's interpreter carries no stable code-signing identity, so macOS
tracks it by path, and a grant to a path-identified client lasts only for that
process. Every 15-minute run is a new process. The prompt cannot be answered away. The
only fix is not to read other apps' data at all.

WHAT MACOS PROTECTS. App Data protection, TCC service kTCCServiceSystemPolicyAppData:
since macOS 14, the per-app and per-daemon container folders under your Library; since
macOS 15, the shared app-group folders as well (the three are PROTECTED_RELATIVE below). Reading inside any of them, or walking a folder that holds them (your home
folder or its Library), is what triggers the prompt. A process started by RichOS.app is
attributed to RichOS, so for a user the prompt would say "RichOS".

THE TWO HALVES OF THE RULE, BOTH HERE:
  entering(path)   runtime: would measuring or walking `path` enter another app's data?
                   Callers that walk a configured list (the disk watchdog) refuse such a
                   path instead of walking it.
  scan(roots)      static: source lines that name those folders, or that start a recursive
                   walk at the home folder or its Library. Used by the engine's and the app's
                   test suites, so a violation fails a suite before it reaches anybody's Mac.

EXEMPTIONS ARE DECLARED, NEVER INFERRED. A line that must name one of these folders (this
file, or a test that builds a fake one in a sandbox) carries
`foreign-app-data-exempt: <reason>` on the same line, where a reviewer can see it. A bare
marker with no reason exempts nothing.

WHAT THE STATIC SCAN CANNOT SEE, stated so it is not over-trusted: a walk whose root comes from a
variable that holds your home folder is data flow, which a line scan cannot follow. The watchdog's
runtime guard covers its own configured list. An agent session's own shell commands are
not source code at all.

Usage:
  foreign_app_data.py scan [--exclude-tests] <file-or-dir>...   exit 0 clean, 1 findings, 2 bad input
  foreign_app_data.py check <path> [--home DIR]                 exit 0 allowed, 1 enters app data
  foreign_app_data.py --self-test
"""

import os
import re
import sys

# The per-user folders macOS guards with App Data protection, relative to the home folder.
PROTECTED_RELATIVE = (
    os.path.join("Library", "Containers"),  # foreign-app-data-exempt: the rule's own list of protected folders
    os.path.join("Library", "Group Containers"),  # foreign-app-data-exempt: the rule's own list of protected folders
    os.path.join("Library", "Daemon Containers"),  # foreign-app-data-exempt: the rule's own list of protected folders
)


def _home(home=None):
    return home or os.environ.get("HOME") or os.path.expanduser("~")


def protected_roots(home=None):
    h = os.path.realpath(_home(home))
    return [os.path.join(h, rel) for rel in PROTECTED_RELATIVE]


def _norm(path):
    return os.path.realpath(os.path.expanduser(path)).rstrip(os.sep) or os.sep


def entering(path, home=None):
    """A sentence saying why walking `path` would enter another app's data, or None.

    Three shapes, all of them walks `du -sk` or os.walk would make:
      inside   the path is one of those folders or below one
      holds    the path is an ancestor of one (the home folder, its Library)
    The comparison is on resolved paths, so a symlink pointing into a container is caught.
    """
    if not path:
        return None
    p = _norm(path)
    for root in protected_roots(home):
        r = _norm(root)
        if p == r or p.startswith(r + os.sep):
            return "%s is inside %s, which macOS protects as another app's data" % (path, r)
        if r.startswith(p + os.sep) or p == os.sep:
            return "%s holds %s, so walking it walks other apps' data" % (path, r)
    return None


# ---------------------------------------------------------------------------
# the static scan
# ---------------------------------------------------------------------------

EXEMPT = re.compile(r"foreign-app-data-exempt:\s*\S")

# R1: any spelling of the three folders. The separators cover `Library/Containers`,
# `"Library", "Containers"`, `.join("Library").join("Containers")` and
# `home / "Library" / "Group Containers"`.
R1 = re.compile(
    r"Library(?:[\s/\\\"',()]|\.join\(|\.push\()*(?:Group |Daemon )?Containers\b"
    r"|Group Containers|Daemon Containers")  # foreign-app-data-exempt: the pattern that refuses them

_HOME_TOKEN = r"(?:\"?\$\{?HOME\}?\"?|~)(?:/Library)?/?(?=[\"'\s;|&)`]|$)"
# R2: a recursive walk or measurement that STARTS at the home folder or its Library.
R2_SHELL = re.compile(
    r"(?:^|[\s;|&(`])(?:du|find|tree|rg|ag|tar|zip|"
    r"grep\s+-[A-Za-z]*[rR][A-Za-z]*|ls\s+-[A-Za-z]*R[A-Za-z]*)"
    r"(?:\s+[^\s;|&]+)*?\s+" + _HOME_TOKEN)
_PY_HOME = (r"(?:os\.path\.expanduser\(\s*[\"']~(?:/Library)?/?[\"']\s*\)"
            r"|os\.environ\[\s*[\"']HOME[\"']\s*\]|os\.environ\.get\(\s*[\"']HOME[\"'][^)]*\)"
            r"|str\(\s*Path\.home\(\)\s*\)|Path\.home\(\)(?:\s*/\s*[\"']Library[\"'])?)")
R2_PY = re.compile(
    r"(?:os\.walk|os\.fwalk|shutil\.copytree|shutil\.disk_usage_walk|glob\.glob)\(\s*" + _PY_HOME
    + r"\s*[,)]"
    r"|Path\.home\(\)(?:\s*/\s*[\"']Library[\"'])?\s*\)?\.(?:rglob|walk)\(")
R2_RUST = re.compile(
    r"WalkDir::new\(\s*&?(?:dirs::home_dir\(\)|home_dir\(\)|std::env::var(?:_os)?\(\s*\"HOME\"\s*\))")
# R3: a configured list of walk roots that holds the home folder or its Library bare.
R3_CONFIG = re.compile(
    r"^\s*(?:export\s+)?[A-Z][A-Z0-9_]*(?:CANDIDATES|ROOTS|PATHS|DIRS)\s*=\s*[\"']?[^\n]*?"
    r"(?:^|[\s\"'=])" + _HOME_TOKEN)

SOURCE_SUFFIXES = (".sh", ".bash", ".zsh", ".py", ".rs", ".js", ".mjs", ".cjs", ".ts",
                   ".swift", ".kt", ".config", ".plist", ".toml")
SKIP_DIRS = {".git", "node_modules", "target", "docs", "reference", "fixtures", "__pycache__",
             ".build", "build", "dist"}


def _is_test(path):
    b = os.path.basename(path)
    parts = path.split(os.sep)
    return (".test." in b or b.startswith("test_") or b.endswith("_test.py")
            or b.endswith("_tests.rs") or "tests" in parts or ".mutation." in b)


def _comment_only(line):
    s = line.lstrip()
    return s.startswith(("#", "//", "/*", "* ", "*/", "--")) or s == "*"


def scan_text(text, name="<text>"):
    """[(line_no, rule, line)] for every finding in `text`."""
    out = []
    for i, line in enumerate(text.splitlines(), 1):
        if _comment_only(line) or EXEMPT.search(line):
            continue
        for rule, rx in (("names-app-data", R1), ("walks-home", R2_SHELL),
                         ("walks-home", R2_PY), ("walks-home", R2_RUST),
                         ("walk-root-is-home", R3_CONFIG)):
            if rx.search(line):
                out.append((i, rule, line.strip()))
                break
    return out


def iter_sources(root, exclude_tests):
    if os.path.isfile(root):
        yield root
        return
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        for f in sorted(filenames):
            p = os.path.join(dirpath, f)
            if not (f.endswith(SOURCE_SUFFIXES) or f == "orchestration.config"):
                continue
            if exclude_tests and _is_test(p):
                continue
            yield p


def scan(roots, exclude_tests=False):
    findings = []
    for root in roots:
        for p in iter_sources(root, exclude_tests):
            try:
                with open(p, encoding="utf-8", errors="replace") as fh:
                    text = fh.read()
            except OSError:
                continue
            for n, rule, line in scan_text(text, p):
                findings.append((p, n, rule, line))
    return findings


# ---------------------------------------------------------------------------
# self-test: every refusal has an acceptance beside it
# ---------------------------------------------------------------------------

def self_test():
    # foreign-app-data-exempt: this table IS the list of spellings the scan must refuse
    must_find = [
        'DISK_CONSUMER_CANDIDATES="$TMPDIR $HOME/Library/Containers"',  # foreign-app-data-exempt: self-test case
        'p = os.path.join(home, "Library", "Containers", ident)',  # foreign-app-data-exempt: self-test case
        'let p = home.join("Library").join("Group Containers");',  # foreign-app-data-exempt: self-test case
        'du -sk "$HOME"',
        'du -sh ~/Library',
        'find ~ -name "*.log"',
        'find "$HOME/Library" -type f',
        'grep -rn secret ~',
        'for r, d, f in os.walk(os.path.expanduser("~")):',  # foreign-app-data-exempt: self-test case
        'files = list(Path.home().rglob("*.json"))',  # foreign-app-data-exempt: self-test case
        'for e in WalkDir::new(dirs::home_dir().unwrap()) {',  # foreign-app-data-exempt: self-test case
        'SCAN_ROOTS="$HOME/ab $HOME"',
        'du -sk "$HOME/ab" "$HOME"',
        'tar -czf backup.tgz ~',
        'y = "Library/Containers"  # foreign-app-data-exempt:',  # foreign-app-data-exempt: a bare marker must exempt nothing
    ]
    must_pass = [
        'DISK_CONSUMER_CANDIDATES="$TMPDIR /private/tmp $HOME/.claude $HOME/ab $HOME/Library/Caches"',
        'du -sk "$HOME/ab"',
        'find ~/ab -name "*.log"',
        'find "$HOME/Library/Developer/CoreSimulator" -maxdepth 1',
        'p = os.path.join(home, "Library", "Application Support", ident)',
        'for r, d, f in os.walk(os.path.expanduser("~/ab")):',
        'home.join("Library").join("Logs").join("RichOS")',
        '# the watchdog never measures other apps\' Containers',
        'x = "Library/Containers"  # foreign-app-data-exempt: names the folder in order to refuse it',
        'cd ~',
        'ls ~',
        'cd ~ && find . -name x',
        'mkdir -p ~/.richos && du -sk ~/.richos',
    ]
    bad = 0
    for s in must_find:
        got = scan_text(s)
        print(("  ok   refused  " if got else "  FAIL missed   ") + s)
        bad += 0 if got else 1
    for s in must_pass:
        got = scan_text(s)
        print(("  ok   allowed  " if not got else "  FAIL refused  ") + s)
        bad += 1 if got else 0
    home = "/Users/someone"
    cases = [
        (home + "/Library/Containers", True),  # foreign-app-data-exempt: self-test case
        (home + "/Library/Group Containers/group.x", True),  # foreign-app-data-exempt: self-test case
        (home + "/Library", True),
        (home, True),
        ("/", True),
        (home + "/Library/Caches", False),
        (home + "/Library/Developer", False),
        (home + "/ab", False),
        ("/Volumes/E1TB/vm", False),
    ]
    for path, want in cases:
        got = entering(path, home=home) is not None
        print(("  ok   " if got == want else "  FAIL ") + "entering(%s) = %s" % (path, got))
        bad += 0 if got == want else 1
    print("%d failure(s)" % bad)
    return 1 if bad else 0


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    if argv[0] == "--self-test":
        return self_test()
    if argv[0] == "check":
        if len(argv) < 2:
            return 2
        home = argv[argv.index("--home") + 1] if "--home" in argv else None
        why = entering(argv[1], home=home)
        if why:
            print(why)
            return 1
        return 0
    if argv[0] == "scan":
        args = argv[1:]
        exclude = "--exclude-tests" in args
        roots = [a for a in args if a != "--exclude-tests"]
        if not roots:
            sys.stderr.write("foreign_app_data.py scan: no roots given\n")
            return 2
        missing = [r for r in roots if not os.path.exists(r)]
        if missing:
            sys.stderr.write("foreign_app_data.py scan: missing root(s): %s — refusing to "
                             "report a clean scan over nothing\n" % " ".join(missing))
            return 2
        findings = scan(roots, exclude_tests=exclude)
        for p, n, rule, line in findings:
            print("%s:%d: [%s] %s" % (p, n, rule, line[:200]))
        if findings:
            print("\n%d line(s) would make macOS ask \"would like to access data from other "
                  "apps\". Walk a narrower folder, or, if the line only names the folder in "
                  "order to refuse it, add `foreign-app-data-exempt: <reason>` to it."
                  % len(findings))
            return 1
        return 0
    sys.stderr.write("unknown command: %s\n" % argv[0])
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
