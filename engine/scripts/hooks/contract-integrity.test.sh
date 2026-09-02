#!/usr/bin/env bash
#
# contract-integrity.test.sh — self-test harness for install.sh +
# contract-integrity-probe.sh.
#
# CANONICAL SOURCE (single-registration root-fix): hooks are registered in
# exactly ONE file, `.claude/settings.local.json` (committed). install.sh no
# longer writes hook stanzas into `.claude/settings.json`; instead it MIGRATES
# any stale hook-duplicating settings.json out of the way (removing a pure
# duplicate, or stripping hooks from a machine-specific one). The probe reads
# the wiring from settings.local.json, and its new Layer M asserts the wiring is
# not duplicated across both files (the additive-merge double-fire). Cases below
# target settings.local.json as the canonical source.
#
# The hard-gated hooks are the main-checkout write guard
# (guard-main-checkout-writes.sh), the secrets scanner (scan-secrets.sh —
# wired as a SECOND hook in the same Write|Edit|MultiEdit|NotebookEdit
# matcher entry), and the four-hook PreToolUse[Agent] chain
# (guard-worktree-isolation.sh FIRST, then guard-definition-drift.sh, then
# reader-teammate-hint.sh, then verify-agent-prompt.sh). Adversarial coverage:
# shim attacks (path confinement) and manifest tampering (sidecar hash closure).
#
# The definition-drift guard PAIR is part of the managed set —
# guard-definition-drift.sh at Agent-chain position 2, snapshot-agent-
# definitions.sh under SessionStart — so both sandbox fixtures wire them and
# probe Layer P has something to verify. The pair's own BEHAVIORAL suite lives
# in scripts/hooks/guard-definition-drift.test.sh; this harness covers wiring.
#
# The WORKTREE-REAPER CHAIN is also part of the managed set —
# session-start-reap-worktrees.sh under SessionStart plus the
# scripts/reap-stale-worktrees.sh it invokes (the one managed script NOT under
# scripts/hooks/, because it is the half that actually deletes worktrees). Both
# fixtures carry them with minted sidecars so probe Layer Q has something to
# assert. Wrapper behavior lives in
# scripts/hooks/session-start-reap-worktrees.test.sh; this harness covers wiring
# plus the tamper/gut/over-reach axes Layer Q is responsible for catching.
#
# The harness builds an isolated sandbox per case (a committed-fresh-clone
# skeleton: canonical settings.local.json + all hook scripts + their .sha256
# sidecars + an orchestration.config, and NO settings.json) so the real repo is
# never mutated.

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL="$SCRIPT_DIR/install.sh"
PROBE="$SCRIPT_DIR/contract-integrity-probe.sh"
REAL_REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# SANDBOX THE OPERATOR CONFIG DIR, for the whole suite, before anything runs.
# install.sh mints the entity-facing engine pointer into
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}, and this suite runs it against ~20
# throwaway sandboxes. Without this line every one of those repoints the REAL
# operator's pointer at a temp directory that is deleted seconds later, leaving
# a dangling symlink on the machine. Observed, once, before the variable
# existed — which is also how BR6b's dangling-pointer branch got written.
CLAUDE_CONFIG_DIR="$(mktemp -d -t contract-integrity-cfg.XXXXXX)"
export CLAUDE_CONFIG_DIR
trap 'rm -rf "$CLAUDE_CONFIG_DIR"' EXIT

if [ ! -x "$INSTALL" ] || [ ! -x "$PROBE" ]; then
    echo "FATAL: install.sh or contract-integrity-probe.sh missing/non-exec" >&2
    exit 1
fi

PASS=0
FAIL=0
FAIL_NAMES=()

# All canonical hook scripts the probe/install manage — DERIVED FROM
# hooks/hooks.json, NEVER TYPED.
#
# This was a hand-typed list of 22 names, in the suite whose entire subject is
# whether the engine's guards are actually wired. It was wrong in two ways at
# once and both were invisible:
#
#   * it was MISSING FOUR REGISTERED HOOKS (the worker-*-handoff.sh family).
#     Every sandbox this suite built was therefore an engine that cannot exist,
#     and the four were never copied, never hashed and never checked here.
#   * adding a 23rd guard made every sandbox miss it, so the probe's Layer R
#     reported it ABSENT and fourteen cases went red at once — with an error
#     message about the new guard rather than about this list. That is the
#     failure mode of a typed inventory exactly: the symptom points away from
#     the cause.
#
# scripts/lib/registered-hooks.sh exists because the guard COUNT drifted twice
# in two days for this reason, and its own header says a list a human must
# remember to update is not a mitigation for drift but a source of it. The
# suite that checks that contract was still carrying one. It is derived now,
# from the same file the host actually loads, through the same parser
# install.sh and engine-status.sh use.
#
# NO SILENT DEGRADATION: deriving nothing is fatal here, not an empty sandbox
# that passes every case by having nothing in it to check.
_RH_LIB="$SCRIPT_DIR/../lib/registered-hooks.sh"
if [ ! -f "$_RH_LIB" ]; then
    echo "FATAL: scripts/lib/registered-hooks.sh missing — the hook inventory cannot be derived, and this suite will not fall back to a typed list" >&2
    exit 1
fi
# shellcheck source=../lib/registered-hooks.sh
. "$_RH_LIB"
ALL_HOOKS=()
while IFS= read -r _h; do
    [ -n "$_h" ] || continue
    ALL_HOOKS+=("$_h")
done <<REGISTERED_EOF
$(registered_hook_scripts "$SCRIPT_DIR/../../hooks/hooks.json" || true)
REGISTERED_EOF
if [ "${#ALL_HOOKS[@]}" -eq 0 ]; then
    echo "FATAL: derived ZERO hooks from hooks/hooks.json — refusing to build sandboxes with nothing in them and report them green" >&2
    exit 1
fi

# The completeness check for the lists below. It is FATAL if absent for the same
# reason the hook inventory is: this suite's cases are only worth their exit
# codes if the sandbox they run in can assemble the engine, and skipping the
# question is how it stopped being asked in the first place.
_SC_LIB="$SCRIPT_DIR/../lib/sandbox-completeness.sh"
if [ ! -f "$_SC_LIB" ]; then
    echo "FATAL: scripts/lib/sandbox-completeness.sh missing — the sandbox file lists below cannot be checked against the engine they claim to model, and this suite will not report green without asking" >&2
    exit 1
fi
# shellcheck source=../lib/sandbox-completeness.sh
. "$_SC_LIB"

# Managed scripts living OUTSIDE scripts/hooks/, relative to the repo root. The
# reaper is hook-reachable (the SessionStart wrapper runs it with --execute) and
# install.sh mints a sidecar for it, so every sandbox must carry both.
ALL_ROOT_SCRIPTS=(
    scripts/reap-stale-worktrees.sh
    # The root-resolution contract is a managed, sidecar-hashed file for the
    # same reason the reaper is: it is not a hook, and it decides something no
    # hook can second-guess — which repository every guard is protecting.
    scripts/lib/resolve-roots.sh
    # The sanctioned removal helper. guard-worktree-removal.sh blocks every raw
    # worktree removal and names this as the only way through, so Layer S
    # verifies both halves and every sandbox must carry both.
    scripts/remove-agent-worktree.sh
    # The publication-boundary predicate. Two registered guards refuse to start
    # without it, so a sandbox missing it would model an engine that cannot run.
    scripts/lib/publication-boundary.sh
    scripts/lib/publication-boundary.py
    # The CEO-TODOs predicate. guard-ceo-todos-commits.sh refuses to start
    # without ceo-todos.sh, so a sandbox missing it would model an engine that
    # cannot run — the same reason the publication pair is on this list.
    scripts/lib/ceo-todos.sh
    scripts/lib/ceo-todos.py
    # The row-currency predicate, for the same reason again:
    # guard-row-currency-commits.sh refuses to start without row-currency.sh.
    scripts/lib/row-currency.sh
    scripts/lib/row-currency.py
    # The Stop-hook notice channel. It is on this list for a DIFFERENT reason
    # from the predicates above, and the difference is worth stating. Those
    # guards REFUSE TO START without their predicate, so a sandbox missing one
    # models an engine that cannot run. The Stop hooks do not refuse — absent
    # this file they fall back to announcing every turn, undeduplicated. So a
    # sandbox without it would not look broken; it would look FINE while
    # modelling a different engine from the one that ships. That is the harder
    # failure to notice, which is why it is carried too.
    scripts/lib/stop-hook-notice.sh
    # The CEO-ask predicate. On this list for the FIRST reason, not the
    # stop-hook-notice one: guard-ceo-ask-first.sh fails OPEN without it, so a
    # sandbox missing it would model an engine whose newest blocking guard is
    # silently off — and it would look fine doing it.
    scripts/lib/ceo-asks.sh
    scripts/lib/ceo-asks.py
    # The CEO-RULED predicate and its operator CLI. On this list for the FIRST
    # reason, and for a second one the SC1 check cannot see. FIRST:
    # guard-ceo-ruled-ask.sh fails OPEN without ceo-ruled.sh and announces it,
    # so a sandbox missing it models an engine whose newest blocking guard is
    # silently off. SECOND, the soft half: ceo-ruled.py loads its tokenizer out
    # of ceo-asks.py, so a sandbox carrying one and not the other assembles an
    # engine that STARTS FINE and reads questions differently from the one that
    # ships. ceo-ruled-exempt.sh is here because the refusal names it as the
    # only way through — a sandbox with a gate and no escape hatch models a
    # wall, which is the thing this gate was designed not to be.
    scripts/lib/ceo-ruled.sh
    scripts/lib/ceo-ruled.py
    scripts/ceo-ruled-exempt.sh
    # The agent-liveness resolver, both halves plus its operator CLI. On this
    # list for the FIRST reason and the hardest version of it:
    # remove-agent-worktree.sh refuses EVERY removal without it, and probe Layer
    # AL fails outright, so a sandbox missing it models an engine whose worktree
    # removal is permanently jammed and whose Stop-time claim check is off. It
    # is also the file three separate callers take their entire answer from, so
    # a sandbox that carries the callers and not the resolver is modeling an
    # engine that cannot be assembled.
    #
    # FOURTH CALLER, added 2026-09-01, and it is on the SOFT side of the line
    # SC1 can see — stated here because that is the whole point of this list.
    # scripts/reap-stale-worktrees.sh asks this resolver whether a hand-rolled
    # worktree's OWNER is still alive. Without it the reaper does not refuse to
    # start: it declares the blindness and treats EVERY hand-rolled worktree as
    # undecidable, which is safe and is also a reaper that can never reap the
    # class it was rebuilt to handle. A sandbox missing it would model that
    # engine while looking entirely healthy.
    scripts/lib/agent-liveness.py
    scripts/lib/agent-liveness.sh
    scripts/agent-liveness.sh
    # THE OWNERSHIP LEDGER and the cross-repository worktree helper (2026-09-02).
    # On this list for BOTH reasons at once. HARD: guard-worktree-isolation.sh
    # BLOCKS a `cwd` spawn when scripts/lib/worktree-ledger.py is missing
    # (fail-closed: an unverifiable registration is not one), so a sandbox
    # without it models an engine that refuses every cross-repository spawn.
    # SOFT, and the harder half: the reaper does not refuse without it — it
    # declares the blindness and treats EVERY hand-rolled worktree as
    # UNRESOLVED, which is the exact backlog this file was written to end;
    # detect-nonnative-worktree.sh and the three lifecycle hooks record
    # nothing without it and say so nowhere a sandbox reads. A sandbox missing
    # this file would model the engine of 2026-09-01 while looking perfectly
    # healthy. The helper is carried because the guard's refusal names it as
    # the only way through — a gate with no escape route models a wall.
    scripts/lib/worktree-ledger.py
    scripts/create-teammate-worktree.sh
    # The jurisdiction predicate — and it was MISSING from this list, silently,
    # for as long as the list has existed. scan-secrets.sh and guard-dialect.sh
    # both REFUSE TO START without it, by exiting 2, and Layer K's canary
    # asserts the scanner exits 2 on a planted secret. Same number, opposite
    # meanings: the layer was green here over a scanner that never ran. Layer T
    # now carries a clean-content canary a dead hook cannot satisfy, which is
    # what turned this omission from invisible into a failing suite.
    scripts/lib/seat-jurisdiction.sh
    # The git-jurisdiction resolver — WHICH REPOSITORY a `git commit`/`git push`
    # on the Bash tool is actually talking to. On this list for the FIRST
    # reason: all five commit/push guards REFUSE TO START without it, by exiting
    # 2, exactly as the predicates above do. It is one file rather than five
    # copies BECAUSE it was five copies, and four of them missed
    # `cd <repo> && git commit` — the form a worktree-isolated agent types by
    # default. SC1 below is what stops this list falling behind it.
    scripts/lib/git-jurisdiction.sh
    # The global-state witness, and it is on this list for the READING reason
    # rather than the running one — stated plainly, because SC1 below cannot see
    # it. No registered hook touches it: it is what the suites that run
    # install.sh use to prove they gave back the operator's engine pointer. A
    # sandbox without it assembles an engine whose test surface cannot answer
    # "did this run leave the pointer moved?", which is the question a red-run
    # fixture answered wrongly on 2026-09-01 while reporting success.
    scripts/lib/global-state-witness.sh
    # The dialect vocabulary. guard-dialect.sh decides nothing without it and
    # Layer T fails loudly when it is absent — first reason on this list, same
    # as the predicates above.
    scripts/lib/dialect-en-US.dict
    # The in-flight notice predicate, both halves. guard-inflight-notify.sh
    # REFUSES TO START without inflight.sh — first reason on this list again —
    # and inflight.sh itself decides nothing without inflight.py.
    #
    # This one was NOT found by reading the diff of what landed. It was found by
    # the completeness case below, which starts every registered hook in a
    # sandbox and reports the ones that cannot. That is the difference between
    # fixing the instance and closing the class, and it is why the case exists.
    scripts/lib/inflight.sh
    scripts/lib/inflight.py
    # The teammate-identity module, and it is here for the STOP-HOOK-NOTICE
    # REASON above rather than the refuse-to-start one — which is worth being
    # precise about, because it marks the edge of what SC1 below can see.
    #
    # inflight.sh and inflight.py do NOT refuse without it. They degrade: the
    # teams directory resolves to nothing, every name resolves to empty, and
    # inflight.py's own wrapper says "teammate-identity.py — MISSING" into a
    # structure nobody reads in a sandbox. So a sandbox without it starts every
    # hook cleanly, passes SC1, and models an engine whose in-flight sweep can
    # no longer name a single teammate.
    #
    # SC1 answers "can every hook START". It does not answer "does every hook
    # DECIDE the same way it would in a real engine", and it cannot: a
    # dependency that fails soft has, by construction, no announcement to read.
    # That half stays a human judgment, made at this list, which is why each
    # entry states its own reason.
    scripts/lib/teammate-identity.py
    # The interactive-prompt shape table. FIRST reason on this list, in its
    # strongest form: guard-interactive-prompt.sh REFUSES TO START without it,
    # by exiting 2 and naming it — and Layer IP's canary asserts that guard
    # exits 2 on a prompting command. Same number, opposite meanings, which is
    # exactly the shape that left Layer K green over a dead scanner. A sandbox
    # missing this file would model an engine whose newest blocking guard is
    # off, and Layer IP would report it as on.
    scripts/lib/interactive-prompt.py
    # THE STOP-HOOK ANALYZERS. Five registered Stop hooks decide NOTHING
    # themselves: the .sh resolves the two roots, reads config, and hands the
    # whole verdict to a sibling .py. None of them was on this list, and the
    # reason that went unnoticed for as long as the list has existed is the
    # sharpest version of the soft-failure problem this file documents further
    # up: a wrapper without its analyzer STARTS PERFECTLY. It emits a "NOT
    # RUNNING: the analyzer is missing" notice into a channel nothing reads in a
    # sandbox, exits 0, and passes SC1's can-every-hook-start question.
    #
    # guard-idle-land.py is the one that made this visible, because Layer IL
    # runs the gate FOR REAL and a missing analyzer makes the two-sided canary
    # fail hard rather than quietly. The other four are carried for the reason a
    # sandbox carries stop-hook-notice.sh: without them it does not look broken,
    # it looks FINE while standing in for a different engine.
    scripts/hooks/guard-idle-land.py
    scripts/hooks/guard-unresolved-claims.py
    scripts/hooks/guard-agent-state-claims.py
    scripts/hooks/guard-unasked-deferral.py
    scripts/hooks/turn-manifest.py
    # The waiver-repetition analyzer, on this list for the stop-hook-notice
    # reason rather than the refuse-to-start one. notice-waiver-repetition.sh
    # does NOT refuse without it: it starts, announces "WAIVER-REPETITION WATCH
    # IS OFF: the analyzer is missing" into a channel a sandbox has no reader
    # for, and exits 0 — so SC1's can-every-hook-start question passes over a
    # sandbox modelling an engine whose newest Stop notice reads no ledger.
    scripts/hooks/notice-waiver-repetition.py
    # The mechanical-findings sweep, both halves, on this list for the
    # stop-hook-notice reason: notice-mechanical-findings.sh does NOT refuse
    # without them — it starts, announces "MECHANICAL SWEEP IS OFF" into a
    # channel a sandbox has no reader for, and exits 0. A sandbox missing them
    # models an engine whose newest Stop hook writes no row.
    scripts/lib/mechanical-findings.sh
    scripts/lib/mechanical-findings.py
    # The model-tier parser. Carried for the DECIDING reason, and SC1 below
    # cannot see it: guard-worktree-isolation.sh does not refuse without it —
    # clause 6 fails OPEN by design, announces the skip into a channel a
    # sandbox has no reader for, and allows the spawn. A sandbox without it
    # starts every hook and models an engine in which a move to a lower
    # capability tier is checked by nobody. Layer MT fails loudly when it is
    # absent, which is how a sandbox missing it stops looking healthy.
    scripts/lib/model-tiers.sh
)

