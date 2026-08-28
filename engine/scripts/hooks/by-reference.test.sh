#!/usr/bin/env bash
#
# by-reference.test.sh — the negative controls for contract-integrity-probe.sh's
# BY-REFERENCE layer set (BR1..BR9).
#
# WHY THIS FILE EXISTS
# ====================
# The by-reference layers were written because an adopter running the engine as
# a plugin had NO automated wiring check at all, and a real regression reached
# an operator instead of a test. Replacing "no check" with "a check nobody has
# seen fail" would be the same mistake wearing a green tick: a validator that
# cannot fail is not a validator. So every layer here is exercised BOTH ways —
# once on a correct installation, and once on an installation broken in exactly
# the way that layer is supposed to notice.
#
# Each negative case asserts THREE things, not one:
#
#   1. the probe's verdict flipped (exit 2),
#   2. the SPECIFIC NAMED layer emitted ✗ — because "something failed" is not
#      evidence that the layer under test is the thing that caught it, and a
#      sloppy mutation can turn a different layer red while the intended one
#      sleeps through it,
#   3. no OTHER layer collapsed with it, where that is the point of the case.
#
# The sandbox is a complete miniature of the real topology — a real engine (no
# stubs; a stubbed engine can pass while the shipped one fails), an adopted
# entity repository that is NOT the engine, a marketplace manifest, and a fake
# HOME carrying the operator-scope plugin registration the host would read. The
# fake HOME is what lets BR6 be tested at all: BR6's whole subject is machine
# state outside any repository.
#
# Run directly:  scripts/hooks/by-reference.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ENGINE="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
FAIL_NAMES=()

ok()  { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); FAIL_NAMES+=("$1"); printf '  FAIL  %s — %s\n' "$1" "$2"; }

# The launching session's own environment must not leak in as a candidate root.
unset CLAUDE_PROJECT_DIR RICHOS_ENTITY_ROOT RICHOS_ENGINE_ROOT CLAUDE_PLUGIN_ROOT

# ---------------------------------------------------------------------------
# Sandbox
# ---------------------------------------------------------------------------
# <sb>/                      marketplace root (git repo)
#   .claude-plugin/marketplace.json
#   engine/                  ENGINE_ROOT — a real engine, by reference
#   home/.claude/...         the operator-scope registration BR6 reads
# <sb>/entity/               ENTITY_ROOT — a different, adopted repository
#
# entity/ lives INSIDE the marketplace repo purely for convenience; it carries
# its own orchestration.config, which is what makes it an adopted root, and the
# probe is always told about it explicitly via RICHOS_ENTITY_ROOT.
make_sandbox() {
    local sb
    sb="$(cd "$(mktemp -d -t byref.XXXXXX)" && pwd -P)"

    mkdir -p "$sb/engine" "$sb/entity/.claude/agents" "$sb/home/.claude/plugins" "$sb/.claude-plugin"

    cp -R "$SRC_ENGINE/scripts"        "$sb/engine/scripts"
    cp -R "$SRC_ENGINE/.claude"        "$sb/engine/.claude"
    cp -R "$SRC_ENGINE/.claude-plugin" "$sb/engine/.claude-plugin"
    cp -R "$SRC_ENGINE/hooks"          "$sb/engine/hooks"
    cp "$SRC_ENGINE/orchestration.config" "$sb/engine/orchestration.config"
    cp "$SRC_ENGINE/VERSION" "$sb/engine/VERSION" 2>/dev/null || printf '0.0.0-test\n' >"$sb/engine/VERSION"

    # The entity's config is deliberately DIFFERENT from the engine's, so a
    # layer that read the wrong one would be visible rather than plausible.
    cat >"$sb/entity/orchestration.config" <<'CFG'
PROTECTED_PATHS="src"
READONLY_ALLOWLIST="Explore Plan"
ALLOWED_MODELS="opus sonnet haiku"
READER_TEAMMATE="reed"
CREATOR_TEAMMATE="dean"
CFG
    printf -- '---\nname: mark\nmodel: opus\n---\nentity roster body\n' \
        >"$sb/entity/.claude/agents/mark.md"

    cat >"$sb/.claude-plugin/marketplace.json" <<'MKT'
{
  "name": "sandbox-local",
  "owner": { "name": "test" },
  "plugins": [
    { "name": "richos-engine", "source": "./engine" }
  ]
}
MKT

    # The operator-scope registration, exactly as the host writes it.
    cat >"$sb/home/.claude/settings.json" <<JSON
{
  "enabledPlugins": { "richos-engine@sandbox-local": true },
  "extraKnownMarketplaces": {
    "sandbox-local": { "source": { "source": "directory", "path": "$sb" } }
  }
}
JSON
    cat >"$sb/home/.claude/plugins/known_marketplaces.json" <<JSON
{
  "sandbox-local": {
    "source": { "source": "directory", "path": "$sb" },
    "installLocation": "$sb"
  }
}
JSON

    # Mint the engine's sidecars, so BR4's tamper check has a baseline to
    # compare against (and so its "did not run" warning is not the default).
    RICHOS_ENTITY_ROOT="$sb/engine" "$sb/engine/scripts/hooks/install.sh" >/dev/null 2>&1

    # BR7's subject is "does this reach the next clone?", so the sandbox has to
    # be a real repository with a real commit.
    git -C "$sb" init -q -b main >/dev/null 2>&1
    git -C "$sb" add -A >/dev/null 2>&1
    git -C "$sb" commit -q -m "sandbox" >/dev/null 2>&1

    printf '%s\n' "$sb"
}

