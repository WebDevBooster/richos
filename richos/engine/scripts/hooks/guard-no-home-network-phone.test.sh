#!/usr/bin/env bash
#
# guard-no-home-network-phone.test.sh — regression tests for
# scripts/hooks/guard-no-home-network-phone.sh.
#
# THE FIXTURES ARE THE REAL TEXTS OF 2026-09-19, not paraphrases of them. That
# is the whole design of this suite: the guard exists because of four specific
# documents, two of which must be refused and two of which must pass, and a
# synthetic fixture cannot tell you which side of that line a change lands on.
# Every quoted block below is copied from the file named above it.
#
# Covered here:
#
#   (a) REFUSES the two sentences ceo-decisions §61's addendum names —
#       "the At-home path stays" and "Do not remove the At-home option" — as an
#       Agent spawn AND as a markdown Write;
#   (b) REFUSES a code write that adds `At home only` to phone.js, including
#       the adjacent-button case where the line above carries a negation cue;
#   (c) PASSES §61 and its addendum, which name every term the guard looks for
#       and are the record of the ruling itself — by MERIT, with no path
#       exemption, because a guard that forbids the record of what it forbids
#       is the shape that cost this engine fourteen vendored lines in 2026-08;
#   (d) PASSES the removal brief that was running when this was written, which
#       names the home path in nine blocks and quotes the refused sentence back
#       at the engineer;
#   (e) PASSES an unrelated write that mentions a home network with no phone
#       signal anywhere — conjunct (a) is what keeps this guard out of every
#       repository that has nothing to do with a phone;
#   (f) THE HATCH IS A CITATION: a live `ceo-ruled-home-network:` line naming a
#       section that EXISTS in the CEO's record and quoting from it permits the
#       call and is LOGGED; a bare marker, a section with no quotation, and a
#       citation of a section that is NOT in the record each exempt nothing and
#       are refused BY NAME;
#   (g) FAIL OPEN: an unparseable payload, a call for another tool, a
#       repository that never adopted the engine, and a declared off switch all
#       allow — the first loudly, the rest in silence;
#   (h) the self-exemption is by BASENAME and covers exactly four files;
#   (i) the one hard refusal: a missing scripts/lib/resolve-roots.sh prints the
#       shared BROKEN INSTALL banner and exits 2.
#
# Run directly: scripts/hooks/guard-no-home-network-phone.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$SCRIPT_DIR/guard-no-home-network-phone.sh"

# DECLARED, never inherited from the launching session: run from a session
# seated elsewhere, every case below would pass by standing down.
unset CLAUDE_PROJECT_DIR

PASS=0
FAIL=0

