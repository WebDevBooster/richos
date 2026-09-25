#!/usr/bin/env bash
#
# operator-leads.mutation.sh: PROVES operator-leads.test.sh WOULD CATCH THE CLAIM,
# THE SHARED-WRITES GUARD OR THE LIVE-NAME GUARD GOING WRONG (richos-hq spec r3
# (e) the claim, e3, e5; r4 §2.4; Frank G11). Each mutant removes ONE property
# from a throwaway copy of the engine and demands that the NAMED case go red. The
# loop is scripts/lib/mutation-harness.sh.
#
# Run directly: scripts/hooks/operator-leads.mutation.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/mutation-harness.sh
. "$ENGINE_ROOT/scripts/lib/mutation-harness.sh"

mutation_begin "the operator claim, shared writes and live names" "scripts/hooks/operator-leads.test.sh"

L="scripts/lib/operator_leads.py"
M="scripts/lib/operator-mode.sh"

# --- the switch -------------------------------------------------------------
mutant switch-always-on "C0c " "$M" \
    '    [ "$marker" = 1 ] || return 1{NL}    return "$on"' \
    '    return 0' \
    "e8: with the switch off every hook would start its check on every call of his terminal."
mutant python-switch-ignored "C0d " "$L" \
    '    conf, _paths = OF.launcher_for(entity){NL}    return OF.fenced(conf)' \
    '    conf, _paths = OF.launcher_for(entity){NL}    return True' \
    "e8: the checks themselves would act with the switch off whenever they are reached."

# --- the claim ----------------------------------------------------------------
mutant claim-not-idempotent "C2 " "$L" \
    '                if any(p["pid"] == who["pid"] and p["start"] == who["start"] for p in alive):' \
    '                if False:' \
    "r4 §2.4: every compaction and resume would rewrite the claim; the hook must do nothing for a session already in it."
mutant sdk-counts-as-terminal "C3 " "$L" \
    '    if not entry or entry.startswith("sdk-"):' \
    '    if not entry:' \
    "F6: a print-mode lead would claim as his terminal and lock the app out of his team."
mutant worktrees-count-as-terminal "C4 " "$L" \
    '    return not inside(cwd, os.path.join(entity, ".claude", "worktrees"))' \
    '    return True' \
    "r3 (e) item 1: a session seated in a teammate's worktree is not his terminal."
mutant app-claim-ignored-at-start "C5 " "$L" \
    '            if state == "app":{NL}                return system_message(app_running_text(rec,' \
    '            if False:{NL}                return system_message(app_running_text(rec,' \
    "item 2: a terminal opened while the app runs his team would take the claim from under it."
mutant guard-refuses-nothing "C6a " "$L" \
    '        return refuse(unreadable_text(reason, what)){NL}    return refuse(app_running_text(rec, what))' \
    '        return refuse(unreadable_text(reason, what)){NL}    return 0' \
    "item 7: the terminal would run his team beside the app."
mutant lease-command-unseen "C6a " "$L" \
    '        if "land-lease.sh" in command and any(v in command for v in (" acquire", " takeover")):' \
    '        if False:' \
    "item 7: the terminal could take the land lease while the app's leads land."
mutant memory-write-unseen "C6a " "$L" \
    '        if memory_dir_of(path):{NL}            return "write to your memory"' \
    '        if False:{NL}            return "write to your memory"' \
    "item 7: the terminal could write his memory while the app's leads write it."
mutant wrapper-drops-refusal "C6a " "scripts/hooks/guard-operator-claim.sh" \
    '    printf '"'"'%s\n'"'"' "$_goc_err" >&2{NL}    exit 2' \
    '    printf '"'"'%s\n'"'"' "$_goc_err" >&2{NL}    exit 0' \
    "the wrapper would print the refusal and let the call through."
mutant stop-refused "C6d " "$L" \
    'TEAM_TOOLS = ("Agent", "SendMessage")' \
    'TEAM_TOOLS = ("Agent", "SendMessage", "TaskStop")' \
    "§67: a stop in his terminal would wait on, or be refused by, a claim file."
mutant app-lead-refused "C7 " "$L" \
    '    if not claim_id or not who or state != "app" or rec.get("claim_id") != claim_id:{NL}        return False' \
    '    if True:{NL}        return False' \
    "item 4: the app's own leads would be refused as if they were a second terminal."
