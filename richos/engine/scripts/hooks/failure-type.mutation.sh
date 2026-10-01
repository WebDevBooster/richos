#!/usr/bin/env bash
#
# failure-type.mutation.sh — PROVES THE FAILURE-TYPE SUITE CAN FAIL, ONE RULE AT
#                            A TIME, FOR THE RIGHT REASON.
#
# Forty green ticks are evidence of nothing until each rule they claim to prove
# has been removed and the suite watched going red on the case that names it.
# This suite is exposed in the usual two ways: half of what it asserts is
# silence (a predicate that never runs is silent too), and a gate that refuses
# is easy to mistake for a gate that refuses for the RIGHT missing step.
#
# So: take the shipped source, remove ONE property in a throwaway copy of the
# engine, and assert that failure-type.test.sh fails, that the SPECIFIC named
# case fails, and that the mutation applied. The loop is
# scripts/lib/mutation-harness.sh; failure-type.test.sh runs this file.
#
# Run directly: scripts/hooks/failure-type.mutation.sh
# Exit 0 = every property is proven load-bearing.

# THE MERGE GATE LEAVES THIS PASS TO THE NIGHTLY (richos/app/scripts/autocheck/README.md): the
# gate runs the suite with RICHOS_MUTATION_PASSES=0; nightly-engine.py runs every pass.
if [ "${RICHOS_MUTATION_PASSES:-}" = 0 ]; then echo "NOT RUN: $(basename "$0"), a mutation pass (RICHOS_MUTATION_PASSES=0, the merge gate; the nightly runs it)"; exit 0; fi

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/mutation-harness.sh
. "$ENGINE_ROOT/scripts/lib/mutation-harness.sh"

mutation_begin "failure type: read, name, commit" "scripts/hooks/failure-type.test.sh"
# Each mutant stops at its named FAIL line (see mutation_focus): in this suite a
# printed FAIL line always ends the run red, so the rest of the run buys nothing.
mutation_focus stop-at-want

S="scripts/lib/failure-type.py"
U="scripts/hooks/failure-type-lookup.sh"
G="scripts/hooks/guard-failure-type-answer.sh"

# --- 1. THE TRIGGER: HIS WORDS, LITERALLY ---------------------------------
mutant window-too-wide "FT03" "$S" \
    '            if abs(i - j) <= WINDOW:' \
    '            if abs(i - j) <= WINDOW + 1:' \
    "the words seven apart would trigger: the window would no longer be the one measured and declared."

mutant envelopes-kept "FT04" "$S" \
    '    return ENVELOPE_BLOCKS.sub(" ", text)' \
    '    return text' \
    "a reminder block or a pasted report carrying the words would count as HIS words, and the lead would owe a register entry for text he never wrote."

mutant prefixes-ignored "FT04" "$S" \
    '        if stripped.startswith(prefix):{NL}            return ""' \
    '        if False:{NL}            return ""' \
    "hook feedback and another session's message open with a fixed prefix; without it they would read as his."

mutant ups-hears-teammates "FT18" "$S" \
    '    if payload.get("agent_id"):{NL}        return 0{NL}    prompt = payload.get("prompt")' \
    '    prompt = payload.get("prompt")' \
    "a teammate's brief mentioning a failure type would inject the register into a teammate's turn."

# --- 2. WHAT THE LEAD IS HANDED -------------------------------------------
mutant context-dropped "FT10" "$S" \
    '"additionalContext": context}}' \
    '"additionalContext": ""}}' \
    "the list would go nowhere the model reads: the person would be told the lookup ran while the lead saw nothing."

mutant list-truncated "FT12" "$S" \
    '    numbers = sorted(reg["types"])' \
    '    numbers = sorted(reg["types"])[:3]' \
    "the lead would be handed a partial list with no word that anything was missing."

mutant no-budget "FT19" "$S" \
    '        if used + len(row) + 1 + 160 > CONTEXT_BUDGET or len(shown) >= lines_left:{NL}            break' \
    '        if False:{NL}            break' \
    "a long register would exceed the measured channel cap and the host would drop the WHOLE object: the lookup would go silent exactly when the register had grown."

mutant box-disagreement-hidden "FT15" "$S" \
    '    if bt is None or bt != dt:' \
    '    if False:' \
    "a box that disagrees with the headings would hand out a number that collides with an existing type."

mutant ups-no-obligation "FT46" "$S" \
    '    save_pending(entity, session, pend){NL}    log_event(entity, {"event": "injected"' \
    '    log_event(entity, {"event": "injected"' \
    "the Stop gate would depend on finding the message in the transcript; the lookup's own record of the obligation would be lost."

mutant ups-output-dropped "FT10" "$U" \
    '[ -n "$OUT" ] && printf '"'"'%s\n'"'"' "$OUT"' \
    ':' \
    "the analyzer would build the lookup and the hook would throw it away."

# --- 3. THE STOP GATE: WHOSE WORDS -----------------------------------------
mutant machine-counts-as-him "FT46" "$S" \
    '            if verdict:{NL}                humans.append(text)' \
    '            if text and not has_result:{NL}                humans.append(text)' \
    "a task notification carrying the words would put the lead in debt for a message the machine wrote."

mutant machine-pending-kept "FT46" "$S" \
    '    pending = [p for p in pending if p.get("hash") not in machine_hashes]' \
    '    pending = list(pending)' \
    "an obligation raised at UserPromptSubmit for machine text would survive the transcript's proof that it was not his."

mutant first-message-only "FT49" "$S" \
    '                humans.append(text)' \
    '                humans.append(text) if not humans else None' \
    "a message he queued while the turn was running would be ignored, and he queues constantly."