SB="$(cd "$(mktemp -d -t guard-no-home-network-phone.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SB"' EXIT

ENTITY="$SB/entity"
HQ="$SB/hq"
mkdir -p "$ENTITY/.claude/state" "$HQ/wiki"
printf 'PROTECTED_PATHS=""\nCEO_TODOS_REPOS="%s"\n' "$HQ" >"$ENTITY/orchestration.config"
: >"$HQ/.ceo-todos"

# The record the hatch must resolve against. §61 is here; §99 deliberately is
# not, and case F4 cites §99.
{
    printf '## %s61 — Mobile is purely optional; the definition of a mobile app\n\n' "§"
    printf 'Body.\n\n'
    printf '### %s61.1 — The Tailscale identity trap\n\n' "§"
    printf 'Body.\n'
} >"$HQ/wiki/ceo-decisions.md"

# ===========================================================================
# THE FIXTURES — real text, from the files named
# ===========================================================================

# richos-hq/docs/briefs/echo-brief-the-chosen-route-reaches-the-backend-2026-09-19.md
# Lines 3 and 11. These are the two sentences §61's addendum is about.
read -r -d '' ROUTE1 <<'FIX' || true
# Brief: the user's route choice reaches the backend

**CEO, verbatim.** §61 (2026-09-18): two paths, the Tailscale path first and *"the approach that costs me money will be added later"*; the At-home path stays. §61.1: the identity trap *"would need to be made ABSOLUTELY UBER MEGA SUPER CRYSTAL-CLEAR to ever user of RichOS"* — *"I would ABSOLUTELY NEVER have both the phone and the desktop computer share the same identity."*

**The fix Urban requires, and there is one:** the user's answer is an input to the backend, not a label on a button. `phone_begin_pairing` takes the chosen route; `serving_plan` takes it too and returns the home plan when the user said at-home, even on a Mac with a valid tailnet certificate; `pairing_path` follows the plan as it already does. Both address sets and both origins already exist. **Do not remove the At-home option, and do not fix it in the UI.**
FIX

# richos-hq/wiki/ceo-decisions.md — the §61 addendum of 2026-09-19 ~15:05Z, the
# ruling that ordered this guard. Dense with every term the guard looks for.
read -r -d '' S61 <<'FIX' || true
**Addendum, 2026-09-19 ~15:05Z — his question, verbatim: *"How many more times will any "home network" related shit be associated with a phone or built for phone?"*** The answer is zero, and it is enforced rather than remembered. Rich had kept the "At home only" route (self-signed certificate, trust page on 8444, sixteen taps, the `.local` origin) across three briefs on 2026-09-19 although this ruling already made it useless; it is being removed. From this line on: (1) a test in the app's own suite fails if the phone flow or its backend names a home-network path again; (2) an engine guard refuses any brief, code write or spawn that associates the phone with a home network unless the text quotes a CEO ruling reinstating it. **There is one phone path now (Tailscale) and one later (the paid relay); nothing else.**
FIX

# richos-hq/docs/briefs/echo-brief-remove-the-at-home-route-2026-09-19.md — the
# brief that removed the route. Note block 3: it QUOTES the refused sentence.
read -r -d '' ONEPATH <<'FIX' || true
# Brief: the "At home only" route is removed — a phone app is for outside the home network, so "Use Rich from your phone" leads straight to the Tailscale screens (CEO §61)

**Rich's error, stated so you do not inherit it:** the route chooser ("Anywhere, including away from home" / "At home only") and the whole At-home path — the self-signed certificate, the trust QR at `http://<name>.local:8444/ca`, the sixteen certificate taps, the `.local:8443` origin — survived §61, and today's briefs (route1: "Do not remove the At-home option … §61 keeps both") asserted a ruling that does not exist. §61 keeps exactly one path now (Tailscale) and one later (the paid relay). The At-home path is not a second path; it is the thing his definition calls useless.

1. **The chooser goes.** Settings → *Use Rich from your phone* opens on the Tailscale flow directly. No "At home only" option, no `Pick a different way` back to a chooser.
2. **The At-home path's screens, copy and machinery leave the product**: the trust QR / CA-download page and its HTTP listener on 8444, the sixteen-tap walkthrough, the `.local` pairing origin, `Route::AtHome` and the home plan in `serving_plan` (a Mac with no Tailscale account is not "at home", it is "not set up yet" and gets the how-to screens).
FIX

# richos/app/ui/phone.js — the two route buttons, adjacent, as they are shipped.
# The FIRST line carries "away from home", which is a negation cue. Scored as
# one block these two lines would exempt each other; a code surface is scored
# per line, and this fixture is why.
read -r -d '' PHONEJS <<'FIX' || true
        <button id="phone-route-anywhere" class="desk-btn" type="button">Anywhere, including away from home</button>
        <button id="phone-route-home" class="desk-btn" type="button">At home only</button>
FIX

# Somebody else's repository, somebody else's home network, no phone anywhere.
#
# DELIBERATELY CARRYING NO NEGATION CUE. A fixture that said "a home network is
# never part of the path" would pass through conjunct (c) and prove nothing
# about conjunct (a) — the shape this project calls a negative test that passes
# for the wrong reason. Case E1b is its positive probe: the SAME sentences with
# the word "phone" in them must be refused.
read -r -d '' UNRELATED <<'FIX' || true
The coach's browser reaches the Convex deployment over the public internet.
A home network sits between the laptop and the router, and the self-signed
certificate on the local dev server is trusted only there.
FIX

# The spawn prompt for the removal brief, lines 46-48 — the orchestrator's
# PROVENANCE apparatus quoting the brief back at the engineer with CURLY pairs,
# and truncating mid-sentence. This exact block was the ONE false positive of
# the first measured pass: the truncation cut the item off before "leave the
# product", so what survives is a bare "The At-home path's screens" with no
# statement about it at all. It is quoted matter, and it must pass.
read -r -d '' PROVENANCE <<'FIX' || true
**Presented as a quotation, and NOT found in the file named:**

- “option, no `Pick a different way` back to a chooser (the control's other job — leaving the pairing screen and stopping serving — stays, and returns to `This Mac is ready`).
2. **The At-home path's screens, copy and machi”
  (presented as from docs/verification/ui-ux-signoffs/URBAN_SIGNOFF_2026-09-19_05.14.md; this run is NOT in that file)
FIX

# richos-hq/docs/briefs/echo-brief-tailscale-path-2026-09-19.md, the brief that
# STARTED the Tailscale path. It describes today's pairing, and "sixteen" is
# the only home-shaped word in it. A number word is not a home path.
read -r -d '' SIXTEEN_ALONE <<'FIX' || true
Pairing today: QR, then the user installs the Mac's CA profile on the phone
(sixteen taps), then six words.
FIX

# ===========================================================================
# HARNESS
# ===========================================================================

# payload <tool> <file_path> <text> [cwd]
payload() {
    python3 - "$1" "$2" "$3" "${4-}" <<'PY'
import json, sys
tool, path, text, cwd = sys.argv[1:5]
if tool == "Agent":
    ti = {"subagent_type": "echo", "name": "echo-opus-t1", "prompt": text,
          "isolation": "worktree"}
elif tool == "Write":
    ti = {"file_path": path, "content": text}
elif tool == "Edit":
    ti = {"file_path": path, "old_string": "PLACEHOLDER", "new_string": text}
elif tool == "MultiEdit":
    ti = {"file_path": path, "edits": [{"old_string": "P", "new_string": text}]}
else:
    ti = {"command": text}
d = {"tool_name": tool, "tool_input": ti,
     "session_id": "hn000000-0000-4000-8000-000000000000",
     "tool_use_id": "toolu_hn_test"}
if cwd:
    d["cwd"] = cwd
print(json.dumps(d))
PY
}

RC=0
OUT=""
run() {   # <json> [extra env assignments...]
    local json="$1"; shift
    set +e
    OUT="$(printf '%s' "$json" | env RICHOS_ENTITY_ROOT="$ENTITY" "$@" "$HOOK" 2>&1)"
    RC=$?
    set -e
}

ok()  { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s%s\n' "$1" "${2:+ — $2}"; }

expect_rc() {   # <name> <rc> <json>
    run "$3"
    if [ "$RC" -eq "$2" ]; then ok "$1"; else bad "$1" "expected exit $2, got $RC: ${OUT:0:240}"; fi
}

expect_silent() {   # <name> <json>
    run "$2"
    if [ "$RC" -ne 0 ]; then bad "$1" "expected exit 0, got $RC: ${OUT:0:240}"
    elif [ -n "$OUT" ]; then bad "$1" "expected SILENCE, got: ${OUT:0:240}"
    else ok "$1"; fi
}

expect_says() {   # <name> <needle> <json>
    run "$3"
    if printf '%s' "$OUT" | grep -qF "$2"; then ok "$1"; else bad "$1" "output did not carry '$2': ${OUT:0:240}"; fi
}

printf '=== guard-no-home-network-phone.sh ===\n'

# --- (a) the two sentences the ruling names --------------------------------
expect_rc     "A1  route1's brief as an Agent spawn is REFUSED" 2 "$(payload Agent "" "$ROUTE1")"
expect_rc     "A2  route1's brief as a markdown Write is REFUSED" 2 "$(payload Write "$SB/docs/briefs/x.md" "$ROUTE1")"
expect_says   "A3  the refusal names the site 'the At-home path stays'" "At-home" "$(payload Agent "" "$ROUTE1")"
expect_says   "A4  the refusal names BOTH sites, including 'home plan'" "home plan" "$(payload Agent "" "$ROUTE1")"
expect_says   "A5  the refusal carries the ruling, not a pointer to it" "utterly useless within the home network" "$(payload Agent "" "$ROUTE1")"
expect_says   "A6  the refusal gives the citation line" "ceo-ruled-home-network:" "$(payload Agent "" "$ROUTE1")"
expect_rc     "A7  the same text through MultiEdit is REFUSED" 2 "$(payload MultiEdit "$SB/docs/briefs/x.md" "$ROUTE1")"

# The retention veto, isolated: "Do not remove" carries a removal word and is an
# instruction to KEEP. Without the veto this exempts itself.
expect_rc     "A8  'Do not remove the At-home option' alone is REFUSED" 2 \
              "$(payload Write "$SB/x.md" "The phone flow: do not remove the At-home option.")"

# --- (b) the code surface --------------------------------------------------
expect_rc     "B1  a phone.js edit adding 'At home only' is REFUSED" 2 "$(payload Edit "$SB/app/ui/phone.js" "$PHONEJS")"
expect_says   "B2  ... and it is read as code, not prose" "read as code" "$(payload Edit "$SB/app/ui/phone.js" "$PHONEJS")"
expect_rc     "B3  a quoted route token in code is REFUSED (a string literal is the copy)" 2 \
              "$(payload Edit "$SB/app/ui/phone.js" 'const route = "at-home";')"
expect_rc     "B4  a Rust write binding the home plan is REFUSED" 2 \
              "$(payload Write "$SB/src/phone/mod.rs" 'fn serving_plan() -> Plan { Plan::AtHome }')"
expect_silent "B5  a code comment saying the at-home route was removed PASSES" \
              "$(payload Edit "$SB/app/ui/phone.js" '// the At-home route was removed; phone pairing is tailnet-only now')"

# --- (c) the record of the ruling passes ON MERIT --------------------------
expect_silent "C1  §61's addendum as a Write to ceo-decisions.md PASSES" \
              "$(payload Write "$HQ/wiki/ceo-decisions.md" "$S61")"
expect_silent "C2  ... and as an Agent prompt quoting it PASSES" "$(payload Agent "" "$S61")"
# Proof it is MERIT and not the path: the same file path with the refused text.
expect_rc     "C3  ceo-decisions.md is NOT path-exempt — route1's text there is REFUSED" 2 \
              "$(payload Write "$HQ/wiki/ceo-decisions.md" "$ROUTE1")"

# --- (d) the removal brief -------------------------------------------------
expect_silent "D1  the removal brief as an Agent spawn PASSES" "$(payload Agent "" "$ONEPATH")"
expect_silent "D2  the removal brief as a markdown Write PASSES" "$(payload Write "$SB/docs/briefs/y.md" "$ONEPATH")"
# It quotes route1's refused sentence. Quoting a mistake is how it gets recorded.
expect_silent "D3  quoting the refused sentence in prose PASSES" \
              "$(payload Write "$SB/x.md" 'The phone brief said: "Do not remove the At-home option … §61 keeps both", and that ruling does not exist.')"
expect_silent "D4  a TRUNCATED curly-quoted provenance block PASSES" \
              "$(payload Agent "" "$PROVENANCE")"
# D5 and D6 are CONSTRUCTED, and say so. No document in the 269 measured
# isolates either stripper: every curly quotation the provenance apparatus
# emits is annotated on the next line with "nothing in scope sources it" or
# "this run is NOT in that file", which is a negation in the same block, so the
# block-scope rule carries those cases on its own. These two remove that help.
expect_silent "D5  CONSTRUCTED: a curly quotation with no negation near it PASSES" \
              "$(payload Agent "" "Phone pairing round two.

- “the At-home path stays”")"
# D6 is MULTI-LINE on purpose: a single-line *"..."* is already covered by the
# bare-quote stripper, so only a quotation that WRAPS isolates this one, and
# the record wraps its CEO quotations at ~95 columns.
expect_silent "D6  CONSTRUCTED: a WRAPPED *\"...\"* quotation, no negation near it, PASSES" \
              "$(payload Agent "" "Phone pairing round two.

He said *\"the At-home path
stays\"* here.")"

# --- (e) conjunct (a) keeps it out of everybody else's repository ----------
expect_silent "E1  a home network with no phone signal anywhere PASSES" \
              "$(payload Write "$SB/src/lib/client.js" "$UNRELATED")"
expect_rc     "E1b ... and the POSITIVE PROBE: the same text with a phone in it is REFUSED" 2 \
              "$(payload Write "$SB/src/lib/client.js" "The phone reaches it too.
$UNRELATED")"
expect_silent "E2  a phone brief with no home path PASSES" \
              "$(payload Agent "" 'Brief: the phone pairs over Tailscale from anywhere. Ship the PWA.')"
expect_silent "E3  'sixteen taps' alone, in a phone brief, PASSES (a weak signal needs a second)" \
              "$(payload Write "$SB/docs/briefs/z.md" "$SIXTEEN_ALONE")"
expect_rc     "E4  ... and TWO weak signals in one block are REFUSED" 2 \
              "$(payload Write "$SB/docs/briefs/z.md" "Pairing today: the phone installs the self-signed CA profile, sixteen taps.")"

# --- (f) the hatch is a citation -------------------------------------------
ACKLOG="$ENTITY/.claude/state/home-network-acks.log"
: >"$ACKLOG"
GOOD_ACK="$ROUTE1
ceo-ruled-home-network: §61 — \"the new working definition for a mobile app or PWA is this\""
expect_silent "F1  a resolving citation with his words PASSES" "$(payload Agent "" "$GOOD_ACK")"
if grep -q 'cite=§61' "$ACKLOG" 2>/dev/null; then ok "F2  ... and is LOGGED to home-network-acks.log"
else bad "F2  ... and is LOGGED to home-network-acks.log" "nothing in $ACKLOG"; fi
if grep -q 'section=verified' "$ACKLOG" 2>/dev/null; then ok "F3  ... recorded as verified against the record"
else bad "F3  ... recorded as verified against the record" "$(cat "$ACKLOG" 2>/dev/null | head -1)"; fi

expect_rc     "F4  a citation of a section that is NOT in the record is REFUSED" 2 \
              "$(payload Agent "" "$ROUTE1
ceo-ruled-home-network: §99 — \"a sentence he never said about the home network\"")"
expect_says   "F5  ... and the refusal names the section and the file" "§99 is NOT in" \
              "$(payload Agent "" "$ROUTE1
ceo-ruled-home-network: §99 — \"a sentence he never said about the home network\"")"
expect_rc     "F6  a BARE marker exempts nothing" 2 \
              "$(payload Agent "" "$ROUTE1