# Sandbox orchestration.config: protected trees for the write-guard + canary.
write_sandbox_config() {
    cat >"$1/orchestration.config" <<'CFG'
PROTECTED_PATHS="app packages"
READONLY_ALLOWLIST="Explore Plan claude-code-guide statusline-setup"
READER_TEAMMATE="reed"
CREATOR_TEAMMATE="dean"
# Declared, so Layer T exercises the dialect guard instead of taking its
# "declared nothing, enforcing nothing" WARN branch. A sandbox that models the
# engine with a guard stood down is modelling a different engine.
DIALECT_TARGET="en-US"
# Declared, so Layer MT exercises the tier gate instead of failing on a blank
# declaration — and so the sandbox models the engine with the capability order
# where it belongs: in data, beside the alias set it must equal.
ALLOWED_MODELS="fable opus sonnet haiku"
MODEL_TIERS="fable > opus > sonnet > haiku"
CFG
}

# gen_sidecars <root> — write a committed-style <hook>.sha256 next to each hook,
# so the sandbox faithfully mirrors the state after install.sh has minted the
# sidecars (the engine keeps them gitignored + regenerated, so a fresh clone runs
# install.sh once — the sandbox seeds them directly).
gen_sidecars() {
    local root="$1" f
    for h in "${ALL_HOOKS[@]}"; do
        f="$root/scripts/hooks/$h"
        [ -f "$f" ] || continue
        shasum -a 256 "$f" | awk '{print $1}' > "$f.sha256"
    done
    for s in "${ALL_ROOT_SCRIPTS[@]}"; do
        f="$root/$s"
        [ -f "$f" ] || continue
        shasum -a 256 "$f" | awk '{print $1}' > "$f.sha256"
    done
}

# copy_root_scripts <root> — mirror the managed non-hooks/ scripts (the reaper)
# into a sandbox, executable, exactly as a clone would carry them.
copy_root_scripts() {
    local root="$1" s
    for s in "${ALL_ROOT_SCRIPTS[@]}"; do
        cp "$REAL_REPO_ROOT/$s" "$root/$s"
        chmod +x "$root/$s"
    done
}

# write_sandbox_settings_local <root> <teams-flag-or-empty> <baseref-or-empty>
#
# Writes the sandbox's canonical .claude/settings.local.json wiring EVERY event
# (mirroring the real repo): SessionStart echo + agent-definition snapshotter,
# PreToolUse[Agent] four-hook chain (in canonical order, drift guard at position
# 2), PreToolUse[Write...] write-guard + secrets
# scanner, PreToolUse[SendMessage] resume-guard, PostToolUse[Agent] detector,
# TeammateIdle + TaskCompleted loggers — PLUS the two critical config keys
# (env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS, worktree.baseRef) parameterized so
# Layer I/J cases can omit either by passing an empty string. Placeholders
# ($CLAUDE_PROJECT_DIR) exactly as committed.
write_sandbox_settings_local() {
    local root="$1" teams_flag="$2" base_ref="$3"
    python3 - "$root/.claude/settings.local.json" "$teams_flag" "$base_ref" <<'PY'
import json, sys
out_path, teams_flag, base_ref = sys.argv[1:4]
P = "$CLAUDE_PROJECT_DIR/scripts/hooks"
data = {}
if teams_flag:
    data["env"] = {"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": teams_flag}
if base_ref:
    data["worktree"] = {"baseRef": base_ref}
data["hooks"] = {
    "SessionStart": [
        {"hooks": [{"type": "command", "command": "echo hi", "timeout": 5}]},
        {"hooks": [{"type": "command", "command": P + "/engine-status.sh", "timeout": 10}]},
        {"hooks": [{"type": "command", "command": P + "/session-start-reap-worktrees.sh", "timeout": 30}]},
        {"hooks": [{"type": "command", "command": P + "/snapshot-agent-definitions.sh", "timeout": 15}]},
    ],
    "PreToolUse": [
        {"matcher": "Agent", "hooks": [
            {"type": "command", "command": P + "/guard-worktree-isolation.sh", "timeout": 10},
            {"type": "command", "command": P + "/guard-definition-drift.sh", "timeout": 10},
            {"type": "command", "command": P + "/reader-teammate-hint.sh", "timeout": 10},
            {"type": "command", "command": P + "/verify-agent-prompt.sh", "timeout": 10},
            # LAST, mirroring the shipped chain. Layer C compares this chain
            # position by position against CANONICAL_AGENT_CHAIN, so a sandbox
            # that stopped at four would model an engine that cannot pass its
            # own probe — and every "probe passes" case in this file would go
            # red for a reason that has nothing to do with what it is testing.
            {"type": "command", "command": P + "/guard-ceo-ask-first.sh", "timeout": 20},
        ]},
        {"matcher": "Write|Edit|MultiEdit|NotebookEdit", "hooks": [
            {"type": "command", "command": P + "/guard-main-checkout-writes.sh", "timeout": 10},
            {"type": "command", "command": P + "/scan-secrets.sh", "timeout": 10},
            # Layer T's subject. Wired LAST here for the same reason it is wired
            # last in the shipped table: the two above decide whether the write
            # is ALLOWED AT ALL, and this one decides what the words say.
            {"type": "command", "command": P + "/guard-dialect.sh", "timeout": 10},
        ]},
        {"matcher": "SendMessage", "hooks": [
            {"type": "command", "command": P + "/guard-resume-isolation.sh", "timeout": 10},
        ]},
        {"matcher": "Bash", "hooks": [
            # FIRST, mirroring the shipped table. Layer IP scans the whole Bash
            # matcher list so order does not decide the layer — it is first
            # because a command that can hang the session should be refused
            # before anything slower has spent time on it.
            {"type": "command", "command": P + "/guard-interactive-prompt.sh", "timeout": 10},
            {"type": "command", "command": P + "/guard-bash-main-writes.sh", "timeout": 10},
            {"type": "command", "command": P + "/guard-worktree-removal.sh", "timeout": 10},
        ]},
        {"matcher": "Workflow", "hooks": [
            {"type": "command", "command": P + "/guard-workflow-ban.sh", "timeout": 10},
        ]},
    ],
    "PostToolUse": [
        {"matcher": "Agent", "hooks": [
            {"type": "command", "command": P + "/detect-nonnative-worktree.sh", "timeout": 10},
        ]},
    ],
    # THE STOP EVENT, WHICH THIS SANDBOX DID NOT WIRE AT ALL until 2026-09-01.
    # The comment above this function says it mirrors EVERY event; it did not
    # mirror this one, and the cost was invisible in exactly the way a missing
    # sandbox entry always is. The Stop event carries the engine's two BLOCKING
    # turn guards. Neither had a functional probe layer, so nothing noticed that
    # the sandbox modeled an engine whose Stop hooks were copied to disk and
    # registered nowhere -- and a layer written against them would have failed
    # for a reason that has nothing to do with the property it tests.
    #
    # Wired as the FULL shipped list rather than only Layer IL's subject: a
    # sandbox that wires one of nine is a different engine from the one that
    # ships, and the next Stop layer somebody writes would have to discover that
    # for itself.
    "Stop": [
        {"hooks": [{"type": "command", "command": P + "/guard-unresolved-claims.sh", "timeout": 20}]},
        {"hooks": [{"type": "command", "command": P + "/turn-manifest.sh", "timeout": 15}]},
        {"hooks": [{"type": "command", "command": P + "/notice-hook-staleness.sh", "timeout": 15}]},
        {"hooks": [{"type": "command", "command": P + "/notice-inflight-acks.sh", "timeout": 15}]},
        {"hooks": [{"type": "command", "command": P + "/notice-mechanical-findings.sh", "timeout": 15}]},
        {"hooks": [{"type": "command", "command": P + "/notice-unstarted-rows.sh", "timeout": 15}]},
        {"hooks": [{"type": "command", "command": P + "/notice-ceo-unasked.sh", "timeout": 15}]},
        {"hooks": [{"type": "command", "command": P + "/notice-unasked-deferral.sh", "timeout": 15}]},
        {"hooks": [{"type": "command", "command": P + "/guard-agent-state-claims.sh", "timeout": 15}]},
        {"hooks": [{"type": "command", "command": P + "/guard-idle-land.sh", "timeout": 20}]},
    ],
    "TeammateIdle": [
        {"hooks": [{"type": "command", "command": P + "/teammate-idle-handoff.sh", "timeout": 15}]}
    ],
    "TaskCompleted": [
        {"hooks": [{"type": "command", "command": P + "/task-completed-handoff.sh", "timeout": 15}]}
    ],
}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
PY
}

# ---------------------------------------------------------------------------
# Build a sandbox repo skeleton mirroring a committed fresh clone with the
# sidecars minted: canonical settings.local.json (all events, placeholders) +
# all hook scripts + their .sha256 sidecars + orchestration.config, and NO
# generated settings.json. Returns the absolute path of the new sandbox.
# ---------------------------------------------------------------------------
make_sandbox() {
    local root
    root="$(mktemp -d -t contract-integrity.XXXXXX)"
    mkdir -p "$root/scripts/hooks" "$root/scripts/lib" "$root/.claude/state"
    cp "$SCRIPT_DIR/install.sh" "$root/scripts/hooks/"
    cp "$SCRIPT_DIR/contract-integrity-probe.sh" "$root/scripts/hooks/"
    for h in "${ALL_HOOKS[@]}"; do
        cp "$SCRIPT_DIR/$h" "$root/scripts/hooks/"
    done
    cp "$SCRIPT_DIR/../lib/resolve-main-checkout.sh" "$root/scripts/lib/"
    # The guard inventory and the table it derives from. Every real engine
    # ships hooks/hooks.json — a seated engine registers its guards in
    # .claude/settings.local.json AND publishes the same set here for adopters
    # loading it as a plugin, which is exactly the pair Layer R's R4 compares.
    # A sandbox without it was modelling an engine that cannot exist, and it
    # went unnoticed only while nothing read the file.
    mkdir -p "$root/hooks"
    cp "$SCRIPT_DIR/../../hooks/hooks.json" "$root/hooks/hooks.json"
    cp "$SCRIPT_DIR/../lib/registered-hooks.sh" "$root/scripts/lib/"
    # The sandbox is its own engine root, so it identifies itself like one.
    cp "$SCRIPT_DIR/../../VERSION" "$root/VERSION" 2>/dev/null || printf '0.0.0-sandbox\n' >"$root/VERSION"
    copy_root_scripts "$root"
    chmod +x "$root/scripts/hooks/"*.sh 2>/dev/null || true
    write_sandbox_config "$root"
    write_sandbox_settings_local "$root" "1" "head"
    gen_sidecars "$root"
    echo "$root"
}

# Build a resolved, hook-DUPLICATING settings.json at <root> (the OLD broken
# state the pre-fix install.sh produced): a $CLAUDE_PROJECT_DIR-resolved copy of
# settings.local.json, which Claude Code would merge → every hook fires twice.
build_dup_settings_json() { # <root>
    python3 - "$1" <<'PY'
import json, sys
root = sys.argv[1]
with open(f"{root}/.claude/settings.local.json") as f: d = json.load(f)
def walk(o):
    if isinstance(o, dict): return {k: walk(v) for k, v in o.items()}
    if isinstance(o, list): return [walk(v) for v in o]
    if isinstance(o, str): return o.replace("$CLAUDE_PROJECT_DIR", root)
    return o
with open(f"{root}/.claude/settings.json", "w") as f:
    json.dump(walk(d), f, indent=2)
PY
}

# Both helpers DECLARE the sandbox as the repository under verification.
#
# Before the root-resolution contract, running "$ROOT/scripts/hooks/<x>.sh"
# implicitly meant "verify $ROOT", because the script derived its root from its
# own location. It no longer does — deliberately — so the intent has to be
# stated. Without it these cases verified whatever repository the harness
# happened to be launched from, and every wired path would be compared against
# the wrong canonical location.
# The `shift` is load-bearing: without it "$@" still holds $1, so the sandbox
# ROOT was passed to install.sh as a positional argument on every call. It was
# harmless only because install.sh ignored arguments entirely — and it stopped
# being harmless the moment install.sh grew --force-engine-pointer and began
# REFUSING unrecognized ones, which is exactly what strict argument parsing is
# for. The forwarding itself is kept, since forwarding extra flags is plainly
# what this line was reaching for.
run_install_in() {
    local _root="$1"; shift
    RICHOS_ENTITY_ROOT="$_root" "$_root/scripts/hooks/install.sh" "$@" 2>&1
}
run_probe_in() {
    # CI_PROBE_DEBUG=1 echoes the probe's own ✗ lines to stderr. A harness that
    # reports "expected exit=0 got=2" and nothing else forces whoever is
    # debugging to rebuild the sandbox by hand — which is how a real finding
    # gets written off as "the harness is fiddly".
    if [ -n "${CI_PROBE_DEBUG:-}" ]; then
        RICHOS_ENTITY_ROOT="$1" "$1/scripts/hooks/contract-integrity-probe.sh" 2>&1 | tee /dev/stderr
    else
        RICHOS_ENTITY_ROOT="$1" "$1/scripts/hooks/contract-integrity-probe.sh" 2>&1
    fi
}

emit_case() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS+1))
        printf '  PASS  %s\n' "$name"
    else
        FAIL=$((FAIL+1))
        FAIL_NAMES+=("$name")
        printf '  FAIL  %s  (expected exit=%s got=%s)\n' "$name" "$expected" "$actual"
    fi
}

# Helper: mutate ONLY the write-guard's (first) command in the Write|Edit
# matcher entry, leaving scan-secrets.sh's (second) command untouched — the
# matcher wires TWO hooks, and these cases are specifically about Layer B's
# write-guard, not Layer K's secrets scanner.
set_guard_command() { # <settings-file> <new-command>
    python3 - "$1" "$2" <<'PY'
import json, sys
p, cmd = sys.argv[1], sys.argv[2]
with open(p) as f: d = json.load(f)
for entry in d["hooks"]["PreToolUse"]:
    if "Write" in entry.get("matcher", ""):
        if entry["hooks"]:
            entry["hooks"][0]["command"] = cmd
with open(p, "w") as f: json.dump(d, f, indent=2)
PY
}

echo "=== contract-integrity.test.sh ==="
echo ""

# ---------------------------------------------------------------------------
# Canonical-source baseline
# ---------------------------------------------------------------------------

# Case 1 — committed fresh clone with sidecars minted (settings.local.json +
# hooks + sidecars, NO settings.json, NO install.sh run this case) → probe
# PASSES. The committed source alone wires enforcement; the sidecars are seeded.
ROOT="$(make_sandbox)"
set +e; run_probe_in "$ROOT" >/dev/null; rc=$?; set -e
emit_case "1.committed-source-passes" 0 "$rc"
rm -rf "$ROOT"

# ---------------------------------------------------------------------------
# SANDBOX COMPLETENESS — the case that makes the list above unable to fall
# behind silently.
#
# EVERY case in this file builds its sandbox from ALL_HOOKS + ALL_ROOT_SCRIPTS,
# and every case's exit code is only worth reading if the engine in that sandbox
# can actually be assembled. On 2026-08-31 it could not: five guards landed and
# the list did not grow, so scan-secrets.sh and guard-main-checkout-writes.sh
# could not start, and BOTH refuse by exiting 2 — the same number Layers K and D
# were asserting as proof that they had run and caught something. Two dead
# guards, two green layers, for as long as the list had existed.
#
# So the list is no longer trusted to be complete: it is ASKED. SC1 starts every
# registered hook in a real sandbox and fails naming any that announced a
# missing file. It is answered by RUNNING the hooks, so it holds for a
# dependency expressed in any form — sourced library, sibling .py, data file,
# path assembled at runtime. It found scripts/lib/inflight.sh, which reading the
# night's diff had not.
#
# SC2 is its negative control, and it is not optional: SC1 reports a problem by
# printing NOTHING, which is the same output a check that scanned zero hooks
# produces. SC2 deletes seat-jurisdiction.sh — the exact file whose absence
# started this — and requires SC1's machinery to name the guard that then cannot
# start. Without it, SC1 is a clean bill of health signed by nobody.
# ---------------------------------------------------------------------------
ROOT="$(make_sandbox)"
set +e; SC_OUT="$(richos_sandbox_start_failures "$ROOT" "${ALL_HOOKS[@]}")"; set -e
if [ -z "$SC_OUT" ]; then
    emit_case "SC1.every-registered-hook-starts-in-a-sandbox" 0 0
