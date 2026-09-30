#!/usr/bin/env python3
"""publication-completeness-graph.test.py -- the reachability graph follows the
links and commands that are really there.

  G1  a parent-relative markdown link (`../guide.md`) enters the onboarding set
  G2  a link with a #fragment (`guide.md#setup`) enters it too
  G3  commands inside a `run: |` block are read as workflow entry points
  G4  an unrooted workflow is UNREACHABLE when ANY of its commands has no root
      run, not only when none is shared
  G5  (control) a workflow whose every command a root workflow runs is covered
"""
import importlib.util
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "publication_completeness", os.path.join(HERE, "publication-completeness.py"))
pc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pc)


class FakeTree:
    def __init__(self, files):
        self.files = set(files)
        self._text = files
        self.shipped_roots = [""]

    def has(self, p):
        return p in self.files

    def read(self, p):
        return self._text.get(p)


class Graph(unittest.TestCase):
    def test_parent_relative_link_is_followed(self):
        tree = FakeTree({"README.md": "see [docs](docs/index.md)",
                         "docs/index.md": "back to [guide](../guide.md)",
                         "guide.md": "x"})
        self.assertIn("guide.md", pc.onboarding_set(tree))

    def test_fragment_link_is_followed(self):
        tree = FakeTree({"README.md": "see [setup](guide.md#setup)", "guide.md": "x"})
        self.assertIn("guide.md", pc.onboarding_set(tree))

    def test_block_scalar_run_commands_are_entry_points(self):
        wf = ("jobs:\n  a:\n    steps:\n      - run: |\n"
              "          bash scripts/alpha.sh\n          python3 scripts/beta.py\n"
              "      - run: scripts/gamma.sh\n      - name: next\n        uses: x\n")
        self.assertEqual(pc._wf_entrypoints(wf), {"alpha.sh", "beta.py", "gamma.sh"})

    def test_block_scalar_stops_at_the_next_key(self):
        wf = "      - run: |\n          bash a.sh\n        env:\n          X: b.sh\n"
        self.assertEqual(pc._wf_entrypoints(wf), {"a.sh"})

    def _workflow_findings(self, sub_wf):
        pc.FINDINGS.clear()
        tree = FakeTree({".github/workflows/root.yml": "      - run: bash common.sh\n",
                         "sub/.github/workflows/t.yml": sub_wf})
        pc.check_workflows(tree, set(), {}, False)
        return list(pc.FINDINGS)

    def test_any_uncovered_command_is_unreachable(self):
        found = self._workflow_findings("      - run: bash common.sh\n      - run: bash unique.sh\n")
        self.assertEqual(len(found), 1)
        self.assertIn("unique.sh", found[0][2])
        self.assertNotIn("common.sh", found[0][2])

    def test_fully_covered_workflow_is_quiet(self):
        self.assertEqual(self._workflow_findings("      - run: bash common.sh\n"), [])


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]] + sys.argv[1:])
