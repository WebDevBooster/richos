#!/usr/bin/env python3
"""shell-worktree-sparse.py — THE NATIVE SHELL STOPS BEING A FULL CHECKOUT.
It stays a registered git worktree; it stops being 266 MB of files nobody
reads.

===========================================================================
WHAT A "SHELL" IS, AND WHY IT EXISTS AT ALL
===========================================================================
A cross-repository teammate is spawned with BOTH native isolation in the
session's repository AND a prepared worktree in the repository it actually
edits — `kind == "native+external"` in scripts/lib/worktree-transactions.py.
The native worktree is not its workspace. Its workspace is the external one.

The native worktree is still MANDATORY, and this file changes nothing about
that. guard-worktree-isolation.sh refuses a cwd-only spawn because a
cwd-only worker owns only hand-rolled worktrees: no `WorktreeRemove` ever
names one, so the native-disappearance backstop has nothing to watch and the
worker's death becomes permanently undecidable (wiki/worktree-lifecycle.md
§1). The shell buys DECIDABILITY. It is the platform's own witness that the
agent existed and then stopped.

So the shell stays. What it does not need to be is a materialized copy of
every byte in the repository.

===========================================================================
THE MEASUREMENT THAT PRODUCED THIS FILE (2026-09-04, this machine)
===========================================================================
    one never-written shell                266 MB
      of which qa-audits                   202 MB   (accumulated screenshots)
      application code                      17 MB
    capture store, total                    16 GB
      member-0 (the shell)      38 archives  9.9 GB   mean 266 MB
      member-1 (the real tree)  41 archives  6.5 GB   mean 161 MB

`build_manifest` in reconcile-terminal-worktrees.py walks the DISK
(`os.walk(root)`), not git's index. So a shell with nothing materialized
produces a near-empty manifest and therefore a near-empty archive: the
saving lands on the live directory AND on its archive, and NO archive code
changes. That is the whole design.

===========================================================================
THE MECHANISM, AND WHY THIS ONE
===========================================================================
    git -C <shell> sparse-checkout set --cone [<keep-dir> ...]

Cone mode with ZERO directories writes the patterns `/*` and `!/*/`: every
file at the TOP LEVEL stays materialized, every subdirectory is skipped.
Measured in a fixture: 3936 KB -> 16 KB (20 KB keeping `.claude`).

Top-level files are kept ON PURPOSE, and it is not incidental — it is what
keeps the escalation path working. An agent told to write `BLOCKED.md` at
the root of its worktree and commit it can still do exactly that: `git add`
of a NEW root file succeeds under these patterns, and so does the commit
(proven, S12). Under an empty pattern set it would have failed with
"paths ... outside of your sparse-checkout definition". Cheap is not worth a
broken escalation channel.

THE PLATFORM HAS ITS OWN SPARSE SETTING, AND IT IS THE WRONG TOOL HERE —
which is worth stating because the first instinct is to reach for it.
`worktree.sparsePaths` (Claude Code 2.1.76) checks out only named directories
"via git sparse-checkout", and a later fix cleans up `extensions.worktreeConfig`
"after the last `worktree.sparsePaths` worktree was removed". So the platform
creates sparse worktrees deliberately and tolerates them by design — useful
corroboration for property 1, and the reason this file is not fighting the
harness.

It still cannot do this job, for two reasons and neither is a preference.
Its changelog entry names `claude --worktree` only, where the `worktree.baseRef`
entry explicitly enumerates "`--worktree`, `EnterWorktree`, and agent-isolation
worktrees" — so whether it reaches an agent-isolation worktree at all is
UNPROVEN, and it was not tested here because testing it means changing a
repository-wide setting on a live repository. And repository-wide is the second
reason: one setting cannot tell a never-read SHELL from a plain native worker's
WORKSPACE, and stripping the second is the one outcome this whole design exists
to avoid. The decision belongs to the transaction, which knows the spawn kind;
it does not belong to a repository.

WHAT IS *NOT* REMOVED, and this is the answer to "is sparse a data-loss
path": sparse-checkout removes only tracked files whose content is at HEAD
and recoverable from the object store. It does not touch untracked files, it
does not touch ignored files (the `.worktreeinclude`-seeded `.env` copies
survive — proven, S07), and it REFUSES to remove anything modified. On top of
git's own refusal this module requires `git status --porcelain` to be EMPTY
before it acts, and re-verifies afterwards; a shell that has been written to
is left alone at full size with the reason recorded.

And if a teammate writes into a sparsified shell anyway — it should not, but
no system may depend on manners — the file lands on disk exactly as before,
so the reconciler's disk walk captures it and archives it byte-for-byte.
Proven end-to-end by a positive probe in reconcile-terminal-worktrees.test.sh
(C60-C62), not asserted here.

===========================================================================
WHAT THIS DOES NOT CHANGE — the five properties, each of them a test
===========================================================================
1. The directory stays a registered, non-prunable git worktree. Verified
   after the operation, and a failure to verify ROLLS BACK (S09, S10).
2. Every lifecycle signal still fires and still joins by agent id: nothing
   here touches the transaction's state machine, the ingresses, the
   quarantine rename, the capture or the removal. The only write to the
   transaction is one advisory `sparse` block on the member.
3. The native-disappearance backstop still watches it: `native_member_gone`
   asks whether the directory exists and whether git lists it non-prunable
   in the recorded repository. Sparsification changes neither (S06).
4. A write into a sparsified shell is materialized, captured and archived
   exactly as today (above; proven in the reconciler's suite).
5. Reversible in one command, and the reverse is exact:
       git -C <shell> sparse-checkout disable
   restores every file (proven, S11).

===========================================================================
REFUSALS — every one of them leaves the shell at full size
===========================================================================
  - the policy is off (SHELL_SPARSE)
  - the spawn is not `native+external` (a plain `native` worker's worktree
    IS its workspace and is never touched — S02)
  - the transaction is already terminal, or a terminal event is pending:
    the tree is about to be quarantined and captured; do not race it
  - the member is past `bound`
  - the path is not the registered, non-prunable, top-level linked worktree
    the transaction recorded
  - `git status --porcelain` is not empty (S04)
  - a git operation is in progress (merge, rebase, cherry-pick, bisect)
  - any submodule is initialized (its working tree is not reconstructible
    from this repository's object store alone)
  - `extensions.worktreeConfig` is off AND the shared config sets
    `core.bare = true` or `core.worktree`: enabling the extension would then
    change how the MAIN checkout reads its own config (git worktree(1)).
    Where the extension is already on — both repositories on this machine,
    turned on by another tool — `git sparse-checkout` writes
    `core.sparseCheckout` into the SHELL's own `config.worktree` and the
    main checkout is untouched (S05).
  - git cannot do it: any nonzero exit is recorded, then `disable` is run to
    restore whatever a partial update left behind (S10).

Every refusal is recorded on the member as `sparse.applied = false` with its
reason. Nothing here ever raises into the seal path: a sparsification that
cannot happen must never cost a worker its manifest.

Config: SHELL_SPARSE / SHELL_SPARSE_KEEP in orchestration.config (the
entity's, else the engine's). Env override for tests: RICHOS_SHELL_SPARSE,
RICHOS_SHELL_SPARSE_KEEP.

CLI (operator, one shell at a time — never a sweep):
    shell-worktree-sparse.py inspect  --path <shell>
    shell-worktree-sparse.py sparsify --path <shell> [--repo <main>] [--keep ".claude .githooks"]
    shell-worktree-sparse.py restore  --path <shell>
"""

