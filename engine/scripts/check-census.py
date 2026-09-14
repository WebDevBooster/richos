#!/usr/bin/env python3
"""check-census.py — FOR EVERY REGISTERED CHECK: DOES A FINDING CHANGE WHAT HAPPENS?

===========================================================================
WHY THIS EXISTS
===========================================================================
Asked by the CEO, 2026-09-14, out of failure type AB (the detector that never
misses and never intervenes), richos-hq/docs/verification/
lifecycle-failure-record-2026-09-13.md §10l:

    "for each check in this engine, does a refusal, a hold, or a re-open
     follow from a finding — or does it only say so? That census is cheap and
     would separate the controls from the instruments."

The failure it comes from: of the 14 escalation records whose title names a
false premise, 10 carry `state: work-complete`. The engineer re-derives the
lead's premise, finds it false, and finishes the job anyway. A perfect
detector wired to nothing is indistinguishable, in outcome, from no detector
— except that it produces a record which makes everyone feel covered.

===========================================================================
THE THREE COLUMNS, AND WHY "CAN IT ACT?" IS NOT ENOUGH
===========================================================================
1. Does a finding change what happens?  Two independent facts decide it, and
   BOTH are required:
     (a) THE HOST'S CEILING. What the host does with a refusal on the event
         the check is registered on. A PostToolUse hook cannot refuse
         anything whatever its exit code — the tool already ran. This is a
         property of the EVENT, not of the code, and no amount of code
         changes it.
     (b) THE CODE'S PATH. Whether the check has a refusal site that is
         reached because of a FINDING, as opposed to one reached because the
         check itself is broken (a missing library, an absent python3, an
         unparseable payload). A check that exits 2 only when it cannot run
         refuses nothing about the thing it watches.
   The second is the one that matters, and it is the one a "does it exit 2?"
   grep gets wrong: most of the exit-2 sites in the registered hooks are
   fail-closed self-failure, not findings. The report prints both counts.

2. If it acts, is the action waivable, and by which named marker?

3. If waivable, how often has the hatch ACTUALLY been taken? A control whose
   refusal carries a hatch that is always taken is an instrument wearing a
   control's clothes. Counted from the hatch ledgers, which are discovered by
   scripts/hooks/notice-waiver-repetition.py — IMPORTED here rather than
   reimplemented, because a second copy of ledger discovery is the defect
   class this engine keeps finding in itself.

===========================================================================
NOTHING HERE IS TYPED. WHAT IS DECLARED IS DECLARED WITH ITS EVIDENCE.
===========================================================================
The population comes from hooks/hooks.json. The refusal sites come from the
sources. The ledgers come from the guards. The waiver counts come from disk.

Exactly one table is a constant: EVENT_ACT, what the host does with a refusal
on each event. That cannot be derived from this repository — it is a property
of Claude Code — so every row carries its evidence and a `verified` flag, and
the report prints the unverified rows as unverified rather than burying them.
Two rows are measured in this repository, in the files cited; the rest are
not, and say so.

===========================================================================
USAGE
===========================================================================
    check-census.py --engine-root R [--entity-root E]
                    [--format table|tsv|json] [--sites]

Exit 0 always. THIS FILE IS AN INSTRUMENT AND SAYS SO. Whatever refuses on
the strength of it is a separate mechanism, deliberately — the argument for
that split is in docs/verification/check-census-2026-09-14.md.
"""

import argparse
import importlib.util
import json
import os
import re
import sys