ceo-ruled-home-network: yes")"
expect_rc     "F7  a section with no quotation exempts nothing" 2 \
              "$(payload Agent "" "$ROUTE1
ceo-ruled-home-network: §61 covers this")"
expect_rc     "F8  a quotation too short to be a sentence exempts nothing" 2 \
              "$(payload Agent "" "$ROUTE1
ceo-ruled-home-network: §61 — \"keeps both\"")"
# A refused citation is never logged.
: >"$ACKLOG"
run "$(payload Agent "" "$ROUTE1
ceo-ruled-home-network: yes")"
if [ ! -s "$ACKLOG" ]; then ok "F9  a REFUSED citation is not logged"
else bad "F9  a REFUSED citation is not logged" "$(head -1 "$ACKLOG")"; fi

# --- (g) fail open ---------------------------------------------------------
printf 'not json at all' >"$SB/garbage.json"
set +e
OUT="$(env RICHOS_ENTITY_ROOT="$ENTITY" "$HOOK" <"$SB/garbage.json" 2>&1)"; RC=$?
set -e
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'NOT checked'; then ok "G1  an unparseable payload ALLOWS and says so"
else bad "G1  an unparseable payload ALLOWS and says so" "rc=$RC: ${OUT:0:200}"; fi

expect_silent "G2  a call for another tool is silent" "$(payload Bash "" "git log --oneline")"

