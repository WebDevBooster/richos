#!/usr/bin/env python3
"""publication-completeness.py — the analysis behind publication-completeness.sh.

Read that script's header first; it carries the argument for why this contract
exists. This file is the predicate, and nothing else: it takes a publication
root, derives everything it needs from the tree, and prints findings.

The four checks are documented at their own functions below. What they all
share is the derivation rule this engine holds itself to:

    NOTHING HERE IS A TYPED INVENTORY OF CAPABILITIES.

The set of declarations is derived from the shipped source that reads them.
The set of documents is derived from git. The set of onboarding entry points
is derived from README's own link graph. The set of workflows is derived from
the paths GitHub Actions itself discovers. A capability added tomorrow is
checked by the next run with no edit here — which is the only reason this
check can still be true in six months.

Output is one line per finding on stdout, machine-greppable:

    <CHECK>\t<severity>\t<path>\t<message>

Exit codes: 0 no findings, 1 findings, 2 broken (see the .sh wrapper).
"""

import json
import os
import re
import subprocess
import sys

# ---------------------------------------------------------------------------
# Bounds. Exceeding one is BROKEN, never "checked what we could" — a checker
# that silently truncates its own scope is the defect it exists to find.
# ---------------------------------------------------------------------------
MAX_TRACKED_FILES = 100000
MAX_PRIVATE_FILES = 50000
MAX_FILE_BYTES = 4 * 1024 * 1024

FINDINGS = []


def finding(check, path, message):
    FINDINGS.append((check, path, message))


class Broken(Exception):
    pass


