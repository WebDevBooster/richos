#!/usr/bin/env python3
"""RichOS app-icon pipeline: one artwork file in, every artefact Tauri bundles out.

WHY THIS EXISTS
---------------
`app/src-tauri/icons/` shipped four byte-identical 2200-byte placeholders, so the
desktop app had no icon at any size. That is launch-blocking for a product the CEO
installs on his own machine. The missing half was never the artwork alone: there was
no generator, no checkable source spec, and the build gate hand-typed four filenames
while `tauri.conf.json` declared six.

DESIGN RULE — DERIVE, NEVER TYPE
--------------------------------
Everything required here is DERIVED from `tauri.conf.json`'s `bundle.icon` array,
which is Tauri's own source of truth for what gets bundled. Adding a size to that
array automatically makes it required; it cannot leave the check silently passing.
An entry whose filename we cannot decode is a hard ERROR, never a skip — silence on
an unrecognized entry is exactly how a check rots into decoration.

The Rust build gate (`app/src-tauri/build.rs`) derives the SAME requirements
INDEPENDENTLY from the SAME config. That duplication is deliberate: two independent
readers agreeing is a stronger guarantee than one shared helper, and if this
generator's derivation ever drifts from the gate's, the gate fails the build.

TOOL AND LICENSE
----------------
Pillow, SPDX `MIT-CMU` (confirmed from the installed distribution's
`License-Expression` metadata, Pillow 12.3.0). Permissive, no copyleft, no
attribution burden on the generated output. Nothing from Pillow is linked into or
shipped inside the signed `.app`: it runs at authoring time only, and the sole
artefacts that ship are pixels derived from the CEO's own artwork. That keeps the
license question entirely clear of the signing/notarization path, which is why it
passes the v1 license gate.

macOS `.icns` is written by `/usr/bin/iconutil`, Apple's own tool, which ships with
macOS. It is preferred over Pillow's ICNS writer for a measured reason:

    iconutil : ic04(16) ic05(32) ic07(128) ic08(256) ic09(512) ic10(1024)
               ic11(32) ic12(64) ic13(256) ic14(512)     -> covers 16px
    Pillow   : ic07 ic08 ic09 ic10 ic11 ic12 ic13 ic14   -> NO 16px layer at all

Off macOS there is no iconutil, so we fall back to Pillow and say so out loud. That
fallback is a NAMED DEGRADATION, not a silent one.

HONEST GAP: Tauri's own `helpers/icns.json` also lists `is32`/`il32` (the pre-10.7
24-bit RLE variants, each paired with a separate `s8mk`/`l8mk` mask chunk).
`cargo tauri icon` does emit those; NEITHER iconutil NOR Pillow does, because Apple's
canonical tool replaced them with the ARGB `ic04`/`ic05`. Measured on this machine
against tauri-cli 2.11.4, both encoders nonetheless cover the identical set of PIXEL
sizes {16, 32, 64, 128, 256, 512, 1024}. So the checker requires pixel-size coverage
rather than a literal fourcc list: requiring the fourccs would fail on output from
Apple's own tool, which is a checker bug, not an artwork bug.
"""

from __future__ import annotations

import json
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

# ---------------------------------------------------------------------------
# Derivation from tauri.conf.json
# ---------------------------------------------------------------------------

# `32x32.png`, `128x128.png`, `128x128@2x.png` -> declared size times the @Nx multiplier.
_SIZED_PNG = re.compile(r"^(\d+)x(\d+)(?:@(\d+)x)?\.png$", re.IGNORECASE)

# `tauri icon` emits the unsized `icon.png` at 512x512. This is the ONE filename whose
# required size cannot be read off the name, so it is pinned here with its provenance.
# Ref: https://v2.tauri.app/develop/icons/ — verified against tauri-cli 2.11.4 output.
_UNSIZED_PNG = {"icon.png": 512}

# Windows .ico layers Tauri's icon guide specifies.
# Ref: https://v1.tauri.app/v1/guides/features/icons/ (format unchanged in v2).
# Verified: `cargo tauri icon` 2.11.4 emits exactly [16, 24, 32, 48, 64, 256].
ICO_LAYERS = (16, 24, 32, 48, 64, 256)

# The five base sizes of a macOS `.iconset`, each of which also carries an @2x variant.
# These are the only names `iconutil` accepts; there is no `icon_64x64.png`.
ICONSET_BASES = (16, 32, 128, 256, 512)