import json
import os
import subprocess
import sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))

# The default keep-set. `.claude` because it is the only directory the
# platform itself is known to read by convention, and 316 KB out of 266 MB is
# not the problem being solved. `.githooks` because a repository that points
# core.hooksPath at it would otherwise lose its commit-time guards inside the
# shell — and a commit in the shell is exactly the escalation case kept alive
# above. hooks_keep() adds whatever core.hooksPath actually resolves to, so
# the protection does not depend on this name.
DEFAULT_KEEP = ".claude .githooks"

# EVERY GIT CALL HERE IS BOUNDED, AND THE BOUND IS DELIBERATELY SMALL.
# try_seal is reached from the write barrier (guard-sealed-worktree.sh) on a
# worker's own first tool call, so this code can sit in the path of a hook the
# platform is timing. A repository too large to de-materialize inside the
# bound simply is not de-materialized: the timeout is a git failure like any
# other, which means the rollback runs and the shell is left whole. What must
# never happen is the platform killing the hook mid-checkout with nobody left
# to restore the tree, so this bound stays well under any plausible hook
# budget. Measured on this machine: a 266 MB, 4247-entry shell took under two
# seconds end to end.
GIT_TIMEOUT = 60


def now_iso():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


# --------------------------------------------------------------------------
# policy — committed data, never a constant hidden in code
# --------------------------------------------------------------------------

