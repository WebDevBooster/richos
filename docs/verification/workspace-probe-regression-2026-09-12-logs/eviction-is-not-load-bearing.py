"""Is the AGE-based eviction load-bearing, or does the unpaired-Post fallback
alone rescue frank's leaked-window-evicts case? Measure it; do not guess."""
import os, re, shutil, subprocess, sys, tempfile

SRC = "/Users/alex/ab/richos-wt/zach-opus-g3/engine/scripts/lib/workspaces.py"
PROBE = "/tmp/claude-501/g3/frank-c4.py"
s = open(SRC, encoding="utf-8").read()

old_evict = s[s.index("def _evict_old_slots(key):"):s.index("def _local_refs(repo):")]
legacy = '''def _evict_old_slots(key):
    slots = _open_slots(key)
    if len(slots) <= _MAX_OPEN_CALLS:
        return
    try:
        slots.sort(key=os.path.getmtime)
    except OSError:
        pass
    for p in slots[:len(slots) - _MAX_OPEN_CALLS]:
        try:
            os.unlink(p)
        except OSError:
            pass


'''
variants = {
    "as shipped in this branch": s,
    "legacy eviction (64, oldest-by-position), fallback KEPT":
        s.replace(old_evict, legacy).replace("_MAX_OPEN_CALLS = 4096", "_MAX_OPEN_CALLS = 64"),
    "age eviction KEPT, unpaired-Post fallback removed":
        s.replace('        paths = [p] if os.path.exists(p) else _open_slots(key)[:1]',
                  '        paths = [p] if os.path.exists(p) else []'),
    "legacy eviction AND no fallback":
        s.replace(old_evict, legacy).replace("_MAX_OPEN_CALLS = 4096", "_MAX_OPEN_CALLS = 64")
         .replace('        paths = [p] if os.path.exists(p) else _open_slots(key)[:1]',
                  '        paths = [p] if os.path.exists(p) else []'),
}
for name, text in variants.items():
    d = tempfile.mkdtemp(prefix="evict-")
    lib = os.path.join(d, "workspaces.py")
    open(lib, "w", encoding="utf-8").write(text)
    r = subprocess.run([sys.executable, "-B", PROBE, lib, "leaked-window-evicts"],
                       capture_output=True, text=True)
    verdict = "HOLDS" if r.returncode == 0 else "BROKEN"
    print("%-58s %s" % (name, verdict))
    shutil.rmtree(d, ignore_errors=True)