# ---------------------------------------------------------------------------
# The tree, as git sees it.
# ---------------------------------------------------------------------------
def git(root, *args):
    p = subprocess.run(["git", "-C", root] + list(args),
                       capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr


class Tree:
    """The publication-bound tree: tracked files only.

    Tracked-and-not-ignored is not an approximation of "what an adopter
    receives" — it IS what an adopter receives. Using os.path.exists() here
    would have been the subtle version of the bug this whole file is about: a
    citation that resolves on the author's disk and dangles in the clone.
    """

    def __init__(self, root):
        self.root = root
        rc, out, err = git(root, "ls-files", "-z")
        if rc != 0:
            raise Broken("`git ls-files` failed in %s: %s" % (root, err.strip()))
        self.files = set(x for x in out.split("\0") if x)
        if not self.files:
            raise Broken("`git ls-files` returned nothing in %s — that is not an "
                         "empty publication tree, it is a broken checkout." % root)
        if len(self.files) > MAX_TRACKED_FILES:
            raise Broken("%d tracked files exceeds the %d bound."
                         % (len(self.files), MAX_TRACKED_FILES))
        self.dirs = set()
        for f in self.files:
            d = os.path.dirname(f)
            while d:
                self.dirs.add(d)
                d = os.path.dirname(d)
        # Every directory that holds a VERSION file is a SHIPPED ROOT: a unit
        # somebody can vendor on its own. `engine/` is one; the repository root
        # is always one. This is how a doc under engine/docs/ gets to cite
        # `docs/foo.md` and mean engine/docs/foo.md — which is what its author
        # meant, and what an adopter who vendored engine/ at their root reads.
        self.shipped_roots = [""]
        for f in sorted(self.files):
            if os.path.basename(f) == "VERSION":
                d = os.path.dirname(f)
                if d and d not in self.shipped_roots:
                    self.shipped_roots.append(d)

    def has(self, rel):
        return rel in self.files or rel in self.dirs

    def read(self, rel):
        p = os.path.join(self.root, rel)
        try:
            if os.path.getsize(p) > MAX_FILE_BYTES:
                return None
            with open(p, encoding="utf-8", errors="replace") as fh:
                return fh.read()
        except (OSError, ValueError):
            return None

    def ignored(self, candidates):
        """Which of these repo-relative paths does .gitignore exclude?

        A citation of an ignored path is not a broken claim. It is a claim
        about a file that is GENERATED (a .sha256 sidecar install.sh mints) or
        OPERATOR-LOCAL (~/.claude state). Documenting those is the correct
        thing to do, and demanding they be committed would be demanding the
        opposite of what the boundary contract requires. Measured: this one
        rule removed 6 false positives on the first run, with no exemption.
        """
        cands = sorted(set(candidates))
        if not cands:
            return set()
        p = subprocess.run(["git", "-C", self.root, "check-ignore", "--stdin", "-z"],
                           input="\0".join(cands), capture_output=True, text=True)
        # rc 0 = some ignored, 1 = none ignored, 128 = error.
        if p.returncode not in (0, 1):
            raise Broken("`git check-ignore` failed: %s" % p.stderr.strip())
        return set(x for x in p.stdout.split("\0") if x)

    def nearest_shipped_root(self, rel):
        best = ""
        for r in self.shipped_roots:
            if r and (rel == r or rel.startswith(r + "/")) and len(r) > len(best):
                best = r
        return best


# ---------------------------------------------------------------------------
# CHECK 1 — REFERENTIAL HONESTY
# ---------------------------------------------------------------------------
# Every path a public document cites must resolve IN THE PUBLIC TREE.
#
# This is the cheapest of the four and it caught the loudest defect: a README
# that says "CI runs exactly this on windows-latest
# (.github/workflows/windows-companion-ci.yml)" about a file that exists in no
# repository anywhere. It also caught five citations that dangle for a reason
# worth stating, because it is the exact shape of the CEO's complaint: the
# publication boundary correctly MOVED five documents out to the private
# record, and every reference to them stayed behind. The boundary took the
# wrong things out. Nothing put the references right. A reader with only the
# public repo hits five dead links.
#
# PRECISION IS THE CONTRACT. A checker that fires on everything gets switched
# off, so the extraction was measured against this tree rather than argued:
#
#   naive (any backticked path, any ancestor anchor)          89 findings
#   + anchored only at the citing dir / shipped root / repo root
#   + gitignored targets skipped                              16 findings
#   + engine/reference/ declared as adopter-template prose    11 findings
#
# and all 11 were real. The three narrowing rules are, in order:
#
#   ANCHORED. A citation is a claim about THIS tree only if its first path
#   segment names something that exists in this tree at one of three anchors:
#   the citing file's own directory, its nearest shipped root, or the
#   repository root. `src/lib/Foo.svelte` in an example is not a claim about
#   this tree and is not treated as one. This is what removed 73 of the 89.
#
#   NOT IGNORED. See Tree.ignored().
#
#   NOT DECLARED REFERENCE MATERIAL. engine/reference/'s own README already
#   says, in prose: "Cross-file path references still point at the original
#   layout and will not resolve here — that is expected for reference
#   material." The CITATION_EXEMPT key makes that existing declaration
#   machine-readable. It is not a new license; it is the one already granted.
# ---------------------------------------------------------------------------

CITE_TOKEN = re.compile(r"`([^`\n]{2,200})`|\]\(([^)\s]{2,200})\)")
# Anything with a glob, a placeholder, a variable, a scheme, a home-relative or
# absolute root, or a `..` is not a concrete claim about a committed path.
CITE_REJECT = re.compile(r"""[*?<>{}$|\\"'\s]|\.\.|https?:|^~|^/|^-""")
CITE_HAS_EXT = re.compile(r"\.[A-Za-z0-9]{1,8}$")
# A FILENAME TEMPLATE IS NOT A CLAIM. `ui-ux-signoffs/SIGNOFF_YYYY-MM-DD_HH.MM.md`
# names the shape of a file the adopter will create, not a file anyone shipped.
# These are the conventional stand-ins, and treating them as citations was
# measured as 2 false positives out of the first 26 — small, but the kind that
# teaches a reader the check is pedantic, which is how a check gets switched off.
CITE_PLACEHOLDER = re.compile(r"(?:^|[^A-Za-z])(?:YYYY|MM|DD|HH|SS|NN|X{3,}|N{3,})(?:[^A-Za-z]|$)")
TEXT_SUFFIXES = (".md", ".txt")


def check_citations(tree, exempt_prefixes, used):
    pending = []
    for f in sorted(tree.files):
        if not f.endswith(TEXT_SUFFIXES):
            continue
        # A CHANGELOG RECORDS PATHS THAT NO LONGER EXIST, ON PURPOSE. Its
        # entries are of the form "`.github/workflows/kit-self-verify.yml` →
        # `.github/workflows/engine-self-verify.yml`" — the left side is
        # written down precisely BECAUSE it is gone. Demanding those resolve
        # would demand never renaming anything, and would grow one permanent
        # false positive per rename, forever. Same reason it is not in the
        # onboarding set: a changelog answers "what changed", not "what is".
        if os.path.basename(f) == "CHANGELOG.md":
            continue
        hit = _match_prefix(f, exempt_prefixes)
        if hit is not None:
            used.setdefault("CITATION_EXEMPT", set()).add(hit)
            continue
        text = tree.read(f)
        if text is None:
            continue
        anchors = [os.path.dirname(f), tree.nearest_shipped_root(f), ""]
        seen = set()
        for m in CITE_TOKEN.finditer(text):
            in_backticks = m.group(1) is not None
            cite = (m.group(1) or m.group(2) or "").strip().rstrip("/")
            if "/" not in cite or CITE_REJECT.search(cite):
                continue
            # `./x` INSIDE BACKTICKS IS A RUNTIME ARGUMENT, NOT A DOCUMENTED PATH.
            # app/README.md quotes the Tauri CLI's default icon source as
            # `./app-icon.png` — a value relative to whatever directory the
            # operator runs the command in. In a markdown LINK, `./` is instead
            # an ordinary relative link and must resolve, so the two syntaxes
            # are treated as what they respectively are.
            if in_backticks and cite.startswith("./"):
                continue
            if not CITE_HAS_EXT.search(cite.split("/")[-1]):
                continue
            if CITE_PLACEHOLDER.search(cite):
                continue
            if (f, cite) in seen:
                continue
            seen.add((f, cite))
            resolved = False
            anchored_as = None
            for a in anchors:
                full = os.path.normpath(os.path.join(a, cite)) if a else cite
                if tree.has(full):
                    resolved = True
                    break
                head = cite.split("/")[0]
                first = os.path.normpath(os.path.join(a, head)) if a else head
                if anchored_as is None and tree.has(first):
                    anchored_as = full
            if not resolved and anchored_as is not None:
                pending.append((f, cite, anchored_as))

    for f, cite, full in _drop_ignored(tree, pending):
        finding("CITATION", f,
                "cites `%s`, which does not exist in the published tree "
                "(would be %s). Fix the path, or point it at the private "
                "record by name so a reader with only the public repo is not "
                "sent to a file they will never have." % (cite, full))


def _drop_ignored(tree, pending):
    ign = tree.ignored([p[2] for p in pending])
    return [p for p in pending if p[2] not in ign]


# ---------------------------------------------------------------------------
# CHECK 2 — DECLARATION REACHABILITY  ("shipped inert")
# ---------------------------------------------------------------------------
# The engine's guards are switched on by a committed declaration file at the
# governed repository's root: .publication-boundary switches on the boundary
# guards, .ceo-todos switches on the TODOs guard. Presence IS adoption. That
# design is right, and it has a failure mode that is invisible from inside:
#
#   SHIP THE ENFORCEMENT, SHIP THE TESTS, SHIP NO DECLARATION AND NO WORD OF
#   IT ANYWHERE AN ADOPTER READS — AND THE CUSTOMER RECEIVES A GUARD THAT CAN
#   NEVER FIRE.
#
# That is not a hypothetical. On 2026-08-29 the engine shipped
# ceo-todos-lint.sh, guard-ceo-todos-commits.sh, lib/ceo-todos.{sh,py} and a
# full test suite, with no .ceo-todos anywhere, no template of one, and no
# mention in ONBOARDING-RUNBOOK.md, WALKTHROUGH.md or the bootstrap-interview
# skill. Every test passed. The probe was green. The capability was inert.
#
# THE SET OF DECLARATIONS IS DERIVED, NOT LISTED. Each guard names its own
# declaration in its own source, in one form the engine already uses twice:
#
#     : "${PUBLICATION_DECLARATION:=.publication-boundary}"
#     : "${CEO_TODOS_DECLARATION:=.ceo-todos}"
#
# so the set is a grep over shipped source, and a third capability added
# tomorrow is checked the moment it follows the same convention. What that
# does NOT catch is a capability that invents a different convention; see the
# .sh wrapper's "WHAT THIS CANNOT CATCH".
#
# TWO ARMS, because the failure had two halves:
#
#   COPYABLE   Some tracked file is named <D>, <D>.example, <D>.template or
#              <D>.sample. Without one, the adopter must reverse-engineer the
#              format out of a parser.
#   ONBOARDED  <D> is named in the ADOPTER'S ENTRY-POINT SET — README.md, the
#              transitive closure of the markdown it links to, and every
#              shipped SKILL.md. Derived from README's own link graph, so it
#              tracks the docs rather than a list of doc names. CHANGELOG.md
#              is not in the closure and must not be: a changelog records that
#              something happened, it does not tell a new adopter to do it.
# ---------------------------------------------------------------------------

DECL_BASH = re.compile(r""":\s*"\$\{([A-Z][A-Z0-9_]*_DECLARATION):=([^}"'\s]+)\}"\s*""")
DECL_ASSIGN = re.compile(r"""^\s*([A-Z][A-Z0-9_]*_DECLARATION)\s*=\s*["']([^"'\s]+)["']""",
                         re.MULTILINE)
SOURCE_SUFFIXES = (".sh", ".py", ".mjs", ".js", ".rb", ".ps1")
MD_LINK = re.compile(r"\]\(([^)\s#]{1,200})\)")


# A TEST FIXTURE IS NOT A SHIPPED CAPABILITY. Suites and mutation testers build
# synthetic trees declaring synthetic gates — this file's own suite declares a
# `.widget` — and deriving from those would demand a template and an onboarding
# paragraph for a capability that exists only inside a fixture. Caught on the
# first end-to-end ci-verify run: the check reported the engine as shipping
# inert `.widget` enforcement, which is exactly the kind of confident,
# well-formatted, wrong finding that gets a checker switched off.
#
# The blind spot this opens, stated: a declaration named ONLY in a test file is
# not derived. That is the correct reading — a gate no shipped code reads is not
# a capability the tree offers.
FIXTURE_SUFFIXES = (".test.sh", ".test.py", ".mutation.sh")


def derive_declarations(tree):
    decls = {}
    for f in sorted(tree.files):
        if not f.endswith(SOURCE_SUFFIXES) or f.endswith(FIXTURE_SUFFIXES):
            continue
        text = tree.read(f)
        if text is None:
            continue
        # A DEFINITION IS CODE. A COMMENT QUOTING THE CONVENTION IS NOT.
        # This file's own header quotes both real declarations verbatim to
        # explain the derivation, and that made it register as a THIRD source
        # of `.ceo-todos` — so a finding named it alongside the guard that
        # actually implements the gate, and deleting the real guard would have
        # left the declaration "alive" in a doc comment. Comment lines are
        # dropped before matching, which is both more accurate and the reason
        # a header may go on quoting the convention it documents.
        code = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))
        for rx in (DECL_BASH, DECL_ASSIGN):
            for m in rx.finditer(code):
                decls.setdefault(m.group(2), set()).add(f)
    return decls


