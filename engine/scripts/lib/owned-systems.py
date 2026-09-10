#!/usr/bin/env python3
"""owned-systems.py — THE STANDING-OWNERSHIP PREDICATE.

Every other mechanism in this engine is triggered by an ACT: a spawn, a land, a
commit, a turn ending. This one is triggered by nothing at all, which is the
whole point — the defects the founder found himself on 2026-09-10 were the ones
no act ever pointed at.

The argument for the inventory, and the inventory itself, are in
`owned-systems.declaration` at the engine root. Read that first. THIS FILE IS
THE PARSER, THE RUNNER AND THE VERDICT, and nothing else knows how a check is
decided.

===========================================================================
THE THREE VERDICTS, AND WHY THERE ARE THREE
===========================================================================
  HEALTHY    the declared check exited 0.
  UNHEALTHY  the declared check exited non-zero. Its output is the evidence,
             quoted, never summarized into a count.
  UNKNOWN    the check could not be run — its program is not on disk, or it
             overran its declared budget, or the interpreter is missing.

UNKNOWN IS NOT A THIRD KIND OF HEALTHY. This project has shipped a scanner
reporting CLEAN over an empty corpus, a runner reporting all-passed over a
suite it never invoked, and a probe layer green over a guard that refused to
start. So an absent check counts as a state that stands, exactly like a red
one; it merely sorts BELOW a real red, because a genuine defect always
outranks a missing instrument when only one thing can be demanded at a time.

===========================================================================
AGE IS A FIRST-CLASS FIELD, AND IT IS WHY ROTATION CANNOT WORK
===========================================================================
"Red" without "for how long" is the fact that let thirteen days happen. So the
first moment each system is OBSERVED unhealthy is written down
(`.claude/state/owned-state-seen.json`) and cleared the moment it is observed
healthy again. The gate demands the OLDEST standing state, never the newest and
never a rotating one — an operator who acks whichever is cheapest today meets
the same item tomorrow, with the age counting up in front of him.

The clock starts at FIRST OBSERVATION, not at the defect's true birth, and that
is honest rather than convenient: the engine cannot know when CI first went red,
only when it first looked. The report says `first observed`, never `broken
since`.

===========================================================================
THE CACHE, AND WHY A GATE MAY NOT SPEND A MINUTE
===========================================================================
The checks cost real time — the reconciler walks 79 transactions, the CI
surface calls a network API. A PreToolUse hook that spends that on every
dispatch is a hook that gets switched off, and a switched-off gate protects
nothing forever. So the whole verdict is cached at
`.claude/state/owned-state-verdict.json` with a TTL, invalidated whenever the
declaration itself changes, and the gate stops at the session ledger BEFORE it
would run anything at all. The real-world cost is therefore: at most one check
sweep per session, at the first dispatch, and nothing after that.

A cached verdict always carries the time it was taken and the report prints it.
A stale answer presented as a fresh one is the failure this engine is named
after avoiding.

CLI
    owned-systems.py report   --entity R --engine E [--json] [--refresh]
    owned-systems.py demanded --entity R --engine E --session S [--json]
    owned-systems.py dispose  --entity R --session S --system ID
                              --how ack|addressed --reason TEXT [--agent A]

Exit codes
    report    0 every system in jurisdiction is healthy
              1 at least one is not (each named, with its evidence)
              2 the declaration could not be read — NEVER the same code as 0
    demanded  0 nothing is demanded of this session
              1 a system is demanded (printed)
              2 broken
    dispose   0 recorded · 2 refused
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time

DEFAULT_TIMEOUT = 45
DEFAULT_TTL = 900
STATE_DIR = os.path.join(".claude", "state")
SEEN_NAME = "owned-state-seen.json"
VERDICT_NAME = "owned-state-verdict.json"
ACK_LOG_NAME = "owned-state-acks.log"
DISPOSITION_LOG_NAME = "owned-state-dispositions.log"

HEALTHY = "HEALTHY"
UNHEALTHY = "UNHEALTHY"
UNKNOWN = "UNKNOWN"

# UNHEALTHY outranks UNKNOWN when one thing must be demanded: a real defect
# always beats a missing instrument. Within a rank, oldest first observation.
RANK = {UNHEALTHY: 0, UNKNOWN: 1, HEALTHY: 9}


def now():
    return time.time()


def iso(ts):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))


# ---------------------------------------------------------------------------
# THE DECLARATION
# ---------------------------------------------------------------------------

class DeclarationError(Exception):
    pass


def declaration_path(entity_root, engine_root):
    """The entity's own file if it ships one, else the engine's default.

    Named by OWNED_SYSTEMS_DECLARATION in orchestration.config, read with the
    same order every other consumer of that file uses: the entity's config,
    then the engine's, then the built-in default. One key, two possible homes,
    and the report always prints which file answered."""
    rel = None
    for cfg in (os.path.join(entity_root, "orchestration.config"),
                os.path.join(engine_root, "orchestration.config")):
        val = _config_value(cfg, "OWNED_SYSTEMS_DECLARATION")
        if val:
            rel = val
            break
    if not rel:
        rel = "owned-systems.declaration"
    if os.path.isabs(rel):
        return rel if os.path.isfile(rel) else None
    for root in (entity_root, engine_root):
        cand = os.path.join(root, rel)
        if os.path.isfile(cand):
            return cand
    return None


def _config_value(path, key):
    """LAST assignment wins, exactly as `. orchestration.config` would.

    The first version returned the FIRST match, which is what a reader
    naturally writes and is the opposite of what every other consumer of this
    file does — those source it in bash, where a later line overwrites an
    earlier one. Its own test suite caught it: a fixture that appended an
    override got the default back and a case asserting a missing declaration
    passed for the wrong reason. Two readers of one config with two different
    answers is the drift this whole layer exists to prevent."""
    found = None
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line.startswith(key + "="):
                    continue
                val = line[len(key) + 1:].strip()
                if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
                    val = val[1:-1]
                found = val
    except OSError:
        return None
    return found


def parse_declaration(path):
    """Blank-line-separated `key: value` records. A record with no `id:` and no
    `check:` is a malformed row and is REFUSED rather than skipped: a row that
    silently drops out of the inventory is the drift this file exists to end."""
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        raise DeclarationError("%s could not be read: %s" % (path, exc))

    records, cur, lineno_of = [], {}, {}
    lineno = 0
    for raw in text.splitlines():
        lineno += 1
        line = raw.rstrip()
        if line.startswith("#"):
            continue
        if not line.strip():
            if cur:
                records.append((cur, lineno_of.get("id", lineno)))
                cur, lineno_of = {}, {}
            continue
        if ":" not in line:
            raise DeclarationError(
                "%s line %d is neither a comment, a blank line nor `key: value`: %r"
                % (path, lineno, raw))
        key, val = line.split(":", 1)
        key = key.strip()
        if not cur:
            lineno_of["id"] = lineno
        cur[key] = val.strip()
    if cur:
        records.append((cur, lineno_of.get("id", lineno)))

    out = []
    for rec, ln in records:
        if "id" not in rec or "check" not in rec:
            raise DeclarationError(
                "%s: the record at line %d has no `id:` or no `check:`; a row that "
                "cannot be run must be fixed, never silently dropped" % (path, ln))
        try:
            timeout = int(rec.get("timeout", DEFAULT_TIMEOUT))
        except ValueError:
            raise DeclarationError(
                "%s: system '%s' declares timeout %r, which is not a number"
                % (path, rec["id"], rec.get("timeout")))
        # A LIST, because one code was not enough within hours of shipping.
        # scripts/ci-status.sh reserves TWO: 2 for "the surface could not be
        # established" and 3 for "the surface was established and something in
        # it is UNJUDGED" — a distinction its own header insists must never be
        # collapsed. A single-code field would have forced one of them to be
        # read as a finding.
        unknown_exit = []
        for tok in rec.get("unknown-exit", "").replace(",", " ").split():
            try:
                unknown_exit.append(int(tok))
            except ValueError:
                raise DeclarationError(
                    "%s: system '%s' declares unknown-exit %r, which is not a number"
                    % (path, rec["id"], tok))
        out.append({
            "id": rec["id"],
            "unknown_exit": unknown_exit,
            "title": rec.get("title", rec["id"]),
            "jurisdiction": rec.get("jurisdiction", ""),
            "check": rec["check"],
            "evidence": rec.get("evidence", ""),
            "match": rec.get("match", ""),
            "timeout": timeout,
            "why": rec.get("why", ""),
            "line": ln,
        })
    if not out:
        raise DeclarationError("%s declares no systems at all" % path)
    ids = [r["id"] for r in out]
    dupes = sorted({i for i in ids if ids.count(i) > 1})
    if dupes:
        raise DeclarationError(
            "%s declares the same id twice: %s. An id is what an ack names, so a "
            "duplicate makes an ack ambiguous." % (path, ", ".join(dupes)))
    return out


def expand(cmd, entity_root, engine_root):
    return cmd.replace("{entity}", entity_root).replace("{engine}", engine_root)


# ---------------------------------------------------------------------------
# RUNNING A CHECK
# ---------------------------------------------------------------------------

def _program_of(cmd):
    """The file a command would execute, when that is knowable without running
    it. `python3 X/y.py --flag` -> X/y.py; `bash X/y.sh` -> X/y.sh; a bare path
    -> itself. Anything else -> None, which means 'cannot be pre-checked' and
    the command is simply run."""
    parts = cmd.split()
    if not parts:
        return None
    if parts[0] in ("python3", "python", "bash", "sh", "zsh"):
        # `-c` means the program IS the argument, inline. Returning that string
        # as a path made every `bash -c '...'` row report "the declared check is
        # not on disk: 'echo" — a fixture in this file's own suite caught it,
        # and it is the exact shape of defect this engine keeps finding: a
        # verdict that looks authoritative and is about the wrong object.
        if "-c" in parts[1:]:
            return None
        for tok in parts[1:]:
            if tok.startswith("-"):
                continue
            return tok
        return None
    if "/" in parts[0]:
        return parts[0]
    return None


def choose_command(check_field, entity_root, engine_root):
    """PREFERENCE ORDER, and the report always says which one answered.

    ` :: ` separates alternatives. The first whose program exists on disk wins.
    If none exists, the FIRST is returned anyway, with present=False — so the
    refusal names the command that is supposed to exist rather than the
    fallback that also does not."""
    alts = [a.strip() for a in check_field.split(" :: ") if a.strip()]
    if not alts:
        return None, False, []
    expanded = [expand(a, entity_root, engine_root) for a in alts]
    for cmd in expanded:
        prog = _program_of(cmd)
        if prog is None or os.path.exists(prog):
            return cmd, True, expanded
    return expanded[0], False, expanded


def run(cmd, timeout, cwd):
    try:
        proc = subprocess.run(["bash", "-c", cmd], cwd=cwd, timeout=timeout,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    except subprocess.TimeoutExpired:
        return None, "the check overran its declared %ds budget" % timeout
    except OSError as exc:
        return None, "the check could not be started: %s" % exc
    return proc.returncode, proc.stdout.decode("utf-8", "replace")


def evidence_lines(output, pattern, limit=6):
    lines = [ln.rstrip() for ln in output.splitlines() if ln.strip()]
    if pattern:
        try:
            rx = re.compile(pattern)
        except re.error:
            rx = None
        if rx is not None:
            hit = [ln for ln in lines if rx.search(ln)]
            if hit:
                return hit[:limit]
    return lines[:4]


# ---------------------------------------------------------------------------
# STATE
# ---------------------------------------------------------------------------

def state_path(entity_root, name):
    return os.path.join(entity_root, STATE_DIR, name)


def _read_json(path, default):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def _write_json(path, doc):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(doc, fh, indent=2, sort_keys=True)
        os.replace(tmp, path)
        return True
    except OSError:
        return False


def update_seen(entity_root, results, at):
    """First observation per system, cleared on a healthy observation.

    Best-effort: a state directory that cannot be written must never turn a
    real verdict into a crash. An unwritable seen-file costs the AGE, not the
    finding, and the report says `age unknown` rather than inventing a zero."""
    path = state_path(entity_root, SEEN_NAME)
    seen = _read_json(path, {})
    if not isinstance(seen, dict):
        seen = {}
    changed = False
    for r in results:
        sid = r["id"]
        if r["status"] == HEALTHY:
            if sid in seen:
                del seen[sid]
                changed = True
            r["first_seen"] = None
        else:
            if sid not in seen:
                seen[sid] = at
                changed = True
            r["first_seen"] = seen.get(sid)
    if changed:
        _write_json(path, seen)
    return results


def session_dispositions(entity_root, session_id):
    """Every disposition recorded for THIS session, newest last.

    The ledger is append-only plain text for the same reason staging-record.sh
    is: it is read on a PreToolUse path, and a format with a parse-failure mode
    would make the gate's verdict depend on the parser."""
    path = state_path(entity_root, DISPOSITION_LOG_NAME)
    out = []
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                fields = dict()
                for part in line.rstrip("\n").split("\t"):
                    if "=" in part:
                        k, v = part.split("=", 1)
                        fields[k] = v
                if fields.get("session") and fields["session"] == session_id:
                    out.append(fields)
    except OSError:
        return []
    return out


