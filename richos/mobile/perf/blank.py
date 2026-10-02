#!/usr/bin/env python3
"""blank.py — does the phone show a blank screen, or a layout that jumps, after the user taps the app?

    blank.py analyze VIDEO [--tap-at S] [--from S] [--to S]     the verdict, as JSON
    blank.py frames VIDEO [--from S] [--to S] [--png DIR]       what it saw in each frame, one line each
                                                                (--png: each analyzed frame as a PNG, to look at)
    blank.py series VIDEO [VIDEO ...]                            several starts judged as one series (p95)
    blank.py limit                                              the limit and every threshold it judges by

THE RULE (CEO, 2026-10-02): never show the user a blank screen for any noticeable amount of time.
From the moment any part of the app is visible, something useful or pleasing is on screen. A blank
or white screen is never useful, and recoloring it does not make it useful. A screen showing the
app's logo is NOT blank. "Noticeable" is `BLANK_LIMIT_MS` below: 400 ms, above the Android release
cold start he calls fine and below the half second he named as painful (the reason is beside the
constant). This file is the one place that number lives; perf.py, the tests and the record read it
from here.

What it reads. A screen recording of the phone, decoded by framedump.swift beside this file
(macOS's own AVFoundation, no installed decoder), every frame scaled to `ANALYSIS_WIDTH` pixels wide
with the time the recording gives it. A variable-rate recording (Android's screenrecord writes a
frame only when the screen changes) keeps its gaps: a frame lasts until the next one.

What it judges, measured from the tap:
  * A BLANK FRAME shows nothing but background: under `MIN_CONTENT_SHARE` of the screen (system
    bars excluded) differs by more than `TOLERANCE` from the frame's dominant color. White, one flat
    color and a near-uniform fill are all blank; so is a spinner on an empty screen (a spinner is
    far under 1% of a phone screen). A designed element (an icon, a logo, a picture) or any content
    makes it not blank. So is an EMPTY WINDOW covering `WINDOW_MIN_COVER` of the screen or more
    with a sliver of home screen still around it (the iPhone's launch screen while the system's
    opening animation finishes).
  * A BLANK STRETCH is a run of blank frames. It begins earlier when the system's opening animation
    was already growing that same blank window: the frames just before it in which the blank color
    covers at least `OPENING_RISE` more of the screen than it did before the tap, AND the area it
    covers is itself empty (`empty_window`: a window growing over the home screen, not a logo on the
    ground), belong to it. It ends at the first frame with content. A stretch still blank when the
    recording ends is `open`.
  * A JUMP is content drawn and then moved: a frame whose content matches the settled screen only
    when shifted vertically by at least `JUMP_MIN_SHIFT` of the screen (content first at the top,
    then moved to the bottom). Content that appears in place, or that gains rows in place, is not
    a jump. A JUMP STRETCH runs from the first misplaced frame to the first frame in place.
  * THE TAP is `--tap-at` when the caller knows it on the recording's clock; otherwise it is the
    first frame that differs from the recording's first frame (the home screen reacting to the
    tap), which needs the recording to start on a still home screen for `STILL_BEFORE_TAP_MS`. The
    record says which.

Verdict on ONE start: FAIL when any blank stretch or jump stretch lasts longer than
`BLANK_LIMIT_MS`; exit 1. PASS, exit 0. Exit 2 with a sentence when it cannot answer: the video
does not decode, the tap cannot be found, or the screen had not settled `SETTLE_MS` before the
recording ended (a jump cannot be judged without the settled screen). A FAIL found before an
unsettled end still fails.

Verdict on a SERIES of starts (`series`, and perf.py's cold-start check): each start's worst
stretch (its longest blank or jump stretch, 0 when it had none) is one sample; the series FAILS
when the nearest-rank p95 of those samples (from `SERIES_P95_FROM` starts; their median under
that) is over `BLANK_LIMIT_MS`. Every start over the limit is
listed with its recording whatever the verdict, so an outlier is shown and never hidden. A start
that cannot be answered fails the series: a start nobody could judge is not a start that passed.

Phone evidence stays private: recordings are read where they are (the external SSD), and nothing
here copies a frame anywhere. The repository's tests (richos/app/scripts/mobile-blank.test.py) use
synthetic frames only.
"""
import argparse
import collections
import json
import os
import shutil
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# THE limit. Change it here and everything that judges a start changes with it.
# 400 ms: above the Android release cold start the CEO calls fine (flat stretch up to 350 ms) and
# below the half second he named as already painful, 2026-10-02.
BLANK_LIMIT_MS = 400
# A series of starts is judged by one statistic of its per-start worst stretches (perfcore's nearest
# rank): from SERIES_P95_FROM starts its p95, as the speed benchmarks judge a series; under that, its
# median (lead, 2026-10-02: the nearest-rank p95 of fewer than 20 starts IS the slowest start, so a
# single outlier would decide it). Every start over the limit is listed whatever the verdict.
SERIES_P95_FROM = 20
SERIES_SMALL_PERCENTILE = 50