# ==========================================================================
# THE ONE CONSTANT — what the HOST does with a refusal, per event
# ==========================================================================
# act:      refuses-call | refuses-turn-end | refuses-completion |
#           refuses-prompt | none
# verified: True only where THIS repository holds the measurement.
EVENT_ACT = {
    "PreToolUse": (
        "refuses-call", True,
        "In production continuously; the refusal text and the blocked call are "
        "the engine's daily experience (CLAUDE.md records four blocked spawns "
        "in one session, 2026-09-06). The contract is documented at "
        "scripts/hooks/guard-worktree-isolation.sh line 222."),
    "Stop": (
        "refuses-turn-end", True,
        "MEASURED: scripts/lib/stop-hook-notice.sh lines 44-47 — 'the turn was "
        "still refused (the hook re-fired, which only happens after a block)'."),
    "PostToolUse": (
        "none", True,
        "MEASURED: scripts/hooks/notice-claim-capability.sh lines 248-262 and "
        "scripts/hooks/detect-nonnative-worktree.sh line 96 — exit 2 reaches "
        "the AUTHOR under a 'BLOCKING ERROR' banner and refuses nothing; the "
        "tool has already run."),
    "TaskCompleted": (
        "refuses-completion", False,
        "UNVERIFIED. Claimed by scripts/hooks/task-completed-handoff.sh line 12 "
        "('a refused proof exits 2 so the native task remains open') and by "
        "nothing else. No probe in this repository measures it."),
    "UserPromptSubmit": (
        "refuses-prompt", False,
        "UNVERIFIED in this repository. Host-documented; no engine hook relies "
        "on it — the one registered hook is declared NON-BLOCKING."),
    "SubagentStop": (
        "refuses-turn-end", False,
        "UNVERIFIED in this repository. Assumed to mirror Stop; no registered "
        "hook exercises it."),
    "SessionStart": ("none", False, "UNVERIFIED; no refusal semantics known."),
    "SessionEnd": ("none", False, "UNVERIFIED; no refusal semantics known."),
    "SubagentStart": ("none", False, "UNVERIFIED; no refusal semantics known."),
    "TeammateIdle": ("none", False, "UNVERIFIED; no refusal semantics known."),
}

ACT_RANK = {
    "none": 0,
    "refuses-prompt": 1,
    "refuses-completion": 2,
    "refuses-turn-end": 3,
    "refuses-call": 4,
}


# ==========================================================================
# SELF-FAILURE VOCABULARY — derived from the corpus, not invented
# ==========================================================================
# The engine's fail-closed exits announce themselves in a small, repeated set
# of shapes. Clustering the exit-2 sites by the identical text of their five
# preceding code lines puts 80 of 221 in six fragments that appear in five or
# more different files — the shared bootstrap, byte-identical by design
# (contract-integrity-probe.sh Layer R asserts exactly that). The vocabulary
# below was read off those clusters and the singleton fail-closed sites beside
# them; `--sites` prints every classification with its file and line so any one
# of them can be checked by hand.
#
# A site is SELF-FAILURE when the text it emits says the check could not run.
# Everything else is a FINDING refusal.
SELF_FAILURE = re.compile(
    r"BROKEN INSTALL"
    r"|root_failure_banner"
    r"|is missing(?: at)?\b"
    r"|python3 (?:is )?required|python3 required"
    r"|fail-closed"
    r"|refusing unevaluated"
    r"|unexpected .{0,40}output"
    r"|cannot tell|cannot run|could not|unable to"
    r"|command -v "
    r"|unreadable|not found|resolver is missing"
    r"|failed to|failed;",
    re.I)

# A refusal, however it is spelled. `exit 2` is the engine's form throughout;
# the JSON forms are checked too so a future hook that uses them is not read
# as silent.
REFUSAL_LINE = re.compile(
    r"\bexit\s+2\b"
    r'|"permissionDecision"\s*:\s*"deny"'
    r'|"decision"\s*:\s*"block"')

PERSON_CHANNEL = re.compile(r"systemMessage|stop_notice_abnormal|stop_notice_normal")
AUTHOR_CHANNEL = re.compile(r"additionalContext")

# LEDGER WRITES THE IMPORTED DISCOVERY CANNOT SEE, and why the fallback is
# needed rather than tidy. notice-waiver-repetition.py's scan finds an append
# by its LINE — `>>`, append_log, open(..,"a"). The worker-lifecycle hooks build
# their path with os.path.join on one line and append on another, inside an
# inline python heredoc, so the scan attributes worker-events.jsonl and
# inflight-notices.jsonl to NO writer — they show up in its own
# "on disk, claimed by no guard" list. Reading those hooks as INERT would be
# the census committing the error it exists to find, so a file that names a
# ledger AND contains an append idiom anywhere is credited with that ledger.
# It is deliberately NOT fed back into hatch classification: whether a ledger
# is an escape hatch stays the imported module's verdict, in one place.
LEDGER_NAME = re.compile(r"(?<![-$\w/.])([a-z0-9][a-z0-9._-]*\.(?:log|jsonl))")
APPEND_IDIOM = re.compile(r">>|append_log|append_line|open\([^)]*,\s*[\"']a")

CONTEXT_LINES = 6


def strip_comment_lines(lines):
    """Index-preserving: comment-only lines become empty, so line numbers hold."""
    out = []
    for line in lines:
        out.append("" if line.strip().startswith("#") else line)
    return out


