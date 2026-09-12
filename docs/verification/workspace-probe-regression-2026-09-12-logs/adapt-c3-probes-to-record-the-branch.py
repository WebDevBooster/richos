"""not-a-probe: this BUILDS probes, it asserts nothing of its own, and the
runner would otherwise report it UNRUNNABLE and block on it forever.

THE COMMITTED PROBES ARE NOT MODIFIED. These are derived copies in /tmp with
ONE line added to the fixture -- the `workspaces.sh integration` recording that
point 14 requires before the first spawn -- so the question "is every remaining
red case caused by the fixture recording nothing?" can be answered by running
them rather than asserted.

Same shape as the g2 round's own adapter, which lives at
docs/verification/workspace-window-and-target-2026-09-12-logs/."""
import io, os, subprocess, sys

LIB = "/Users/alex/ab/richos-wt/zach-opus-g3/engine/scripts/lib/workspaces.py"
JOBS = [
    ("/tmp/claude-501/g3/frank-c3.py", "/tmp/claude-501/g3/frank-c3-recorded.py",
     '        self.sid = "sess-frank-c3000001"\n        self.session(self.sid, self.entity)\n'),
    ("/tmp/claude-501/g3/sage-c3.py", "/tmp/claude-501/g3/sage-c3-recorded.py",
     '        self.sid = "sess-sage-22222222"\n        self.session(self.sid, self.entity)\n'),
]
for src, dst, anchor in JOBS:
    s = io.open(src, encoding="utf-8").read()
    assert s.count(anchor) == 1, (src, s.count(anchor))
    add = anchor + (
        "        for _r in [self.entity] + ([self.other] if hasattr(self, 'other') else []):\n"
        "            try:\n"
        "                self.ws.record_integration(_r, 'main', 'the probe body of work', self.sid)\n"
        "            except Exception:\n"
        "                pass\n")
    io.open(dst, "w", encoding="utf-8").write(s.replace(anchor, add))
    r = subprocess.run([sys.executable, "-B", dst, LIB], capture_output=True, text=True)
    tail = [l for l in r.stdout.splitlines() if "cases hold" in l or "held:" in l]
    print("%-34s exit %d   %s" % (os.path.basename(src), r.returncode,
                                  tail[-1].strip() if tail else "(no summary)"))
