#!/usr/bin/env bash
#
# four-routes-reopened.sh — THE REPRODUCTION FOR certification-sage-gate-integrity-2026-09-12.md
#
# Every one of the four routes past workspace-probes.py that cc/zach-opus-g4 @
# 6fd5aef8 says it closed is re-opened here, in a throwaway git repository under
# $2, against the runner and library copied out of $1. Nothing touches either
# real repository, and RICHOS_WORKSPACES_DIR is aimed inside $2 so that a probe
# which fails to sandbox itself lands there and is visible rather than silent.
#
# Each case runs its CONTROL first — the same fixture with the attack not
# applied — because a gate that refuses everything would pass an attack test.
#
#   usage: four-routes-reopened.sh <engine-tree-root> <scratch-dir>
#          e.g.  four-routes-reopened.sh /Users/alex/ab/richos "$(mktemp -d)"
#
# Exit 0 means every attack SUCCEEDED, which is the finding. Exit 1 means one of
# them was refused, which would mean this record has been overtaken.
set -uo pipefail

SRC="${1:?usage: four-routes-reopened.sh <engine-tree-root> <scratch-dir>}"
S="${2:?usage: four-routes-reopened.sh <engine-tree-root> <scratch-dir>}"
RUNNER="$SRC/engine/scripts/workspace-probes.py"
LIB="$SRC/engine/scripts/lib/workspaces.py"
[ -f "$RUNNER" ] || { echo "no runner at $RUNNER" >&2; exit 2; }
[ -f "$LIB" ] || { echo "no library at $LIB" >&2; exit 2; }

export GIT_AUTHOR_NAME="Alex Booster" GIT_AUTHOR_EMAIL="webdevbooster@gmail.com"
export GIT_COMMITTER_NAME="Alex Booster" GIT_COMMITTER_EMAIL="webdevbooster@gmail.com"
export RICHOS_WORKSPACES_DIR="$S/sandbox-registry"

