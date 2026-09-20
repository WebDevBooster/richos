"""qaocr.py — reading text off a captured frame, and the word boxes it sits in.

===========================================================================
A READER THAT CANNOT READ REPORTS ZERO HITS
===========================================================================
This is the whole reason the OCR helpers here are shared rather than
rewritten. `tesseract` returning nothing is indistinguishable, at the call
site, from a frame that genuinely holds no text — and "0 hits" is the
answer a privacy gate is LOOKING for. So a gate built on a broken reader
reports exactly what a clean run reports.

Every caller that draws a conclusion from an absence therefore runs
`positive_control()` first: the same reader, the same preprocessing, on an
image whose text is known, which must come back with a hit. Only then does
zero mean zero. That discipline was invented on the candidate .15 walk and
then not carried anywhere, which is why it is here.

===========================================================================
WHERE TESSERACT IS, AND WHY IT IS NOT JUST `tesseract`
===========================================================================
Four walks hard-coded `/opt/homebrew/bin/tesseract` because PATH under a
non-interactive shell does not carry Homebrew. Resolved here, once, from
$RICHOS_QA_TESSERACT, then PATH, then the two Homebrew prefixes. Absence
is an error with a sentence, never a silent empty string.
"""

import os
import shutil
import subprocess
import sys

_CANDIDATES = (
    "/opt/homebrew/bin/tesseract",     # Apple silicon Homebrew
    "/usr/local/bin/tesseract",        # Intel Homebrew
)


class OcrUnavailable(Exception):
    """There is no reader on this machine, so nothing was read."""


def tesseract_path():
    override = os.environ.get("RICHOS_QA_TESSERACT")
    if override:
        if os.path.isfile(override) and os.access(override, os.X_OK):
            return override
        raise OcrUnavailable(
            "RICHOS_QA_TESSERACT=%s is not an executable file" % override)
    found = shutil.which("tesseract")
    if found:
        return found
    for c in _CANDIDATES:
        if os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    raise OcrUnavailable(
        "tesseract is not on this machine (`brew install tesseract`). "
        "Nothing was read, which is NOT the same as nothing being there.")


def text(png, psm=None):
    """The plain text tesseract reads out of a PNG."""
    cmd = [tesseract_path(), png, "stdout"]
    if psm:
        cmd += ["--psm", str(psm)]
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                       text=True, errors="replace", check=False)
    return r.stdout


def words(png):
    """Every word tesseract reads, with its box and its line identity.

    Returns dicts: {'text', 'l', 't', 'w', 'h', 'line'}. `line` is the
    (block, paragraph, line) triple, which is what lets a caller join a
    word to its neighbor — an address broken into two tokens is still one
    address, and a redactor that misses the second half has published it.
    """
    r = subprocess.run([tesseract_path(), png, "stdout", "tsv"],
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                       text=True, errors="replace", check=False)
    out = []
    for line in r.stdout.splitlines()[1:]:
        f = line.split("\t")
        if len(f) < 12 or not f[11].strip():
            continue
        try:
            out.append({
                "line": (f[1], f[2], f[3], f[4]),
                "l": int(f[6]), "t": int(f[7]), "w": int(f[8]), "h": int(f[9]),
                "text": f[11],
            })
        except ValueError:
            continue
    return out


def positive_control(png, must_match):
    """Prove the reader works before an absence is allowed to mean anything.

    `png` is an image whose text is known; `must_match` is a compiled regex
    that has to fire on what comes back. Returns the text on success and
    raises OcrUnavailable with a sentence on failure.
    """
    got = text(png)
    if not must_match.search(got):
        raise OcrUnavailable(
            "POSITIVE CONTROL FAILED: the reader did not find the known string "
            "in %s. Every '0 hits' from this reader is therefore meaningless. "
            "What it read was: %r" % (png, got[:200]))
    return got


def die(msg):
    sys.stderr.write(msg.rstrip("\n") + "\n")
    raise SystemExit(1)