else
    printf '        sandbox is missing what these hooks need:\n%s\n' "$SC_OUT" >&2
    emit_case "SC1.every-registered-hook-starts-in-a-sandbox" 0 1
fi
rm -rf "$ROOT"

ROOT="$(make_sandbox)"
rm -f "$ROOT/scripts/lib/seat-jurisdiction.sh"
set +e; SC_OUT="$(richos_sandbox_start_failures "$ROOT" "${ALL_HOOKS[@]}")"; set -e
if printf '%s' "$SC_OUT" | grep -q '^scan-secrets\.sh'; then
    emit_case "SC2.NEGATIVE-CONTROL-deleted-lib-is-named-by-SC1" 0 0
else
    printf '        expected scan-secrets.sh to be reported unable to start, got: [%s]\n' "$SC_OUT" >&2
    emit_case "SC2.NEGATIVE-CONTROL-deleted-lib-is-named-by-SC1" 0 1
fi
rm -rf "$ROOT"

# Case 2 — install.sh (no settings.json to migrate) + probe → both exit 0.
ROOT="$(make_sandbox)"
set +e; run_install_in "$ROOT" >/dev/null; rc1=$?; set -e
set +e; run_probe_in "$ROOT" >/dev/null; rc2=$?; set -e
emit_case "2.install-noop-rc-0" 0 "$rc1"
emit_case "2.post-install-probe-rc-0" 0 "$rc2"
rm -rf "$ROOT"

# Case 3 — drop the write-guard entry from the CANONICAL file → probe exits 2.
ROOT="$(make_sandbox)"
python3 - "$ROOT/.claude/settings.local.json" <<'PY'
import json, sys
p = sys.argv[1]
with open(p) as f: d = json.load(f)
pre = d.get("hooks", {}).get("PreToolUse", [])
d["hooks"]["PreToolUse"] = [e for e in pre if "Write" not in e.get("matcher", "")]
with open(p, "w") as f: json.dump(d, f, indent=2)
PY
set +e; run_probe_in "$ROOT" >/dev/null; rc=$?; set -e
emit_case "3.hook-removed-fails" 2 "$rc"
rm -rf "$ROOT"

# Case 4 — canonical wiring points at a non-existent script → probe exits 2.
ROOT="$(make_sandbox)"
set_guard_command "$ROOT/.claude/settings.local.json" "/nonexistent/path/to/guard-main-checkout-writes.sh"
set +e; run_probe_in "$ROOT" >/dev/null; rc=$?; set -e
emit_case "4.wrong-path-fails" 2 "$rc"
rm -rf "$ROOT"

# Case 5 — install.sh is idempotent (sidecars byte-stable across runs) and the
# probe still passes.
ROOT="$(make_sandbox)"
"$ROOT/scripts/hooks/install.sh" >/dev/null
HASH1="$(shasum -a 256 "$ROOT/scripts/hooks/guard-main-checkout-writes.sh.sha256" | awk '{print $1}')"
"$ROOT/scripts/hooks/install.sh" >/dev/null
HASH2="$(shasum -a 256 "$ROOT/scripts/hooks/guard-main-checkout-writes.sh.sha256" | awk '{print $1}')"
if [ "$HASH1" = "$HASH2" ]; then
    PASS=$((PASS+1)); printf '  PASS  5.double-install-idempotent\n'
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("5.double-install-idempotent"); printf '  FAIL  5.double-install-idempotent  (sidecar hash drifted)\n'
fi
set +e; run_probe_in "$ROOT" >/dev/null; rc=$?; set -e
emit_case "5.double-install-probe-still-rc-0" 0 "$rc"
rm -rf "$ROOT"

# Case 6 — install.sh fails when canonical settings.local.json is absent.
ROOT="$(make_sandbox)"
rm "$ROOT/.claude/settings.local.json"
set +e; run_install_in "$ROOT" >/dev/null 2>&1; rc=$?; set -e
emit_case "6.install-source-missing-rc-2" 2 "$rc"
rm -rf "$ROOT"

# Case 7 — install.sh NEVER rewrites the canonical settings.local.json (it only
# migrates settings.json + refreshes sidecars). The committed source, including
# its $CLAUDE_PROJECT_DIR placeholders, is left byte-identical.
ROOT="$(make_sandbox)"
BEFORE="$(shasum -a 256 "$ROOT/.claude/settings.local.json" | awk '{print $1}')"
"$ROOT/scripts/hooks/install.sh" >/dev/null
AFTER="$(shasum -a 256 "$ROOT/.claude/settings.local.json" | awk '{print $1}')"
if [ "$BEFORE" = "$AFTER" ]; then
    PASS=$((PASS+1)); printf '  PASS  7.canonical-source-untouched-by-install\n'
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("7.canonical-source-untouched-by-install"); printf '  FAIL  7.canonical-source-untouched-by-install  (install.sh mutated settings.local.json)\n'
fi
rm -rf "$ROOT"

# ---------------------------------------------------------------------------
# Layer M — registration uniqueness (the double-fire root-fix)
# ---------------------------------------------------------------------------

# Case M1 — a stale hook-duplicating settings.json (the OLD broken state) is
# MERGED with settings.local.json → probe exits 2 (Layer M detects double-fire).
ROOT="$(make_sandbox)"
build_dup_settings_json "$ROOT"
set +e; run_probe_in "$ROOT" >/dev/null; rc=$?; set -e
emit_case "M1.duplicated-registration-fails" 2 "$rc"
rm -rf "$ROOT"

# Case M2 — install.sh MIGRATES the duplicated state: it removes the pure-
# duplicate settings.json, and the probe then PASSES (converges to single-fire).
ROOT="$(make_sandbox)"
build_dup_settings_json "$ROOT"
"$ROOT/scripts/hooks/install.sh" >/dev/null
if [ ! -f "$ROOT/.claude/settings.json" ]; then
    PASS=$((PASS+1)); printf '  PASS  M2.migration-removes-duplicate-settings-json\n'
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("M2.migration-removes-duplicate-settings-json"); printf '  FAIL  M2.migration-removes-duplicate-settings-json  (settings.json survived install.sh)\n'
fi
set +e; run_probe_in "$ROOT" >/dev/null; rc=$?; set -e
emit_case "M2.post-migration-probe-passes" 0 "$rc"
# M2 idempotence — a SECOND install.sh run is a no-op (settings.json stays gone).
"$ROOT/scripts/hooks/install.sh" >/dev/null
if [ ! -f "$ROOT/.claude/settings.json" ]; then
    PASS=$((PASS+1)); printf '  PASS  M2b.migration-second-run-noop\n'
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("M2b.migration-second-run-noop"); printf '  FAIL  M2b.migration-second-run-noop  (settings.json reappeared)\n'
fi
rm -rf "$ROOT"

# Case M3 — a settings.json carrying MACHINE-SPECIFIC non-hook config plus a
# duplicated hooks block: install.sh strips the hooks but KEEPS the file (and
# its unique key), and the probe then passes.
ROOT="$(make_sandbox)"
build_dup_settings_json "$ROOT"
python3 - "$ROOT/.claude/settings.json" <<'PY'
import json, sys
p = sys.argv[1]
with open(p) as f: d = json.load(f)
d["env2"] = {"MACHINE_SPECIFIC_KNOB": "1"}   # a key NOT present in settings.local.json
with open(p, "w") as f: json.dump(d, f, indent=2)
PY
"$ROOT/scripts/hooks/install.sh" >/dev/null
KEPT=0; HAS_HOOKS=1; HAS_KNOB=0
if [ -f "$ROOT/.claude/settings.json" ]; then
    KEPT=1
    HAS_HOOKS="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(1 if d.get('hooks') else 0)" "$ROOT/.claude/settings.json")"
    HAS_KNOB="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(1 if d.get('env2',{}).get('MACHINE_SPECIFIC_KNOB')=='1' else 0)" "$ROOT/.claude/settings.json")"
fi
if [ "$KEPT" = "1" ] && [ "$HAS_HOOKS" = "0" ] && [ "$HAS_KNOB" = "1" ]; then
    PASS=$((PASS+1)); printf '  PASS  M3.machine-specific-settings-json-hooks-stripped-config-kept\n'
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("M3.machine-specific-settings-json-hooks-stripped-config-kept"); printf '  FAIL  M3.machine-specific-settings-json  (kept=%s hooks=%s knob=%s)\n' "$KEPT" "$HAS_HOOKS" "$HAS_KNOB"
fi
set +e; run_probe_in "$ROOT" >/dev/null; rc=$?; set -e
emit_case "M3.machine-specific-probe-passes" 0 "$rc"
rm -rf "$ROOT"

# Case M4 — INTRA-FILE duplication: the same hook listed twice inside
# settings.local.json alone → probe exits 2 (Layer M2 counts the total).
ROOT="$(make_sandbox)"
python3 - "$ROOT/.claude/settings.local.json" <<'PY'
import json, sys
p = sys.argv[1]
with open(p) as f: d = json.load(f)
for entry in d["hooks"]["PreToolUse"]:
    if "Write" in entry.get("matcher", ""):
        # Append a byte-identical second copy of the write-guard hook.
        entry["hooks"].append(dict(entry["hooks"][0]))
with open(p, "w") as f: json.dump(d, f, indent=2)
PY
set +e; run_probe_in "$ROOT" >/dev/null; rc=$?; set -e
emit_case "M4.intra-file-duplication-fails" 2 "$rc"
rm -rf "$ROOT"

# ---------------------------------------------------------------------------
# Shim attacks — Layer B path-confinement + hashing, targeting the CANONICAL
# settings.local.json.
# ---------------------------------------------------------------------------

# Case 8 — Shim at non-canonical path with matching filename → FAIL.
ROOT="$(make_sandbox)"
SHIMDIR="$(mktemp -d -t shim.XXXXXX)"
SHIM="$SHIMDIR/guard-main-checkout-writes.sh"
cat >"$SHIM" <<'SHIM_SH'
#!/usr/bin/env bash
INPUT="$(cat)"
if printf '%s' "$INPUT" | grep -q '__integrity_canary__'; then
    exit 2
fi
exit 0
SHIM_SH
chmod +x "$SHIM"
set_guard_command "$ROOT/.claude/settings.local.json" "$SHIM"
set +e; run_probe_in "$ROOT" >/dev/null; rc=$?; set -e
emit_case "8.shim-at-wrong-path-fails" 2 "$rc"
rm -rf "$ROOT" "$SHIMDIR"

# Case 9 — Canonical path but modified content → hash mismatch → FAIL.
ROOT="$(make_sandbox)"
cat >"$ROOT/scripts/hooks/guard-main-checkout-writes.sh" <<'NOOP_SH'
#!/usr/bin/env bash
exit 0
NOOP_SH
chmod +x "$ROOT/scripts/hooks/guard-main-checkout-writes.sh"
set +e; run_probe_in "$ROOT" >/dev/null; rc=$?; set -e
emit_case "9.canonical-path-wrong-hash-fails" 2 "$rc"
rm -rf "$ROOT"

# Case 10 — Hook command points to symlink whose target is outside repo → FAIL.
ROOT="$(make_sandbox)"
OUTSIDE="$(mktemp -d -t outside.XXXXXX)"
cat >"$OUTSIDE/g.sh" <<'OUT_SH'
#!/usr/bin/env bash
exit 0
OUT_SH
chmod +x "$OUTSIDE/g.sh"
rm -f "$ROOT/scripts/hooks/guard-main-checkout-writes.sh"
ln -s "$OUTSIDE/g.sh" "$ROOT/scripts/hooks/guard-main-checkout-writes.sh"
set +e; run_probe_in "$ROOT" >/dev/null; rc=$?; set -e
emit_case "10.symlink-to-outside-fails" 2 "$rc"
rm -rf "$ROOT" "$OUTSIDE"

# Case 11 — trailing args on the canonical path are benign → PASS;
# a shim path with the same trailing args → FAIL.
ROOT="$(make_sandbox)"
GUARD_ABS="$ROOT/scripts/hooks/guard-main-checkout-writes.sh"
set_guard_command "$ROOT/.claude/settings.local.json" "$GUARD_ABS --flag"
set +e; run_probe_in "$ROOT" >/dev/null; rc=$?; set -e
emit_case "11.canonical-with-trailing-args-passes" 0 "$rc"
SHIMDIR="$(mktemp -d -t shim.XXXXXX)"
SHIM="$SHIMDIR/guard-main-checkout-writes.sh"
cp "$GUARD_ABS" "$SHIM"
set_guard_command "$ROOT/.claude/settings.local.json" "$SHIM --flag"
set +e; run_probe_in "$ROOT" >/dev/null; rc=$?; set -e
emit_case "11b.shim-with-trailing-args-fails" 2 "$rc"
rm -rf "$ROOT" "$SHIMDIR"

# Case 12 — Fresh committed clone (no modification) → all layers PASS.
ROOT="$(make_sandbox)"
set +e; run_probe_in "$ROOT" >/dev/null; rc=$?; set -e
emit_case "12.canonical-fresh-clone-passes" 0 "$rc"
rm -rf "$ROOT"

# ---------------------------------------------------------------------------
# Manifest tampering — sidecar hash closure.
# ---------------------------------------------------------------------------

# Case 13 — tamper the canonical guard hook → Layer B FAILS.
ROOT="$(make_sandbox)"
printf '\n' >> "$ROOT/scripts/hooks/guard-main-checkout-writes.sh"
set +e; run_probe_in "$ROOT" >/dev/null; rc=$?; set -e
emit_case "13.tamper-canonical-guard-fails" 2 "$rc"
rm -rf "$ROOT"

# Case 14 — tamper the agent hook → Layer C FAILS.
ROOT="$(make_sandbox)"
printf '\n# tampered\n' >> "$ROOT/scripts/hooks/verify-agent-prompt.sh"
set +e; run_probe_in "$ROOT" >/dev/null; rc=$?; set -e
emit_case "14.tamper-canonical-agent-fails" 2 "$rc"
rm -rf "$ROOT"

# Case 14a — tamper the FIRST chain member (guard-worktree-isolation.sh) → FAIL.
ROOT="$(make_sandbox)"
printf '\n# tampered\n' >> "$ROOT/scripts/hooks/guard-worktree-isolation.sh"
set +e; run_probe_in "$ROOT" >/dev/null; rc=$?; set -e
emit_case "14a.tamper-guard-worktree-isolation-fails" 2 "$rc"
rm -rf "$ROOT"

# Case 14b — tamper the MIDDLE chain member (reader-teammate-hint.sh) → FAIL.
ROOT="$(make_sandbox)"
printf '\n# tampered\n' >> "$ROOT/scripts/hooks/reader-teammate-hint.sh"
set +e; run_probe_in "$ROOT" >/dev/null; rc=$?; set -e
emit_case "14b.tamper-reader-teammate-hint-fails" 2 "$rc"
rm -rf "$ROOT"

# Case 14c — chain entry count mismatch (only verify-agent-prompt.sh wired) → FAIL.
ROOT="$(make_sandbox)"
python3 - "$ROOT/.claude/settings.local.json" <<'PY'
import json, sys
p = sys.argv[1]
with open(p) as f: d = json.load(f)
for entry in d["hooks"]["PreToolUse"]:
    if entry.get("matcher") == "Agent":
        entry["hooks"] = [h for h in entry["hooks"] if "verify-agent-prompt" in h.get("command", "")]
with open(p, "w") as f: json.dump(d, f, indent=2)
PY
set +e; run_probe_in "$ROOT" >/dev/null; rc=$?; set -e
emit_case "14c.chain-entry-missing-fails" 2 "$rc"
rm -rf "$ROOT"

# Case 14d — chain entries wired OUT OF ORDER (reversed) → Layer C FAILS (order is load-bearing).
ROOT="$(make_sandbox)"
python3 - "$ROOT/.claude/settings.local.json" <<'PY'
import json, sys
p = sys.argv[1]
with open(p) as f: d = json.load(f)
for entry in d["hooks"]["PreToolUse"]:
    if entry.get("matcher") == "Agent":
        entry["hooks"] = list(reversed(entry["hooks"]))
with open(p, "w") as f: json.dump(d, f, indent=2)
PY
set +e; run_probe_in "$ROOT" >/dev/null; rc=$?; set -e
emit_case "14d.chain-out-of-order-fails" 2 "$rc"
rm -rf "$ROOT"