BROKE=0
say() { printf '\n=========== %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

# A probe authored by <who>. It is argv-shaped (main(sys.argv[1:])), declares its
# cases the way cases_of() can read (CASES = [...]), names workspaces.py so
# is_workspaces_probe() finds it, and fails on the case named in $2.
mkprobe() {  # $1 = author  $2 = failing case or "none"  $3 = repo root
    cat > "$3/docs/verification/certification-$1-toy-2026-09-12.probe.py" <<PY
#!/usr/bin/env python3
"""A toy probe of workspaces.py by $1."""
import importlib.util, sys

CASES = ["X1", "X2", "X3"]
FAILS = "$2"


def main(argv):
    spec = importlib.util.spec_from_file_location("workspaces", argv[0])
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    assert hasattr(m, "barrier")
    want = argv[1:] or CASES
    bad = [c for c in want if c == FAILS]
    print("ran: %s ; failed: %s" % (", ".join(want), ", ".join(bad) or "(none)"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PY
}

# A fixture repository: frank's probe is RED on X2, sage's is green, the
# retirements file is empty, and HEAD is the ENGINEER's branch — the party
# failing the probe, which is whose hands every attack below is in.
fixture() {  # $1 = name -> echoes the repo path
    local R="$S/$1"
    rm -rf "$R"; mkdir -p "$R/engine/scripts/lib" "$R/docs/verification"
    cp "$RUNNER" "$R/engine/scripts/workspace-probes.py"
    cp "$LIB"    "$R/engine/scripts/lib/workspaces.py"
    mkprobe frank X2   "$R"
    mkprobe sage  none "$R"
    printf '# retirements\n' > "$R/docs/verification/workspace-probe-retirements.tsv"
    git -C "$R" init -q -b main
    git -C "$R" add -A
    git -C "$R" commit -q -m "two toy probes: sage green, frank RED on X2"
    git -C "$R" checkout -q -b cc/zach-opus-toy
    printf '%s' "$R"
}

run() {  # $1 = repo -> prints the runner's headline lines, sets RC
    ( cd "$1" && python3 engine/scripts/workspace-probes.py --tree-only ) > "$S/out.txt" 2>&1
    RC=$?
    grep -E '^(GREEN|RED|RETIRED|UNRUNNABLE|MISSING|DECLARED)|DELETED from history|every discovered probe ran' \
        "$S/out.txt" | sed 's/^/    | /'
    note "exit $RC"
}

verdict() {  # $1 = what  $2 = expected-rc-of-the-attack
    if [ "$RC" -eq "$2" ]; then
        note "ROUTE RE-OPENED: $1"
        BROKE=$((BROKE + 1))
    else
        note "refused — this record has been overtaken for: $1"
    fi
}

# ---------------------------------------------------------------------------
say "ROUTE 2 — a retirement the engineer signs with the reviewer's name."
# A3 asks: is the introducing commit contained in a local branch whose name is
# not the branch under test? It never looks at WHOSE branch, or at whether that
# branch is anything more than a second pointer at the same commit.
R="$(fixture route2)"
note "CONTROL: the probe is RED and nothing retires it"
run "$R"
note "the engineer commits a DOCS-ONLY retirement signed 'frank', on its own branch"
printf 'certification-frank-toy-2026-09-12.probe.py\tfrank\tObsolete: the premise changed.\n' \
    >> "$R/docs/verification/workspace-probe-retirements.tsv"
git -C "$R" add docs/verification/workspace-probe-retirements.tsv
git -C "$R" commit -q -m "retire frank's probe (docs only)"
note "STEP A — no other branch exists yet. A3 must refuse:"
run "$R"
note "STEP B — one command, and the branch name is not anybody's:  git branch wip"
git -C "$R" branch wip
run "$R"
verdict "A3 is answered by a bare second pointer at the same commit; no impersonation, no reviewer's branch name, and the witness prints as 'wip'" 0

# ---------------------------------------------------------------------------
say "ROUTE 4 — delete the probe, then silence MISSING with an UNCOMMITTED line."
# The MISSING filter is  `if os.path.basename(q) not in retired`  — membership in
# the TSV as parsed from the WORKING TREE. It asks A1 of nothing, and it does not
# check the signature either.
R="$(fixture route4)"
git -C "$R" rm -q docs/verification/certification-frank-toy-2026-09-12.probe.py
git -C "$R" commit -q -m "delete frank's probe"
note "CONTROL: deleted, nothing retires it — MISSING must block"
run "$R"
note "now one line in the working tree, never committed, signed 'zach' (not frank)"
printf 'certification-frank-toy-2026-09-12.probe.py\tzach\tI deleted it and I say it was obsolete.\n' \
    >> "$R/docs/verification/workspace-probe-retirements.tsv"
git -C "$R" status --porcelain | sed 's/^/    | /'
run "$R"
verdict "MISSING is suppressed by an uncommitted line signed by the wrong name — A1, A2, A3 and the author check are all bypassed" 0

# ---------------------------------------------------------------------------
say "ROUTE 1 — annotate the reviewer's probe, in the same commit as the engine change."
# A2 is deliberately not asked of a `not-a-probe:` marker, so the marker may ride
# in the very commit that broke the probe. Only A1 and A3 apply, and A3 is the
# one answered above.
R="$(fixture route1)"
note "CONTROL: frank's probe is RED"
run "$R"
note "ONE commit that edits the library AND annotates the probe it fails, then: git branch wip"
printf '\n# a change to the library, in the same commit\n' >> "$R/engine/scripts/lib/workspaces.py"
printf '\n# not-a-probe: this asserts nothing any more\n' \
    >> "$R/docs/verification/certification-frank-toy-2026-09-12.probe.py"
git -C "$R" add -A
git -C "$R" commit -q -m "engine change plus a not-a-probe marker on the probe it fails"
git -C "$R" branch wip
run "$R"
verdict "the exact shape A2 exists to refuse is accepted for a marker, and the probe leaves the run" 0

# ---------------------------------------------------------------------------
say "ROUTE 3 — a probe driven through getattr is still not discovered."
# The runner's header says: "a probe reaching the library through \`getattr\` ...
# was SILENTLY NOT DISCOVERED ... So loading the library at all counts, which is
# something every probe of it must do however it then drives it."
# The code is  `return loads and drives_entry`  and drives_entry needs an entry
# point spelled with an opening parenthesis. Nothing the engineer does here; the
# probe was simply written that way.
# Built from scratch rather than from fixture(): frank's toy probe must never
# have EXISTED here, because a probe deleted from history is MISSING and MISSING
# blocks -- which would mask the result this case is about.
R="$S/route3"
rm -rf "$R"; mkdir -p "$R/engine/scripts/lib" "$R/docs/verification"
cp "$RUNNER" "$R/engine/scripts/workspace-probes.py"
cp "$LIB"    "$R/engine/scripts/lib/workspaces.py"
mkprobe sage none "$R"
printf '# retirements\n' > "$R/docs/verification/workspace-probe-retirements.tsv"
cat > "$R/docs/verification/certification-frank-getattr-2026-09-12.probe.py" <<'PY'
#!/usr/bin/env python3
"""frank's probe. Drives the library handed to it, by name, at runtime."""
import importlib.util, sys
CASES = ["F1"]
ENTRY = "register" + "_spawn"
def main(argv):
    spec = importlib.util.spec_from_file_location("lib", argv[0])
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    fn = getattr(m, ENTRY)
    print("drove %r" % fn.__name__)
    print("F1 FAILS -- this is the assertion that should block")
    return 1
if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PY
git -C "$R" init -q -b main
git -C "$R" add -A
git -C "$R" commit -q -m "a green probe, and frank's probe driven through getattr"
git -C "$R" checkout -q -b cc/zach-opus-toy
note "it exits 1 when run by hand:"
( cd "$R" && python3 docs/verification/certification-frank-getattr-2026-09-12.probe.py \
    engine/scripts/lib/workspaces.py ) 2>&1 | sed 's/^/    | /'
note "and the runner:"
run "$R"
verdict "a red probe that never spells an entry point with a parenthesis is counted under 'not probes of this library' and the run exits 0" 0

# ---------------------------------------------------------------------------
say "did anything write outside its sandbox?"
if [ -d "$RICHOS_WORKSPACES_DIR" ]; then
    note "the belt-and-braces registry at $RICHOS_WORKSPACES_DIR was populated:"
    find "$RICHOS_WORKSPACES_DIR" | sed 's/^/    | /'
else
    note "$RICHOS_WORKSPACES_DIR was never created — nothing here drove the library's writers"
fi

say "$BROKE of 4 routes re-opened"
[ "$BROKE" -eq 4 ] && exit 0
exit 1
