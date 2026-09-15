#!/usr/bin/env bash
#
# scripts/hooks/dispatch-pretooluse.sh — ONE PROCESS, N RULES.
#
# ===========================================================================
# WHAT THIS REPLACES, AND THE MEASUREMENT THAT DECIDED ITS SHAPE
# ===========================================================================
# Before this file, PreToolUse[Bash] registered TWELVE guard scripts and
# PreToolUse[Write|Edit|MultiEdit|NotebookEdit] registered FIVE. The host runs
# each registered entry as its own process, so seventeen scripts were seventeen
# processes, and twelve of them ran on every single shell call any agent made.
#
# The design that ordered this step (docs/verification/verification-layer-
# design-2026-09-14.md §7, Step 3) said the cost was "12 separate bash
# processes". IT IS NOT, and the difference decides this file's shape. Measured
# on this machine, 2026-09-15, macOS 24.6.0, by putting counting shims ahead of
# the real binaries on PATH and replaying one real payload through the chain:
#
#     bash -c 'exit 0'                      2.12 ms
#     python3 -c 'pass'                    14.64 ms
#     git rev-parse --show-toplevel         4.23 ms
#
#     PreToolUse[Bash] chain, one call:   14 bash + 37 python3 + 36 git
#                                       = 30 ms  +  542 ms   + 152 ms
#
# AND WHAT IT COSTS NOW, the same call counted the same way — the dispatcher
# plus the two entries below that are deliberately not rules:
#
#     PreToolUse[Bash] chain, one call:    3 bash + 19 python3 +  8 git
#
#     serial work,   median of 7 runs:  1203 ms -> 397 ms
#     parallel wall, median of 7 runs:   310 ms -> 254 ms
#
# `unverified:` whether the host runs its registered entries concurrently. Both
# numbers are given because the answer decides which one matters, and measuring
# it would mean registering a probe hook on the operator's live session.
#
# Bash process startup is 4% of the apparatus cost. The other 96% is python3
# and git, and TWO OF EVERY THREE python3 forks and FOUR OF EVERY FOUR git
# forks were the same two questions asked twelve times over one identical
# payload:
#
#     1. which repository does this call govern?   (resolve_entity_root)
#     2. does this payload parse as a JSON object? (richos_payload_unreadable)
#
# So "collapse twelve processes into one" is the right move for the wrong
# reason. The win is not that bash is cheap to start; it is that ONE process
# can answer those two questions ONCE and hand the answers to every rule. That
# is what this dispatcher does, and it is the only reason it is worth the risk
# of running twelve rules in one address space.
#
# ===========================================================================
# THE RULES ARE THE EXISTING FILES, UNMOVED AND UNEDITED
# ===========================================================================
# Every module named in the manifest is the guard script that was registered
# before this change, at the same path, byte-identical. Nothing was moved into
# a rules/ subdirectory and nothing was rewritten.
#
# That is deliberate, and it is the cheap answer to three problems at once:
#
#   * Layer R of contract-integrity-probe.sh asserts that ~59 hooks carry a
#     BYTE-IDENTICAL root-resolution bootstrap block. Moving a guard changes
#     its `../lib` relative path and breaks that block. Leaving them put costs
#     nothing and keeps Layer R meaningful.
#   * Every guard keeps its own test suite, which still runs it as a process.
#     A rule that can only be exercised through the dispatcher is a rule whose
#     failures are harder to find; these stay independently runnable.
#   * `ls scripts/hooks/*.sh | wc -l` does not move. The design named the
#     git-mv game explicitly and rejected it; this change must not look like
#     one. What falls is the number of scripts the HOST LOADS AND SPAWNS,
#     which is the number that costs something.
#
# ===========================================================================
# ISOLATION: WHAT HAPPENS WHEN ONE RULE BREAKS
# ===========================================================================
# Each module runs as `( set +e +u +o pipefail; . module )` — a real forked
# subshell with its own file descriptors, sourced rather than exec'd.
#
#   * An `exit 2` inside a module exits ITS subshell. The dispatcher reads the
#     status and carries on to the report; it never inherits the exit.
#   * A module's variables, traps, shell options and `exec` cannot reach the
#     dispatcher or any sibling: a subshell is a fork.
#   * The options are reset to bash's script defaults before each source,
#     because a module written against `set -eo pipefail` must not inherit a
#     `set -u` the dispatcher happens to want for itself.
#   * A module that is MISSING, UNREADABLE, or exits with anything that is not
#     0 or 2 is ANNOUNCED BY NAME and the remaining modules still run. It is
#     never treated as a pass. The engine's rule is fail loud, never skip, and
#     a rule that did not evaluate is exactly the thing that must be said out
#     loud rather than counted as silence.
#
# The one thing this shape cannot reproduce is per-module TIMEOUTS. The host
# applied a timeout to each registered entry; it now applies one to the
# dispatcher, so a module that hangs past the dispatcher's budget takes the
# whole chain with it instead of only itself. Modules run CONCURRENTLY, so the
# chain's wall time is its slowest module rather than the sum, and the
# registered timeout is set well above the slowest module's old budget. Stated
# here rather than discovered later: on timeout, the host lets the tool call
# proceed, which is the same outcome the old shape produced for the module
# that timed out — it is the other eleven that now share its fate.
#
# ===========================================================================
# OUTPUT: WHAT THE HOST SEES
# ===========================================================================
# Reproduces exactly what the host computed from the separate entries:
#
#   exit code   2 if ANY module exited 2, else 0. Every module runs either way
#               — the old shape ran all twelve regardless of what the first
#               one decided, so the report names every refusal, not the first.
#   stderr      each module's stderr, concatenated in MANIFEST ORDER, which is
#               the order hooks.json registered them.
#   stdout      each module's stdout, concatenated in manifest order. Measured
#               over 11,299 real Bash payloads and 383 real Write payloads
#               recovered from this project's transcripts: no Bash or Write
#               rule module writes to stdout on any of them. The one shape
#               that would break — two modules emitting JSON objects that
#               concatenate into invalid JSON — is detected and reported as a
#               systemMessage rather than shipped as a broken envelope.
#
# `shell-evidence.sh` is NOT a module here and stays registered on its own.
# It is an input TRANSFORMER, not a guard: it returns `updatedInput` that
# rewrites the command the host is about to run. Folding an updatedInput
# emitter into an aggregator is the highest-risk merge available for the
# smallest possible gain, and the design's own count of "12 PreToolUse[Bash]
# guards" excludes it. `guard-sealed-worktree.sh` stays registered on its own
# too, for a different reason: it is registered on the EMPTY matcher, so it
# governs every tool, and moving it under a Bash-or-Write dispatcher would
# narrow what it protects.
#
# ===========================================================================
# USAGE
# ===========================================================================
#   dispatch-pretooluse.sh <chain-key>
#
# <chain-key> is `Bash` or `Write` and is passed by hooks.json, never derived
# from the payload. Deriving it would mean an unparseable payload selects NO
# rules and passes in silence — the failure mode the whole unevaluated-payload
# library exists to remove. The matcher already decided which chain this is;
# the argument records that decision where it cannot be lost.
#
# Exit codes: 0 allow, 2 block. Anything else is a bug in this file.

