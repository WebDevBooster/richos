#!/usr/bin/env bash
#
# provision-claude-md.test.sh — tests for scripts/provision-claude-md.sh.
#
# Covers the two things that make provisioning trustworthy rather than merely convenient:
#   (a) a bare boot IS Rich — the generated CLAUDE.md carries the CEO's actuals, and no adopter
#       instruction, sample rule, or invented value survives into live doctrine;
#   (b) it is safe to run twice — idempotent on unchanged inputs, refreshing an unedited file, and
#       NEVER clobbering a CEO-edited one.
#
# Test names document the invariant. Run directly: scripts/provision-claude-md.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROV="$SCRIPT_DIR/provision-claude-md.sh"
TEMPLATE="$ENGINE_ROOT/CLAUDE.md.template"

PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ok() { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
no() { printf '  FAIL  %s\n      %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }

# assert_exit <name> <expected> <command...>
assert_exit() {
    local name="$1" expected="$2"; shift 2
    "$@" >/dev/null 2>&1
    local actual=$?
    [ "$actual" -eq "$expected" ] && ok "$name" || no "$name" "expected exit $expected, got $actual"
}

# assert_has <name> <file> <needle>
assert_has() {
    grep -qF -- "$3" "$2" && ok "$1" || no "$1" "expected to find: $3"
}

# assert_lacks <name> <file> <needle>
assert_lacks() {
    grep -qF -- "$3" "$2" && no "$1" "should NOT contain: $3" || ok "$1"
}

mkconfig() {  # mkconfig <path> <ceo-name>
    cat >"$1" <<CFG
COMPANY_NAME="Meridian Robotics"
CEO_NAME="$2"
COMPANY_DOMAIN="meridian-robotics.example"
COMPANY_ONE_LINER="Shop-floor robotics for mid-market manufacturers."
LORO_PATH="../loro"
CFG
}

CFG="$WORK/identity.config"
OUT="$WORK/CLAUDE.md"
mkconfig "$CFG" "Dana Whitlock"

run() { "$PROV" --config "$CFG" --template "$TEMPLATE" --out "$OUT" "$@"; }

printf '\n== required values ==\n'

: >"$WORK/blank.config"
assert_exit 'provisioning: a blank COMPANY_NAME is REFUSED, never written as a TODO placeholder' 2 \
    "$PROV" --config "$WORK/blank.config" --template "$TEMPLATE" --out "$WORK/never.md"
[ -f "$WORK/never.md" ] && no 'provisioning: a refused run writes nothing' || ok 'provisioning: a refused run writes nothing'

assert_exit 'provisioning: a missing identity.config is REFUSED with a usage error' 2 \
    "$PROV" --config "$WORK/absent.config" --template "$TEMPLATE" --out "$WORK/never2.md"

printf '\n== first run ==\n'

assert_exit 'provisioning: a first run generates CLAUDE.md and exits 0' 0 run
assert_has "provisioning: the generated file names the CEO, so a bare boot knows who it serves" "$OUT" 'Dana Whitlock'
assert_has 'provisioning: the generated file names the company' "$OUT" 'Meridian Robotics'
assert_has 'provisioning: the generated file IS the Rich persona, not generic Claude' "$OUT" 'You are **Rich Hand**'
assert_lacks 'provisioning: no adopter TODO block survives into live doctrine' "$OUT" 'TODO (adopter)'
assert_lacks 'provisioning: the adopter-facing template header is stripped' "$OUT" 'Copy this to CLAUDE.md in your repo root'
assert_lacks "provisioning: the sample pagination rule never ships as this company's doctrine" "$OUT" '**No pagination — ever.**'
assert_has 'provisioning: an unconfigured section says NOT CONFIGURED and forbids inventing a value' "$OUT" 'never invent a value to fill this gap'
assert_has 'provisioning: the file carries an engine-version provenance stamp' "$OUT" '<!-- richos-provisioned: engine='
assert_has 'provisioning: Rich is pointed at loro for company memory' "$OUT" 'loro-context.mjs compile'
assert_has 'provisioning: Rich is told to scope a teammate slice with --audience worker' "$OUT" '--audience worker'

# THE LOCALE RULE MUST SURVIVE INTO LIVE DOCTRINE. A dialect that lives only in
# the template is a dialect nobody is bound by: the whole point is that the
# implementer reads it in CLAUDE.md, not in the engine's docs. Both arms —
# unconfigured is an honest refusal to guess, configured reaches the doctrine
# verbatim — because either one alone can pass while the other silently rots.
assert_has 'provisioning: an unconfigured locale refuses to pick a dialect rather than defaulting to one' \
    "$OUT" 'No locale is recorded'
LOCALE_CFG="$WORK/locale.config"
mkconfig "$LOCALE_CFG" "Dana Whitlock"
printf 'PRODUCT_LOCALE="**American English.** Dates M/D/YYYY, USD."\n' >> "$LOCALE_CFG"
"$PROV" --config "$LOCALE_CFG" --template "$TEMPLATE" --out "$WORK/locale.md" >/dev/null 2>&1
assert_has 'provisioning: a configured locale reaches live doctrine verbatim, where an implementer reads it' \
    "$WORK/locale.md" '**American English.** Dates M/D/YYYY, USD.'

printf '\n== idempotency and no-clobber ==\n'

BEFORE="$(shasum "$OUT" | awk '{print $1}')"
OUT_MSG="$(run 2>&1)"
AFTER="$(shasum "$OUT" | awk '{print $1}')"
[ "$BEFORE" = "$AFTER" ] && ok 'provisioning: re-running with unchanged inputs leaves the file byte-identical' \
    || no 'provisioning: re-running with unchanged inputs leaves the file byte-identical' 'file changed'
printf '%s' "$OUT_MSG" | grep -q 'up-to-date' && ok 'provisioning: an unchanged re-run reports up-to-date, not a rewrite' \
    || no 'provisioning: an unchanged re-run reports up-to-date, not a rewrite' "$OUT_MSG"

mkconfig "$CFG" "Robin Alvarez"
OUT_MSG="$(run 2>&1)"
printf '%s' "$OUT_MSG" | grep -q 'refreshed' && ok 'provisioning: changed identity values REFRESH an unedited file' \
    || no 'provisioning: changed identity values REFRESH an unedited file' "$OUT_MSG"
assert_has 'provisioning: a refresh carries the new CEO name' "$OUT" 'Robin Alvarez'

printf '\n== the CEO edited it ==\n'

printf '\n<!-- the CEO added this line by hand -->\n' >>"$OUT"
EDITED="$(shasum "$OUT" | awk '{print $1}')"
OUT_MSG="$(run 2>&1)"
[ "$(shasum "$OUT" | awk '{print $1}')" = "$EDITED" ] \
    && ok 'provisioning: a CEO-edited CLAUDE.md is NEVER clobbered' \
    || no 'provisioning: a CEO-edited CLAUDE.md is NEVER clobbered' 'the file was overwritten'
printf '%s' "$OUT_MSG" | grep -q 'preserved' && ok 'provisioning: the edited case reports preserved, loudly' \
    || no 'provisioning: the edited case reports preserved, loudly' "$OUT_MSG"

run --upgrade >/dev/null 2>&1
[ -f "$OUT.new" ] && ok 'provisioning: --upgrade writes the new render BESIDE the edited file for hand-merge' \
    || no 'provisioning: --upgrade writes the new render BESIDE the edited file for hand-merge' 'no CLAUDE.md.new'
[ "$(shasum "$OUT" | awk '{print $1}')" = "$EDITED" ] \
    && ok 'provisioning: --upgrade still does not touch the edited file' \
    || no 'provisioning: --upgrade still does not touch the edited file' 'the file was overwritten'

run --force >/dev/null 2>&1
[ "$(shasum "$OUT" | awk '{print $1}')" != "$EDITED" ] \
    && ok 'provisioning: --force overwrites an edited file ONLY when explicitly asked' \
    || no 'provisioning: --force overwrites an edited file ONLY when explicitly asked' 'nothing changed'

HAND="$WORK/hand.md"
printf '# my own CLAUDE.md\n' >"$HAND"
"$PROV" --config "$CFG" --template "$TEMPLATE" --out "$HAND" >/dev/null 2>&1
[ "$(cat "$HAND")" = '# my own CLAUDE.md' ] \
    && ok 'provisioning: a hand-authored CLAUDE.md with no stamp is never overwritten' \
    || no 'provisioning: a hand-authored CLAUDE.md with no stamp is never overwritten' 'it was replaced'

printf '\n== --check and template drift ==\n'

assert_exit 'provisioning: --check exits 1 when CLAUDE.md has not been provisioned' 1 \
    "$PROV" --config "$CFG" --template "$TEMPLATE" --out "$WORK/nothing-here.md" --check
FRESH="$WORK/fresh.md"
run --out "$FRESH" >/dev/null 2>&1
"$PROV" --config "$CFG" --template "$TEMPLATE" --out "$FRESH" >/dev/null 2>&1
assert_exit 'provisioning: --check exits 0 when the generated file is current' 0 \
    "$PROV" --config "$CFG" --template "$TEMPLATE" --out "$FRESH" --check

DRIFT="$WORK/drifted.template.md"
{ cat "$TEMPLATE"; printf '\n<!-- TODO (adopter): describe your brand new unknown section here. -->\n'; } >"$DRIFT"
assert_exit 'provisioning: an UNRECOGNIZED template block fails loud rather than leaking adopter instructions' 2 \
    "$PROV" --config "$CFG" --template "$DRIFT" --out "$WORK/drift-out.md"

printf '\n== the identity seam other components read ==\n'

JSON="$("$PROV" --config "$CFG" --template "$TEMPLATE" --identity-json 2>/dev/null)"
printf '%s' "$JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["company_name"]=="Meridian Robotics" and d["ceo_name"]=="Robin Alvarez" else 1)' \
    && ok 'provisioning: --identity-json exposes company_name/ceo_name as the ONE source of truth' \
    || no 'provisioning: --identity-json exposes company_name/ceo_name as the ONE source of truth' "$JSON"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
