#!/usr/bin/env python3
"""phone-apps-independent.mutation.py -- each rule of phone-apps-independent.test.py, watched going red.

WHY (CEO ruling §91, 2026-09-26): the iPhone app and the Android app are independent apps with
their own versions and their own builds. The test's rules only mean something if each can fail,
so every mutant below puts back ONE way the two were, or could again be, tied together, and the
rule that owns it must fail WITH the line that names it. A mutant caught by an incidental error
does not score. The unmutated run must pass first.

THE SHIPPED FILES ARE NEVER OPENED FOR WRITING. Suite declarations are mutated in a private copy
of this directory's *.test.sh and phone-app-suites.tsv (PHONE_APPS_SCRIPTS); a re-added tie is a
private copy of the file it was in (PHONE_APPS_SCAN); a mutant of the test's own reasoning is the
test's text compiled in memory under its real name, so every path it derives stays the real one.

Invoked by phone-apps-independent.test.sh. Exit 0 = every rule proven load-bearing.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
TEST = HERE / "phone-apps-independent.test.py"
IOS = "richos/mobile/native-ios/project.yml"
TIE = """test('the iPhone and Android apps ship one version, the one in release-config.json', () => {
  const setting = (file, pattern) => pattern.exec(readFileSync(join(__dirname, '..', file), 'utf8'))[1];
  assert.equal(setting('native-ios/project.yml', /^\\s*MARKETING_VERSION:\\s*"([^"]+)"/m), version);
  assert.equal(setting('native-android/app/build.gradle.kts', /^\\s*versionName\\s*=\\s*"([^"]+)"/m), version);
});
"""

# Runs the (possibly mutated) test text under its real file name.
LAUNCHER = "import sys; source = open(sys.argv[1]).read(); exec(compile(source, sys.argv[2], 'exec'), {'__name__': '__main__', '__file__': sys.argv[2]})"


def add_input(suite, path):
    def edit(scripts):
        file = scripts / suite
        lines = file.read_text().splitlines(keepends=True)
        hits = [i for i, line in enumerate(lines) if line.startswith("# run-tests: inputs ")]
        assert len(hits) == 1, suite
        lines[hits[0]] = lines[hits[0]].rstrip("\n") + " " + path + "\n"
        file.write_text("".join(lines))
    return edit


def refile(prefix, apps):
    def edit(scripts):
        file = scripts / "phone-app-suites.tsv"
        rows = []
        for line in file.read_text().splitlines(keepends=True):
            if line.startswith(prefix) and "\t" in line:
                suite, _apps, reason = line.split("\t", 2)
                line = "\t".join([suite, apps, reason])
            rows.append(line)
        file.write_text("".join(rows))
    return edit


def text_edit(before, after):
    def edit(source):
        assert source.count(before) == 1, before
        return source.replace(before, after)
    return edit


# (name, scripts edit, re-added tie?, test-text edit, the line that must FAIL)
MUTANTS = (
    ("a desktop suite reads the iPhone version file again (490d4707)", add_input("mobile-headless.test.sh", IOS), False, None,
     "mobile-headless.test.sh runs in the desktop build and reads the iPhone app's tree through " + IOS),
    ("a desktop suite reads the Android version file again (490d4707)",
     add_input("mobile-headless.test.sh", "richos/mobile/native-android/app/build.gradle.kts"), False, None,
     "mobile-headless.test.sh runs in the desktop build and reads the Android app's tree"),
    ("an Android suite reads the iPhone version file", add_input("native-android-ui.test.sh", IOS), False, None,
     "native-android-ui.test.sh is filed under android only"),
    ("the suites that build the iPhone app are filed under Android", refile("native-ios-", "android"), False, None,
     "native-ios-app.test.sh is filed under android only"),
    ("no suite filed under the iPhone app reads its version", refile("native-", "android"), False, None,
     "V1 a suite filed under the iPhone app proves an iPhone version change: none"),
    ("a test holds the two versions together again (0394da20)", None, True, None,
     "these files read both apps' versions"),
    ("the rule's selection disagrees with the land's (directory inputs ignored)", None, False,
     text_edit("return path == dep or path.startswith(dep + \"/\")", "return path == dep"),
     "V4 proof-for.sh selects exactly these suites"),
)


def run(work, scripts_edit=None, tie=False, test_edit=None):
    scripts = work / "scripts"
    shutil.rmtree(work, ignore_errors=True)
    scripts.mkdir(parents=True)
    for file in list(HERE.glob("*.test.sh")) + [HERE / "phone-app-suites.tsv"]:
        shutil.copy2(file, scripts / file.name)
    if scripts_edit:
        scripts_edit(scripts)
    env = dict(os.environ, PHONE_APPS_SCRIPTS=str(scripts), PYTHONDONTWRITEBYTECODE="1")
    if tie:
        scan = work / "mobile"
        (scan / "test").mkdir(parents=True)
        (scan / "test/client-part2.test.js").write_text((ROOT / "richos/mobile/test/client-part2.test.js").read_text() + TIE)
        env["PHONE_APPS_SCAN"] = str(scan)
    source = TEST.read_text()
    if test_edit:
        source = test_edit(source)
    (work / "test.py").write_text(source)
    result = subprocess.run([sys.executable, "-c", LAUNCHER, str(work / "test.py"), str(TEST)],
                            capture_output=True, text=True, env=env, cwd=str(ROOT), timeout=120)
    return result.returncode, result.stdout + result.stderr


def failing(output, expected):
    return any(line.startswith("  FAIL  ") and expected in line or line.startswith("        ") and expected in line
               for line in output.splitlines())


def main():
    base = Path(tempfile.mkdtemp(prefix="phone-apps-mutation.", dir=os.environ.get("TMPDIR") or None))
    failed = 0
    try:
        code, output = run(base / "unmutated")
        if code == 0 and "0 failed" in output:
            print("  ok    unmutated: every rule passes")
        else:
            failed += 1
            print("  FAIL  unmutated: the rules do not pass on the real tree (exit %d)\n%s" % (code, output[-2000:]))
        for number, (name, scripts_edit, tie, test_edit, expected) in enumerate(MUTANTS):
            code, output = run(base / ("m%d" % number), scripts_edit, tie, test_edit)
            if code == 1 and failing(output, expected):
                print("  ok    caught: %s" % name)
            else:
                failed += 1
                print("  FAIL  survived: %s (exit %d; expected a failing line with %r)\n%s" % (name, code, expected, output[-2000:]))
    finally:
        shutil.rmtree(base, ignore_errors=True)
    print("phone-apps-independent.mutation: %d of %d passed" % (len(MUTANTS) + 1 - failed, len(MUTANTS) + 1))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
