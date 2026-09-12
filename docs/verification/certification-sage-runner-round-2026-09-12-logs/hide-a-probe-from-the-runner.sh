#!/bin/bash
# hide-a-probe-from-the-runner.sh — Sage, 2026-09-12.
#
# The brief for this review said: "Undiscovered is worse than red: try to hide a
# probe from it." This is that attempt, made against
# engine/scripts/workspace-probes.py as it stands at 4c70bfc2, in a throwaway
# repository under $TMPDIR. It touches nothing outside that directory: no real
# repository, no ~/.claude/state, no engine install.
#
#     bash docs/verification/.../hide-a-probe-from-the-runner.sh
#
# It runs four steps and prints the runner's exit code after each.
#
#   A  a red probe blocks             — the control, so the rest measures something
#   B  ATTACK 1: the person failing the probe adds ONE line to it,
#      `# not-a-probe: superseded elsewhere`, and the run goes green
#   C  --show-all, which the runner's own header offers as the way to see a
#      declared non-probe, prints its heading and NOTHING under it
#   D  ATTACK 2: a probe that drives the library through argv and never spells
#      the literal string "workspaces.py" is never discovered at all, with the
#      same file spelled out as the matched control
set -u
T="$(mktemp -d "${TMPDIR:-/tmp}/hide-probe-XXXXXX")"
trap 'rm -rf "$T"' EXIT
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

mkdir -p "$T/engine/scripts/lib" "$T/docs/verification" "$T/home"
cp "$SRC/engine/scripts/workspace-probes.py" "$T/engine/scripts/"
cp "$SRC/engine/scripts/lib/"*.py "$T/engine/scripts/lib/"
export HOME="$T/home"
printf '[user]\n\tname=p\n\temail=p@example.invalid\n[init]\n\tdefaultBranch=main\n' > "$HOME/.gitconfig"
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
git -C "$T" init -q -b main
D="$T/docs/verification"
R="$T/engine/scripts/workspace-probes.py"

# A probe that is green, so the tree is never empty of probes — that is what
# makes the zero-probe refusal (W10) stop rescuing the run.
cat > "$D/certification-frank-other-probe.py" <<'PY'
"""A second, green probe of engine/scripts/lib/workspaces.py."""
import importlib.util, sys, os
spec = importlib.util.spec_from_file_location("workspaces", os.path.abspath(sys.argv[1]))
ws = importlib.util.module_from_spec(spec); spec.loader.exec_module(ws)
assert hasattr(ws, "land")
def main(a): return 0
if __name__ == "__main__": sys.exit(main(sys.argv[1:]))
PY

red_probe() {   # $1 = extra first line
    { [ -n "${1:-}" ] && printf '%s\n' "$1"; cat <<'PY'
"""A reviewer's probe of engine/scripts/lib/workspaces.py that the build fails."""
import importlib.util, sys, os
spec = importlib.util.spec_from_file_location("workspaces", os.path.abspath(sys.argv[1]))
ws = importlib.util.module_from_spec(spec); spec.loader.exec_module(ws)
assert hasattr(ws, "an_entry_point_this_build_does_not_have")
def main(a): return 0
if __name__ == "__main__": sys.exit(main(sys.argv[1:]))
PY
    } > "$D/certification-sage-red-probe.py"
}

git -C "$T" add -A >/dev/null; git -C "$T" commit -qm base

echo "=== A. CONTROL — the red probe is discovered and blocks"
red_probe ""
python3 "$R" 2>&1 | grep -E "^probes discovered|^RED|^GREEN|every discovered"
python3 "$R" >/dev/null 2>&1; echo "    exit=$?"

echo
echo "=== B. ATTACK 1 — one line, added by the person failing it, no author check"
red_probe "# not-a-probe: superseded elsewhere"
python3 "$R" 2>&1 | grep -E "^probes discovered|^other files|^RED|^GREEN|every discovered"
python3 "$R" >/dev/null 2>&1; echo "    exit=$?"

echo
echo "=== C. --show-all, offered by the runner's own header as the way to see it"
python3 "$R" --show-all 2>&1 | sed -n '/--- files under docs/,$p'

echo
echo "=== D. ATTACK 2 — a probe that never spells the literal \"workspaces.py\""
rm -f "$D/certification-sage-red-probe.py"
cat > "$D/certification-sage-indirect-probe.py" <<'PY'
"""A reviewer's probe that takes the library as an argument, as probes do."""
import importlib.util, sys, os
LIBNAME = "workspaces" + "." + "py"
spec = importlib.util.spec_from_file_location("workspaces", os.path.abspath(sys.argv[1]))
ws = importlib.util.module_from_spec(spec); spec.loader.exec_module(ws)
assert hasattr(ws, "an_entry_point_this_build_does_not_have")
def main(a): return 0
if __name__ == "__main__": sys.exit(main(sys.argv[1:]))
PY
python3 "$R" 2>&1 | grep -E "^probes discovered|^RED|^GREEN|every discovered"
python3 "$R" >/dev/null 2>&1; echo "    exit=$?"

echo
echo "=== D-control — the SAME file with the name spelled out"
python3 - "$D/certification-sage-indirect-probe.py" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
open(p, "w").write(s.replace('LIBNAME = "workspaces" + "." + "py"', 'LIBNAME = "workspaces.py"'))
PY
python3 "$R" 2>&1 | grep -E "^probes discovered|^RED|^GREEN|every discovered"
python3 "$R" >/dev/null 2>&1; echo "    exit=$?"