mutant stop-refuses-teammates "FT50" "$S" \
    '    if payload.get("agent_id"):{NL}        stop_status("none", "teammate"){NL}        return 0' \
    '    pass' \
    "a teammate's turn could be refused for the lead's obligation."

# --- 4. THE THREE CHECKS ---------------------------------------------------
mutant read-tool-ignored "FT31" "$S" \
    '        if name == "Read" and path_is_register(inp.get("file_path"), reg_path, rel):{NL}            return True' \
    '        if name == "Read" and path_is_register(inp.get("file_path"), reg_path, rel):{NL}            pass' \
    "reading the register with the Read tool, the plainest way, would not count."

mutant any-mention-is-a-read "FT47" "$S" \
    '        if verb not in _READER_WORDS:' \
    '        if False:' \
    "a command that is not a reader (\`git add\` of the register) would count as having read it."

mutant any-argument-is-the-register "FT57" "$S" \
    '    return path_is_register(arg, reg_path, rel) or os.path.basename(arg) == base' \
    '    return True' \
    "a reader run on some OTHER file (\`cat notes.md\`) would count as having read the register."

mutant errored-read-counts "FT47" "$S" \
    '        if res is None or res.get("is_error"):' \
    '        if res is None:' \
    "a Read that failed would count as the lookup."

mutant worktree-copy-ignored "FT48" "$S" \
    '    return bool(rel) and (p == rel or p.endswith(os.sep + rel))' \
    '    return False' \
    "reading the register in a worktree, which is where it is edited, would not count."

mutant heading-not-checked "FT35" "$S" \
    '        if after.startswith(want):' \
    '        if True:' \
    "a real number followed by a heading from memory would pass: the one piece of evidence that the register, not recall, answered."

mutant any-number-exists "FT34" "$S" \
    '        heading = types.get(n)' \
    '        heading = types.get(n) or "something invented"' \
    "a type number the register does not have would count."

mutant new-type-on-say-so "FT38" "$S" \
    '    b_ok = bool(verbatim) or (says_new and bool(new_headings))' \
    '    b_ok = bool(verbatim) or says_new' \
    "saying \"new type\" would be enough, with no number allocated and nothing recorded under it."

mutant earlier-text-ignored "FT44" "$S" \
    '    reply = "\n".join(facts["texts"] + [payload.get("last_assistant_message") or ""])' \
    '    reply = payload.get("last_assistant_message") or ""' \
    "an answer given at the top of the turn, before the tool calls, would not count."

mutant old-commit-counts "FT39" "$S" \
    '        if start is not None and ct < start - COMMIT_SKEW_S:{NL}            continue' \
    '        if False:{NL}            continue' \
    "any register commit ever made would satisfy (c), so nothing would have to be recorded for THIS instance."

mutant any-file-commit-counts "FT40" "$S" \
    '"--format=%H %ct", "--", rel])' \
    '"--format=%H %ct"])' \
    "a commit this turn to any other file in the record would satisfy (c)."

mutant main-only "FT41" "$S" \
    '["log", "--all", "--max-count=200"' \
    '["log", "--max-count=200"' \
    "a record committed in a workspace, not yet landed, would not count, and that is where it is usually written."

mutant no-prompt-id-guessed "FT53" "$S" \
    '    if not prompt_id:{NL}        stop_status("cannot"' \
    '    if False:{NL}        stop_status("cannot"' \
    "a payload with no prompt_id would be judged on whatever the analyzer made of it instead of being declared unchecked, for that reason."

# --- 5. THE DEBT -------------------------------------------------------------
mutant stands-down-on-refire "FT43" "$S" \
    '    session = payload.get("session_id") or ""{NL}    prompt_id = payload.get("prompt_id")' \
    '    if payload.get("stop_hook_active"):{NL}        stop_status("none", "refire"){NL}        return 0{NL}    session = payload.get("session_id") or ""{NL}    prompt_id = payload.get("prompt_id")' \
    "the engine's usual Stop pattern: one refusal per turn, then waved through. This gate breaks it deliberately."

mutant debt-forgiven "FT45" "$S" \
    '    save_pending(entity, session, obligations){NL}    lines = [' \
    '    save_pending(entity, session, []){NL}    lines = [' \
    "a turn the host ended over the block cap would take the obligation with it: the one path by which an answer could stay unrecorded."

mutant debt-never-cleared "FT45" "$S" \
    '    if a_ok and b_ok and c_ok:{NL}        save_pending(entity, session, [])' \
    '    if a_ok and b_ok and c_ok:{NL}        pass' \
    "a paid obligation would be demanded again on every later turn."

# --- 6. THE WRAPPER ----------------------------------------------------------
mutant never-blocks "FT30" "$G" \
    '        [ "$RC" = "2" ] && exit 2' \
    '        true' \
    "the analyzer would find the missing steps and the hook would let the turn end anyway."

mutant silent-standdown "FT52" "$G" \
    'if [ "$CHECK_FAILURE_TYPE" = "0" ]; then' \
    'if false; then' \
    "an opt-out nobody can see decays into a rumor."

mutant silent-cannot "FT51" "$G" \
    '    cannot){NL}' \
    '    cannot){NL}        exit 0{NL}' \
    "a turn that could not be checked would look exactly like a turn that passed."

mutant silent-satisfied "FT33" "$G" \
    '        printf '"'"'{"suppressOutput":true,"systemMessage":"%s"}\n'"'"' "$_J"' \
    '        :' \
    "the person would never see that the lookup and the record happened, only that nothing complained."

mutation_end
