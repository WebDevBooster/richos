#!/usr/bin/env bash
#
# scratch-reaper.mutation.sh — EVERY SAFETY THIS REAPER CLAIMS, REMOVED ONE AT
#                              A TIME, WITH THE SUITE WATCHED GOING RED.
#
# ===========================================================================
# WHY THIS FILE IS NOT OPTIONAL FOR THIS PARTICULAR PROGRAM
# ===========================================================================
# scratch-reaper.test.sh is, in the main, a suite of things that must NOT
# happen: a live session's scratch survives, a registered workspace survives, a
# checkout survives, an undecidable verdict survives. EVERY ONE OF THOSE CASES
# PASSES PERFECTLY AGAINST A REAPER THAT DELETES NOTHING AT ALL, and a reaper
# that deletes nothing is the state this whole mechanism was ordered to end.
#
# So a green suite over a deleter proves nothing until somebody has watched
# each guarantee go red for the right reason. Each mutant below removes exactly
# one property from a THROWAWAY COPY of the engine — the shipped file is never
# opened for writing — and asserts that the suite fails AT THE NAMED CASE.
#
#   M1  the liveness check, gutted           -> S1  (a live session is deleted)
#   M2  INDETERMINATE collapsed into dead    -> S3
#   M3  wall 3, the registered workspaces    -> S2
#   M4  wall 2, the .git in the tree         -> S4
#   M5  the log write                        -> S5
#   M6  --dry-run deletes                    -> S6
#   M7  an undeclared threshold gets a default instead of a refusal -> S9
#   M8  a held temp workspace treated as abandoned -> S10b
#   M9  the orphan rule's "a running process could own this" -> S7b
#   M10 the nightly retention                -> S8
#
# M1 IS THE ONE THE BRIEF ASKED FOR AND IT IS THE RIGHT ONE TO ASK FOR: it guts
# the two places that read "is this session running" and demands that the suite
# then reports a LIVE SESSION'S SCRATCH DELETED. A liveness check that has
# quietly stopped working is invisible from every other angle — the program
# still runs, still logs, still ends with a verdict line, and deletes somebody's
# work while they are using it.
#
# Run from scratch-reaper.test.sh's own section of contract-integrity.test.sh,
# for the reason scripts/lib/mutation-harness.sh gives: a *.mutation.sh is not
# discovered by the *.test.sh runner, and eight harnesses in this engine were
# once run by nothing at all.

set -uo pipefail
ENGINE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/mutation-harness.sh
. "$ENGINE_ROOT/scripts/lib/mutation-harness.sh"

mutation_begin "scratch-reaper safety properties" "scripts/scratch-reaper.test.sh"

LIB="scripts/lib/scratch-reaper.py"

mutant M1.liveness-gutted "S1 " "$LIB" \
    "if session_id in self.running:{AND}if name in self.live.running:" \
    "if False:{AND}if False:" \
    "With both readings of the running set removed, a session whose process is
     alive and whose session file names it must be reported as deleted."

mutant M2.indeterminate-collapsed "S3 " "$LIB" \
    "if cutoff is not None and newest_mtime >= cutoff:" \
    "if False:" \
    "An unattributed running process no longer makes anything undecidable, so
     INDETERMINATE has been folded into dead — the 2026-08-31 defect exactly."

mutant M3.registered-wall-removed "S2 " "$LIB" \
    "if inside(reg, real) or inside(real, reg):" \
    "if False:" \
    "Wall 3 no longer recognizes a registered workspace, so an agent's
     workspace inside a dead session's scratch is deleted with it."

