#!/usr/bin/env python3
"""Defeat the filesystem guard through real file resolution, without a GUI."""
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest

import probe_packaged as probe


class IsolationTests(unittest.TestCase):
    def test_failed_reap_preserves_the_process_workspace(self):
        root = None
        try:
            with self.assertRaisesRegex(probe.ProbeCleanupError, "staging retained"):
                with probe.staging('probe-cleanup-test-') as root:
                    (root / 'in-use').write_text('fixture')
                    raise probe.ProbeCleanupError('fixture process did not reap')
            self.assertEqual((root / 'in-use').read_text(), 'fixture')
        finally:
            if root and root.exists():
                shutil.rmtree(root)

    def test_intact_external_substitution_and_restored(self):
        with tempfile.TemporaryDirectory() as temp:
            parent = Path(temp)
            root = parent / 'installation'
            (root / 'home').mkdir(parents=True)
            executable = root / 'read-component'
            source = parent / 'reader.c'
            source.write_text('#include <stdio.h>\nint main(int n,char **v){'
                              'if(n!=2)return 2;FILE *f=fopen(v[1],"r");if(!f)return 3;'
                              'int c;while((c=fgetc(f))!=EOF)putchar(c);return fclose(f);}')
            subprocess.run(['cc', str(source), '-o', str(executable)], check=True, timeout=30)
            dependency = root / 'dependency'
            dependency.write_text('real dependency contents')
            command = [executable, dependency]
            self.assertEqual(probe.run(root, command), 'real dependency contents')
            outside = parent / 'valid-outside-copy'
            dependency.rename(outside)
            dependency.symlink_to(outside)
            with self.assertRaisesRegex(ValueError, 'refused inside isolation'):
                probe.run(root, command)
            # Removing the defense must make this very same negative case pass.
            self.assertEqual(probe.run(root, command, policy=probe.profile(root) + '(allow file-read*)'),
                             'real dependency contents')
            dependency.unlink()
            outside.rename(dependency)
            self.assertEqual(probe.run(root, command), 'real dependency contents')


if __name__ == '__main__':
    unittest.main()