# run_probe <sandbox> -> stdout+stderr in OUT, exit code in RC
OUT=""
RC=0
run_probe() {
    local sb="$1"
    set +e
    OUT="$(HOME="$sb/home" RICHOS_ENTITY_ROOT="$sb/entity" \
        "$sb/engine/scripts/hooks/contract-integrity-probe.sh" 2>&1)"
    RC=$?
    set -e
}

# Assertion helpers. `layer_failed BR2` is true when a ✗ line names that layer.
# The layer token is anchored on the whitespace that precedes it, so asking
# about layer "A" cannot be satisfied by an "A." buried in another layer's
# prose. A loose pattern here would quietly make these assertions unfalsifiable.
layer_failed() { printf '%s\n' "$OUT" | grep -q "✗.*[[:space:]]$1\." ; }
layer_passed() { printf '%s\n' "$OUT" | grep -q "✓.*[[:space:]]$1\." ; }
layer_warned() { printf '%s\n' "$OUT" | grep -q "⚠.*[[:space:]]$1\." ; }
out_has()      { printf '%s\n' "$OUT" | grep -qF "$1" ; }

# expect_only_layer_failed <case> <layer> [substring]
#
# The three-part assertion: verdict flipped, the NAMED layer is the one that
# caught it, and (when given) it caught it for the stated REASON rather than
# incidentally.
expect_only_layer_failed() {
    local name="$1" layer="$2" substr="${3:-}"
    if [ "$RC" -ne 2 ]; then
        bad "$name" "probe exit was $RC, expected 2"
        return
    fi
    if ! layer_failed "$layer"; then
        bad "$name" "$layer did not report ✗ (some other layer may have absorbed the mutation)"
        return
    fi
    if [ -n "$substr" ] && ! out_has "$substr"; then
        bad "$name" "$layer failed, but not for the stated reason (missing: $substr)"
        return
    fi
    ok "$name"
}

echo "=== by-reference.test.sh ==="
echo ""

# ---------------------------------------------------------------------------
# 0 — the baseline. Everything below is only meaningful if a correct
#     installation is genuinely green; a suite whose baseline is already red
#     proves its mutations changed nothing.
# ---------------------------------------------------------------------------
SB="$(make_sandbox)"
run_probe "$SB"
if [ "$RC" -eq 0 ]; then
    ok "0a.baseline-correct-install-is-green"