# A CHANGELOG IS NOT ONBOARDING, and this distinction is load-bearing rather
# than fussy. Measured: with CHANGELOG.md in the closure, BOTH declarations
# passed the ONBOARDED arm — because the changelog records the commit that
# ADDED them. `.ceo-todos` was mentioned in exactly one published document, the
# one that says it happened, and in none of the documents that tell an adopter
# to do it. A changelog answers "what changed"; onboarding answers "what do I
# do". Counting the first as the second is how a capability comes to look
# documented while being undiscoverable, which is failure #1 wearing a
# reassuring green tick.
NOT_ONBOARDING = {"CHANGELOG.md", "LICENSE", "LICENSE.md", "LICENSE-TODO.md"}


def onboarding_set(tree):
    """README.md, everything it links to transitively, and every SKILL.md."""
    frontier, seen = [], set()
    for root in tree.shipped_roots:
        r = os.path.join(root, "README.md") if root else "README.md"
        if tree.has(r):
            frontier.append(r)
    for f in sorted(tree.files):
        if os.path.basename(f) == "SKILL.md":
            frontier.append(f)
    while frontier:
        cur = frontier.pop()
        if cur in seen or os.path.basename(cur) in NOT_ONBOARDING:
            continue
        seen.add(cur)
        text = tree.read(cur)
        if text is None:
            continue
        base = os.path.dirname(cur)
        for m in MD_LINK.finditer(text):
            t = m.group(1)
            if not t.endswith(".md") or CITE_REJECT.search(t):
                continue
            nxt = os.path.normpath(os.path.join(base, t)) if base else t
            if tree.has(nxt) and nxt not in seen:
                frontier.append(nxt)
    return seen