# macOS `.icns` pixel sizes, DERIVED from the iconset bases rather than typed out, so
# the generator and the requirement can never disagree about what a full set is.
ICNS_SIZES = tuple(sorted({s for b in ICONSET_BASES for s in (b, b * 2)}))

# Guard the derivation itself: this is the coverage `cargo tauri icon` 2.11.4 produces
# (is32/il32 for 16/32, ic07-ic14 above) and that iconutil produces (ic04/ic05 for
# 16/32). If ICONSET_BASES is ever edited, this assertion is the thing that notices.
assert ICNS_SIZES == (16, 32, 64, 128, 256, 512, 1024), ICNS_SIZES

# The largest layer any artefact needs — derived, so it tracks the constants above.
# 1024 comes from the `ic10` / `icon_512x512@2x` layer; a smaller source would force
# an upscale for exactly that layer, which is the one users see largest.
SOURCE_MIN_PX = max(max(ICNS_SIZES), max(ICO_LAYERS), max(_UNSIZED_PNG.values()))

# Apple's macOS app-icon grid draws the icon body inside 824px of a 1024px canvas
# (~80.5%). Content wider than SAFE_AREA_WARN_PCT of the canvas risks being clipped by
# the rounded-rect mask macOS applies at display time.
SAFE_AREA_WARN_PCT = 90.0


class SpecError(Exception):
    """The config declares something we refuse to guess about."""


class SourceError(Exception):
    """The supplied artwork cannot produce a correct icon set."""


@dataclass(frozen=True)
class Requirement:
    """One artefact `tauri.conf.json` says must exist, and what makes it valid."""

    rel: str  # path relative to src-tauri/, exactly as tauri.conf.json spells it
    kind: str  # "png" | "icns" | "ico"
    sizes: tuple[int, ...]  # png: one (square) size; icns/ico: every layer size

    @property
    def name(self) -> str:
        return Path(self.rel).name