ANALYSIS_WIDTH = 144            # pixels across, after scaling; a line of text still darkens what it crosses
SYSTEM_BARS = (0.06, 0.05)      # top and bottom share of the screen left out: the status bar and the home
                                # indicator or navigation bar are the system's, drawn over every app
TOLERANCE = 16                  # largest channel difference (0-255) still counted as the background color
MIN_CONTENT_SHARE = 0.01        # under 1% of the screen differing from the background is a blank frame
OPENING_RISE = 0.10             # the opening animation: the blank color covers this much more than before the tap
OPENING_INSET = 0.10            # ...and the area it covers, inset by this much on each side, is itself empty
WINDOW_MIN_COVER = 0.5          # an empty window covering half the screen or more is a blank frame, whatever
                                # sliver of home screen still frames it (the iPhone's opening animation)
CHANGE_SHARE = 0.005            # share of pixels that must change for "the screen reacted" (the tap)
STILL_BEFORE_TAP_MS = 300       # the recording must open on a still screen at least this long
SETTLE_MS = 500                 # the screen must be still this long before the recording ends
JUMP_MIN_SHIFT = 0.05           # a move of at least 5% of the screen height
JUMP_MIN_GAIN = 0.25            # the moved picture matches at least 25% more of the content than in place
JUMP_MIN_MATCH = 0.6            # and at least 60% of it, pixel for pixel: the same content, moved
JUMP_CANDIDATES = 5             # shifts shortlisted from the row profiles before the pixel comparison


class CannotAnswer(Exception):
    """The recording cannot be judged; the message says why in one sentence."""


class Frame:
    __slots__ = ("t", "w", "h", "rgb")

    def __init__(self, t, w, h, rgb):
        if len(rgb) != w * h * 3:
            raise ValueError(f"a {w}x{h} frame needs {w * h * 3} bytes, got {len(rgb)}")
        self.t, self.w, self.h, self.rgb = float(t), w, h, bytes(rgb)


# ------------------------------------------------------------------------------------------------
# decoding
# ------------------------------------------------------------------------------------------------

def parse_dump(data):
    """framedump.swift's stream: a header line, then (8-byte little-endian time, RGB) per frame."""
    nl = data.find(b"\n")
    if nl < 0 or not data.startswith(b"RFD1 "):
        raise CannotAnswer("the decoder's output has no RFD1 header")
    fields = data[:nl].decode("ascii").split()
    try:
        w, h, sw, sh, count = (int(x) for x in fields[1:6])
        duration = float(fields[6])
    except (ValueError, IndexError):
        raise CannotAnswer(f"the decoder's header is malformed: {data[:nl][:80]!r}")
    size = w * h * 3
    body = data[nl + 1:]
    if len(body) != count * (8 + size):
        raise CannotAnswer(f"the decoder promised {count} frames and wrote {len(body)} bytes, not {count * (8 + size)}")
    frames = []
    for i in range(count):
        at = i * (8 + size)
        (t,) = struct.unpack("<d", body[at:at + 8])
        frames.append(Frame(t, w, h, body[at + 8:at + 8 + size]))
    return frames, {"source": f"{sw}x{sh}", "analysis": f"{w}x{h}", "durationS": round(duration, 3)}