else
    bad "0a.baseline-correct-install-is-green" "exit $RC; output: $(printf '%s' "$OUT" | grep '✗' | head -3)"
fi
if layer_passed "BR1" && layer_passed "BR2" && layer_passed "BR3" && layer_passed "BR4" \
   && layer_passed "BR5" && layer_passed "BR6" && layer_passed "BR8" && layer_passed "BR9"; then
    ok "0b.baseline-every-BR-layer-actually-ran"
else
    bad "0b.baseline-every-BR-layer-actually-ran" "a layer neither passed nor was reached: $(printf '%s' "$OUT" | grep -c '✓') ✓ lines"
fi
# The mode branch itself: a by-reference install must NOT be audited with the
# seated layers, and vice versa. Both directions, because picking the wrong set
# is precisely the defect that made this probe refuse a verdict for a month.
if out_has "ENGINE LOADED BY REFERENCE" && ! layer_passed "A" && ! layer_failed "A"; then
    ok "0c.by-reference-install-does-not-run-the-seated-layers"
else
    bad "0c.by-reference-install-does-not-run-the-seated-layers" "seated Layer A ran under a by-reference engine"
fi
set +e
SEATED_OUT="$(HOME="$SB/home" RICHOS_ENTITY_ROOT="$SB/engine" \
    "$SB/engine/scripts/hooks/contract-integrity-probe.sh" 2>&1)"
SEATED_RC=$?
set -e
if printf '%s\n' "$SEATED_OUT" | grep -q "✓.*A\." && ! printf '%s\n' "$SEATED_OUT" | grep -q "BR1\."; then
    ok "0d.seated-install-runs-the-seated-layers-not-the-BR-set"
else
    bad "0d.seated-install-runs-the-seated-layers-not-the-BR-set" "exit $SEATED_RC"
fi
# The regression this suite was written alongside: R4 asserts engine-status.sh
# is registered in the ENTITY's settings.local.json, which is only true when
# SEATED. By reference the plugin registers it and the entity's settings file
# correctly never mentions it — asserting the seated location there produced a
# hard failure whose only cause was the probe looking in the wrong file.
mkdir -p "$SB/entity/.claude"
printf '{\n  "hooks": {}\n}\n' >"$SB/entity/.claude/settings.local.json"
run_probe "$SB"
if ! out_has "engine-status.sh is NOT registered in"; then
    ok "0e.R4-does-not-demand-the-seated-registration-from-a-by-reference-entity"
else
    bad "0e.R4-does-not-demand-the-seated-registration-from-a-by-reference-entity" "R4 fired on the entity's settings file"
fi
rm -rf "$SB"

# ---------------------------------------------------------------------------
# BR1 — the plugin manifest
# ---------------------------------------------------------------------------
SB="$(make_sandbox)"
rm -f "$SB/engine/.claude-plugin/plugin.json"
run_probe "$SB"
expect_only_layer_failed "1a.BR1-missing-plugin-manifest" "BR1" "plugin manifest MISSING"
rm -rf "$SB"

SB="$(make_sandbox)"
printf '{ "displayName": "no name here" }\n' >"$SB/engine/.claude-plugin/plugin.json"
run_probe "$SB"
expect_only_layer_failed "1b.BR1-manifest-without-a-name" "BR1" 'has no "name"'
rm -rf "$SB"

# ---------------------------------------------------------------------------
# BR2 — the plugin hook table
# ---------------------------------------------------------------------------
SB="$(make_sandbox)"
rm -f "$SB/engine/hooks/hooks.json"
run_probe "$SB"
expect_only_layer_failed "2a.BR2-missing-hook-table" "BR2" "plugin hook table MISSING"
rm -rf "$SB"

# A guard silently dropped from the table. Every byte of it is still on disk and
# still correct — and it never runs. This is the shape of the regression.
SB="$(make_sandbox)"
python3 - "$SB/engine/hooks/hooks.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for entry in d["hooks"]["PreToolUse"]:
    if entry.get("matcher") == "SendMessage":
        entry["hooks"] = []