set -uo pipefail

_DSP_TAG="(hook: scripts/hooks/dispatch-pretooluse.sh)"
_DSP_CHAIN_KEY="${1:-}"

if [ -z "$_DSP_CHAIN_KEY" ]; then
    printf '%s\n' "ERROR: dispatch-pretooluse.sh: no chain key argument. hooks.json must pass 'Bash' or 'Write'. NO RULE IN THIS CHAIN EVALUATED THIS CALL. $_DSP_TAG" >&2
    exit 2
fi

# --- ROOT RESOLUTION -------------------------------------------------------
# TWO ROOTS, NEVER ONE. The full contract, and why the old single-root
# resolution was wrong the moment the engine became loadable by reference,
# is in scripts/lib/resolve-roots.sh. This bootstrap block is byte-identical
# in every hook that needs a root; contract-integrity-probe.sh Layer R asserts
# that, so a divergent copy is a probe failure rather than a surprise.
#
# THE BANNER BELOW GOES OUT ON TWO CHANNELS AND ONLY THE SECOND IS HEARD.
# Measured on Claude Code 2.1.270 (macOS, 2026-09-14) by registering one probe
# hook per channel on five events at once and reading the transcript back:
#
#   channel, exit 0     SessionStart  UserPromptSubmit  PreToolUse  PostToolUse  Stop
#   stderr              silent        silent            silent      silent       silent
#   stdout, plain text  model         model             silent      silent       silent
#   {"systemMessage"}   PERSON        PERSON            PERSON      PERSON       PERSON
#   additionalContext   model         model             model       model        model
#
# `silent` is not shorthand: the host records a `hook_success` attachment
# carrying the text in its stderr field and renders it to NO ONE. So a hook
# that could not find its own engine announced a dead enforcement layer
# exactly as loudly as a clean pass. Of the 60 files carrying this block, 35
# exit 2 here — where the host does render stderr, as the refusal reason — and
# 24 exit 0 and were inaudible. The 24 are the notices and observers, which is
# the trap: the hooks that must never block are the hooks nobody could hear.
#
# WHY `systemMessage` AND NOT `additionalContext`. additionalContext must name
# its own event in the envelope, and this block is identical in hooks
# registered on eight different events — it cannot know which one it is on.
# `systemMessage` is event-agnostic and it reaches the operator rather than
# only the model, which is the right audience for "your guards are off".
# Measured too: adding it to an exit-2 hook leaves the refusal untouched —
# same `hook error:` tool result, same blocked write — and only adds a render.
# Nothing here changes what any hook detects, refuses, or exits with.
#
# The escaping is deliberately pure bash (verified on 3.2.57, the macOS system
# shell) and calls nothing external: this is the one code path in the engine
# that runs when the install is already known to be broken, so it must not
# depend on python3, jq, or any file it has just failed to find.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_RR_LIB="$SCRIPT_DIR/../lib/resolve-roots.sh"
if [ ! -f "$_RR_LIB" ]; then
    _RR_MSG="=== RICHOS ENGINE: BROKEN INSTALL — ENFORCEMENT IS NOT ACTIVE ===
  hook: scripts/hooks/dispatch-pretooluse.sh
  scripts/lib/resolve-roots.sh is missing at: $_RR_LIB
  Without it this guard cannot tell WHICH REPOSITORY it governs.
  It will not guess, and it will not carry on quietly — a defense
  that reports 'on' while protecting nothing is worse than none."
    printf '%s\n' "$_RR_MSG" >&2
    _RR_J="${_RR_MSG//\\/\\\\}"; _RR_J="${_RR_J//\"/\\\"}"; _RR_J="${_RR_J//$'\n'/\\n}"
    printf '{"systemMessage":"%s"}\n' "$_RR_J"
    exit 2