def record_disposition(entity_root, session_id, system, how, reason, agent=""):
    """Append the disposition, and — when it is a WAIVER — to the ack ledger too.

    TWO EXPLICIT APPEND SITES, EACH NAMING ITS LEDGER ON ITS OWN LINE, and that
    is not style. notice-waiver-repetition.py discovers escape-hatch ledgers by
    reading every engine script for an append site whose target RESOLVES to a
    *.log basename — it has no typed list of ledgers, deliberately, because a
    typed list is the thing that falls behind. The first version of this
    function wrote both files from one loop over a variable, so the analyzer
    could not resolve either name and its own lint reported them as "ON DISK,
    CLAIMED BY NO GUARD". The gate's refusal text PROMISES the operator that a
    repeated excuse gets named, and that promise was false for as long as this
    loop was clever. Verified by running the lint, not by reading the analyzer.

    Both ledgers now classify as hatches, and the dispositions one is arguably
    over-classified because it also records dispatches that ADDRESSED a system,
    which are not waivers at all. That is the direction the analyzer's own
    header says it chooses to fail in: an over-classified record costs the
    operator a line he can dismiss, an under-classified hatch is a defect
    nobody is told about."""
    at = iso(now())
    row = "at=%s\tsession=%s\tsystem=%s\thow=%s\tagent=%s\treason=%s\n" % (
        at, session_id, system, how, agent, reason.replace("\t", " ").replace("\n", " "))
    ok = True

    disposition_path = state_path(entity_root, DISPOSITION_LOG_NAME)
    try:
        os.makedirs(os.path.dirname(disposition_path), exist_ok=True)
        with open(disposition_path, "a", encoding="utf-8") as fh:  # ledger: owned-state-dispositions.log
            fh.write(row)
    except OSError:
        ok = False

    if how == "ack":
        # The waiver ledger. An operator who gives the same reason for the same
        # system session after session is named by notice-waiver-repetition.py.
        ack_path = state_path(entity_root, ACK_LOG_NAME)
        try:
            os.makedirs(os.path.dirname(ack_path), exist_ok=True)
            with open(ack_path, "a", encoding="utf-8") as fh:  # ledger: owned-state-acks.log
                fh.write(row)
        except OSError:
            ok = False

    return ok