# Case 15 — inline shim-replace of the canonical guard body → hash mismatch FAIL.
ROOT="$(make_sandbox)"
cat >"$ROOT/scripts/hooks/guard-main-checkout-writes.sh" <<'NOOP_SH'
#!/usr/bin/env bash
exit 0
NOOP_SH
chmod +x "$ROOT/scripts/hooks/guard-main-checkout-writes.sh"
set +e; run_probe_in "$ROOT" >/dev/null; rc=$?; set -e
emit_case "15.inline-shim-replace-fails" 2 "$rc"
rm -rf "$ROOT"

# Case 16 — manifest file missing → probe FAILS.
ROOT="$(make_sandbox)"
rm -f "$ROOT/scripts/hooks/guard-main-checkout-writes.sh.sha256"
set +e; run_probe_in "$ROOT" >/dev/null; rc=$?; set -e
emit_case "16.manifest-missing-fails" 2 "$rc"
rm -rf "$ROOT"

# Case 17 — manifest file stale (wrong hash) → FAIL.
ROOT="$(make_sandbox)"
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' \
    > "$ROOT/scripts/hooks/guard-main-checkout-writes.sh.sha256"
set +e; run_probe_in "$ROOT" >/dev/null; rc=$?; set -e
emit_case "17.manifest-wrong-hash-fails" 2 "$rc"
rm -rf "$ROOT"

# Case 18 — install.sh is idempotent for manifests too.
ROOT="$(make_sandbox)"
"$ROOT/scripts/hooks/install.sh" >/dev/null
HASH1_G="$(shasum -a 256 "$ROOT/scripts/hooks/guard-main-checkout-writes.sh.sha256" | awk '{print $1}')"
HASH1_A="$(shasum -a 256 "$ROOT/scripts/hooks/verify-agent-prompt.sh.sha256" | awk '{print $1}')"
HASH1_R="$(shasum -a 256 "$ROOT/scripts/hooks/reader-teammate-hint.sh.sha256" | awk '{print $1}')"
HASH1_W="$(shasum -a 256 "$ROOT/scripts/hooks/guard-worktree-isolation.sh.sha256" | awk '{print $1}')"
"$ROOT/scripts/hooks/install.sh" >/dev/null
HASH2_G="$(shasum -a 256 "$ROOT/scripts/hooks/guard-main-checkout-writes.sh.sha256" | awk '{print $1}')"
HASH2_A="$(shasum -a 256 "$ROOT/scripts/hooks/verify-agent-prompt.sh.sha256" | awk '{print $1}')"
HASH2_R="$(shasum -a 256 "$ROOT/scripts/hooks/reader-teammate-hint.sh.sha256" | awk '{print $1}')"
HASH2_W="$(shasum -a 256 "$ROOT/scripts/hooks/guard-worktree-isolation.sh.sha256" | awk '{print $1}')"
if [ "$HASH1_G" = "$HASH2_G" ] && [ "$HASH1_A" = "$HASH2_A" ] && [ "$HASH1_R" = "$HASH2_R" ] && [ "$HASH1_W" = "$HASH2_W" ]; then
    PASS=$((PASS+1)); printf '  PASS  18.install-idempotent-manifests\n'
else
    FAIL=$((FAIL+1))
    FAIL_NAMES+=("18.install-idempotent-manifests")
    printf '  FAIL  18.install-idempotent-manifests  (manifest hash drifted across runs)\n'
fi
rm -rf "$ROOT"

# ---------------------------------------------------------------------------
# Worktree-resolution cases — the probe must resolve the TRUE main checkout
# whether its own copy runs from the main checkout OR from a linked
# `git worktree`.
# ---------------------------------------------------------------------------
make_git_main() {
    local root
    root="$(cd "$(mktemp -d -t contract-integrity-git.XXXXXX)" && pwd -P)"
    mkdir -p "$root/scripts/hooks" "$root/scripts/lib" "$root/.claude/state"
    cp "$SCRIPT_DIR/install.sh" "$root/scripts/hooks/"
    cp "$SCRIPT_DIR/contract-integrity-probe.sh" "$root/scripts/hooks/"
    for h in "${ALL_HOOKS[@]}"; do
        cp "$SCRIPT_DIR/$h" "$root/scripts/hooks/"
    done
    cp "$SCRIPT_DIR/../lib/resolve-main-checkout.sh" "$root/scripts/lib/"
    # The guard inventory and the table it derives from. Every real engine
    # ships hooks/hooks.json — a seated engine registers its guards in
    # .claude/settings.local.json AND publishes the same set here for adopters
    # loading it as a plugin, which is exactly the pair Layer R's R4 compares.
    # A sandbox without it was modelling an engine that cannot exist, and it
    # went unnoticed only while nothing read the file.
    mkdir -p "$root/hooks"
    cp "$SCRIPT_DIR/../../hooks/hooks.json" "$root/hooks/hooks.json"
    cp "$SCRIPT_DIR/../lib/registered-hooks.sh" "$root/scripts/lib/"
    # The sandbox is its own engine root, so it identifies itself like one.
    cp "$SCRIPT_DIR/../../VERSION" "$root/VERSION" 2>/dev/null || printf '0.0.0-sandbox\n' >"$root/VERSION"
    copy_root_scripts "$root"
    chmod +x "$root/scripts/hooks/"*.sh 2>/dev/null || true
    write_sandbox_config "$root"
    write_sandbox_settings_local "$root" "1" "head"
    gen_sidecars "$root"
    # Gitignore the generated settings.json + nested worktrees so a linked
    # worktree does NOT receive its own settings.json — mirroring the real repo,
    # where a probe run from a worktree reaches back to the MAIN checkout. The
    # .sha256 sidecars are gitignored per engine convention; the probe reads MAIN's
    # ON-DISK sidecars (minted by gen_sidecars) regardless of git tracking.
    cat >"$root/.gitignore" <<'GI'
/.claude/settings.json
/.claude/worktrees/
scripts/hooks/*.sha256
scripts/*.sha256
GI
    git -C "$root" init -q -b main
    # NO local identity override. These throwaway fixtures inherit the
    # operator's real global identity, which is what a machine-wide pre-commit
    # identity guard requires. With a fake identity the seed commit is REFUSED,
    # the fixture has no branch, `git worktree add` fails, and cases 19-21
    # report exit 127 (missing path) rather than anything about the probe.
    git -C "$root" add -A
    # Force-add the canonical settings file so Layer N sees it tracked. A GLOBAL
    # gitignore convention ('**/.claude/settings.local.json') on the test
    # machine would otherwise make `git add -A` silently skip it (exactly the
    # trap Layer N exists to catch) — mirror the real remedy, `git add -f`.
    git -C "$root" add -f .claude/settings.local.json
    # Force-add the sidecar for scripts/agent-liveness.sh, for the same reason
    # one line up and a different gitignore rule. Cases 20/21 probe FROM the
    # linked worktree, and the layers that resolve against ENGINE_ROOT rather
    # than REPO_ROOT — R and AL — therefore read the WORKTREE's copy of the
    # engine, not MAIN's. Every other ENGINE_ROOT-read sidecar in this fixture
    # lives under scripts/lib/, which the .gitignore above does not cover, so
    # they arrive in the worktree by accident rather than by intent. This one
    # lives at scripts/ and would not, leaving the worktree carrying a managed
    # file with no sidecar — a real finding in a real engine, and a fixture
    # artifact here. Named rather than papered over: a REAL linked worktree of
    # this engine has NO sidecars at all until install.sh is run in it, which
    # is why an engine land is red until it is.
    git -C "$root" add -f scripts/agent-liveness.sh.sha256 2>/dev/null || true
    git -C "$root" commit -q -m init
    echo "$root"
}

# Case 19 — probe passes from the MAIN checkout of a real git repo, and Layer N
# emits its explicit git-tracked PASS line (positive shape).
MAIN="$(make_git_main)"
set +e; PROBE_OUT="$(RICHOS_ENTITY_ROOT="$MAIN" "$MAIN/scripts/hooks/contract-integrity-probe.sh" 2>&1 1>/dev/null)"; rc=$?; set -e
emit_case "19.git-main-checkout-passes" 0 "$rc"
if printf '%s' "$PROBE_OUT" | grep -qF 'N. .claude/settings.local.json is git-tracked'; then
    PASS=$((PASS+1)); printf '  PASS  19b.layer-N-tracked-pass-line-present\n'
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("19b.layer-N-tracked-pass-line-present"); printf '  FAIL  19b.layer-N-tracked-pass-line-present  (got: %s)\n' "$PROBE_OUT"
fi

# Case 20 — probe passes when invoked FROM A LINKED WORKTREE (resolve_main_
# checkout resolves REPO_ROOT back to MAIN; the worktree has no settings.json).
WT="$MAIN/.claude/worktrees/agent-test"
git -C "$MAIN" worktree add -q -b wt-test "$WT" >/dev/null 2>&1
set +e; RICHOS_ENTITY_ROOT="$WT" "$WT/scripts/hooks/contract-integrity-probe.sh" >/dev/null 2>&1; rc=$?; set -e
emit_case "20.git-worktree-invocation-passes" 0 "$rc"

# Case 21 — proof the worktree run TRULY targets MAIN's settings: planting a
# hook-duplicating settings.json in MAIN flips the worktree-invoked probe to
# FAIL (exit 2, Layer M), proving it reads MAIN's files, not a worktree-local
# copy or a stale fallback.
build_dup_settings_json "$MAIN"
set +e; RICHOS_ENTITY_ROOT="$WT" "$WT/scripts/hooks/contract-integrity-probe.sh" >/dev/null 2>&1; rc=$?; set -e
emit_case "21.worktree-probe-targets-main-settings" 2 "$rc"

git -C "$MAIN" worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"
rm -rf "$MAIN"

# ---------------------------------------------------------------------------
# Layer N — git-tracked canonical settings.local.json (the silent global-
# gitignore stranding trap). Positive shape lives in case 19b (tracked -> PASS
# line). These two cover the HARD-fail trap and the not-yet-committed WARN.
#
# Determinism: git's default excludesFile is the XDG path (~/.config/git/ignore),
# consulted EVEN when GIT_CONFIG_GLOBAL is neutralized — and on a dev box it
# commonly DOES carry the '**/.claude/settings.local.json' rule (the automation QA's live-fire
# F2). So we point core.excludesFile at /dev/null via a throwaway global config
# and null out the system config, making the "is it ignored?" answer depend ONLY
# on each case's own repo-local .gitignore, not the test machine.
# ---------------------------------------------------------------------------
NOIGNORE_CFG="$(mktemp -t contract-integrity-noignore.XXXXXX)"
printf '[core]\n\texcludesFile = /dev/null\n' > "$NOIGNORE_CFG"

# Case 32 — THE TRAP: settings.local.json present on disk but untracked AND
# matched by a (repo-local) gitignore rule -> Layer N HARD-fails and names the
# git-add-f fix.
MAIN="$(make_git_main)"
git -C "$MAIN" rm --cached -q .claude/settings.local.json
printf '/.claude/settings.local.json\n' >> "$MAIN/.gitignore"
git -C "$MAIN" add .gitignore
git -C "$MAIN" commit -q -m "untrack + ignore settings.local.json (simulate the F2 trap)"
set +e
PROBE_OUT="$(GIT_CONFIG_GLOBAL="$NOIGNORE_CFG" GIT_CONFIG_SYSTEM=/dev/null RICHOS_ENTITY_ROOT="$MAIN" "$MAIN/scripts/hooks/contract-integrity-probe.sh" 2>&1 1>/dev/null)"
rc=$?
set -e
emit_case "32.git-untracked-ignored-settings-local-fails" 2 "$rc"
if printf '%s' "$PROBE_OUT" | grep -qF 'git add -f .claude/settings.local.json'; then
    PASS=$((PASS+1)); printf '  PASS  32b.layer-N-names-the-git-add-f-fix\n'
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("32b.layer-N-names-the-git-add-f-fix"); printf '  FAIL  32b.layer-N-names-the-git-add-f-fix  (got: %s)\n' "$PROBE_OUT"
fi
rm -rf "$MAIN"

# Case 33 — NOT-YET-COMMITTED (no ignore rule matches): untracked but not
# ignored -> Layer N WARNS, never HARD-fails (avoids the pre-first-commit false
# positive). Probe still exits 0.
MAIN="$(make_git_main)"
git -C "$MAIN" rm --cached -q .claude/settings.local.json
git -C "$MAIN" commit -q -m "untrack settings.local.json, no ignore rule"
set +e
PROBE_OUT="$(GIT_CONFIG_GLOBAL="$NOIGNORE_CFG" GIT_CONFIG_SYSTEM=/dev/null RICHOS_ENTITY_ROOT="$MAIN" "$MAIN/scripts/hooks/contract-integrity-probe.sh" 2>&1 1>/dev/null)"
rc=$?
set -e
emit_case "33.git-untracked-not-ignored-warns-rc-0" 0 "$rc"
if printf '%s' "$PROBE_OUT" | grep -qF 'N. .claude/settings.local.json is present but not yet git-tracked'; then
    PASS=$((PASS+1)); printf '  PASS  33b.layer-N-warns-when-not-yet-committed\n'
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("33b.layer-N-warns-when-not-yet-committed"); printf '  FAIL  33b.layer-N-warns-when-not-yet-committed  (got: %s)\n' "$PROBE_OUT"
fi
rm -rf "$MAIN"
rm -f "$NOIGNORE_CFG"

# ---------------------------------------------------------------------------
# python3-missing-from-PATH cases — mirrors the automation QA's fail-open repro. Both
# install.sh and contract-integrity-probe.sh must refuse (non-zero exit, loud
# stderr) rather than silently degrading when python3 is unresolvable.
# ---------------------------------------------------------------------------

# make_fakebin_no_python3 — a PATH dir populated with symlinks to every
# external tool these scripts need EXCEPT python3.
make_fakebin_no_python3() {
    local dir
    dir="$(mktemp -d -t fakebin-no-python3.XXXXXX)"
    local tools="cat grep sed cut tr date mkdir git mktemp basename dirname rm ln awk sort uniq wc head tail shasum sha256sum env mv"
    local t p
    for t in $tools; do
        p="$(command -v "$t" 2>/dev/null || true)"
        [ -n "$p" ] && ln -sf "$p" "$dir/$t"
    done
    echo "$dir"
}
BASH_BIN="$(command -v bash)"

# Case 22 — install.sh with no python3 on PATH -> refuses (non-zero), names
# python3 in its diagnostic.
ROOT="$(make_sandbox)"
FAKEBIN="$(make_fakebin_no_python3)"
set +e
NOPY_OUT="$(PATH="$FAKEBIN" "$BASH_BIN" "$ROOT/scripts/hooks/install.sh" 2>&1 1>/dev/null)"
rc=$?
set -e
emit_case "22.install-no-python3-refuses" 2 "$rc"
if printf '%s' "$NOPY_OUT" | grep -qF 'python3'; then
    PASS=$((PASS+1)); printf '  PASS  22b.install-no-python3-stderr-names-python3\n'
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("22b.install-no-python3-stderr-names-python3"); printf '  FAIL  22b.install-no-python3-stderr-names-python3  (got: %s)\n' "$NOPY_OUT"
fi
rm -rf "$FAKEBIN" "$ROOT"

# Case 23 — probe with no python3 on PATH -> refuses (non-zero), names python3
# in its diagnostic. Confirms the probe itself does not silently degrade its
# JSON-extraction / path-confinement checks when its interpreter is missing.
ROOT="$(make_sandbox)"
FAKEBIN="$(make_fakebin_no_python3)"
set +e
NOPY_OUT="$(PATH="$FAKEBIN" RICHOS_ENTITY_ROOT="$ROOT" "$BASH_BIN" "$ROOT/scripts/hooks/contract-integrity-probe.sh" 2>&1 1>/dev/null)"
rc=$?
set -e
emit_case "23.probe-no-python3-refuses" 2 "$rc"
if printf '%s' "$NOPY_OUT" | grep -qF 'python3'; then
    PASS=$((PASS+1)); printf '  PASS  23b.probe-no-python3-stderr-names-python3\n'
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("23b.probe-no-python3-stderr-names-python3"); printf '  FAIL  23b.probe-no-python3-stderr-names-python3  (got: %s)\n' "$NOPY_OUT"
fi
rm -rf "$FAKEBIN" "$ROOT"

# ---------------------------------------------------------------------------
# Critical-config cases (env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS,
# worktree.baseRef) — the "ghost team" incident this pair guards against.
# Cover both install.sh's own preserve-or-fail refusal (key missing BEFORE any
# install has run) and the probe's Layer I/J (key removed AFTER a successful
# install). Case 28 is the required positive-shape probe.
# ---------------------------------------------------------------------------