# Not adopted: no orchestration.config anywhere above the payload's cwd, and NO
# explicit declaration — an explicit RICHOS_ENTITY_ROOT naming an unadopted
# directory is BROKEN by the resolver's own contract, which is a different
# state and a different (loud) exit.
NOADOPT="$SB/noadopt"
mkdir -p "$NOADOPT"
payload Agent "" "$ROUTE1" "$NOADOPT" >"$SB/noadopt.json"
set +e
# `cd` as well as the payload cwd: the resolver's last-resort candidate is
# $PWD, and this suite is normally run from inside the engine — which IS
# adopted, and would answer the question the case is asking.
OUT="$(cd "$NOADOPT" && env -u RICHOS_ENTITY_ROOT -u CLAUDE_PROJECT_DIR "$HOOK" <"$SB/noadopt.json" 2>&1)"; RC=$?
set -e
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "G3  an unadopted repository is silent"
else bad "G3  an unadopted repository is silent" "rc=$RC: ${OUT:0:200}"; fi

# And the DIFFERENT state it is often confused with: a root declared
# explicitly that is not adopted. The resolver calls that BROKEN rather than
# not-adopted — it will not substitute a root behind the operator's back — and
# this guard fails open LOUDLY there, which is not the same as silence.
set +e
OUT="$(env RICHOS_ENTITY_ROOT="$NOADOPT" "$HOOK" <"$SB/noadopt.json" 2>&1)"; RC=$?
set -e
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'GUARD IS OFF'; then ok "G3b an unresolvable declared root ALLOWS and says so"
else bad "G3b an unresolvable declared root ALLOWS and says so" "rc=$RC: ${OUT:0:200}"; fi

