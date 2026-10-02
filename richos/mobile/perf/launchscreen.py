#!/usr/bin/env python3
"""launchscreen.py — is the first thing each phone app shows, before any of its code runs, empty?

    launchscreen.py [--root DIR] [--json]      every launch surface, EMPTY or SHOWS, and why

THE RULE (CEO, 2026-10-02): from the moment any part of the app is visible, something useful or
pleasing is on screen; a screen showing the app's logo is not blank, a flat color is. Before the
app's own code draws, the phone shows a launch surface the app only DECLARES, so whether it is
empty can be read from the source without a phone. The frame analyzer (blank.py) judges what the
phone actually showed; this judges the declaration, at every commit.

The surfaces, read from source:

  iphone        The launch screen. It SHOWS something when the app's Info.plist or project.yml
                names a launch storyboard that exists and holds an image view or a label, or a
                `UILaunchScreen` whose `UIImageName` is an image set in the app's asset catalog. A
                generated launch screen (`INFOPLIST_KEY_UILaunchScreen_Generation`) with no image
                is EMPTY: one flat color for as long as the app takes to draw.
  android-31+   Android 12 and later draw the system splash screen: the window background with the
                app's icon in the middle (`windowSplashScreenAnimatedIcon`, the launcher icon when
                unset). EMPTY when the theme suppresses the icon (transparent, @null or a color) or
                the manifest names no icon.
  android-pre31 Android 10 and 11 (when minSdk is below 31) draw the theme's `windowBackground`
                and nothing else. EMPTY when that is a color, or a drawable with no bitmap, vector
                or other drawable layer in it.

Exit 0 when nothing is EMPTY, 1 when something is (each with its reason), 2 when a source it needs
is missing (a moved file is a broken check, never a pass).
"""
import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
IOS = "richos/mobile/native-ios"
ANDROID = "richos/mobile/native-android/app"
ANDROID_RES = ANDROID + "/src/main/res"


class Missing(Exception):
    pass


def _read(root, rel):
    path = os.path.join(root, rel)
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        raise Missing(f"{rel} is missing: the launch surface cannot be read from source")


def _walk(root, rel, suffixes):
    base = os.path.join(root, rel)
    for d, dirs, names in os.walk(base):
        dirs[:] = [x for x in dirs if x not in (".build", "build", "DerivedData", ".gradle")]
        for n in names:
            if n.endswith(suffixes):
                yield os.path.join(d, n)


