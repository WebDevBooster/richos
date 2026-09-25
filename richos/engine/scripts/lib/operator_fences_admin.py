#!/usr/bin/env python3
"""operator_fences_admin.py: `operator-fences.sh install|on|off|status|uninstall`.

ONE INSTALLER OWNS THE CHAIN (spec r3 e8; Frank §3). `install` writes the
launcher as <common>/hooks/reference-transaction in each repository and moves
whatever hook was there into reference-transaction.d/, where the launcher runs
it on every transaction, refused ones included:

    reference-transaction.d/20-ref-transaction-forensics.sh   the recorder
    reference-transaction.d/50-repository-hook                  any other hook

`install-ref-forensics.sh` and femcboost's `.githooks/install.sh` learn the
launcher and write into those two slots instead of over it.

THE SWITCH LIVES IN THE LAUNCHERS (Frank G12). `on` and `off` rewrite one line
in each launcher this command owns; nothing in any repository's working tree is
touched, so an emergency `off` needs no lease and leaves every repository as
clean as it found it. The entity's orchestration.config line OPERATOR_FENCES is
the DECLARATION: `on` refuses unless it says "on", and `status` (and the
integrity probe through it) reports any disagreement.

THE LEASE HOME IS BAKED IN (Frank G10). The installer resolves the home and
the per-repository key with workspaces.py's own land_lock_path() and writes
both into the launcher, which is the only place the fence reads them from.

NOT DONE HERE, on purpose: ~/.codex/AGENTS.md is never edited by this command.
r3 e1 had the installer write a Codex block there; the brief for this build put
that text in the handoff for Rich to apply by hand, because it changes how the
CEO's Codex works. See the as-built record.
"""
import hashlib
import json
import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)
import operator_fences as F   # noqa: E402

ENGINE = os.path.realpath(os.path.join(HERE, "..", ".."))
TEMPLATE = os.path.join(HERE, "operator-fence-launcher.sh")
PROGRAM_SOURCE = os.path.join(HERE, "operator_fences.py")
RECORDER_MARKER = "ref-transaction-forensics.sh"
REGISTRY_NAME = "operator-fences.json"
_ASSIGN = re.compile(r'^\s*([A-Z_][A-Z0-9_]*)=(?:"([^"]*)"|\'([^\']*)\'|(\S*))\s*(?:#.*)?$')


def say(text):
    sys.stdout.write(text.rstrip("\n") + "\n")


def declaration(entity):
    """KEY -> value for the plain assignments of <entity>/orchestration.config."""
    out = {}
    try:
        with open(os.path.join(entity, "orchestration.config"), encoding="utf-8") as fh:
            for line in fh:
                m = _ASSIGN.match(line)
                if m:
                    out[m.group(1)] = next(g for g in m.groups()[1:] if g is not None)
    except OSError:
        return None
    return out


def registry_path():
    return os.path.join(F._default_home(), REGISTRY_NAME)


def read_registry():
    return F.read_json(registry_path()) or {"repositories": {}}


def write_registry(reg):
    F.write_json_atomic(registry_path(), reg)


def resolve_entity(opts, reg):
    entity = opts.get("--entity") or (os.environ.get("RICHOS_ENTITY_ROOT") or "").strip() or reg.get("entity")
    if not entity:
        raise SystemExit("operator-fences: name the entity (--entity <path>): the repository whose "
                         "orchestration.config declares OPERATOR_FENCES")
    entity = os.path.realpath(os.path.expanduser(entity))
    if declaration(entity) is None:
        raise SystemExit("operator-fences: %s has no orchestration.config" % entity)
    return entity


def declared_repos(decl):
    raw = (decl or {}).get("OPERATOR_FENCES_REPOS", "")
    return [os.path.realpath(os.path.expanduser(p)) for p in raw.split()]