# The declared off switch.
printf 'PROTECTED_PATHS=""\nCEO_TODOS_REPOS="%s"\nHOME_NETWORK_PHONE_GUARD="off"\n' "$HQ" >"$ENTITY/orchestration.config"
expect_silent "G4  HOME_NETWORK_PHONE_GUARD=off stands down silently" "$(payload Agent "" "$ROUTE1")"
printf 'PROTECTED_PATHS=""\nCEO_TODOS_REPOS="%s"\n' "$HQ" >"$ENTITY/orchestration.config"
expect_rc     "G5  ... and removing the switch restores the refusal" 2 "$(payload Agent "" "$ROUTE1")"

# --- (h) the self-exemption ------------------------------------------------
expect_silent "H1  the guard's own source is exempt" \
              "$(payload Write "$SB/scripts/hooks/guard-no-home-network-phone.sh" "$ROUTE1")"
expect_silent "H2  its suite is exempt" \
              "$(payload Write "$SB/scripts/hooks/guard-no-home-network-phone.test.sh" "$ROUTE1")"
expect_silent "H3  its mutation harness is exempt" \
              "$(payload Write "$SB/scripts/hooks/home-network-phone.mutation.sh" "$ROUTE1")"
expect_rc     "H4  a file merely NAMED like one, elsewhere, is not exempt by directory" 2 \
              "$(payload Write "$SB/scripts/hooks/guard-no-home-network-phones.sh" "$ROUTE1")"

