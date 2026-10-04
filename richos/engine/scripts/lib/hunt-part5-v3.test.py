#!/usr/bin/env python3
"""Hunt part 5, v3 (richos-hq docs/audits/2026-09-29-hunt/part-5-codex-v3.md).

Each class is one finding's reproduction from that report, red on main 3171302c2
and green with its fix. Fixtures are data only: no command named in a case is run
unless the case says so, and anything it runs is harmless (print, true, grep).
"""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Scratch(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="hunt-p5v3-")
        self.addCleanup(shutil.rmtree, self.tmp, True)


class P5_08_UnreadManifestBlob(Scratch):
    """A staged blob the scanner could not read is not CLEAN."""

    def scan(self, rows):
        ids = os.path.join(self.tmp, "ids")
        with open(ids, "w") as fh:
            fh.write("FIXTURE-SERIAL-0001\n")
        manifest = os.path.join(self.tmp, "manifest")
        with open(manifest, "w") as fh:
            fh.write("".join("%s\t%s\n" % r for r in rows))
        env = dict(os.environ, RICHOS_DEVICE_IDENTIFIERS_FILE=ids)
        out = subprocess.run([sys.executable, os.path.join(HERE, "device-identifiers.py"),
                              "--scan-manifest", manifest], capture_output=True, text=True,
                             env=env, timeout=60)
        self.assertEqual(out.returncode, 0, out.stderr)
        return out.stdout

    def test_missing_blob_is_not_clean(self):
        out = self.scan([("fixture.txt", os.path.join(self.tmp, "no-such-blob"))])
        self.assertEqual(out.split("\t")[0].strip(), "BROKEN", out)

    def test_readable_match_still_found(self):
        blob = os.path.join(self.tmp, "blob")
        with open(blob, "w") as fh:
            fh.write("serial fixture-serial-0001 here\n")
        self.assertTrue(self.scan([("fixture.txt", blob)]).startswith("FOUND\n"))

    def test_readable_clean_blob_is_clean(self):
        blob = os.path.join(self.tmp, "blob")
        with open(blob, "w") as fh:
            fh.write("nothing here\n")
        self.assertEqual(self.scan([("fixture.txt", blob)]), "CLEAN\n")


class P5_45_RedirectionOperands(Scratch):
    """Reading or writing a guard file is not running it (hook_enforced_on_surface)."""

    def enforced(self, command):
        surface = os.path.join(self.tmp, "hooks.json")
        with open(surface, "w") as fh:
            json.dump({"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [
                {"type": "command", "command": command}]}]}}, fh)
        out = subprocess.run(["bash", "-c", '. "$1"; hook_enforced_on_surface "$2" guard-ghost.sh',
                              "_", os.path.join(HERE, "registered-hooks.sh"), surface],
                             capture_output=True, text=True, timeout=60)
        return out.returncode

    def test_direct_execution_is_enforced(self):
        self.assertEqual(self.enforced("bash scripts/hooks/guard-ghost.sh"), 0)

    def test_input_redirection_is_not_enforced(self):
        self.assertEqual(self.enforced("cat < scripts/hooks/guard-ghost.sh"), 1)

    def test_output_redirection_is_not_enforced(self):
        self.assertEqual(self.enforced("echo x > scripts/hooks/guard-ghost.sh"), 1)

    def test_python_inline_code_is_not_enforced(self):
        self.assertEqual(self.enforced("python3 -c scripts/hooks/guard-ghost.sh"), 1)

    def test_env_option_argument_does_not_hide_the_program(self):
        self.assertEqual(self.enforced("env -u UNUSED bash scripts/hooks/guard-ghost.sh"), 0)

    def test_redirect_after_a_real_run_still_enforced(self):
        self.assertEqual(self.enforced("bash scripts/hooks/guard-ghost.sh 2>/dev/null"), 0)


