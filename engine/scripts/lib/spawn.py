#!/usr/bin/env python3
"""spawn.py - STARTING ONE TEAMMATE IS ONE COMMAND THAT EITHER SUCCEEDS OR NAMES
EVERY PROBLEM BEFORE ANYTHING IS CREATED.

The page: docs/plans/worktree-spec-2026-09-11.md. The registry: workspaces.py.
The command: scripts/spawn.sh.

===========================================================================
WHY THIS EXISTS - CEO, 2026-09-13, his third time asking
===========================================================================
  "it was taking you 10 fucking minutes to spin up one fucking agent properly
   at the beginning of the session. how much longer do I fucking have to wait
   for that retarded fuckshit to be fixed once and forever?"

Starting one teammate was FOUR commands plus a hand-authored JSON file, with at
least four independent ways to fail AFTER work had already begun:

  1. create-teammate-worktree.sh <ABSOLUTE-repo> <name>
       - refused a bare repository name                     (one round trip)
       - refused with "no branch is recorded as the one this work integrates
         on", naming a SECOND command to run first          (one round trip)
       - the richos record was STALE: it named dev/workspace-spec, deleted from
         the remote, so it needed --correct                 (one round trip)
  2. a hand-written JSON input file
  3. prepare-agent-spawn.py --file <input.json>  (adds the ack contract, runs
     no guard at all)
  4. the tool call - where the PreToolUse[Agent] guards finally run, so a
     wording mistake in the brief surfaced only at the very end, one refusal
     per attempt.

On one brief, on one night, that cost: two refusals from
guard-brief-verification-scope.sh, one for a reused name, one for an
unrecorded integration branch, one for a relative repository path. Every one
was fixable in seconds. Every one cost a full round trip in front of him.

===========================================================================
WHAT THIS DOES DIFFERENTLY, AND THE ONE IDEA UNDER ALL OF IT
===========================================================================
EVERY REFUSAL IS EVALUATED BEFORE ANYTHING IS CREATED, AND THEY ARE REPORTED
TOGETHER. A brief that breaks three rules is fixed once, not three times.

  1. The integration branch is RESOLVED, and RECORDED when it is absent and
     the answer is not a human's to give - rather than refusing and naming a
     second command. A STALE record (one naming a branch that no longer
     exists) is CORRECTED in place, keeping the body of work's id so agents
     already bound to it move with it. Where the answer genuinely is a human
     decision - the repository is not on its default branch, or this work must
     not reach main yet - it says WHICH decision, in one line, and stops.
     It never guesses one: point 14 is "nothing infers it and nothing guesses
     it", and the deleted first-registration floor is what guessing costs.
  2. The repository is accepted by absolute path AND by bare name where that is
     unambiguous; an ambiguous name is answered with the candidates.
  3. EVERY PreToolUse[Agent] guard is evaluated against the payload, FROM BOTH
     SURFACES - the engine's hooks/hooks.json and the governed repository's
     .claude/settings*.json - and every failure is reported together. Reading
     only the engine's list is the exact hole that cost two refusals that
     night: guard-brief-verification-scope.sh lives in femcboost, not here.
     A matcherless PreToolUse group matches EVERY tool, so it is collected too;
     the stopgap this replaces missed those.
  4. Only then is the workspace created, and the guards are evaluated a SECOND
     time against the real thing - because clause 7a asks a question about a
     workspace that must exist to be answered.
  5. On ANY failure nothing is left behind: before creation there is nothing to
     leave, and after it the workspace, its branch and its registration are
     withdrawn (workspaces.sh withdraw-cc), which frees the name for the retry.

THE CLAUSE-7 FALSE POSITIVE IS GONE, NOT SPECIAL-CASED. The stopgap
(femcboost/scripts/preflight-agent-spawn.sh, deleted with this) always reported
guard-worktree-isolation.sh as refusing, because a synthetic envelope has no
session_id or tool_use_id and only the host mints those. A check that always
fails protects nothing and teaches its reader to skip it. So workspaces.py
grew `check-spawn`: the SAME code as `register-spawn` with the write removed,
reached only when the platform minted no tool_use_id. See `is_spawn_check`.
"""
import importlib.util
import json
import os
import re
import shlex
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ENGINE = os.path.dirname(os.path.dirname(HERE))          # .../engine


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