def decode(video, width=ANALYSIS_WIDTH, runner=subprocess.run):
    if not os.path.isfile(video):
        raise CannotAnswer(f"no such recording: {video}")
    swift = shutil.which("swift")
    if not swift:
        raise CannotAnswer("swift is not on PATH: the frames are decoded with macOS AVFoundation through framedump.swift")
    p = runner([swift, "-O", os.path.join(HERE, "framedump.swift"), video, str(width)],
               capture_output=True, timeout=600)
    if p.returncode:
        raise CannotAnswer(f"the recording did not decode: {p.stderr.decode(errors='replace').strip()[-300:]}")
    return parse_dump(p.stdout)


# ------------------------------------------------------------------------------------------------
# one frame
# ------------------------------------------------------------------------------------------------

def _rows(frame):
    top = int(frame.h * SYSTEM_BARS[0])
    bottom = frame.h - int(frame.h * SYSTEM_BARS[1])
    return top, max(top + 1, bottom)


def dominant(frame):
    """The frame's background: the mean of the most common 16-level color bin (system bars excluded)."""
    top, bottom = _rows(frame)
    data = frame.rgb[top * frame.w * 3:bottom * frame.w * 3]
    keys = collections.Counter((data[i] >> 4, data[i + 1] >> 4, data[i + 2] >> 4) for i in range(0, len(data), 3))
    (kr, kg, kb), _ = keys.most_common(1)[0]
    sr = sg = sb = n = 0
    for i in range(0, len(data), 3):
        if data[i] >> 4 == kr and data[i + 1] >> 4 == kg and data[i + 2] >> 4 == kb:
            sr += data[i]
            sg += data[i + 1]
            sb += data[i + 2]
            n += 1
    return (round(sr / n), round(sg / n), round(sb / n))


def content_profile(frame, color):
    """Per analyzed row, the share of pixels that are not `color` (within TOLERANCE)."""
    top, bottom = _rows(frame)
    r0, g0, b0 = color
    w, rgb, profile = frame.w, frame.rgb, []
    for y in range(top, bottom):
        row = rgb[y * w * 3:(y + 1) * w * 3]
        off = 0
        for i in range(0, len(row), 3):
            if abs(row[i] - r0) > TOLERANCE or abs(row[i + 1] - g0) > TOLERANCE or abs(row[i + 2] - b0) > TOLERANCE:
                off += 1
        profile.append(off / w)
    return profile


def share_of(frame, color):
    p = content_profile(frame, color)
    return 1.0 - sum(p) / len(p)


def empty_window(frame, color):
    """Is the area `color` covers itself empty? Its bounding box, inset by OPENING_INSET on each side,
    holds under MIN_CONTENT_SHARE of other pixels. True for a blank window growing over the home
    screen (what lies outside it is the launcher); False for a logo on the ground."""
    top, bottom = _rows(frame)
    r0, g0, b0 = color
    w, rgb = frame.w, frame.rgb
    match = []
    x0, x1, y0, y1 = w, -1, bottom, -1
    for y in range(top, bottom):
        row = []
        for x in range(w):
            i = (y * w + x) * 3
            same = abs(rgb[i] - r0) <= TOLERANCE and abs(rgb[i + 1] - g0) <= TOLERANCE and abs(rgb[i + 2] - b0) <= TOLERANCE
            row.append(same)
            if same:
                x0, x1, y0, y1 = min(x0, x), max(x1, x), min(y0, y), max(y1, y)
        match.append(row)
    if x1 < 0:
        return False
    dx = int((x1 - x0 + 1) * OPENING_INSET)
    dy = int((y1 - y0 + 1) * OPENING_INSET)
    inside = other = 0
    for y in range(y0 + dy, y1 - dy + 1):
        for x in range(x0 + dx, x1 - dx + 1):
            inside += 1
            other += not match[y - top][x]
    return inside > 0 and other / inside < MIN_CONTENT_SHARE