class P5_57_UnrelatedReadIsNotTheRegister(unittest.TestCase):
    """A program that names the register but reads another file did not read the register."""

    REG = "/repo/docs/failure-types.md"
    REL = "docs/failure-types.md"
    BASE = "failure-types.md"

    @classmethod
    def setUpClass(cls):
        cls.ft = load("failure_type", os.path.join(HERE, "failure-type.py"))

    def credited(self, cmd):
        return self.ft.bash_reads_register(cmd, self.REG, self.REL, self.BASE)

    def test_print_name_then_open_other_file(self):
        self.assertFalse(self.credited(
            """python3 -c "print('failure-types.md');open('other-file').read()" """))

    def test_printed_open_text_is_not_a_read(self):
        self.assertFalse(self.credited("""python3 -c "print('open(failure-types.md)')" """))

    def test_writing_the_register_is_not_reading_it(self):
        self.assertFalse(self.credited("""python3 -c "open('failure-types.md', 'w').write('x')" """))

    def test_python_open_of_register_is_credited(self):
        self.assertTrue(self.credited("""python3 -c "open('failure-types.md').read()" """))

    def test_pathlib_read_of_register_is_credited(self):
        self.assertTrue(self.credited(
            """python3 -c "from pathlib import Path; print(Path('docs/failure-types.md').read_text())" """))

    def test_perl_open_of_register_is_credited(self):
        self.assertTrue(self.credited("""perl -e 'open(my $f, "<", "failure-types.md"); print <$f>'"""))

    def test_cat_of_register_is_credited(self):
        self.assertTrue(self.credited("cat failure-types.md"))


class P5_67_ShortCircuitedGrep(unittest.TestCase):
    """A quiet exit 1 excuses a command only when the no-match tool produced it."""

    @classmethod
    def setUpClass(cls):
        # The verifier's Python lives inside row-headline-verify.sh; take the exact
        # function text from it rather than a copy.
        with open(os.path.join(SCRIPTS, "row-headline-verify.sh"), encoding="utf-8") as fh:
            src = fh.read()
        start = src.index("NO_MATCH_TOOLS = ")
        end = src.index("    return verb in NO_MATCH_TOOLS\n", start) + len("    return verb in NO_MATCH_TOOLS\n")
        ns = {"re": __import__("re"), "os": os}
        exec(src[start:end], ns)
        cls.fn = staticmethod(ns["ends_in_no_match_tool"])

    def test_failed_command_before_and_and_grep_is_not_excused(self):
        cmd = "python3 -c \"print('ASSERTION');raise SystemExit(1)\" && grep absent /tmp/empty"
        # the shell really returns 1 here without reaching grep
        rc = subprocess.run(["/bin/sh", "-c", cmd.replace("/tmp/empty", os.devnull)],
                            capture_output=True, text=True).returncode
        self.assertEqual(rc, 1)
        self.assertFalse(self.fn(cmd))

    def test_plain_grep_is_excused(self):
        self.assertTrue(self.fn("grep absent file"))

    def test_grep_after_semicolon_or_pipe_or_or_is_excused(self):
        self.assertTrue(self.fn("cd sub; grep absent file"))
        self.assertTrue(self.fn("cat file | grep absent"))
        self.assertTrue(self.fn("false || grep absent file"))

    def test_and_chain_inside_group_is_not_excused(self):
        self.assertFalse(self.fn("false && ( grep absent file )"))


class P5_82_UnboundShellPositionals(unittest.TestCase):
    """`sh -c '<script>' sh` supplies $0 only; $1 is not bound. Parsed as data, never run."""

    @classmethod
    def setUpClass(cls):
        sys.path.insert(0, HERE)
        cls.ur = load("unguarded_rm_p5v3", os.path.join(HERE, "unguarded_rm.py"))

    def reasons(self, cmd):
        return self.ur.verdict(cmd, cwd="/owned/work", home="/Users/fixture")

    def test_direct_unguarded_variable_refused(self):
        self.assertTrue(self.reasons('rm -f "$D/file"'))

    def test_only_argument_zero_does_not_bind_dollar_one(self):
        self.assertTrue(self.reasons("""sh -c 'rm -f "$1/file"' sh"""))

    def test_one_argument_does_not_bind_dollar_two(self):
        self.assertTrue(self.reasons("""sh -c 'rm -f "$2/file"' sh /owned"""))

    def test_supplied_positional_passes(self):
        self.assertEqual(self.reasons("""sh -c 'rm -f "$1/file"' sh /owned"""), [])

    def test_guarded_positional_passes(self):
        self.assertEqual(self.reasons("""sh -c 'rm -f "${1:?}/file"' sh"""), [])


