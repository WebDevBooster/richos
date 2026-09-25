// hand-file.js — the guest half of hand-file.sh. Runs under `osascript -l JavaScript`, with a
// `var HAND_PARAMS = {...};` block prepended by the host (built by python3, never interpolated).
//
// Two ways a person hands an app a file, and nothing else:
//   paste  the file goes on the pasteboard the way macOS puts it there (a PNG as image data,
//          which is what a screenshot to the clipboard is; anything else as a file reference,
//          which is what Finder's Copy is), then Command-V goes to the app under test by PID.
//   drag   the file is placed on the guest user's Desktop, where Finder gives it a screen
//          position, and a real mouse drag (CoreGraphics events) carries it from its icon to
//          the point given. The app receives an ordinary Finder drag; nothing about the app is
//          bypassed.
//
// Every key and every drag is refused unless the app under test is FRONTMOST by PID first —
// the discipline ax.sh has carried since a synthetic Command-Q reached the operator's Terminal
// on 2026-09-19. This runs only inside the owned test guest.
ObjC.import("AppKit");
ObjC.import("CoreGraphics");

function run() {
  var P = HAND_PARAMS;
  var se = Application("System Events");
  function out(o) { return JSON.stringify(o); }
  function error(code, why) { return out({ error: code, reason: String(why) }); }
  function frontPid() {
    var f = se.processes.whose({ frontmost: true });
    return f.length ? f[0].unixId() : 0;
  }
  var fm = $.NSFileManager.defaultManager;
  if (!fm.fileExistsAtPath(P.path)) return error("nofile", "no such file in the guest: " + P.path);
  var procs = se.processes.whose({ unixId: P.pid });
  if (!procs.length) return error("noprocess", "no process with pid " + P.pid);
  var proc = procs[0];
  var name = P.path.split("/").pop();

  function bringToFront() {
    proc.frontmost = true;
    for (var i = 0; i < 20 && frontPid() !== P.pid; i++) delay(0.1);
    return frontPid() === P.pid;
  }

  if (P.mode === "paste") {
    var pb = $.NSPasteboard.generalPasteboard;
    var saved = pb.stringForType($.NSPasteboardTypeString);
    var savedText = saved && !saved.isNil() ? saved.js : null;
    pb.clearContents;
    var ext = (name.split(".").pop() || "").toLowerCase();
    var as;
    var wrote;
    if (ext === "png") {
      wrote = pb.setDataForType($.NSData.dataWithContentsOfFile(P.path), $.NSPasteboardTypePNG);
      as = "image data (public.png), as a screenshot to the clipboard puts it";
    } else {
      wrote = pb.writeObjects($([$.NSURL.fileURLWithPath(P.path)]));
      as = "a file reference (public.file-url), as Finder's Copy puts it";
    }
    if (!wrote) return error("pasteboard", "the pasteboard refused the file");
    try {
      if (!bringToFront()) return error("notfront", "refusing: the app under test is not frontmost, so no key was sent");
      se.keystroke("v", { using: "command down" });
      delay(0.8);
    } finally {
      pb.clearContents;
      if (savedText !== null) pb.setStringForType($(savedText), $.NSPasteboardTypeString);
    }
    return out({ handed: "paste", file: name, as: as, pid: P.pid });
  }

  if (P.mode === "drag") {
    var desktop = $.NSHomeDirectory().js + "/Desktop";
    var placed = desktop + "/" + name;
    if (!fm.fileExistsAtPath(placed)) {
      if (!fm.copyItemAtPathToPathError(P.path, placed, $())) return error("copyfailed", "could not place the file on the Desktop");
    }
    // The icon's on-screen box comes from the ACCESSIBILITY tree of Finder's desktop, read
    // through System Events, which the guest is already granted. NEVER from Finder's own
    // scripting (`Application("Finder")...desktopPosition()`): that is an Apple Event to Finder,
    // which raises a "wants access to control Finder" consent dialog in the guest that nobody
    // can answer, and the whole call then hangs to its deadline. Measured on 2026-09-24 in
    // walk-c9772ad8c468, the first run that reached that fallback. A new icon can take a moment
    // to appear, so the tree is polled for up to ten seconds.
    var at = null;
    for (var tries = 0; tries < 50 && !at; tries++) {
      try {
        var icons = se.processes.byName("Finder").scrollAreas[0].groups[0].images.whose({ name: name });
        if (icons.length) {
          var pos = icons[0].position(), size = icons[0].size();
          at = { x: pos[0] + size[0] / 2, y: pos[1] + size[1] / 2, from: "finder-ax" };
        }
      } catch (e) {}
      if (!at) delay(0.2);
    }
    if (!at) return error("noicon", "Finder's desktop never showed " + name + " in its accessibility tree within 10 s; nothing was dragged");
    if (!bringToFront()) return error("notfront", "refusing: the app under test is not frontmost, so nothing was dragged");
    function mouse(type, x, y) {
      var ev = $.CGEventCreateMouseEvent($(), type, { x: x, y: y }, 0);
      $.CGEventPost(0, ev);
    }
    // 5 moved, 1 left down, 6 left dragged, 2 left up (CGEventType).
    mouse(5, at.x, at.y);
    delay(0.2);
    mouse(1, at.x, at.y);
    delay(0.3);
    // Past the system's drag threshold first, then across, in steps a hand would take.
    for (var s = 1; s <= 6; s++) { mouse(6, at.x - s * 3, at.y + s * 2); delay(0.03); }
    var sx = at.x - 18, sy = at.y + 12, steps = 40;
    for (var k = 1; k <= steps; k++) {
      mouse(6, sx + (P.tox - sx) * k / steps, sy + (P.toy - sy) * k / steps);
      delay(0.025);
    }
    delay(0.3);
    mouse(2, P.tox, P.toy);
    delay(0.8);
    return out({ handed: "drag", file: name, from: at, to: { x: P.tox, y: P.toy }, pid: P.pid });
  }
  return error("usage", "mode must be paste or drag");
}