# THE ANCHOR MOVED ON 2026-09-18 AND THIS HARNESS CAUGHT IT, which is the whole
# reason a mutation harness asserts that its mutation applied. Wall 2 gained a
# narrowing parameter for the legacy families (`and not git_is_fixture`), and
# with the old one-line anchor this mutant reported
# "MUTATION TARGET ABSENT — the source has drifted" instead of silently
# scoring PROVEN against a line that no longer existed.
#
# The mutant still removes the WHOLE wall — `if False:` — rather than only the
# narrowing, because what S4 covers is "a checkout in dead scratch is refused",
# and the narrowing is proven separately by S11/S11b below.
mutant M4.git-wall-removed "S4 " "$LIB" \
    "if has_git and not git_is_fixture:" \
    "if False:" \
    "Wall 2 no longer notices a checkout in the tree, so a repository living
     in dead scratch is removed."

mutant M5.log-write-removed "S5 " "$LIB" \
    "write_log(log_path, lines)" \
    "pass" \
    "Deletions happen and nothing records them. 'Every deletion is on the
     record' is the half of the order that makes the other half auditable."

mutant M6.dry-run-deletes "S6 " "$LIB" \
    "    if args.apply:{NL}        deleted, freed, failures = reaper.apply(args.log or default_log())" \
    "    if True:{NL}        deleted, freed, failures = reaper.apply(args.log or default_log())" \
    "The plan deletes. A dry run that acts is worse than no dry run, because
     the next person reads it expecting to be shown rather than obeyed."

mutant M7.undeclared-gets-a-default "S9 " "$LIB" \
    "        v = (os.environ.get(name) or \"\").strip(){NL}        if not v:" \
    "        v = (os.environ.get(name) or \"\").strip() or \"60\"{NL}        if False:" \
    "An undeclared threshold silently becomes a number nobody chose — the
     third-party-default failure, arriving through the back door."

mutant M8.held-workspace-deleted "S10b" "$LIB" \
    "if holder:" \
    "if False:" \
    "A temp workspace a process is sitting in is treated as abandoned."

mutant M9.orphan-rule-inverted "S7b" "$LIB" \
    "if newest >= oldest_start:" \
    "if False:" \
    "A file written after a running session started is no longer that
     session's, so live working files in a scratch root are deleted."

mutant M10.nightly-retention-removed "S8 " "$LIB" \
    "if i < keep:" \
    "if False:" \
    "The declared retention keeps nothing, so every release and log is deleted
     including the newest."

# ===========================================================================
# THE 2026-09-18 ARMS — the allocator root, the legacy sweep and the Docker rule
# ===========================================================================
# THE WHOLE REASON THESE EXIST is that the reaper they extend was ALREADY
# INSTALLED AND RUNNING on the night 105 GB accumulated, and every one of its
# ten mutants above was green. A suite of green ticks over an arm that does not
# cover the thing that broke is exactly the failure this engine refuses, so each
# new arm gets a mutant that removes its load-bearing decision.

mutant M11.dead-owner-kept "S12 " "$LIB" \
    "if alive:{AND}            self.add(path, \"scratch-alloc\", size, DELETE, why)" \
    "if True:{AND}            pass" \
    "The allocator root no longer distinguishes a dead owner from a live one and
     never deletes an allocation — which is the 105 GB night restored exactly:
     a sweeper that runs, logs, ends with a verdict, and reclaims nothing."

mutant M12.live-owner-deleted "S12b" "$LIB" \
    "if alive:" \
    "if False:" \
    "A LIVE owner's sandbox is deleted from under a running harness. This is the
     one failure in this file that costs somebody's work rather than disk
     space."

mutant M13.unrecorded-child-spared "S12c" "$LIB" \
    "pid = row.get(\"pid\") or pid_from_name(name)" \
    "pid = row.get(\"pid\") or os.getpid()" \
    "An unrecorded child of the allocator root inherits the SWEEPER's own pid,
     which is always alive, so deny-by-default becomes allow-by-default and
     anything that skipped the ledger lives forever."

mutant M14.registered-wall-bypassed-for-legacy "S14c" "$LIB" \
    "refused = walls.check(path, has_git,{NL}                              git_is_fixture=self.cfg[\"legacy_git_is_fixture\"])" \
    "refused = \"\"" \
    "The legacy arm stops consulting the walls at all, so a REGISTERED
     WORKSPACE wearing a legacy family name is deleted. This is the mutant that
     proves the wall-2 narrowing did not quietly take wall 3 with it."

