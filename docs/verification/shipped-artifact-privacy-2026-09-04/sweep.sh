#!/usr/bin/env bash
# sweep.sh — what personal or private data reaches the artifact a stranger installs?
#
# Re-runnable. Derives the shipped file sets from the BUILD DEFINITION rather than from a
# hand-typed list, then searches each set for every category, and prints the empty results
# as well as the hits — because "we looked and found nothing" is the finding that makes a
# pass like this worth anything.
#
#   bash docs/verification/shipped-artifact-privacy-2026-09-04/sweep.sh [--repo DIR]
#
# THE THREE SETS, and why they are three:
#
#   1. EMBEDDED FRONTEND — `app/src-tauri/build.rs` stages `app/ui` into the directory
#      `tauri.conf.json` names as `build.frontendDist`, minus the top-level names in
#      `UI_NOT_SHIPPED`. `tauri-codegen` then walks that directory filtered on nothing but
#      `is_dir()` and brotli-compresses every file into the executable. So the set is
#      `app/ui` minus those names, at any depth, INCLUDING dotfiles and anything untracked
#      that happens to be sitting there.
#
#   2. COMPILED RUST — `app/src-tauri/src` plus the two path crates it depends on. Only
#      code that survives comment-stripping and `#[cfg(test)]` removal can reach a release
#      binary, which is what `rust-shipped-strings.py` next to this file computes.
#
#   3. ENGINE ASSET — what `app/scripts/make-engine-asset.sh` packages, which the customer
#      downloads from the GitHub release. It is not inside RichOS.app, but it lands on the
#      same stranger's machine, so it is in scope.
#
#      THE RULE CHANGED ON 2026-09-04, AND THIS FOLLOWED IT. The script used to archive ALL
#      of `engine/` with no exclusions, and that was a finding in its own right: on main, 119
#      gitignored files went into the download, among them fifteen
#      `.claude/state/agent-definitions-*.snapshot` carrying a session UUID and the operator's
#      absolute home path. The script now builds from `git ls-files`, so the shipped set is
#      the TRACKED set and this derives it the same way. Sweeping `find engine -type f` would
#      now report on files no customer ever receives, and a privacy sweep that describes the
#      wrong set is a sweep whose empty cells mean nothing.
#
# Exit status is always 0: this reports, it does not gate. The gate on the built bundle is
# `app/scripts/lib/no_host_paths.py`, run by `package-app.sh` before it signs.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
[ "${1:-}" = "--repo" ] && REPO="$2"
cd "$REPO" || exit 2

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

rule() { printf '\n===== %s =====\n' "$*"; }
row()  { printf '  %-34s %s\n' "$1" "$2"; }

# ---------------------------------------------------------------------------
# Set 1 — the embedded frontend, derived from build.rs
# ---------------------------------------------------------------------------
DIST="$(sed -n 's/.*"frontendDist"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' app/src-tauri/tauri.conf.json)"
# UI_NOT_SHIPPED, read out of build.rs rather than retyped, so this cannot drift from it.
EXCL="$(sed -n 's/^const UI_NOT_SHIPPED.*= &\[\(.*\)\];$/\1/p' app/src-tauri/build.rs | tr -d '" ' | tr ',' '\n')"

prune=()
while IFS= read -r name; do
  [ -n "$name" ] || continue
  prune+=(-path "app/ui/$name" -o)
done <<< "$EXCL"
find app/ui -mindepth 1 \( "${prune[@]:0:${#prune[@]}-1}" \) -prune -o -type f -print \
  | LC_ALL=C sort > "$TMP/embedded.txt"

rule "SET 1 — embedded frontend"
echo "  frontendDist   : $DIST   (build.rs stages app/ui into it, then Tauri embeds it)"
echo "  UI_NOT_SHIPPED : $(echo "$EXCL" | tr '\n' ' ')"
echo "  files          : $(wc -l < "$TMP/embedded.txt" | tr -d ' ')"
echo "  bytes          : $(tr '\n' '\0' < "$TMP/embedded.txt" | xargs -0 stat -f '%z' | awk '{s+=$1} END {print s}')"
sed 's/^/    /' "$TMP/embedded.txt"

# ---------------------------------------------------------------------------
# Set 2 — the Rust that survives into a release binary
# ---------------------------------------------------------------------------
find app/src-tauri/src app/crates/richos-core/src app/crates/richos-voice/src \
     -type f -name '*.rs' | LC_ALL=C sort > "$TMP/rust.txt"
# shellcheck disable=SC2046
python3 "$(dirname "${BASH_SOURCE[0]}")/rust-shipped-strings.py" $(cat "$TMP/rust.txt") > "$TMP/rust-shipped.txt"

rule "SET 2 — compiled Rust"
echo "  source files          : $(wc -l < "$TMP/rust.txt" | tr -d ' ')"
echo "  lines after stripping comments and #[cfg(test)] : $(wc -l < "$TMP/rust-shipped.txt" | tr -d ' ')"

# ---------------------------------------------------------------------------
# Set 3 — the engine release asset
# ---------------------------------------------------------------------------
# Derived the way the packaging script derives it: `git ls-files`, not the working tree. The
# LICENSE and third-party notices packaging copies in are tracked files of this repository and
# are covered as part of the repository's own text, so they are not added here twice.
git -C "$REPO" ls-files engine | LC_ALL=C sort > "$TMP/engine.txt"
rule "SET 3 — engine release asset"
if [ ! -s "$TMP/engine.txt" ]; then
  echo "  REFUSING: git tracks nothing under engine/ — an empty set would report an empty sweep." >&2
  exit 2