# Case 24 — install.sh refuses when settings.local.json is missing the env
# flag from the start (never migrates/refreshes on a broken source).
ROOT="$(make_sandbox)"
write_sandbox_settings_local "$ROOT" "" "head"
set +e; INSTALL_OUT="$("$ROOT/scripts/hooks/install.sh" 2>&1 1>/dev/null)"; rc=$?; set -e
emit_case "24.install-missing-env-flag-refuses" 2 "$rc"
if printf '%s' "$INSTALL_OUT" | grep -qF 'CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS'; then
    PASS=$((PASS+1)); printf '  PASS  24b.install-missing-env-flag-names-the-key\n'
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("24b.install-missing-env-flag-names-the-key"); printf '  FAIL  24b.install-missing-env-flag-names-the-key  (got: %s)\n' "$INSTALL_OUT"
fi
if [ -f "$ROOT/.claude/settings.json" ]; then
    FAIL=$((FAIL+1)); FAIL_NAMES+=("24c.install-missing-env-flag-must-not-write-settings-json"); printf '  FAIL  24c.install-missing-env-flag-must-not-write-settings-json  (settings.json was written despite refusal)\n'
else
    PASS=$((PASS+1)); printf '  PASS  24c.install-missing-env-flag-must-not-write-settings-json\n'
fi
rm -rf "$ROOT"

# Case 25 — install.sh refuses when settings.local.json is missing
# worktree.baseRef from the start.
ROOT="$(make_sandbox)"
write_sandbox_settings_local "$ROOT" "1" ""
set +e; INSTALL_OUT="$("$ROOT/scripts/hooks/install.sh" 2>&1 1>/dev/null)"; rc=$?; set -e
emit_case "25.install-missing-baseref-refuses" 2 "$rc"
if printf '%s' "$INSTALL_OUT" | grep -qF 'worktree.baseRef'; then
    PASS=$((PASS+1)); printf '  PASS  25b.install-missing-baseref-names-the-key\n'
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("25b.install-missing-baseref-names-the-key"); printf '  FAIL  25b.install-missing-baseref-names-the-key  (got: %s)\n' "$INSTALL_OUT"
fi
rm -rf "$ROOT"

# Case 26 — probe Layer I catches the env flag being removed AFTER a
# successful install (the true incident shape: hand-edit settings.local.json,
# no re-install yet).
ROOT="$(make_sandbox)"
set +e; "$ROOT/scripts/hooks/install.sh" >/dev/null 2>&1; set -e
python3 -c "
import json
p = '$ROOT/.claude/settings.local.json'
d = json.load(open(p))
del d['env']
json.dump(d, open(p, 'w'), indent=2)
"
set +e; PROBE_OUT="$(RICHOS_ENTITY_ROOT="$ROOT" "$ROOT/scripts/hooks/contract-integrity-probe.sh" 2>&1 1>/dev/null)"; rc=$?; set -e
emit_case "26.probe-catches-env-flag-removed-post-install" 2 "$rc"
if printf '%s' "$PROBE_OUT" | grep -qF 'CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS'; then
    PASS=$((PASS+1)); printf '  PASS  26b.probe-names-the-missing-env-flag\n'
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("26b.probe-names-the-missing-env-flag"); printf '  FAIL  26b.probe-names-the-missing-env-flag  (got: %s)\n' "$PROBE_OUT"
fi
rm -rf "$ROOT"

# Case 27 — probe Layer J catches worktree.baseRef being removed AFTER a
# successful install (same incident shape, the other critical key).
ROOT="$(make_sandbox)"
set +e; "$ROOT/scripts/hooks/install.sh" >/dev/null 2>&1; set -e
python3 -c "
import json
p = '$ROOT/.claude/settings.local.json'
d = json.load(open(p))
del d['worktree']
json.dump(d, open(p, 'w'), indent=2)
"
set +e; PROBE_OUT="$(RICHOS_ENTITY_ROOT="$ROOT" "$ROOT/scripts/hooks/contract-integrity-probe.sh" 2>&1 1>/dev/null)"; rc=$?; set -e
emit_case "27.probe-catches-baseref-removed-post-install" 2 "$rc"
if printf '%s' "$PROBE_OUT" | grep -qF 'worktree.baseRef'; then
    PASS=$((PASS+1)); printf '  PASS  27b.probe-names-the-missing-baseref\n'
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("27b.probe-names-the-missing-baseref"); printf '  FAIL  27b.probe-names-the-missing-baseref  (got: %s)\n' "$PROBE_OUT"
fi
rm -rf "$ROOT"

# Case 28 — POSITIVE-SHAPE: both keys correct -> the probe emits an explicit
# PASS line for EACH of Layer I, J, K (not just an overall rc=0).
ROOT="$(make_sandbox)"
set +e; "$ROOT/scripts/hooks/install.sh" >/dev/null 2>&1; set -e
set +e; PROBE_OUT="$(RICHOS_ENTITY_ROOT="$ROOT" "$ROOT/scripts/hooks/contract-integrity-probe.sh" 2>&1 1>/dev/null)"; rc=$?; set -e
emit_case "28.both-keys-correct-probe-passes" 0 "$rc"
if printf '%s' "$PROBE_OUT" | grep -qF 'I. env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS="1" present'; then
    PASS=$((PASS+1)); printf '  PASS  28b.layer-I-explicit-pass-line-present\n'
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("28b.layer-I-explicit-pass-line-present"); printf '  FAIL  28b.layer-I-explicit-pass-line-present  (got: %s)\n' "$PROBE_OUT"
fi
if printf '%s' "$PROBE_OUT" | grep -qF 'J. worktree.baseRef="head" present'; then
    PASS=$((PASS+1)); printf '  PASS  28c.layer-J-explicit-pass-line-present\n'
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("28c.layer-J-explicit-pass-line-present"); printf '  FAIL  28c.layer-J-explicit-pass-line-present  (got: %s)\n' "$PROBE_OUT"
fi
if printf '%s' "$PROBE_OUT" | grep -qF 'K. secrets scanner wired + REJECTS a planted secret and PASSES clean content'; then
    PASS=$((PASS+1)); printf '  PASS  28d.layer-K-explicit-pass-line-present\n'
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("28d.layer-K-explicit-pass-line-present"); printf '  FAIL  28d.layer-K-explicit-pass-line-present  (got: %s)\n' "$PROBE_OUT"
fi
if printf '%s' "$PROBE_OUT" | grep -qF 'M. registration uniqueness'; then
    PASS=$((PASS+1)); printf '  PASS  28e.layer-M-explicit-pass-line-present\n'
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("28e.layer-M-explicit-pass-line-present"); printf '  FAIL  28e.layer-M-explicit-pass-line-present  (got: %s)\n' "$PROBE_OUT"
fi
rm -rf "$ROOT"

# ---------------------------------------------------------------------------
# Layer K (secrets scanner) cases — missing wiring, tampered content, and the
# genuinely-broken-then-reinstalled case that hash-matching ALONE cannot catch
# (only the functional canary can).
# ---------------------------------------------------------------------------

# Case 29 — scan-secrets.sh NOT wired (dropped from the CANONICAL file, guard-
# main-checkout-writes.sh left alone) -> Layer K fails, names the scanner.
ROOT="$(make_sandbox)"
python3 - "$ROOT/.claude/settings.local.json" <<'PY'
import json, sys
p = sys.argv[1]
with open(p) as f: d = json.load(f)
for entry in d["hooks"]["PreToolUse"]:
    if "Write" in entry.get("matcher", ""):
        entry["hooks"] = [h for h in entry["hooks"] if "scan-secrets" not in h.get("command", "")]
with open(p, "w") as f: json.dump(d, f, indent=2)
PY
set +e; PROBE_OUT="$(RICHOS_ENTITY_ROOT="$ROOT" "$ROOT/scripts/hooks/contract-integrity-probe.sh" 2>&1 1>/dev/null)"; rc=$?; set -e
emit_case "29.secrets-scanner-not-wired-fails" 2 "$rc"
if printf '%s' "$PROBE_OUT" | grep -qF 'K. PreToolUse[Write|Edit|MultiEdit|NotebookEdit] secrets scanner (scan-secrets.sh) NOT wired'; then
    PASS=$((PASS+1)); printf '  PASS  29b.probe-names-the-missing-secrets-scanner\n'
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("29b.probe-names-the-missing-secrets-scanner"); printf '  FAIL  29b.probe-names-the-missing-secrets-scanner  (got: %s)\n' "$PROBE_OUT"
fi
rm -rf "$ROOT"

# Case 30 — scan-secrets.sh tampered (sidecar now stale) -> Layer K
# content-hash-mismatch fails.
ROOT="$(make_sandbox)"
printf '\n# tampered\n' >> "$ROOT/scripts/hooks/scan-secrets.sh"
set +e; PROBE_OUT="$(RICHOS_ENTITY_ROOT="$ROOT" "$ROOT/scripts/hooks/contract-integrity-probe.sh" 2>&1 1>/dev/null)"; rc=$?; set -e
emit_case "30.secrets-scanner-tampered-fails" 2 "$rc"
if printf '%s' "$PROBE_OUT" | grep -qF 'K. secrets-scanner content hash mismatch'; then
    PASS=$((PASS+1)); printf '  PASS  30b.probe-names-the-hash-mismatch\n'
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("30b.probe-names-the-hash-mismatch"); printf '  FAIL  30b.probe-names-the-hash-mismatch  (got: %s)\n' "$PROBE_OUT"
fi
rm -rf "$ROOT"

# Case 31 — scan-secrets.sh genuinely broken (edited into a no-op) THEN
# install.sh re-run, which regenerates the sidecar to MATCH the broken content.
# Hash-matching alone would now wrongly pass — only the functional canary
# (Layer K feeding it a known-bad secret) catches this.
ROOT="$(make_sandbox)"
cat >"$ROOT/scripts/hooks/scan-secrets.sh" <<'NOOP_SH'
#!/usr/bin/env bash
# Adversarial no-op: accepts everything, even an obvious secret.
exit 0
NOOP_SH
chmod +x "$ROOT/scripts/hooks/scan-secrets.sh"
"$ROOT/scripts/hooks/install.sh" >/dev/null
set +e; PROBE_OUT="$(RICHOS_ENTITY_ROOT="$ROOT" "$ROOT/scripts/hooks/contract-integrity-probe.sh" 2>&1 1>/dev/null)"; rc=$?; set -e
emit_case "31.secrets-scanner-broken-then-reinstalled-fails" 2 "$rc"
if printf '%s' "$PROBE_OUT" | grep -qF 'K. wired secrets scanner did NOT block a known-bad secret'; then
    PASS=$((PASS+1)); printf '  PASS  31b.functional-canary-catches-broken-scanner-despite-matching-hash\n'
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("31b.functional-canary-catches-broken-scanner-despite-matching-hash"); printf '  FAIL  31b.functional-canary-catches-broken-scanner-despite-matching-hash  (got: %s)\n' "$PROBE_OUT"
fi
rm -rf "$ROOT"

# Case 31c/31d — THE DEAD SCANNER. The case Layer K could not see until it grew
# a second side, and the reason it exists.
#
# scan-secrets.sh refuses to start without scripts/lib/seat-jurisdiction.sh by
# EXITING 2. Layer K's canary asserted the scanner exits 2 on a planted secret.
# Same number, opposite meanings — so a scanner that never executed satisfied
# the layer completely, and did so in both engine sandboxes for as long as those
# sandbox file lists had existed. Case 31 above cannot catch it: that scanner is
# a no-op that exits 0, this one never runs at all.
#
# 31c requires the probe to FAIL, and 31d requires it to say the true thing —
# "it is not scanning, it is failing to start" — rather than the misleading
# "did NOT block a known-bad secret", which would send a reader to audit
# detectors in a scanner that had not run a line.
#
# Note what this deliberately does NOT touch: the hook is byte-identical and its
# sidecar matches. Every hash check in Layer K passes. Only the second canary
# separates a guard that is READING from one that is merely refusing.
ROOT="$(make_sandbox)"
rm -f "$ROOT/scripts/lib/seat-jurisdiction.sh"
set +e; PROBE_OUT="$(RICHOS_ENTITY_ROOT="$ROOT" "$ROOT/scripts/hooks/contract-integrity-probe.sh" 2>&1 1>/dev/null)"; rc=$?; set -e
emit_case "31c.dead-secrets-scanner-fails-layer-K" 2 "$rc"
if printf '%s' "$PROBE_OUT" | grep -qF 'K. the secrets scanner refused BOTH a planted secret and content with no secret in it'; then
    PASS=$((PASS+1)); printf '  PASS  31d.layer-K-says-failing-to-start-not-failing-to-catch\n'
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("31d.layer-K-says-failing-to-start-not-failing-to-catch"); printf '  FAIL  31d.layer-K-says-failing-to-start-not-failing-to-catch  (got: %s)\n' "$PROBE_OUT"
fi
rm -rf "$ROOT"

# ---------------------------------------------------------------------------
# Layer P — the definition-drift guard PAIR. Either half alone is useless: with
# no SessionStart snapshot the PreToolUse guard has nothing to compare against,
# fails OPEN by design, and never blocks — silently. So the probe must FAIL when
# EITHER half is unwired, tampered, gutted, or duplicated, and must visibly PASS
# when both are intact.
# ---------------------------------------------------------------------------

# Case 34 — POSITIVE probe: an intact sandbox emits the Layer P PASS line.
ROOT="$(make_sandbox)"
set +e; PROBE_OUT="$(run_probe_in "$ROOT")"; rc=$?; set -e
emit_case "34.definition-drift-pair-intact-probe-rc-0" 0 "$rc"
if printf '%s' "$PROBE_OUT" | grep -qF 'P. definition-drift pair wired exactly once'; then
    PASS=$((PASS+1)); printf '  PASS  34b.layer-P-pass-line-present\n'
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("34b.layer-P-pass-line-present"); printf '  FAIL  34b.layer-P-pass-line-present  (got: %s)\n' "$PROBE_OUT"
fi
rm -rf "$ROOT"

# Case 35 — ONLY the SessionStart snapshotter unwired (the Agent chain is
# untouched, so Layer C still passes) -> Layer P alone must fail. The isolation
# case: it proves Layer P catches the silent half of the pair.
ROOT="$(make_sandbox)"
python3 - "$ROOT/.claude/settings.local.json" <<'PY'
import json, sys
p = sys.argv[1]
with open(p) as f: d = json.load(f)
d["hooks"]["SessionStart"] = [
    e for e in d["hooks"]["SessionStart"]
    if not any("snapshot-agent-definitions" in h.get("command", "") for h in e.get("hooks", []))
]
with open(p, "w") as f: json.dump(d, f, indent=2)
PY
set +e; PROBE_OUT="$(run_probe_in "$ROOT")"; rc=$?; set -e
emit_case "35.definition-snapshotter-unwired-fails-layerP" 2 "$rc"
if printf '%s' "$PROBE_OUT" | grep -qF 'snapshot-agent-definitions.sh) NOT wired'; then
    PASS=$((PASS+1)); printf '  PASS  35b.layer-P-names-the-missing-snapshotter\n'
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("35b.layer-P-names-the-missing-snapshotter"); printf '  FAIL  35b.layer-P-names-the-missing-snapshotter  (got: %s)\n' "$PROBE_OUT"
fi
rm -rf "$ROOT"

# Case 36 — the PreToolUse[Agent] drift guard unwired -> probe fails (Layers C+P).
ROOT="$(make_sandbox)"
python3 - "$ROOT/.claude/settings.local.json" <<'PY'
import json, sys
p = sys.argv[1]
with open(p) as f: d = json.load(f)
for entry in d["hooks"]["PreToolUse"]:
    if entry.get("matcher") == "Agent":
        entry["hooks"] = [h for h in entry["hooks"]
                          if "guard-definition-drift" not in h.get("command", "")]
with open(p, "w") as f: json.dump(d, f, indent=2)
PY
set +e; run_probe_in "$ROOT" >/dev/null 2>&1; rc=$?; set -e
emit_case "36.definition-drift-guard-unwired-fails" 2 "$rc"
rm -rf "$ROOT"

# Case 37 — drift guard tampered (hash != sidecar) -> fails.
ROOT="$(make_sandbox)"
printf '\n# tamper — no longer matches the minted sidecar\n' >> "$ROOT/scripts/hooks/guard-definition-drift.sh"
set +e; run_probe_in "$ROOT" >/dev/null 2>&1; rc=$?; set -e
emit_case "37.definition-drift-guard-tampered-fails" 2 "$rc"
rm -rf "$ROOT"

# Case 37b — SessionStart snapshotter tampered (hash != sidecar) -> fails. The
# snapshotter is not in the Agent chain, so ONLY Layer P can catch this.
ROOT="$(make_sandbox)"
printf '\n# tamper — no longer matches the minted sidecar\n' >> "$ROOT/scripts/hooks/snapshot-agent-definitions.sh"
set +e; run_probe_in "$ROOT" >/dev/null 2>&1; rc=$?; set -e
emit_case "37b.definition-snapshotter-tampered-fails-layerP" 2 "$rc"
rm -rf "$ROOT"