# ---------------------------------------------------------------------------
# THE SWEEP
# ---------------------------------------------------------------------------

def sweep(entity_root, engine_root, decl_path, systems):
    at = now()
    results = []
    for sysrec in systems:
        rec = {
            "id": sysrec["id"],
            "title": sysrec["title"],
            "why": sysrec["why"],
            "match": sysrec["match"],
        }
        jur = sysrec["jurisdiction"].strip()
        if jur:
            jcmd = expand(jur, entity_root, engine_root)
            jrc, _jout = run(jcmd, 20, entity_root)
            if jrc is None or jrc != 0:
                rec.update({"status": "OUT-OF-JURISDICTION", "via": jcmd,
                            "evidence": [], "exit": jrc})
                results.append(rec)
                continue
        cmd, present, alts = choose_command(sysrec["check"], entity_root, engine_root)
        rec["via"] = cmd
        rec["alternatives"] = alts
        if cmd is None:
            rec.update({"status": UNKNOWN, "exit": None, "evidence": [
                "this system declares no runnable check command"]})
            results.append(rec)
            continue
        if not present:
            rec.update({"status": UNKNOWN, "exit": None, "evidence": [
                "the declared check is not on disk: %s" % _program_of(cmd),
                "an absent check is not a passing check",
            ]})
            results.append(rec)
            continue
        rc, out = run(cmd, sysrec["timeout"], entity_root)
        if rc is None:
            rec.update({"status": UNKNOWN, "exit": None, "evidence": [out]})
        elif rc == 0:
            rec.update({"status": HEALTHY, "exit": 0, "evidence": []})
        elif rc in (sysrec.get("unknown_exit") or []):
            # The row DECLARES which exit code means "I could not decide".
            # It is per-row and not a global convention because the codes
            # genuinely disagree across the tools this inventory consumes:
            # escalate.sh reserves 2 for an unreadable ledger, while the ECS
            # capture status uses 2 for a real finding. A global rule would
            # have read one of them backwards, and reading a finding as
            # "unknown" is how a defect goes quiet.
            rec.update({"status": UNKNOWN, "exit": rc,
                        "evidence": evidence_lines(out, sysrec["evidence"]) or [
                            "the check exited %d, which this row declares as "
                            "'could not decide'" % rc]})
        else:
            rec.update({"status": UNHEALTHY, "exit": rc,
                        "evidence": evidence_lines(out, sysrec["evidence"])})
        results.append(rec)

    # EVERY judged system, not only the standing ones. Passing just the standing
    # list looks right and silently breaks the clearing half: a system that
    # healed would keep its first-observed stamp forever, so the day it went bad
    # again it would be reported as having been bad since the first time — an
    # age that is a lie, in a mechanism whose entire point is that age is true.
    # A row that is out of jurisdiction is left alone: not judged is not healed.
    judged = [r for r in results if r["status"] in (HEALTHY, UNHEALTHY, UNKNOWN)]
    update_seen(entity_root, judged, at)
    for r in results:
        r.setdefault("first_seen", None)
    return {
        "generated_at": iso(at),
        "generated_ts": at,
        "declaration": decl_path,
        "entity": entity_root,
        "engine": engine_root,
        "systems": results,
    }