mutant M15.legacy-open-handle-ignored "S15 " "$LIB" \
    "if self.held_in_snapshot(path, snapshot):" \
    "if False:" \
    "A legacy directory a process is actively writing into is treated as
     abandoned — which for a running 181-minute mutation pass means its sandbox
     is deleted underneath it."

mutant M16.docker-daemon-probe-removed "S16 " "$LIB" \
    "if probe.returncode != 0 or not probe.stdout.strip():" \
    "if False:" \
    "The sweep stops checking whether the daemon answers, so a laptop with
     Docker Desktop shut down reports a prune failure on every scheduled run —
     the six-hourly false alarm that trains its reader to skip the log."

mutant M17.docker-age-filter-dropped "S16e" "$LIB" \
    "\"until=\" + until]," \
    "\"until=0h\"]," \
    "The 30-day window becomes zero, so \`image prune -a\` reaches EVERY
     unreferenced image including one built minutes ago. The age filter is the
     only thing that makes -a safe, and this is what removing it looks like."

mutant M18.docker-prune-order-reversed "S16d" "$LIB" \
    "for args, klass in jobs:" \
    "for args, klass in reversed(jobs):" \
    "Images are pruned BEFORE containers, so every image pinned by a months-old
     exited container survives the image stage and the sweep silently reclaims
     far less than its log implies. This is the CEO's own caveat — stopped
     containers pin images — turned into a defect."

mutant M19.failed-deletion-forgotten "S17 " "$LIB" \
    "rows = read_failures(failures_path())" \
    "rows = {}" \
    "A deletion that FAILED is forgotten between runs, so the failed rmtree's
     own mtime bump hides the garbage behind the age floor and the next run
     reports ok with the tree still on disk. Measured live on 2026-09-18: five
     failures, then failures=0 with all five still there."

mutant M20.unstick-unbounded "S18c" "$LIB" \
    "and e.klass in _UNSTICKABLE_CLASSES" \
    "and True" \
    "The uchg-clearing stops being bounded to machine-made harness scratch and
     reaches a SESSION's scratchpad, overriding a file a person pinned on
     purpose instead of reporting it."

mutant M21.alloc-open-handle-ignored "S19 " "$LIB" \
    "if name in snapshot:" \
    "if False:" \
    "The ALLOCATOR arm stops consulting the open-file table, so a tree whose
     owning pid is dead is deleted while a live process is reading it. This is
     the defect as it actually shipped — reproduced on the real allocator root
     before the fix, deleting 2.0 MB under a live tail -f — and the mutant
     proves the wall that replaced it is what keeps S19 green rather than some
     other accident of ordering."

mutant M22.holder-blind-to-contents "S20 " "$LIB" \
    "args = [\"lsof\", \"+D\", path, \"-t\", \"-n\", \"-P\", \"-w\"]" \
    "args = [\"lsof\", \"-t\", \"-n\", \"-P\", \"-w\", \"--\", path]" \
    "holder() goes back to asking who has the DIRECTORY NODE open instead of who
     has a file open inside it — which on this OS answers 'nobody' about a tree a
     live process is writing into. The wall is present, consulted, and given a
     false answer, which is the subtler half of the same defect.

     IT IS ASSERTED AGAINST S20 AND NOT S19, and finding that out was worth the
     mutant on its own. Targeted at S19 it FAILED as 'red, but not here' — S19
     stays GREEN under this mutation, because its KEEP comes from the cached
     whole-machine snapshot (name in snapshot), which never calls holder() at
     all. What actually depends on holder() telling the truth is the
     TEST-INSTANCE override: with the node form it cannot see which process
     holds the tree, so the holder set reads 'unknown', the override declines,
     and the stray app keeps its scratch alive for ever. So the two walls are
     independent, and only S20 is evidence about this line."

