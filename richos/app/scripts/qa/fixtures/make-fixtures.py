#!/usr/bin/env python3
"""make-fixtures.py — regenerate the committed fixtures in this directory.

  make-fixtures.py [--check]

Needs Pillow and a system TrueType face, because it draws. Everything the
fixtures are USED for works without either, which is exactly why they are
committed rather than generated at test time: the suite has to run on a
machine that cannot draw.

  ocr-control.png   a white card carrying `qa-fixture@example.invalid`.
                    ocr-gate.sh's positive control, and redact.py's input in
                    the suite. `.invalid` is reserved by RFC 2606 and can
                    never belong to anyone, so the fixture is not itself a
                    thing that would ever need redacting.
  pair-pass.png     a solid #767676 block on #FFFFFF — 4.54:1, just over the
                    AA floor for normal text.
  pair-fail.png     a solid #A0A0A0 block on #FFFFFF — 2.61:1, a real
                    failure, and under the 3:1 non-text floor as well.

The two pairs are BLOCKS, not glyphs. An antialiased stroke has a dozen
shades and an estimator picks one of them, so a text fixture would assert
the heuristic rather than the arithmetic. A reviewer can check 4.54 and 2.61
by hand from the two hex values at
<https://webaim.org/resources/contrastchecker/>.

--check re-renders into a temporary directory and reports whether the
committed bytes still match, so a change to the renderer cannot silently
move the numbers the suite asserts.
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "lib"))

import qaimg                                             # noqa: E402

TEXT_SPECS = (
    ("ocr-control.png", 460, 140,
     ["QA FIXTURE CARD",
      "qa-fixture@example.invalid",
      "nothing here is real"],
     (17, 17, 17), (255, 255, 255), 24),
)

BLOCK_SPECS = (
    ("pair-pass.png", 240, 80, (255, 255, 255), (0x76, 0x76, 0x76), (40, 20, 160, 40)),
    ("pair-fail.png", 240, 80, (255, 255, 255), (0xA0, 0xA0, 0xA0), (40, 20, 160, 40)),
)


def build(outdir):
    made = []
    for name, w, h, lines, fg, bg, size in TEXT_SPECS:
        qaimg.save(qaimg.render_text(w, h, lines, fg=fg, bg=bg, size=size),
                   os.path.join(outdir, name))
        made.append(os.path.join(outdir, name))
    for name, w, h, bg, fg, box in BLOCK_SPECS:
        qaimg.save(qaimg.render_blocks(w, h, bg, fg, box),
                   os.path.join(outdir, name))
        made.append(os.path.join(outdir, name))
    return made


def names():
    return [s[0] for s in TEXT_SPECS] + [s[0] for s in BLOCK_SPECS]


def main(argv):
    if argv and argv[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0
    if argv and argv[0] == "--check":
        import tempfile
        tmp = tempfile.mkdtemp(prefix="qa-fixtures-")
        try:
            build(tmp)
        except qaimg.ImageError as exc:
            print("cannot check: %s" % exc, file=sys.stderr)
            return 2
        bad = 0
        try:
            for name in names():
                a = os.path.join(HERE, name)
                b = os.path.join(tmp, name)
                if not os.path.isfile(a):
                    print("MISSING  %s" % name)
                    bad += 1
                elif open(a, "rb").read() != open(b, "rb").read():
                    print("DIFFERS  %s — the renderer moved. Re-check the numbers "
                          "the suite asserts before committing." % name)
                    bad += 1
                else:
                    print("same     %s" % name)
        finally:
            for f in os.listdir(tmp):
                os.remove(os.path.join(tmp, f))
            os.rmdir(tmp)
        return 1 if bad else 0
    try:
        for p in build(HERE):
            print("wrote %s" % p)
    except qaimg.ImageError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