# ==========================================================================
# population
# ==========================================================================
def registrations(engine_root):
    """[(event, matcher, script_rel_or_None, raw_command)] from hooks/hooks.json."""
    path = os.path.join(engine_root, "hooks", "hooks.json")
    with open(path) as fh:
        doc = json.load(fh)
    rows = []
    for event, matchers in doc["hooks"].items():
        for m in matchers:
            matcher = m.get("matcher", "*")
            for hk in m.get("hooks", []):
                cmd = hk.get("command", "")
                mm = re.search(r"\$\{CLAUDE_PLUGIN_ROOT\}/(\S+?)(?:\"|\s|$)", cmd)
                rel = mm.group(1).rstrip('"') if mm else None
                rows.append((event, matcher, rel, cmd))
    if not rows:
        raise SystemExit("check-census.py: hooks/hooks.json yielded NO "
                         "registration — the parser is broken, not the engine")
    return rows


# ==========================================================================
# per-check derivation
# ==========================================================================
def analyze_source(engine_root, rel):
    with open(os.path.join(engine_root, rel), errors="replace") as fh:
        raw = fh.read().splitlines()
    code = strip_comment_lines(raw)
    sites = []
    for i, line in enumerate(code):
        if not line.strip() or not REFUSAL_LINE.search(line):
            continue
        ctx = []
        j = i - 1
        while j >= 0 and len(ctx) < CONTEXT_LINES:
            t = code[j].strip()
            if t:
                ctx.append(t)
            j -= 1
        window = "\n".join(reversed(ctx)) + "\n" + line.strip()
        kind = "self-failure" if SELF_FAILURE.search(window) else "finding"
        sites.append({"line": i + 1, "kind": kind, "text": line.strip()[:120]})
    body = "\n".join(code)
    named = sorted(set(LEDGER_NAME.findall(body))) if APPEND_IDIOM.search(body) else []
    return {
        "sites": sites,
        "finding_sites": [s for s in sites if s["kind"] == "finding"],
        "self_sites": [s for s in sites if s["kind"] == "self-failure"],
        "person_channel": bool(PERSON_CHANNEL.search(body)),
        "author_channel": bool(AUTHOR_CHANNEL.search(body)),
        "named_ledgers": named,
    }


