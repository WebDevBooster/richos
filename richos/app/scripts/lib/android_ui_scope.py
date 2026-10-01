#!/usr/bin/env python3
"""android_ui_scope.py — what native-android-ui.test.sh runs from a teammate workspace.

THE WORKSPACE DEFAULT (CEO, 2026-10-01): with no selection, a runner started in a teammate
workspace runs only the test cases the branch adds or changes, plus the cases its changed files
are claimed by, and says so in one line. `engine/scripts/lib/workspace_scope.py` decides WHEN
(a cc/ branch in a linked worktree, and never under RICHOS_TEST_SCOPE=full, which proof-run.py and
the nightlies set); this decides WHAT for the Android screens suite.

    android_ui_scope.py workspace <root> <suite> [--full] -- <gradle --tests patterns...>

prints shell assignments (SCOPE, SCOPE_LINE, SCOPE_TESTS=(...)) for the suite to `eval`.

THE CASE IS A TEST CLASS HERE, not a method. The suite's cases are JUnit classes run by Robolectric
on the JVM, most named in Kotlin backticks with spaces and commas, which Gradle's `--tests`
filter does not take reliably; a class is seconds. The map, per changed path the suite claims:
  * a test class file (`app/src/test/kotlin/...`, with `@Test`)  -> its classes;
  * a source file `X.kt`                                         -> the sibling `XTest` class;
  * anything else the suite reads (a test helper, the catalog, Gradle, the suite itself) ->
    every class: it can change all of them.
Only classes the full run runs are ever selected (the patterns the suite passes), so a narrowed run
is a subset of the full one, never a different set. THERE IS NO DEVICE TO NARROW: Robolectric draws
the 360 dp and 412 dp phones as configurations of one test class, with no emulator.
"""
from pathlib import Path
import re
import shlex
import sys

ANDROID = 'richos/mobile/native-android/'
TEST_ROOT = ANDROID + 'app/src/test/kotlin/'
CLASS = re.compile(r'^(?:@\S+.*\n)*(?:(?:internal|open|abstract|private|public)\s+)*class\s+(\w+)', re.M)


def classes(path):
    """Fully qualified test classes declared in one Kotlin test file ([] when it has no test)."""
    text = Path(path).read_text(encoding='utf-8', errors='replace')
    if '@Test' not in text:
        return []
    m = re.search(r'^package\s+([\w.]+)', text, re.M)
    pkg = m.group(1) + '.' if m else ''
    # Only the test classes: a helper class beside them has no test, and Gradle refuses a
    # `--tests` filter that matches no test ("No tests found for given includes").
    return [pkg + name for name in CLASS.findall(text) if name.endswith('Test')]


def in_run(name, patterns):
    """Whether the full run runs class `name` (Gradle `--tests` patterns: exact or `pkg.*`)."""
    for p in patterns:
        if p.endswith('.*') and name.startswith(p[:-1]):
            return True
        if name == p:
            return True
    return False


def select(root, paths, patterns):
    """(classes, every): the classes the changed `paths` map to, or None with `every` naming the
    paths that can change every class."""
    root = Path(root)
    chosen, every = set(), []
    tests = {f.stem: f for f in (root / TEST_ROOT).rglob('*Test.kt')} if (root / TEST_ROOT).is_dir() else {}
    for path in paths:
        source = root / path
        if path.startswith(TEST_ROOT) and path.endswith('.kt') and source.is_file():
            found = classes(source)
            if not found:
                every.append(path)  # a helper every screen test uses (ScreenChecks.kt)
            chosen.update(c for c in found if in_run(c, patterns))
            continue
        if path.startswith(ANDROID) and path.endswith('.kt') and source.is_file():
            sibling = tests.get(source.stem + 'Test')
            found = [c for c in classes(sibling) if in_run(c, patterns)] if sibling else []
            if found:
                chosen.update(found)
                continue
        every.append(path)
    return (None if every else sorted(chosen)), every


def workspace_plan(root, suite, patterns, full=False, environ=None):
    sys.path.insert(0, str(Path(root) / 'richos/engine/scripts/lib'))
    import workspace_scope
    decided = workspace_scope.decide(root, full=full, environ=environ)
    plan = {'scope': 'full', 'line': '', 'tests': []}
    if decided['scope'] != 'narrow':
        return plan
    where = 'workspace run on %s, compared with main at %s' % (decided['branch'] or 'this checkout',
                                                               decided['base'][:12])
    full_cmd = 'bash scripts/native-android-ui.test.sh --full'
    declared = workspace_scope.inputs(suite)
    paths = [p for p in workspace_scope.changed(decided['root'], decided['base'])
             if workspace_scope.claimed(p, declared)]
    chosen, every = select(root, paths, patterns) if paths else ([], [])
    if not paths or chosen == []:
        plan['scope'] = 'refuse'
        plan['line'] = ('native-android-ui: REFUSED: %s: the branch changes no test class this suite runs '
                        'and nothing it reads, so nothing would run. Everything: %s ; chosen screens: '
                        'native-android-ui.test.sh <id|gN>' % (where, full_cmd))
        return plan
    plan['scope'] = 'narrow'
    if chosen is None:
        shown = ', '.join(every[:3]) + (' and %d more' % (len(every) - 3) if len(every) > 3 else '')
        plan['line'] = ('native-android-ui: %s: every test class, because %s can affect every class '
                        '(the same as %s)' % (where, shown, full_cmd))
        return plan
    plan['tests'] = chosen
    plan['line'] = ('native-android-ui: %s: %d test class(es): %s. Everything: %s'
                    % (where, len(chosen), ' '.join(c.rsplit('.', 1)[-1] for c in chosen), full_cmd))
    return plan


def main(argv):
    if argv[:1] != ['workspace'] or '--' not in argv or len(argv) < 4:
        print('usage: android_ui_scope.py workspace <root> <suite> [--full] -- <patterns...>', file=sys.stderr)
        return 64
    head, patterns = argv[1:argv.index('--')], [p for p in argv[argv.index('--') + 1:] if p != '--tests']
    try:
        plan = workspace_plan(head[0], head[1], patterns, full='--full' in head[2:])
    except ValueError as exc:
        print('android_ui_scope: %s' % exc, file=sys.stderr)
        return 64
    print('SCOPE=%s' % shlex.quote(plan['scope']))
    print('SCOPE_LINE=%s' % shlex.quote(plan['line']))
    print('SCOPE_TESTS=(%s)' % ' '.join(shlex.quote(c) for c in plan['tests']))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
