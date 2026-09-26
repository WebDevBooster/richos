#!/usr/bin/env python3
"""phone-apps-independent.test.py -- the iPhone app and the Android app each have their own version,
and raising one never touches the other or its tests.

WHY (CEO ruling §91, 2026-09-26): "the mobile apps MUST HAVE THEIR OWN VERSION and therefore also
MUST HAVE THEIR OWN BUILDS", and "does every bug fix in iOS need to needlessly bump the version of
Android and needlessly create a build for that and vice versa?" The acceptance criterion: an
iPhone-only fix changes only the iPhone version and builds only the iPhone app; an Android-only fix
likewise.

Until 2026-09-26 a headless test (client-part2.test.js) held native-ios MARKETING_VERSION and
native-android versionName equal to release-config.json, and mobile-headless.test.sh (a suite the
desktop build runs) named both files as inputs so a version-only change ran it. So raising the
iPhone version ran a test that read the Android version and failed until Android was raised too.

The rules, each checked by name:

  V1  each app's version is set in ONE file inside that app's own tree, and at least one suite
      filed under that app in phone-app-suites.tsv reads that file, so a raise is proven by the
      app that was raised.
  V2  raising one app's version selects none of the other app's suites and no desktop-build suite
      that reaches into a phone app's tree. Every suite the land selects for it is filed under
      that app, or selects it only through an input holding BOTH apps (richos/mobile or above):
      a repository tool that tests neither app.
  V3  nothing holds the two versions together: no code file outside the two app trees names both
      an iPhone version key and an Android version key. This suite's own three files are the one
      exception, declared here, because they must name both to check them.
  V4  the land's own selector (proof-for.sh --paths) selects exactly what V2 reasoned about, so
      these rules describe what actually runs.

The declarations are read with the same parser proof-for.sh uses (lib/proof_declarations.py).
Nothing builds, launches or opens a network connection. Overrides, for the mutation check only:
PHONE_APPS_SCRIPTS (a directory of *.test.sh and phone-app-suites.tsv) and PHONE_APPS_SCAN
(os.pathsep-separated directories V3 scans).
"""
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE / "lib"))
from proof_declarations import read_declarations  # noqa: E402

SCRIPTS = Path(os.environ.get("PHONE_APPS_SCRIPTS") or HERE)
SCAN = [Path(p) for p in (os.environ.get("PHONE_APPS_SCAN") or
                          os.pathsep.join([str(ROOT / "richos/mobile"), str(ROOT / "richos/app/scripts")])).split(os.pathsep)]

# One version source per app, inside that app's own tree, with the keys that set it there.
APPS = {
    "ios": {"tree": "richos/mobile/native-ios", "source": "richos/mobile/native-ios/project.yml",
            "keys": ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION", "CFBundleShortVersionString", "CFBundleVersion"),
            "name": "iPhone"},
    "android": {"tree": "richos/mobile/native-android", "source": "richos/mobile/native-android/app/build.gradle.kts",
                "keys": ("versionName", "versionCode"), "name": "Android"},
}
OWN_FILES = {"phone-apps-independent.test.sh", "phone-apps-independent.test.py", "phone-apps-independent.mutation.py"}
CODE = {".js", ".mjs", ".cjs", ".ts", ".py", ".sh", ".swift", ".kt", ".kts", ".yml", ".yaml", ".json", ".rb"}
SKIP_DIRS = {"node_modules", "build", ".gradle", "target", "DerivedData", ".build", "__pycache__"}

PASSED = FAILED = 0


def check(ok, what, detail=""):
    global PASSED, FAILED
    if ok:
        PASSED += 1
        print("  ok    %s" % what)
    else:
        FAILED += 1
        print("  FAIL  %s%s" % (what, ("\n        %s" % detail) if detail else ""))


def phone_suites():
    """suite -> set of apps, from phone-app-suites.tsv (the same file run-tests.sh --for reads)."""
    rows = {}
    for line in (SCRIPTS / "phone-app-suites.tsv").read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        suite, apps, _reason = line.split("\t", 2)
        rows[suite] = set(apps.split(","))
    return rows


def selects(dep, path):
    return path == dep or path.startswith(dep + "/")


def holds_both(dep):
    return all(selects(dep, app["tree"]) for app in APPS.values())


declarations = read_declarations(ROOT, SCRIPTS)
filed = phone_suites()


def selected_by(path):
    """suite -> the inputs that select `path`, exactly as proof-for.sh selects a script suite."""
    return {suite: [dep for dep in inputs if selects(dep, path)]
            for suite, inputs, _covers in declarations if any(selects(dep, path) for dep in inputs)}


for app_id, app in APPS.items():
    other = next(a for a in APPS if a != app_id)
    source, name = app["source"], app["name"]
    chosen = selected_by(source)

    # V1
    check((ROOT / source).is_file() and selects(app["tree"], source),
          "V1 the %s app's version is set in its own tree, in %s" % (name, source))
    own = sorted(s for s in chosen if app_id in filed.get(s, ()))
    check(bool(own), "V1 a suite filed under the %s app proves an %s version change: %s" % (name, name, ", ".join(own) or "none"),
          "no suite filed under %s in phone-app-suites.tsv has an input that selects %s" % (app_id, source))

    # V2
    wrong = []
    for suite, deps in sorted(chosen.items()):
        apps = filed.get(suite)
        if apps is not None and app_id not in apps:
            wrong.append("%s is filed under %s only, and %s selects it" % (suite, ",".join(sorted(apps)), " ".join(deps)))
        elif apps is None and not all(holds_both(dep) for dep in deps):
            wrong.append("%s runs in the desktop build and reads the %s app's tree through %s"
                         % (suite, name, " ".join(d for d in deps if not holds_both(d))))
    check(not wrong, "V2 raising the %s version selects none of the %s app's suites and no desktop suite that reads the %s tree"
          % (name, APPS[other]["name"], name), "; ".join(wrong))

    # V4
    env = dict(os.environ, PROOF_FOR_SCRIPT_DIR=str(SCRIPTS))
    run = subprocess.run(["bash", str(HERE / "proof-for.sh"), "--quiet", "--paths", source],
                         capture_output=True, text=True, env=env, cwd=str(ROOT))
    ran = set(re.findall(r"--only (\S+)", run.stdout))
    check(run.returncode == 0 and ran == set(chosen),
          "V4 proof-for.sh selects exactly these suites for an %s version change: %s" % (name, ", ".join(sorted(ran)) or "none"),
          "exit %d; proof-for.sh %s, declarations %s; %s" % (run.returncode, sorted(ran), sorted(chosen), run.stderr.strip()[-400:]))

# V3
pattern = {a: re.compile(r"\b(%s)\b" % "|".join(APPS[a]["keys"])) for a in APPS}
trees = [ROOT / app["tree"] for app in APPS.values()]
both = []
for base in SCAN:
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not any(Path(dirpath, d) == t for t in trees)]
        for filename in filenames:
            path = Path(dirpath, filename)
            if path.suffix not in CODE or filename in OWN_FILES:
                continue
            try:
                text = path.read_text(errors="replace")
            except OSError:
                continue
            if all(pattern[a].search(text) for a in APPS):
                both.append(str(path.relative_to(ROOT)) if ROOT in path.parents else str(path))
check(not both, "V3 no code outside the two app trees names both the iPhone and the Android version keys",
      "these files read both apps' versions, so a raise of one breaks on the other: " + ", ".join(sorted(both)))

print("phone-apps-independent: %d passed, %d failed" % (PASSED, FAILED))
sys.exit(1 if FAILED else 0)
