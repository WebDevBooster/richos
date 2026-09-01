#!/usr/bin/env bash
# A MACHINE THAT HAS NEVER SEEN RICHOS, PROVISIONED, AND THEN FOUND.
#
# A clean HOME: no `Library/Application Support/RichOS`, no pointer of any kind, no corpus
# anywhere. The CEO's own $HOME is never read and never written by this script — every path
# below is under the throwaway HOME it creates.
#
# THREE STEPS, AND THE THIRD IS THE ONE THAT MATTERS:
#   1. locate, with nothing in place            -> "no corpus configured", three candidates named
#   2. provision                                -> the corpus, the git repo, the compiler, the pointer
#   3. locate again, UNDER AN EMPTY ENVIRONMENT -> "compiling from <HOME>/RichOS/corpus"
#
# Step 2 is run with RICHOS_LORO_SOURCE naming the compiler's source. That variable is an
# INSTALLER input and it is here because nothing ships the compiler yet: the product repo
# holds no `loro/` and the signed bundle's Resources hold `icon.icns` and nothing else
# (BLOCKED.md). It stands in for the bundle resource that does not exist. STEP 3 READS NO
# ENVIRONMENT AT ALL beyond HOME and PATH, which is the half that has to hold on a
# customer's machine.
set -uo pipefail

APP_DIR="$(cd "$(dirname "$0")/../../../../app" && pwd)"
SIM="${1:?usage: fresh-install.sh <throwaway-home> [compiler-source]}"
SOURCE="${2:-/Users/alex/ab/richos-hq/loro}"
CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"

rm -rf "$SIM"
mkdir -p "$SIM"
echo "=== a HOME that has never seen RichOS: $SIM ==="
find "$SIM" -mindepth 1 | head
echo "(empty)"

DEMO="$APP_DIR/target/debug/examples/first_run_demo"
( cd "$APP_DIR" && "$CARGO" build -q -p richos-core --example first_run_demo ) || exit 1

echo
echo "=== steps 1 and 2: nothing in place, then provisioned ==="
/usr/bin/env -i \
    HOME="$SIM" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    RICHOS_LORO_SOURCE="$SOURCE" \
    "$DEMO"
rc=$?
echo "(exit $rc)"
[ $rc -eq 0 ] || exit $rc

echo
echo "=== what is on disk now ==="
find "$SIM" -maxdepth 4 -not -path "*/loro-tools/*" -not -path "*/.git/*" | sort
echo
echo "--- the pointer ---"
ls -l "$SIM/Library/Application Support/RichOS/"
echo "--- git, in the corpus ---"
git -C "$SIM/RichOS/corpus" log --oneline
git -C "$SIM/RichOS/corpus" remote -v
echo "(no output above means no remote, which is the point)"
echo "--- the compiler's freshness stamp ---"
cat "$SIM/Library/Application Support/RichOS/loro-tools/INSTALLED-FROM"

echo
echo "=== step 3: THE SAME RESOLVER, ENVIRONMENT HOLDING NOTHING BUT HOME AND PATH ==="
/usr/bin/env -i HOME="$SIM" PATH="/usr/bin:/bin:/usr/sbin:/sbin" "$DEMO"
echo "(exit $?)"

echo
echo "=== and the compiler actually runs against it ==="
/usr/bin/env -i HOME="$SIM" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    "$APP_DIR/target/debug/examples/loro_reprime_demo" "what did we decide about code signing?" 2>&1 |
    head -20