# Case 38 — drift guard gutted into an always-allow no-op AND its sidecar
# refreshed to match, so ONLY the functional block-canary can catch it.
ROOT="$(make_sandbox)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$ROOT/scripts/hooks/guard-definition-drift.sh"
chmod +x "$ROOT/scripts/hooks/guard-definition-drift.sh"
shasum -a 256 "$ROOT/scripts/hooks/guard-definition-drift.sh" | awk '{print $1}' > "$ROOT/scripts/hooks/guard-definition-drift.sh.sha256"
set +e; run_probe_in "$ROOT" >/dev/null 2>&1; rc=$?; set -e
emit_case "38.definition-drift-guard-gutted-fails-layerP-canary" 2 "$rc"
rm -rf "$ROOT"

# Case 38b — drift guard turned into an always-BLOCK no-op (sidecar refreshed):
# the ALLOW-canary must catch the over-block, which a negative-only test never
# would. The "negative tests need a positive probe" pairing.
ROOT="$(make_sandbox)"
printf '#!/usr/bin/env bash\nexit 2\n' > "$ROOT/scripts/hooks/guard-definition-drift.sh"
chmod +x "$ROOT/scripts/hooks/guard-definition-drift.sh"
shasum -a 256 "$ROOT/scripts/hooks/guard-definition-drift.sh" | awk '{print $1}' > "$ROOT/scripts/hooks/guard-definition-drift.sh.sha256"
set +e; PROBE_OUT="$(run_probe_in "$ROOT")"; rc=$?; set -e
emit_case "38b.definition-drift-guard-overblocks-fails-layerP-canary" 2 "$rc"
if printf '%s' "$PROBE_OUT" | grep -qF 'blocked an UNCHANGED definition'; then
    PASS=$((PASS+1)); printf '  PASS  38c.layer-P-names-the-over-block\n'
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("38c.layer-P-names-the-over-block"); printf '  FAIL  38c.layer-P-names-the-over-block  (got: %s)\n' "$PROBE_OUT"
fi
rm -rf "$ROOT"

# Case 39 — snapshotter registered TWICE (double-fire) -> fails (Layers M+P).
ROOT="$(make_sandbox)"
python3 - "$ROOT/.claude/settings.local.json" <<'PY'
import json, sys
p = sys.argv[1]
with open(p) as f: d = json.load(f)
ss = d["hooks"]["SessionStart"]
dup = [e for e in ss
       if any("snapshot-agent-definitions" in h.get("command", "") for h in e.get("hooks", []))]
d["hooks"]["SessionStart"] = ss + [json.loads(json.dumps(dup[0]))]
with open(p, "w") as f: json.dump(d, f, indent=2)
PY
set +e; run_probe_in "$ROOT" >/dev/null 2>&1; rc=$?; set -e
emit_case "39.definition-snapshotter-duplicated-fails" 2 "$rc"
rm -rf "$ROOT"

# Case 40 — the pair's OWN behavioral suite (block/allow/ack/created/missing/
# cross-session/dedup/e2e) passes against the live scripts.
set +e; "$SCRIPT_DIR/guard-definition-drift.test.sh" >/dev/null 2>&1; rc=$?; set -e
emit_case "40.definition-drift-guard-suite-passes" 0 "$rc"

# ---------------------------------------------------------------------------
# Layer Q — the SessionStart WORKTREE-REAPER CHAIN. Two halves: the wrapper
# (session-start-reap-worktrees.sh, wired under SessionStart) and the script it
# runs with --execute (scripts/reap-stale-worktrees.sh — the only hook-reachable
# code that deletes worktrees and branches). Both of its failure modes are
# silent, so the probe must fail on BOTH: sweeping nothing, and sweeping
# something it must not.
# ---------------------------------------------------------------------------

# Case 41 — POSITIVE probe: an intact sandbox emits the Layer Q PASS line.
ROOT="$(make_sandbox)"
set +e; PROBE_OUT="$(run_probe_in "$ROOT")"; rc=$?; set -e
emit_case "41.reaper-chain-intact-probe-rc-0" 0 "$rc"
if printf '%s' "$PROBE_OUT" | grep -qF 'Q. worktree-reaper chain wired exactly once'; then
    PASS=$((PASS+1)); printf '  PASS  41b.layer-Q-pass-line-present\n'
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("41b.layer-Q-pass-line-present"); printf '  FAIL  41b.layer-Q-pass-line-present  (got: %s)\n' "$PROBE_OUT"
fi
rm -rf "$ROOT"

# Case 42 — the SessionStart wrapper unwired -> Layer Q fails and names it. No
# other layer looks at this stanza, so this is the isolation case.
ROOT="$(make_sandbox)"
python3 - "$ROOT/.claude/settings.local.json" <<'PY'
import json, sys
p = sys.argv[1]
with open(p) as f: d = json.load(f)
d["hooks"]["SessionStart"] = [
    e for e in d["hooks"]["SessionStart"]
    if not any("session-start-reap-worktrees" in h.get("command", "") for h in e.get("hooks", []))
]
with open(p, "w") as f: json.dump(d, f, indent=2)
PY
set +e; PROBE_OUT="$(run_probe_in "$ROOT")"; rc=$?; set -e
emit_case "42.reaper-wrapper-unwired-fails-layerQ" 2 "$rc"
if printf '%s' "$PROBE_OUT" | grep -qF 'session-start-reap-worktrees.sh) NOT wired'; then
    PASS=$((PASS+1)); printf '  PASS  42b.layer-Q-names-the-missing-wrapper\n'
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("42b.layer-Q-names-the-missing-wrapper"); printf '  FAIL  42b.layer-Q-names-the-missing-wrapper\n'
fi
rm -rf "$ROOT"

# Case 43 — wrapper tampered (hash != sidecar) -> fails. The wrapper is in no
# PreToolUse chain, so ONLY Layer Q can catch this.
ROOT="$(make_sandbox)"
printf '\n# tamper — no longer matches the minted sidecar\n' >> "$ROOT/scripts/hooks/session-start-reap-worktrees.sh"
set +e; run_probe_in "$ROOT" >/dev/null 2>&1; rc=$?; set -e
emit_case "43.reaper-wrapper-tampered-fails-layerQ" 2 "$rc"
rm -rf "$ROOT"

# Case 44 — the REAPER ITSELF tampered (hash != sidecar) -> fails. This is the
# half that deletes work, and it lives outside scripts/hooks/.
ROOT="$(make_sandbox)"
printf '\n# tamper — no longer matches the minted sidecar\n' >> "$ROOT/scripts/reap-stale-worktrees.sh"
set +e; run_probe_in "$ROOT" >/dev/null 2>&1; rc=$?; set -e
emit_case "44.reaper-script-tampered-fails-layerQ" 2 "$rc"
rm -rf "$ROOT"

# Case 44b — the reaper's sidecar MISSING entirely (a wired hook with no
# manifest and therefore no coverage) must be loud, not silent.
ROOT="$(make_sandbox)"
rm -f "$ROOT/scripts/reap-stale-worktrees.sh.sha256"
set +e; PROBE_OUT="$(run_probe_in "$ROOT")"; rc=$?; set -e
emit_case "44b.reaper-sidecar-missing-fails-layerQ" 2 "$rc"
if printf '%s' "$PROBE_OUT" | grep -qF 'Q. reaper manifest missing'; then
    PASS=$((PASS+1)); printf '  PASS  44c.layer-Q-names-the-missing-manifest\n'
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("44c.layer-Q-names-the-missing-manifest"); printf '  FAIL  44c.layer-Q-names-the-missing-manifest\n'
fi
rm -rf "$ROOT"

# Case 45 — reaper GUTTED into a no-op that still prints a plausible summary,
# with its sidecar refreshed to match: only the sweep canary can catch it. This
# is the silent regression that recreates the stale-worktree backlog.
ROOT="$(make_sandbox)"
cat > "$ROOT/scripts/reap-stale-worktrees.sh" <<'GUTTED'
#!/usr/bin/env bash
echo "=== summary (EXECUTE): reaped=0 skipped=0 errors=0 residue=0 ==="
exit 0
GUTTED
chmod +x "$ROOT/scripts/reap-stale-worktrees.sh"
shasum -a 256 "$ROOT/scripts/reap-stale-worktrees.sh" | awk '{print $1}' > "$ROOT/scripts/reap-stale-worktrees.sh.sha256"
set +e; PROBE_OUT="$(run_probe_in "$ROOT")"; rc=$?; set -e
emit_case "45.reaper-gutted-fails-layerQ-canary" 2 "$rc"
if printf '%s' "$PROBE_OUT" | grep -qF 'did NOT remove a merged, clean, unlocked sandbox worktree'; then
    PASS=$((PASS+1)); printf '  PASS  45b.layer-Q-names-the-gutted-sweep\n'
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("45b.layer-Q-names-the-gutted-sweep"); printf '  FAIL  45b.layer-Q-names-the-gutted-sweep\n'
fi
rm -rf "$ROOT"

# Case 45c — reaper turned into an OVER-REACHING remover that force-removes
# every agent worktree (sidecar refreshed) and reports a plausible summary. The
# sweep canary alone would pass it; only the protective canary catches the data
# loss. ("Negative tests need a positive probe" — and vice versa.)
ROOT="$(make_sandbox)"
cat > "$ROOT/scripts/reap-stale-worktrees.sh" <<'OVERREACH'
#!/usr/bin/env bash
ROOT="$1"
for d in "$ROOT"/.claude/worktrees/agent-*; do
    [ -d "$d" ] || continue
    git -C "$ROOT" worktree remove --force "$d" >/dev/null 2>&1
done
echo "=== summary (EXECUTE): reaped=1 skipped=1 errors=0 residue=0 ==="
exit 0
OVERREACH
chmod +x "$ROOT/scripts/reap-stale-worktrees.sh"
shasum -a 256 "$ROOT/scripts/reap-stale-worktrees.sh" | awk '{print $1}' > "$ROOT/scripts/reap-stale-worktrees.sh.sha256"
set +e; PROBE_OUT="$(run_probe_in "$ROOT")"; rc=$?; set -e
emit_case "45c.reaper-overreaches-fails-layerQ-canary" 2 "$rc"
if printf '%s' "$PROBE_OUT" | grep -qF 'REMOVED a sandbox worktree carrying uncommitted work'; then
    PASS=$((PASS+1)); printf '  PASS  45d.layer-Q-names-the-destroyed-work\n'
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("45d.layer-Q-names-the-destroyed-work"); printf '  FAIL  45d.layer-Q-names-the-destroyed-work\n'
fi
rm -rf "$ROOT"

# Case 46 — wrapper registered TWICE under SessionStart (two concurrent
# --execute sweeps of the same worktree set) -> fails (Layers M+Q).
ROOT="$(make_sandbox)"
python3 - "$ROOT/.claude/settings.local.json" <<'PY'
import json, sys
p = sys.argv[1]
with open(p) as f: d = json.load(f)
ss = d["hooks"]["SessionStart"]
dup = [e for e in ss
       if any("session-start-reap-worktrees" in h.get("command", "") for h in e.get("hooks", []))]
d["hooks"]["SessionStart"] = ss + [json.loads(json.dumps(dup[0]))]
with open(p, "w") as f: json.dump(d, f, indent=2)
PY
set +e; run_probe_in "$ROOT" >/dev/null 2>&1; rc=$?; set -e
emit_case "46.reaper-wrapper-duplicated-fails" 2 "$rc"
rm -rf "$ROOT"

# Case 47 — install.sh mints sidecars for BOTH halves of the chain, including
# the one managed script that does not live under scripts/hooks/.
ROOT="$(make_sandbox)"
rm -f "$ROOT/scripts/hooks/session-start-reap-worktrees.sh.sha256" \
      "$ROOT/scripts/hooks/agent-finished-reap-worktrees.sh.sha256" \
      "$ROOT/scripts/reap-stale-worktrees.sh.sha256"
"$ROOT/scripts/hooks/install.sh" >/dev/null
MINTED=1
for f in "$ROOT/scripts/hooks/session-start-reap-worktrees.sh" \
         "$ROOT/scripts/hooks/agent-finished-reap-worktrees.sh" \
         "$ROOT/scripts/reap-stale-worktrees.sh"; do
    [ -f "$f.sha256" ] || MINTED=0
    [ "$(shasum -a 256 "$f" | awk '{print $1}')" = "$(awk 'NR==1{print $1}' "$f.sha256" 2>/dev/null)" ] || MINTED=0
done
if [ "$MINTED" = "1" ]; then
    PASS=$((PASS+1)); printf '  PASS  47.install-mints-reaper-chain-sidecars\n'
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("47.install-mints-reaper-chain-sidecars"); printf '  FAIL  47.install-mints-reaper-chain-sidecars\n'
fi
set +e; run_probe_in "$ROOT" >/dev/null 2>&1; rc=$?; set -e
emit_case "47b.post-install-probe-passes" 0 "$rc"
rm -rf "$ROOT"

# Case 48 — the wrapper's OWN behavioral suite (reap/skip gates, fail-open,
# JSON shape, idempotence) passes against the live scripts.
set +e; "$SCRIPT_DIR/session-start-reap-worktrees.test.sh" >/dev/null 2>&1; rc=$?; set -e
emit_case "48.reaper-wrapper-suite-passes" 0 "$rc"

# ---------------------------------------------------------------------------
# Layer Q, the SCOPE half — cases 49-54.
#
# Every case from 41 to 48 is ONE repository holding ONLY native `agent-*`
# worktrees. All of them were green on 2026-09-01, the morning the reaper
# printed `reaped=1 skipped=0 errors=0 residue=0` while 25 worktrees sat
# unswept all day in two OTHER repositories under the hand-rolled convention
# the project's doctrine requires for cross-repository work. They could not
# have caught it: they only ever ask whether the reaper still does the thing it
# already did.
#
# These six ask the questions that go red when it GOES BLIND, when the second
# trigger becomes a corpse, and when it stops sparing a live agent's worktree.
# ---------------------------------------------------------------------------

# Case 49 — the agent-finish trigger unregistered from BOTH its events. Nothing
# else looks at those stanzas. Without it the chain still runs and still
# reports, and can never decide a hand-rolled worktree at all, because the
# owner's isolation worktree — the only liveness evidence a lockless tree has —
# is gone by the time a session start comes around.
ROOT="$(make_sandbox)"
python3 - "$ROOT/hooks/hooks.json" <<'PY'
import json, sys
p = sys.argv[1]
with open(p) as f: d = json.load(f)
for ev in ("TeammateIdle", "TaskCompleted"):
    for entry in d["hooks"].get(ev, []):
        entry["hooks"] = [h for h in entry.get("hooks", [])
                          if "agent-finished-reap-worktrees" not in h.get("command", "")]
with open(p, "w") as f: json.dump(d, f, indent=2)
PY
set +e; PROBE_OUT="$(run_probe_in "$ROOT")"; rc=$?; set -e
emit_case "49.agent-finish-trigger-unregistered-fails-layerQ" 2 "$rc"
if printf '%s' "$PROBE_OUT" | grep -qF 'wired 0x on TeammateIdle and 0x on TaskCompleted'; then
    PASS=$((PASS+1)); printf '  PASS  49b.layer-Q-names-the-missing-agent-finish-trigger\n'
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("49b.layer-Q-names-the-missing-agent-finish-trigger"); printf '  FAIL  49b.layer-Q-names-the-missing-agent-finish-trigger\n'
fi
rm -rf "$ROOT"

# Case 50 — the agent-finish wrapper GUTTED into a registered no-op, sidecar
# refreshed. Case 49 proves the registration is checked; a registration is not
# a sweep, and "wired, hashed and doing nothing" is the exact shape that kept
# Layer K green over a scanner that never ran.
ROOT="$(make_sandbox)"
cat > "$ROOT/scripts/hooks/agent-finished-reap-worktrees.sh" <<'GUTTEDFINISH'
#!/usr/bin/env bash
# gutted: resolves everything, sweeps nothing, exits 0 forever
exit 0
GUTTEDFINISH
chmod +x "$ROOT/scripts/hooks/agent-finished-reap-worktrees.sh"
shasum -a 256 "$ROOT/scripts/hooks/agent-finished-reap-worktrees.sh" | awk '{print $1}' \
    > "$ROOT/scripts/hooks/agent-finished-reap-worktrees.sh.sha256"
set +e; PROBE_OUT="$(run_probe_in "$ROOT")"; rc=$?; set -e
emit_case "50.agent-finish-trigger-gutted-fails-layerQ5" 2 "$rc"
if printf '%s' "$PROBE_OUT" | grep -qF 'it is registered and sweeps nothing'; then
    PASS=$((PASS+1)); printf '  PASS  50b.layer-Q5-names-the-registered-corpse\n'
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("50b.layer-Q5-names-the-registered-corpse"); printf '  FAIL  50b.layer-Q5-names-the-registered-corpse\n'
fi
rm -rf "$ROOT"

