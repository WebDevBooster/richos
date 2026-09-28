#!/usr/bin/env python3
"""Semantic config and hook changes, including real repository grammar."""
import json
import hashlib
import os
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
import verification_inputs as inputs


class Inputs(unittest.TestCase):
    def test_assignment_context_is_preserved_across_commit_index_and_worktree(self):
        with tempfile.TemporaryDirectory(prefix="config-versions.") as directory:
            root = Path(directory)
            env = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_SYSTEM": os.devnull,
                "GIT_AUTHOR_NAME": "fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
                "GIT_COMMITTER_NAME": "fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid"}
            def git(*args):
                return subprocess.check_output(["git", "-C", directory, *args], env=env, text=True).strip()
            git("init", "-q")
            file = root / "orchestration.config"
            file.write_text("A=base\nB=stable\n")
            git("add", ".")
            git("commit", "-q", "-m", "fixture")
            original = inputs.Snapshot(root, "HEAD")
            file.write_text("A=staged\nB=stable\n")
            git("add", ".")
            file.write_text("A=working\nB=stable\nNEW=working\n")
            staged = inputs.Snapshot(root, "INDEX")
            working = inputs.Snapshot(root, "WORKTREE")
            self.assertEqual(inputs.config_change(original.read(file.name), staged.read(file.name))["keys"], ["A"])
            self.assertEqual(inputs.config_change(staged.read(file.name), working.read(file.name))["keys"], ["A", "NEW"])
            file.unlink()
            self.assertIsNone(working.read(file.name))
            self.assertIsNotNone(staged.read(file.name))
            self.assertIsNone(original.read("not-present.config"))
            self.assertEqual(inputs.revisions(root, "HEAD...HEAD"), (git("rev-parse", "HEAD"), "HEAD"))
            with self.assertRaises(inputs.Unsupported):
                inputs.Snapshot(root, "missing-ref")

    def test_real_config_accepts_all_eight_environment_path_assignments(self):
        parsed = inputs.config((HERE.parent / "orchestration.config").read_text())
        expected = {"SCRATCH_CAMPAIGN_PARENT", "SCRATCH_NIGHTLY_DIR", "SCRATCH_FAILURES_STATE",
                    "SCRATCH_REAPER_STATE", "APP_INSTANCE_FAILURES_STATE", "TEST_DEVICE_FAILURES_STATE",
                    "DISK_CONSUMER_CANDIDATES", "DISK_STATE_JSON"}
        actual = {key for key, row in parsed.items() if any(part[0] == "parameter" for part in row["value"])}
        self.assertEqual(actual, expected)
        self.assertEqual(len(parsed), 103)
        self.assertIsNone(inputs.config_change("", (HERE.parent / "orchestration.config").read_text())["fallback"])

    def test_semantic_values_ignore_comments_spacing_and_equivalent_quotes(self):
        change = inputs.config_change("A=alpha\nB=\"literal # value\"\n",
                                      '  A="alpha"  # explanation\nB=\'literal # value\'\n\n# end\n')
        self.assertEqual(change["keys"], [])
        self.assertTrue(change["content"])  # Whole-content assertions still observe bytes.
        self.assertIsNone(change["fallback"])
        self.assertEqual(inputs.config_change('A=""\n', 'A= # empty\n')["keys"], [])

    def test_added_changed_deleted_and_transitively_referenced_keys(self):
        before = 'A=old\nB="$A/path"\nC="${B:-$HOME/default}"\nDELETE=yes\n'
        after = 'A=new\nB="$A/path"\nC="${B:-$HOME/default}"\nNEW=yes\n'
        self.assertEqual(inputs.config_change(before, after)["keys"], ["A", "B", "C", "DELETE", "NEW"])
        self.assertTrue(inputs.config_change(None, "A=one")["presence"])
        self.assertTrue(inputs.config_change("A=one", None)["presence"])

    def test_nested_defaults_and_environment_values_are_not_executed(self):
        text = 'A="${CLAUDE_CONFIG_DIR:-${HOME:-/Users/fallback}/.claude}/state"\n'
        self.assertIsNone(inputs.config_change(text, text.replace("/state", "/next"))["fallback"])
        self.assertEqual(inputs.config_change('A="$HOME"', 'A=${HOME}')["keys"], [])
        self.assertEqual(inputs.config_change('A=\\$HOME', "A='$HOME'")["keys"], [])

    def test_unsupported_execution_dynamic_expansion_duplicates_and_multiline_are_visible(self):
        cases = ['A=$(touch nowhere)', 'A=`touch nowhere`', 'A=$((1+1))', 'A="${HOME%/}"',
                 'A="$UNDECLARED"', 'A="first\nsecond"', 'A=one\nA=two', 'A=ok; exit 0',
                 'if true; then\nA=one\nfi', 'A =one', 'A= echo unsafe', 'export A=one',
                 'A="$A"', 'A="$B"\nB=late']
        for text in cases:
            with self.subTest(text=text):
                result = inputs.config_change('A=one\n', text)
                self.assertTrue(result["fallback"])
                self.assertEqual(result["keys"], [])
        with tempfile.TemporaryDirectory(prefix="config-no-exec.") as directory:
            marker = Path(directory) / "executed"
            result = inputs.config_change("A=one", f'A="$(touch {marker})"')
            self.assertTrue(result["fallback"])
            self.assertFalse(marker.exists())
            self.assertIsNone(inputs.config_change("A=one", f"A='$(touch {marker})'")["fallback"])
            self.assertFalse(marker.exists())

    def test_real_hooks_file_and_metadata_only_change(self):
        original = (HERE.parent / "hooks/hooks.json").read_text()
        self.assertIsNone(inputs.hooks_change(original, original)["fallback"])
        for row in inputs.hook_entries(original).values():
            inputs.hook_command_path(row['command'])
        changed = json.loads(original)
        first_event = next(iter(changed["hooks"]))
        first = changed["hooks"][first_event][0]
        first["matcher"] = "ChangedMatcher"
        difference = inputs.hooks_change(original, json.dumps(changed))
        self.assertTrue(difference["metadata"])
        self.assertIn(first["hooks"][0]["command"], difference["commands"])
        self.assertEqual(difference['events'], [first_event])

    def test_hook_removed_added_order_timeout_and_empty_group_changes(self):
        def document(names):
            return {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": name, "timeout": 10}]} for name in names]}}
        before = document(["one", "two"])
        after = document(["two", "three"])
        difference = inputs.hooks_change(json.dumps(before), json.dumps(after))
        self.assertEqual(difference["commands"], ["one", "three", "two"])
        after = document(["two", "one"])
        self.assertEqual(inputs.hooks_change(json.dumps(before), json.dumps(after))["commands"], ["one", "two"])
        before = document(["one"])
        after = document(["one"])
        after["hooks"]["Stop"][0]["hooks"][0]["timeout"] = 20
        self.assertEqual(inputs.hooks_change(json.dumps(before), json.dumps(after))["commands"], ["one"])
        after = document(["one"])
        after["hooks"]["Stop"].append({"hooks": []})
        self.assertTrue(inputs.hooks_change(json.dumps(before), json.dumps(after))["metadata"])
        after = {**before, "description": "only explanatory prose changed"}
        difference = inputs.hooks_change(json.dumps(before), json.dumps(after))
        self.assertFalse(difference["metadata"])
        self.assertEqual(difference["commands"], [])

    def test_unknown_hook_structure_has_explicit_fallback(self):
        for text in ('[]', '{"hooks": []}', '{"hooks":{"Stop": [{"hooks": [{"type": "prompt"}]}]}}',
                     '{"hooks":{"Stop":[{"future-matcher": 1, "hooks":[]}]}}',
                     '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"x","async":"yes"}]}]}}'):
            with self.subTest(text=text):
                self.assertTrue(inputs.hooks_change('{"hooks":{}}', text)["fallback"])

    def test_ambiguous_hook_json_cannot_hide_an_entry_or_metadata_change(self):
        valid = '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"one"}]}]}}'
        cases = [
            '{"hooks":{"Stop":[]},"hooks":{}}',
            '{"hooks":{"Stop":[],"Stop":[]}}',
            valid.replace('"hooks":[', '"matcher":"a","matcher":"b","hooks":['),
            valid.replace('"command":"one"', '"command":"two","command":"one"'),
        ]
        cases.extend(valid.replace('"command":"one"', '"command":"one","timeout":'+value)
                     for value in ('NaN', 'Infinity', '-Infinity', '1e999'))
        for text in cases:
            with self.subTest(text=text):
                self.assertTrue(inputs.hooks_change(valid, text)['fallback'])
                self.assertTrue(inputs.hooks_change(text, valid)['fallback'])


class Closure(unittest.TestCase):
    def test_inflight_durability_retains_real_workspace_cleanup_settings(self):
        document = json.loads((HERE / 'lib/verification-dependencies.json').read_text())
        graph = inputs.Dependencies(HERE.parent, document)
        unit = 'scripts/hooks/inflight-ack-durability.test.sh'
        closure = graph.closure(unit)
        expected = {'APP_TEST_INSTANCE_PROCESS_NAMES', 'APP_TEST_INSTANCE_BUNDLE_ID',
                    'APP_TEST_INSTANCE_REAL_HOME_PATHS', 'APP_TEST_INSTANCE_QUIT_GRACE_SECONDS',
                    'APP_TEST_INSTANCE_KILL_GRACE_SECONDS'}
        self.assertEqual(set(closure['keys']), expected)
        self.assertFalse(closure['whole'] or closure['presence'] or closure['fallback'], closure)
        for key in expected | {'INFLIGHT_ACK_TIMEOUT_MIN', 'PROTECTED_PATHS', 'SHOW_TURN_MANIFEST'}:
            change = inputs.config_change(key+'=old', key+'=new')
            self.assertEqual(bool(graph.config_units(change, [unit])), key in expected, key)
        unrelated = inputs.config_change('PROTECTED_PATHS=old', 'PROTECTED_PATHS=new')
        for helper in ('mega-lander/workspaces.py#discard', 'mega-lander/workspaces.sh#discard',
                       'scripts/lib/appinstances.py#workspace-cleanup',
                       'scripts/lib/testdevices.py#workspace-collection',
                       'scripts/lib/containers.py#workspace-cleanup'):
            with self.subTest(helper=helper):
                previous = document['nodes'].pop(helper)
                self.assertEqual(set(graph.config_units(unrelated, [unit])), {unit})
                document['nodes'][helper] = previous

    def test_inflight_notification_covers_stop_and_durable_ack_readers(self):
        document = json.loads((HERE / 'lib/verification-dependencies.json').read_text())
        graph = inputs.Dependencies(HERE.parent, document)
        unit = 'scripts/hooks/inflight-notify.test.sh'
        self.assertEqual(graph.closure(unit),
                         {'keys': {}, 'whole': [], 'presence': [], 'fallback': []})
        self.assertEqual(set(graph.closure('scripts/hooks/notice-inflight-acks.sh')['keys']),
                         {'INFLIGHT_ACK_TIMEOUT_MIN'})
        change = inputs.config_change('INFLIGHT_ACK_TIMEOUT_MIN=5', 'INFLIGHT_ACK_TIMEOUT_MIN=10')
        self.assertEqual(graph.config_units(change, [unit]), {})
        for helper in ('scripts/hooks/notice-inflight-acks.sh', 'scripts/inflight-ack.sh',
                       'scripts/lib/stop-hook-notice.sh', 'scripts/lib/inflight.py'):
            with self.subTest(helper=helper):
                previous = document['nodes'].pop(helper)
                self.assertEqual(set(graph.config_units(change, [unit])), {unit})
                document['nodes'][helper] = previous

    def test_inflight_two_leads_keeps_private_settings_and_transitive_bindings(self):
        document = json.loads((HERE / 'lib/verification-dependencies.json').read_text())
        graph = inputs.Dependencies(HERE.parent, document)
        unit = 'scripts/hooks/inflight-two-leads.test.sh'
        self.assertEqual(graph.closure(unit),
                         {'keys': {}, 'whole': [], 'presence': [], 'fallback': []})
        self.assertEqual(set(graph.closure('scripts/hooks/guard-inflight-notify.sh')['keys']),
                         {'INFLIGHT_ACK_TIMEOUT_MIN'})
        change = inputs.config_change('INFLIGHT_ACK_TIMEOUT_MIN=5', 'INFLIGHT_ACK_TIMEOUT_MIN=10')
        self.assertEqual(graph.config_units(change, [unit]), {})
        self.assertEqual(graph.config_units(inputs.config_change(None, 'PROTECTED_PATHS=src'), [unit]), {})
        for helper in ('scripts/lib/inflight.py', 'scripts/lib/inflight.sh',
                       'scripts/hooks/guard-inflight-notify.sh',
                       'scripts/hooks/notice-inflight-sends.sh', 'scripts/inflight-notify.sh',
                       'scripts/lib/teammate-identity.py', 'mega-lander/workspaces.py#integration'):
            with self.subTest(helper=helper):
                previous = document['nodes'][helper]['sha256']
                document['nodes'][helper]['sha256'] = 'changed'
                self.assertEqual(set(graph.config_units(change, [unit])), {unit})
                document['nodes'][helper]['sha256'] = previous

    def test_staging_and_worktree_detectors_replace_entity_settings(self):
        document = json.loads((HERE / 'lib/verification-dependencies.json').read_text())
        graph = inputs.Dependencies(HERE.parent, document)
        units = ['scripts/hooks/stale-staging.test.sh',
                 'scripts/hooks/detect-nonnative-worktree.test.sh']
        for unit in units:
            closure = graph.closure(unit)
            self.assertEqual(closure['keys'], {}, closure)
            self.assertEqual(closure['whole'], [], closure)
            self.assertEqual(closure['fallback'], [], closure)
        for key in ('STAGING_TREES', 'STAGING_DEPLOY_RECORD', 'READONLY_ALLOWLIST', 'SESSION_TEAMS_DIR'):
            self.assertEqual(graph.config_units(inputs.config_change(key + '=a', key + '=b'), units), {})
        self.assertEqual(set(graph.config_units(inputs.config_change(None, 'STAGING_TREES=a'), units)), {units[0]})
        for helper, unit in (('scripts/hooks/stale-staging.mutation.sh', units[0]),
                             ('scripts/staging-record.sh', units[0]),
                             ('scripts/hooks/detect-nonnative-worktree.sh', units[1])):
            original = document['nodes'].pop(helper)
            self.assertTrue(graph.closure(unit)['fallback'])
            document['nodes'][helper] = original

    def test_python_wrappers_follow_their_actual_imports(self):
        document = json.loads((HERE / 'lib/verification-dependencies.json').read_text())
        graph = inputs.Dependencies(HERE.parent, document)
        for stem in ('durable-filesystem-identity', 'spawn-guard-audience'):
            base = 'scripts/lib/' + stem
            unit = base + '.test.sh'
            with self.subTest(unit=unit):
                self.assertEqual(graph.closure(unit),
                                 {'keys': {}, 'whole': [], 'presence': [], 'fallback': []})
                for suffix in ('.test.py', '.py'):
                    original = document['nodes'][base + suffix]['sha256']
                    document['nodes'][base + suffix]['sha256'] = 'changed'
                    self.assertTrue(graph.closure(unit)['fallback'])
                    document['nodes'][base + suffix]['sha256'] = original

    def test_todo_records_and_cold_readers_are_fixtures_but_adoption_still_matters(self):
        document = json.loads((HERE / 'lib/verification-dependencies.json').read_text())
        graph = inputs.Dependencies(HERE.parent, document)
        units = ['scripts/cold-open.test.sh', 'scripts/hooks/ceo-todos.test.sh']
        for unit in units:
            closure = graph.closure(unit)
            self.assertEqual(closure['keys'], {}, closure)
            self.assertEqual(closure['whole'], [], closure)
            self.assertEqual(closure['fallback'], [], closure)
        change = inputs.config_change('SCRATCH_DEFAULT_TTL_MINUTES=360', 'SCRATCH_DEFAULT_TTL_MINUTES=300')
        self.assertEqual(graph.config_units(change, units), {})
        self.assertEqual(set(graph.config_units(inputs.config_change(None, 'PROTECTED_PATHS=src'), units)),
                         {units[1]})
        for helper, affected in (
                ('scripts/lib/ceo-todos.py#fixture-records', units),
                ('scripts/cold-open.sh#fixture-reader', units),
                ('scripts/hooks/ceo-todos.mutation.sh', units[1:]),
                ('scripts/ceo-todos-init.sh#no-cold-open', units[1:])):
            with self.subTest(helper=helper):
                original = document['nodes'][helper]['sha256']
                document['nodes'][helper]['sha256'] = 'changed'
                self.assertEqual(set(graph.config_units(change, units)), set(affected))
                document['nodes'][helper]['sha256'] = original

    def test_worktree_removal_reads_private_adoption_and_registry_only(self):
        document = json.loads((HERE / 'lib/verification-dependencies.json').read_text())
        graph = inputs.Dependencies(HERE.parent, document)
        unit = 'scripts/hooks/guard-worktree-removal.test.sh'
        self.assertEqual(graph.closure(unit),
                         {'keys': {}, 'whole': [], 'presence': [], 'fallback': []})
        change = inputs.config_change('PROTECTED_PATHS=old', 'PROTECTED_PATHS=new')
        self.assertEqual(graph.config_units(change, [unit]), {})
        for helper in ('mega-lander/workspaces.py#integration',
                       'scripts/hooks/guard-worktree-removal.sh'):
            with self.subTest(helper=helper):
                original = document['nodes'].pop(helper)
                self.assertEqual(set(graph.config_units(change, [unit])), {unit})
                document['nodes'][helper] = original

    def test_artifact_and_manifest_fixtures_do_not_consume_production_settings(self):
        document = json.loads((HERE / 'lib/verification-dependencies.json').read_text())
        graph = inputs.Dependencies(HERE.parent, document)
        units = ['scripts/collect-worktree-artifacts.test.sh',
                 'scripts/hooks/turn-manifest.test.sh']
        for unit in units:
            self.assertEqual(graph.closure(unit),
                             {'keys': {}, 'whole': [], 'presence': [], 'fallback': []})
        for key in ('ARTIFACT_MERGE_DIRS', 'ARTIFACT_REPLACE_DIRS', 'SHOW_TURN_MANIFEST'):
            change = inputs.config_change(key+'=old', key+'=new')
            self.assertEqual(graph.config_units(change, units), {})
        self.assertEqual(graph.config_units(inputs.config_change(None, 'SHOW_TURN_MANIFEST=1'), units), {})
        self.assertEqual(set(graph.closure('scripts/collect-worktree-artifacts.sh')['keys']),
                         {'ARTIFACT_MERGE_DIRS', 'ARTIFACT_REPLACE_DIRS'})
        self.assertEqual(set(graph.closure('scripts/hooks/turn-manifest.sh')['keys']),
                         {'SHOW_TURN_MANIFEST'})
        # Fixture replacement may remove value dependencies, never uncertainty
        # about a helper or the constructor used by the nested mutation run.
        for helper, affected in (
                ('scripts/lib/resolve-roots.sh#roots', units),
                ('scripts/hooks/turn-manifest.py', units[1:]),
                ('scripts/hooks/turn-manifest.mutation.sh', units[1:]),
                ('scripts/collect-worktree-artifacts.sh', units[:1])):
            with self.subTest(helper=helper):
                old = document['nodes'][helper]['sha256']
                document['nodes'][helper]['sha256'] = 'changed'
                self.assertEqual(set(graph.config_units(change, units)), set(affected))
                document['nodes'][helper]['sha256'] = old

    def test_unlanded_fixture_copy_and_mutants_preserve_entity_config_origin(self):
        document = json.loads((HERE / 'lib/verification-dependencies.json').read_text())
        graph = inputs.Dependencies(HERE.parent, document)
        unit = 'scripts/hooks/unlanded-branches.test.sh'
        closure = graph.closure(unit)
        self.assertEqual(closure['keys'], {}, closure)
        self.assertEqual(closure['whole'], [], closure)
        self.assertEqual(closure['fallback'], [], closure)
        change = inputs.config_change('CHECK_UNLANDED_BRANCHES=1', 'CHECK_UNLANDED_BRANCHES=0')
        self.assertEqual(graph.config_units(change, [unit]), {})
        document['nodes'].pop('scripts/lib/unlanded-branches.py')
        self.assertEqual(set(graph.config_units(change, [unit])), {unit})

    def test_claim_and_ci_gates_reach_only_fixture_settings(self):
        document = json.loads((HERE / 'lib/verification-dependencies.json').read_text())
        graph = inputs.Dependencies(HERE.parent, document)
        units = ['scripts/hooks/guard-unresolved-claims.test.sh',
                 'scripts/hooks/guard-ci-turn-gate.test.sh']
        for unit in units:
            closure = graph.closure(unit)
            self.assertEqual(closure['keys'], {}, closure)
            self.assertEqual(closure['whole'], [], closure)
            self.assertEqual(closure['fallback'], [], closure)
        for key in ('CHECK_UNRESOLVED_CLAIMS', 'UNLANDED_BRANCHES_EXTRA_REPOS', 'PROTECTED_PATHS'):
            change = inputs.config_change(key+'=old', key+'=new')
            self.assertEqual(graph.config_units(change, units), {})
        document['nodes'].pop('mega-lander/workspaces.py#integration')
        self.assertEqual(set(graph.config_units(change, units)), {units[0]})

    def test_scratch_fixture_config_reaches_imported_readers_and_mutations(self):
        document = json.loads((HERE / 'lib/verification-dependencies.json').read_text())
        graph = inputs.Dependencies(HERE.parent, document)
        units = ['scripts/hooks/session-start-scratch.test.sh',
                 'scripts/lib/mutation-harness-guards.test.sh', 'scripts/scratch-reaper.test.sh']
        for unit in units:
            closure = graph.closure(unit)
            self.assertEqual(closure['keys'], {}, closure)
            self.assertEqual(closure['whole'], [], closure)
            self.assertEqual(closure['fallback'], [], closure)
        reaper = graph.closure('scripts/scratch-reaper.sh')
        for key in ('SCRATCH_REAPER_ENABLE', 'SCRATCH_SYSTEM_FLAGS',
                    'APP_TEST_INSTANCE_PROCESS_NAMES', 'SCRATCH_ROOT_NAME'):
            self.assertIn(key, reaper['keys'])
            self.assertEqual(graph.config_units(inputs.config_change(key+'=old', key+'=new'), units), {})
        document['nodes'].pop('scripts/lib/appinstances.py')
        change = inputs.config_change('BAN_WORKFLOW_TOOL=1', 'BAN_WORKFLOW_TOOL=0')
        self.assertEqual(set(graph.config_units(change, units)), set(units))

    def test_root_and_banner_fixtures_do_not_read_shipped_setting_values(self):
        document = json.loads((HERE / 'lib/verification-dependencies.json').read_text())
        graph = inputs.Dependencies(HERE.parent, document)
        units = ['scripts/hooks/engine-status.test.sh', 'scripts/lib/resolve-roots.test.sh']
        for unit in units:
            closure = graph.closure(unit)
            self.assertEqual(closure['keys'], {}, closure)
            self.assertEqual(closure['whole'], [], closure)
            self.assertEqual(closure['fallback'], [], closure)
        for key in ('PROTECTED_PATHS', 'AGENT_NAMESPACE_ROOTS', 'BAN_WORKFLOW_TOOL'):
            self.assertEqual(graph.config_units(inputs.config_change(key+'=old', key+'=new'), units), {})
        document['nodes'].pop('scripts/lib/registered-hooks.sh')
        change = inputs.config_change('PROTECTED_PATHS=before', 'PROTECTED_PATHS=after')
        self.assertEqual(set(graph.config_units(change, units)), {units[0]})

    def test_staleness_and_record_guards_keep_copies_distinct_from_real_readers(self):
        document = json.loads((HERE / 'lib/verification-dependencies.json').read_text())
        graph = inputs.Dependencies(HERE.parent, document)
        units = ['scripts/hooks/hook-staleness.test.sh', 'scripts/hooks/guard-public-record-repo.test.sh']
        for unit in units:
            closure = graph.closure(unit)
            self.assertEqual(closure['keys'], {}, closure)
            self.assertEqual(closure['whole'], [], closure)
            self.assertEqual(closure['fallback'], [], closure)
        self.assertEqual(set(graph.closure('scripts/hooks/guard-public-record-repo.sh')['keys']),
                         {'PUBLIC_RECORD_REPO_GUARD', 'PUBLICATION_DECLARATION'})
        for key in ('PUBLIC_RECORD_REPO_GUARD', 'PUBLICATION_DECLARATION', 'PROTECTED_PATHS'):
            change = inputs.config_change(key+'=before', key+'=after')
            self.assertEqual(graph.config_units(change, units), {})
        document['nodes'].pop('scripts/lib/git-jurisdiction.sh')
        self.assertEqual(set(graph.config_units(change, units)), {units[1]})

    def test_claims_and_premise_fixtures_replace_real_settings_through_helpers(self):
        document = json.loads((HERE / 'lib/verification-dependencies.json').read_text())
        graph = inputs.Dependencies(HERE.parent, document)
        units = ['scripts/hooks/agent-state-claims.test.sh', 'scripts/hooks/premise-ask.test.sh']
        for unit in units:
            closure = graph.closure(unit)
            self.assertEqual(closure['keys'], {}, closure)
            self.assertEqual(closure['whole'], [], closure)
            self.assertEqual(closure['fallback'], [], closure)
        self.assertEqual(set(graph.closure('scripts/hooks/guard-agent-state-claims.sh')['keys']),
                         {'CHECK_AGENT_STATE_CLAIMS'})
        for key in ('CHECK_AGENT_STATE_CLAIMS', 'CEO_RULINGS_PATHS', 'PROTECTED_PATHS'):
            change = inputs.config_change(key+'=before', key+'=after')
            self.assertEqual(graph.config_units(change, units), {})
        document['nodes'].pop('scripts/lib/stop-session-recovery.py')
        self.assertEqual(set(graph.config_units(change, units)), {units[0]})

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="dependency-closure.")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.map = {"schema": 1, "config_keys": ["A", "B", "PLANTED"], "nodes": {}, "units": {}}

    def test_scanner_transport_retains_keys_and_deferral_fixture_replaces_them(self):
        document = json.loads((HERE / 'lib/verification-dependencies.json').read_text())
        graph = inputs.Dependencies(HERE.parent, document)
        scan, deferral = 'scripts/hooks/scan-secrets.test.sh', 'scripts/hooks/unasked-deferral.test.sh'
        keys = {'SECRET_SCAN_MIN_LENGTH', 'SECRET_SCAN_MIN_ENTROPY',
                'SECRET_SCAN_ALLOWLIST', 'SECRET_SCAN_CODE_AWARE'}
        self.assertEqual(set(graph.closure(scan)['keys']), keys)
        self.assertEqual(graph.closure(deferral)['keys'], {})
        for unit in (scan, deferral):
            self.assertEqual(graph.closure(unit)['whole'], [])
            self.assertEqual(graph.closure(unit)['fallback'], [])
        for key in keys:
            change = inputs.config_change(key+'=before', key+'=after')
            self.assertEqual(set(graph.config_units(change, [scan, deferral])), {scan})
        change = inputs.config_change('PROTECTED_PATHS=app', 'PROTECTED_PATHS=engine')
        self.assertEqual(graph.config_units(change, [scan, deferral]), {})
        document['nodes'].pop('scripts/hooks/guard-unasked-deferral.py')
        self.assertEqual(set(graph.config_units(change, [scan, deferral])), {deferral})

    def test_notice_and_stop_predicate_closures_are_independent_of_config_values(self):
        document = json.loads((HERE / 'lib/verification-dependencies.json').read_text())
        graph = inputs.Dependencies(HERE.parent, document)
        units = ['scripts/hooks/guard-stop-live-work.test.sh',
                 'scripts/hooks/unevaluated-notice.test.sh',
                 'scripts/hooks/session-start-ci-surface.test.sh']
        for unit in units:
            closure = graph.closure(unit)
            self.assertEqual(closure['keys'], {}, closure)
            self.assertEqual(closure['whole'], [], closure)
            self.assertEqual(closure['fallback'], [], closure)
        change = inputs.config_change('BAN_WORKFLOW_TOOL=1', 'BAN_WORKFLOW_TOOL=0')
        self.assertEqual(graph.config_units(change, units), {})
        document['nodes'].pop('mega-lander/workspaces.py#liveness-readers')
        self.assertEqual(set(graph.config_units(change, units)), {units[0]})

    def test_serial_runner_fixtures_and_ci_discovery_do_not_read_config_values(self):
        document = json.loads((HERE / 'lib/verification-dependencies.json').read_text())
        graph = inputs.Dependencies(HERE.parent, document)
        units = ['scripts/run-all-tests.test.sh', 'scripts/ci-surface-watch.test.sh',
                 'scripts/lib/ci-surface.test.sh']
        for unit in units:
            closure = graph.closure(unit)
            self.assertEqual(closure['keys'], {}, closure)
            self.assertEqual(closure['whole'], [], closure)
            self.assertEqual(closure['fallback'], [], closure)
        for key in ('PROTECTED_PATHS', 'BAN_WORKFLOW_TOOL', 'SESSION_TEAMS_DIR'):
            self.assertEqual(graph.config_units(inputs.config_change(key+'=before', key+'=after'), units), {})
        document['nodes'].pop('scripts/lib/ci_pause.py')
        change = inputs.config_change('BAN_WORKFLOW_TOOL=1', 'BAN_WORKFLOW_TOOL=0')
        self.assertEqual(set(graph.config_units(change, units)), set(units[1:]))

    def test_dialect_copy_preserves_readers_and_ledger_copy_uses_fixture_values(self):
        document = json.loads((HERE / 'lib/verification-dependencies.json').read_text())
        graph = inputs.Dependencies(HERE.parent, document)
        dialect = 'scripts/hooks/guard-dialect.test.sh'
        ledger = 'scripts/hooks/guard-reference-ledger.test.sh'
        expected = {'DIALECT_TARGET', 'DIALECT_SCAN_ALLOWLIST', 'DIALECT_EXEMPT_PATHS',
                    'VENDORING_DECLARATION'}
        self.assertEqual(set(graph.closure(dialect)['keys']), expected)
        self.assertEqual(graph.closure(ledger)['keys'], {})
        for unit in (dialect, ledger):
            self.assertEqual(graph.closure(unit)['fallback'], [])
            self.assertEqual(graph.closure(unit)['whole'], [])
        for key in expected:
            change = inputs.config_change(key+'=before', key+'=after')
            self.assertEqual(set(graph.config_units(change, [dialect, ledger])), {dialect})
        change = inputs.config_change('BAN_WORKFLOW_TOOL=1', 'BAN_WORKFLOW_TOOL=0')
        self.assertEqual(graph.config_units(change, [dialect, ledger]), {})
        document['nodes'].pop('scripts/lib/vendored-material.sh')
        self.assertEqual(set(graph.config_units(change, [dialect, ledger])), {dialect})

    def test_source_linters_keep_generated_config_and_scanned_commands_as_data(self):
        document = json.loads((HERE / 'lib/verification-dependencies.json').read_text())
        graph = inputs.Dependencies(HERE.parent, document)
        units = ['scripts/scratch-allocation-lint.test.sh', 'scripts/entrypoint-currency-lint.test.sh']
        for unit in units:
            self.assertEqual(graph.closure(unit), {'keys': {}, 'whole': [], 'presence': [], 'fallback': []})
        for key in ('ENTRYPOINTS', 'INSTRUCTION_SURFACES', 'BAN_WORKFLOW_TOOL'):
            self.assertEqual(graph.config_units(inputs.config_change(key+'=old', key+'=new'), units), {})
        document['nodes'].pop('scripts/hooks/contract-integrity-layer-ep.sh')
        selected = graph.config_units(inputs.config_change('ENTRYPOINTS=old', 'ENTRYPOINTS=new'), units)
        self.assertEqual(set(selected), {units[1]})

    def test_harness_controls_and_locator_do_not_consume_copied_config_values(self):
        document = json.loads((HERE / 'lib/verification-dependencies.json').read_text())
        graph = inputs.Dependencies(HERE.parent, document)
        units = ['scripts/lib/mutation-focus.test.sh', 'scripts/lib/mutation-harness.test.sh',
                 'scripts/locate-engine.test.sh']
        for unit in units:
            closure = graph.closure(unit)
            self.assertEqual(closure['keys'], {})
            self.assertEqual(closure['whole'], [])
            self.assertEqual(closure['fallback'], [])
        self.assertTrue(graph.closure(units[1])['presence'])
        change = inputs.config_change('PROTECTED_PATHS=before', 'PROTECTED_PATHS=after')
        self.assertEqual(graph.config_units(change, units), {})
        document['nodes'].pop('scripts/lib/mutation-harness.sh')
        self.assertEqual(set(graph.config_units(change, units)), set(units[:2]))

    def test_definition_and_seat_fixtures_do_not_read_real_config_values(self):
        document = json.loads((HERE / 'lib/verification-dependencies.json').read_text())
        graph = inputs.Dependencies(HERE.parent, document)
        units = ['scripts/hooks/guard-definition-drift.test.sh', 'scripts/lib/seat-jurisdiction.test.sh']
        for unit in units:
            closure = graph.closure(unit)
            self.assertEqual(closure['fallback'], [], unit)
            self.assertEqual(closure['keys'], {}, unit)
            self.assertEqual(closure['whole'], [], unit)
        before = (HERE.parent / 'orchestration.config').read_text()
        change = inputs.config_change(before, before + '\nPLANTED_UNUSED_SETTING=1\n')
        self.assertEqual(graph.config_units(change, units), {})
        source = 'scripts/hooks/snapshot-agent-definitions.sh'
        def changed(path):
            value = (HERE.parent / path).read_text()
            return value + '\n: "$NEW_READ"\n' if path == source else value
        stale = inputs.Dependencies(HERE.parent, document, read=changed)
        self.assertEqual(set(stale.config_units(change, units)), {units[0]})

    def test_hook_dependency_scanner_parses_source_without_consuming_config_values(self):
        document = json.loads((HERE / 'lib/verification-dependencies.json').read_text())
        graph = inputs.Dependencies(HERE.parent, document)
        unit = 'scripts/lib/hook-dependencies.test.sh'
        closure = graph.closure(unit)
        self.assertEqual(closure['fallback'], [])
        self.assertEqual(closure['keys'], {})
        self.assertEqual(closure['whole'], [])
        before = (HERE.parent / 'orchestration.config').read_text()
        self.assertEqual(graph.config_units(inputs.config_change(before, before + '\nPLANTED_UNUSED_SETTING=1'), [unit]), {})
        document['nodes'].pop('scripts/lib/hook-dependencies.py')
        self.assertTrue(inputs.Dependencies(HERE.parent, document).closure(unit)['fallback'])

    def test_global_witness_and_private_installer_have_no_real_config_dependency(self):
        document = json.loads((HERE / 'lib/verification-dependencies.json').read_text())
        graph = inputs.Dependencies(HERE.parent, document)
        unit = 'scripts/lib/global-state-witness.test.sh'
        closure = graph.closure(unit)
        self.assertEqual(closure['fallback'], [])
        self.assertEqual(closure['keys'], {})
        self.assertEqual(closure['whole'], [])
        before = (HERE.parent / 'orchestration.config').read_text()
        self.assertEqual(graph.config_units(inputs.config_change(before, before + '\nPLANTED_UNUSED_SETTING=1'), [unit]), {})
        document['nodes'].pop('scripts/hooks/install.sh#private-home')
        self.assertTrue(inputs.Dependencies(HERE.parent, document).closure(unit)['fallback'])

    def node(self, name, content, **contract):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        row = {"source": name, "sha256": hashlib.sha256(content.encode()).hexdigest(),
               "evidence": "controlled fixture read/call relationship", "keys": [], "edges": [], **contract}
        self.map["nodes"][name] = row
        return row

    def selected(self, before, after, units):
        return inputs.Dependencies(self.root, self.map).config_units(inputs.config_change(before, after), units)

    def test_direct_nested_subprocess_and_both_named_copy_helpers(self):
        self.node("reader.sh", 'printf "%s" "$A"\n', keys=["A"])
        self.node("nested.sh", "bash reader.sh\n", edges=[{"to": "reader.sh"}])
        copies = ["direct-copy.sh", "lib/mutation-harness.sh", "hooks/contract-integrity-probe.sh"]
        for helper in copies:
            self.node(helper, 'cp orchestration.config fixture/orchestration.config\nbash nested.sh\n',
                presence="transport needs source file", edges=[{"to": "nested.sh"}])
        self.node("unrelated.sh", 'printf "%s" "$B"\n', keys=["B"])
        selected = self.selected("A=1\nB=1", "A=2\nB=1", [*copies, "unrelated.sh"])
        self.assertEqual(set(selected), set(copies))
        for reasons in selected.values():
            self.assertTrue(any("nested.sh -> reader.sh" in reason for reason in reasons))
        self.assertEqual(set(self.selected("A=1\nB=1", "A=1\nB=2", [*copies, "unrelated.sh"])), {"unrelated.sh"})

    def test_copy_overrides_whole_content_presence_and_full_fixture_replacement(self):
        self.node("reader.sh", 'printf "%s" "$A $B"\n', keys=["A", "B"])
        self.node("override.sh", "copy_then_override\n", edges=[{"to": "reader.sh", "overrides": ["A"]}])
        self.node("private.sh", "new_fixture_config\n", edges=[{"to": "reader.sh", "fixture": True}])
        self.node("bytes.sh", "sha256sum orchestration.config\n", whole="hashes every byte")
        self.node("adopt.sh", "test -f orchestration.config\n", presence="checks adoption")
        units = ["override.sh", "private.sh", "bytes.sh", "adopt.sh"]
        self.assertEqual(set(self.selected("A=1\nB=1", "A=2\nB=1", units)), {"bytes.sh"})
        self.assertEqual(set(self.selected("A=1\nB=1", "A=1\nB=2", units)), {"override.sh", "bytes.sh"})
        self.assertEqual(set(self.selected("A=1\nB=1", "A=1\nB=1\n# comment", units)), {"bytes.sh"})
        self.assertIn("adopt.sh", self.selected(None, "A=1\nB=1", units))

    def test_new_helper_and_key_selects_only_its_consumer_even_before_qualification(self):
        self.node("consumer.sh", "bash new-helper.sh\n", edges=[{"to": "new-helper.sh"}])
        self.node("unrelated.sh", 'printf "%s" "$B"\n', keys=["B"])
        self.node("global.sh", "validate all config\n", whole="global config validation")
        units = ["consumer.sh", "unrelated.sh", "global.sh"]
        before, after = "A=1\nB=1", "A=1\nB=1\nPLANTED=1"
        selected = self.selected(before, after, units)
        self.assertEqual(set(selected), {"consumer.sh", "global.sh"})
        self.assertIn("unqualified reader new-helper.sh", " ".join(selected["consumer.sh"]))
        self.node("new-helper.sh", 'printf "%s" "$PLANTED"\n', keys=["PLANTED"])
        selected = self.selected(before, after, units)
        self.assertEqual(set(selected), {"consumer.sh", "global.sh"})
        self.assertNotIn("unresolved", " ".join(selected["consumer.sh"]))
        self.assertEqual(set(self.selected(after, after + "\nUNUSED=1\n", units)), {"global.sh"})

    def test_known_omission_modified_helper_and_unbounded_eval_fail_closed(self):
        self.node("omitted.sh", 'printf "%s" "$A"\n')
        self.node("changed.sh", 'printf "%s" "$A"\n', keys=["A"])
        (self.root / "changed.sh").write_text('printf "%s" "$A $B"\n')
        self.node("dynamic.sh", 'eval "printf %s \\${$UNKNOWN}"\n')
        self.node("unrelated.sh", "true\n")
        units = ["omitted.sh", "changed.sh", "dynamic.sh", "unrelated.sh"]
        selected = self.selected("A=1\nB=1", "A=1\nB=2", units)
        self.assertEqual(set(selected), set(units) - {"unrelated.sh"})
        self.assertIn("omitted known key", " ".join(selected["omitted.sh"]))
        self.assertIn("changed reader", " ".join(selected["changed.sh"]))
        self.assertIn("dynamic evaluation", " ".join(selected["dynamic.sh"]))

    def test_finite_indirect_alias_is_bound_to_helper_content(self):
        row = self.node("indirect.sh", 'CONFIG_KEY="A"\neval "printf %s \\${$CONFIG_KEY}"\n',
                        keys=["A"], indirect={"CONFIG_KEY": "A"})
        self.assertEqual(set(self.selected("A=1\nB=1", "A=2\nB=1", ["indirect.sh"])), {"indirect.sh"})
        self.assertFalse(self.selected("A=1\nB=1", "A=1\nB=2", ["indirect.sh"]))
        row["indirect"] = {"CONFIG_KEY": "B"}
        self.assertIn("indirect.sh", self.selected("A=1\nB=1", "A=1\nB=2", ["indirect.sh"]))

    def test_unsupported_config_syntax_selects_sourcing_readers_with_reason(self):
        self.node("reader.sh", 'printf "%s" "$A"\n', keys=["A"])
        self.node("unrelated.sh", "true\n")
        selected = self.selected("A=1", "A=$(command)", ["reader.sh", "unrelated.sh"])
        self.assertEqual(set(selected), {"reader.sh"})
        self.assertIn("config syntax fallback", " ".join(selected["reader.sh"]))

    def test_real_finite_aliases_and_copy_regions_match_reviewed_sources(self):
        document = json.loads((HERE / "lib/verification-dependencies.json").read_text())
        graph = inputs.Dependencies(HERE.parent, document)
        asks = graph.closure("scripts/lib/ceo-asks.sh")
        ruled = graph.closure("scripts/lib/ceo-ruled.sh")
        self.assertEqual(set(asks["keys"]), {"CEO_TODOS_REPOS"})
        self.assertEqual(set(ruled["keys"]), {"CEO_RULINGS_PATHS", "CEO_TODOS_REPOS"})
        self.assertFalse(asks["fallback"] + ruled["fallback"])
        for name in ("scripts/lib/mutation-harness.sh#copy", "scripts/hooks/contract-integrity-probe.sh#workspace-copy"):
            closure = graph.closure(name)
            self.assertEqual(closure["keys"], {})
            self.assertEqual(closure["whole"], [])
            self.assertTrue(closure["presence"])
            self.assertEqual(closure["fallback"], [])

    def test_real_direct_and_transitive_key_readers_in_reviewed_subset(self):
        document = json.loads((HERE / "lib/verification-dependencies.json").read_text())
        graph = inputs.Dependencies(HERE.parent, document)
        guards = {"scripts/hooks/guard-main-checkout-writes.test.sh",
                  "scripts/hooks/guard-bash-main-writes.test.sh"}
        units = sorted(guards | {"scripts/check-census.test.sh", "scripts/hooks/ceo-asks.test.sh"})
        for unit in units:
            self.assertEqual(graph.closure(unit)["fallback"], [], unit)
        for key, expected in (("PROTECTED_PATHS", guards),
                              ("BAN_WORKFLOW_TOOL", {"scripts/check-census.test.sh"})):
            change = inputs.config_change(key + "=before\n", key + "=after\n")
            self.assertEqual(set(graph.config_units(change, units)), expected)
        # Removing a real subprocess edge must not hide the indirect read.
        document["nodes"]["scripts/check-census.test.sh"]["edges"] = [
            edge for edge in document["nodes"]["scripts/check-census.test.sh"]["edges"]
            if edge["to"] != "scripts/hooks/guard-workflow-ban.sh"]
        closure = graph.closure("scripts/check-census.test.sh")
        self.assertIn("omitted known execute edges", " ".join(closure["fallback"]))

    def test_real_private_config_remains_independent_through_nested_mutants(self):
        document = json.loads((HERE / "lib/verification-dependencies.json").read_text())
        graph = inputs.Dependencies(HERE.parent, document)
        unit = "scripts/hooks/ceo-asks.test.sh"
        closure = graph.closure(unit)
        self.assertEqual(closure, {"keys": {}, "whole": [], "presence": [], "fallback": []})
        self.assertFalse(graph.config_units(inputs.config_change("CEO_TODOS_REPOS=a", "CEO_TODOS_REPOS=b"), [unit]))
        # A broken nested helper qualification still blocks exclusion. Private
        # fixture replacement cannot erase uncertainty about executed code.
        document["nodes"]["scripts/lib/ceo-todos.py#items"]["sha256"] = "unreviewed"
        self.assertIn(unit, graph.config_units(inputs.config_change("A=1", "A=2"), [unit]))

    def test_model_ceiling_mutants_transport_config_without_consuming_its_values(self):
        document = json.loads((HERE / 'lib/verification-dependencies.json').read_text())
        graph = inputs.Dependencies(HERE.parent, document)
        unit = 'scripts/hooks/guard-model-ceiling.test.sh'
        closure = graph.closure(unit)
        self.assertFalse(closure['keys'] or closure['whole'] or closure['fallback'], closure)
        self.assertTrue(closure['presence'])
        for key in ('MODEL_CEILING', 'MODEL_TIERS', 'PROTECTED_PATHS', 'SCRATCH_DEFAULT_TTL_MINUTES'):
            self.assertFalse(graph.config_units(inputs.config_change(key+'=one', key+'=two'), [unit]), key)
        self.assertIn(unit, graph.config_units(inputs.config_change(None, 'MODEL_CEILING=one'), [unit]))
        document['nodes']['scripts/lib/resolve-model.sh']['sha256'] = 'changed'
        self.assertIn(unit, graph.config_units(inputs.config_change('MODEL_CEILING=one', 'MODEL_CEILING=two'), [unit]))

    def test_ingress_gates_use_only_private_entity_settings(self):
        document = json.loads((HERE / 'lib/verification-dependencies.json').read_text())
        graph = inputs.Dependencies(HERE.parent, document)
        unit = 'scripts/hooks/ceo-inputs.test.sh'
        self.assertEqual(graph.closure(unit), {'keys': {}, 'whole': [], 'presence': [], 'fallback': []})
        document['nodes']['scripts/hooks/scan-secrets.sh']['sha256'] = 'changed'
        self.assertIn(unit, graph.config_units(inputs.config_change('SECRET_SCAN_ALLOWLIST=a', 'SECRET_SCAN_ALLOWLIST=b'), [unit]))

    def test_literal_mutation_operands_are_content_bound_and_need_an_explanation(self):
        row = self.node('mutation.sh', "printf '%s' '$A'\n", literal_keys={'A':'single-quoted source replacement operand'})
        self.assertFalse(self.selected('A=old', 'A=new', ['mutation.sh']))
        row['literal_keys'] = {'A': ''}
        selected = self.selected('A=old', 'A=new', ['mutation.sh'])
        self.assertIn('require evidence', ' '.join(selected['mutation.sh']))

    def test_ruling_gate_and_drift_mutants_use_private_config_values(self):
        document = json.loads((HERE / 'lib/verification-dependencies.json').read_text())
        graph = inputs.Dependencies(HERE.parent, document)
        unit = 'scripts/hooks/ceo-ruled.test.sh'
        self.assertEqual(graph.closure(unit), {'keys': {}, 'whole': [], 'presence': [], 'fallback': []})
        self.assertFalse(graph.config_units(inputs.config_change('CEO_RULINGS_PATHS=a', 'CEO_RULINGS_PATHS=b'), [unit]))
        document['nodes']['scripts/lib/premise-ask.sh']['sha256'] = 'changed'
        self.assertIn(unit, graph.config_units(inputs.config_change('CEO_TODOS_REPOS=a', 'CEO_TODOS_REPOS=b'), [unit]))

    def test_global_validator_is_a_qualified_whole_config_obligation(self):
        document = json.loads((HERE / "lib/verification-dependencies.json").read_text())
        graph = inputs.Dependencies(HERE.parent, document)
        unit = "scripts/verification-config.test.sh"
        closure = graph.closure(unit)
        self.assertEqual(closure["fallback"], [])
        self.assertTrue(closure["whole"])
        self.assertIn(unit, graph.config_units(inputs.config_change("A=1", "A=1\nUNUSED=2"), [unit]))

    def test_protocol_installers_and_stubbed_ci_do_not_read_real_config(self):
        document = json.loads((HERE / "lib/verification-dependencies.json").read_text())
        graph = inputs.Dependencies(HERE.parent, document)
        helpers = {"scripts/ci-verify.test.sh": "scripts/ci-verify.sh#stubbed-steps",
            "scripts/install-ack-protocol.test.sh": "scripts/install-ack-protocol.sh",
            "scripts/install-escalation-protocol.test.sh": "scripts/install-escalation-protocol.sh"}
        for unit, helper in helpers.items():
            with self.subTest(unit=unit):
                self.assertEqual(graph.closure(unit), {"keys": {}, "whole": [], "presence": [], "fallback": []})
                original = document["nodes"][helper]["sha256"]
                document["nodes"][helper]["sha256"] = "unreviewed"
                self.assertIn(unit, graph.config_units(inputs.config_change("MODEL_CEILING=a", "MODEL_CEILING=b"), [unit]))
                document["nodes"][helper]["sha256"] = original

    def test_slot_priority_and_pause_fixtures_have_reviewed_config_closures(self):
        document = json.loads((HERE / "lib/verification-dependencies.json").read_text())
        graph = inputs.Dependencies(HERE.parent, document)
        slot = "scripts/lib/engine_pass.test.sh"
        priority = "scripts/lib/worker-priority.test.sh"
        pause = "scripts/lib/pause_protocol.test.sh"
        for unit in (slot, priority, pause):
            closure = graph.closure(unit)
            self.assertFalse(closure["whole"] or closure["fallback"], closure)
        self.assertEqual(set(graph.closure(pause)["keys"]), {"SESSION_TEAMS_DIR"})
        self.assertTrue(graph.closure(slot)["presence"])
        change = inputs.config_change("BAN_WORKFLOW_TOOL=1", "BAN_WORKFLOW_TOOL=0")
        self.assertEqual(graph.config_units(change, [slot, priority, pause]), {})
        # A valid captured pause now continues past syntax validation. Its
        # recipient lookup and identity readers cannot be omitted or stale.
        for helper in ("scripts/lib/teammate-identity.py",
                       "mega-lander/workspaces.py#empty-recipient-fixture"):
            previous = document["nodes"][helper]["sha256"]
            document["nodes"][helper]["sha256"] = "changed"
            self.assertIn(pause, graph.config_units(change, [pause]))
            document["nodes"][helper]["sha256"] = previous
        fixture_sha = document["nodes"]["scripts/lib/verification-fixture.sh"]["sha256"]
        document["nodes"]["scripts/lib/verification-fixture.sh"]["sha256"] = "changed"
        self.assertEqual(set(graph.config_units(change, [slot, priority, pause])), {slot, priority})
        document["nodes"]["scripts/lib/verification-fixture.sh"]["sha256"] = fixture_sha
        document["nodes"]["scripts/lib/worker_tokens.py"]["sha256"] = "changed"
        self.assertIn(priority, graph.config_units(change, [priority]))

    def test_sealed_guard_copy_keeps_real_readers_and_only_masks_the_fixture_override(self):
        document = json.loads((HERE / 'lib/verification-dependencies.json').read_text())
        graph = inputs.Dependencies(HERE.parent, document)
        unit = 'scripts/hooks/guard-sealed-worktree.test.sh'
        expected = {'READONLY_ALLOWLIST', 'HARNESS_UTILITY_TYPES', 'SEAL_READONLY_TOOLS',
                    'APP_TEST_INSTANCE_PROCESS_NAMES', 'APP_TEST_INSTANCE_BUNDLE_ID',
                    'APP_TEST_INSTANCE_REAL_HOME_PATHS', 'APP_TEST_INSTANCE_QUIT_GRACE_SECONDS',
                    'APP_TEST_INSTANCE_KILL_GRACE_SECONDS'}
        closure = graph.closure(unit)
        self.assertEqual(closure['fallback'], [])
        self.assertEqual(set(closure['keys']), expected)
        self.assertFalse(closure['whole'])
        self.assertTrue(closure['presence'])
        for key in expected | {'SEAL_WAIT_SECONDS', 'SCRATCH_ROOT_NAME', 'MODEL_CEILING'}:
            selected = graph.config_units(inputs.config_change(key+'=old', key+'=new'), [unit])
            self.assertEqual(bool(selected), key in expected, key)
        document['nodes']['scripts/lib/appinstances.py#workspace-cleanup']['sha256'] = 'changed'
        self.assertIn(unit, graph.config_units(inputs.config_change('MODEL_CEILING=a', 'MODEL_CEILING=b'), [unit]))

    def test_payload_guards_and_private_ruling_fixtures_do_not_consume_copied_settings(self):
        document = json.loads((HERE / 'lib/verification-dependencies.json').read_text())
        graph = inputs.Dependencies(HERE.parent, document)
        cases = {
            'guard-interactive-prompt': 'scripts/lib/interactive-prompt.py#payload',
            'guard-host-display-power': 'scripts/lib/ceo-ruled.sh',
            'guard-no-home-network-phone': 'scripts/lib/ceo-ruled.sh',
        }
        for name, helper in cases.items():
            with self.subTest(name=name):
                unit = 'scripts/hooks/'+name+'.test.sh'
                closure = graph.closure(unit)
                self.assertFalse(closure['keys'] or closure['whole'] or closure['fallback'], closure)
                self.assertTrue(closure['presence'])
                change = inputs.config_change('CEO_RULINGS_PATHS=old', 'CEO_RULINGS_PATHS=new')
                self.assertNotIn(unit, graph.config_units(change, [unit]))
                previous = document['nodes'][helper]['sha256']
                document['nodes'][helper]['sha256'] = 'changed'
                self.assertIn(unit, graph.config_units(change, [unit]))
                document['nodes'][helper]['sha256'] = previous

    def test_session_notice_and_retired_installer_have_private_config_closures(self):
        document = json.loads((HERE / 'lib/verification-dependencies.json').read_text())
        graph = inputs.Dependencies(HERE.parent, document)
        cases = {'session-start-quota': 'scripts/lib/quota_watch.py#notice',
                 'install-retire-reconciler': 'scripts/lib/registered-hooks.sh'}
        for name, helper in cases.items():
            with self.subTest(name=name):
                unit = 'scripts/hooks/'+name+'.test.sh'
                self.assertEqual(graph.closure(unit), {'keys': {}, 'whole': [], 'presence': [], 'fallback': []})
                change = inputs.config_change('QUOTA_PAUSE_PERCENT=93', 'QUOTA_PAUSE_PERCENT=94')
                self.assertNotIn(unit, graph.config_units(change, [unit]))
                previous = document['nodes'][helper]['sha256']
                document['nodes'][helper]['sha256'] = 'changed'
                self.assertIn(unit, graph.config_units(change, [unit]))
                document['nodes'][helper]['sha256'] = previous

    def test_weekly_policy_fixture_and_real_source_scan_have_different_inputs(self):
        document = json.loads((HERE / "lib/verification-dependencies.json").read_text())
        graph = inputs.Dependencies(HERE.parent, document)
        weekly = "scripts/quota-weekly.test.sh"
        scan = "scripts/no-foreign-app-data.test.sh"
        self.assertEqual(graph.closure(weekly), {"keys": {}, "whole": [], "presence": [], "fallback": []})
        closure = graph.closure(scan)
        self.assertEqual(closure["fallback"], [])
        self.assertTrue(closure["whole"])
        self.assertEqual(set(graph.config_units(inputs.config_change("QUOTA_PAUSE_PERCENT=93", "QUOTA_PAUSE_PERCENT=94"), [weekly, scan])), {scan})
        document["nodes"]["scripts/lib/quota_watch.py#weekly-fixture"]["sha256"] = "changed"
        self.assertIn(weekly, graph.config_units(inputs.config_change("MODEL_CEILING=a", "MODEL_CEILING=b"), [weekly]))


if __name__ == "__main__":
    unittest.main()
