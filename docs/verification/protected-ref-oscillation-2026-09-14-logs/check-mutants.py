#!/usr/bin/env python3
"""For every mutant I added or changed: does the anchor still apply, and does the
named python test go RED under it?

Usage: check-mutants.py <worktree>
"""
import os
import shutil
import subprocess
import sys
import tempfile

WT = sys.argv[1]
LIB = os.path.join(WT, "engine/scripts/lib/workspaces.py")
TEST = os.path.join(WT, "engine/scripts/lib/workspaces.test.py")

# (name, [(old, new)...], python test to run or None)
MUTANTS = [
    ("p14-moved-recorded-branch-not-reported",
     [("    _restore_protected_refs(rec, priors + bg_priors, latest)", "    pass")],
     "Point14_IntegrationBranch.test_point_14_a_recorded_branch_moved_in_an_agents_call_is_reported_and_left_alone"),
    ("p14-a-move-is-put-back-again",
     [("                if cur is not None:", "                if False:"),
      ('    return git(repo, "update-ref", "-m", msg, "--no-deref", "refs/heads/" + branch, tip, "")',
       '    return git(repo, "update-ref", "--no-deref", "refs/heads/" + branch, tip)')],
     "Point14_IntegrationBranch.test_point_14_the_engine_never_moves_the_recorded_branch_when_two_agents_run"),
    ("p14-the-restore-write-is-anonymous-and-unconditional",
     [('    return git(repo, "update-ref", "-m", msg, "--no-deref", "refs/heads/" + branch, tip, "")',
       '    return git(repo, "update-ref", "--no-deref", "refs/heads/" + branch, tip)')],
     "Point14_IntegrationBranch.test_point_02_the_restore_of_a_deleted_ref_is_create_only_and_never_clobbers"),
    ("p14-protected-set-keyed-by-name-across-repositories",
     [("    recorded = _protected_names(repo)",
       '    recorded = set(w["branch"] for w in all_bodies_of_work().values() if (w or {}).get("branch"))')],
     "Point14_IntegrationBranch.test_point_14_a_recorded_branch_is_protected_in_its_own_repository_only"),
    ("p14-the-leads-move-reported-too",
     [("                    else:\n                        continue                        # a descendant carrying none of the agent's work: the lead's land",
       '                    else:\n                        why = "moved"')],
     "Point14_IntegrationBranch.test_point_14_a_recorded_branch_moved_in_an_agents_call_is_reported_and_left_alone"),
    ("p14-end-of-run-reports-the-leads-land",
     [("                elif b not in windowed:\n                    continue",
       "                elif False:\n                    continue")],
     "Point14_IntegrationBranch.test_point_14_the_leads_land_after_the_agents_last_call_is_not_undone"),
    ("p02-codex-tips-not-snapshotted",
     [("            tips[repo] = _protected_tips(repo, refs)", "            tips[repo] = {}")],
     "Point14_IntegrationBranch.test_point_02_a_codex_ref_deleted_in_an_agents_call_is_restored_and_a_move_is_reported"),
]

src0 = open(LIB, encoding="utf-8").read()
bad = 0
for name, pairs, test in MUTANTS:
    src = src0
    applied = True
    for o, n in pairs:
        if o not in src:
            print("  FAIL  %-52s ANCHOR ABSENT: %s" % (name, o.strip()[:70]))
            applied = False
            bad += 1
            break
        src = src.replace(o, n, 1)
    if not applied:
        continue
    d = tempfile.mkdtemp(prefix="mut-" + name + "-")
    open(os.path.join(d, "workspaces.py"), "w", encoding="utf-8").write(src)
    shutil.copy(TEST, os.path.join(d, "workspaces.test.py"))
    r = subprocess.run([sys.executable, "workspaces.test.py", test], cwd=d,
                       capture_output=True, text=True)
    red = r.returncode != 0
    print("  %s  %-52s applies; named test %s" % ("PASS" if red else "FAIL", name,
                                                  "goes RED" if red else "STAYS GREEN (unproven!)"))
    if not red:
        bad += 1
        print(r.stdout[-800:])
    shutil.rmtree(d, ignore_errors=True)

print("\n%d mutant(s) checked, %d not proven" % (len(MUTANTS), bad))
sys.exit(1 if bad else 0)