mutant wrong-claim-id-accepted "C7 " "$L" \
    '    if not claim_id or not who or state != "app" or rec.get("claim_id") != claim_id:' \
    '    if not claim_id or not who or state != "app":' \
    "item 4: any session carrying a stale or invented claim id would pass as an app lead."
mutant unreadable-is-free "C8 " "$L" \
    '    if kind == "unreadable":{NL}        return "unreadable", None, reason' \
    '    if kind == "unreadable":{NL}        return "none", None, ""' \
    "item 6: an unreadable claim must be held, never read as nobody's."
mutant dead-claim-counts-as-live "C9 " "$L" \
    '    return [p for p in (rec or {}).get("processes") or [] if OF.alive(p["pid"], p["start"])]' \
    '    return [p for p in (rec or {}).get("processes") or []]' \
    "item 3: a claim whose processes have all ended would hold his team forever."
mutant only-cli-is-terminal "C10 " "$L" \
    '    if not entry or entry.startswith("sdk-"):' \
    '    if entry != "cli":' \
    "G11: his team run from an IDE or desktop entrypoint would not count as the terminal."

# --- e3 -----------------------------------------------------------------------
mutant memory-lease-not-taken "S1 " "$L" \
    '    memory = memory_dir_of(path){NL}    if memory:{NL}        ok, holder = take_memory_lease' \
    '    memory = memory_dir_of(path){NL}    if False:{NL}        ok, holder = take_memory_lease' \
    "e3: two leads would write his memory at the same moment and one line would be lost."
mutant fresh-lease-counts-as-stale "S3 " "$L" \
    '    if age > MEMORY_LEASE_STALE or age < -60:' \
    '    if True:' \
    "e3: a live, fresh lease would be taken over instead of waited for."
mutant dead-holder-waited-for "S4 " "$L" \
    '    if isinstance(pid, int) and isinstance(start, int) and not OF.alive(pid, start):' \
    '    if False:' \
    "e3: a lease whose session ended would hold every other write for its full 5 s."
mutant same-call-waits "S5 " "$L" \
    '            return True, None                           # the same call, delivered again' \
    '            pass' \
    "e3: a hook delivered twice for one call would wait on its own lease."
mutant record-unfenced "S7 " "$L" \
    '    ok, lease = OF.authorized(OF.Files(conf)){NL}    if ok:' \
    '    ok, lease = OF.authorized(OF.Files(conf)){NL}    if True:' \
    "e3: a lead without the land lease would write the shared record under another lead's land."
mutant prefix-not-checkout "S8 " "$L" \
    '    if not paths or not paths["main"] or paths["gitdir"] != paths["common"]:{NL}        return None{NL}    conf = OF.read_launcher' \
    '    if not paths or not paths["main"]:{NL}        return None{NL}    conf = OF.read_launcher' \
    "Frank G1 point 3: every teammate's write in a native worktree would be refused."
mutant ignored-not-exempt "S8 " "$L" \
    '    rc, _out, _err = OF.git(paths["main"], "check-ignore", "-q", "--", real){NL}    if rc == 0:' \
    '    rc, _out, _err = OF.git(paths["main"], "check-ignore", "-q", "--", real){NL}    if False:' \
    "e3: a gitignored scratch file in a main checkout would need the land lease."
mutant failure-not-registered "R1 " "hooks/hooks.json" \
    '    "PostToolUseFailure": [' \
    '    "PostToolUseFailureRetired": [' \
    "e3: a write refused by a sibling guard would hold his memory for 5 s at every refusal."

# --- e5 -----------------------------------------------------------------------
mutant other-session-name-free "N1 " "$L" \
    '        finished, _paused, why = W.finished_state(rec, cache){NL}        if not finished:' \
    '        finished, _paused, why = W.finished_state(rec, cache){NL}        if False:' \
    "e5: a stop, a message or a land naming the agent would reach two agents."
mutant own-session-checked-here "N2 " "$L" \
    '        if rec.get("name") != name or not rec.get("session_id") or rec.get("session_id") == session_id:' \
    '        if rec.get("name") != name or not rec.get("session_id"):' \
    "e5 is about OTHER sessions; this session's names are clause 3's."
mutant finished-holds-name "N3 " "$L" \
    '        finished, _paused, why = W.finished_state(rec, cache){NL}        if not finished:' \
    '        finished, _paused, why = W.finished_state(rec, cache){NL}        if True:' \
    "e5: a name would stay taken forever after its agent finished."

mutation_end
