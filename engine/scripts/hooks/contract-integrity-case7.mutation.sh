#!/usr/bin/env bash
#
# contract-integrity-case7.mutation.sh — PROVES CASE 7 CAN FAIL, CLAUSE BY CLAUSE.
#
# ===========================================================================
# WHY THIS EXISTS
# ===========================================================================
# On 2026-09-15 case 7 of contract-integrity.test.sh was REPLACED. It had
# asserted that install.sh leaves `.claude/settings.local.json` byte-identical,
# which was true of every install.sh that had ever existed until `3b76bf86`
# deliberately made the `hooks` key GENERATED from hooks/hooks.json. `main` was
# red for a contradiction rather than a defect.
#
# The obvious replacement — "install.sh may write that file" — would have
# turned a real assertion into a permission slip. So the replacement pins FIVE
# properties instead of one, and the moment a test gets more specific it also
# gets easier to write in a way that cannot fail. A case that flags nothing
# passes on every build, looks like coverage, and is worth less than no case at
# all because it reports coverage that is not there.
#
# THIS FILE IS THE ANSWER TO "HOW DO YOU KNOW CASE 7 STILL BITES?"
#
# ===========================================================================
# IT TESTS THE SHIPPED ASSERTION, NOT A COPY OF IT
# ===========================================================================
# The python block is EXTRACTED from contract-integrity.test.sh at run time,
# between its own heredoc markers, and executed over crafted fixtures. A copy
# would agree with the original on the day it was written and drift silently
# afterwards, which is the duplicated-inventory defect this engine has paid for
# repeatedly. Edit the case and this harness tests the edit.
#
# ===========================================================================
# WHY FIXTURES RATHER THAN MUTATING install.sh
# ===========================================================================
# The first attempt mutated the real install.sh and ran `--only base` per
# mutant. Two of five mutants reported neither PASS nor FAIL for case 7,
# because they broke an EARLIER case in the section — emptying `env` makes
# install.sh refuse on its next run, and reformatting the file moves the
# sidecar hashes — so the suite never reached case 7. Those were INVALID
# MUTANTS, not a weak assertion, and each one cost 130 seconds to discover.
#
# Worse, the very first version of that harness APPENDED its mutation to
# install.sh, which ends with an explicit `exit 0` on its last line. Not one
# mutation ever executed. It reported all four mutants "NOT CAUGHT" — a
# harness measuring nothing and announcing the assertion was weak.
#
# Fixtures make each clause violable in isolation, in under a second, with no
# way for one clause's mutant to be swallowed by another's side effect.
#
# THE POSITIVE CONTROL IS NOT OPTIONAL. Without it, an assertion block that
# refused EVERYTHING would flag all eight mutants and look perfect.
#
# Run directly: scripts/hooks/contract-integrity-case7.mutation.sh
# Exit 0 = every clause of case 7 is proven load-bearing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_FILE="$SCRIPT_DIR/contract-integrity.test.sh"

