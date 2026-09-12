"""Build derived copies of the two reviewers' probes with ONE line added to the
fixture -- the `workspaces.sh integration` recording point 14 requires before the
first spawn -- so the attribution cases can be judged on attribution rather than
on a repository that has no recorded integration branch. The committed probes are
not modified; these copies live in /tmp."""
import io

for src, dst, anchor in (
        ("/tmp/sage-probe.py", "/tmp/g2/sage-probe-recorded.py",
         '        self.sid = "sess-sage-22222222"\n        self.session(self.sid, self.entity)\n'),
        ("/tmp/frank-probe.py", "/tmp/g2/frank-probe-recorded.py", None)):
    s = io.open(src, encoding="utf-8").read()
    if anchor is None:
        # find frank's session line
        import re
        m = re.search(r'\n(        self\.sid = "[^"]+"\n        self\.session\(self\.sid, self\.entity\)\n)', s)
        assert m, "frank's fixture anchor not found"
        anchor = m.group(1)
    assert s.count(anchor) == 1, (src, anchor)
    add = anchor + (
        "        for _r in [self.entity] + ([self.other] if hasattr(self, 'other') else []):\n"
        "            self.ws.record_integration(_r, 'main', 'the probe body of work', self.sid)\n")
    io.open(dst, "w", encoding="utf-8").write(s.replace(anchor, add))
    print("wrote", dst)