W = _load("richos_workspaces", os.path.join(HERE, "workspaces.py"))
PREPARE = _load("richos_prepare_agent_spawn",
                os.path.join(ENGINE, "scripts", "prepare-agent-spawn.py"))
PROV = _load("richos_brief_provenance",
             os.path.join(ENGINE, "scripts", "brief-provenance.py"))


class Refusal(Exception):
    """One thing that must be fixed before this teammate can be started. Never
    raised one at a time where several can be collected."""


def sh(args, cwd=None, timeout=60):
    try:
        p = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except (OSError, subprocess.SubprocessError) as exc:
        return 127, "", str(exc)


# ---------------------------------------------------------------------------
# 1. WHICH REPOSITORY
# ---------------------------------------------------------------------------

def candidate_repos(project_dir):
    """Every repository this machine has a reason to know about, deduplicated:
    the ones the registry remembers, the ones with an integration record, the
    session's own, and its siblings. Used ONLY to resolve a bare name and to
    print candidates when one does not resolve - never to pick one."""
    out = []
    seen = set()

    def add(path):
        if not path:
            return
        main = W.main_checkout(path)
        if main and main not in seen:
            seen.add(main)
            out.append(main)

    add(project_dir)
    for r in W.known_repos():
        add(r)
    for r in W.all_integration_records():
        add(r)
    parent = os.path.dirname(W.realpath(project_dir)) if project_dir else ""
    if parent and os.path.isdir(parent):
        try:
            for n in sorted(os.listdir(parent)):
                p = os.path.join(parent, n)
                if os.path.isdir(os.path.join(p, ".git")):
                    add(p)
        except OSError:
            pass
    return out


def resolve_repo(arg, project_dir):
    """A repository by ABSOLUTE PATH, by relative path, or by BARE NAME where
    that is unambiguous. `create-teammate-worktree.sh richos` answered "'richos'
    is not a directory", which is true and is not the answer to the question
    that was asked."""
    arg = (arg or "").strip()
    if not arg:
        raise Refusal("name the repository: --repo <absolute path, or a bare name like 'richos'>")
    looks_like_path = ("/" in arg) or arg in (".", "..") or arg.startswith("~")
    if looks_like_path:
        path = os.path.expanduser(arg)
        if not os.path.isdir(path):
            raise Refusal("--repo %s: no such directory. Give an absolute path, or a bare repository "
                          "name (%s)." % (arg, ", ".join(os.path.basename(r) for r in
                                                         candidate_repos(project_dir)) or "none known"))
        main = W.main_checkout(path)
        if not main:
            raise Refusal("--repo %s is not inside a git repository" % arg)
        return main
    hits = [r for r in candidate_repos(project_dir) if os.path.basename(r) == arg]
    if len(hits) == 1:
        return hits[0]
    if not hits:
        known = ", ".join(os.path.basename(r) for r in candidate_repos(project_dir))
        raise Refusal("--repo %s: no repository of that name is known here. Known: %s. An absolute "
                      "path always works." % (arg, known or "none"))
    raise Refusal("--repo %s is ambiguous - it names %d repositories: %s. Give the absolute path of "
                  "the one you mean." % (arg, len(hits), ", ".join(hits)))


# ---------------------------------------------------------------------------
# 2. WHICH BRANCH THIS WORK INTEGRATES ON (point 14)
# ---------------------------------------------------------------------------