def derive_requirements(conf_path: Path) -> list[Requirement]:
    """Read Tauri's OWN bundle.icon list and turn it into checkable requirements.

    Raises SpecError on any entry we cannot decode. Refusing to guess is the point: a
    new `icons/64x64.png` becomes required automatically, and an entry we do not
    understand stops the pipeline instead of being quietly dropped.
    """
    try:
        conf = json.loads(conf_path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise SpecError(f"{conf_path} not found — cannot derive icon requirements")
    except json.JSONDecodeError as e:
        raise SpecError(f"{conf_path} is not valid JSON: {e}")

    entries = conf.get("bundle", {}).get("icon")
    if not isinstance(entries, list) or not entries:
        raise SpecError(
            f"{conf_path}: bundle.icon is missing or empty. Tauri bundles exactly what "
            f"this array lists, so an empty array means the app ships with no icon."
        )

    reqs: list[Requirement] = []
    for entry in entries:
        if not isinstance(entry, str):
            raise SpecError(f"bundle.icon entry is not a string: {entry!r}")
        name = Path(entry).name
        low = name.lower()

        if low.endswith(".png"):
            m = _SIZED_PNG.match(name)
            if m:
                w, h, mult = int(m.group(1)), int(m.group(2)), int(m.group(3) or 1)
                if w != h:
                    raise SpecError(
                        f"bundle.icon entry {entry!r} declares a non-square {w}x{h}. "
                        f"App icons must be square."
                    )
                reqs.append(Requirement(entry, "png", (w * mult,)))
            elif low in _UNSIZED_PNG:
                reqs.append(Requirement(entry, "png", (_UNSIZED_PNG[low],)))
            else:
                raise SpecError(
                    f"bundle.icon entry {entry!r}: cannot derive a required pixel size "
                    f"from this filename. Name it `<N>x<N>.png` or `<N>x<N>@<M>x.png`, "
                    f"or add it to _UNSIZED_PNG with a cited source. This pipeline will "
                    f"not guess a size and ship a wrong icon."
                )
        elif low.endswith(".icns"):
            reqs.append(Requirement(entry, "icns", ICNS_SIZES))
        elif low.endswith(".ico"):
            reqs.append(Requirement(entry, "ico", ICO_LAYERS))
        else:
            raise SpecError(
                f"bundle.icon entry {entry!r}: unsupported extension. This pipeline "
                f"knows .png, .icns and .ico. An unknown type must stop the run rather "
                f"than be skipped."
            )
    return reqs


# ---------------------------------------------------------------------------
# Source artwork validation — precise, not prose
# ---------------------------------------------------------------------------


def load_and_validate_source(path: Path, allow_full_bleed: bool = False):
    """Open the CEO's artwork and prove it can produce a correct icon set.

    Returns (RGBA image in sRGB, list of human-readable warnings).
    Raises SourceError listing EVERY problem at once, so a re-supply round trip fixes
    all of them, rather than revealing one defect per attempt.
    """
    from PIL import Image

    errors: list[str] = []
    warnings: list[str] = []

    if not path.exists():
        raise SourceError(f"source artwork not found: {path}")

    if path.suffix.lower() == ".svg":
        raise SourceError(
            f"{path.name}: SVG is not supported by this pipeline. Export a flat PNG at "
            f"{SOURCE_MIN_PX}x{SOURCE_MIN_PX} or larger with a transparent background "
            f"and supply that instead. (Rasterizing SVG would need an extra engine "
            f"whose license is not vetted for this signed bundle.)"
        )

    try:
        im = Image.open(path)
        im.load()
    except Exception as e:
        raise SourceError(f"{path.name}: not a readable image ({type(e).__name__}: {e})")

    if im.format != "PNG":
        errors.append(
            f"format is {im.format}, must be PNG. JPEG and friends have no alpha "
            f"channel, so the icon would ship with an opaque rectangle behind it."
        )

    # --- color space -----------------------------------------------------
    if im.mode in ("CMYK", "LAB", "YCbCr"):
        errors.append(
            f"color space is {im.mode}; app icons must be RGB/sRGB. Re-export as "
            f"sRGB (8 bits per channel) with an alpha channel."
        )

    # --- alpha ------------------------------------------------------------
    has_alpha = im.mode in ("RGBA", "LA", "PA") or (
        im.mode == "P" and "transparency" in im.info
    )
    if not has_alpha:
        errors.append(
            f"no alpha channel (mode {im.mode}). Tauri requires a squared PNG WITH "
            f"transparency: macOS and Windows each apply their own corner/shape mask, "
            f"and an opaque source shows as a hard square tile beside rounded icons."
        )

    # --- geometry ---------------------------------------------------------
    w, h = im.size
    if w != h:
        errors.append(
            f"is {w}x{h}, must be exactly square. Tauri does not letterbox or crop; a "
            f"non-square source would be squashed at every size."
        )
    if min(w, h) < SOURCE_MIN_PX:
        errors.append(
            f"is {w}x{h}, must be at least {SOURCE_MIN_PX}x{SOURCE_MIN_PX}. The macOS "
            f".icns `ic10` layer is {SOURCE_MIN_PX}px; anything smaller upscales for "
            f"exactly the layer shown largest, which is where softness is most visible."
        )

    if errors:
        raise SourceError("\n".join(f"  - {path.name}: {e}" for e in errors))

    # --- normalize to sRGB RGBA ------------------------------------------
    icc = im.info.get("icc_profile")
    if icc:
        try:
            import io

            from PIL import ImageCms

            src_profile = ImageCms.ImageCmsProfile(io.BytesIO(icc))
            src_name = ImageCms.getProfileDescription(src_profile).strip()
            if "srgb" not in src_name.lower():
                im = ImageCms.profileToProfile(
                    im, src_profile, ImageCms.createProfile("sRGB"), outputMode="RGBA"
                )
                warnings.append(
                    f"source carried a non-sRGB ICC profile ({src_name!r}); converted "
                    f"to sRGB. Colors in the icon may differ slightly from your art "
                    f"tool's preview — supply sRGB directly to avoid the conversion."
                )
        except Exception as e:  # pragma: no cover - depends on local littleCMS build
            warnings.append(
                f"source carried an ICC profile that could not be converted "
                f"({type(e).__name__}); using the raw channel values as sRGB."
            )

    im = im.convert("RGBA")

    # --- transparency actually used, and safe area ------------------------
    alpha = im.getchannel("A")
    lo, hi = alpha.getextrema()
    if hi == 0:
        raise SourceError(
            f"  - {path.name}: every pixel is fully transparent — the image is blank."
        )
    if lo == 255:
        msg = (
            f"  - {path.name}: the alpha channel is fully opaque edge to edge "
            f"(full bleed). macOS clips app icons to a rounded rectangle, so the "
            f"corners of this artwork WILL be cut off. Supply art with a transparent "
            f"margin, or pass --allow-full-bleed if the square crop is deliberate."
        )
        if not allow_full_bleed:
            raise SourceError(msg)
        warnings.append(msg.strip().removeprefix("- "))

    bbox = alpha.getbbox()  # tight box of every non-fully-transparent pixel
    if bbox:
        content_w = bbox[2] - bbox[0]
        content_h = bbox[3] - bbox[1]
        extent = 100.0 * max(content_w, content_h) / float(w)
        if extent > SAFE_AREA_WARN_PCT:
            warnings.append(
                f"artwork fills {extent:.1f}% of the canvas (safe area is "
                f"{SAFE_AREA_WARN_PCT:.0f}%). Apple's macOS icon grid draws the icon "
                f"body inside 824 of 1024px (~80.5%); content this close to the edge "
                f"may be clipped by the rounded-rect mask."
            )

    return im, warnings


# ---------------------------------------------------------------------------
# Generation
# ---------------------------------------------------------------------------


def _resize(im, size: int):
    from PIL import Image

    return im.resize((size, size), Image.LANCZOS)


def _write_png(im, size: int, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    _resize(im, size).save(dest, format="PNG", optimize=True)


def _write_ico(im, sizes: tuple[int, ...], dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    # Pillow downsamples internally, but feeding it the largest layer explicitly keeps
    # the resample filter ours rather than its default.
    _resize(im, max(sizes)).save(
        dest, format="ICO", sizes=[(s, s) for s in sorted(sizes)]
    )


def _write_icns(im, dest: Path, log) -> None:
    """Prefer Apple's iconutil (covers 16px); fall back to Pillow with a loud note."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    iconutil = shutil.which("iconutil")
    if iconutil:
        with tempfile.TemporaryDirectory() as td:
            iconset = Path(td) / "icon.iconset"
            iconset.mkdir()
            for base in ICONSET_BASES:
                _resize(im, base).save(iconset / f"icon_{base}x{base}.png", format="PNG")
                _resize(im, base * 2).save(
                    iconset / f"icon_{base}x{base}@2x.png", format="PNG"
                )
            subprocess.run(
                [iconutil, "-c", "icns", str(iconset), "-o", str(dest)],
                check=True,
                capture_output=True,
            )
        return

    log(
        "WARNING: /usr/bin/iconutil not found (not macOS). Falling back to Pillow's "
        "ICNS writer, which emits NO 16px layer — the Finder list-view size. The "
        "resulting .icns is usable but incomplete; regenerate on macOS before signing "
        "a release."
    )
    _resize(im, max(ICNS_SIZES)).save(dest, format="ICNS")


def generate(source: Path, conf_path: Path, icons_dir: Path, log, allow_full_bleed=False):
    """Validate the source, then emit every artefact tauri.conf.json declares."""
    reqs = derive_requirements(conf_path)
    im, warnings = load_and_validate_source(source, allow_full_bleed=allow_full_bleed)

    for w in warnings:
        log(f"WARNING: {w}")

    log(f"source OK: {source} ({im.size[0]}x{im.size[1]} RGBA sRGB)")
    log(f"derived {len(reqs)} required artefact(s) from {conf_path}")

    for req in reqs:
        dest = icons_dir / req.name
        if req.kind == "png":
            _write_png(im, req.sizes[0], dest)
            log(f"  wrote {req.rel:<28} {req.sizes[0]}x{req.sizes[0]}")
        elif req.kind == "ico":
            _write_ico(im, req.sizes, dest)
            log(f"  wrote {req.rel:<28} layers {list(req.sizes)}")
        elif req.kind == "icns":
            _write_icns(im, dest, log)
            log(f"  wrote {req.rel:<28} layers {list(req.sizes)}")
    return reqs


# ---------------------------------------------------------------------------
# Verification — the same derivation, applied to what is on disk
# ---------------------------------------------------------------------------


def _png_size(data: bytes):
    sig = b"\x89PNG\r\n\x1a\n"
    if len(data) < 24 or data[:8] != sig or data[12:16] != b"IHDR":
        return None
    return struct.unpack(">II", data[16:24])


def _icns_sizes(data: bytes) -> set[int]:
    """Pixel sizes present in an .icns, by fourcc, not by decoding every layer."""
    by_fourcc = {
        b"is32": 16, b"s8mk": 16, b"ic04": 16, b"icp4": 16,
        b"il32": 32, b"l8mk": 32, b"ic05": 32, b"ic11": 32, b"icp5": 32,
        b"ic12": 64, b"icp6": 64,
        b"ih32": 48, b"h8mk": 48,
        b"ic07": 128, b"it32": 128, b"t8mk": 128,
        b"ic08": 256, b"ic13": 256,
        b"ic09": 512, b"ic14": 512,
        b"ic10": 1024,
    }
    found: set[int] = set()
    if len(data) < 8 or data[:4] != b"icns":
        return found
    off = 8
    while off + 8 <= len(data):
        fourcc = data[off : off + 4]
        (length,) = struct.unpack(">I", data[off + 4 : off + 8])
        if length < 8:
            break
        if fourcc in by_fourcc:
            found.add(by_fourcc[fourcc])
        off += length
    return found


def _ico_sizes(path: Path) -> set[int]:
    from PIL import Image

    with Image.open(path) as im:
        return {w for (w, h) in im.ico.sizes() if w == h}


def verify(conf_path: Path, icons_dir: Path) -> list[str]:
    """Return a list of failures. Empty list means the icon set is real and complete."""
    reqs = derive_requirements(conf_path)
    failures: list[str] = []
    blobs: list[tuple[str, bytes]] = []

    for req in reqs:
        dest = icons_dir / req.name
        if not dest.exists():
            failures.append(
                f"{req.rel} is declared in tauri.conf.json bundle.icon but does not "
                f"exist on disk"
            )
            continue
        data = dest.read_bytes()
        blobs.append((req.rel, data))

        if req.kind == "png":
            got = _png_size(data)
            want = req.sizes[0]
            if got is None:
                failures.append(f"{req.rel} is not a readable PNG (bad IHDR)")
            elif got != (want, want):
                failures.append(
                    f"{req.rel} is named for {want}x{want} but is actually "
                    f"{got[0]}x{got[1]} — Tauri ships bundle icons as-is, it does not "
                    f"resize them to match their filename"
                )
        elif req.kind == "icns":
            got_sizes = _icns_sizes(data)
            missing = sorted(set(req.sizes) - got_sizes)
            if not got_sizes:
                failures.append(f"{req.rel} is not a readable .icns archive")
            elif missing:
                failures.append(
                    f"{req.rel} is missing layer size(s) {missing}px "
                    f"(has {sorted(got_sizes)})"
                )
        elif req.kind == "ico":
            try:
                got_sizes = _ico_sizes(dest)
            except Exception as e:
                failures.append(f"{req.rel} is not a readable .ico ({type(e).__name__})")
                continue
            missing = sorted(set(req.sizes) - got_sizes)
            if missing:
                failures.append(
                    f"{req.rel} is missing layer size(s) {missing}px "
                    f"(has {sorted(got_sizes)})"
                )

    # The exact defect this pipeline replaces: every required file was the same file.
    # Independently rendered sizes are never byte-identical.
    for i in range(len(blobs)):
        for j in range(i + 1, len(blobs)):
            if blobs[i][1] == blobs[j][1]:
                failures.append(
                    f"{blobs[j][0]} is byte-identical to {blobs[i][0]} — these are "
                    f"supposed to be independently rendered artefacts, not copies of "
                    f"one placeholder"
                )
    return failures


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _paths():
    here = Path(__file__).resolve()
    src_tauri = here.parents[2] / "src-tauri"
    return src_tauri / "tauri.conf.json", src_tauri / "icons"


def main(argv: list[str]) -> int:
    import argparse

    conf_default, icons_default = _paths()
    p = argparse.ArgumentParser(
        prog="app_icons.py",
        description="Generate and verify the RichOS Tauri app-icon set.",
    )
    p.add_argument("command", choices=["generate", "verify"])
    p.add_argument("source", nargs="?", help="source artwork PNG (generate only)")
    p.add_argument("--conf", type=Path, default=conf_default)
    p.add_argument("--icons-dir", type=Path, default=icons_default)
    p.add_argument(
        "--allow-full-bleed",
        action="store_true",
        help="accept artwork with no transparent margin (macOS will clip its corners)",
    )
    args = p.parse_args(argv)

    def log(msg: str) -> None:
        print(msg, flush=True)

    try:
        if args.command == "generate":
            if not args.source:
                p.error("generate needs a source artwork path")
            generate(
                Path(args.source).expanduser(),
                args.conf,
                args.icons_dir,
                log,
                allow_full_bleed=args.allow_full_bleed,
            )
            log("")
            log("verifying what was just written, from tauri.conf.json...")
        failures = verify(args.conf, args.icons_dir)
    except (SpecError, SourceError) as e:
        print(f"\nFAILED: {e}\n", file=sys.stderr)
        return 2

    if failures:
        print("\nFAILED — the icon set is not usable:\n", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        print("", file=sys.stderr)
        return 1

    print("OK: every artefact declared in tauri.conf.json bundle.icon is present, "
          "correctly sized, and distinct.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