class P5_83_SessionIdAssignment(Scratch):
    """`SID=<uuid>; rm .../$SID/scratchpad/x` names the same shared session as the literal path."""

    SID = "11111111-2222-3333-4444-555555555555"

    def setUp(self):
        super().setUp()
        sys.path.insert(0, HERE)
        self.sp = load("shared_scratchpad_p5v3", os.path.join(HERE, "shared_scratchpad.py"))
        self.root = os.path.realpath(os.path.join(self.tmp, "shared-root"))
        os.makedirs(os.path.join(self.root, "project", self.SID, "scratchpad"))
        self.cwd = os.path.realpath(os.path.join(self.tmp, "work"))
        os.makedirs(self.cwd)

    def refusal(self, cmd):
        return self.sp.verdict(cmd, cwd=self.cwd, roots=[self.root])

    def test_literal_session_path_refused(self):
        self.assertIsNotNone(self.refusal(
            "rm -f %s/project/%s/scratchpad/notes.txt" % (self.root, self.SID)))

    def test_assigned_session_id_refused(self):
        self.assertIsNotNone(self.refusal(
            "SID=%s; rm -f %s/project/$SID/scratchpad/notes.txt" % (self.SID, self.root)))

    def test_assigned_relative_dir_still_resolves_against_cwd(self):
        self.assertIsNone(self.refusal("D=sub; rm -rf $D"))


def transcript(tmp, rows):
    path = os.path.join(tmp, "t.jsonl")
    with open(path, "w") as fh:
        fh.write("".join(json.dumps(r) + "\n" for r in rows))
    return path


class P5_29_UnknownTranscriptType(Scratch):
    """A file whose only row has an unknown type is not a transcript, never a zero."""

    def setUp(self):
        super().setUp()
        self.qt = load("qa_throwaways_p5v3", os.path.join(HERE, "qa-throwaways.py"))

    def test_unknown_type_cannot_answer(self):
        with self.assertRaises(self.qt.CannotAnswer):
            self.qt.scan(transcript(self.tmp, [{"type": "garbage"}]))

    def test_real_assistant_row_is_a_transcript(self):
        events, rows = self.qt.scan(transcript(self.tmp, [
            {"type": "user", "message": {"content": "hi"}},
            {"type": "assistant", "message": {"content": []}}]))
        self.assertEqual((events, rows), ([], 2))


def bash_row(cmd):
    return {"type": "assistant", "message": {"content": [
        {"type": "tool_use", "name": "Bash", "input": {"command": cmd}}]}}


class P5_30_ShellWrittenScripts(Scratch):
    """Different shell-written contents at different paths are two scripts, not a copy."""

    def setUp(self):
        super().setUp()
        self.qt = load("qa_throwaways_p5v3b", os.path.join(HERE, "qa-throwaways.py"))

    def count(self, rows):
        events, _ = self.qt.scan(transcript(self.tmp, rows))
        scripts, _ = self.qt.classify(events)
        return scripts

    def test_two_printf_writes_of_different_content_are_two_scripts(self):
        scripts = self.count([bash_row("printf 'print(1)' > /one/analyze.py"),
                              bash_row("printf 'print(2)' > /two/analyze.py")])
        self.assertEqual(len(scripts), 2)

    def test_two_heredoc_writes_of_different_content_are_two_scripts(self):
        scripts = self.count([bash_row("cat > /one/analyze.py <<'EOF'\nprint(1)\nEOF"),
                              bash_row("cat > /two/analyze.py <<'EOF'\nprint(2)\nEOF")])
        self.assertEqual(len(scripts), 2)

    def test_transfer_from_a_decoder_is_still_a_copy(self):
        scripts = self.count([bash_row("cat > /one/analyze.py <<'EOF'\nprint(1)\nEOF"),
                              bash_row("echo cHJpbnQoMSkK | base64 -d > /guest/analyze.py")])
        self.assertEqual(len(scripts), 1)
        self.assertEqual(scripts[0]["copies"], ["/guest/analyze.py"])

    def test_rewrites_of_one_path_are_one_script(self):
        scripts = self.count([bash_row("printf 'a' > /s/send.sh"),
                              bash_row("printf 'b' > /s/send.sh"),
                              bash_row("printf 'c' > /s/send.sh")])
        self.assertEqual(len(scripts), 1)
        self.assertEqual(scripts[0]["events"], 3)


if __name__ == "__main__":
    unittest.main()