mutant M23.test-instance-holder-not-quit "S20 " "$LIB" \
    "if held_by == \"test-instances\":" \
    "if False:" \
    "A stray test instance of the app once again makes its own scratch immortal:
     held -> KEEP, on every run, for ever. Observed for real while this was
     written. The mutant proves S20 is green because the override exists, not
     because the tree happened to be swept by some other arm."

# ===========================================================================
# THE DENY-BY-DEFAULT TEMP ARM (Frank's D1/D2) — every condition, one at a time
# ===========================================================================
# THIS ARM IS THE ONE MOST IN NEED OF THIS FILE. It is the arm that decides
# whether to delete something NOBODY DECLARED, which means there is no name list
# to read it back off and no test that fails "by accident" if it stops working.
# Its whole coverage is invisible from the outside: an arm that silently reverts
# to skipping is indistinguishable from a clean machine, which is precisely how
# 56,770 entries came to be invisible in the first place.

mutant M24.deny-by-default-off "S21 " "$LIB" \
    "                if self.cfg[\"deny_by_default\"]:" \
    "                if False:" \
    "The \`continue\` is back: a \$TMPDIR name matching neither declared pattern
     list is skipped rather than decided. This is D1 exactly as it shipped — not
     kept, not deleted, never looked at — and the mutant proves S21 is green
     because the arm runs and not because some other arm caught the fixture."

# ASSERTED AGAINST S21h AND NOT S21g, and the harness is what found that out.
# Aimed at S21g it reported "red, but not here": S21g only asks whether the fresh
# tree survived, and with the proof removed THE AGE FLOOR CATCHES THE SAME TREE —
# it is zero minutes old, the floor is an hour — so it survives for a different
# reason and the case stays green. Only S21h, which reads WHICH REASON the KEEP
# carried, can see the proof has gone. Same lesson as M22, and the same lesson as
# the DST defect M30 pins: a case that checks only the outcome is blind to a
# guarantee being replaced by a coincidence.
mutant M25.session-proof-removed "S21h" "$LIB" \
    "        if newest >= oldest:" \
    "        if False:" \
    "The one PROOF this arm has is gone: a tree written after the earliest
     running session started is no longer that session's. Nothing is left but an
     age, and an age is what the whole program refuses to delete on."

mutant M26.foreign-keeplist-ignored "S21d" "$LIB" \
    "if any(fnmatch.fnmatch(name, pat) for pat in self.cfg[\"foreign_patterns\"]):" \
    "if False:" \
    "The keep-list stops being consulted, so ANOTHER PROGRAM'S temp directory is
     a candidate. Deny-by-default without the keep-list is not coverage, it is a
     reaper that deletes Xcode's and VS Code's working files."

mutant M27.unknown-open-handle-ignored "S21l" "$LIB" \
    "        if name in held:" \
    "        if False:" \
    "The new arm stops consulting the open-file table — D5 one arm across. A tree
     an undeclared harness is still reading is deleted from under it."

mutant M28.shared-root-not-swept "S21i" "$LIB" \
    "        for root in self.cfg[\"shared_tmp_roots\"]:" \
    "        for root in []:" \
    "The declared shared temp roots are never enumerated, so /private/tmp goes
     back to being swept by nothing at all. That is D2, and it was 25.77 GiB."

mutant M29.unknown-floor-ignored "S21n" "$LIB" \
    "        if age < unknown_floor:" \
    "        if False:" \
    "The declared floor for an undeclared family is not applied, so the session
     proof is left standing alone and a directory written five minutes before the
     only running session started is deleted."

