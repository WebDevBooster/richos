"""Case by case, both ways: is each still-red c3 case red because its fixture
records no integration branch (point 14), or for some other reason?

Not asserted -- run. The committed probes are untouched; the `-recorded` copies
are the /tmp derivatives written by adapt-c3.py."""
import os, subprocess, sys

LIB = "/Users/alex/ab/richos-wt/zach-opus-g3/engine/scripts/lib/workspaces.py"
JOBS = [
    ("frank-c3", "/tmp/claude-501/g3/frank-c3.py", "/tmp/claude-501/g3/frank-c3-recorded.py",
     ["outside-stray", "outside-side", "floor-trap", "floor-control", "no-floor-self-heals",
      "floor-timing", "rich-at-my-tip", "serial-stray", "serial-side", "serial-rename"]),
    ("sage-c3", "/tmp/claude-501/g3/sage-c3.py", "/tmp/claude-501/g3/sage-c3-recorded.py",
     ["S1", "S2", "S3", "S4", "S5", "S6", "S7", "S8", "S9", "S10"]),
]


def run(path, case):
    r = subprocess.run([sys.executable, "-B", path, LIB, case],
                       capture_output=True, text=True)
    return r.returncode == 0


for label, plain, recorded, cases in JOBS:
    print("=== %s" % label)
    for c in cases:
        a = run(plain, c)
        b = run(recorded, c)
        if a and b:
            verdict = "green both ways"
        elif b and not a:
            verdict = "RED ONLY WITHOUT A RECORDED BRANCH  <- the fixture, not the build"
        elif a and not b:
            verdict = "green only WITHOUT a record — the case is ABOUT the no-record state"
        else:
            verdict = "RED BOTH WAYS  <- a real question, not the fixture"
        print("    %-22s %s" % (c, verdict))