def config_value(key, default, repo=None):
    """The entity's orchestration.config if it declares the key, else the
    engine's, else the default. Same contract as the reconciler's reader."""
    candidates = ([os.path.join(repo, "orchestration.config")] if repo else [])
    candidates.append(os.path.join(HERE, "..", "..", "orchestration.config"))
    for cfg in candidates:
        try:
            with open(cfg, encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line.startswith(key + "="):
                        return line.split("=", 1)[1].strip().strip('"').strip("'")
        except OSError:
            continue
    return default


def policy(repo=None):
    """(enabled, keep_dirs). Env overrides exist for tests only."""
    v = os.environ.get("RICHOS_SHELL_SPARSE")
    if v is None or v == "":
        v = config_value("SHELL_SPARSE", "on", repo)
    enabled = str(v).strip().lower() in ("on", "1", "true", "yes")
    k = os.environ.get("RICHOS_SHELL_SPARSE_KEEP")
    if k is None:
        k = config_value("SHELL_SPARSE_KEEP", DEFAULT_KEEP, repo)
    keep = [x for x in str(k).split() if x and not x.startswith("-")]
    return enabled, keep


# --------------------------------------------------------------------------
# measurement
# --------------------------------------------------------------------------

def tree_size(path):
    """(bytes, entries) over everything under `path`, symlinks not followed.
    One stat pass; this is the artifact the operator is owed, so it is taken
    before and after rather than estimated."""
    total = 0
    entries = 0
    for dirpath, dirnames, filenames in os.walk(path, followlinks=False):
        for name in dirnames + filenames:
            full = os.path.join(dirpath, name)
            entries += 1
            try:
                total += os.lstat(full).st_size
            except OSError:
                pass
    return total, entries


# --------------------------------------------------------------------------
# git, and it never raises
# --------------------------------------------------------------------------

def git(path, *args, **kw):
    """(rc, stdout, stderr). rc 127 means git could not be run at all."""
    try:
        r = subprocess.run(["git", "-C", path] + list(args), capture_output=True,
                           text=True, timeout=kw.get("timeout", GIT_TIMEOUT))
        return r.returncode, r.stdout, r.stderr
    except Exception as e:  # missing git, timeout, anything
        return 127, "", str(e)


def norm(p):
    try:
        return os.path.realpath(p) if p else ""
    except OSError:
        return p or ""


def is_registered_linked_worktree(repo, path):
    """(ok, why). The path must be the TOP LEVEL of a LINKED worktree that
    the RECORDED repository lists and does not call prunable. Exactly the
    facts native_member_gone() reads, asked before we touch anything."""
    if not os.path.isdir(path):
        return False, "%s does not exist" % path
    rc, out, err = git(path, "rev-parse", "--show-toplevel")
    if rc != 0:
        return False, "git cannot read %s: %s" % (path, err.strip()[:160])
    if norm(out.strip()) != norm(path):
        return False, "%s is not the top level of a git worktree" % path
    rc, out, _ = git(path, "rev-parse", "--git-dir", "--git-common-dir")
    lines = out.split()
    if rc != 0 or len(lines) < 2 or norm(lines[0]) == norm(lines[1]):
        return False, "%s is a main checkout, not a linked worktree" % path
    if not repo:
        return False, "no repository recorded for %s" % path
    rc, out, err = git(repo, "worktree", "list", "--porcelain")
    if rc != 0:
        return False, "git worktree list failed in %s: %s" % (repo, err.strip()[:160])
    want = norm(path)
    found = False
    prunable = False
    for block in out.split("\n\n"):
        cur = ""
        for line in block.splitlines():
            if line.startswith("worktree "):
                cur = norm(line[len("worktree "):])
            elif line.startswith("prunable") and cur == want:
                prunable = True
        if cur == want:
            found = True
    if not found:
        return False, "git does not list %s as a worktree of %s" % (path, repo)
    if prunable:
        return False, "git lists %s as prunable" % path
    return True, ""


def operation_in_progress(path):
    """A merge, rebase, cherry-pick, revert or bisect leaves state a working-
    tree rewrite must not walk into. Named, not guessed."""
    for marker in ("MERGE_HEAD", "REBASE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD",
                   "BISECT_LOG", "rebase-merge", "rebase-apply"):
        rc, out, _ = git(path, "rev-parse", "--git-path", marker)
        if rc == 0 and out.strip():
            p = out.strip()
            if not os.path.isabs(p):
                p = os.path.join(path, p)
            if os.path.exists(p):
                return marker
    return ""


def initialized_submodule(path):
    """A submodule's working tree is not reconstructible from THIS
    repository's object store, so a shell that has one is left alone."""
    if not os.path.exists(os.path.join(path, ".gitmodules")):
        return ""
    rc, out, _ = git(path, "submodule", "status")
    if rc != 0:
        return "submodule status is unreadable"
    for line in out.splitlines():
        if line and not line.startswith("-"):
            return line.strip()[:120]
    return ""


def worktree_config_hazard(path, repo):
    """git worktree(1): enabling extensions.worktreeConfig moves per-worktree
    settings out of the shared config, and `core.bare` / `core.worktree` left
    in the shared config then apply where they should not. If the extension is
    already on, `git sparse-checkout` writes core.sparseCheckout into THIS
    worktree's own config.worktree and nothing else is touched."""
    rc, out, _ = git(path, "config", "--get", "extensions.worktreeConfig")
    if rc == 0 and out.strip().lower() == "true":
        return ""
    cfg = os.path.join(repo or "", ".git", "config")
    try:
        with open(cfg, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return ""
    for line in text.splitlines():
        s = line.strip().replace(" ", "").lower()
        if s.startswith("bare=true") or s.startswith("worktree="):
            return ("extensions.worktreeConfig is off and %s sets core.%s; enabling it "
                    "would change how the main checkout reads its own config" % (cfg, s))
    return ""


def hooks_keep(path):
    """The top-level directory core.hooksPath resolves to, when it resolves
    INSIDE this worktree. A repository whose hooks live in `.githooks` keeps
    its commit-time guards inside the shell without anyone remembering to
    name the directory in config."""
    rc, out, _ = git(path, "config", "--get", "core.hooksPath")
    hp = out.strip() if rc == 0 else ""
    if not hp:
        return []
    full = hp if os.path.isabs(hp) else os.path.join(path, hp)
    try:
        rel = os.path.relpath(norm(full), norm(path))
    except ValueError:
        return []
    if rel.startswith("..") or rel in (".", ""):
        return []
    return [rel.split(os.sep)[0]]


def is_sparse(path):
    rc, out, _ = git(path, "config", "--get", "core.sparseCheckout")
    return rc == 0 and out.strip().lower() == "true"


# --------------------------------------------------------------------------
# the operation
# --------------------------------------------------------------------------

def _refused(reason, before=None):
    r = {"applied": False, "reason": reason, "ts": now_iso()}
    if before:
        r["bytes_before"], r["entries_before"] = before
    return r


def sparsify_shell(path, repo=None, keep=None, measure=True):
    """De-materialize a never-read native shell. Returns a result dict and
    NEVER raises. On any failure after the git command has run, the tree is
    restored with `sparse-checkout disable` before returning."""
    path = os.path.abspath(path)
    repo = os.path.abspath(repo) if repo else None
    enabled, cfg_keep = policy(repo)
    if not enabled:
        return _refused("SHELL_SPARSE is off")
    if keep is None:
        keep = cfg_keep
    ok, why = is_registered_linked_worktree(repo, path)
    if not ok:
        return _refused(why)
    if is_sparse(path):
        return _refused("already sparse")
    op = operation_in_progress(path)
    if op:
        return _refused("a git operation is in progress (%s)" % op)
    sub = initialized_submodule(path)
    if sub:
        return _refused("an initialized submodule is present (%s)" % sub)
    haz = worktree_config_hazard(path, repo)
    if haz:
        return _refused(haz)
    rc, out, err = git(path, "status", "--porcelain")
    if rc != 0:
        return _refused("git status failed: %s" % err.strip()[:160])
    if out.strip():
        n = len(out.strip().splitlines())
        return _refused("the shell has been written to (%d uncommitted path%s) — left at full size"
                        % (n, "" if n == 1 else "s"))

    keep_set = list(dict.fromkeys([k for k in list(keep) + hooks_keep(path) if k]))
    before = tree_size(path) if measure else (0, 0)
    rc, out, set_err = git(path, "sparse-checkout", "set", "--cone", *keep_set)
    if rc != 0:
        restored = restore_shell(path)
        return {"applied": False, "ts": now_iso(),
                "reason": "git sparse-checkout failed: %s" % (set_err.strip()[:200] or out.strip()[:200]),
                "restored": restored.get("ok", False), "bytes_before": before[0],
                "entries_before": before[1]}

    # Self-verification: the three properties this operation is not allowed to
    # cost. Any one of them missing rolls the whole thing back.
    problems = []
    rc, out, err = git(path, "status", "--porcelain")
    if rc != 0 or out.strip():
        problems.append("status is no longer clean (%s)" % (out.strip()[:120] or err.strip()[:120]))
    ok, why = is_registered_linked_worktree(repo, path)
    if not ok:
        problems.append("registration lost: %s" % why)
    if not os.path.isdir(path):
        problems.append("the directory is gone")
    if problems:
        restored = restore_shell(path)
        return {"applied": False, "ts": now_iso(),
                "reason": "post-conditions failed: " + "; ".join(problems),
                "restored": restored.get("ok", False)}

    after = tree_size(path) if measure else (0, 0)
    res = {"applied": True, "ts": now_iso(), "mode": "cone", "keep": keep_set,
           "bytes_before": before[0], "bytes_after": after[0],
           "entries_before": before[1], "entries_after": after[1],
           "bytes_freed": max(0, before[0] - after[0])}
    # GIT EXITS 0 WHEN IT COULD NOT REMOVE A FILE — measured, not assumed: an
    # unwritable directory produces "warning: unable to unlink ..." and status
    # 0, and a file left behind because it is not up to date produces
    # "warning: The following paths are not up to date". Nothing is lost
    # either way (what stays is what git refused to touch), so this is not a
    # failure — but a shell that did not shrink must not report as one that
    # did, and the exit code cannot tell them apart. The warnings are kept
    # verbatim beside the sizes that show the effect.
    warn = [ln for ln in (set_err or "").splitlines() if ln.strip()]
    if warn:
        res["git_warnings"] = warn[:20]
    return res


def restore_shell(path):
    """`git sparse-checkout disable` — the exact reverse, one command."""
    rc, out, err = git(path, "sparse-checkout", "disable")
    if rc != 0:
        return {"ok": False, "reason": (err.strip() or out.strip())[:200]}
    return {"ok": True, "bytes": tree_size(path)[0]}


# --------------------------------------------------------------------------
# the seal-time entry point
# --------------------------------------------------------------------------

def eligible(tx):
    """(index, member, reason). The shell is the NATIVE member of a
    `native+external` transaction that is still `bound` and not terminal.
    Nothing is resolved by name, and a plain native worker — whose native
    worktree IS its workspace — is never eligible."""
    if not isinstance(tx, dict) or not tx.get("sealed"):
        return None, None, "not sealed"
    if tx.get("terminal"):
        return None, None, "already terminal"
    if tx.get("kind") != "native+external":
        return None, None, "kind %r is not native+external" % tx.get("kind")
    for i, m in enumerate(tx.get("members") or []):
        if m.get("class") != "native":
            continue
        if m.get("sparse") is not None:
            return None, None, "already decided"
        if m.get("state") != "bound":
            return None, None, "native member state is %r, not bound" % m.get("state")
        return i, m, ""
    return None, None, "no native member"


def maybe_sparsify(tx, persist):
    """Called from worktree-transactions.try_seal the moment a manifest
    seals. `persist(index, **fields)` writes the member fields under the
    transaction lock and returns the new transaction.

    THIS FUNCTION IS ADVISORY AND MUST NEVER COST A SEAL. Every failure path
    returns the transaction it was given."""
    try:
        i, m, why = eligible(tx)
        if i is None:
            return tx
        res = sparsify_shell(m.get("path") or "", m.get("repo") or "")
        new = persist(i, sparse=res)
        return new or tx
    except Exception:
        return tx


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def main(argv):
    import argparse
    p = argparse.ArgumentParser(description="de-materialize a never-read native isolation shell")
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("inspect", "sparsify", "restore"):
        s = sub.add_parser(name)
        s.add_argument("--path", required=True)
        s.add_argument("--repo", default="")
        if name == "sparsify":
            s.add_argument("--keep", default=None,
                           help='space-separated directories to keep materialized')
    a = p.parse_args(argv)
    path = os.path.abspath(a.path)
    repo = os.path.abspath(a.repo) if a.repo else None
    if not repo:
        rc, out, _ = git(path, "rev-parse", "--path-format=absolute", "--git-common-dir")
        if rc == 0 and out.strip():
            repo = os.path.dirname(norm(out.strip().rstrip("/")))
    if a.cmd == "inspect":
        enabled, keep = policy(repo)
        ok, why = is_registered_linked_worktree(repo, path)
        size, entries = tree_size(path)
        print(json.dumps({"path": path, "repo": repo, "policy_enabled": enabled,
                          "keep": keep + hooks_keep(path), "registered": ok, "why": why,
                          "sparse": is_sparse(path), "bytes": size, "entries": entries},
                         indent=2, sort_keys=True))
        return 0
    if a.cmd == "restore":
        r = restore_shell(path)
        print(json.dumps(r, indent=2, sort_keys=True))
        return 0 if r.get("ok") else 1
    keep = a.keep.split() if a.keep is not None else None
    r = sparsify_shell(path, repo, keep)
    print(json.dumps(r, indent=2, sort_keys=True))
    return 0 if r.get("applied") else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
