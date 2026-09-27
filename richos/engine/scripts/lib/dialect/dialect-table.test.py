#!/usr/bin/env python3
"""dialect-table.test.py - the generated American spelling table is fresh, pinned, consistent
with every hand-kept list, and safe to apply without context.

Every word this suite needs is read from the data at run time (the table, the lists, the
fixtures), never written here, so the suite itself carries no vocabulary word; test_own_code
proves that for every non-data file beside the generator.
"""
import hashlib
import importlib.util
import re
import shutil
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("dialect_table", HERE / "dialect-table.py")
dt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dt)

FIXTURES = HERE / "fixtures"


def table_rows(text):
    rows = {}
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        rows[parts[0]] = (parts[1], parts[2] if len(parts) > 2 else "")
    return rows


class Base(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.committed = dt.TABLE.read_text(encoding="utf-8")
        cls.rows = table_rows(cls.committed)
        clusters = dt.parse_clusters(dt.read_varcon())
        cls.verified, cls.any_tier, cls.ambiguous = dt.split_varcon(clusters)
        cls.hand = dt.read_pairs(dt.DICT)
        cls.overrides = dt.read_pairs(dt.OVERRIDES)
        cls.leave = dt.read_leave(dt.LEAVE)


class Freshness(Base):
    def test_committed_table_matches_a_fresh_generation(self):
        text, _, stats = dt.generate()
        self.assertEqual(self.committed, text, "run dialect-table.py and commit the table")
        self.assertEqual(len(self.rows), stats["table"])

    def test_check_mode_agrees(self):
        self.assertEqual(dt.main(["--check"]), 0)

    def test_varcon_is_the_pinned_bytes(self):
        raw = dt.VARCON.read_bytes()
        self.assertEqual(hashlib.sha256(raw).hexdigest(), dt.VARCON_SHA256)

    def test_a_changed_input_is_refused(self):
        with tempfile.TemporaryDirectory(prefix="dialect-table-test-") as tmp:
            copy = Path(tmp) / "varcon.txt"
            raw = bytearray(dt.VARCON.read_bytes())
            raw[-2] = ord("q") if raw[-2] != ord("q") else ord("z")
            copy.write_bytes(bytes(raw))
            with self.assertRaises(dt.Refused):
                dt.generate(varcon_path=copy)


class Composition(Base):
    def test_split_counts_match_the_research(self):
        # richos-hq docs/research/2026-09-27-american-spelling-autofix.md: 107 ambiguous;
        # 3,855 verified forms at level 70 or below, 3,781 of them lowercase.
        self.assertEqual(len(self.ambiguous), 107)
        self.assertEqual(len(self.verified), 3781)

    def test_every_hand_kept_line_is_carried_with_its_options(self):
        for form, (target, opts) in self.hand.items():
            self.assertEqual(self.rows.get(form), (target, opts), form)

    def test_hand_kept_dictionary_never_disagrees_with_varcon(self):
        for form, (target, _) in self.hand.items():
            self.assertNotIn(form, self.ambiguous, form)
            if form in self.verified:
                self.assertEqual(self.verified[form], target, form)

    def test_every_override_is_carried_and_really_is_one(self):
        for form, (target, _) in self.overrides.items():
            self.assertEqual(self.rows.get(form), (target, ""), form)
            self.assertNotIn(form, self.verified, form)
            self.assertNotIn(form, self.hand, form)
            if form in self.any_tier:
                self.assertEqual(self.any_tier[form], target, form)

    def test_every_leave_entry_removes_a_verified_form(self):
        for form in self.leave:
            self.assertIn(form, self.verified, form)
            self.assertNotIn(form, self.rows, form)

    def test_everything_else_verified_is_carried_unchanged(self):
        for form, target in self.verified.items():
            if form in self.leave:
                continue
            self.assertEqual(self.rows[form][0], target, form)

    def test_no_ambiguous_form_is_ever_emitted(self):
        self.assertFalse(set(self.rows) & set(self.ambiguous))

    def test_review_list_dispositions_are_applied(self):
        seen = {"fix": 0, "leave": 0}
        for line in (FIXTURES / "harper-review-list.tsv").read_text(encoding="utf-8").splitlines():
            if not line or line.startswith("#"):
                continue
            form, disposition = line.split("\t")
            seen[disposition] += 1
            self.assertIn(form, self.verified, form)
            if disposition == "fix":
                self.assertEqual(self.rows.get(form), (self.verified[form], ""), form)
            else:
                self.assertNotIn(form, self.rows, form)
                self.assertTrue(self.leave.get(form, "").startswith("review-list:"), form)
        self.assertEqual(seen, {"fix": 18, "leave": 7})


class SafeWithoutContext(Base):
    def test_keys_and_targets_are_lowercase_ascii_letters(self):
        self.assertTrue(self.committed.isascii(), "the app embeds this with include_str!")
        for form, (target, _) in self.rows.items():
            self.assertRegex(form, r"^[a-z]+$")
            self.assertRegex(target, r"^[a-z]+$")

    def test_no_key_is_hex_only(self):
        # A hex-only key could match inside a commit SHA in a reply or a record.
        self.assertEqual([f for f in self.rows if re.fullmatch(r"[a-f0-9]+", f)], [])

    def test_no_self_map_and_no_chain(self):
        for form, (target, _) in self.rows.items():
            self.assertNotEqual(form, target)
            self.assertNotIn(target, self.rows, "%s -> %s is itself a key" % (form, target))

    def test_rows_are_sorted_and_unique(self):
        forms = [ln.split("\t")[0] for ln in self.committed.splitlines() if ln and not ln.startswith("#")]
        self.assertEqual(forms, sorted(set(forms)))

    def test_header_marks_the_modified_version_and_carries_the_notices(self):
        head = "\n".join(ln for ln in self.committed.splitlines() if ln.startswith("#"))
        self.assertIn("THIS IS A MODIFIED VERSION OF VARCON", head)
        self.assertIn(dt.VARCON_SHA256, head)
        for holder in ("Copyright 2000-2019 by Kevin Atkinson", "Copyright 2016 by Benjamin Titze",
                       "Copyright 1993, Geoff Kuenning"):
            self.assertIn(holder, head)
        self.assertIn("may not be used to endorse or promote", head)
        self.assertIn('"AS IS"', head.replace("``AS IS''", '"AS IS"'))


class Refusals(Base):
    """The generator refuses every disagreement instead of picking a winner. Words come from
    the data, so these cases stay valid whatever VarCon or the lists contain."""

    def run_with(self, hand=None, overrides=None, leave=None):
        with tempfile.TemporaryDirectory(prefix="dialect-table-test-") as tmp:
            tmp = Path(tmp)
            paths = {}
            for name, rows, src in (("dict", hand, dt.DICT), ("overrides", overrides, dt.OVERRIDES),
                                    ("leave", leave, dt.LEAVE)):
                p = tmp / name
                if rows is None:
                    shutil.copyfile(src, p)
                else:
                    p.write_text("".join("\t".join(r) + "\n" for r in rows), encoding="utf-8")
                paths[name] = p
            return dt.generate(dict_path=paths["dict"], overrides_path=paths["overrides"],
                               leave_path=paths["leave"])

    def unverified_pair(self):
        for form, target in sorted(self.any_tier.items()):
            if form not in self.verified and form not in self.hand and form == form.lower() \
                    and re.fullmatch(r"[a-z]+", form):
                return form, target
        self.fail("no unverified VarCon pair to test with")

    def test_baseline_generates(self):
        self.run_with()

    def test_override_already_verified_is_refused(self):
        form = sorted(f for f in self.verified if f not in self.hand and f not in self.leave)[0]
        with self.assertRaisesRegex(dt.Refused, "not an override"):
            self.run_with(overrides=[(form, self.verified[form])])

    def test_override_disagreeing_with_varcon_is_refused(self):
        form, target = self.unverified_pair()
        with self.assertRaisesRegex(dt.Refused, "unverified"):
            self.run_with(overrides=[(form, target + "x")])

    def test_override_that_is_ambiguous_is_refused(self):
        form = sorted(f for f in self.ambiguous if re.fullmatch(r"[a-z]+", f))[0]
        with self.assertRaisesRegex(dt.Refused, "preferred American"):
            self.run_with(overrides=[(form, form + "x")])

    def test_dictionary_disagreeing_with_varcon_is_refused(self):
        form = sorted(self.verified)[0]
        rows = [(f, t) for f, (t, _) in self.hand.items()] + [(form, self.verified[form] + "x")]
        with self.assertRaisesRegex(dt.Refused, "VarCon's verified form"):
            self.run_with(hand=rows)

    def test_stale_leave_entry_is_refused(self):
        form, _ = self.unverified_pair()
        rows = [(f, w) for f, w in self.leave.items()] + [(form, "stale on purpose")]
        with self.assertRaisesRegex(dt.Refused, "removes nothing"):
            self.run_with(leave=rows)

    def test_duplicate_line_is_refused(self):
        form, target = self.unverified_pair()
        with self.assertRaisesRegex(dt.Refused, "repeats"):
            self.run_with(overrides=[(form, target), (form, target)])


class KeyedSample(Base):
    """fixtures/british-keyed.txt, the research's keyed sample: the table must carry every
    must-fix item as data, and carry no must-leave word except the declared context traps."""
    KEY = re.compile(r"\{([^|{}]+)\|([^{}]*)\}")

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        items = cls.KEY.findall((FIXTURES / "british-keyed.txt").read_text(encoding="utf-8"))
        cls.fix = [(b, a) for b, a in items if a != "="]
        cls.keep = [b for b, a in items if a == "="]
        cls.context_traps = {ln.strip() for ln in (FIXTURES / "british-keyed.context-traps.txt")
                             .read_text(encoding="utf-8").splitlines()
                             if ln.strip() and not ln.startswith("#")}

    def test_sample_shape(self):
        self.assertEqual((len(self.fix), len(self.keep)), (106, 30))

    def test_every_must_fix_item_is_in_the_table(self):
        missed = [(b, a) for b, a in self.fix if self.rows.get(b.lower(), ("",))[0] != a.lower()]
        self.assertEqual(missed, [])

    def test_only_declared_context_traps_are_in_the_table(self):
        self.assertEqual({b.lower() for b in self.keep if b.lower() in self.rows}, self.context_traps)


class OwnCode(Base):
    def test_own_code_carries_no_vocabulary_word(self):
        # These files need no dialect exemption because they contain no word the table would
        # change. If one ever does, give it an exemption deliberately or reword it.
        words = re.compile(r"[A-Za-z]+")
        for name in ("dialect-table.py", "dialect-table.test.py", "dialect-table.test.sh", "README.md"):
            text = (HERE / name).read_text(encoding="utf-8")
            hits = sorted({w for w in words.findall(text) if w.lower() in self.rows})
            self.assertEqual(hits, [], name)


if __name__ == "__main__":
    unittest.main(verbosity=2)