def check_declarations(tree, exempt, used, explain):
    decls = derive_declarations(tree)
    if not decls:
        raise Broken("derived NO declaration names from shipped source. The engine "
                     "has used the `${X_DECLARATION:=.name}` convention since "
                     "2026-08-29; finding none means the derivation is broken, not "
                     "that there is nothing to check.")
    onboard = onboarding_set(tree)
    if not onboard:
        raise Broken("derived an EMPTY adopter entry-point set (no README.md and no "
                     "SKILL.md anywhere in the tree). Refusing to report every "
                     "declaration as undocumented on the strength of that.")
    if explain:
        sys.stderr.write("declarations derived: %s\n" % ", ".join(sorted(decls)))
        sys.stderr.write("adopter entry-point set (%d):\n  %s\n"
                         % (len(onboard), "\n  ".join(sorted(onboard))))

    by_base = {}
    for f in tree.files:
        by_base.setdefault(os.path.basename(f), []).append(f)

    for d in sorted(decls):
        problems = []
        # A DOTFILE'S TEMPLATE IS USUALLY SHIPPED WITHOUT THE DOT, because a
        # hidden template is a template nobody browsing the tree ever sees.
        # `.ceo-todos`'s real one shipped as reference/ceo-todos/ceo-todos.example
        # and this check called it missing — a false positive on a capability
        # that had just been fixed properly, which is how a checker earns the
        # reputation that gets it switched off. The dot-stripped form is
        # accepted only WITH an explicit template suffix, so a coincidentally
        # named file can never satisfy this arm.
        stem = d[1:] if d.startswith(".") else d
        names = [d] + ["%s.%s" % (n, sfx)
                       for n in ({d, stem} if stem else {d})
                       for sfx in ("example", "template", "sample")]
        if not any(by_base.get(n) for n in names):
            problems.append("no copyable instance or template of `%s` is published "
                            "(looked for %s anywhere in the tree)"
                            % (d, ", ".join(sorted(set(names)))))
        if not any(d in (tree.read(p) or "") for p in sorted(onboard)):
            problems.append("`%s` is named in no document an adopter reads "
                            "(README.md, everything README links to, and every "
                            "SKILL.md)" % d)
        if not problems:
            continue
        if d in exempt:
            used.setdefault("DECLARATION_EXEMPT", set()).add(d)
            continue
        finding("INERT", ", ".join(sorted(decls[d])),
                "ships enforcement gated on `%s`, but %s. A customer receives "
                "machinery that can never fire." % (d, "; and ".join(problems)))