# M30 IS A REGRESSION PIN ON A DEFECT FOUND BY THIS PASS, not on a wall.
# lstart_epoch used mktime(...) - time.timezone, which is the zone's STANDARD
# offset and does not move for daylight saving — so in DST it returned every
# process start one hour EARLY. Measured on this machine: error -3600 s exactly.
# It failed in the safe direction (things were kept that could have been swept),
# which is why nothing noticed for as long as it existed.
#
# IT IS ASSERTED AGAINST S21o, AND THAT IS THE POINT OF THE CASE. S21n only
# checks the tree is still there, and it stays green under this mutation — an
# hour-early start time keeps the tree for the WRONG reason. Only a case that
# reads WHICH REASON the KEEP carried can see the difference.
mutant M30.lstart-dst-offset "S21o" "$LIB" \
    "        return calendar.timegm(time.strptime(text, \"%a %b %d %H:%M:%S %Y\"))" \
    "        return int(time.mktime(time.strptime(text, \"%a %b %d %H:%M:%S %Y\")) - time.timezone)" \
    "Every session process is reported as having started an hour before it did,
     so 'nothing running can own this' is answered against a clock that is wrong
     for half the year."

# ===========================================================================
# THE GARBAGE ALARM (Frank's Fix 2) — the reporting is a safety, not a comfort
# ===========================================================================
# It is tempting to treat a report as untestable decoration. It is the opposite
# here: the CEO's rule has two halves and this IS the second one. A mechanism that
# cannot say "there is garbage here and nobody is coming for it" satisfies §54
# only for the paths it already sweeps, which was the whole of Frank's verdict.

# THE ANCHOR MOVED ONCE ALREADY AND THE HARNESS SAID SO RATHER THAN SCORING
# GREEN — "MUTATION TARGET ABSENT — the source has drifted" — when skipped() was
# rewritten to key on Entry.standing instead of matching a sentence in the report.
# That assertion is the reason a stale mutant is a failure here and not a silent
# pass against a line that no longer exists.
mutant M31.skipped-not-counted "S22 " "$LIB" \
    "        return len(rows), sum(e.size for e in rows)" \
    "        return 0, 0" \
    "The skipped count is always zero, so a pile of garbage nothing will ever
     collect reports as an empty one. This is the shape the mechanism was in
     before Fix 2: 1.13 GB on this machine, and every report green."