def chain_reachable(main):
    """Will a repository-local reference-transaction hook actually run? The
    same test install-ref-forensics.sh makes: with core.hooksPath set, the
    dispatcher there must chain to the repository's own hook."""
    rc, out, _ = F.git(main, "config", "--get", "core.hooksPath")
    hooks_path = out.strip() if rc == 0 else ""
    if not hooks_path:
        return True, "(unset)"
    dispatch = os.path.join(os.path.expanduser(hooks_path), "reference-transaction")
    try:
        with open(os.path.realpath(dispatch), encoding="utf-8", errors="replace") as fh:
            return "git-common-dir" in fh.read(), hooks_path
    except OSError:
        return False, hooks_path


def launcher_text(values):
    with open(TEMPLATE, encoding="utf-8") as fh:
        text = fh.read()
    for key, value in values.items():
        if '"' in value or "\n" in value or "$" in value or "`" in value:
            raise SystemExit("operator-fences: refusing to bake %s=%r into a hook" % (key, value))
        text = text.replace("@%s@" % key, value)
    return set_state_text(text, values.get("STATE", "off"))


def set_state_text(text, state):
    return re.sub(r'(?m)^OPERATOR_FENCES_STATE="[^"]*"$', 'OPERATOR_FENCES_STATE="%s"' % state, text, count=1)


def write_executable(path, text):
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.chmod(tmp, 0o755)
    os.replace(tmp, path)


def chain_members(common):
    d = os.path.join(common, "hooks", F.CHAIN_DIR)
    try:
        return sorted(n for n in os.listdir(d) if os.path.isfile(os.path.join(d, n)))
    except OSError:
        return []


def install_one(repo, entity, decl):
    paths = F.repo_paths(repo)
    if not paths or not paths["main"]:
        raise SystemExit("operator-fences: %s is not a repository with a main checkout" % repo)
    main, common = paths["main"], paths["common"]
    rc, out, _ = F.git(main, "config", "--get", "extensions.refStorage")
    if rc == 0 and out.strip() == "reftable":
        raise SystemExit("operator-fences: %s uses the reftable back end; the fence reads the files back end, "
                         "so it is not installed there" % main)
    ok, hooks_path = chain_reachable(main)
    if not ok:
        raise SystemExit("operator-fences: core.hooksPath=%s does not chain to %s's own reference-transaction "
                         "hook, so a launcher there would never run. Refusing." % (hooks_path, main))
    home, key = F.keyed_paths(main)
    hooks = os.path.join(common, "hooks")
    target = os.path.join(hooks, "reference-transaction")
    chain = os.path.join(hooks, F.CHAIN_DIR)
    os.makedirs(chain, exist_ok=True)
    state = "off"
    existing = F.read_launcher(target)
    moved = ""
    if existing:
        state = existing.get("STATE", "off")
    elif os.path.exists(target):
        with open(target, encoding="utf-8", errors="replace") as fh:
            body = fh.read()
        slot = F.RECORDER_SLOT if RECORDER_MARKER in body else F.REPOSITORY_SLOT
        dest = os.path.join(chain, slot)
        if os.path.exists(dest):
            with open(dest, encoding="utf-8", errors="replace") as fh:
                if fh.read() != body:
                    raise SystemExit("operator-fences: %s already holds a different hook; refusing to overwrite "
                                     "either one" % dest)
            os.unlink(target)
        else:
            shutil.move(target, dest)
            os.chmod(dest, 0o755)
        moved = slot
    program_dir = os.path.join(hooks, "operator-fences")
    os.makedirs(program_dir, exist_ok=True)
    program = os.path.join(program_dir, "operator_fences.py")
    shutil.copyfile(PROGRAM_SOURCE, program)
    digest = F.file_digest(program)
    holders = " ".join(decl.get("LAND_LEASE_HOLDERS", "").split())
    write_executable(target, launcher_text({
        "STATE": state, "REPO": main, "COMMON": common, "HOME": home, "KEY": key, "HOLDERS": holders,
        "ENGINE": ENGINE, "PROGRAM": program, "DIGEST": digest}))
    return {"main": main, "common": common, "state": state, "moved": moved, "chain": chain_members(common),
            "hooks_path": hooks_path}


