#!/usr/bin/env bash
# Wrapper so run-all-tests.sh, which discovers *.test.sh from disk, finds it.
#
# NAMED HERE, NOT ONLY IN THE .py, SO ci-affected-units.sh's RULE 3 CAN FIND
# THIS SUITE. Its logic execs spawn-guard-audience.test.py, and rule 3 greps
# only the *.test.sh files it discovers — never the .py a thin wrapper hands
# off to. Five guards landed registered in hooks/hooks.json and undeclared in
# spawn-guard-audience.declaration (found by zach-opus-canary3 at fff77cb0)
# because a diff touching either file mapped to NO unit at all: neither name
# appeared, as a literal string, in any *.test.sh on disk. dialect-table.test.sh
# already carries this same convention for its own inputs; this file adopts it.
# The suite covers, and so names for ci-affected-units.sh: hooks/hooks.json (the
# registration surface) and ../../spawn-guard-audience.declaration (the
# classification this suite checks it against).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -B "$HERE/spawn-guard-audience.test.py" "$@"