json.dump(d, open(p, "w"), indent=2)
PY
run_probe "$SB"
expect_only_layer_failed "2b.BR2-guard-not-registered" "BR2" "guard-resume-isolation.sh(NOT registered)"
rm -rf "$SB"

# The additive-merge double-fire, arriving through the plugin door.
SB="$(make_sandbox)"
python3 - "$SB/engine/hooks/hooks.json" <<'PY'
import copy, json, sys
p = sys.argv[1]
d = json.load(open(p))
for entry in d["hooks"]["PreToolUse"]:
    if entry.get("matcher") == "Bash":
        entry["hooks"].append(copy.deepcopy(entry["hooks"][0]))
json.dump(d, open(p, "w"), indent=2)
PY
run_probe "$SB"
expect_only_layer_failed "2c.BR2-guard-registered-twice" "BR2" "guard-bash-main-writes.sh(registered 2x"
rm -rf "$SB"

# Chain order. The isolation guard must refuse a bad spawn before the later
# hooks start reasoning about a spawn that should never have been considered.
SB="$(make_sandbox)"
python3 - "$SB/engine/hooks/hooks.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for entry in d["hooks"]["PreToolUse"]:
    if entry.get("matcher") == "Agent":
        entry["hooks"].reverse()
json.dump(d, open(p, "w"), indent=2)
PY
run_probe "$SB"
expect_only_layer_failed "2d.BR2-agent-chain-out-of-order" "BR2" "chain ORDER wrong"
rm -rf "$SB"

# Right guard, wrong event: registered, present, hash-matched — and wired to an
# event it will never see. Nothing else in the probe would notice.
SB="$(make_sandbox)"
python3 - "$SB/engine/hooks/hooks.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
moved = None
for entry in d["hooks"]["PostToolUse"]:
    if entry.get("matcher") == "Agent":
        moved = entry["hooks"].pop()
d["hooks"].setdefault("Stop", []).append({"hooks": [moved]})
json.dump(d, open(p, "w"), indent=2)
PY
run_probe "$SB"
expect_only_layer_failed "2e.BR2-guard-on-the-wrong-event" "BR2" "detect-nonnative-worktree.sh(registered, but not on PostToolUse)"
rm -rf "$SB"

# ---------------------------------------------------------------------------
# BR3 — confinement to ${CLAUDE_PLUGIN_ROOT}
# ---------------------------------------------------------------------------
SB="$(make_sandbox)"
python3 - "$SB/engine/hooks/hooks.json" "$SB" <<'PY'
import json, sys
p, sb = sys.argv[1], sys.argv[2]
d = json.load(open(p))
for entry in d["hooks"]["PreToolUse"]:
    if entry.get("matcher") == "Bash":
        entry["hooks"][0]["command"] = f"bash {sb}/engine/scripts/hooks/guard-bash-main-writes.sh"
json.dump(d, open(p, "w"), indent=2)
PY
run_probe "$SB"
expect_only_layer_failed "3a.BR3-absolute-path-instead-of-plugin-root" "BR3" "no \${CLAUDE_PLUGIN_ROOT}"
rm -rf "$SB"

# The ENTITY root standing in for an ENGINE asset — the exact conflation the
# whole two-root contract exists to prevent, expressed in the wiring.
SB="$(make_sandbox)"
python3 - "$SB/engine/hooks/hooks.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for entry in d["hooks"]["PreToolUse"]:
    if entry.get("matcher") == "SendMessage":
        entry["hooks"][0]["command"] = "bash $CLAUDE_PROJECT_DIR/scripts/hooks/guard-resume-isolation.sh"
json.dump(d, open(p, "w"), indent=2)
PY
run_probe "$SB"
expect_only_layer_failed "3b.BR3-CLAUDE_PROJECT_DIR-for-an-engine-asset" "BR3" "uses \$CLAUDE_PROJECT_DIR"
rm -rf "$SB"