# ---------------------------------------------------------------------------
# CHECK 3 — WORKFLOW REACHABILITY
# ---------------------------------------------------------------------------
# GitHub Actions discovers workflows ONLY in `.github/workflows/` at the
# REPOSITORY ROOT. Until 2026-08-29 this repository's only copy of its own
# self-verification lived at engine/.github/workflows/engine-self-verify.yml.
# It was not broken and it was not misconfigured. It had never executed once —
# `gh run list` returned nothing at all — because it sat at a path the runner
# does not look at.
#
# A workflow under a subdirectory is legitimate: it is the ADOPTER'S TEMPLATE,
# and it fires at their root once they vendor the engine there. What is not
# legitimate is that being the ONLY copy, because then the repository shipping
# it has never run the thing it tells the adopter to run.
#
# So the predicate is not "no workflows in subdirectories". It is: whatever a
# subdirectory workflow INVOKES must also be invoked by a workflow at the root.
# Entry points are read out of the YAML's own `run:` lines, so the two copies
# are compared on what they actually do rather than on being byte-identical —
# which they must not be (the root copy carries `working-directory: engine`).
# ---------------------------------------------------------------------------

WF_RE = re.compile(r"(?:^|/)\.github/workflows/[^/]+\.ya?ml$")
RUN_TOKEN = re.compile(r"[\w./-]+\.(?:sh|py|ps1|bash)\b")