def cmd_install(opts, repos):
    reg = read_registry()
    entity = resolve_entity(opts, reg)
    decl = declaration(entity)
    repos = repos or declared_repos(decl)
    if not repos:
        raise SystemExit("operator-fences: no repositories: pass --repo or declare OPERATOR_FENCES_REPOS in %s"
                         % os.path.join(entity, "orchestration.config"))
    reg["entity"] = entity
    for repo in repos:
        r = install_one(repo, entity, decl)
        reg["repositories"][r["main"]] = {"common": r["common"], "chain": r["chain"], "installed": F.iso()}
        say("installed  %s  state=%s  chain=%s%s" % (r["main"], r["state"], ",".join(r["chain"]) or "(empty)",
                                                    "  (moved the existing hook to %s)" % r["moved"] if r["moved"]
                                                    else ""))
    write_registry(reg)
    return 0


def target_repos(opts, repos):
    if repos:
        return [os.path.realpath(os.path.expanduser(r)) for r in repos]
    return sorted(read_registry().get("repositories", {}))


def cmd_set_state(opts, repos, state):
    repos = target_repos(opts, repos)
    if not repos:
        say("operator-fences: nothing is installed, so there is nothing to turn %s." % state)
        return 0 if state == "off" else 1
    if state == "on":
        reg = read_registry()
        entity = resolve_entity(opts, reg)
        if (declaration(entity) or {}).get("OPERATOR_FENCES") != "on":
            say("operator-fences: REFUSED. %s/orchestration.config declares OPERATOR_FENCES=%r. Declare it \"on\" "
                "first; the declaration and the launchers must agree." % (
                    entity, (declaration(entity) or {}).get("OPERATOR_FENCES")))
            return 1
        problems = [p for repo in repos for p in check_one(repo, "on-ready")]
        if problems:
            say("operator-fences: REFUSED to turn the fences on:\n  " + "\n  ".join(problems))
            return 1
    rc = 0
    for repo in repos:
        paths = F.repo_paths(repo)
        target = os.path.join(paths["common"], "hooks", "reference-transaction") if paths else ""
        conf = F.read_launcher(target) if target else None
        if not conf:
            say("operator-fences: %s has no launcher; skipped." % repo)
            rc = 1 if state == "on" else rc
            continue
        with open(target, encoding="utf-8") as fh:
            text = fh.read()
        write_executable(target, set_state_text(text, state))
        say("%s  %s" % (state.upper(), repo))
    return rc


def check_one(repo, mode):
    """Problems with one repository's install, as sentences. mode 'on-ready'
    skips the state check (used before turning it on)."""
    problems = []
    paths = F.repo_paths(repo)
    if not paths:
        return ["%s: not a repository" % repo]
    target = os.path.join(paths["common"], "hooks", "reference-transaction")
    conf = F.read_launcher(target)
    if not conf:
        return ["%s: the launcher is not installed" % repo]
    if mode != "on-ready" and conf.get("STATE") != "on":
        problems.append("%s: the fence is off" % repo)
    if F.file_digest(conf.get("PROGRAM", "")) != F.file_digest(PROGRAM_SOURCE):
        problems.append("%s: the installed fence program differs from the engine's; run operator-fences.sh "
                        "install" % repo)
    ok, hooks_path = chain_reachable(paths["main"])
    if not ok:
        problems.append("%s: core.hooksPath=%s does not reach the launcher" % (repo, hooks_path))
    expected = (read_registry().get("repositories", {}).get(paths["main"]) or {}).get("chain") or []
    missing = [m for m in expected if m not in chain_members(paths["common"])]
    if missing:
        problems.append("%s: chain member(s) %s are gone" % (repo, ", ".join(missing)))
    try:
        home, key = F.keyed_paths(paths["main"])
        if os.path.realpath(home) != os.path.realpath(conf.get("HOME", "")) or key != conf.get("KEY"):
            problems.append("%s: the launcher's lease home %s/%s differs from this environment's %s/%s"
                            % (repo, conf.get("HOME"), conf.get("KEY"), home, key))
    except Exception as error:  # noqa: BLE001
        problems.append("%s: cannot compute the lease home (%s)" % (repo, error))
    return problems


