#!/usr/bin/env bash
#
# install-settings-parse-error.test.sh — install.sh never deletes a settings.json
# it cannot parse.
#
# Until this suite, a settings.json that failed to parse (a truncated write, a
# stray comma) was removed outright, taking whatever the user kept in it with
# it and leaving no copy (hunt 2026-09-29 part 3, finding 7). The reason for
# removing it still holds: a broken file must stop being loaded so the
# canonical settings.local.json is the only settings file. So it is MOVED ASIDE
# instead, which does both. What this proves, in a sandbox only:
#
#   P1  an unparseable settings.json stops being loaded (the exact name is gone)
#   P2  ... and its bytes survive, unchanged, in a *.unparseable-*.bak beside it
#   P3  the install says where the copy went, and still succeeds
#   P4  a parseable, hook-free duplicate is still removed (the old behavior,
#       which this change must not touch)
#
# Every run uses a copied engine, a fake HOME and a sandboxed CLAUDE_CONFIG_DIR.
#
# Run directly: scripts/hooks/install-settings-parse-error.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
SCRATCH="$(cd "$(mktemp -d -t install-settings.XXXXXX)" && pwd -P)"
trap 'chmod -R u+w "$SCRATCH" 2>/dev/null; rm -rf "$SCRATCH"' EXIT

ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s%s\n' "$1" "${2:+ ($2)}"; FAIL=$((FAIL + 1)); }

echo "=== install.sh keeps a settings.json it cannot parse ==="

EPH="$SCRATCH/eph-engine"
mkdir -p "$EPH/.claude" "$EPH/hooks"
cp -R "$ENGINE_ROOT/scripts" "$EPH/scripts"
cp -R "$ENGINE_ROOT/mega-lander" "$EPH/mega-lander"
cp -R "$ENGINE_ROOT/ass-kicker" "$EPH/ass-kicker"
cp "$ENGINE_ROOT/VERSION" "$EPH/VERSION"
cp "$ENGINE_ROOT/.claude/settings.local.json" "$EPH/.claude/settings.local.json"
cp "$ENGINE_ROOT/hooks/hooks.json" "$EPH/hooks/hooks.json"

FAKEHOME="$SCRATCH/home"
mkdir -p "$FAKEHOME/.claude"
CFG="$SCRATCH/cfg"
mkdir -p "$CFG"
AGENTS="$SCRATCH/LaunchAgents"
mkdir -p "$AGENTS"

# launchctl is SHIMMED: a red run must not be able to reach the operator's launchd.
SHIM="$SCRATCH/shim"; mkdir -p "$SHIM"
printf '#!/usr/bin/env bash\nexit 0\n' >"$SHIM/launchctl"
chmod +x "$SHIM/launchctl"

install_run() { # -> OUT, RC
    OUT="$(env HOME="$FAKEHOME" CLAUDE_CONFIG_DIR="$CFG" PATH="$SHIM:$PATH" \
               RICHOS_LAUNCH_AGENTS_DIR="$AGENTS" bash "$EPH/scripts/hooks/install.sh" 2>&1)"
    RC=$?
}

SETTINGS="$EPH/.claude/settings.json"

# A truncated JSON document carrying a setting that is the user's own.
printf '{"private-user-setting": "keep-me", "env": {"A": "1"' >"$SETTINGS"
ORIGINAL="$(cat "$SETTINGS")"

install_run

if [ "$RC" -eq 0 ] && [ ! -e "$SETTINGS" ]; then
    ok "P1 the unparseable settings.json is no longer loaded under its own name"
else
    bad "P1 not moved away" "rc=$RC settings=$([ -e "$SETTINGS" ] && echo present || echo gone) out=$(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"
fi

BAK=""
for f in "$EPH"/.claude/settings.json.unparseable-*.bak; do
    [ -e "$f" ] && BAK="$f" && break
done
if [ -n "$BAK" ] && [ "$(cat "$BAK")" = "$ORIGINAL" ]; then
    ok "P2 its bytes survive unchanged in a .bak beside it"
else
    bad "P2 no intact backup" "bak=${BAK:-none}"
fi

if [ -n "$BAK" ] && printf '%s' "$OUT" | grep -qF "$BAK"; then
    ok "P3 the install names where the copy went"
else
    bad "P3 backup path not reported" "out=$(printf '%s' "$OUT" | grep -i 'settings.json' | head -2 | tr '\n' ' ')"
fi

# P4 — the pre-existing path: a parseable duplicate of the canonical source
# (no hooks) is still deleted outright.
python3 - "$EPH/.claude/settings.local.json" "$SETTINGS" <<'PY'
import json, sys
src = json.load(open(sys.argv[1]))
json.dump({k: v for k, v in src.items() if k != "hooks"}, open(sys.argv[2], "w"))
PY
install_run
if [ "$RC" -eq 0 ] && [ ! -e "$SETTINGS" ] && printf '%s' "$OUT" | grep -qF 'removed stale hook-duplicating'; then
    ok "P4 a parseable pure duplicate is still removed"
else
    bad "P4 duplicate handling changed" "rc=$RC settings=$([ -e "$SETTINGS" ] && echo present || echo gone)"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== install-settings-parse-error: $FAIL FAILED, $PASS passed ==="
    exit 1
fi
echo "=== install-settings-parse-error: all $PASS passed ==="
exit 0