def ordered_standing(doc):
    """Every standing state, worst-and-oldest first."""
    standing = [r for r in doc["systems"] if r["status"] in (UNHEALTHY, UNKNOWN)]
    return sorted(standing, key=lambda r: (RANK[r["status"]],
                                           r.get("first_seen") or 0,
                                           r["id"]))


def load_or_sweep(entity_root, engine_root, refresh, ttl):
    decl = declaration_path(entity_root, engine_root)
    if not decl:
        raise DeclarationError(
            "no owned-systems declaration was found under %s or %s (key "
            "OWNED_SYSTEMS_DECLARATION in orchestration.config)"
            % (entity_root, engine_root))
    cache_path = state_path(entity_root, VERDICT_NAME)
    if not refresh:
        cached = _read_json(cache_path, None)
        if isinstance(cached, dict) and cached.get("declaration") == decl:
            try:
                fresh = (now() - float(cached.get("generated_ts", 0))) < ttl
                same = float(cached.get("declaration_mtime", -1)) == os.path.getmtime(decl)
            except (OSError, TypeError, ValueError):
                fresh, same = False, False
            if fresh and same:
                cached["from_cache"] = True
                return cached
    systems = parse_declaration(decl)
    doc = sweep(entity_root, engine_root, decl, systems)
    try:
        doc["declaration_mtime"] = os.path.getmtime(decl)
    except OSError:
        doc["declaration_mtime"] = -1
    doc["from_cache"] = False
    _write_json(cache_path, doc)
    return doc


