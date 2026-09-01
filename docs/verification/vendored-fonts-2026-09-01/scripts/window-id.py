"""Print the CGWindowID of the on-screen windows owned by a given pid.

Used so the app's window can be photographed WHERE IT IS, off-screen, instead of
being dragged onto the CEO's display to be looked at.
"""
import sys
import Quartz

pid = int(sys.argv[1])
opts = Quartz.kCGWindowListOptionAll
info = Quartz.CGWindowListCopyWindowInfo(opts, Quartz.kCGNullWindowID)
for w in info:
    if w.get("kCGWindowOwnerPID") != pid:
        continue
    b = w.get("kCGWindowBounds", {})
    print(
        "%d\t%s\t%s\t%dx%d at (%d,%d)\tlayer=%s"
        % (
            w.get("kCGWindowNumber", 0),
            w.get("kCGWindowOwnerName", ""),
            w.get("kCGWindowName", ""),
            b.get("Width", 0),
            b.get("Height", 0),
            b.get("X", 0),
            b.get("Y", 0),
            w.get("kCGWindowLayer"),
        )
    )