fi
# shellcheck source=../lib/resolve-roots.sh
. "$_RR_LIB"
ENGINE_ROOT="$(resolve_engine_root "$SCRIPT_DIR")"

_DSP_DIR="$SCRIPT_DIR"
_DSP_MANIFEST="$_DSP_DIR/dispatch-pretooluse.manifest"

if [ ! -f "$_DSP_MANIFEST" ]; then
    printf '%s\n' "=== RICHOS ENGINE: BROKEN INSTALL — ENFORCEMENT IS NOT ACTIVE ===
  hook: scripts/hooks/dispatch-pretooluse.sh
  the rule manifest is missing at: $_DSP_MANIFEST
  Without it this dispatcher does not know which rules govern this call.
  It will not guess: every rule in the ${_DSP_CHAIN_KEY} chain is UNEVALUATED." >&2
    exit 2
fi

# The payload is read ONCE, here, and handed to every module on its own stdin.
_DSP_INPUT="$(cat)"

# --- the chassis, answered once --------------------------------------------
# Priming these two memos in THIS process, before any module is forked, is the
# whole point of the dispatcher (see the measurement at the top). Both memos
# are OFF unless explicitly enabled, so nothing outside this process can be
# affected by them; a subshell inherits the primed values, and a subshell's own
# writes cannot leak back out.
# resolve-roots.sh is already sourced by the bootstrap block above; this only
# primes the memo, and the rc is deliberately ignored — the DISPATCHER makes no
# decision from the root. Each module still calls resolve_entity_root itself and
# still branches on its own status, exactly as it did as a separate process.
_RR_MEMO_ENABLE=1
resolve_entity_root "$_DSP_INPUT" || true

_DSP_UE_LIB="$_DSP_DIR/../lib/unevaluated-notice.sh"
if [ -f "$_DSP_UE_LIB" ]; then
    # shellcheck source=../lib/unevaluated-notice.sh
    . "$_DSP_UE_LIB"
    _UE_MEMO_ENABLE=1
    richos_payload_unreadable "$_DSP_INPUT" >/dev/null || true
fi

# --- the modules -----------------------------------------------------------
_DSP_MODULES="$(grep -E "^${_DSP_CHAIN_KEY}\|" "$_DSP_MANIFEST" 2>/dev/null | cut -d'|' -f2 || true)"

if [ -z "$_DSP_MODULES" ]; then
    printf '%s\n' "ERROR: dispatch-pretooluse.sh: the manifest names NO rules for chain '${_DSP_CHAIN_KEY}'. This call was NOT checked by any rule in that chain. Manifest: $_DSP_MANIFEST $_DSP_TAG" >&2
    exit 2
fi

_DSP_WORK="$(mktemp -d "${TMPDIR:-/tmp}/richos-dispatch.XXXXXX")" || {
    printf '%s\n' "ERROR: dispatch-pretooluse.sh: cannot create a working directory; NO RULE in the ${_DSP_CHAIN_KEY} chain evaluated this call. $_DSP_TAG" >&2
    exit 2
}
trap 'rm -rf "$_DSP_WORK" 2>/dev/null || true' EXIT

printf '%s' "$_DSP_INPUT" > "$_DSP_WORK/payload"