def _wf_entrypoints(text):
    eps = set()
    for line in (text or "").splitlines():
        s = line.strip()
        if not (s.startswith("run:") or s.startswith("- run:") or s.startswith("-run:")):
            continue
        for m in RUN_TOKEN.finditer(s):
            eps.add(os.path.basename(m.group(0)))
    return eps


def check_workflows(tree, exempt, used, explain):
    wfs = [f for f in sorted(tree.files) if WF_RE.search(f)]
    if not wfs:
        return
    root_wfs = [f for f in wfs if f.startswith(".github/workflows/")]
    root_eps = set()
    for f in root_wfs:
        root_eps |= _wf_entrypoints(tree.read(f))
    if explain:
        sys.stderr.write("workflows: %d total, %d at the repository root; root entry "
                         "points: %s\n" % (len(wfs), len(root_wfs),
                                           ", ".join(sorted(root_eps)) or "(none)"))
    for f in wfs:
        if f in root_wfs:
            continue
        if f in exempt:
            used.setdefault("WORKFLOW_EXEMPT", set()).add(f)
            continue
        eps = _wf_entrypoints(tree.read(f))
        if not root_wfs:
            finding("UNREACHABLE", f,
                    "is a GitHub Actions workflow outside `.github/workflows/` at the "
                    "repository root, and this repository has NO root workflow at all. "
                    "Actions discovers workflows only at the root, so this file has "
                    "never executed and cannot. A workflow that has not run verifies "
                    "nothing.")
            continue
        if eps and not (eps & root_eps):
            finding("UNREACHABLE", f,
                    "runs %s, which no root-level workflow runs. Actions discovers "
                    "workflows only at `.github/workflows/` in the repository root, so "
                    "this copy never executes here — it is a template for an adopter, "
                    "and nothing in THIS repository proves it works."
                    % ", ".join(sorted(eps)))


# ---------------------------------------------------------------------------
# CHECK 4 — MECHANISM MISPLACEMENT
# ---------------------------------------------------------------------------
# The TODOs contract shipped its guard, its lint and its parser to the public
# tree, and left the renderer — the only thing that turns the record into
# something a CEO can look at — in the private HQ repository. The customer got
# the enforcement and not the view.
#
# THE JUDGEMENT CALL IS MECHANISM vs INSTANCE DATA, and it is made
# STRUCTURALLY rather than by opinion:
#
#   INSTANCE DATA  is content. `.ceo-todos` in richos-hq is one company's
#                  declaration; CEO-TODOs.md is one company's TODOs. Correctly
#                  private, and never a candidate here, because neither has a
#                  shebang nor an executable extension.
#
#   MECHANISM      is executable. A shebang, or a .sh/.py/.mjs/.js/.rb/.ps1
#                  extension. render-ceo-todos.mjs is one.
#
# Being a mechanism is not enough — a private repo is allowed its own scripts.
# The defect is a private mechanism COUPLED TO A PUBLIC CONTRACT: it reads or
# writes an artifact whose format is defined by machinery in the public tree,
# i.e. it mentions one of the declaration names Check 2 derived. That is the
# whole test, and it is why normalize-gpt-branch-exports.mjs — a private script
# that couples to nothing public — is not flagged and should not be.
#
# WHERE the private trees are is not guessed: it is read from PRIVATE_SOURCES
# in .publication-boundary, which the operator already maintains for the
# boundary guard. One declaration, two contracts, no second copy to drift.
# ---------------------------------------------------------------------------

