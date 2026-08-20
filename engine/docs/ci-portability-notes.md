# CI portability notes — macOS (dev) vs. Linux (CI/adopter)

The kit is developed on macOS. `.github/workflows/kit-self-verify.yml` runs on
`ubuntu-latest`, and an adopter may run any of these scripts on Linux too.
This doc records the actual reasoning behind that portability claim — every
item below was checked by reading the shipped scripts and testing the
specific command, not assumed from general "bash is bash" optimism.

## What was checked (and found clean)

Grepped every shipped script (`scripts/`, `reference/`) for the classic
BSD-vs-GNU trip-wires:

- **`sed -i`** — zero occurrences. (BSD `sed -i` requires a backup-suffix
  argument, even if empty (`-i ''`); GNU `sed -i` doesn't. This kit never
  uses in-place `sed` editing at all, so the incompatibility doesn't arise.)
- **`date -v` / `date -j` (BSD-only) / `gdate`** — zero occurrences. Every
  timestamp in the kit is produced by `date -u +%Y-%m-%dT%H:%M:%SZ}` (POSIX)
  or Python's `datetime`, both identical on any platform.
- **`stat -f` (BSD) vs. `stat -c` (GNU)** — zero occurrences of the `stat`
  command at all (the one grep hit was the English word "stat" inside a
  comment, not the command).
- **`pbcopy` / `pbpaste` / `osascript`** — zero occurrences (these would be
  macOS-only with no Linux equivalent at all).
- **Hashing** — every hook that needs a content hash already tries
  `shasum` (present on GitHub's `ubuntu-latest` runners via the bundled
  Perl) → falls back to `sha256sum` (GNU coreutils, present on every Linux
  distro) → falls back to a `python3 hashlib` one-liner. This fallback chain
  was already in place before B3, not added for it — confirmed by reading
  `sha256_of()` in `contract-integrity-probe.sh` and the equivalent block in
  `install.sh`.
- **`awk` field-separator usage (`awk -F'\t'`)** — only basic, POSIX-portable
  `-F`/`print`/pattern-action usage appears anywhere; nothing that depends on
  `gawk`-only or BSD-`awk`-only extensions.
- **Bash version features** (arrays, `${var//pattern/repl}`, `local`,
  `[[ ]]`) — all bash ≥4 features, universally available on any Linux distro
  GitHub Actions ships (`ubuntu-latest` runs a modern bash 5.x) and on modern
  macOS bash/Homebrew bash alike.
- **`git rev-parse --path-format=absolute --git-common-dir`**
  (`scripts/lib/resolve-main-checkout.sh`) — requires git ≥ 2.31 (Feb 2021).
  `ubuntu-latest` ships a much newer git; this is a documented minimum
  version, not a portability bug.

## One real (but cosmetic, non-breaking) difference: `mktemp -t`

Every hook that needs a scratch temp file/dir uses `mktemp`. `mktemp -t
prefix` behaves **differently by design** on BSD/macOS vs. GNU/Linux:

- **BSD/macOS** (`man mktemp`, read in full): `-t prefix` builds an internal
  template from `prefix` + the platform's temp-dir convention, and treats
  any `X`s you embedded in `prefix` as **opaque literal characters** — it
  does **not** substitute them. Uniqueness comes entirely from BSD mktemp
  appending its **own** random suffix after your whole string. Verified by
  running `mktemp -d -t "name.XXXXXX"` on the dev machine: the output was
  `.../name.XXXXXX.<8-random-chars>` — the literal `XXXXXX` survived
  unchanged, with real randomness bolted on afterward.
- **GNU/Linux** (coreutils mktemp): substitutes a trailing run of `X`s
  directly, and does not require `-t` for uniqueness at all.

Both behaviors are **functionally correct and unique on their own platform**
— this is not a bug, and nothing was silently broken. It only matters in one
place: `scripts/demo.sh`'s `SAMPLE_ROOT`, whose value is narrated straight to
the CEO running the demo ("Building a tiny sample repo at ..."). On macOS,
the un-fixed form produced an ugly double-suffixed path like
`.../orchestration-kit-demo.XXXXXX.k3ryLSxK9V`. **Fixed** (trivially
portable, one line): swapped `mktemp -d -t orchestration-kit-demo.XXXXXX` for
`mktemp -d "${TMPDIR:-/tmp}/orchestration-kit-demo.XXXXXX"` — dropping `-t`
and giving an explicit path template. Verified this produces a clean,
X-substituted, non-double-suffixed path on macOS (`.../orchestration-kit-
demo.KdeiiJ`), and by the documented GNU semantics above, produces an
equally clean result on Linux.

**Not fixed, documented instead:** three internal (never user-narrated)
scratch-file `mktemp` calls — `scripts/hooks/verify-agent-prompt.sh`,
`scripts/hooks/scan-secrets.sh`, and `scripts/hooks/contract-integrity-
probe.sh` each mktemp a `NAME.XXXXXX.py` file to hold an embedded Python
script. Here the `X`s are **not** the trailing characters (a literal `.py`
follows them), and testing confirmed that on BSD/macOS, dropping `-t` for a
non-trailing `X` run performs **no substitution at all** — a genuine
uniqueness regression risk, not just a cosmetic one. Keeping `-t` here is the
*correct* choice on both platforms: on macOS it still gets real uniqueness
(from BSD's own appended-suffix behavior, landing after the `.py`, e.g.
`name.XXXXXX.py.SLOXFMkooT`), and on Linux it substitutes normally. The
resulting filename's literal `.py` extension gets extra characters appended
after it on macOS only — harmless, since every call site invokes the file
directly as `python3 <path>` (Python does not care about file extension for
direct execution, only for `import` statements, which none of these do).
Fixing this properly would require restructuring each site (e.g. `mktemp -d`
for a directory, then a fixed filename inside it) — more than the "trivially
portable" bar this audit used to decide what to change now versus merely
record.

## Net result

`scripts/demo.sh` is the one place worth a portability polish, applied. Every
other hook and script was already portable by construction (mostly because
the kit's own `python3`-fallback discipline for anything hash- or JSON-shaped
sidesteps the entire BSD/GNU shell-tool divide) — Frank's hostile-buyer
review's claim ("Linux is fine") holds up under a full read, not just a
plausibility check.