[ -f "$TEST_FILE" ] || { echo "FATAL: missing $TEST_FILE" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is required" >&2; exit 2; }

python3 - "$TEST_FILE" <<'PY'
import json, os, re, shutil, subprocess, sys, tempfile

test_file = sys.argv[1]
src = open(test_file, encoding="utf-8").read()
m = re.search(r'C7_OUT="\$\(python3 - "\$ROOT" <<\'PY\'\n(.*?)\nPY\n\)"', src, re.S)
if not m:
    # NOT a pass. If the block cannot be found, this harness proved nothing and
    # must say so rather than exiting 0 over an empty set of mutants.
    sys.stderr.write(
        "FATAL: could not extract case 7's assertion block from %s.\n"
        "This harness verified NOTHING. Either the case was renamed or its heredoc\n"
        "markers changed; fix the extraction rather than deleting this file.\n" % test_file)
    sys.exit(2)
BLOCK = m.group(1)

PLUGIN = {"hooks": {
    "PreToolUse": [{"matcher": "Bash", "hooks": [
        {"type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/hooks/guard-a.sh"}]}],
    "Stop": [{"matcher": "", "hooks": [
        {"type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/hooks/guard-b.sh"}]}],
}}
SEATED = {
    "env": {"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"},
    "worktree": {"baseRef": "head"},
    "hooks": {
        "PreToolUse": [{"matcher": "Bash", "hooks": [
            {"type": "command", "command": "$CLAUDE_PROJECT_DIR/scripts/hooks/guard-a.sh"}]}],
        "Stop": [{"matcher": "", "hooks": [
            {"type": "command", "command": "$CLAUDE_PROJECT_DIR/scripts/hooks/guard-b.sh"}]}],
    },
}


def deep(o):
    return json.loads(json.dumps(o))


def run(before, after1, after2):
    root = tempfile.mkdtemp(prefix="case7-mutation.")
    try:
        os.makedirs(os.path.join(root, "hooks"))
        for name, doc in (("settings.before.json", before), ("settings.after1.json", after1),
                          ("settings.after2.json", after2)):
            with open(os.path.join(root, name), "w", encoding="utf-8") as fh:
                json.dump(doc, fh)
        with open(os.path.join(root, "hooks", "hooks.json"), "w", encoding="utf-8") as fh:
            json.dump(PLUGIN, fh)
        r = subprocess.run([sys.executable, "-c", BLOCK, root], capture_output=True, text=True)
        return (r.stdout + r.stderr).strip()
    finally:
        shutil.rmtree(root, ignore_errors=True)


cases = []

# THE POSITIVE CONTROL: the behavior install.sh is SUPPOSED to have. `hooks`
# replaced with the correct transform, every other key untouched, idempotent.
ctl = deep(SEATED)
ctl["hooks"] = {"PreToolUse": []}     # the fixture's approximate seated surface
cases.append(("CONTROL  only `hooks` changed, correctly", True,
              run(ctl, deep(SEATED), deep(SEATED))))

a = deep(SEATED); a["newKey"] = 1
cases.append(("7a  a top-level key is ADDED", False, run(deep(SEATED), a, deep(a))))

a = deep(SEATED); del a["worktree"]
cases.append(("7a  a top-level key is DROPPED", False, run(deep(SEATED), a, deep(a))))

a = deep(SEATED); a["env"] = {}
cases.append(("7b  `env` is rewritten (the AGENT_TEAMS flag)", False,
              run(deep(SEATED), a, deep(a))))

a = deep(SEATED); a["worktree"]["baseRef"] = "main"
cases.append(("7b  `worktree.baseRef` is rewritten", False, run(deep(SEATED), a, deep(a))))

a = deep(SEATED)
a["hooks"]["PreToolUse"][0]["hooks"][0]["command"] = "/Users/someone/repo/scripts/hooks/guard-a.sh"
cases.append(("7c  the $CLAUDE_PROJECT_DIR placeholder is RESOLVED", False,
              run(deep(SEATED), a, deep(a))))

a = deep(SEATED); a["hooks"]["Stop"] = []
cases.append(("7d  a REGISTERED hook is missing from the seated surface", False,
              run(deep(SEATED), a, deep(a))))

a = deep(SEATED)
a["hooks"]["Stop"].append({"matcher": "x", "hooks": [
    {"type": "command", "command": "$CLAUDE_PROJECT_DIR/scripts/hooks/ghost.sh"}]})
cases.append(("7d  an UNREGISTERED hook is seated", False, run(deep(SEATED), a, deep(a))))

a2 = deep(SEATED); a2["hooks"]["Stop"].append({"matcher": "nonce", "hooks": []})
cases.append(("7e  a second install run changes the file again", False,
              run(deep(SEATED), deep(SEATED), a2)))

print("=== contract-integrity case 7: every clause, against the SHIPPED assertion ===")
wrong = []
for label, expect_clean, out in cases:
    clean = (out == "")
    ok = (clean == expect_clean)
    print("  %-8s %-52s %s" % ("PASS" if ok else "FAIL", label,
                               "not flagged" if clean else "flagged"))
    if not clean and not expect_clean:
        print("           -> %s" % out.splitlines()[0][:96])
    if not ok:
        wrong.append(label)

print("")
if wrong:
    print("=== case 7 mutations: %d of %d NOT load-bearing ===" % (len(wrong), len(cases)))
    for w in wrong:
        print("  - %s" % w)
    sys.exit(1)
print("=== case 7 mutations: all %d clauses load-bearing ===" % len(cases))
PY