def default_branch(repo):
    """The repository's own default branch, read from git and never guessed:
    origin/HEAD if the remote declares one, else `main` or `master` if exactly
    one of them exists. "" when git does not answer - and "" is an answer here,
    not a reason to pick something."""
    rc, out, _ = sh(["git", "-C", repo, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"])
    if rc == 0 and out.strip().startswith("refs/remotes/origin/"):
        b = out.strip()[len("refs/remotes/origin/"):]
        if b and W.branch_tip(repo, b):
            return b
    have = [b for b in ("main", "master") if W.branch_tip(repo, b)]
    return have[0] if len(have) == 1 else ""


def checkout_branch(repo):
    wl = W.worktree_list(repo) or []
    return wl[0]["branch"] if wl else ""


def ensure_integration(repo, explicit, why, session):
    """Point 14, as one step of one command instead of a refusal naming a second
    command. Returns a one-line note for the report.

    THE THREE STATES, and the third is the one that bit us:
      recorded and its branch exists  -> nothing to do
      not recorded                    -> RECORD it, when the answer is not a
                                         human's to give
      recorded and its branch is GONE -> CORRECT it in place (same work id, so
                                         every agent already bound to it moves
                                         with it), when the answer is not a
                                         human's to give

    WHEN IT IS A HUMAN'S TO GIVE, IT SAYS SO AND STOPS. Recording the default
    branch is safe only where nothing suggests this work is being kept off it:
    the repository's main checkout is sitting ON its default branch. Anywhere
    else the question "does this work integrate on main, or on a branch that
    must not reach main yet?" has an answer this command cannot read, and
    point 14 is explicit that nothing may guess it - the deleted
    first-registration floor guessed exactly this and froze the wrong answer
    onto agents already in flight."""
    rec = W.integration_record(repo)
    live = bool(rec and W.branch_tip(repo, rec["branch"]))
    if rec and live and not explicit:
        return "integration: %s (recorded %s, body of work %s)" % (rec["branch"], rec["recorded_at"],
                                                                   rec["id"])
    if rec and live and explicit and explicit == rec["branch"]:
        return "integration: %s (recorded, matches --integration)" % rec["branch"]

    dflt = default_branch(repo)
    on = checkout_branch(repo)
    branch = explicit
    reason = "named with --integration"
    if not branch:
        if not dflt:
            raise Refusal(
                "%s: this command will not guess the branch this work integrates on (point 14). "
                "DECISION: git names no unambiguous default branch here, so say which branch it is: "
                "re-run with --integration <branch> [--integration-why '<this body of work>']." % repo)
        if on != dflt:
            raise Refusal(
                "%s: this command will not guess the branch this work integrates on (point 14). "
                "DECISION: its main checkout is on %r, not on its default branch %r - does this work "
                "integrate on %s, or on a branch that must not reach main yet? Re-run with "
                "--integration <branch> [--integration-why '<this body of work>']."
                % (repo, on, dflt, dflt))
        branch = dflt
        reason = "its main checkout is on %s and git names %s as its default branch" % (dflt, dflt)

    if not W.branch_tip(repo, branch):
        raise Refusal("%s: there is no branch %s to integrate on. The branch a body of work "
                      "integrates on exists before its first agent is spawned (point 14)."
                      % (repo, branch))

    if rec and not live:
        note = ("%s was recorded as this work's integration branch and no longer exists; %s"
                % (rec["branch"], reason))
        W.record_integration(repo, branch, why or note, session, correct=True)
        return ("integration: CORRECTED %s from %s (no such branch) to %s - %s"
                % (repo, rec["branch"], branch, reason))
    if rec and live and explicit and explicit != rec["branch"]:
        W.record_integration(repo, branch, why or reason, session, correct=True)
        return ("integration: CORRECTED %s from %s to %s - %s" % (repo, rec["branch"], branch, reason))
    W.record_integration(repo, branch, why or reason, session)
    if explicit:
        return "integration: RECORDED %s for %s - %s" % (branch, repo, reason)
    return ("integration: RECORDED %s for %s - %s. If this work must not reach %s yet, re-run with "
            "--integration <branch>." % (branch, repo, reason, branch))


# ---------------------------------------------------------------------------
# 3. THE GUARDS, FROM EVERY SURFACE THAT REGISTERS THEM
# ---------------------------------------------------------------------------

def _hook_groups(node):
    if isinstance(node, dict):
        if "hooks" in node and isinstance(node.get("hooks"), list):
            yield node
        for v in node.values():
            for g in _hook_groups(v):
                yield g
    elif isinstance(node, list):
        for v in node:
            for g in _hook_groups(v):
                yield g


def _matches_agent(matcher):
    """Claude Code matches a hook group's `matcher` against the tool name as a
    regular expression. NO MATCHER AT ALL (and "" and "*") MATCHES EVERY TOOL -
    which is how guard-sealed-worktree.sh is registered, and which the stopgap
    this replaces silently skipped because it only looked for the string
    "Agent"."""
    if matcher is None:
        return True
    m = str(matcher).strip()
    if m in ("", "*"):
        return True
    try:
        return bool(re.search(m, "Agent"))
    except re.error:
        return m == "Agent"


def settings_sources(project_dir):
    """Every file that can register a PreToolUse[Agent] hook for a session
    seated in `project_dir`, in the order the platform layers them.

    RICHOS_SPAWN_HOOK_SOURCES ('<label>=<path>' entries, ':'-separated) replaces
    the list. It is a TEST AFFORDANCE, in the same spirit as
    RICHOS_WORKSPACES_DIR, and it is not a way to spawn past a guard: the guards
    that actually refuse a call are the ones the platform runs at PreToolUse.
    This command only tells you in advance what they will say."""
    override = (os.environ.get("RICHOS_SPAWN_HOOK_SOURCES") or "").strip()
    if override:
        out = []
        for item in override.split(":"):
            if "=" in item:
                label, path = item.split("=", 1)
                out.append((label.strip(), path.strip()))
            elif item.strip():
                out.append(("override", item.strip()))
        return out
    cfg = (os.environ.get("CLAUDE_CONFIG_DIR") or "").strip() \
        or os.path.join(os.path.expanduser("~"), ".claude")
    return [
        ("engine", os.path.join(ENGINE, "hooks", "hooks.json")),
        ("user", os.path.join(cfg, "settings.json")),
        ("project", os.path.join(project_dir, ".claude", "settings.json")),
        ("local", os.path.join(project_dir, ".claude", "settings.local.json")),
    ]


def collect_guards(project_dir):
    """[(source_label, source_path, command)] for every PreToolUse hook that a
    real Agent call would run, deduplicated by command, in registration order."""
    out, seen = [], set()
    for label, path in settings_sources(project_dir):
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError):
            continue
        pre = None
        if isinstance(data, dict):
            pre = (data.get("hooks") or {}).get("PreToolUse")
            if pre is None and isinstance(data.get("PreToolUse"), list):
                pre = data["PreToolUse"]
        if not isinstance(pre, list):
            continue
        for group in _hook_groups({"_": pre}):
            if not _matches_agent(group.get("matcher")):
                continue
            for hook in group.get("hooks") or []:
                cmd = str((hook or {}).get("command") or "").strip()
                if not cmd or cmd in seen:
                    continue
                seen.add(cmd)
                out.append((label, path, cmd))
    return out


def guard_name(cmd):
    m = re.findall(r"[^\s/'\"]+\.(?:sh|py)", cmd)
    if m:
        return m[-1]
    return (cmd.split() or ["?"])[0][:60]


def expand(cmd, project_dir):
    for var, val in (("CLAUDE_PROJECT_DIR", project_dir), ("CLAUDE_PLUGIN_ROOT", ENGINE)):
        cmd = cmd.replace("${%s}" % var, val).replace("$%s" % var, val)
    return cmd


def run_guards(guards, envelope, project_dir):
    """Run every guard against one envelope and return every verdict. NEVER
    stops at the first refusal: reporting one problem per attempt is the cost
    this command exists to remove.

    THE VERDICT IS THE PLATFORM'S, NOT A GUESS. Claude Code blocks a tool call
    on exit code 2, or on a JSON stdout that denies it; any other nonzero is a
    non-blocking error, which is reported loudly and separately because a guard
    that cannot run protected nothing."""
    env = dict(os.environ)
    env["CLAUDE_PROJECT_DIR"] = project_dir
    env.setdefault("CLAUDE_PLUGIN_ROOT", ENGINE)
    env["RICHOS_SPAWN_CHECK"] = "1"
    results = []
    for label, source, cmd in guards:
        line = expand(cmd, project_dir)
        t0 = time.time()
        try:
            p = subprocess.run(["bash", "-c", line], input=envelope, capture_output=True,
                               text=True, cwd=project_dir, env=env, timeout=180)
            rc, out, err = p.returncode, p.stdout, p.stderr
        except subprocess.TimeoutExpired:
            rc, out, err = 124, "", "the guard did not finish inside 180s"
        except OSError as exc:
            rc, out, err = 127, "", str(exc)
        verdict = "ok"
        if rc == 2:
            verdict = "blocked"
        elif rc != 0:
            verdict = "error"
        else:
            try:
                j = json.loads(out)
            except ValueError:
                j = None
            if isinstance(j, dict):
                hso = j.get("hookSpecificOutput") or {}
                if hso.get("permissionDecision") == "deny" or j.get("decision") == "block":
                    verdict = "blocked"
        results.append({"name": guard_name(cmd), "source": label, "source_path": source,
                        "command": line, "rc": rc, "verdict": verdict,
                        "output": (err.strip() or out.strip()), "seconds": round(time.time() - t0, 1)})
    return results


# ---------------------------------------------------------------------------
# 4. THE PAYLOAD
# ---------------------------------------------------------------------------

def build_payload(args, brief, workspace):
    prompt = brief.rstrip("\n")
    if workspace:
        line = "cross-repo-worktree: %s" % workspace
        have = W.prompt_lines(prompt, "cross-repo-worktree")
        if not have:
            prompt = line + "\n\n" + prompt
        else:
            wrong = [p for p in have if W.realpath(p.split()[0]) != workspace]
            if wrong:
                raise Refusal("the brief already names a different workspace on a "
                              "'cross-repo-worktree:' line (%s); this command would create %s. Remove "
                              "the line and let it be written, or pass --dir %s."
                              % (wrong[0], workspace, os.path.dirname(wrong[0].split()[0])))
    ti = {"name": args["name"], "subagent_type": args["type"], "prompt": prompt,
          "isolation": "worktree"}
    if args.get("description"):
        ti["description"] = args["description"]
    if args.get("model"):
        ti["model"] = args["model"]
    # The acknowledgement contract is prepare-agent-spawn.py's, and it stays
    # prepare-agent-spawn.py's: one answer, one place. This calls it.
    return PREPARE.prepare(ti)


def envelope_for(payload, session, project_dir, planned):
    return json.dumps({
        "session_id": session,
        "cwd": project_dir,
        "hook_event_name": "PreToolUse",
        "tool_name": "Agent",
        "tool_input": payload,
        # THE MARKER, AND WHY IT IS SAFE: clause 7 treats a payload as a dry
        # evaluation only when this is present AND the platform minted no
        # tool_use_id. There is no tool_use_id here because no call has been
        # made; a live call always has one.
        "richos_spawn_check": {"planned": planned},
    })


# ---------------------------------------------------------------------------
# 5. THE REPORT
# ---------------------------------------------------------------------------

def report_problems(title, problems, out=sys.stderr):
    print("", file=out)
    print("spawn: %s - NOTHING WAS CREATED." % title, file=out)
    print("", file=out)
    for i, p in enumerate(problems, 1):
        print("  [%d] %s" % (i, p["headline"]), file=out)
        for line in (p.get("detail") or "").splitlines():
            print("      %s" % line, file=out)
        print("", file=out)
    print("  %d problem(s). Fix them together and run the same command again." % len(problems),
          file=out)


def problems_from(results):
    out = []
    for r in results:
        if r["verdict"] == "blocked":
            out.append({"headline": "%s REFUSES this spawn  (%s: %s)"
                                    % (r["name"], r["source"], r["source_path"]),
                        "detail": r["output"] or "(the guard printed nothing; exit %d)" % r["rc"]})
    return out


def errors_from(results):
    return [r for r in results if r["verdict"] == "error"]


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

USAGE = """usage: spawn.sh <teammate-name> --repo <repo> --type <subagent-type> --brief <file>
                [--model <alias>] [--description <text>] [--base <ref>] [--dir <path>]
                [--integration <branch>] [--integration-why <text>]
                [--payload-out <file>] [--json] [--dry-run]

  <teammate-name>      <role>-<model>-<identifier>, e.g. zach-opus-spawn1
  --repo <repo>        absolute path, OR a bare name where it is unambiguous
  --type <t>           the subagent_type the definition is registered under
  --brief <file>       the brief, as a file; `-` reads stdin
  --integration <b>    the branch this body of work integrates on; needed only
                       where the answer is a human's to give, and the refusal
                       says so when it is
  --dry-run            evaluate everything and create nothing
  --json               machine-readable result on stdout instead of the payload

Prints the finished Agent tool payload on stdout, ready to use. Everything a
person reads goes to stderr, so `spawn.sh ... > payload.json` is a payload.
Exit 0 ready; 1 refused (nothing created); 2 usage; 4 created but rolled back.
"""


def parse_args(argv):
    args = {"name": "", "repo": "", "type": "", "brief": "", "model": "", "description": "",
            "base": "", "dir": "", "integration": "", "integration_why": "", "payload_out": "",
            "json": False, "dry_run": False, "project_dir": ""}
    flags = {"--repo": "repo", "--type": "type", "--brief": "brief", "--model": "model",
             "--description": "description", "--base": "base", "--dir": "dir",
             "--integration": "integration", "--integration-why": "integration_why",
             "--payload-out": "payload_out", "--project-dir": "project_dir"}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in flags:
            if i + 1 >= len(argv):
                raise Refusal("%s needs a value" % a)
            args[flags[a]] = argv[i + 1]
            i += 2
        elif a == "--json":
            args["json"] = True
            i += 1
        elif a == "--dry-run":
            args["dry_run"] = True
            i += 1
        elif a in ("-h", "--help"):
            sys.stderr.write(USAGE)
            raise SystemExit(2)
        elif a.startswith("-"):
            raise Refusal("unknown option %s" % a)
        else:
            if args["name"]:
                raise Refusal("unexpected argument %r" % a)
            args["name"] = a
            i += 1
    return args


def main(argv):
    try:
        args = parse_args(argv)
    except Refusal as exc:
        sys.stderr.write("spawn: %s\n\n%s" % (exc, USAGE))
        return 2
    missing = [k for k in ("name", "repo", "type", "brief") if not args[k]]
    if missing:
        sys.stderr.write("spawn: missing %s\n\n%s" % (", ".join(missing), USAGE))
        return 2

    project_dir = args["project_dir"] or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    project_dir = W.main_checkout(project_dir) or W.realpath(project_dir)
    session = W.current_session()
    notes = []
    problems = []

    # --- everything that can be decided without creating anything -----------
    try:
        if not session:
            raise Refusal("this session is not recorded, so nothing spawned from it could be "
                          "registered (point 12). Start the session through the engine, or export "
                          "RICHOS_SESSION_ID.")
        try:
            brief = sys.stdin.read() if args["brief"] == "-" else open(args["brief"],
                                                                       encoding="utf-8").read()
        except OSError as exc:
            raise Refusal("--brief %s: %s" % (args["brief"], exc))
        if not brief.strip():
            raise Refusal("--brief %s is empty. The prompt carries the whole task." % args["brief"])

        repo = resolve_repo(args["repo"], project_dir)
        notes.append("repository:  %s" % repo)

        # Point 14 for EVERY repository this teammate will work in - the
        # session's own included, because register_spawn checks the entity too.
        for r in ([project_dir] if repo != project_dir else []) + [repo]:
            notes.append(ensure_integration(r, args["integration"] if r == repo else "",
                                            args["integration_why"] if r == repo else "", session))

        same_repo = (repo == project_dir)
        workspace = ""
        planned = []
        if not same_repo:
            workspace = W.realpath(args["dir"]) if args["dir"] else W.realpath(
                os.path.join(os.path.dirname(repo), os.path.basename(repo) + "-wt", args["name"]))
            planned = [{"path": workspace, "repo": repo, "branch": W.CC_PREFIX + args["name"]}]
            notes.append("workspace:   %s  (%s%s)" % (workspace, W.CC_PREFIX, args["name"]))
        else:
            notes.append("workspace:   native isolation only (the target repository IS this session's)")

        payload = build_payload(args, brief, workspace)
        # THE PROVENANCE OF THE BRIEF ITSELF, decided here so the guards evaluate the
        # text that will actually be dispatched. It never refuses: a statement with no
        # source is named to the agent, and the agent re-derives it. On a brief that
        # sources everything, nothing is appended and the payload is byte-identical.
        payload["prompt"], findings = PROV.annotate(payload["prompt"], repo)
    except Refusal as exc:
        report_problems("refused", [{"headline": str(exc), "detail": ""}])
        return 1
    except W.SpecError as exc:
        report_problems("refused", [{"headline": str(exc), "detail": ""}])
        return 1

    guards = collect_guards(project_dir)
    if not guards:
        report_problems("refused", [{
            "headline": "no PreToolUse[Agent] guard was found on any surface",
            "detail": "Sources looked at:\n  " + "\n  ".join(p for _l, p in
                                                             settings_sources(project_dir)) +
                      "\nRefusing to call that a pass: an unguarded spawn is not a verified one."}])
        return 1

    pre = run_guards(guards, envelope_for(payload, session, project_dir, planned), project_dir)
    problems = problems_from(pre)
    if problems:
        report_problems("refused by %d of %d guard(s)" % (len(problems), len(guards)), problems)
        _print_guard_table(pre)
        return 1

    if args["dry_run"]:
        print("", file=sys.stderr)
        print("spawn: --dry-run - every check passed and nothing was created.", file=sys.stderr)
        _print_report(notes, pre, guards, None, args, findings)
        return _emit(payload, args, pre, notes, created=None)

    # --- create ------------------------------------------------------------
    # WHOSE REGISTRATION IS IT? Asked HERE, before anything is created, because
    # after a failure it can no longer be told apart. A rollback may only undo
    # what THIS run made: on 2026-09-13 an earlier draft of this file, with the
    # spawn guard standing down in a test repository that had not adopted the
    # engine, reused a name, failed to create, and withdrew the EXISTING
    # workspace of that name - deleting a live teammate's tree and branch while
    # reporting a refusal. `withdraw_cc` cannot see the difference (the record
    # looks identical either way), so the caller carries the answer.
    mine = not os.path.exists(W.agent_path(W.named_key(session, args["name"])))
    created = None
    if planned:
        cmd = [os.path.join(ENGINE, "scripts", "create-teammate-worktree.sh"), repo, args["name"],
               "--dir", planned[0]["path"], "--session", session]
        if args["base"]:
            cmd += ["--base", args["base"]]
        rc, out, err = sh(cmd, timeout=300)
        if rc != 0:
            report_problems("could not create the workspace",
                            [{"headline": "create-teammate-worktree.sh exited %d" % rc,
                              "detail": (err.strip() or out.strip())}])
            _rollback(session, args["name"], mine)
            return 1
        created = planned[0]["path"]

    # --- the same guards again, against the real thing ----------------------
    post = run_guards(guards, envelope_for(payload, session, project_dir, []), project_dir)
    problems = problems_from(post)
    if problems:
        report_problems("refused AFTER the workspace was created - rolling it back", problems)
        _print_guard_table(post)
        _rollback(session, args["name"], mine)
        return 4

    _print_report(notes, post, guards, created, args, findings)
    return _emit(payload, args, post, notes, created)


def _rollback(session, name, mine):
    """On ANY failure of OUR OWN making, leave nothing behind.

    `mine` is false when a registration of this name already existed when this
    run started. Then the failure is "that name is taken", the workspace belongs
    to somebody else, and withdrawing it would delete a live teammate's tree and
    branch. `withdraw_cc` refuses anything that ever RAN, which is a different
    question and does not cover this one: a registered, created, not-yet-spawned
    workspace looks the same whoever made it."""
    if not mine:
        print("  left alone: %s was already registered before this run, so its workspace is not "
              "this command's to withdraw. Pick a fresh identifier." % name, file=sys.stderr)
        return
    try:
        W.withdraw_cc(session, name, "its spawn was refused before it was made")
        print("  rolled back: workspace, branch and registration withdrawn; the name %s is free "
              "again." % name, file=sys.stderr)
    except W.SpecError as exc:
        if "there is no registration" not in str(exc):
            print("  ROLLBACK FAILED: %s" % exc, file=sys.stderr)
            print("  Nothing was spawned into it. Clean it up with: workspaces.sh discard %s "
                  "--reason '<why>' --not-ceo-ordered '<why>'" % name, file=sys.stderr)


def _print_guard_table(results, out=sys.stderr):
    print("  guards evaluated (all of them, every time):", file=out)
    for r in results:
        mark = {"ok": "ok     ", "blocked": "REFUSED", "error": "ERROR  "}[r["verdict"]]
        print("    %s %-38s %-8s %5.1fs" % (mark, r["name"], r["source"], r["seconds"]), file=out)
    print("", file=out)


def _print_report(notes, results, guards, created, args, findings=()):
    out = sys.stderr
    print("", file=out)
    print("spawn: READY - %s" % args["name"], file=out)
    for n in notes:
        print("  %s" % n, file=out)
    if created:
        print("  created:     %s" % created, file=out)
    ok = len([r for r in results if r["verdict"] == "ok"])
    print("  guards:      %d evaluated, %d passed (%s)"
          % (len(guards), ok, ", ".join(sorted(set("%s:%d" % (lbl, len([g for g in guards
                                                                        if g[0] == lbl]))
                                                   for lbl, _p, _c in guards)))), file=out)
    print("", file=out)
    _print_guard_table(results)
    PROV.report(list(findings), args["name"], out=out)
    print("", file=out)
    for r in errors_from(results):
        print("  NOTE: %s could not run (exit %d) - it is a non-blocking error for the platform "
              "too, but it protected nothing here:\n    %s" % (r["name"], r["rc"], r["output"]),
              file=out)
    print("  The payload is on stdout. It is complete: pass it to the Agent tool as-is.", file=out)
    print("", file=out)


def _emit(payload, args, results, notes, created):
    text = json.dumps(payload, indent=2)
    if args["payload_out"]:
        try:
            with open(args["payload_out"], "w", encoding="utf-8") as f:
                f.write(text + "\n")
            print("  payload also written to %s" % args["payload_out"], file=sys.stderr)
        except OSError as exc:
            print("spawn: could not write --payload-out %s: %s" % (args["payload_out"], exc),
                  file=sys.stderr)
            return 1
    if args["json"]:
        print(json.dumps({"ready": True, "payload": payload, "created": created, "notes": notes,
                          "guards": results}, indent=2))
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