SB="$(make_sandbox)"
python3 - "$SB/engine/hooks/hooks.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for entry in d["hooks"]["PreToolUse"]:
    if entry.get("matcher") == "Bash":
        entry["hooks"][0]["command"] = "bash ${CLAUDE_PLUGIN_ROOT}/../scripts/hooks/guard-bash-main-writes.sh"
json.dump(d, open(p, "w"), indent=2)
PY
run_probe "$SB"
expect_only_layer_failed "3c.BR3-escapes-the-plugin-root" "BR3" "escapes the plugin root"
rm -rf "$SB"

# ---------------------------------------------------------------------------
# BR4 — the scripts behind the registrations
# ---------------------------------------------------------------------------
SB="$(make_sandbox)"
rm -f "$SB/engine/scripts/hooks/scan-secrets.sh"
run_probe "$SB"
expect_only_layer_failed "4a.BR4-registered-script-not-on-disk" "BR4" "NOT ON DISK"
rm -rf "$SB"

SB="$(make_sandbox)"
chmod -x "$SB/engine/scripts/hooks/reader-teammate-hint.sh"
run_probe "$SB"
expect_only_layer_failed "4b.BR4-registered-script-not-executable" "BR4" "not executable"
rm -rf "$SB"

# Tampered AFTER the sidecar was minted — a guard gutted in place is invisible
# to every check except a hash.
SB="$(make_sandbox)"
printf '\n# tampered\n' >>"$SB/engine/scripts/hooks/guard-definition-drift.sh"
run_probe "$SB"
expect_only_layer_failed "4c.BR4-script-modified-since-install" "BR4" "MODIFIED since install"
rm -rf "$SB"

# A missing sidecar must NEVER be a green tick. It is not a failure either —
# a by-reference engine root is read-only to the repository it governs, so an
# adopter cannot mint one. What it must be is NAMED.
SB="$(make_sandbox)"
rm -f "$SB/engine/scripts/hooks/scan-secrets.sh.sha256"
run_probe "$SB"
if layer_warned "BR4" && out_has "TAMPER CHECK DID NOT RUN" && out_has "scan-secrets.sh"; then
    ok "4d.BR4-absent-sidecar-is-named-not-waved-through"
else
    bad "4d.BR4-absent-sidecar-is-named-not-waved-through" "no warning naming the unverified script"
fi
if printf '%s\n' "$OUT" | grep -q "✓.*BR4\. all 14 registered guard scripts present, executable and hash-matched"; then
    bad "4e.BR4-absent-sidecar-does-not-claim-hash-matched" "claimed hash-matched with a sidecar missing"
else
    ok "4e.BR4-absent-sidecar-does-not-claim-hash-matched"
fi
rm -rf "$SB"

# ---------------------------------------------------------------------------
# BR5 — the declared meta-roles
# ---------------------------------------------------------------------------
SB="$(make_sandbox)"
python3 - "$SB/engine/.claude-plugin/plugin.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["agents"] = ["./.claude/agents/does-not-exist.md"]
json.dump(d, open(p, "w"), indent=2)
PY
run_probe "$SB"
expect_only_layer_failed "5a.BR5-declared-role-file-missing" "BR5" "NOT FOUND"
rm -rf "$SB"

SB="$(make_sandbox)"
python3 - "$SB/engine/.claude-plugin/plugin.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["agents"] = ["./../../etc/hosts.md"]
json.dump(d, open(p, "w"), indent=2)
PY
run_probe "$SB"
expect_only_layer_failed "5b.BR5-declared-role-escapes-the-plugin-root" "BR5" "ESCAPES the plugin root"
rm -rf "$SB"

# The phantom-role trap, measured on this host 2026-08-28: the agent loader
# RECURSES into subdirectories of a declared agent directory and registers what
# it finds as <plugin>:<subdir>:<name>. engine/.claude/agents/ carries a
# templates/ subdirectory of non-live skeletons, so declaring that directory
# instead of the four files would ship seventeen roles nobody meant to ship.
SB="$(make_sandbox)"
python3 - "$SB/engine/.claude-plugin/plugin.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["agents"] = ["./.claude/agents"]
json.dump(d, open(p, "w"), indent=2)
PY
run_probe "$SB"
expect_only_layer_failed "5c.BR5-declared-directory-with-subdirs-ships-phantom-roles" "BR5" "phantom"
rm -rf "$SB"