EXEC_SUFFIXES = (".sh", ".py", ".mjs", ".js", ".rb", ".ps1", ".bash")
SKIP_DIRS = {".git", "node_modules", "target", "dist", "build", ".venv", "__pycache__"}


def _is_mechanism(path):
    if path.endswith(EXEC_SUFFIXES):
        return True
    try:
        with open(path, "rb") as fh:
            return fh.read(2) == b"#!"
    except OSError:
        return False


def check_misplacement(tree, private_roots, decl_names, exempt, used, explain):
    if not private_roots:
        return
    for label, root in private_roots:
        n = 0
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for fn in sorted(filenames):
                n += 1
                if n > MAX_PRIVATE_FILES:
                    raise Broken("walking the declared private tree %s exceeded the "
                                 "%d-file bound. Refusing to report a clean "
                                 "misplacement check over a truncated walk."
                                 % (root, MAX_PRIVATE_FILES))
                full = os.path.join(dirpath, fn)
                if not _is_mechanism(full):
                    continue
                rel = os.path.relpath(full, root)
                try:
                    if os.path.getsize(full) > MAX_FILE_BYTES:
                        continue
                    with open(full, encoding="utf-8", errors="replace") as fh:
                        body = fh.read()
                except OSError:
                    continue
                coupled = sorted(d for d in decl_names if d in body)
                if not coupled:
                    continue
                key = "%s/%s" % (label, rel)
                if key in exempt:
                    used.setdefault("INSTANCE_MECHANISMS", set()).add(key)
                    continue
                finding("MISPLACED", key,
                        "is an executable mechanism in the PRIVATE tree that reads the "
                        "public contract %s. The public tree ships the enforcement and "
                        "withholds this. Move it into the published tree, or declare it "
                        "instance-specific in .publication-completeness "
                        "(INSTANCE_MECHANISMS)." % ", ".join("`%s`" % c for c in coupled))
        if explain:
            sys.stderr.write("private tree %s (%s): %d files walked\n" % (label, root, n))


def _match_prefix(path, prefixes):
    for p in prefixes:
        if path == p.rstrip("/") or path.startswith(p if p.endswith("/") else p + "/"):
            return p
    return None


# ---------------------------------------------------------------------------
def main():
    cfg = json.loads(sys.stdin.read())
    root = cfg["root"]
    explain = bool(cfg.get("explain"))
    exempt = cfg.get("exempt", {})
    used = {}

    try:
        tree = Tree(root)
        decls = derive_declarations(tree)
        check_citations(tree, exempt.get("CITATION_EXEMPT", []), used)
        check_declarations(tree, set(exempt.get("DECLARATION_EXEMPT", [])), used, explain)
        check_workflows(tree, set(exempt.get("WORKFLOW_EXEMPT", [])), used, explain)
        check_misplacement(tree, cfg.get("private_roots", []), set(decls),
                           set(exempt.get("INSTANCE_MECHANISMS", [])), used, explain)
    except Broken as e:
        sys.stderr.write("BROKEN: %s\n" % e)
        return 2

    # -----------------------------------------------------------------------
    # AN EXEMPTION THAT SUPPRESSES NOTHING IS A FAILURE.
    #
    # Every exemption list in this engine is a place drift hides: the line was
    # written for a real reason, the reason was fixed, and the line stayed —
    # now silently licensing the next instance of the defect. So an exemption
    # that no longer suppresses anything does not pass quietly; it FAILS, and
    # names itself for deletion. That is what makes the escape hatch safe to
    # have: it cannot outlive its own justification.
    # -----------------------------------------------------------------------
    for key in sorted(exempt):
        for entry in sorted(exempt[key]):
            if entry not in used.get(key, set()):
                finding("STALE-EXEMPTION", ".publication-completeness",
                        "%s entry `%s` suppresses nothing any more. Either the defect "
                        "it excused is fixed — in which case DELETE THIS LINE — or the "
                        "path it names has moved and the exemption is now silently "
                        "licensing something else." % (key, entry))

    for check, path, msg in sorted(FINDINGS):
        sys.stdout.write("%s\t%s\t%s\n" % (check, path, msg))
    return 1 if FINDINGS else 0


if __name__ == "__main__":
    sys.exit(main())