# Case 51 — THE ONE THAT MATTERS. The owner-liveness gate removed from the
# reaper, sidecar refreshed. The reaper still sweeps, still refuses dirty and
# unmerged trees, and Layer Q's original canary stays green — while a LIVE
# agent's hand-rolled worktree is now selected for removal, taking its
# uncommitted work with it. Only Q4 can see this.
ROOT="$(make_sandbox)"
python3 - "$ROOT/scripts/reap-stale-worktrees.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '        if [ "$class" = "hand-rolled" ]; then\n            owner="$branch_name"'
assert old in s, "owner-liveness gate anchor not found — this mutation no longer mutates anything"
open(p, "w").write(s.replace(old, '        if false; then\n            owner="$branch_name"', 1))
PY
shasum -a 256 "$ROOT/scripts/reap-stale-worktrees.sh" | awk '{print $1}' > "$ROOT/scripts/reap-stale-worktrees.sh.sha256"
set +e; PROBE_OUT="$(run_probe_in "$ROOT")"; rc=$?; set -e
emit_case "51.owner-liveness-gate-removed-fails-layerQ4" 2 "$rc"
if printf '%s' "$PROBE_OUT" | grep -qF "a LIVE agent's hand-rolled worktree was SELECTED FOR REMOVAL"; then
    PASS=$((PASS+1)); printf '  PASS  51b.layer-Q4-names-the-live-worktree-selected\n'
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("51b.layer-Q4-names-the-live-worktree-selected"); printf '  FAIL  51b.layer-Q4-names-the-live-worktree-selected\n'
fi
if printf '%s' "$PROBE_OUT" | grep -qF 'Q. worktree-reaper chain wired exactly once'; then
    PASS=$((PASS+1)); printf '  PASS  51c.original-layer-Q-canary-stays-GREEN-over-the-same-defect\n'
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("51c.original-layer-Q-canary-stays-GREEN-over-the-same-defect"); printf '  FAIL  51c.original-layer-Q-canary-stays-GREEN-over-the-same-defect\n'
fi
rm -rf "$ROOT"

# Case 52 — DISCOVERY removed, sidecar refreshed. The reaper is back to one
# repository: exactly the state that reported success all day. Q4a is the check
# that goes red when it goes blind, which is the property Layer Q did not have.
ROOT="$(make_sandbox)"
python3 - "$ROOT/scripts/reap-stale-worktrees.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'if [ "$DISCOVER" -eq 1 ]; then\n    # --- engine:'
assert old in s, "discovery anchor not found — this mutation no longer mutates anything"
open(p, "w").write(s.replace(old, 'if false; then\n    # --- engine:', 1))
PY
shasum -a 256 "$ROOT/scripts/reap-stale-worktrees.sh" | awk '{print $1}' > "$ROOT/scripts/reap-stale-worktrees.sh.sha256"
set +e; PROBE_OUT="$(run_probe_in "$ROOT")"; rc=$?; set -e
emit_case "52.discovery-removed-fails-layerQ4" 2 "$rc"
if printf '%s' "$PROBE_OUT" | grep -qF 'the sibling repository was never swept'; then
    PASS=$((PASS+1)); printf '  PASS  52b.layer-Q4-names-the-blind-sweep\n'
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("52b.layer-Q4-names-the-blind-sweep"); printf '  FAIL  52b.layer-Q4-names-the-blind-sweep\n'
fi
rm -rf "$ROOT"

# Case 53 — the reaper's OWN scope/safety suite (discovery, the owner-liveness
# rule including the absence case, report-only repositories, the ledger, the
# container rule) passes against the live scripts.
set +e; "$SCRIPT_DIR/../reap-stale-worktrees.test.sh" >/dev/null 2>&1; rc=$?; set -e
emit_case "53.reaper-scope-and-safety-suite-passes" 0 "$rc"

# Case 54 — the agent-finish wrapper's OWN behavioral suite passes.
set +e; "$SCRIPT_DIR/agent-finished-reap-worktrees.test.sh" >/dev/null 2>&1; rc=$?; set -e
emit_case "54.agent-finish-wrapper-suite-passes" 0 "$rc"

# ---------------------------------------------------------------------------
# Layer S — the worktree-removal PAIR (guard + sanctioned helper)
# ---------------------------------------------------------------------------
# Four ways the pair can be broken, each of which leaves a live agent's worktree
# removable by a raw command, or leaves the guard with no escape route. The
# positive baseline is already covered by cases 1/2 (the committed source and a
# post-install sandbox both pass, and both now include Layer S).

# S1 — the guard is not wired at all.
ROOT="$(make_sandbox)"
python3 - "$ROOT/.claude/settings.local.json" <<'PY'
import json, sys
p = sys.argv[1]
with open(p) as f: d = json.load(f)
for entry in d["hooks"]["PreToolUse"]:
    if entry.get("matcher") == "Bash":
        entry["hooks"] = [h for h in entry["hooks"]
                          if "guard-worktree-removal.sh" not in h.get("command", "")]
with open(p, "w") as f: json.dump(d, f, indent=2)
PY
set +e; S_OUT="$(run_probe_in "$ROOT" 2>&1)"; rc=$?; set -e
emit_case "S1.worktree-removal-guard-not-wired-fails" 2 "$rc"
if printf '%s' "$S_OUT" | grep -q 'S\. PreToolUse\[Bash\] worktree-removal guard'; then
    PASS=$((PASS+1)); printf '  PASS  %s\n' "S1b.layer-S-is-the-layer-that-caught-it"
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("S1b.layer-S-is-the-layer-that-caught-it")
    printf '  FAIL  %s  (some other layer absorbed it)\n' "S1b.layer-S-is-the-layer-that-caught-it"
fi
rm -rf "$ROOT"

# S2 — wired TWICE. Hook sources merge additively, so it fires twice per Bash
# call and every ack-log line is duplicated.
ROOT="$(make_sandbox)"
python3 - "$ROOT/.claude/settings.local.json" <<'PY'
import json, sys
p = sys.argv[1]
with open(p) as f: d = json.load(f)
for entry in d["hooks"]["PreToolUse"]:
    if entry.get("matcher") == "Bash":
        dup = [h for h in entry["hooks"] if "guard-worktree-removal.sh" in h.get("command", "")]
        entry["hooks"].extend(dup)
with open(p, "w") as f: json.dump(d, f, indent=2)
PY
set +e; run_probe_in "$ROOT" >/dev/null 2>&1; rc=$?; set -e
emit_case "S2.worktree-removal-guard-wired-twice-fails" 2 "$rc"
rm -rf "$ROOT"

# S3 — the guard is gutted into a no-op. It is still wired, still present, and
# its hash no longer matches; the canary would also catch it if the hash did not.
ROOT="$(make_sandbox)"
cat >"$ROOT/scripts/hooks/guard-worktree-removal.sh" <<'NOOP_SH'
#!/usr/bin/env bash
exit 0
NOOP_SH
chmod +x "$ROOT/scripts/hooks/guard-worktree-removal.sh"
set +e; run_probe_in "$ROOT" >/dev/null 2>&1; rc=$?; set -e
emit_case "S3.gutted-worktree-removal-guard-fails" 2 "$rc"
rm -rf "$ROOT"

# S4 — THE PAIR SPLIT. The guard is perfect; its sanctioned helper is gone. This
# is the case the layer exists for and the one a hooks-directory-shaped sweep
# would miss entirely: the helper is not a hook and does not live in
# scripts/hooks/. A guard whose only documented way through does not exist stops
# being a gate and becomes a prompt to reach for the ack override.
ROOT="$(make_sandbox)"
rm -f "$ROOT/scripts/remove-agent-worktree.sh"
set +e; S_OUT="$(run_probe_in "$ROOT" 2>&1)"; rc=$?; set -e
emit_case "S4.sanctioned-helper-missing-fails" 2 "$rc"
if printf '%s' "$S_OUT" | grep -q 'sanctioned removal helper is MISSING'; then
    PASS=$((PASS+1)); printf '  PASS  %s\n' "S4b.layer-S-names-the-missing-helper"
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("S4b.layer-S-names-the-missing-helper")
    printf '  FAIL  %s\n' "S4b.layer-S-names-the-missing-helper"
fi
rm -rf "$ROOT"

# ---------------------------------------------------------------------------
# Layer IP — the interactive-prompt guard and its shape table
# ---------------------------------------------------------------------------
# Six ways the pair can be broken, each of which reopens the hole that put a
# macOS password window on the CEO's screen at 02:01 on 2026-09-01. The positive
# baseline is covered by cases 1/2, which now include Layer IP.
#
# IP5 is the case worth reading. This guard exits 2 to refuse and 2 when it
# cannot start, so a one-sided canary would be satisfied by a corpse — the exact
# way Layer K stayed green over a dead secrets scanner. The two-sided canary is
# what makes IP5 possible, and IP5 is what proves the two-sided canary is real.

# IP1 — the guard is not wired at all.
ROOT="$(make_sandbox)"
python3 - "$ROOT/.claude/settings.local.json" <<'PY'
import json, sys
p = sys.argv[1]
with open(p) as f: d = json.load(f)
for entry in d["hooks"]["PreToolUse"]:
    if entry.get("matcher") == "Bash":
        entry["hooks"] = [h for h in entry["hooks"]
                          if "guard-interactive-prompt.sh" not in h.get("command", "")]
with open(p, "w") as f: json.dump(d, f, indent=2)
PY
set +e; IP_OUT="$(run_probe_in "$ROOT" 2>&1)"; rc=$?; set -e
emit_case "IP1.interactive-prompt-guard-not-wired-fails" 2 "$rc"
if printf '%s' "$IP_OUT" | grep -q 'IP\. PreToolUse\[Bash\] interactive-prompt guard'; then
    PASS=$((PASS+1)); printf '  PASS  %s\n' "IP1b.layer-IP-is-the-layer-that-caught-it"
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("IP1b.layer-IP-is-the-layer-that-caught-it")
    printf '  FAIL  %s  (some other layer absorbed it)\n' "IP1b.layer-IP-is-the-layer-that-caught-it"
fi
rm -rf "$ROOT"

# IP2 — wired TWICE. Hook sources merge additively, so the same missing -P is
# reported as two separate hazards in one command line.
ROOT="$(make_sandbox)"
python3 - "$ROOT/.claude/settings.local.json" <<'PY'
import json, sys
p = sys.argv[1]
with open(p) as f: d = json.load(f)
for entry in d["hooks"]["PreToolUse"]:
    if entry.get("matcher") == "Bash":
        dup = [h for h in entry["hooks"] if "guard-interactive-prompt.sh" in h.get("command", "")]
        entry["hooks"].extend(dup)
with open(p, "w") as f: json.dump(d, f, indent=2)
PY
set +e; run_probe_in "$ROOT" >/dev/null 2>&1; rc=$?; set -e
emit_case "IP2.interactive-prompt-guard-wired-twice-fails" 2 "$rc"
rm -rf "$ROOT"

# IP3 — the guard is gutted into a no-op. Still wired, still present; the hash
# catches it, and the canary would too if the hash did not.
ROOT="$(make_sandbox)"
cat >"$ROOT/scripts/hooks/guard-interactive-prompt.sh" <<'NOOP_SH'
#!/usr/bin/env bash
exit 0
NOOP_SH
chmod +x "$ROOT/scripts/hooks/guard-interactive-prompt.sh"
set +e; run_probe_in "$ROOT" >/dev/null 2>&1; rc=$?; set -e
emit_case "IP3.gutted-interactive-prompt-guard-fails" 2 "$rc"
rm -rf "$ROOT"

# IP4 — THE PAIR SPLIT. The guard is perfect; the shape table it takes every
# decision from is gone. Like Layer S's helper and Layer T's vocabulary, the
# table is not a hook and does not live in scripts/hooks/, so a directory-shaped
# sweep misses it entirely.
ROOT="$(make_sandbox)"
rm -f "$ROOT/scripts/lib/interactive-prompt.py" "$ROOT/scripts/lib/interactive-prompt.py.sha256"
set +e; IP_OUT="$(run_probe_in "$ROOT" 2>&1)"; rc=$?; set -e
emit_case "IP4.shape-table-missing-fails" 2 "$rc"
if printf '%s' "$IP_OUT" | grep -q 'the shape table is MISSING'; then
    PASS=$((PASS+1)); printf '  PASS  %s\n' "IP4b.layer-IP-names-the-missing-shape-table"
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("IP4b.layer-IP-names-the-missing-shape-table")
    printf '  FAIL  %s\n' "IP4b.layer-IP-names-the-missing-shape-table"
fi
rm -rf "$ROOT"

# IP5 — A DEAD GUARD, WHOSE CORPSE EXITS 2. This is the failure a one-sided
# canary cannot see: refusing everything looks identical to refusing the right
# thing. Layer IP must say it is failing to START, not failing to catch.
ROOT="$(make_sandbox)"
cat >"$ROOT/scripts/hooks/guard-interactive-prompt.sh" <<'DEAD_SH'
#!/usr/bin/env bash
exit 2
DEAD_SH
chmod +x "$ROOT/scripts/hooks/guard-interactive-prompt.sh"
shasum -a 256 "$ROOT/scripts/hooks/guard-interactive-prompt.sh" | awk '{print $1}' \
    > "$ROOT/scripts/hooks/guard-interactive-prompt.sh.sha256"
set +e; IP_OUT="$(run_probe_in "$ROOT" 2>&1)"; rc=$?; set -e
emit_case "IP5.dead-guard-that-refuses-everything-fails-despite-matching-hash" 2 "$rc"
if printf '%s' "$IP_OUT" | grep -q 'refused BOTH the prompting command and the corrected one'; then
    PASS=$((PASS+1)); printf '  PASS  %s\n' "IP5b.layer-IP-says-failing-to-start-not-failing-to-catch"
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("IP5b.layer-IP-says-failing-to-start-not-failing-to-catch")
    printf '  FAIL  %s\n' "IP5b.layer-IP-says-failing-to-start-not-failing-to-catch"
fi
rm -rf "$ROOT"

# IP6 — the guard's OWN behavioral suite (113 cases, two-sided throughout) and
# the mutation harness that proves that suite can fail, both against the live
# scripts. Case 48 does the same for the reaper wrapper.
set +e; "$SCRIPT_DIR/guard-interactive-prompt.test.sh" >/dev/null 2>&1; rc=$?; set -e
emit_case "IP6.interactive-prompt-guard-suite-passes" 0 "$rc"
set +e; "$SCRIPT_DIR/interactive-prompt.mutation.sh" >/dev/null 2>&1; rc=$?; set -e
emit_case "IP7.interactive-prompt-mutations-all-load-bearing" 0 "$rc"

# ---------------------------------------------------------------------------
# LAYER IL — THE IDLE-LAND GATE, THE FIRST FUNCTIONAL LAYER ON THE Stop EVENT
# ---------------------------------------------------------------------------
# Until 2026-09-01 the Stop event's two BLOCKING guards were known to this probe
# only as REGISTRATION. That is the gap these cases close, and the reason it
# matters is on the record rather than hypothetical: the idle-land gate shipped
# registered, hashed, executable and green on every layer here, while standing
# itself down on 41% of the turns it governs. Registration is not enforcement.
#
# IL5 is the case worth reading. This gate FAILS OPEN by design — a Stop guard
# that fails closed refuses to let the SESSION end — so a corpse exits 0, and a
# one-sided canary asserting only "declared stop -> 0" is satisfied by a hook
# that refuses nothing at all. That is precisely the state it shipped in. The
# two-sided canary is what makes IL5 possible, and IL5 is what proves the
# two-sided canary is real.

# IL1 — the gate is not wired on Stop at all.
ROOT="$(make_sandbox)"
python3 - "$ROOT/.claude/settings.local.json" <<'PY'
import json, sys
p = sys.argv[1]
with open(p) as f: d = json.load(f)
d["hooks"]["Stop"] = [e for e in d["hooks"]["Stop"]
                      if not any("guard-idle-land.sh" in h.get("command", "")
                                 for h in e.get("hooks", []))]
with open(p, "w") as f: json.dump(d, f, indent=2)
PY
set +e; IL_OUT="$(run_probe_in "$ROOT" 2>&1)"; rc=$?; set -e
emit_case "IL1.idle-land-gate-not-wired-fails" 2 "$rc"
if printf '%s' "$IL_OUT" | grep -q 'IL. Stop\[guard-idle-land.sh\] NOT wired'; then
    PASS=$((PASS+1)); printf '  PASS  %s\n' "IL1b.layer-IL-is-the-layer-that-caught-it"
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("IL1b.layer-IL-is-the-layer-that-caught-it")
    printf '  FAIL  %s  (some other layer absorbed it)\n' "IL1b.layer-IL-is-the-layer-that-caught-it"