def _text(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


# ------------------------------------------------------------------------------------------------
# iPhone
# ------------------------------------------------------------------------------------------------

def iphone(root):
    project = _read(root, IOS + "/project.yml")
    plists = [p for p in _walk(root, IOS + "/App", (".plist",))]
    sources = [project] + [_text(p) for p in plists]
    storyboards = {os.path.splitext(os.path.basename(p))[0]: p for p in _walk(root, IOS, (".storyboard",))}
    imagesets = {os.path.basename(p)[:-len(".imageset")]
                 for d, dirs, _ in os.walk(os.path.join(root, IOS, "App")) for p in (os.path.join(d, x) for x in dirs)
                 if p.endswith(".imageset")}
    for text in sources:
        for name in re.findall(r"UILaunchStoryboardName(?:</key>\s*<string>|:\s*\"?)([\w.-]+)", text):
            board = storyboards.get(name)
            if board and re.search(r"<(imageView|label)\b", _text(board)):
                return {"empty": False, "why": f"launch storyboard {name} with an image view or a label"}
        for name in re.findall(r"UIImageName(?:</key>\s*<string>|:\s*\"?)([\w.-]+)", text):
            if name in imagesets:
                return {"empty": False, "why": f"UILaunchScreen image {name} (an image set in the asset catalog)"}
    if re.search(r"INFOPLIST_KEY_UILaunchScreen_Generation:\s*\"?YES", project):
        return {"empty": True, "why": "the launch screen is generated (INFOPLIST_KEY_UILaunchScreen_Generation in "
                                      "native-ios/project.yml) with no UIImageName and no storyboard: one flat color"}
    return {"empty": True, "why": "no launch storyboard with content and no UILaunchScreen image is declared"}


# ------------------------------------------------------------------------------------------------
# Android
# ------------------------------------------------------------------------------------------------

def _style(themes, name):
    m = re.search(r'<style\s+name="%s"[^>]*>(.*?)</style>' % re.escape(name), themes, re.S)
    return m.group(1) if m else None


def _item(style, attr):
    m = re.search(r'<item\s+name="(?:android:)?%s">\s*([^<\s]+)\s*</item>' % re.escape(attr), style or "")
    return m.group(1) if m else None


def _min_sdk(root):
    for rel in (ANDROID + "/build.gradle.kts", ANDROID + "/build.gradle"):
        try:
            m = re.search(r"minSdk\s*=?\s*(\d+)", _read(root, rel))
        except Missing:
            continue
        if m:
            return int(m.group(1))
    raise Missing(f"no minSdk in {ANDROID}/build.gradle(.kts)")


def _drawable_shows(root, ref):
    """Does @drawable/x (or @mipmap/x) draw anything but a color?"""
    kind, _, name = ref.lstrip("@").partition("/")
    if kind not in ("drawable", "mipmap"):
        return False
    found = [p for p in _walk(root, ANDROID_RES, (".xml", ".png", ".webp"))
             if os.path.basename(os.path.dirname(p)).startswith(kind) and os.path.splitext(os.path.basename(p))[0] == name]
    for p in found:
        if not p.endswith(".xml"):
            return True                       # a bitmap
        x = _text(p)
        if re.search(r"<(bitmap|vector|adaptive-icon|animated-vector)\b", x):
            return True
        for inner in re.findall(r'android:drawable="(@(?:drawable|mipmap)/[\w.]+)"', x):
            if _drawable_shows(root, inner):
                return True
    return False


def android(root):
    manifest = _read(root, ANDROID + "/src/main/AndroidManifest.xml")
    theme_ref = re.search(r'<application\b[^>]*android:theme="@style/([\w.]+)"', manifest, re.S)
    icon = re.search(r'<application\b[^>]*android:icon="(@[\w]+/[\w.]+)"', manifest, re.S)
    if not theme_ref:
        raise Missing("the manifest's <application> names no @style theme")
    name = theme_ref.group(1)
    styles = {}
    for p in _walk(root, ANDROID_RES, ("themes.xml", "styles.xml")):
        styles[os.path.basename(os.path.dirname(p))] = _style(_text(p), name) or styles.get(os.path.basename(os.path.dirname(p)))
    base = styles.get("values")
    if base is None:
        raise Missing(f"style {name} is not in res/values/themes.xml or styles.xml")
    v31 = next((s for d, s in styles.items() if s and re.match(r"values(-night)?-v3[1-9]", d)), None)
    out = {}

    splash_icon = _item(v31, "windowSplashScreenAnimatedIcon") or _item(base, "windowSplashScreenAnimatedIcon")
    if not icon or not _drawable_shows(root, icon.group(1)):
        out["android-31+"] = {"empty": True, "why": "the manifest's <application> names no icon that draws: the system splash has nothing to show"}
    elif splash_icon and (splash_icon in ("@null", "@android:color/transparent") or splash_icon.startswith(("@color/", "#", "@android:color/"))):
        out["android-31+"] = {"empty": True, "why": f"windowSplashScreenAnimatedIcon is {splash_icon}: the system splash shows no icon"}
    elif splash_icon and not _drawable_shows(root, splash_icon):
        out["android-31+"] = {"empty": True, "why": f"windowSplashScreenAnimatedIcon {splash_icon} draws nothing"}
    else:
        out["android-31+"] = {"empty": False, "why": "the system splash shows "
                              + (f"{splash_icon}" if splash_icon else f"the launcher icon {icon.group(1)}")
                              + " on the window background"}

    if _min_sdk(root) < 31:
        background = _item(base, "windowBackground")
        if background and _drawable_shows(root, background):
            out["android-pre31"] = {"empty": False, "why": f"windowBackground {background} draws a picture"}
        else:
            out["android-pre31"] = {"empty": True, "why": f"windowBackground is {background or 'unset'} in {name}: Android 10 and 11 "
                                    "(minSdk is below 31) show this one flat color until the first frame"}
    return out


def surfaces(root=REPO):
    out = {"iphone": iphone(root)}
    out.update(android(root))
    return out


def main(argv=None):
    p = argparse.ArgumentParser(prog="launchscreen.py", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--root", default=REPO, help="the richos checkout (default: the one this file is in)")
    p.add_argument("--json", action="store_true")
    args = p.parse_args(argv)
    try:
        found = surfaces(args.root)
    except Missing as e:
        print(f"launchscreen.py: cannot answer: {e}", file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps(found, indent=2))
    else:
        for name, v in found.items():
            print(f"{name:14s} {'EMPTY' if v['empty'] else 'SHOWS'}  {v['why']}")
    return 1 if any(v["empty"] for v in found.values()) else 0


if __name__ == "__main__":
    sys.exit(main())