SB="$(make_sandbox)"
printf 'no frontmatter at all\n' >"$SB/engine/.claude/agents/clark.md"
run_probe "$SB"
expect_only_layer_failed "5d.BR5-declared-role-without-frontmatter" "BR5" "no YAML frontmatter"
rm -rf "$SB"

# ---------------------------------------------------------------------------
# BR6 — will this operator actually load this engine?
# ---------------------------------------------------------------------------
# THE CASE THAT MATTERS MOST. Everything above can be perfect and the host can
# still load nothing, because the registration lives in ~/.claude and not in any
# repository. This is the shape of the reported regression: guards correct,
# guards present, guards never loaded — with no error anywhere.
SB="$(make_sandbox)"
printf '{\n  "enabledPlugins": {}\n}\n' >"$SB/home/.claude/settings.json"
printf '{}\n' >"$SB/home/.claude/plugins/known_marketplaces.json"
run_probe "$SB"
expect_only_layer_failed "6a.BR6-plugin-not-enabled-anywhere" "BR6" "UNGUARDED"
rm -rf "$SB"

SB="$(make_sandbox)"
python3 - "$SB/home/.claude/settings.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["enabledPlugins"] = {"richos-engine@sandbox-local": False}
json.dump(d, open(p, "w"), indent=2)
PY
run_probe "$SB"
expect_only_layer_failed "6b.BR6-plugin-registered-but-disabled" "BR6" "UNGUARDED"
rm -rf "$SB"

# Enabled, and pointing at a different copy of the engine. "A plugin is enabled"
# is not the question; "is THIS engine the one that loads" is.
SB="$(make_sandbox)"
mkdir -p "$SB/other-engine"
python3 - "$SB/.claude-plugin/marketplace.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["plugins"][0]["source"] = "./other-engine"
json.dump(d, open(p, "w"), indent=2)
PY
run_probe "$SB"
expect_only_layer_failed "6c.BR6-enabled-plugin-resolves-elsewhere" "BR6" "does NOT resolve to this engine"
rm -rf "$SB"

# ---------------------------------------------------------------------------
# BR7 — does the registration reach the next clone?
# ---------------------------------------------------------------------------
SB="$(make_sandbox)"
git -C "$SB" rm -q --cached ".claude-plugin/marketplace.json" >/dev/null 2>&1
printf '.claude-plugin/marketplace.json\n' >>"$SB/.gitignore"
git -C "$SB" add .gitignore >/dev/null 2>&1
git -C "$SB" commit -q -m "untrack" >/dev/null 2>&1
run_probe "$SB"
expect_only_layer_failed "7a.BR7-marketplace-manifest-untracked-and-ignored" "BR7" "reaches nobody else"
rm -rf "$SB"

SB="$(make_sandbox)"
rm -f "$SB/.claude-plugin/marketplace.json"
run_probe "$SB"
expect_only_layer_failed "7b.BR7-no-marketplace-manifest-at-all" "BR7" "no marketplace to add"
rm -rf "$SB"

# ---------------------------------------------------------------------------
# BR8 — the announcement, on both channels
# ---------------------------------------------------------------------------
# The operator channel specifically. On 2026-08-28 the announcement was firing
# perfectly into additionalContext, where only the model could see it, and an
# operator reading stdout and stderr concluded the engine was not loaded.
SB="$(make_sandbox)"
cat >"$SB/engine/scripts/hooks/engine-status.sh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"ENFORCEMENT ACTIVE '"$RICHOS_ENTITY_ROOT"'"}}'
exit 0
EOS
chmod +x "$SB/engine/scripts/hooks/engine-status.sh"
run_probe "$SB"
if layer_failed "BR8" && out_has "no systemMessage"; then
    ok "8a.BR8-announcement-that-reaches-only-the-model-is-a-failure"