# --- (i) the one hard refusal ----------------------------------------------
BROKEN="$SB/broken"
mkdir -p "$BROKEN/scripts/hooks" "$BROKEN/scripts/lib"
cp "$HOOK" "$BROKEN/scripts/hooks/"
payload Agent "" "$ROUTE1" >"$SB/route1.json"
set +e
OUT="$(env RICHOS_ENTITY_ROOT="$ENTITY" bash "$BROKEN/scripts/hooks/guard-no-home-network-phone.sh" <"$SB/route1.json" 2>&1)"; RC=$?
set -e
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'BROKEN INSTALL'; then ok "I1  a missing resolve-roots.sh REFUSES with the shared banner"
else bad "I1  a missing resolve-roots.sh REFUSES with the shared banner" "rc=$RC: ${OUT:0:200}"; fi

# --- the mutation harness --------------------------------------------------
# A suite that cannot fail proves nothing. The harness breaks the guard in ways
# a real edit could and requires this suite to go red for each.
if [ -z "${RICHOS_MUTATION_INNER:-}" ] && [ -x "$SCRIPT_DIR/home-network-phone.mutation.sh" ]; then
    printf '\n--- mutation harness ---\n'
    if "$SCRIPT_DIR/home-network-phone.mutation.sh"; then
        PASS=$((PASS + 1)); printf '  PASS  M1  the suite FAILS on every planted defect\n'
    else
        FAIL=$((FAIL + 1)); printf '  FAIL  M1  the suite FAILS on every planted defect\n'
    fi
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
