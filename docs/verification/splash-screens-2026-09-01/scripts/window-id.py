"""Print the CGWindowID of the on-screen windows owned by a given pid.

Used so the app's own window can be photographed WHERE IT IS, by its backing store,
instead of the CEO's whole display being captured to get at it.
"""
import sys
import Quartz

pid = int(sys.argv[1])
info = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID)
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
