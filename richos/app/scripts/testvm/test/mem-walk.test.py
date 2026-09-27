#!/usr/bin/env python3
"""mem-walk.py's reading of one guest probe, offline, on the probe's own output shape."""
import importlib.util
from pathlib import Path
import sys
import unittest

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
spec = importlib.util.spec_from_file_location('mem_walk', HERE / 'mem-walk.py')
mem_walk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mem_walk)

# vm_stat's own layout (macOS 15), with round numbers: 16 KB pages.
PROBE_OUTPUT = """Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                               10000.
Pages active:                             90000.
Pages inactive:                           80000.
Pages speculative:                         5000.
Pages throttled:                              0.
Pages wired down:                         40000.
Pages purgeable:                           2000.
"Translation faults":                  99999999.
Pages copy-on-write:                     123456.
Pages zero filled:                      7654321.
Pages reactivated:                        11111.
Pages purged:                              2222.
File-backed pages:                        70000.
Anonymous pages:                         102000.
Pages stored in compressor:               30000.
Pages occupied by compressor:             10000.
Decompressions:                            3333.
Compressions:                              4444.
Pageins:                                   5555.
Pageouts:                                     6.
Swapins:                                      7.
Swapouts:                                    42.
hw.memsize: 4294967296
memorystatus_level: 55
proc:  409600 /Users/admin/testvm/walk-x/RichOS.app/Contents/MacOS/richos-tauri
proc:  307200 /Users/admin/.local/bin/claude
proc:  102400 claude
"""


class Parse(unittest.TestCase):
    def test_used_is_app_memory_plus_wired_plus_compressed(self):
        s = mem_walk.parse(PROBE_OUTPUT)
        # (102000 anonymous - 2000 purgeable + 40000 wired + 10000 compressor) x 16 KB = 2343.75 MB
        self.assertEqual(s['used_mb'], 2344)
        self.assertEqual(s['total_mb'], 4096)

    def test_need_is_total_less_the_kernels_available_level(self):
        s = mem_walk.parse(PROBE_OUTPUT)
        self.assertEqual((s['available_percent'], s['need_mb']), (55, 1843))

    def test_swapouts_and_the_app_and_claude_processes_are_read(self):
        s = mem_walk.parse(PROBE_OUTPUT)
        self.assertEqual(s['swapouts'], 42)
        self.assertEqual([(t['name'], t['rss_mb']) for t in s['top']],
                         [("richos-tauri", 400), ("claude", 300), ("claude", 100)])


if __name__ == '__main__':
    unittest.main(verbosity=1)