def import_waiver_module(engine_root):
    path = os.path.join(engine_root, "scripts", "hooks",
                        "notice-waiver-repetition.py")
    spec = importlib.util.spec_from_file_location("nwr", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def ledger_map(engine_root):
    """file-rel -> [(ledger, is_hatch)] — inverted from the waiver analyzer's
    own source-side discovery. Imported, never re-derived."""
    mod = import_waiver_module(engine_root)
    ledgers, notes = mod.discover_from_source(engine_root)
    by_file = {}
    dropped = []
    for name, rec in ledgers.items():
        for writer in rec["writers"]:
            rel, lineno = writer.rsplit(":", 1)
            # THE IMPORTED SCAN DOES NOT STRIP COMMENTS, and one attribution in
            # the live engine is wrong because of it: inflight-waivers.jsonl is
            # credited to notice-waiver-repetition.py:457, which is a COMMENT
            # describing how the real writer resolves its path
            # (scripts/lib/inflight.py:500, reached from
            # guard-inflight-notify.sh). So the waiver report names the watcher
            # as the owner of a hatch it does not write. Verified, not assumed:
            #   sed -n '457p' scripts/hooks/notice-waiver-repetition.py
            #   grep -rn inflight-waivers scripts/ --include=*.sh --include=*.py
            # This census drops an attribution whose site is a comment line and
            # says which, rather than inheriting a row it knows is false.
            try:
                with open(os.path.join(engine_root, rel), errors="replace") as fh:
                    line = fh.read().splitlines()[int(lineno) - 1]
            except (OSError, IndexError, ValueError):
                line = ""
            if line.strip().startswith("#"):
                dropped.append("%s -> %s (comment line)" % (writer, name))
                continue
            by_file.setdefault(rel, [])
            if (name, rec["hatch"]) not in by_file[rel]:
                by_file[rel].append((name, rec["hatch"]))
    if dropped:
        notes = list(notes) + ["attribution dropped, site is a comment: "
                               + "; ".join(sorted(dropped))]
    return by_file, ledgers, notes, mod


def ledger_sizes(mod, entity_root):
    """ledger basename -> entries on disk, using the analyzer's own disk scan."""
    teams_root = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    teams_root = os.path.join(teams_root, "teams")
    dirs = mod.state_dirs_for(entity_root, teams_root)
    on_disk = mod.discover_on_disk(dirs)
    sizes = {}
    for name, paths in on_disk.items():
        total = 0
        for path in paths:
            try:
                with open(path, errors="replace") as fh:
                    total += sum(1 for line in fh if line.strip())
            except OSError:
                pass
        sizes[name] = total
    return sizes, dirs


# ==========================================================================
# classification
# ==========================================================================
def classify(rec):
    """The one verdict the CEO asked for, in his words: does a refusal, a hold
    or a re-open follow from a finding — or does it only say so?"""
    if rec["host_act"] != "none" and rec["finding_sites"]:
        return "CONTROL"
    # Everything below refuses nothing about the thing it watches. The
    # `fail_closed` column, not the class, carries "it exits 2 when it is
    # itself broken" — that is a property of every well-built check here and
    # says nothing about its authority over a finding.
    if rec["person_channel"]:
        return "INSTRUMENT (person)"
    if rec["author_channel"]:
        return "INSTRUMENT (author)"
    if rec["hatch_ledgers"] or rec["record_ledgers"]:
        return "RECORD"
    return "INERT"


NAME_CLAIMS_CONTROL = re.compile(r"^(guard-|verify-|scan-)")
NAME_CLAIMS_INSTRUMENT = re.compile(
    r"^(notice-|observe-|detect-|snapshot-|reader-|session-start-|engine-status)")


def name_claim(base):
    if NAME_CLAIMS_CONTROL.search(base):
        return "control"
    if NAME_CLAIMS_INSTRUMENT.search(base):
        return "instrument"
    return "unstated"


def build(engine_root, entity_root):
    regs = registrations(engine_root)
    by_file, ledgers, notes, mod = ledger_map(engine_root)
    sizes, state_dirs = ledger_sizes(mod, entity_root)

    checks = {}
    inline = []
    for event, matcher, rel, cmd in regs:
        if rel is None:
            inline.append((event, matcher, cmd))
            continue
        c = checks.setdefault(rel, {"rel": rel, "events": [], "matchers": []})
        c["events"].append(event)
        c["matchers"].append(matcher)

    rows = []
    for rel, c in sorted(checks.items()):
        src = analyze_source(engine_root, rel)
        led = list(by_file.get(rel, []))
        # A hook's predicate often lives in a sibling .py. Its ledgers and its
        # channels belong to the check, not to a second row nobody registered.
        sibling = rel[:-3] + ".py"
        if rel.endswith(".sh") and os.path.exists(os.path.join(engine_root, sibling)):
            led += [x for x in by_file.get(sibling, []) if x not in led]
            sib = analyze_source(engine_root, sibling)
            src["person_channel"] = src["person_channel"] or sib["person_channel"]
            src["author_channel"] = src["author_channel"] or sib["author_channel"]
        acts = [EVENT_ACT.get(e, ("none", False, "UNKNOWN EVENT"))
                for e in sorted(set(c["events"]))]
        best = max(acts, key=lambda a: ACT_RANK.get(a[0], 0))
        rec = {
            "check": os.path.basename(rel),
            "path": rel,
            "events": sorted(set(c["events"])),
            "matchers": sorted(set(c["matchers"])),
            "host_act": best[0],
            "host_act_verified": best[1],
            "finding_sites": src["finding_sites"],
            "self_sites": src["self_sites"],
            "person_channel": src["person_channel"],
            "author_channel": src["author_channel"],
            "hatch_ledgers": [n for n, h in led if h],
            "record_ledgers": sorted(set([n for n, h in led if not h]
                                         + src["named_ledgers"])
                                     - {n for n, h in led if h}),
            "fail_closed": bool(src["self_sites"]),
        }
        rec["class"] = classify(rec)
        rec["name_claim"] = name_claim(rec["check"])
        acts_like = "control" if rec["class"] == "CONTROL" else "instrument"
        rec["name_agrees"] = (rec["name_claim"] == "unstated"
                              or rec["name_claim"] == acts_like)
        rec["waivers"] = {n: sizes.get(n, 0) for n in rec["hatch_ledgers"]}
        rows.append(rec)

    for event, matcher, cmd in inline:
        act = EVENT_ACT.get(event, ("none", False, ""))
        rows.append({
            "check": "<inline echo in hooks.json>", "path": "hooks/hooks.json",
            "events": [event], "matchers": [matcher],
            "host_act": act[0], "host_act_verified": act[1],
            "finding_sites": [], "self_sites": [],
            "person_channel": False,
            "author_channel": "additionalContext" in cmd,
            "hatch_ledgers": [], "record_ledgers": [], "fail_closed": False,
            "class": "INSTRUMENT (author)" if "additionalContext" in cmd else "INERT",
            "name_claim": "unstated", "name_agrees": True, "waivers": {},
        })

    return {
        "engine_root": engine_root,
        "entity_root": entity_root,
        "registrations": len(regs),
        "checks": sorted(rows, key=lambda r: (r["class"], r["check"])),
        "state_dirs": state_dirs,
        "discovery_notes": notes,
        "all_hatch_ledgers": {n: sizes.get(n, 0)
                              for n, r in sorted(ledgers.items()) if r["hatch"]},
    }


# ==========================================================================
# rendering
# ==========================================================================
def render_table(rep, show_sites=False):
    out = []
    a = out.append
    a("=== check census — does a finding change what happens? ===")
    a("")
    a("  engine root    : %s" % rep["engine_root"])
    a("  entity root    : %s" % (rep["entity_root"] or "(none)"))
    a("  registrations  : %d" % rep["registrations"])
    a("  distinct checks: %d" % len(rep["checks"]))
    a("")
    counts = {}
    for r in rep["checks"]:
        counts[r["class"]] = counts.get(r["class"], 0) + 1
    a("  BY CLASS")
    for k in sorted(counts):
        a("    %-30s %d" % (k, counts[k]))
    a("")
    hdr = "%-38s %-24s %-20s %-7s %s" % (
        "check", "event(s)", "class", "sites", "hatch (entries on disk)")
    a("  " + hdr)
    a("  " + "-" * len(hdr))
    for r in rep["checks"]:
        hatch = ", ".join("%s=%d" % (n, r["waivers"][n])
                          for n in r["hatch_ledgers"])
        if not hatch:
            hatch = "-" if r["class"] == "CONTROL" else (
                ", ".join(r["record_ledgers"]) or "-")
        mark = "" if r["name_agrees"] else "   <-- NAME DISAGREES"
        a("  %-38s %-24s %-20s %-7s %s%s" % (
            r["check"][:38], ",".join(r["events"])[:24], r["class"],
            "%d/%d" % (len(r["finding_sites"]),
                       len(r["finding_sites"]) + len(r["self_sites"])),
            hatch[:44], mark))
        if show_sites:
            for s in r["finding_sites"]:
                a("        finding      %s:%d  %s" % (r["path"], s["line"], s["text"][:70]))
            for s in r["self_sites"]:
                a("        self-failure %s:%d  %s" % (r["path"], s["line"], s["text"][:70]))
    a("")
    a("  'sites' is finding-refusals / all refusal sites in the check's source.")
    a("")
    a("  HOST CEILING PER EVENT — the rows NOT measured in this repository:")
    for ev, (act, ver, _why) in sorted(EVENT_ACT.items()):
        if not ver:
            a("    %-18s %-20s UNVERIFIED" % (ev, act))
    a("")
    if rep["discovery_notes"]:
        a("  LEDGER DISCOVERY NOTES: " + "; ".join(rep["discovery_notes"]))
    return "\n".join(out)


def render_tsv(rep):
    out = ["check\tevents\tclass\thost_act\thost_act_verified\tfinding_sites\t"
           "self_failure_sites\tperson_channel\tauthor_channel\trecords\thatches\twaivers\t"
           "name_claim\tname_agrees"]
    for r in rep["checks"]:
        out.append("\t".join([
            r["check"], ",".join(r["events"]), r["class"], r["host_act"],
            str(r["host_act_verified"]), str(len(r["finding_sites"])),
            str(len(r["self_sites"])), str(r["person_channel"]),
            str(r["author_channel"]), ",".join(r["record_ledgers"]) or "-",
            ",".join(r["hatch_ledgers"]) or "-",
            ",".join("%s=%d" % (k, v) for k, v in sorted(r["waivers"].items())) or "-",
            r["name_claim"], str(r["name_agrees"])]))
    return "\n".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--engine-root", required=True)
    ap.add_argument("--entity-root", default="")
    ap.add_argument("--format", default="table", choices=["table", "tsv", "json"])
    ap.add_argument("--sites", action="store_true")
    args = ap.parse_args(argv)

    rep = build(os.path.abspath(args.engine_root), args.entity_root)
    if args.format == "json":
        print(json.dumps(rep, indent=2, sort_keys=True))
    elif args.format == "tsv":
        print(render_tsv(rep))
    else:
        print(render_table(rep, args.sites))
    return 0


if __name__ == "__main__":
    sys.exit(main())