else
    bad "8a.BR8-announcement-that-reaches-only-the-model-is-a-failure" "BR8 accepted a model-only announcement"
fi
rm -rf "$SB"

# The negative arm's own negative control. A status hook that hardcodes ACTIVE
# satisfies every positive assertion while deciding nothing — mutation M9's
# failure, which is why BR8 also drives an UNADOPTED directory.
SB="$(make_sandbox)"
cat >"$SB/engine/scripts/hooks/engine-status.sh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' '{"systemMessage":"ENFORCEMENT ACTIVE '"$RICHOS_ENTITY_ROOT"'","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"ENFORCEMENT ACTIVE '"$RICHOS_ENTITY_ROOT"'"}}'
exit 0
EOS
chmod +x "$SB/engine/scripts/hooks/engine-status.sh"
run_probe "$SB"
if layer_failed "BR8" && out_has "did not get STOOD DOWN"; then
    ok "8b.BR8-status-hook-that-always-says-ACTIVE-is-caught"
else
    bad "8b.BR8-status-hook-that-always-says-ACTIVE-is-caught" "BR8 accepted a hook that decides nothing"
fi
rm -rf "$SB"

# ---------------------------------------------------------------------------
# BR9 — a guard that still has teeth
# ---------------------------------------------------------------------------
SB="$(make_sandbox)"
cat >"$SB/engine/scripts/hooks/guard-worktree-isolation.sh" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
chmod +x "$SB/engine/scripts/hooks/guard-worktree-isolation.sh"
run_probe "$SB"
if layer_failed "BR9" && out_has "was ALLOWED"; then
    ok "9a.BR9-guard-gutted-into-a-no-op-is-caught"
else
    bad "9a.BR9-guard-gutted-into-a-no-op-is-caught" "BR9 accepted a guard that blocks nothing"
fi
rm -rf "$SB"

# The other direction, and the reason BR9 has a positive arm at all: a guard
# that refuses everything satisfies "does it block?" while being useless, and
# would take a working session down with it.
SB="$(make_sandbox)"
cat >"$SB/engine/scripts/hooks/guard-worktree-isolation.sh" <<'EOS'
#!/usr/bin/env bash
exit 2
EOS
chmod +x "$SB/engine/scripts/hooks/guard-worktree-isolation.sh"
run_probe "$SB"
if layer_failed "BR9" && out_has "was REFUSED"; then
    ok "9b.BR9-guard-that-blocks-everything-is-caught"
else
    bad "9b.BR9-guard-that-blocks-everything-is-caught" "BR9 accepted a guard that refuses every spawn"
fi
rm -rf "$SB"

# The roster read. A guard that compares two strings it was handed would pass
# 9a and 9b; only the model-truthfulness arm requires it to have actually opened
# the ENTITY's own agent definition.
SB="$(make_sandbox)"
cat >"$SB/engine/scripts/hooks/guard-worktree-isolation.sh" <<'EOS'
#!/usr/bin/env bash
PAYLOAD="$(cat)"
case "$PAYLOAD" in
    *'"isolation":"worktree"'*) exit 0 ;;
    *) exit 2 ;;
esac
EOS
chmod +x "$SB/engine/scripts/hooks/guard-worktree-isolation.sh"
run_probe "$SB"
if layer_failed "BR9" && out_has "did not read the entity's roster"; then
    ok "9c.BR9-guard-that-never-reads-the-roster-is-caught"
else
    bad "9c.BR9-guard-that-never-reads-the-roster-is-caught" "BR9 accepted a guard that only pattern-matches its payload"
fi
rm -rf "$SB"

# ---------------------------------------------------------------------------
echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "=== by-reference.test.sh: all $PASS passed ==="
    exit 0
fi
echo "=== by-reference.test.sh: $PASS passed, $FAIL FAILED ==="
for n in "${FAIL_NAMES[@]}"; do echo "    - $n"; done
exit 1