fi
rm -rf "$ROOT"

# IL2 — THE PAIR SPLIT, and the case this whole layer was built to make
# possible. The wrapper is perfect: wired, executable, hash-matched. Its
# ANALYZER is gone — and the wrapper decides nothing without it. It starts
# cleanly, announces "NOT RUNNING: the analyzer is missing" into a channel
# nothing reads in a sandbox, and exits 0 on every turn. SC1 passes it, because
# SC1 asks whether a hook can START.
ROOT="$(make_sandbox)"
rm -f "$ROOT/scripts/hooks/guard-idle-land.py" "$ROOT/scripts/hooks/guard-idle-land.py.sha256"
set +e; IL_OUT="$(run_probe_in "$ROOT" 2>&1)"; rc=$?; set -e
emit_case "IL2.missing-analyzer-fails" 2 "$rc"
if printf '%s' "$IL_OUT" | grep -q 'the idle-land ANALYZER is missing'; then
    PASS=$((PASS+1)); printf '  PASS  %s\n' "IL2b.layer-IL-names-the-missing-analyzer"
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("IL2b.layer-IL-names-the-missing-analyzer")
    printf '  FAIL  %s\n' "IL2b.layer-IL-names-the-missing-analyzer"
fi
rm -rf "$ROOT"

# IL3 — the analyzer is REPLACED. Still present, still importable, and it
# decides the opposite of what it should. The hash catches it; the canary would
# too if the hash did not.
ROOT="$(make_sandbox)"
cat >"$ROOT/scripts/hooks/guard-idle-land.py" <<'NOOP_PY'
import sys
sys.exit(0)
NOOP_PY
set +e; run_probe_in "$ROOT" >/dev/null 2>&1; rc=$?; set -e
emit_case "IL3.replaced-analyzer-fails-on-the-hash" 2 "$rc"
rm -rf "$ROOT"

# IL4 — the wrapper is gutted into a no-op, hash regenerated so the manifest
# agrees. Only the functional canary can see this.
ROOT="$(make_sandbox)"
cat >"$ROOT/scripts/hooks/guard-idle-land.sh" <<'NOOP_SH'
#!/usr/bin/env bash
exit 0
NOOP_SH
chmod +x "$ROOT/scripts/hooks/guard-idle-land.sh"
shasum -a 256 "$ROOT/scripts/hooks/guard-idle-land.sh" | awk '{print $1}' \
    > "$ROOT/scripts/hooks/guard-idle-land.sh.sha256"
set +e; IL_OUT="$(run_probe_in "$ROOT" 2>&1)"; rc=$?; set -e
emit_case "IL4.gutted-gate-fails-despite-matching-hash" 2 "$rc"
if printf '%s' "$IL_OUT" | grep -q 'did NOT refuse a turn that merged a branch'; then
    PASS=$((PASS+1)); printf '  PASS  %s\n' "IL4b.layer-IL-says-it-is-registered-but-not-enforcing"
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("IL4b.layer-IL-says-it-is-registered-but-not-enforcing")
    printf '  FAIL  %s\n' "IL4b.layer-IL-says-it-is-registered-but-not-enforcing"
fi
rm -rf "$ROOT"

# IL5 — A GATE THAT REFUSES EVERYTHING, hash regenerated. The mirror image of
# IL4, and the half a one-sided canary cannot see: an always-2 hook satisfies
# "bad turn is refused" perfectly while making the declared escape unreachable —
# and an escape nobody can reach is a guard somebody unwires.
ROOT="$(make_sandbox)"
cat >"$ROOT/scripts/hooks/guard-idle-land.sh" <<'DEAD_SH'
#!/usr/bin/env bash
exit 2
DEAD_SH
chmod +x "$ROOT/scripts/hooks/guard-idle-land.sh"
shasum -a 256 "$ROOT/scripts/hooks/guard-idle-land.sh" | awk '{print $1}' \
    > "$ROOT/scripts/hooks/guard-idle-land.sh.sha256"
set +e; IL_OUT="$(run_probe_in "$ROOT" 2>&1)"; rc=$?; set -e
emit_case "IL5.gate-that-refuses-everything-fails-despite-matching-hash" 2 "$rc"
if printf '%s' "$IL_OUT" | grep -q 'refused BOTH the bad turn and a legitimately DECLARED stop'; then
    PASS=$((PASS+1)); printf '  PASS  %s\n' "IL5b.layer-IL-says-refusing-everything-not-deciding"
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("IL5b.layer-IL-says-refusing-everything-not-deciding")
    printf '  FAIL  %s\n' "IL5b.layer-IL-says-refusing-everything-not-deciding"
fi
rm -rf "$ROOT"

# IL6 — the gate's OWN behavioral suite and the mutation harness that proves
# that suite can fail, both against the live scripts. The mutation harness is
# not optional decoration here: this gate's previous suite was 38 green cases
# over a term that disarmed it, and a mutation run is the only thing that asks
# whether a green tick is load-bearing.
set +e; "$SCRIPT_DIR/guard-idle-land.test.sh" >/dev/null 2>&1; rc=$?; set -e
emit_case "IL6.idle-land-gate-suite-passes" 0 "$rc"
set +e; "$SCRIPT_DIR/idle-land.mutation.sh" >/dev/null 2>&1; rc=$?; set -e
emit_case "IL7.idle-land-mutations-all-load-bearing" 0 "$rc"

# CL1/CL2 — the CLAIM gate's own behavioral suite and mutation harness, for the
# reason IL6/IL7 exist, arriving late and after a cost. Both files were in this
# repository and were run by NOTHING: the only automatic check on
# guard-unresolved-claims.sh was that it starts (SC1) and that its hash matches
# (Layer BR). On 2026-09-01 that gate blocked one of the night's three false
# reports and passed the other two, and nothing in CI would have noticed if a
# refactor had silenced all three.
#
# The mutation half is not decoration here either. This gate's newest arm is a
# two-sided canary, and the property most easily satisfied by a corpse is
# "a false claim is refused" — a gate that refuses everything passes it. One of
# the mutations empties the integration ref list precisely so a TRUE landing
# claim gets refused, and asserts that the POSITIVE case goes red.
set +e; "$SCRIPT_DIR/guard-unresolved-claims.test.sh" >/dev/null 2>&1; rc=$?; set -e
emit_case "CL1.claim-gate-suite-passes" 0 "$rc"
# Output KEPT on failure. IL7 discards it, and when CL2 first went red inside
# this suite while passing standalone, "exit=1" was the entire diagnosis. A
# mutation harness that can only say "something survived" is a harness you end
# up re-running by hand anyway.
CL2_LOG="$(mktemp -t claim-mutations.XXXXXX)"
set +e; "$SCRIPT_DIR/claim-roles.mutation.sh" >"$CL2_LOG" 2>&1; rc=$?; set -e
emit_case "CL2.claim-gate-mutations-all-load-bearing" 0 "$rc"
if [ "$rc" -ne 0 ]; then
    grep -E '^  FAIL|survived or misfired' "$CL2_LOG" | sed 's/^/        /'
fi
rm -f "$CL2_LOG"

# RI1/RI2/IN2 — the resume-isolation guard's suite and mutation harness, and the
# in-flight notify mutations. Registered here for the reason CL1/CL2 are: a
# harness nothing runs is a harness that rots. IN2 earned its row the hard way —
# at pristine HEAD it killed 11 of 18, because five mutant sandboxes lacked
# scripts/lib/git-jurisdiction.sh and so ran a guard that REFUSED TO START, which
# reads exactly like a guard that caught the mutation.
set +e; "$SCRIPT_DIR/guard-resume-isolation.test.sh" >/dev/null 2>&1; rc=$?; set -e
emit_case "RI1.resume-isolation-suite-passes" 0 "$rc"
set +e; "$SCRIPT_DIR/guard-resume-isolation.mutation.sh" >/dev/null 2>&1; rc=$?; set -e
emit_case "RI2.resume-isolation-mutations-all-load-bearing" 0 "$rc"
set +e; "$SCRIPT_DIR/inflight-notify.mutation.sh" >/dev/null 2>&1; rc=$?; set -e
emit_case "IN2.inflight-notify-mutations-all-load-bearing" 0 "$rc"

# WTR1 — the worktree-removal guard's mutation harness, for the reason CL1/CL2
# exist and one step further along the same road. The guard's own behavioral
# suite IS run, because run-all-tests.sh discovers every *.test.sh from disk.
# Its mutation harness is a *.mutation.sh, so that discovery never saw it, and
# on 2026-09-02 nothing in this engine ran it at all.
#
# That matters more than usual for this guard, because the fix landed that day
# was a fix to a FALSE POSITIVE — and the cheapest way to stop a guard
# false-firing is to stop it firing. The harness's M6 mutant is the arm that
# refuses that shortcut. An unrun mutant refuses nothing.
set +e; "$SCRIPT_DIR/guard-worktree-removal.mutation.sh" >/dev/null 2>&1; rc=$?; set -e
emit_case "WTR1.worktree-removal-mutations-all-load-bearing" 0 "$rc"

# ---------------------------------------------------------------------------
# LAYER MT — THE MODEL CAPABILITY ORDER IS DATA, AND THE PROSE IS HELD TO IT
# ---------------------------------------------------------------------------
# Every case below is a way the 2026-09-02 defect could come back: the order
# undeclared (MT1), declared but disagreeing with the alias set (MT2), stated
# in prose that quotes a DIFFERENT order than the data (MT3), and the original
# shape — "don't downgrade" in prose with no data behind it at all (MT4). MT5
# is the control: a sandbox with the declaration, the parser and a doctrine
# file that quotes it passes the layer, so the four refusals above are refusals
# and not a layer that fails on everything.

# MT1 — MODEL_TIERS blank: the order is not declared.
ROOT="$(make_sandbox)"
sed -i '' 's/^MODEL_TIERS=.*/MODEL_TIERS=""/' "$ROOT/orchestration.config"
set +e; MT_OUT="$(run_probe_in "$ROOT" 2>&1)"; rc=$?; set -e
emit_case "MT1.model-tiers-undeclared-fails" 2 "$rc"
if printf '%s' "$MT_OUT" | grep -q 'MT\. MODEL_TIERS in .*: MODEL_TIERS is blank'; then
    emit_case "MT1b.the-refusal-names-the-blank-declaration" 0 0
else
    emit_case "MT1b.the-refusal-names-the-blank-declaration" 0 1
fi
rm -rf "$ROOT"

# MT2 — the alias sets disagree: ALLOWED_MODELS names an alias the order does
# not rank. A spawn on that alias is one the guard cannot rank.
ROOT="$(make_sandbox)"
sed -i '' 's/^MODEL_TIERS=.*/MODEL_TIERS="fable > opus > sonnet"/' "$ROOT/orchestration.config"
set +e; MT_OUT="$(run_probe_in "$ROOT" 2>&1)"; rc=$?; set -e
emit_case "MT2.model-tiers-alias-set-drifts-from-allowed-models-fails" 2 "$rc"
if printf '%s' "$MT_OUT" | grep -q 'MT\. MODEL_TIERS and ALLOWED_MODELS disagree.*haiku'; then
    emit_case "MT2b.the-refusal-names-the-unranked-alias" 0 0
else
    emit_case "MT2b.the-refusal-names-the-unranked-alias" 0 1
fi
rm -rf "$ROOT"

# MT3 — the doctrine file quotes a DIFFERENT order than the declaration.
ROOT="$(make_sandbox)"
printf '**Models:** the order is `MODEL_TIERS="opus > fable > sonnet > haiku"` and never move a teammate down it.\n' >"$ROOT/CLAUDE.md"
set +e; MT_OUT="$(run_probe_in "$ROOT" 2>&1)"; rc=$?; set -e
emit_case "MT3.doctrine-quotes-a-different-order-fails" 2 "$rc"
if printf '%s' "$MT_OUT" | grep -q 'MT\. .*CLAUDE.md quotes MODEL_TIERS="opus > fable > sonnet > haiku" but orchestration.config declares MODEL_TIERS="fable > opus > sonnet > haiku"'; then
    emit_case "MT3b.the-refusal-names-both-orders" 0 0
else
    emit_case "MT3b.the-refusal-names-both-orders" 0 1
fi
rm -rf "$ROOT"

# MT4 — the original defect: "don't downgrade" in prose, no data behind it.
ROOT="$(make_sandbox)"
printf '**Models:** definitions default to Opus for the judgment-critical roles (do not downgrade) and Sonnet for the rest.\n' >"$ROOT/CLAUDE.md"
set +e; MT_OUT="$(run_probe_in "$ROOT" 2>&1)"; rc=$?; set -e
emit_case "MT4.doctrine-says-downgrade-without-quoting-the-data-fails" 2 "$rc"
if printf '%s' "$MT_OUT" | grep -q 'MT\. .*says "downgrade" but never quotes the declaration'; then
    emit_case "MT4b.the-refusal-names-the-missing-quotation" 0 0
else
    emit_case "MT4b.the-refusal-names-the-missing-quotation" 0 1
fi
rm -rf "$ROOT"

# MT5 — CONTROL: declaration + parser + a doctrine file that quotes it -> the
# layer passes, two-sided canary included. Without this the four above could
# be a layer that fails on everything.
ROOT="$(make_sandbox)"
printf '**Models:** the order is `MODEL_TIERS="fable > opus > sonnet > haiku"`; do not move a teammate to a lower tier without saying why.\n' >"$ROOT/CLAUDE.md"
set +e; MT_OUT="$(run_probe_in "$ROOT" 2>&1)"; rc=$?; set -e
# The probe styles its check mark (C_GREEN ... C_RESET) so "✓ MT." never
# appears as plain text; match the layer's own words, as MT1-MT4 do.
if printf '%s' "$MT_OUT" | grep -q 'MT\. capability order declared as data'; then
    emit_case "MT5.control-declared-and-quoted-passes-the-layer" 0 0
else
    emit_case "MT5.control-declared-and-quoted-passes-the-layer" 0 1
    printf '%s\n' "$MT_OUT" | grep -E 'MT\.' | sed 's/^/        /'
fi
rm -rf "$ROOT"

# WTI1 — the spawn guard's CLAUSE 5 (staffing) mutation harness, registered for
# the reason WTR1 is: run-all-tests.sh discovers every *.test.sh from disk, so
# the guard's behavioral suite IS run, but a *.mutation.sh is invisible to that
# discovery and nothing would run this one.
#
# Clause 5's arms are the two-sided kind a corpse satisfies: "a generic dispatch
# without a hatch is refused" is passed by a guard that refuses everything, and
# "a statusline change needs no hatch" is passed by a guard that refuses
# nothing. M5, M6, M7 and M11 are the over-blocking mutants that refuse both
# shortcuts. An unrun mutant refuses nothing.
set +e; "$SCRIPT_DIR/guard-worktree-isolation.mutation.sh" >/dev/null 2>&1; rc=$?; set -e
emit_case "WTI1.staffing-gate-mutations-all-load-bearing" 0 "$rc"

# MF1 — the mechanical-findings mutation harness, registered for the reason
# WTR1 and WTI1 are: a *.mutation.sh is invisible to run-all-tests.sh's
# discovery. Unregistered, it is itself an `unrun-harness` finding of the very
# sweep it proves, and the sweep will write that row.
set +e; "$SCRIPT_DIR/mechanical-findings.mutation.sh" >/dev/null 2>&1; rc=$?; set -e
emit_case "MF1.mechanical-findings-mutations-all-load-bearing" 0 "$rc"

# SA1/SA2 — the stated-actions gate's behavioral suite and its mutation
# harness, registered here for the reason IL6/IL7 are and with the same
# two-sided risk: "a stated-but-untaken action is refused" is satisfied by a
# gate that refuses everything, and "a same-turn dispatch is let through" by
# one that refuses nothing. The harness carries both kinds of mutant, and an
# unrun mutant refuses nothing. Output KEPT on failure, for CL2's reason.
set +e; "$SCRIPT_DIR/guard-stated-actions.test.sh" >/dev/null 2>&1; rc=$?; set -e
emit_case "SA1.stated-actions-gate-suite-passes" 0 "$rc"
SA2_LOG="$(mktemp -t stated-actions-mutations.XXXXXX)"
set +e; "$SCRIPT_DIR/stated-actions.mutation.sh" >"$SA2_LOG" 2>&1; rc=$?; set -e
emit_case "SA2.stated-actions-mutations-all-load-bearing" 0 "$rc"
if [ "$rc" -ne 0 ]; then
    grep -E '^  FAIL' "$SA2_LOG" | sed 's/^/        /'
fi
rm -f "$SA2_LOG"

echo ""
echo "=== summary ==="
echo "passed: $PASS"
echo "failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo "failing cases:"
    for n in "${FAIL_NAMES[@]}"; do echo "  - $n"; done
    exit 1
fi
exit 0
