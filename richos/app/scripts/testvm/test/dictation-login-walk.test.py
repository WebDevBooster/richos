#!/usr/bin/env python3
"""dictation-login-walk.py's verdicts, offline. The live walk is its own proof."""
import importlib.util
import re
from pathlib import Path
import unittest

HERE = Path(__file__).resolve().parent.parent
APP = HERE.parent.parent
spec = importlib.util.spec_from_file_location('dictation_login_walk', HERE / 'dictation-login-walk.py')
walk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(walk)

BUNDLE = '/Users/admin/Applications/RichOS.app'


class ReadingTheRecords(unittest.TestCase):
    def test_launches_json_counts_starts(self):
        self.assertEqual(walk.launches('{"starts": [1, 2, 3], "open_run": null}'), 3)
        self.assertEqual(walk.launches(''), 0)
        self.assertEqual(walk.launches('{}'), 0)
        self.assertIsNone(walk.launches('{broken'))

    def test_the_tools_start_line_is_what_tool_rs_writes(self):
        line = ('2026-10-08T12:00:00.000Z dictation tool started: version 1.2.0-dev.abc1234, key F1, accuracy '
                'large-v3-turbo-q5_0, by launchd at login, the key held at /private/tmp/richos-501/dictation.sock')
        self.assertEqual(walk.started_line(line), {'version': '1.2.0-dev.abc1234', 'key': 1, 'accuracy': 'large-v3-turbo-q5_0',
                                                   'started': 'by launchd at login'})
        self.assertIsNone(walk.started_line('x key tap created for F1'))
        source = (APP / 'src-tauri/src/dictation/tool.rs').read_text()
        self.assertIn('"dictation tool started: version {own_version}, key F{}, accuracy {}, {launched_by}, the key held at {}{}"', source)
        for said in ('by launchd at login', 'restarting for the new version', 'the tool restarts once no dictation is in progress',
                     'LaunchServices opened RichOS and reached the tool', 'RichOS asked for', 'Turn dictation off chosen',
                     'Open RichOS chosen', 'an app connected: version {version}'):
            self.assertIn(said, source, said)
        app_side = (APP / 'src-tauri/src/dictation_app.rs').read_text()
        for said in ('an installed copy', 'login start is registered', 'login start is unregistered', 'works only while RichOS is open'):
            self.assertIn(said, app_side, said)
        main = (APP / 'src-tauri/src/main.rs').read_text()
        self.assertIn('"[richos] window: launch kind {}, splash {}"', main)


class TellingTheProcessesApart(unittest.TestCase):
    def test_the_installed_tool_is_launchds_and_the_app_is_not_the_tool(self):
        tool = BUNDLE + '/Contents/MacOS/richos-tauri --richos-dictation'
        child = BUNDLE + '/Contents/MacOS/richos-tauri --richos-dictation --data-dir /d --parent 42'
        app = BUNDLE + '/Contents/MacOS/richos-tauri'
        other = '/Users/admin/testvm/x/RichOS.app/Contents/MacOS/richos-tauri --richos-dictation'
        self.assertTrue(walk.is_tool(tool, BUNDLE))
        self.assertFalse(walk.is_tool(child, BUNDLE), "an app's child is not the launchd tool")
        self.assertFalse(walk.is_tool(app, BUNDLE))
        self.assertFalse(walk.is_tool(other, BUNDLE), 'another bundle')
        self.assertTrue(walk.is_app(app, BUNDLE))
        self.assertFalse(walk.is_app(tool, BUNDLE))
        self.assertFalse(walk.is_app(other, BUNDLE))


class TheSteps(unittest.TestCase):
    def test_the_three_parts_and_the_two_tool_stays_steps_are_in_order(self):
        steps = walk.STEPS
        self.assertEqual(steps[:3], ['identity', 'stage', 'install'])
        self.assertLess(steps.index('window-closed'), steps.index('reboot'))
        self.assertLess(steps.index('self-quit'), steps.index('reboot'))
        self.assertLess(steps.index('reboot'), steps.index('login'))
        self.assertLess(steps.index('login'), steps.index('ways-in'))
        self.assertLess(steps.index('update'), steps.index('turn-off'), 'the update needs the registered tool')
        self.assertLess(steps.index('turn-off'), steps.index('folder-copy'), 'the folder copy needs the key free and nothing registered')
        for step in steps:
            self.assertTrue(hasattr(walk.LoginWalk, step.replace('-', '_')), step)
        self.assertEqual(walk.WAYS, ['open-a', 'finder', 'dock', 'menu'])

    def test_a_button_is_clicked_by_click_button_never_by_click_with_one_argument(self):
        # walk-974ea2706058: BarWalk.click(x, y) is a point click; self.click('Not now') crashed.
        source = (HERE / 'dictation-login-walk.py').read_text()
        self.assertEqual(re.findall(r"self\.click\(\s*['\"]", source), [])
        self.assertTrue(hasattr(walk.LoginWalk, 'click_button'))

    def test_finder_is_never_sent_an_apple_event(self):
        # walk-d94269c3a41c: 'tell application "Finder"' put up a consent prompt nobody answers;
        # the Finder way in is open -R plus Command-O through System Events.
        source = (HERE / 'dictation-login-walk.py').read_text()
        self.assertNotIn('tell application "Finder"', source)

    def test_the_installed_copy_is_on_the_real_home(self):
        self.assertEqual(walk.REAL_HOME, '/Users/admin')
        self.assertTrue(walk.INSTALLED.startswith(walk.REAL_HOME + '/Applications/'))
        self.assertEqual(walk.DATA, walk.REAL_HOME + '/Library/Application Support/com.richos.app')
        self.assertEqual(walk.AGENT, 'com.richos.app.dictation')
        plist = (APP / 'src-tauri/launchd/com.richos.app.dictation.plist').read_text()
        self.assertIn('<string>' + walk.AGENT + '</string>', plist)


if __name__ == '__main__':
    unittest.main()