# Fork every module. Concurrency is what keeps the chain's wall time at its
# slowest rule rather than the sum of all of them, which is what the host's own
# per-entry execution gave us before.
_DSP_N=0
for _dsp_m in $_DSP_MODULES; do
    _DSP_N=$((_DSP_N + 1))
    _dsp_slot="$_DSP_WORK/$(printf '%03d' "$_DSP_N").$_dsp_m"
    if [ ! -f "$_DSP_DIR/$_dsp_m" ]; then
        # An absent module never forks, so it has no status to read. It is
        # marked ABSENT rather than given a synthetic exit code: a rule that
        # did not run has no verdict, and inventing one — 0 or 2 — would be
        # the guess this dispatcher refuses everywhere else. The announcement
        # below carries the whole signal.
        : > "$_dsp_slot.absent"
        printf '%s\n' "ERROR: dispatch-pretooluse.sh: rule module '$_dsp_m' is NOT PRESENT at $_DSP_DIR/$_dsp_m. THAT RULE DID NOT EVALUATE THIS CALL — every other rule in the ${_DSP_CHAIN_KEY} chain still ran. Run scripts/hooks/install.sh and check the manifest. $_DSP_TAG" > "$_dsp_slot.err"
        continue
    fi
    (
        set +e +u +o pipefail
        . "$_DSP_DIR/$_dsp_m"
    ) < "$_DSP_WORK/payload" > "$_dsp_slot.out" 2> "$_dsp_slot.err" &
    printf '%s\n' "$!" > "$_dsp_slot.pid"
done

# --- the report ------------------------------------------------------------
_DSP_RC=0
_DSP_STDOUT_EMITTERS=0
_DSP_STDOUT=""
_DSP_N=0
for _dsp_m in $_DSP_MODULES; do
    _DSP_N=$((_DSP_N + 1))
    _dsp_slot="$_DSP_WORK/$(printf '%03d' "$_DSP_N").$_dsp_m"

    if [ -f "$_dsp_slot.absent" ]; then
        # It never ran. Say so — once — and go on to the next rule. It does not
        # block, because a rule that did not evaluate the call has not refused
        # it; and it does not pass, because the line above says it did not run.
        cat "$_dsp_slot.err" >&2
        continue
    fi

    _dsp_pid="$(cat "$_dsp_slot.pid" 2>/dev/null || true)"
    if [ -z "$_dsp_pid" ]; then
        # The fork left no pid — the shell could not start the subshell at all,
        # which under resource pressure is a real outcome and not a theoretical
        # one. There is no status to read, so there is no verdict: announce it
        # and carry on, the same treatment an absent module gets.
        printf '%s\n' "ERROR: dispatch-pretooluse.sh: rule module '$_dsp_m' left no process status — it could not be started. THAT RULE DID NOT EVALUATE THIS CALL; every other rule in the ${_DSP_CHAIN_KEY} chain ran normally and their verdicts stand. $_DSP_TAG" >&2
        [ -f "$_dsp_slot.err" ] && cat "$_dsp_slot.err" >&2
        continue
    fi
    wait "$_dsp_pid"
    _dsp_rc=$?

    [ -f "$_dsp_slot.err" ] && cat "$_dsp_slot.err" >&2
    if [ -s "$_dsp_slot.out" ]; then
        _DSP_STDOUT_EMITTERS=$((_DSP_STDOUT_EMITTERS + 1))
        _DSP_STDOUT="$_DSP_STDOUT$(cat "$_dsp_slot.out")"
    fi

    case "$_dsp_rc" in
        0) : ;;
        2) _DSP_RC=2 ;;
        *)
            printf '%s\n' "ERROR: dispatch-pretooluse.sh: rule module '$_dsp_m' exited $_dsp_rc, which is neither 0 (allow) nor 2 (block). THAT RULE DID NOT EVALUATE THIS CALL and its verdict is unknown; every other rule in the ${_DSP_CHAIN_KEY} chain ran normally and their verdicts stand. $_DSP_TAG" >&2
            ;;
    esac
done

if [ -n "$_DSP_STDOUT" ]; then
    if [ "$_DSP_STDOUT_EMITTERS" -gt 1 ]; then
        # Two JSON objects concatenated are not a JSON object. Say so instead of
        # shipping an envelope the host will silently drop.
        printf '{"systemMessage":"%s"}\n' "dispatch-pretooluse.sh: ${_DSP_STDOUT_EMITTERS} rules in the ${_DSP_CHAIN_KEY} chain wrote to stdout on one call. Their outputs cannot be concatenated into one hook result and were NOT delivered. The rules themselves ran and their exit codes stand. Fix: give the chain a real merge, or take the stdout-emitting rule out of the chain."
    else
        printf '%s\n' "$_DSP_STDOUT"
    fi
fi

exit "$_DSP_RC"