def changed_share(a, b):
    """Share of pixels whose color moved by more than TOLERANCE between two frames (whole screen)."""
    n = a.w * a.h
    moved = 0
    ra, rb = a.rgb, b.rgb
    for i in range(0, n * 3, 3):
        if abs(ra[i] - rb[i]) > TOLERANCE or abs(ra[i + 1] - rb[i + 1]) > TOLERANCE or abs(ra[i + 2] - rb[i + 2]) > TOLERANCE:
            moved += 1
    return moved / n


def shift_candidates(profile, settled, keep=JUMP_CANDIDATES):
    """Vertical shifts (rows, never 0) ranked by how much of this frame's row profile the settled
    screen's profile holds there: cheap, and only a shortlist; moved_match decides."""
    total = sum(profile)
    if total == 0:
        return []
    h = len(profile)
    scored = []
    for s in range(-h // 2, h // 2 + 1):
        if s:
            acc = 0.0
            for y in range(max(0, -s), min(h, h - s)):
                acc += min(profile[y], settled[y + s])
            scored.append((acc / total, -abs(s), s))
    scored.sort(reverse=True)
    return [s for _, _, s in scored[:keep]]


def moved_match(frame, settled, ground, s):
    """Share of this frame's content pixels (not `ground`) found with the same color `s` rows lower
    on the settled screen: the same picture moved scores near 1, a different picture near 0."""
    top, bottom = _rows(frame)
    w, a, b = frame.w, frame.rgb, settled.rgb
    r0, g0, b0 = ground
    content = same = 0
    for y in range(top, bottom):
        yy = y + s
        inside = top <= yy < bottom
        for x in range(w):
            i = (y * w + x) * 3
            if abs(a[i] - r0) <= TOLERANCE and abs(a[i + 1] - g0) <= TOLERANCE and abs(a[i + 2] - b0) <= TOLERANCE:
                continue
            content += 1
            if inside:
                j = (yy * w + x) * 3
                if abs(a[i] - b[j]) <= TOLERANCE and abs(a[i + 1] - b[j + 1]) <= TOLERANCE and abs(a[i + 2] - b[j + 2]) <= TOLERANCE:
                    same += 1
    return same / content if content else 0.0


def write_png(frame, path):
    """The analyzed (scaled) frame as an 8-bit RGB PNG, standard library only."""
    import zlib
    raw = b"".join(b"\x00" + frame.rgb[y * frame.w * 3:(y + 1) * frame.w * 3] for y in range(frame.h))

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", frame.w, frame.h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def hexcolor(c):
    return "#%02X%02X%02X" % c


# ------------------------------------------------------------------------------------------------
# the recording
# ------------------------------------------------------------------------------------------------

def describe(frames):
    """Per frame: time, background, content share, blank or not. Blank is nothing but background
    (under MIN_CONTENT_SHARE), or an EMPTY WINDOW: the background covers at least WINDOW_MIN_COVER of
    the screen and the area it covers holds nothing (the launch screen during the opening animation,
    framed by a sliver of home screen, is what the eye lands on)."""
    out, seen = [], {}
    for f in frames:
        if f.rgb not in seen:
            c = dominant(f)
            p = content_profile(f, c)
            share = sum(p) / len(p)
            window = share >= MIN_CONTENT_SHARE and 1.0 - share >= WINDOW_MIN_COVER and empty_window(f, c)
            seen[f.rgb] = (c, p, share, share < MIN_CONTENT_SHARE or window)
        c, p, share, is_blank = seen[f.rgb]
        out.append({"t": f.t, "color": c, "profile": p, "content": share, "blank": is_blank})
    return out


def find_tap(frames, tap_at=None):
    """Index of the first frame at or after the tap, and how the tap was found."""
    if tap_at is not None:
        for i, f in enumerate(frames):
            if f.t >= tap_at - 1e-6:
                return i, f"given: {tap_at:.3f} s on the recording's clock"
        raise CannotAnswer(f"the recording ends before the given tap at {tap_at:.3f} s")
    ref = frames[0]
    for i, f in enumerate(frames[1:], 1):
        if changed_share(ref, f) > CHANGE_SHARE:
            still = (f.t - ref.t) * 1000
            if still < STILL_BEFORE_TAP_MS:
                raise CannotAnswer(f"the recording did not open on a still screen: it changed after {still:.0f} ms, "
                                   f"under {STILL_BEFORE_TAP_MS} ms, so the tap cannot be told from it (pass --tap-at)")
            return i, ("first visible reaction: the first frame differing from the still home screen the recording "
                       "opened on; the touch itself is up to one touch latency earlier")
    raise CannotAnswer("nothing on screen changed after the recording's first frame: no tap was recorded")


def analyze(frames, tap_at=None, duration=None):
    """The verdict on one recording of one start. `frames` are in time order; `duration` (seconds)
    is the recording's own length, so the last frame's lifetime is known."""
    if len(frames) < 2:
        raise CannotAnswer(f"{len(frames)} frame(s) is not a start")
    frames = sorted(frames, key=lambda f: f.t)
    end_t = max(duration or 0.0, frames[-1].t)
    tap_i, tap_how = find_tap(frames, tap_at)
    t0 = tap_at if tap_at is not None else frames[tap_i].t
    seen = describe(frames)

    def ms(t):
        return round((t - t0) * 1000.0, 1)

    # blank stretches, each with the opening-animation frames that were already growing it
    in_blank = [False] * len(frames)
    stretches, i = [], tap_i
    while i < len(frames):
        if not seen[i]["blank"]:
            i += 1
            continue
        j = i
        while j < len(frames) and seen[j]["blank"]:
            j += 1
        start = i
        color = seen[i]["color"]
        baseline = share_of(frames[0], color)
        while (start - 1 > tap_i and not seen[start - 1]["blank"]
               and share_of(frames[start - 1], color) - baseline >= OPENING_RISE
               and empty_window(frames[start - 1], color)):
            start -= 1
        for k in range(start, j):
            in_blank[k] = True
        begin = max(frames[start].t, t0)
        stop = frames[j].t if j < len(frames) else end_t
        colors = []
        for k in range(i, j):
            h = hexcolor(seen[k]["color"])
            if h not in colors:
                colors.append(h)
        stretches.append({"startMs": ms(begin), "lengthMs": round((stop - begin) * 1000.0, 1), "colors": colors,
                          "openingAnimationFrames": i - start, "open": j >= len(frames)})
        i = j

    # the settled screen, and content drawn on the app's own ground before it
    last = len(frames) - 1
    while last > 0 and changed_share(frames[last - 1], frames[-1]) <= CHANGE_SHARE / 5:
        last -= 1
    settled_since = frames[last].t
    settled = (end_t - settled_since) * 1000 >= SETTLE_MS
    final = seen[-1]
    ground = final["color"]

    def on_ground(k):
        return max(abs(a - b) for a, b in zip(seen[k]["color"], ground)) <= TOLERANCE

    app_content = [k for k in range(tap_i + 1, len(frames)) if not in_blank[k] and not seen[k]["blank"] and on_ground(k)]

    # jumps: content on the app's ground that matches the settled screen only when moved
    final_profile = content_profile(frames[-1], ground)
    shift_min = max(1, int(JUMP_MIN_SHIFT * len(final_profile)))
    jumps, misplaced, judged = [], {}, {}
    if not final["blank"]:
        for k in app_content:
            if frames[k].rgb not in judged:          # a constant-rate recording repeats frames: judge each picture once
                here = moved_match(frames[k], frames[-1], ground, 0)
                judged[frames[k].rgb] = any(
                    abs(s) >= shift_min and m >= JUMP_MIN_MATCH and m - here >= JUMP_MIN_GAIN
                    for s in shift_candidates(content_profile(frames[k], ground), final_profile)
                    for m in (moved_match(frames[k], frames[-1], ground, s),))
            misplaced[k] = judged[frames[k].rgb]
    k = tap_i + 1
    while k < len(frames):
        if not misplaced.get(k):
            k += 1
            continue
        m = k
        while m < len(frames) and misplaced.get(m):
            m += 1
        stop = frames[m].t if m < len(frames) else end_t
        jumps.append({"startMs": ms(frames[k].t), "lengthMs": round((stop - frames[k].t) * 1000.0, 1),
                      "open": m >= len(frames)})
        k = m

    over = [s for s in stretches if s["lengthMs"] > BLANK_LIMIT_MS]
    jumped = [s for s in jumps if s["lengthMs"] > BLANK_LIMIT_MS]
    why = [f"blank for {s['lengthMs']:.0f} ms from {s['startMs']:.0f} ms after the tap ({', '.join(s['colors'])})"
           + (", still blank when the recording ended" if s["open"] else "") for s in over]
    why += [f"content drawn and then moved: misplaced for {s['lengthMs']:.0f} ms from {s['startMs']:.0f} ms" for s in jumped]
    result = {
        "limitMs": BLANK_LIMIT_MS,
        "tap": tap_how,
        "frames": len(frames),
        "framesAfterTap": len(frames) - tap_i,
        "blankStretches": stretches,
        "blankMs": round(sum(s["lengthMs"] for s in stretches), 1),
        "longestBlankMs": max((s["lengthMs"] for s in stretches), default=0.0),
        "jumps": jumps,
        "settledMs": ms(settled_since),
        "settled": settled,
    }
    if why:
        result["verdict"], result["why"] = "FAIL", why
    elif not settled:
        raise CannotAnswer(f"the screen was still changing {round((end_t - settled_since) * 1000)} ms before the recording "
                           f"ended, under {SETTLE_MS} ms: record longer so the settled screen can be judged")
    else:
        result["verdict"], result["why"] = "PASS", []
    return result


def window(frames, start=None, stop=None):
    """The frames on screen between `start` and `stop` (seconds): a frame lasts until the next one,
    so the one already showing at `start` opens the window, dated `start`."""
    out = [f for f in frames if (start is None or f.t >= start) and (stop is None or f.t <= stop)]
    if start is not None and (not out or out[0].t > start):
        before = [f for f in frames if f.t < start]
        if before:
            out.insert(0, Frame(start, before[-1].w, before[-1].h, before[-1].rgb))
    return out


def analyze_video(video, tap_at=None, start=None, stop=None, runner=subprocess.run):
    """Decode and judge one recording; the result names the file and its geometry."""
    frames, meta = decode(video, runner=runner)
    duration = meta["durationS"] if stop is None else min(stop, meta["durationS"])
    result = analyze(window(frames, start, stop), tap_at=tap_at, duration=duration)
    result["recording"] = {"file": os.path.abspath(video), **meta}
    return result


def worst_ms(result):
    """One start's sample for a series: its longest blank or jump stretch, 0 when it had none."""
    return max([s["lengthMs"] for s in result["blankStretches"]] + [s["lengthMs"] for s in result["jumps"]] + [0.0])


def judge_series(starts):
    """A series of starts, each {"recording": path, "result": analyze() result} or {"recording",
    "error": why}. FAIL when the nearest-rank p95 of the per-start worst stretches is over the
    limit, or when any start could not be judged; every start over the limit is listed."""
    import perfcore
    samples, over, unanswered = [], [], []
    for s in starts:
        if s.get("error"):
            unanswered.append({"recording": s["recording"], "why": s["error"]})
            continue
        w = worst_ms(s["result"])
        samples.append(w)
        if w > BLANK_LIMIT_MS:
            over.append({"recording": s["recording"], "worstMs": w, "why": s["result"]["why"]})
    pct = 95 if len(samples) >= SERIES_P95_FROM else SERIES_SMALL_PERCENTILE
    name = "p95" if pct == 95 else "median"
    value = perfcore.percentile(samples, pct)
    why = []
    if not samples:
        why.append("no start could be judged")
    elif value > BLANK_LIMIT_MS:
        why.append(f"the {name} of {len(samples)} starts' longest blank stretch is {value:.0f} ms, over the {BLANK_LIMIT_MS} ms limit")
    if unanswered:
        why.append(f"{len(unanswered)} start(s) could not be judged")
    return {"limitMs": BLANK_LIMIT_MS,
            "rule": (f"FAIL when the {name} (nearest rank; the p95 from {SERIES_P95_FROM} starts, the median under that) of "
                     f"each start's longest blank or jump stretch is over {BLANK_LIMIT_MS} ms; every start over it is listed"),
            "statistic": name, "valueMs": value, "n": len(samples), "maxMs": max(samples) if samples else None,
            "samplesMs": samples, "overLimit": over, "unanswered": unanswered,
            "verdict": "FAIL" if why else "PASS", "why": why}


def series_of_videos(videos, runner=subprocess.run):
    starts = []
    for v in videos:
        try:
            starts.append({"recording": os.path.abspath(v), "result": analyze_video(v, runner=runner)})
        except CannotAnswer as e:
            starts.append({"recording": os.path.abspath(v), "error": str(e)})
    return judge_series(starts), starts


# ------------------------------------------------------------------------------------------------

def thresholds():
    return {"limitMs": BLANK_LIMIT_MS, "seriesP95From": SERIES_P95_FROM, "seriesSmallPercentile": SERIES_SMALL_PERCENTILE,
            "analysisWidth": ANALYSIS_WIDTH, "systemBars": SYSTEM_BARS,
            "tolerance": TOLERANCE, "minContentShare": MIN_CONTENT_SHARE, "openingRise": OPENING_RISE,
            "changeShare": CHANGE_SHARE, "stillBeforeTapMs": STILL_BEFORE_TAP_MS, "settleMs": SETTLE_MS,
            "openingInset": OPENING_INSET, "windowMinCover": WINDOW_MIN_COVER, "jumpMinShift": JUMP_MIN_SHIFT, "jumpMinGain": JUMP_MIN_GAIN, "jumpMinMatch": JUMP_MIN_MATCH,
            "source": "CEO 2026-10-02: no blank screen for any noticeable time; 400 ms is above the Android release "
                      "cold start he calls fine and below the half second he named as painful"}


def main(argv=None):
    p = argparse.ArgumentParser(prog="blank.py", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("analyze", help="the verdict on one recording, as JSON")
    f = sub.add_parser("frames", help="what each frame shows: time, background, content share")
    for q in (a, f):
        q.add_argument("video")
        q.add_argument("--from", dest="start", type=float, help="ignore frames before this time (s)")
        q.add_argument("--to", dest="stop", type=float, help="ignore frames after this time (s)")
    f.add_argument("--png", metavar="DIR", help="also write each analyzed frame there as <time>.png (keep phone frames private)")
    a.add_argument("--tap-at", type=float, help="the tap's time on the recording's clock (s), when known")
    sr = sub.add_parser("series", help="judge several starts as one series (p95), listing every start over the limit")
    sr.add_argument("videos", nargs="+")
    sub.add_parser("limit", help="the limit and every threshold, as JSON")
    args = p.parse_args(argv)
    try:
        if args.cmd == "limit":
            print(json.dumps(thresholds(), indent=2))
            return 0
        if args.cmd == "series":
            verdict, _ = series_of_videos(args.videos)
            print(json.dumps(verdict, indent=2))
            return 0 if verdict["verdict"] == "PASS" else 1
        if args.cmd == "frames":
            frames, meta = decode(args.video)
            print(json.dumps(meta))
            kept = window(frames, args.start, args.stop)
            if args.png:
                os.makedirs(args.png, exist_ok=True)
                for fr in kept:
                    write_png(fr, os.path.join(args.png, f"{fr.t:08.3f}.png"))
            for d in describe(kept):
                print(f"{d['t']:8.3f}s  {hexcolor(d['color'])}  content {d['content'] * 100:6.2f}%  {'BLANK' if d['blank'] else ''}")
            return 0
        result = analyze_video(args.video, args.tap_at, args.start, args.stop)
        print(json.dumps(result, indent=2))
        return 0 if result["verdict"] == "PASS" else 1
    except CannotAnswer as e:
        print(f"blank.py: cannot answer: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