# ---------------------------------------------------------------------------
# REPORT — the positive probe
# ---------------------------------------------------------------------------

def age_text(first_seen):
    if not first_seen:
        return "age unknown"
    days = (now() - float(first_seen)) / 86400.0
    if days < 1:
        return "first observed %.1fh ago" % (days * 24)
    return "first observed %.1f days ago" % days


def render(doc):
    lines = []
    lines.append("OWNED SYSTEMS — %s" % doc["entity"])
    lines.append("  declaration : %s" % doc["declaration"])
    lines.append("  taken       : %s%s" % (
        doc["generated_at"], " (cached)" if doc.get("from_cache") else ""))
    lines.append("")
    standing = ordered_standing(doc)
    for r in doc["systems"]:
        mark = {HEALTHY: "ok      ", UNHEALTHY: "UNHEALTHY", UNKNOWN: "UNKNOWN ",
                "OUT-OF-JURISDICTION": "n/a     "}[r["status"]]
        lines.append("  [%s] %-13s %s" % (mark, r["id"], r["title"]))
        if r["status"] == "OUT-OF-JURISDICTION":
            lines.append("      not present in this repository (jurisdiction line did not hold)")
            continue
        lines.append("      via  : %s" % r.get("via"))
        if r["status"] == HEALTHY:
            continue
        lines.append("      state: %s, exit %s, %s" % (
            r["status"], r.get("exit"), age_text(r.get("first_seen"))))
        for ev in r.get("evidence", []):
            lines.append("      >    %s" % ev.strip())
        if r.get("why"):
            lines.append("      why  : %s" % r["why"])
    lines.append("")
    if not standing:
        lines.append("  Every system in jurisdiction is healthy.")
    else:
        lines.append("  %d system(s) standing. Oldest first: %s" % (
            len(standing), ", ".join(r["id"] for r in standing)))
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def cmd_report(args):
    try:
        doc = load_or_sweep(args.entity, args.engine, args.refresh, args.ttl)
    except DeclarationError as exc:
        sys.stderr.write("owned-systems: BROKEN — %s\n" % exc)
        return 2
    if args.json:
        print(json.dumps(doc, indent=2, sort_keys=True))
    else:
        print(render(doc))
    return 1 if ordered_standing(doc) else 0


