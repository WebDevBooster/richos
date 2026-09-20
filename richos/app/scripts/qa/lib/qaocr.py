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

import functools
import hashlib
import json
import tempfile
from pathlib import Path
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


@functools.lru_cache(maxsize=8)
def reader_identity(binary, stamp=None):
    # Resolve once per invocation, never once per frame. Include binary contents
    # as well as its version so test readers and rebuilt binaries cannot collide.
    r = subprocess.run([binary, "--version"], capture_output=True, timeout=10)
    if r.returncode:
        raise OcrUnavailable("OCR reader version failed (exit %d)" % r.returncode)
    return {"path": os.path.realpath(binary), "version": r.stdout.decode(errors="replace"),
            "binary": hashlib.sha256(Path(binary).read_bytes()).hexdigest()}


@functools.lru_cache(maxsize=256)
def _file_digest(path,mtime,size):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


@functools.lru_cache(maxsize=16)
def _data_directory(binary,stamp,options,prefix):
    if '--tessdata-dir' in options:
        return options[options.index('--tessdata-dir')+1]
    if prefix:return prefix
    result=subprocess.run([binary,'--list-langs'],capture_output=True,text=True,timeout=10)
    if result.returncode:raise OcrUnavailable('OCR configuration discovery failed')
    import re
    match=re.search(r'"([^"\n]+)"',result.stdout+result.stderr)
    return match.group(1) if match else None


def configuration(binary,stamp,options):
    directory=_data_directory(binary,stamp,tuple(options),os.environ.get('TESSDATA_PREFIX',''))
    paths=[]
    if directory:
        root=Path(directory)
        if not root.is_dir():raise OcrUnavailable('OCR data directory is absent: '+directory)
        paths.extend(p for p in root.rglob('*') if p.is_file())
    # Explicit user dictionaries, patterns and config files also affect output.
    paths.extend(Path(v) for v in options if Path(v).is_file())
    result={}
    for path in sorted(set(paths)):
        stat=path.stat()
        result[str(path.resolve())]=_file_digest(str(path),stat.st_mtime_ns,stat.st_size)
    return result


def read(png, options=(), fresh=False):
    binary = tesseract_path()
    try:
        extra = json.loads(os.environ.get("RICHOS_QA_OCR_ARGS", "[]"))
        if not isinstance(extra, list) or not all(isinstance(v, str) for v in extra):
            raise ValueError("expected a list of strings")
        options = extra + list(options)
        data = Path(png).read_bytes()
        stat=Path(binary).stat();stamp=(stat.st_mtime_ns,stat.st_size)
        identity = {"image": hashlib.sha256(data).hexdigest(), "reader": reader_identity(binary,stamp),
                    "options": options, "configuration": configuration(binary,stamp,options),
                    "locale": [os.environ.get(k, "") for k in ("LANG", "LC_ALL")]}
        key = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
        cache = os.environ.get("RICHOS_QA_OCR_CACHE")
        entry = Path(cache)/ (key+".json") if cache else None
        if entry and entry.exists() and not fresh:
            try:
                value = json.loads(entry.read_text())
                if value.get("identity") == identity and isinstance(value.get("text"), str):
                    return value["text"]
            except (ValueError, OSError):
                pass
        r = subprocess.run([binary, str(png), "stdout"] + options,
                           capture_output=True, text=True, errors="replace", timeout=30)
        if r.returncode:
            # Do not echo OCR text, which may contain data the gate must protect.
            raise OcrUnavailable("OCR reader failed for %s (exit %d); no result cached" % (png, r.returncode))
        if entry:
            entry.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            fd, name = tempfile.mkstemp(prefix=".ocr-", dir=entry.parent)
            try:
                with os.fdopen(fd, "w") as fh:
                    json.dump({"identity": identity, "text": r.stdout}, fh)
                os.replace(name, entry)
            finally:
                if os.path.exists(name): os.unlink(name)
        return r.stdout
    except (OSError, ValueError, IndexError, subprocess.TimeoutExpired) as exc:
        raise OcrUnavailable("OCR could not run: %s" % exc) from exc


def text(png, psm=None, fresh=False):
    return read(png, ["--psm", str(psm)] if psm else [], fresh=fresh)


def words(png):
    """Every word tesseract reads, with its box and its line identity.

    Returns dicts: {'text', 'l', 't', 'w', 'h', 'line'}. `line` is the
    (block, paragraph, line) triple, which is what lets a caller join a
    word to its neighbor — an address broken into two tokens is still one
    address, and a redactor that misses the second half has published it.
    """
    result = read(png, ["tsv"])
    out = []
    for line in result.splitlines()[1:]:
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
    got = text(png, fresh=True)
    if not must_match.search(got):
        raise OcrUnavailable(
            "POSITIVE CONTROL FAILED: the reader did not find the known string "
            "in %s. Every '0 hits' from this reader is therefore meaningless. "
            "What it read was: %r" % (png, got[:200]))
    return got


def die(msg):
    sys.stderr.write(msg.rstrip("\n") + "\n")
    raise SystemExit(1)