mutant M32.failure-not-in-exit-code "S22c" "$LIB" \
    "    if n_failures:{NL}        return 4" \
    "    if False:{NL}        return 4" \
    "A run in which every deletion failed hands launchd a green exit again — D10
     exactly, where \`applied: deleted=0 freed=0 B\` and EXIT=0 were
     indistinguishable from a run with nothing to do."

mutant M33.notice-reruns-the-expensive-arm "S22i" "$LIB" \
    "        reaper.skip_unknown_arm = bool(args.notice)" \
    "        reaper.skip_unknown_arm = False" \
    "The SessionStart banner attempts the deny-by-default arm again, so every
     session start pays for it and prints \"44,851 entries were NOT MEASURED
     within the budget\" for ever. A line that is always true is wallpaper, and
     wallpaper is how the real signal comes to be skipped."

mutant M34.garbage-alarm-ignores-threshold "S22j" "$LIB" \
    "        if sb >= cfg[\"skipped_notice_bytes\"]:" \
    "        if True:" \
    "The garbage alarm fires whatever the declared threshold says, which is the
     cries-wolf failure: an alarm that always speaks is one somebody switches
     off, and then the mechanism is back to silence with extra steps."

# ===========================================================================
# D11 — a name-derived pid is attribution, not liveness
# ===========================================================================

mutant M35.name-pid-trusted-as-liveness "S23 " "$LIB" \
    "        if from_ledger:{NL}            return True, \"\"" \
    "        if True:{NL}            return True, \"\"" \
    "A pid taken off a DIRECTORY NAME skips the two name-shape tests, so
     \`1-frank-immortal-b\` is immortal again: pid 1 belongs to root and started
     before every directory on the machine, and the KEEP is silent by
     construction because a KEEP is the reaper working as designed."

mutant M36.pid-reuse-not-detected "S23c" "$LIB" \
    "        if born is not None and start is not None and start > born + 1:" \
    "        if False:" \
    "A process that started AFTER the directory was created is accepted as its
     owner, which is precisely what pid reuse looks like. macOS recycles pids at
     99998, so this is the ordinary way a week-old name comes to match a live
     process."

# M37 IS THE MUTANT THAT FOUND A DEFECT INSTEAD OF PROVING A PROPERTY, and the
# note is worth more than the mutant. Written against the original shape — where
# `if from_ledger:` returned pid_alive() and skipped EVERY test — it reported "the
# suite still PASSED without this property", which sent me back to the code with a
# better question than the one I had asked.
#
# What I found there was `scan_scratch_root`'s own comment claiming that TTL "lets
# a row whose pid has been REUSED by an unrelated process still age out". It does
# not: a live pid returns KEEP two lines before TTL is consulted, so a ledger row
# from three days ago whose pid now belongs to an unrelated live process was
# immortal in exactly the way `1-frank-immortal-b` was. THE COMMENT DESCRIBED A
# SAFETY THE PROGRAM DID NOT HAVE.
#
# So the reuse test was moved ABOVE the ledger exemption — it is a fact about the
# filesystem and the process table rather than a question of trust — and S23f is
# the case for it. This mutant now proves what the exemption itself is worth.
mutant M37.ledger-row-subjected-to-the-name-tests "S23e" "$LIB" \
    "            alive, why_pid = self.owner_state(pid, bool(row), path)" \
    "            alive, why_pid = self.owner_state(pid, False, path)" \
    "A LEDGER ROW is put through the two NAME-SHAPE tests — the uid test and the
     pid floor — which exist because digits in a directory name can be chosen by
     anybody. The row was written by our own process at allocation time, so its
     uid is implied; treating it as a guess means a legitimately recorded owner
     can be dismissed and its live sandbox deleted."

mutant M38.ledger-pid-reuse-not-detected "S23f" "$LIB" \
    "        if born is not None and start is not None and start > born + 1:" \
    "        if not from_ledger and born is not None and start is not None and start > born + 1:" \
    "The reuse test is skipped FOR A LEDGER ROW ONLY, which is the state the
     program was in when its own comment claimed TTL covered this. A three-day-old
     row whose pid now belongs to an unrelated live process is immortal. S23c
     stays green under this mutation, because a name-derived reuse is still caught
     — which is what makes S23f the case that is actually about this line."

# ===========================================================================
# D3 — declared campaign roots under ~/ab
# ===========================================================================

mutant M39.campaign-root-deleted "S24 " "$LIB" \
    "                self.add(path, \"campaign-root\", size, KEEP,{NL}                         \"A DECLARED CAMPAIGN ROOT PAST ITS RETENTION" \
    "                self.add(path, \"campaign-root\", size, DELETE,{NL}                         \"A DECLARED CAMPAIGN ROOT PAST ITS RETENTION" \
    "A campaign root is DELETED automatically. Every one of them holds a checkout,
     which is wall 2 everywhere else in this program, and these are 13-19 GB of
     somebody's campaign under ~/ab. §54's second branch exists for exactly this
     case: report it and a person removes it."

mutant M40.campaign-root-not-nominated "S24b" "$LIB" \
    "        for name in names:{NL}            for path in sorted(glob.glob(os.path.join(parent, name))):" \
    "        for name in []:{NL}            for path in sorted(glob.glob(os.path.join(parent, name))):" \
    "The declared campaign roots are never enumerated, so the piles under ~/ab go
     back to being seen by no arm of the mechanism at all. That is D3, and it was
     18.90 GB plus 13.75 GB."

mutant M41.standing-keep-hidden "S24b" "$LIB" \
    "            if e.action == KEEP and not verbose and not e.standing:" \
    "            if e.action == KEEP and not verbose:" \
    "A STANDING keep — kept, and a person has to act on it — is hidden behind
     --verbose again, so the only channel that reports it is one nobody runs. The
     report says nothing and the pile stays; reporting that nobody reads is the
     same as not reporting."

mutation_end