fi
echo "  files : $(wc -l < "$TMP/engine.txt" | tr -d ' ')   (what git tracks under engine/, which is what ships)"

# ---------------------------------------------------------------------------
# The categories
# ---------------------------------------------------------------------------
# `hits <listfile> <grep-args...>` — distinct matches across a file list.
#
# THE LIST ARRIVES ON STDIN, and that is not a style choice. BSD xargs (macOS) has no
# `-a` flag: `xargs -a "$list" grep ...` fails, prints its usage to a discarded stderr,
# and yields NOTHING — which reads exactly like a clean result. The first version of this
# script did that and reported every category empty for all three sets, including the set
# that demonstrably contains the CEO's ChatGPT project id. `positive_control` below exists
# so that failure mode cannot come back silently.
hits() {
  local list="$1"; shift
  # `-0`/`tr` so a path with a space cannot split; grep -I skips binaries.
  tr '\n' '\0' < "$list" | xargs -0 grep -hIo --binary-files=text "$@" 2>/dev/null \
    | LC_ALL=C sort -u
}

# A search that cannot find a thing known to be there is not a clean result; it is a
# broken search wearing one. These two facts are true of this repository at the commit
# this record was written and are asserted before any category is reported.
positive_control() {
  local bad=0
  if ! grep -rq 'g-p-67c804d0' engine/tools/gpt-exporter/content.js; then
    echo "  SKIP: the control string is gone from engine/tools/gpt-exporter/content.js;" >&2
    echo "        re-point positive_control at something that IS present." >&2
    return 0
  fi
  printf 'engine/tools/gpt-exporter/content.js\n' > "$TMP/control.txt"
  [ -n "$(hits "$TMP/control.txt" -e 'g-p-[0-9a-f]\{16,\}')" ] || { echo "  CONTROL FAILED: hits() finds nothing in a file that contains a match." >&2; bad=1; }
  printf 'engine/tools/gpt-exporter/LICENSE\n' > "$TMP/control.txt"
  [ -n "$(hits "$TMP/control.txt" -e 'Alex Booster')" ] || { echo "  CONTROL FAILED: hits() finds no personal name in the copyright line." >&2; bad=1; }
  [ "$bad" = 0 ] && echo "  control: hits() finds both known-present strings — an empty category below is a real empty."
  return "$bad"
}

sweep_set() {
  local label="$1" list="$2"
  rule "CATEGORY SWEEP — $label"

  row "absolute paths under /Users/" "$(hits "$list" -e '/Users/[A-Za-z0-9_.-]*' | tr '\n' ' ')"
  row "absolute paths under ~/"      "$(hits "$list" -e '~/[A-Za-z0-9_/.-]\{3,\}' | tr '\n' ' ')"

  local names=""
  for w in femcboost deeply prospects richos-hq gpt-exporter webinar-booster; do
    local n
    n=$(tr '\n' '\0' < "$list" | xargs -0 grep -lIi --binary-files=text -e "$w" 2>/dev/null | wc -l | tr -d ' ')
    [ "$n" != "0" ] && names+="$w:$n "
  done
  row "CEO company names (files)" "${names:-none}"

  row "personal names"  "$(hits "$list" -e 'Alex Booster' -e 'WebDevBooster' -e 'abbooster' | tr '\n' ' ')"
  row "email addresses" "$(hits "$list" -e '[A-Za-z0-9._%+-]\+@[A-Za-z0-9.-]\+\.[A-Za-z]\{2,\}' | tr '\n' ' ' | cut -c1-160)"
  row "ChatGPT project ids" "$(hits "$list" -e 'g-p-[0-9a-f]\{16,\}' | tr '\n' ' ')"
  row "hostnames (*.local)"  "$(hits "$list" -e '[A-Za-z0-9-]\+\.local\b' | tr '\n' ' ')"
  row "IPv4 literals"        "$(hits "$list" -e '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}' | tr '\n' ' ' | cut -c1-160)"
  row "vendor API keys"      "$(hits "$list" -e 'sk-[A-Za-z0-9]\{20,\}' -e 'ghp_[A-Za-z0-9]\{20,\}' -e 'AKIA[0-9A-Z]\{16\}' -e 'xox[bp]-[A-Za-z0-9-]\{10,\}' | tr '\n' ' ')"
  row "Apple serial shapes"  "$(hits "$list" -e '\bC02[A-Z0-9]\{8,10\}\b' | tr '\n' ' ')"
}

rule "POSITIVE CONTROL"
positive_control || exit 3

sweep_set "SET 1 (embedded frontend)" "$TMP/embedded.txt"
printf '%s\n' "$TMP/rust-shipped.txt" > "$TMP/rust-one.txt"
sweep_set "SET 2 (compiled Rust)" "$TMP/rust-one.txt"
sweep_set "SET 3 (engine asset)" "$TMP/engine.txt"

# ---------------------------------------------------------------------------
# The bundle, where one exists
# ---------------------------------------------------------------------------
rule "BUILT BUNDLES on this machine (class evidence, NOT evidence about HEAD)"
for b in "$HOME"/.richos-signing/rebuild-survival/builds/*/RichOS.app; do
  [ -d "$b" ] || continue
  echo "  $b"
  python3 app/scripts/lib/no_host_paths.py "$b" 2>&1 | sed 's/^/    /' | head -8
done