def cmd_status(opts, repos, declaration_check):
    reg = read_registry()
    repos = target_repos(opts, repos)
    entity = opts.get("--entity") or (os.environ.get("RICHOS_ENTITY_ROOT") or "").strip() or reg.get("entity")
    declared = (declaration(os.path.realpath(entity)) or {}).get("OPERATOR_FENCES") if entity else None
    lines, problems = [], []
    for repo in repos:
        paths = F.repo_paths(repo)
        conf = F.read_launcher(os.path.join(paths["common"], "hooks", "reference-transaction")) if paths else None
        lines.append("%s  launcher=%s  state=%s  chain=%s" % (
            repo, "present" if conf else "ABSENT", (conf or {}).get("STATE", "-"),
            ",".join(chain_members(paths["common"])) if paths else "-"))
    if declaration_check:
        # The integrity probe's question: do the launchers agree with the declaration?
        if declared in (None, "", "off"):
            for repo in repos:
                paths = F.repo_paths(repo)
                conf = F.read_launcher(os.path.join(paths["common"], "hooks", "reference-transaction")) \
                    if paths else None
                if conf and conf.get("STATE") != "off":
                    problems.append("%s: the declaration is off but the launcher is on" % repo)
        else:
            if not repos:
                problems.append("the declaration is on but no repository has the launcher")
            for repo in repos:
                problems.extend(check_one(repo, "status"))
    else:
        if declared != "on":
            problems.append("the declaration (%s) says OPERATOR_FENCES=%r" % (entity, declared))
        if not repos:
            problems.append("no repository has the launcher installed")
        for repo in repos:
            problems.extend(check_one(repo, "status"))
    for line in lines:
        say(line)
    for p in problems:
        say("PROBLEM  " + p)
    say("operator-fences: %s" % ("OK" if not problems else "NOT OK (%d problem%s)" % (
        len(problems), "" if len(problems) == 1 else "s")))
    return 0 if not problems else 1


def cmd_uninstall(opts, repos):
    reg = read_registry()
    repos = target_repos(opts, repos)
    rc = 0
    for repo in repos:
        paths = F.repo_paths(repo)
        if not paths:
            continue
        hooks = os.path.join(paths["common"], "hooks")
        target = os.path.join(hooks, "reference-transaction")
        if not F.read_launcher(target):
            say("operator-fences: %s has no launcher of ours; nothing removed." % repo)
            continue
        members = chain_members(paths["common"])
        if len(members) > 1:
            say("operator-fences: REFUSED for %s: the chain holds %s, and a single reference-transaction hook "
                "can hold only one. Remove all but one by hand, then run uninstall again." % (repo, ", ".join(members)))
            rc = 1
            continue
        chain = os.path.join(hooks, F.CHAIN_DIR)
        if members:
            os.replace(os.path.join(chain, members[0]), target)
        else:
            os.unlink(target)
        shutil.rmtree(os.path.join(hooks, "operator-fences"), ignore_errors=True)
        try:
            os.rmdir(chain)
        except OSError:
            pass
        reg.get("repositories", {}).pop(paths["main"], None)
        say("uninstalled  %s%s" % (repo, "  (restored %s)" % members[0] if members else ""))
    write_registry(reg)
    return rc


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        say("usage: operator-fences.sh install|on|off|status|uninstall [--repo <path>]... [--entity <path>] "
            "[--declaration-check]")
        return 0 if argv else 2
    sub, rest = argv[0], argv[1:]
    repos, opts, i = [], {}, 0
    while i < len(rest):
        a = rest[i]
        if a == "--repo" and i + 1 < len(rest):
            repos.append(rest[i + 1])
            i += 2
        elif a == "--entity" and i + 1 < len(rest):
            opts["--entity"] = rest[i + 1]
            i += 2
        elif a == "--declaration-check":
            opts[a] = True
            i += 1
        else:
            raise SystemExit("operator-fences: unknown argument %r" % a)
    if sub == "install":
        return cmd_install(opts, repos)
    if sub in ("on", "off"):
        return cmd_set_state(opts, repos, sub)
    if sub == "status":
        return cmd_status(opts, repos, bool(opts.get("--declaration-check")))
    if sub == "uninstall":
        return cmd_uninstall(opts, repos)
    raise SystemExit("operator-fences: unknown command %r" % sub)