def cmd_demanded(args):
    try:
        doc = load_or_sweep(args.entity, args.engine, args.refresh, args.ttl)
    except DeclarationError as exc:
        sys.stderr.write("owned-systems: BROKEN — %s\n" % exc)
        return 2
    standing = ordered_standing(doc)
    if not standing:
        return 0
    disposed = session_dispositions(args.entity, args.session)
    if disposed:
        return 0
    top = standing[0]
    out = {
        "demanded": top["id"],
        "title": top["title"],
        "status": top["status"],
        "age": age_text(top.get("first_seen")),
        "via": top.get("via"),
        "match": top.get("match", ""),
        "evidence": top.get("evidence", []),
        "why": top.get("why", ""),
        # EVERY standing system carries its own `match`, not just the demanded
        # one: a dispatch at ANY of them is motion toward an owned system, and
        # refusing that because it aimed at the second-oldest would be a gate
        # punishing the behavior it exists to produce.
        "others": [{"id": r["id"], "status": r["status"], "title": r["title"],
                    "match": r.get("match", ""),
                    "age": age_text(r.get("first_seen"))} for r in standing[1:]],
        "taken": doc["generated_at"],
        "from_cache": doc.get("from_cache", False),
    }
    print(json.dumps(out, indent=2, sort_keys=True))
    return 1


def cmd_dispose(args):
    if not args.system.strip():
        sys.stderr.write("owned-systems: dispose needs --system\n")
        return 2
    if args.how == "ack" and len(args.reason.strip()) < 15:
        sys.stderr.write("owned-systems: an ack needs a reason of at least 15 "
                         "characters; a bare marker exempts nothing\n")
        return 2
    ok = record_disposition(args.entity, args.session, args.system.strip(),
                            args.how, args.reason, args.agent)
    return 0 if ok else 2


def main(argv=None):
    ap = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p, need_engine=True):
        p.add_argument("--entity", required=True)
        if need_engine:
            p.add_argument("--engine", required=True)
        p.add_argument("--ttl", type=int, default=DEFAULT_TTL)
        p.add_argument("--refresh", action="store_true")

    p = sub.add_parser("report")
    common(p)
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_report)

    p = sub.add_parser("demanded")
    common(p)
    p.add_argument("--session", default="")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_demanded)

    p = sub.add_parser("dispose")
    p.add_argument("--entity", required=True)
    p.add_argument("--session", default="")
    p.add_argument("--system", required=True)
    p.add_argument("--how", choices=("ack", "addressed"), required=True)
    p.add_argument("--reason", default="")
    p.add_argument("--agent", default="")
    p.set_defaults(func=cmd_dispose)

    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
